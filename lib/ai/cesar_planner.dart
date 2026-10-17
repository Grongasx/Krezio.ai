import '../backend/models/financial_goal.dart';
import '../backend/models/financial_reminder.dart';
import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'cesar_text.dart';
import 'local_nlp_engine.dart';
import 'pt_number_words.dart';
import 'temporal_date_parser.dart';
import 'dart:math';
import 'affordability_analyzer.dart';
import 'analytics/financial_advisors.dart';
import 'analytics/financial_profile.dart';
import 'cesar_commentary.dart';

/// A reply from the planner. [createdReminderIds]/[createdGoalId] let the
/// assistant offer "desfaz" for what was created.
class PlannerReply {
  final String text;
  final String spokenText;
  final String route;
  final List<String> createdReminderIds;
  final String? createdGoalId;
  final Map<String, double> previousBudgets;

  /// Anything else to put back on "desfaz" (a debt payment, a paid bill).
  final bool Function(FinancialRepository repository)? undo;

  const PlannerReply(this.text, this.route,
      {String? spoken, this.createdReminderIds = const [], this.createdGoalId, this.previousBudgets = const {}, this.undo})
      : spokenText = spoken ?? text;
}

sealed class _Flow {}

/// "quero comprar um carro": waiting for the price, then for the "sim".
class _GoalFlow extends _Flow {
  final String item;
  double? price;
  int? months;
  double? perMonth;
  bool awaitingConfirm = false;
  _GoalFlow(this.item);
}

/// "fiz uma dívida": waiting for the value (and who), then created.
class _DebtFlow extends _Flow {
  String? creditor;
  double? total;
  double? parcel;
  int? installments;
  int? day;
  DateTime? due;

  /// The debt was told in a question ("como eu pago?") and César offered to
  /// note it: a "sim" creates it as told.
  bool offered = false;
  _DebtFlow();
}

/// "quer que eu baixe o limite de lazer para 500?": waiting for the "sim".
class _LimitFlow extends _Flow {
  final String category;
  final String name;
  final double limit;
  _LimitFlow(this.category, this.name, this.limit);
}

/// "posso comprar um notebook?": waiting for the price.
class _PurchaseFlow extends _Flow {
  final String item;
  _PurchaseFlow(this.item);
}

/// "vamos dividir meu salário": salary → fixed expenses → proposal → "sim".
class _BudgetFlow extends _Flow {
  double? salary;
  bool salaryConfirmed = false;
  final Map<String, double> extraFixed = {};
  bool fixedAsked = false;
  Map<String, double>? proposal;
  double? savings;
  _BudgetFlow();
}

/// César as a planner: the day's/week's agenda, whom to charge, debts the
/// user must pay (with installments), how to get a bank statement, how much
/// can be invested, planning a purchase as a goal, and splitting the salary
/// into fixed costs, spending and savings. Multi-turn flows keep their state
/// here; nothing is created without the user's "sim". Pure Dart.
class CesarPlanner {
  final FinancialRepository repository;
  final DateTime Function() _clock;
  _Flow? _flow;

  CesarPlanner({required this.repository, DateTime Function()? now}) : _clock = now ?? DateTime.now;

  bool get hasFlow => _flow != null;
  void cancelFlow() => _flow = null;

  DateTime get _today => CesarText.dayOnly(_clock());

  // ───────────────────────── numbers ─────────────────────────

