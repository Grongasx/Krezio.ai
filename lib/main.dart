import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'ai/local_nlp_engine.dart';
import 'frontend/theme/krezio_theme.dart';
import 'backend/repositories/financial_repository.dart';
import 'backend/services/auth_service.dart';
import 'backend/services/cloud_sync_service.dart';
import 'backend/services/data_export.dart';
import 'backend/services/persistence_service.dart';
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
import 'package:home_widget/home_widget.dart';
import 'frontend/features/home_widget/home_widget_sync.dart';

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
  HomeWidgetSync? _widgetSync;
  LocalFinancialNlpEngine? _engine;
  FinancialRepository? _repository;
  FinancialRepository? _demo;
  final _navigator = GlobalKey<NavigatorState>();
  Future<void> _authQueue = Future.value();
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<Uri?>? _widgetSubscription;
  bool _hasLegacyData = false;
  bool _hasSession = false;
  bool _sessionBusy = false;
  String? _sessionError;
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
    // Opened by a link ("krezio://app/chat?frase=…", a shortcut, the widget).
    final start = Uri.tryParse(WidgetsBinding.instance.platformDispatcher.defaultRouteName);
    if (start != null && start.hasQuery) KrezioRoutes.pendingLink.value = start;
    if (HomeWidgetSync.supported) {
      HomeWidget.initiallyLaunchedFromHomeWidget().then((u) {
        if (u != null) KrezioRoutes.pendingLink.value = KrezioRoutes.asRoute(u);
      });
      _widgetSubscription = HomeWidget.widgetClicked.listen((u) {
        if (u != null) KrezioRoutes.pendingLink.value = KrezioRoutes.asRoute(u);
      });
    }
    _loadNlpEngine();
    _start();
  }

  Future<void> _loadNlpEngine() async {
    try {
      final jsonStr = await rootBundle.loadString('models/on_device/krezio_nlp_model.json');
      final engine = LocalFinancialNlpEngine.fromJsonString(jsonStr);
      if (!mounted) return;
      setState(() {
        _engine = engine;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Erro ao carregar engine local: $e';
      });
    }
  }

  Future<void> _start() async {
    try {
      _hasLegacyData = await const PersistenceService().hasPersistedData();
      if (!mounted) return;
      if (DefaultFirebaseOptions.isConfigured) {
        try {
          await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
          FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true);
          _authService = AuthService();
          _firebaseReady = true;
        } catch (e) {
          debugPrint('[Firebase] Inicialização indisponível: $e');
        }
      }
      if (!mounted) return;
      if (_authService case final auth?) {
        _authSubscription = auth.authStateChanges.listen(_queueSession);
      } else {
        _queueSession(null);
      }
    } catch (_) {
      if (mounted) setState(() => _sessionError = 'Não foi possível abrir os dados locais.');
    }
  }

  void _queueSession(User? user) {
    _authQueue = _authQueue.then((_) => _openSession(user)).catchError((Object error) {
      debugPrint('[Sessão] $error');
      if (mounted) setState(() => _sessionError = 'Não foi possível abrir esta sessão.');
    });
  }

  Future<void> _openSession(User? user) async {
    if (!mounted || (_hasSession && _currentUser?.uid == user?.uid && _isRepositoryReady)) return;
    if (_hasSession) {
      KrezioRoutes.pendingLink.value = null;
      _navigator.currentState?.popUntil((route) => route.isFirst);
    }
    setState(() {
      _isRepositoryReady = false;
      _sessionError = null;
    });
    final oldRepo = _repository;
    final oldSync = _cloudSync;
    _widgetSync?.stop();
    _widgetSync = null;
    oldSync?.dispose();
    _cloudSync = null;
    await oldSync?.drain();
    await oldRepo?.flushPendingWrites();
    await HomeWidgetSync.clear();
    if (!mounted || (_firebaseReady && _authService?.currentUser?.uid != user?.uid)) return;

    FinancialRepository? repository;
    CloudSyncService? sync;
    var firstLoad = false;
    if (!_firebaseReady || user != null) {
      final store = user == null ? const PersistenceService.local() : PersistenceService.account(user.uid);
      firstLoad = !await store.hasPersistedData();
      repository = FinancialRepository(persistence: store, seedDemo: false);
      await repository.initialize();
    }
    if (user != null && repository != null) {
      sync = CloudSyncService(repository: repository, uid: user.uid);
      try {
        await sync.pullFromCloud(firstLoad: firstLoad).timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('[CloudSync] Conta aberta com a cópia local: $e');
      }
    }
    if (!mounted || (_firebaseReady && _authService?.currentUser?.uid != user?.uid)) {
      sync?.dispose();
      return;
    }

    _cloudSync = sync;
    sync?.startAutoSync();
    ThemeController.mode.value = ThemeController.parse(repository?.preference(ThemeController.pref));
    if (repository != null) _widgetSync = HomeWidgetSync(repository)..start();
    setState(() {
      _repository = repository;
      _demo = null;
      _currentUser = user;
      _hasSession = true;
      _onboardingDone = repository?.preference(OnboardingScreen.donePref) != null;
      _isRepositoryReady = true;
    });
  }

  Future<void> _signOut({required bool keepData, required bool skipSync}) async {
    final uid = _currentUser!.uid;
    final repository = _repository!;
    final sync = _cloudSync;
    if (_sessionBusy) return;
    _sessionBusy = true;
    try {
      await repository.flushPendingWrites();
      if (!skipSync && sync != null) {
        try {
          await sync.pushToCloud().timeout(const Duration(seconds: 8));
        } catch (_) {
          throw const SignOutSyncFailure();
        }
      }
      if (_authService?.currentUser?.uid != uid) return;
      if (!keepData) {
        sync?.dispose();
        await sync?.drain();
        await repository.clearAllData();
        await CloudSyncService.discardLocalBase(uid);
      }
      await _authService!.signOut();
    } finally {
      _sessionBusy = false;
    }
  }

  Future<void> _deleteAccount() async {
    final uid = _currentUser!.uid;
    final repository = _repository!;
    final sync = _cloudSync;
    sync?.dispose();
    await sync?.drain();
    await _authService!.deleteAccount();
    await repository.clearAllData();
    await CloudSyncService.discardLocalBase(uid);
  }

  Future<void> _clearData() async {
    if (_sessionBusy) return;
    final repository = _repository!;
    final sync = _cloudSync;
    setState(() => _sessionBusy = true);
    try {
      if (sync != null) {
        await sync.resetCloudData();
      } else {
        await repository.clearAllData();
      }
      repository.setPreference(OnboardingScreen.donePref, DateTime.now().toIso8601String());
      await repository.flushPendingWrites();
    } finally {
      if (mounted) setState(() => _sessionBusy = false);
    }
  }

  Future<void> _exportLegacy() async {
    final recovery = FinancialRepository(persistence: const PersistenceService(), seedDemo: false);
    try {
      await recovery.initialize();
      final bytes = Uint8List.fromList(utf8.encode(DataExport.toJson(recovery)));
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'application/json')],
        fileNameOverrides: ['krezio-recuperacao.json'],
      ));
    } finally {
      recovery.dispose();
    }
  }

  void _finishOnboarding({bool demo = false}) {
    setState(() {
      _onboardingDone = true;
      if (demo) _demo = FinancialRepository.demo();
    });
  }

  void _toggleTheme() {
    final next = _isDark ? ThemeMode.light : ThemeMode.dark;
    ThemeController.mode.value = next;
    (_demo ?? _repository)?.setPreference(ThemeController.pref, ThemeController.nameOf(next));
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  /// A link received while the app is open: handled here (switch tab, send
  /// the sentence) instead of pushing a named route that doesn't exist.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    KrezioRoutes.pendingLink.value = KrezioRoutes.asRoute(routeInformation.uri);
    return true;
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
    _authSubscription?.cancel();
    _widgetSubscription?.cancel();
    _widgetSync?.stop();
    _cloudSync?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Krezio.ai',
      navigatorKey: _navigator,
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: KrezioTheme.lightTheme,
      darkTheme: KrezioTheme.darkTheme,
      themeMode: _themeMode,
      home: AbsorbPointer(absorbing: _sessionBusy, child: _buildHome()),
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

    if (_sessionError case final error?) {
      return Scaffold(body: KrezioErrorState(
        message: error,
        onRetry: () {
          setState(() => _sessionError = null);
          if (_authService != null) {
            _queueSession(_authService?.currentUser);
          } else {
            _start();
          }
        },
      ));
    }
    if (_engine == null || !_isRepositoryReady) {
      return const KrezioSplash();
    }

    if (_firebaseReady && _currentUser == null) {
      final login = LoginScreen(
        authService: _authService!,
        isDark: _isDark,
        onTermsAccepted: () {
          final uid = _authService?.currentUser?.uid;
          unawaited(_authQueue.then((_) {
            if (uid != null && _currentUser?.uid == uid) {
              _repository?.setPreference(LegalDocuments.acceptedPref, LegalDocuments.acceptedValue(DateTime.now()));
            }
          }));
        },
        onExportLegacy: _hasLegacyData ? _exportLegacy : null,
      );
      return _hasLegacyData
          ? AppLockGate(lock: _pinLock, biometric: _biometric.authenticate, child: login)
          : login;
    }

    final repository = _demo ?? _repository!;
    return AppLockGate(
      key: ObjectKey(repository),
      lock: _pinLock,
      biometric: _biometric.authenticate,
      child: !_onboardingDone ? OnboardingScreen(
        repository: repository,
        onDone: _finishOnboarding,
        onExploreDemo: () => _finishOnboarding(demo: true),
      ) : MainNavigationWrapper(
        engine: _engine!,
        repository: repository,
        onToggleTheme: _toggleTheme,
        isDark: _isDark,
        userEmail: _currentUser?.email,
        onSignOut: (_firebaseReady && _currentUser != null) ? _signOut : null,
        onDeleteAccount: (_firebaseReady && _currentUser != null) ? _deleteAccount : null,
        onClearData: _clearData,
        onExportLegacy: !_firebaseReady && _hasLegacyData ? _exportLegacy : null,
        onToggleDemo: () => setState(() {
          _demo = _demo == null ? FinancialRepository.demo() : null;
        }),
        isDemo: _demo != null,
        initialIndex: _initialTab,
      ),
    );
  }
}
