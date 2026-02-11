import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:easy_localization/easy_localization.dart'; 
import '../services/face_recognition_service.dart';

class CustomProfileCamera extends StatefulWidget {
  final String? referencePath; 

  const CustomProfileCamera({super.key, this.referencePath});

  @override
  State<CustomProfileCamera> createState() => _CustomProfileCameraState();
}

class _CustomProfileCameraState extends State<CustomProfileCamera> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;
  
  // UI State
  String _statusText = "";
  Color _statusColor = Colors.white;
  
  // Logic Control
  late final FaceDetector _faceDetector;
  bool _isProcessing = false; 
  bool _isTakingPicture = false; 
  bool _faceDetected = false; // 用于控制按钮是否可用

  final FaceRecognitionService _faceService = FaceRecognitionService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusText = 'camera.align'.tr(); 
    
    _faceService.clearReference();
    if (widget.referencePath != null) {
      _faceService.preloadReference(widget.referencePath!);
    }
    
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableClassification: true, 
        enableLandmarks: true,      
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.15, 
      ),
    );
    
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _faceDetector.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        frontCamera,
        ResolutionPreset.medium, 
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();
      if (!mounted) return;

      setState(() => _isInitialized = true);
      await _controller!.startImageStream(_processImage);
    } catch (e) {
      debugPrint('Camera initialization error: $e');
      _showErrorDialog(e.toString());
    }
  }

  Future<void> _processImage(CameraImage image) async {
    // 仅做检测提示，不自动拍照
    if (_isProcessing || _isTakingPicture || !mounted || _controller == null) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final faces = await _faceDetector.processImage(inputImage);
      
      if (!mounted) {
        _isProcessing = false;
        return;
      }

      if (faces.isEmpty) {
        _updateUI(status: 'camera.no_face'.tr(), color: Colors.red, hasFace: false);
      } else {
        // 只要检测到人脸，就允许拍照，仅做提示
        final face = faces.first;
        bool isCentered = _isFaceCentered(face, image.width, image.height);
        
        if (!isCentered) {
           _updateUI(status: 'camera.center_face'.tr(), color: Colors.orange, hasFace: true);
        } else {
           _updateUI(status: 'Ready to Capture', color: Colors.green, hasFace: true);
        }
      }
    } catch (e) {
      debugPrint('Face detection error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // 🔵 手动拍照逻辑
  Future<void> _manualCapture() async {
    if (_controller == null || _isTakingPicture) return;
    
    setState(() {
      _isTakingPicture = true;
      _statusText = 'camera.processing'.tr();
    });

    try {
      await _controller!.stopImageStream();
      
      final XFile image = await _controller!.takePicture();
      
      if (widget.referencePath != null) {
        await _performVerification(image);
      } else {
        if (!mounted) return;
        _showCaptureDialog(image);
      }

    } catch (e) {
      debugPrint('Capture error: $e');
      _resetCameraState();
    }
  }

  Future<void> _performVerification(XFile image) async {
    setState(() => _statusText = 'camera.verifying'.tr());

    try {
      final result = await _faceService.compareFacesDetailed(widget.referencePath!, image);
      if (!mounted) return;

      if (result.verified) {
        Navigator.pop(context, image);
      } else {
        _showFailureDialog();
      }
    } catch (e) {
       _showErrorDialog(e.toString());
       _resetCameraState();
    }
  }

  void _resetCameraState() async {
     if (!mounted) return;
     setState(() {
        _isTakingPicture = false;
        _statusText = 'camera.align'.tr();
        _statusColor = Colors.white;
      });
      if (_controller != null && !_controller!.value.isStreamingImages) {
         await _controller!.startImageStream(_processImage);
      }
  }

  InputImage? _convertCameraImage(CameraImage image) {
    if (_controller == null) return null;
    try {
      final camera = _controller!.description;
      final sensorOrientation = camera.sensorOrientation;
      final rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
      final format = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;

      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  bool _isFaceCentered(Face face, int imgWidth, int imgHeight) {
    double centerX = face.boundingBox.center.dx;
    double centerY = face.boundingBox.center.dy;
    // 稍微放宽一点范围，避免太难对准
    bool xOk = centerX > imgWidth * 0.2 && centerX < imgWidth * 0.8;
    bool yOk = centerY > imgHeight * 0.2 && centerY < imgHeight * 0.8;
    return xOk && yOk;
  }

  void _updateUI({required String status, required Color color, required bool hasFace}) {
    // 减少 setState 频率
    if (_statusText != status || _statusColor != color || _faceDetected != hasFace) {
      if (mounted) {
        setState(() {
          _statusText = status;
          _statusColor = color;
          _faceDetected = hasFace;
        });
      }
    }
  }

  // --- Dialogs ---

  void _showCaptureDialog(XFile image) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('camera.success'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(image.path), height: 200, fit: BoxFit.cover),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _resetCameraState();
            },
            child: const Text('Retake', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context, image);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF15438c)),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showFailureDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.red), SizedBox(width: 8), Text("Failed")]),
        content: Text('camera.failed'.tr()),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _resetCameraState();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            }, 
            child: const Text('Exit')
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final size = MediaQuery.of(context).size;
    // 计算中间绿色框的尺寸
    final double rectWidth = size.width * 0.75;
    final double rectHeight = size.width * 1.0; // 4:3 比例近似人脸

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.referencePath == null ? 'camera.title_register'.tr() : 'camera.title_verify'.tr()),
        backgroundColor: const Color(0xFF15438c),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(_controller!),
                
                // 🟢 1. 绿色长方形框 (覆盖层)
                Center(
                  child: Container(
                    width: rectWidth,
                    height: rectHeight,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.greenAccent, width: 3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),

                // 状态提示文字 (位于框上方)
                Positioned(
                  top: size.height * 0.1, 
                  left: 0, 
                  right: 0,
                  child: Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _statusColor, 
                      fontSize: 20, 
                      fontWeight: FontWeight.bold,
                      shadows: const [Shadow(color: Colors.black, blurRadius: 4)]
                    ),
                  ),
                ),

                // Processing Overlay
                 if (_isTakingPicture)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          
          // 🔵 2. 底部手动拍照区域
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: GestureDetector(
                onTap: _faceDetected ? _manualCapture : null, // 只有检测到人脸时才能点
                child: Container(
                  height: 80,
                  width: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    color: _faceDetected ? Colors.white : Colors.grey, // 灰色表示不可用
                  ),
                  child: _faceDetected 
                    ? const Icon(Icons.camera_alt, color: Colors.black, size: 40)
                    : const Icon(Icons.face_retouching_off, color: Colors.black54, size: 40),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}