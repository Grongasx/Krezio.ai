import 'dart:math';

import '../backend/models/financial_goal.dart';
import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'analytics/cash_flow_forecast.dart';
import 'analytics/financial_profile.dart';
import 'cesar_text.dart';
import 'transaction_code.dart';

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
    return _why(s) ??
        _duplicates(s) ??
        _insights(s) ??
        _averages(s) ??
        _yearly(s) ??
        _weekdayPeak(s) ??
        _peakMonth(s) ??
        _timeToSave(s) ??
        _raise(s) ??
        _withoutIt(s) ??
        _cut(s) ??
        _saveForGoal(s) ??
        _payNamed(s) ??
        _whereToSave(s) ??
        _monthProjection(s) ??
        _balanceOn(s) ??
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
    // "delivery", "streaming": the apps, whatever their titles say.
    if (RegExp(r'^(?:delivery|deliveries|pedidos?\s+de\s+comida|comida\s+por\s+app|app\s+de\s+comida)$').hasMatch(f)) {
      return FinancialProfile.deliveryTitles.hasMatch(CesarText.fold(t.title));
    }
    if (RegExp(r'^(?:streaming|streamings)$').hasMatch(f)) return FinancialProfile.streamingTitles.hasMatch(CesarText.fold(t.title));
    final inTitles = _titleTerms.putIfAbsent(f, () => repository.transactions.any((x) => CesarText.fold(x.title).contains(f)));
    if (inTitles) return CesarText.fold(t.title).contains(f);
    final code = CesarText.resolveCategory(term, repository.budgets);
    return code != null && t.category == code;
  }

  final Map<String, bool> _titleTerms = {};

  /// [term] as a brand is spelled in some title ("ifood" → "iFood"); an
  /// ordinary word stays as said ("mercado", not "Mercado").
  String _display(String term) => CesarText.brandSpelling(term, repository.transactions.map((t) => t.title));

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
    return _expenses.where((t) => t.date.year == now.year && t.date.month == now.month && !CesarText.dayOnly(t.date).isAfter(_today)).fold(0.0, (a, t) => a + t.amount);
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

  // ───────────────────────── 5.4: real averages ─────────────────────────

  /// What is left of a question once the measure words are gone: the
  /// category or place it is about ("qual meu gasto médio diário com
  /// mercado?" → "mercado"), or ''.
  static String _subject(String s) => s
      .replaceAll(
          RegExp(r'\b(?:quanto|quantos|qual|quais|e|o|a|os|as|meu|minha|meus|minhas|eu|gasto|gastos|gastei|gastando|medio|media|medias|em|por|ao|cada|dia|dias|'
              r'semana|semanas|mes|meses|ano|anos|diario|diaria|semanal|mensal|anual|anualmente|com|de|no|na|do|da|dos|das|que|um|uma|valor|real|normalmente|'
              r'geralmente|mais|ou|menos|total|todo|toda|inteiro|cesar|isso|nisso|pago|pagando|essa|esse|esta|este|nessa|nesse|nesta|neste|passada|passado|'
              r'ultima|ultimo|ultimas|ultimos|hoje|ontem|agora|ate)\b'),
          ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// This month's spending so far, on [term] (a category or a title) or on everything.
  double _monthSpentOn(String term) {
    final now = _today;
    final start = DateTime(now.year, now.month);
    final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
    if (term.isEmpty) return _monthExpense;
    return repository.getSpendingByCategoryOrTerm(term, start: start, end: end).fold(0.0, (a, t) => a + t.amount);
  }

  /// "em média quanto eu gasto por dia?", "quanto gasto por semana em
  /// média?", "qual meu gasto médio diário com mercado?": the real average of
  /// this month so far — of everything, or of one category/place.
  Advice? _averages(String s) {
    if (!RegExp(r'\bmedi[ao]s?\b').hasMatch(s)) return null;
    final unit = RegExp(r'\b(?:por|ao|cada|na|no)\s+(dia|semana|mes)\b|\b(diari[oa]|semanal|mensal)\b').firstMatch(s);
    if (unit == null) return null;
    final u = unit.group(1) ?? unit.group(2)!;
    final term = _subject(s);
    final what = term.isEmpty ? '' : ' com ${_display(term)}';
    final day = _today.day;
    final spent = _monthSpentOn(term);
    if (u.startsWith('dia')) {
      // "por dia essa semana", "por dia no mês passado": the period said.
      final week = RegExp(r'\b(?:essa|esta|nessa|nesta)\s+semana\b').hasMatch(s);
      final lastWeek = RegExp(r'\bsemana\s+passada\b|\bultima\s+semana\b').hasMatch(s);
      final lastMonth = RegExp(r'\bmes\s+passado\b|\bultimo\s+mes\b').hasMatch(s);
      if (week || lastWeek || lastMonth) {
        final monday = _today.subtract(Duration(days: _today.weekday - 1));
        final start = week ? monday : (lastWeek ? monday.subtract(const Duration(days: 7)) : DateTime(_today.year, _today.month - 1));
        final end = week ? _today : (lastWeek ? monday.subtract(const Duration(days: 1)) : DateTime(_today.year, _today.month, 0));
        final days = end.difference(start).inDays + 1;
        final items = term.isEmpty
            ? _expenses.where((t) => !CesarText.dayOnly(t.date).isBefore(start) && !CesarText.dayOnly(t.date).isAfter(end))
            : repository.getSpendingByCategoryOrTerm(term, start: start, end: DateTime(end.year, end.month, end.day, 23, 59, 59));
        final total = items.fold(0.0, (a, t) => a + t.amount);
        final label = week ? 'esta semana' : (lastWeek ? 'na semana passada' : 'no mês passado');
        final spoken = 'Sua média $label é ${CesarText.money(total / days)} por dia$what: ${CesarText.money(total)} em $days ${days == 1 ? 'dia' : 'dias'}.';
        return Advice('📊 $spoken', spoken, 'advice:daily_average');
      }
      final avg = spent / day;
      final spoken = 'Sua média real este mês é ${CesarText.money(avg)} por dia$what: ${CesarText.money(spent)} em $day ${day == 1 ? 'dia' : 'dias'}.';
      return Advice('📊 $spoken\n\nIsso é o que você *já gastou* por dia. Para saber quanto *ainda pode* gastar por dia, '
          'pergunte "quanto posso gastar por dia?".', spoken, 'advice:daily_average');
    }
    if (u.startsWith('seman')) {
      final weeks = day / 7;
      final avg = spent / weeks;
      final spoken = 'Sua média este mês é ${CesarText.money(avg)} por semana$what: ${CesarText.money(spent)} em $day ${day == 1 ? 'dia' : 'dias'} '
          '(${weeks.toStringAsFixed(1).replaceAll('.', ',')} semanas).';
      return Advice('📊 $spoken', spoken, 'advice:weekly_average');
    }
    // A month: the average of the last full months, when there are any.
    final perMonth = term.isEmpty ? _monthlyAverage((_) => true) : _monthlyAverage(_filterFor(term));
    final span = (_daysOfData / 30).floor().clamp(0, 3);
    if (span == 0) {
      final days = DateTime(_today.year, _today.month + 1, 0).day;
      final projected = spent / day * days;
      final spoken = 'Ainda não tenho um mês inteiro de dados: até agora foram ${CesarText.money(spent)}$what, '
          'o que daria uns ${CesarText.money(projected)} no mês nesse ritmo.';
      return Advice('📊 $spoken', spoken, 'advice:monthly_average');
    }
    final spoken = '${span == 1 ? 'No último mês' : 'Na média dos últimos $span meses'}, você gastou ${CesarText.money(perMonth)}${span == 1 ? '' : ' por mês'}$what. '
        'Este mês, até agora: ${CesarText.money(spent)}.';
    return Advice('📊 $spoken', spoken, 'advice:monthly_average');
  }

  /// Records of a category or title, as the reports filter them.
  bool Function(FinancialTransaction) _filterFor(String term) {
    final ids = repository.getSpendingByCategoryOrTerm(term).map((t) => t.id).toSet();
    return (t) => ids.contains(t.id);
  }

  /// "quanto eu gasto por ano com academia?": a fixed bill × 12, or the
  /// monthly average × 12.
  Advice? _yearly(String s) {
    if (!RegExp(r'\b(?:por|ao|num|em\s+um)\s+ano\b|\banual(?:mente)?\b').hasMatch(s) || !RegExp(r'\b(?:quanto|qual)\b').hasMatch(s)) return null;
    if (RegExp(r'\b(?:ganho|recebo|ganhei|recebi|rende|rendimento|salario)\b').hasMatch(s)) return null;
    final term = _subject(s);
    if (term.isEmpty) {
      final perMonth = _monthlyAverage((_) => true);
      if (perMonth <= 0) return null;
      final spoken = 'No ritmo dos últimos meses, você gasta uns ${CesarText.money(perMonth * 12)} por ano (${CesarText.money(perMonth)} por mês).';
      return Advice('📆 $spoken', spoken, 'advice:yearly');
    }
    final fixed = _recurring().where((t) => CesarText.fold(t.title).contains(CesarText.fold(term))).toList();
    if (fixed.isNotEmpty) {
      final monthly = fixed.fold(0.0, (a, t) => a + t.amount);
      final names = fixed.map((t) => t.title).join(' e ');
      final spoken = 'Com $names você paga ${CesarText.money(monthly)} por mês: ${CesarText.money(monthly * 12)} por ano.';
      return Advice('📆 $spoken', spoken, 'advice:yearly');
    }
    final perMonth = _monthlyAverage(_filterFor(term));
    if (perMonth <= 0) {
      final t = 'Não achei gastos com "$term" nos últimos meses para estimar o ano.';
      return Advice('📆 $t', t, 'advice:yearly');
    }
    final spoken = 'Com $term você gasta uns ${CesarText.money(perMonth)} por mês, o que dá ${CesarText.money(perMonth * 12)} por ano.';
    return Advice('📆 $spoken', spoken, 'advice:yearly');
  }

  static const _weekdayNames = ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];

  /// "qual dia da semana eu mais gasto?": the weekday with the highest
  /// average of variable spending (fixed bills left out) in the last 90 days.
  Advice? _weekdayPeak(String s) {
    if (!RegExp(r'\bdias?\s+da\s+semana\b').hasMatch(s) || !RegExp(r'\b(?:mais|menos)\b').hasMatch(s)) return null;
    final least = RegExp(r'\bmenos\b').hasMatch(s);
    final days = min(90, _daysOfData);
    if (days < 14) {
      const t = 'Ainda tenho poucos dias de dados: com umas duas semanas de lançamentos eu te digo o dia da semana em que você mais gasta.';
      return const Advice('📅 $t', t, 'advice:weekday');
    }
    final start = _today.subtract(Duration(days: days - 1));
    final total = List<double>.filled(7, 0);
    final count = List<int>.filled(7, 0);
    for (var d = start; !d.isAfter(_today); d = d.add(const Duration(days: 1))) {
      count[d.weekday - 1]++;
    }
    for (final t in _expenses.where((t) => !t.isRecurrent && !CesarText.dayOnly(t.date).isBefore(start) && !CesarText.dayOnly(t.date).isAfter(_today))) {
      total[t.date.weekday - 1] += t.amount;
    }
    final avg = [for (var i = 0; i < 7; i++) count[i] == 0 ? 0.0 : total[i] / count[i]];
    final order = List.generate(7, (i) => i)..sort((a, b) => least ? avg[a].compareTo(avg[b]) : avg[b].compareTo(avg[a]));
    final top = order.first;
    final name = _weekdayNames[top];
    final plural = top >= 5 ? '${name}s' : '${name}s-feiras';
    final second = order[1];
    final spoken = least
        ? 'O dia em que você menos gasta é $name: em média ${CesarText.money(avg[top])} por $name.'
        : 'Você gasta mais às $plural: em média ${CesarText.money(avg[top])} por $name, contra ${CesarText.money(avg[second])} '
            'no segundo dia mais caro (${_weekdayNames[second]}).';
    return Advice('📅 $spoken\n\nConta: gastos do dia a dia dos últimos $days dias, sem as contas fixas.', spoken, 'advice:weekday');
  }

  static const _monthNames = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];

  /// "qual foi o mês que eu mais gastei?": the months with data, by total.
  Advice? _peakMonth(String s) {
    // "qual foi o mês que eu mais gastei?", "em que mês eu gastei menos?" —
    // not "gastei mais que mês passado?" (a comparison).
    if (!RegExp(r'\b(?:qual|em\s+qual|em\s+que|que)\s+(?:foi\s+)?(?:o\s+)?mes\b(?!\s+(?:passado|anterior|retrasado))').hasMatch(s) ||
        !RegExp(r'\b(?:mais|menos)\s+(?:eu\s+)?gast|\bgastei\s+(?:mais|menos)\b').hasMatch(s) ||
        RegExp(r'\b(?:mais|menos)\s+(?:do\s+)?que\s+(?:o\s+|no\s+|em\s+)?mes\b').hasMatch(s)) {
      return null;
    }
    final least = RegExp(r'\bmenos\b').hasMatch(s);
    final byMonth = <int, double>{};
    for (final t in _expenses.where((t) => !CesarText.dayOnly(t.date).isAfter(_today))) {
      final k = t.date.year * 12 + t.date.month - 1;
      byMonth[k] = (byMonth[k] ?? 0) + t.amount;
    }
    if (byMonth.isEmpty) {
      const t = 'Ainda não tenho gastos registrados para comparar os meses.';
      return const Advice('📆 $t', t, 'advice:peak_month');
    }
    final cur = _today.year * 12 + _today.month - 1;
    final ranked = byMonth.entries.toList()..sort((a, b) => least ? a.value.compareTo(b.value) : b.value.compareTo(a.value));
    String label(int k) => '${_monthNames[k % 12]}${k ~/ 12 == _today.year ? '' : ' de ${k ~/ 12}'}';
    final top = ranked.first;
    final note = top.key == cur ? ' (e o mês ainda não acabou)' : '';
    final rest = ranked.skip(1).take(2).map((e) => '${label(e.key)} (${CesarText.money(e.value)})').join(' e ');
    final spoken = 'O mês em que você ${least ? 'menos' : 'mais'} gastou foi ${label(top.key)}: ${CesarText.money(top.value)}$note.'
        '${rest.isEmpty ? '' : ' Depois vêm $rest.'}';
    return Advice('📆 $spoken', spoken, 'advice:peak_month');
  }

  /// "em quanto tempo eu junto 5 mil guardando 500 por mês?"
  Advice? _timeToSave(String s) {
    final m = RegExp(r'\b(?:em\s+)?quanto\s+tempo\s+(?:eu\s+)?(?:levo\s+(?:pra|para)\s+)?(?:junto|juntaria|consigo\s+juntar|guardo|guardaria|chego\s+(?:a|em|nos?)|tenho|teria|juntar|guardar)\s+'
            r'(.+?)\s+(?:se\s+(?:eu\s+)?)?(?:guardando|juntando|poupando|economizando|separando|depositando|guardar|juntar|poupar|economizar|separar|depositar)\s+(.+?)\s+(?:por|ao|todo|cada)\s+mes\b')
        .firstMatch(s);
    if (m == null) return null;
    final target = _money(m.group(1)!), monthly = _money(m.group(2)!);
    if (target == null || monthly == null || monthly <= 0) return null;
    final months = (target / monthly).ceil();
    final when = DateTime(_today.year, _today.month + months);
    // The same money in a savings account that pays ~0.8% a month.
    const rate = 0.008;
    final withYield = (log(1 + target * rate / monthly) / log(1 + rate)).ceil();
    final yieldNote = withYield < months
        ? ' Se o dinheiro ficar rendendo uns 0,8% ao mês (algo como o Tesouro Selic ou um CDB de liquidez diária), chega em $withYield.'
        : '';
    final spoken = 'Guardando ${CesarText.money(monthly)} por mês, você junta ${CesarText.money(target)} em $months ${months == 1 ? 'mês' : 'meses'}, '
        'lá por ${_monthNames[when.month - 1]} de ${when.year}.$yieldNote';
    return Advice('🎯 $spoken\n\nQuer que eu crie essa meta? Diga, por exemplo, "quero juntar ${target.toStringAsFixed(0)} até ${_monthNames[when.month - 1]}".',
        spoken, 'advice:time_to_save');
  }

  /// "5 mil", "R$ 3.000", "500".
  static double? _money(String text) {
    var t = text.replaceAll(RegExp(r'r\$\s*'), '');
    t = t.replaceAllMapped(RegExp(r'(\d+(?:[.,]\d+)?)\s*(?:mil|k)\b'),
        (m) => '${(double.parse(m.group(1)!.replaceAll('.', '').replaceAll(',', '.')) * 1000).round()}');
    final m = RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)').firstMatch(t);
    if (m == null) return null;
    final raw = m.group(1)!;
    final v = raw.contains(RegExp(r'\.\d{3}')) ? double.tryParse(raw.replaceAll('.', '').replaceAll(',', '.')) : double.tryParse(raw.replaceAll(',', '.'));
    return v != null && v > 0 ? v : null;
  }

  /// The salary: the latest income in the salary category (or the
  /// average monthly income when there is none).
  double get _salary {
    final salaries = repository.transactions.where((t) => t.type == TransactionType.income && t.category == 'salary').toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (salaries.isNotEmpty) return salaries.first.amount;
    return _monthIncome;
  }

  /// "se meu salário aumentar 10%, quanto sobra por mês?", "se eu ganhar
  /// 500 a mais?"
  Advice? _raise(String s) {
    final pct = RegExp(r'\bse\s+(?:o\s+)?(?:meu\s+)?(?:salario|renda)\s+(?:aumentar|subir|crescer|tiver\s+(?:um\s+)?aumento\s+de|for\s+reajustad[oa]\s+em)\s+(?:de\s+|em\s+)?'
            r'(\d+(?:[.,]\d+)?)\s*(%|por\s*cento)')
        .firstMatch(s);
    final more = RegExp(r'\bse\s+(?:eu\s+)?(?:ganhar|receber)\s+(?:mais\s+)?(?:r\$\s*)?(\d+(?:[.,]\d+)?(?:\s*mil)?)\s*(?:reais\s+)?(?:a\s+mais|de\s+aumento|mais)\b')
        .firstMatch(s);
    if (pct == null && more == null) return null;
    final salary = _salary;
    if (salary <= 0) {
      const t = 'Ainda não sei o seu salário. Me diga quando ele cair (ex.: "recebi 3000 de salário") que eu faço a conta.';
      return const Advice('🧮 $t', t, 'hypothesis');
    }
    final raise = pct != null ? salary * (double.parse(pct.group(1)!.replaceAll(',', '.')) / 100) : (_money(more!.group(1)!) ?? 0);
    if (raise <= 0) return null;
    final newSalary = salary + raise;
    final spend = _monthlyAverage((_) => true);
    final otherIncome = (_monthIncome - salary).clamp(0, double.infinity);
    final leftNow = salary + otherIncome - spend;
    final leftAfter = leftNow + raise;
    final spoken = 'Com ${pct != null ? '+${pct.group(1)}%' : '+${CesarText.money(raise)}'}, seu salário vai de ${CesarText.money(salary)} para '
        '${CesarText.money(newSalary)}. Mantendo os gastos (uns ${CesarText.money(spend)} por mês), '
        '${leftAfter >= 0 ? 'sobrariam uns ${CesarText.money(leftAfter)} por mês' : 'ainda faltariam ${CesarText.money(-leftAfter)} por mês'}'
        ' — hoje ${leftNow >= 0 ? 'sobram ${CesarText.money(leftNow)}' : 'faltam ${CesarText.money(-leftNow)}'}.';
    return Advice('🧮 $spoken\n\n💡 Se vier o aumento, guardar a diferença logo que cair evita que ela suma no dia a dia. $_simNote', '$spoken $_simNote', 'hypothesis');
  }

  /// "quanto eu teria hoje se não tivesse pedido ifood?": the balance plus
  /// what went to it this month.
  Advice? _withoutIt(String s) {
    final m = RegExp(r'\b(?:quanto|qto)\s+(?:eu\s+)?(?:teria|tinha|estaria\s+com|sobraria)\b.*\bse\s+(?:eu\s+)?(?:nao\s+)?(?:tivesse|houvesse)\s+'
            r'(?:pedido|gastado(?:\s+com|\s+no|\s+na|\s+em)?|comprado|usado|pago|ido\s+(?:no|na|ao|a))\s+(.+)$')
        .firstMatch(s);
    if (m == null) return null;
    final term = _cleanTerm(m.group(1)!.replaceAll(RegExp(r'\b(?:esse|este|nesse|neste)\s+mes\b'), ''));
    if (term.isEmpty) return null;
    final now = _today;
    final delivery = RegExp(r'^(?:delivery|comida|pedidos?)$').hasMatch(term);
    bool hit(FinancialTransaction t) => delivery ? FinancialProfile.deliveryTitles.hasMatch(CesarText.fold(t.title)) : _matches(t, term);
    final month = _expenses.where((t) => t.date.year == now.year && t.date.month == now.month && !CesarText.dayOnly(t.date).isAfter(_today) && hit(t)).toList();
    final spentMonth = month.fold(0.0, (a, t) => a + t.amount);
    if (spentMonth <= 0) {
      final t = 'Este mês não achei gastos com "$term", então o seu saldo seria o mesmo: ${CesarText.money(repository.totalBalance)}.';
      return Advice('🧮 $t', t, 'hypothesis');
    }
    final balance = repository.totalBalance;
    final yearAvg = _monthlyAverage(hit);
    final spoken = 'Sem ${_display(term)} este mês, você teria ${CesarText.money(balance + spentMonth)} hoje: ${CesarText.money(spentMonth)} a mais '
        '(${month.length} ${month.length == 1 ? 'vez' : 'vezes'}).';
    final year = yearAvg > 0 ? '\n\nNo ritmo dos últimos meses, $term custa uns ${CesarText.money(yearAvg * 12)} por ano.' : '';
    return Advice('🧮 $spoken$year $_simNote', '$spoken $_simNote', 'hypothesis');
  }

  // ───────────────────────── why, duplicates, insights, balance ahead ─────────────────────────

  /// Spending of [items] by category.
  static Map<String, double> _byCategory(Iterable<FinancialTransaction> items) {
    final out = <String, double>{};
    for (final t in items) {
      out[t.category] = (out[t.category] ?? 0) + t.amount;
    }
    return out;
  }

  /// Day-to-day spending: fixed bills move on their own calendar (a rent
  /// missing from last month's data is not "spending more").
  Iterable<FinancialTransaction> get _variable => _expenses.where((t) => !t.isRecurrent);

  /// This month's variable spending up to today, and the average of the same
  /// days of the months before that have data (up to 3) — null when there is none.
  ({Map<String, double> cur, Map<String, double>? ref, int months}) _monthToDate() {
    final now = _today;
    final cur = _byCategory(_variable.where((t) => t.date.year == now.year && t.date.month == now.month && !CesarText.dayOnly(t.date).isAfter(now)));
    final refs = <Map<String, double>>[];
    for (var back = 1; back <= 3; back++) {
      final m = DateTime(now.year, now.month - back);
      if (!repository.transactions.any((t) => t.date.year == m.year && t.date.month == m.month)) continue;
      final until = min(now.day, DateTime(m.year, m.month + 1, 0).day);
      refs.add(_byCategory(_variable.where((t) => t.date.year == m.year && t.date.month == m.month && t.date.day <= until)));
    }
    if (refs.isEmpty) return (cur: cur, ref: null, months: 0);
    final ref = <String, double>{};
    for (final r in refs) {
      r.forEach((k, v) => ref[k] = (ref[k] ?? 0) + v / refs.length);
    }
    return (cur: cur, ref: ref, months: refs.length);
  }

  /// The purchases behind a category this month: "Aluguel (R$ 1.400,00)",
  /// "iFood 3× (R$ 230,00)".
  String _behind(String category) {
    final now = _today;
    final groups = <String, List<FinancialTransaction>>{};
    for (final t in _variable.where((t) => t.category == category && t.date.year == now.year && t.date.month == now.month && !CesarText.dayOnly(t.date).isAfter(now))) {
      groups.putIfAbsent(t.title, () => []).add(t);
    }
    final ranked = groups.entries.toList()
      ..sort((a, b) => b.value.fold(0.0, (x, t) => x + t.amount).compareTo(a.value.fold(0.0, (x, t) => x + t.amount)));
    return ranked.take(2).map((e) {
      final sum = e.value.fold(0.0, (x, t) => x + t.amount);
      return e.value.length > 1 ? '${e.key} ${e.value.length}× (${CesarText.money(sum)})' : '${e.key} (${CesarText.money(sum)})';
    }).join(' e ');
  }

  /// "por que eu gastei tanto esse mês?", "por que meu saldo caiu?", "o que
  /// aconteceu com meu dinheiro?": this month against the same days of the
  /// months before, category by category, with the purchases behind it.
  Advice? _why(String s) {
    if (!RegExp(r'\bpor\s*que\b.*\b(?:gastei|gastando|gastos?|sobrou|sobra|saldo|dinheiro|grana|despesas?|mes)\b|'
            r'\bo\s+que\s+(?:aconteceu|houve)\s+com\s+(?:o\s+|a\s+)?(?:meu\s+|minha\s+)?(?:dinheiro|saldo|mes|grana|conta)\b|\bonde\s+(?:eu\s+)?errei\b')
        .hasMatch(s)) {
      return null;
    }
    final now = _today;
    final m = _monthToDate();
    final curTotal = m.cur.values.fold(0.0, (a, v) => a + v);
    String name(String code) => CesarText.categoryName(code, repository.budgets);
    if (m.ref == null) {
      final top = m.cur.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      if (top.isEmpty) {
        const t = 'Ainda não tem gastos registrados este mês para explicar.';
        return const Advice('🔍 $t', t, 'advice:why');
      }
      final lines = top.take(3).map((e) => '- **${name(e.key)}**: ${CesarText.money(e.value)} — ${_behind(e.key)}').join('\n');
      final t = 'Seus gastos do dia a dia somam ${CesarText.money(curTotal)} este mês. Ainda não tenho meses anteriores para comparar, mas o que mais pesou foi:';
      return Advice('🔍 $t\n$lines', '$t ${name(top.first.key)}.', 'advice:why');
    }
    final ref = m.ref!;
    final refTotal = ref.values.fold(0.0, (a, v) => a + v);
    final diffs = {for (final c in {...m.cur.keys, ...ref.keys}) c: (m.cur[c] ?? 0) - (ref[c] ?? 0)};
    final up = diffs.entries.where((e) => e.value >= 20).toList()..sort((a, b) => b.value.compareTo(a.value));
    final lines = up.take(3).map((e) => '- **${name(e.key)}**: +${CesarText.money(e.value)} — ${_behind(e.key)}').join('\n');
    final window = 'no mesmo período ${m.months == 1 ? 'do mês passado' : 'dos últimos ${m.months} meses'}';
    final String head;
    if (curTotal > refTotal * 1.05) {
      head = 'Até hoje (dia ${now.day}), seus gastos do dia a dia somam ${CesarText.money(curTotal)} — ${CesarText.money(curTotal - refTotal)} a mais que $window '
          '(${CesarText.money(refTotal)}).${up.isEmpty ? '' : ' O que mais pesou:'}';
    } else if (curTotal < refTotal * 0.95) {
      head = 'Na verdade, no dia a dia você gastou menos que o normal: ${CesarText.money(curTotal)} até hoje, contra ${CesarText.money(refTotal)} $window. 👏'
          '${up.isEmpty ? '' : ' Só subiram:'}';
    } else {
      head = 'No dia a dia você está no seu ritmo normal: ${CesarText.money(curTotal)} até hoje, contra ${CesarText.money(refTotal)} $window.'
          '${up.isEmpty ? '' : ' O que subiu:'}';
    }
    // "por que meu saldo caiu?": what came in matters too.
    var income = '';
    if (RegExp(r'\b(?:saldo|sobrou|sobra|dinheiro|grana)\b').hasMatch(s)) {
      final inNow = repository.transactions
          .where((t) => t.type == TransactionType.income && t.date.year == now.year && t.date.month == now.month && !CesarText.dayOnly(t.date).isAfter(now))
          .fold(0.0, (a, t) => a + t.amount);
      final avgIn = _monthlyAverageIncome();
      if (avgIn > 0 && inNow < avgIn * 0.9) {
        income = '\n\n💰 E entrou menos: ${CesarText.money(inNow)} até agora, contra uns ${CesarText.money(avgIn)} num mês normal.';
      }
    }
    // The fixed bills apart: they are the month's, not a change of habit.
    final fixedNow = _expenses
        .where((t) => t.isRecurrent && t.date.year == now.year && t.date.month == now.month && !CesarText.dayOnly(t.date).isAfter(now))
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    final fixed = fixedNow.isEmpty
        ? ''
        : '\n\n🔁 Fora isso, as contas fixas já pagas este mês somam ${CesarText.money(fixedNow.fold(0.0, (a, t) => a + t.amount))} '
            '(${fixedNow.take(3).map((t) => t.title).join(', ')}).';
    final close = curTotal > refTotal * 1.05 ? '\n\nQuer que eu veja onde dá pra cortar? Pergunte "o que eu devo cortar?".' : '';
    return Advice('🔍 $head${lines.isEmpty ? '' : '\n$lines'}$fixed$income$close', head.replaceAll(' 👏', ''), 'advice:why');
  }

  /// Average monthly income over the last full months (up to 3).
  double _monthlyAverageIncome() {
    final now = _today;
    final sums = <double>[];
    for (var back = 1; back <= 3; back++) {
      final m = DateTime(now.year, now.month - back);
      final inMonth = repository.transactions.where((t) => t.type == TransactionType.income && t.date.year == m.year && t.date.month == m.month);
      if (inMonth.isEmpty) continue;
      sums.add(inMonth.fold(0.0, (a, t) => a + t.amount));
    }
    return sums.isEmpty ? 0 : sums.reduce((a, b) => a + b) / sums.length;
  }

  /// "tem algum lançamento duplicado?", "lancei duas vezes?": the same name
  /// and value within a day, in the last 60 days.
  Advice? _duplicates(String s) {
    if (!RegExp(r'\bduplicad[oa]s?\b|\brepetid[oa]s?\b|\b(?:lancei|registrei|anotei|lancou|registrou|anotou|salvou|salvei)\s+(?:algo\s+|alguma\s+coisa\s+|algum\s+gasto\s+)?'
            r'(?:duas\s+vezes|em\s+dobro|repetido|duplicado)\b|\bem\s+dobro\b')
        .hasMatch(s)) {
      return null;
    }
    final since = _today.subtract(const Duration(days: 60));
    final groups = <String, List<FinancialTransaction>>{};
    for (final t in repository.transactions.where((t) => !t.date.isBefore(since) && !t.isInternalTransfer)) {
      groups.putIfAbsent('${t.type.name}|${CesarText.fold(t.title)}|${(t.amount * 100).round()}', () => []).add(t);
    }
    final pairs = <(FinancialTransaction, FinancialTransaction)>[];
    for (final g in groups.values) {
      g.sort((a, b) => a.date.compareTo(b.date));
      for (var i = 1; i < g.length; i++) {
        if (CesarText.dayOnly(g[i].date).difference(CesarText.dayOnly(g[i - 1].date)).inDays <= 1) pairs.add((g[i - 1], g[i]));
      }
    }
    if (pairs.isEmpty) {
      const t = 'Não achei lançamentos repetidos nos últimos 60 dias (mesmo nome e mesmo valor em até um dia). 👍';
      return const Advice('✅ $t', t, 'advice:duplicates');
    }
    pairs.sort((a, b) => b.$2.date.compareTo(a.$2.date));
    final lines = pairs.take(5).map((p) => '- **${p.$1.title}** ${CesarText.money(p.$1.amount)}: ${CesarText.ddmm(p.$1.date)} ${TransactionCode.label(p.$1.id)} '
        'e ${CesarText.ddmm(p.$2.date)} ${TransactionCode.label(p.$2.id)}');
    final t = 'Achei ${pairs.length} ${pairs.length == 1 ? 'possível repetido' : 'possíveis repetidos'} (mesmo nome e valor em até um dia):';
    return Advice('🔁 $t\n${lines.join('\n')}\n\nSe for repetido mesmo, diga "apaga o ${TransactionCode.label(pairs.first.$2.id)}". '
        'Se foram duas compras de verdade, pode deixar.', t, 'advice:duplicates');
  }

  /// "o que você notou nos meus gastos?", "me dá uma dica": a few things the
  /// numbers say, the most telling first.
  Advice? _insights(String s) {
    if (!RegExp(r'\bo\s+que\s+(?:voce\s+)?(?:notou|percebeu|observou|reparou|descobriu|acha\s+dos\s+meus\s+gastos)\b|'
            r'\bme\s+(?:conta|diz|fala|mostra)\s+(?:algo|alguma\s+coisa|umas?\s+coisas?)\s+(?:interessante|curios[oa]|sobre\s+(?:os\s+)?meus\s+gastos|que\s+voce\s+(?:notou|percebeu))|'
            r'\b(?:me\s+da|me\s+de|tem|manda|da)\s+(?:uma\s+|alguma\s+)?dica\b|\binsights?\b|\bcuriosidades?\b|\btem\s+algo\s+(?:estranho|diferente|fora\s+do\s+normal)\b|'
            r'\balguma\s+novidade\b|\banalis[ae]\s+(?:os\s+)?meus\s+gastos\b|\bcomo\s+(?:eu\s+)?(?:to|estou)\s+gastando\b')
        .hasMatch(s)) {
      return null;
    }
    if (repository.transactions.isEmpty) {
      const t = 'Ainda não tenho lançamentos para analisar. Me conte seus gastos (ex.: "gastei 30 no uber no pix") que eu começo a notar os padrões.';
      return const Advice('💡 $t', t, 'advice:insights');
    }
    final now = _today;
    final notes = <String>[];
    // 1. Out of the ordinary in the last 7 days.
    notes.addAll(unusualSpending().take(1).map((a) => a.text));
    // 2. A category above its usual pace.
    final m = _monthToDate();
    if (m.ref != null) {
      final up = {for (final c in m.cur.keys) c: (m.cur[c] ?? 0) - (m.ref![c] ?? 0)}.entries.where((e) => e.value >= 50).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (up.isNotEmpty) {
        notes.add('📈 **${CesarText.categoryName(up.first.key, repository.budgets)}** está ${CesarText.money(up.first.value)} acima do normal '
            'para esta altura do mês (${_behind(up.first.key)}).');
      }
    }
    // 3. What is left this month.
    final income = _monthIncome, spent = _monthExpense;
    if (income > 0) {
      final left = income - spent;
      notes.add(left >= 0
          ? '💰 Este mês sobraram ${CesarText.money(left)} até agora (${(left / income * 100).round()}% do que entrou).'
          : '⚠️ Este mês já saiu ${CesarText.money(-left)} a mais do que entrou.');
    }
    // 4. Small purchases.
    final small = _expenses.where((t) => t.date.year == now.year && t.date.month == now.month && t.amount <= 30 && !t.isRecurrent).toList();
    if (small.length >= 5) {
      final sum = small.fold(0.0, (a, t) => a + t.amount);
      notes.add('☕ Foram ${small.length} compras pequenas (até R\$ 30) este mês, somando ${CesarText.money(sum)} — '
          'no ritmo de um ano, uns ${CesarText.money(sum / now.day * 365)}.');
    }
    // 5. Delivery.
    final delivery = _expenses.where((t) => t.date.year == now.year && t.date.month == now.month && FinancialProfile.deliveryTitles.hasMatch(CesarText.fold(t.title))).toList();
    if (delivery.length >= 2) {
      notes.add('🛵 Você pediu delivery ${delivery.length} vezes este mês (${CesarText.money(delivery.fold(0.0, (a, t) => a + t.amount))}).');
    }
    // 6. The biggest purchase outside the fixed bills.
    final big = _expenses.where((t) => t.date.year == now.year && t.date.month == now.month && !t.isRecurrent).toList()..sort((a, b) => b.amount.compareTo(a.amount));
    if (big.isNotEmpty && notes.length < 4) {
      notes.add('🛍️ Sua maior compra do mês, fora as contas fixas, foi **${big.first.title}** (${CesarText.money(big.first.amount)}).');
    }
    // 7. Fixed costs.
    final fixed = _recurring();
    if (fixed.isNotEmpty && notes.length < 4) {
      final total = fixed.fold(0.0, (a, t) => a + t.amount);
      notes.add('🔁 Seus gastos fixos somam ${CesarText.money(total)} por mês (${fixed.take(3).map((t) => t.title).join(', ')}${fixed.length > 3 ? '…' : ''}).');
    }
    if (notes.isEmpty) {
      const t = 'Nada fora do comum por aqui: seus gastos estão no seu ritmo de sempre. 👏';
      return const Advice('💡 $t', t, 'advice:insights');
    }
    final shown = notes.take(4).toList();
    return Advice('💡 O que eu notei:\n${shown.map((n) => '- $n').join('\n')}', shown.first.replaceAll('**', ''), 'advice:insights');
  }

  /// The day a question asks about: "dia 25", "fim do mês", "quando cair o
  /// salário", "semana que vem", "sexta", "amanhã", "daqui a 10 dias".
  DateTime? _targetDay(String s) {
    final today = _today;
    final day = RegExp(r'\bdia\s+(\d{1,2})\b').firstMatch(s);
    if (day != null) {
      final d = int.parse(day.group(1)!);
      if (d < 1 || d > 31) return null;
      final thisMonth = DateTime(today.year, today.month, min(d, DateTime(today.year, today.month + 1, 0).day));
      return thisMonth.isBefore(today) ? DateTime(today.year, today.month + 1, d) : thisMonth;
    }
    if (RegExp(r'\b(?:fim|final)\s+do\s+mes\b').hasMatch(s)) return DateTime(today.year, today.month + 1, 0);
    if (RegExp(r'\b(?:quando|depois\s+que|assim\s+que)\s+(?:cair|entrar|chegar|receber)\s+(?:o\s+|meu\s+)?(?:salario|pagamento)\b|\bno\s+dia\s+do\s+(?:salario|pagamento)\b').hasMatch(s)) {
      return _nextSalaryDay();
    }
    if (RegExp(r'\b(?:antes\s+do|ate\s+o)\s+(?:proximo\s+)?(?:salario|pagamento)\b').hasMatch(s)) return _nextSalaryDay()?.subtract(const Duration(days: 1));
    if (RegExp(r'\b(?:semana\s+que\s+vem|proxima\s+semana)\b').hasMatch(s)) return today.add(const Duration(days: 7));
    if (RegExp(r'\b(?:mes\s+que\s+vem|proximo\s+mes)\b').hasMatch(s)) return DateTime(today.year, today.month + 1, today.day);
    if (RegExp(r'\bamanha\b').hasMatch(s)) return today.add(const Duration(days: 1));
    final later = RegExp(r'\bdaqui\s+a\s+(\d{1,3})\s+dias?\b').firstMatch(s);
    if (later != null) return today.add(Duration(days: int.parse(later.group(1)!)));
    const weekdays = {'segunda': 1, 'terca': 2, 'quarta': 3, 'quinta': 4, 'sexta': 5, 'sabado': 6, 'domingo': 7};
    for (final e in weekdays.entries) {
      if (RegExp('\\b${e.key}\\b').hasMatch(s)) {
        var ahead = (e.value - today.weekday) % 7;
        if (ahead == 0) ahead = 7;
        return today.add(Duration(days: ahead));
      }
    }
    return null;
  }

  /// The next day the salary should come in, from the last one received.
  DateTime? _nextSalaryDay() {
    final salaries = repository.transactions.where((t) => t.type == TransactionType.income && t.category == 'salary').toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (salaries.isEmpty) return null;
    final day = salaries.first.dueDay ?? salaries.first.date.day;
    final today = _today;
    final thisMonth = DateTime(today.year, today.month, day);
    return thisMonth.isAfter(today) ? thisMonth : DateTime(today.year, today.month + 1, day);
  }

  /// "quanto vou ter dia 25?", "quanto vou ter quando cair o salário?": the
  /// balance ahead — salary, bills and the usual day to day until then.
  Advice? _balanceOn(String s) {
    if (!RegExp(r'\bquanto\s+(?:eu\s+)?(?:vou|vai|irei|devo|deveria)\s+ter\b|\bquanto\s+(?:vai\s+)?(?:estar|ficar)\s+(?:o\s+)?(?:meu\s+)?saldo\b|'
            r'\b(?:meu\s+)?saldo\s+(?:vai\s+)?(?:estar|ficar|ser)\b|\bcom\s+quanto\s+(?:eu\s+)?(?:vou\s+)?(?:chegar|ficar)\b')
        .hasMatch(s)) {
      return null;
    }
    final target = _targetDay(s);
    if (target == null) return null;
    final today = _today;
    final days = target.difference(today).inDays;
    if (days < 0 || days > 120) return null;
    final when = days == 0 ? 'hoje' : (days == 1 ? 'amanhã' : 'no dia ${CesarText.ddmm(target)}');
    final profile = FinancialProfile.build(repository.transactions, now: _clock());
    final events = CashFlowForecast.knownEvents(profile, transactions: repository.transactions, openBills: repository.openBills, days: days + 1)
        .where((e) => !CesarText.dayOnly(e.day).isAfter(target))
        .toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    final balance = repository.totalBalance;
    String median, pessimistic = '';
    if (profile.hasHistory && days > 0) {
      final f = CashFlowForecast.run(profile, startBalance: balance, days: days + 1, events: events);
      median = CesarText.money(f.medianOn(target));
      pessimistic = ' (num cenário mais apertado, ${CesarText.money(f.p10On(target))})';
    } else {
      final daily = _daysOfData > 0 ? _monthExpense / max(1, _today.day) : 0.0;
      final known = events.fold(0.0, (a, e) => a + e.amount);
      median = CesarText.money(balance + known - daily * days);
    }
    final ins = events.where((e) => e.amount > 0).map((e) => '+${CesarText.money(e.amount)} ${e.label} (${CesarText.ddmm(e.day)})');
    final outs = events.where((e) => e.amount < 0).take(4).map((e) => '−${CesarText.money(-e.amount)} ${e.label} (${CesarText.ddmm(e.day)})');
    final steps = [...ins, ...outs];
    final detail = steps.isEmpty ? '' : '\n\nAté lá: ${steps.join('; ')}, além do dia a dia.';
    final t = 'Hoje seu saldo é ${CesarText.money(balance)}. ${when[0].toUpperCase()}${when.substring(1)}, a previsão é você ter uns **$median**$pessimistic.';
    return Advice('🔮 $t$detail', t.replaceAll('**', ''), 'advice:balance_on');
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
    final now = _today;
    final thisMonth = _expenses
        .where((t) => t.date.year == now.year && t.date.month == now.month && !CesarText.dayOnly(t.date).isAfter(_today) && _matches(t, term))
        .fold(0.0, (a, t) => a + t.amount);
    final spoken = 'Se cortar $term, você economiza cerca de ${CesarText.money(perMonth)} por mês, '
        '${CesarText.money(perMonth * 12)} por ano.';
    final month = thisMonth > 0 ? ' Só este mês já foram ${CesarText.money(thisMonth)}.' : '';
    return Advice('✂️ $spoken$month\n\nConta: média dos seus gastos com $term nos últimos meses. $_simNote', '$spoken$month $_simNote', 'advice:cut');
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
    // A negative balance as a bank shows it: "R$ -200,30".
    final shown = after < 0 ? 'R\$ -${CesarText.money(-after).substring(3)}' : CesarText.money(after);
    final spoken = 'Se pagar $term (${CesarText.money(amount)}), seu saldo vai de ${CesarText.money(balance)} para $shown.'
        '${after < 0 ? ' Ficaria ${CesarText.money(-after)} no vermelho.' : ''}';
    final monthNet = _monthIncome - _monthExpense - amount;
    final month = ' Contando só este mês (o que entrou menos o que saiu), ${monthNet >= 0 ? 'ainda sobrariam ${CesarText.money(monthNet)}' : 'faltariam ${CesarText.money(-monthNet)}'}.';
    return Advice('🧮 $spoken$month\n\nUsei o valor de $source. $_simNote', '$spoken $_simNote', 'hypothesis');
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
        .where((t) => t.date.year == now.year && t.date.month == now.month && !t.isRecurrent && !CesarText.dayOnly(t.date).isAfter(_today))
        .fold(0.0, (a, t) => a + t.amount);
    final daily = variable / now.day;
    final end = monthSoFar - bills - daily * daysLeft;
    final spoken = end >= 0
        ? 'No ritmo atual, a previsão é fechar o mês com cerca de ${CesarText.money(end)} sobrando.'
        : 'No ritmo atual, a previsão é fechar o mês ${CesarText.money(-end)} no vermelho.';
    final detail = 'Conta: até agora ${CesarText.money(monthSoFar)} (entradas − saídas), '
        '${bills > 0 ? '− ${CesarText.money(bills)} em contas que ainda vencem, ' : ''}'
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
    for (final t in _expenses.where((t) => _matches(t, term) && !CesarText.dayOnly(t.date).isAfter(_today))) {
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
