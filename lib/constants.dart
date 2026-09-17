// Signaling server URL.
//
// PUBLIC / INTERNET (Render):         wss://watchparty-ohug.onrender.com
// LOCAL DEVELOPMENT (adb reverse):    ws://127.0.0.1:8091
// LOCAL DEVELOPMENT (Emulator):       ws://10.0.2.2:8091
//
// Override at build time:
//   flutter run --dart-define=SIGNALING_URL=ws://127.0.0.1:8091
//
// Default is the public Render URL.
const signalingUrl = String.fromEnvironment(
  'SIGNALING_URL',
  defaultValue: 'wss://watchparty-ohug.onrender.com',
);
