import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/user_model.dart';
import '../services/firestore_service.dart';
import '../services/storage_service.dart';
import 'home_screen.dart';

class ProfileSetupScreen extends StatefulWidget {
  final bool isEditMode;
  const ProfileSetupScreen({super.key, this.isEditMode = false});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final StorageService _storageService = StorageService();
  final ImagePicker _picker = ImagePicker();

  final _step1FormKey = GlobalKey<FormState>();
  final _step2FormKey = GlobalKey<FormState>();

  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();

  int _currentStep = 1;
  File? _imageFile;

  bool _isCheckingUsername = false;
  bool? _isUsernameAvailable;
  String? _usernameErrorText;
  Timer? _debounceTimer;

  bool _isSubmitting = false;
  String _submissionStatus = '';

  @override
  void initState() {
    super.initState();
    // Prefill display name from auth provider if available (e.g. Google Sign In)
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser?.displayName != null && currentUser!.displayName!.isNotEmpty) {
      _displayNameController.text = currentUser.displayName!;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _displayNameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (picked != null) {
        setState(() {
          _imageFile = File(picked.path);
        });
      }
    } catch (e) {
      _showSnackBar('Failed to select image: $e', isError: true);
    }
  }

  void _onUsernameChanged(String value) {
    _debounceTimer?.cancel();
    final trimmed = value.trim().toLowerCase();

    if (trimmed.isEmpty) {
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = null;
        _usernameErrorText = null;
      });
      return;
    }

    final validPattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');
    if (!validPattern.hasMatch(trimmed)) {
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = false;
        _usernameErrorText = '3-20 characters: letters, numbers, and _ only';
      });
      return;
    }

    setState(() {
      _isCheckingUsername = true;
      _isUsernameAvailable = null;
      _usernameErrorText = null;
    });

    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final isTaken = await _firestoreService.isUsernameTaken(trimmed);
        if (!mounted) return;
        setState(() {
          _isCheckingUsername = false;
          _isUsernameAvailable = !isTaken;
          _usernameErrorText = isTaken ? 'This username is already taken' : null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isCheckingUsername = false;
          _isUsernameAvailable = null;
        });
      }
    });
  }

  void _goToStep2() {
    if (_step1FormKey.currentState?.validate() ?? false) {
      setState(() {
        _currentStep = 2;
      });
    }
  }

  Future<void> _submitProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnackBar('No active user session. Please sign in again.', isError: true);
      return;
    }

    if (!(_step2FormKey.currentState?.validate() ?? false)) {
      return;
    }

    final username = _usernameController.text.trim().toLowerCase();

    // Verify username availability one last time if not confirmed
    if (_isUsernameAvailable != true) {
      setState(() {
        _isCheckingUsername = true;
      });
      final isTaken = await _firestoreService.isUsernameTaken(username);
      if (!mounted) return;
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = !isTaken;
      });
      if (isTaken) {
        setState(() {
          _usernameErrorText = 'This username is already taken';
        });
        return;
      }
    }

    setState(() {
      _isSubmitting = true;
      _submissionStatus = 'Saving profile...';
    });

    try {
      String? photoUrl;
      if (_imageFile != null) {
        setState(() {
          _submissionStatus = 'Uploading profile photo...';
        });
        try {
          photoUrl = await _storageService.uploadProfileImage(user.uid, _imageFile!);
        } catch (e) {
          debugPrint('Storage upload note: $e');
          // Proceed even if photo upload fails
        }
      }

      setState(() {
        _submissionStatus = 'Finalizing setup...';
      });

      final displayName = _displayNameController.text.trim();
      final bio = _bioController.text.trim();

      final userModel = UserModel(
        uid: user.uid,
        displayName: displayName,
        username: username,
        email: user.email,
        photoUrl: photoUrl ?? user.photoURL,
        bio: bio.isNotEmpty ? bio : null,
        isGuest: user.isAnonymous,
        roomsHosted: 0,
        createdAt: DateTime.now(),
      );

      await _firestoreService.createUserProfile(userModel);

      try {
        await user.updateDisplayName(displayName);
        if (photoUrl != null) {
          await user.updatePhotoURL(photoUrl);
        }
      } catch (_) {}

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submissionStatus = '';
      });
      _showSnackBar('Failed to create profile: $e', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        backgroundColor: isError ? const Color(0xFFD32F2F) : const Color(0xFF6C63FF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        elevation: 0,
        leading: _currentStep == 2
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                onPressed: () => setState(() => _currentStep = 1),
              )
            : null,
        title: const Text(
          'Profile Setup',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Progress indicator at top showing step 1/2 or 2/2
                  _buildProgressIndicator(),

                  const SizedBox(height: 32),

                  // Step Content
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _currentStep == 1
                        ? _buildStep1()
                        : _buildStep2(),
                  ),
                ],
              ),
            ),
          ),

          // Submitting loading overlay
          if (_isSubmitting)
            Container(
              color: Colors.black.withOpacity(0.7),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: const Color(0xFF6C63FF).withOpacity(0.3),
                      width: 1.2,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _submissionStatus,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _currentStep == 1 ? 'Step 1: Photo & Name' : 'Step 2: Username & Bio',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '$_currentStep / 2',
              style: const TextStyle(
                color: Color(0xFF6C63FF),
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: _currentStep == 1 ? 0.5 : 1.0,
            backgroundColor: const Color(0xFF1A1A2E),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
            minHeight: 6,
          ),
        ),
      ],
    );
  }

  Widget _buildStep1() {
    return Form(
      key: _step1FormKey,
      child: Column(
        key: const ValueKey('step1'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 12),

          // Circular avatar with camera icon overlay, taps to pick from gallery
          Center(
            child: GestureDetector(
              onTap: _pickImage,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF1A1A2E),
                      border: Border.all(
                        color: const Color(0xFF6C63FF).withOpacity(0.6),
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6C63FF).withOpacity(0.25),
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: _imageFile != null
                          ? Image.file(
                              _imageFile!,
                              width: 110,
                              height: 110,
                              fit: BoxFit.cover,
                            )
                          : const Icon(
                              Icons.person_rounded,
                              size: 64,
                              color: Color(0xFF8E8EA8),
                            ),
                    ),
                  ),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C63FF),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF0A0A0F),
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.4),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.camera_alt_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          )
              .animate()
              .scale(duration: 400.ms, curve: Curves.easeOutBack),

          const SizedBox(height: 14),

          // Skip / Change photo option
          if (_imageFile != null)
            TextButton(
              onPressed: () => setState(() => _imageFile = null),
              child: const Text(
                'Remove photo',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 13,
                ),
              ),
            )
          else
            TextButton(
              onPressed: _goToStep2,
              child: const Text(
                'Skip profile photo',
                style: TextStyle(
                  color: Color(0xFF8E8EA8),
                  fontSize: 13,
                ),
              ),
            ),

          const SizedBox(height: 24),

          // TextFormField for display name
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Display Name',
              style: TextStyle(
                color: Colors.white.withOpacity(0.85),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _displayNameController,
            style: const TextStyle(color: Colors.white),
            cursorColor: const Color(0xFF6C63FF),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              hintText: 'e.g. Alex Morgan',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
              prefixIcon: const Icon(
                Icons.badge_outlined,
                color: Color(0xFF6C63FF),
                size: 20,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF6C63FF), width: 1.8),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFD32F2F)),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFD32F2F), width: 1.8),
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter your display name';
              }
              if (value.trim().length < 2) {
                return 'Display name must be at least 2 characters';
              }
              return null;
            },
          ),

          const SizedBox(height: 38),

          // 'Next' button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _goToStep2,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Next',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_forward_rounded, size: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return Form(
      key: _step2FormKey,
      child: Column(
        key: const ValueKey('step2'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),

          // Username Field Title
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Username',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_isCheckingUsername)
                const Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                      ),
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Checking...',
                      style: TextStyle(color: Color(0xFF6C63FF), fontSize: 12),
                    ),
                  ],
                )
              else if (_isUsernameAvailable == true)
                const Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 14),
                    SizedBox(width: 4),
                    Text(
                      'Available',
                      style: TextStyle(color: Colors.greenAccent, fontSize: 12),
                    ),
                  ],
                )
              else if (_isUsernameAvailable == false && _usernameErrorText != null)
                Row(
                  children: [
                    const Icon(Icons.cancel_rounded, color: Colors.redAccent, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      _usernameErrorText!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ],
                ),
            ],
          ),

          const SizedBox(height: 8),

          // @username field, validates uniqueness via FirestoreService.isUsernameTaken() (debounced)
          TextFormField(
            controller: _usernameController,
            onChanged: _onUsernameChanged,
            style: const TextStyle(color: Colors.white),
            cursorColor: const Color(0xFF6C63FF),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              hintText: 'alex_m',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
              prefixIcon: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    '@',
                    style: TextStyle(
                      color: Color(0xFF6C63FF),
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: _isUsernameAvailable == true
                      ? Colors.greenAccent.withOpacity(0.7)
                      : (_usernameErrorText != null
                          ? Colors.redAccent
                          : const Color(0xFF2A2A4A)),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF6C63FF), width: 1.8),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFD32F2F)),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFD32F2F), width: 1.8),
              ),
            ),
            validator: (value) {
              final trimmed = value?.trim().toLowerCase() ?? '';
              if (trimmed.isEmpty) {
                return 'Please enter a username';
              }
              final validPattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');
              if (!validPattern.hasMatch(trimmed)) {
                return '3-20 characters: letters, numbers, and _ only';
              }
              if (_isUsernameAvailable == false) {
                return _usernameErrorText ?? 'Username is already taken';
              }
              return null;
            },
          ),

          const SizedBox(height: 24),

          // Bio field (optional, max 150 chars)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Bio',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Optional · max 150 chars',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          TextFormField(
            controller: _bioController,
            maxLength: 150,
            maxLines: 3,
            style: const TextStyle(color: Colors.white),
            cursorColor: const Color(0xFF6C63FF),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              hintText: 'What kind of movies or shows do you love?',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
              counterStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A4A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF6C63FF), width: 1.8),
              ),
            ),
          ),

          const SizedBox(height: 28),

          // 'Create Profile' button → saves to Firestore → navigates to HomeScreen
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _isSubmitting ? null : _submitProfile,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                'Create Profile',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
