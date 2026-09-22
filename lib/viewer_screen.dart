import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'constants.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});
  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> with TickerProviderStateMixin {
  final _roomController = TextEditingController();

  bool _disposed = false;
  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  String _roomId = '';
  String _status = 'Enter the room code from your host';
  bool _connected = false;
  bool _isLoading = false;
  bool _isFullscreen = false;
  bool _remoteDescriptionSet = false;
  bool _showControls = true;
  Timer? _controlsTimer;

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  MediaStream? _remoteStream;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final List<RTCIceCandidate> _pendingIce = [];

  bool _isPlaying = false;
  int _positionMs = 0;
  int _durationMs = 0;

  final List<Map<String, dynamic>> _chatMessages = [];
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  bool _chatOpen = false;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _dotCtrl;

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _dotCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  }

  @override
  void dispose() {
    _disposed = true;
    _controlsTimer?.cancel();
    _pulseCtrl.dispose();
    _dotCtrl.dispose();
    _roomController.dispose();
    _chatController.dispose();
    _chatScroll.dispose();
    _leaveRoom();
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _safeSet(VoidCallback fn) {
    if (mounted && !_disposed) setState(fn);
  }

  void _showControlsTemp() {
    _safeSet(() => _showControls = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      _safeSet(() => _showControls = false);
    });
  }

  void _scrollChat() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(_chatScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _sendChatMessage() {
    final msg = _chatController.text.trim();
    if (msg.isNotEmpty && _connected) {
      _channel?.send(RTCDataChannelMessage(jsonEncode({'type': 'chat', 'message': msg})));
      _safeSet(() => _chatMessages.add({'sender': 'You', 'text': msg}));
      _chatController.clear();
      _scrollChat();
    }
  }

  Future<void> _joinRoom() async {
    final code = _roomController.text.trim().toUpperCase();
    if (code.length < 4) {
      _safeSet(() => _status = 'Please enter the 6-character room code');
      return;
    }
    _safeSet(() => _isLoading = true);
    try {
      _socket = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _socketSubscription = _socket!.stream.listen(_handleSignal, onError: (e) {
        _safeSet(() => _status = 'Connection error. Try again.');
      }, onDone: () {
        if (!_disposed && _roomId.isNotEmpty) {
          _safeSet(() => _status = 'Disconnected from server');
        }
      });
      _socket!.sink.add(jsonEncode({'type': 'join_room', 'roomId': code}));
      _safeSet(() => _status = 'Joining room...');
    } catch (e) {
      _safeSet(() => _status = 'Could not connect to server. Check your internet.');
    } finally {
      _safeSet(() => _isLoading = false);
    }
  }

  void _send(Map<String, dynamic> data) {
    if (_socket != null) _socket!.sink.add(jsonEncode(data));
  }

  Future<void> _handleSignal(dynamic msg) async {
    if (_disposed) return;
    try {
      final data = jsonDecode(msg as String) as Map<String, dynamic>;
      switch (data['type']) {
        case 'room_joined':
          _safeSet(() {
            _roomId = data['roomId'];
            _status = 'Joined! Waiting for host to start...';
          });
          break;
        case 'offer':
          _safeSet(() => _status = 'Connecting stream...');
          await _handleOffer(data);
          break;
        case 'ice_candidate':
          await _handleIce(data);
          break;
        case 'host_left':
          _showSnack('Host ended the session');
          await Future.delayed(const Duration(seconds: 2));
          if (!_disposed) _leaveRoom();
          break;
        case 'error':
          _safeSet(() => _status = data['message'] ?? 'Unknown error');
          break;
      }
    } catch (e) {
      debugPrint('Signal handle failed: $e');
    }
  }

  Future<RTCPeerConnection?> _ensurePeer() async {
    if (_pc != null) return _pc;
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
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _safeSet(() {
          _connected = true;
          _status = 'Connected · Synced with host';
        });
        // Force audio to loudspeaker instead of earpiece (phone call mode)
        Helper.setSpeakerphoneOn(true);
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _safeSet(() => _status = 'Connection failed. Ask host to restart.');
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _safeSet(() => _status = 'Connection lost...');
      }
    };

    _pc!.onIceCandidate = (c) {
      if (c.candidate != null) {
        _send({'type': 'ice_candidate', 'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}});
      }
    };

    _pc!.onDataChannel = (channel) {
      _channel = channel;
      _channel!.onMessage = (RTCDataChannelMessage m) {
        try {
          final data = jsonDecode(m.text);
          final p = data['positionMs'] ?? 0;
          if (data['type'] == 'play') {
            _safeSet(() { _isPlaying = true; _positionMs = p; });
          } else if (data['type'] == 'pause') {
            _safeSet(() { _isPlaying = false; _positionMs = p; });
          } else if (data['type'] == 'seek') {
            _safeSet(() => _positionMs = p);
          } else if (data['type'] == 'duration') {
            _safeSet(() => _durationMs = data['durationMs'] ?? 0);
          } else if (data['type'] == 'chat') {
            _safeSet(() => _chatMessages.add({'sender': 'Host', 'text': data['message']}));
            _scrollChat();
          }
        } catch (e) { debugPrint('Control msg error: $e'); }
      };
    };

    _pc!.onAddStream = (stream) {
      _remoteStream = stream;
      _remoteRenderer.srcObject = stream;
    };

    _pc!.onTrack = (event) {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteRenderer.srcObject = _remoteStream;
      }
    };

    return _pc;
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    final pc = await _ensurePeer();
    if (pc == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(data['sdp'], 'offer'));
    _remoteDescriptionSet = true;
    for (final c in _pendingIce) { await pc.addCandidate(c); }
    _pendingIce.clear();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _send({'type': 'answer', 'sdp': answer.sdp});
  }

  Future<void> _handleIce(Map<String, dynamic> data) async {
    final c = data['candidate'];
    if (c != null) {
      final ice = RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']);
      if (!_remoteDescriptionSet || _pc == null) {
        _pendingIce.add(ice);
      } else {
        await _pc!.addCandidate(ice);
      }
    }
  }

  Future<void> _leaveRoom() async {
    await _channel?.close();
    await _pc?.close();
    _remoteRenderer.srcObject = null;
    await _remoteStream?.dispose();
    _channel = null;
    _pc = null;
    _remoteStream = null;
    _pendingIce.clear();
    _remoteDescriptionSet = false;
    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    _socket = null;
    _socketSubscription = null;
    _safeSet(() {
      _roomId = '';
      _status = 'Enter the room code from your host';
      _connected = false;
      _isPlaying = false;
      _positionMs = 0;
      _durationMs = 0;
      _chatMessages.clear();
    });
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

  @override
  Widget build(BuildContext context) {
    if (_isFullscreen) return _buildFullscreen();
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () {
            if (_roomId.isNotEmpty) _leaveRoom();
            Navigator.pop(context);
          },
        ),
        title: Text(
          _roomId.isEmpty ? 'JOIN A ROOM' : 'WATCHING · $_roomId',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2),
        ),
        centerTitle: true,
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
                Text('Joining room...', style: TextStyle(color: Colors.white54)),
              ],
            ))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 32),
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: const Color(0xFF2A2A4A), width: 1.5),
                    ),
                    child: const Icon(Icons.tv_rounded, size: 56, color: Color(0xFF6C63FF)),
                  ),
                  const SizedBox(height: 28),
                  const Text('Join a Room', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Ask your friend for the 6-character room code',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 14)),
                  const SizedBox(height: 40),
                  TextField(
                    controller: _roomController,
                    textAlign: TextAlign.center,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(
                      fontSize: 32,
                      letterSpacing: 10,
                      fontWeight: FontWeight.w900,
                    ),
                    decoration: InputDecoration(
                      hintText: '· · · · · ·',
                      hintStyle: TextStyle(
                        fontSize: 28,
                        letterSpacing: 8,
                        color: Colors.white.withOpacity(0.2),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF1A1A2E),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Color(0xFF6C63FF), width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 20),
                    ),
                    onSubmitted: (_) => _joinRoom(),
                  ),
                  const SizedBox(height: 16),
                  // Status text
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _status,
                      key: ValueKey(_status),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _status.contains('error') || _status.contains('Error')
                            ? Colors.redAccent
                            : Colors.white.withOpacity(0.4),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _joinRoom,
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('JOIN ROOM'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildRoom() {
    return Column(
      children: [
        _buildStatusBar(),
        // Video
        GestureDetector(
          onTap: _showControlsTemp,
          child: Container(
            color: Colors.black,
            height: MediaQuery.of(context).size.height * 0.3,
            child: Stack(
              children: [
                Center(
                  child: _connected
                      ? RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(color: Color(0xFF6C63FF)),
                            const SizedBox(height: 14),
                            Text('Waiting for video stream...',
                                style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13)),
                          ],
                        ),
                ),
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
                if (_connected && _showControls)
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
                          colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                        ),
                      ),
                      child: Column(
                        children: [
                          if (_durationMs > 0) _buildProgressBar(),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _isPlaying ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                  color: Colors.white70,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${_isPlaying ? "Playing" : "Paused"} · ${_formatTime(_positionMs)}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Bottom panel
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
                color: _connected ? const Color(0xFF4CAF50) : const Color(0xFFFFA000),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (_connected ? const Color(0xFF4CAF50) : const Color(0xFFFFA000))
                        .withOpacity(_pulseAnim.value),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _status,
              style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
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
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              activeTrackColor: const Color(0xFF6C63FF),
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(value: val, max: max, onChanged: (_) {}),
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
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A2A4A)),
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
                  child: const Icon(Icons.tv_rounded, color: Color(0xFF6C63FF)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Room', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
                      Text(_roomId,
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 6)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (!_connected)
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
                  Text('Waiting for host video...', style: TextStyle(color: Colors.white54)),
                ],
              ),
            ),
          if (_connected)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF4CAF50).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(_isPlaying ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      color: const Color(0xFF4CAF50), size: 22),
                  const SizedBox(width: 12),
                  Text(
                    '${_isPlaying ? "Playing" : "Paused"} · ${_formatTime(_positionMs)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const Spacer(),
                  const Text('Synced', style: TextStyle(color: Color(0xFF4CAF50), fontSize: 12)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                _leaveRoom();
              },
              icon: const Icon(Icons.exit_to_app_rounded, size: 20),
              label: const Text('LEAVE ROOM'),
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
                            Text(msg['sender']!,
                                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10)),
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
                    hintText: _connected ? 'Message host...' : 'Waiting for connection...',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    filled: true,
                    fillColor: const Color(0xFF0A0A0F),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                  enabled: _connected,
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
        onTap: _showControlsTemp,
        child: Stack(
          children: [
            _connected
                ? RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                : const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF))),
            if (_showControls) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 44, 16, 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(_isPlaying ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                color: Colors.white70, size: 16),
                            const SizedBox(width: 4),
                            Text(_formatTime(_positionMs),
                                style: const TextStyle(color: Colors.white70, fontSize: 13)),
                          ],
                        ),
                      ),
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
              if (_durationMs > 0)
                Positioned(
                  bottom: 40,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _buildProgressBar(),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
