import '../backend/models/budget_category.dart';
import '../backend/models/financial_transaction.dart';
import 'category_name_matcher.dart';
import 'local_nlp_engine.dart';

/// Small, pure helpers shared by César's conversational features (Q&A,
/// edit/delete by chat, undo): text folding, money/date formatting and
/// Portuguese names for internal codes. Kept in one place so every answer
/// formats values the same way ("R$ 1.400,00", "08/09", "Pix").
class CesarText {
  CesarText._();

  /// Lowercase, accent-free, trimmed — what every regex in the features runs on.
  static String fold(String text) => CategoryNameMatcher.foldAccents(text.toLowerCase().trim());

  /// [fold] plus punctuation turned into spaces and whitespace collapsed
  /// ("Ops, era 45!" → "ops era 45"). Decimal commas/dots between digits are kept.
  static String simplify(String text) {
    final folded = fold(text)
        .replaceAll(RegExp(r'(?<!\d)[.,]|[.,](?!\d)'), ' ')
        .replaceAll(RegExp(r'[!?;:"“”()\[\]]'), ' ');
    return folded.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// "R$ 1.400,00".
  static String money(double value) {
    final negative = value < 0;
    final parts = value.abs().toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.');
    return '${negative ? '-' : ''}R\$ $intPart,${parts[1]}';
  }

  static String ddmm(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  static DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// "hoje", "ontem", "anteontem" or "08/09".
  static String relativeDay(DateTime date, DateTime now) {
    final diff = dayOnly(now).difference(dayOnly(date)).inDays;
    if (diff == 0) return 'hoje';
    if (diff == 1) return 'ontem';
    if (diff == 2) return 'anteontem';
    return ddmm(date);
  }

  static String paymentName(String code) {
    switch (code) {
      case 'pix':
        return 'Pix';
      case 'credit_card':
        return 'cartão de crédito';
      case 'debit_card':
        return 'cartão de débito';
      case 'cash':
        return 'dinheiro';
      case 'bank_slip':
        return 'boleto';
      default:
        return 'forma não informada';
    }
  }

  static const Map<String, String> _extraCategoryNames = {
    'salary': 'Salário',
    'investment': 'Investimentos',
    'income_other': 'Outras receitas',
    'expense_other': 'Outras despesas',
    'unknown': 'Sem categoria',
  };

  /// Display name of a category code: the budget's own name (built-in or the
  /// user's), or a Portuguese name for codes without a budget.
  static String categoryName(String code, List<BudgetCategory> budgets) {
    for (final b in budgets) {
      if (b.category == code) return b.name;
    }
    return _extraCategoryNames[code] ?? code;
  }

  static String typeName(TransactionType type) {
    switch (type) {
      case TransactionType.income:
        return 'receita';
      case TransactionType.transfer:
        return 'transferência';
      case TransactionType.expense:
        return 'despesa';
    }
  }

  /// "Mercado (hoje, R$ 50,00, Pix)" — how a record is named in answers.
  static String describe(FinancialTransaction tx, DateTime now) {
    final pay = tx.paymentMethod == 'unknown' ? '' : ', ${paymentName(tx.paymentMethod)}';
    return '${tx.title} (${relativeDay(tx.date, now)}, ${money(tx.amount)}$pay)';
  }

  /// Deterministic variant picker: the same [seed] always gives the same index,
  /// so replies vary between messages without making tests flaky.
  static int pick(String seed, int n) {
    if (n <= 1) return 0;
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h % n;
  }

  /// Words for the built-in categories as people say them. Several words map
  /// to the same code ("farmácia" and "saúde" → health).
  static const Map<String, String> categoryWords = {
    'lazer': 'leisure', 'alimentacao': 'leisure', 'comida': 'leisure', 'restaurante': 'leisure', 'restaurantes': 'leisure',
    'mercado': 'supermarket', 'supermercado': 'supermarket', 'feira': 'supermarket', 'compras do mes': 'supermarket',
    'transporte': 'transport', 'combustivel': 'transport', 'gasolina': 'transport', 'uber': 'transport',
    'saude': 'health', 'farmacia': 'health', 'remedio': 'health', 'remedios': 'health',
    'moradia': 'housing', 'casa': 'housing', 'contas': 'housing', 'conta de casa': 'housing',
    'educacao': 'education', 'estudo': 'education', 'estudos': 'education', 'curso': 'education', 'cursos': 'education',
    'investimento': 'investment', 'investimentos': 'investment',
    'salario': 'salary',
    'outros': 'expense_other', 'outras despesas': 'expense_other', 'outra': 'expense_other',
  };

  /// Category code for a short phrase naming a category ("lazer", "farmácia",
  /// "pets", "Lazer & Alimentação"), or null when it names none. Tries, in
  /// order: the user's custom categories, the budgets' display names, the
  /// built-in words above, and finally the engine's rule-based guess (which
  /// knows brands and places like "drogasil" or "posto").
  static String? resolveCategory(String phrase, List<BudgetCategory> budgets) {
    final f = simplify(phrase)
        .replaceAll(RegExp(r'^(?:(?:a|na|no|em|pra|para|pro|de|da|do|categoria|a categoria)\s+)+'), '')
        .trim();
    if (f.isEmpty) return null;
    for (final b in budgets) {
      if (b.isCustom && (CategoryNameMatcher.sameName(b.name, f) || CategoryNameMatcher.mentions(f, b.name))) return b.category;
    }
    for (final b in budgets) {
      if (CategoryNameMatcher.sameName(b.name, f)) return b.category;
    }
    final direct = categoryWords[f];
    if (direct != null) return direct;
    // "lazer e alimentação", "saúde & farmácia": any word naming a category.
    final words = f.split(' ');
    if (words.length <= 3) {
      for (final w in words) {
        final code = categoryWords[w];
        if (code != null) return code;
      }
      for (final b in budgets) {
        final nameWords = CategoryNameMatcher.tokens(b.name);
        if (words.any((w) => nameWords.contains(CategoryNameMatcher.tokens(w).join()))) return b.category;
      }
      final guessed = LocalFinancialNlpEngine.guessCategoryFromText(f);
      if (guessed != 'unknown') return guessed;
    }
    return null;
  }
}
