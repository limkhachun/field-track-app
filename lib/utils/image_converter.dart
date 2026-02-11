import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
class ImageConverter {
  // 将 CameraImage (YUV420) 转换为 img.Image (RGB)
  static img.Image? convertYUV420ToImage(CameraImage image) {
    try {
      final int width = image.width;
      final int height = image.height;
      
      // 创建目标图片
      var imgBuffer = img.Image(width: width, height: height); // v4 语法

      // YUV420 数据平面
      final int uvRowStride = image.planes[1].bytesPerRow;
      final int? uvPixelStride = image.planes[1].bytesPerPixel;

      // 遍历像素 (为了性能，这是一个耗时操作)
      // 在 Dart 中做双重循环处理 640x480 的图片大约需要 50-100ms
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int uvIndex = (uvPixelStride! * (x / 2).floor()) + (uvRowStride * (y / 2).floor());
          final int index = y * width + x;

          final yp = image.planes[0].bytes[index];
          final up = image.planes[1].bytes[uvIndex];
          final vp = image.planes[2].bytes[uvIndex];

          // YUV 转 RGB 公式
          int r = (yp + (vp - 128) * 1.402).toInt();
          int g = (yp - (up - 128) * 0.34414 - (vp - 128) * 0.71414).toInt();
          int b = (yp + (up - 128) * 1.772).toInt();

          // 限制范围 0-255
          r = r.clamp(0, 255);
          g = g.clamp(0, 255);
          b = b.clamp(0, 255);

          imgBuffer.setPixelRgb(x, y, r, g, b);
        }
      }
      return imgBuffer;
    } catch (e) {
      debugPrint("Conversion Error: $e");
      return null;
    }
  }
}