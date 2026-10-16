import 'package:flutter/material.dart';
import '../../theme/krezio_theme.dart';
import '../../widgets/krezio_components.dart';
import '../../../backend/repositories/financial_repository.dart';
import '../legal/legal_documents.dart';

/// First use: 3 short pages (what the app does, talk to César like a friend,
/// privacy on the device), then an optional initial setup (monthly income,
/// main categories, a suggested budget). Everything can be skipped.
class OnboardingScreen extends StatefulWidget {
  final FinancialRepository repository;
  final VoidCallback onDone;

  const OnboardingScreen({super.key, required this.repository, required this.onDone});

  static const String donePref = 'onboarding_done';

  /// A first budget from the monthly income: 50% for needs split among the
  /// chosen categories (or the usual ones), rounded to R$ 10.
  static Map<String, double> suggestedBudgets(double income, Set<String> chosen) {
    final cats = chosen.isEmpty ? {'supermarket', 'housing', 'transport', 'leisure'} : chosen;
    const weight = {'housing': 3.0, 'supermarket': 2.0, 'transport': 1.0, 'leisure': 1.0, 'health': 1.0, 'education': 1.0};
    final total = cats.fold(0.0, (a, c) => a + (weight[c] ?? 1));
    return {for (final c in cats) c: ((income * 0.5 * (weight[c] ?? 1) / total) / 10).round() * 10.0};
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  final _income = TextEditingController();
  final _name = TextEditingController();
  final Set<String> _focus = {};

  static const _intro = [
    (
      Icons.account_balance_wallet_outlined,
      'Suas finanças, sem planilha',
      'Registre gastos e receitas, acompanhe orçamentos e metas, e veja para onde vai o seu dinheiro.',
      <String>[],
    ),
    (
      Icons.chat_bubble_outline,
      'Fale com o César como fala com um amigo',
      'Escreva ou fale do seu jeito. Ele entende e pergunta quando tiver dúvida.',
      ['"gastei 50 no mercado no pix"', '"quanto gastei com uber esse mês?"', '"apaga o último"', '"onde posso economizar?"'],
    ),
    (
      Icons.lock_outline,
      'Privacidade no seu aparelho',
      'O César roda no celular: suas frases não vão para servidores. Sem conta, nada sai do aparelho.',
      <String>[],
    ),
  ];

  static const _categories = {
    'supermarket': 'Mercado',
    'leisure': 'Lazer e comida',
    'transport': 'Transporte',
    'housing': 'Moradia e contas',
    'health': 'Saúde',
    'education': 'Educação',
  };

  @override
  void dispose() {
    _pages.dispose();
    _income.dispose();
    _name.dispose();
    super.dispose();
  }

  void _finish() {
    final repo = widget.repository;
    final name = _name.text.trim();
    if (name.isNotEmpty) repo.setPreference(FinancialRepository.prefUserName, name);
    final income = KrezioMoneyField.parse(_income.text);
    if (income != null) {
      repo.setPreference('monthly_income', income.toStringAsFixed(2));
      for (final e in OnboardingScreen.suggestedBudgets(income, _focus).entries) {
        repo.setBudgetLimit(e.key, e.value);
      }
    }
    repo.setPreference(OnboardingScreen.donePref, DateTime.now().toIso8601String());
    repo.setPreference(LegalDocuments.acceptedPref, LegalDocuments.acceptedValue(DateTime.now()));
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _intro.length;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _finish, child: const Text('Pular')),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final p in _intro) _introPage(p.$1, p.$2, p.$3, p.$4),
                  _setupPage(),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i <= _intro.length; i++)
                  Container(
                    margin: const EdgeInsets.all(KrezioSpace.xs),
                    width: i == _page ? 18 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page ? KrezioColors.aiPurple : KrezioColors.aiPurple.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(KrezioSpace.lg),
              child: KrezioButton(
                label: last ? 'Começar' : 'Próximo',
                expand: true,
                onPressed: last
                    ? _finish
                    : () => _pages.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _introPage(IconData icon, String title, String text, List<String> examples) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: KrezioColors.aiPurple),
          const SizedBox(height: KrezioSpace.xl),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold)),
          const SizedBox(height: KrezioSpace.md),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: KrezioFont.bodyLarge)),
          const SizedBox(height: KrezioSpace.lg),
          for (final e in examples)
            Padding(
              padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
              child: Chip(label: Text(e)),
            ),
        ],
      ),
    );
  }

  Widget _setupPage() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.xxl, vertical: KrezioSpace.lg),
      children: [
        const Text('Vamos ajustar para você', style: TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold)),
        const SizedBox(height: KrezioSpace.sm),
        const Text('Tudo é opcional e dá para mudar depois.'),
        const SizedBox(height: KrezioSpace.lg),
        KrezioTextField(controller: _name, label: 'Como o César te chama?', hint: 'Ex.: Ana', textCapitalization: TextCapitalization.words),
        const SizedBox(height: KrezioSpace.md),
        KrezioMoneyField(controller: _income, label: 'Renda mensal (para sugerir um orçamento)'),
        const SizedBox(height: KrezioSpace.lg),
        const Text('Onde mais vai o seu dinheiro?', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: KrezioSpace.sm),
        Wrap(
          spacing: KrezioSpace.sm,
          runSpacing: KrezioSpace.sm,
          children: [
            for (final e in _categories.entries)
              FilterChip(
                label: Text(e.value),
                selected: _focus.contains(e.key),
                onSelected: (on) => setState(() => on ? _focus.add(e.key) : _focus.remove(e.key)),
              ),
          ],
        ),
        const SizedBox(height: KrezioSpace.lg),
        Text.rich(
          TextSpan(children: [
            const TextSpan(text: 'Ao começar, você concorda com os '),
            WidgetSpan(
              child: GestureDetector(
                onTap: () => LegalDocuments.open(context, title: 'Termos de uso', asset: LegalDocuments.termsAsset),
                child: const Text('Termos de uso', style: TextStyle(color: KrezioColors.aiPurple, decoration: TextDecoration.underline)),
              ),
            ),
            const TextSpan(text: ' e a '),
            WidgetSpan(
              child: GestureDetector(
                onTap: () => LegalDocuments.open(context, title: 'Política de privacidade', asset: LegalDocuments.privacyAsset),
                child: const Text('Política de privacidade', style: TextStyle(color: KrezioColors.aiPurple, decoration: TextDecoration.underline)),
              ),
            ),
            const TextSpan(text: '.'),
          ]),
          style: const TextStyle(fontSize: KrezioFont.small),
        ),
      ],
    );
  }
}
