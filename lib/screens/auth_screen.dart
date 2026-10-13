import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import 'profile_setup_screen.dart';
import 'home_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final FirestoreService _firestoreService = FirestoreService();

  bool _isLoading = false;
  String _loadingMessage = '';

  Future<void> _handleGoogleSignIn() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _loadingMessage = 'Connecting to Google...';
    });

    try {
      final credential = await AuthService.signInWithGoogle();

      if (credential == null || credential.user == null) {
        // User cancelled the Google sign-in dialog
        if (mounted) {
          setState(() {
            _isLoading = false;
            _loadingMessage = '';
          });
        }
        return;
      }

      await _routeUser(credential.user!.uid);
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? 'Authentication failed: ${e.code}');
    } catch (e) {
      _showError('Google sign in failed: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingMessage = '';
        });
      }
    }
  }

  Future<void> _handleGuestSignIn() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _loadingMessage = 'Starting guest session...';
    });

    try {
      final credential = await AuthService.signInAsGuest();

      if (credential.user == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _loadingMessage = '';
          });
        }
        return;
      }

      await _routeUser(credential.user!.uid);
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? 'Guest sign-in error: ${e.code}');
    } catch (e) {
      _showError('Guest sign-in failed: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingMessage = '';
        });
      }
    }
  }

  Future<void> _routeUser(String uid) async {
    setState(() {
      _loadingMessage = 'Checking account profile...';
    });

    try {
      final hasProfile = await _firestoreService.hasProfile(uid);

      if (!mounted) return;

      if (hasProfile) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ProfileSetupScreen()),
        );
      }
    } catch (e) {
      _showError('Error verifying profile: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        backgroundColor: const Color(0xFFD32F2F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF14132B),
              Color(0xFF0A0A0F),
              Color(0xFF08080D),
            ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(flex: 3),

                    // Top: large glowing purple logo circle with play_circle icon
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF6C63FF), Color(0xFFAA63FF)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF6C63FF).withOpacity(0.55),
                            blurRadius: 36,
                            spreadRadius: 6,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.play_circle_filled_rounded,
                        size: 58,
                        color: Colors.white,
                      ),
                    )
                        .animate()
                        .scale(duration: 700.ms, curve: Curves.easeOutBack)
                        .shimmer(delay: 700.ms, duration: 1200.ms),

                    const SizedBox(height: 28),

                    // Title: 'Watch Together' with gradient text (purple to blue)
                    ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [Color(0xFF6C63FF), Color(0xFF00D2FF)],
                      ).createShader(bounds),
                      child: const Text(
                        'Watch Together',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                          color: Colors.white,
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 600.ms, delay: 200.ms)
                        .slideY(begin: 0.2, end: 0, duration: 600.ms),

                    const SizedBox(height: 10),

                    // Subtitle: 'Watch with anyone. Anywhere. Together.'
                    Text(
                      'Watch with anyone. Anywhere. Together.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withOpacity(0.65),
                        letterSpacing: 0.4,
                        height: 1.4,
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 600.ms, delay: 350.ms),

                    const Spacer(flex: 3),

                    // Button a: 'Continue with Google' — white button, Google logo colors 'G', calls AuthService.signInWithGoogle()
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleGoogleSignIn,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF1A1A2E),
                          disabledBackgroundColor: Colors.white.withOpacity(0.7),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const _GoogleLogo(size: 22),
                            const SizedBox(width: 14),
                            const Text(
                              'Continue with Google',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.3,
                                color: Color(0xFF1E1E2E),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 600.ms, delay: 500.ms)
                        .slideY(begin: 0.2, end: 0, duration: 600.ms),

                    const SizedBox(height: 14),

                    // Button b: 'Continue as Guest' — outlined purple button, person icon, calls AuthService.signInAsGuest()
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: OutlinedButton(
                        onPressed: _isLoading ? null : _handleGuestSignIn,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: const Color(0xFF1A1A2E).withOpacity(0.5),
                          side: const BorderSide(
                            color: Color(0xFF6C63FF),
                            width: 1.6,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.person_outline_rounded,
                              size: 22,
                              color: Color(0xFF6C63FF),
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Continue as Guest',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.3,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 600.ms, delay: 650.ms)
                        .slideY(begin: 0.2, end: 0, duration: 600.ms),

                    const SizedBox(height: 18),

                    // Small text c: 'Guest sessions are temporary. Sign in to save history.'
                    Text(
                      'Guest sessions are temporary. Sign in to save history.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.4),
                        letterSpacing: 0.2,
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 600.ms, delay: 800.ms),

                    const Spacer(flex: 2),
                  ],
                ),
              ),

              // Loading spinner while signing in
              if (_isLoading)
                Container(
                  color: Colors.black.withOpacity(0.65),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 22,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: const Color(0xFF6C63FF).withOpacity(0.3),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 38,
                            height: 38,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Color(0xFF6C63FF),
                              ),
                            ),
                          ),
                          if (_loadingMessage.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              _loadingMessage,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Custom painter for official 4-colored Google 'G' icon
class _GoogleLogo extends StatelessWidget {
  final double size;

  const _GoogleLogo({this.size = 22});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GoogleLogoPainter(),
      ),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final center = Offset(w / 2, h / 2);
    final radius = w / 2;
    final strokeWidth = w * 0.22;

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    final rect = Rect.fromCircle(
      center: center,
      radius: radius - strokeWidth / 2,
    );

    // Blue arc (bottom right to right side)
    arcPaint.color = const Color(0xFF4285F4);
    canvas.drawArc(rect, -0.785, 1.57, false, arcPaint);

    // Green arc (bottom)
    arcPaint.color = const Color(0xFF34A853);
    canvas.drawArc(rect, 0.785, 1.57, false, arcPaint);

    // Yellow arc (left)
    arcPaint.color = const Color(0xFFFBBC05);
    canvas.drawArc(rect, 2.356, 1.57, false, arcPaint);

    // Red arc (top)
    arcPaint.color = const Color(0xFFEA4335);
    canvas.drawArc(rect, 3.927, 1.57, false, arcPaint);

    // Horizontal blue bar into center
    final barPaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;

    final barRect = Rect.fromLTWH(
      center.dx - (strokeWidth * 0.1),
      center.dy - (strokeWidth / 2),
      radius - (strokeWidth * 0.2),
      strokeWidth,
    );
    canvas.drawRect(barRect, barPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
