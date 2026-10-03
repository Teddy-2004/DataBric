import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:databric/models/app_state.dart';
import 'package:databric/providers/auth_provider.dart';
import 'package:databric/providers/friends_provider.dart';
import 'package:databric/providers/session_provider.dart';
import 'package:databric/services/notification_service.dart';
import 'package:databric/services/xray_service.dart';
import 'package:databric/theme/app_theme.dart';
import 'package:databric/screens/home_screen.dart';
import 'package:databric/screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  // Firebase may legitimately be unavailable (missing google-services.json
  // in dev). Init returns false in that case; the app continues without push.
  await NotificationService.init();

  final xrayService = XrayService();
  await xrayService.init();

  runApp(DataBricApp(xrayService: xrayService));
}

class DataBricApp extends StatelessWidget {
  final XrayService xrayService;
  const DataBricApp({super.key, required this.xrayService});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider.value(value: xrayService),
        ChangeNotifierProvider(
          create: (_) => SessionProvider(xrayService: xrayService),
        ),
      ],
      child: MaterialApp(
        title: 'DataBric',
        theme: AppTheme.theme,
        debugShowCheckedModeBanner: false,
        home: const _AppEntry(),
      ),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final auth = context.read<AuthProvider>();
    await auth.checkAuth();
    if (!auth.isAuthenticated || !mounted) return;

    // Wire post-auth state in the background. None of these should block
    // the home screen from rendering.
    final friends = context.read<FriendsProvider>();
    final session = context.read<SessionProvider>();
    friends.setCurrentUserId(auth.userId);
    // ignore: unawaited_futures
    friends.loadFriends();
    // ignore: unawaited_futures
    session.restoreActive();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    switch (auth.status) {
      case AuthStatus.unknown:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case AuthStatus.unauthenticated:
        return const LoginScreen();
      case AuthStatus.authenticated:
        return const HomeScreen();
    }
  }
}
