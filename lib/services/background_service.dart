import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart'; // Ensure this import is correct

class BackgroundService {
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    // Android Notification Channel (Required for Foreground Service)
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'my_foreground', 
      'Tracking Service', 
      description: 'Used for tracking staff location in background',
      importance: Importance.low, 
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // 🟢 Default to false, start manually when user logs in/clocks in
        isForegroundMode: true,
        notificationChannelId: 'my_foreground',
        initialNotificationTitle: 'Field Track Pro',
        initialNotificationContent: 'Initializing tracking service...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  // 🟢 iOS Background Handler
  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  // 🟢 The Main Isolate Logic (Runs even if App is closed)
  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    // 1. Initialize Flutter & Plugins in this Isolate
    DartPluginRegistrant.ensureInitialized();
    
    // 2. Initialize Firebase (CRITICAL: Firebase isn't shared between isolates)
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e) {
      // Firebase might already be initialized
    }

    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });
      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    // 3. Start Location Listening
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 100, // 🟢 Keep consistent with your requirement
    );

    // Get User ID from SharedPreferences (Since we can't access Auth Provider here easily)
    final prefs = await SharedPreferences.getInstance();
    // Assuming you save the UID when logging in. 
    // You MUST save 'current_user_id' to prefs in your LoginScreen/HomeScreen.
    String? userId = prefs.getString('current_user_id'); 

    if (userId == null) {
      service.stopSelf();
      return;
    }

    Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position? position) {
      if (position != null) {
        _updateLocationToFirestore(userId, position);
        
        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: "Field Track Pro",
            content: "Tracking Active: ${DateTime.now().hour}:${DateTime.now().minute}",
          );
        }
        
        debugPrint("📍 Background Location: ${position.latitude}, ${position.longitude}");
      }
    });
  }

  static Future<void> _updateLocationToFirestore(String userId, Position position) async {
    try {
      // Update Live Location
      await FirebaseFirestore.instance.collection('users').doc(userId).update({
        'lastKnownLocation': GeoPoint(position.latitude, position.longitude),
        'lastLocationUpdate': FieldValue.serverTimestamp(),
      });

      // Optional: Add to History (If you have a tracking session ID, you'd need to pass that via SharedPreferences too)
    } catch (e) {
      debugPrint("❌ Background Write Error: $e");
    }
  }
}