import 'package:flutter/material.dart';

// Previously held mock friends/sessions/user data. After the audit, those
// responsibilities moved to AuthProvider (user), FriendsProvider (friends),
// and SessionProvider (history). This class is kept as an empty
// ChangeNotifier for legacy imports; new code shouldn't depend on it.
class AppState extends ChangeNotifier {}
