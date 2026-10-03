import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:databric/models/models.dart';
import 'package:databric/providers/session_provider.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/widgets/widgets.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = context.read<SessionProvider>();
    await session.loadHistory();
    if (mounted) setState(() => _loaded = true);
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inHours < 1) return 'Just now';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final sessions = session.history;

    // Calculate totals
    final totalSentGb = sessions
        .where((s) => s.direction == SessionDirection.sent)
        .fold(0.0, (sum, s) => sum + s.amountGb);
    final totalReceivedGb = sessions
        .where((s) => s.direction == SessionDirection.received)
        .fold(0.0, (sum, s) => sum + s.amountGb);

    // Group by date label
    final grouped = <String, List<SharingSession>>{};
    for (final s in sessions) {
      final diff = DateTime.now().difference(s.createdAt);
      String label;
      if (diff.inDays == 0) {
        label = 'Today';
      } else if (diff.inDays == 1) {
        label = 'Yesterday';
      } else if (diff.inDays < 7) {
        label = 'This week';
      } else {
        label = 'Earlier';
      }
      grouped.putIfAbsent(label, () => []).add(s);
    }

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primary,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('History', style: Theme.of(context).textTheme.displayLarge),
                if (!_loaded)
                  const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // Stats
            Row(
              children: [
                Expanded(
                  child: SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionLabel('Total sent'),
                        AmountLabel(gb: totalSentGb, fontSize: 24),
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
                        const SectionLabel('Total received'),
                        AmountLabel(gb: totalReceivedGb, fontSize: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            if (sessions.isEmpty)
              SurfaceCard(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                      'No transfers yet.\nShare data with a friend to get started.',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else
              ...grouped.entries.map((entry) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionLabel(entry.key),
                  SurfaceCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: entry.value.asMap().entries.map((e) {
                        final s = e.value;
                        final isLast = e.key == entry.value.length - 1;
                        final isSent = s.direction == SessionDirection.sent;
                        return Column(
                          children: [
                            ListTile(
                              leading: DirectionIcon(direction: s.direction),
                              title: Text(
                                s.friendName,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontSize: 14),
                              ),
                              subtitle: Text(
                                '${s.friendCarrier} · ${_formatDate(s.createdAt)}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              trailing: Text(
                                '${isSent ? '−' : '+'}${s.amountLabel}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: isSent ? AppTheme.sent : AppTheme.received,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            ),
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
                  const SizedBox(height: 20),
                ],
              )),
          ],
        ),
      ),
    );
  }
}
