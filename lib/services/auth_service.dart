import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();

  static final AuthService instance = AuthService._internal();
  AuthService._internal();
  factory AuthService() => instance;

  static FirebaseAuth get auth => _auth;
  static User? get currentUser => _auth.currentUser;
  static Stream<User?> get authStateChanges => _auth.authStateChanges();
  static bool get isGuest => _auth.currentUser?.isAnonymous ?? true;

  // Instance getters for callers using instance
  User? get user => _auth.currentUser;
  Stream<User?> get authStateStream => _auth.authStateChanges();

  static Future<UserCredential?> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null;

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      return await _auth.signInWithCredential(credential);
    } catch (e) {
      rethrow;
    }
  }

  static Future<UserCredential> signInAnonymously() async {
    return await _auth.signInAnonymously();
  }

  static Future<UserCredential> signInAsGuest() async {
    return await signInAnonymously();
  }

  static Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _auth.signOut();
  }

  // Instance method delegates for compatibility
  Future<UserCredential?> signInGoogle() => signInWithGoogle();
  Future<UserCredential> signInGuest() => signInAsGuest();
}
