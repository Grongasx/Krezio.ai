import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../navigation/krezio_routes.dart';
import '../../theme/krezio_theme.dart';
import '../../../backend/repositories/financial_repository.dart';
import '../../../backend/services/auth_service.dart';
import '../../../backend/services/notification_service.dart';
import '../../../ai/local_nlp_engine.dart';
import '../dashboard/presentation/screens/dashboard_screen.dart';
import '../transactions/presentation/screens/transactions_screen.dart';
import '../budgets/presentation/screens/budgets_screen.dart';
import '../settings/presentation/screens/settings_screen.dart';
import '../chat/presentation/screens/chat_screen.dart';

class MainNavigationWrapper extends StatefulWidget {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repository;
  final VoidCallback onToggleTheme;
  final bool isDark;
  final String? userEmail;
  final SignOutAction? onSignOut;
  final Future<void> Function()? onDeleteAccount;
  final Future<void> Function()? onClearData;
  final Future<void> Function()? onExportLegacy;
  final VoidCallback? onToggleDemo;
  final bool isDemo;

  /// Tab to open first (from the deep link / initial route).
  final int initialIndex;

  const MainNavigationWrapper({
    super.key,
    required this.engine,
    required this.repository,
    required this.onToggleTheme,
    required this.isDark,
    this.userEmail,
    this.onSignOut,
    this.onDeleteAccount,
    this.onClearData,
    this.onExportLegacy,
    this.onToggleDemo,
    this.isDemo = false,
    this.initialIndex = 0,
  });

  @override
  State<MainNavigationWrapper> createState() => _MainNavigationWrapperState();
}

class _MainNavigationWrapperState extends State<MainNavigationWrapper> {
  late int _currentIndex = widget.initialIndex;
  String? _focusedBudget;
  bool _transactionsShowBudgets = false;
  int _transactionsJump = 0;

  @override
  void initState() {
    super.initState();
    KrezioRoutes.pendingLink.addListener(_onLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NotificationService(widget.repository).dispatchIfDue(context);
    });
  }

  @override
  void dispose() {
    KrezioRoutes.pendingLink.removeListener(_onLink);
    super.dispose();
  }

  /// A link opens its tab; the chat handles a sentence or the voice itself.
  void _onLink() {
    final link = KrezioRoutes.pendingLink.value;
    if (link == null) return;
    _goTo(KrezioRoutes.tabFor(link.path));
    if (KrezioRoutes.phraseIn(link) == null && !KrezioRoutes.wantsVoice(link)) KrezioRoutes.pendingLink.value = null;
  }

  void _goTo(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    // Keeps the browser URL in step with the tab (no-op off the web).
    SystemNavigator.routeInformationUpdated(uri: Uri.parse(KrezioRoutes.tabs[index]));
  }

  @override
  Widget build(BuildContext context) {
    final bgNav = widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;

    final pages = [
      DashboardScreen(
        repository: widget.repository,
        isDark: widget.isDark,
        onNavigateToChat: () => _goTo(2),
        onNavigateToTransactions: () {
          setState(() {
            _transactionsShowBudgets = false;
            _focusedBudget = null;
            _transactionsJump++;
          });
          _goTo(1);
        },
        onNavigateToBudgets: (category) {
          setState(() {
            _transactionsShowBudgets = true;
            _focusedBudget = category;
            _transactionsJump++;
          });
          _goTo(1);
        },
      ),
      TransactionsScreen(
        key: ValueKey(_transactionsJump),
        repository: widget.repository,
        isDark: widget.isDark,
        showBudgets: _transactionsShowBudgets,
        focusedBudget: _focusedBudget,
      ),
      ChatScreen(
        engine: widget.engine,
        repository: widget.repository,
        onToggleTheme: widget.onToggleTheme,
        isDarkMode: widget.isDark,
      ),
      BudgetsScreen(
        repository: widget.repository,
        isDark: widget.isDark,
      ),
      SettingsScreen(
        repository: widget.repository,
        engine: widget.engine,
        isDark: widget.isDark,
        onToggleTheme: widget.onToggleTheme,
        userEmail: widget.isDemo ? null : widget.userEmail,
        onSignOut: widget.isDemo ? null : widget.onSignOut,
        onDeleteAccount: widget.isDemo ? null : widget.onDeleteAccount,
        onClearData: widget.isDemo ? null : widget.onClearData,
        onExportLegacy: widget.isDemo ? null : widget.onExportLegacy,
        onExploreDemo: widget.isDemo ? null : widget.onToggleDemo,
        isDemo: widget.isDemo,
      ),
    ];

    // Android back on any tab other than Início goes to Início instead of
    // closing the app; on Início it behaves normally (leaves the app).
    return PopScope(
      canPop: _currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goTo(0);
      },
      child: Scaffold(
        body: Column(
          children: [
            if (widget.isDemo)
              SafeArea(
                bottom: false,
                child: ListTile(
                  dense: true,
                  title: const Text('Exemplo'),
                  trailing: TextButton(
                    onPressed: widget.onToggleDemo,
                    child: const Text('Sair dos exemplos'),
                  ),
                ),
              ),
            Expanded(child: IndexedStack(index: _currentIndex, children: pages)),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: bgNav,
            border: Border(
              top: BorderSide(
                color: widget.isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                width: 1,
              ),
            ),
          ),
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: _goTo,
            backgroundColor: bgNav,
            elevation: 0,
            indicatorColor: KrezioColors.aiPurple.withValues(alpha: widget.isDark ? 0.24 : 0.13),
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard, color: KrezioColors.aiPurple),
                label: 'Início',
              ),
              const NavigationDestination(
                icon: Icon(Icons.receipt_long_outlined),
                selectedIcon: Icon(Icons.receipt_long, color: KrezioColors.aiPurple),
                label: 'Extrato',
              ),
              NavigationDestination(
                icon: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [KrezioColors.aiPurple, Color(0xFF6366F1)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: KrezioColors.aiPurple.withValues(alpha: 0.45),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.auto_awesome, color: Colors.white, size: 22),
                ),
                selectedIcon: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [KrezioColors.emeraldGreen, KrezioColors.aiPurple],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: KrezioColors.aiPurple.withValues(alpha: 0.6),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.auto_awesome, color: Colors.white, size: 24),
                ),
                label: 'César IA',
              ),
              const NavigationDestination(
                icon: Icon(Icons.savings_outlined),
                selectedIcon: Icon(Icons.savings, color: KrezioColors.aiPurple),
                label: 'Cofrinhos',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings, color: KrezioColors.aiPurple),
                label: 'Ajustes',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
