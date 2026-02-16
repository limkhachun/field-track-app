import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
// 📦 Import Biometric Guard (Create this file first as discussed)
import 'widgets/biometric_guard.dart'; 
import 'services/background_service.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart'; 
import 'screens/home_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 2. Initialize Notification Service
  await NotificationService().init();
  await BackgroundService.initialize();
  // 3. Initialize Localization
  await EasyLocalization.ensureInitialized();

  runApp(
    // 4. Wrap MyApp with EasyLocalization Provider
    EasyLocalization(
      supportedLocales: const [
        Locale('en'), // English
        Locale('ms'), // Malay
        Locale('zh')  // Chinese
      ],
      path: 'assets/translations', 
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'), 
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      
      // Localization Hookup
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale, 

      title: 'Field Track App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      
      // 🟢 KEY CHANGE: Use 'builder' to wrap the entire app with BiometricGuard
      // This ensures the lock screen sits on top of EVERYTHING (Login, Home, etc.)
      builder: (context, child) {
        // Only wrap if child is not null
        return BiometricGuard(
          child: child ?? const SizedBox.shrink(),
        );
      },

      // 5. Auth Flow (Standard StreamBuilder)
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          
          if (snapshot.hasError) {
            return const Scaffold(
              body: Center(child: Text("Connection Error. Please restart.")),
            );
          }

          if (snapshot.hasData) {
            return const HomeScreen(); 
          }

          return const LoginScreen(); 
        },
      ),
    );
  }
}