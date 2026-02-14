import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart'; 
import 'package:firebase_auth/firebase_auth.dart'; 
import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:firebase_storage/firebase_storage.dart'; 
import 'package:image/image.dart' as img; 
import 'package:gal/gal.dart'; 
import 'package:path_provider/path_provider.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;
  Timer? _timer;
  
  String _address = "Locating..."; 
  String _staffName = "Loading..."; 
  String _dateTimeStr = ""; 
  bool _isProcessing = false; 

  bool get _isReady => 
      _controller != null && 
      _controller!.value.isInitialized &&
      _address != "Locating..." && 
      _address != "Location Error" && 
      _staffName != "Loading..." && 
      _staffName != "Unknown Staff" &&
      !_isProcessing;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _fetchStaffName(); 
    _initLocationAndAddress(); 
    _startClock(); 
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final backCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back, 
      orElse: () => cameras.first
    );
    _controller = CameraController(backCamera, ResolutionPreset.high, enableAudio: false);
    _initializeControllerFuture = _controller!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _fetchStaffName() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
        if (mounted && q.docs.isNotEmpty) {
          final data = q.docs.first.data();
          setState(() {
            if (data['personal'] != null && data['personal']['name'] != null) {
              _staffName = data['personal']['name'];
            } else {
              _staffName = data['name'] ?? "Staff";
            }
          });
        } else {
          setState(() => _staffName = "Unknown Staff");
        }
      } catch (e) {
        setState(() => _staffName = "Unknown Staff");
      }
    }
  }

  Future<void> _initLocationAndAddress() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      List<Placemark> placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        if (mounted) {
          setState(() {
            String fullAddress = [
              p.street, p.subLocality, p.locality, p.postalCode, p.administrativeArea
            ].where((e) => e != null && e.toString().isNotEmpty).join(', ');
            if (fullAddress.isEmpty) fullAddress = "Unknown Address";
            _address = fullAddress; 
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _address = "Location Error");
    }
  }

  void _startClock() {
    _updateTime(); 
    _timer = Timer.periodic(const Duration(seconds: 1), (t) => _updateTime());
  }

  void _updateTime() {
    if (mounted) setState(() => _dateTimeStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()));
  }

  int _estimateTextWidth(String text) {
    int width = 0;
    for (int i = 0; i < text.length; i++) {
      String char = text[i];
      if (char == ' ' || char == ':' || char == ',' || char == '.' || char == 'i' || char == 'l' || char == '1') {
        width += 12; 
      } else if (RegExp(r'[A-Z]').hasMatch(char) || RegExp(r'[0-9]').hasMatch(char)) {
        width += 32; 
      } else {
        width += 24; 
      }
    }
    return width;
  }

  List<String> _wrapText(String text, int maxChars) {
    List<String> lines = [];
    List<String> words = text.split(' ');
    String currentLine = "";
    for (var word in words) {
      if ((currentLine + word).length > maxChars) {
        lines.add(currentLine.trim());
        currentLine = "$word ";
      } else {
        currentLine += "$word ";
      }
    }
    if (currentLine.isNotEmpty) lines.add(currentLine.trim());
    return lines;
  }

  void _drawOutlinedText(img.Image image, String text, int x, int y, img.BitmapFont font, {bool isYellow = false}) {
    final black = img.ColorRgba8(0, 0, 0, 255);
    const int offset = 3; 

    final offsets = [
      [-offset, -offset], [0, -offset], [offset, -offset],
      [-offset, 0],                     [offset, 0],
      [-offset, offset],  [0, offset],  [offset, offset]
    ];
    for (var o in offsets) {
      img.drawString(image, text, font: font, x: x + o[0], y: y + o[1], color: black);
    }
    
    final mainColor = isYellow ? img.ColorRgba8(255, 235, 59, 255) : img.ColorRgba8(255, 255, 255, 255);
    img.drawString(image, text, font: font, x: x, y: y, color: mainColor);
  }

  Future<File> _processImageWithWatermark(String inputPath) async {
    final Uint8List bytes = await File(inputPath).readAsBytes();
    img.Image? baseImage = img.decodeImage(bytes);
    if (baseImage == null) return File(inputPath);

    const int targetWidth = 1080;
    if (baseImage.width != targetWidth) {
      baseImage = img.copyResize(baseImage, width: targetWidth, interpolation: img.Interpolation.linear);
    }

    img.BitmapFont font = img.arial48; 

    const int marginRight = 40; 
    const int marginBottom = 250; 
    const int wrapChars = 38; 

    List<String> addressLines = _wrapText(_address, wrapChars);
    List<String> allLines = [_dateTimeStr, ...addressLines, "Staff: $_staffName"];
    
    int lineHeight = (font.lineHeight * 1.3).toInt(); 
    int contentHeight = allLines.length * lineHeight;

    int yStart = baseImage.height - contentHeight - marginBottom;
    
    for (int i = 0; i < allLines.length; i++) {
      String line = allLines[i];
      int textWidth = _estimateTextWidth(line);
      int x = baseImage.width - marginRight - textWidth;
      bool isStaff = (i == allLines.length - 1);
      _drawOutlinedText(baseImage, line, x, yStart + (i * lineHeight), font, isYellow: isStaff);
    }

    final directory = await getTemporaryDirectory();
    final String timestamp = DateFormat('yyyyMMddHHmmss').format(DateTime.now());
    final String cleanStaffName = _staffName.replaceAll(' ', '');
    final String fileName = "${cleanStaffName}_$timestamp.jpg";
    final String newPath = '${directory.path}/$fileName';
    
    final File newFile = File(newPath);
    await newFile.writeAsBytes(img.encodeJpg(baseImage, quality: 95));
    
    return newFile;
  }

  Future<void> _captureAndUpload() async {
    if (!_isReady) return;

    try {
      setState(() => _isProcessing = true);
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // 1. 拍照
      final XFile rawImage = await _controller!.takePicture();
      
      // 2. 烧录水印
      File watermarkedFile = await _processImageWithWatermark(rawImage.path);
      String fileName = watermarkedFile.path.split('/').last;

      // 3. 保存相册 (静默)
      try {
        await Gal.putImage(watermarkedFile.path, album: "FieldTrack");
      } catch (e) {
        // Silent catch
      }

      // 4. 上传 Firebase (静默)
      Reference storageRef = FirebaseStorage.instance.ref().child('accident_evidence').child(fileName);
      await storageRef.putFile(watermarkedFile);
      String downloadUrl = await storageRef.getDownloadURL();

      // 5. 记录 Firestore (静默)
      await FirebaseFirestore.instance.collection('evidence_logs').add({
        'uid': user.uid,
        'staffName': _staffName,
        'photoUrl': downloadUrl,
        'location': _address,
        'capturedAt': FieldValue.serverTimestamp(),
        'localTime': _dateTimeStr,
        'fileName': fileName,
        'type': 'accident_evidence'
      });

      // 不显示任何成功提示，直接结束

    } catch (e) {
      if (mounted) {
        // 只在出错时保留提示，避免用户不知道拍照失败
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  TextStyle _getOutlinedTextStyle({required double fontSize, FontWeight fontWeight = FontWeight.bold, Color color = Colors.white}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      shadows: const [
        Shadow(offset: Offset(-1, -1), color: Colors.black),
        Shadow(offset: Offset(1, -1), color: Colors.black),
        Shadow(offset: Offset(1, 1), color: Colors.black),
        Shadow(offset: Offset(-1, 1), color: Colors.black),
        Shadow(blurRadius: 2, color: Colors.black),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const double uniformFontSize = 15.0;
    const FontWeight uniformFontWeight = FontWeight.bold;

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              children: [
                SizedBox.expand(child: CameraPreview(_controller!)),
                
                // UI 预览水印
                Positioned(
                  bottom: 130, right: 15, left: 15, 
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end, 
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_dateTimeStr, style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight), textAlign: TextAlign.right),
                      const SizedBox(height: 4),
                      Text(_address, style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight), textAlign: TextAlign.right, maxLines: 4),
                      const SizedBox(height: 4),
                      Text("Staff: $_staffName", style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight, color: Colors.white), textAlign: TextAlign.right),
                    ],
                  ),
                ),
                
                // 拍照按钮
                Positioned(
                  bottom: 30, left: 0, right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: _isReady ? _captureAndUpload : null,
                      child: Container(
                        height: 80, width: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, 
                          border: Border.all(color: _isReady ? Colors.white : Colors.grey.withValues(alpha:0.5), width: 5),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.3), blurRadius: 10)]
                        ),
                        child: Center(
                          child: Container(
                            height: 64, width: 64,
                            decoration: BoxDecoration(color: _isReady ? Colors.white : Colors.transparent, shape: BoxShape.circle),
                            child: _isProcessing 
                              ? const CircularProgressIndicator(color: Colors.black)
                              : Center(child: _isReady ? null : const Icon(Icons.hourglass_empty, color: Colors.grey, size: 30)), 
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                Positioned(top: 50, right: 20, child: GestureDetector(onTap: () => Navigator.pop(context), child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black.withValues(alpha:0.4), shape: BoxShape.circle), child: const Icon(Icons.close, color: Colors.white, size: 24)))),
              ],
            );
          }
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        },
      ),
    );
  }
}