import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:databric/services/api_service.dart';

/// Owns Firebase init + FCM token plumbing.
///
/// Call [init] once at app start (before the widget tree mounts).
/// Call [registerDeviceWithBackend] after the user has signed in (we need
/// the JWT before we can hit /auth/device).
class NotificationService {
  static bool _initialized = false;

  /// Returns true if Firebase is available. If `google-services.json` is
  /// missing or Firebase init fails for any reason, we log it and continue —
  /// the rest of the app must function without push.
  static Future<bool> init() async {
    if (_initialized) return true;
    try {
      await Firebase.initializeApp();
      _initialized = true;
      return true;
    } catch (e) {
      debugPrint('[NotificationService] Firebase init failed: $e');
      return false;
    }
  }

  /// Request permission (no-op on Android <13), grab the FCM token,
  /// register it with the backend, and subscribe to token refreshes so
  /// re-issued tokens reach the backend.
  static Future<void> registerDeviceWithBackend() async {
    if (!_initialized) {
      final ok = await init();
      if (!ok) return;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _safeRegister(token);
      }

      // If FCM rotates the token later, push the new one to the backend.
      messaging.onTokenRefresh.listen(_safeRegister);
    } catch (e) {
      debugPrint('[NotificationService] FCM registration failed: $e');
    }
  }

  static Future<void> _safeRegister(String token) async {
    try {
      await apiService.registerDevice(token);
    } catch (e) {
      // Backend unreachable / not yet authenticated — non-fatal.
      debugPrint('[NotificationService] registerDevice failed: $e');
    }
  }
}
