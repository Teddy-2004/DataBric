import 'package:flutter/foundation.dart';

enum XrayMode { buyer, seller, idle }
enum TunnelStatus { idle, connecting, connected, error }

/// Stub XrayService — real Xray-core integration added in next phase.
/// All tunnel logic is mocked so the UI builds and runs cleanly.
class XrayService extends ChangeNotifier {
  XrayMode _mode = XrayMode.idle;
  TunnelStatus _status = TunnelStatus.idle;
  String? _currentSessionId;
  String? _errorMessage;
  int _uploadBytes = 0;
  int _downloadBytes = 0;

  XrayMode get mode => _mode;
  TunnelStatus get status => _status;
  String? get currentSessionId => _currentSessionId;
  String? get errorMessage => _errorMessage;
  int get uploadBytes => _uploadBytes;
  int get downloadBytes => _downloadBytes;
  bool get isActive => _status == TunnelStatus.connected;

  Future<void> init() async {
    debugPrint('[XrayService] Stub init — real Xray added in Phase 2');
  }

  Future<bool> connectAsBuyer(String vlessUri, String sessionId) async {
    debugPrint('[XrayService] Stub connectAsBuyer: $sessionId');
    _mode = XrayMode.buyer;
    _currentSessionId = sessionId;
    _status = TunnelStatus.connected;
    notifyListeners();
    return true;
  }

  Future<bool> startAsSeller(String vlessUri, String sessionId) async {
    debugPrint('[XrayService] Stub startAsSeller: $sessionId');
    _mode = XrayMode.seller;
    _currentSessionId = sessionId;
    _status = TunnelStatus.connected;
    notifyListeners();
    return true;
  }

  Future<void> stopTunnel() async {
    debugPrint('[XrayService] Stub stopTunnel');
    _mode = XrayMode.idle;
    _status = TunnelStatus.idle;
    _currentSessionId = null;
    _uploadBytes = 0;
    _downloadBytes = 0;
    _errorMessage = null;
    notifyListeners();
  }
}