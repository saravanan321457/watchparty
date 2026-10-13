import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:intl/intl.dart';

import '../models/room_model.dart';
import '../services/firestore_service.dart';
import '../services/auth_service.dart';

import 'host_screen.dart';
import 'viewer_screen.dart';
import 'youtube_sync_screen.dart';
import 'web_media_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _currentNavIndex = 0;
  String _searchQuery = '';
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();

  static const Color _bgColor = Color(0xFF0A0A0F);
  static const Color _surfaceColor = Color(0xFF1A1A2E);
  static const Color _accentPurple = Color(0xFF6C63FF);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _currentNavIndex = _tabController.index == 0 ? 0 : 2;
        });
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _formatTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inSeconds < 60) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return DateFormat('MMM d').format(dateTime);
    }
  }

  void _showCreateBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: _surfaceColor,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 30,
                offset: Offset(0, -5),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top handle
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Sheet Title
                const Text(
                  'Start Watch Party',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Choose a video source to stream and sync with friends',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.55),
                  ),
                ),
                const SizedBox(height: 24),

                // Option 1: Local Video
                _BottomSheetOption(
                  iconEmoji: '🎬',
                  iconBgColor: const Color(0xFF6C63FF),
                  title: 'Local Video',
                  subtitle: 'Host a video from your phone',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const HostScreen()),
                    );
                  },
                ),
                const SizedBox(height: 12),

                // Option 2: YouTube Sync
                _BottomSheetOption(
                  iconEmoji: '▶',
                  iconBgColor: const Color(0xFFFF3366),
                  title: 'YouTube Sync',
                  subtitle: 'Sync YouTube with friends',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const YouTubeSyncScreen()),
                    );
                  },
                ),
                const SizedBox(height: 12),

                // Option 3: Web Media
                _BottomSheetOption(
                  iconEmoji: '🌐',
                  iconBgColor: const Color(0xFF00B4D8),
                  title: 'Web Media',
                  subtitle: 'Sync any web video',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const WebMediaScreen()),
                    );
                  },
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPrivateRoomCodeDialog(RoomModel room) {
    final codeController = TextEditingController();
    String? errorMessage;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: _surfaceColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.lock_rounded,
                        color: Colors.amber, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Private Room',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This room requires a passcode to enter.',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.7), fontSize: 13),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: codeController,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Enter room passcode',
                      hintStyle:
                          TextStyle(color: Colors.white.withOpacity(0.35)),
                      errorText: errorMessage,
                      prefixIcon: const Icon(Icons.key_rounded,
                          color: _accentPurple),
                      filled: true,
                      fillColor: _bgColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Color(0xFF2A2A4A)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: _accentPurple, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel',
                      style:
                          TextStyle(color: Colors.white.withOpacity(0.6))),
                ),
                FilledButton(
                  onPressed: () {
                    final enteredCode = codeController.text.trim();
                    if (room.passcode != null &&
                        room.passcode!.isNotEmpty &&
                        enteredCode != room.passcode) {
                      setDialogState(() {
                        errorMessage = 'Incorrect passcode';
                      });
                      return;
                    }
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ViewerScreen(roomCode: room.roomCode),
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: _accentPurple,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Enter Room'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _onBottomNavTapped(int index) {
    setState(() {
      _currentNavIndex = index;
    });

    if (index == 0) {
      _tabController.animateTo(0);
      if (_isSearching) {
        setState(() {
          _isSearching = false;
          _searchQuery = '';
          _searchController.clear();
        });
      }
    } else if (index == 1) {
      setState(() {
        _isSearching = !_isSearching;
        if (!_isSearching) {
          _searchQuery = '';
          _searchController.clear();
        }
      });
    } else if (index == 2) {
      _tabController.animateTo(1);
    } else if (index == 3) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ProfileScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? '';

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _bgColor,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search rooms or hosts...',
                  hintStyle:
                      TextStyle(color: Colors.white.withOpacity(0.4)),
                  border: InputBorder.none,
                  prefixIcon: const Icon(Icons.search_rounded,
                      color: _accentPurple),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white54),
                    onPressed: () {
                      setState(() {
                        _isSearching = false;
                        _searchQuery = '';
                        _searchController.clear();
                      });
                    },
                  ),
                ),
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val.trim().toLowerCase();
                  });
                },
              )
            : ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [Color(0xFF6C63FF), Color(0xFFA78BFA)],
                ).createShader(r),
                child: const Text(
                  'Watch Together',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                    color: Colors.white,
                  ),
                ),
              ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _accentPurple, width: 2),
                ),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: _surfaceColor,
                  backgroundImage: user?.photoURL != null &&
                          user!.photoURL!.isNotEmpty
                      ? CachedNetworkImageProvider(user.photoURL!)
                      : null,
                  child: user?.photoURL == null || user!.photoURL!.isEmpty
                      ? Text(
                          (user?.displayName?.isNotEmpty ?? false)
                              ? user!.displayName![0].toUpperCase()
                              : 'U',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(54),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: _surfaceColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: _accentPurple,
                boxShadow: [
                  BoxShadow(
                    color: _accentPurple.withOpacity(0.4),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              labelStyle: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15),
              unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.normal, fontSize: 15),
              tabs: const [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.explore_rounded, size: 18),
                      SizedBox(width: 8),
                      Text('Discover'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.video_library_rounded, size: 18),
                      SizedBox(width: 8),
                      Text('My Rooms'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Discover Tab
          _buildDiscoverTab(),

          // My Rooms Tab
          _buildMyRoomsTab(uid),
        ],
      ),
      floatingActionButton: Container(
        height: 60,
        width: 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Color(0xFF6C63FF), Color(0xFF8B84FF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: _accentPurple.withOpacity(0.55),
              blurRadius: 18,
              spreadRadius: 2,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: RawMaterialButton(
          shape: const CircleBorder(),
          elevation: 0,
          onPressed: _showCreateBottomSheet,
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 34),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        color: const Color(0xFF141424),
        elevation: 10,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // 1. Home / Discover
              _BottomNavItem(
                icon: Icons.explore_rounded,
                label: 'Discover',
                isSelected: _currentNavIndex == 0,
                onTap: () => _onBottomNavTapped(0),
              ),

              // 2. Search
              _BottomNavItem(
                icon: Icons.search_rounded,
                label: 'Search',
                isSelected: _currentNavIndex == 1 || _isSearching,
                onTap: () => _onBottomNavTapped(1),
              ),

              const SizedBox(width: 48), // Gap for docked FAB

              // 3. My Rooms
              _BottomNavItem(
                icon: Icons.video_library_rounded,
                label: 'My Rooms',
                isSelected: _currentNavIndex == 2,
                onTap: () => _onBottomNavTapped(2),
              ),

              // 4. Profile
              _BottomNavItem(
                icon: Icons.person_rounded,
                label: 'Profile',
                isSelected: _currentNavIndex == 3,
                onTap: () => _onBottomNavTapped(3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiscoverTab() {
    return StreamBuilder<List<RoomModel>>(
      stream: FirestoreService.instance.getPublicRoomsStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildShimmerLoading();
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.wifi_off_rounded,
                      size: 60, color: Colors.white38),
                  const SizedBox(height: 16),
                  Text(
                    'Error loading live rooms',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white.withOpacity(0.8),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12, color: Colors.white.withOpacity(0.4)),
                  ),
                ],
              ),
            ),
          );
        }

        List<RoomModel> rooms = snapshot.data ?? [];

        if (_searchQuery.isNotEmpty) {
          rooms = rooms.where((r) {
            return r.title.toLowerCase().contains(_searchQuery) ||
                r.hostName.toLowerCase().contains(_searchQuery) ||
                r.roomCode.toLowerCase().contains(_searchQuery);
          }).toList();
        }

        if (rooms.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _surfaceColor,
                      boxShadow: [
                        BoxShadow(
                          color: _accentPurple.withOpacity(0.15),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.movie_filter_rounded,
                        size: 50, color: _accentPurple),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'No rooms live right now. Be the first!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Tap the glowing + button below to start hosting your movie party.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _showCreateBottomSheet,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Host Room'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accentPurple,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return RefreshIndicator(
          color: _accentPurple,
          backgroundColor: _surfaceColor,
          onRefresh: () async {
            setState(() {});
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: rooms.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (context, index) {
              final room = rooms[index];
              return _RoomCard(
                room: room,
                timeAgo: _formatTimeAgo(room.createdAt),
                onJoin: () {
                  if (room.isPublic) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ViewerScreen(roomCode: room.roomCode),
                      ),
                    );
                  } else {
                    _showPrivateRoomCodeDialog(room);
                  }
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildMyRoomsTab(String uid) {
    if (uid.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.account_circle_outlined,
                  size: 60, color: Colors.white38),
              const SizedBox(height: 16),
              const Text(
                'Please sign in to view your rooms',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  );
                },
                style: FilledButton.styleFrom(
                    backgroundColor: _accentPurple),
                child: const Text('Go to Profile'),
              ),
            ],
          ),
        ),
      );
    }

    return StreamBuilder<List<RoomModel>>(
      stream: FirestoreService.instance.getMyRoomsStream(uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildShimmerLoading();
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading your rooms: ${snapshot.error}',
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }

        List<RoomModel> rooms = snapshot.data ?? [];

        if (_searchQuery.isNotEmpty) {
          rooms = rooms.where((r) {
            return r.title.toLowerCase().contains(_searchQuery) ||
                r.roomCode.toLowerCase().contains(_searchQuery);
          }).toList();
        }

        if (rooms.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _surfaceColor,
                      boxShadow: [
                        BoxShadow(
                          color: _accentPurple.withOpacity(0.12),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.video_camera_back_rounded,
                        size: 44, color: _accentPurple),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "You haven't hosted any rooms yet. Tap + to start!",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Pick a video file, YouTube link, or web stream to begin.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _showCreateBottomSheet,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Create a Room'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accentPurple,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return RefreshIndicator(
          color: _accentPurple,
          backgroundColor: _surfaceColor,
          onRefresh: () async {
            setState(() {});
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: rooms.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (context, index) {
              final room = rooms[index];
              return _RoomCard(
                room: room,
                timeAgo: _formatTimeAgo(room.createdAt),
                onJoin: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ViewerScreen(roomCode: room.roomCode),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildShimmerLoading() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        return Shimmer.fromColors(
          baseColor: _surfaceColor,
          highlightColor: const Color(0xFF2A2A4A),
          child: Container(
            height: 135,
            decoration: BoxDecoration(
              color: _surfaceColor,
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        );
      },
    );
  }
}

// Internal RoomCard widget
class _RoomCard extends StatelessWidget {
  final RoomModel room;
  final String timeAgo;
  final VoidCallback onJoin;

  const _RoomCard({
    required this.room,
    required this.timeAgo,
    required this.onJoin,
  });

  Color _getVideoTypeColor() {
    switch (room.videoType.toUpperCase()) {
      case 'YOUTUBE':
        return const Color(0xFFFF0033);
      case 'WEB':
        return const Color(0xFF00B4D8);
      case 'LOCAL':
      default:
        return const Color(0xFF6C63FF);
    }
  }

  String _getVideoTypeIcon() {
    switch (room.videoType.toUpperCase()) {
      case 'YOUTUBE':
        return '▶ YouTube';
      case 'WEB':
        return '🌐 Web';
      case 'LOCAL':
      default:
        return '🎬 Local';
    }
  }

  @override
  Widget build(BuildContext context) {
    const cardBg = Color(0xFF1A1A2E);
    const accentPurple = Color(0xFF6C63FF);

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF2A2A4A).withOpacity(0.6),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Row: Avatar + Title/Host/Badges + JOIN button
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Host Avatar
              CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0xFF2A2A4A),
                backgroundImage: room.hostAvatar != null &&
                        room.hostAvatar!.isNotEmpty
                    ? CachedNetworkImageProvider(room.hostAvatar!)
                    : null,
                child: room.hostAvatar == null || room.hostAvatar!.isEmpty
                    ? Text(
                        room.hostName.isNotEmpty
                            ? room.hostName[0].toUpperCase()
                            : 'H',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 14),

              // Title and Host details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Host: ${room.hostName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.6),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Badges: Video Type Chip + Public/Private Chip
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        // Video Type Badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _getVideoTypeColor().withOpacity(0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: _getVideoTypeColor().withOpacity(0.6),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            _getVideoTypeIcon(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _getVideoTypeColor(),
                            ),
                          ),
                        ),

                        // Public / Private Badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: room.isPublic
                                ? const Color(0xFF4CAF50).withOpacity(0.18)
                                : const Color(0xFFFF9800).withOpacity(0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: room.isPublic
                                  ? const Color(0xFF4CAF50).withOpacity(0.6)
                                  : const Color(0xFFFF9800).withOpacity(0.6),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                room.isPublic
                                    ? Icons.public_rounded
                                    : Icons.lock_rounded,
                                size: 11,
                                color: room.isPublic
                                    ? const Color(0xFF4CAF50)
                                    : const Color(0xFFFF9800),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                room.isPublic ? 'PUBLIC' : 'PRIVATE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                  color: room.isPublic
                                      ? const Color(0xFF4CAF50)
                                      : const Color(0xFFFF9800),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 10),

              // Right: JOIN button
              ElevatedButton(
                onPressed: onJoin,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentPurple,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 4,
                  shadowColor: accentPurple.withOpacity(0.5),
                ),
                child: const Text(
                  'JOIN',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFF2A2A4A)),
          const SizedBox(height: 10),

          // Bottom row: 👁 viewerCount + time ago
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Viewer count
              Row(
                children: [
                  const Icon(
                    Icons.visibility_rounded,
                    size: 16,
                    color: Color(0xFF6C63FF),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${room.viewerCount} watching',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withOpacity(0.75),
                    ),
                  ),
                ],
              ),

              // Time ago
              Row(
                children: [
                  Icon(
                    Icons.access_time_rounded,
                    size: 14,
                    color: Colors.white.withOpacity(0.4),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    timeAgo,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.45),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Bottom sheet option widget
class _BottomSheetOption extends StatelessWidget {
  final String iconEmoji;
  final Color iconBgColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _BottomSheetOption({
    required this.iconEmoji,
    required this.iconBgColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: iconBgColor.withOpacity(0.2),
        highlightColor: iconBgColor.withOpacity(0.1),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF222238),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF2E2E4A),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: iconBgColor.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text(
                  iconEmoji,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.55),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 15,
                color: Colors.white.withOpacity(0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Bottom nav item widget
class _BottomNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const accentPurple = Color(0xFF6C63FF);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isSelected ? accentPurple : Colors.white38,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? accentPurple : Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
