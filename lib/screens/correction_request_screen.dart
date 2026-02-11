import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

class CorrectionRequestScreen extends StatefulWidget {
  final DateTime date;
  final String? attendanceId; 
  final String originalIn;
  final String originalOut;

  const CorrectionRequestScreen({
    super.key,
    required this.date,
    this.attendanceId,
    required this.originalIn,
    required this.originalOut,
  });

  @override
  State<CorrectionRequestScreen> createState() => _CorrectionRequestScreenState();
}

class _CorrectionRequestScreenState extends State<CorrectionRequestScreen> {
  TimeOfDay? _reqIn;
  TimeOfDay? _reqOut;
  final TextEditingController _remarksCtrl = TextEditingController();
  bool _isLoading = false;

  XFile? _selectedFile;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
  }

  Future<void> _selectTime(bool isIn) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null) {
      setState(() {
        if (isIn) {
          _reqIn = picked;
        } else {
          _reqOut = picked;
        }
      });
    }
  }

  Future<void> _pickImage() async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery, 
        imageQuality: 80
      );
      if (picked != null) {
        setState(() => _selectedFile = picked);
      }
    } catch (e) {
      debugPrint("Error picking image: $e");
    }
  }

  Future<void> _submitRequest() async {
    // 至少需要选择一个新时间，或者填写备注
    if (_reqIn == null && _reqOut == null && _remarksCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please modify a time or add remarks.")));
      return;
    }

    final String requestedInStr = _reqIn?.format(context) ?? widget.originalIn;
    final String requestedOutStr = _reqOut?.format(context) ?? widget.originalOut;

    setState(() => _isLoading = true);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final dateStr = DateFormat('yyyy-MM-dd').format(widget.date);

    try {
      String? attachmentUrl;
      // 上传图片证据
      if (_selectedFile != null) {
        final String fileName = '${DateTime.now().millisecondsSinceEpoch}_correction_${user.uid}.jpg';
        final Reference storageRef = FirebaseStorage.instance
            .ref()
            .child('correction_evidence')
            .child(user.uid)
            .child(fileName);
        
        await storageRef.putFile(File(_selectedFile!.path));
        attachmentUrl = await storageRef.getDownloadURL();
      }

      // 🛑 核心修改：写入独立的 'attendance_corrections' 集合
      // 避免与 Admin 端的 "Profile Edit Requests" (edit_requests) 冲突
      await FirebaseFirestore.instance.collection('attendance_corrections').add({
        'uid': user.uid,
        'email': user.email,
        'type': 'attendance_correction', // 明确类型
        'attendanceId': widget.attendanceId, // 关联原始考勤记录ID
        'targetDate': dateStr,
        'originalIn': widget.originalIn,
        'originalOut': widget.originalOut,
        'requestedIn': requestedInStr,
        'requestedOut': requestedOutStr,
        'remarks': _remarksCtrl.text,
        'status': 'Pending', // 初始状态
        'createdAt': FieldValue.serverTimestamp(),
        'attachmentUrl': attachmentUrl,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Correction Request Submitted!"), backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateHeader = DateFormat('dd/MM/yyyy (EEEE)').format(widget.date);

    return Scaffold(
      appBar: AppBar(
        title: Text("Correct: $dateHeader", style: const TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF15438c), 
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 显示原始数据
            const Text("Original Record", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(8)),
              child: Column(
                children: [
                  _buildRow("Time In", widget.originalIn),
                  const Divider(height: 20),
                  _buildRow("Time Out", widget.originalOut),
                ],
              ),
            ),
            
            const SizedBox(height: 30),

            // 2. 请求修改的数据
            const Text("Correction Request", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _buildTimePicker("New Time In", _reqIn, true)),
                const SizedBox(width: 20),
                Expanded(child: _buildTimePicker("New Time Out", _reqOut, false)),
              ],
            ),

            const SizedBox(height: 20),

            // 3. 备注
            const Text("Reason / Remarks", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 5),
            TextField(
              controller: _remarksCtrl,
              decoration: InputDecoration(
                hintText: "Why do you need this correction?",
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              maxLines: 2,
            ),

            const SizedBox(height: 20),

            // 4. 附件/证据
            const Text("Proof (Optional)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 8),
            
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: double.infinity,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.grey[100], 
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!, style: BorderStyle.solid),
                  image: _selectedFile != null 
                    ? DecorationImage(
                        image: FileImage(File(_selectedFile!.path)), 
                        fit: BoxFit.cover
                      ) 
                    : null
                ),
                child: _selectedFile == null 
                  ? const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo, size: 30, color: Colors.grey),
                        SizedBox(height: 4),
                        Text("Upload photo/screenshot", style: TextStyle(color: Colors.grey, fontSize: 12))
                      ],
                    )
                  : Stack(
                      children: [
                        Positioned(
                          top: 5, right: 5,
                          child: GestureDetector(
                            onTap: () => setState(() => _selectedFile = null),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                              child: const Icon(Icons.close, color: Colors.white, size: 16),
                            ),
                          ),
                        )
                      ],
                    ),
              ),
            ),

            const SizedBox(height: 40),

            // 5. 提交按钮
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _submitRequest,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C853), 
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _isLoading 
                  ? const CircularProgressIndicator(color: Colors.white) 
                  : const Text("SUBMIT REQUEST", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black54)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 16)),
      ],
    );
  }

  Widget _buildTimePicker(String label, TimeOfDay? time, bool isIn) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54)),
        const SizedBox(height: 5),
        GestureDetector(
          onTap: () => _selectTime(isIn),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white, 
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(8)
            ),
            child: Center(
              child: Text(
                time?.format(context) ?? "Select",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: time != null ? Colors.blue[800] : Colors.grey
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}