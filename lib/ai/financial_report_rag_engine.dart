import 'dart:math' as math;
import '../backend/models/financial_reminder.dart';
import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'temporal_date_parser.dart';

enum ReportIntent {
  debtors,
  spending,
  bills,
  overview,
  conversationHistory,
  unknown,
}

/// A chart to render alongside a report, built only when the user's query asks for one
/// (e.g. "gráfico dos meus gastos"). Exactly one of [categoryValues] or [barValues] is set.
class ReportChartData {
  /// Category code -> total amount (rendered as the existing dashboard donut chart).
  final Map<String, double>? categoryValues;

  /// Label -> value pairs for a generic bar chart (debtors, bills, overview).
  final List<MapEntry<String, double>>? barValues;

  const ReportChartData.category(Map<String, double> this.categoryValues) : barValues = null;
  const ReportChartData.bars(List<MapEntry<String, double>> this.barValues) : categoryValues = null;
}

class ReportRagResult {
  final ReportIntent intent;
  final String spokenText;
  final String formattedText;
  final DateRangeResult? dateRange;
  final List<dynamic> matchedItems;
  final ReportChartData? chart;

  const ReportRagResult({
    required this.intent,
    required this.spokenText,
    required this.formattedText,
    this.dateRange,
    this.matchedItems = const [],
    this.chart,
  });
}

/// On-device RAG (Retrieval-Augmented Generation) Engine for Financial Reporting.
///
/// Combines the local repository knowledge graph (transactions, reminders, budgets)
/// and conversational history to generate natural spoken responses and rich markdown summaries.
class FinancialReportRagEngine {
  final FinancialRepository repository;

  FinancialReportRagEngine({required this.repository});

  /// "quem está me devendo?", "quem me deve?" and also "alguém tá me
  /// devendo?" / "tem alguém me devendo?" — the last ones used to become a
  /// loan draft ("cobrar o ele").
  static final RegExp _debtorsQuestion = RegExp(
    r'(?:quem|quais\s+pessoas?|algu[ée]m)\s+(?:(?:est[áa]|t[áa])\s+)?(?:me\s+)?devendo|(?:quem|algu[ée]m)\s+(?:ainda\s+)?me\s+deve\b|'
    r'quem\s+eu\s+deveria\s+cobrar|quem\s+tem\s+que\s+me\s+pagar|quem\s+vai\s+me\s+pagar|tem\s+algu[ée]m\s+(?:que\s+)?(?:me\s+)?dev(?:e|endo)',
  );

  /// Identifies if a user prompt is an analytical/reporting query rather than a simple transaction creation.
  static bool isReportQuery(String text) {
    final lower = text.toLowerCase().trim();

    // Debtor patterns
    if (_debtorsQuestion.hasMatch(lower)) {
      return true;
    }

    // Spending patterns
    if (RegExp(r'(?:quanto|qto|qnto)(?:\s+eu|\s+já|\s+que\s+eu|\s+q\s+eu)?\s+gastei|(?:quanto|qto|qnto)\s+foi\s+gasto|total\s+de\s+gastos\s+com|despesas\s+com\s+|gastos\s+com\s+').hasMatch(lower)) {
      return true;
    }

    // Bill due patterns
    if (RegExp(r'(?:quais|qual|que)\s+(?:boletos?|contas?)(?:\s+(?:ou|e)\s+(?:boletos?|contas?))?\s+(?:tenho|est[ãa]o|vencem?|vence|para\s+vencer|pra\s+vencer)|o\s+que\s+(?:tenho|tem)\s+para\s+pagar|boletos?\s+(?:a\s+vencer|da\s+semana|deste\s+m[êe]s)').hasMatch(lower)) {
      return true;
    }

    // Overview patterns
    if (RegExp(r'(?:como\s+(?:est[ãa]o|est[áa]|t[ãa]o|t[áa])|qual\s+[ée]\s+o\s+resumo|resumo\s+geral|situa[çc][ãa]o\s+geral)\s+(?:das?\s+)?minhas?\s+finan[çc]as|quanto\s+sobrou|meu\s+saldo\s+geral').hasMatch(lower)) {
      return true;
    }

    // Month-over-month comparison / trend patterns
    if (RegExp(r'compar(?:ado|ando|a[çc][ãa]o)?\s+(?:com|ao|do)\s+m[êe]s\s+passado|'
            r'(?:mais|menos)\s+que\s+(?:o\s+)?m[êe]s\s+passado|tend[êe]ncia\s+de\s+gastos')
        .hasMatch(lower)) {
      return true;
    }

    // Context questions
    if (RegExp(r'o\s+que\s+eu\s+acabei\s+de\s+falar|o\s+que\s+conversamos\s+antes').hasMatch(lower)) {
      return true;
    }

    // Chart-flavored variants that don't match the phrasings above verbatim, e.g.
    // "me mostra um gráfico dos meus gastos" or "gráfico de quem está me devendo".
    if (wantsChart(lower) && _reportDomainKeywords.hasMatch(lower)) {
      return true;
    }

    return false;
  }

