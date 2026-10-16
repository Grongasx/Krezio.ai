import '../backend/models/financial_goal.dart';
import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'cesar_text.dart';

/// One piece of advice: chat text, the short spoken version and a route name.
class Advice {
  final String text;
  final String spokenText;
  final String route;

  const Advice(this.text, this.spokenText, this.route);
}

/// César as a consultant, from the user's own data and 100% on-device:
/// "e se…?" simulations ("quanto sobra se eu pagar o aluguel?", "se eu cortar
/// o delivery, quanto economizo?", "se eu guardar 200 por mês, quando bato a
/// meta?"), "onde posso economizar?", "como vou fechar o mês?", "quanto vem a
/// luz?", "quais assinaturas eu pago?", the real daily average, the weekly
/// summary and the out-of-pattern spending warning. Nothing here records
/// anything. Pure Dart: [now] can be injected so tests are deterministic.
class CesarAdvisor {
  final FinancialRepository repository;
  final DateTime Function() _clock;

  CesarAdvisor({required this.repository, DateTime Function()? now}) : _clock = now ?? DateTime.now;

  static const _simNote = 'É só uma simulação, não registrei nada.';

  /// The advice [text] asks for, or null when it is not one of these questions.
  Advice? answer(String text) {
    final s = CesarText.simplify(text);
    if (s.isEmpty) return null;
    return _dailyAverage(s) ??
        _cut(s) ??
        _saveForGoal(s) ??
        _payNamed(s) ??
        _whereToSave(s) ??
        _monthProjection(s) ??
        _forecastBill(s) ??
        _subscriptions(s);
  }

  // ───────────────────────── helpers ─────────────────────────

  DateTime get _today => CesarText.dayOnly(_clock());

  Iterable<FinancialTransaction> get _expenses => repository.transactions.where((t) => t.type == TransactionType.expense);

  static String _cleanTerm(String raw) => raw
      .replaceAll(RegExp(r'\b(?:do|da|de|dos|das|o|a|os|as|meu|minha|meus|minhas|com|no|na)\b'), ' ')
      .replaceAll(RegExp(r'\b(?:quanto|quantos|eu|economizo|economizaria|sobra|sobraria|por|mes|ao|todo|agora|ai|cesar)\b.*$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// A name found in some title ("aluguel", "ifood") filters by the title
  /// only; otherwise the term is a category ("delivery", "lazer").
  bool _matches(FinancialTransaction t, String term) {
    if (term.isEmpty) return false;
    final f = CesarText.fold(term);
    final inTitles = _titleTerms.putIfAbsent(f, () => repository.transactions.any((x) => CesarText.fold(x.title).contains(f)));
    if (inTitles) return CesarText.fold(t.title).contains(f);
    final code = CesarText.resolveCategory(term, repository.budgets);
    return code != null && t.category == code;
  }

  final Map<String, bool> _titleTerms = {};

  /// Days with data: from the first record to today.
  int get _daysOfData {
    if (repository.transactions.isEmpty) return 0;
    final first = repository.transactions.map((t) => t.date).reduce((a, b) => a.isBefore(b) ? a : b);
    return _today.difference(CesarText.dayOnly(first)).inDays + 1;
  }

  /// Average monthly spending on [where] over the last [months] full months
  /// (fewer when there is less data).
  double _monthlyAverage(bool Function(FinancialTransaction) where, {int months = 3}) {
    final now = _today;
    final span = (_daysOfData / 30).floor().clamp(1, months);
    final start = DateTime(now.year, now.month - span, now.day);
    final sum = _expenses.where((t) => where(t) && !t.date.isBefore(start) && !t.date.isAfter(now)).fold(0.0, (a, t) => a + t.amount);
    return sum / span;
  }

  double get _monthExpense {
    final now = _today;
    return _expenses.where((t) => t.date.year == now.year && t.date.month == now.month && !t.date.isAfter(_clock())).fold(0.0, (a, t) => a + t.amount);
  }

  double get _monthIncome {
    final now = _today;
    return repository.transactions
        .where((t) => t.type == TransactionType.income && t.date.year == now.year && t.date.month == now.month)
        .fold(0.0, (a, t) => a + t.amount);
  }

  double get _billsLeftThisMonth {
    final now = _clock();
    final lastDay = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    return repository
        .getUpcomingBills(start: _today, end: lastDay)
        .fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0));
  }

