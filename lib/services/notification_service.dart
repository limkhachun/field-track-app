import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart'; 
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:easy_localization/easy_localization.dart';

class NotificationService {
  // Singleton Pattern
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  // Notification IDs
  static const int _trackingId = 888;
  static const int _shiftStartId = 101;
  static const int _shiftEndId = 102;

  // Channel IDs
  static const String _trackingChannelId = 'tracking_channel';
  static const String _reminderChannelId = 'shift_reminders';
  static const String _statusChannelId = 'status_updates'; 

  bool _isInitialized = false;
  
  // 🟢 监听器订阅列表 (用于退出登录时取消)
  final List<StreamSubscription> _subscriptions = [];
  DateTime? _listeningStartTime;

  /// Initialize the Notification Service
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
      _isInitialized = true;
      debugPrint("✅ NotificationService initialized");
    } catch (e) {
      debugPrint("❌ Error initializing notifications: $e");
    }
  }

  // =========================================================
  // 🎧 🟢 核心功能：监听 Firestore 数据变化
  // =========================================================

  /// 在用户登录成功后调用此方法
  void startListeningToUserUpdates(String uid) {
    stopListening(); // 防止重复监听
    _listeningStartTime = DateTime.now(); // 记录开始时间，只通知这之后的变化
    debugPrint("🎧 Started listening for Admin updates for UID: $uid");

    // 1. 监听 Leave Approval (请假审批)
    _subscriptions.add(
      FirebaseFirestore.instance
          .collection('leaves')
          .where('authUid', isEqualTo: uid) // 确保这里字段名和数据库一致
          .snapshots()
          .listen((snapshot) {
        for (var change in snapshot.docChanges) {
          // 只关注修改过的文档 (Admin 修改状态)
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() as Map<String, dynamic>;
            _checkAndNotify(
              data: data,
              title: 'Leave Update',
              body: 'Your ${data['type']} request has been ${data['status']}.',
              timeField: 'reviewedAt', // Admin 审核的时间字段
            );
          }
        }
      })
    );

    // 2. 监听 Attendance Corrections (补卡审批)
    _subscriptions.add(
      FirebaseFirestore.instance
          .collection('attendance_corrections')
          .where('authUid', isEqualTo: uid)
          .snapshots()
          .listen((snapshot) {
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() as Map<String, dynamic>;
            _checkAndNotify(
              data: data,
              title: 'Attendance Correction',
              body: 'Your correction request for ${data['targetDate']} was ${data['status']}.',
              timeField: 'resolvedAt', 
            );
          }
        }
      })
    );

    // 3. 监听 Profile Updates (资料修改审批)
    _subscriptions.add(
      FirebaseFirestore.instance
          .collection('edit_requests')
          .where('uid', isEqualTo: uid)
          .snapshots()
          .listen((snapshot) {
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() as Map<String, dynamic>;
            _checkAndNotify(
              data: data,
              title: 'Profile Update',
              body: 'Your profile update request has been ${data['status']}.',
              timeField: 'reviewedAt',
            );
          }
        }
      })
    );

    // 4. 监听 Payslips (工资单发布) - 监听新增
    _subscriptions.add(
      FirebaseFirestore.instance
          .collection('payslips')
          .where('uid', isEqualTo: uid) // 注意：这里通常存的是 DocID，确认一下你存的是 authUid 还是 user doc id
          .where('status', isEqualTo: 'Published')
          .snapshots()
          .listen((snapshot) {
        for (var change in snapshot.docChanges) {
          // 工资单通常是新建或修改为 Published
          if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
            final data = change.doc.data() as Map<String, dynamic>;
            // 对于工资单，我们检查 updatedAt 是否很新
            _checkAndNotify(
              data: data,
              title: 'Payslip Ready',
              body: 'Your payslip for ${data['month']} is now available.',
              timeField: 'updatedAt',
            );
          }
        }
      })
    );
  }

  /// 内部辅助函数：检查时间并发送通知
  void _checkAndNotify({
    required Map<String, dynamic> data,
    required String title,
    required String body,
    required String timeField,
  }) {
    if (_listeningStartTime == null) return;

    Timestamp? ts = data[timeField] as Timestamp?;
    // 如果没有时间戳，或者时间戳晚于监听开始时间（说明是新发生的动作）
    if (ts != null && ts.toDate().isAfter(_listeningStartTime!)) {
       showStatusNotification(title, body);
    }
  }

  /// 退出登录时调用
  void stopListening() {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _listeningStartTime = null;
    debugPrint("🛑 Stopped listening for updates");
  }

  // =========================================================
  // 📍 GPS Tracking Notification (Persistent)
  // =========================================================

  Future<void> showTrackingNotification() async {
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
  // 🔔 即时状态通知 (Admin 审批结果)
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
    final now = DateTime.now();

    // A. Shift Start Reminder (15 mins before)
    final scheduledStart = shiftStart.subtract(const Duration(minutes: 15));
    if (scheduledStart.isAfter(now)) {
      await _scheduleNotification(
        _shiftStartId,
        'notif.shift_start_title'.tr(),
        'notif.shift_start_body'.tr(),
        scheduledStart,
      );
    }

    // B. Shift End Reminder (10 mins before)
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