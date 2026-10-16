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
import 'frontend/navigation/krezio_routes.dart';
import 'frontend/widgets/krezio_components.dart';
import 'frontend/theme/theme_controller.dart';
import 'frontend/features/onboarding/onboarding_screen.dart';
import 'frontend/features/legal/legal_documents.dart';
import 'frontend/features/security/app_lock_gate.dart';
import 'frontend/features/security/biometric_auth.dart';
import 'backend/services/pin_lock.dart';
import 'backend/services/pin_store_prefs.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KrezioApp());
}

class KrezioApp extends StatefulWidget {
  const KrezioApp({super.key});

  @override
  State<KrezioApp> createState() => _KrezioAppState();
}

class _KrezioAppState extends State<KrezioApp> with WidgetsBindingObserver {
  ThemeMode get _themeMode => ThemeController.mode.value;
  bool get _isDark => ThemeController.isDark(_themeMode, WidgetsBinding.instance.platformDispatcher.platformBrightness);
  final PinLock _pinLock = PinLock(PrefsPinStore());
  final BiometricAuth _biometric = BiometricAuth();
  bool _onboardingDone = true;
  LocalFinancialNlpEngine? _engine;
  final FinancialRepository _repository = FinancialRepository();
  bool _isRepositoryReady = false;
  String? _errorMessage;

  // Deep link: the route the app was opened at (web `/#/chat`, Android intent).
  final int _initialTab = KrezioRoutes.tabFor(WidgetsBinding.instance.platformDispatcher.defaultRouteName);

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
    WidgetsBinding.instance.addObserver(this);
    ThemeController.mode.addListener(_onThemeChanged);
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
    final savedTheme = _repository.preference(ThemeController.pref);
    if (savedTheme != null) ThemeController.mode.value = ThemeController.parse(savedTheme);
    if (mounted) {
      setState(() {
        _isRepositoryReady = true;
        _onboardingDone = _repository.preference(OnboardingScreen.donePref) != null;
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

  /// Stops syncing first: signing out would push the local data back up.
  Future<void> _deleteAccount() async {
    _cloudSync?.dispose();
    _cloudSync = null;
    await _authService!.deleteAccount();
  }

  void _toggleTheme() {
    final next = _isDark ? ThemeMode.light : ThemeMode.dark;
    ThemeController.mode.value = next;
    _repository.setPreference(ThemeController.pref, ThemeController.nameOf(next));
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  /// "Seguir o sistema" follows the phone switching light/dark.
  @override
  void didChangePlatformBrightness() {
    if (_themeMode == ThemeMode.system) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ThemeController.mode.removeListener(_onThemeChanged);
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
        body: KrezioErrorState(
          message: _errorMessage!,
          onRetry: () {
            setState(() => _errorMessage = null);
            _loadNlpEngine();
          },
        ),
      );
    }

    if (_engine == null || !_isRepositoryReady) {
      return const KrezioSplash();
    }

    // Login is only enforced once Firebase is actually configured and reachable.
    if (!_onboardingDone) {
      return OnboardingScreen(
        repository: _repository,
        onDone: () => setState(() => _onboardingDone = true),
      );
    }

    if (_firebaseReady && _currentUser == null) {
      return LoginScreen(
        authService: _authService!,
        isDark: _isDark,
        onTermsAccepted: () => _repository.setPreference(LegalDocuments.acceptedPref, LegalDocuments.acceptedValue(DateTime.now())),
      );
    }

    return AppLockGate(
      lock: _pinLock,
      biometric: _biometric.authenticate,
      child: MainNavigationWrapper(
        engine: _engine!,
        repository: _repository,
        onToggleTheme: _toggleTheme,
        isDark: _isDark,
        userEmail: _currentUser?.email,
        onSignOut: (_firebaseReady && _currentUser != null) ? _signOut : null,
        onDeleteAccount: (_firebaseReady && _currentUser != null) ? _deleteAccount : null,
        initialIndex: _initialTab,
      ),
    );
  }
}
