import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
// import 'package:cloud_firestore/cloud_firestore.dart'; // 移除未使用的引用
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:field_track_app/screens/login_screen.dart';
import 'package:field_track_app/screens/change_password_screen.dart';
// import '../services/notification_service.dart'; 

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  // 1. 移除未使用的 _db
  // final FirebaseFirestore _db = FirebaseFirestore.instance;
  
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
    // 检查 mounted 防止在组件销毁后调用 setState
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
      // NotificationService().cancelAllReminders(); 
    }
  }

  // 切换生物识别锁
  Future<void> _toggleBiometric(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometric_enabled', value);
    if (!mounted) return; // 2. 关键修复：异步操作后检查 mounted
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

  // 3. 移除未使用的 _formatTimestamp 方法
  /*
  String _formatTimestamp(Timestamp? ts) {
    if (ts == null) return "";
    return DateFormat('dd MMM yyyy, hh:mm a').format(ts.toDate());
  }
  */

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
          
          SwitchListTile(
            title: Text('settings.biometric_lock'.tr()),
            subtitle: Text('settings.biometric_desc'.tr()),
            value: _biometricEnabled,
            onChanged: _toggleBiometric,
            secondary: const Icon(Icons.fingerprint, color: Colors.blue),
            // 4. 修复 activeColor 弃用警告
            // 使用 activeTrackColor 控制轨道颜色，或 activeThumbColor 控制滑块颜色
            activeTrackColor: Colors.blue, 
            activeThumbColor: Colors.white, // 设置滑块为白色以配合轨道
          ),
          
          const Divider(),

          SwitchListTile(
            title: Text('settings.notifications'.tr()),
            subtitle: Text('settings.notif_desc'.tr()),
            value: _notificationsEnabled,
            onChanged: _toggleNotifications,
            secondary: const Icon(Icons.notifications_active, color: Colors.orange),
            // 4. 修复 activeColor 弃用警告
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
              await _auth.signOut();
              
              // ✅ 修复：使用 context.mounted 代替 !mounted
              // 这明确告诉编译器我们是在检查 context 是否有效
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