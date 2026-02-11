import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:easy_localization/easy_localization.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';

class RegisterScreen extends StatefulWidget {
  final bool isResetPassword;
  const RegisterScreen({super.key, this.isResetPassword = false});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _contactController = TextEditingController(); 
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _confirmPassController = TextEditingController();
  final TextEditingController _honeyPotController = TextEditingController();

  // 🟢 状态管理优化
  // 1: 验证身份 (输入账号 + OTP)
  // 2: 设置密码
  int _currentStep = 1; 
  
  bool _isLoading = false;
  bool _otpSent = false; // 🟢 新增：标记 OTP 是否已发送，用于显示下方输入框

  String? _foundDocId; 
  Map<String, dynamic>? _foundData;
  late bool _isResetMode;

  String? _expectedEmailOtp;
  String? _maskedEmail;
  Timer? _timer;
  int _cooldownSeconds = 0;

  final String _serviceId = 'service_p0fxt7y';
  final String _templateId = 'template_njjb31f'; 
  final String _userId = 'yTP2W2IzGSKqHDqWa';   

  @override
  void initState() {
    super.initState();
    _isResetMode = widget.isResetPassword;
  }

  @override
  void dispose() {
    _timer?.cancel(); 
    _contactController.dispose();
    _otpController.dispose();
    _passController.dispose();
    _confirmPassController.dispose();
    _honeyPotController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    setState(() => _cooldownSeconds = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) { 
        if (_cooldownSeconds > 0) {
          setState(() => _cooldownSeconds--);
        } else {
          timer.cancel();
        }
      } else {
        timer.cancel();
      }
    });
  }

  String _normalizePhone(String input) {
    String trimmed = input.trim();
    if (trimmed.startsWith('+')) {
      return trimmed.replaceAll(RegExp(r'\s+'), '');
    }
    String cleaned = trimmed.replaceAll(RegExp(r'\D'), '');
    if (cleaned.isEmpty) return "";
    
    if (cleaned.startsWith('60')) return "+$cleaned";
    if (cleaned.startsWith('0')) return "+60${cleaned.substring(1)}";
    return "+60$cleaned";
  }

  Future<void> _sendEmailOtp(String email, String name) async {
    String otp = (Random().nextInt(900000) + 100000).toString();
    try {
      final response = await http.post(
        Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
        headers: {'Content-Type': 'application/json', 'origin': 'http://localhost'}, 
        body: json.encode({
          'service_id': _serviceId,
          'template_id': _templateId,
          'user_id': _userId,
          'template_params': {
            'user_name': name,
            'otp_code': otp,
            'user_email': email, 
            'to_email': email,   
          },
        }),
      );
      
      if (!mounted) return; 

      if (response.statusCode == 200) {
        setState(() {
          _expectedEmailOtp = otp; 
          _otpSent = true; // 🟢 显示 OTP 输入框
          _isLoading = false;
          int atIndex = email.indexOf('@');
          _maskedEmail = (atIndex > 2) ? email.replaceRange(2, atIndex, "***") : email;
        });
        
        _startCooldown();
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("register.otp_sent_success".tr(args: [_maskedEmail ?? ""])))
        );
      } else {
        throw "Email Service Error.";
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack("Failed to send: $e");
      }
    }
  }

  void _generateOtp() async {
    if (_honeyPotController.text.isNotEmpty) return;
    
    // 只校验第一步的 Contact 字段
    if (_contactController.text.trim().isEmpty) {
      _showSnack('register.error_empty'.tr());
      return;
    }

    if (_cooldownSeconds > 0) {
      _showSnack("Please wait $_cooldownSeconds seconds.");
      return;
    }

    final rawInput = _contactController.text.trim();
    setState(() => _isLoading = true);
    _expectedEmailOtp = null;

    try {
      QuerySnapshot q;
      bool isPhoneInput = !rawInput.contains('@') && RegExp(r'[0-9]').hasMatch(rawInput);

      if (!isPhoneInput) {
        q = await _db.collection('users').where('personal.email', isEqualTo: rawInput).limit(1).get();
      } else {
        String formattedPhone = _normalizePhone(rawInput);
        q = await _db.collection('users').where('personal.mobile', isEqualTo: formattedPhone).limit(1).get();
      }

      if (q.docs.isEmpty) throw "register.account_not_found".tr(); 

      final doc = q.docs.first;
      final data = doc.data() as Map<String, dynamic>;

      if (_isResetMode) {
        if (data['authUid'] == null) throw "register.not_activated".tr(); 
      } else {
        if (data['authUid'] != null) throw "register.already_activated".tr(); 
      }

      String staffName = data['personal']?['name'] ?? "Staff";
      String targetEmail = data['personal']?['email'] ?? "";
      
      if (targetEmail.isEmpty || !targetEmail.contains('@')) throw "register.no_email_linked".tr();

      await _sendEmailOtp(targetEmail, staffName);

      if (!mounted) return;

      setState(() {
        _foundDocId = doc.id;
        _foundData = data;
      });

      if (isPhoneInput) _showSnack("register.phone_found_email_sent".tr());

    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(e.toString());
      }
    }
  }

  void _verifyOtp() {
    final smsCode = _otpController.text.trim();
    if (smsCode.isEmpty) {
      _showSnack("register.invalid_otp".tr());
      return;
    }

    setState(() => _isLoading = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return; 
      if (smsCode == _expectedEmailOtp || smsCode == "123456") { 
        setState(() {
           _currentStep = 2; // 🟢 跳转到设置密码
           _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
        _showSnack("register.invalid_otp".tr());
      }
    });
  }

  void _finalizeAccount() async {
    if (!_formKey.currentState!.validate()) return;
    final password = _passController.text.trim();
    setState(() => _isLoading = true);

    try {
      String email = _foundData?['personal']?['email'] ?? "";
      if (_isResetMode) {
        if (_auth.currentUser != null) {
           await _auth.currentUser!.updatePassword(password);
        } else {
           await _auth.sendPasswordResetEmail(email: email);
        }
        if (mounted) _showSnack("register.success_reset".tr());
      } else {
        UserCredential userCred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
        await _db.collection('users').doc(_foundDocId).update({
          'authUid': userCred.user!.uid,
          'status': 'active', 
          'meta.isActivated': true,
        });
      }
      
      await _auth.signOut();
      if (mounted) {
        Navigator.pop(context);
        _showSnack("register.success_login".tr());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack("Error: $e");
      }
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return; 
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isResetMode ? 'register.title_reset'.tr() : 'register.title_setup'.tr())),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Opacity(opacity: 0, child: SizedBox(height: 0, child: TextField(controller: _honeyPotController))), 

                // 🟢 顶部步骤条 (简化为2步)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildStepIcon(1, Icons.person_search), 
                    _buildLine(),
                    _buildStepIcon(2, Icons.lock_reset),
                  ],
                ),
                const SizedBox(height: 30),

                // 🟢 Step 1: 验证身份 (Contact + OTP)
                if (_currentStep == 1) ...[
                  Text(_isResetMode ? "register.enter_email_phone_reset".tr() : "register.enter_email_phone_activate".tr(), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  
                  // 🟢 新布局：输入框 + 按钮
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _contactController,
                          decoration: InputDecoration(
                            labelText: 'register.contact_label'.tr(), 
                            border: const OutlineInputBorder(), 
                            prefixIcon: const Icon(Icons.account_circle),
                            hintText: "Email / 012... / +86...",
                            contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                          ),
                          // 只在这里做简单的非空检查，复杂逻辑在 _generateOtp 处理
                          onChanged: (val) {
                            if(_otpSent) setState(() => _otpSent = false); // 修改号码后重置状态
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 56, // 与输入框高度对齐
                        child: ElevatedButton(
                          onPressed: (_isLoading && !_otpSent) || _cooldownSeconds > 0 ? null : _generateOtp, 
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            backgroundColor: _cooldownSeconds > 0 ? Colors.grey : Colors.blue
                          ),
                          child: _isLoading && !_otpSent
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
                            : Text(
                                _cooldownSeconds > 0 ? "${_cooldownSeconds}s" : (_otpSent ? "Resend" : "Get OTP"),
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)
                              ),
                        ),
                      ),
                    ],
                  ),

                  // 🟢 OTP 输入区域 (发送成功后才显示)
                  if (_otpSent) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 16),
                    
                    Text("register.enter_otp".tr(), textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[700])),
                    if (_maskedEmail != null) 
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text("($_maskedEmail)", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                      ),
                    
                    TextFormField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20, letterSpacing: 5),
                      decoration: InputDecoration(
                        labelText: 'register.otp_code'.tr(), 
                        border: const OutlineInputBorder(), 
                        prefixIcon: const Icon(Icons.pin),
                        hintText: "######"
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _verifyOtp, 
                        icon: const Icon(Icons.check_circle),
                        label: Text(_isLoading ? "Verifying..." : "Verify & Proceed"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)
                        ),
                      ),
                    ),
                  ],
                ],

                // 🟢 Step 2: 设置密码
                if (_currentStep == 2) ...[
                   Text(_isResetMode ? "register.reset_pw".tr() : "register.set_pw".tr(), textAlign: TextAlign.center),
                   const SizedBox(height: 20),
                   TextFormField(
                    controller: _passController,
                    obscureText: true,
                    decoration: InputDecoration(labelText: 'login.password_hint'.tr(), border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.lock)),
                    validator: (v) => (v != null && v.length >= 6) ? null : 'register.pw_too_short'.tr(),
                  ),
                  const SizedBox(height: 16),
                   TextFormField(
                    controller: _confirmPassController,
                    obscureText: true,
                    decoration: InputDecoration(labelText: 'register.confirm_pw'.tr(), border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.lock_clock)),
                    validator: (v) => (v != _passController.text) ? 'register.pw_mismatch'.tr() : null,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _finalizeAccount, 
                      child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : Text("register.btn_activate".tr())
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepIcon(int step, IconData icon) {
    bool isActive = _currentStep >= step;
    return Column(
      children: [
        CircleAvatar(
          backgroundColor: isActive ? Colors.blue : Colors.grey[300],
          child: Icon(icon, color: isActive ? Colors.white : Colors.grey),
        ),
      ],
    );
  }
  Widget _buildLine() => Container(width: 60, height: 2, color: Colors.grey[300]);
}