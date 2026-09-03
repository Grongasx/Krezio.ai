import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/ml/local_nlp_engine.dart';
import 'core/theme/krezio_theme.dart';
import 'core/repositories/financial_repository.dart';
import 'features/navigation/main_navigation_wrapper.dart';

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
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadNlpEngine();
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

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
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

    if (_engine == null) {
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

    return MainNavigationWrapper(
      engine: _engine!,
      repository: _repository,
      onToggleTheme: _toggleTheme,
      isDark: _themeMode == ThemeMode.dark,
    );
  }
}
