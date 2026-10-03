import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

/// Central API client for all DataBric backend calls.
/// Uses Dio with automatic JWT injection and error handling.
class ApiService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://databric.onrender.com', // Android emulator → Render
  );

  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'databric_jwt';

  late final Dio _dio;

  ApiService() {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'Content-Type': 'application/json'},
    ));

    // Inject JWT on every request
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _storage.read(key: _tokenKey);
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) {
        handler.next(error);
      },
    ));
  }

  // ── Token management ─────────────────────────────────────

  Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }

  Future<bool> hasToken() async {
    final token = await _storage.read(key: _tokenKey);
    return token != null && token.isNotEmpty;
  }

  // ── Auth ─────────────────────────────────────────────────

  Future<void> sendOtp(String phoneNumber) async {
    await _dio.post('/auth/otp/send', data: {'phone_number': phoneNumber});
  }

  Future<Map<String, dynamic>> verifyOtp(String phoneNumber, String otp) async {
    final resp = await _dio.post('/auth/otp/verify', data: {
      'phone_number': phoneNumber,
      'otp_code': otp,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<void> registerDevice(String fcmToken) async {
    await _dio.post('/auth/device', data: {
      'fcm_token': fcmToken,
      'platform': 'android',
      'app_version': '1.0.0',
    });
  }

  Future<Map<String, dynamic>> getMe() async {
    final resp = await _dio.get('/auth/me');
    return resp.data as Map<String, dynamic>;
  }

  // ── Users ────────────────────────────────────────────────

  Future<void> updateProfile({
    String? carrier,
    String? city,
    String? country,
    String? displayName,
  }) async {
    final body = <String, dynamic>{};
    if (carrier != null) body['carrier'] = carrier;
    if (city != null) body['city'] = city;
    if (country != null) body['country'] = country;
    if (displayName != null) body['display_name'] = displayName;

    await _dio.patch('/users/me', data: body);
  }

  // ── Friends ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getFriends() async {
    final resp = await _dio.get('/friends');
    return List<Map<String, dynamic>>.from(resp.data as List);
  }

  Future<void> inviteFriend(String phoneNumber) async {
    await _dio.post('/friends/invite', data: {'phone_number': phoneNumber});
  }

  Future<void> friendAction(String friendshipId, String action) async {
    await _dio.post('/friends/action', data: {
      'friendship_id': friendshipId,
      'action': action,
    });
  }

  // ── Sessions ─────────────────────────────────────────────

  /// Start sharing — returns VLESS URI and session ID
  Future<Map<String, dynamic>> startSharing(double limitGb, {String? receiverId}) async {
    final body = <String, dynamic>{
      'limit_gb': limitGb.toDouble(),  // force float
    };
    if (receiverId != null) body['receiver_id'] = receiverId;

    debugPrint('[ApiService] startSharing body: $body');

    final resp = await _dio.post('/sessions/start', data: body);
    return resp.data as Map<String, dynamic>;
  }

  Future<void> stopSharing() async {
    await _dio.post('/sessions/stop');
  }

  /// Connect to a friend's session — returns VLESS URI for buyer
  Future<Map<String, dynamic>> connectToSession(String sellerId) async {
    final resp = await _dio.post('/sessions/connect', data: {
      'seller_id': sellerId,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<void> disconnect() async {
    await _dio.post('/sessions/disconnect');
  }

  Future<Map<String, dynamic>> getActiveSession() async {
    final resp = await _dio.get('/sessions/active');
    return resp.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getHistory({
    int page = 1,
    int perPage = 20,
  }) async {
    final resp = await _dio.get('/sessions/history', queryParameters: {
      'page': page,
      'per_page': perPage,
    });
    return List<Map<String, dynamic>>.from(resp.data as List);
  }
}

/// Singleton instance used throughout the app
final apiService = ApiService();