  /// A query asks for a visual chart when it mentions any of these terms.
  /// "pizza" alone is food ("a carla me deve 75 da pizza" was read as a
  /// debtors report, R2-CONV-014); only "em (forma de) pizza" is a chart.
  static bool wantsChart(String text) {
    return RegExp(r'gr[áa]fico|gr[áa]fica|em\s+forma\s+de\s+pizza|\bem\s+pizza\b|plot(?:ar|e)?|visualiza[çc][ãa]o').hasMatch(text.toLowerCase());
  }

  static final RegExp _reportDomainKeywords =
      RegExp(r'gast|despes|categoria|deve|devendo|cobran|emprestim|boleto|conta|finan[çc]|resumo|saldo');

  /// Classifies the report intent from the query text.
  ReportIntent classifyIntent(String text) {
    final lower = text.toLowerCase().trim();

    if (_debtorsQuestion.hasMatch(lower)) {
      return ReportIntent.debtors;
    }
    if (RegExp(r'(?:quanto|qto|qnto)(?:\s+eu|\s+já|\s+que\s+eu|\s+q\s+eu)?\s+gastei|(?:quanto|qto|qnto)\s+foi\s+gasto|total\s+de\s+gastos\s+com|despesas\s+com\s+|gastos\s+com\s+').hasMatch(lower)) {
      return ReportIntent.spending;
    }
    if (RegExp(r'(?:quais|qual|que)\s+(?:boletos?|contas?)(?:\s+(?:ou|e)\s+(?:boletos?|contas?))?|o\s+que\s+(?:tenho|tem)\s+para\s+pagar|boletos?\s+(?:a\s+vencer|da\s+semana|deste\s+m[êe]s)').hasMatch(lower)) {
      return ReportIntent.bills;
    }
    if (RegExp(r'como\s+(?:est[ãa]o|est[áa]|t[ãa]o|t[áa])\s+(?:das?\s+)?minhas?\s+finan[çc]as|resumo\s+geral|quanto\s+sobrou|meu\s+saldo|'
            r'compar(?:ado|ando|a[çc][ãa]o)?\s+(?:com|ao|do)\s+m[êe]s\s+passado|'
            r'(?:mais|menos)\s+que\s+(?:o\s+)?m[êe]s\s+passado|tend[êe]ncia\s+de\s+gastos')
        .hasMatch(lower)) {
      return ReportIntent.overview;
    }
    if (RegExp(r'o\s+que\s+eu\s+acabei\s+de\s+falar|o\s+que\s+conversamos').hasMatch(lower)) {
      return ReportIntent.conversationHistory;
    }

    // Fallback for chart-flavored phrasings that didn't match a specific pattern above
    // (e.g. "me mostra um gráfico dos meus gastos" has no "gastos com X" or "quanto gastei").
    if (wantsChart(lower)) {
      if (RegExp(r'deve|devendo|cobran|emprestim').hasMatch(lower)) return ReportIntent.debtors;
      if (RegExp(r'boleto|conta').hasMatch(lower)) return ReportIntent.bills;
      if (RegExp(r'finan[çc]|resumo|saldo').hasMatch(lower)) return ReportIntent.overview;
      if (RegExp(r'gast|despes|categoria').hasMatch(lower)) return ReportIntent.spending;
    }

    return ReportIntent.unknown;
  }

