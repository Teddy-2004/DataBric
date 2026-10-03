import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:databric/providers/auth_provider.dart';
import 'package:databric/providers/session_provider.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/widgets/widgets.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _signOut(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Sign out',
              style: TextStyle(color: AppTheme.sent),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    // Close any in-progress session before clearing the token so the
    // backend records a proper end and the tunnel stops cleanly. We must
    // do this BEFORE signOut(), since after the JWT is cleared the
    // /sessions/stop call would 401.
    final session = context.read<SessionProvider>();
    if (session.role == SessionRole.seller) {
      await session.stopSharing();
    } else if (session.role == SessionRole.buyer) {
      await session.disconnect();
    }

    if (!context.mounted) return;
    await context.read<AuthProvider>().signOut();
    // _AppEntry will swap to LoginScreen automatically once
    // AuthProvider.status flips.
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    final name = user?.name ?? '';
    final phone = user?.phoneNumber ?? '';
    final carrier = user?.carrier ?? '';
    final city = user?.city ?? '';
    final country = user?.country ?? '';

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          Text('Profile', style: Theme.of(context).textTheme.displayLarge),
          const SizedBox(height: 20),

          // Avatar + name
          Center(
            child: Column(
              children: [
                Container(
                  width: 72, height: 72,
                  decoration: const BoxDecoration(
                    color: AppTheme.primaryLight,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.primaryDark,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(name, style: Theme.of(context).textTheme.headlineMedium),
                Text(phone, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Account
          const SectionLabel('Account'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _ProfileRow(
                  icon: Icons.phone_android_rounded,
                  label: 'Phone number',
                  value: phone,
                ),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: RowDivider()),
                _ProfileRow(
                  icon: Icons.signal_cellular_alt_rounded,
                  label: 'Carrier',
                  value: carrier.isNotEmpty ? carrier : 'Not set',
                ),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: RowDivider()),
                _ProfileRow(
                  icon: Icons.location_on_outlined,
                  label: 'Location',
                  value: [city, country].where((s) => s.isNotEmpty).join(', '),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Settings
          const SectionLabel('Settings'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _ProfileRow(
                  icon: Icons.notifications_outlined,
                  label: 'Notifications',
                  value: 'On',
                  showChevron: true,
                  onTap: () {},
                ),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: RowDivider()),
                _ProfileRow(
                  icon: Icons.security_outlined,
                  label: 'Privacy & security',
                  value: '',
                  showChevron: true,
                  onTap: () {},
                ),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: RowDivider()),
                _ProfileRow(
                  icon: Icons.help_outline_rounded,
                  label: 'Help & feedback',
                  value: '',
                  showChevron: true,
                  onTap: () {},
                ),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: RowDivider()),
                _ProfileRow(
                  icon: Icons.info_outline_rounded,
                  label: 'About DataBric',
                  value: 'v1.0.0',
                  showChevron: true,
                  onTap: () {},
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Sign out
          SurfaceCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: const Icon(
                Icons.logout_rounded,
                color: AppTheme.sent,
                size: 20,
              ),
              title: const Text(
                'Sign out',
                style: TextStyle(
                  color: AppTheme.sent,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onTap: () => _signOut(context),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool showChevron;
  final VoidCallback? onTap;

  const _ProfileRow({
    required this.icon,
    required this.label,
    required this.value,
    this.showChevron = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20, color: AppTheme.textSecondary),
      title: Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value.isNotEmpty)
            Text(value, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          if (showChevron)
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textTertiary, size: 18),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      onTap: onTap,
    );
  }
}
