import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
// import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:field_track_app/screens/login_screen.dart';
import 'package:field_track_app/screens/change_password_screen.dart';
import 'package:field_track_app/screens/announcement_screen.dart'; // 🟢 Import New Screen
import '../services/notification_service.dart'; 

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  // Settings State
  bool _notificationsEnabled = true;
  bool _biometricEnabled = false;
  bool _isLoading = true;

  final Map<String, String> _languages = {
    'en': 'English',
    'ms': 'Bahasa Melayu',
    'zh': '中文 (Chinese)',
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  // 加载本地设置
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return; 
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
      _biometricEnabled = prefs.getBool('biometric_enabled') ?? false;
      _isLoading = false;
    });
  }

  // 切换通知
  Future<void> _toggleNotifications(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', value);
    if (!mounted) return;
    setState(() => _notificationsEnabled = value);

    if (!value) {
      NotificationService().cancelAllReminders(); 
    }
  }

  // 切换生物识别锁
  Future<void> _toggleBiometric(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometric_enabled', value);
    if (!mounted) return;
    setState(() => _biometricEnabled = value);
    
    if (value) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('settings.biometric_on_msg'.tr())),
      );
    }
  }

  Future<void> _changeLanguage(String? langCode) async {
    if (langCode == null) return;
    await context.setLocale(Locale(langCode));
    if (!mounted) return;
    setState(() {}); 
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(
        title: Text('settings.title'.tr()),
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: Colors.black,
      ),
      backgroundColor: Colors.grey[50],
      body: ListView(
        children: [
          // 1. App Settings Section
          _buildSectionHeader('settings.header_app'.tr()),
          
          // 🟢 NEW: Announcement Tile
          ListTile(
            leading: const Icon(Icons.campaign, color: Colors.orange),
            title: const Text('Announcements'), // "announcement.title".tr()
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnouncementScreen())),
          ),

          const Divider(),

          SwitchListTile(
            title: Text('settings.biometric_lock'.tr()),
            subtitle: Text('settings.biometric_desc'.tr()),
            value: _biometricEnabled,
            onChanged: _toggleBiometric,
            secondary: const Icon(Icons.fingerprint, color: Colors.blue),
            activeTrackColor: Colors.blue, 
            activeThumbColor: Colors.white, 
          ),
          
          const Divider(),

          SwitchListTile(
            title: Text('settings.notifications'.tr()),
            subtitle: Text('settings.notif_desc'.tr()),
            value: _notificationsEnabled,
            onChanged: _toggleNotifications,
            secondary: const Icon(Icons.notifications_active, color: Colors.orange),
            activeTrackColor: Colors.orange,
            activeThumbColor: Colors.white,
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.language, color: Colors.purple),
            title: Text('settings.language'.tr()),
            trailing: DropdownButton<String>(
              value: context.locale.languageCode,
              underline: Container(),
              items: _languages.entries.map((entry) {
                return DropdownMenuItem(value: entry.key, child: Text(entry.value));
              }).toList(),
              onChanged: _changeLanguage,
            ),
          ),

          // 2. Account Section
          _buildSectionHeader('settings.header_account'.tr()),
          ListTile(
            leading: const Icon(Icons.lock_reset, color: Colors.grey),
            title: Text('settings.change_pw'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
          ),
          
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text('settings.logout'.tr(), style: const TextStyle(color: Colors.red)),
            onTap: () async {
              NotificationService().stopListening();
              
              await _auth.signOut();
              
              if (!context.mounted) return;
              
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (route) => false
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey[600]),
      ),
    );
  }
}