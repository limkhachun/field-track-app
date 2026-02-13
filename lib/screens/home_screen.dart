import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 📦 Required for caching
import '../widgets/custom_profile_camera.dart';
import 'camera_screen.dart';
import 'attendance_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import 'leave_application_screen.dart';
import 'payslip_screen.dart';

import '../services/tracking_service.dart';
import '../services/notification_service.dart';
import '../services/biometric_service.dart'; // 📦 Required for biometric check

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Removed WidgetsBindingObserver (BiometricGuard now handles lock screen)

  String _staffName = "Staff";
  String? _faceIdPhotoPath;

  StreamSubscription? _leaveSubscription;
  StreamSubscription? _profileSubscription;

  @override
  void initState() {
    super.initState();
    // 1. Load User Data
    _loadUserData();

    // 2. Start Notification Listeners
    // 🟢 NEW: Activate Global Notification Listener Service
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // 启动监听 Leave, Correction, Profile, Payslip 的变化
      NotificationService().startListeningToUserUpdates(user.uid);
    }
    
    // _listenForAdminUpdates(); // 🔴 已注释：防止与 NotificationService 重复导致双重弹窗

    // 3. 🟢 New: Check if biometric setup is needed
    // (Delayed slightly to avoid conflict with initial rendering)
    Future.delayed(const Duration(seconds: 1), _checkBiometricSetup);

    // 4. Resume GPS Tracking
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndResumeTracking();
    });
  }

  @override
  void dispose() {
    _leaveSubscription?.cancel();
    _profileSubscription?.cancel();
    super.dispose();
  }

  // 🟢 Core Logic: Ask to enable biometrics on first login
  Future<void> _checkBiometricSetup() async {
    final prefs = await SharedPreferences.getInstance();

    // Check flags
    bool hasAsked = prefs.getBool('has_asked_biometrics') ?? false; // Has asked before?
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;   // Is already enabled?

    // If enabled or already asked (and rejected), do not disturb
    if (hasAsked || isEnabled) return;

    // Check hardware support
    bool isHardwareSupported = await BiometricService().isDeviceSupported();
    if (!isHardwareSupported) return; // Skip if device not supported

    if (!mounted) return;

    // Show dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('settings.biometric_lock'.tr()),
        content: Text('login.ask_biometric_desc'.tr()), // "Use Fingerprint/Face ID for faster login..."
        actions: [
          TextButton(
            onPressed: () async {
              // User chose "Later" -> Mark as asked
              await prefs.setBool('has_asked_biometrics', true);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text('login.btn_later'.tr(), style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx); // Close dialog, start auth

              // Verify identity immediately
              bool success = await BiometricService().authenticateStaff();

              if (success) {
                // Verification success -> Enable feature and save
                await prefs.setBool('biometric_enabled', true);
                await prefs.setBool('has_asked_biometrics', true);

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('settings.biometric_on_msg'.tr()), backgroundColor: Colors.green)
                  );
                }
              }
            },
            child: Text('login.btn_enable'.tr()),
          ),
        ],
      ),
    );
  }

  // ---------------- Existing Logic Below ----------------

  // 🔴 此方法已不再被调用，功能已移交 NotificationService

  void _checkAndResumeTracking() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      TrackingService().resumeTrackingSession(user.uid);
    }
  }

  void _loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        final data = querySnapshot.docs.first.data();

        if (mounted) {
          setState(() {
            final personal = data['personal'] as Map<String, dynamic>?;
            if (personal != null) {
              if (personal['shortName'] != null && personal['shortName'].toString().isNotEmpty) {
                _staffName = personal['shortName'];
              } else if (personal['name'] != null) {
                _staffName = personal['name'];
              }
              // 🟢 Cache Name (For Biometric Guard Lock Screen)
              _cacheUserName(_staffName);
            }

            if (data['faceIdPhoto'] != null) {
              _faceIdPhotoPath = data['faceIdPhoto'];
            }
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching user data: $e");
    }
  }

  // Helper: Cache User Name
  Future<void> _cacheUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_staff_name', name);
  }

  Future<void> _openCustomCamera() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final XFile? photo = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CustomProfileCamera()),
    );

    if (photo == null) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('home.msg_uploading'.tr()))
      );
    }

    try {
      final String fileName = 'face_id_${user.uid}.jpg';
      final Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('user_faces')
          .child(fileName);

      await storageRef.putFile(File(photo.path));
      final String downloadUrl = await storageRef.getDownloadURL();

      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (q.docs.isNotEmpty) {
        await q.docs.first.reference.update({
          'faceIdPhoto': downloadUrl,
          'hasFaceId': true,
          'lastFaceUpdate': FieldValue.serverTimestamp(),
        });

        if (mounted) {
          setState(() {
            _faceIdPhotoPath = downloadUrl;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('profile.save_success'.tr()),
              backgroundColor: Colors.green,
            )
          );
        }
      }
    } catch (e) {
      debugPrint("Error updating photo: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${'home.msg_upload_fail'.tr()}: $e"), backgroundColor: Colors.red)
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ImageProvider? profileImage;
    if (_faceIdPhotoPath != null && _faceIdPhotoPath!.isNotEmpty) {
      if (_faceIdPhotoPath!.startsWith('http')) {
        profileImage = NetworkImage(_faceIdPhotoPath!);
      } else {
        final file = File(_faceIdPhotoPath!);
        if (file.existsSync()) {
          profileImage = FileImage(file);
        }
      }
    }

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Text('home.app_title'.tr()),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: GestureDetector(
              onTap: _openCustomCamera,
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha:0.1), blurRadius: 4)
                  ]
                ),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.blue.shade700,
                  backgroundImage: profileImage,
                  child: profileImage == null
                      ? const Icon(Icons.add_a_photo, size: 20, color: Colors.white)
                      : null,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'settings.title'.tr(),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.blue,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Row(
              children: [

                const SizedBox(width: 15),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('home.welcome'.tr(), style: const TextStyle(color: Colors.white70)),
                    Text(
                      _staffName,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)
                    ),
                  ],
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
            child: Text('home.menu_main'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),

          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              crossAxisSpacing: 20,
              mainAxisSpacing: 20,
              children: [
                _buildMenuCard(
                  context,
                  'home.att_center'.tr(),
                  Icons.access_time_filled,
                  Colors.orange,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const AttendanceScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.apply_leave'.tr(),
                  Icons.calendar_month_outlined,
                  Colors.green,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const LeaveApplicationScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.smart_cam'.tr(),
                  Icons.camera_alt_outlined,
                  Colors.blue,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const CameraScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.payslip'.tr(),
                  Icons.receipt_long,
                  Colors.pink,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const PayslipScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.profile'.tr(),
                  Icons.person,
                  Colors.purple,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const ProfileScreen())
                    );
                  },
                ),

              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuCard(BuildContext context, String title, IconData icon, Color color, {required VoidCallback onTap, bool isEnabled = true}) {
    return InkWell(
      onTap: isEnabled ? onTap : () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('home.soon'.tr()),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: isEnabled ? Colors.white : Colors.grey[200],
          borderRadius: BorderRadius.circular(20),
          boxShadow: isEnabled ? [
            BoxShadow(
              color: Colors.grey.withValues(alpha:0.1),
              blurRadius: 10,
              spreadRadius: 2,
              offset: const Offset(0, 5),
            ),
          ] : [],
        ),
        child: Stack(
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: isEnabled ? color.withValues(alpha:0.1) : Colors.grey.withValues(alpha:0.3),
                    shape: BoxShape.circle
                  ),
                  child: Icon(icon, color: isEnabled ? color : Colors.grey, size: 35),
                ),
                const SizedBox(height: 15),
                Center(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: isEnabled ? Colors.black : Colors.grey
                    )
                  ),
                ),
              ],
            ),
            if (!isEnabled)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(10)
                  ),
                  child: Text(
                    'home.soon'.tr(),
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)
                  ),
                ),
              )
          ],
        ),
      ),
    );
  }
}