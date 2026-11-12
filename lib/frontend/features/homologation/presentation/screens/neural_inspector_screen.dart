import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../ai/local_nlp_engine.dart';
import '../../../../../backend/services/calendar_service.dart';
import '../../../../../backend/services/money.dart';
import '../../../../theme/krezio_theme.dart';

/// Explainable AI (XAI) & MLOps On-Device Pipeline Inspector for Homologation.
/// Exposes pre-processing/typo correction, TF-IDF vectorization & OOV rate,
/// linear Softmax weights/contributions (`w * tfidf`), calibration metrics
/// (margin & normalized entropy), rule-override diffs, and golden benchmarks.
class NeuralInspectorScreen extends StatefulWidget {
  final LocalFinancialNlpEngine engine;
  final String? initialQuery;
  final bool isDark;

  const NeuralInspectorScreen({
    super.key,
    required this.engine,
    this.initialQuery,
    this.isDark = true,
  });

  @override
  State<NeuralInspectorScreen> createState() => _NeuralInspectorScreenState();
}

class _GoldenCase {
  final String phrase;
  final String tag;
  final String expectedIntent;
  final bool Function(NeuralThoughtTrace trace) check;

  const _GoldenCase({
    required this.phrase,
    required this.tag,
    required this.expectedIntent,
    required this.check,
  });
}

class _BenchmarkRow {
  final _GoldenCase testCase;
  final NeuralThoughtTrace trace;
  final bool passed;

  const _BenchmarkRow({
    required this.testCase,
    required this.trace,
    required this.passed,
  });
}