  // ───────────────────────── 5.4: real daily average ─────────────────────────

  Advice? _dailyAverage(String s) {
    if (!RegExp(r'\bmedia\b').hasMatch(s) || !RegExp(r'\b(?:por|ao|cada)\s+dia\b|\bdiari[oa]\b').hasMatch(s)) return null;
    final day = _today.day;
    final spent = _monthExpense;
    final avg = spent / day;
    final spoken = 'Sua média real este mês é ${CesarText.money(avg)} por dia: ${CesarText.money(spent)} em $day ${day == 1 ? 'dia' : 'dias'}.';
    return Advice('📊 $spoken\n\nIsso é o que você *já gastou* por dia. Para saber quanto *ainda pode* gastar por dia, '
        'pergunte "quanto posso gastar por dia?".', spoken, 'advice:daily_average');
  }

  // ───────────────────────── 5.5: "e se…?" ─────────────────────────

  /// "se eu cortar o delivery, quanto economizo?"
  Advice? _cut(String s) {
    final m = RegExp(r'\bse\s+(?:eu\s+)?(?:cortar|cortasse|parar\s+de\s+(?:gastar\s+com|pedir|usar|comprar)|parasse\s+de\s+(?:gastar\s+com|pedir|usar)|'
            r'cancelar|cancelasse|tirar|tirasse|deixar\s+de\s+(?:gastar\s+com|pedir|usar|comprar))\s+(.+)$')
        .firstMatch(s);
    if (m == null) return null;
    final term = _cleanTerm(m.group(1)!);
    if (term.isEmpty) return null;
    if (_daysOfData < 28) {
      const t = 'Ainda não tenho dados suficientes: preciso de pelo menos um mês de lançamentos para estimar quanto você economizaria.';
      return const Advice('🧮 $t', t, 'advice:cut');
    }
    final perMonth = _monthlyAverage((t) => _matches(t, term));
    if (perMonth <= 0) {
      final t = 'Não achei gastos com "$term" nos últimos meses, então cortar isso não muda nada. $_simNote';
      return Advice('🧮 $t', t, 'advice:cut');
    }
    final spoken = 'Se cortar $term, você economiza cerca de ${CesarText.money(perMonth)} por mês, '
        '${CesarText.money(perMonth * 12)} por ano.';
    return Advice('✂️ $spoken\n\nConta: média dos seus gastos com $term nos últimos meses. $_simNote', '$spoken $_simNote', 'advice:cut');
  }

  /// "se eu guardar 200 por mês, quando bato a meta?"
  Advice? _saveForGoal(String s) {
    final m = RegExp(r'\bse\s+(?:eu\s+)?(?:guardar|guardasse|juntar|juntasse|poupar|poupasse|economizar|economizasse|separar|separasse|depositar)\s+'
            r'(?:r\s*)?(\d+(?:[.,]\d+)?)\s*(?:reais\s+|conto\s+)?(?:por|ao|todo|cada|no)\s+mes')
        .firstMatch(s);
    if (m == null) return null;
    final perMonth = double.tryParse(m.group(1)!.replaceAll('.', '').replaceAll(',', '.')) ?? 0;
    if (perMonth <= 0) return null;
    final open = repository.goals.where((g) => !g.isReached).toList();
    FinancialGoal? goal;
    final named = RegExp(r'\bmeta\s+(?:d[aoe]s?\s+|pra\s+|para\s+)?([a-z][a-z ]*)').firstMatch(s)?.group(1)?.trim();
    if (named != null && named.isNotEmpty) {
      goal = open.where((g) => CesarText.fold(g.title).contains(named) || named.contains(CesarText.fold(g.title))).firstOrNull;
    }
    goal ??= open.length == 1 ? open.first : null;
    if (goal == null) {
      final list = open.isEmpty ? '' : ' Suas metas: ${open.map((g) => g.title).join(', ')}.';
      final t = open.isEmpty
          ? 'Guardando ${CesarText.money(perMonth)} por mês, você junta ${CesarText.money(perMonth * 12)} em um ano. '
              'Crie uma meta (ex.: "quero juntar 3000 pra viagem") que eu calculo quando você chega lá. $_simNote'
          : 'Para qual meta?$list Ex.: "se eu guardar ${perMonth.toStringAsFixed(0)} por mês, quando bato a meta da ${open.first.title.toLowerCase()}?"';
      return Advice('🎯 $t', t, 'advice:goal_date');
    }
    final months = (goal.remaining / perMonth).ceil();
    final now = _today;
    final when = DateTime(now.year, now.month + months);
    const names = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
    final whenLabel = '${names[when.month - 1]} de ${when.year}';
    var spoken = 'Guardando ${CesarText.money(perMonth)} por mês, você bate a meta ${goal.title} em $months '
        '${months == 1 ? 'mês' : 'meses'}, em $whenLabel. Faltam ${CesarText.money(goal.remaining)}.';
    if (goal.targetDate != null && when.isAfter(DateTime(goal.targetDate!.year, goal.targetDate!.month + 1, 0))) {
      final need = goal.suggestedMonthlyContribution;
      spoken += ' Isso passa do prazo${need != null ? '; para chegar a tempo, guarde ${CesarText.money(need)} por mês' : ''}.';
    }
    return Advice('🎯 $spoken\n\n$_simNote', '$spoken $_simNote', 'advice:goal_date');
  }

