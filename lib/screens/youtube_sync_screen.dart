import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../constants.dart';
import '../models/room_model.dart';
import '../services/firestore_service.dart';

/// Helper function to extract YouTube video ID from various URL formats.
/// Supports:
/// - youtu.be/VIDEO_ID
/// - youtube.com/watch?v=VIDEO_ID
/// - youtube.com/embed/VIDEO_ID
/// - youtube.com/shorts/VIDEO_ID
/// - Raw 11-character video ID
String? extractYouTubeId(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;

  // Direct 11-character video ID
  if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(trimmed)) {
    return trimmed;
  }

  // youtu.be/VIDEO_ID
  final shortMatch = RegExp(r'youtu\.be\/([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
  if (shortMatch != null && shortMatch.groupCount >= 1) {
    return shortMatch.group(1);
  }

  // youtube.com/watch?v=VIDEO_ID (and query parameters before/after)
  final watchMatch = RegExp(r'youtube\.com\/watch\?.*v=([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
  if (watchMatch != null && watchMatch.groupCount >= 1) {
    return watchMatch.group(1);
  }

  // youtube.com/embed/VIDEO_ID
  final embedMatch = RegExp(r'youtube\.com\/embed\/([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
  if (embedMatch != null && embedMatch.groupCount >= 1) {
    return embedMatch.group(1);
  }

  // youtube.com/shorts/VIDEO_ID
  final shortsMatch = RegExp(r'youtube\.com\/shorts\/([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
  if (shortsMatch != null && shortsMatch.groupCount >= 1) {
    return shortsMatch.group(1);
  }

  // Fallback to youtube_player_flutter built-in converter
  return YoutubePlayerController.convertUrlToId(trimmed);
}

class YouTubeSyncScreen extends StatefulWidget {
  final String? roomCode;
  final String? videoId;
  final bool isHost;

  const YouTubeSyncScreen({
    super.key,
    this.roomCode,
    this.videoId,
    this.isHost = true,
  });

  const YouTubeSyncScreen.host({
    super.key,
    this.videoId,
  })  : roomCode = null,
        isHost = true;

  const YouTubeSyncScreen.viewer({
    super.key,
    required String roomCode,
    String? videoId,
  })  : roomCode = roomCode,
        videoId = videoId,
        isHost = false;

  @override
  State<YouTubeSyncScreen> createState() => _YouTubeSyncScreenState();
}

class _YouTubeSyncScreenState extends State<YouTubeSyncScreen> with TickerProviderStateMixin {
  final FirestoreService _firestoreService = FirestoreService.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Controllers
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScroll = ScrollController();

  // State
  bool _disposed = false;
  late bool _isHost;
  String _roomCode = '';
  String? _videoId;
  String _roomTitle = 'YouTube Watch Party';
  bool _isPublic = true;
  bool _isRoomCreated = false;
  bool _isLoading = false;
  String _statusMessage = 'Initializing...';
  String _syncBadgeText = 'Syncing...';
  bool _isSynced = false;
  int _viewerCount = 1;

  // YouTube Player
  YoutubePlayerController? _ytController;
  bool _isPlayerReady = false;
  bool _isRemoteAction = false; // Prevents recursive broadcast loops
  Timer? _hostPeriodicSyncTimer;

  // Signaling & WebSocket
  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;

  // Chat
  final List<Map<String, dynamic>> _chatMessages = [];
  bool _chatOpen = false;

  // Animations
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _isHost = widget.isHost;

    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    if (widget.videoId != null && widget.videoId!.isNotEmpty) {
      _videoId = widget.videoId;
      _urlController.text = 'https://youtu.be/$_videoId';
    }

    if (!_isHost) {
      // Viewer mode initialization
      _roomCode = widget.roomCode ?? '';
      _initViewerMode();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _hostPeriodicSyncTimer?.cancel();
    _pulseCtrl.dispose();
    _urlController.dispose();
    _titleController.dispose();
    _chatController.dispose();
    _chatScroll.dispose();

    _leaveRoom(isDisposing: true);
    _ytController?.close();
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

  // ── Viewer Mode Setup ─────────────────────────────────────────────────────
  Future<void> _initViewerMode() async {
    _safeSet(() {
      _isLoading = true;
      _statusMessage = 'Connecting to room $_roomCode...';
    });

    try {
      // 1. Fetch Room from Firestore if videoId is missing
      if (_videoId == null || _videoId!.isEmpty) {
        final doc = await FirebaseFirestore.instance.collection('rooms').doc(_roomCode).get();
        if (doc.exists && doc.data() != null) {
          final room = RoomModel.fromFirestore(doc);
          _videoId = room.videoUrl;
          _roomTitle = room.title;
        }
      }

      // 2. Increment viewer count
      await _firestoreService.incrementViewerCount(_roomCode);

      // 3. Connect to signaling server
      _connectWebSocket(isHost: false);

      // 4. Initialize YouTube player if videoId found
      if (_videoId != null && _videoId!.isNotEmpty) {
        _initPlayer(_videoId!, autoPlay: true);
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
    final extractedId = extractYouTubeId(rawUrl);

    if (extractedId == null || extractedId.isEmpty) {
      _showSnack('Please paste a valid YouTube video link');
      return;
    }

    _safeSet(() => _isLoading = true);

    try {
      _videoId = extractedId;
      _roomCode = _generateCode();
      final title = _titleController.text.trim().isEmpty ? 'YouTube Watch Party' : _titleController.text.trim();
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
        videoType: 'YOUTUBE',
        videoUrl: extractedId,
        viewerCount: 1,
        createdAt: DateTime.now(),
      );

      // Save room to Firestore
      await _firestoreService.createRoom(room);

      // Connect to WebSocket signaling server
      _connectWebSocket(isHost: true);

      // Initialize YouTube player
      _initPlayer(extractedId, autoPlay: false);

      // Start periodic sync broadcast for host
      _startHostPeriodicSync();

      _safeSet(() {
        _isRoomCreated = true;
        _isLoading = false;
        _statusMessage = 'Waiting for viewers...';
        _syncBadgeText = 'Host (Ready)';
        _isSynced = true;
      });
    } catch (e) {
      _safeSet(() => _isLoading = false);
      _showSnack('Error creating room: $e');
    }
  }

  // ── WebSocket Signaling ───────────────────────────────────────────────────
  void _connectWebSocket({required bool isHost}) {
    try {
      _socket = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _socketSubscription = _socket!.stream.listen(
        _handleSignalMessage,
        onError: (e) {
          _safeSet(() {
            _statusMessage = 'Connection lost. Reconnecting...';
            _syncBadgeText = 'Reconnecting...';
            _isSynced = false;
          });
        },
        onDone: () {
          if (!_disposed && _roomCode.isNotEmpty) {
            _safeSet(() {
              _statusMessage = 'Disconnected from server';
              _syncBadgeText = 'Disconnected';
              _isSynced = false;
            });
          }
        },
      );

      // Send initial room setup message
      if (isHost) {
        _send({'type': 'create_room', 'roomId': _roomCode});
      } else {
        _send({'type': 'join_room', 'roomId': _roomCode});
      }
    } catch (e) {
      debugPrint('WebSocket connection error: $e');
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
            _statusMessage = 'Room created! Share the code.';
          });
          break;

        case 'room_joined':
          _safeSet(() {
            _roomCode = data['roomId'] ?? _roomCode;
            _statusMessage = 'Joined party!';
            _syncBadgeText = 'Synced';
            _isSynced = true;
          });
          break;

        case 'viewer_joined':
          _safeSet(() {
            _viewerCount++;
            _statusMessage = 'Viewer joined the party!';
          });
          _showSnack('A viewer joined the party!');
          // Immediately send sync state to the new viewer
          if (_isHost) _sendHostSync();
          break;

        case 'viewer_left':
          _safeSet(() {
            if (_viewerCount > 1) _viewerCount--;
            _statusMessage = 'Viewer left';
          });
          break;

        case 'play':
          _handleRemotePlay(data);
          break;

        case 'pause':
          _handleRemotePause(data);
          break;

        case 'seek':
          _handleRemoteSeek(data);
          break;

        case 'sync':
          _handleRemoteSync(data);
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

  // ── YouTube Player Setup & Listeners ──────────────────────────────────────
  void _initPlayer(String videoId, {required bool autoPlay}) {
    _ytController = YoutubePlayerController.fromVideoId(
      videoId: videoId,
      autoPlay: autoPlay,
      params: const YoutubePlayerParams(
        showControls: true,
        mute: false,
        showFullscreenButton: true,
      ),
    );
    _safeSet(() => _isPlayerReady = true);
  }

  void _startHostPeriodicSync() {
    _hostPeriodicSyncTimer?.cancel();
    _hostPeriodicSyncTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_isHost && _isPlayerReady && _ytController != null && !_disposed) {
        _sendHostSync();
      }
    });
  }

  Future<void> _sendHostSync() async {
    if (_ytController == null || !_isPlayerReady) return;
    try {
      final posSec = (await _ytController!.currentTime).toInt();
      final isPlaying = _ytController!.value.playerState == PlayerState.playing;

      _send({
        'type': 'sync',
        'position': posSec,
        'positionMs': posSec * 1000,
        'isPlaying': isPlaying,
        'videoId': _videoId,
      });
    } catch (_) {}
  }

  // ── Host Manual Controls (broadcasting events) ───────────────────────────
  Future<void> _hostPlay() async {
    if (_ytController == null) return;
    try {
      await _ytController!.playVideo();
      final posSec = (await _ytController!.currentTime).toInt();
      _send({
        'type': 'play',
        'position': posSec,
        'positionMs': posSec * 1000,
      });
    } catch (_) {}
  }

  Future<void> _hostPause() async {
    if (_ytController == null) return;
    try {
      await _ytController!.pauseVideo();
      final posSec = (await _ytController!.currentTime).toInt();
      _send({
        'type': 'pause',
        'position': posSec,
        'positionMs': posSec * 1000,
      });
    } catch (_) {}
  }

  Future<void> _hostSeek(int seconds) async {
    if (_ytController == null) return;
    try {
      await _ytController!.seekTo(seconds: seconds.toDouble(), allowSeekAhead: true);
      _send({
        'type': 'seek',
        'position': seconds,
        'positionMs': seconds * 1000,
      });
    } catch (_) {}
  }

  // ── Viewer Remote Mirroring Handlers ─────────────────────────────────────
  Future<void> _handleRemotePlay(Map<String, dynamic> data) async {
    if (_isHost) return;
    final posSec = (data['position'] as num?)?.toInt() ?? ((data['positionMs'] as num?)?.toInt() ?? 0) ~/ 1000;

    _safeSet(() {
      _syncBadgeText = 'Syncing...';
      _isSynced = false;
    });

    _isRemoteAction = true;
    if (_ytController != null) {
      try {
        final currentPos = (await _ytController!.currentTime).toInt();
        if ((currentPos - posSec).abs() > 2) {
          await _ytController!.seekTo(seconds: posSec.toDouble(), allowSeekAhead: true);
        }
        await _ytController!.playVideo();
      } catch (_) {}
    }
    Future.delayed(const Duration(milliseconds: 300), () {
      _isRemoteAction = false;
      _safeSet(() {
        _syncBadgeText = 'Synced';
        _isSynced = true;
      });
    });
  }

  Future<void> _handleRemotePause(Map<String, dynamic> data) async {
    if (_isHost) return;
    final posSec = (data['position'] as num?)?.toInt() ?? ((data['positionMs'] as num?)?.toInt() ?? 0) ~/ 1000;

    _safeSet(() {
      _syncBadgeText = 'Syncing...';
      _isSynced = false;
    });

    _isRemoteAction = true;
    if (_ytController != null) {
      try {
        final currentPos = (await _ytController!.currentTime).toInt();
        if ((currentPos - posSec).abs() > 2) {
          await _ytController!.seekTo(seconds: posSec.toDouble(), allowSeekAhead: true);
        }
        await _ytController!.pauseVideo();
      } catch (_) {}
    }
    Future.delayed(const Duration(milliseconds: 300), () {
      _isRemoteAction = false;
      _safeSet(() {
        _syncBadgeText = 'Synced';
        _isSynced = true;
      });
    });
  }

  Future<void> _handleRemoteSeek(Map<String, dynamic> data) async {
    if (_isHost) return;
    final posSec = (data['position'] as num?)?.toInt() ?? ((data['positionMs'] as num?)?.toInt() ?? 0) ~/ 1000;

    _safeSet(() {
      _syncBadgeText = 'Syncing...';
      _isSynced = false;
    });

    _isRemoteAction = true;
    try {
      await _ytController?.seekTo(seconds: posSec.toDouble(), allowSeekAhead: true);
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 300), () {
      _isRemoteAction = false;
      _safeSet(() {
        _syncBadgeText = 'Synced';
        _isSynced = true;
      });
    });
  }

  Future<void> _handleRemoteSync(Map<String, dynamic> data) async {
    if (_isHost) return;

    // Load video if viewer didn't have ID yet
    final remoteVideoId = data['videoId'] as String?;
    if (remoteVideoId != null && remoteVideoId.isNotEmpty && (_videoId == null || _videoId != remoteVideoId)) {
      _videoId = remoteVideoId;
      _initPlayer(remoteVideoId, autoPlay: data['isPlaying'] == true);
      return;
    }

    if (_ytController == null || !_isPlayerReady) return;

    final posSec = (data['position'] as num?)?.toInt() ?? ((data['positionMs'] as num?)?.toInt() ?? 0) ~/ 1000;
    final isPlaying = data['isPlaying'] as bool? ?? false;

    _isRemoteAction = true;
    try {
      final currentPos = (await _ytController!.currentTime).toInt();
      // Only seek if drift is greater than 2 seconds
      if ((currentPos - posSec).abs() > 2) {
        await _ytController!.seekTo(seconds: posSec.toDouble(), allowSeekAhead: true);
      }

      final isCurrentlyPlaying = _ytController!.value.playerState == PlayerState.playing;
      if (isPlaying && !isCurrentlyPlaying) {
        await _ytController!.playVideo();
      } else if (!isPlaying && isCurrentlyPlaying) {
        await _ytController!.pauseVideo();
      }
    } catch (_) {}

    Future.delayed(const Duration(milliseconds: 300), () {
      _isRemoteAction = false;
      _safeSet(() {
        _syncBadgeText = 'Synced';
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

  // ── Leave / Clean Up ──────────────────────────────────────────────────────
  Future<void> _leaveRoom({bool isDisposing = false}) async {
    _hostPeriodicSyncTimer?.cancel();

    if (_roomCode.isNotEmpty) {
      try {
        if (_isHost) {
          // Delete room document from Firestore
          await _firestoreService.deleteRoom(_roomCode);
        } else {
          // Decrement viewer count in Firestore
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
      final id = extractYouTubeId(data.text!.trim());
      if (id != null) {
        _safeSet(() => _videoId = id);
        _showSnack('Extracted YouTube Video ID: $id');
      } else {
        _showSnack('Pasted text is not a recognized YouTube URL');
      }
    } else {
      _showSnack('Clipboard is empty');
    }
  }

  // ── Build UI ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // If room is active and ready, show the Player & Sync screen
    if (_isRoomCreated && _videoId != null && _videoId!.isNotEmpty) {
      return _buildActivePartyScreen();
    }

    // Otherwise show Host Setup form or Viewer Loading screen
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        elevation: 0,
        title: Text(
          _isHost ? 'Host YouTube Party' : 'Joining YouTube Party',
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

  // ── Host Setup Form ───────────────────────────────────────────────────────
  Widget _buildHostSetupBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1A1A2E), Color(0xFF141424)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF0000).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.play_arrow_rounded, color: Color(0xFFFF0000), size: 36),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Watch YouTube in Sync',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Play, pause, and seek together with friends in real-time',
                        style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // URL Input Field
          const Text(
            'Paste YouTube URL',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            onChanged: (val) {
              final id = extractYouTubeId(val);
              _safeSet(() => _videoId = id);
            },
            decoration: InputDecoration(
              hintText: 'https://youtu.be/... or youtube.com/watch?v=...',
              prefixIcon: const Icon(Icons.link_rounded, color: Color(0xFF6C63FF)),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF6C63FF)),
                tooltip: 'Paste from clipboard',
                onPressed: _pasteFromClipboard,
              ),
              fillColor: const Color(0xFF1A1A2E),
            ),
          ),
          if (_videoId != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Valid video ID: $_videoId',
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Thumbnail preview
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  'https://img.youtube.com/vi/$_videoId/hqdefault.jpg',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFF1A1A2E),
                    child: const Center(
                      child: Icon(Icons.videocam_rounded, color: Colors.white38, size: 40),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
              hintText: 'e.g. Chill Music Session, Tech Talk...',
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
                        _isPublic ? 'Public Room' : 'Private Room',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isPublic
                            ? 'Visible in public explore feed'
                            : 'Only people with the code can join',
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

          // Create Room Button
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
                  : const Icon(Icons.rocket_launch_rounded),
              label: Text(_isLoading ? 'CREATING ROOM...' : 'CREATE ROOM'),
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
              'Connecting to room code: $_roomCode',
              style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ── Active Party Screen (Player + Sync Controls + Chat) ───────────────────
  Widget _buildActivePartyScreen() {
    return Scaffold(
          backgroundColor: const Color(0xFF0A0A0F),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0A0A0F),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close_rounded, size: 22),
              onPressed: () => _confirmLeaveDialog(),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _roomTitle,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    FadeTransition(
                      opacity: _pulseAnim,
                      child: Container(
                        width: 8,
                        height: 8,
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
                        fontSize: 11,
                        color: _isSynced ? Colors.greenAccent : Colors.amberAccent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              // Chat toggle button with badge
              TextButton.icon(
                onPressed: () => _safeSet(() => _chatOpen = !_chatOpen),
                icon: Icon(
                  _chatOpen ? Icons.videocam_rounded : Icons.chat_bubble_outline_rounded,
                  color: const Color(0xFF6C63FF),
                  size: 18,
                ),
                label: Text(
                  _chatOpen ? 'Controls' : 'Chat (${_chatMessages.length})',
                  style: const TextStyle(color: Color(0xFF6C63FF), fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              // Inline YouTube Player
              Container(
                color: Colors.black,
                child: YoutubePlayer(controller: _ytController!),
              ),

              // Content Area: Either Controls & Room Info or Chat Panel
              Expanded(
                child: _chatOpen ? _buildChatPanel() : _buildPartyControlsPanel(),
              ),
            ],
          ),
        );
  }

  // ── Party Controls Panel ──────────────────────────────────────────────────
  Widget _buildPartyControlsPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Room Code Card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.vpn_key_rounded, color: Color(0xFF6C63FF), size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ROOM CODE',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _roomCode,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copy Code',
                  icon: const Icon(Icons.copy_rounded, color: Color(0xFF6C63FF)),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _roomCode));
                    _showSnack('Room code $_roomCode copied to clipboard!');
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Host Play / Pause / Seek Sync Bar
          if (_isHost) ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Host Sync Controls',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6C63FF).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'MASTER',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF6C63FF),
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'All actions you make are broadcast to viewers instantly',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5)),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Replay 10s
                      IconButton.filledTonal(
                        onPressed: () async {
                          if (_ytController != null) {
                            try {
                              final current = (await _ytController!.currentTime).toInt();
                              _hostSeek((current - 10).clamp(0, 999999));
                            } catch (_) {}
                          }
                        },
                        icon: const Icon(Icons.replay_10_rounded),
                        style: IconButton.styleFrom(backgroundColor: const Color(0xFF0A0A0F)),
                      ),
                      // Play Button
                      FilledButton.icon(
                        onPressed: _hostPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play All'),
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
                      ),
                      // Pause Button
                      OutlinedButton.icon(
                        onPressed: _hostPause,
                        icon: const Icon(Icons.pause_rounded),
                        label: const Text('Pause All'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFF6C63FF)),
                        ),
                      ),
                      // Forward 10s
                      IconButton.filledTonal(
                        onPressed: () async {
                          if (_ytController != null) {
                            try {
                              final current = (await _ytController!.currentTime).toInt();
                              _hostSeek(current + 10);
                            } catch (_) {}
                          }
                        },
                        icon: const Icon(Icons.forward_10_rounded),
                        style: IconButton.styleFrom(backgroundColor: const Color(0xFF0A0A0F)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            // Viewer Sync Status Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.sync_rounded, color: Colors.greenAccent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Synced with Host',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Your player mirrors the host in real-time',
                          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Request Sync',
                    icon: const Icon(Icons.refresh_rounded, color: Color(0xFF6C63FF)),
                    onPressed: () {
                      _safeSet(() => _syncBadgeText = 'Syncing...');
                      _send({'type': 'request_sync'});
                      Future.delayed(const Duration(seconds: 1), () {
                        _safeSet(() => _syncBadgeText = 'Synced');
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),

          // Leave / End Party Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _confirmLeaveDialog(),
              icon: const Icon(Icons.exit_to_app_rounded, size: 20),
              label: Text(_isHost ? 'END PARTY FOR ALL' : 'LEAVE PARTY'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.redAccent, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Chat Panel (Bubble UI) ────────────────────────────────────────────────
  Widget _buildChatPanel() {
    return Column(
      children: [
        // Messages List
        Expanded(
          child: _chatMessages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded, size: 44, color: Colors.white.withOpacity(0.15)),
                      const SizedBox(height: 12),
                      Text('No messages yet', style: TextStyle(color: Colors.white.withOpacity(0.3))),
                      const SizedBox(height: 4),
                      Text('Say hi to everyone in the party!', style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 12)),
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
                          boxShadow: isMe
                              ? [
                                  BoxShadow(
                                    color: const Color(0xFF6C63FF).withOpacity(0.25),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  )
                                ]
                              : null,
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

        // Chat Input Bar
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
                    hintText: 'Send a message...',
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
                  width: 42,
                  height: 42,
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
        title: Text(_isHost ? 'End YouTube Party?' : 'Leave Party?'),
        content: Text(
          _isHost
              ? 'Leaving will end the room for all connected viewers.'
              : 'Are you sure you want to exit this watch party?',
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
