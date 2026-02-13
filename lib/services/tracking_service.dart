import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

class TrackingService {
  StreamSubscription<Position>? _positionStream;
  String? _currentUserId;
  
  // 🟢 新增：记录上一次成功上传的位置
  Position? _lastUploadedPosition;
  
  // 🟢 阈值设置：200米
  static const double _uploadDistanceFilter = 200.0;

  final ValueNotifier<bool> isTrackingNotifier = ValueNotifier(false);
  Timer? _autoStopTimer;

  static final TrackingService _instance = TrackingService._internal();
  factory TrackingService() => _instance;
  TrackingService._internal();

  bool get isTracking => isTrackingNotifier.value;

  /// 🔄 恢复会话 (App 启动时调用)
  Future<void> resumeTrackingSession(String authUid) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);

      final q = await FirebaseFirestore.instance
          .collection('attendance')
          .where('uid', isEqualTo: authUid)
          .where('date', isEqualTo: todayStr)
          .get();

      if (q.docs.isNotEmpty) {
        final data = q.docs.first.data();
        if (data['clockIn'] != null && data['clockOut'] == null) {
          debugPrint("🔄 Resuming tracking session for $authUid");
          startTracking(authUid);
        }
      }
    } catch (e) {
      debugPrint("Error resuming tracking: $e");
    }
  }

  /// ▶️ 开始追踪
  Future<void> startTracking(String userId) async {
    if (isTrackingNotifier.value) return; 

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      _currentUserId = userId;
      _lastUploadedPosition = null; // 🟢 每次开始前重置上次上传点
      
      final prefs = await SharedPreferences.getInstance();
      final bool shouldNotify = prefs.getBool('notifications_enabled') ?? true;
      
      if (shouldNotify) {
        await NotificationService().showTrackingNotification();
      }

      // 🟢 这里的 filter 保持较小 (如 10m)，让 Stream 保持活跃，
      // 具体的上传逻辑由 _uploadLocation 里的 200m 阈值控制。
      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, 
      );

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen((Position position) {
        _uploadLocation(position);
      });

      isTrackingNotifier.value = true;
      _scheduleAutoStop(userId); 
      debugPrint("✅ Tracking Started");
    } else {
      debugPrint("❌ Location permission denied");
    }
  }

  /// ⏹️ 停止追踪
  Future<void> stopTracking() async {
    await _positionStream?.cancel();
    _positionStream = null;
    _autoStopTimer?.cancel();
    _currentUserId = null;
    _lastUploadedPosition = null; // 🟢 清除缓存位置
    isTrackingNotifier.value = false;
    
    await NotificationService().cancelTrackingNotification();
    
    debugPrint("🛑 Tracking Stopped");
  }

  /// ☁️ 上传位置到 Firestore (带手动距离过滤)
  Future<void> _uploadLocation(Position pos) async {
    if (_currentUserId == null) return;

    // 🟢 核心逻辑：手动距离过滤 (200米)
    if (_lastUploadedPosition != null) {
      double distance = Geolocator.distanceBetween(
        _lastUploadedPosition!.latitude,
        _lastUploadedPosition!.longitude,
        pos.latitude,
        pos.longitude,
      );

      // 如果移动距离小于 200 米，直接忽略，不上传
      if (distance < _uploadDistanceFilter) {
        // debugPrint("🚫 Skipped: Moved only ${distance.toStringAsFixed(1)}m");
        return; 
      }
    }

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);

    try {
      await FirebaseFirestore.instance.collection('tracking_logs').add({
        'uid': _currentUserId,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'speed': pos.speed, 
        'heading': pos.heading,
        'timestamp': FieldValue.serverTimestamp(),
        'date': todayStr,
        'lastUpdate': now, 
      });
      
      // 🟢 更新“上次上传点”为当前点
      _lastUploadedPosition = pos;
      
      debugPrint("📍 Location uploaded (Moved > 200m)");
    } catch (e) {
      debugPrint("Error uploading location: $e");
    }
  }

  /// ⏰ 智能自动停止逻辑
  Future<void> _scheduleAutoStop(String authUid) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);

      final schedSnap = await FirebaseFirestore.instance
          .collection('schedules')
          .where('date', isEqualTo: todayStr)
          .get();

      var mySchedule = schedSnap.docs.where((doc) {
        final data = doc.data();
        return data['userId'] == authUid || data['userId'] == _currentUserId; 
      }).toList();

      DateTime? forceStopTime;

      if (mySchedule.isNotEmpty) {
        final data = mySchedule.first.data();
        Timestamp endTs = data['end']; 
        DateTime shiftEnd = endTs.toDate();

        // 班次结束后 1 小时停止
        forceStopTime = shiftEnd.add(const Duration(hours: 1));
        debugPrint("📅 Shift Ends: ${DateFormat('HH:mm').format(shiftEnd)} | Auto-Stop: ${DateFormat('HH:mm').format(forceStopTime)}");

      } else {
        // 后备方案: 12小时后停止
        forceStopTime = now.add(const Duration(hours: 12));
        debugPrint("⚠️ No schedule found. Defaulting to 12-hour timeout.");
      }

      final duration = forceStopTime.difference(DateTime.now());

      if (duration.isNegative) {
        _autoStopTimer = Timer(const Duration(hours: 1), stopTracking);
      } else {
        _autoStopTimer = Timer(duration, () {
          debugPrint("⏰ Auto-Stop Triggered.");
          stopTracking();
        });
      }
      
    } catch (e) {
      debugPrint("Error scheduling auto-stop: $e");
    }
  }
}