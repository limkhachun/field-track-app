import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 📦 新增
import 'notification_service.dart'; // 📦 新增

class TrackingService {
  StreamSubscription<Position>? _positionStream;
  String? _currentUserId;
  
  // 🟢 UI Notifier: 监听此变量以更新 UI 开关状态
  final ValueNotifier<bool> isTrackingNotifier = ValueNotifier(false);

  // ⏰ 自动停止定时器 (安全/隐私)
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

      // 1. 获取用户今日的出勤记录
      final q = await FirebaseFirestore.instance
          .collection('attendance')
          .where('uid', isEqualTo: authUid)
          .where('date', isEqualTo: todayStr)
          .get();

      if (q.docs.isNotEmpty) {
        final data = q.docs.first.data();
        // 只有当状态是 "Clocked In" 且没有 "Clock Out" 时才恢复追踪
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
    if (isTrackingNotifier.value) return; // 防止重复启动

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      _currentUserId = userId;
      
      // 🔔 [新增] 检查设置并显示通知
      final prefs = await SharedPreferences.getInstance();
      final bool shouldNotify = prefs.getBool('notifications_enabled') ?? true;
      
      if (shouldNotify) {
        await NotificationService().showTrackingNotification();
      }

      // 配置定位参数 (距离过滤器: 10米)
      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, 
      );

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen((Position position) {
        _uploadLocation(position);
      });

      isTrackingNotifier.value = true;
      _scheduleAutoStop(userId); // 启动自动停止计时器
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
    isTrackingNotifier.value = false;
    
    // 🔕 [新增] 移除通知
    await NotificationService().cancelTrackingNotification();
    
    debugPrint("🛑 Tracking Stopped");
  }

  /// ☁️ 上传位置到 Firestore
  Future<void> _uploadLocation(Position pos) async {
    if (_currentUserId == null) return;

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);

    try {
      await FirebaseFirestore.instance.collection('tracking_logs').add({
        'uid': _currentUserId,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'speed': pos.speed, // m/s
        'heading': pos.heading,
        'timestamp': FieldValue.serverTimestamp(),
        'date': todayStr, // 用于查询索引
        'lastUpdate': now, // 用于判断在线状态
      });
      // debugPrint("📍 Location uploaded: ${pos.latitude}, ${pos.longitude}");
    } catch (e) {
      debugPrint("Error uploading location: $e");
    }
  }

  /// ⏰ 智能自动停止逻辑
  /// 规则: 获取今日排班结束时间，在结束时间后1小时自动停止。
  /// 如果没有排班，则默认12小时后停止。
  Future<void> _scheduleAutoStop(String authUid) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);

      final schedSnap = await FirebaseFirestore.instance
          .collection('schedules')
          .where('date', isEqualTo: todayStr)
          .get();

      // 在内存中过滤当前用户的排班
      var mySchedule = schedSnap.docs.where((doc) {
        final data = doc.data();
        return data['userId'] == authUid || data['userId'] == _currentUserId; 
      }).toList();

      DateTime? forceStopTime;

      if (mySchedule.isNotEmpty) {
        final data = mySchedule.first.data();
        Timestamp endTs = data['end']; 
        DateTime shiftEnd = endTs.toDate();

        // 规则: 班次结束后 1 小时停止
        forceStopTime = shiftEnd.add(const Duration(hours: 1));
        debugPrint("📅 Shift Ends: ${DateFormat('HH:mm').format(shiftEnd)} | Auto-Stop: ${DateFormat('HH:mm').format(forceStopTime)}");

      } else {
        // 后备方案: 12小时后停止
        forceStopTime = now.add(const Duration(hours: 12));
        debugPrint("⚠️ No schedule found. Defaulting to 12-hour timeout.");
      }

      final duration = forceStopTime.difference(DateTime.now());

      if (duration.isNegative) {
        // 如果已经过了时间，1小时后强制停止
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