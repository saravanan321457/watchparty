import re

with open('lib/viewer_screen.dart', 'r') as f:
    code = f.read()

bad_code = """    _pc!.onTrack = (event) {
      if (event.track.kind == 'video') {
        _remoteStream ??= MediaStream('remote_stream', 'remote_stream');
        _remoteStream!.addTrack(event.track, _remoteStream!);
        _remoteRenderer.srcObject = _remoteStream;
      }
    };"""

good_code = """    _pc!.onTrack = (event) {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteRenderer.srcObject = _remoteStream;
      }
    };"""

code = code.replace(bad_code, good_code)

with open('lib/viewer_screen.dart', 'w') as f:
    f.write(code)
