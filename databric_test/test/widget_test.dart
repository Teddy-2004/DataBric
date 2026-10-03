// Minimal smoke test — exercises model logic that doesn't need a fully
// initialized Flutter binding or Firebase. The real integration smoke
// (login → tunnel) lives in the manual verification plan, since it needs
// a backend, a google-services.json, and a relay.

import 'package:flutter_test/flutter_test.dart';
import 'package:databric/models/models.dart';

void main() {
  test('Friend.initials handles empty name without crashing', () {
    const f = Friend(
      id: '1',
      name: '',
      phoneNumber: '+250780000000',
      carrier: '',
      city: '',
      country: '',
    );
    expect(f.initials, '?');
  });

  test('Friend.initials uses first letter for single-word names', () {
    const f = Friend(
      id: '1',
      name: 'Amara',
      phoneNumber: '+250780000000',
      carrier: '',
      city: '',
      country: '',
    );
    expect(f.initials, 'A');
  });

  test('Friend.initials uses two-letter initials for multi-word names', () {
    const f = Friend(
      id: '1',
      name: 'Amara Mensah',
      phoneNumber: '+250780000000',
      carrier: '',
      city: '',
      country: '',
    );
    expect(f.initials, 'AM');
  });

  test('SharingSession.amountLabel rounds decimal GB to 2 places', () {
    final s = SharingSession(
      id: 's',
      friendId: 'f',
      friendName: 'X',
      friendCarrier: 'MTN',
      direction: SessionDirection.sent,
      amountGb: 1.23456,
      createdAt: DateTime(2026),
    );
    expect(s.amountLabel, '1.23 GB');
  });

  test('SharingSession.amountLabel shows MB for sub-1 GB amounts', () {
    final s = SharingSession(
      id: 's',
      friendId: 'f',
      friendName: 'X',
      friendCarrier: 'MTN',
      direction: SessionDirection.sent,
      amountGb: 0.5,
      createdAt: DateTime(2026),
    );
    expect(s.amountLabel, '512 MB');
  });
}
