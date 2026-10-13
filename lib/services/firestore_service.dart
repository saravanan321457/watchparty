import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/room_model.dart';
import '../models/user_model.dart';

class FirestoreService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static final FirestoreService instance = FirestoreService._internal();
  FirestoreService._internal();
  factory FirestoreService() => instance;

  CollectionReference<Map<String, dynamic>> get _roomsRef =>
      _firestore.collection('rooms');

  CollectionReference<Map<String, dynamic>> get _usersRef =>
      _firestore.collection('users');

  /// Stream of active public rooms for Discover tab
  Stream<List<RoomModel>> getPublicRoomsStream() {
    return _roomsRef
        .where('isPublic', isEqualTo: true)
        .where('isActive', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => RoomModel.fromFirestore(doc)).toList();
    });
  }

  /// Stream of rooms hosted by a specific user for My Rooms tab
  Stream<List<RoomModel>> getMyRoomsStream(String uid) {
    if (uid.isEmpty) {
      return Stream.value(<RoomModel>[]);
    }
    return _roomsRef
        .where('hostId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => RoomModel.fromFirestore(doc)).toList();
    });
  }

  /// Stream of user profile
  Stream<UserModel?> getUserStream(String uid) {
    if (uid.isEmpty) return Stream.value(null);
    return _usersRef.doc(uid).snapshots().map((doc) {
      if (!doc.exists) return null;
      return UserModel.fromFirestore(doc);
    });
  }

  /// Get single user profile
  Future<UserModel?> getUser(String uid) async {
    if (uid.isEmpty) return null;
    final doc = await _usersRef.doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromFirestore(doc);
  }

  /// Save or update user profile
  Future<void> createOrUpdateUser(UserModel user) async {
    await _usersRef.doc(user.uid).set(user.toMap(), SetOptions(merge: true));
  }

  /// Check if user has an existing profile
  Future<bool> hasProfile(String uid) async {
    if (uid.isEmpty) return false;
    try {
      final doc = await _usersRef.doc(uid).get();
      return doc.exists && doc.data() != null;
    } catch (_) {
      return false;
    }
  }

  /// Check if username is taken (case-insensitive)
  Future<bool> isUsernameTaken(String username) async {
    final trimmed = username.trim().toLowerCase();
    if (trimmed.isEmpty) return false;
    try {
      final query = await _usersRef
          .where('username', isEqualTo: trimmed)
          .limit(1)
          .get();
      return query.docs.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Create user profile from UserModel
  Future<void> createUserProfile(UserModel user) async {
    await createOrUpdateUser(user);
  }

  /// Create a new room in Firestore
  Future<void> createRoom(RoomModel room) async {
    final docId = room.roomCode.isNotEmpty ? room.roomCode : (room.id.isNotEmpty ? room.id : _roomsRef.doc().id);
    final modelToSave = room.copyWith(
      id: docId,
      roomCode: room.roomCode.isNotEmpty ? room.roomCode : docId,
    );
    await _roomsRef.doc(docId).set(modelToSave.toMap(), SetOptions(merge: true));

    // Increment roomsHosted count on user document
    if (room.hostId.isNotEmpty) {
      await _usersRef.doc(room.hostId).set({
        'roomsHosted': FieldValue.increment(1),
      }, SetOptions(merge: true));
    }
  }

  /// Delete a room
  Future<void> deleteRoom(String roomCode) async {
    if (roomCode.isEmpty) return;
    try {
      await _roomsRef.doc(roomCode).delete();
    } catch (_) {}
  }

  /// Close or deactivate a room
  Future<void> closeRoom(String roomId) async {
    if (roomId.isEmpty) return;
    try {
      await _roomsRef.doc(roomId).update({
        'isActive': false,
      });
    } catch (_) {}
  }

  /// Increment viewer count atomically
  Future<void> incrementViewerCount(String roomCode) async {
    if (roomCode.isEmpty) return;
    try {
      await _roomsRef.doc(roomCode).update({
        'viewerCount': FieldValue.increment(1),
      });
    } catch (_) {}
  }

  /// Decrement viewer count atomically
  Future<void> decrementViewerCount(String roomCode) async {
    if (roomCode.isEmpty) return;
    try {
      final doc = await _roomsRef.doc(roomCode).get();
      if (doc.exists) {
        final current = (doc.data()?['viewerCount'] as num? ?? 1).toInt();
        await _roomsRef.doc(roomCode).update({
          'viewerCount': current > 0 ? current - 1 : 0,
        });
      }
    } catch (_) {}
  }

  /// Update viewer count directly
  Future<void> updateRoomViewerCount(String roomId, int count) async {
    if (roomId.isEmpty) return;
    try {
      await _roomsRef.doc(roomId).update({
        'viewerCount': count,
      });
    } catch (_) {}
  }
}
