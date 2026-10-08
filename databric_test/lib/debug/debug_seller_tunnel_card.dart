import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:databric/debug/static_tunnel_test.dart';
import 'package:databric/services/xray_service.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/widgets/widgets.dart';

/// Debug-only control for the static reverse-tunnel test.
///
/// Starts the seller bridge with the hardcoded config in
/// static_tunnel_test.dart. No backend session is created. Renders nothing in
/// release builds.
class DebugSellerTunnelCard extends StatefulWidget {
  const DebugSellerTunnelCard({super.key});

  @override
  State<DebugSellerTunnelCard> createState() => _DebugSellerTunnelCardState();
}

class _DebugSellerTunnelCardState extends State<DebugSellerTunnelCard> {
  bool _busy = false;

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _toggle(XrayService xray, bool running) async {
    setState(() => _busy = true);
    try {
      if (running) {
        await xray.stopTunnel();
      } else {
        await xray.startAsSeller(kStaticSellerTestConfig, kStaticTestSessionId);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();

    final xray = context.watch<XrayService>();
    final isStaticTest = xray.mode == XrayMode.seller &&
        xray.currentSessionId == kStaticTestSessionId;
    final running = isStaticTest &&
        (xray.status == TunnelStatus.connecting ||
            xray.status == TunnelStatus.connected);

    final String statusText;
    if (!isStaticTest) {
      statusText = 'Stopped';
    } else if (xray.status == TunnelStatus.connected) {
      statusText = 'Core running. Check the laptop for the result.';
    } else if (xray.status == TunnelStatus.connecting) {
      statusText = 'Starting core...';
    } else {
      statusText = 'Stopped';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('Debug: static seller tunnel'),
            Text(
              'Bridges to a relay on 127.0.0.1:9443 through adb reverse. '
              'Turn Wi-Fi off first. No backend session is created.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(statusText, style: Theme.of(context).textTheme.titleMedium),
            if (running) ...[
              const SizedBox(height: 4),
              Text(
                'To relay ${_formatBytes(xray.uploadBytes)}  ·  '
                'From relay ${_formatBytes(xray.downloadBytes)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (!running && xray.errorMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                xray.errorMessage!,
                style: const TextStyle(color: AppTheme.sent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _toggle(xray, running),
              child: Text(running ? 'Stop seller tunnel' : 'Start seller tunnel'),
            ),
          ],
        ),
      ),
    );
  }
}
