import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import 'auth_screen.dart';
import 'profile_setup_screen.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final AuthService _authService = AuthService();
  final FirestoreService _firestoreService = FirestoreService();

  @override
  void initState() {
    super.initState();
    _checkAuthAndNavigate();
  }

  Future<void> _checkAuthAndNavigate() async {
    // Provide a brief delay so splash branding and animations render smoothly
    await Future.delayed(const Duration(milliseconds: 1600));
    if (!mounted) return;

    try {
      final currentUser = AuthService.currentUser ?? FirebaseAuth.instance.currentUser;

      if (currentUser != null) {
        final hasProfile = await _firestoreService.hasProfile(currentUser.uid);
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
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AuthScreen()),
        );
      }
    } catch (e) {
      debugPrint('SplashScreen auth check error: $e');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Centered glowing purple circle with play icon
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
                Icons.play_arrow_rounded,
                size: 54,
                color: Colors.white,
              ),
            )
                .animate()
                .scale(
                  duration: 800.ms,
                  curve: Curves.easeOutBack,
                )
                .shimmer(
                  delay: 800.ms,
                  duration: 1200.ms,
                  color: Colors.white.withOpacity(0.4),
                ),

            const SizedBox(height: 32),

            // Animated fade-in 'Watch Together' text
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFF6C63FF), Color(0xFFAA63FF)],
              ).createShader(bounds),
              child: const Text(
                'Watch Together',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.5,
                  color: Colors.white,
                ),
              ),
            )
                .animate()
                .fadeIn(duration: 700.ms, delay: 300.ms)
                .slideY(begin: 0.25, end: 0, duration: 700.ms, curve: Curves.easeOut),

            const SizedBox(height: 14),

            // Pulsing subtitle 'Loading...'
            Text(
              'Loading...',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 13,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w500,
              ),
            )
                .animate(onPlay: (controller) => controller.repeat(reverse: true))
                .fadeIn(duration: 600.ms)
                .then()
                .fadeOut(duration: 600.ms),
          ],
        ),
      ),
    );
  }
}
