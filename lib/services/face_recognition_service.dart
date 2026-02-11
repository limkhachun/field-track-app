import 'dart:io';
import 'dart:math';
// 🟢 [修复1] 删除多余的 import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceRecognitionService {
  Interpreter? _interpreter;
  late final FaceDetector _faceDetector;

  static const int inputSize = 112;
  static const int embeddingSize = 192;
  double threshold = 1.0; 

  // 缓存底片的中间数据，用于 Debug 对比
  List<double>? _cachedRefEmbedding;
  List<double>? _debugRefInputTensor; // 调试用：底片的归一化数据
  int? _debugRefCenterPixel;          // 调试用：底片中心点原始像素值

  static final FaceRecognitionService _instance = FaceRecognitionService._internal();
  factory FaceRecognitionService() => _instance;
  
  FaceRecognitionService._internal() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true, 
        enableClassification: false,
      ),
    );
  }

  Future<void> initialize({
    String assetPath = 'assets/models/mobilefacenet.tflite',
    int threads = 4,
  }) async {
    try {
      final options = InterpreterOptions()..threads = threads;
      _interpreter = await Interpreter.fromAsset(assetPath, options: options);
      _interpreter!.allocateTensors();
      
      var inputShape = _interpreter!.getInputTensor(0).shape;
      var outputShape = _interpreter!.getOutputTensor(0).shape;
      
      debugPrint("✅ Model Loaded.");
      debugPrint("ℹ️ Model Input: $inputShape");
      debugPrint("ℹ️ Model Output: $outputShape");
      
    } catch (e) {
      debugPrint("❌ Model load error: $e");
    }
    
  }
