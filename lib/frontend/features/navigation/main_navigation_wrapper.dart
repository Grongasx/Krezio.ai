import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../navigation/krezio_routes.dart';
import '../../theme/krezio_theme.dart';
import '../../../backend/repositories/financial_repository.dart';
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
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onDeleteAccount;

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
    this.initialIndex = 0,
  });

  @override
  State<MainNavigationWrapper> createState() => _MainNavigationWrapperState();
}

class _MainNavigationWrapperState extends State<MainNavigationWrapper> {
  late int _currentIndex = widget.initialIndex;

  void _goTo(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    // Keeps the browser URL in step with the tab (no-op off the web).
    SystemNavigator.routeInformationUpdated(uri: Uri.parse(KrezioRoutes.tabs[index]));
  }

  @override
  Widget build(BuildContext context) {
    final bgNav = widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final unselectedColor = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    final pages = [
      DashboardScreen(
        repository: widget.repository,
        isDark: widget.isDark,
        onNavigateToChat: () => _goTo(2),
        onNavigateToTransactions: () => _goTo(1),
      ),
      TransactionsScreen(
        repository: widget.repository,
        isDark: widget.isDark,
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
        userEmail: widget.userEmail,
        onSignOut: widget.onSignOut,
        onDeleteAccount: widget.onDeleteAccount,
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
        body: IndexedStack(
          index: _currentIndex,
          children: pages,
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
          child: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: _goTo,
            backgroundColor: bgNav,
            elevation: 0,
            type: BottomNavigationBarType.fixed,
            selectedItemColor: KrezioColors.aiPurple,
            unselectedItemColor: unselectedColor,
            selectedLabelStyle: const TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.bold),
            unselectedLabelStyle: const TextStyle(fontSize: KrezioFont.caption),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.dashboard_outlined),
                activeIcon: Icon(Icons.dashboard),
                label: 'Início',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_outlined),
                activeIcon: Icon(Icons.receipt_long),
                label: 'Extrato',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.auto_awesome_outlined),
                activeIcon: Icon(Icons.auto_awesome),
                label: 'IA Chat',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.pie_chart_outline),
                activeIcon: Icon(Icons.pie_chart),
                label: 'Metas',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings_outlined),
                activeIcon: Icon(Icons.settings),
                label: 'Ajustes',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
