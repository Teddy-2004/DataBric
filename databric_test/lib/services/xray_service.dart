import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:permission_handler/permission_handler.dart';

enum XrayMode { buyer, seller, idle }

enum TunnelStatus { idle, connecting, connected, error }

/// XrayService
///
/// BUYER side: standard VLESS client.
///   connectAsBuyer(vlessUri, sessionId) parses the URI and opens an Android
///   VPN TUN interface, so all device traffic goes relay -> seller -> internet.
///
/// SELLER side: Xray reverse proxy, "Option B".
///   The seller phone is the BRIDGE. It dials OUT to the relay, which is the
///   PORTAL, and the relay sends buyer traffic back down that connection.
///   The phone never accepts an inbound connection, so this works behind
///   carrier NAT.
///
///     buyer -> relay (portal) -> seller phone (bridge) -> carrier network
///
///   startAsSeller(configJson, sessionId) runs a full Xray JSON config in
///   proxy-only mode (no VPN interface; the seller's own traffic is untouched).
///
/// What flutter_v2ray 1.0.10 requires of a custom config (it fails silently
/// otherwise):
///   - an "inbounds" array must be present
///   - outbounds[0] must be the VLESS outbound with settings.vnext[0]
///   - tag that outbound "proxy" for the upload/download counters to work
///
/// The bundled core is Xray v25.3.6. Run the same version on the relay.
///
/// Stopping: flutter_v2ray's stop closes the core, but for a reverse bridge
/// that leaves the open connection to the relay running inside the core's
/// process, which Android keeps alive. The seller would keep sharing. So every
/// stop also ends that process (MainActivity.kt, channel databric/tunnel_process).
///
/// Still to do:
///   - backend returns a per-session bridge config instead of a VLESS URI
///   - seller tunnel survives the app being backgrounded for long periods
class XrayService extends ChangeNotifier {
  XrayMode _mode = XrayMode.idle;
  TunnelStatus _status = TunnelStatus.idle;
  String? _currentSessionId;
  String? _errorMessage;
  int _uploadBytes = 0;
  int _downloadBytes = 0;

  /// Last state reported by the native core: CONNECTING, CONNECTED, DISCONNECTED.
  String? _coreState;

  /// flutter_v2ray never switches back from proxy-only to VPN mode within one
  /// app process. Once the seller has run, a buyer connection would start
  /// without a VPN interface and silently tunnel nothing.
  bool _proxyOnlyLatched = false;

  /// True while stopTunnel() runs, so its own DISCONNECTED event is not
  /// mistaken for a stop from outside the app.
  bool _stopping = false;

  static const MethodChannel _tunnelProcess =
      MethodChannel('databric/tunnel_process');

  late final FlutterV2ray _v2ray = FlutterV2ray(
    onStatusChanged: (V2RayStatus s) {
      _coreState = s.state;
      // Running totals for the session, in bytes.
      _uploadBytes = s.upload;
      _downloadBytes = s.download;
      if (s.state == 'CONNECTED') {
        _status = TunnelStatus.connected;
      } else if (s.state == 'DISCONNECTED') {
        final stoppedFromOutside = !_stopping &&
            _mode == XrayMode.seller &&
            _status == TunnelStatus.connected;
        _status = TunnelStatus.idle;
        if (stoppedFromOutside) {
          // e.g. the notification's DISCONNECT button. The plugin's stop
          // leaves the bridge connection open, so end the process here too.
          debugPrint('[XrayService] core stopped outside the app');
          _mode = XrayMode.idle;
          _currentSessionId = null;
          unawaited(_endTunnelProcess());
        }
      }
      notifyListeners();
    },
  );

  XrayMode get mode => _mode;
  TunnelStatus get status => _status;
  String? get currentSessionId => _currentSessionId;
  String? get errorMessage => _errorMessage;
  int get uploadBytes => _uploadBytes;
  int get downloadBytes => _downloadBytes;
  bool get isActive => _status == TunnelStatus.connected;

