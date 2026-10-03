import 'package:flutter/foundation.dart';
import 'package:databric/services/api_service.dart';
import 'package:databric/services/notification_service.dart';
import 'package:databric/models/models.dart';

enum AuthStatus { unknown, unauthenticated, authenticated }

class AuthProvider extends ChangeNotifier {
  AuthStatus _status = AuthStatus.unknown;
  UserProfile? _user;
  String? _userId;
  bool _isLoading = false;
  String? _error;

  AuthStatus get status => _status;
  UserProfile? get user => _user;
  String? get userId => _userId;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  Future<void> checkAuth() async {
    final hasToken = await apiService.hasToken();
    if (!hasToken) {
      _status = AuthStatus.unauthenticated;
      notifyListeners();
      return;
    }
    try {
      final data = await apiService.getMe();
      _user = _userFromMap(data);
      _userId = data['id']?.toString();
      _status = AuthStatus.authenticated;
      // Register the FCM token now that we have a valid JWT.
      // Non-blocking so a missing google-services.json doesn't stall startup.
      // ignore: unawaited_futures
      NotificationService.registerDeviceWithBackend();
    } catch (_) {
      await apiService.clearToken();
      _status = AuthStatus.unauthenticated;
    }
    notifyListeners();
  }

  Future<bool> sendOtp(String phoneNumber) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      await apiService.sendOtp(phoneNumber);
      return true;
    } catch (e) {
      _error = _parseError(e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> verifyOtp(String phoneNumber, String otp) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final data = await apiService.verifyOtp(phoneNumber, otp);
      final token = data['access_token'] as String;
      await apiService.saveToken(token);
      final userMap = data['user'] as Map<String, dynamic>;
      _user = _userFromMap(userMap);
      _userId = userMap['id']?.toString();
      _status = AuthStatus.authenticated;
      // Fire-and-forget — the token will land at /auth/device when ready.
      // ignore: unawaited_futures
      NotificationService.registerDeviceWithBackend();
      return true;
    } catch (e) {
      _error = _parseError(e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await apiService.clearToken();
    _user = null;
    _userId = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  UserProfile _userFromMap(Map<String, dynamic> m) {
    final phone = (m['phone_number'] ?? '').toString();
    final display = (m['display_name'] as String?)?.trim();
    return UserProfile(
      name: (display == null || display.isEmpty) ? phone : display,
      phoneNumber: phone,
      carrier: (m['carrier'] ?? '').toString(),
      city: (m['city'] ?? '').toString(),
      country: (m['country'] ?? '').toString(),
    );
  }

  String _parseError(dynamic e) {
    if (e is Exception) return e.toString().replaceAll('Exception: ', '');
    return 'Something went wrong. Please try again.';
  }
}
