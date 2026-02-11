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

  // --- UI Status ---
  String _statusText = "";
  Color _statusColor = Colors.white;
  bool _isLoadingReference = true;
  
  // --- Flow Control ---
  // 0: Find Face, 1: Blink (Liveness), 2: Verifying/Capturing
  int _step = 0; 
  bool _eyesPreviouslyClosed = false; 
  bool _hasCaptured = false; 

  // --- Logic ---
  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  final FaceRecognitionService _faceService = FaceRecognitionService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusText = 'camera.align'.tr(); 

    // 1. Initialize Face Detector
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate, // Consider 'fast' if still slow on older devices
        enableLandmarks: true,
        enableClassification: true, 
        enableContours: false,
        minFaceSize: 0.15, // Keep at 0.15 to avoid detecting faces too far away
      ),
    );

    // 2. Parallel Init: Download Ref & Start Camera
    _downloadAndInitializeReference();
    _initializeCamera();
  }

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

  // --- Real-time Processing ---
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
        
        // 🟢 RELAXED CENTERING LOGIC
        bool isCentered = _isFaceCentered(face, image.width, image.height);
        
        if (!isCentered) {
          // If the face is way off, ask to center.
          // But now "Centered" allows a much wider area.
          _updateUI(status: 'camera.center_face'.tr(), color: Colors.orange, step: 0);
          _eyesPreviouslyClosed = false;
        } else {
          // 2. Face is valid, check liveness
          if (_step == 0) {
            _updateUI(status: "Please Blink\nSila Kelip Mata", color: Colors.yellowAccent, step: 1);
          } else if (_step == 1) {
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

  // 🟢 Modified Check: Relaxed Boundaries
  bool _isFaceCentered(Face face, int imgWidth, int imgHeight) {
    double centerX = face.boundingBox.center.dx;
    double centerY = face.boundingBox.center.dy;

    // Previous Strict: 0.2 - 0.8
    // New Relaxed: 0.1 - 0.9 (Allow face almost anywhere except edges)
    // Also ensuring face is large enough (width > 15% of image)
    
    bool xOk = centerX > imgWidth * 0.1 && centerX < imgWidth * 0.9;
    bool yOk = centerY > imgHeight * 0.1 && centerY < imgHeight * 0.9;
    
    // Optional: Ensure face isn't too small (too far away)
    // bool sizeOk = face.boundingBox.width > imgWidth * 0.25; 

    return xOk && yOk; // && sizeOk;
  }

  void _checkBlinkLiveness(Face face) {
    final leftOpen = face.leftEyeOpenProbability;
    final rightOpen = face.rightEyeOpenProbability;

    if (leftOpen == null || rightOpen == null) return;

    // Thresholds: < 0.2 Closed, > 0.5 Open (Lowered open threshold for faster detection)
    bool isClosed = (leftOpen < 0.2 && rightOpen < 0.2);
    bool isOpen = (leftOpen > 0.5 && rightOpen > 0.5);

    if (isClosed) {
      _eyesPreviouslyClosed = true; 
    } else if (isOpen && _eyesPreviouslyClosed) {
      _captureAndVerify();
    }
  }

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
        content: const Text("Face mismatch. Please try again in better lighting."),
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
      await _controller!.startImageStream(_processImage);
    }
  }

  void _updateUI({required String status, required Color color, required int step}) {
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

  InputImage? _convertCameraImage(CameraImage image) {
    if (_controller == null) return null;
    try {
      final camera = _controller!.description;
      final sensorOrientation = camera.sensorOrientation;
      
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
    final double rectWidth = size.width * 0.8;
    final double rectHeight = size.width * 1.1; 

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
                      borderRadius: BorderRadius.circular(20), 
                    ),
                  ),
                ),
              ],
            ),
          ),

          Center(
            child: Container(
              width: rectWidth,
              height: rectHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _step == 1 ? Colors.yellowAccent : (_step == 2 ? Colors.greenAccent : Colors.white), 
                  width: 4
                ),
              ),
            ),
          ),

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