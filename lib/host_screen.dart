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

class _HostScreenState extends State<HostScreen> {
  static const _channelNative = MethodChannel('mp4_webrtc');

  bool _disposed = false;
  String? _videoPath;
  String _videoName = '';
  
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
  int _positionMs = 0;
  int _durationMs = 0;
  
  final List<String> _chatMessages = [];
  final TextEditingController _chatController = TextEditingController();
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
  }

  @override
  void dispose() {
    _disposed = true;
    _progressTimer?.cancel();
    _leaveRoom();
    _localRenderer.dispose();
    super.dispose();
  }

  void _sendChatMessage() {
    final msg = _chatController.text.trim();
    if (msg.isNotEmpty && _viewerConnected) {
      _channel?.send(RTCDataChannelMessage(jsonEncode({'type': 'chat', 'message': msg})));
      _safeSet(() {
        _chatMessages.add('You: $msg');
      });
      _chatController.clear();
    }
  }

  void _safeSet(VoidCallback fn) {
    if (mounted && !_disposed) setState(fn);
  }

  Future<void> _selectVideo() async {
    _safeSet(() => _isLoading = true);
    try {
      final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: false,         // never load into memory — use path/uri instead
      withReadStream: false,
    );
    if (result == null) return;
    final file = result.files.single;

    // On Android 10+ the file picker may return a content:// URI.
    // file.path can be null for files on external/cloud storage.
    // We prefer the real path when available; otherwise we use the identifier
    // (which is the content:// URI string on Android).
    final String? videoPath = file.path ?? file.identifier;

    if (videoPath != null && videoPath.isNotEmpty) {
      _safeSet(() {
        _videoPath = videoPath;
        _videoName = file.name;
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not access this video file. Please try another.')),
        );
      }
    }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error selecting file: \$e')));
      }
    } finally {
      _safeSet(() => _isLoading = false);
    }
  }

  Future<void> _createRoom() async {
    if (_videoPath == null) return;
    try {
      _socket = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _socketSubscription = _socket!.stream.listen(_handleSignal, onError: (e) {
        _safeSet(() => _status = 'Signaling error: $e');
      }, onDone: () {
        if (!_disposed && _roomId.isNotEmpty) _leaveRoom();
      });
      _socket!.sink.add(jsonEncode({'type': 'create_room', 'roomId': _generateCode()}));
      _safeSet(() => _status = 'Connecting...');
    } catch (e) {
      _safeSet(() => _status = 'Could not connect: $e');
    }
  }

  String _generateCode() {
    final chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = DateTime.now().microsecondsSinceEpoch;
    return List.generate(6, (i) => chars[(rnd + i) % chars.length]).join();
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

  Future<void> _createOffer() async {
    try {
      _pc = await createPeerConnection({'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}]});
      _pc!.onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _safeSet(() => _status = 'Connection failed');
        }
      };
      _pc!.onIceCandidate = (c) {
        if (c.candidate != null) _send({'type': 'ice_candidate', 'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}});
      };
      _channel = await _pc!.createDataChannel('watch_control', RTCDataChannelInit());
      _channel!.onDataChannelState = (s) {
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          _safeSet(() {
            _viewerConnected = true;
            _status = 'Viewer Connected';
          });
          _startProgressTimer();
        }
      };

      if (_videoStream == null) {
        _videoStream = await navigator.mediaDevices.getUserMedia({
          'video': {
            'optional': [{'sourceId': 'MP4_VIDEO:$_videoPath'}]
          },
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
      _safeSet(() => _status = 'Offer failed: $e');
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
        if (positionMs != null) 'positionMs': positionMs
      })));
    }
  }

  Future<void> _togglePlay() async {
    if (!_viewerConnected) return;
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
    try {
      final clamped = ms.clamp(0, _durationMs);
      await _channelNative.invokeMethod('seek', {'position': clamped});
      _sendControl('seek', clamped);
      _safeSet(() => _positionMs = clamped);
    } catch (_) {}
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
                child: _videoStream != null ? RTCVideoView(_localRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain) : const Center(child: CircularProgressIndicator()),
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
            if (_viewerConnected)
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 48,
                      icon: const Icon(Icons.replay_10, color: Colors.white),
                      onPressed: () => _seekTo(_positionMs - 10000),
                    ),
                    const SizedBox(width: 32),
                    FloatingActionButton(
                      onPressed: _togglePlay,
                      child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 48),
                    ),
                    const SizedBox(width: 32),
                    IconButton(
                      iconSize: 48,
                      icon: const Icon(Icons.forward_10, color: Colors.white),
                      onPressed: () => _seekTo(_positionMs + 10000),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('HOST ROOM', style: TextStyle(letterSpacing: 2, fontSize: 16, fontWeight: FontWeight.bold)),
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
                    FilledButton.icon(
                onPressed: _selectVideo,
                icon: const Icon(Icons.video_file),
                label: const Text('SELECT VIDEO'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
              ),
              if (_videoName.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Selected video:', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                Text(_videoName, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _createRoom,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                  ),
                  child: const Text('CREATE ROOM'),
                ),
              ],
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
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _roomId));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied!')));
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('COPY'),
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
                  _viewerConnected ? Icons.check_circle : Icons.hourglass_empty,
                  color: _viewerConnected ? Colors.green : Colors.orange,
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
                      _videoStream != null ? RTCVideoView(_localRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain) : const Center(child: CircularProgressIndicator()),
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
          if (_viewerConnected)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 32,
                        icon: const Icon(Icons.replay_10),
                        onPressed: () => _seekTo(_positionMs - 10000),
                      ),
                      const SizedBox(width: 24),
                      FloatingActionButton(
                        onPressed: _togglePlay,
                        child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 36),
                      ),
                      const SizedBox(width: 24),
                      IconButton(
                        iconSize: 32,
                        icon: const Icon(Icons.forward_10),
                        onPressed: () => _seekTo(_positionMs + 10000),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Slider(
                    value: _positionMs.toDouble(),
                    max: _durationMs > 0 ? _durationMs.toDouble() : 1.0,
                    onChanged: (val) {
                      _safeSet(() => _positionMs = val.toInt());
                    },
                    onChangeEnd: (val) => _seekTo(val.toInt()),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatTime(_positionMs)),
                      Text(_formatTime(_durationMs)),
                    ],
                  ),
                ],
              ),
            ),

          if (_viewerConnected)
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: _chatMessages.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Text(_chatMessages[index]),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            decoration: const InputDecoration(
                              hintText: 'Type a message...',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _sendChatMessage(),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: _sendChatMessage,
                        ),
                      ],
                    ),
                  ),
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
