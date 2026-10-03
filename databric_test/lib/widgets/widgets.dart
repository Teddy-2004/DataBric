import 'package:flutter/material.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/models/models.dart';

// ── Avatar ─────────────────────────────────────────────────────
class FriendAvatar extends StatelessWidget {
  final Friend friend;
  final double size;

  const FriendAvatar({super.key, required this.friend, this.size = 40});

  Color _bgColor() {
    final colors = [AppTheme.primaryLight, AppTheme.blueLight, AppTheme.amberLight, AppTheme.sentLight];
    return colors[friend.id.hashCode % colors.length];
  }

  Color _fgColor() {
    final colors = [AppTheme.primaryDark, AppTheme.blue, AppTheme.amber, AppTheme.sent];
    return colors[friend.id.hashCode % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: _bgColor(), shape: BoxShape.circle),
      child: Center(
        child: Text(
          friend.initials,
          style: TextStyle(fontSize: size * 0.35, fontWeight: FontWeight.w500, color: _fgColor()),
        ),
      ),
    );
  }
}

// ── Section label ──────────────────────────────────────────────
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

// ── Surface card ──────────────────────────────────────────────
class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;

  const SurfaceCard({super.key, required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border, width: 0.5),
      ),
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );
  }
}

// ── Divider row ────────────────────────────────────────────────
class RowDivider extends StatelessWidget {
  const RowDivider({super.key});
  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, thickness: 0.5, color: AppTheme.border);
  }
}

// ── Amount display ─────────────────────────────────────────────
class AmountLabel extends StatelessWidget {
  final double gb;
  final double fontSize;

  const AmountLabel({super.key, required this.gb, this.fontSize = 42});

  @override
  Widget build(BuildContext context) {
    final isGb = gb >= 1;
    final value = isGb ? (gb % 1 == 0 ? gb.toInt().toString() : gb.toString()) : (gb * 1024).round().toString();
    final unit = isGb ? 'GB' : 'MB';

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
        const SizedBox(width: 4),
        Text(unit, style: TextStyle(fontSize: fontSize * 0.38, color: AppTheme.textSecondary)),
      ],
    );
  }
}

// ── Direction icon ─────────────────────────────────────────────
class DirectionIcon extends StatelessWidget {
  final SessionDirection direction;
  const DirectionIcon({super.key, required this.direction});

  @override
  Widget build(BuildContext context) {
    final isSent = direction == SessionDirection.sent;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isSent ? AppTheme.sentLight : AppTheme.receivedLight,
        shape: BoxShape.circle,
      ),
      child: Icon(
        isSent ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
        size: 16,
        color: isSent ? AppTheme.sent : AppTheme.received,
      ),
    );
  }
}

// ── Status badge ───────────────────────────────────────────────
class StatusBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;

  const StatusBadge({super.key, required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg)),
    );
  }
}