  Future<void> init() async {
    await _v2ray.initializeV2Ray(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    debugPrint('[XrayService] flutter_v2ray initialized');
  }

  // ── BUYER SIDE ──────────────────────────────────────────────────────────────

  /// Connect as buyer using a VLESS URI returned by the backend.
  /// The URI encodes relay address, port, session UUID, and Reality params.
  /// flutter_v2ray parses it and creates a VPN TUN interface.
  Future<bool> connectAsBuyer(String vlessUri, String sessionId) async {
    if (_proxyOnlyLatched) {
      _setError(
        'This phone shared data earlier in this app session. '
        'Close and reopen the app before using a friend\'s data.',
      );
      return false;
    }
    try {
      debugPrint('[XrayService] connectAsBuyer: $sessionId');
      _mode = XrayMode.buyer;
      _currentSessionId = sessionId;
      _status = TunnelStatus.connecting;
      _errorMessage = null;
      notifyListeners();

      // Request VPN permission from the user (shows Android system dialog).
      final permissionGranted = await _v2ray.requestPermission();
      if (!permissionGranted) {
        _setError('VPN permission denied');
        return false;
      }

      // Parse the VLESS URI into a V2RayURL object.
      final v2rayUrl = FlutterV2ray.parseFromURL(vlessUri);

      // Start the VPN service with the parsed config.
      await _v2ray.startV2Ray(
        remark: 'DataBric session $sessionId',
        config: v2rayUrl.getFullConfiguration(),
        proxyOnly: false, // use full VPN mode
      );

      _status = TunnelStatus.connected;
      notifyListeners();
      return true;
    } catch (e) {
      _setError('Tunnel error: $e');
      return false;
    }
  }

  // ── SELLER SIDE ─────────────────────────────────────────────────────────────

  /// Start as seller with a full Xray reverse-bridge config (JSON).
  ///
  /// Returns true once the core reports it is running. That means the bridge
  /// is up on this phone; it does not prove the relay accepted it. The relay
  /// log is where you see the bridge arrive.
  Future<bool> startAsSeller(String sellerConfig, String sessionId) async {
    if (_status == TunnelStatus.connecting ||
        _status == TunnelStatus.connected) {
      debugPrint('[XrayService] startAsSeller ignored: a tunnel is running');
      return false;
    }

    // The backend still hands sellers a VLESS URI, which cannot describe a
    // bridge. Until it returns a bridge config, the normal share flow keeps
    // its placeholder behaviour: the UI shows a session, no tunnel runs.
    if (sellerConfig.trimLeft().startsWith('vless://')) {
      debugPrint('[XrayService] startAsSeller: got a VLESS URI, not a bridge '
          'config. PLACEHOLDER ONLY, no tunnel started.');
      _mode = XrayMode.seller;
      _currentSessionId = sessionId;
      _errorMessage = null;
      _status = TunnelStatus.connected;
      notifyListeners();
      return true;
    }

    try {
      debugPrint('[XrayService] startAsSeller: $sessionId');
      _mode = XrayMode.seller;
      _currentSessionId = sessionId;
      _status = TunnelStatus.connecting;
      _errorMessage = null;
      _coreState = null;
      notifyListeners();

      // On Android 13+ the core's service is only kept alive if it can show
      // its notification. Without the permission it is killed after a few
      // seconds.
      final notifications = await Permission.notification.request();
      if (!notifications.isGranted) {
        _setError('Allow notifications so the tunnel can keep running');
        return false;
      }

      _proxyOnlyLatched = true;
      await _v2ray.startV2Ray(
        remark: 'DataBric sharing $sessionId',
        config: sellerConfig,
        proxyOnly: true,
      );

      // startV2Ray returns even when the plugin rejected the config, so wait
      // for the core itself to report in.
      if (!await _waitForCore()) {
        try {
          await _v2ray.stopV2Ray();
        } catch (_) {}
        _setError('Xray core did not start. See adb logcat, tag '
            'V2rayCoreManager.');
        return false;
      }

      _status = TunnelStatus.connected;
      notifyListeners();
      return true;
    } catch (e) {
      _setError('Tunnel error: $e');
      return false;
    }
  }

  Future<bool> _waitForCore({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_coreState == 'CONNECTED') return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  // ── SHARED ──────────────────────────────────────────────────────────────────

  Future<void> stopTunnel() async {
    debugPrint('[XrayService] stopTunnel');
    _stopping = true;
    try {
      try {
        await _v2ray.stopV2Ray();
      } catch (e) {
        debugPrint('[XrayService] stopV2Ray failed: $e');
      }
      final error = await _endTunnelProcess();
      _mode = XrayMode.idle;
      _status = error == null ? TunnelStatus.idle : TunnelStatus.error;
      _currentSessionId = null;
      _coreState = null;
      _uploadBytes = 0;
      _downloadBytes = 0;
      _errorMessage = error;
      notifyListeners();
    } finally {
      _stopping = false;
    }
  }

  /// Ends the core's process and checks it is gone. Returns null on success,
  /// or a message saying the tunnel may still be running.
  Future<String?> _endTunnelProcess() async {
    try {
      // Let the plugin finish its own stop first (status broadcast, notification).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final ended =
          await _tunnelProcess.invokeMethod<int>('endTunnelProcess') ?? 0;
      debugPrint('[XrayService] ended $ended tunnel process(es)');
      for (var i = 0; i < 10; i++) {
        final alive =
            await _tunnelProcess.invokeMethod<bool>('isTunnelProcessAlive') ??
                false;
        if (!alive) return null;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return 'Tunnel process is still running. Force-stop the app to cut it.';
    } catch (e) {
      debugPrint('[XrayService] could not end tunnel process: $e');
      return 'Could not confirm the tunnel stopped ($e). '
          'Force-stop the app to be sure.';
    }
  }

  void _setError(String msg) {
    debugPrint('[XrayService] ERROR: $msg');
    _errorMessage = msg;
    _status = TunnelStatus.error;
    _mode = XrayMode.idle;
    notifyListeners();
  }
}
