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

class _ViewerScreenState extends State<ViewerScreen> {
  final _roomController = TextEditingController();
  
  bool _disposed = false;
  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  String _roomId = '';
  String _status = 'Ready to connect';
  bool _connected = false;
  bool _isLoading = false;
  bool _isFullscreen = false;
  bool _remoteDescriptionSet = false;
  
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  MediaStream? _remoteStream;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final List<RTCIceCandidate> _pendingIce = [];
  
  bool _isPlaying = false;
  int _positionMs = 0;
  
  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();
  }

  @override
  void dispose() {
    _disposed = true;
    _leaveRoom();
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _safeSet(VoidCallback fn) {
    if (mounted && !_disposed) setState(fn);
  }

  Future<void> _joinRoom() async {
    final code = _roomController.text.trim().toUpperCase();
    if (code.isEmpty) return;
    _safeSet(() => _isLoading = true);
    try {
      _socket = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _socketSubscription = _socket!.stream.listen(_handleSignal, onError: (e) {
        _safeSet(() => _status = 'Signaling error: $e');
      }, onDone: () {
        if (!_disposed && _roomId.isNotEmpty) _leaveRoom();
      });
      _socket!.sink.add(jsonEncode({'type': 'join_room', 'roomId': code}));
      _safeSet(() => _status = 'Connecting...');
    } catch (e) {
      _safeSet(() => _status = 'Could not connect: $e');
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
            _status = 'Joined. Waiting for host video...';
          });
          break;
        case 'offer':
          _safeSet(() => _status = 'Connecting video...');
          await _handleOffer(data);
          break;
        case 'ice_candidate':
          await _handleIce(data);
          break;
        case 'host_left':
          _safeSet(() => _status = 'Host closed the room.');
          await Future.delayed(const Duration(seconds: 3));
          if (!_disposed) _leaveRoom();
          break;
        case 'error':
          _safeSet(() => _status = 'Error: ${data['message']}');
          break;
      }
    } catch (e) {
      debugPrint('Signal handle failed: $e');
    }
  }

  Future<RTCPeerConnection?> _ensurePeer() async {
    if (_pc != null) return _pc;
    _pc = await createPeerConnection({'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}]});
    
    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _safeSet(() {
          _connected = true;
          _status = 'Connected';
        });
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed || s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _safeSet(() => _status = 'Connection lost');
      }
    };
    
    _pc!.onIceCandidate = (c) {
      if (c.candidate != null) _send({'type': 'ice_candidate', 'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}});
    };
    
    _pc!.onDataChannel = (channel) {
      _channel = channel;
      _channel!.onMessage = (RTCDataChannelMessage msg) {
        try {
          final m = jsonDecode(msg.text);
          final p = m['positionMs'] ?? 0;
          if (m['type'] == 'play') {
            _safeSet(() { _isPlaying = true; _positionMs = p; });
          } else if (m['type'] == 'pause') {
            _safeSet(() { _isPlaying = false; _positionMs = p; });
          } else if (m['type'] == 'seek') {
            _safeSet(() { _positionMs = p; });
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
    for (final c in _pendingIce) {
      await pc.addCandidate(c);
    }
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
      _status = 'Ready to connect';
      _connected = false;
      _isPlaying = false;
      _positionMs = 0;
    });
  }

  String _formatTime(int ms) {
    final d = Duration(milliseconds: ms);
    final min = d.inMinutes.toString().padLeft(2, '0');
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  @override
  Widget build(BuildContext context) {
    if (_isFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _connected ? RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain) : const Center(child: CircularProgressIndicator()),
              ),
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: const Icon(Icons.fullscreen_exit, color: Colors.white, size: 32),
                onPressed: () {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                  _safeSet(() => _isFullscreen = false);
                },
              ),
            ),
            if (_connected)
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_isPlaying ? Icons.play_arrow : Icons.pause, color: Colors.white, size: 32),
                    const SizedBox(width: 12),
                    Text('Host time: \${_formatTime(_positionMs)}', style: const TextStyle(fontSize: 18, color: Colors.white)),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('VIEW ROOM', style: TextStyle(letterSpacing: 2, fontSize: 16, fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: _roomId.isEmpty ? _buildSetup() : _buildRoom(),
    );
  }

  Widget _buildSetup() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: _isLoading
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 24),
                    Text('Loading media...', style: TextStyle(fontWeight: FontWeight.w500)),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextField(
                controller: _roomController,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 4, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  hintText: 'ROOM CODE',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _joinRoom,
                icon: const Icon(Icons.login),
                label: const Text('JOIN ROOM'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                ),
              ),
              const SizedBox(height: 24),
              Text(_status, style: const TextStyle(color: Colors.orange)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoom() {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Room Code', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                        Text(_roomId, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 4)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(
                  _connected ? Icons.check_circle : Icons.hourglass_empty,
                  color: _connected ? Colors.green : Colors.orange,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(_status, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              color: Colors.black,
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    children: [
                      _connected ? RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain) : const Center(child: CircularProgressIndicator()),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: IconButton(
                          icon: const Icon(Icons.fullscreen, color: Colors.white, size: 28),
                          onPressed: () {
                            SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                            _safeSet(() => _isFullscreen = true);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_connected)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_isPlaying ? Icons.play_arrow : Icons.pause, color: Colors.blue, size: 28),
                  const SizedBox(width: 12),
                  Text('Host time: ${_formatTime(_positionMs)}', style: const TextStyle(fontSize: 16)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _leaveRoom,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text('LEAVE ROOM'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