  /// "quanto sobra se eu pagar o aluguel?" (no value said: the bill's value).
  Advice? _payNamed(String s) {
    final m = RegExp(r'\b(?:sobra|sobraria|resta|restaria|fica|ficaria|fico\s+com)\b.*\bse\s+(?:eu\s+)?(?:pagar|pagasse|quitar|quitasse)\s+(.+)$').firstMatch(s) ??
        RegExp(r'\bse\s+(?:eu\s+)?(?:pagar|pagasse|quitar|quitasse)\s+(.+?)\s*,?\s*(?:quanto\s+)?(?:sobra|sobraria|resta|restaria|fica|ficaria)\b').firstMatch(s);
    if (m == null || RegExp(r'\d').hasMatch(s)) return null;
    final term = _cleanTerm(m.group(1)!);
    if (term.isEmpty) return null;
    double? amount;
    String? source;
    for (final b in repository.openBills) {
      if (CesarText.fold(b.title).contains(term) && (b.amount ?? 0) > 0) {
        amount = b.amount;
        source = 'a conta ${b.title}';
        break;
      }
    }
    if (amount == null) {
      final past = repository.transactions.where((t) => t.type == TransactionType.expense && _matches(t, term)).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      if (past.isNotEmpty) {
        amount = past.first.amount;
        source = 'o último ${past.first.title} (${CesarText.ddmm(past.first.date)})';
      }
    }
    if (amount == null) {
      final t = 'Não sei quanto é "$term" ainda. Me diga o valor (ex.: "quanto sobra se eu pagar 1400 de $term?"). $_simNote';
      return Advice('🧮 $t', t, 'hypothesis');
    }
    final balance = repository.totalBalance;
    final after = balance - amount;
    final spoken = 'Se pagar $term (${CesarText.money(amount)}), seu saldo vai de ${CesarText.money(balance)} para ${CesarText.money(after)}.'
        '${after < 0 ? ' Ficaria no vermelho.' : ''}';
    return Advice('🧮 $spoken\n\nUsei o valor de $source. $_simNote', '$spoken $_simNote', 'hypothesis');
  }

  // ───────────────────────── 5.5: where to save ─────────────────────────

