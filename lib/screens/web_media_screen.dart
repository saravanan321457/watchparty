import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../constants.dart';
import '../models/room_model.dart';
import '../services/firestore_service.dart';

class WebMediaScreen extends StatefulWidget {
  final String? roomCode;
  final String? videoUrl;
  final bool isHost;

  const WebMediaScreen({
    super.key,
    this.roomCode,
    this.videoUrl,
    this.isHost = true,
  });

  const WebMediaScreen.host({
    super.key,
    this.videoUrl,
  })  : roomCode = null,
        isHost = true;

  const WebMediaScreen.viewer({
    super.key,
    required String roomCode,
    String? videoUrl,
  })  : roomCode = roomCode,
        videoUrl = videoUrl,
        isHost = false;

  @override
  State<WebMediaScreen> createState() => _WebMediaScreenState();
}

class _WebMediaScreenState extends State<WebMediaScreen> with TickerProviderStateMixin {
  final FirestoreService _firestoreService = FirestoreService.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Controllers
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScroll = ScrollController();

  WebViewController? _webViewController;

  // State
  bool _disposed = false;
  late bool _isHost;
  String _roomCode = '';
  String _videoUrl = '';
  String _roomTitle = 'Web Stream Party';
  bool _isPublic = true;
  bool _isRoomCreated = false;
  bool _isLoading = false;
  bool _isWebLoading = true;
  int _webLoadingProgress = 0;
  String _statusMessage = 'Initializing...';
  String _syncBadgeText = 'Syncing...';
  bool _isSynced = false;
  int _viewerCount = 1;
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _showDrmBanner = true;

  // Signaling & WebSocket
  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;

  // Chat
  final List<Map<String, dynamic>> _chatMessages = [];
  bool _chatOpen = false;

  // Animations
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // Popular web media presets
  final List<Map<String, String>> _popularPresets = [
    {'name': 'YouTube', 'url': 'https://m.youtube.com'},
    {'name': 'Netflix', 'url': 'https://www.netflix.com'},
    {'name': 'Prime Video', 'url': 'https://www.primevideo.com'},
    {'name': 'Disney+', 'url': 'https://www.disneyplus.com'},
    {'name': 'Twitch', 'url': 'https://m.twitch.tv'},
    {'name': 'Vimeo', 'url': 'https://vimeo.com/watch'},
  ];

  @override
  void initState() {
    super.initState();
    _isHost = widget.isHost;

    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    if (widget.videoUrl != null && widget.videoUrl!.isNotEmpty) {
      _videoUrl = _formatUrl(widget.videoUrl!);
      _urlController.text = _videoUrl;
    }

    if (!_isHost) {
      _roomCode = widget.roomCode ?? '';
      _initViewerMode();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controlsTimer?.cancel();
    _pulseCtrl.dispose();
    _urlController.dispose();
    _titleController.dispose();
    _chatController.dispose();
    _chatScroll.dispose();

    _leaveRoom(isDisposing: true);
    super.dispose();
  }

  void _safeSet(VoidCallback fn) {
    if (mounted && !_disposed) setState(fn);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1A1A2E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _generateCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = DateTime.now().microsecondsSinceEpoch;
    return List.generate(6, (i) => chars[(rnd + i * 7919) % chars.length]).join();
  }

  String _formatUrl(String raw) {
    var trimmed = raw.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    return trimmed;
  }

  void _toggleControls() {
    _safeSet(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _controlsTimer?.cancel();
      _controlsTimer = Timer(const Duration(seconds: 5), () {
        if (!_chatOpen && mounted && !_disposed) {
          _safeSet(() => _controlsVisible = false);
        }
      });
    }
  }

  // ── Viewer Mode Setup ─────────────────────────────────────────────────────
  Future<void> _initViewerMode() async {
    _safeSet(() {
      _isLoading = true;
      _statusMessage = 'Connecting to room $_roomCode...';
    });

    try {
      // 1. Fetch Room from Firestore if videoUrl is missing
      if (_videoUrl.isEmpty) {
        final doc = await FirebaseFirestore.instance.collection('rooms').doc(_roomCode).get();
        if (doc.exists && doc.data() != null) {
          final room = RoomModel.fromFirestore(doc);
          _videoUrl = _formatUrl(room.videoUrl ?? 'https://youtube.com');
          _roomTitle = room.title;
        }
      }

      // 2. Increment viewer count
      await _firestoreService.incrementViewerCount(_roomCode);

      // 3. Connect to signaling server
      _connectWebSocket(isHost: false);

      // 4. Initialize WebView with videoUrl
      if (_videoUrl.isNotEmpty) {
        _initWebView(_videoUrl);
      }

      _safeSet(() {
        _isRoomCreated = true;
        _isLoading = false;
        _statusMessage = 'Connected to room';
        _syncBadgeText = 'Synced';
        _isSynced = true;
      });
    } catch (e) {
      _safeSet(() {
        _isLoading = false;
        _statusMessage = 'Failed to join room: $e';
      });
      _showSnack('Error connecting to room. Please check the code.');
    }
  }

  // ── Host Mode: Create Room ────────────────────────────────────────────────
  Future<void> _createHostRoom() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) {
      _showSnack('Please enter a video URL');
      return;
    }

