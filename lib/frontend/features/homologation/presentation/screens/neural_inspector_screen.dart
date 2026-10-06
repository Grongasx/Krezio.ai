import 'dart:math';
import 'package:flutter/material.dart';
import '../../../../../ai/local_nlp_engine.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/services/calendar_service.dart';

/// Interactive Visual Neural Thought Inspector for Homologation / Staging environments.
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

class _NeuralInspectorScreenState extends State<NeuralInspectorScreen>
    with SingleTickerProviderStateMixin {
  late TextEditingController _textController;
  late AnimationController _pulseController;
  NeuralThoughtTrace? _currentTrace;

  int _selectedTab = 0; // 0 = Grafo Neural Animado, 1 = Auditoria de Probabilidades, 2 = Slots & Regras, 3 = JSON Bruto

  final List<String> _quickTestCases = [
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
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [KrezioColors.aiPurple, Color(0xFF6366F1)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hub, color: Colors.white, size: 16),
                  SizedBox(width: 6),
                  Text(
                    'REDE NEURAL ON-DEVICE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: KrezioColors.friendlyOrange,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Ambiente Atual',
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      color: surface,
      child: Container(
        decoration: BoxDecoration(
          color: widget.isDark ? const Color(0xFF141414) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 20),
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                style: TextStyle(color: primaryText, fontSize: 14, fontWeight: FontWeight.w500),
                decoration: InputDecoration(
                  hintText: 'Digite ou edite qualquer frase para testar a IA...',
                  hintStyle: TextStyle(color: secondaryText, fontSize: 13),
                  border: InputBorder.none,
                ),
                onChanged: _runInference,
                onSubmitted: _runInference,
              ),
            ),
            if (_textController.text.isNotEmpty)
              IconButton(
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _quickTestCases.map((phrase) {
            final isSelected = _textController.text.trim() == phrase.trim();
            final isAnnualCase = phrase.contains('anual');
            final isMonthlySub = phrase.contains('netflix') || phrase.contains('academia');
            Color tagColor = KrezioColors.aiPurple;
            if (isAnnualCase) tagColor = KrezioColors.friendlyOrange;
            if (isMonthlySub) tagColor = KrezioColors.emeraldGreen;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  _textController.text = phrase;
                  _runInference(phrase);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? tagColor.withOpacity(0.18)
                        : (widget.isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF3F4F6)),
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
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tagColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        phrase,
                        style: TextStyle(
                          fontSize: 12,
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: widget.isDark ? const Color(0xFF18181B) : const Color(0xFFF9FAFB),
        border: Border(
          top: BorderSide(color: border),
          bottom: BorderSide(color: border),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildMetricBadge(
            icon: Icons.bolt,
            label: 'Latência On-Device',
            value: '${trace.latencyMs.toStringAsFixed(2)} ms',
            color: KrezioColors.emeraldGreen,
          ),
          _buildMetricBadge(
            icon: Icons.memory,
            label: 'Features TF-IDF',
            value: '${trace.activeFeatures.length} ativas',
            color: KrezioColors.aiPurple,
          ),
          _buildMetricBadge(
            icon: Icons.credit_card,
            label: 'Regra de Cartão',
            value: trace.installmentDecision.isExempt
                ? 'Assinatura Mensal (1x)'
                : (trace.installmentDecision.isAnnual
                    ? 'Assinatura Anual (${trace.installmentDecision.installments ?? 'N/D'}x)'
                    : (trace.installmentDecision.installments != null
                        ? '${trace.installmentDecision.installments}x'
                        : 'À Vista / Desamb.')),
            color: trace.installmentDecision.isExempt
                ? KrezioColors.emeraldGreen
                : (trace.installmentDecision.isAnnual ? KrezioColors.friendlyOrange : KrezioColors.aiPurple),
          ),
          _buildMetricBadge(
            icon: trace.isComplete ? Icons.check_circle : Icons.pending,
            label: 'Completude',
            value: trace.isComplete ? '100% Completo' : '${trace.missingSlots.length} pendentes',
            color: trace.isComplete ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
          ),
        ],
      ),
    );
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
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
            Text(
              value,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNavigationTabs(Color surface, Color primaryText, Color secondaryText, Color border) {
    final tabs = [
      {'label': 'Grafo Neural Animado', 'icon': Icons.hub_outlined},
      {'label': 'Classificadores Softmax', 'icon': Icons.bar_chart_rounded},
      {'label': 'Árvore de Decisão & Slots', 'icon': Icons.account_tree_outlined},
      {'label': 'Calendário em Tempo Real', 'icon': Icons.calendar_month_outlined},
      {'label': 'Trace Detalhado', 'icon': Icons.code},
    ];

    return Container(
      color: surface,
      child: Row(
        children: tabs.asMap().entries.map((entry) {
          final idx = entry.key;
          final item = entry.value;
          final isSelected = _selectedTab == idx;

          return Expanded(
            child: InkWell(
              onTap: () => setState(() => _selectedTab = idx),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isSelected ? KrezioColors.aiPurple : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
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
                        fontSize: 11.5,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected ? KrezioColors.aiPurple : secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
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
        return _buildCalendarTab(surface, primaryText, secondaryText, border);
      case 4:
      default:
        return _buildJsonTraceTab(surface, primaryText, secondaryText, border);
    }
  }

  Widget _buildNeuralGraphTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _buildSubscriptionNoticeBanner(trace, surface, primaryText, border),
              const SizedBox(height: 12),
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
            ],
          ),
        );
      },
    );
  }

  Widget _buildSubscriptionNoticeBanner(
      NeuralThoughtTrace trace, Color surface, Color primaryText, Color border) {
    final dec = trace.installmentDecision;
    Color bannerColor = KrezioColors.aiPurple;
    IconData bannerIcon = Icons.info_outline;
    String title = 'Processamento Padrão de Pagamento';
    String desc = dec.explanation;

    if (trace.draft.isReminder) {
      bannerColor = KrezioColors.friendlyOrange;
      bannerIcon = Icons.calendar_month_outlined;
      title = '🔔 Heurística Ativa: Lembrete & Consulta ao Calendário em Tempo Real';
      desc = trace.draft.calendarConsultationNote ??
          'A IA identificou empréstimo a terceiro com promessa de devolução no pagamento e consultou o calendário em tempo real para agendar cobrança no 5º dia útil.';
    } else if (dec.isExempt) {
      bannerColor = KrezioColors.emeraldGreen;
      bannerIcon = Icons.verified_user_rounded;
      title = '💡 Regra de Negócio: Assinatura Mensal no Crédito';
      desc =
          'Detectada assinatura mensal recorrente! A IA reconhece que não é uma compra parcelada (cobrança mensal avulsa à vista todo mês). O campo de parcelamento foi automaticamente resolvido (1x) sem interromper o usuário.';
    } else if (dec.isAnnual) {
      bannerColor = KrezioColors.friendlyOrange;
      bannerIcon = Icons.event_repeat_rounded;
      title = '📅 Regra de Negócio: Assinatura Anual no Crédito';
      desc =
          'Detectada assinatura ANUAL! Planos anuais no crédito suportam e permitem parcelamento (ex: em até 12x). A IA valida se as parcelas foram informadas ou se requer esclarecimento.';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bannerColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bannerColor.withOpacity(0.35), width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(bannerIcon, color: bannerColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: bannerColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 12,
                    color: primaryText.withOpacity(0.85),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClassifiersTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildClassifierCard(
          title: 'Classificador de Intenção (Intent)',
          modelTrace: trace.intentModel,
          accentColor: KrezioColors.aiPurple,
          surface: surface,
          primaryText: primaryText,
          secondaryText: secondaryText,
          border: border,
        ),
        const SizedBox(height: 16),
        _buildClassifierCard(
          title: 'Classificador de Categoria (Category)',
          modelTrace: trace.categoryModel,
          accentColor: KrezioColors.emeraldGreen,
          surface: surface,
          primaryText: primaryText,
          secondaryText: secondaryText,
          border: border,
        ),
        const SizedBox(height: 16),
        _buildClassifierCard(
          title: 'Classificador de Meio de Pagamento (Payment Method)',
          modelTrace: trace.paymentModel,
          accentColor: KrezioColors.friendlyOrange,
          surface: surface,
          primaryText: primaryText,
          secondaryText: secondaryText,
          border: border,
        ),
      ],
    );
  }

  Widget _buildClassifierCard({
    required String title,
    required ModelInferenceTrace modelTrace,
    required Color accentColor,
    required Color surface,
    required Color primaryText,
    required Color secondaryText,
    required Color border,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
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
              Text(
                title,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryText),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Vencedor: ${modelTrace.predictedLabel} (${(modelTrace.confidence * 100).toStringAsFixed(1)}%)',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: accentColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...modelTrace.probabilities.take(5).map((prob) {
            final isWinner = prob.label == modelTrace.predictedLabel;
            final pct = prob.probability;

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        prob.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
                          color: isWinner ? accentColor : primaryText,
                        ),
                      ),
                      Text(
                        '${(pct * 100).toStringAsFixed(1)}% (score: ${prob.score.toStringAsFixed(2)})',
                        style: TextStyle(fontSize: 11, color: secondaryText),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      backgroundColor: widget.isDark ? const Color(0xFF27272A) : const Color(0xFFE5E7EB),
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
        ],
      ),
    );
  }

  Widget _buildDecisionTreeTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;
    final dec = trace.installmentDecision;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
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
                  SizedBox(width: 8),
                  Text(
                    'Árvore de Decisão & NER de Slots',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildSlotAuditItem(
                label: 'Intenção Identificada',
                value: trace.draft.intent,
                isSatisfied: trace.draft.intent != 'unknown',
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Valor Monetário (Amount)',
                value: trace.parsedAmount != null
                    ? 'R\$ ${trace.parsedAmount!.toStringAsFixed(2).replaceAll('.', ',')}'
                    : 'Não identificado',
                isSatisfied: trace.parsedAmount != null && trace.parsedAmount! > 0,
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Categoria do Gasto',
                value: trace.draft.category,
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
                    ? 'Sim (${trace.frequency ?? 'mensal'}, renova dia ${trace.dueDay ?? 'N/D'}, prazo: ${trace.recurrenceDuration ?? 'indeterminado'})'
                    : 'Não (transação pontual)',
                isSatisfied: true,
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              _buildSlotAuditItem(
                label: 'Regra de Parcelamento no Crédito',
                value: dec.isExempt
                    ? 'ISENTO (Assinatura Mensal = 1x sem parcelar)'
                    : (dec.isAnnual
                        ? 'PERMITE PARCELAMENTO (Assinatura Anual = ${dec.installments ?? 'a esclarecer'}x)'
                        : (dec.installments != null
                            ? '${dec.installments}x'
                            : 'Requer desambiguação de parcelas')),
                isSatisfied: !trace.missingSlots.contains('installments'),
                highlightColor: dec.isExempt
                    ? KrezioColors.emeraldGreen
                    : (dec.isAnnual ? KrezioColors.friendlyOrange : null),
                primaryText: primaryText,
                secondaryText: secondaryText,
              ),
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Status de Completude:',
                    style: TextStyle(fontWeight: FontWeight.bold, color: primaryText),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: trace.isComplete
                          ? KrezioColors.emeraldGreen.withOpacity(0.15)
                          : KrezioColors.friendlyOrange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      trace.isComplete ? 'Pronto para Gravação 🎉' : 'Aguardando Resposta Contextual ⏳',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: trace.isComplete ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
                      ),
                    ),
                  ),
                ],
              ),
              if (trace.clarificationPrompt != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Pergunta Empática Gerada:',
                  style: TextStyle(fontSize: 12, color: secondaryText),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: widget.isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    trace.clarificationPrompt!,
                    style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: primaryText),
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSatisfied ? Icons.check_circle_rounded : Icons.pending_rounded,
            size: 16,
            color: isSatisfied ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Text(label, style: TextStyle(fontSize: 12, color: secondaryText)),
          ),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: highlightColor ?? (isSatisfied ? primaryText : KrezioColors.friendlyOrange),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final calendar = widget.engine.calendarService;
    final nextPayday = calendar.getNextSalaryPayday();
    final paydayLabel = RealtimeCalendarService.formatDateLabel(nextPayday);
    final trace = _currentTrace;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1. Status da Consulta da Frase Atual
        if (trace != null && trace.draft.isReminder) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: KrezioColors.friendlyOrange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: KrezioColors.friendlyOrange.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.event_available, color: KrezioColors.friendlyOrange, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Lembrete Agendado pelo Motor IA',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: KrezioColors.friendlyOrange,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  trace.draft.calendarConsultationNote ?? 'Lembrete conectado ao 5º dia útil bancário.',
                  style: TextStyle(fontSize: 12, color: primaryText),
                ),
                if (trace.draft.personName != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Devedor: ${trace.draft.personName} • Data-Alvo: $paydayLabel',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: KrezioColors.friendlyOrange),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // 2. Previsão de Salário e 5º Dia Útil FEBRABAN
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.calendar_month, color: KrezioColors.aiPurple, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Previsão de Salário (5º Dia Útil Bancário)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'A IA calcula os dias úteis bancários reais excluindo finais de semana e feriados nacionais FEBRABAN:',
                style: TextStyle(fontSize: 12, color: secondaryText),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: KrezioColors.aiPurple.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: KrezioColors.aiPurple.withOpacity(0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Próximo 5º dia útil:',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      paydayLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: KrezioColors.aiPurple,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 3. Eventos & Lembretes no Calendário
        Container(
          padding: const EdgeInsets.all(16),
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
                  const Text(
                    'Eventos & Lembretes no Calendário',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${calendar.events.length} eventos',
                    style: TextStyle(fontSize: 11, color: secondaryText),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...calendar.events.map((ev) {
                final dateStr = RealtimeCalendarService.formatDateLabel(ev.dateTime);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        ev.category == CalendarEventCategory.loanReceivable
                            ? Icons.handshake_outlined
                            : (ev.category == CalendarEventCategory.salary
                                ? Icons.payments_outlined
                                : Icons.trending_up),
                        size: 16,
                        color: KrezioColors.friendlyOrange,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ev.title,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: primaryText),
                            ),
                            if (ev.notes != null)
                              Text(
                                ev.notes!,
                                style: TextStyle(fontSize: 10, color: secondaryText),
                              ),
                          ],
                        ),
                      ),
                      Text(
                        dateStr,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: secondaryText),
                      ),
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

  Widget _buildJsonTraceTab(Color surface, Color primaryText, Color secondaryText, Color border) {
    final trace = _currentTrace!;

    final map = {
      'raw_text': trace.rawText,
      'normalized_text': trace.normalizedText,
      'latency_ms': trace.latencyMs,
      'active_features_count': trace.activeFeatures.length,
      'active_features': trace.activeFeatures.map((f) => {
        'token': f.token,
        'index': f.index,
        'tf': f.tf,
        'idf': f.idf,
        'value': f.value,
      }).toList(),
      'intent': {
        'predicted': trace.intentModel.predictedLabel,
        'confidence': trace.intentModel.confidence,
      },
      'category': {
        'predicted': trace.categoryModel.predictedLabel,
        'confidence': trace.categoryModel.confidence,
      },
      'payment_method': {
        'predicted': trace.paymentModel.predictedLabel,
        'confidence': trace.paymentModel.confidence,
      },
      'installment_decision': {
        'is_credit_card': trace.installmentDecision.isCreditCard,
        'is_subscription': trace.installmentDecision.isSubscription,
        'is_annual': trace.installmentDecision.isAnnual,
        'is_exempt_from_installments': trace.installmentDecision.isExempt,
        'installments': trace.installmentDecision.installments,
        'explanation': trace.installmentDecision.explanation,
      },
      'missing_slots': trace.missingSlots,
      'is_complete': trace.isComplete,
      'clarification_prompt': trace.clarificationPrompt,
    };

    return Container(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: widget.isDark ? const Color(0xFF141416) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            _formatJson(map, 0),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
              color: KrezioColors.aiPurple,
            ),
          ),
        ),
      ),
    );
  }

  String _formatJson(dynamic object, int indent) {
    final spaces = '  ' * indent;
    if (object is Map) {
      final buffer = StringBuffer('{\n');
      object.forEach((k, v) {
        buffer.writeln('$spaces  "$k": ${_formatJson(v, indent + 1)},');
      });
      buffer.write('$spaces}');
      return buffer.toString();
    } else if (object is List) {
      final buffer = StringBuffer('[\n');
      for (final item in object) {
        buffer.writeln('$spaces  ${_formatJson(item, indent + 1)},');
      }
      buffer.write('$spaces]');
      return buffer.toString();
    } else if (object is String) {
      return '"$object"';
    } else {
      return object.toString();
    }
  }

  void _showEnvironmentDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.shield_outlined, color: KrezioColors.aiPurple),
              SizedBox(width: 8),
              Text('Ambiente de Homologação'),
            ],
          ),
          content: const Text(
            'Esta interface visual da rede neural é exclusiva para homologação e auditoria on-device do Krezio.ai.\n\n'
            'Ela expõe em tempo real o cálculo de tensores TF-IDF, matriz de pesos, distribuição de probabilidades Softmax e as regras de negócio de assinaturas no crédito.',
            style: TextStyle(fontSize: 13, height: 1.4),
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

/// Custom Painter that renders the neural network topology, active neurons, and synaptic connections.
class NeuralNetworkPainter extends CustomPainter {
  final NeuralThoughtTrace trace;
  final double pulseValue;
  final bool isDark;

  NeuralNetworkPainter({
    required this.trace,
    required this.pulseValue,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final layerX1 = size.width * 0.12; // Input Tokens Layer
    final layerX2 = size.width * 0.38; // TF-IDF Active Feature Nodes
    final layerX3 = size.width * 0.65; // Dense Classification Nodes (Intent, Category, Payment)
    final layerX4 = size.width * 0.88; // Slot & Decision Rule Nodes

    final activeFeats = trace.activeFeatures.take(6).toList();
    final tokens = trace.normalizedTokens.take(5).toList();

    final inputPositions = <Offset>[];
    final featPositions = <Offset>[];
    final classPositions = <Offset>[];
    final decisionPositions = <Offset>[];

    // Calculate Y coordinates for Layer 1 (Tokens)
    final inputSpacing = size.height / (tokens.length + 1);
    for (int i = 0; i < tokens.length; i++) {
      inputPositions.add(Offset(layerX1, inputSpacing * (i + 1)));
    }

    // Calculate Y coordinates for Layer 2 (Features)
    final featSpacing = size.height / (activeFeats.length + 1);
    for (int i = 0; i < activeFeats.length; i++) {
      featPositions.add(Offset(layerX2, featSpacing * (i + 1)));
    }

    // Calculate Y coordinates for Layer 3 (Classifiers: Intent, Category, Payment)
    final classSpacing = size.height / 4;
    for (int i = 0; i < 3; i++) {
      classPositions.add(Offset(layerX3, classSpacing * (i + 1)));
    }

    // Calculate Y coordinates for Layer 4 (Decision: Amount, Subscription Rule, Result)
    final decSpacing = size.height / 4;
    for (int i = 0; i < 3; i++) {
      decisionPositions.add(Offset(layerX4, decSpacing * (i + 1)));
    }

    final synapsePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Draw Synapses: Layer 1 -> Layer 2
    for (final inPos in inputPositions) {
      for (final featPos in featPositions) {
        synapsePaint.color = (isDark ? const Color(0xFF6366F1) : const Color(0xFF818CF8))
            .withOpacity(0.12 + 0.1 * sin(pulseValue * 2 * pi));
        synapsePaint.strokeWidth = 1.0;
        canvas.drawLine(inPos, featPos, synapsePaint);
      }
    }

    // Draw Synapses: Layer 2 -> Layer 3
    for (int f = 0; f < featPositions.length; f++) {
      final featPos = featPositions[f];
      final weight = activeFeats[f].value;
      for (int c = 0; c < classPositions.length; c++) {
        final classPos = classPositions[c];
        final pulse = (sin((pulseValue * 2 * pi) + (f * 0.4)) + 1) / 2;
        synapsePaint.color = const Color(0xFF8B5CF6).withOpacity(0.15 + 0.35 * pulse);
        synapsePaint.strokeWidth = 1.0 + min(weight * 3, 2.5);
        canvas.drawLine(featPos, classPos, synapsePaint);
      }
    }

    // Draw Synapses: Layer 3 -> Layer 4
    for (final classPos in classPositions) {
      for (final decPos in decisionPositions) {
        synapsePaint.color = (isDark ? const Color(0xFF10B981) : const Color(0xFF059669))
            .withOpacity(0.2 + 0.15 * cos(pulseValue * 2 * pi));
        synapsePaint.strokeWidth = 1.2;
        canvas.drawLine(classPos, decPos, synapsePaint);
      }
    }

    // Draw Layer 1 Nodes (Input Tokens)
    for (int i = 0; i < inputPositions.length; i++) {
      _drawNeuronNode(
        canvas,
        inputPositions[i],
        tokens[i],
        const Color(0xFF6366F1),
        isLabelLeft: true,
      );
    }

    // Draw Layer 2 Nodes (Features)
    for (int i = 0; i < featPositions.length; i++) {
      _drawNeuronNode(
        canvas,
        featPositions[i],
        activeFeats[i].token,
        KrezioColors.aiPurple,
        radius: 7.0 + min(activeFeats[i].value * 4, 6.0),
      );
    }

    // Draw Layer 3 Nodes (Dense Classifiers)
    final classLabels = [
      'Intent: ${trace.intentModel.predictedLabel}',
      'Cat: ${trace.categoryModel.predictedLabel}',
      'Pay: ${trace.paymentModel.predictedLabel}',
    ];
    final classColors = [
      KrezioColors.aiPurple,
      KrezioColors.emeraldGreen,
      KrezioColors.friendlyOrange,
    ];
    for (int i = 0; i < classPositions.length; i++) {
      _drawNeuronNode(
        canvas,
        classPositions[i],
        classLabels[i],
        classColors[i],
        radius: 12.0,
      );
    }

    // Draw Layer 4 Nodes (Decision & Subscription Rule)
    final isExempt = trace.installmentDecision.isExempt;
    final isAnnual = trace.installmentDecision.isAnnual;
    final decLabels = [
      trace.parsedAmount != null ? 'R\$ ${trace.parsedAmount!.toStringAsFixed(2)}' : 'Valor N/D',
      isExempt
          ? '🛡️ Assinatura: NÃO Parcelada (1x)'
          : (isAnnual ? '📅 Assinatura: Anual (${trace.installmentDecision.installments ?? 'a esclarecer'}x)' : '💳 Crédito Padrão'),
      trace.isComplete ? '✅ Completo' : '⏳ Incompleto',
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
        decisionPositions[i],
        decLabels[i],
        decColors[i],
        radius: 11.0,
        isLabelRight: true,
      );
    }
  }

  void _drawNeuronNode(
    Canvas canvas,
    Offset position,
    String label,
    Color color, {
    double radius = 8.0,
    bool isLabelLeft = false,
    bool isLabelRight = false,
  }) {
    // Glow ring
    final glowPaint = Paint()
      ..color = color.withOpacity(0.25)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(position, radius + 4.0, glowPaint);

    // Main node
    final nodePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(position, radius, nodePaint);

    // Inner bright core
    final corePaint = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(position, radius * 0.4, corePaint);

    // Text label
    final textSpan = TextSpan(
      text: label,
      style: TextStyle(
        color: isDark ? const Color(0xFFF3F4F6) : const Color(0xFF1F2937),
        fontSize: 10,
        fontWeight: FontWeight.bold,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    double textX = position.dx - (textPainter.width / 2);
    double textY = position.dy + radius + 4;

    if (isLabelLeft) {
      textX = position.dx - textPainter.width - radius - 6;
      textY = position.dy - (textPainter.height / 2);
    } else if (isLabelRight) {
      textX = position.dx + radius + 6;
      textY = position.dy - (textPainter.height / 2);
    }

    textPainter.paint(canvas, Offset(textX, textY));
  }

  @override
  bool shouldRepaint(covariant NeuralNetworkPainter oldDelegate) {
    return oldDelegate.pulseValue != pulseValue || oldDelegate.trace != trace;
  }
}
