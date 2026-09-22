import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'constants.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key});
  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> with TickerProviderStateMixin {
  static const _channelNative = MethodChannel('mp4_webrtc');

  bool _disposed = false;
  String? _videoPath;
  String _videoName = '';
  String _videoSize = '';

  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  String _roomId = '';
  String _status = '';
  bool _viewerConnected = false;

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  MediaStream? _videoStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  bool _isPlaying = false;
  bool _isLoading = false;
  bool _isFullscreen = false;
  bool _showControls = true;
  Timer? _controlsTimer;
  int _positionMs = 0;
  int _durationMs = 0;

  final List<Map<String, dynamic>> _chatMessages = [];
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  bool _chatOpen = false;
  Timer? _progressTimer;

  // Animation
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _progressTimer?.cancel();
    _controlsTimer?.cancel();
    _pulseCtrl.dispose();
    _chatController.dispose();
    _chatScroll.dispose();
    _leaveRoom();
    _localRenderer.dispose();
    super.dispose();
  }

  void _safeSet(VoidCallback fn) {
    if (mounted && !_disposed) setState(fn);
  }

  void _showControls_() {
    _safeSet(() => _showControls = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (_isPlaying) _safeSet(() => _showControls = false);
    });
  }

  // ── Chat ─────────────────────────────────────────────────────────────────
  void _sendChatMessage() {
    final msg = _chatController.text.trim();
    if (msg.isNotEmpty && _viewerConnected) {
      _channel?.send(RTCDataChannelMessage(jsonEncode({'type': 'chat', 'message': msg})));
      _safeSet(() => _chatMessages.add({'sender': 'You', 'text': msg}));
      _chatController.clear();
      _scrollChat();
    }
  }

  void _scrollChat() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(_chatScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  // ── File Picker ─────────────────────────────────────────────────────────
  Future<void> _selectVideo() async {
    _safeSet(() => _isLoading = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        withData: false,
        withReadStream: false,
      );
      if (result == null) return;
      final file = result.files.single;
      final path = file.path ?? file.identifier;
      if (path != null && path.isNotEmpty) {
        final sizeStr = file.size > 0
            ? (file.size > 1024 * 1024 * 1024
                ? '${(file.size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
                : '${(file.size / (1024 * 1024)).toStringAsFixed(0)} MB')
            : '';
        _safeSet(() {
          _videoPath = path;
          _videoName = file.name;
          _videoSize = sizeStr;
        });
      } else {
        _showSnack('Could not access this video file. Please try another.');
      }
    } catch (e) {
      _showSnack('Error selecting file. Please try again.');
    } finally {
      _safeSet(() => _isLoading = false);
    }
  }

  // ── Room / Signaling ─────────────────────────────────────────────────────
  Future<void> _createRoom() async {
    if (_videoPath == null) return;
    try {
      _socket = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _socketSubscription = _socket!.stream.listen(_handleSignal, onError: (e) {
        _safeSet(() => _status = 'Reconnecting...');
      }, onDone: () {
        if (!_disposed && _roomId.isNotEmpty) {
          _safeSet(() => _status = 'Disconnected from server');
        }
      });
      _socket!.sink.add(jsonEncode({'type': 'create_room', 'roomId': _generateCode()}));
      _safeSet(() => _status = 'Connecting...');
    } catch (e) {
      _showSnack('Could not connect to server. Check your internet.');
    }
  }

  String _generateCode() {
    final chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = DateTime.now().microsecondsSinceEpoch;
    return List.generate(6, (i) => chars[(rnd + i * 7919) % chars.length]).join();
  }

  void _send(Map<String, dynamic> data) {
    if (_socket != null) _socket!.sink.add(jsonEncode(data));
  }

  Future<void> _handleSignal(dynamic msg) async {
    if (_disposed) return;
    try {
      final data = jsonDecode(msg as String) as Map<String, dynamic>;
      switch (data['type']) {
        case 'room_created':
          _safeSet(() {
            _roomId = data['roomId'];
            _status = 'Waiting for viewer...';
          });
          break;
        case 'viewer_joined':
          _safeSet(() => _status = 'Viewer joining...');
          await _resetPeer(keepMedia: true);
          await _createOffer();
          break;
        case 'viewer_left':
          _safeSet(() {
            _status = 'Waiting for viewer...';
            _viewerConnected = false;
          });
          await _resetPeer(keepMedia: true);
          break;
        case 'answer':
          await _handleAnswer(data);
          break;
        case 'ice_candidate':
          await _handleIce(data);
          break;
        case 'error':
          _safeSet(() => _status = 'Error: ${data['message']}');
          break;
      }
    } catch (e) {
      debugPrint('Signal handle failed: $e');
    }
  }

  // ── WebRTC ────────────────────────────────────────────────────────────────
  Future<void> _createOffer() async {
    try {
      _pc = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
          {'urls': 'turn:openrelay.metered.ca:80', 'username': 'openrelayproject', 'credential': 'openrelayproject'},
          {'urls': 'turn:openrelay.metered.ca:443', 'username': 'openrelayproject', 'credential': 'openrelayproject'},
          {'urls': 'turn:openrelay.metered.ca:443?transport=tcp', 'username': 'openrelayproject', 'credential': 'openrelayproject'},
        ]
      });
      _pc!.onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _safeSet(() => _status = 'Connection failed — ask viewer to rejoin');
        } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _safeSet(() => _status = 'Viewer disconnected');
        }
      };
      _pc!.onIceCandidate = (c) {
        if (c.candidate != null) {
          _send({'type': 'ice_candidate', 'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}});
        }
      };
      _channel = await _pc!.createDataChannel('watch_control', RTCDataChannelInit());
      _channel!.onDataChannelState = (s) {
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          _safeSet(() {
            _viewerConnected = true;
            _status = 'Viewer Connected';
          });
          _startProgressTimer();
        } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
          _safeSet(() {
            _viewerConnected = false;
            _status = 'Viewer left';
          });
        }
      };
      _channel!.onMessage = (RTCDataChannelMessage m) {
        try {
          final data = jsonDecode(m.text);
          if (data['type'] == 'chat') {
            _safeSet(() => _chatMessages.add({'sender': 'Viewer', 'text': data['message']}));
            _scrollChat();
          }
        } catch (_) {}
      };
      if (_videoStream == null) {
        _videoStream = await navigator.mediaDevices.getUserMedia({
          'video': {'optional': [{'sourceId': 'MP4_VIDEO:$_videoPath'}]},
          'audio': true,
        });
        _localRenderer.srcObject = _videoStream;
      }
      for (final track in _videoStream!.getTracks()) {
        await _pc!.addTrack(track, _videoStream!);
      }
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send({'type': 'offer', 'sdp': offer.sdp});
    } catch (e) {
      _safeSet(() => _status = 'Failed to start stream. Tap "Create Room" again.');
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'answer'));
  }

  Future<void> _handleIce(Map<String, dynamic> data) async {
    final c = data['candidate'];
    if (c != null && _pc != null) {
      await _pc!.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
    }
  }

  Future<void> _resetPeer({bool keepMedia = false}) async {
    _progressTimer?.cancel();
    _progressTimer = null;
    await _channel?.close();
    await _pc?.close();
    _channel = null;
    _pc = null;
    if (!keepMedia) {
      _localRenderer.srcObject = null;
      await _videoStream?.dispose();
      _videoStream = null;
    }
    _safeSet(() {
      _isPlaying = false;
      _positionMs = 0;
      _durationMs = 0;
    });
  }

  Future<void> _leaveRoom() async {
    await _resetPeer();
    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    _socket = null;
    _socketSubscription = null;
    _safeSet(() {
      _roomId = '';
      _status = '';
      _viewerConnected = false;
    });
  }

  // ── Playback controls ─────────────────────────────────────────────────────
  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        final pos = await _channelNative.invokeMethod<int>('getPosition') ?? 0;
        final dur = await _channelNative.invokeMethod<int>('getDuration') ?? 0;
        _safeSet(() {
          _positionMs = pos;
          _durationMs = dur;
        });
      } catch (_) {}
    });
  }

  void _sendControl(String type, [int? positionMs]) {
    if (_channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _channel!.send(RTCDataChannelMessage(jsonEncode({
        'type': type,
        if (positionMs != null) 'positionMs': positionMs,
      })));
    }
  }

  Future<void> _togglePlay() async {
    if (!_viewerConnected) return;
    _showControls_();
    try {
      if (_isPlaying) {
        await _channelNative.invokeMethod('pause');
        _sendControl('pause', _positionMs);
      } else {
        await _channelNative.invokeMethod('play');
        _sendControl('play', _positionMs);
      }
      _safeSet(() => _isPlaying = !_isPlaying);
    } catch (_) {}
  }

  Future<void> _seekTo(int ms) async {
    if (!_viewerConnected) return;
    _showControls_();
    try {
      final clamped = ms.clamp(0, _durationMs > 0 ? _durationMs : 0);
      await _channelNative.invokeMethod('seek', {'position': clamped});
      _sendControl('seek', clamped);
      _safeSet(() => _positionMs = clamped);
    } catch (_) {}
  }

  void _showSnack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatTime(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isFullscreen) return _buildFullscreen();
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _roomId.isEmpty ? 'HOST A MOVIE' : 'HOSTING · $_roomId',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2),
        ),
        centerTitle: true,
        actions: [
          if (_roomId.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy_rounded, size: 20),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _roomId));
                _showSnack('Room code copied!');
              },
            ),
        ],
      ),
      body: _roomId.isEmpty ? _buildSetup() : _buildRoom(),
    );
  }

  Widget _buildSetup() {
    return SafeArea(
      child: _isLoading
          ? const Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Color(0xFF6C63FF)),
                SizedBox(height: 20),
                Text('Loading video...', style: TextStyle(color: Colors.white54)),
              ],
            ))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SizedBox(height: 32),
                  // Illustration
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: const Color(0xFF2A2A4A), width: 1.5),
                    ),
                    child: const Icon(Icons.movie_filter_rounded, size: 56, color: Color(0xFF6C63FF)),
                  ),
                  const SizedBox(height: 32),
                  const Text('Select a Video', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Pick any MP4 from your device to stream',
                      style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 14)),
                  const SizedBox(height: 40),
                  if (_videoName.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.4), width: 1.5),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: const Color(0xFF6C63FF).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.play_circle_outline_rounded, color: Color(0xFF6C63FF), size: 26),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_videoName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                if (_videoSize.isNotEmpty)
                                  Text(_videoSize, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.change_circle_outlined, color: Colors.white38, size: 22),
                            onPressed: _selectVideo,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        onPressed: _createRoom,
                        icon: const Icon(Icons.cast_rounded),
                        label: const Text('CREATE ROOM'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF6C63FF),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: _selectVideo,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('BROWSE FILES'),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF6C63FF), width: 1.5),
                          foregroundColor: const Color(0xFF6C63FF),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildRoom() {
    return Column(
      children: [
        // Status bar
        _buildStatusBar(),
        // Video player
        GestureDetector(
          onTap: _showControls_,
          child: Container(
            color: Colors.black,
            height: MediaQuery.of(context).size.height * 0.3,
            child: Stack(
              children: [
                Center(
                  child: _videoStream != null
                      ? RTCVideoView(_localRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                      : const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF))),
                ),
                // Top-right controls
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 28),
                    onPressed: () {
                      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                      _safeSet(() => _isFullscreen = true);
                    },
                  ),
                ),
                // Overlay controls (visible when _showControls)
                if (_viewerConnected && _showControls)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                        ),
                      ),
                      child: Column(
                        children: [
                          _buildProgressBar(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.replay_10_rounded, color: Colors.white, size: 28),
                                onPressed: () => _seekTo(_positionMs - 10000),
                              ),
                              const SizedBox(width: 20),
                              GestureDetector(
                                onTap: _togglePlay,
                                child: Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF6C63FF),
                                    shape: BoxShape.circle,
                                    boxShadow: [BoxShadow(color: const Color(0xFF6C63FF).withOpacity(0.5), blurRadius: 12)],
                                  ),
                                  child: Icon(
                                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 32,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 20),
                              IconButton(
                                icon: const Icon(Icons.forward_10_rounded, color: Colors.white, size: 28),
                                onPressed: () => _seekTo(_positionMs + 10000),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Chat + controls
        Expanded(
          child: _chatOpen ? _buildChatPanel() : _buildRoomInfo(),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) => Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _viewerConnected ? const Color(0xFF4CAF50) : const Color(0xFFFFA000),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (_viewerConnected ? const Color(0xFF4CAF50) : const Color(0xFFFFA000))
                        .withOpacity(_pulseAnim.value),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(_status, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13))),
          TextButton.icon(
            onPressed: () => _safeSet(() => _chatOpen = !_chatOpen),
            icon: Icon(_chatOpen ? Icons.videocam_rounded : Icons.chat_rounded, size: 18),
            label: Text(_chatOpen ? 'Video' : 'Chat'),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF6C63FF)),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final max = _durationMs > 0 ? _durationMs.toDouble() : 1.0;
    final val = _positionMs.toDouble().clamp(0.0, max);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: const Color(0xFF6C63FF),
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: val,
              max: max,
              onChanged: (v) => _safeSet(() => _positionMs = v.toInt()),
              onChangeEnd: (v) => _seekTo(v.toInt()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatTime(_positionMs), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                Text(_formatTime(_durationMs), style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoomInfo() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Room code card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A2A4A), width: 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.key_rounded, color: Color(0xFF6C63FF)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Room Code', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
                      Text(_roomId,
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 6)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.share_rounded, color: Color(0xFF6C63FF)),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _roomId));
                    _showSnack('Code copied! Share it with your friend.');
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (!_viewerConnected)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFA000))),
                  SizedBox(width: 16),
                  Text('Waiting for viewer to join...', style: TextStyle(color: Colors.white54)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _leaveRoom,
              icon: const Icon(Icons.stop_circle_outlined, size: 20),
              label: const Text('END SESSION'),
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
                      const SizedBox(height: 12),
                      Text('No messages yet', style: TextStyle(color: Colors.white.withOpacity(0.25))),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _chatMessages.length,
                  itemBuilder: (context, i) {
                    final msg = _chatMessages[i];
                    final isMe = msg['sender'] == 'You';
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          color: isMe ? const Color(0xFF6C63FF) : const Color(0xFF1A1A2E),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            Text(msg['sender']!, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10)),
                            Text(msg['text']!, style: const TextStyle(color: Colors.white, fontSize: 14)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  decoration: InputDecoration(
                    hintText: _viewerConnected ? 'Message viewer...' : 'Waiting for viewer...',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    filled: true,
                    fillColor: const Color(0xFF0A0A0F),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                  enabled: _viewerConnected,
                  onSubmitted: (_) => _sendChatMessage(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sendChatMessage,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(color: Color(0xFF6C63FF), shape: BoxShape.circle),
                  child: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFullscreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _showControls_,
        child: Stack(
          children: [
            _videoStream != null
                ? RTCVideoView(_localRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                : const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF))),
            if (_showControls) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 40, 8, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white, size: 28),
                        onPressed: () {
                          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                          _safeSet(() => _isFullscreen = false);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildProgressBar(),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(icon: const Icon(Icons.replay_10_rounded, color: Colors.white, size: 36), onPressed: () => _seekTo(_positionMs - 10000)),
                          const SizedBox(width: 32),
                          GestureDetector(
                            onTap: _togglePlay,
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(color: const Color(0xFF6C63FF), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFF6C63FF).withOpacity(0.5), blurRadius: 20)]),
                              child: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 38),
                            ),
                          ),
                          const SizedBox(width: 32),
                          IconButton(icon: const Icon(Icons.forward_10_rounded, color: Colors.white, size: 36), onPressed: () => _seekTo(_positionMs + 10000)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
