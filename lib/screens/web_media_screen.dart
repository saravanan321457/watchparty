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
  final TextEditingController _passcodeController = TextEditingController();
  final TextEditingController _browserAddressController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScroll = ScrollController();

  WebViewController? _webViewController;

  // State
  bool _disposed = false;
  late bool _isHost;
  String _roomCode = '';
  String _videoUrl = '';
  String _roomTitle = 'Private Web Stream';
  bool _isPublic = false; // Default private
  bool _isAdultContent = false; // 18+ adult content flag
  int _maxViewers = 8; // Strictly capped at 8 people
  String _passcode = '';
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

  // Video Sniffer State
  bool _hasDetectedVideo = false;
  double _detectedVideoTime = 0.0;
  bool _detectedVideoPlaying = false;
  Timer? _videoDetectorTimer;

  // Signaling & WebSocket
  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;

  // Chat
  final List<Map<String, dynamic>> _chatMessages = [];
  bool _chatOpen = false;

  // Animations
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // Cloud & Web Presets
  final List<Map<String, dynamic>> _cloudPresets = [
    {
      'name': 'Google Drive',
      'icon': Icons.add_to_drive_rounded,
      'color': Color(0xFF34A853),
      'url': 'https://drive.google.com',
      'hint': 'Paste Google Drive video link (converted to preview player automatically)',
    },
    {
      'name': 'Dropbox',
      'icon': Icons.cloud_queue_rounded,
      'color': Color(0xFF0061FF),
      'url': 'https://www.dropbox.com',
      'hint': 'Paste Dropbox video link (converted to direct stream automatically)',
    },
    {
      'name': 'Direct MP4/M3U8',
      'icon': Icons.video_file_rounded,
      'color': Color(0xFF6C63FF),
      'url': 'https://',
      'hint': 'Paste any raw .mp4 or .m3u8 cloud streaming link',
    },
    {
      'name': '18+ Adult Video',
      'icon': Icons.explicit_rounded,
      'color': Color(0xFFFF1744),
      'url': 'https://',
      'hint': 'Watch private 18+ adult web video (Strictly private with PIN, max 8 viewers)',
    },
    {
      'name': 'Web Search',
      'icon': Icons.search_rounded,
      'color': Color(0xFF00B4D8),
      'url': 'https://www.google.com',
      'hint': 'Browse any website and play videos directly',
    },
  ];

  @override
  void initState() {
    super.initState();
    _isHost = widget.isHost;

    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Auto-generate 4-digit PIN for private rooms
    _passcode = (1000 + (DateTime.now().millisecond * 9) % 9000).toString();
    _passcodeController.text = _passcode;

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
    _videoDetectorTimer?.cancel();
    _pulseCtrl.dispose();
    _urlController.dispose();
    _titleController.dispose();
    _passcodeController.dispose();
    _browserAddressController.dispose();
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

  /// Converts Google Drive or Dropbox links to streamable embed/direct preview format
  String _formatUrl(String raw) {
    var trimmed = raw.trim();

    // 1. Google Drive preview conversion:
    // e.g. https://drive.google.com/file/d/1a2b3c4d5e/view?usp=sharing
    // -> https://drive.google.com/file/d/1a2b3c4d5e/preview
    final driveMatch = RegExp(r'drive\.google\.com\/file\/d\/([a-zA-Z0-9_-]+)').firstMatch(trimmed);
    if (driveMatch != null) {
      final fileId = driveMatch.group(1);
      return 'https://drive.google.com/file/d/$fileId/preview';
    }

    final driveOpenMatch = RegExp(r'drive\.google\.com\/open\?id=([a-zA-Z0-9_-]+)').firstMatch(trimmed);
    if (driveOpenMatch != null) {
      final fileId = driveOpenMatch.group(1);
      return 'https://drive.google.com/file/d/$fileId/preview';
    }

    // 2. Dropbox raw stream conversion:
    if (trimmed.contains('dropbox.com')) {
      if (trimmed.contains('?dl=0')) {
        trimmed = trimmed.replaceAll('?dl=0', '?raw=1');
      } else if (!trimmed.contains('?raw=1')) {
        trimmed = '$trimmed?raw=1';
      }
    }

    // 3. Fallback prefix
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
      _statusMessage = 'Connecting to private stream $_roomCode...';
    });

    try {
      // 1. Fetch Room from Firestore
      final doc = await FirebaseFirestore.instance.collection('rooms').doc(_roomCode).get();
      if (!doc.exists || doc.data() == null) {
        _safeSet(() {
          _isLoading = false;
          _statusMessage = 'Room not found';
        });
        _showSnack('Room not found. Check code.');
        return;
      }

      final room = RoomModel.fromFirestore(doc);

      // 2. Enforce 8 people capacity limit
      if (room.viewerCount >= room.maxViewers) {
        _safeSet(() {
          _isLoading = false;
          _statusMessage = 'Room is full (${room.maxViewers}/${room.maxViewers} participants)';
        });
        _showSnack('Room has reached its maximum capacity of ${room.maxViewers} people.');
        return;
      }

      // 3. Age verification if 18+ content
      if (room.isAdultContent) {
        final confirmed = await _showAgeGateDialog();
        if (!confirmed) {
          _safeSet(() => _isLoading = false);
          if (mounted) Navigator.pop(context);
          return;
        }
      }

      _videoUrl = _formatUrl(room.videoUrl ?? 'https://google.com');
      _roomTitle = room.title;
      _isAdultContent = room.isAdultContent;
      _maxViewers = room.maxViewers;
      _browserAddressController.text = _videoUrl;

      // 4. Increment viewer count
      await _firestoreService.incrementViewerCount(_roomCode);

      // 5. Connect to signaling server
      _connectWebSocket(isHost: false);

      // 6. Initialize WebView with videoUrl
      if (_videoUrl.isNotEmpty) {
        _initWebView(_videoUrl);
      }

      _safeSet(() {
        _isRoomCreated = true;
        _isLoading = false;
        _statusMessage = 'Connected to stream';
        _syncBadgeText = 'Synced';
        _isSynced = true;
      });
    } catch (e) {
      _safeSet(() {
        _isLoading = false;
        _statusMessage = 'Failed to join: $e';
      });
      _showSnack('Error connecting to room. Please check the code.');
    }
  }

  Future<bool> _showAgeGateDialog() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFFF1744), size: 28),
                  SizedBox(width: 10),
                  Text(
                    '18+ Adult Content',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ],
              ),
              content: const Text(
                'This private watch room is tagged as 18+ Adult Content. You must be at least 18 years old to enter this room.',
                style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Exit', style: TextStyle(color: Colors.white54)),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF1744)),
                  child: const Text('I am 18+ (Enter)'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  // ── Host Mode: Create Room ────────────────────────────────────────────────
  Future<void> _createHostRoom() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) {
      _showSnack('Please enter a website or video URL');
      return;
    }

    _safeSet(() => _isLoading = true);

    try {
      final formattedUrl = _formatUrl(rawUrl);
      _videoUrl = formattedUrl;
      _browserAddressController.text = formattedUrl;
      _roomCode = _generateCode();
      final title = _titleController.text.trim().isEmpty
          ? (_isAdultContent ? '🔞 Private 18+ Stream' : 'Cloud / Web Watch Party')
          : _titleController.text.trim();
      _roomTitle = title;
      _passcode = _passcodeController.text.trim();

      final currentUser = _auth.currentUser;
      final room = RoomModel(
        id: _roomCode,
        roomCode: _roomCode,
        hostId: currentUser?.uid ?? '',
        hostName: currentUser?.displayName?.isNotEmpty == true ? currentUser!.displayName! : 'Host',
        hostAvatar: currentUser?.photoURL,
        title: title,
        isPublic: _isPublic && !_isAdultContent, // 18+ is ALWAYS private
        videoType: 'WEB',
        videoUrl: formattedUrl,
        viewerCount: 1,
        maxViewers: _maxViewers, // Strictly capped at 8 people
        isAdultContent: _isAdultContent,
        passcode: _passcode.isNotEmpty ? _passcode : null,
        createdAt: DateTime.now(),
      );

      // Save room to Firestore
      await _firestoreService.createRoom(room);

      // Connect to WebSocket signaling server
      _connectWebSocket(isHost: true);

      // Initialize WebView
      _initWebView(formattedUrl);

      // Start periodic video sniffer
      _startVideoSniffer();

      _safeSet(() {
        _isRoomCreated = true;
        _isLoading = false;
        _statusMessage = 'Room ready! Max 8 viewers allowed.';
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
            _safeSet(() {
              _isWebLoading = true;
              _browserAddressController.text = url;
            });
          },
          onPageFinished: (String url) {
            _safeSet(() {
              _isWebLoading = false;
              _videoUrl = url;
              _browserAddressController.text = url;
            });
            _detectVideoOnPage();
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('Web resource error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
  }

  // ── Periodic Video Sniffer (Finds HTML5 <video> tags on web pages) ────────
  void _startVideoSniffer() {
    _videoDetectorTimer?.cancel();
    _videoDetectorTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_webViewController != null && !_disposed) {
        _detectVideoOnPage();
      }
    });
  }

  Future<void> _detectVideoOnPage() async {
    if (_webViewController == null) return;
    try {
      const jsCode = """
        (function() {
          var v = document.querySelector('video');
          if (!v) {
            var iframes = document.querySelectorAll('iframe');
            for (var i = 0; i < iframes.length; i++) {
              try {
                var doc = iframes[i].contentDocument || iframes[i].contentWindow.document;
                var iv = doc.querySelector('video');
                if (iv) { v = iv; break; }
              } catch(e) {}
            }
          }
          if (v) {
            return JSON.stringify({
              found: true,
              currentTime: v.currentTime || 0,
              paused: v.paused,
              duration: v.duration || 0
            });
          }
          return JSON.stringify({ found: false });
        })();
      """;
      final raw = await _webViewController!.runJavaScriptReturningResult(jsCode);
      var cleaned = raw.toString();
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        cleaned = cleaned.substring(1, cleaned.length - 1).replaceAll(r'\"', '"');
      }
      final parsed = jsonDecode(cleaned) as Map<String, dynamic>;
      if (parsed['found'] == true) {
        _safeSet(() {
          _hasDetectedVideo = true;
          _detectedVideoTime = (parsed['currentTime'] as num?)?.toDouble() ?? 0.0;
          _detectedVideoPlaying = !(parsed['paused'] as bool? ?? true);
        });
      }
    } catch (_) {}
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
            _statusMessage = 'Private room active! Share PIN with friends.';
          });
          break;

        case 'room_joined':
          _safeSet(() {
            _roomCode = data['roomId'] ?? _roomCode;
            _statusMessage = 'Joined private room';
            _syncBadgeText = 'Synced';
            _isSynced = true;
          });
          break;

        case 'viewer_joined':
          _safeSet(() {
            _viewerCount++;
            _statusMessage = 'Viewer joined ($_viewerCount/$_maxViewers)';
          });
          _showSnack('A viewer joined the private stream ($_viewerCount/$_maxViewers)');
          if (_isHost) _hostManualSync();
          break;

        case 'viewer_left':
          _safeSet(() {
            if (_viewerCount > 1) _viewerCount--;
            _statusMessage = 'Viewer left ($_viewerCount/$_maxViewers)';
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

        case 'url_changed':
          _handleViewerUrlChanged(data);
          break;

        case 'chat':
          _handleIncomingChat(data);
          break;

        case 'error':
          _showSnack('Server message: ${data['message'] ?? 'Notice'}');
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
      _showSnack('▶ Play broadcast to all $_viewerCount viewers');
    } catch (e) {
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
      _showSnack('⏸ Pause broadcast to all $_viewerCount viewers');
    } catch (e) {
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

      _showSnack('⚡ Synced time (${time.toStringAsFixed(1)}s) across all $_viewerCount viewers');
    } catch (e) {
      _send({
        'type': 'sync',
        'timestamp': 0.0,
        'isPlaying': true,
        'url': _videoUrl,
      });
    }
  }

  /// Broadcast current page navigation URL to all viewers
  void _hostSyncCurrentUrl() {
    if (_videoUrl.isNotEmpty) {
      _send({
        'type': 'url_changed',
        'url': _videoUrl,
      });
      _showSnack('Navigated all viewers to current page');
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
        videos.forEach(function(v) {
          if (Math.abs(v.currentTime - $timestamp) > 2) {
            v.currentTime = $timestamp;
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
        videos.forEach(function(v) {
          if (Math.abs(v.currentTime - $timestamp) > 2) {
            v.currentTime = $timestamp;
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

    final url = data['url'] as String?;
    if (url != null && url.isNotEmpty && url != _videoUrl) {
      _videoUrl = url;
      _browserAddressController.text = url;
      _webViewController!.loadRequest(Uri.parse(url));
    }

    final timestamp = (data['timestamp'] as num?)?.toDouble() ?? (data['position'] as num?)?.toDouble() ?? 0.0;
    final isPlaying = data['isPlaying'] as bool? ?? false;

    final js = """
      (function() {
        var videos = document.querySelectorAll('video');
        videos.forEach(function(v) {
          if (Math.abs(v.currentTime - $timestamp) > 2) {
            v.currentTime = $timestamp;
          }
          if ($isPlaying) {
            v.play();
          } else {
            v.pause();
          }
        });
      })();
    """;
    _webViewController!.runJavaScript(js);

    _safeSet(() {
      _syncBadgeText = 'Synced';
      _isSynced = true;
    });
  }

  void _handleViewerUrlChanged(Map<String, dynamic> data) {
    if (_isHost || _webViewController == null) return;
    final url = data['url'] as String?;
    if (url != null && url.isNotEmpty && url != _videoUrl) {
      _videoUrl = url;
      _browserAddressController.text = url;
      _webViewController!.loadRequest(Uri.parse(url));
      _showSnack('Host navigated to new page');
    }
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
        'message': text,
        'isMe': true,
        'time': DateTime.now(),
      });
      _chatController.clear();
    });

    _scrollChatToBottom();
  }

  void _handleIncomingChat(Map<String, dynamic> data) {
    final text = data['message'] as String? ?? '';
    final sender = data['sender'] as String? ?? 'Friend';

    _safeSet(() {
      _chatMessages.add({
        'sender': sender,
        'message': text,
        'isMe': false,
        'time': DateTime.now(),
      });
    });

    if (!_chatOpen) {
      _showSnack('$sender: $text');
    }
    _scrollChatToBottom();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Exit & Cleanup ────────────────────────────────────────────────────────
  Future<void> _leaveRoom({bool isDisposing = false}) async {
    try {
      if (_isHost && _roomCode.isNotEmpty) {
        await _firestoreService.deleteRoom(_roomCode);
      } else if (!_isHost && _roomCode.isNotEmpty) {
        await _firestoreService.decrementViewerCount(_roomCode);
      }
    } catch (_) {}

    _socketSubscription?.cancel();
    _socket?.sink.close();
    _socket = null;
    _socketSubscription = null;

    if (!isDisposing && mounted) {
      Navigator.of(context).pop();
    }
  }

  void _confirmLeaveDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(_isHost ? 'End Private Stream?' : 'Leave Stream?', style: const TextStyle(color: Colors.white)),
        content: Text(
          _isHost
              ? 'This will close the stream for all viewers.'
              : 'Are you sure you want to exit this watch room?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _leaveRoom();
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF1744)),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  void _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _urlController.text = data.text!;
      _showSnack('Pasted link from clipboard');
    }
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isRoomCreated) {
      return _buildActiveStreamingScreen();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            const Icon(Icons.lock_rounded, color: Color(0xFF6C63FF), size: 20),
            const SizedBox(width: 8),
            Text(
              _isHost ? 'Private Cloud & Web Stream' : 'Join Private Stream',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      body: _isHost ? _buildHostSetupBody() : _buildViewerLoadingBody(),
    );
  }

  // ── Host Setup Body ───────────────────────────────────────────────────────
  Widget _buildHostSetupBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Banner
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF2E1A47), Color(0xFF1A1A2E)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_rounded, color: Color(0xFF6C63FF), size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Private Stream (Max 8 People)',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Stream Google Drive, Cloud links, or 18+ adult web video in a strictly private room with PIN protection.',
                        style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),

          // 🔞 18+ Adult Content Toggle Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _isAdultContent ? const Color(0xFF2D1118) : const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isAdultContent ? const Color(0xFFFF1744) : Colors.white.withOpacity(0.08),
                width: _isAdultContent ? 1.5 : 1.0,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _isAdultContent
                        ? const Color(0xFFFF1744).withOpacity(0.2)
                        : Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.explicit_rounded,
                    color: _isAdultContent ? const Color(0xFFFF1744) : Colors.white60,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            '18+ Adult Video Content',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF1744),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('18+', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _isAdultContent
                            ? 'Strictly Private: Hidden from public discovery. Room PIN required.'
                            : 'Enable if streaming adult sites or mature content.',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isAdultContent ? const Color(0xFFFF8A80) : Colors.white.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isAdultContent,
                  activeColor: const Color(0xFFFF1744),
                  onChanged: (val) {
                    _safeSet(() {
                      _isAdultContent = val;
                      if (val) _isPublic = false; // 18+ is ALWAYS strictly private
                    });
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // URL Input
          const Text(
            'Website or Video Link',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Google Drive, Dropbox, direct MP4, or web URL...',
              prefixIcon: const Icon(Icons.link_rounded, color: Color(0xFF6C63FF)),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF6C63FF)),
                tooltip: 'Paste from clipboard',
                onPressed: _pasteFromClipboard,
              ),
              fillColor: const Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 12),

          // Preset Chips (Drive, Dropbox, Direct MP4, 18+ Sites)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _cloudPresets.map((preset) {
              return ActionChip(
                avatar: Icon(preset['icon'] as IconData, size: 16, color: preset['color'] as Color),
                backgroundColor: const Color(0xFF1A1A2E),
                side: BorderSide(color: (preset['color'] as Color).withOpacity(0.35)),
                label: Text(
                  preset['name'] as String,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                ),
                onPressed: () {
                  _urlController.text = preset['url'] as String;
                  if (preset['name'] == '18+ Adult Video') {
                    _safeSet(() => _isAdultContent = true);
                  }
                  _showSnack(preset['hint'] as String);
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
            decoration: InputDecoration(
              hintText: _isAdultContent ? '🔞 Private 18+ Watch Party' : 'e.g. Movie Stream, Drive Video...',
              prefixIcon: const Icon(Icons.title_rounded, color: Color(0xFF6C63FF)),
              fillColor: const Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 20),

          // Max Viewers Selector (Max 8 people)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.group_rounded, color: Color(0xFF6C63FF), size: 20),
                        SizedBox(width: 8),
                        Text('Room Capacity Limit', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('$_maxViewers People Max', style: const TextStyle(color: Color(0xFFA78BFA), fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [2, 4, 6, 8].map((cap) {
                    final isSelected = _maxViewers == cap;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text('$cap', style: TextStyle(color: isSelected ? Colors.white : Colors.white60, fontWeight: FontWeight.bold)),
                          selected: isSelected,
                          selectedColor: const Color(0xFF6C63FF),
                          backgroundColor: const Color(0xFF0A0A0F),
                          side: BorderSide(color: isSelected ? const Color(0xFF6C63FF) : Colors.white12),
                          onSelected: (_) => _safeSet(() => _maxViewers = cap),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Text(
                  'Capped at 8 people to ensure butter-smooth synchronized playback & privacy.',
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Security PIN / Passcode
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Row(
              children: [
                const Icon(Icons.pin_rounded, color: Color(0xFF6C63FF), size: 24),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Room Security PIN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text('Friends must enter this 4-digit PIN to join', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11)),
                    ],
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _passcodeController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    maxLength: 4,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 3),
                    decoration: const InputDecoration(
                      counterText: '',
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                      fillColor: Color(0xFF0A0A0F),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Start Stream Button
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
                  : Icon(_isAdultContent ? Icons.lock_open_rounded : Icons.cast_connected_rounded),
              label: Text(
                _isLoading
                    ? 'STARTING STREAM...'
                    : (_isAdultContent ? 'START 18+ PRIVATE STREAM' : 'START PRIVATE STREAM'),
                style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _isAdultContent ? const Color(0xFFFF1744) : const Color(0xFF6C63FF),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          const SizedBox(height: 30),
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

  // ── Active Streaming Screen (In-App Browser + Sync Overlay + Chat) ─────────
  Widget _buildActiveStreamingScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Column(
          children: [
            // 1. Browser Navigation Top Bar
            _buildBrowserTopBar(),

            if (_isWebLoading)
              LinearProgressIndicator(
                value: _webLoadingProgress / 100.0,
                backgroundColor: const Color(0xFF0A0A0F),
                valueColor: AlwaysStoppedAnimation<Color>(_isAdultContent ? const Color(0xFFFF1744) : const Color(0xFF6C63FF)),
                minHeight: 2,
              ),

            // 2. WebView Container
            Expanded(
              child: Stack(
                children: [
                  if (_webViewController != null)
                    WebViewWidget(controller: _webViewController!),

                  // Chat Panel Overlay (if open)
                  if (_chatOpen)
                    Positioned.fill(
                      child: Container(
                        color: const Color(0xFF0A0A0F).withOpacity(0.95),
                        child: _buildChatPanel(),
                      ),
                    ),

                  // Floating Video Sniffer & Sync Bar (Bottom)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: _buildFloatingSyncController(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── In-App Browser Navigation Top Bar ─────────────────────────────────────
  Widget _buildBrowserTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: const Color(0xFF141424),
      child: Column(
        children: [
          Row(
            children: [
              // Close / Leave Button
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 22),
                onPressed: _confirmLeaveDialog,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),

              // Back
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white60, size: 16),
                onPressed: () => _webViewController?.goBack(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),

              // Forward
              IconButton(
                icon: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white60, size: 16),
                onPressed: () => _webViewController?.goForward(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 10),

              // URL Display / Search Bar
              Expanded(
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A0F),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isAdultContent ? const Color(0xFFFF1744).withOpacity(0.5) : const Color(0xFF6C63FF).withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isAdultContent ? Icons.explicit_rounded : Icons.lock_rounded,
                        color: _isAdultContent ? const Color(0xFFFF1744) : const Color(0xFF6C63FF),
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _browserAddressController,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            hintText: 'Search or enter video URL...',
                            hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                          onSubmitted: (val) {
                            if (val.trim().isNotEmpty) {
                              final f = _formatUrl(val.trim());
                              _webViewController?.loadRequest(Uri.parse(f));
                            }
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh_rounded, color: Colors.white60, size: 18),
                        onPressed: () => _webViewController?.reload(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Chat Toggle
              Stack(
                children: [
                  IconButton(
                    icon: Icon(
                      _chatOpen ? Icons.videocam_rounded : Icons.chat_bubble_outline_rounded,
                      color: const Color(0xFF6C63FF),
                      size: 22,
                    ),
                    onPressed: () => _safeSet(() => _chatOpen = !_chatOpen),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  if (_chatMessages.isNotEmpty && !_chatOpen)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(color: Color(0xFFFF1744), shape: BoxShape.circle),
                        child: Text(
                          '${_chatMessages.length}',
                          style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Stream Info Bar: Room Code, PIN, Viewers Count (Max 8)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  if (_isAdultContent)
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0xFFFF1744), borderRadius: BorderRadius.circular(4)),
                      child: const Text('18+ PRIVATE', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: _roomCode));
                      _showSnack('Room code copied: $_roomCode');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.copy_rounded, color: Color(0xFFA78BFA), size: 12),
                          const SizedBox(width: 4),
                          Text('Room: $_roomCode', style: const TextStyle(color: Color(0xFFA78BFA), fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                  if (_passcode.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('PIN: $_passcode', style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              ),

              // Viewer Capacity Badge (Max 8 People)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.people_rounded, color: Colors.greenAccent, size: 13),
                    const SizedBox(width: 4),
                    Text('$_viewerCount/$_maxViewers People', style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Floating Video Sniffer & Playback Sync Controls ───────────────────────
  Widget _buildFloatingSyncController() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF141424).withOpacity(0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isAdultContent ? const Color(0xFFFF1744).withOpacity(0.4) : const Color(0xFF6C63FF).withOpacity(0.4),
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black87, blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              FadeTransition(
                opacity: _pulseAnim,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _hasDetectedVideo ? Colors.greenAccent : const Color(0xFF6C63FF),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _hasDetectedVideo
                      ? 'Video active (${_detectedVideoTime.toStringAsFixed(1)}s)'
                      : 'Watching web stream ($_viewerCount/$_maxViewers people)',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isHost)
                TextButton.icon(
                  onPressed: _hostSyncCurrentUrl,
                  icon: const Icon(Icons.sync_rounded, size: 14, color: Color(0xFF6C63FF)),
                  label: const Text('Sync Page', style: TextStyle(color: Color(0xFF6C63FF), fontSize: 11, fontWeight: FontWeight.bold)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), visualDensity: VisualDensity.compact),
                ),
            ],
          ),
          const SizedBox(height: 6),

          // Host Play / Pause / Match Time buttons
          Row(
            children: [
              if (_isHost) ...[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _hostPlay,
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Play All', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6C63FF),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _hostPause,
                    icon: const Icon(Icons.pause_rounded, size: 18),
                    label: const Text('Pause All', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF6C63FF)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _hostManualSync,
                  icon: const Icon(Icons.fast_forward_rounded, size: 18),
                  tooltip: 'Match Timestamps',
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF1E1E34),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ] else ...[
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.sync_rounded, color: Colors.greenAccent, size: 16),
                        const SizedBox(width: 6),
                        Text('Playback synchronized with Host', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12)),
                      ],
                    ),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: Color(0xFF141424),
            border: Border(bottom: BorderSide(color: Colors.white12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Room Chat (${_chatMessages.length})', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
                onPressed: () => _safeSet(() => _chatOpen = false),
              ),
            ],
          ),
        ),
        Expanded(
          child: _chatMessages.isEmpty
              ? Center(
                  child: Text('No messages yet. Say hello!', style: TextStyle(color: Colors.white.withOpacity(0.4))),
                )
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: _chatMessages.length,
                  itemBuilder: (ctx, i) {
                    final msg = _chatMessages[i];
                    final isMe = msg['isMe'] == true;
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isMe ? const Color(0xFF6C63FF) : const Color(0xFF1E1E34),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            if (!isMe)
                              Text(msg['sender'] as String, style: const TextStyle(color: Color(0xFFA78BFA), fontSize: 11, fontWeight: FontWeight.bold)),
                            Text(msg['message'] as String, style: const TextStyle(color: Colors.white, fontSize: 13)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          color: const Color(0xFF141424),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    fillColor: const Color(0xFF0A0A0F),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _sendChatMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _sendChatMessage,
                icon: const Icon(Icons.send_rounded, size: 20),
                style: IconButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
