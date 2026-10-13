import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String displayName;
  final String username;
  final String? email;
  final String? photoUrl;
  final String? bio;
  final bool isGuest;
  final int roomsHosted;
  final DateTime createdAt;

  const UserModel({
    required this.uid,
    required this.displayName,
    required this.username,
    this.email,
    this.photoUrl,
    this.bio,
    this.isGuest = false,
    this.roomsHosted = 0,
    required this.createdAt,
  });

  factory UserModel.fromMap(Map<String, dynamic> map, [String? docUid]) {
    DateTime parsedDate;
    final createdVal = map['createdAt'];
    if (createdVal is Timestamp) {
      parsedDate = createdVal.toDate();
    } else if (createdVal is String) {
      parsedDate = DateTime.tryParse(createdVal) ?? DateTime.now();
    } else if (createdVal is int) {
      parsedDate = DateTime.fromMillisecondsSinceEpoch(createdVal);
    } else {
      parsedDate = DateTime.now();
    }

    return UserModel(
      uid: docUid ?? map['uid'] ?? '',
      displayName: map['displayName'] ?? 'User',
      username: map['username'] ?? 'user',
      email: map['email'] as String?,
      photoUrl: map['photoUrl'] as String?,
      bio: map['bio'] as String?,
      isGuest: map['isGuest'] as bool? ?? false,
      roomsHosted: (map['roomsHosted'] as num? ?? 0).toInt(),
      createdAt: parsedDate,
    );
  }

  factory UserModel.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? {};
    return UserModel.fromMap(data, doc.id);
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'displayName': displayName,
      'username': username,
      'email': email,
      'photoUrl': photoUrl,
      'bio': bio,
      'isGuest': isGuest,
      'roomsHosted': roomsHosted,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  UserModel copyWith({
    String? uid,
    String? displayName,
    String? username,
    String? email,
    String? photoUrl,
    String? bio,
    bool? isGuest,
    int? roomsHosted,
    DateTime? createdAt,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      displayName: displayName ?? this.displayName,
      username: username ?? this.username,
      email: email ?? this.email,
      photoUrl: photoUrl ?? this.photoUrl,
      bio: bio ?? this.bio,
      isGuest: isGuest ?? this.isGuest,
      roomsHosted: roomsHosted ?? this.roomsHosted,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