class _NeuralInspectorScreenState extends State<NeuralInspectorScreen>
    with SingleTickerProviderStateMixin {
  late TextEditingController _textController;
  late AnimationController _pulseController;
  NeuralThoughtTrace? _currentTrace;
  List<_BenchmarkRow>? _benchmarkResults;

  int _selectedTab = 0;

  static const List<String> _quickTestCases = [
    'César, quem é você?',
    'cesar, enprestei dinheiro pro joão, ele disse que quando o salário dele cair ele me paga',
    'meu salrio cai todo dia 05, quero que automaticamente todo dia 05 vc adicione esse valor a nosso plano',
    'lembrar dos dividentos da mxrf 11 no dia 15',
    'asinei a netflx de 55 no cartao credito',
    'assinei o plano anual da alura de 1200 no credito em 12x',
    'assinei o duolingo anual de 360 no credito',
    'minha academia de 120 no crédito vence todo dia 10',
    'comprei um notebook de 4000 no credito em 10x',
    'gastei 150 no mercado no debito e 35 no uber no pix',
  ];

  static final List<_GoldenCase> _goldenSuite = [
    _GoldenCase(
      phrase: 'assinei a netflix de 55 no credito',
      tag: 'Assinatura Mensal 1x',
      expectedIntent: 'expense',
      check: (t) =>
          t.draft.intent == 'expense' &&
          t.installmentDecision.isExempt &&
          t.installmentDecision.installments == 1 &&
          t.isComplete,
    ),
    _GoldenCase(
      phrase: 'asinei a netflx de 55 no cartao credito',
      tag: 'Typo + Mensal 1x',
      expectedIntent: 'expense',
      check: (t) =>
          t.draft.intent == 'expense' &&
          t.typoFixes.isNotEmpty &&
          t.installmentDecision.isExempt &&
          t.parsedAmount == 55.0,
    ),
    _GoldenCase(
      phrase: 'assinei o duolingo anual de 360 no credito',
      tag: 'Anual (Desambiguação)',
      expectedIntent: 'expense',
      check: (t) =>
          t.draft.intent == 'expense' &&
          t.installmentDecision.isAnnual &&
          t.missingSlots.contains('installments'),
    ),
    _GoldenCase(
      phrase: 'assinei o plano anual da alura de 1200 no credito em 12x',
      tag: 'Anual Parcelada 12x',
      expectedIntent: 'expense',
      check: (t) =>
          t.draft.intent == 'expense' &&
          t.installmentDecision.isAnnual &&
          t.draft.installments == 12 &&
          t.isComplete,
    ),
    _GoldenCase(
      phrase: 'comprei um notebook de 4000 no credito em 10x',
      tag: 'Crédito 10x',
      expectedIntent: 'expense',
      check: (t) =>
          t.draft.intent == 'expense' &&
          t.draft.paymentMethod == 'credit_card' &&
          t.draft.installments == 10 &&
          t.parsedAmount == 4000.0 &&
          t.isComplete,
    ),
    _GoldenCase(
      phrase: 'gastei 85 no mercadp no pix ontem',
      tag: 'Typo + Pix + Ontem',
      expectedIntent: 'expense',
      check: (t) =>
          t.draft.intent == 'expense' &&
          t.draft.category == 'supermarket' &&
          t.draft.paymentMethod == 'pix' &&
          t.dateOffsetDays == -1 &&
          t.isComplete,
    ),
    _GoldenCase(
      phrase: 'recebi 4500 de salario no pix',
      tag: 'Receita Salário',
      expectedIntent: 'income',
      check: (t) =>
          t.draft.intent == 'income' &&
          t.draft.category == 'salary' &&
          t.parsedAmount == 4500.0 &&
          t.isComplete,
    ),
    _GoldenCase(
      phrase: 'cesar, enprestei dinheiro pro joão, ele disse que quando o salário dele cair ele me paga',
      tag: 'Empréstimo + Calendário',
      expectedIntent: 'reminder',
      check: (t) => t.draft.isReminder && t.dueDay == null,
    ),
    _GoldenCase(
      phrase: 'meu salrio cai todo dia 05, quero que automaticamente todo dia 05 vc adicione esse valor a nosso plano',
      tag: 'Salário Recorrente',
      expectedIntent: 'income',
      check: (t) =>
          t.draft.intent == 'income' &&
          t.isRecurrent &&
          t.dueDay == 5 &&
          t.missingSlots.contains('amount'),
    ),
    _GoldenCase(
      phrase: 'César, quem é você?',
      tag: 'Identidade (Anti-Aluc.)',
      expectedIntent: 'query',
      check: (t) => t.parsedAmount == null && t.draft.intent != 'expense' && t.draft.intent != 'income',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: widget.initialQuery ?? _quickTestCases.first,
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _runInference(_textController.text);
  }

  @override
  void dispose() {
    _textController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _runInference(String text) {
    if (text.trim().isEmpty) return;
    setState(() {
      _currentTrace = widget.engine.inspect(text);
    });
  }

  void _runBenchmarkSuite() {
    final rows = _goldenSuite.map((gc) {
      final trace = widget.engine.inspect(gc.phrase);
      return _BenchmarkRow(
        testCase: gc,
        trace: trace,
        passed: gc.check(trace),
      );
    }).toList();
    setState(() => _benchmarkResults = rows);
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground;
    final surface = widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final primaryText = widget.isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryText = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    final border = widget.isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: surface,
        elevation: 0,
        titleSpacing: KrezioSpace.sm,
        title: Row(
          children: [
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.xs),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [KrezioColors.aiPurple, Color(0xFF6366F1)],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.hub, color: Colors.white, size: 15),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'NLP PIPELINE',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: KrezioFont.caption,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: KrezioSpace.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm, vertical: KrezioSpace.xs),
              decoration: BoxDecoration(
                color: KrezioColors.friendlyOrange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: KrezioColors.friendlyOrange.withOpacity(0.4),
                  width: 1,
                ),
              ),
              child: const Text(
                'HOMOLOGAÇÃO',
                style: TextStyle(
                  fontSize: KrezioFont.micro,
                  fontWeight: FontWeight.bold,
                  color: KrezioColors.friendlyOrange,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Especificações do Modelo On-Device',
            icon: const Icon(Icons.info_outline, color: KrezioColors.aiPurple),
            onPressed: () => _showEnvironmentDialog(context),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildInputBar(surface, primaryText, secondaryText, border),
          _buildQuickChips(surface, primaryText, secondaryText, border),
          _buildMetricsRibbon(surface, primaryText, secondaryText, border),
          _buildNavigationTabs(surface, primaryText, secondaryText, border),
          Expanded(
            child: _currentTrace == null
                ? const Center(child: CircularProgressIndicator(color: KrezioColors.aiPurple))
                : _buildTabContent(surface, primaryText, secondaryText, border),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(Color surface, Color primaryText, Color secondaryText, Color border) {
    return Container(
      padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.sm, KrezioSpace.lg, KrezioSpace.sm),
      color: surface,
      child: Container(
        decoration: BoxDecoration(
          color: widget.isDark ? const Color(0xFF141414) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: KrezioSpace.md, right: KrezioSpace.sm),
              child: Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 18),
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                style: TextStyle(color: primaryText, fontSize: KrezioFont.body, fontWeight: FontWeight.w500),
                decoration: InputDecoration(
                  hintText: 'Digite ou edite qualquer frase para auditar o NLP...',
                  hintStyle: TextStyle(color: secondaryText, fontSize: KrezioFont.bodySmall),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm),
                ),
                onChanged: _runInference,
                onSubmitted: _runInference,
              ),
            ),
            if (_textController.text.isNotEmpty)
              IconButton(
                tooltip: 'Limpar',
                icon: Icon(Icons.close, size: 18, color: secondaryText),
                onPressed: () {
                  _textController.clear();
                  setState(() {});
                },
              ),
            IconButton(
              tooltip: 'Executar Inferência',
              icon: const Icon(Icons.play_arrow_rounded, color: KrezioColors.emeraldGreen, size: 24),
              onPressed: () => _runInference(_textController.text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickChips(Color surface, Color primaryText, Color secondaryText, Color border) {
    return Container(
      width: double.infinity,
      color: surface,
      padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, 0, KrezioSpace.lg, KrezioSpace.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _quickTestCases.map((phrase) {
            final isSelected = _textController.text.trim() == phrase.trim();
            final lower = phrase.toLowerCase();
            final isAnnualCase = lower.contains('anual');
            final isMonthlySub = lower.contains('netflix') || lower.contains('netflx') || lower.contains('academia');
            final isReminderCase = lower.contains('enprestei') || lower.contains('dividentos');
            Color tagColor = KrezioColors.aiPurple;
            if (isAnnualCase || isReminderCase) tagColor = KrezioColors.friendlyOrange;
            if (isMonthlySub) tagColor = KrezioColors.emeraldGreen;

            return Padding(
              padding: const EdgeInsets.only(right: KrezioSpace.sm),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  _textController.text = phrase;
                  _runInference(phrase);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? tagColor.withOpacity(0.18)
                        : (widget.isDark ? KrezioColors.darkSurfaceVariant : const Color(0xFFF3F4F6)),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected ? tagColor : border,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: tagColor),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        phrase,
                        style: TextStyle(
                          fontSize: KrezioFont.small,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? primaryText : secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildMetricsRibbon(Color surface, Color primaryText, Color secondaryText, Color border) {
    if (_currentTrace == null) return const SizedBox.shrink();
    final trace = _currentTrace!;
    final hitPct = (trace.vocabHitRate * 100).clamp(0.0, 100.0);
    final avgMargin = ((trace.intentModel.margin + trace.categoryModel.margin + trace.paymentModel.margin) / 3 * 100);
    final overrideCount = _overrideCount(trace);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
      decoration: BoxDecoration(
        color: widget.isDark ? const Color(0xFF18181B) : const Color(0xFFF9FAFB),
        border: Border(
          top: BorderSide(color: border),
          bottom: BorderSide(color: border),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildMetricBadge(
              icon: Icons.bolt,
              label: 'Latência',
              value: '${trace.latencyMs.toStringAsFixed(2)} ms',
              color: KrezioColors.emeraldGreen,
            ),
            const SizedBox(width: KrezioSpace.lg),
            _buildMetricBadge(
              icon: Icons.memory,
              label: 'Cobertura TF-IDF',
              value: '${trace.activeFeatures.length} ativas (${hitPct.toStringAsFixed(0)}%)',
              color: hitPct < 40 ? KrezioColors.budgetWarning : KrezioColors.aiPurple,
            ),
            const SizedBox(width: KrezioSpace.lg),
            _buildMetricBadge(
              icon: Icons.stacked_line_chart,
              label: 'Margem Média Δp',
              value: '${avgMargin.toStringAsFixed(0)}%',
              color: avgMargin < 25 ? KrezioColors.budgetWarning : KrezioColors.emeraldGreen,
            ),
            const SizedBox(width: KrezioSpace.lg),
            _buildMetricBadge(
              icon: Icons.alt_route,
              label: 'Overrides Regra',
              value: overrideCount == 0 ? 'Nenhum (ML puro)' : '$overrideCount regra${overrideCount > 1 ? 's' : ''}',
              color: overrideCount > 0 ? KrezioColors.friendlyOrange : KrezioColors.aiPurple,
            ),
            const SizedBox(width: KrezioSpace.lg),
            _buildMetricBadge(
              icon: trace.isComplete ? Icons.check_circle : Icons.pending,
              label: 'Completude',
              value: trace.isComplete ? '100% Completo' : '${trace.missingSlots.length} pendentes',
              color: trace.isComplete ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
            ),
          ],
        ),
      ),
    );
  }

  int _overrideCount(NeuralThoughtTrace t) {
    int count = 0;
    if (t.intentModel.predictedLabel != t.draft.intent) count++;
    if (t.categoryModel.predictedLabel != t.draft.category) count++;
    if (t.paymentModel.predictedLabel != t.draft.paymentMethod) count++;
    return count;
  }

  Widget _buildMetricBadge({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: KrezioFont.micro, color: Colors.grey)),
            Text(
              value,
              style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNavigationTabs(Color surface, Color primaryText, Color secondaryText, Color border) {
    final tabs = [
      {'label': 'Pipeline & Grafo', 'icon': Icons.hub_outlined},
      {'label': 'Softmax & XAI', 'icon': Icons.bar_chart_rounded},
      {'label': 'Slots & Regras', 'icon': Icons.account_tree_outlined},
      {'label': 'Benchmark & Agenda', 'icon': Icons.speed_outlined},
      {'label': 'Trace JSON', 'icon': Icons.code},
    ];

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm),
        child: Row(
          children: tabs.asMap().entries.map((entry) {
            final idx = entry.key;
            final item = entry.value;
            final isSelected = _selectedTab == idx;

            return InkWell(
              onTap: () {
                setState(() => _selectedTab = idx);
                if (idx == 3 && _benchmarkResults == null) {
                  _runBenchmarkSuite();
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.md),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isSelected ? KrezioColors.aiPurple : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      item['icon'] as IconData,
                      size: 16,
                      color: isSelected ? KrezioColors.aiPurple : secondaryText,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      item['label'] as String,
                      style: TextStyle(
                        fontSize: KrezioFont.small,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected ? KrezioColors.aiPurple : secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildTabContent(Color surface, Color primaryText, Color secondaryText, Color border) {
    switch (_selectedTab) {
      case 0:
        return _buildNeuralGraphTab(surface, primaryText, secondaryText, border);
      case 1:
        return _buildClassifiersTab(surface, primaryText, secondaryText, border);
      case 2:
        return _buildDecisionTreeTab(surface, primaryText, secondaryText, border);
      case 3:
        return _buildBenchmarkAndCalendarTab(surface, primaryText, secondaryText, border);
      case 4:
      default:
        return _buildJsonTraceTab(surface, primaryText, secondaryText, border);
    }
  }

  // ── TAB 1: PIPELINE & GRAFO LINEAR PONDERADO ───────────────────────────────

  Widget _buildNeuralGraphTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Padding(
          padding: const EdgeInsets.all(KrezioSpace.lg),
          child: Column(
            children: [
              _buildSubscriptionNoticeBanner(trace, surface, primaryText, border),
              const SizedBox(height: KrezioSpace.md),
              _buildPipelineStageHeader(secondaryText),
              const SizedBox(height: KrezioSpace.xs),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: widget.isDark ? const Color(0xFF131316) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: border),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: CustomPaint(
                      painter: NeuralNetworkPainter(
                        trace: trace,
                        pulseValue: _pulseController.value,
                        isDark: widget.isDark,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: KrezioSpace.sm),
              _buildGraphLegend(secondaryText),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPipelineStageHeader(Color secondaryText) {
    Widget stage(String title) => Expanded(
          child: Text(
            title,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: KrezioFont.micro,
              fontWeight: FontWeight.bold,
              color: secondaryText,
              letterSpacing: 0.4,
            ),
          ),
        );

    return Row(
      children: [
        stage('1. TOKENS'),
        stage('2. TF-IDF'),
        stage('3. SOFTMAX'),
        stage('4. PÓS-REGRA'),
      ],
    );
  }

  Widget _buildGraphLegend(Color secondaryText) {
    Widget dot(Color c, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 10, height: 3, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 4),
            Text(text, style: TextStyle(fontSize: KrezioFont.micro, color: secondaryText)),
          ],
        );

    return Wrap(
      spacing: KrezioSpace.md,
      runSpacing: KrezioSpace.xs,
      alignment: WrapAlignment.center,
      children: [
        dot(KrezioColors.emeraldGreen, 'Peso pró-classe (w·x > 0)'),
        dot(KrezioColors.budgetOver, 'Peso inibidor (w·x < 0)'),
        dot(KrezioColors.friendlyOrange, 'Override por regra'),
      ],
    );
  }

  Widget _buildSubscriptionNoticeBanner(
      NeuralThoughtTrace trace, Color surface, Color primaryText, Color border) {
    final dec = trace.installmentDecision;
    final overrides = _overrideCount(trace);
    Color bannerColor = KrezioColors.aiPurple;
    IconData bannerIcon = Icons.hub_outlined;
    String title = 'Pipeline Linear + Regras Determinísticas';
    String desc = dec.explanation;

    if (trace.intentModel.isZeroVectorFallback) {
      bannerColor = KrezioColors.budgetWarning;
      bannerIcon = Icons.warning_amber_rounded;
      title = 'Zero-Vector Gate Ativado (100% OOV)';
      desc = 'Nenhum n-grama da frase existe no vocabulário TF-IDF. Os classificadores retornaram fallback seguro "unknown".';
    } else if (trace.draft.isReminder) {
      bannerColor = KrezioColors.friendlyOrange;
      bannerIcon = Icons.calendar_month_outlined;
      title = 'Heurística Ativa: Lembrete & Calendário em Tempo Real';
      desc = trace.draft.calendarConsultationNote ??
          'A IA identificou promessa de pagamento futuro e consultou o calendário bancário FEBRABAN (5º dia útil).';
    } else if (dec.isExempt) {
      bannerColor = KrezioColors.emeraldGreen;
      bannerIcon = Icons.verified_user_rounded;
      title = 'Regra de Negócio: Assinatura Mensal no Crédito (1x)';
      desc =
          'Assinatura mensal recorrente detectada. O slot de parcelas foi resolvido automaticamente como 1x sem interromper o usuário.';
    } else if (dec.isAnnual) {
      bannerColor = KrezioColors.friendlyOrange;
      bannerIcon = Icons.event_repeat_rounded;
      title = 'Regra de Negócio: Assinatura Anual no Crédito';
      desc =
          'Plano anual no crédito permite parcelamento em até 12x; o motor verifica se o número de parcelas já foi dito.';
    } else if (overrides > 0) {
      bannerColor = KrezioColors.friendlyOrange;
      bannerIcon = Icons.alt_route;
      title = 'Pós-processamento Aplicou $overrides Override${overrides > 1 ? 's' : ''} sobre o Softmax';
      desc = 'Veja na aba "Softmax & XAI" exatamente qual predição linear foi ajustada por regra contextual, threshold ou categoria do usuário.';
    }

    return Container(
      padding: const EdgeInsets.all(KrezioSpace.md),
      decoration: BoxDecoration(
        color: bannerColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bannerColor.withOpacity(0.35), width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(bannerIcon, color: bannerColor, size: 20),
          const SizedBox(width: KrezioSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.bold, color: bannerColor),
                ),
                const SizedBox(height: KrezioSpace.xs),
                Text(
                  desc,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: KrezioFont.small, color: primaryText.withOpacity(0.88), height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── TAB 2: SOFTMAX, XAI ATTRIBUTION & OOV ──────────────────────────────────

  Widget _buildClassifiersTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;

    return ListView(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      children: [
        _buildMlVsRuleDiffCard(trace, surface, primaryText, secondaryText, border),
        const SizedBox(height: KrezioSpace.lg),
        _buildTokenizationAndOovCard(trace, surface, primaryText, secondaryText, border),
        const SizedBox(height: KrezioSpace.lg),
        _buildClassifierCard(
          title: 'Classificador de Intenção (Intent)',
          modelTrace: trace.intentModel,
          finalLabel: trace.draft.intent,
          threshold: trace.confidenceThreshold,
          accentColor: KrezioColors.aiPurple,
          surface: surface,
          primaryText: primaryText,
          secondaryText: secondaryText,
          border: border,
        ),
        const SizedBox(height: KrezioSpace.lg),
        _buildClassifierCard(
          title: 'Classificador de Categoria (Category)',
          modelTrace: trace.categoryModel,
          finalLabel: trace.draft.category,
          threshold: trace.confidenceThreshold,
          accentColor: KrezioColors.emeraldGreen,
          surface: surface,
          primaryText: primaryText,
          secondaryText: secondaryText,
          border: border,
        ),
        const SizedBox(height: KrezioSpace.lg),
        _buildClassifierCard(
          title: 'Classificador de Meio de Pagamento (Payment)',
          modelTrace: trace.paymentModel,
          finalLabel: trace.draft.paymentMethod,
          threshold: trace.confidenceThreshold,
          accentColor: KrezioColors.friendlyOrange,
          surface: surface,
          primaryText: primaryText,
          secondaryText: secondaryText,
          border: border,
        ),
      ],
    );
  }

  Widget _buildMlVsRuleDiffCard(
    NeuralThoughtTrace trace,
    Color surface,
    Color primaryText,
    Color secondaryText,
    Color border,
  ) {
    Widget diffRow(String dimension, ModelInferenceTrace ml, String resolved, {String? note}) {
      final changed = ml.predictedLabel != resolved;
      final lowConf = !ml.isZeroVectorFallback && ml.confidence < trace.confidenceThreshold;
      final statusColor = changed ? KrezioColors.friendlyOrange : KrezioColors.emeraldGreen;
      final statusText = changed
          ? (note ?? (lowConf ? 'Threshold/Regra' : 'Override Regra'))
          : 'ML Aceito';

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: KrezioSpace.xs),
        child: Row(
          children: [
            SizedBox(
              width: 78,
              child: Text(dimension, style: TextStyle(fontSize: KrezioFont.small, color: secondaryText)),
            ),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${ml.predictedLabel} (${(ml.confidence * 100).toStringAsFixed(0)}%)',
                    style: TextStyle(fontSize: KrezioFont.small, color: primaryText, fontWeight: FontWeight.w500),
                  ),
                  Icon(Icons.arrow_forward, size: 13, color: statusColor),
                  Text(
                    resolved,
                    style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                statusText,
                style: TextStyle(fontSize: KrezioFont.micro, fontWeight: FontWeight.bold, color: statusColor),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.compare_arrows, color: KrezioColors.aiPurple, size: 18),
              const SizedBox(width: KrezioSpace.sm),
              Expanded(
                child: Text(
                  'ML Softmax Bruto vs. Saída Pós-Regras',
                  style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryText),
                ),
              ),
            ],
          ),
          const SizedBox(height: KrezioSpace.sm),
          diffRow('Intenção', trace.intentModel, trace.draft.intent),
          diffRow(
            'Categoria',
            trace.categoryModel,
            trace.draft.category,
            note: trace.matchedCustomCategory != null ? 'Custom Cat' : null,
          ),
          diffRow('Pagamento', trace.paymentModel, trace.draft.paymentMethod),
        ],
      ),
    );
  }

  Widget _buildTokenizationAndOovCard(
    NeuralThoughtTrace trace,
    Color surface,
    Color primaryText,
    Color secondaryText,
    Color border,
  ) {
    final hitPct = (trace.vocabHitRate * 100).clamp(0.0, 100.0);
    final activeSet = trace.activeFeatures.map((f) => f.token).toSet();

    return Container(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.token_outlined, color: KrezioColors.aiPurple, size: 18),
              const SizedBox(width: KrezioSpace.sm),
              Expanded(
                child: Text(
                  'Pré-processamento, Typos & OOV',
                  style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryText),
                ),
              ),
              Text(
                'Vocab: ${trace.vocabSize} feats',
                style: TextStyle(fontSize: KrezioFont.caption, color: secondaryText),
              ),
            ],
          ),
          const SizedBox(height: KrezioSpace.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cobertura de N-gramas (1–2g): ${trace.activeFeatures.length} in-vocab / ${trace.oovNgrams.length} OOV',
                  style: TextStyle(fontSize: KrezioFont.caption, color: secondaryText),
                ),
              ),
              const SizedBox(width: KrezioSpace.sm),
              Text(
                '${hitPct.toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: KrezioFont.caption,
                  fontWeight: FontWeight.bold,
                  color: hitPct < 40 ? KrezioColors.budgetWarning : KrezioColors.emeraldGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: trace.vocabHitRate.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: widget.isDark ? KrezioColors.darkSurfaceVariant : const Color(0xFFE5E7EB),
              valueColor: AlwaysStoppedAnimation<Color>(
                hitPct < 40 ? KrezioColors.budgetWarning : KrezioColors.emeraldGreen,
              ),
            ),
          ),
          if (trace.typoFixes.isNotEmpty) ...[
            const SizedBox(height: KrezioSpace.md),
            Text(
              'Correções Ortográficas Aplicadas:',
              style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.w600, color: KrezioColors.emeraldGreen),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: trace.typoFixes.entries.map((e) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: KrezioColors.emeraldGreen.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: KrezioColors.emeraldGreen.withOpacity(0.35)),
                  ),
                  child: Text(
                    '${e.key} → ${e.value}',
                    style: const TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.w600, color: KrezioColors.emeraldGreen),
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: KrezioSpace.md),
          Text(
            'Tokens Normalizados (Roxo = No Vocabulário | Cinza = OOV):',
            style: TextStyle(fontSize: KrezioFont.caption, color: secondaryText),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in trace.activeFeatures)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: KrezioColors.aiPurple.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: KrezioColors.aiPurple.withOpacity(0.4)),
                  ),
                  child: Text(
                    '${f.token} (${f.value.toStringAsFixed(2)})',
                    style: const TextStyle(fontSize: KrezioFont.micro, fontWeight: FontWeight.w600, color: KrezioColors.aiPurpleLight),
                  ),
                ),
              for (final oov in trace.oovNgrams.take(8))
                if (!activeSet.contains(oov))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: border),
                    ),
                    child: Text(
                      '$oov [OOV]',
                      style: TextStyle(fontSize: KrezioFont.micro, color: secondaryText),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildClassifierCard({
    required String title,
    required ModelInferenceTrace modelTrace,
    required String finalLabel,
    required double threshold,
    required Color accentColor,
    required Color surface,
    required Color primaryText,
    required Color secondaryText,
    required Color border,
  }) {
    final overridden = modelTrace.predictedLabel != finalLabel;
    final lowMargin = modelTrace.margin < 0.25 && !modelTrace.isZeroVectorFallback;
    final belowThreshold = !modelTrace.isZeroVectorFallback && modelTrace.confidence < threshold;

    Widget statPill(String label, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Text(label, style: TextStyle(fontSize: KrezioFont.micro, fontWeight: FontWeight.bold, color: color)),
        );

    return Container(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryText),
                ),
              ),
              const SizedBox(width: KrezioSpace.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm, vertical: KrezioSpace.xs),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${modelTrace.predictedLabel} (${(modelTrace.confidence * 100).toStringAsFixed(1)}%)',
                  style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.bold, color: accentColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: KrezioSpace.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              statPill(
                'Margem Δp: ${(modelTrace.margin * 100).toStringAsFixed(1)}%',
                lowMargin ? KrezioColors.budgetWarning : KrezioColors.emeraldGreen,
              ),
              statPill('Entropia H: ${modelTrace.normalizedEntropy.toStringAsFixed(2)}', secondaryText),
              statPill('Bias b₀: ${modelTrace.bias.toStringAsFixed(2)}', KrezioColors.aiPurple),
              if (modelTrace.isZeroVectorFallback)
                statPill('Zero-Vector Fallback', KrezioColors.budgetWarning)
              else
                statPill(
                  belowThreshold
                      ? '< Threshold (${(threshold * 100).toStringAsFixed(0)}%)'
                      : '≥ Threshold (${(threshold * 100).toStringAsFixed(0)}%)',
                  belowThreshold ? KrezioColors.budgetOver : KrezioColors.emeraldGreen,
                ),
              if (overridden) statPill('Final pós-regra: $finalLabel', KrezioColors.friendlyOrange),
            ],
          ),
          const SizedBox(height: KrezioSpace.md),
          ...modelTrace.probabilities.take(5).map((prob) {
            final isWinner = prob.label == modelTrace.predictedLabel;
            final pct = prob.probability;

            return Padding(
              padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          prob.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: KrezioFont.small,
                            fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
                            color: isWinner ? accentColor : primaryText,
                          ),
                        ),
                      ),
                      const SizedBox(width: KrezioSpace.sm),
                      Text(
                        '${(pct * 100).toStringAsFixed(1)}% · z=${prob.score.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: KrezioFont.caption,
                          color: secondaryText,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: KrezioSpace.xs),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      backgroundColor: widget.isDark ? KrezioColors.darkSurfaceVariant : const Color(0xFFE5E7EB),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        isWinner ? accentColor : secondaryText.withOpacity(0.4),
                      ),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            );
          }),
          if (modelTrace.topContributions.isNotEmpty) ...[
            const Divider(height: KrezioSpace.lg),
            Text(
              'Atribuição por Token (w · TF-IDF para "${modelTrace.predictedLabel}"):',
              style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.w600, color: secondaryText),
            ),
            const SizedBox(height: KrezioSpace.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: modelTrace.topContributions.take(8).map((c) {
                final pos = c.contribution >= 0;
                final col = pos ? KrezioColors.emeraldGreen : KrezioColors.budgetOver;
                final sign = pos ? '+' : '';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: col.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: col.withOpacity(0.35)),
                  ),
                  child: Text(
                    '"${c.token}" $sign${c.contribution.toStringAsFixed(2)} (w=${c.weight.toStringAsFixed(1)})',
                    style: TextStyle(
                      fontSize: KrezioFont.micro,
                      fontWeight: FontWeight.w600,
                      color: col,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  // ── TAB 3: SLOTS & REGRAS ──────────────────────────────────────────────────

  Widget _buildDecisionTreeTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;
    final dec = trace.installmentDecision;

    return ListView(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      children: [
        Container(
          padding: const EdgeInsets.all(KrezioSpace.lg),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.account_tree, color: KrezioColors.aiPurple, size: 20),
                  SizedBox(width: KrezioSpace.sm),
                  Expanded(
                    child: Text(
                      'Árvore de Decisão & Extração de Slots',
                      style: TextStyle(fontSize: KrezioFont.bodyLarge, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.lg),
              _buildSlotAuditItem(
                label: 'Intenção Final (vs Softmax)',
                value: trace.intentModel.predictedLabel == trace.draft.intent
                    ? trace.draft.intent
                    : '${trace.draft.intent} (ML disse ${trace.intentModel.predictedLabel})',
                isSatisfied: trace.draft.intent != 'unknown',
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Descrição Extraída',
                value: trace.extractedDescription.isEmpty ? 'Não identificada' : trace.extractedDescription,
                isSatisfied: trace.extractedDescription.isNotEmpty,
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Valor Monetário (Amount)',
                value: trace.parsedAmount != null ? Money.brl(trace.parsedAmount!) : 'Não identificado',
                isSatisfied: trace.parsedAmount != null && trace.parsedAmount! > 0,
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Deslocamento de Data',
                value: trace.dateOffsetDays == 0
                    ? 'Hoje (offset 0d)'
                    : (trace.dateOffsetDays < 0 ? '${trace.dateOffsetDays} dia(s)' : '+${trace.dateOffsetDays} dia(s)'),
                isSatisfied: true,
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Categoria Resolvida',
                value: trace.matchedCustomCategory != null
                    ? '${trace.draft.category} (custom)'
                    : trace.draft.category,
                isSatisfied: trace.draft.category != 'unknown',
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Forma de Pagamento',
                value: trace.draft.paymentMethod,
                isSatisfied: trace.draft.paymentMethod != 'unknown',
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Recorrência / Assinatura',
                value: trace.isRecurrent
                    ? 'Sim (${trace.frequency ?? 'mensal'}, dia ${trace.dueDay ?? 'N/D'}, ${trace.recurrenceDuration ?? 'contínua'})'
                    : 'Não (pontual)',
                isSatisfied: true,
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Regra de Parcelamento no Crédito',
                value: dec.isExempt
                    ? 'ISENTO (Assinatura Mensal = 1x)'
                    : (dec.isAnnual
                        ? 'PERMITE PARCELAR (Anual = ${dec.installments ?? 'a esclarecer'}x)'
                        : (dec.installments != null
                            ? '${dec.installments}x'
                            : (dec.isCreditCard ? 'Desambiguar parcelas' : 'N/A'))),
                isSatisfied: !trace.missingSlots.contains('installments'),
                highlightColor: dec.isExempt
                    ? KrezioColors.emeraldGreen
                    : (dec.isAnnual ? KrezioColors.friendlyOrange : null),
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Status de Completude:',
                      style: TextStyle(fontWeight: FontWeight.bold, color: primaryText),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.xs),
                    decoration: BoxDecoration(
                      color: trace.isComplete
                          ? KrezioColors.emeraldGreen.withOpacity(0.15)
                          : KrezioColors.friendlyOrange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      trace.isComplete ? 'Pronto para Gravação' : 'Slots Pendentes',
                      style: TextStyle(
                        fontSize: KrezioFont.small,
                        fontWeight: FontWeight.bold,
                        color: trace.isComplete ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
                      ),
                    ),
                  ),
                ],
              ),
              if (trace.missingSlots.isNotEmpty) ...[
                const SizedBox(height: KrezioSpace.sm),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: trace.missingSlots
                      .map((s) => Chip(
                            label: Text('Faltando: $s', style: const TextStyle(fontSize: KrezioFont.caption)),
                            visualDensity: VisualDensity.compact,
                          ))
                      .toList(),
                ),
              ],
              if (trace.clarificationPrompt != null) ...[
                const SizedBox(height: KrezioSpace.md),
                Text('Pergunta Empática Gerada:', style: TextStyle(fontSize: KrezioFont.small, color: secondaryText)),
                const SizedBox(height: KrezioSpace.xs),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(KrezioSpace.md),
                  decoration: BoxDecoration(
                    color: widget.isDark ? KrezioColors.darkSurfaceVariant : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    trace.clarificationPrompt!,
                    style: TextStyle(fontSize: KrezioFont.bodySmall, fontStyle: FontStyle.italic, color: primaryText),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSlotAuditItem({
    required String label,
    required String value,
    required bool isSatisfied,
    Color? highlightColor,
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSatisfied ? Icons.check_circle_rounded : Icons.pending_rounded,
            size: 16,
            color: isSatisfied ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
          ),
          const SizedBox(width: KrezioSpace.sm),
          Expanded(
            flex: 4,
            child: Text(label, style: TextStyle(fontSize: KrezioFont.small, color: secondaryText)),
          ),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: KrezioFont.small,
                fontWeight: FontWeight.w600,
                color: highlightColor ?? (isSatisfied ? primaryText : KrezioColors.friendlyOrange),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── TAB 4: BENCHMARK GOLDEN & CALENDÁRIO FEBRABAN ──────────────────────────

  Widget _buildBenchmarkAndCalendarTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final calendar = widget.engine.calendarService;
    final nextPayday = calendar.getNextSalaryPayday();
    final paydayLabel = RealtimeCalendarService.formatDateLabel(nextPayday);
    final trace = _currentTrace;
    final rows = _benchmarkResults;

    double p50 = 0;
    double p95 = 0;
    double avgHit = 0;
    double avgMargin = 0;
    double overrideRatePct = 0;
    int passedCount = 0;
    int overrideCount = 0;
    int zeroVecCount = 0;
    if (rows != null && rows.isNotEmpty) {
      final latencies = rows.map((r) => r.trace.latencyMs).toList()..sort();
      p50 = latencies[latencies.length ~/ 2];
      p95 = latencies[((latencies.length - 1) * 0.95).round()];
      avgHit = rows.fold<double>(0.0, (s, r) => s + r.trace.vocabHitRate) / rows.length * 100;
      avgMargin = rows.fold<double>(0.0, (s, r) => s + r.trace.intentModel.margin) / rows.length * 100;
      passedCount = rows.where((r) => r.passed).length;
      overrideCount = rows.where((r) => r.trace.intentModel.predictedLabel != r.trace.draft.intent).length;
      zeroVecCount = rows.where((r) => r.trace.intentModel.isZeroVectorFallback).length;
      overrideRatePct = overrideCount / rows.length * 100;
    }

    return ListView(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      children: [
        // 1. Live On-Device Golden Benchmark Card
        Container(
          padding: const EdgeInsets.all(KrezioSpace.lg),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.speed, color: KrezioColors.aiPurple, size: 20),
                  const SizedBox(width: KrezioSpace.sm),
                  Expanded(
                    child: Text(
                      'Benchmark Golden Set On-Device',
                      style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryText),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _runBenchmarkSuite,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Executar'),
                  ),
                ],
              ),
              if (rows != null) ...[
                const SizedBox(height: KrezioSpace.md),
                Row(
                  children: [
                    _benchStat('Pass Rate', '$passedCount/${rows.length}',
                        passedCount == rows.length ? KrezioColors.emeraldGreen : KrezioColors.budgetWarning),
                    const SizedBox(width: KrezioSpace.sm),
                    _benchStat('p50 / p95', '${p50.toStringAsFixed(1)} / ${p95.toStringAsFixed(1)} ms', KrezioColors.aiPurple),
                    const SizedBox(width: KrezioSpace.sm),
                    _benchStat('Cobertura Vocab', '${avgHit.toStringAsFixed(0)}%', KrezioColors.emeraldGreen),
                  ],
                ),
                const SizedBox(height: KrezioSpace.sm),
                Row(
                  children: [
                    _benchStat(
                      'Override Rate',
                      '$overrideCount/${rows.length} (${overrideRatePct.toStringAsFixed(0)}%)',
                      overrideCount == 0 ? KrezioColors.emeraldGreen : KrezioColors.budgetWarning,
                    ),
                    const SizedBox(width: KrezioSpace.sm),
                    _benchStat(
                      'Margem Δp',
                      '${avgMargin.toStringAsFixed(0)}%',
                      avgMargin >= 40 ? KrezioColors.emeraldGreen : KrezioColors.budgetWarning,
                    ),
                    const SizedBox(width: KrezioSpace.sm),
                    _benchStat(
                      'Zero-Vec Rate',
                      '$zeroVecCount/${rows.length}',
                      zeroVecCount == 0 ? KrezioColors.emeraldGreen : KrezioColors.budgetOver,
                    ),
                  ],
                ),
                const SizedBox(height: KrezioSpace.md),
                for (final r in rows) _buildGoldenBenchmarkRow(r, primaryText, secondaryText),
              ],
            ],
          ),
        ),
        const SizedBox(height: KrezioSpace.lg),

        // 2. Status da Consulta da Frase Atual no Calendário
        if (trace != null && trace.draft.isReminder) ...[
          Container(
            padding: const EdgeInsets.all(KrezioSpace.lg),
            decoration: BoxDecoration(
              color: KrezioColors.friendlyOrange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: KrezioColors.friendlyOrange.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.event_available, color: KrezioColors.friendlyOrange, size: 20),
                    SizedBox(width: KrezioSpace.sm),
                    Expanded(
                      child: Text(
                        'Lembrete Agendado pelo Motor IA',
                        style: TextStyle(
                          fontSize: KrezioFont.body,
                          fontWeight: FontWeight.bold,
                          color: KrezioColors.friendlyOrange,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: KrezioSpace.sm),
                Text(
                  trace.draft.calendarConsultationNote ?? 'Lembrete conectado ao 5º dia útil bancário.',
                  style: TextStyle(fontSize: KrezioFont.small, color: primaryText),
                ),
                if (trace.draft.personName != null) ...[
                  const SizedBox(height: KrezioSpace.sm),
                  Text(
                    'Devedor: ${trace.draft.personName} • Data-Alvo: $paydayLabel',
                    style: const TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: KrezioColors.friendlyOrange),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: KrezioSpace.lg),
        ],

        // 3. Previsão de Salário e 5º Dia Útil FEBRABAN
        Container(
          padding: const EdgeInsets.all(KrezioSpace.lg),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.calendar_month, color: KrezioColors.aiPurple, size: 20),
                  SizedBox(width: KrezioSpace.sm),
                  Expanded(
                    child: Text(
                      'Previsão de Salário (5º Dia Útil Bancário)',
                      style: TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.md),
              Text(
                'O motor calcula os dias úteis bancários excluindo finais de semana e feriados nacionais FEBRABAN:',
                style: TextStyle(fontSize: KrezioFont.small, color: secondaryText),
              ),
              const SizedBox(height: KrezioSpace.md),
              Container(
                padding: const EdgeInsets.all(KrezioSpace.md),
                decoration: BoxDecoration(
                  color: KrezioColors.aiPurple.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: KrezioColors.aiPurple.withOpacity(0.2)),
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('Próximo 5º dia útil:', style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.w600))),
                    const SizedBox(width: KrezioSpace.sm),
                    Text(
                      paydayLabel,
                      style: const TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.bold, color: KrezioColors.aiPurple),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KrezioSpace.lg),

        // 4. Eventos & Lembretes no Calendário
        Container(
          padding: const EdgeInsets.all(KrezioSpace.lg),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Eventos & Lembretes no Calendário',
                      style: TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text('${calendar.events.length} eventos', style: TextStyle(fontSize: KrezioFont.caption, color: secondaryText)),
                ],
              ),
              const SizedBox(height: KrezioSpace.md),
              ...calendar.events.map((ev) {
                final dateStr = RealtimeCalendarService.formatDateLabel(ev.dateTime);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm),
                  child: Row(
                    children: [
                      Icon(
                        ev.category == CalendarEventCategory.loanReceivable
                            ? Icons.handshake_outlined
                            : (ev.category == CalendarEventCategory.salary ? Icons.payments_outlined : Icons.trending_up),
                        size: 16,
                        color: KrezioColors.friendlyOrange,
                      ),
                      const SizedBox(width: KrezioSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(ev.title, style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.w600, color: primaryText)),
                            if (ev.notes != null) Text(ev.notes!, style: TextStyle(fontSize: KrezioFont.micro, color: secondaryText)),
                          ],
                        ),
                      ),
                      const SizedBox(width: KrezioSpace.sm),
                      Text(dateStr, style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.w500, color: secondaryText)),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGoldenBenchmarkRow(_BenchmarkRow r, Color primaryText, Color secondaryText) {
    final overrode = r.trace.intentModel.predictedLabel != r.trace.draft.intent;
    final confPct = (r.trace.intentModel.confidence * 100).toStringAsFixed(0);
    final marginPct = (r.trace.intentModel.margin * 100).toStringAsFixed(0);
    final flywheelLabel = overrode
        ? 'Override (${r.trace.intentModel.predictedLabel}→${r.trace.draft.intent}) • ML $confPct% • Δp $marginPct%'
        : 'ML=Final ($confPct%) • Δp $marginPct%';

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        _textController.text = r.testCase.phrase;
        _runInference(r.testCase.phrase);
        setState(() => _selectedTab = 0);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              r.passed ? Icons.check_circle : Icons.error_outline,
              size: 16,
              color: r.passed ? KrezioColors.emeraldGreen : KrezioColors.budgetOver,
            ),
            const SizedBox(width: KrezioSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.testCase.tag,
                    style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: primaryText),
                  ),
                  Text(
                    r.testCase.phrase,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: KrezioFont.micro, color: secondaryText),
                  ),
                  Text(
                    flywheelLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: KrezioFont.micro,
                      color: overrode ? KrezioColors.budgetWarning : secondaryText,
                      fontWeight: overrode ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: KrezioSpace.sm),
            Text(
              '${r.trace.latencyMs.toStringAsFixed(1)} ms',
              style: TextStyle(fontSize: KrezioFont.caption, color: secondaryText),
            ),
          ],
        ),
      ),
    );
  }

  Widget _benchStat(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: KrezioFont.micro, color: Colors.grey),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: color)),
            ),
          ],
        ),
      ),
    );
  }

  // ── TAB 5: TRACE JSON VÁLIDO & COPIÁVEL ────────────────────────────────────

  Map<String, dynamic> _traceAsMap(NeuralThoughtTrace trace) {
    Map<String, dynamic> modelJson(ModelInferenceTrace m, String resolved) => {
          'predicted': m.predictedLabel,
          'resolved_after_rules': resolved,
          'overridden_by_rule': m.predictedLabel != resolved,
          'confidence': double.parse(m.confidence.toStringAsFixed(4)),
          'margin_p1_p2': double.parse(m.margin.toStringAsFixed(4)),
          'normalized_entropy': double.parse(m.normalizedEntropy.toStringAsFixed(4)),
          'bias': double.parse(m.bias.toStringAsFixed(4)),
          'is_zero_vector_fallback': m.isZeroVectorFallback,
          'top_probabilities': m.probabilities
              .take(5)
              .map((p) => {
                    'label': p.label,
                    'probability': double.parse(p.probability.toStringAsFixed(4)),
                    'logit': double.parse(p.score.toStringAsFixed(4)),
                  })
              .toList(),
          'feature_contributions': m.topContributions
              .map((c) => {
                    'token': c.token,
                    'weight': double.parse(c.weight.toStringAsFixed(4)),
                    'tfidf': double.parse(c.tfidf.toStringAsFixed(4)),
                    'contribution': double.parse(c.contribution.toStringAsFixed(4)),
                  })
              .toList(),
        };

    return {
      'model_metadata': {
        'architecture': 'TF-IDF (1-2 ngrams) + 3x Linear Logistic Regression Softmax + Deterministic Slot Rules',
        'vocab_size': trace.vocabSize,
        'confidence_threshold': trace.confidenceThreshold,
      },
      'latency_ms': double.parse(trace.latencyMs.toStringAsFixed(3)),
      'preprocessing': {
        'raw_text': trace.rawText,
        'normalized_text': trace.normalizedText,
        'raw_tokens': trace.rawTokens,
        'normalized_tokens': trace.normalizedTokens,
        'typo_fixes': trace.typoFixes,
        'ngrams': trace.ngrams,
        'oov_ngrams': trace.oovNgrams,
        'vocab_hit_rate': double.parse(trace.vocabHitRate.toStringAsFixed(4)),
      },
      'active_features': trace.activeFeatures
          .map((f) => {
                'token': f.token,
                'index': f.index,
                'tf': double.parse(f.tf.toStringAsFixed(4)),
                'idf': double.parse(f.idf.toStringAsFixed(4)),
                'tfidf': double.parse(f.value.toStringAsFixed(4)),
              })
          .toList(),
      'classifiers': {
        'intent': modelJson(trace.intentModel, trace.draft.intent),
        'category': modelJson(trace.categoryModel, trace.draft.category),
        'payment_method': modelJson(trace.paymentModel, trace.draft.paymentMethod),
      },
      'installment_decision': {
        'is_credit_card': trace.installmentDecision.isCreditCard,
        'is_subscription': trace.installmentDecision.isSubscription,
        'is_annual': trace.installmentDecision.isAnnual,
        'is_exempt_from_installments': trace.installmentDecision.isExempt,
        'installments': trace.installmentDecision.installments,
        'explanation': trace.installmentDecision.explanation,
      },
      'final_draft': {
        'intent': trace.draft.intent,
        'description': trace.extractedDescription,
        'amount': trace.parsedAmount,
        'category': trace.draft.category,
        'matched_custom_category': trace.matchedCustomCategory,
        'payment_method': trace.draft.paymentMethod,
        'date_offset_days': trace.dateOffsetDays,
        'is_recurrent': trace.isRecurrent,
        'due_day': trace.dueDay,
        'missing_slots': trace.missingSlots,
        'is_complete': trace.isComplete,
        'clarification_prompt': trace.clarificationPrompt,
      },
    };
  }

  Widget _buildJsonTraceTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;
    final prettyJson = const JsonEncoder.withIndent('  ').convert(_traceAsMap(trace));

    return Padding(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Payload Telemetria JSON (RFC 8259 válido)',
                  style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: secondaryText),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: prettyJson));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Trace JSON copiado para a área de transferência.')),
                  );
                },
                icon: const Icon(Icons.copy, size: 15),
                label: const Text('Copiar JSON'),
              ),
            ],
          ),
          const SizedBox(height: KrezioSpace.sm),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(KrezioSpace.lg),
              decoration: BoxDecoration(
                color: widget.isDark ? const Color(0xFF141416) : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  prettyJson,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: KrezioFont.small,
                    height: 1.4,
                    color: KrezioColors.aiPurple,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showEnvironmentDialog(BuildContext context) {
    final trace = _currentTrace;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.shield_outlined, color: KrezioColors.aiPurple),
              SizedBox(width: KrezioSpace.sm),
              Expanded(child: Text('Especificações do Pipeline On-Device')),
            ],
          ),
          content: Text(
            'Este inspetor de homologação expõe com transparência matemática a arquitetura real de NLP do Krezio.ai:\n\n'
            '• Pré-processamento: redução de repetição, gírias, _commonTypoCorrections e distância de edição (KeywordTypoCorrector).\n'
            '• Vetorização: Bag-of-Ngrams (1–2 gramas) ponderado por TF-IDF (${trace?.vocabSize ?? '—'} features).\n'
            '• Classificadores: 3 modelos lineares independentes (Intent, Category, Payment) via z = b₀ + Σ w·TF-IDF → Softmax.\n'
            '• Threshold de Confiança: ${trace != null ? '${(trace.confidenceThreshold * 100).toStringAsFixed(0)}%' : '45%'} + Zero-Vector Gate + Regras de Negócio & Slots.',
            style: const TextStyle(fontSize: KrezioFont.bodySmall, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Entendido', style: TextStyle(color: KrezioColors.aiPurple)),
            ),
          ],
        );
      },
    );
  }
}

