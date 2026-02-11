import 'dart:async';
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
  // 🟢 新增：状态更新通知渠道 ID
  static const String _statusChannelId = 'status_updates'; 

  bool _isInitialized = false;

  /// Initialize the Notification Service
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      // 1. Initialize Time Zones
      tz.initializeTimeZones();
      final String timeZoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneName));

      // 2. Android Settings
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher'); 

      // 3. iOS Settings
      const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      // 4. Initialize Plugin
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
  // 🔔 🟢 新增：即时状态通知 (Admin 审批结果)
  // =========================================================

  Future<void> showStatusNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _statusChannelId,
      'Status Updates', // 渠道名称
      channelDescription: 'Notifications for application status changes',
      importance: Importance.max, // 最高重要性，确保弹窗
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());

    // 使用当前时间戳作为 ID，避免不同通知互相覆盖
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
      debugPrint("✅ Scheduled notification [$id] at $scheduledTime");
    } catch (e) {
      debugPrint("❌ Error scheduling notification: $e");
    }
  }

  Future<void> cancelAllReminders() async {
    await _notificationsPlugin.cancel(_shiftStartId);
    await _notificationsPlugin.cancel(_shiftEndId);
  }
}