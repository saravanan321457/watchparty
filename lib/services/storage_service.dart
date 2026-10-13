import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';

class StorageService {
  StorageService._internal();
  static final StorageService _instance = StorageService._internal();

  /// Returns the singleton instance of [StorageService].
  factory StorageService() => _instance;
  static StorageService get instance => _instance;

  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Uploads a user's profile photo to Firebase Storage and returns the download URL.
  Future<String> uploadProfilePhoto(String uid, File imageFile) async {
    final extension = imageFile.path.contains('.')
        ? imageFile.path.split('.').last.toLowerCase()
        : 'jpg';
    final mimeType = extension == 'png' ? 'image/png' : 'image/jpeg';
    final fileName = 'profile_$uid.$extension';
    final ref = _storage.ref().child('profile_photos').child(uid).child(fileName);

    final metadata = SettableMetadata(
      contentType: mimeType,
      customMetadata: {
        'userId': uid,
        'uploadedAt': DateTime.now().toIso8601String(),
      },
    );

    final uploadTask = ref.putFile(imageFile, metadata);
    final snapshot = await uploadTask;
    return await snapshot.ref.getDownloadURL();
  }

  /// Alias for uploadProfilePhoto
  Future<String> uploadProfileImage(String uid, File imageFile) =>
      uploadProfilePhoto(uid, imageFile);

  /// Deletes a user's profile photo from Firebase Storage if it exists.
  Future<void> deleteProfilePhoto(String uid) async {
    try {
      final listResult = await _storage.ref().child('profile_photos').child(uid).listAll();
      for (final item in listResult.items) {
        await item.delete();
      }
    } catch (_) {
      // Ignore errors if directory or file doesn't exist
    }
  }
}