  Advice? _whereToSave(String s) {
    if (!RegExp(r'\bonde\s+(?:eu\s+)?(?:posso|consigo|da\s+pra|da\s+para|devo|poderia|dava\s+pra)\s+(?:economizar|cortar|poupar|gastar\s+menos)|'
            r'\bcomo\s+(?:eu\s+)?(?:posso\s+|consigo\s+)?(?:economizar|gastar\s+menos|poupar)|\bdicas?\s+(?:de|pra|para)\s+economi|\bem\s+que\s+(?:eu\s+)?(?:posso\s+)?cortar')
        .hasMatch(s)) {
      return null;
    }
    if (_daysOfData < 28) {
      const t = 'Ainda não tenho dados suficientes: com pelo menos um mês de lançamentos eu comparo as categorias e mostro onde dá para cortar.';
      return const Advice('💡 $t', t, 'advice:where_to_save');
    }
    final now = _today;
    final last30Start = now.subtract(const Duration(days: 29));
    final prevStart = now.subtract(const Duration(days: 119));
    final recent = <String, double>{};
    final before = <String, double>{};
    for (final t in _expenses) {
      final d = CesarText.dayOnly(t.date);
      if (d.isAfter(now)) continue;
      if (!d.isBefore(last30Start)) {
        recent[t.category] = (recent[t.category] ?? 0) + t.amount;
      } else if (!d.isBefore(prevStart)) {
        before[t.category] = (before[t.category] ?? 0) + t.amount;
      }
    }
    final prevMonths = ((_daysOfData - 30) / 30).clamp(1, 3);
    final growth = <MapEntry<String, double>>[];
    for (final e in recent.entries) {
      final avg = (before[e.key] ?? 0) / prevMonths;
      if (e.value - avg > 1) growth.add(MapEntry(e.key, e.value - avg));
    }
    growth.sort((a, b) => b.value.compareTo(a.value));
    final lines = <String>[];
    for (final g in growth.take(3)) {
      final name = CesarText.categoryName(g.key, repository.budgets);
      final cur = recent[g.key]!;
      final avg = cur - g.value;
      lines.add('- **$name**: ${CesarText.money(cur)} nos últimos 30 dias, contra a média de ${CesarText.money(avg)}. '
          'Voltando à média, você economiza ${CesarText.money(g.value)} por mês.');
    }
    final fixed = _recurring();
    final fixedTotal = fixed.fold(0.0, (a, t) => a + t.amount);
    if (fixed.isNotEmpty) {
      lines.add('- **Gastos fixos**: ${fixed.length} (${CesarText.money(fixedTotal)} por mês). Vale revisar se ainda usa todos: '
          '${fixed.take(4).map((t) => t.title).join(', ')}.');
    }
    if (lines.isEmpty) {
      const t = 'Seus gastos estão dentro da média dos últimos meses, sem categoria crescendo. Bom sinal! 👏';
      return const Advice('💡 $t', t, 'advice:where_to_save');
    }
    final spoken = growth.isEmpty
        ? 'Nenhuma categoria cresceu; o que dá para rever são os gastos fixos, ${CesarText.money(fixedTotal)} por mês.'
        : 'Onde mais cresceu: ${growth.take(3).map((g) => CesarText.categoryName(g.key, repository.budgets)).join(', ')}.';
    return Advice('💡 Onde dá para economizar:\n${lines.join('\n')}', spoken, 'advice:where_to_save');
  }

  // ───────────────────────── 5.5: projections ─────────────────────────

  Advice? _monthProjection(String s) {
    if (!RegExp(r'\bcomo\s+(?:eu\s+)?(?:vou|vamos|devo)\s+fechar\s+(?:o\s+)?mes|\b(?:previsao|projecao)\s+(?:d[oe]|pro|para\s+o)\s+(?:fim\s+d[oe]\s+|final\s+d[oe]\s+)?mes|'
            r'\bvou\s+fechar\s+(?:o\s+mes\s+)?(?:no\s+)?(?:vermelho|azul|positivo|negativo)|\bquanto\s+(?:vai|vou|deve)\s+(?:sobrar|ter)\s+(?:no|ate\s+o)\s+(?:fim|final)\s+do\s+mes')
        .hasMatch(s)) {
      return null;
    }
    if (_daysOfData < 28) {
      const t = 'Ainda não tenho dados suficientes: com pelo menos um mês de lançamentos eu projeto como você fecha o mês.';
      return const Advice('🔮 $t', t, 'advice:projection');
    }
    final now = _today;
    final lastDay = DateTime(now.year, now.month + 1, 0).day;
    final daysLeft = lastDay - now.day;
    final monthSoFar = _monthIncome - _monthExpense;
    final bills = _billsLeftThisMonth;
    // Daily average without the fixed bills (they are counted apart).
    final variable = _expenses
        .where((t) => t.date.year == now.year && t.date.month == now.month && !t.isRecurrent && !t.date.isAfter(_clock()))
        .fold(0.0, (a, t) => a + t.amount);
    final daily = variable / now.day;
    final end = monthSoFar - bills - daily * daysLeft;
    final spoken = end >= 0
        ? 'No ritmo atual, você fecha o mês com cerca de ${CesarText.money(end)} sobrando.'
        : 'No ritmo atual, você fecha o mês ${CesarText.money(-end)} no vermelho.';
    final detail = 'Conta: até agora ${CesarText.money(monthSoFar)} (entradas − saídas), '
        '− ${CesarText.money(bills)} em contas que ainda vencem, '
        '− ${CesarText.money(daily)} por dia × $daysLeft ${daysLeft == 1 ? 'dia' : 'dias'} restantes.';
    return Advice('🔮 $spoken\n\n$detail', spoken, 'advice:projection');
  }

