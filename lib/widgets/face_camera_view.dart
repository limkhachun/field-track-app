import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'; 
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:easy_localization/easy_localization.dart'; 
import 'package:path_provider/path_provider.dart'; // 📦 需要这个来保存下载的临时文件
import '../services/face_recognition_service.dart';

class FaceCameraView extends StatefulWidget {
  final String? referencePath; 

  const FaceCameraView({super.key, this.referencePath});

  @override
  State<FaceCameraView> createState() => _FaceCameraViewState();
}

class _FaceCameraViewState extends State<FaceCameraView> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;
  
  // UI State
  String _statusText = "";
  Color _statusColor = Colors.white;
  bool _isLoadingReference = true; // 🟢 新增：标记是否正在下载参考图
  
  // Logic Control
  late final FaceDetector _faceDetector;
  bool _isProcessing = false; 
  bool _isTakingPicture = false; 
  bool _hasCaptured = false; 

  // 倒计时控制
  DateTime? _firstCenteredTime; 

  final FaceRecognitionService _faceService = FaceRecognitionService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusText = 'camera.align'.tr(); 

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableClassification: true, 
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.15,
      ),
    );
    
    // 🟢 异步初始化：处理 URL 下载
    _downloadAndInitializeReference();
    _initializeCamera();
  }

  // 🟢 核心修复：如果是 URL，先下载到本地
  Future<void> _downloadAndInitializeReference() async {
    _faceService.initialize();
    
    if (widget.referencePath == null) {
      setState(() => _isLoadingReference = false);
      return;
    }

    String path = widget.referencePath!;

    // 检查是否是网络链接
    if (path.startsWith('http') || path.startsWith('https')) {
      try {
        setState(() {
          _statusText = "Loading Profile..."; // 提示用户正在下载
          _isLoadingReference = true;
        });

        // 使用 HttpClient 下载图片 (不依赖额外第三方库)
        final request = await HttpClient().getUrl(Uri.parse(path));
        final response = await request.close();
        
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/temp_ref_face.jpg');
          await file.writeAsBytes(bytes);
          
          // 使用下载后的本地路径
          _faceService.preloadReference(file.path);
        } else {
          debugPrint("Failed to download face reference: ${response.statusCode}");
          _statusText = "Profile Load Error";
        }
      } catch (e) {
        debugPrint("Error downloading reference: $e");
        _statusText = "Network Error";
      } finally {
        if (mounted) {
          setState(() {
            _isLoadingReference = false;
            if (_statusText == "Loading Profile...") {
              _statusText = 'camera.align'.tr();
            }
          });
        }
      }
    } else {
      // 如果本来就是本地路径，直接加载
      _faceService.preloadReference(path);
      setState(() => _isLoadingReference = false);
    }
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
    }
  }

  Future<void> _processImage(CameraImage image) async {
    // 如果参考图还没下载好，不要开始识别
    if (_isLoadingReference || _isProcessing || _isTakingPicture || _hasCaptured || !mounted || _controller == null) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final faces = await _faceDetector.processImage(inputImage);
      
      if (!mounted || _isTakingPicture || _hasCaptured) {
        _isProcessing = false;
        return;
      }

      if (faces.isEmpty) {
        _updateUI(status: 'camera.no_face'.tr(), color: Colors.red);
        _firstCenteredTime = null; 
      } else {
        final face = faces.first;
        
        bool isCentered = _isFaceCentered(face, image.width, image.height);

        if (!isCentered) {
           _updateUI(status: 'camera.center_face'.tr(), color: Colors.orange);
           _firstCenteredTime = null; 
        } else {
          // 进入中心，开始计时
          if (_firstCenteredTime == null) {
            _firstCenteredTime = DateTime.now();
            _updateUI(status: 'camera.hold_still'.tr(), color: Colors.green);
          } else {
            final duration = DateTime.now().difference(_firstCenteredTime!);
            // 持续 1 秒后自动拍照
            if (duration.inMilliseconds > 1000) {
               _updateUI(status: 'camera.verifying'.tr(), color: Colors.blue);
               await _autoCaptureAndVerify();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Face detection error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _autoCaptureAndVerify() async {
    if (_isTakingPicture || _hasCaptured) return;
    
    setState(() {
      _isTakingPicture = true;
      _hasCaptured = true; 
      _statusText = 'camera.processing'.tr();
      _statusColor = Colors.blue;
    });

    try {
      await _controller!.stopImageStream();
      await Future.delayed(const Duration(milliseconds: 100)); 

      final XFile image = await _controller!.takePicture();
      
      if (widget.referencePath == null) {
        if (mounted) Navigator.pop(context, image);
        return;
      }

      VerifyResult result = await _faceService.compareFacesDetailed(widget.referencePath!, image);

      if (!mounted) return;

      if (result.verified) {
        Navigator.pop(context, image);
      } else {
        setState(() {
          _statusText = 'camera.failed'.tr();
          _statusColor = Colors.red;
        });
        await _showRetryDialog();
      }

    } catch (e) {
      debugPrint('System Error: $e');
      _resetCamera();
    }
  }

  Future<void> _showRetryDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('camera.failed'.tr()),
        content: const Text("Face verification failed. Please try again."),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _resetCamera();
            },
            child: const Text('Retry'),
          )
        ],
      ),
    );
  }

  void _resetCamera() async {
    if (!mounted) return;
    setState(() {
      _isTakingPicture = false;
      _hasCaptured = false;
      _firstCenteredTime = null; 
      _statusText = 'camera.align'.tr();
      _statusColor = Colors.white;
    });
    
    try {
      if (_controller != null) {
        await _controller!.resumePreview(); 
        if (!_controller!.value.isStreamingImages) {
          await _controller!.startImageStream(_processImage);
        }
      }
    } catch (e) {
      debugPrint("Reset Error: $e");
    }
  }

  void _updateUI({required String status, required Color color}) {
    if (_statusText != status || _statusColor != color) {
      if (mounted) {
        setState(() {
          _statusText = status;
          _statusColor = color;
        });
      }
    }
  }

  bool _isFaceCentered(Face face, int imgWidth, int imgHeight) {
    double centerX = face.boundingBox.center.dx;
    double centerY = face.boundingBox.center.dy;
    bool xOk = centerX > imgWidth * 0.2 && centerX < imgWidth * 0.8;
    bool yOk = centerY > imgHeight * 0.2 && centerY < imgHeight * 0.8;
    return xOk && yOk;
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

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final size = MediaQuery.of(context).size;
    final double rectWidth = size.width * 0.75;
    final double rectHeight = size.width * 1.0; 

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('camera.title_verify'.tr()),
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
                
                // 🟢 1. 绿色长方形框
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

                // 提示文字
                Positioned(
                  top: size.height * 0.1, 
                  left: 0, right: 0,
                  child: Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _statusColor, 
                      fontSize: 22, 
                      fontWeight: FontWeight.bold,
                      shadows: const [Shadow(color: Colors.black, blurRadius: 4)]
                    ),
                  ),
                ),
                
                // Processing Overlay (下载中 或 处理中)
                if (_hasCaptured || _isLoadingReference)
                  Container(
                    color: Colors.black54,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(color: Colors.white),
                          const SizedBox(height: 20),
                          Text(_statusText, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  )
              ],
            ),
          ),
        ],
      ),
    );
  }
}