  /// Main RAG execution pipeline: retrieves relevant facts, synthesizes spoken response and formatted markdown.
  ReportRagResult generateReport(String query, {List<dynamic>? history}) {
    final intent = classifyIntent(query);
    final dateRange = TemporalDateParser.parse(query);
    final withChart = wantsChart(query);

    switch (intent) {
      case ReportIntent.debtors:
        return _generateDebtorsReport(query, dateRange, withChart);
      case ReportIntent.spending:
        return _generateSpendingReport(query, dateRange, withChart);
      case ReportIntent.bills:
        return _generateBillsReport(query, dateRange, withChart);
      case ReportIntent.overview:
        return _generateOverviewReport(query, dateRange, withChart);
      case ReportIntent.conversationHistory:
        return _generateHistoryReport(query, history);
      case ReportIntent.unknown:
        return _generateFallbackReport(query);
    }
  }

  // ── DEBTORS REPORT ──

  ReportRagResult _generateDebtorsReport(String query, DateRangeResult? dateRange, bool withChart) {
    final allDebtors = repository.getActiveDebtors();
    final filteredDebtors = dateRange != null
        ? repository.getActiveDebtors(start: dateRange.start, end: dateRange.end)
        : allDebtors;

    if (filteredDebtors.isEmpty) {
      final timeMsg = dateRange != null ? ' para ${dateRange.label}' : '';
      if (allDebtors.isNotEmpty && dateRange != null) {
        final totalAll = allDebtors.fold(0.0, (acc, d) => acc + (d.amount ?? 0.0));
        return ReportRagResult(
          intent: ReportIntent.debtors,
          dateRange: dateRange,
          matchedItems: allDebtors,
          spokenText: 'Você não tem cobranças previstas$timeMsg. No geral, você tem ${allDebtors.length} ${allDebtors.length == 1 ? "cobrança pendente" : "cobranças pendentes"} totalizando R\$ ${_formatMoney(totalAll)}.',
          formattedText: '### 🤝 Cobranças Pendentes\n\n'
              'Nenhum pagamento previsto para **${dateRange.label}**.\n\n'
              '**Geral:** ${_buildDebtorsListMarkdown(allDebtors)}',
        );
      }

      return ReportRagResult(
        intent: ReportIntent.debtors,
        dateRange: dateRange,
        matchedItems: const [],
        spokenText: 'Você não tem ninguém te devendo no momento. Todas as suas contas a receber estão zeradas!',
        formattedText: '### 🤝 Cobranças e Empréstimos\n\n'
            '🎉 **Nenhuma cobrança pendente!**\n'
            'Todos os empréstimos e valores a receber estão em dia.',
      );
    }

    final total = filteredDebtors.fold(0.0, (acc, d) => acc + (d.amount ?? 0.0));
    final timeStr = dateRange != null ? ' com previsão para ${dateRange.label}' : '';

    String spoken;
    if (filteredDebtors.length == 1) {
      final d = filteredDebtors.first;
      final name = d.personName ?? d.title;
      spoken = 'O $name está te devendo R\$ ${_formatMoney(d.amount ?? 0.0)}$timeStr.';
    } else {
      final names = filteredDebtors.map((d) => d.personName ?? d.title).take(3).join(', ');
      spoken = 'Você tem ${filteredDebtors.length} pessoas te devendo$timeStr, totalizando R\$ ${_formatMoney(total)}. Destaque para $names.';
    }

    final formatted = StringBuffer();
    formatted.writeln('### 🤝 Relatório de Cobranças');
    if (dateRange != null) {
      formatted.writeln('**Período:** ${dateRange.label}\n');
    }
    formatted.writeln('**Total a receber:** `R\$ ${_formatMoney(total)}`\n');
    formatted.writeln(_buildDebtorsListMarkdown(filteredDebtors));

    ReportChartData? chart;
    if (withChart) {
      final byPerson = <String, double>{};
      for (final d in filteredDebtors) {
        final name = d.personName ?? d.title;
        byPerson[name] = (byPerson[name] ?? 0) + (d.amount ?? 0.0);
      }
      final bars = byPerson.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      chart = ReportChartData.bars(bars);
    }

    return ReportRagResult(
      intent: ReportIntent.debtors,
      dateRange: dateRange,
      matchedItems: filteredDebtors,
      spokenText: spoken,
      formattedText: formatted.toString(),
      chart: chart,
    );
  }

  String _buildDebtorsListMarkdown(List<FinancialReminder> debtors) {
    final sb = StringBuffer();
    for (final d in debtors) {
      final name = d.personName ?? d.title;
      final amount = d.amount != null ? 'R\$ ${_formatMoney(d.amount!)}' : 'Valor a definir';
      final dateStr = '${d.targetDate.day.toString().padLeft(2, '0')}/${d.targetDate.month.toString().padLeft(2, '0')}/${d.targetDate.year}';
      sb.writeln('- **$name**: $amount *(previsão: $dateStr)*${d.notes != null ? " - ${d.notes}" : ""}');
    }
    return sb.toString();
  }

