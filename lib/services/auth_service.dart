import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'; 
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // 1. Get current user data (Needed for Home Screen)
  Future<Map<String, dynamic>?> getCurrentUserData() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        DocumentSnapshot doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        return doc.data() as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      debugPrint("Error fetching user data: $e");
      return null;
    }
  }

  // 2. Login with Username
  Future<User?> loginWithUsername(String username, String password) async {
    try {
      String email = "${username.trim()}@fieldtrack.com";
      UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email, 
        password: password
      );
      return result.user;
    } catch (e) {
      debugPrint("Login Error: ${e.toString()}");
      return null;
    }
  }

  // 3. Get Phone Number for WhatsApp Support
  Future<String?> getPhoneNumber(String username) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('username', isEqualTo: username.trim())
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        return snapshot.docs.first.get('phone') as String;
      }
      return null;
    } catch (e) {
      debugPrint("Error fetching phone: $e");
      return null;
    }
  }

  // 4. Register with Username
  Future<User?> registerWithUsername(String username, String password) async {
    try {
      String email = "${username.trim()}@fieldtrack.com";
      UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email, 
        password: password
      );
      return result.user;
    } catch (e) {
      debugPrint("Registration Error: ${e.toString()}");
      return null;
    }
  }

  // 5. Sign Out
  Future<void> signOut() async => await _auth.signOut();
}