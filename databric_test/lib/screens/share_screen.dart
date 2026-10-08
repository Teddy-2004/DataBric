import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:databric/debug/debug_seller_tunnel_card.dart';
import 'package:databric/models/models.dart';
import 'package:databric/providers/friends_provider.dart';
import 'package:databric/providers/session_provider.dart';
import 'package:databric/services/xray_service.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/widgets/widgets.dart';

// Placeholder until carrier balance API is available.
const double _kAvailableGb = 10.0;
const double _kTotalGb = 10.0;

class ShareDataScreen extends StatelessWidget {
  const ShareDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final xray = context.watch<XrayService>();

    if (session.hasActiveSession) {
      return _ActiveSessionView(
        role: session.role,
        usedGb: session.usedGb,
        limitGb: session.limitGb,
        usagePercent: session.usagePercent,
        xrayStatus: xray.status,
        uploadBytes: xray.uploadBytes,
        downloadBytes: xray.downloadBytes,
        onStop: session.role == SessionRole.seller
            ? () => session.stopSharing()
            : () => session.disconnect(),
        isLoading: session.isLoading,
      );
    }

    return const _IdleView();
  }
}

class _IdleView extends StatefulWidget {
  const _IdleView();

  @override
  State<_IdleView> createState() => _IdleViewState();
}

