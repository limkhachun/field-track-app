import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart'; 
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 🟢 新增：用于检查设置开关

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  static const int _trackingId = 888;
  static const int _shiftStartId = 101;
  static const int _shiftEndId = 102;

  static const String _trackingChannelId = 'tracking_channel';
  static const String _reminderChannelId = 'shift_reminders';
  static const String _statusChannelId = 'status_updates'; 

  bool _isInitialized = false;
  final List<StreamSubscription> _subscriptions = [];

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      tz.initializeTimeZones();
      final String timeZoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneName));

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher'); 

      const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings settings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notificationsPlugin.initialize(settings);
      
      // 🟢 新增：请求 Android 13+ 的通知权限
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidImplementation?.requestNotificationsPermission();

      _isInitialized = true;
      debugPrint("✅ NotificationService initialized");
    } catch (e) {
      debugPrint("❌ Error initializing notifications: $e");
    }
  }

  // 🟢 新增：检查用户是否在设置中开启了通知
  Future<bool> _canShowNotification() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('notifications_enabled') ?? true;
  }

  void startListeningToUserUpdates(String uid) {
    stopListening(); 
    debugPrint("🎧 Started listening for Admin updates for UID: $uid");

    // 1. Listen for Leave Approvals
    bool isLeaveInitial = true; // 🟢 使用布尔值跳过首次加载，抛弃时间戳对比
    _subscriptions.add(
      FirebaseFirestore.instance.collection('leaves').where('authUid', isEqualTo: uid).snapshots().listen((snapshot) {
        if (isLeaveInitial) { isLeaveInitial = false; return; } // 跳过旧数据
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Leave Update', 'Your ${data['type']} request has been ${data['status']}.');
          }
        }
      })
    );

    // 2. Listen for Attendance Correction Replies
    bool isCorrectionInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('attendance_corrections').where('authUid', isEqualTo: uid).snapshots().listen((snapshot) {
        if (isCorrectionInitial) { isCorrectionInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Attendance Correction', 'Your correction request for ${data['targetDate']} was ${data['status']}.');
          }
        }
      })
    );

    // 3. Listen for Profile Update Requests
    bool isProfileInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('edit_requests').where('uid', isEqualTo: uid).snapshots().listen((snapshot) {
        if (isProfileInitial) { isProfileInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Profile Update', 'Your profile update request has been ${data['status']}.');
          }
        }
      })
    );

    // 4. Listen for New Payslips
    bool isPayslipInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('payslips').where('uid', isEqualTo: uid).where('status', isEqualTo: 'Published').snapshots().listen((snapshot) {
        if (isPayslipInitial) { isPayslipInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Payslip Ready', 'Your payslip for ${data['month']} is now available.');
          }
        }
      })
    );
    
    // 5. Listen for Announcements
    bool isAnnounceInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('announcements').orderBy('createdAt', descending: true).limit(1).snapshots().listen((snapshot) {
        if (isAnnounceInitial) { isAnnounceInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) { // 只有新增公告才弹窗
             final data = change.doc.data() ?? {};
             _triggerNotification('📢 New Announcement', data['message'] ?? 'Check the app for a new update.');
          }
        }
      })
    );
  }

  // 🟢 统一的触发器入口
  Future<void> _triggerNotification(String title, String body) async {
    // 发送前检查设置面板的开关
    if (!await _canShowNotification()) {
      debugPrint("🔕 Notification blocked by user settings.");
      return;
    }
    showStatusNotification(title, body);
  }

  void stopListening() {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    debugPrint("🛑 Stopped listening for updates");
  }

  // =========================================================
  // 📍 GPS Tracking Notification (Persistent)
  // =========================================================

  Future<void> showTrackingNotification() async {
    if (!await _canShowNotification()) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _trackingChannelId,
      'GPS Tracking Service',
      channelDescription: 'Running in background to track location',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      _trackingId,
      'notif.tracking_active'.tr(), 
      'notif.tracking_desc'.tr(),   
      details,
    );
  }

  Future<void> cancelTrackingNotification() async {
    await _notificationsPlugin.cancel(_trackingId);
  }

  // =========================================================
  // 🔔 Instant Status Notification (Admin Actions)
  // =========================================================

  Future<void> showStatusNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _statusChannelId,
      'Status Updates',
      channelDescription: 'Notifications for application status changes',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
    
    int notificationId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await _notificationsPlugin.show(
      notificationId,
      title,
      body,
      details,
    );
  }

  // =========================================================
  // ⏰ Shift Reminders (Scheduled)
  // =========================================================

  Future<void> scheduleShiftReminders(DateTime shiftStart, DateTime shiftEnd) async {
    if (!await _canShowNotification()) return;
    
    final now = DateTime.now();

    final scheduledStart = shiftStart.subtract(const Duration(minutes: 15));
    if (scheduledStart.isAfter(now)) {
      await _scheduleNotification(
        _shiftStartId,
        'notif.shift_start_title'.tr(),
        'notif.shift_start_body'.tr(),
        scheduledStart,
      );
    }

    final scheduledEnd = shiftEnd.subtract(const Duration(minutes: 10));
    if (scheduledEnd.isAfter(now)) {
      await _scheduleNotification(
        _shiftEndId,
        'notif.shift_end_title'.tr(),
        'notif.shift_end_body'.tr(),
        scheduledEnd,
      );
    }
  }

  Future<void> _scheduleNotification(int id, String title, String body, DateTime scheduledTime) async {
    try {
      await _notificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _reminderChannelId,
            'Shift Reminders',
            channelDescription: 'Reminders for clock-in and clock-out',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint("❌ Error scheduling notification: $e");
    }
  }

  Future<void> cancelAllReminders() async {
    await _notificationsPlugin.cancel(_shiftStartId);
    await _notificationsPlugin.cancel(_shiftEndId);
  }
}