  /// Money said in [text]: "40 mil", "R$ 3.000", "3k", "dois mil e quinhentos".
  /// Days, counts of installments and of days/months are not money.
  static double? money(String text) {
    var t = PtNumberWords.normalize(CesarText.fold(text));
    t = t.replaceAllMapped(RegExp(r'(\d+(?:[.,]\d+)?)\s*(?:mil|k)\b'),
        (m) => '${(double.parse(m.group(1)!.replaceAll('.', '').replaceAll(',', '.')) * 1000).round()}');
    t = t
        .replaceAll(RegExp(r'\b(?:todo\s+)?dia\s+\d{1,2}\b'), ' ')
        .replaceAll(RegExp(r'\b\d{1,2}\s*x\b'), ' ')
        .replaceAll(RegExp(r'\b\d{1,3}\s*(?:vezes|parcelas|dias|meses|mes|anos|ano|semanas)\b'), ' ')
        .replaceAll(RegExp(r'\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b'), ' ');
    final m = RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)').firstMatch(t);
    if (m == null) return null;
    final v = LocalFinancialNlpEngine.cleanAndParseAmount(m.group(1));
    return v != null && v > 0 ? v : null;
  }

  static bool _yes(String s) =>
      RegExp(r'^(?:sim|s|pode|pode\s+sim|claro|bora|vamos|ok|okay|beleza|blz|isso|manda|cria|criar|aplica|aplicar|quero|confirmo|fechado|perfeito|com\s+certeza)\b').hasMatch(s);
  static bool _no(String s) => RegExp(r'^(?:nao|n|nada|deixa|esquece|cancela|para|agora\s+nao|depois)\b').hasMatch(s);

  // ───────────────────────── entry points ─────────────────────────

  /// A new request this planner answers, or null.
  /// Chat shorthand spelled out: "oq tem pra hj" → "o que tem pra hoje".
  static String expandShorthand(String s) {
    const words = {
      'oq': 'o que', 'oque': 'o que', 'hj': 'hoje', 'q': 'que', 'qnto': 'quanto', 'qnt': 'quanto', 'qto': 'quanto', 'qnta': 'quanta',
      'vc': 'voce', 'vcs': 'voces', 'tb': 'tambem', 'tbm': 'tambem', 'msm': 'mesmo', 'pq': 'porque', 'td': 'tudo', 'tds': 'todos',
      'mt': 'muito', 'mto': 'muito', 'mta': 'muita', 'dps': 'depois', 'amnh': 'amanha', 'blz': 'beleza', 'obg': 'obrigado', 'vlw': 'valeu',
      'cmg': 'comigo', 'ctg': 'contigo', 'p': 'pra', 'pf': 'por favor', 'pfv': 'por favor', 'sla': 'sei la', 'ngm': 'ninguem', 'qd': 'quando', 'qdo': 'quando',
    };
    return s.split(' ').map((w) => words[w] ?? w).join(' ');
  }

  PlannerReply? start(String text) {
    final s = expandShorthand(CesarText.simplify(text));
    if (s.isEmpty) return null;
    return _alertLimit(s) ??
        _scenario(s) ??
        _cutsAdvice(s) ??
        _saveMore(s) ??
        _howAmIDoing(s) ??
        _purchaseAsk(s, text) ??
        _howTo(s) ??
        _appHelp(s) ??
        _knowledge(s) ??
        _feelings(s) ??
        _cardBill(s) ??
        _charge(s) ??
        _paidInFull(s) ??
        _payInstallment(s) ??
        _myDebts(s) ??
        _payoff(s) ??
        _newDebt(s, text) ??
        _remindToPay(s, text) ??
        _situation(s) ??
        _profit(s) ??
        _canPay(s) ??
        _agenda(s) ??
        _weekReview(s) ??
        _monthReview(s) ??
        _noMoney(s) ??
        _canGoOut(s) ??
        _goalVariants(s) ??
        _goalStart(s, text) ??
        _saveMonthly(s) ??
        _budgetStart(s, text) ??
        _invest(s) ??
        _comment(s, text);
  }

  /// The next answer inside a flow. Null when [text] is not an answer to it
  /// (the flow is dropped and the message goes on its way).
  PlannerReply? continueFlow(String text) {
    final flow = _flow;
    if (flow == null) return null;
    final s = CesarText.simplify(text);
    // A new entry ("gastei 50 no mercado") is not an answer: the flow ends
    // and the entry goes on its way.
    if (RegExp(r'^(?:\w+\s+){0,2}(?:gastei|paguei|comprei|recebi|ganhei|transferi|torrei|abasteci|depositei|emprestei|almocei|jantei)\b').hasMatch(s)) {
      _flow = null;
      return null;
    }
    if (_no(s) && !(flow is _BudgetFlow && flow.fixedAsked && flow.proposal == null)) {
      _flow = null;
      return const PlannerReply('Tudo bem, deixei para lá. Quando quiser retomar, é só pedir. 👍', 'planner:cancel');
    }
    switch (flow) {
      case _GoalFlow():
        return _goalContinue(flow, s, text);
      case _DebtFlow():
        return _debtContinue(flow, s, text);
      case _BudgetFlow():
        return _budgetContinue(flow, s, text);
      case _PurchaseFlow():
        return _purchaseContinue(flow, s, text);
      case _LimitFlow():
        return _limitContinue(flow, s);
    }
  }

  // ───────────────────────── comments and limits ─────────────────────────

  /// "a gasolina subiu de novo", "preciso parar de pedir ifood", "amanhã vou
  /// no mercado": answered with the user's numbers, never an entry. A limit
  /// offered waits for the "sim".
  PlannerReply? _comment(String s, String text) {
    final c = CesarCommentary(repository: repository, now: _clock()).reply(s, text);
    if (c == null) return null;
    final offer = c.limitOffer;
    if (offer != null) _flow = _LimitFlow(offer.category, offer.name, offer.limit);
    return PlannerReply(c.text, c.route, spoken: c.spokenText);
  }

  PlannerReply? _limitContinue(_LimitFlow f, String s) {
    _flow = null;
    if (!_yes(s)) return null;
    return _setLimit(f.category, f.limit);
  }

  PlannerReply? _setLimit(String category, double limit) {
    final b = repository.budgets.where((b) => b.category == category).firstOrNull;
    if (b == null) return null;
    final old = b.monthlyLimit;
    repository.setBudgetLimit(category, limit);
    final now = repository.budgets.firstWhere((x) => x.category == category);
    final status = now.isOverBudget
        ? 'Você já gastou ${CesarText.money(now.currentSpent)} este mês — ${CesarText.money(now.currentSpent - limit)} acima dele.'
        : 'Você já usou ${CesarText.money(now.currentSpent)} este mês; sobram ${CesarText.money(now.remaining)}.';
    final t = 'Pronto! O limite de **${b.name}** agora é **${CesarText.money(limit)}** por mês'
        '${old > 0 && old != limit ? ' (antes: ${CesarText.money(old)})' : ''}. $status Eu te aviso quando chegar perto. 🎯';
    return PlannerReply(t, 'budget_set', spoken: t.replaceAll('**', '').replaceAll(' 🎯', ''), previousBudgets: {category: old});
  }

  /// "me avisa se eu passar de 500 no lazer": the budget limit of that
  /// category, which is what warns when it gets close.
  PlannerReply? _alertLimit(String s) {
    final m = RegExp(r'\bme\s+(?:avisa|avise|alerta|alerte|lembra|lembre)\s+(?:se|quando|caso)\s+(?:eu\s+)?'
            r'(?:passar|gastar\s+mais|ultrapassar|estourar|chegar\s+a|chegar\s+em|gastar)\s+(?:de\s+|do\s+|dos\s+)?(?:r\$\s*)?(\d[\d.,]*)\s*'
            r'(?:reais\s+|conto\s+|contos\s+)?(?:no|na|nos|nas|em|com|de|do|da)\s+(.+)$')
        .firstMatch(s);
    if (m == null) return null;
    final limit = money(m.group(1)!);
    final code = CesarText.resolveCategory(m.group(2)!, repository.budgets);
    if (limit == null || code == null) return null;
    return _setLimit(code, limit);
  }

  // ───────────────────────── data helpers ─────────────────────────

  Iterable<FinancialTransaction> get _tx => repository.transactions;

  /// Average monthly income and expenses over the last full months with data
  /// (up to 3); the current month when there is nothing before it.
  ({double income, double expense, int months}) monthlyAverages() {
    final now = _today;
    var income = 0.0, expense = 0.0, months = 0;
    for (var back = 1; back <= 3; back++) {
      final m = DateTime(now.year, now.month - back);
      final inMonth = _tx.where((t) => t.date.year == m.year && t.date.month == m.month && !t.isInternalTransfer);
      if (inMonth.isEmpty) continue;
      months++;
      for (final t in inMonth) {
        if (t.type == TransactionType.income) income += t.amount;
        if (t.type == TransactionType.expense) expense += t.amount;
      }
    }
    if (months == 0) {
      income = repository.monthIncome;
      expense = repository.monthExpense;
      return (income: income, expense: expense, months: 0);
    }
    return (income: income / months, expense: expense / months, months: months);
  }

  /// Bills (recurring + reminders) due between [from] and [to].
  List<Map<String, dynamic>> _bills(DateTime from, DateTime to) =>
      repository.getUpcomingBills(start: from, end: DateTime(to.year, to.month, to.day, 23, 59, 59));

  String _when(DateTime d) {
    final diff = CesarText.dayOnly(d).difference(_today).inDays;
    if (diff < 0) return 'atrasada há ${-diff} ${diff == -1 ? 'dia' : 'dias'}';
    if (diff == 0) return 'hoje';
    if (diff == 1) return 'amanhã';
    return 'em ${CesarText.ddmm(d)}';
  }

  /// What is still free this month: income − expenses so far − bills still
  /// due − the daily average of variable spending for the days left.
  double _freeThisMonth() {
    final now = _today;
    final last = DateTime(now.year, now.month + 1, 0);
    final bills = _bills(now, last).fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0));
    final variable = _tx
        .where((t) => t.type == TransactionType.expense && !t.isRecurrent && t.date.year == now.year && t.date.month == now.month && !t.date.isAfter(_clock()))
        .fold(0.0, (a, t) => a + t.amount);
    final daily = variable / now.day;
    return repository.monthIncome - repository.monthExpense - bills - daily * (last.day - now.day);
  }

  // ───────────────────────── agenda ─────────────────────────

  PlannerReply? _agenda(String s) {
    final asksAgenda = RegExp(r'\b(?:o\s+que|oque|que)\s+(?:eu\s+)?(?:tenho|temos|tem|preciso|precisamos|devo)\b').hasMatch(s) ||
        RegExp(r'\b(?:agenda|compromissos?|pendencias|precisa\s+ser\s+feito|tenho\s+que\s+fazer|a\s+fazer)\b').hasMatch(s) ||
        // ("tenho alguma conta pra vencer?" with no day is the bills report.)
        (RegExp(r'\b(?:tenho|tem)\s+(?:alguma\s+coisa|algo|alguma\s+conta|algum\s+boleto|conta|contas|boleto|boletos)\s+(?:pra|para|a)\s+(?:pagar|vencer|fazer)\b').hasMatch(s) &&
            RegExp(r'\b(?:hoje|amanha|semana)\b').hasMatch(s)) ||
        RegExp(r'\bresumo\s+(?:do|de)\s+(?:dia|hoje|que|semana)\b').hasMatch(s) ||
        RegExp(r'\b(?:conta|contas|boleto|boletos)\s+(?:atrasad\w*|vencid\w*)\b').hasMatch(s) ||
        // "tem boleto vencendo amanhã", "o que vence hoje" (with a day).
        (RegExp(r'\b(?:conta|contas|boleto|boletos|algo|alguma\s+coisa)\s+(?:vencendo|pra\s+vencer|a\s+vencer|que\s+vence\w*)\b|\bo\s+que\s+vence\b').hasMatch(s) &&
            RegExp(r'\b(?:hoje|amanha|semana|mes)\b').hasMatch(s)) ||
        // ("como tá minha vida financeira?" is the overview report, not the agenda.)
        RegExp(r'\bcomo\s+(?:estao|esta|tao|ta)\s+(?:as\s+coisas|tudo)\b').hasMatch(s);
    if (!asksAgenda) return null;
    // Questions with a measure of their own ("o que eu tenho de saldo") are
    // the Q&A engine's.
    if (RegExp(r'\b(?:saldo|gastei|gasto|gastos|receb\w+|ganhei)\b').hasMatch(s)) return null;
    final week = RegExp(r'\bsemana\b').hasMatch(s);
    final month = RegExp(r'\bmes\b').hasMatch(s) && !week;
    final tomorrow = RegExp(r'\bamanha\b').hasMatch(s) && !week && !month;
    final now = _today;
    final end = week
        ? now.add(const Duration(days: 7))
        : (month ? DateTime(now.year, now.month + 1, 0) : (tomorrow ? now.add(const Duration(days: 1)) : now));
    final label = week ? 'nos próximos 7 dias' : (month ? 'até o fim do mês' : (tomorrow ? 'até amanhã' : 'hoje'));

    if (RegExp(r'\b(?:atrasad\w*|vencid\w*)\b').hasMatch(s)) {
      final late = repository.openBills.where((b) => FinancialRepository.isOverdue(b, _clock())).toList();
      if (late.isEmpty) {
        const t = 'Nenhuma conta atrasada. 👏';
        return const PlannerReply('✅ $t', 'planner:agenda', spoken: t);
      }
      final sum = late.fold(0.0, (a, b) => a + (b.amount ?? 0));
      return PlannerReply('🔴 Contas atrasadas (${CesarText.money(sum)}):\n${late.map((b) => '- **${b.title}**${b.amount != null ? ' — ${CesarText.money(b.amount!)}' : ''} (${_when(b.targetDate)})').join('\n')}',
          'planner:agenda', spoken: '${late.length} contas atrasadas, ${CesarText.money(sum)}.');
    }
    final lines = <String>[];
    var total = 0.0;
    // Overdue bills first, then what is due.
    for (final b in repository.openBills.where((b) => FinancialRepository.isOverdue(b, _clock()))) {
      lines.add('- 🔴 Pagar **${b.title}**${b.amount != null && b.amount! > 0 ? ' — ${CesarText.money(b.amount!)}' : ''} (${_when(b.targetDate)})');
      total += b.amount ?? 0;
    }
    for (final b in _bills(now, end)) {
      final amount = (b['amount'] as num?)?.toDouble() ?? 0;
      lines.add('- 💳 Pagar **${b['title']}**${amount > 0 ? ' — ${CesarText.money(amount)}' : ''} (${_when(b['dueDate'] as DateTime)})');
      total += amount;
    }
    final charge = repository
        .getActiveDebtors()
        .where((d) => !CesarText.dayOnly(d.targetDate).isAfter(end))
        .toList()
      ..sort((a, b) => a.targetDate.compareTo(b.targetDate));
    for (final d in charge) {
      lines.add('- 🤝 Cobrar **${d.personName ?? d.title}**${d.amount != null ? ' — ${CesarText.money(d.amount!)}' : ''} (${_when(d.targetDate)})');
    }
    for (final b in repository.budgets.where((b) => b.monthlyLimit > 0 && b.level.index >= 1)) {
      lines.add('- ⚠️ Orçamento de **${b.name}**: ${b.statusText.toLowerCase()} (${(b.currentSpent / b.monthlyLimit * 100).round()}%)');
    }
    final greet = RegExp(r'^(?:bom\s+dia|boa\s+tarde|boa\s+noite|oi|ola|e\s+ai)\b').hasMatch(s);
    final hello = greet ? '${s.startsWith('bom dia') ? 'Bom dia' : (s.startsWith('boa tarde') ? 'Boa tarde' : (s.startsWith('boa noite') ? 'Boa noite' : 'Oi'))}! ' : '';
    final name = repository.preference(FinancialRepository.prefUserName);
    final hi = hello.isEmpty ? '' : '${hello.replaceFirst('! ', '')}${name != null ? ', $name' : ''}! ';
    if (lines.isEmpty) {
      final t = '${hi}Nada pendente $label: nenhuma conta para pagar, ninguém para cobrar e os orçamentos estão em dia. 🎉';
      return PlannerReply('🗓️ $t', 'planner:agenda', spoken: t);
    }
    final head = '$hi${week ? 'Para os próximos 7 dias' : (month ? 'Até o fim do mês' : (tomorrow ? 'Até amanhã' : 'Para hoje'))} você tem:';
    final money = total > 0 ? '\n\nTotal a pagar: **${CesarText.money(total)}** · saldo atual: ${CesarText.money(repository.totalBalance)}.' : '';
    final spoken = '$head ${lines.length} ${lines.length == 1 ? 'item' : 'itens'}${total > 0 ? ', ${CesarText.money(total)} a pagar' : ''}.';
    return PlannerReply('🗓️ $head\n${lines.join('\n')}$money', 'planner:agenda', spoken: spoken);
  }

  PlannerReply? _weekReview(String s) {
    if (!RegExp(r'\bcomo\s+(?:foi|ta|esta|anda)\s+(?:a\s+)?(?:minha\s+)?semana\b|\bbalanco\s+da\s+semana\b|\bgastos?\s+da\s+semana\b').hasMatch(s)) return null;
    final now = _clock();
    final weekAgo = _today.subtract(const Duration(days: 6));
    final prevStart = weekAgo.subtract(const Duration(days: 7));
    double sum(DateTime a, DateTime b) => _tx
        .where((t) => t.type == TransactionType.expense && !t.date.isBefore(a) && t.date.isBefore(b) && !t.date.isAfter(now))
        .fold(0.0, (x, t) => x + t.amount);
    final week = sum(weekAgo, now.add(const Duration(seconds: 1)));
    final prev = sum(prevStart, weekAgo);
    final byCat = <String, double>{};
    for (final t in _tx.where((t) => t.type == TransactionType.expense && !t.date.isBefore(weekAgo) && !t.date.isAfter(now))) {
      byCat[t.category] = (byCat[t.category] ?? 0) + t.amount;
    }
    if (week <= 0) {
      const t = 'Nos últimos 7 dias você não registrou nenhum gasto. 👏';
      return const PlannerReply('🗓️ $t', 'planner:week', spoken: t);
    }
    final top = byCat.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final cmp = prev > 0 ? ' (${((week - prev) / prev * 100).round().abs()}% ${week >= prev ? 'a mais' : 'a menos'} que nos 7 dias antes)' : '';
    final t = 'Nos últimos 7 dias você gastou ${CesarText.money(week)}$cmp, mais em ${CesarText.categoryName(top.key, repository.budgets)} (${CesarText.money(top.value)}).';
    return PlannerReply('🗓️ $t', 'planner:week', spoken: t);
  }

  PlannerReply? _monthReview(String s) {
    if (!RegExp(r'\bcomo\s+(?:foi|ta|esta|anda)\s+(?:o\s+)?(?:meu\s+)?mes\b|\bpanorama\s+(?:do|deste|desse)\s+mes\b|\bbalanco\s+do\s+mes\b|\bresumo\s+do\s+mes\b').hasMatch(s)) {
      return null;
    }
    final income = repository.monthIncome, expense = repository.monthExpense;
    final byCat = repository.categoryExpensesThisMonth.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final top = byCat.take(3).map((e) => '${CesarText.categoryName(e.key, repository.budgets)} (${CesarText.money(e.value)})').join(', ');
    final over = repository.budgets.where((b) => b.isOverBudget).map((b) => b.name).toList();
    final change = repository.monthOverMonthExpenseChange;
    final lines = [
      '- Entraram **${CesarText.money(income)}** e saíram **${CesarText.money(expense)}** (sobra ${CesarText.money(income - expense)}).',
      if (top.isNotEmpty) '- Onde mais foi: $top.',
      if (change != null) '- ${change <= 0 ? 'Você gastou ${(-change * 100).round()}% a menos' : 'Você gastou ${(change * 100).round()}% a mais'} que no mês passado, no mesmo período.',
      if (over.isNotEmpty) '- Orçamento estourado: ${over.join(', ')}.',
    ];
    final spoken = 'Este mês entraram ${CesarText.money(income)} e saíram ${CesarText.money(expense)}.';
    return PlannerReply('📊 Seu mês até agora:\n${lines.join('\n')}', 'planner:month', spoken: spoken);
  }

  // ───────────────────────── charge / debts ─────────────────────────

  PlannerReply? _charge(String s) {
    if (!RegExp(r'\bquem\s+(?:eu\s+)?(?:preciso|tenho\s+que|devo|vou|posso)\s+cobrar\b|\b(?:alguem|quem)\s+(?:esta|ta)\s+(?:atrasad\w*|me\s+devendo\s+atrasad\w*)|\btem\s+alguem\s+atrasad\w*|\bcobrancas?\s+(?:do|deste|desse)\s+mes\b')
        .hasMatch(s)) {
      return null;
    }
    final now = _today;
    final monthOnly = RegExp(r'\bmes\b').hasMatch(s);
    final lateOnly = RegExp(r'\batrasad').hasMatch(s);
    final end = DateTime(now.year, now.month + 1, 0);
    final list = repository.getActiveDebtors().where((d) {
      if (lateOnly) return CesarText.dayOnly(d.targetDate).isBefore(now);
      if (monthOnly) return !CesarText.dayOnly(d.targetDate).isAfter(end);
      return true;
    }).toList()
      ..sort((a, b) => a.targetDate.compareTo(b.targetDate));
    if (list.isEmpty) {
      final all = repository.getActiveDebtors();
      final t = lateOnly
          ? 'Ninguém está atrasado com você. 👍'
          : monthOnly && all.isNotEmpty
              ? 'Ninguém precisa ser cobrado este mês. ${all.length == 1 ? 'Há 1 valor' : 'Há ${all.length} valores'} para depois: ${all.map((d) => '${d.personName ?? d.title} (${CesarText.ddmm(d.targetDate)})').join(', ')}.'
              : 'Ninguém te deve nada no momento. 👍';
      return PlannerReply('🤝 $t', 'planner:charge', spoken: t);
    }
    final total = list.fold(0.0, (a, d) => a + (d.amount ?? 0));
    final lines = list.map((d) => '- **${d.personName ?? d.title}** — ${d.amount != null ? CesarText.money(d.amount!) : 'valor não informado'} (${_when(d.targetDate)})').join('\n');
    final head = lateOnly ? 'Estão atrasados com você' : (monthOnly ? 'Para cobrar este mês' : 'Para cobrar');
    final spoken = '$head: ${list.length} ${list.length == 1 ? 'pessoa' : 'pessoas'}, ${CesarText.money(total)} no total.';
    return PlannerReply('🤝 $head (${CesarText.money(total)}):\n$lines\n\nQuando alguém pagar, diga "o João me pagou 50".', 'planner:charge', spoken: spoken);
  }

  /// Bills the user owes to someone (created by [_newDebt]) and other open bills.
  PlannerReply? _myDebts(String s) {
    if (!RegExp(r'^(?:e\s+)?(?:eu\s+)?(?:tenho|to\s+com|estou\s+com)\s+(?:alguma\s+)?dividas?\b|^(?:e\s+)?(?:quanto|qto)\s+(?:eu\s+)?(?:ainda\s+)?(?:devo|(?:to|tou|estou)\s+devendo)\b|\b(?:pra|para|a)\s+quem\s+(?:eu\s+)?devo\b|\bminhas\s+dividas\b|\bquais\s+(?:sao\s+)?(?:as\s+)?minhas\s+dividas\b|\bquanto\s+falta\s+(?:pra|para)\s+(?:quitar|pagar)\b')
        .hasMatch(s)) {
      return null;
    }
    final bills = repository.openBills;
    if (bills.isEmpty) {
      const t = 'Você não tem dívidas nem contas em aberto registradas. 👏';
      return const PlannerReply('✅ $t', 'planner:my_debts', spoken: t);
    }
    final byWho = <String, List<FinancialReminder>>{};
    for (final b in bills) {
      byWho.putIfAbsent(b.personName ?? b.title.replaceFirst(RegExp(r'^Parcela \d+/\d+ — '), ''), () => []).add(b);
    }
    final total = bills.fold(0.0, (a, b) => a + (b.amount ?? 0));
    final lines = byWho.entries.map((e) {
      final sum = e.value.fold(0.0, (a, b) => a + (b.amount ?? 0));
      final next = e.value.first;
      return '- **${e.key}** — ${CesarText.money(sum)}${e.value.length > 1 ? ' em ${e.value.length} parcelas' : ''} (próxima ${_when(next.targetDate)})';
    }).join('\n');
    final spoken = 'Você deve ${CesarText.money(total)} no total.';
    return PlannerReply('📌 Você deve **${CesarText.money(total)}**:\n$lines\n\nQuando pagar, marque em Ajustes → Contas e devedores ou me diga "paguei a parcela".',
        'planner:my_debts',
        spoken: spoken);
  }

  static final _debtStart = RegExp(
      r'\b(?:fiz|peguei|tomei|contrai|fechei|assumi)\s+(?:uma?\s+)?(?:divida|emprestimo|financiamento|consignado)\b|'
      r'\bacabei\s+de\s+(?:fazer|pegar)\s+(?:uma?\s+)?(?:divida|emprestimo)|'
      r'\bpeguei\s+(?:r\s*)?\d[\d.,]*\s*(?:mil|reais|conto|contos)?\s+emprestad[oa]|'
      r'\b(?:peguei|pedi)\s+emprestad[oa]\b|'
      r'\bpeguei\s+(?:r\s*)?\d[\d.,]*\s*(?:mil|reais|conto|contos)?\s+(?:com|do|da)\s+(?:o\s+|a\s+|meu\s+|minha\s+)?[a-z]+.*\b(?:devolv\w*|pag\w*|acert\w*)|'
      r'\b(?:to|estou|fiquei)\s+devendo\b|'
      r'^(?:eu\s+)?devo\s+(?:r\s*)?\d|'
      r'\bpreciso\s+pagar\s+(?:uma?\s+)?(?:divida|emprestimo)');

  PlannerReply? _newDebt(String s, String text) {
    if (!_debtStart.hasMatch(s)) return null;
    final flow = _DebtFlow();
    _fillDebt(flow, s, text);
    _flow = flow;
    return _debtNext(flow);
  }

  void _fillDebt(_DebtFlow f, String s, String text) {
    final parcel = RegExp(r'\b(\d{1,2})\s*(?:x|vezes|parcelas)\s+de\s+(?:r\s*)?(\d[\d.,]*(?:\s*mil)?)').firstMatch(s);
    final count = RegExp(r'\b(?:em\s+)?(\d{1,2})\s*(?:x|vezes|parcelas)\b').firstMatch(s);
    if (count != null) f.installments = int.parse(count.group(1)!);
    if (parcel != null) {
      f.installments = int.parse(parcel.group(1)!);
      f.parcel = money(parcel.group(2)!);
      final rest = s.replaceFirst(parcel.group(0)!, ' ');
      final total = money(rest);
      if (total != null) f.total = total;
    } else {
      final v = money(s);
      if (v != null) {
        if (RegExp(r'\b(?:parcela|cada\s+parcela|por\s+mes|mensal)\b').hasMatch(s) && f.installments != null) {
          f.parcel = v;
        } else {
          f.total = v;
        }
      }
    }
    final day = RegExp(r'\btodo\s+dia\s+(\d{1,2})\b').firstMatch(s) ?? (f.installments != null ? RegExp(r'\bdia\s+(\d{1,2})\b').allMatches(s).lastOrNull : null);
    if (day != null) f.day = int.parse(day.group(1)!).clamp(1, 31);
    final inDays = RegExp(r'\b(?:dentro\s+de|em|daqui\s+a|no\s+prazo\s+de)\s+(\d{1,3})\s+dias?\b').firstMatch(s);
    if (inDays != null) f.due = _today.add(Duration(days: int.parse(inDays.group(1)!)));
    final inMonths = RegExp(r'\b(?:dentro\s+de|em|daqui\s+a|no\s+prazo\s+de)\s+(\d{1,2})\s+mes(?:es)?\b').firstMatch(s);
    if (inMonths != null && f.installments == null) {
      f.due = DateTime(_today.year, _today.month + int.parse(inMonths.group(1)!), _today.day);
    }
    final weekday = RegExp(r'\b(?:ate|na|no|pagar|pago|pagarei|vence|devolvo|devolver)\s+(?:a\s+|o\s+|na\s+|no\s+|essa\s+|esta\s+|proxima\s+)?(segunda|terca|quarta|quinta|sexta|sabado|domingo)\b')
        .firstMatch(s);
    if (weekday != null && f.due == null) {
      const days = ['segunda', 'terca', 'quarta', 'quinta', 'sexta', 'sabado', 'domingo'];
      final target = days.indexOf(weekday.group(1)!) + 1;
      var ahead = (target - _today.weekday) % 7;
      if (ahead == 0) ahead = 7;
      f.due = _today.add(Duration(days: ahead));
    }
    if (f.due == null && f.installments == null) {
      final spoken = SpokenDayParser.parse(s, now: _clock(), allowFuture: true);
      final day = spoken?.day;
      if (day != null && day.start.isAfter(_today)) f.due = CesarText.dayOnly(day.start);
    }
    final who = RegExp(r'\b(?:com|pro|pra|para|do|da|ao|na|no)(?:\s+(?:o|a|meu|minha|seu|sua))?(?:\s+(?:meu|minha))?\s+((?:irmao|irma|mae|pai|tio|tia|primo|prima|amigo|amiga|chefe|banco|vo|vizinho|vizinha|sogro|sogra|cunhado|cunhada|[a-z]{3,}))\b')
        .allMatches(s)
        .map((m) => m.group(1)!)
        .where((w) => !const {
              'divida', 'emprestimo', 'pagar', 'dias', 'parcelas', 'vezes', 'mes', 'cartao', 'pix', 'boleto', 'agora', 'hoje', 'semana', 'reais', 'mil',
              'ela', 'ele', 'isso', 'prazo', 'ultima', 'proxima', 'dentro', 'quinze', 'cada', 'todo', 'final', 'fim', 'sexta', 'segunda', 'terca', 'quarta',
              'quinta', 'sabado', 'domingo', 'amanha', 'depois'
            }.contains(w))
        .firstOrNull;
    if (who != null) {
      final typed = text.split(RegExp(r'[^\p{L}]+', unicode: true)).firstWhere((w) => CesarText.fold(w) == who, orElse: () => who);
      f.creditor ??= typed[0].toUpperCase() + typed.substring(1);
    }
    if (RegExp(r'\b(?:banco|nubank|itau|bradesco|caixa|santander|inter|financeira|consignado)\b').hasMatch(s)) {
      f.creditor ??= RegExp(r'\b(nubank|itau|bradesco|caixa|santander|inter)\b').firstMatch(s)?.group(1)?.toUpperCase() ?? 'Banco';
    }
  }

  PlannerReply _debtNext(_DebtFlow f) {
    if (f.total == null && f.parcel == null) {
      final who = f.creditor == null ? ' e com quem' : '';
      final parc = f.installments != null ? ' (o total ou o de cada uma das ${f.installments} parcelas)' : '';
      return PlannerReply('📌 Vou anotar essa dívida para te lembrar de pagar. De quanto ela é$parc$who? Ex.: "3000 com o banco" ou "parcela de 300".',
          'planner:debt_ask');
    }
    return _createDebt(f);
  }

  PlannerReply? _debtContinue(_DebtFlow f, String s, String text) {
    if (f.offered && _yes(s) && money(s) == null) return _createDebt(f);
    if (money(s) == null) {
      _flow = null;
      return null;
    }
    _fillDebt(f, s, text);
    return _debtNext(f);
  }

  PlannerReply _createDebt(_DebtFlow f) {
    _flow = null;
    final now = _today;
    final who = f.creditor;
    final label = who == null ? 'Dívida' : 'Dívida com $who';
    final ids = <String>[];
    final seq = _clock().microsecondsSinceEpoch;
    if ((f.installments ?? 1) > 1) {
      final n = f.installments!;
      final parcel = f.parcel ?? (f.total! / n);
      final day = f.day ?? now.day;
      // First due date: this month's day if it hasn't passed, else next month's.
      var first = DateTime(now.year, now.month, day.clamp(1, DateTime(now.year, now.month + 1, 0).day));
      if (first.isBefore(now)) first = DateTime(now.year, now.month + 1, day.clamp(1, DateTime(now.year, now.month + 2, 0).day));
      for (var i = 0; i < n; i++) {
        final last = DateTime(first.year, first.month + i + 1, 0).day;
        final date = DateTime(first.year, first.month + i, day.clamp(1, last));
        final id = 'debt-$seq-$i';
        repository.addReminder(FinancialReminder(
            id: id, title: 'Parcela ${i + 1}/$n — $label', personName: who, amount: (parcel * 100).round() / 100, targetDate: date, type: ReminderType.billPayment));
        ids.add(id);
      }
      final total = parcel * n;
      final t = 'Anotei: **$label**, ${n}x de ${CesarText.money(parcel)} (total ${CesarText.money(total)}), todo dia $day — '
          'a primeira em ${CesarText.ddmm(first)}. Vou te lembrar de cada parcela.';
      return PlannerReply('📌 $t\n\nSe errei, diga "desfaz".', 'planner:debt_created', spoken: t.replaceAll('**', ''), createdReminderIds: ids);
    }
    final due = f.due ?? (f.day != null ? _nextDay(f.day!) : now.add(const Duration(days: 30)));
    final id = 'debt-$seq';
    repository.addReminder(FinancialReminder(id: id, title: label, personName: who, amount: f.total, targetDate: due, type: ReminderType.billPayment));
    ids.add(id);
    final saidDue = f.due != null || f.day != null;
    // "até 16/11" alone — "(em 16/11)" after it said the date twice.
    final close = CesarText.dayOnly(due).difference(_today).inDays <= 1 ? ' (${_when(due)})' : '';
    final t = 'Anotei: **$label** de ${CesarText.money(f.total!)}, para pagar até ${CesarText.ddmm(due)}$close.'
        '${saidDue ? '' : ' Não ouvi o prazo, então coloquei 30 dias — diga "vence dia 10" para mudar.'}';
    return PlannerReply('📌 $t Vou te lembrar antes do vencimento.\n\nSe errei, diga "desfaz".', 'planner:debt_created',
        spoken: t.replaceAll('**', ''), createdReminderIds: ids);
  }

  DateTime _nextDay(int day) {
    final now = _today;
    final thisMonth = DateTime(now.year, now.month, day.clamp(1, DateTime(now.year, now.month + 1, 0).day));
    return thisMonth.isBefore(now) ? DateTime(now.year, now.month + 1, day.clamp(1, DateTime(now.year, now.month + 2, 0).day)) : thisMonth;
  }

  /// "me lembra de pagar o aluguel dia 5" (no value said: the last one).
  PlannerReply? _remindToPay(String s, String text) {
    final m = RegExp(r'\b(?:me\s+)?(?:lembra|lembre|avisa|avise)\s+(?:me\s+)?(?:de|pra|para)\s+pagar\s+(?:o|a|os|as)?\s*([a-z ]+?)\s+(?:no\s+)?dia\s+(\d{1,2})\b').firstMatch(s) ??
        RegExp(r'\b(?:me\s+)?(?:lembra|lembre|avisa|avise)\s+(?:me\s+)?(?:de|pra|para)\s+pagar\s+(?:o|a|os|as)?\s*([a-z ]+?)\s+(?:em|daqui\s+a)\s+(\d{1,3})\s+dias\b').firstMatch(s);
    if (m == null) return null;
    final what = m.group(1)!.trim();
    if (what.isEmpty) return null;
    final inDays = m.group(0)!.contains('dias');
    final due = inDays ? _today.add(Duration(days: int.parse(m.group(2)!))) : _nextDay(int.parse(m.group(2)!));
    var amount = money(s.replaceFirst(m.group(0)!, ' '));
    if (amount == null) {
      final past = _tx.where((t) => t.type == TransactionType.expense && CesarText.fold(t.title).contains(what)).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      if (past.isNotEmpty) amount = past.first.amount;
    }
    final title = what[0].toUpperCase() + what.substring(1);
    final id = 'remind-${_clock().microsecondsSinceEpoch}';
    repository.addReminder(FinancialReminder(id: id, title: title, amount: amount, targetDate: due, type: ReminderType.billPayment));
    final t = 'Combinado! Vou te lembrar de pagar **$title**${amount != null ? ' (${CesarText.money(amount)})' : ''} em ${CesarText.ddmm(due)}.';
    return PlannerReply('⏰ $t', 'planner:reminder', spoken: t.replaceAll('**', ''), createdReminderIds: [id]);
  }

  // ───────────────────────── help ─────────────────────────

  PlannerReply? _howTo(String s) {
    if (RegExp(r'\b(?:como|onde)\s+(?:eu\s+)?(?:faco|consigo|posso|pego|tiro|baixo|exporto|importo|coloco|trago|puxo|vejo)?\s*(?:pra|para|de)?\s*(?:pegar|tirar|baixar|exportar|importar|colocar|trazer|puxar)?\s*(?:o\s+|meu\s+)?extrato\b')
            .hasMatch(s) ||
        RegExp(r'\bimportar\s+(?:o\s+|meu\s+)?extrato\b').hasMatch(s)) {
      const t = 'Para trazer o extrato do banco para o Krezio:\n'
          '1. No app ou site do seu banco, abra o **extrato** e procure **Exportar**, **Compartilhar** ou **Baixar**.\n'
          '2. Escolha o formato **OFX** (o melhor) ou **CSV/Excel**. Muitos bancos chamam de "arquivo para Money/Quicken" o OFX. '
          'Na fatura do cartão a opção costuma ser "exportar fatura" (CSV).\n'
          '3. Salve o arquivo no celular ou no computador.\n'
          '4. Aqui no app: **Ajustes → Ferramentas → Importar extrato do banco** e escolha o arquivo.\n\n'
          'Eu mostro tudo antes de importar e ignoro o que já estiver registrado, então pode importar sem medo de duplicar.';
      return const PlannerReply('🏦 $t', 'help', spoken: 'No app do banco, exporte o extrato em OFX ou CSV. Depois, aqui em Ajustes, Ferramentas, Importar extrato.');
    }
    if (RegExp(r'\b(?:como|onde)\s+(?:eu\s+)?(?:cadastro|adiciono|coloco|crio|registro|ponho)\s+(?:um\s+|o\s+|meu\s+|uma\s+|a\s+|minha\s+)?(?:cartao|conta|carteira|banco)\b').hasMatch(s)) {
      const t = 'Em **Ajustes → Contas e carteiras → Nova conta**. Para cartão de crédito, escolha "Cartão de crédito" e informe o dia de fechamento e de vencimento: '
          'eu passo a calcular a fatura de cada mês (com as parcelas). Depois, ao lançar uma compra, escolha a conta no formulário.';
      return const PlannerReply('💳 $t', 'help', spoken: 'Em Ajustes, Contas e carteiras, Nova conta.');
    }
    return null;
  }

  // ───────────────────────── money left ─────────────────────────

  PlannerReply? _noMoney(String s) {
    if (!RegExp(r'\b(?:to|tou|estou|fiquei|ando|tamo|estamos)\s+(?:sem\s+(?:dinheiro|grana|um\s+tostao)|quebrad[oa]|liso|lisa|duro|dura|apertad[oa])\b|\bo\s+dinheiro\s+(?:acabou|nao\s+da)\b').hasMatch(s)) {
      return null;
    }
    final balance = repository.totalBalance;
    final now = _today;
    final soon = _bills(now, now.add(const Duration(days: 7)));
    final soonTotal = soon.fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0));
    final toReceive = repository.getActiveDebtors().fold(0.0, (a, d) => a + (d.amount ?? 0));
    final top = repository.categoryExpensesThisMonth.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final tips = <String>[
      '- Seu saldo hoje é **${CesarText.money(balance)}**${soonTotal > 0 ? ', e vencem ${CesarText.money(soonTotal)} nos próximos 7 dias' : ''}.',
      if (soon.isNotEmpty) '- Priorize as contas essenciais (moradia, luz, água) e veja se dá para negociar a data das outras.',
      if (toReceive > 0) '- Você tem **${CesarText.money(toReceive)}** a receber: vale cobrar agora (pergunte "quem eu preciso cobrar?").',
      if (top.isNotEmpty) '- Onde mais saiu dinheiro este mês: ${CesarText.categoryName(top.first.key, repository.budgets)} (${CesarText.money(top.first.value)}). Segurar isso por alguns dias ajuda.',
      '- Evite parcelar no cartão para cobrir o mês: os juros do rotativo são altos.',
    ];
    const head = 'Calma, vamos olhar juntos:';
    return PlannerReply('🫂 $head\n${tips.join('\n')}\n\nSe quiser, pergunte "quanto posso gastar por dia?" que eu faço a conta até o fim do mês.', 'planner:no_money',
        spoken: '$head seu saldo é ${CesarText.money(balance)}.');
  }

  PlannerReply? _canGoOut(String s) {
    final m = RegExp(r'\b(?:posso|da\s+pra|consigo)\s+(?:sair|ir)\s+(?:pra|para|no|na|ao)?\s*(?:um\s+|uma\s+)?(jantar|almocar|almoco|lanchar|pizza|bar|cinema|balada|show|restaurante|happy\s+hour|rolê|role)\b').firstMatch(s);
    if (m == null || RegExp(r'\d').hasMatch(s)) return null;
    final free = _freeThisMonth();
    final now = _today;
    final daysLeft = DateTime(now.year, now.month + 1, 0).day - now.day + 1;
    final perDay = free / daysLeft;
    final leisure = _tx.where((t) => t.type == TransactionType.expense && t.category == 'leisure').toList();
    final ticket = leisure.isEmpty ? null : leisure.fold(0.0, (a, t) => a + t.amount) / leisure.length;
    final String t;
    if (free <= 0) {
      t = 'Este mês já não sobra margem (as contas e o ritmo de gastos levam tudo). Se for, escolha algo barato ou deixe para depois do próximo salário.';
    } else if (ticket == null || ticket <= perDay * 2) {
      t = 'Pode sim! Dá para gastar uns ${CesarText.money(perDay)} por dia até o fim do mês${ticket != null ? ', e sua saída costuma custar ${CesarText.money(ticket)}' : ''}. Aproveite! 🍽️';
    } else {
      t = 'Dá, mas com cuidado: sua saída costuma custar ${CesarText.money(ticket)}, e o ideal até o fim do mês é ${CesarText.money(perDay)} por dia. '
          'Se for, compense nos próximos dias.';
    }
    return PlannerReply('🤔 $t', 'planner:can_go_out', spoken: t);
  }

  PlannerReply? _invest(String s) {
    final howMuch = RegExp(r'\bquanto\s+(?:eu\s+)?(?:posso|consigo|da\s+pra|da\s+para|devo|deveria|sobra\s+pra|sobra\s+para)\s+(?:investir|guardar|poupar|economizar|separar|aplicar|juntar)\b').hasMatch(s);
    final where = RegExp(r'\b(?:onde|em\s+que|no\s+que|qual\s+(?:o\s+)?(?:melhor\s+)?investimento)\b.*\b(?:invist\w*|investir|aplicar|aplico)\b|\bvale\s+a\s+pena\s+investir\b|\bdevo\s+investir\b').hasMatch(s);
    if (!howMuch && !where) return null;
    final avg = monthlyAverages();
    final free = _freeThisMonth();
    final reserveTarget = avg.expense * 6;
    final buf = StringBuffer();
    // With history: the simulated end of the month, pessimistic case (p10).
    final ctx = _ctx;
    if (ctx.profile.hasHistory) {
      // Until a few days after the next salary: the lowest balance of the
      // pessimistic path (p10) minus the safety floor can go to investments.
      final salaryDay = ctx.profile.recurringIncomes.isEmpty ? null : ctx.profile.recurringIncomes.first.day;
      var next = salaryDay == null ? _today.add(const Duration(days: 30)) : DateTime(_today.year, _today.month, salaryDay);
      if (!next.isAfter(_today)) next = DateTime(_today.year, _today.month + 1, salaryDay ?? _today.day);
      final days = next.difference(_today).inDays + 5;
      final f = ctx.forecast(days: days);
      final lowP10 = f.p10.reduce(min);
      final investable = ((lowP10 - ctx.floor) * 0.9 / 10).floor() * 10.0;
      if (investable > 0) {
        buf.writeln('Simulei 400 cenários até o próximo salário (${CesarText.ddmm(next)}) com o seu histórico: com **90% de chance**, '
            'dá para investir **${CesarText.money(investable)}** hoje sem que o saldo fique abaixo da sua reserva mínima de ${CesarText.money(ctx.floor)}.');
        if (ctx.profile.avgNet > 0) {
          buf.writeln('E todo mês sobram, em média, ${CesarText.money(ctx.profile.avgNet)} — dá para investir uns ${CesarText.money((ctx.profile.avgNet * 0.8 / 10).floor() * 10.0)} por mês.');
        }
        buf.writeln();
        buf.writeln(_investTail(avg, reserveTarget, where));
        return PlannerReply('💰 ${buf.toString().trim()}', 'planner:invest',
            spoken: 'Com 90% de chance, dá para investir ${CesarText.money(investable)} hoje, mantendo sua reserva mínima.');
      }
    }
    if (free > 0) {
      final invest = (free * 0.8 / 10).floor() * 10.0;
      buf.writeln('Pelas contas deste mês, devem sobrar uns **${CesarText.money(free)}** (entradas − saídas − contas que ainda vencem − seu ritmo de gastos).');
      buf.writeln('Dá para separar cerca de **${CesarText.money(invest)}** e deixar ${CesarText.money(free - invest)} de folga para imprevistos.');
    } else {
      buf.writeln('Este mês não sobra margem para investir: as saídas e as contas já levam o que entrou. '
          'Pergunte "onde posso economizar?" que eu mostro onde cortar.');
    }
    buf.writeln();
    buf.writeln(_investTail(avg, reserveTarget, where));
    final spoken = free > 0 ? 'Este mês devem sobrar uns ${CesarText.money(free)}.' : 'Este mês não sobra margem para investir.';
    return PlannerReply('💰 ${buf.toString().trim()}', 'planner:invest', spoken: spoken);
  }

  /// Emergency fund first; where to invest is general information only.
  String _investTail(({double income, double expense, int months}) avg, double reserveTarget, bool where) {
    final reserveGoal = repository.goals.where((g) => CesarText.fold(g.title).contains('reserva')).firstOrNull;
    final buf = StringBuffer();
    if (reserveGoal == null || !reserveGoal.isReached) {
      buf.writeln('💡 Antes de investir em coisas que oscilam, o comum é montar uma **reserva de emergência** de 3 a 6 meses de gastos '
          '(para você, ${CesarText.money(avg.expense * 3)} a ${CesarText.money(reserveTarget)}), num lugar seguro e com resgate rápido.'
          '${reserveGoal == null ? ' Quer que eu crie essa meta? Diga "quero juntar ${reserveTarget.round()} pra reserva de emergência".' : ''}');
    }
    if (where) {
      buf.writeln();
      buf.writeln('Sobre onde investir: não posso recomendar produtos específicos (não sou consultor de investimentos). '
          'Compare rentabilidade, risco, liquidez e taxas, e para decisões maiores procure um profissional certificado.');
    }
    return buf.toString().trim();
  }

  // ───────────────────────── goals for a purchase ─────────────────────────

  static final _goalWords = RegExp(
      r'\b(?:quero|queria|pretendo|preciso|to\s+querendo|estou\s+querendo|tô\s+querendo|vou|sonho\s+em)\s+(?:comprar|trocar\s+(?:de|o|a|meu|minha)|ter|fazer)\s+(?:(?:um|uma|o|a|meu|minha|de)\s+)?([a-z]{3,}(?:\s+(?:novo|nova|zero|usado|usada|proprio|propria))?)|'
      r'\b(?:me\s+)?ajud\w*\s+a\s+(?:economizar|juntar|guardar|planejar)\s+(?:pra|para)\s+(?:comprar\s+)?(?:(?:um|uma|o|a|meu|minha)\s+)?([a-z]{3,})|'
      // "quero juntar grana pra comprar uma casa"
      r'\b(?:quero|preciso|vou|pretendo)\s+(?:juntar|guardar|economizar|poupar)\s+(?:(?:grana|dinheiro)\s+)?(?:pra|para)\s+(?:comprar\s+|trocar\s+de\s+|ter\s+)?(?:(?:um|uma|o|a|meu|minha)\s+)?([a-z]{3,})');

  PlannerReply? _goalStart(String s, String text) {
    final m = _goalWords.firstMatch(s);
    if (m == null) return null;
    final item = (m.group(1) ?? m.group(2) ?? m.group(3))?.trim();
    if (item == null || item.length < 3 || const {'dinheiro', 'isso', 'algo', 'coisa', 'gasto', 'pix', 'compra', 'reserva', 'uma', 'meu', 'minha', 'divida', 'dividas'}.contains(item)) return null;
    // A purchase being told ("quero registrar que comprei…") is not a plan:
    // only with a planning word or no past purchase verb.
    if (RegExp(r'\b(?:comprei|paguei|gastei)\b').hasMatch(s)) return null;
    final title = item[0].toUpperCase() + item.substring(1);
    final flow = _GoalFlow(title)..price = money(s);
    final within = RegExp(r'\b(?:em|ate|dentro\s+de)\s+(\d{1,2})\s+(meses|mes|anos|ano)\b').firstMatch(s);
    if (within != null) flow.months = int.parse(within.group(1)!) * (within.group(2)!.startsWith('ano') ? 12 : 1);
    _flow = flow;
    if (flow.price == null) {
      return PlannerReply('🎯 Bora planejar o **$title**! Quanto ele custa, mais ou menos? (ex.: "40 mil")', 'planner:goal_ask', spoken: 'Quanto custa, mais ou menos?');
    }
    return _goalPlan(flow);
  }

  PlannerReply? _goalContinue(_GoalFlow f, String s, String text) {
    if (f.awaitingConfirm) {
      if (_yes(s)) return _goalCreate(f);
      final v = money(s);
      if (v != null) {
        // "e se eu guardar 1000 por mês?" / a new price
        if (RegExp(r'\bpor\s+mes|mensal|ao\s+mes\b').hasMatch(s)) {
          f.perMonth = v;
          f.months = (f.price! / v).ceil();
        } else {
          f.price = v;
          f.perMonth = null;
        }
        return _goalPlan(f);
      }
      final within = RegExp(r'\b(?:em|ate|dentro\s+de)\s+(\d{1,2})\s+(meses|mes|anos|ano)\b').firstMatch(s);
      if (within != null) {
        f.months = int.parse(within.group(1)!) * (within.group(2)!.startsWith('ano') ? 12 : 1);
        f.perMonth = null;
        return _goalPlan(f);
      }
      _flow = null;
      return null;
    }
    final v = money(s);
    if (v == null) {
      _flow = null;
      return null;
    }
    f.price = v;
    return _goalPlan(f);
  }

  PlannerReply _goalPlan(_GoalFlow f) {
    final avg = monthlyAverages();
    final surplus = avg.income - avg.expense;
    final price = f.price!;
    final buf = StringBuffer('🎯 **${f.item}** de ${CesarText.money(price)}:\n');
    if (f.months != null && f.perMonth == null) f.perMonth = price / f.months!;
    if (f.perMonth == null) {
      if (surplus <= 0) {
        buf.writeln('- Hoje suas saídas (${CesarText.money(avg.expense)}/mês) estão iguais ou acima das entradas (${CesarText.money(avg.income)}/mês), então ainda não sobra para guardar.');
        buf.writeln('- O primeiro passo é abrir espaço: pergunte "onde posso economizar?".');
        buf.writeln('\nSe quiser, me diga quanto consegue guardar por mês (ex.: "500 por mês") que eu calculo o prazo.');
        f.awaitingConfirm = true;
        return PlannerReply(buf.toString().trim(), 'planner:goal_plan', spoken: 'Hoje ainda não sobra para guardar. Me diga quanto consegue por mês.');
      }
      // The fastest realistic pace: 70% of what usually is left each month.
      f.perMonth = (surplus * 0.7 / 10).floor() * 10.0;
      f.months = (price / f.perMonth!).ceil();
      buf.writeln('- Pela sua média, sobram uns ${CesarText.money(surplus)} por mês. Guardando **${CesarText.money(f.perMonth!)}** (70% disso, para manter uma folga), '
          'você chega lá em **${f.months} ${f.months == 1 ? 'mês' : 'meses'}**.');
    } else {
      f.months = (price / f.perMonth!).ceil();
      final ok = f.perMonth! <= surplus;
      buf.writeln('- Guardando **${CesarText.money(f.perMonth!)}** por mês, você chega lá em **${f.months} ${f.months == 1 ? 'mês' : 'meses'}**.');
      if (!ok) {
        buf.writeln('- Atenção: isso passa do que costuma sobrar (${CesarText.money(surplus > 0 ? surplus : 0)}/mês). Vai precisar cortar gastos — pergunte "onde posso economizar?".');
      }
    }
    final now = _today;
    final when = DateTime(now.year, now.month + f.months!);
    const names = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
    buf.writeln('- Previsão: **${names[when.month - 1]} de ${when.year}**.');
    buf.writeln('- Para acelerar: corte uma categoria que cresceu ("onde posso economizar?") ou use dinheiro extra (13º, freela) como aporte.');
    buf.writeln('\nCrio a meta **${f.item}** de ${CesarText.money(price)} com ${CesarText.money(f.perMonth!)} por mês? (sim/não) '
        'Você também pode mudar: "em 2 anos" ou "1000 por mês".');
    f.awaitingConfirm = true;
    return PlannerReply(buf.toString().trim(), 'planner:goal_plan',
        spoken: 'Guardando ${CesarText.money(f.perMonth!)} por mês, você chega lá em ${f.months} meses. Crio a meta?');
  }

  PlannerReply _goalCreate(_GoalFlow f) {
    _flow = null;
    final now = _today;
    final id = 'goal-${_clock().microsecondsSinceEpoch}';
    final target = DateTime(now.year, now.month + f.months! + 1, 0);
    repository.addGoal(FinancialGoal(id: id, title: f.item, targetAmount: f.price!, targetDate: target));
    final t = 'Meta **${f.item}** criada: ${CesarText.money(f.price!)} até ${CesarText.ddmm(target)}/${target.year}, guardando ${CesarText.money(f.perMonth!)} por mês. '
        'Quando guardar, diga "guardei 500 pro ${f.item.toLowerCase()}". 🚀';
    return PlannerReply('✅ $t', 'planner:goal_created', spoken: t.replaceAll('**', ''), createdGoalId: id);
  }

  // ───────────────────────── salary split ─────────────────────────

  static final _budgetWords = RegExp(
      r'\b(?:definir|define|montar|monta|monte|fazer|faz|faca|criar|cria|organizar|organiza|planejar|planeja)\s+(?:um\s+|uma\s+|meu\s+|minha\s+|o\s+|os\s+|as\s+|meus\s+|minhas\s+)?(?:orcamento|planejamento|gastos\s+fixos|despesas\s+fixas|divisao|financas|economias|plano)\b|'
      r'\b(?:dividir|divide|distribuir|particionar|repartir)\s+(?:o\s+|meu\s+)?(?:salario|dinheiro|renda|pagamento)\b|'
      r'\bquanto\s+(?:eu\s+)?(?:devo|deveria|tenho\s+que|preciso)\s+(?:guardar|poupar|economizar|separar)\b|'
      r'\b(?:monta|montar|cria|criar|faz|fazer)\s+(?:um\s+)?orcamento\s+(?:pra|para)\s+mim\b');

  PlannerReply? _budgetStart(String s, String text) {
    if (!_budgetWords.hasMatch(s)) return null;
    final flow = _BudgetFlow();
    final said = money(s);
    if (said != null && RegExp(r'\b(?:ganho|recebo|salario|renda|ganhamos|recebemos|entra|entram)\b').hasMatch(s)) {
      flow.salary = said;
      flow.salaryConfirmed = true;
    }
    _flow = flow;
    return _budgetNext(flow);
  }

  double? get _knownSalary {
    final saved = double.tryParse(repository.preference('monthly_income') ?? '');
    if (saved != null) return saved;
    final avg = monthlyAverages();
    return avg.income > 0 ? avg.income : null;
  }

  List<FinancialTransaction> _fixed() {
    final byTitle = <String, FinancialTransaction>{};
    for (final t in _tx.where((t) => t.type == TransactionType.expense && t.isRecurrent)) {
      final k = CesarText.fold(t.title);
      final cur = byTitle[k];
      if (cur == null || t.date.isAfter(cur.date)) byTitle[k] = t;
    }
    return byTitle.values.toList()..sort((a, b) => b.amount.compareTo(a.amount));
  }

  PlannerReply _budgetNext(_BudgetFlow f) {
    if (f.salary == null) {
      final known = _knownSalary;
      if (known != null && !f.salaryConfirmed) {
        f.salary = known;
        return PlannerReply('🧾 Vamos montar seu plano do mês! Pelo que vi, você recebe uns **${CesarText.money(known)}** por mês. '
            'Está certo? Responda "sim" ou me diga o valor certo (ex.: "5000").', 'planner:budget_ask_salary', spoken: 'Você recebe uns ${CesarText.money(known)} por mês?');
      }
      return const PlannerReply('🧾 Vamos montar seu plano do mês! Quanto você recebe por mês, já descontado (ex.: "4500")?', 'planner:budget_ask_salary');
    }
    if (!f.salaryConfirmed) {
      return PlannerReply('Você recebe uns **${CesarText.money(f.salary!)}** por mês? Responda "sim" ou o valor certo.', 'planner:budget_ask_salary');
    }
    if (!f.fixedAsked) {
      f.fixedAsked = true;
      final fixed = _fixed();
      final list = fixed.isEmpty ? 'Não achei gastos fixos registrados.' : 'Seus gastos fixos registrados:\n${fixed.map((t) => '- ${t.title} — ${CesarText.money(t.amount)}').join('\n')}';
      return PlannerReply('🧾 $list\n\nFalta algum (aluguel, internet, escola, prestação…)? Me diga como "internet 100, escola 800" ou responda "não".', 'planner:budget_ask_fixed',
          spoken: 'Falta algum gasto fixo? Me diga ou responda não.');
    }
    return _budgetProposal(f);
  }

  PlannerReply? _budgetContinue(_BudgetFlow f, String s, String text) {
    if (!f.salaryConfirmed) {
      if (_yes(s)) {
        f.salaryConfirmed = true;
        return _budgetNext(f);
      }
      final v = money(s);
      if (v == null) {
        _flow = null;
        return null;
      }
      f.salary = v;
      f.salaryConfirmed = true;
      return _budgetNext(f);
    }
    if (f.proposal == null) {
      if (!_no(s) && !RegExp(r'^(?:so\s+isso|e\s+so|mais\s+nada|nenhum|nenhuma|ta\s+certo|esta\s+certo|isso\s+mesmo|sim)\b').hasMatch(s)) {
        // "internet 100, escola 800", "aluguel de 1400 e luz 200"
        for (final m in RegExp(r'([a-z][a-z ]*?)\s*(?:de\s+)?(?:r\s*)?(\d[\d.,]*(?:\s*mil)?)').allMatches(s)) {
          final name = m.group(1)!.trim().replaceFirst(RegExp(r'^(?:e|mais|tem|tenho|o|a|do|da|de)\s+'), '').trim();
          final v = money(m.group(2)!);
          if (name.isNotEmpty && v != null) f.extraFixed[name[0].toUpperCase() + name.substring(1)] = v;
        }
        if (f.extraFixed.isEmpty) {
          _flow = null;
          return null;
        }
      }
      return _budgetProposal(f);
    }
    if (_yes(s)) return _budgetApply(f);
    _flow = null;
    return null;
  }

  static const _variableWeights = {'supermarket': 0.40, 'transport': 0.20, 'leisure': 0.25, 'health': 0.15};

  PlannerReply _budgetProposal(_BudgetFlow f) {
    final salary = f.salary!;
    final fixed = _fixed();
    final fixedTotal = fixed.fold(0.0, (a, t) => a + t.amount) + f.extraFixed.values.fold(0.0, (a, v) => a + v);
    final rest = salary - fixedTotal;
    final lines = <String>[
      '**Salário: ${CesarText.money(salary)}**',
      '- 🏠 Gastos fixos: **${CesarText.money(fixedTotal)}** (${(fixedTotal / salary * 100).round()}%)'
          '${[...fixed.map((t) => t.title), ...f.extraFixed.keys].isEmpty ? '' : ' — ${[...fixed.map((t) => t.title), ...f.extraFixed.keys].join(', ')}'}',
    ];
    if (rest <= 0) {
      _flow = null;
      lines.add('- Os gastos fixos já passam do salário em ${CesarText.money(-rest)}. Antes de guardar, é preciso reduzir algum deles ou aumentar a renda.');
      return PlannerReply('🧾 ${lines.join('\n')}', 'planner:budget_plan', spoken: 'Os gastos fixos já passam do salário.');
    }
    // Savings: 20% of the salary when it fits, never more than half of what is left.
    final savings = ((salary * 0.2).clamp(0, rest * 0.5) / 10).floor() * 10.0;
    final variable = rest - savings;
    // Spending split by how the user really spends (last months), else defaults.
    final spent = <String, double>{};
    final since = DateTime(_today.year, _today.month - 3, _today.day);
    for (final t in _tx.where((t) => t.type == TransactionType.expense && !t.isRecurrent && !t.date.isBefore(since))) {
      if (_variableWeights.containsKey(t.category)) spent[t.category] = (spent[t.category] ?? 0) + t.amount;
    }
    final totalSpent = spent.values.fold(0.0, (a, v) => a + v);
    // Half how the user really spends, half a balanced default — one month of
    // data alone left almost everything to the market.
    final weights = {
      for (final c in _variableWeights.keys) c: totalSpent > 0 ? 0.5 * (spent[c] ?? 0) / totalSpent + 0.5 * _variableWeights[c]! : _variableWeights[c]!,
    };
    final proposal = {for (final e in weights.entries) e.key: ((variable * e.value) / 10).floor() * 10.0};
    lines.add('- 🛒 Gastos do dia a dia: **${CesarText.money(variable)}** (${(variable / salary * 100).round()}%):');
    for (final e in proposal.entries) {
      lines.add('   - ${CesarText.categoryName(e.key, repository.budgets)}: ${CesarText.money(e.value)}');
    }
    lines.add('- 🐷 Guardar: **${CesarText.money(savings)}** por mês (${(savings / salary * 100).round()}%) — primeiro a reserva de emergência, depois suas metas.');
    lines.add('\nPara pagar as despesas fixas sem aperto, separe **${CesarText.money(fixedTotal)}** assim que o salário cair.');
    lines.add('\nAplico esses limites nos seus orçamentos e crio a meta **Reserva de emergência**? (sim/não)');
    f.proposal = proposal;
    f.savings = savings;
    return PlannerReply('🧾 Seu plano do mês:\n${lines.join('\n')}', 'planner:budget_plan',
        spoken: 'Fixos ${CesarText.money(fixedTotal)}, dia a dia ${CesarText.money(variable)} e guardar ${CesarText.money(savings)} por mês. Aplico?');
  }

  PlannerReply _budgetApply(_BudgetFlow f) {
    _flow = null;
    final previous = <String, double>{};
    for (final e in f.proposal!.entries) {
      final b = repository.budgets.where((b) => b.category == e.key).firstOrNull;
      if (b == null) continue;
      previous[e.key] = b.monthlyLimit;
      repository.setBudgetLimit(e.key, e.value);
    }
    repository.setPreference('monthly_income', f.salary!.toStringAsFixed(2));
    String? goalId;
    final hasReserve = repository.goals.any((g) => CesarText.fold(g.title).contains('reserva'));
    if (!hasReserve && f.savings! > 0) {
      final fixedTotal = _fixed().fold(0.0, (a, t) => a + t.amount) + f.extraFixed.values.fold(0.0, (a, v) => a + v);
      final variable = f.proposal!.values.fold(0.0, (a, v) => a + v);
      final target = ((fixedTotal + variable) * 6 / 100).round() * 100.0;
      final months = (target / f.savings!).ceil();
      goalId = 'goal-${_clock().microsecondsSinceEpoch}';
      repository.addGoal(FinancialGoal(
          id: goalId, title: 'Reserva de emergência', targetAmount: target, targetDate: DateTime(_today.year, _today.month + months + 1, 0)));
    }
    final t = 'Pronto! Orçamentos atualizados${goalId != null ? ' e meta **Reserva de emergência** criada (6 meses de gastos)' : ''}. '
        'Eu te aviso quando algum orçamento chegar a 80%. Se quiser voltar atrás, diga "desfaz".';
    return PlannerReply('✅ $t', 'planner:budget_applied', spoken: t.replaceAll('**', ''), createdGoalId: goalId, previousBudgets: previous);
  }

  // ───────────────────────── situation ─────────────────────────

  PlannerReply? _situation(String s) {
    if (!RegExp(r'\b(?:minha\s+)?situacao(?:\s+financeira)?\b|\bme\s+atualiza\b|\bresumo\s+da\s+semana\b|\bcomo\s+(?:eu\s+)?(?:to|tou|estou|ando)\s+(?:de\s+dinheiro|de\s+grana|financeiramente|nas\s+financas)\b|\b(?:to|estou|tamo)\s+(?:bem|mal)\s+de\s+(?:dinheiro|grana)\b')
        .hasMatch(s)) {
      return null;
    }
    final income = repository.monthIncome, expense = repository.monthExpense;
    final free = _freeThisMonth();
    final now = _today;
    final week = _bills(now, now.add(const Duration(days: 7)));
    final weekTotal = week.fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0));
    final overdue = repository.openBills.where((b) => FinancialRepository.isOverdue(b, _clock())).toList();
    final warnings = repository.budgets.where((b) => b.monthlyLimit > 0 && b.level.index >= 1).map((b) => b.name).toList();
    final toReceive = repository.getActiveDebtors().fold(0.0, (a, d) => a + (d.amount ?? 0));
    final owe = repository.openBills.fold(0.0, (a, b) => a + (b.amount ?? 0));
    final verdict = free > 0 && overdue.isEmpty
        ? '🟢 Está tudo sob controle'
        : (free > 0 ? '🟡 No azul, mas com conta atrasada' : '🔴 Atenção: o mês está apertado');
    final lines = [
      '- Saldo: **${CesarText.money(repository.totalBalance)}** · este mês entraram ${CesarText.money(income)} e saíram ${CesarText.money(expense)}.',
      '- Previsão para o fim do mês: ${free >= 0 ? 'sobram uns ${CesarText.money(free)}' : 'faltam uns ${CesarText.money(-free)}'}.',
      if (week.isNotEmpty) '- Nos próximos 7 dias vencem ${CesarText.money(weekTotal)} (${week.map((b) => b['title']).join(', ')}).',
      if (overdue.isNotEmpty) '- 🔴 Atrasadas: ${overdue.map((b) => b.title).join(', ')}.',
      if (warnings.isNotEmpty) '- ⚠️ Orçamentos perto do limite: ${warnings.join(', ')}.',
      if (toReceive > 0) '- A receber: ${CesarText.money(toReceive)}.',
      if (owe > 0) '- Você deve: ${CesarText.money(owe)}.',
    ];
    final spoken = '$verdict. Saldo de ${CesarText.money(repository.totalBalance)}, e ${free >= 0 ? 'devem sobrar ${CesarText.money(free)}' : 'devem faltar ${CesarText.money(-free)}'} no fim do mês.';
    return PlannerReply('$verdict.\n${lines.join('\n')}', 'planner:situation', spoken: spoken);
  }

  PlannerReply? _profit(String s) {
    if (!RegExp(r'\b(?:to|tou|estou|tamo|estamos|fiquei|fico)\s+no\s+(?:lucro|azul|positivo|verde)\b|\bto\s+gastando\s+mais\s+do\s+que\s+(?:ganho|recebo)\b|\bgasto\s+mais\s+do\s+que\s+(?:ganho|recebo)\b')
        .hasMatch(s)) {
      return null;
    }
    final income = repository.monthIncome, expense = repository.monthExpense;
    final diff = income - expense;
    final free = _freeThisMonth();
    final askedOverspend = RegExp(r'\bmais\s+do\s+que\s+(?:ganho|recebo)\b').hasMatch(s);
    final t = diff >= 0
        ? '${askedOverspend ? 'Não, está tudo bem!' : 'Sim!'} Este mês entraram ${CesarText.money(income)} e saíram ${CesarText.money(expense)}: ${CesarText.money(diff)} no azul. '
            '${free >= 0 ? 'Mantendo o ritmo, devem sobrar uns ${CesarText.money(free)} no fim do mês.' : 'Mas com as contas que ainda vencem, o mês pode fechar ${CesarText.money(-free)} no vermelho.'}'
        : '${askedOverspend ? 'Sim' : 'Não'}: este mês saíram ${CesarText.money(expense)} e entraram ${CesarText.money(income)} — ${CesarText.money(-diff)} a mais do que entrou. Pergunte "onde posso economizar?".';
    return PlannerReply('${diff >= 0 ? '🟢' : '🔴'} $t', 'planner:profit', spoken: t);
  }

  /// "consigo pagar todas as contas esse mês?", "vai dar pra pagar o aluguel?"
  PlannerReply? _canPay(String s) {
    final all = RegExp(r'\b(?:consigo|vou\s+conseguir|da\s+pra|vai\s+dar\s+pra|tenho\s+dinheiro\s+pra)\s+pagar\s+(?:todas\s+)?(?:as\s+|minhas\s+)?(?:contas|boletos|despesas)\b').hasMatch(s);
    final one = RegExp(r'\b(?:consigo|vou\s+conseguir|da\s+pra|vai\s+dar\s+pra|tenho\s+dinheiro\s+pra)\s+pagar\s+(?:o|a)\s+([a-z]+(?:\s+[a-z]+)?)').firstMatch(s);
    if (!all && one == null) return null;
    final now = _today;
    final last = DateTime(now.year, now.month + 1, 0);
    final bills = [..._bills(now, last)];
    final overdue = repository.openBills.where((b) => FinancialRepository.isOverdue(b, _clock()));
    var total = bills.fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0)) + overdue.fold(0.0, (a, b) => a + (b.amount ?? 0));
    var label = 'as contas que ainda vencem este mês';
    if (!all && one != null) {
      final name = one.group(1)!.trim();
      final match = bills.where((b) => CesarText.fold('${b['title']}').contains(name.split(' ').first)).toList();
      if (match.isNotEmpty) {
        total = match.fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0));
        label = '${match.first['title']} (${CesarText.money(total)}, ${_when(match.first['dueDate'] as DateTime)})';
      } else {
        final past = _tx.where((t) => t.type == TransactionType.expense && CesarText.fold(t.title).contains(name.split(' ').first)).toList()
          ..sort((a, b) => b.date.compareTo(a.date));
        if (past.isEmpty) return null;
        total = past.first.amount;
        label = '${past.first.title} (${CesarText.money(total)}, pelo último valor)';
      }
    }
    final balance = repository.totalBalance;
    final ok = balance >= total;
    final t = total <= 0
        ? 'Não há contas para vencer até o fim do mês. 👍'
        : ok
            ? 'Dá sim: seu saldo é ${CesarText.money(balance)} e $label somam ${CesarText.money(total)}. Sobram ${CesarText.money(balance - total)}.'
            : 'Hoje não dá: seu saldo é ${CesarText.money(balance)} e $label somam ${CesarText.money(total)} — faltam ${CesarText.money(total - balance)}. '
                'Veja se entra algo antes do vencimento ou se dá para negociar a data.';
    return PlannerReply('${ok ? '✅' : '⚠️'} ${t.replaceFirst('somam', all ? 'somam' : 'é de')}', 'planner:can_pay', spoken: t);
  }

  // ───────────────────────── debts, part 2 ─────────────────────────

  /// "o joão pagou tudo", "cobrei o joão e ele pagou tudo", "a maria quitou".
  PlannerReply? _paidInFull(String s) {
    final m = RegExp(r'\bcobrei\s+(?:o|a)\s+([a-z]{3,})\s+e\s+(?:ele|ela)\s+(?:me\s+)?(?:pagou\s+tudo|quitou|acertou)').firstMatch(s) ??
        RegExp(r'\b(?:o|a)?\s*([a-z]{3,})\s+(?:me\s+)?(?:pagou\s+tudo|quitou|acertou\s+tudo|pagou\s+o\s+que\s+devia)\b').firstMatch(s);
    if (m == null || const {'ele', 'ela', 'eles', 'elas', 'voce', 'cara', 'mano'}.contains(m.group(1))) return null;
    final debtors = repository.findDebtorsByName(m.group(1)!);
    if (debtors.isEmpty) return null;
    final d = debtors.first;
    final owed = d.amount ?? 0;
    if (owed <= 0) return null;
    final before = d;
    final result = repository.applyDebtPayment(d.id, owed);
    final t = '${d.personName ?? d.title} quitou a dívida: registrei ${CesarText.money(owed)} de entrada. 🎉';
    return PlannerReply('✅ $t\n\nSe errei, diga "desfaz".', 'planner:debt_settled', spoken: t, undo: (r) {
      r.deleteTransaction(result.transaction.id);
      r.removeReminder(before.id);
      r.addReminder(before);
      return true;
    });
  }

  /// "paguei a parcela do empréstimo", "paguei a dívida do joão".
  PlannerReply? _payInstallment(String s) {
    final m = RegExp(r'\bpaguei\s+(?:a\s+|uma\s+|mais\s+uma\s+)?(?:parcela|prestacao|divida)(?:\s+(?:do|da|de|com)\s+(?:o\s+|a\s+)?([a-z ]+))?$').firstMatch(s);
    if (m == null || RegExp(r'\d').hasMatch(s)) return null;
    final hint = m.group(1)?.trim() ?? '';
    final open = repository.openBills.where((b) {
      final t = CesarText.fold('${b.title} ${b.personName ?? ''}');
      if (!RegExp(r'\b(?:parcela|divida)\b').hasMatch(t)) return false;
      if (hint.isEmpty || RegExp(r'^(?:emprestimo|divida|financiamento|cartao)$').hasMatch(hint)) return true;
      return t.contains(hint.split(' ').first);
    }).toList();
    if (open.isEmpty) return null;
    final b = open.first;
    final tx = repository.payBill(b.id);
    final left = repository.openBills.where((x) => x.title.endsWith(b.title.replaceFirst(RegExp(r'^Parcela \d+/\d+ — '), ''))).toList();
    final t = 'Marquei como paga: **${b.title}**${b.amount != null ? ' (${CesarText.money(b.amount!)})' : ''}${tx != null ? ' e registrei a despesa' : ''}. '
        '${left.isEmpty ? 'Essa dívida está quitada! 🎉' : 'Faltam ${left.length} ${left.length == 1 ? 'parcela' : 'parcelas'} (${CesarText.money(left.fold(0.0, (a, x) => a + (x.amount ?? 0)))}).'}';
    return PlannerReply('✅ $t\n\nSe errei, diga "desfaz".', 'planner:installment_paid', spoken: t.replaceAll('**', ''), undo: (r) {
      if (tx != null) r.deleteTransaction(tx.id);
      r.removeReminder(b.id);
      r.addReminder(b);
      return true;
    });
  }

  /// "quero quitar meu cartão o quanto antes", "faz um plano pra eu sair das dívidas".
  PlannerReply? _payoff(String s) {
    final debtWords = RegExp(r'\b(?:dividas?|devo|devendo|cartao|emprestimo|financiamento|rotativo|cheque\s+especial|fatura)\b');
    final howTo = RegExp(r'\bcomo\s+(?:eu\s+)?(?:pago|quito|saio|resolvo|pagar|quitar|sair|resolver|faco\s+pra\s+pagar)\b|\bo\s+que\s+(?:eu\s+)?faco\b|\bme\s+ajuda\s+a\s+(?:pagar|quitar|sair)\b')
            .hasMatch(s) &&
        debtWords.hasMatch(s);
    if (!(howTo ||
            RegExp(r'\b(?:quitar|pagar|zerar|sair\s+d[ae]s?)\s+(?:minhas\s+|as\s+|meu\s+|o\s+|a\s+)?(?:dividas?|cartao|emprestimo|financiamento|cheque\s+especial|fatura)\b|\bsair\s+do\s+vermelho\b|\bsair\s+das\s+dividas\b')
                .hasMatch(s)) ||
        RegExp(r'\b(?:paguei|quitei)\b').hasMatch(s)) {
      return null;
    }
    final debts = repository.openBills;
    final total = debts.fold(0.0, (a, b) => a + (b.amount ?? 0));
    final avg = monthlyAverages();
    final surplus = avg.income - avg.expense;
    // "tenho uma dívida de 3 mil no cartão, como eu pago?": a plan for the
    // value said, and the offer to note it down.
    final said = money(s);
    if (said != null && said > 0) return _payoffFor(said, s, surplus);
    final tips = [
      '- **Comece pela dívida mais cara**: rotativo do cartão e cheque especial costumam ter os maiores juros. Se puder, troque por um empréstimo mais barato (ex.: consignado) e quite o rotativo.',
      '- **Negocie**: bancos costumam dar desconto à vista em mutirões de renegociação.',
      '- **Não faça dívida nova** enquanto paga: corte o que cresceu ("onde posso economizar?").',
    ];
    if (total <= 0) {
      final flow = _DebtFlow();
      _flow = flow;
      return PlannerReply('💪 Bora sair das dívidas! Ainda não tenho nenhuma registrada. Quanto você deve e pra quem? '
          '(ex.: "3000 no cartão" ou "12x de 300 do empréstimo todo dia 10")\n\nEnquanto isso, o caminho certo:\n${tips.join('\n')}', 'planner:payoff_ask',
          spoken: 'Quanto você deve e pra quem?');
    }
    final pace = surplus > 0 ? (surplus * 0.8 / 10).floor() * 10.0 : 0.0;
    final months = pace > 0 ? (total / pace).ceil() : null;
    final plan = months == null
        ? '- Hoje não sobra dinheiro no mês para acelerar: o primeiro passo é cortar gastos ou aumentar a renda.'
        : '- Pagando **${CesarText.money(pace)}** por mês (80% do que costuma sobrar), você quita tudo em **$months ${months == 1 ? 'mês' : 'meses'}**.';
    final t = 'Você deve ${CesarText.money(total)} no total.';
    return PlannerReply('💪 $t\n$plan\n${tips.join('\n')}\n\nPergunte "quanto eu devo?" para ver a lista.', 'planner:payoff', spoken: t);
  }

  /// "paguei a fatura do cartão, 1540": not a new expense — the purchases on
  /// the card count when each is told; recording the bill too would count the
  /// same money twice. César says so, and points to what may be missing.
  PlannerReply? _cardBill(String s) {
    if (!RegExp(r'\b(?:paguei|pagando|vou\s+pagar|pago|quitei|acabei\s+de\s+pagar|paga)\s+(?:a\s+|minha\s+|o\s+valor\s+da\s+|toda\s+a\s+)?fatura\b').hasMatch(s)) return null;
    if (RegExp(r'\bfatura\s+(?:d[aoe]\s+)?(?:luz|agua|energia|internet|celular|telefone|gas|vivo|claro|tim|oi|net|sky|enel|cemig|cpfl|sabesp|light|copel|condominio|escola|faculdade|academia)\b')
        .hasMatch(s)) {
      return null;
    }
    final said = money(s);
    final since = _today.subtract(const Duration(days: 35));
    // What the card should have this month: purchases since the last bill,
    // and one installment of each purchase split in installments.
    var onCard = 0.0;
    for (final t in repository.transactions) {
      if (t.type != TransactionType.expense || t.paymentMethod != 'credit_card') continue;
      final n = t.installments ?? 1;
      if (n > 1) {
        final monthsAgo = (_today.year - t.date.year) * 12 + _today.month - t.date.month;
        if (monthsAgo >= 0 && monthsAgo < n) onCard += t.amount / n;
      } else if (!t.date.isBefore(since)) {
        onCard += t.amount;
      }
    }
    final gap = said != null && onCard > 0 && said > onCard * 1.1
        ? '\n\nNo crédito, você me contou uns ${CesarText.money(onCard)} no último mês. Se a fatura veio ${CesarText.money(said)}, pode ter compra que ficou de fora — '
            'me conta (ex.: "gastei 80 no mercado no crédito") que eu anoto.'
        : '';
    const t = 'Pagamento de fatura eu não registro como gasto novo: as compras do cartão já contam quando você me fala de cada uma — senão o mesmo dinheiro entraria duas vezes.';
    return PlannerReply('💳 $t$gap\n\nSe o cartão estiver cadastrado em **Contas**, a fatura dele aparece lá.', 'planner:card_bill', spoken: t);
  }

  PlannerReply _payoffFor(double amount, String s, double surplus) {
    final card = RegExp(r'\b(?:cartao|rotativo|fatura)\b').hasMatch(s);
    final overdraft = RegExp(r'\bcheque\s+especial\b').hasMatch(s);
    final pace = surplus > 0 ? (surplus * 0.8 / 10).floor() * 10.0 : 0.0;
    final months = pace > 0 ? (amount / pace).ceil() : null;
    final where = card ? ' no cartão' : (overdraft ? ' no cheque especial' : '');
    final lines = <String>[
      months == null
          ? '- Hoje não sobra dinheiro no mês para acelerar: o primeiro passo é cortar gastos ("onde posso economizar?") ou aumentar a renda.'
          : '- Pagando **${CesarText.money(pace)}** por mês (80% do que costuma sobrar), você quita em **$months ${months == 1 ? 'mês' : 'meses'}**.',
      if (card || overdraft)
        '- **${card ? 'Cartão' : 'Cheque especial'} é das dívidas mais caras**: se não der para pagar tudo agora, um parcelamento ou um empréstimo com juros menores costuma sair bem mais barato.',
      '- **Negocie**: bancos costumam dar desconto para pagamento à vista ou em mutirões de renegociação.',
      '- **Não faça dívida nova** enquanto paga.',
    ];
    _flow = _DebtFlow()
      ..total = amount
      ..creditor = card ? 'cartão' : (overdraft ? 'cheque especial' : null)
      ..offered = true;
    final t = 'Dá para resolver! Uma dívida de ${CesarText.money(amount)}$where:';
    return PlannerReply('💪 $t\n${lines.join('\n')}\n\nQuer que eu anote essa dívida para te lembrar das parcelas? Responda "sim" ou me diga como vai pagar '
        '(ex.: "10x de ${(amount / 10).ceil()} todo dia 10").', 'planner:payoff', spoken: '$t ${months == null ? '' : 'Pagando ${CesarText.money(pace)} por mês, você quita em $months meses.'}');
  }

  // ───────────────────────── goals, part 2 ─────────────────────────

  /// Goals said in other ways: emergency fund, a trip, "consigo comprar X de
  /// Y até…", "quanto tempo pra juntar 20 mil", "quero economizar 500 por mês".
  PlannerReply? _goalVariants(String s) {
    // Emergency fund: explain and plan it.
    if (RegExp(r'\breserva\s+de\s+emergencia\b|\bquanto\s+(?:eu\s+)?(?:preciso|devo)\s+ter\s+(?:de|na|em)\s+reserva\b').hasMatch(s) &&
        !RegExp(r'\bguardei|depositei|coloquei\b').hasMatch(s)) {
      final avg = monthlyAverages();
      final monthly = avg.expense > 0 ? avg.expense : null;
      final explain = 'A **reserva de emergência** é um dinheiro guardado só para imprevistos (perder o emprego, saúde, conserto), '
          'num lugar seguro e que dá para sacar na hora. O comum é ter de 3 a 6 meses dos seus gastos.';
      if (RegExp(r'^(?:o\s+que\s+e|oque\s+e|que\s+e|como\s+funciona)\b').hasMatch(s) || monthly == null) {
        return PlannerReply('🛟 $explain${monthly != null ? '\n\nPara você: de ${CesarText.money(monthly * 3)} a ${CesarText.money(monthly * 6)}.' : ''}', 'planner:knowledge',
            spoken: explain.replaceAll('**', ''));
      }
      final flow = _GoalFlow('Reserva de emergência')..price = ((monthly * 6) / 100).round() * 100.0;
      _flow = flow;
      final r = _goalPlan(flow);
      return PlannerReply('🛟 $explain Para você, 6 meses de gastos = **${CesarText.money(flow.price!)}**.\n\n${r.text}', r.route, spoken: r.spokenText);
    }
    // A trip: "quero viajar pra europa ano que vem".
    final trip = RegExp(r'\b(?:quero|queria|vou|pretendo|sonho\s+em)\s+(?:viajar|fazer\s+uma\s+viagem|conhecer|ir)\s+(?:pra|para|a|ao|o)\s+(?:a\s+|o\s+)?([a-z]+(?:\s+(?!(?:ano|mes|semana|que|em|no|na|ate|e|com|pra|para|daqui)\b)[a-z]+)?)').firstMatch(s);
    // "consigo comprar uma moto de 15 mil até o fim do ano?"
    final canBuy = RegExp(r'\b(?:consigo|da\s+pra|vou\s+conseguir)\s+(?:comprar|trocar\s+de)\s+(?:(?:um|uma|o|a|meu|minha)\s+)?([a-z]{3,})').firstMatch(s);
    // "quanto tempo pra eu juntar 20 mil?"
    final howLong = RegExp(r'\bquanto\s+tempo\s+(?:pra|para|eu\s+levo\s+pra|levo\s+pra)\s+(?:eu\s+)?(?:juntar|guardar|economizar|ter)\b').hasMatch(s);
    if (trip == null && (canBuy == null || money(s) == null || !RegExp(r'\b(?:ate|em|ano|mes|meses)\b').hasMatch(s)) && !howLong) return null;
    final name = trip != null
        ? 'Viagem para ${trip.group(1)!.split(' ').map((w) => w[0].toUpperCase() + w.substring(1)).join(' ')}'
        : canBuy != null
            ? canBuy.group(1)![0].toUpperCase() + canBuy.group(1)!.substring(1)
            : 'Objetivo';
    final flow = _GoalFlow(name)..price = money(s);
    flow.months = _deadlineMonths(s);
    _flow = flow;
    if (flow.price == null) {
      return PlannerReply('🎯 Bora planejar: **$name**${flow.months != null ? ' em ${flow.months} meses' : ''}. Quanto vai custar, mais ou menos?', 'planner:goal_ask',
          spoken: 'Quanto vai custar, mais ou menos?');
    }
    return _goalPlan(flow);
  }

  /// "até o fim do ano", "ano que vem", "em 8 meses", "até dezembro".
  int? _deadlineMonths(String s) {
    final now = _today;
    final within = RegExp(r'\b(?:em|ate|dentro\s+de)\s+(\d{1,2})\s+(meses|mes|anos|ano)\b').firstMatch(s);
    if (within != null) return int.parse(within.group(1)!) * (within.group(2)!.startsWith('ano') ? 12 : 1);
    if (RegExp(r'\b(?:fim|final)\s+do\s+ano\b|\bate\s+dezembro\b').hasMatch(s)) return (12 - now.month).clamp(1, 12);
    if (RegExp(r'\bano\s+que\s+vem\b|\bproximo\s+ano\b').hasMatch(s)) return 12 + (12 - now.month) ~/ 2;
    const names = ['janeiro', 'fevereiro', 'marco', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
    final month = RegExp(r'\bate\s+(' + names.join('|') + r')\b').firstMatch(s);
    if (month != null) {
      final target = names.indexOf(month.group(1)!) + 1;
      final diff = (target - now.month + 12) % 12;
      return diff == 0 ? 12 : diff;
    }
    return null;
  }

  /// "quero economizar 500 por mês", "me ajuda a juntar dinheiro".
  PlannerReply? _saveMonthly(String s) {
    final perMonth = RegExp(r'\b(?:quero|vou|preciso|pretendo)\s+(?:economizar|guardar|poupar|juntar|separar)\s+(?:r\s*)?(\d[\d.,]*(?:\s*mil)?)\s*(?:reais\s+)?(?:por|ao|todo|cada)\s+mes\b').firstMatch(s);
    if (perMonth != null) {
      final v = money(perMonth.group(1)!)!;
      final avg = monthlyAverages();
      final surplus = avg.income - avg.expense;
      final fits = surplus <= 0 ? 'Hoje não sobra dinheiro no mês, então vai ser preciso cortar gastos para isso ("onde posso economizar?").'
          : v <= surplus ? 'Cabe no seu orçamento: em média sobram ${CesarText.money(surplus)} por mês.'
          : 'É mais do que costuma sobrar (${CesarText.money(surplus)}/mês) — vai precisar cortar ${CesarText.money(v - surplus)} ("onde posso economizar?").';
      final t = 'Guardando ${CesarText.money(v)} por mês: ${CesarText.money(v * 6)} em 6 meses e ${CesarText.money(v * 12)} em 1 ano. $fits';
      return PlannerReply('🐷 $t\n\nQuer dar um nome a isso? Diga, por exemplo, "quero juntar ${(v * 12).round()} pra reserva de emergência".', 'planner:save_monthly', spoken: t);
    }
    if (RegExp(r'\b(?:me\s+)?ajud\w*\s+a\s+(?:juntar|guardar|economizar|poupar)\s+(?:dinheiro|grana)\b|\bquero\s+(?:comecar\s+a\s+)?(?:juntar|guardar|economizar|poupar)\s+(?:dinheiro|grana)\b|\bcomo\s+(?:eu\s+)?(?:junto|guardo|economizo)\s+(?:dinheiro|grana)\b')
        .hasMatch(s)) {
      final flow = _BudgetFlow();
      _flow = flow;
      final r = _budgetNext(flow);
      return PlannerReply('🐷 Bora! O jeito mais simples é decidir quanto guardar assim que o salário cai, antes de gastar. Vou montar isso com você.\n\n${r.text}', r.route,
          spoken: r.spokenText);
    }
    return null;
  }

  // ───────────────────────── knowledge ─────────────────────────

  static const _glossary = <String, String>{
    r'\bcdb\b':
        '**CDB** (Certificado de Depósito Bancário) é um empréstimo que você faz ao banco em troca de juros. Costuma render um percentual do CDI; '
            'tem garantia do FGC até o limite por CPF e instituição; e o Imposto de Renda diminui quanto mais tempo o dinheiro fica aplicado.',
    r'\btesouro\s+direto\b|\btesouro\s+(?:selic|ipca|prefixado)\b':
        '**Tesouro Direto** é comprar títulos do governo federal. O **Tesouro Selic** acompanha a taxa básica de juros e oscila pouco — comum para reserva de emergência; '
            'o **IPCA+** protege da inflação (bom para prazos longos, mas oscila se vender antes); o **Prefixado** trava uma taxa. Se vale a pena depende do seu prazo e objetivo.',
    r'\bpoupanca\b':
        '**Poupança** é simples e sem Imposto de Renda, mas costuma render menos que outras opções de renda fixa (como Tesouro Selic ou CDB com liquidez diária).',
    r'\bjuros?\s+(?:do\s+)?(?:cartao|rotativo)\b|\brotativo\b':
        'Quando você não paga a **fatura inteira** do cartão, o que fica vai para o **rotativo**, com juros entre os mais altos do mercado. '
            'Desde 2024, juros e encargos do rotativo não podem passar do valor da dívida original. O melhor é pagar a fatura toda ou trocar por um parcelamento ou empréstimo mais barato.',
    r'\bcheque\s+especial\b':
        '**Cheque especial** é o limite que o banco libera quando a conta fica negativa — com juros muito altos. Use só por pouquíssimos dias.',
    r'\b(?:cdi|selic)\b':
        'A **Selic** é a taxa básica de juros do Brasil, definida pelo Banco Central; o **CDI** anda colado nela. Muitos investimentos de renda fixa rendem "x% do CDI".',
    r'\bfgc\b':
        'O **FGC** (Fundo Garantidor de Créditos) devolve o dinheiro de CDB, LCI, LCA e poupança se o banco quebrar, até um limite por CPF e por instituição.',
    r'\b(?:lci|lca)\b':
        '**LCI e LCA** são títulos de bancos ligados a imóveis e ao agronegócio. Para pessoa física, não pagam Imposto de Renda e têm garantia do FGC; costumam ter prazo mínimo.',
    r'\bacoes\b|\bbolsa\s+de\s+valores\b':
        '**Ações** são pedaços de empresas. Podem render muito mais, mas oscilam bastante: é dinheiro para prazos longos e depois de ter a reserva de emergência.',
    r'\brenda\s+fixa\b':
        'Na **renda fixa** você sabe a regra do rendimento na hora de investir (ex.: 100% do CDI, IPCA + 6%). Na **renda variável** (ações, fundos imobiliários) o rendimento oscila.',
    r'\binflacao\b|\bipca\b':
        '**Inflação** é a alta geral dos preços; o **IPCA** é o índice oficial. Se seu dinheiro rende menos que a inflação, ele perde poder de compra.',
  };

  PlannerReply? _knowledge(String s) {
    if (!RegExp(r'^(?:o\s+que\s+(?:e|sao|significa)|oque\s+e|que\s+e|como\s+funciona[m]?|me\s+explica|explica|vale\s+a\s+pena|e\s+bom|compensa)\b|\bvale\s+a\s+pena\b|\bcompensa\b|'
            r'\be\s+(?:ruim|bom|boa|perigos[oa]|car[oa]|seguro|segura|confiavel)\b|\bdevo\s+usar\b|\bpor\s+que\s+(?:evitar|fugir)\b|'
            // "qual a diferença entre cdb e poupança?", "quanto rende a poupança?"
            r'\bdiferenca\s+entre\b|\bqual\s+(?:e\s+)?(?:a\s+)?diferenca\b|\bquanto\s+rende\b|\bqual\s+(?:e\s+)?(?:o\s+)?melhor\b|\be\s+melhor\b|\brende\s+mais\b')
        .hasMatch(s)) {
      return null;
    }
    final found = [
      for (final e in _glossary.entries)
        if (RegExp(e.key).hasMatch(s)) e.value,
    ];
    if (found.isEmpty) return null;
    // Two things asked side by side ("cdb ou poupança?"): both, one after the other.
    final both = found.length >= 2 && RegExp(r'\bdiferenca\b|\bou\b|\bmelhor\b|\bmais\b|\bvs\b|\bversus\b').hasMatch(s);
    final t = both ? '${found[0]}\n\n${found[1]}' : found.first;
    final close = both ? '\n\nO melhor depende do prazo e de quando você vai precisar do dinheiro: para reserva, vale a liquidez diária; para prazos longos, o rendimento pesa mais.' : '';
    return PlannerReply('📚 $t$close\n\n_Isso é informação geral, não recomendação de investimento._', 'planner:knowledge', spoken: found.first.replaceAll('**', ''));
  }

  // ───────────────────────── app help, part 2 ─────────────────────────

  PlannerReply? _appHelp(String s) {
    if (RegExp(r'\b(?:consegue|sabe|pode)\s+ler\s+(?:o\s+)?(?:meu\s+)?extrato\b|\bimporta\w*\s+extrato\b').hasMatch(s)) {
      return const PlannerReply('🏦 Consigo sim! Exporte o extrato no app do banco em OFX ou CSV e use **Ajustes → Ferramentas → Importar extrato do banco**. '
          'Eu mostro tudo antes de importar e não duplico o que já existe. Se quiser o passo a passo, pergunte "como pego meu extrato no banco?".', 'help');
    }
    if (RegExp(r'\b(?:exportar|baixar|levar|salvar)\s+(?:os\s+)?(?:meus\s+)?dados\b|\bbackup\b').hasMatch(s)) {
      return const PlannerReply('📦 Em **Ajustes → Privacidade e dados → Exportar meus dados** você baixa tudo em JSON e os lançamentos em CSV (abre no Excel).', 'help');
    }
    if (RegExp(r'\bo\s+que\s+(?:voce\s+)?nao\s+(?:sabe|consegue|faz)\b|\bquais\s+(?:sao\s+)?(?:seus|os\s+seus)\s+limites\b').hasMatch(s)) {
      return const PlannerReply('🙂 Ainda não consigo:\n'
          '- acessar sua conta no banco direto (importe o extrato por arquivo);\n'
          '- fazer pagamentos ou transferências;\n'
          '- recomendar investimentos específicos (dou informação geral);\n'
          '- entender tudo de primeira — quando eu errar, me corrija ("não, foi 45") que eu aprendo as categorias.', 'help');
    }
    return null;
  }

  // ───────────────────────── conversation ─────────────────────────

  PlannerReply? _feelings(String s) {
    if (RegExp(r'\b(?:to|tou|estou|ando|fico)\s+(?:muito\s+)?(?:preocupad[oa]|ansios[oa]|estressad[oa]|nervos[oa]|com\s+medo)\b').hasMatch(s) &&
        RegExp(r'\b(?:dinheiro|grana|contas?|dividas?|financas|mes)\b').hasMatch(s)) {
      final free = _freeThisMonth();
      final t = 'Entendo, dinheiro preocupa mesmo. Vamos olhar com calma: seu saldo é ${CesarText.money(repository.totalBalance)} e, no ritmo atual, '
          '${free >= 0 ? 'devem sobrar uns ${CesarText.money(free)} no fim do mês' : 'o mês pode fechar ${CesarText.money(-free)} no vermelho'}.';
      return PlannerReply('🫂 $t\n\nPosso te ajudar a: ver o que vence ("o que tenho essa semana?"), achar onde cortar ("onde posso economizar?") '
          'ou montar um plano ("me ajuda a dividir meu salário").', 'planner:feelings', spoken: t);
    }
    if (RegExp(r'^(?:valeu|obrigad\w*|brigad\w*|muito\s+obrigad\w*|show|top|perfeito|massa)\b.*\b(?:ajudou|ajuda|salvou|demais|muito)\b').hasMatch(s)) {
      return const PlannerReply('Que bom que ajudou! Tô por aqui sempre que precisar. 💜', 'smalltalk');
    }
    if (RegExp(r'\b(?:conta|conte|fala|me\s+fala)\s+(?:uma\s+)?piada\b').hasMatch(s)) {
      const jokes = [
        'Por que o dinheiro foi ao médico? Porque estava se sentindo muito *desvalorizado*. 😄',
        'Meu salário e eu temos um relacionamento sério: ele chega, me dá um beijo e vai embora. 😅',
        'Qual o investimento que nunca dá prejuízo? Dormir cedo: rende juros de disposição. 😴',
      ];
      return PlannerReply(jokes[_clock().second % jokes.length], 'smalltalk');
    }
    return null;
  }

  // ───────────────────────── analytics: cuts, savings, goals, scenarios ─────────────────────────

  /// The cuts of the last "o que eu devo cortar?" — what "nisso" refers to.
  List<CutSuggestion> _lastCuts = const [];

  AnalysisContext get _ctx => AnalysisContext(repository, now: _clock());

  String _dataNote(AnalysisContext ctx) => ctx.profile.daysOfData < 60
      ? '\n\n_Tenho ${ctx.profile.daysOfData} dias dos seus dados: as contas ficam mais precisas com o tempo._'
      : '';

  PlannerReply? _cutsAdvice(String s) {
    if (!RegExp(r'\b(?:o\s+que|oque|onde|em\s+que|no\s+que|qual\s+gasto|quais\s+gastos)\s+(?:eu\s+)?(?:devo|posso|deveria|poderia|consigo|preciso|tenho\s+que|da\s+pra)\s+(?:cortar|reduzir|diminuir|economizar|enxugar)\b|'
            r'\bonde\s+(?:eu\s+)?(?:to|estou)\s+gastando\s+(?:demais|muito)\b|\bem\s+que\s+(?:eu\s+)?gasto\s+demais\b|\bcortar\s+(?:de\s+|meus\s+|os\s+)?gastos\b|\bquais?\s+gastos?\s+(?:eu\s+)?(?:corto|cortar)\b')
        .hasMatch(s)) {
      return null;
    }
    final ctx = _ctx;
    final cuts = SavingsCoach(ctx).cuts();
    _lastCuts = cuts;
    if (cuts.isEmpty) {
      const t = 'Não encontrei exageros: seus gastos estão no seu padrão e dentro do comum para a sua renda. 👏 '
          'Se quiser guardar mais, pergunte "o que eu poderia fazer para economizar mais?".';
      return const PlannerReply('✂️ $t', 'planner:cuts', spoken: t);
    }
    final total = cuts.fold(0.0, (a, c) => a + c.monthly);
    const effort = {1: 'fácil', 2: 'médio', 3: 'difícil'};
    final lines = [
      for (var i = 0; i < cuts.length; i++) '${i + 1}. **${cuts[i].title}** — ${CesarText.money(cuts[i].monthly)}/mês (${effort[cuts[i].effort]}). ${cuts[i].detail}',
    ];
    final impact = SavingsCoach(ctx).goalImpact(total).where((g) => g.before.isFinite && g.before - g.after >= 0.5).take(2).toList();
    final goals = impact.isEmpty
        ? ''
        : '\n\n🎯 Com tudo isso, ${impact.map((g) => '**${g.goal.title}** chega ${(g.before - g.after).round()} ${(g.before - g.after).round() == 1 ? 'mês' : 'meses'} antes').join(' e ')}.';
    final t = 'Analisei seus gastos mês a mês. Dá para economizar até **${CesarText.money(total)} por mês** (${CesarText.money(total * 12)} por ano):';
    return PlannerReply('✂️ $t\n${lines.join('\n')}$goals\n\nQuer saber em quanto tempo isso vira uma compra? Pergunte, por exemplo, '
        '"se eu economizar nisso, em quanto tempo compro um notebook de 2000?".${_dataNote(ctx)}', 'planner:cuts',
        spoken: 'Dá para economizar até ${CesarText.money(total)} por mês. O maior corte é ${cuts.first.title}, ${CesarText.money(cuts.first.monthly)} por mês.');
  }

  PlannerReply? _saveMore(String s) {
    if (!RegExp(r'\b(?:o\s+que|oque|como)\s+(?:eu\s+)?(?:poderia|posso|devo|consigo|deveria|da\s+pra)\s+(?:fazer\s+)?(?:pra|para)?\s*(?:economizar|guardar|poupar|juntar)\s+mais\b|'
            r'\b(?:economizar|guardar|poupar|sobrar)\s+mais\s+(?:dinheiro|grana)?\b|\bdicas?\s+(?:de|pra|para)\s+(?:economi|guardar|poupar)\w*|\bcomo\s+(?:eu\s+)?(?:faco|faço)\s+(?:pra|para)\s+sobrar\s+(?:mais\s+)?dinheiro\b|'
            // "preciso economizar", "tenho que guardar dinheiro", "quero poupar".
            r'^(?:(?:eu|acho\s+que|nossa|cara|mano)\s+)*(?:preciso|precisava|tenho\s+que|tenho\s+de|quero|queria|devia|deveria)\s+(?:muito\s+)?(?:comecar\s+a\s+)?'
            r'(?:economizar|guardar\s+(?:dinheiro|grana)|poupar|juntar\s+(?:dinheiro|grana))$')
        .hasMatch(s)) {
      return null;
    }
    final ctx = _ctx;
    final p = ctx.profile;
    final coach = SavingsCoach(ctx);
    final cuts = coach.cuts();
    _lastCuts = cuts;
    final total = cuts.fold(0.0, (a, c) => a + c.monthly);
    final actions = <String>[];
    if (cuts.isNotEmpty) {
      actions.add('**Cortes com mais efeito**: ${cuts.take(3).map((c) => '${c.title} (${CesarText.money(c.monthly)}/mês)').join(', ')}'
          ' — juntos, ${CesarText.money(cuts.take(3).fold(0.0, (a, c) => a + c.monthly))} por mês.');
    }
    if (p.avgIncome > 0) {
      final target = max(p.avgIncome * 0.1, (p.avgNet * 0.5 / 10).round() * 10.0);
      final salaryDay = p.recurringIncomes.isEmpty ? null : p.recurringIncomes.first.day;
      actions.add('**Pague-se primeiro**: separe ${CesarText.money(target)} assim que o salário cair${salaryDay != null ? ' (dia $salaryDay)' : ''}, '
          'antes de gastar — o que sobra no fim do mês costuma sumir.');
    }
    final uncovered = p.categories.values
        .where((c) => !c.essential && c.mean >= 100 && !ctx.repository.budgets.any((b) => b.category == c.category && b.monthlyLimit > 0))
        .toList();
    if (uncovered.isNotEmpty) {
      actions.add('**Crie limites** para ${uncovered.map((c) => '${CesarText.categoryName(c.category, ctx.repository.budgets)} (sugiro ${CesarText.money((c.median / 10).round() * 10.0)})').join(', ')} '
          '— eu aviso quando chegar a 80%.');
    }
    final over = ctx.repository.budgets.where((b) => b.isOverBudget).map((b) => b.name).toList();
    if (over.isNotEmpty) actions.add('**Orçamento estourado** este mês: ${over.join(', ')}. Segure essas categorias até o fim do mês.');
    final debts = ctx.repository.openBills.fold(0.0, (a, b) => a + (b.amount ?? 0));
    if (debts > 0) actions.add('**Quite as dívidas mais caras primeiro** (você deve ${CesarText.money(debts)}): juros pagos são dinheiro que não fica com você.');
    if (p.savingsRate < 0.2 && p.avgIncome > 0) {
      actions.add('Hoje você guarda **${_pctLabel(p.savingsRate)}** da renda; a referência comum é 20%. Faltam ${CesarText.money(max(0.0, p.avgIncome * 0.2 - p.avgNet))} por mês para chegar lá.');
    }
    final impact = coach.goalImpact(total).where((g) => g.before.isFinite && g.before - g.after >= 0.5).take(2).toList();
    final goals = impact.isEmpty ? '' : '\n\n🎯 Aplicando os cortes, ${impact.map((g) => '**${g.goal.title}** chega ${(g.before - g.after).round()} meses antes').join(' e ')}.';
    final t = 'Hoje sobram uns ${CesarText.money(max(0.0, p.avgNet))} por mês (${_pctLabel(p.savingsRate)} da renda). Para guardar mais:';
    return PlannerReply('💡 $t\n${[for (var i = 0; i < actions.length; i++) '${i + 1}. ${actions[i]}'].join('\n')}$goals${_dataNote(ctx)}', 'planner:save_more',
        spoken: '$t ${cuts.isNotEmpty ? 'O que mais rende é cortar ${cuts.first.title}.' : ''}');
  }

  static String _pctLabel(double r) => '${(r * 100).round()}%';

  PlannerReply? _howAmIDoing(String s) {
    if (!RegExp(r'\bcomo\s+(?:eu\s+)?(?:estou|to|tou|ando)\s+(?:me\s+saindo|indo)\b|\bcomo\s+(?:estao|tao|andam)\s+(?:as\s+|minhas\s+|nossas\s+)?metas\b|'
            r'\b(?:vou|consigo|vamos)\s+(?:bater|alcancar|atingir|cumprir|chegar\s+n?as)\s+(?:as\s+|minhas\s+|nossas\s+)?metas?\b|\b(?:to|estou)\s+no\s+caminho\s+certo\b|\bprogresso\s+(?:das?\s+)?(?:minhas\s+)?metas?\b|\bminhas\s+metas\s+(?:estao|tao)\b')
        .hasMatch(s)) {
      return null;
    }
    final ctx = _ctx;
    final rep = GoalTracker(ctx).report();
    final lines = <String>[
      '- Você guarda **${_pctLabel(rep.savingsRate)}** da renda por mês (referência: 20%).',
      if (rep.budgetsTotal > 0) '- Orçamentos: ${rep.budgetsOver == 0 ? 'todos dentro do limite 👏' : '${rep.budgetsOver} de ${rep.budgetsTotal} estourados este mês'}.',
    ];
    for (final g in rep.goals) {
      final saved = '${CesarText.money(g.goal.savedAmount)} de ${CesarText.money(g.goal.targetAmount)}';
      if (g.onTrack == null) {
        lines.add('- 🎯 **${g.goal.title}**: $saved${g.projected != null ? '; no seu ritmo, chega em ${CesarText.ddmm(g.projected!)}/${g.projected!.year}' : '; ainda sem aportes'}.');
      } else if (g.onTrack!) {
        lines.add('- ✅ **${g.goal.title}**: $saved — no ritmo! Previsão ${CesarText.ddmm(g.projected!)}/${g.projected!.year}, '
            'chance de bater o prazo: **${_pctLabel(g.chance ?? 1)}**.');
      } else {
        final need = g.requiredMonthly ?? 0;
        lines.add('- ⚠️ **${g.goal.title}**: $saved — fora do ritmo. Precisa de ${CesarText.money(need)}/mês até ${CesarText.ddmm(g.goal.targetDate!)}/${g.goal.targetDate!.year} '
            '(hoje: ${CesarText.money(g.pace)}/mês); chance: **${_pctLabel(g.chance ?? 0)}**. '
            '${need > max(0.0, ctx.profile.avgNet) ? 'Isso passa do que sobra por mês: estique o prazo ou corte gastos ("o que eu devo cortar?").' : 'Aumente o aporte para chegar lá.'}');
      }
    }
    if (rep.goals.isEmpty) lines.add('- Você ainda não tem metas. Diga, por exemplo, "quero juntar 5000 pra uma viagem até dezembro".');
    final t = 'Nota **${rep.score}/100** — você está ${rep.label}';
    return PlannerReply('📈 $t\n${lines.join('\n')}${_dataNote(ctx)}', 'planner:goals_report',
        spoken: 'Sua nota é ${rep.score} de 100. Você guarda ${_pctLabel(rep.savingsRate)} da renda.');
  }

  /// "se eu economizar nisso, em quanto tempo compro um notebook de 2000?",
  /// "se eu cortar o delivery, quando consigo comprar um celular de 3 mil?",
  /// "se eu guardar 300 por mês, em quanto tempo tenho 5 mil?"
  PlannerReply? _scenario(String s) {
    final cond = RegExp(r'\bse\s+(?:eu\s+)?(?:economizar|cortar|guardar|poupar|reduzir|parar\s+de|deixar\s+de|seguir|fizer|aplicar|juntar|separar)\b').firstMatch(s);
    if (cond == null) return null;
    if (!RegExp(r'\b(?:quanto\s+tempo|quando|quantos\s+meses|que\s+mes|em\s+que\s+mes)\b').hasMatch(s)) return null;
    if (!RegExp(r'\b(?:comprar|ter\s+(?:o\s+)?dinheiro|juntar|ter\s+(?:r\s*)?\d|trocar|pagar|quitar)\b').hasMatch(s)) return null;
    // The monthly amount ("300 por mês") and the price (the other value).
    final perMonthM = RegExp(r'(\d[\d.,]*(?:\s*mil)?)\s*(?:reais\s+)?(?:por|ao|todo|cada|no)\s+mes\b').firstMatch(s);
    final perMonthSaid = perMonthM == null ? null : money(perMonthM.group(1)!);
    final rest = perMonthM == null ? s : s.replaceFirst(perMonthM.group(0)!, ' ');
    final price = money(rest);
    if (price == null) return null;
    final item = RegExp(r'\b(?:comprar|trocar\s+de|ter)\s+(?:(?:um|uma|o|a|meu|minha)\s+)?([a-z]{3,})').firstMatch(rest)?.group(1);
    final title = item == null || item == 'dinheiro' ? 'isso' : item;
    final ctx = _ctx;
    final coach = SavingsCoach(ctx);
    double extra;
    String what;
    if (perMonthSaid != null) {
      // "se eu guardar 300 por mês": that is the whole monthly saving.
      extra = perMonthSaid - max(0.0, ctx.profile.avgNet);
      what = 'guardando ${CesarText.money(perMonthSaid)} por mês';
    } else if (RegExp(r'\b(?:nisso|isso|disso|nesses?|nessas?|esses?|essas?|os\s+cortes|tudo\s+isso|essas\s+dicas)\b').hasMatch(s)) {
      if (_lastCuts.isEmpty) _lastCuts = coach.cuts();
      extra = _lastCuts.fold(0.0, (a, c) => a + c.monthly);
      what = _lastCuts.isEmpty ? 'com os cortes' : 'com os cortes que sugeri (${_lastCuts.map((c) => c.title).join(', ')}: +${CesarText.money(extra)}/mês)';
    } else {
      // "se eu cortar o delivery": that suggestion, or the category's spending.
      final target = cond.end < s.length ? s.substring(cond.end) : '';
      final cuts = _lastCuts.isEmpty ? coach.cuts() : _lastCuts;
      final match = cuts.where((c) => target.contains(CesarText.fold(c.title).split(' ').first) || target.contains(c.category)).firstOrNull;
      if (match != null) {
        extra = match.monthly;
        what = 'cortando ${match.title} (+${CesarText.money(extra)}/mês)';
      } else if (RegExp(r'\b(?:delivery|ifood)\b').hasMatch(target)) {
        final d = ctx.repository.transactions.where((t) => FinancialProfile.deliveryTitles.hasMatch(CesarText.fold(t.title)) && t.date.isAfter(ctx.now.subtract(const Duration(days: 90))));
        extra = d.fold(0.0, (a, t) => a + t.amount) / 3;
        what = 'sem delivery (+${CesarText.money(extra)}/mês)';
      } else {
        extra = 0;
        what = 'com esse corte';
      }
    }
    final base = coach.timeToAfford(price);
    final withCut = coach.timeToAfford(price, extraMonthly: extra);
    String line(({int months, double perMonth, double chance})? r, String label) {
      if (r == null) return '- $label: hoje não sobra dinheiro no fim do mês, então não chega lá sem mudar algo.';
      if (r.months == 0) return '- $label: **já dá** — você tem isso acima da sua reserva mínima.';
      return '- $label: **${coach.monthsLabel(r.months)}** (${coach.whenLabel(r.months)}), juntando ${CesarText.money(r.perMonth)}/mês — chance de ter o dinheiro até lá: ${_pctLabel(r.chance)}.';
    }
    final gain = base != null && withCut != null ? base.months - withCut.months : null;
    final label = title == 'isso' ? '' : ' (${title[0].toUpperCase()}${title.substring(1)})';
    final t = 'Para ter ${CesarText.money(price)}$label:';
    final lines = [
      line(base, 'No seu ritmo atual'),
      if (extra.abs() >= 1) line(withCut, what[0].toUpperCase() + what.substring(1)),
    ];
    // Already affordable: how long only with what is left each month, so the
    // balance stays untouched.
    if (base != null && base.months == 0) {
      final net = max(0.0, ctx.profile.avgNet);
      final onlySavings = net > 0 ? (price / net).ceil() : null;
      final onlyWithCut = net + extra > 0 ? (price / (net + extra)).ceil() : null;
      if (onlySavings != null) {
        lines.add('- Sem mexer no saldo, só com o que sobra por mês: **${coach.monthsLabel(onlySavings)}**'
            '${extra.abs() >= 1 && onlyWithCut != null && onlyWithCut < onlySavings ? '; ${what.replaceFirst(RegExp(r'\s*\(.*$'), '')}: **${coach.monthsLabel(onlyWithCut)}**' : ''}.');
      }
    }
    final summary = gain != null && gain > 0
        ? '\n\nO corte adianta a compra em **${coach.monthsLabel(gain)}**.'
        : (withCut != null && withCut.months > 0 ? '' : '');
    final months = withCut?.months ?? base?.months;
    if (months != null && months > 0) {
      final flow = _GoalFlow(title == 'isso' ? 'Objetivo' : title[0].toUpperCase() + title.substring(1))
        ..price = price
        ..perMonth = withCut?.perMonth ?? base?.perMonth
        ..months = months
        ..awaitingConfirm = true;
      _flow = flow;
      return PlannerReply('🧮 $t\n${lines.join('\n')}$summary\n\nQuer que eu crie a meta **${flow.item}** com esse plano? (sim/não)${_dataNote(ctx)}', 'planner:scenario',
          spoken: '${withCut != null && extra.abs() >= 1 ? 'Com o corte, em ${coach.monthsLabel(withCut.months)}' : 'Em ${coach.monthsLabel(months)}'}. Crio a meta?');
    }
    return PlannerReply('🧮 $t\n${lines.join('\n')}$summary${_dataNote(ctx)}', 'planner:scenario', spoken: lines.first.replaceAll('**', ''));
  }

  /// "posso comprar um notebook?" with no price: ask it, then simulate.
  /// "tô pensando em trocar de carro", "será que compensa assinar o
  /// gamepass?", "tô afim de comprar uma bike": a purchase being weighed.
  static final _weighing = RegExp(r'\b(?:pensando\s+em|penso\s+em|to\s+afim\s+de|estou\s+afim\s+de|to\s+querendo|estou\s+querendo|vale\s+a\s+pena|compensa)\s+'
      r'(?:comprar|trocar\s+(?:de|o|a|meu|minha)|pegar|assinar|bancar)\s+(?:(?:um|uma|o|a|meu|minha|esse|essa)\s+)?([a-z]{3,}(?:\s+(?!agora|hoje|logo|ja|esse|este|essa)[a-z]{3,})?)');

  PlannerReply? _purchaseAsk(String s, String text) {
    final weighed = money(s) == null ? _weighing.firstMatch(s)?.group(1) : null;
    if (weighed != null) {
      _flow = _PurchaseFlow(weighed);
      return PlannerReply('🛍️ Bora ver se cabe! Quanto custa o **$weighed**? (ex.: "2500" ou "3000 em 10x") Eu simulo o seu caixa com e sem a compra.',
          'planner:purchase_ask', spoken: 'Bora ver se cabe! Quanto custa?');
    }
    if (!AffordabilityAnalyzer.isAffordabilityQuestion(text) || money(s) != null) return null;
    final item = RegExp(r'\b(?:comprar|bancar)\s+(?:(?:um|uma|o|a|meu|minha|esse|essa)\s+)?([a-z]{3,}(?:\s+[a-z]{3,})?)').firstMatch(s)?.group(1);
    if (item == null) return null;
    _flow = _PurchaseFlow(item);
    return PlannerReply('🛍️ Quanto custa ${item.startsWith(RegExp('[aeiou]')) ? 'o' : 'o'} **$item**? (ex.: "2500" ou "3000 em 10x") Eu simulo o seu caixa com e sem a compra.',
        'planner:purchase_ask', spoken: 'Quanto custa?');
  }

  PlannerReply? _purchaseContinue(_PurchaseFlow f, String s, String text) {
    final price = money(s.replaceAll(RegExp(r'\b\d{1,2}\s*x\b|\bem\s+\d{1,2}\s+(?:vezes|parcelas)\b'), ' '));
    _flow = null;
    if (price == null) return null;
    final result = AffordabilityAnalyzer(repository: repository, now: _clock).analyze('posso comprar ${f.item} de $price reais ${RegExp(r'\b\d{1,2}\s*x\b|\bem\s+\d{1,2}\s+(?:vezes|parcelas)\b').firstMatch(s)?.group(0) ?? ''}');
    if (result == null) return null;
    return PlannerReply(result.formattedText.trim(), 'afford:${result.verdict.name}', spoken: result.spokenText);
  }
}
