import 'package:cloud_firestore/cloud_firestore.dart';

class RoomModel {
  final String id;
  final String roomCode;
  final String title;
  final String hostId;
  final String hostName;
  final String? hostAvatar;
  final String videoType; // 'LOCAL', 'YOUTUBE', 'WEB'
  final String? videoUrl;
  final bool isPublic;
  final int viewerCount;
  final int maxViewers; // Default 8 max viewers
  final bool isAdultContent; // 18+ sensitive adult content flag
  final DateTime createdAt;
  final String? passcode;
  final bool isActive;

  const RoomModel({
    required this.id,
    required this.roomCode,
    required this.title,
    required this.hostId,
    required this.hostName,
    this.hostAvatar,
    this.videoType = 'LOCAL',
    this.videoUrl,
    this.isPublic = true,
    this.viewerCount = 0,
    this.maxViewers = 8,
    this.isAdultContent = false,
    required this.createdAt,
    this.passcode,
    this.isActive = true,
  });

  factory RoomModel.fromMap(Map<String, dynamic> map, [String? docId]) {
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

    return RoomModel(
      id: docId ?? map['id'] ?? map['roomCode'] ?? '',
      roomCode: map['roomCode'] ?? docId ?? '',
      title: map['title'] ?? 'Watch Party',
      hostId: map['hostId'] ?? '',
      hostName: map['hostName'] ?? 'Host',
      hostAvatar: map['hostAvatar'] as String?,
      videoType: (map['videoType'] as String? ?? 'LOCAL').toUpperCase(),
      videoUrl: map['videoUrl'] as String?,
      isPublic: map['isPublic'] as bool? ?? true,
      viewerCount: (map['viewerCount'] as num? ?? 0).toInt(),
      maxViewers: (map['maxViewers'] as num? ?? 8).toInt(),
      isAdultContent: map['isAdultContent'] as bool? ?? false,
      createdAt: parsedDate,
      passcode: map['passcode'] as String?,
      isActive: map['isActive'] as bool? ?? true,
    );
  }

  factory RoomModel.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? {};
    return RoomModel.fromMap(data, doc.id);
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'roomCode': roomCode,
      'title': title,
      'hostId': hostId,
      'hostName': hostName,
      'hostAvatar': hostAvatar,
      'videoType': videoType,
      'videoUrl': videoUrl,
      'isPublic': isPublic,
      'viewerCount': viewerCount,
      'maxViewers': maxViewers,
      'isAdultContent': isAdultContent,
      'createdAt': Timestamp.fromDate(createdAt),
      'passcode': passcode,
      'isActive': isActive,
    };
  }

  RoomModel copyWith({
    String? id,
    String? roomCode,
    String? title,
    String? hostId,
    String? hostName,
    String? hostAvatar,
    String? videoType,
    String? videoUrl,
    bool? isPublic,
    int? viewerCount,
    int? maxViewers,
    bool? isAdultContent,
    DateTime? createdAt,
    String? passcode,
    bool? isActive,
  }) {
    return RoomModel(
      id: id ?? this.id,
      roomCode: roomCode ?? this.roomCode,
      title: title ?? this.title,
      hostId: hostId ?? this.hostId,
      hostName: hostName ?? this.hostName,
      hostAvatar: hostAvatar ?? this.hostAvatar,
      videoType: videoType ?? this.videoType,
      videoUrl: videoUrl ?? this.videoUrl,
      isPublic: isPublic ?? this.isPublic,
      viewerCount: viewerCount ?? this.viewerCount,
      maxViewers: maxViewers ?? this.maxViewers,
      isAdultContent: isAdultContent ?? this.isAdultContent,
      createdAt: createdAt ?? this.createdAt,
      passcode: passcode ?? this.passcode,
      isActive: isActive ?? this.isActive,
    );
  }
}
