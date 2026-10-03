import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:databric/models/models.dart';
import 'package:databric/providers/friends_provider.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/widgets/widgets.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  bool _isInviting = false;
  String? _inviteError;
  final _inviteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Refresh on entry — the list may be stale after accepting an invite
    // from a notification, etc.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FriendsProvider>().loadFriends();
    });
  }

  @override
  void dispose() {
    _inviteController.dispose();
    super.dispose();
  }

  Future<void> _inviteFriend() async {
    final phone = _inviteController.text.trim();
    if (phone.isEmpty) return;

    setState(() {
      _isInviting = true;
      _inviteError = null;
    });
    final friends = context.read<FriendsProvider>();
    final ok = await friends.invite(phone);
    if (!mounted) return;
    setState(() => _isInviting = false);

    if (ok) {
      _inviteController.clear();
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invite sent to $phone'),
          backgroundColor: AppTheme.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      setState(() => _inviteError = friends.error ?? 'Failed to invite');
    }
  }

  Future<void> _acceptFriend(Friend friend) async {
    final friends = context.read<FriendsProvider>();
    final ok = await friends.acceptRequest(friend);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friends.error ?? 'Could not accept'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showInviteSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Invite a friend', style: Theme.of(sheetCtx).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'They need DataBric installed to receive data.',
                style: Theme.of(sheetCtx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _inviteController,
                keyboardType: TextInputType.phone,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '+250 78 000 0000',
                  prefixIcon: Icon(Icons.phone_outlined, size: 20),
                  labelText: 'Phone number',
                ),
              ),
              if (_inviteError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_inviteError!,
                      style: const TextStyle(color: AppTheme.sent, fontSize: 13)),
                ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isInviting ? null : _inviteFriend,
                child: _isInviting
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Send invite'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<FriendsProvider>();
    final accepted = friends.accepted;
    final incoming = friends.incomingPending;
    final outgoing = friends.outgoingPending;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        actions: [
          TextButton.icon(
            onPressed: _showInviteSheet,
            icon: const Icon(Icons.person_add_outlined, size: 18),
            label: const Text('Add'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: friends.loadFriends,
        color: AppTheme.primary,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            if (incoming.isNotEmpty) ...[
              const SectionLabel('Incoming requests'),
              _pendingCard(context, incoming, actionable: true),
              const SizedBox(height: 24),
            ],
            if (outgoing.isNotEmpty) ...[
              const SectionLabel('Sent'),
              _pendingCard(context, outgoing, actionable: false),
              const SizedBox(height: 24),
            ],

            SectionLabel('My friends (${accepted.length})'),
            if (friends.isLoading && accepted.isEmpty)
              const SurfaceCard(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (accepted.isEmpty)
              SurfaceCard(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Icon(Icons.people_outline_rounded,
                          size: 40, color: AppTheme.textTertiary),
                      const SizedBox(height: 12),
                      Text('No friends yet',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Invite friends to start sharing data with them.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _showInviteSheet,
                        icon: const Icon(Icons.person_add_outlined, size: 18),
                        label: const Text('Invite a friend'),
                      ),
                    ],
                  ),
                ),
              )
            else
              SurfaceCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: accepted.asMap().entries.map((e) {
                    final friend = e.value;
                    final isLast = e.key == accepted.length - 1;
                    return Column(
                      children: [
                        ListTile(
                          leading: FriendAvatar(friend: friend),
                          title: Text(friend.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontSize: 14)),
                          subtitle: Text(
                            '${friend.carrier} · ${friend.city}, ${friend.country}'
                                .trim(),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded,
                              color: AppTheme.textTertiary),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          onTap: () {},
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
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _pendingCard(BuildContext context, List<Friend> rows, {required bool actionable}) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: rows.asMap().entries.map((e) {
          final friend = e.value;
          final isLast = e.key == rows.length - 1;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    FriendAvatar(friend: friend),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(friend.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontSize: 14)),
                          Text(friend.phoneNumber,
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                    if (actionable)
                      TextButton(
                        onPressed: () => _acceptFriend(friend),
                        style: TextButton.styleFrom(
                          backgroundColor: AppTheme.primaryLight,
                          foregroundColor: AppTheme.primaryDark,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Accept', style: TextStyle(fontSize: 12)),
                      )
                    else
                      const StatusBadge(
                        label: 'Pending',
                        bg: AppTheme.amberLight,
                        fg: AppTheme.amber,
                      ),
                  ],
                ),
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
    );
  }
}
