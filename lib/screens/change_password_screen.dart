import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  
  // Controllers
  final TextEditingController _currentController = TextEditingController();
  final TextEditingController _newController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();

  // Visibility State
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;

  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  // Submit Logic
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    final user = _auth.currentUser;

    if (user == null || user.email == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error: No user login.")));
      setState(() => _isLoading = false);
      return;
    }

    try {
      // 1. Re-authenticate (Required for security sensitive operations)
      AuthCredential credential = EmailAuthProvider.credential(
        email: user.email!,
        password: _currentController.text.trim(),
      );
      
      await user.reauthenticateWithCredential(credential);

      // 2. Update Password
      await user.updatePassword(_newController.text.trim());

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('change_pw.success'.tr()), // Localized Success
          backgroundColor: Colors.green
        )
      );
      Navigator.pop(context); 

    } on FirebaseAuthException catch (e) {
      String msg = 'change_pw.error_generic'.tr(); // Default error
      
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        msg = 'change_pw.error_wrong_curr'.tr();
      } else if (e.code == 'weak-password') {
        msg = 'register.pw_too_short'.tr(); // Reuse existing key
      } else if (e.code == 'requires-recent-login') {
        msg = 'change_pw.error_session'.tr();
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red)
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red)
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildPasswordField({
    required String label,
    required TextEditingController controller,
    required bool isObscure,
    required VoidCallback onToggle,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 13)),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          obscureText: isObscure,
          decoration: InputDecoration(
            hintText: label, // Simplified hint
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            suffixIcon: IconButton(
              icon: Icon(isObscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: onToggle,
            ),
          ),
          validator: validator,
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('settings.change_pw'.tr()),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_reset, size: 64, color: Colors.blue),
                ),
              ),
              const SizedBox(height: 30),

              Text(
                'change_pw.subtitle'.tr(), 
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)
              ),
              Text(
                'change_pw.desc'.tr(),
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 30),

              // 1. Current Password
              _buildPasswordField(
                label: 'change_pw.current_label'.tr(),
                controller: _currentController,
                isObscure: _obscureCurrent,
                onToggle: () => setState(() => _obscureCurrent = !_obscureCurrent),
                validator: (val) => (val == null || val.isEmpty) ? 'leave.error_required'.tr() : null,
              ),

              // 2. New Password
              _buildPasswordField(
                label: 'change_pw.new_label'.tr(),
                controller: _newController,
                isObscure: _obscureNew,
                onToggle: () => setState(() => _obscureNew = !_obscureNew),
                validator: (val) {
                  if (val == null || val.length < 6) return 'register.pw_too_short'.tr();
                  if (val == _currentController.text) return 'change_pw.error_same'.tr();
                  return null;
                },
              ),

              // 3. Confirm Password
              _buildPasswordField(
                label: 'change_pw.confirm_label'.tr(),
                controller: _confirmController,
                isObscure: _obscureConfirm,
                onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
                validator: (val) {
                  if (val != _newController.text) return 'register.pw_mismatch'.tr();
                  return null;
                },
              ),

              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isLoading 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text('change_pw.btn_submit'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}