void clearReference() {
    _cachedRefEmbedding = null;
    _debugRefInputTensor = null;
    _debugRefCenterPixel = null;
  }
  // ==========================================
  //  核心逻辑
  // ==========================================

  Future<bool> preloadReference(String path) async {
    debugPrint("\n🔵 [STEP 1] Loading Reference...");
    final file = File(path);
    if (!file.existsSync()) return false;

    // 1. 加载
    img.Image? rawImage = await _loadImage(file, "REF");
    if (rawImage == null) return false;

    // 2. 裁剪
    img.Image? faceImage = await _cropSquareFace(rawImage, label: "REF");
    faceImage ??= rawImage; // 降级

    // 3. 计算 (会顺便缓存调试数据)
    var result = await _calculateEmbedding(faceImage, label: "REF");
    if (result == null) return false;

    _cachedRefEmbedding = result.embedding;
    _debugRefInputTensor = result.inputTensor;
    _debugRefCenterPixel = result.centerPixel;

    return true;
  }

  Future<VerifyResult> compareFacesDetailed(String refPath, XFile photo) async {
    debugPrint("\n🟠 [STEP 2] Loading Probe...");
    
    // 确保底片已加载
    if (_cachedRefEmbedding == null) {
      await preloadReference(refPath);
    }

    final photoFile = File(photo.path);
    
    // 1. 加载
    img.Image? rawProbe = await _loadImage(photoFile, "PROBE");
    if (rawProbe == null) return VerifyResult(false, 999.0);

    // 2. 裁剪
    img.Image? probeImage = await _cropSquareFace(rawProbe, label: "PROBE");
    probeImage ??= rawProbe;

    // 3. 计算
    var result = await _calculateEmbedding(probeImage, label: "PROBE");
    if (result == null || _cachedRefEmbedding == null) return VerifyResult(false, 999.0);

    // ===========================================
    // 🚨 终极对比：逐个环节检查差异
    // ===========================================
    debugPrint("\n🔍 ========= DEBUG REPORT =========");
    
    // Check 1: 中心像素 (检查图片是否一致/旋转)
    debugPrint("1️⃣ Center Pixel (Raw RGB Hex):");
    debugPrint("   REF  : ${_debugRefCenterPixel?.toRadixString(16).toUpperCase()}");
    debugPrint("   PROBE: ${result.centerPixel.toRadixString(16).toUpperCase()}");
    
    // Check 2: 输入 Tensor 前5位 (检查归一化/BGR转换)
    debugPrint("2️⃣ Input Tensor (Normalized):");
    debugPrint("   REF  : ${_debugRefInputTensor?.sublist(0, 5)}");
    debugPrint("   PROBE: ${result.inputTensor.sublist(0, 5)}");

    // Check 3: 输出 Embedding 前5位 (检查模型推理)
    debugPrint("3️⃣ Output Embedding (Normalized):");
    debugPrint("   REF  : ${_cachedRefEmbedding?.sublist(0, 5)}");
    debugPrint("   PROBE: ${result.embedding.sublist(0, 5)}");

    // Check 4: 欧氏距离
    double distance = _euclideanDistance(_cachedRefEmbedding!, result.embedding);
    debugPrint("4️⃣ Euclidean Distance: $distance");
    debugPrint("🔍 ===============================\n");

    return VerifyResult(distance <= threshold, distance);
  }

  // ==========================================
  //  内部处理函数
  // ==========================================

  Future<img.Image?> _loadImage(File file, String label) async {
    try {
      final bytes = await file.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return null;
      
      debugPrint("ℹ️ [$label] Raw Size: ${image.width}x${image.height}");
      
      image = img.bakeOrientation(image); // 修复旋转
      
      if (image.numChannels != 3) {
        image = image.convert(numChannels: 3);
      }
      return image;
    } catch (e) {
      debugPrint("❌ [$label] Load error: $e");
      return null;
    }
  }

  Future<img.Image?> _cropSquareFace(img.Image originalImage, {required String label}) async {
    try {
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/temp_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await tempFile.writeAsBytes(img.encodeJpg(originalImage));
      final inputImage = InputImage.fromFile(tempFile);

      final faces = await _faceDetector.processImage(inputImage);
      tempFile.delete().ignore();

      if (faces.isEmpty) {
        debugPrint("⚠️ [$label] No faces detected.");
        return null;
      }

      Face face = faces.reduce((a, b) => (a.boundingBox.width * a.boundingBox.height) > (b.boundingBox.width * b.boundingBox.height) ? a : b);
      final box = face.boundingBox;

      debugPrint("📐 [$label] Face Box: ${box.left}, ${box.top}, ${box.width}x${box.height}");

      int x = box.left.toInt();
      int y = box.top.toInt();
      int w = box.width.toInt();
      int h = box.height.toInt();
      
      int size = (max(w, h) * 1.2).toInt(); 
      if (size > originalImage.width) size = originalImage.width;
      if (size > originalImage.height) size = originalImage.height;

      int centerX = x + w ~/ 2;
      int centerY = y + h ~/ 2;
      int newX = (centerX - size ~/ 2).clamp(0, originalImage.width - size);
      int newY = (centerY - size ~/ 2).clamp(0, originalImage.height - size);
      
      return img.copyCrop(originalImage, x: newX, y: newY, width: size, height: size);
    } catch (e) {
      debugPrint("❌ [$label] Crop error: $e");
      return null;
    }
  }

  Future<_InferenceResult?> _calculateEmbedding(img.Image src, {required String label}) async {
    if (_interpreter == null) return null;

    // 1. Resize
    img.Image resized = img.copyResize(src, width: inputSize, height: inputSize);
    
    // 🟢 [修复2] Pixel 无法直接转 int，需要手动提取 RGB 拼成一个整数
    var p = resized.getPixel(inputSize ~/ 2, inputSize ~/ 2);
    int centerPixel = (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();

    // 3. 归一化 (使用 RGB 尝试，如果失败再切回 BGR)
    Float32List inputBytes = Float32List(inputSize * inputSize * 3);
    int pixelIndex = 0;
    
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        var pixel = resized.getPixel(x, y);
        
        // 提取 RGB
        double r = pixel.r.toDouble();
        double g = pixel.g.toDouble();
        double b = pixel.b.toDouble();

        inputBytes[pixelIndex++] = (r - 127.5) / 128.0;
        inputBytes[pixelIndex++] = (g - 127.5) / 128.0;
        inputBytes[pixelIndex++] = (b - 127.5) / 128.0;
      }
    }

    Object input = inputBytes.reshape([1, inputSize, inputSize, 3]);
    List<List<double>> output = List.generate(1, (_) => List.filled(embeddingSize, 0.0));
    
    try {
      _interpreter!.run(input, output);
    } catch (e) {
      debugPrint("❌ [$label] Run error: $e");
      return null;
    }

    List<double> finalEmb = _l2Normalize(output[0]);
    
    return _InferenceResult(finalEmb, inputBytes, centerPixel);
  }

  List<double> _l2Normalize(List<double> v) {
    double sum = 0.0;
    // 🟢 [修复3] 为 for 循环添加大括号
    for (var x in v) {
      sum += x * x;
    }
    final norm = sqrt(sum);
    if (norm == 0.0) return v;
    return v.map((e) => e / norm).toList();
  }

  double _euclideanDistance(List<double> a, List<double> b) {
    double sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      double diff = a[i] - b[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }
}

// 辅助类：存储中间结果
class _InferenceResult {
  final List<double> embedding;
  final List<double> inputTensor; // 归一化后的数据前几位
  final int centerPixel;          // 中心像素原始值
  _InferenceResult(this.embedding, this.inputTensor, this.centerPixel);
}

class VerifyResult {
  final bool verified;
  final double score;
  VerifyResult(this.verified, this.score);
}