class _IdleViewState extends State<_IdleView>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  double _shareAmountGb = 2.0;
  Friend? _selectedReceiver;
  final TextEditingController _amountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _amountController.text = _formatGb(_shareAmountGb);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _tab.dispose();
    super.dispose();
  }

  String _formatGb(double value) {
    final formatted = value.toStringAsFixed(2);
    return formatted.endsWith('.00') ? formatted.split('.').first : formatted;
  }

  void _updateAmount(double newValue) {
    const maxGb = _kAvailableGb;
    final clamped = newValue.clamp(0.5, maxGb).toDouble();
    setState(() {
      _shareAmountGb = clamped;
      _amountController.text = _formatGb(clamped);
    });
  }

  void _onManualInputChanged(String value) {
    if (value.isEmpty) return;
    final input = double.tryParse(value);
    if (input != null) _updateAmount(input);
  }

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<FriendsProvider>();
    final session = context.watch<SessionProvider>();
    const maxGb = _kAvailableGb;
    final hasFriends = friends.accepted.isNotEmpty;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text('Share Data',
                style: Theme.of(context).textTheme.displayLarge),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border, width: 0.5),
              ),
              child: TabBar(
                controller: _tab,
                labelColor: AppTheme.textPrimary,
                unselectedLabelColor: AppTheme.textSecondary,
                indicator: BoxDecoration(
                  color: AppTheme.background,
                  borderRadius: BorderRadius.circular(10),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                padding: const EdgeInsets.all(4),
                tabs: const [
                  Tab(text: 'Share my data'),
                  Tab(text: "Use friend's data"),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    SurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SectionLabel('Available to share'),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              AmountLabel(gb: _kAvailableGb, fontSize: 36),
                              const Spacer(),
                              Text('of ${_kTotalGb.toInt()} GB',
                                  style: Theme.of(context).textTheme.bodyMedium),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: _kAvailableGb / _kTotalGb,
                              backgroundColor: AppTheme.border,
                              valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                              minHeight: 4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    SectionLabel('Share with'),
                    if (!hasFriends)
                      SurfaceCard(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              Icon(Icons.people_outline_rounded,
                                  size: 48, color: AppTheme.textTertiary),
                              const SizedBox(height: 12),
                              Text('No friends yet',
                                  style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              Text(
                                'Add friends to start sharing data',
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (_selectedReceiver != null)
                      _SelectedFriendCard(
                        friend: _selectedReceiver!,
                        onClear: () => setState(() => _selectedReceiver = null),
                      )
                    else
                      _buildFriendPicker(context, friends.accepted),
                    const SizedBox(height: 16),
                    if (_selectedReceiver != null) ...[
                      SectionLabel('How much to share'),
                      SurfaceCard(
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 140,
                                  child: TextField(
                                    controller: _amountController,
                                    textAlign: TextAlign.center,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    style: Theme.of(context)
                                        .textTheme
                                        .displayLarge
                                        ?.copyWith(fontSize: 48, fontWeight: FontWeight.w600),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                    onChanged: _onManualInputChanged,
                                  ),
                                ),
                                const Text(' GB',
                                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w500)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                _CircleBtn(
                                    icon: Icons.remove,
                                    onTap: () => _updateAmount(_shareAmountGb - 0.5)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Slider(
                                    value: _shareAmountGb,
                                    min: 0.5,
                                    max: maxGb,
                                    divisions: ((maxGb - 0.5) / 0.5).round(),
                                    onChanged: _updateAmount,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _CircleBtn(
                                    icon: Icons.add,
                                    onTap: () => _updateAmount(_shareAmountGb + 0.5)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded,
                                size: 18, color: AppTheme.primaryDark),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Only ${_selectedReceiver!.name.split(" ").first} can connect to this session.',
                                style: const TextStyle(fontSize: 12, color: AppTheme.primaryDark),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (session.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(session.error!,
                            style: TextStyle(color: AppTheme.sent, fontSize: 13)),
                      ),
                    ElevatedButton(
                      onPressed: (session.isLoading || _selectedReceiver == null)
                          ? null
                          : () => session.startSharing(
                                _shareAmountGb,
                                receiverId: _selectedReceiver!.id,
                              ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _selectedReceiver == null ? AppTheme.border : AppTheme.primary,
                        minimumSize: const Size(double.infinity, 52),
                      ),
                      child: session.isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              _selectedReceiver == null
                                  ? 'Select a friend to continue'
                                  : 'Share ${_formatGb(_shareAmountGb)}GB with '
                                      '${_selectedReceiver!.name.split(" ").first}',
                            ),
                    ),
                    const DebugSellerTunnelCard(),
                    const SizedBox(height: 24),
                  ],
                ),
                const _BuyerTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendPicker(BuildContext context, List<Friend> friends) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          ...friends.asMap().entries.map((e) {
            final friend = e.value;
            final isLast = e.key == friends.length - 1;
            return Column(
              children: [
                ListTile(
                  leading: FriendAvatar(friend: friend),
                  title: Text(friend.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14)),
                  subtitle: Text('${friend.carrier} · ${friend.city}',
                      style: Theme.of(context).textTheme.bodyMedium),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textTertiary),
                  onTap: () => setState(() => _selectedReceiver = friend),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                ),
                if (!isLast) RowDivider(),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _BuyerTab extends StatelessWidget {
  const _BuyerTab();

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<FriendsProvider>().accepted;
    final session = context.watch<SessionProvider>();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        SectionLabel('Connect to a friend'),
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: AppTheme.blueLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: AppTheme.blue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Your friend must start sharing and select you before you can connect.',
                  style: TextStyle(fontSize: 12, color: AppTheme.blue),
                ),
              ),
            ],
          ),
        ),
        if (friends.isEmpty)
          SurfaceCard(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.people_outline_rounded, size: 48, color: AppTheme.textTertiary),
                  const SizedBox(height: 12),
                  Text('No friends yet', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          )
        else
          SurfaceCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: friends.asMap().entries.map((e) {
                final friend = e.value;
                final isLast = e.key == friends.length - 1;
                return Column(
                  children: [
                    ListTile(
                      leading: FriendAvatar(friend: friend),
                      title: Text(friend.name,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14)),
                      subtitle: Text('${friend.carrier} · ${friend.city}',
                          style: Theme.of(context).textTheme.bodyMedium),
                      trailing: ElevatedButton(
                        onPressed: session.isLoading
                            ? null
                            : () => session.connectToFriend(friend.id),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(80, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: const Text('Connect'),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    ),
                    if (!isLast) RowDivider(),
                  ],
                );
              }).toList(),
            ),
          ),
        if (session.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(session.error!, style: TextStyle(color: AppTheme.sent, fontSize: 13)),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ActiveSessionView extends StatelessWidget {
  final SessionRole role;
  final double usedGb;
  final double limitGb;
  final double usagePercent;
  final TunnelStatus xrayStatus;
  final int uploadBytes;
  final int downloadBytes;
  final VoidCallback onStop;
  final bool isLoading;

  const _ActiveSessionView({
    required this.role,
    required this.usedGb,
    required this.limitGb,
    required this.usagePercent,
    required this.xrayStatus,
    required this.uploadBytes,
    required this.downloadBytes,
    required this.onStop,
    required this.isLoading,
  });

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = xrayStatus == TunnelStatus.connected;
    final statusColor = isConnected ? AppTheme.primary : AppTheme.amber;
    final statusLabel = isConnected
        ? (role == SessionRole.seller ? 'Sharing active' : 'Connected')
        : 'Connecting...';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              role == SessionRole.seller ? 'Sharing Data' : "Using Friend's Data",
              style: Theme.of(context).textTheme.displayLarge,
            ),
            const SizedBox(height: 20),
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(statusLabel,
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500, color: statusColor)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SectionLabel('Data used'),
                          AmountLabel(gb: usedGb, fontSize: 32),
                        ],
                      ),
                      const Spacer(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SectionLabel('Limit'),
                          AmountLabel(gb: limitGb, fontSize: 32),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: usagePercent,
                      backgroundColor: AppTheme.border,
                      valueColor: AlwaysStoppedAnimation(
                          usagePercent > 0.9 ? AppTheme.sent : AppTheme.primary),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('${(usagePercent * 100).toStringAsFixed(1)}% used',
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionLabel('Upload'),
                        Text(_formatBytes(uploadBytes),
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionLabel('Download'),
                        Text(_formatBytes(downloadBytes),
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isLoading ? null : onStop,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.sent,
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        role == SessionRole.seller ? 'Stop sharing' : 'Disconnect',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectedFriendCard extends StatelessWidget {
  final Friend friend;
  final VoidCallback onClear;

  const _SelectedFriendCard({required this.friend, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Row(
        children: [
          FriendAvatar(friend: friend, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(friend.name, style: Theme.of(context).textTheme.titleMedium),
                Text('${friend.carrier} · ${friend.city}, ${friend.country}',
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          GestureDetector(
            onTap: onClear,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: AppTheme.border, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, size: 14, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppTheme.border),
          color: AppTheme.surface,
        ),
        child: Icon(icon, size: 18, color: AppTheme.textPrimary),
      ),
    );
  }
}
