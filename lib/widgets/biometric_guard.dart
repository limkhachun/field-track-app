import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart'; // 需要退出登录
import 'package:easy_localization/easy_localization.dart'; // 翻译
import '../services/biometric_service.dart'; // 你的服务

class BiometricGuard extends StatefulWidget {
  final Widget child;

  const BiometricGuard({super.key, required this.child});

  @override
  State<BiometricGuard> createState() => _BiometricGuardState();
}

class _BiometricGuardState extends State<BiometricGuard> with WidgetsBindingObserver {
  bool _isLocked = false; 
  bool _isAuthenticating = false; 
  bool _isEnabled = false; 
  String _cachedName = ""; // 🟢 缓存的名字

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkInitialStatus() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('biometric_enabled') ?? false;
    
    // 🟢 读取缓存的名字
    setState(() {
      _cachedName = prefs.getString('cached_staff_name') ?? "Staff";
    });

    final user = FirebaseAuth.instance.currentUser;
    // 只有已登录且开启了指纹锁才锁定
    if (_isEnabled && user != null) {
      setState(() => _isLocked = true);
      _authenticate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isAuthenticating) return;

    if (state == AppLifecycleState.paused) {
      _checkSettingsAndLock();
    } else if (state == AppLifecycleState.resumed) {
      if (_isLocked) {
        _authenticate();
      }
    }
  }

  Future<void> _checkSettingsAndLock() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('biometric_enabled') ?? false;
    final user = FirebaseAuth.instance.currentUser;
    
    if (_isEnabled && user != null) {
      setState(() => _isLocked = true);
    }
  }

  Future<void> _authenticate() async {
    _isAuthenticating = true;
    try {
      bool authenticated = await BiometricService().authenticateStaff();
      if (mounted) {
        setState(() {
          // 验证成功 -> 解锁；失败 -> 保持锁定
          if (authenticated) _isLocked = false; 
        });
      }
    } catch (e) {
      debugPrint("Auth error: $e");
    } finally {
      await Future.delayed(const Duration(milliseconds: 500));
      _isAuthenticating = false;
    }
  }

  // 🟢 处理“重新登录”
  Future<void> _handleRelogin() async {
    // 1. 解锁遮罩 (否则退出后可能还会盖在 LoginScreen 上)
    setState(() => _isLocked = false);
    
    // 2. 执行登出
    await FirebaseAuth.instance.signOut();
    
    // main.dart 的 StreamBuilder 会自动感知并跳转到 LoginScreen
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. 底层应用
        widget.child,

        // 2. 顶层：仿 Info-Tech 锁屏界面
        if (_isLocked)
          Scaffold(
            backgroundColor: Colors.white,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30.0, vertical: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    
                    // --- 1. Logo 区域 ---
                    // 如果有 logo 图片资源: Image.asset('assets/logo.png', height: 60),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        "FIELDTRACK PRO", 
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF15438c), letterSpacing: 1.5),
                      ),
                    ),

                    const SizedBox(height: 60),

                    // --- 2. 欢迎语 ---
                    Text(
                      "lock.welcome_back".tr(),
                      style: const TextStyle(fontSize: 18, color: Colors.black54),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _cachedName.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 26, 
                        fontWeight: FontWeight.bold, 
                        color: Color(0xFF15438c) // 深蓝色
                      ),
                    ),

                    const Spacer(), 

                    // --- 3. 指纹图标区域 ---
                    Text(
                      "lock.verify_identity".tr(),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    const SizedBox(height: 20),
                    
                    GestureDetector(
                      onTap: _authenticate, // 点击图标再次触发验证
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.blue.shade100, width: 2),
                        ),
                        child: const Icon(
                          Icons.fingerprint, 
                          size: 70, 
                          color: Colors.blue
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 15),
                    Text(
                      "lock.touch_sensor".tr(),
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),

                    const Spacer(),

                    // --- 4. 重新登陆按钮 ---
                    TextButton(
                      onPressed: _handleRelogin,
                      child: Text(
                        "lock.relogin".tr(),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF15438c)),
                      ),
                    ),

                    const SizedBox(height: 30),

                    // --- 5. 底部版权文字 ---
                    Text(
                      "Version 1.0.0",
                      style: TextStyle(color: Colors.blue.shade800, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 20),
                    
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 4,
                      children: [
                        Text("lock.footer_text".tr(), style: const TextStyle(fontSize: 11, color: Colors.black54), textAlign: TextAlign.center),
                        GestureDetector(
                          onTap: () {}, // 可以在此添加跳转隐私政策的逻辑
                          child: Text("lock.privacy".tr(), style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.bold)),
                        ),
                        const Text("&", style: TextStyle(fontSize: 11, color: Colors.black54)),
                        GestureDetector(
                          onTap: () {},
                          child: Text("lock.terms".tr(), style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.bold)),
                        ),
                        const Text(".", style: TextStyle(fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}