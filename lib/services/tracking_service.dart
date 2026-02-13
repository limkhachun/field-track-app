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
  
  // 🟢 记录上一次成功上传的位置，用于距离过滤
  Position? _lastUploadedPosition;
  
  // 🟢 阈值设置：200米（过滤信号漂移并减少数据库读写）
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

  /// ▶️ 开始追踪 (🟢 已添加 Driver 权限检查)
  Future<void> startTracking(String userId) async {
    if (isTrackingNotifier.value) return; 

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      
      // 🟢 1. 检查是否为 Driver
      try {
        final userQuery = await FirebaseFirestore.instance
            .collection('users')
            .where('authUid', isEqualTo: userId)
            .limit(1)
            .get();

        if (userQuery.docs.isNotEmpty) {
          final userData = userQuery.docs.first.data();
          // 如果 isDriver 字段不存在或为 false，则禁止追踪
          bool isDriver = userData['isDriver'] == true;

          if (!isDriver) {
            debugPrint("🚫 User is not setup as a Driver. Tracking skipped.");
            return; // 直接返回，不启动流
          }
        } else {
          debugPrint("⚠️ User profile not found. Tracking skipped.");
          return;
        }
      } catch (e) {
        debugPrint("Error checking driver status: $e");
        return; // 出错时安全退出
      }

      // 🟢 2. 验证通过，初始化追踪
      _currentUserId = userId;
      _lastUploadedPosition = null; 
      
      final prefs = await SharedPreferences.getInstance();
      final bool shouldNotify = prefs.getBool('notifications_enabled') ?? true;
      
      if (shouldNotify) {
        await NotificationService().showTrackingNotification();
      }

      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // 保持流活跃，实际过滤在 _uploadLocation 处理
      );

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen((Position position) {
        _uploadLocation(position);
      });

      isTrackingNotifier.value = true;
      _scheduleAutoStop(userId); 
      debugPrint("✅ Tracking Started (Driver Verified)");
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
    _lastUploadedPosition = null;
    isTrackingNotifier.value = false;
    
    await NotificationService().cancelTrackingNotification();
    
    debugPrint("🛑 Tracking Stopped");
  }

  /// ☁️ 上传位置到 Firestore (双重更新优化版)
  /// 同时更新历史日志和最新位置文档，以支持大规模员工管理
  Future<void> _uploadLocation(Position pos) async {
    if (_currentUserId == null) return;

    // 🟢 手动距离过滤 (200米)
    if (_lastUploadedPosition != null) {
      double distance = Geolocator.distanceBetween(
        _lastUploadedPosition!.latitude,
        _lastUploadedPosition!.longitude,
        pos.latitude,
        pos.longitude,
      );

      if (distance < _uploadDistanceFilter) {
        return; 
      }
    }

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final batch = FirebaseFirestore.instance.batch();

    // 1. 添加到历史轨迹集合 (用于 Admin 端按需画线)
    final logRef = FirebaseFirestore.instance.collection('tracking_logs').doc();
    batch.set(logRef, {
      'uid': _currentUserId,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'speed': pos.speed, 
      'heading': pos.heading,
      'timestamp': FieldValue.serverTimestamp(),
      'date': todayStr,
    });

    // 2. 🟢 核心优化：更新司机的“最后已知位置”文档
    // 这样做让 Admin 首页只需读取 100 个文档即可查看所有人实时状态，极大节省读取成本。
    final lastLocRef = FirebaseFirestore.instance.collection('user_last_locations').doc(_currentUserId);
    batch.set(lastLocRef, {
      'uid': _currentUserId,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'speed': pos.speed,
      'timestamp': FieldValue.serverTimestamp(),
      'lastUpdate': now, // 兼容 Admin 端的在线/离线逻辑
    });

    try {
      await batch.commit();
      _lastUploadedPosition = pos;
      debugPrint("📍 Double Upload Success (> 200m)");
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

        forceStopTime = shiftEnd.add(const Duration(hours: 1));
        debugPrint("📅 Shift Ends: ${DateFormat('HH:mm').format(shiftEnd)} | Auto-Stop: ${DateFormat('HH:mm').format(forceStopTime)}");
      } else {
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