// Signaling server URL.
//
// For physical phone (adb reverse):   ws://127.0.0.1:8091
// For Android Emulator:               ws://10.0.2.2:8091
//
// Override at build time:
//   flutter run --dart-define=SIGNALING_URL=ws://10.0.2.2:8091
//
// Default is the adb-reverse URL used by the physical phone (HOST).
const signalingUrl = String.fromEnvironment(
  'SIGNALING_URL',
  defaultValue: 'ws://127.0.0.1:8091',
);
