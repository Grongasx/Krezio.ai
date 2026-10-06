import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'ai/local_nlp_engine.dart';
import 'frontend/theme/krezio_theme.dart';
import 'backend/repositories/financial_repository.dart';
import 'backend/services/auth_service.dart';
import 'backend/services/cloud_sync_service.dart';
import 'frontend/features/navigation/main_navigation_wrapper.dart';
import 'frontend/features/auth/presentation/screens/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KrezioApp());
}

class KrezioApp extends StatefulWidget {
  const KrezioApp({super.key});

  @override
  State<KrezioApp> createState() => _KrezioAppState();
}

class _KrezioAppState extends State<KrezioApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  LocalFinancialNlpEngine? _engine;
  final FinancialRepository _repository = FinancialRepository();
  bool _isRepositoryReady = false;
  String? _errorMessage;

  // Login is only required once Firebase has real credentials (see
  // firebase_options.dart). Until `flutterfire configure` has run, the app
  // falls back to working exactly as it did before — 100% local, no account.
  bool _firebaseReady = false;
  AuthService? _authService;
  User? _currentUser;
  CloudSyncService? _cloudSync;

  @override
  void initState() {
    super.initState();
    _loadNlpEngine();
    _loadRepository();
    _initFirebase();
  }

  Future<void> _loadNlpEngine() async {
    try {
      final jsonStr = await rootBundle.loadString('models/on_device/krezio_nlp_model.json');
      final engine = LocalFinancialNlpEngine.fromJsonString(jsonStr);
      setState(() {
        _engine = engine;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Erro ao carregar engine local: $e';
      });
    }
  }

  Future<void> _loadRepository() async {
    // Restores transactions, reminders, budgets, goals and category memory from
    // the last session; on the very first run it just persists the seed data.
    await _repository.initialize();
    if (mounted) {
      setState(() {
        _isRepositoryReady = true;
      });
    }
  }

  Future<void> _initFirebase() async {
    if (!DefaultFirebaseOptions.isConfigured) {
      // Placeholder credentials — `flutterfire configure` hasn't run yet.
      debugPrint('[Firebase] firebase_options.dart still has placeholder values; running local-only.');
      return;
    }
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      // Firestore keeps working offline and queues writes to sync automatically
      // once connectivity returns — this is the "sincroniza quando possível"
      // half of the requirement; Krezio.ai's own on-device cache covers the rest.
      FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true);
      _authService = AuthService();
      _authService!.authStateChanges.listen(_onAuthChanged);
      if (mounted) setState(() => _firebaseReady = true);
    } catch (e) {
      debugPrint('[Firebase] Initialization failed, running local-only: $e');
    }
  }

  Future<void> _onAuthChanged(User? user) async {
    await _cloudSync?.pushToCloud();
    _cloudSync?.dispose();
    _cloudSync = null;

    if (user != null) {
      final sync = CloudSyncService(repository: _repository, uid: user.uid);
      try {
        await sync.pullFromCloud();
      } catch (e) {
        debugPrint('[CloudSync] Initial pull failed, continuing with local data: $e');
      }
      sync.startAutoSync();
      _cloudSync = sync;
    }

    if (mounted) setState(() => _currentUser = user);
  }

  Future<void> _signOut() async {
    await _authService?.signOut();
  }

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  void dispose() {
    _cloudSync?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Krezio.ai',
      debugShowCheckedModeBanner: false,
      theme: KrezioTheme.lightTheme,
      darkTheme: KrezioTheme.darkTheme,
      themeMode: _themeMode,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: KrezioColors.friendlyOrange, size: 48),
                const SizedBox(height: 16),
                Text(_errorMessage!, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    if (_engine == null || !_isRepositoryReady) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: KrezioColors.aiPurple.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: KrezioColors.aiPurple,
                  size: 40,
                ),
              ),
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: KrezioColors.aiPurple),
              const SizedBox(height: 16),
              const Text(
                'Carregando Engine Local On-Device...',
                style: TextStyle(fontSize: 14, color: KrezioColors.aiPurple),
              ),
            ],
          ),
        ),
      );
    }

    // Login is only enforced once Firebase is actually configured and reachable.
    if (_firebaseReady && _currentUser == null) {
      return LoginScreen(authService: _authService!, isDark: _themeMode == ThemeMode.dark);
    }

    return MainNavigationWrapper(
      engine: _engine!,
      repository: _repository,
      onToggleTheme: _toggleTheme,
      isDark: _themeMode == ThemeMode.dark,
      userEmail: _currentUser?.email,
      onSignOut: (_firebaseReady && _currentUser != null) ? _signOut : null,
    );
  }
}