  /// "quanto vem a luz?": average of the last bills with that name.
  Advice? _forecastBill(String s) {
    final m = RegExp(r'\bquanto\s+(?:vai\s+vir|vem|deve\s+vir|vai\s+ser|vai\s+dar|deve\s+dar|deve\s+ser|vai\s+ficar|deve\s+ficar)\s+(?:a\s+|o\s+)?(?:conta\s+d[aeo]\s+|fatura\s+d[aeo]\s+)?(.+)$')
        .firstMatch(s);
    if (m == null) return null;
    final term = _cleanTerm(m.group(1)!.replaceAll(RegExp(r'\b(?:esse|este|nesse|neste|proximo)\s+mes\b'), ''));
    if (term.isEmpty) return null;
    final byMonth = <int, double>{};
    for (final t in _expenses.where((t) => _matches(t, term) && !t.date.isAfter(_clock()))) {
      final k = t.date.year * 12 + t.date.month;
      byMonth[k] = (byMonth[k] ?? 0) + t.amount;
    }
    if (byMonth.length < 2) {
      final t = byMonth.isEmpty
          ? 'Ainda não tenho dados suficientes: não achei nenhum lançamento de "$term".'
          : 'Ainda não tenho dados suficientes: só tenho um mês de "$term" (${CesarText.money(byMonth.values.first)}). Com dois ou mais eu faço a média.';
      return Advice('🔮 $t', t, 'advice:forecast');
    }
    final keys = byMonth.keys.toList()..sort();
    final last = keys.reversed.take(3).map((k) => byMonth[k]!).toList();
    final avg = last.reduce((a, b) => a + b) / last.length;
    final spoken = 'A conta de $term deve vir perto de ${CesarText.money(avg)}, pela média dos últimos ${last.length} meses.';
    final detail = last.reversed.map(CesarText.money).join(', ');
    return Advice('🔮 $spoken\n\nÚltimos valores: $detail.', spoken, 'advice:forecast');
  }

  // ───────────────────────── 5.5: subscriptions ─────────────────────────

  /// Recurring expenses, one per title (the latest).
  List<FinancialTransaction> _recurring() {
    final byTitle = <String, FinancialTransaction>{};
    for (final t in _expenses.where((t) => t.isRecurrent)) {
      final k = CesarText.fold(t.title);
      final cur = byTitle[k];
      if (cur == null || t.date.isAfter(cur.date)) byTitle[k] = t;
    }
    return byTitle.values.toList()..sort((a, b) => b.amount.compareTo(a.amount));
  }

