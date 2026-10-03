// ── Friend model ──────────────────────────────────────────────
class Friend {
  final String id; // the other user's UUID (used for /sessions/connect, etc.)
  final String? friendshipId; // row id in `friendships` (used for /friends/action)
  final String name;
  final String phoneNumber;
  final String carrier;
  final String city;
  final String country;
  final FriendStatus status;
  // Who initiated the friendship — needed to render "incoming" vs "outgoing"
  // pending requests. Null when the value isn't relevant (e.g. constructed
  // ad-hoc).
  final String? initiatedBy;

  const Friend({
    required this.id,
    this.friendshipId,
    required this.name,
    required this.phoneNumber,
    required this.carrier,
    required this.city,
    required this.country,
    this.status = FriendStatus.accepted,
    this.initiatedBy,
  });

  factory Friend.fromJson(Map<String, dynamic> m) {
    final friendId = (m['friend_id'] ?? m['id'] ?? '').toString();
    final phone = (m['phone_number'] ?? '').toString();
    final display = (m['display_name'] as String?)?.trim();
    final name = (display == null || display.isEmpty) ? phone : display;
    return Friend(
      id: friendId,
      friendshipId: m['friendship_id']?.toString(),
      name: name,
      phoneNumber: phone,
      carrier: (m['carrier'] ?? '').toString(),
      city: (m['city'] ?? '').toString(),
      country: (m['country'] ?? '').toString(),
      status: _parseStatus(m['status'] as String?),
      initiatedBy: m['initiated_by']?.toString(),
    );
  }

  static FriendStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'accepted':
        return FriendStatus.accepted;
      case 'blocked':
        return FriendStatus.blocked;
      case 'pending':
      default:
        return FriendStatus.pending;
    }
  }

  String get initials {
    if (name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}

// Mirrors backend friendships.status: pending | accepted | blocked.
enum FriendStatus { pending, accepted, blocked }

// ── Sharing session model ──────────────────────────────────────
class SharingSession {
  final String id;
  final String friendId;
  final String friendName;
  final String friendCarrier;
  final SessionDirection direction;
  final double amountGb;
  final DateTime createdAt;
  final SessionStatus status;

  const SharingSession({
    required this.id,
    required this.friendId,
    required this.friendName,
    required this.friendCarrier,
    required this.direction,
    required this.amountGb,
    required this.createdAt,
    this.status = SessionStatus.completed,
  });

  String get amountLabel {
    if (amountGb < 1) return '${(amountGb * 1024).round()} MB';
    if (amountGb % 1 == 0) return '${amountGb.toInt()} GB';
    return '${amountGb.toStringAsFixed(2)} GB';
  }
}

enum SessionDirection { sent, received }
enum SessionStatus { active, completed }

// ── User profile ───────────────────────────────────────────────
// Carrier-balance fields are intentionally absent — we don't have a real
// data source for them yet. The UI shows a "—" placeholder in that case.
class UserProfile {
  final String name;
  final String phoneNumber;
  final String carrier;
  final String city;
  final String country;

  const UserProfile({
    required this.name,
    required this.phoneNumber,
    required this.carrier,
    required this.city,
    required this.country,
  });
}
