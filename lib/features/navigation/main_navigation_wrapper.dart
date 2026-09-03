import 'package:flutter/material.dart';
import '../../core/theme/krezio_theme.dart';
import '../../core/repositories/financial_repository.dart';
import '../../core/ml/local_nlp_engine.dart';
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

  const MainNavigationWrapper({
    super.key,
    required this.engine,
    required this.repository,
    required this.onToggleTheme,
    required this.isDark,
  });

  @override
  State<MainNavigationWrapper> createState() => _MainNavigationWrapperState();
}

class _MainNavigationWrapperState extends State<MainNavigationWrapper> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final bgNav = widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final unselectedColor = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    final pages = [
      DashboardScreen(
        repository: widget.repository,
        isDark: widget.isDark,
        onNavigateToChat: () => setState(() => _currentIndex = 2),
        onNavigateToTransactions: () => setState(() => _currentIndex = 1),
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
        isDark: widget.isDark,
        onToggleTheme: widget.onToggleTheme,
      ),
    ];

    return Scaffold(
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
          onTap: (index) => setState(() => _currentIndex = index),
          backgroundColor: bgNav,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: KrezioColors.aiPurple,
          unselectedItemColor: unselectedColor,
          selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
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
    );
  }
}