    _safeSet(() => _isLoading = true);

    try {
      final formattedUrl = _formatUrl(rawUrl);
      _videoUrl = formattedUrl;
      _roomCode = _generateCode();
      final title = _titleController.text.trim().isEmpty ? 'Web Watch Party' : _titleController.text.trim();
      _roomTitle = title;

      final currentUser = _auth.currentUser;
      final room = RoomModel(
        id: _roomCode,
        roomCode: _roomCode,
        hostId: currentUser?.uid ?? '',
        hostName: currentUser?.displayName?.isNotEmpty == true ? currentUser!.displayName! : 'Host',
        hostAvatar: currentUser?.photoURL,
        title: title,
        isPublic: _isPublic,
        videoType: 'WEB',
        videoUrl: formattedUrl,
        viewerCount: 1,
        createdAt: DateTime.now(),
      );

      // Save room to Firestore
      await _firestoreService.createRoom(room);

      // Connect to WebSocket signaling server
      _connectWebSocket(isHost: true);

      // Initialize WebView
      _initWebView(formattedUrl);

      _safeSet(() {
        _isRoomCreated = true;
        _isLoading = false;
        _statusMessage = 'Waiting for viewers...';
        _syncBadgeText = 'Host (Master)';
        _isSynced = true;
      });
    } catch (e) {
      _safeSet(() => _isLoading = false);
      _showSnack('Error creating room: $e');
    }
  }

  // ── WebView Initialization ────────────────────────────────────────────────
  void _initWebView(String url) {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0A0A0F))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            _safeSet(() => _webLoadingProgress = progress);
          },
          onPageStarted: (String url) {
            _safeSet(() => _isWebLoading = true);
          },
          onPageFinished: (String url) {
            _safeSet(() {
              _isWebLoading = false;
              _videoUrl = url;
            });
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('Web resource error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
  }

  // ── WebSocket Signaling ───────────────────────────────────────────────────
  void _connectWebSocket({required bool isHost}) {
    try {
      _socket = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _socketSubscription = _socket!.stream.listen(
        _handleSignalMessage,
        onError: (e) {
          _safeSet(() {
            _statusMessage = 'Signaling disconnected';
            _syncBadgeText = 'Reconnecting...';
            _isSynced = false;
          });
        },
        onDone: () {
          if (!_disposed && _roomCode.isNotEmpty) {
            _safeSet(() {
              _statusMessage = 'Signaling closed';
              _syncBadgeText = 'Disconnected';
              _isSynced = false;
            });
          }
        },
      );

      if (isHost) {
        _send({'type': 'create_room', 'roomId': _roomCode});
      } else {
        _send({'type': 'join_room', 'roomId': _roomCode});
      }
    } catch (e) {
      debugPrint('WebSocket connect error: $e');
      _safeSet(() => _statusMessage = 'Server connection error');
    }
  }

  void _send(Map<String, dynamic> data) {
    if (_socket != null && !_disposed) {
      try {
        _socket!.sink.add(jsonEncode(data));
      } catch (e) {
        debugPrint('WebSocket send error: $e');
      }
    }
  }

  void _handleSignalMessage(dynamic rawMsg) {
    if (_disposed) return;
    try {
      final data = jsonDecode(rawMsg as String) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case 'room_created':
          _safeSet(() {
            _roomCode = data['roomId'] ?? _roomCode;
            _statusMessage = 'Room ready! Share the code.';
          });
          break;

        case 'room_joined':
          _safeSet(() {
            _roomCode = data['roomId'] ?? _roomCode;
            _statusMessage = 'Joined room successfully';
            _syncBadgeText = 'Synced';
            _isSynced = true;
          });
          break;

        case 'viewer_joined':
          _safeSet(() {
            _viewerCount++;
            _statusMessage = 'Viewer joined!';
          });
          _showSnack('A viewer joined the session!');
          if (_isHost) _hostManualSync();
          break;

        case 'viewer_left':
          _safeSet(() {
            if (_viewerCount > 1) _viewerCount--;
            _statusMessage = 'Viewer left';
          });
          break;

        case 'play':
          _handleViewerPlay(data);
          break;

        case 'pause':
          _handleViewerPause(data);
          break;

        case 'seek':
        case 'sync':
          _handleViewerSync(data);
          break;

        case 'chat':
          _handleIncomingChat(data);
          break;

        case 'error':
          _showSnack('Server error: ${data['message'] ?? 'Unknown'}');
          break;
      }
    } catch (e) {
      debugPrint('Signal handle error: $e');
    }
  }

  // ── Host Controls & JavaScript Extraction ────────────────────────────────
  Future<void> _hostPlay() async {
    if (_webViewController == null) return;
    try {
      const jsCode = """
        (function() {
          var videos = document.querySelectorAll('video');
          var currentTime = 0;
          videos.forEach(function(v) {
            v.play();
            currentTime = v.currentTime;
          });
          return currentTime;
        })();
      """;
      final result = await _webViewController!.runJavaScriptReturningResult(jsCode);
      final timeSeconds = (result is num) ? result.toDouble() : double.tryParse(result.toString()) ?? 0.0;

      _send({
        'type': 'play',
        'timestamp': timeSeconds,
        'position': timeSeconds,
      });
      _showSnack('Play command sent to viewers');
    } catch (e) {
      debugPrint('Error triggering play: $e');
      _send({'type': 'play', 'timestamp': 0.0});
    }
  }

  Future<void> _hostPause() async {
    if (_webViewController == null) return;
    try {
      const jsCode = """
        (function() {
          var videos = document.querySelectorAll('video');
          var currentTime = 0;
          videos.forEach(function(v) {
            v.pause();
            currentTime = v.currentTime;
          });
          return currentTime;
        })();
      """;
      final result = await _webViewController!.runJavaScriptReturningResult(jsCode);
      final timeSeconds = (result is num) ? result.toDouble() : double.tryParse(result.toString()) ?? 0.0;

      _send({
        'type': 'pause',
        'timestamp': timeSeconds,
        'position': timeSeconds,
      });
      _showSnack('Pause command sent to viewers');
    } catch (e) {
      debugPrint('Error triggering pause: $e');
      _send({'type': 'pause', 'timestamp': 0.0});
    }
  }

  Future<void> _hostManualSync() async {
    if (_webViewController == null) return;
    try {
      const jsCode = """
        (function() {
          var v = document.querySelector('video');
          if (!v) {
            return JSON.stringify({ time: 0, paused: true, found: false });
          }
          return JSON.stringify({ time: v.currentTime, paused: v.paused, found: true });
        })();
      """;

      final rawResult = await _webViewController!.runJavaScriptReturningResult(jsCode);
      var cleaned = rawResult.toString();
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        cleaned = cleaned.substring(1, cleaned.length - 1).replaceAll(r'\"', '"');
      }

      final parsed = jsonDecode(cleaned) as Map<String, dynamic>;
      final time = (parsed['time'] as num?)?.toDouble() ?? 0.0;
      final isPlaying = !(parsed['paused'] as bool? ?? true);

      _send({
        'type': 'sync',
        'timestamp': time,
        'position': time,
        'isPlaying': isPlaying,
        'url': _videoUrl,
      });

      _showSnack('Synced playback with viewers (${time.toStringAsFixed(1)}s)');
    } catch (e) {
      debugPrint('Manual sync error: $e');
      _send({
        'type': 'sync',
        'timestamp': 0.0,
        'isPlaying': true,
        'url': _videoUrl,
      });
      _showSnack('Sent sync ping to viewers');
    }
  }

  // ── Viewer JavaScript Injections on Sync ─────────────────────────────────
  void _handleViewerPlay(Map<String, dynamic> data) {
    if (_isHost || _webViewController == null) return;
    final timestamp = (data['timestamp'] as num?)?.toDouble() ?? (data['position'] as num?)?.toDouble() ?? 0.0;

    _safeSet(() {
      _syncBadgeText = 'Syncing...';
      _isSynced = false;
    });

    final js = """
      (function() {
        var videos = document.querySelectorAll('video');
        var t = $timestamp;
        videos.forEach(function(v) {
          if (t > 0 && Math.abs(v.currentTime - t) > 1.5) {
            v.currentTime = t;
          }
          v.play();
        });
      })();
    """;

    _webViewController!.runJavaScript(js);

    Future.delayed(const Duration(milliseconds: 400), () {
      _safeSet(() {
        _syncBadgeText = 'Synced';
        _isSynced = true;
      });
    });
  }

  void _handleViewerPause(Map<String, dynamic> data) {
    if (_isHost || _webViewController == null) return;
    final timestamp = (data['timestamp'] as num?)?.toDouble() ?? (data['position'] as num?)?.toDouble() ?? 0.0;

    _safeSet(() {
      _syncBadgeText = 'Syncing...';
      _isSynced = false;
    });

    final js = """
      (function() {
        var videos = document.querySelectorAll('video');
        var t = $timestamp;
        videos.forEach(function(v) {
          if (t > 0 && Math.abs(v.currentTime - t) > 1.5) {
            v.currentTime = t;
          }
          v.pause();
        });
      })();
    """;

    _webViewController!.runJavaScript(js);

    Future.delayed(const Duration(milliseconds: 400), () {
      _safeSet(() {
        _syncBadgeText = 'Synced';
        _isSynced = true;
      });
    });
  }

  void _handleViewerSync(Map<String, dynamic> data) {
    if (_isHost || _webViewController == null) return;
    final timestamp = (data['timestamp'] as num?)?.toDouble() ?? (data['position'] as num?)?.toDouble() ?? 0.0;
    final shouldPlay = data['isPlaying'] as bool? ?? false;

    _safeSet(() {
      _syncBadgeText = 'Syncing...';
      _isSynced = false;
    });

    final js = """
      (function() {
        var videos = document.querySelectorAll('video');
        var t = $timestamp;
        var play = $shouldPlay;
        videos.forEach(function(v) {
          if (t > 0) {
            v.currentTime = t;
          }
          if (play) {
            v.play();
          } else {
            v.pause();
          }
        });
      })();
    """;

    _webViewController!.runJavaScript(js);

    Future.delayed(const Duration(milliseconds: 500), () {
      _safeSet(() {
        _syncBadgeText = 'Synced (${timestamp.toStringAsFixed(0)}s)';
        _isSynced = true;
      });
    });
  }

  // ── Chat Handlers ─────────────────────────────────────────────────────────
  void _sendChatMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;

    final currentUser = _auth.currentUser;
    final senderName = currentUser?.displayName?.isNotEmpty == true
        ? currentUser!.displayName!
        : (_isHost ? 'Host' : 'Viewer');

    _send({
      'type': 'chat',
      'message': text,
      'sender': senderName,
    });

    _safeSet(() {
      _chatMessages.add({
        'sender': 'You',
        'text': text,
        'timestamp': DateTime.now(),
      });
    });

    _chatController.clear();
    _scrollChatToBottom();
  }

  void _handleIncomingChat(Map<String, dynamic> data) {
    final sender = data['sender'] as String? ?? (_isHost ? 'Viewer' : 'Host');
    final message = data['message'] as String? ?? '';

    if (message.isNotEmpty) {
      _safeSet(() {
        _chatMessages.add({
          'sender': sender,
          'text': message,
          'timestamp': DateTime.now(),
        });
      });
      _scrollChatToBottom();
    }
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Leave & Clean Up ──────────────────────────────────────────────────────
  Future<void> _leaveRoom({bool isDisposing = false}) async {
    _controlsTimer?.cancel();

    if (_roomCode.isNotEmpty) {
      try {
        if (_isHost) {
          await _firestoreService.deleteRoom(_roomCode);
        } else {
          await _firestoreService.decrementViewerCount(_roomCode);
        }
      } catch (e) {
        debugPrint('Error leaving Firestore room: $e');
      }
    }

    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    _socket = null;
    _socketSubscription = null;

    if (!isDisposing && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null && data.text!.isNotEmpty) {
      _urlController.text = data.text!.trim();
      _showSnack('Pasted URL from clipboard');
    } else {
      _showSnack('Clipboard is empty');
    }
  }

  // ── Build UI ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isRoomCreated && _webViewController != null) {
      return _buildActiveStreamingScreen();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        elevation: 0,
        title: Text(
          _isHost ? 'Host Web Stream' : 'Joining Web Party',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isHost ? _buildHostSetupBody() : _buildViewerLoadingBody(),
    );
  }

  // ── Host Setup Body ───────────────────────────────────────────────────────
  Widget _buildHostSetupBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // DRM Warning Banner
          _buildDrmWarningBanner(),
          const SizedBox(height: 24),

          // URL Input
          const Text(
            'Enter video URL (Netflix, Prime, YouTube, etc.)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'https://www.netflix.com or https://youtube.com',
              prefixIcon: const Icon(Icons.language_rounded, color: Color(0xFF6C63FF)),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF6C63FF)),
                tooltip: 'Paste from clipboard',
                onPressed: _pasteFromClipboard,
              ),
              fillColor: const Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 12),

          // Preset Quick Selection Chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _popularPresets.map((preset) {
              return ActionChip(
                backgroundColor: const Color(0xFF1A1A2E),
                side: BorderSide(color: const Color(0xFF6C63FF).withOpacity(0.3)),
                label: Text(preset['name']!, style: const TextStyle(color: Colors.white, fontSize: 12)),
                onPressed: () {
                  _urlController.text = preset['url']!;
                  _showSnack('Selected ${preset['name']}');
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 24),

          // Room Title
          const Text(
            'Room Title',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'e.g. Anime Night, Movie Watch Party...',
              prefixIcon: Icon(Icons.title_rounded, color: Color(0xFF6C63FF)),
              fillColor: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 24),

          // Public/Private Switch Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Row(
              children: [
                Icon(
                  _isPublic ? Icons.public_rounded : Icons.lock_outline_rounded,
                  color: const Color(0xFF6C63FF),
                  size: 24,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isPublic ? 'Public Stream' : 'Private Stream',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isPublic ? 'Visible to everyone in discovery feed' : 'Only people with the code can join',
                        style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5)),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isPublic,
                  activeColor: const Color(0xFF6C63FF),
                  onChanged: (val) => _safeSet(() => _isPublic = val),
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),

          // Open & Host Button
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              onPressed: _isLoading ? null : _createHostRoom,
              icon: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.cast_connected_rounded),
              label: Text(_isLoading ? 'CREATING ROOM...' : 'OPEN & HOST'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Viewer Loading Screen ─────────────────────────────────────────────────
  Widget _buildViewerLoadingBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF6C63FF)),
            ),
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              'Connecting to stream room: $_roomCode',
              style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ── DRM Warning Banner ────────────────────────────────────────────────────
  Widget _buildDrmWarningBanner() {
    if (!_showDrmBanner) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2E1C0C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orangeAccent.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 24),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'DRM-protected sites (Netflix, Prime) may show a black screen on some devices. This is a device limitation.',
              style: TextStyle(color: Color(0xFFFFD180), fontSize: 12, height: 1.4),
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.close_rounded, color: Colors.orangeAccent, size: 18),
            onPressed: () => _safeSet(() => _showDrmBanner = false),
          ),
        ],
      ),
    );
  }

  // ── Active Streaming Screen (WebView + Overlay Bar + Chat) ────────────────
  Widget _buildActiveStreamingScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Stack(
          children: [
            // 1. Full WebView
            GestureDetector(
              onTap: _toggleControls,
              behavior: HitTestBehavior.translucent,
              child: Column(
                children: [
                  if (_isWebLoading)
                    LinearProgressIndicator(
                      value: _webLoadingProgress / 100.0,
                      backgroundColor: const Color(0xFF0A0A0F),
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                    ),
                  Expanded(
                    child: WebViewWidget(controller: _webViewController!),
                  ),
                ],
              ),
            ),

            // 2. Overlay Sync Controls Bar at Top
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              top: _controlsVisible ? 0 : -140,
              left: 0,
              right: 0,
              child: _buildTopOverlayControlsBar(),
            ),

            // 3. Chat Panel Overlay (Drawer/Sheet style)
            if (_chatOpen)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: MediaQuery.of(context).size.height * 0.55,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A0F),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.8),
                        blurRadius: 20,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Party Chat (${_chatMessages.length})',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, color: Colors.white70),
                              onPressed: () => _safeSet(() => _chatOpen = false),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: Colors.white12),
                      Expanded(child: _buildChatPanel()),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Top Overlay Controls Bar ──────────────────────────────────────────────
  Widget _buildTopOverlayControlsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0F).withOpacity(0.92),
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.1))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Top row: Back, Room Title, Room Code, Chat Toggle
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: _confirmLeaveDialog,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _roomTitle,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        FadeTransition(
                          opacity: _pulseAnim,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isSynced ? Colors.greenAccent : Colors.amberAccent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _syncBadgeText,
                          style: TextStyle(
                            color: _isSynced ? Colors.greenAccent : Colors.amberAccent,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Room Code Chip
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _roomCode));
                  _showSnack('Room code $_roomCode copied!');
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.vpn_key_rounded, size: 14, color: Color(0xFF6C63FF)),
                      const SizedBox(width: 6),
                      Text(
                        _roomCode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.copy_rounded, size: 12, color: Colors.white54),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Chat button
              IconButton(
                icon: Badge(
                  isLabelVisible: _chatMessages.isNotEmpty,
                  label: Text('${_chatMessages.length}'),
                  child: const Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF6C63FF)),
                ),
                onPressed: () => _safeSet(() => _chatOpen = !_chatOpen),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // Bottom row: Host / Viewer Sync transport buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (_isHost) ...[
                // Play Button
                FilledButton.tonalIcon(
                  onPressed: _hostPlay,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Play'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A2E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
                // Pause Button
                FilledButton.tonalIcon(
                  onPressed: _hostPause,
                  icon: const Icon(Icons.pause_rounded, size: 18),
                  label: const Text('Pause'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A2E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
                // Sync Now button
                FilledButton.icon(
                  onPressed: _hostManualSync,
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Sync Now'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                ),
              ] else ...[
                // Viewer Sync Now button
                FilledButton.icon(
                  onPressed: () {
                    _safeSet(() => _syncBadgeText = 'Syncing...');
                    _send({'type': 'request_sync'});
                    _showSnack('Requested host sync');
                    Future.delayed(const Duration(seconds: 1), () {
                      _safeSet(() => _syncBadgeText = 'Synced');
                    });
                  },
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Sync with Host'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ── Chat Panel ────────────────────────────────────────────────────────────
  Widget _buildChatPanel() {
    return Column(
      children: [
        Expanded(
          child: _chatMessages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded, size: 40, color: Colors.white.withOpacity(0.15)),
                      const SizedBox(height: 8),
                      Text('No messages yet', style: TextStyle(color: Colors.white.withOpacity(0.3))),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: _chatMessages.length,
                  itemBuilder: (context, i) {
                    final msg = _chatMessages[i];
                    final isMe = msg['sender'] == 'You';
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: isMe ? const Color(0xFF6C63FF) : const Color(0xFF1A1A2E),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMe ? 16 : 4),
                            bottomRight: Radius.circular(isMe ? 4 : 16),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            Text(
                              msg['sender'] as String,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              msg['text'] as String,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),

        // Chat Input Field
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Message party...',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    filled: true,
                    fillColor: const Color(0xFF0A0A0F),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _sendChatMessage(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sendChatMessage,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: Color(0xFF6C63FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _confirmLeaveDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(_isHost ? 'End Web Stream?' : 'Leave Stream?'),
        content: Text(
          _isHost
              ? 'Leaving will terminate the session for all connected viewers.'
              : 'Are you sure you want to leave this session?',
          style: TextStyle(color: Colors.white.withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _leaveRoom();
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }
}