  Advice? _subscriptions(String s) {
    if (!RegExp(r'\b(?:assinaturas?|gastos?\s+fixos?|contas?\s+fixas?|despesas?\s+fixas?|recorrentes?|mensalidades)\b').hasMatch(s) ||
        !RegExp(r'\b(?:quais|qual|quanto|quantas|quantos|lista|liste|mostra|mostre|tenho|pago|ver)\b').hasMatch(s)) {
      return null;
    }
    final list = _recurring();
    if (list.isEmpty) {
      const t = 'Você não tem assinaturas nem gastos fixos registrados. Para marcar um, diga algo como "pago 55 de netflix todo dia 12".';
      return const Advice('🔁 $t', t, 'advice:subscriptions');
    }
    final monthly = list.fold(0.0, (a, t) => a + t.amount);
    final lines = list.map((t) => '- ${t.title} — ${CesarText.money(t.amount)}/mês (${t.dueLabel.toLowerCase()})').join('\n');
    final spoken = 'Você tem ${list.length} ${list.length == 1 ? 'gasto fixo' : 'gastos fixos'}: '
        '${CesarText.money(monthly)} por mês, ${CesarText.money(monthly * 12)} por ano.';
    return Advice('🔁 $spoken\n\n$lines', spoken, 'advice:subscriptions');
  }

  // ───────────────────────── proactive ─────────────────────────

  /// Monday of the week of [d].
  static DateTime weekStart(DateTime d) => CesarText.dayOnly(d).subtract(Duration(days: d.weekday - 1));

  /// Last week's summary, to show on the first opening of a Monday (or of the
  /// week, if Monday was skipped). Null when there is nothing to tell.
  Advice? weeklySummary() {
    final thisWeek = weekStart(_clock());
    final start = thisWeek.subtract(const Duration(days: 7));
    final prevStart = start.subtract(const Duration(days: 7));
    double sumIn(DateTime a, DateTime b) =>
        _expenses.where((t) => !t.date.isBefore(a) && t.date.isBefore(b)).fold(0.0, (x, t) => x + t.amount);
    final week = sumIn(start, thisWeek);
    if (week <= 0) return null;
    final prev = sumIn(prevStart, start);
    final byCat = <String, double>{};
    for (final t in _expenses.where((t) => !t.date.isBefore(start) && t.date.isBefore(thisWeek))) {
      byCat[t.category] = (byCat[t.category] ?? 0) + t.amount;
    }
    final top = byCat.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final topName = CesarText.categoryName(top.key, repository.budgets);
    String cmp = '';
    if (prev > 0) {
      final pct = ((week - prev) / prev * 100).round();
      cmp = pct == 0 ? ' Igual à semana anterior.' : ' ${pct.abs()}% ${pct > 0 ? 'a mais' : 'a menos'} que na semana anterior.';
    }
    final spoken = 'Resumo da semana passada: você gastou ${CesarText.money(week)}, mais em $topName (${CesarText.money(top.value)}).$cmp';
    return Advice('🗓️ $spoken', spoken, 'advice:weekly');
  }

  /// Categories whose spending in the last 7 days is at least twice their
  /// weekly average over the 4 weeks before. [muted] categories are skipped.
  List<Advice> unusualSpending({Set<String> muted = const {}}) {
    final now = _clock();
    final weekAgo = CesarText.dayOnly(now).subtract(const Duration(days: 6));
    final monthBefore = weekAgo.subtract(const Duration(days: 28));
    if (_daysOfData < 35) return const [];
    final week = <String, double>{};
    final before = <String, double>{};
    for (final t in _expenses) {
      if (t.date.isAfter(now)) continue;
      if (!t.date.isBefore(weekAgo)) {
        week[t.category] = (week[t.category] ?? 0) + t.amount;
      } else if (!t.date.isBefore(monthBefore)) {
        before[t.category] = (before[t.category] ?? 0) + t.amount;
      }
    }
    final result = <Advice>[];
    for (final e in week.entries) {
      if (muted.contains(e.key)) continue;
      final avg = (before[e.key] ?? 0) / 4;
      if (avg <= 0 || e.value < avg * 2) continue;
      final name = CesarText.categoryName(e.key, repository.budgets);
      final times = (e.value / avg).toStringAsFixed(1).replaceAll('.', ',');
      final t = 'Gasto fora do padrão em $name: ${CesarText.money(e.value)} nos últimos 7 dias, ${times}× a média semanal '
          '(${CesarText.money(avg)}). Se não quiser mais esse aviso, diga "para de me avisar de ${name.toLowerCase()}".';
      result.add(Advice('⚠️ $t', t, 'advice:unusual:${e.key}'));
    }
    return result;
  }
}