  // ── SPENDING REPORT ──

  ReportRagResult _generateSpendingReport(String query, DateRangeResult? dateRange, bool withChart) {
    final term = _extractCategoryOrMerchant(query);
    final displayTerm = term.isEmpty ? 'despesas gerais' : term;
    final effectiveRange = dateRange ?? TemporalDateParser.parse('este mês')!;

    final matches = repository.getSpendingByCategoryOrTerm(
      term,
      start: effectiveRange.start,
      end: effectiveRange.end,
    );

    final totalSpent = matches.fold(0.0, (acc, tx) => acc + tx.amount);
    final periodLabel = effectiveRange.label;

    if (matches.isEmpty) {
      final spoken = term.isEmpty
          ? 'Você não teve nenhum gasto registrado $periodLabel.'
          : 'Você não teve nenhum gasto registrado com $term $periodLabel.';
      final formatted = '### 💳 Relatório de Gastos: $displayTerm\n\n'
          '**Período:** $periodLabel\n'
          '**Total gasto:** `R\$ 0,00`\n\n'
          'Nenhuma despesa correspondente encontrada no período.';
      return ReportRagResult(
        intent: ReportIntent.spending,
        dateRange: effectiveRange,
        matchedItems: const [],
        spokenText: spoken,
        formattedText: formatted,
      );
    }

    final count = matches.length;
    final avg = totalSpent / count;

    // Check budget if matching a known, specifically-named category (skip for the generic "all expenses" query)
    final budget = term.isEmpty
        ? null
        : repository.budgets.cast<dynamic>().firstWhere(
            (b) => b.category.toLowerCase() == term.toLowerCase() || b.name.toLowerCase().contains(term.toLowerCase()),
            orElse: () => null,
          );

    String budgetNote = '';
    if (budget != null) {
      final percent = ((totalSpent / budget.monthlyLimit) * 100).toStringAsFixed(0);
      budgetNote = ' Isso representa $percent% do seu orçamento mensal definido para ${budget.name}.';
    }

    final spoken = 'Você gastou um total de R\$ ${_formatMoney(totalSpent)} com $displayTerm $periodLabel em $count ${count == 1 ? "compra" : "compras"}.$budgetNote';

    final formatted = StringBuffer();
    formatted.writeln('### 💳 Relatório de Gastos: ${displayTerm.toUpperCase()}');
    formatted.writeln('**Período:** $periodLabel');
    formatted.writeln('**Total gasto:** `R\$ ${_formatMoney(totalSpent)}`');
    formatted.writeln('**Quantidade de compras:** $count | **Média:** R\$ ${_formatMoney(avg)}');

    if (budget != null) {
      final percent = ((totalSpent / budget.monthlyLimit) * 100).clamp(0, 100).toInt();
      formatted.writeln('\n**Limite do Orçamento:** R\$ ${_formatMoney(budget.monthlyLimit)} ($percent% consumido)');
    }

    formatted.writeln('\n#### Transações:');
    for (final tx in matches) {
      final dStr = '${tx.date.day.toString().padLeft(2, '0')}/${tx.date.month.toString().padLeft(2, '0')}';
      formatted.writeln('- **$dStr**: ${tx.title} — `R\$ ${_formatMoney(tx.amount)}` (${tx.paymentMethod})');
    }

    ReportChartData? chart;
    if (withChart) {
      final byCategory = <String, double>{};
      for (final tx in matches) {
        byCategory[tx.category] = (byCategory[tx.category] ?? 0) + tx.amount;
      }
      chart = ReportChartData.category(byCategory);
    }

    return ReportRagResult(
      intent: ReportIntent.spending,
      dateRange: effectiveRange,
      matchedItems: matches,
      spokenText: spoken,
      formattedText: formatted.toString(),
      chart: chart,
    );
  }

