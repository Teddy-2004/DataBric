import 'package:flutter/foundation.dart';
import 'package:databric/services/api_service.dart';
import 'package:databric/models/models.dart';

class FriendsProvider extends ChangeNotifier {
  List<Friend> _friends = [];
  bool _isLoading = false;
  String? _error;
  String? _currentUserId;

  List<Friend> get all => _friends;
  bool get isLoading => _isLoading;
  String? get error => _error;

  List<Friend> get accepted =>
      _friends.where((f) => f.status == FriendStatus.accepted).toList();

  List<Friend> get pending =>
      _friends.where((f) => f.status == FriendStatus.pending).toList();

  /// Pending requests someone else sent me — I can accept or decline.
  /// Empty until we know who "me" is, so my own invites are never shown
  /// as requests to accept.
  List<Friend> get incomingPending => _currentUserId == null
      ? const []
      : _friends
          .where((f) =>
              f.status == FriendStatus.pending &&
              f.initiatedBy != null &&
              f.initiatedBy != _currentUserId)
          .toList();

  /// Pending requests I sent — waiting for the other person.
  List<Friend> get outgoingPending => _currentUserId == null
      ? const []
      : _friends
          .where((f) =>
              f.status == FriendStatus.pending &&
              f.initiatedBy == _currentUserId)
          .toList();

  void setCurrentUserId(String? id) {
    if (_currentUserId == id) return;
    _currentUserId = id;
    notifyListeners();
  }

  /// Forget everything on sign-out, so the next account starts clean.
  void clear() {
    _friends = [];
    _currentUserId = null;
    _error = null;
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadFriends() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final rows = await apiService.getFriends();
      _friends = rows.map((m) => Friend.fromJson(m)).toList();
    } catch (e) {
      _error = _parseError(e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Returns the backend's message on success (it differs when the number
  /// isn't on DataBric yet), or null on failure with [error] set.
  Future<String?> invite(String phoneNumber) async {
    _error = null;
    try {
      final message = await apiService.inviteFriend(phoneNumber);
      // Refresh so the new pending row shows up.
      await loadFriends();
      return message;
    } catch (e) {
      _error = _parseError(e);
      notifyListeners();
      return null;
    }
  }

  Future<bool> acceptRequest(Friend friend) => _doAction(friend, 'accept');
  Future<bool> blockUser(Friend friend) => _doAction(friend, 'block');
  Future<bool> removeFriend(Friend friend) => _doAction(friend, 'remove');
  // Declining a request and cancelling my own invite both delete the row.
  Future<bool> declineRequest(Friend friend) => _doAction(friend, 'remove');
  Future<bool> cancelInvite(Friend friend) => _doAction(friend, 'remove');

  Future<bool> _doAction(Friend friend, String action) async {
    final fid = friend.friendshipId;
    if (fid == null || fid.isEmpty) {
      _error = 'Missing friendship id for this entry.';
      notifyListeners();
      return false;
    }
    _error = null;
    try {
      await apiService.friendAction(fid, action);
      await loadFriends();
      return true;
    } catch (e) {
      _error = _parseError(e);
      notifyListeners();
      return false;
    }
  }

  String _parseError(Object e) => describeApiError(e);
}