/// Custom Painter that renders the real 4-stage TF-IDF -> Linear Softmax ->
/// Post-Rule pipeline topology with signed weight attributions (`w * tfidf`).
class NeuralNetworkPainter extends CustomPainter {
  final NeuralThoughtTrace trace;
  final double pulseValue;
  final bool isDark;

  NeuralNetworkPainter({
    required this.trace,
    required this.pulseValue,
    required this.isDark,
  });

  double _contributionFor(ModelInferenceTrace model, String token) {
    for (final c in model.topContributions) {
      if (c.token == token) return c.contribution;
    }
    return 0.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 4 evenly balanced columns inside safe horizontal padding so labels never clip.
    final layerX1 = size.width * 0.13;
    final layerX2 = size.width * 0.37;
    final layerX3 = size.width * 0.63;
    final layerX4 = size.width * 0.87;

    final activeFeats = trace.activeFeatures.take(6).toList();
    final tokens = trace.normalizedTokens.take(5).toList();

    final inputPositions = <Offset>[];
    final featPositions = <Offset>[];
    final classPositions = <Offset>[];
    final decisionPositions = <Offset>[];

    final inputSpacing = size.height / (tokens.length + 1);
    for (int i = 0; i < tokens.length; i++) {
      inputPositions.add(Offset(layerX1, inputSpacing * (i + 1)));
    }

    final featSpacing = size.height / (activeFeats.length + 1);
    for (int i = 0; i < activeFeats.length; i++) {
      featPositions.add(Offset(layerX2, featSpacing * (i + 1)));
    }

    final classSpacing = size.height / 4;
    for (int i = 0; i < 3; i++) {
      classPositions.add(Offset(layerX3, classSpacing * (i + 1)));
    }

    final decSpacing = size.height / 4;
    for (int i = 0; i < 3; i++) {
      decisionPositions.add(Offset(layerX4, decSpacing * (i + 1)));
    }

    final synapsePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 1. Synapses: Tokens -> Active TF-IDF Features (only connect tokens actually contained in feature n-gram)
    for (int t = 0; t < inputPositions.length; t++) {
      for (int f = 0; f < featPositions.length; f++) {
        final matches = activeFeats[f].token.split(' ').contains(tokens[t]);
        if (!matches) continue;
        synapsePaint.color = const Color(0xFF6366F1).withOpacity(0.35 + 0.15 * sin(pulseValue * 2 * pi));
        synapsePaint.strokeWidth = 1.6;
        canvas.drawLine(inputPositions[t], featPositions[f], synapsePaint);
      }
    }

    // 2. Synapses: TF-IDF Features -> Linear Softmax Classifiers (colored by real w * tfidf!)
    final models = [trace.intentModel, trace.categoryModel, trace.paymentModel];
    for (int f = 0; f < featPositions.length; f++) {
      final featToken = activeFeats[f].token;
      for (int c = 0; c < classPositions.length; c++) {
        final contrib = _contributionFor(models[c], featToken);
        final absC = contrib.abs();
        if (absC < 0.02) {
          synapsePaint.color = (isDark ? Colors.white : Colors.black).withOpacity(0.06);
          synapsePaint.strokeWidth = 0.8;
        } else if (contrib > 0) {
          final pulse = (sin((pulseValue * 2 * pi) + (f * 0.5)) + 1) / 2;
          synapsePaint.color = KrezioColors.emeraldGreen.withOpacity((0.25 + 0.4 * pulse).clamp(0.0, 0.85));
          synapsePaint.strokeWidth = 1.2 + min(absC * 1.4, 3.2);
        } else {
          synapsePaint.color = KrezioColors.budgetOver.withOpacity(0.45);
          synapsePaint.strokeWidth = 1.0 + min(absC * 1.1, 2.2);
        }
        canvas.drawLine(featPositions[f], classPositions[c], synapsePaint);
      }
    }

    // 3. Synapses: Softmax -> Final Post-Rule Resolution (highlight Rule Override in orange)
    final overridden = [
      trace.intentModel.predictedLabel != trace.draft.intent,
      trace.categoryModel.predictedLabel != trace.draft.category,
      trace.paymentModel.predictedLabel != trace.draft.paymentMethod,
    ];
    for (int c = 0; c < classPositions.length; c++) {
      for (int d = 0; d < decisionPositions.length; d++) {
        final isDirect = c == d;
        synapsePaint.color = isDirect && overridden[c]
            ? KrezioColors.friendlyOrange.withOpacity(0.75)
            : KrezioColors.aiPurple.withOpacity(isDirect ? 0.45 : 0.10);
        synapsePaint.strokeWidth = isDirect ? 2.0 : 0.9;
        canvas.drawLine(classPositions[c], decisionPositions[d], synapsePaint);
      }
    }

    // Layer 1 Nodes (Normalized Tokens)
    for (int i = 0; i < inputPositions.length; i++) {
      _drawNeuronNode(
        canvas,
        size,
        inputPositions[i],
        tokens[i],
        const Color(0xFF6366F1),
        radius: 6.5,
        maxLabelWidth: size.width * 0.22,
      );
    }

    // Layer 2 Nodes (Active TF-IDF Features)
    for (int i = 0; i < featPositions.length; i++) {
      _drawNeuronNode(
        canvas,
        size,
        featPositions[i],
        '${activeFeats[i].token} (${activeFeats[i].value.toStringAsFixed(2)})',
        KrezioColors.aiPurple,
        radius: 6.5 + min(activeFeats[i].value * 3.5, 5.5),
        maxLabelWidth: size.width * 0.24,
      );
    }

    // Layer 3 Nodes (Linear Softmax Output)
    final classLabels = [
      '${trace.intentModel.predictedLabel} (${(trace.intentModel.confidence * 100).toStringAsFixed(0)}%)',
      '${trace.categoryModel.predictedLabel} (${(trace.categoryModel.confidence * 100).toStringAsFixed(0)}%)',
      '${trace.paymentModel.predictedLabel} (${(trace.paymentModel.confidence * 100).toStringAsFixed(0)}%)',
    ];
    final classColors = [
      KrezioColors.aiPurple,
      KrezioColors.emeraldGreen,
      KrezioColors.friendlyOrange,
    ];
    for (int i = 0; i < classPositions.length; i++) {
      _drawNeuronNode(
        canvas,
        size,
        classPositions[i],
        classLabels[i],
        classColors[i],
        radius: 10.5,
        maxLabelWidth: size.width * 0.25,
      );
    }

    // Layer 4 Nodes (Final Post-Rule Resolution)
    final isExempt = trace.installmentDecision.isExempt;
    final isAnnual = trace.installmentDecision.isAnnual;
    final decLabels = [
      trace.parsedAmount != null ? Money.brl(trace.parsedAmount!) : 'Valor N/D',
      isExempt
          ? 'Assinatura 1x'
          : (isAnnual
              ? 'Anual (${trace.installmentDecision.installments ?? '?'}x)'
              : trace.draft.category),
      trace.isComplete ? 'Completo' : '${trace.missingSlots.length} slot(s)',
    ];
    final decColors = [
      KrezioColors.aiPurple,
      isExempt
          ? KrezioColors.emeraldGreen
          : (isAnnual ? KrezioColors.friendlyOrange : const Color(0xFF6366F1)),
      trace.isComplete ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
    ];

    for (int i = 0; i < decisionPositions.length; i++) {
      _drawNeuronNode(
        canvas,
        size,
        decisionPositions[i],
        decLabels[i],
        decColors[i],
        radius: 10.0,
        maxLabelWidth: size.width * 0.23,
      );
    }
  }