  String _extractCategoryOrMerchant(String query) {
    final lower = query.toLowerCase();

    // Match phrases like "gastei com ifood", "gastei no carrefour", "gastos com mercado"
    // The term may end the question: "quanto gastei com alimentação?" (the
    // "?" used to hide it and the answer was the grand total).
    final m = RegExp(r'(?:com|no|na|em|de)\s+([a-zA-ZÀ-ÿ0-9_\-\s]+?)(?:\s+(?:esse|este|neste|nessa|essa|esta|semana|m[êe]s|hoje|ontem)\b|\s*[?.!]*\s*$)').firstMatch(lower);
    if (m != null) {
      final raw = m.group(1)!.trim();
      if (raw.isNotEmpty && raw != 'o' && raw != 'a') {
        return raw;
      }
    }

    // Common known keywords
    final keywords = ['ifood', 'mercado', 'supermercado', 'uber', 'farmácia', 'aluguel', 'lazer', 'academia', 'combustível', 'transporte', 'saúde', 'educação'];
    for (final kw in keywords) {
      if (lower.contains(kw)) {
        return kw;
      }
    }

    // No specific category/merchant named — empty means "all expenses", not a literal filter term.
    return '';
  }

  // ── BILLS REPORT ──

  ReportRagResult _generateBillsReport(String query, DateRangeResult? dateRange, bool withChart) {
    final effectiveRange = dateRange ?? TemporalDateParser.parse('esta semana')!;
    final bills = repository.getUpcomingBills(
      start: effectiveRange.start,
      end: effectiveRange.end,
    );

    if (bills.isEmpty) {
      final spoken = 'Você não tem nenhum boleto para pagar ${effectiveRange.label}. Suas contas estão em dia!';
      final formatted = '### 📄 Boletos & Contas a Pagar\n\n'
          '**Período:** ${effectiveRange.label}\n\n'
          '🎉 **Nenhum boleto encontrado no período!**\n'
          'Todas as suas contas para ${effectiveRange.label} estão quitadas ou agendadas.';
      return ReportRagResult(
        intent: ReportIntent.bills,
        dateRange: effectiveRange,
        matchedItems: const [],
        spokenText: spoken,
        formattedText: formatted,
      );
    }

    final total = bills.fold(0.0, (acc, b) => acc + ((b['amount'] as num?)?.toDouble() ?? 0.0));
    final count = bills.length;

    final firstBill = bills.first;
    final firstTitle = firstBill['title'];
    final firstAmount = (firstBill['amount'] as num?)?.toDouble() ?? 0.0;

    String spoken = 'Você tem $count ${count == 1 ? "boleto" : "boletos"} para pagar ${effectiveRange.label}, totalizando R\$ ${_formatMoney(total)}.';
    if (count > 0 && firstAmount > 0) {
      spoken += ' O principal é o $firstTitle no valor de R\$ ${_formatMoney(firstAmount)}.';
    }

    final formatted = StringBuffer();
    formatted.writeln('### 📄 Boletos & Contas a Pagar');
    formatted.writeln('**Período:** ${effectiveRange.label}');
    formatted.writeln('**Total a pagar:** `R\$ ${_formatMoney(total)}`\n');

    for (final b in bills) {
      final title = b['title'];
      final amount = (b['amount'] as num?)?.toDouble() ?? 0.0;
      final due = b['dueDate'] as DateTime;
      final dueStr = '${due.day.toString().padLeft(2, '0')}/${due.month.toString().padLeft(2, '0')}';
      final margin = b['paymentMarginDays'] as int?;
      final billingDay = b['billingDay'] as int?;

      formatted.write('- **$title**: `R\$ ${_formatMoney(amount)}` — Vence em **$dueStr**');
      if (billingDay != null && margin != null) {
        formatted.write(' *(Cai dia $billingDay, margem de $margin ${margin == 1 ? "dia" : "dias"} para pagar)*');
      }
      formatted.writeln();
    }

    ReportChartData? chart;
    if (withChart) {
      final bars = bills
          .map((b) => MapEntry(b['title'] as String, ((b['amount'] as num?)?.toDouble() ?? 0.0)))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      chart = ReportChartData.bars(bars);
    }

    return ReportRagResult(
      intent: ReportIntent.bills,
      dateRange: effectiveRange,
      matchedItems: bills,
      spokenText: spoken,
      formattedText: formatted.toString(),
      chart: chart,
    );
  }

  // ── OVERVIEW REPORT ──

