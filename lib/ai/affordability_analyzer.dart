import 'local_nlp_engine.dart';
import '../backend/repositories/financial_repository.dart';
import '../backend/models/budget_category.dart';

enum AffordabilityVerdict { yes, caution, no }

class AffordabilityResult {
  final AffordabilityVerdict verdict;
  final String itemLabel;
  final double amount;
  final String spokenText;
  final String formattedText;

  const AffordabilityResult({
    required this.verdict,
    required this.itemLabel,
    required this.amount,
    required this.spokenText,
    required this.formattedText,
  });
}

/// Answers "posso comprar isso?" — a purchase-affordability check that weighs
/// the price against the current balance, committed spending in the next 30
/// days (upcoming bills + suggested monthly goal contributions), how big the
/// purchase is relative to monthly income, and — when the item's category can
/// be guessed — whether it would blow that category's budget.
///
/// This is a judgment call rendered from on-device data, not financial advice;
/// the wording always stays in "isso cabe no seu orçamento" terms.
class AffordabilityAnalyzer {
  final FinancialRepository repository;

  AffordabilityAnalyzer({required this.repository});

  static final RegExp _questionPattern = RegExp(
    r'posso\s+comprar|consigo\s+comprar|d[áa]\s+pra\s+comprar|dá\s+pra\s+eu\s+comprar|'
    r'devo\s+comprar|vale\s+a\s+pena\s+comprar|consigo\s+bancar|posso\s+gastar|'
    // "dá pra gastar 300 nesse fim de semana?", "consigo sair pra jantar
    // gastando 150?" — without these it became a R$ 300 transfer draft.
    r'd[áa]\s+(?:pra|para)\s+(?:eu\s+)?gastar|consigo\s+gastar|'
    r'(?:consigo|posso|d[áa]\s+(?:pra|para))\s+(?:eu\s+)?\w+(?:\s+\w+){0,5}?\s+gastando|'
    r'tenho\s+(?:condi[çc][ãa]o|dinheiro)\s+(?:de|pra|para)\s+comprar',
    caseSensitive: false,
  );

  static bool isAffordabilityQuestion(String text) => _questionPattern.hasMatch(text.toLowerCase());

  AffordabilityResult? analyze(String text) {
    if (!isAffordabilityQuestion(text)) return null;

    final amount = _extractAmount(text);
    if (amount == null || amount <= 0) return null;

    final itemLabel = _extractItem(text) ?? 'essa compra';
    final category = LocalFinancialNlpEngine.guessCategoryFromText(text);

    final balance = repository.totalBalance;
    final afterPurchase = balance - amount;
    final monthIncome = repository.monthIncome;

    final now = DateTime.now();
    final upcomingBillsTotal = repository
        .getUpcomingBills(start: now, end: now.add(const Duration(days: 30)))
        .fold(0.0, (acc, b) => acc + ((b['amount'] as num?)?.toDouble() ?? 0.0));
    final goalsMonthlyTotal = repository.goals
        .where((g) => !g.isCompleted)
        .fold(0.0, (acc, g) => acc + (g.suggestedMonthlyContribution ?? 0.0));
    final committedTotal = upcomingBillsTotal + goalsMonthlyTotal;

    var verdict = AffordabilityVerdict.yes;
    final reasons = <String>[];

    if (afterPurchase < 0) {
      verdict = AffordabilityVerdict.no;
      reasons.add('Seu saldo atual é de R\$ ${_fmt(balance)} — não cobre uma compra de R\$ ${_fmt(amount)}.');
    } else if (afterPurchase < committedTotal) {
      verdict = AffordabilityVerdict.caution;
      reasons.add(
        'Depois da compra sobrariam R\$ ${_fmt(afterPurchase)}, mas você já tem R\$ ${_fmt(committedTotal)} '
        'comprometidos em contas e metas nos próximos 30 dias.',
      );
    } else {
      reasons.add('Depois da compra ainda sobram R\$ ${_fmt(afterPurchase)} no seu saldo.');
    }

    if (monthIncome > 0 && amount > monthIncome * 0.5) {
      if (verdict == AffordabilityVerdict.yes) verdict = AffordabilityVerdict.caution;
      reasons.add('Essa compra sozinha equivale a mais da metade da sua renda mensal (R\$ ${_fmt(monthIncome)}).');
    }

    BudgetCategory? budget;
    for (final b in repository.budgets) {
      if (b.category == category) {
        budget = b;
        break;
      }
    }
    if (budget != null) {
      final projectedSpent = budget.currentSpent + amount;
      if (projectedSpent > budget.monthlyLimit) {
        if (verdict != AffordabilityVerdict.no) verdict = AffordabilityVerdict.caution;
        reasons.add(
          'Isso estouraria o orçamento de ${budget.name} em R\$ ${_fmt(projectedSpent - budget.monthlyLimit)}.',
        );
      } else {
        final percent = ((projectedSpent / budget.monthlyLimit) * 100).clamp(0, 100).toStringAsFixed(0);
        reasons.add('Usaria $percent% do orçamento de ${budget.name} este mês.');
      }
    }

    final verdictLabel = switch (verdict) {
      AffordabilityVerdict.yes => 'Sim, pode comprar! ✅',
      AffordabilityVerdict.caution => 'Dá para comprar, mas com cautela ⚠️',
      AffordabilityVerdict.no => 'Não recomendo agora ❌',
    };

    final spoken = '$verdictLabel ${reasons.join(' ')}';

    final formatted = StringBuffer();
    formatted.writeln('### 🛍️ Posso comprar $itemLabel de R\$ ${_fmt(amount)}?');
    formatted.writeln('**Veredito:** $verdictLabel\n');
    for (final r in reasons) {
      formatted.writeln('- $r');
    }

    return AffordabilityResult(
      verdict: verdict,
      itemLabel: itemLabel,
      amount: amount,
      spokenText: spoken,
      formattedText: formatted.toString(),
    );
  }

  String? _extractItem(String text) {
    final lower = text.toLowerCase();
    // 'uma' must be tried before 'um' with a `\b` after the article, otherwise
    // 'um' matches as a prefix of 'uma' and leaves a stray 'a' glued to the item.
    final match = RegExp(
      r'comprar\s+(?:uma|um|o|a)?\b\s*([a-zà-ÿ0-9\s]+?)(?:\s+(?:de|por|no|na)\s+(?:r\$)?\s*\d|\s*\?|\s*$)',
      caseSensitive: false,
    ).firstMatch(lower);
    var item = match?.group(1)?.trim();
    if (item == null || item.isEmpty) return null;
    item = item.replaceAll(RegExp(r'[.!?]+$'), '').trim();
    if (item.isEmpty) return null;
    return item;
  }

  double? _extractAmount(String text) {
    final lower = text.toLowerCase();
    final patterns = [
      RegExp(r'r\$\s*(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)'),
      RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s*(?:reais|real|conto|contos|pila|pilas)\b'),
      RegExp(r'\b(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)\b'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(lower);
      if (match != null) {
        final value = LocalFinancialNlpEngine.cleanAndParseAmount(match.group(1));
        if (value != null && value > 0) return value;
      }
    }
    return null;
  }

  String _fmt(double value) {
    final parts = value.abs().toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]}.',
    );
    return '${value < 0 ? '-' : ''}$intPart,${parts[1]}';
  }
}