  void _drawNeuronNode(
    Canvas canvas,
    Size canvasSize,
    Offset position,
    String label,
    Color color, {
    double radius = 8.0,
    double maxLabelWidth = 96.0,
  }) {
    final glowPaint = Paint()
      ..color = color.withOpacity(0.22)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(position, radius + 4.0, glowPaint);

    final nodePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(position, radius, nodePaint);

    final corePaint = Paint()
      ..color = Colors.white.withOpacity(0.85)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(position, radius * 0.38, corePaint);

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: isDark ? const Color(0xFFF3F4F6) : const Color(0xFF1F2937),
          fontSize: KrezioFont.micro,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxLabelWidth);

    // Center below node and clamp inside horizontal bounds so labels never clip.
    final rawX = position.dx - (textPainter.width / 2);
    final clampedX = rawX.clamp(6.0, max<double>(6.0, canvasSize.width - textPainter.width - 6.0)).toDouble();
    final textY = (position.dy + radius + 4).clamp(4.0, max<double>(4.0, canvasSize.height - textPainter.height - 4.0)).toDouble();

    textPainter.paint(canvas, Offset(clampedX, textY));
  }

  @override
  bool shouldRepaint(covariant NeuralNetworkPainter oldDelegate) {
    return oldDelegate.pulseValue != pulseValue || oldDelegate.trace != trace;
  }
}
