import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:databric/services/api_service.dart';
import 'package:databric/services/xray_service.dart';
import 'package:databric/models/models.dart';

enum SessionRole { none, seller, buyer }

class SessionProvider extends ChangeNotifier {
  final XrayService xrayService;

  SessionProvider({required this.xrayService});

  SessionRole _role = SessionRole.none;
  bool _isLoading = false;
  String? _error;
  Map<String, dynamic>? _activeSession;
  List<SharingSession> _history = [];
  Timer? _pollTimer;

  SessionRole get role => _role;
  bool get isLoading => _isLoading;
  String? get error => _error;
  Map<String, dynamic>? get activeSession => _activeSession;
  List<SharingSession> get history => _history;
  bool get hasActiveSession => _activeSession != null;

  double get usedGb {
    final session = _activeSession;
    if (session == null) return 0;
    // Try bytes first, fall back to gb directly
    final bytes = (session['used_bytes'] as num?)?.toInt();
    if (bytes != null) return bytes / (1024 * 1024 * 1024);
    return (session['used_gb'] as num?)?.toDouble() ?? 0;
  }

double get limitGb {
  final session = _activeSession;
  if (session == null) return 0;
  // Try bytes first, fall back to gb directly
  final bytes = (session['limit_bytes'] as num?)?.toInt();
  if (bytes != null) return bytes / (1024 * 1024 * 1024);
  return (session['limit_gb'] as num?)?.toDouble() ?? 0;
}

  double get usagePercent => limitGb > 0 ? (usedGb / limitGb).clamp(0, 1) : 0;

  // ── Seller: start sharing ─────────────────────────────────

  Future<bool> startSharing(double limitGb, {String? receiverId}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // 1. Ask backend to create the session. It returns the full Xray config
      //    that connects this phone to the relay as the session's bridge.
      final data = await apiService.startSharing(limitGb, receiverId: receiverId);
      final sessionId = data['session_id'] as String;
      // Older backends only send vless_uri; startAsSeller treats that as a
      // placeholder session with no tunnel.
      final sellerConfig =
          (data['seller_config'] ?? data['vless_uri']) as String;

      // 2. Start Xray-core in seller mode
      final started = await xrayService.startAsSeller(sellerConfig, sessionId);
      if (!started) {
        _error = xrayService.errorMessage ?? 'Failed to start tunnel.';
        // Don't leave a session the phone can't serve.
        try {
          await apiService.stopSharing();
        } catch (_) {}
        return false;
      }

      _role = SessionRole.seller;
      _activeSession = {
        ...data,
        'used_bytes': 0,
        'limit_bytes': (limitGb * 1024 * 1024 * 1024).toInt(),
};

      // 3. Start polling for usage updates from backend
      _startPolling();

      return true;
    } catch (e) {
      _error = _parseError(e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> stopSharing() async {
    _isLoading = true;
    notifyListeners();
    try {
      await apiService.stopSharing();
      await xrayService.stopTunnel();
      _role = SessionRole.none;
      _activeSession = null;
      _stopPolling();
    } catch (e) {
      _error = _parseError(e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Buyer: connect to friend ──────────────────────────────

  Future<bool> connectToFriend(String sellerId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // 1. Ask backend to connect and get VLESS URI
      final data = await apiService.connectToSession(sellerId);
      final vlessUri = data['vless_uri'] as String;
      final sessionId = data['session_id'] as String;

      // 2. Start Xray-core in buyer mode — routes all traffic through seller
      final connected = await xrayService.connectAsBuyer(vlessUri, sessionId);
      if (!connected) {
        _error = xrayService.errorMessage ?? 'Failed to connect.';
        return false;
      }

      _role = SessionRole.buyer;
      _activeSession = data;
      _startPolling();

      return true;
    } catch (e) {
      _error = _parseError(e);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _isLoading = true;
    notifyListeners();
    try {
      await apiService.disconnect();
      await xrayService.stopTunnel();
      _role = SessionRole.none;
      _activeSession = null;
      _stopPolling();
    } catch (e) {
      _error = _parseError(e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Restore session after app restart ─────────────────────

  /// Called once after sign-in (or app launch with stored token). If the
  /// backend reports an in-progress session, hydrate state and start
  /// polling so the home screen renders the active banner immediately
  /// instead of waiting for the user to navigate to Share.
  Future<void> restoreActive() async {
    try {
      final data = await apiService.getActiveSession();
      final session = data['session'] as Map<String, dynamic>?;
      if (session == null) return;

      final role = data['role'] as String?;
      if (role == 'seller') {
        _role = SessionRole.seller;
      } else if (role == 'buyer') {
        _role = SessionRole.buyer;
      } else {
        return;
      }
      _activeSession = session;
      _startPolling();
      notifyListeners();
    } catch (_) {
      // Non-fatal — the polling will pick it up later if it comes back.
    }
  }

  // ── History ───────────────────────────────────────────────

  Future<void> loadHistory() async {
    try {
      final data = await apiService.getHistory();
      _history = data.map((m) => SharingSession(
        id: m['id'] as String,
        friendId: '',
        friendName: m['friend_name'] ?? m['friend_phone'] ?? 'Unknown',
        friendCarrier: m['friend_carrier'] ?? '',
        direction: (m['direction'] as String?) == 'sent'
            ? SessionDirection.sent
            : SessionDirection.received,
        amountGb: (m['amount_gb'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.tryParse(m['started_at'] as String? ?? '') ?? DateTime.now(),
      )).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('History load error: $e');
    }
  }

  // ── Polling ───────────────────────────────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final data = await apiService.getActiveSession();
        final session = data['session'] as Map<String, dynamic>?;
        if (session == null) {
          // Session ended on server side
          await xrayService.stopTunnel();
          _role = SessionRole.none;
          _activeSession = null;
          _stopPolling();
        } else {
          _activeSession = session;
        }
        notifyListeners();
      } catch (_) {}
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  String _parseError(dynamic e) {
    if (e is Exception) return e.toString().replaceAll('Exception: ', '');
    return 'Something went wrong. Please try again.';
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
