import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:databric/models/models.dart';
import 'package:databric/providers/friends_provider.dart';
import 'package:databric/screens/friends_screen.dart';
import 'package:databric/providers/session_provider.dart';
import 'package:databric/services/xray_service.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/widgets/widgets.dart';

// Limits a sharer can pick. The backend accepts any value; these keep the
// choice quick. The sharer's real carrier balance isn't known to the app.
const List<double> _kLimitOptionsGb = [0.5, 1, 2, 5, 10];

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
  double _limitGb = 1;
  Friend? _selectedReceiver;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _formatGb(double gb) {
    if (gb < 1) return '${(gb * 1024).round()} MB';
    return gb % 1 == 0 ? '${gb.toInt()} GB' : '${gb.toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<FriendsProvider>();
    final session = context.watch<SessionProvider>();
    final accepted = friends.accepted;
    // Drop a selection whose friendship went away (removed, blocked).
    final selected = accepted
        .where((f) => f.id == _selectedReceiver?.id)
        .firstOrNull;

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
                  Tab(text: "Use a friend's data"),
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
                    const _InfoBanner(
                      icon: Icons.wifi_tethering_rounded,
                      text: 'Let a friend use your mobile data. Their phone '
                          'connects through yours until they reach the limit '
                          'you set.',
                    ),
                    const SizedBox(height: 20),
                    const SectionLabel('1. Who can use it'),
                    if (friends.isLoading && accepted.isEmpty)
                      const _LoadingCard()
                    else if (accepted.isEmpty)
                      const _NoFriendsCard(
                        message:
                            'You can only share data with friends on DataBric.',
                      )
                    else if (selected != null)
                      _SelectedFriendCard(
                        friend: selected,
                        onClear: () => setState(() => _selectedReceiver = null),
                      )
                    else
                      _FriendList(
                        friends: accepted,
                        trailing: (_) => const Icon(Icons.chevron_right_rounded,
                            color: AppTheme.textTertiary),
                        onTap: (f) => setState(() => _selectedReceiver = f),
                      ),
                    if (selected != null) ...[
                      const SizedBox(height: 24),
                      const SectionLabel('2. Set a limit'),
                      SurfaceCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AmountLabel(gb: _limitGb, fontSize: 36),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final gb in _kLimitOptionsGb)
                                  ChoiceChip(
                                    label: Text(_formatGb(gb)),
                                    selected: _limitGb == gb,
                                    onSelected: (_) =>
                                        setState(() => _limitGb = gb),
                                    selectedColor: AppTheme.primaryLight,
                                    showCheckmark: false,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Sharing stops by itself when ${selected.shortName} '
                              'has used ${_formatGb(_limitGb)}. You can stop '
                              'earlier at any time.',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (session.error != null) _ErrorText(session.error!),
                      ElevatedButton(
                        onPressed: session.isLoading
                            ? null
                            : () => session.startSharing(
                                  _limitGb,
                                  receiverId: selected.id,
                                ),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 52),
                        ),
                        child: session.isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Text('Start sharing with ${selected.shortName}'),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Only ${selected.shortName} can connect. Keep DataBric '
                        'running and your phone online while sharing.',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ] else if (session.error != null) ...[
                      const SizedBox(height: 16),
                      _ErrorText(session.error!),
                    ],
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
}

class _BuyerTab extends StatelessWidget {
  const _BuyerTab();

  @override
  Widget build(BuildContext context) {
    final friendsProvider = context.watch<FriendsProvider>();
    final friends = friendsProvider.accepted;
    final session = context.watch<SessionProvider>();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        const _InfoBanner(
          icon: Icons.info_outline_rounded,
          text: 'Ask a friend to start sharing with you, then tap Connect '
              'next to their name.',
          color: AppTheme.blue,
          background: AppTheme.blueLight,
        ),
        const SizedBox(height: 20),
        const SectionLabel('Your friends'),
        if (friendsProvider.isLoading && friends.isEmpty)
          const _LoadingCard()
        else if (friends.isEmpty)
          const _NoFriendsCard(
            message: "Add the friend whose data you'd like to use.",
          )
        else
          _FriendList(
            friends: friends,
            trailing: (friend) => ElevatedButton(
              onPressed: session.isLoading
                  ? null
                  : () => session.connectToFriend(friend.id),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(80, 36),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('Connect'),
            ),
          ),
        if (session.error != null) ...[
          const SizedBox(height: 12),
          _ErrorText(session.error!),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final Color background;

  const _InfoBanner({
    required this.icon,
    required this.text,
    this.color = AppTheme.primaryDark,
    this.background = AppTheme.primaryLight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13, color: color)),
          ),
        ],
      ),
    );
  }
}

/// Shown when there are no accepted friends: says why and offers the way out.
class _NoFriendsCard extends StatelessWidget {
  final String message;
  const _NoFriendsCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final waiting = context.watch<FriendsProvider>().outgoingPending;
    final textTheme = Theme.of(context).textTheme;

    return SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          children: [
            const Icon(Icons.people_outline_rounded,
                size: 44, color: AppTheme.textTertiary),
            const SizedBox(height: 12),
            Text('Add a friend first', style: textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(message, style: textTheme.bodyMedium, textAlign: TextAlign.center),
            if (waiting.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                waiting.length == 1
                    ? 'Waiting for ${waiting.first.name} to accept your invite.'
                    : 'Waiting for ${waiting.length} friends to accept your invites.',
                style: textTheme.bodyMedium?.copyWith(color: AppTheme.amber),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FriendsScreen()),
              ),
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: Text(waiting.isEmpty ? 'Add a friend' : 'Manage friends'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const SurfaceCard(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _FriendList extends StatelessWidget {
  final List<Friend> friends;
  final Widget Function(Friend) trailing;
  final void Function(Friend)? onTap;

  const _FriendList({required this.friends, required this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          for (final (i, friend) in friends.indexed) ...[
            ListTile(
              leading: FriendAvatar(friend: friend),
              title: Text(friend.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14)),
              subtitle: friend.details.isEmpty
                  ? null
                  : Text(friend.details,
                      style: Theme.of(context).textTheme.bodyMedium),
              trailing: trailing(friend),
              onTap: onTap == null ? null : () => onTap!(friend),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            ),
            if (i < friends.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: RowDivider(),
              ),
          ],
        ],
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  final String text;
  const _ErrorText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: const TextStyle(color: AppTheme.sent, fontSize: 13)),
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
                          const SectionLabel('Data used'),
                          AmountLabel(gb: usedGb, fontSize: 32),
                        ],
                      ),
                      const Spacer(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const SectionLabel('Limit'),
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
                        const SectionLabel('Upload'),
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
                        const SectionLabel('Download'),
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
                if (friend.details.isNotEmpty)
                  Text(friend.details,
                      style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          GestureDetector(
            onTap: onClear,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(color: AppTheme.border, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, size: 14, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