  ReportRagResult _generateOverviewReport(String query, DateRangeResult? dateRange, bool withChart) {
    final income = repository.monthIncome;
    final expense = repository.monthExpense;
    final balance = repository.totalBalance;
    final debtors = repository.getActiveDebtors();
    final totalReceivable = debtors.fold(0.0, (acc, d) => acc + (d.amount ?? 0.0));
    final momChange = repository.monthOverMonthExpenseChange;

    String trendSpoken = '';
    String trendFormatted = '';
    if (momChange != null) {
      final absPercent = momChange.abs().toStringAsFixed(0);
      if (momChange > 1) {
        trendSpoken = ' Isso é $absPercent% a mais do que no mês passado.';
        trendFormatted = '- **Tendência:** 📈 $absPercent% a mais que o mês passado\n';
      } else if (momChange < -1) {
        trendSpoken = ' Isso é $absPercent% a menos do que no mês passado.';
        trendFormatted = '- **Tendência:** 📉 $absPercent% a menos que o mês passado\n';
      } else {
        trendSpoken = ' Isso é praticamente igual ao mês passado.';
        trendFormatted = '- **Tendência:** ➡️ estável em relação ao mês passado\n';
      }
    }

    final spoken = 'Seu saldo geral atual é de R\$ ${_formatMoney(balance)}. Este mês você recebeu R\$ ${_formatMoney(income)} e gastou R\$ ${_formatMoney(expense)}.$trendSpoken Você ainda tem R\$ ${_formatMoney(totalReceivable)} a receber.';

    final formatted = StringBuffer();
    formatted.writeln('### 📊 Resumo Financeiro Geral');
    formatted.writeln('- **Saldo Geral em Conta:** `R\$ ${_formatMoney(balance)}`');
    formatted.writeln('- **Receitas deste Mês:** `+ R\$ ${_formatMoney(income)}`');
    formatted.writeln('- **Despesas deste Mês:** `- R\$ ${_formatMoney(expense)}`');
    formatted.write(trendFormatted);
    formatted.writeln('- **A Receber (Empréstimos):** `R\$ ${_formatMoney(totalReceivable)}`');
    formatted.writeln('\n${repository.generateAiInsight()}');

    final chart = withChart
        ? ReportChartData.bars([
            MapEntry('Receitas', income),
            MapEntry('Despesas', expense),
            MapEntry('A Receber', totalReceivable),
            MapEntry('Saldo', balance),
          ])
        : null;

    return ReportRagResult(
      intent: ReportIntent.overview,
      dateRange: dateRange,
      matchedItems: repository.transactions,
      spokenText: spoken,
      formattedText: formatted.toString(),
      chart: chart,
    );
  }

  // ── CONVERSATION HISTORY RAG ──

  ReportRagResult _generateHistoryReport(String query, List<dynamic>? history) {
    if (history == null || history.isEmpty) {
      return const ReportRagResult(
        intent: ReportIntent.conversationHistory,
        spokenText: 'Não encontrei mensagens anteriores na nossa conversa recente.',
        formattedText: 'Nenhum histórico de mensagens encontrado.',
      );
    }

    // Find last user message before this one
    final lastMessages = history.reversed.take(4).toList();
    final sb = StringBuffer();
    sb.writeln('### 💬 Histórico Recente da Conversa\n');
    for (final msg in lastMessages) {
      final isUser = msg.runtimeType.toString().contains('ChatMessage') && (msg as dynamic).isUser == true;
      final text = (msg as dynamic).text as String;
      sb.writeln('- **${isUser ? "Você" : "César (IA)"}**: $text');
    }

    return ReportRagResult(
      intent: ReportIntent.conversationHistory,
      spokenText: 'Aqui está o resumo das últimas mensagens trocadas na nossa conversa.',
      formattedText: sb.toString(),
    );
  }

  ReportRagResult _generateFallbackReport(String query) {
    return ReportRagResult(
      intent: ReportIntent.unknown,
      spokenText: 'Desculpe, não consegui gerar esse relatório específico. Tente perguntar quem está te devendo, quanto você gastou com alguma categoria, ou quais boletos vencem essa semana.',
      formattedText: '❓ Não foi possível identificar o tipo de relatório solicitado.\n\n'
          'Exemplos aceitos:\n'
          '- *"Quem está me devendo essa semana?"*\n'
          '- *"Quanto eu gastei com mercado este mês?"*\n'
          '- *"Quais boletos vencem essa semana?"*\n'
          '- *"Como estão minhas finanças no geral?"*',
    );
  }

  String _formatMoney(double value) {
    final parts = value.toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]}.',
    );
    return '$intPart,${parts[1]}';
  }
}
