import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path_provider/path_provider.dart';
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

  // --- UI 状态 ---
  String _statusText = "";
  Color _statusColor = Colors.white;
  bool _isLoadingReference = true;
  
  // --- 流程控制状态 ---
  // 0: 寻找人脸, 1: 请眨眼(活体), 2: 正在验证/拍照
  int _step = 0; 
  bool _eyesPreviouslyClosed = false; // 记录上一帧是否闭眼
  bool _hasCaptured = false; // 锁定防止重复提交

  // --- 逻辑对象 ---
  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  final FaceRecognitionService _faceService = FaceRecognitionService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusText = 'camera.align'.tr(); 

    // 1. 初始化人脸检测器 (必须开启 classification 以检测眨眼)
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableClassification: true, // 🟢 关键：必须为 true
        enableContours: false,
        minFaceSize: 0.15,
      ),
    );

    // 2. 并行初始化：下载参考图 & 启动相机
    _downloadAndInitializeReference();
    _initializeCamera();
  }

  // 下载参考图片（处理网络图片）
  Future<void> _downloadAndInitializeReference() async {
    await _faceService.initialize();
    
    if (widget.referencePath == null) {
      if (mounted) setState(() => _isLoadingReference = false);
      return;
    }

    String path = widget.referencePath!;

    if (path.startsWith('http') || path.startsWith('https')) {
      try {
        if (mounted) setState(() => _statusText = "Loading Profile...");
        
        final request = await HttpClient().getUrl(Uri.parse(path));
        final response = await request.close();
        
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/temp_ref_face.jpg');
          await file.writeAsBytes(bytes);
          
          await _faceService.preloadReference(file.path);
        }
      } catch (e) {
        debugPrint("Ref download error: $e");
      }
    } else {
      await _faceService.preloadReference(path);
    }

    if (mounted) {
      setState(() {
        _isLoadingReference = false;
        _statusText = 'camera.align'.tr();
      });
    }
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.high, 
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    await _controller!.initialize();
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    if (!mounted) return;
    
    setState(() => _isInitialized = true);
    _controller!.startImageStream(_processImage);
  }

  // --- 实时图像处理 ---
  Future<void> _processImage(CameraImage image) async {
    if (_isLoadingReference || _isProcessing || _hasCaptured || !mounted) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        if (_step != 0 && mounted) {
          _updateUI(status: 'camera.no_face'.tr(), color: Colors.red, step: 0);
          _eyesPreviouslyClosed = false;
        }
      } else {
        final face = faces.first;
        
        // 1. 检查是否居中 (可选)
        bool isCentered = _isFaceCentered(face, image.width, image.height);
        if (!isCentered) {
          _updateUI(status: 'camera.center_face'.tr(), color: Colors.orange, step: 0);
          _eyesPreviouslyClosed = false;
        } else {
          // 2. 居中后，进入活体检测流程
          if (_step == 0) {
            // 提示眨眼
            _updateUI(status: "请眨眼\nPlease BLINK", color: Colors.yellowAccent, step: 1);
          } else if (_step == 1) {
            // 检测眨眼动作
            _checkBlinkLiveness(face);
          }
        }
      }
    } catch (e) {
      debugPrint("Process error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  // --- 🟢 活体检测核心逻辑 ---
  void _checkBlinkLiveness(Face face) {
    final leftOpen = face.leftEyeOpenProbability;
    final rightOpen = face.rightEyeOpenProbability;

    if (leftOpen == null || rightOpen == null) return;

    // 阈值：< 0.2 闭眼，> 0.8 睁眼
    bool isClosed = (leftOpen < 0.2 && rightOpen < 0.2);
    bool isOpen = (leftOpen > 0.8 && rightOpen > 0.8);

    if (isClosed) {
      _eyesPreviouslyClosed = true; // 捕捉到闭眼
    } else if (isOpen && _eyesPreviouslyClosed) {
      // 捕捉到 闭眼 -> 睁眼，通过！
      _captureAndVerify();
    }
  }

  // --- 拍照并验证 ---
  Future<void> _captureAndVerify() async {
    if (_hasCaptured) return;
    
    setState(() {
      _hasCaptured = true;
      _step = 2;
      _statusText = 'camera.verifying'.tr();
      _statusColor = Colors.blue;
    });

    try {
      await _controller!.stopImageStream();
      
      // 拍照
      final XFile image = await _controller!.takePicture();

      // 如果没有参考图（比如是录入模式），直接返回
      if (widget.referencePath == null) {
        if (mounted) Navigator.pop(context, image);
        return;
      }

      // 进行比对
      // 注意：这里假设您的 FaceService 有 compareFacesDetailed 方法
      // 如果没有，请替换为您现有的比对逻辑
      VerifyResult result = await _faceService.compareFacesDetailed(widget.referencePath!, image);

      if (!mounted) return;

      if (result.verified) {
        // 验证成功
        Navigator.pop(context, image);
      } else {
        // 验证失败
        setState(() {
          _statusText = 'camera.failed'.tr();
          _statusColor = Colors.red;
        });
        await _showRetryDialog();
      }

    } catch (e) {
      debugPrint("Capture error: $e");
      _resetCamera();
    }
  }

  Future<void> _showRetryDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('camera.failed'.tr()),
        content: const Text("Face verification failed. Ensure good lighting."),
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
      _hasCaptured = false;
      _step = 0;
      _eyesPreviouslyClosed = false;
      _statusText = 'camera.align'.tr();
      _statusColor = Colors.white;
    });
    
    if (_controller != null) {
      // 重新启动流
      await _controller!.startImageStream(_processImage);
    }
  }

  void _updateUI({required String status, required Color color, required int step}) {
    // 只有状态改变时才刷新 UI，减少 rebuild
    if (_statusText != status || _statusColor != color || _step != step) {
      if (mounted) {
        setState(() {
          _statusText = status;
          _statusColor = color;
          _step = step;
        });
      }
    }
  }

  bool _isFaceCentered(Face face, int imgWidth, int imgHeight) {
    double centerX = face.boundingBox.center.dx;
    double centerY = face.boundingBox.center.dy;
    // 宽松一点的中心判定
    return centerX > imgWidth * 0.2 && centerX < imgWidth * 0.8 &&
           centerY > imgHeight * 0.2 && centerY < imgHeight * 0.8;
  }

  InputImage? _convertCameraImage(CameraImage image) {
    if (_controller == null) return null;
    try {
      final camera = _controller!.description;
      final sensorOrientation = camera.sensorOrientation;
      
      // 处理旋转 (简略版，涵盖大多数情况)
      InputImageRotation rotation = InputImageRotation.rotation0deg;
      if (Platform.isAndroid) {
        rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation270deg;
      } else if (Platform.isIOS) {
        rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
      }

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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _faceDetector.close();
    _controller?.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
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
    // 🟢 定义长方形取景框尺寸
    final double rectWidth = size.width * 0.8;
    final double rectHeight = size.width * 1.1; // 稍微高一点的长方形

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('camera.title_verify'.tr()),
        backgroundColor: const Color(0xFF15438c),
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          
          // 🟢 遮罩层 + 长方形透明框
          ColorFiltered(
            colorFilter: ColorFilter.mode(Colors.black.withValues(alpha:0.5), BlendMode.srcOut),
            child: Stack(
              children: [
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.transparent,
                    backgroundBlendMode: BlendMode.dstOut,
                  ),
                ),
                Center(
                  child: Container(
                    width: rectWidth,
                    height: rectHeight,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      // 长方形圆角
                      borderRadius: BorderRadius.circular(20), 
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 🟢 边框高亮 (颜色随状态变化)
          Center(
            child: Container(
              width: rectWidth,
              height: rectHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  // 1:黄色(眨眼检测中), 2:绿色(通过), 0:白色(未检测)
                  color: _step == 1 ? Colors.yellowAccent : (_step == 2 ? Colors.greenAccent : Colors.white), 
                  width: 4
                ),
              ),
            ),
          ),

          // 提示文字
          Positioned(
            bottom: size.height * 0.15, 
            left: 20, right: 20,
            child: Column(
              children: [
                if (_step == 1)
                  const Icon(Icons.remove_red_eye, color: Colors.yellowAccent, size: 40),
                const SizedBox(height: 10),
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _statusColor, 
                    fontSize: 22, 
                    fontWeight: FontWeight.bold,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 4)]
                  ),
                ),
              ],
            ),
          ),

          // Loading Overlay
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
    );
  }
}