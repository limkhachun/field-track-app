import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
import '../services/biometric_service.dart';

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
  String _cachedName = "Staff"; // Default to "Staff"

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
    
    // Initial load of cached name
    setState(() {
      _cachedName = prefs.getString('cached_staff_name') ?? "Staff";
    });

    final user = FirebaseAuth.instance.currentUser;
    // Only lock if enabled and user is logged in
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
    // 🟢 KEY CHANGE: Refresh the cached name right before authentication
    // This ensures that if HomeScreen just fetched the name, we show it here immediately.
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _cachedName = prefs.getString('cached_staff_name') ?? "Staff";
      });
    }

    _isAuthenticating = true;
    try {
      bool authenticated = await BiometricService().authenticateStaff();
      if (mounted) {
        setState(() {
          // Success -> Unlock; Failure -> Keep locked
          if (authenticated) _isLocked = false; 
        });
      }
    } catch (e) {
      debugPrint("Auth error: $e");
    } finally {
      // Delay slightly to prevent rapid-fire loop if auth fails instantly
      await Future.delayed(const Duration(milliseconds: 500));
      _isAuthenticating = false;
    }
  }

  // Handle "Relogin" (Logout)
  Future<void> _handleRelogin() async {
    // 1. Unlock the guard (otherwise it might cover the LoginScreen)
    setState(() => _isLocked = false);
    
    // 2. Sign out
    await FirebaseAuth.instance.signOut();
    
    // The StreamBuilder in main.dart will detect the auth change and show LoginScreen
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. The actual app underneath
        widget.child,

        // 2. The Lock Screen Overlay
        if (_isLocked)
          Scaffold(
            backgroundColor: Colors.white,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30.0, vertical: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    
                    // --- 1. Logo Area ---
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

                    // --- 2. Welcome Text ---
                    Text(
                      "lock.welcome_back".tr(),
                      style: const TextStyle(fontSize: 18, color: Colors.black54),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _cachedName.toUpperCase(), // Displays the fresh cached name
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 26, 
                        fontWeight: FontWeight.bold, 
                        color: Color(0xFF15438c)
                      ),
                    ),

                    const Spacer(), 

                    // --- 3. Fingerprint Icon ---
                    Text(
                      "lock.verify_identity".tr(),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    const SizedBox(height: 20),
                    
                    GestureDetector(
                      onTap: _authenticate, // Tap to retry
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

                    // --- 4. Relogin Button ---
                    TextButton(
                      onPressed: _handleRelogin,
                      child: Text(
                        "lock.relogin".tr(),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF15438c)),
                      ),
                    ),

                    const SizedBox(height: 30),

                    // --- 5. Footer ---
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
                          onTap: () {}, 
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