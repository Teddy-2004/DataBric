import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:databric/models/models.dart';
import 'package:databric/providers/auth_provider.dart';
import 'package:databric/providers/session_provider.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/widgets/widgets.dart';
import 'package:databric/screens/share_screen.dart';
import 'package:databric/screens/history_screen.dart';
import 'package:databric/screens/friends_screen.dart';
import 'package:databric/screens/profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    _HomeTab(),
    ShareDataScreen(),
    HistoryScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.border, width: 0.5)),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          backgroundColor: AppTheme.surface,
          elevation: 0,
          indicatorColor: AppTheme.primaryLight,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.swap_horiz_outlined),
              selectedIcon: Icon(Icons.swap_horiz_rounded),
              label: 'Share',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history_rounded),
              label: 'History',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Home tab ───────────────────────────────────────────────────

class _HomeTab extends StatefulWidget {
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  bool _historyLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SessionProvider>().loadHistory().then((_) {
        if (mounted) setState(() => _historyLoaded = true);
      });
    });
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning,';
    if (hour < 18) return 'Good afternoon,';
    return 'Good evening,';
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final session = context.watch<SessionProvider>();
    final displayName = auth.user?.name ?? '';
    final recentSessions = session.history.take(3).toList();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          // Greeting
          Text(_greeting(), style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 2),
          Text(displayName, style: Theme.of(context).textTheme.displayLarge),
          const SizedBox(height: 20),

          // Active session banner
          if (session.hasActiveSession)
            _ActiveSessionBanner(
              role: session.role,
              usedGb: session.usedGb,
              limitGb: session.limitGb,
              usagePercent: session.usagePercent,
            ),

          // Balance card — carrier-balance integration is TODO. Until we
          // have a real source for the user's monthly allowance we show
          // dashes rather than fake numbers.
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Available to share'),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '—',
                      style: Theme.of(context).textTheme.displayLarge?.copyWith(fontSize: 40),
                    ),
                    const Spacer(),
                    Text(
                      'Connect your carrier to track usage',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Quick actions
          Row(
            children: [
              Expanded(
                child: _QuickAction(
                  icon: Icons.upload_rounded,
                  label: 'Share data',
                  color: AppTheme.primary,
                  bgColor: AppTheme.primaryLight,
                  onTap: () {
                    final homeState = context.findAncestorStateOfType<_HomeScreenState>();
                    homeState?.setState(() => homeState._currentIndex = 1);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickAction(
                  icon: Icons.download_rounded,
                  label: 'Use data',
                  color: AppTheme.blue,
                  bgColor: AppTheme.blueLight,
                  onTap: () {
                    final homeState = context.findAncestorStateOfType<_HomeScreenState>();
                    homeState?.setState(() => homeState._currentIndex = 1);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickAction(
                  icon: Icons.people_outline_rounded,
                  label: 'Friends',
                  color: AppTheme.amber,
                  bgColor: AppTheme.amberLight,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FriendsScreen()),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Recent activity (real data from /sessions/history)
          const SectionLabel('Recent activity'),
          if (!_historyLoaded)
            const SurfaceCard(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          else if (recentSessions.isEmpty)
            SurfaceCard(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No activity yet — share data with a friend to get started.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SurfaceCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: recentSessions.asMap().entries.map((e) {
                  final s = e.value;
                  final isLast = e.key == recentSessions.length - 1;
                  return Column(
                    children: [
                      _ActivityRow(session: s),
                      if (!isLast)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: RowDivider(),
                        ),
                    ],
                  );
                }).toList(),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Active session banner ──────────────────────────────────────

class _ActiveSessionBanner extends StatelessWidget {
  final SessionRole role;
  final double usedGb;
  final double limitGb;
  final double usagePercent;

  const _ActiveSessionBanner({
    required this.role,
    required this.usedGb,
    required this.limitGb,
    required this.usagePercent,
  });

  @override
  Widget build(BuildContext context) {
    final isSeller = role == SessionRole.seller;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 10, height: 10,
            decoration: const BoxDecoration(
              color: AppTheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSeller ? 'Sharing active' : 'Using friend\'s data',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.primaryDark,
                  ),
                ),
                Text(
                  '${usedGb.toStringAsFixed(2)} / ${limitGb.toStringAsFixed(1)} GB',
                  style: const TextStyle(fontSize: 12, color: AppTheme.primaryDark),
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 60,
              child: LinearProgressIndicator(
                value: usagePercent,
                backgroundColor: AppTheme.primary.withOpacity(0.2),
                valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
                minHeight: 6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Quick action button ────────────────────────────────────────

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color bgColor;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.bgColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.border, width: 0.5),
        ),
        child: Column(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w400,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Activity row ───────────────────────────────────────────────

class _ActivityRow extends StatelessWidget {
  final SharingSession session;
  const _ActivityRow({required this.session});

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.isNegative) return 'Just now';
    if (diff.inHours < 1) return 'Just now';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final isSent = session.direction == SessionDirection.sent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          DirectionIcon(direction: session.direction),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.friendName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14),
                ),
                Text(
                  '${session.friendCarrier} · ${_timeAgo(session.createdAt)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          Text(
            '${isSent ? '−' : '+'}${session.amountLabel}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isSent ? AppTheme.sent : AppTheme.received,
            ),
          ),
        ],
      ),
    );
  }
}
