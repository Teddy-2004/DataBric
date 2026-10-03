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

  /// Pending requests where I am the recipient — actionable.
  List<Friend> get incomingPending => _friends
      .where((f) =>
          f.status == FriendStatus.pending &&
          f.initiatedBy != null &&
          f.initiatedBy != _currentUserId)
      .toList();

  /// Pending requests I sent — read-only "waiting" state.
  List<Friend> get outgoingPending => _friends
      .where((f) =>
          f.status == FriendStatus.pending &&
          f.initiatedBy != null &&
          f.initiatedBy == _currentUserId)
      .toList();

  void setCurrentUserId(String? id) {
    if (_currentUserId == id) return;
    _currentUserId = id;
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

  Future<bool> invite(String phoneNumber) async {
    _error = null;
    try {
      await apiService.inviteFriend(phoneNumber);
      // Refresh in the background so the new pending row shows up.
      await loadFriends();
      return true;
    } catch (e) {
      _error = _parseError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> acceptRequest(Friend friend) => _doAction(friend, 'accept');
  Future<bool> blockUser(Friend friend) => _doAction(friend, 'block');
  Future<bool> removeFriend(Friend friend) => _doAction(friend, 'remove');

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

  String _parseError(dynamic e) {
    if (e is Exception) return e.toString().replaceAll('Exception: ', '');
    return 'Something went wrong. Please try again.';
  }
}
