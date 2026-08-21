import 'package:flutter/material.dart';
import '../../../../core/ml/local_nlp_engine.dart';
import '../../../../core/theme/krezio_theme.dart';

enum MessageSender { user, assistant }

class ChatMessage {
  final String id;
  final MessageSender sender;
  final String text;
  final DateTime timestamp;
  final FinancialTransactionDraft? draft;
  final bool isMergedUpdate;

  ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.draft,
    this.isMergedUpdate = false,
  });
}

class ChatScreen extends StatefulWidget {
  final LocalFinancialNlpEngine engine;
  final VoidCallback onToggleTheme;
  final bool isDarkMode;

  const ChatScreen({
    super.key,
    required this.engine,
    required this.onToggleTheme,
    required this.isDarkMode,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  
  FinancialTransactionDraft? _activeDraft;
  double _lastLatencyMs = 0.0;

  final List<String> _quickSuggestions = [
    'gastei 50',
    'gastei 45,90 no mercado no pix',
    'caiu 1.200 do meu salário no pix',
    'quanto eu gastei com mercado este mês?',
    'como faço um estrogonofe de frango?'
  ];

  @override
  void initState() {
    super.initState();
    _addInitialWelcomeMessage();
  }

  void _addInitialWelcomeMessage() {
    _messages.add(
      ChatMessage(
        id: 'welcome',
        sender: MessageSender.assistant,
        text: 'Olá! Sou o assistente virtual do Krezio.ai, guiado por dados. Como posso te ajudar com suas finanças hoje?\n\nDigite um gasto, receita ou faça uma pergunta sobre seus valores (100% no seu dispositivo).',
        timestamp: DateTime.now(),
      ),
    );
  }

  void _sendMessage(String input) {
    final text = input.trim();
    if (text.isEmpty) return;

    _textController.clear();

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      sender: MessageSender.user,
      text: text,
      timestamp: DateTime.now(),
    );

    setState(() {
      _messages.add(userMsg);
    });

    _scrollToBottom();

    // Process on-device local NLP
    FinancialTransactionDraft draft;
    bool isMerged = false;

    if (_activeDraft != null && !_activeDraft!.isComplete) {
      draft = widget.engine.mergeDrafts(_activeDraft!, text);
      isMerged = true;
    } else {
      draft = widget.engine.parse(text);
    }

    _activeDraft = draft;
    _lastLatencyMs = draft.latencyMs;

    String responseText = draft.clarificationPrompt ??
        'Lançamento registrado com sucesso no seu Krezio.ai!';

    if (draft.intent == 'query') {
      responseText = 'Consultando seus lançamentos locais... Tudo pronto!';
    } else if (draft.intent == 'unknown') {
      responseText = 'Notei que sua mensagem não parece ser um lançamento financeiro. Como posso te ajudar com suas finanças hoje?';
    }

    final assistantMsg = ChatMessage(
      id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
      sender: MessageSender.assistant,
      text: responseText,
      timestamp: DateTime.now(),
      draft: draft.intent != 'unknown' ? draft : null,
      isMergedUpdate: isMerged,
    );

    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() {
        _messages.add(assistantMsg);
      });
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearChat() {
    setState(() {
      _messages.clear();
      _activeDraft = null;
      _lastLatencyMs = 0.0;
      _addInitialWelcomeMessage();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: KrezioColors.aiPurple.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: KrezioColors.aiPurple,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Krezio.ai',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Assistente Financeiro On-Device',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (_lastLatencyMs > 0)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: KrezioColors.emeraldGreen.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: KrezioColors.emeraldGreen.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.bolt, color: KrezioColors.emeraldGreen, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    '${_lastLatencyMs.toStringAsFixed(1)} ms',
                    style: const TextStyle(
                      color: KrezioColors.emeraldGreen,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: widget.onToggleTheme,
            tooltip: 'Alternar Tema',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _clearChat,
            tooltip: 'Limpar Chat',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Quick Suggestions Bar
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: _quickSuggestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final text = _quickSuggestions[index];
                  return ActionChip(
                    label: Text(text, style: const TextStyle(fontSize: 12)),
                    avatar: const Icon(Icons.flash_on, size: 14, color: KrezioColors.aiPurple),
                    backgroundColor: bgSurface,
                    side: BorderSide(
                      color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                    ),
                    onPressed: () => _sendMessage(text),
                  );
                },
              ),
            ),
            const Divider(height: 1, thickness: 1),

            // Chat Messages List
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  return _buildMessageBubble(msg, isDark);
                },
              ),
            ),

            // Input Bar
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: bgSurface,
                border: Border(
                  top: BorderSide(
                    color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _sendMessage,
                      decoration: InputDecoration(
                        hintText: 'Digite um gasto (ex: gastei 50 no mercado)...',
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        filled: true,
                        fillColor: isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground,
                        border: OutlineInputBorder(
                          borderRadius: KrezioTheme.borderRadius,
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: KrezioTheme.borderRadius,
                          borderSide: BorderSide(
                            color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: KrezioTheme.borderRadius,
                          borderSide: const BorderSide(color: KrezioColors.aiPurple, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: KrezioColors.aiPurple,
                    borderRadius: KrezioTheme.borderRadius,
                    child: InkWell(
                      borderRadius: KrezioTheme.borderRadius,
                      onTap: () => _sendMessage(_textController.text),
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isDark) {
    final isUser = msg.sender == MessageSender.user;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser) ...[
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: KrezioColors.aiPurple.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 16),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isUser
                        ? KrezioColors.aiPurple
                        : (isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 16),
                    ),
                    border: !isUser
                        ? Border.all(
                            color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                          )
                        : null,
                  ),
                  child: Text(
                    msg.text,
                    style: TextStyle(
                      color: isUser
                          ? Colors.white
                          : (isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText),
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Embedded Transaction Inspector Card if draft present
          if (msg.draft != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: _buildTransactionInspectorCard(msg.draft!, isDark, msg.isMergedUpdate),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTransactionInspectorCard(FinancialTransactionDraft draft, bool isDark, bool isMerged) {
    final statusColor = draft.isComplete ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? KrezioColors.darkSurfaceVariant : const Color(0xFFF3F4F6),
        borderRadius: KrezioTheme.borderRadius,
        border: Border.all(
          color: statusColor.withOpacity(0.5),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getIntentColor(draft.intent).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _formatIntentName(draft.intent),
                      style: TextStyle(
                        color: _getIntentColor(draft.intent),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (isMerged) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: KrezioColors.aiPurple.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '🔄 Atualizado',
                        style: TextStyle(
                          color: KrezioColors.aiPurple,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Row(
                children: [
                  Icon(
                    draft.isComplete ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                    size: 14,
                    color: statusColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    draft.isComplete ? 'Completo' : 'Incompleto',
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Detail Grid
          Row(
            children: [
              Expanded(
                child: _buildDetailTile(
                  'Valor',
                  draft.amount != null
                      ? 'R\$ ${draft.amount!.toStringAsFixed(2).replaceAll('.', ',')}'
                      : 'Não informado',
                  Icons.attach_money,
                  isDark,
                ),
              ),
              Expanded(
                child: _buildDetailTile(
                  'Categoria',
                  _formatCategory(draft.category),
                  Icons.category_outlined,
                  isDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _buildDetailTile(
                  'Pagamento',
                  _formatPayment(draft.paymentMethod),
                  Icons.payment_outlined,
                  isDark,
                ),
              ),
              Expanded(
                child: _buildDetailTile(
                  'Latência Local',
                  '⚡ ${draft.latencyMs.toStringAsFixed(1)} ms',
                  Icons.speed_outlined,
                  isDark,
                ),
              ),
            ],
          ),

          if (draft.missingSlots.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: KrezioColors.friendlyOrange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Slots ausentes: ${draft.missingSlots.join(", ")}',
                style: const TextStyle(
                  color: KrezioColors.friendlyOrange,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailTile(String label, String value, IconData icon, bool isDark) {
    return Row(
      children: [
        Icon(icon, size: 14, color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _getIntentColor(String intent) {
    switch (intent) {
      case 'income':
        return KrezioColors.emeraldGreen;
      case 'expense':
        return KrezioColors.friendlyOrange; // NEVER blood red!
      case 'transfer':
        return KrezioColors.aiPurple;
      case 'query':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  String _formatIntentName(String intent) {
    switch (intent) {
      case 'expense':
        return 'DESPESA';
      case 'income':
        return 'RECEITA';
      case 'transfer':
        return 'TRANSFERÊNCIA';
      case 'query':
        return 'CONSULTA';
      default:
        return 'OUTRO';
    }
  }

  String _formatCategory(String cat) {
    switch (cat) {
      case 'supermarket':
        return 'Mercado';
      case 'transport':
        return 'Transporte';
      case 'health':
        return 'Saúde';
      case 'leisure':
        return 'Lazer / Restaurante';
      case 'housing':
        return 'Moradia / Contas';
      case 'education':
        return 'Educação';
      case 'salary':
        return 'Salário';
      case 'investment':
        return 'Investimentos';
      default:
        return cat == 'unknown' ? 'Ausente' : cat;
    }
  }

  String _formatPayment(String pay) {
    switch (pay) {
      case 'pix':
        return 'PIX';
      case 'credit_card':
        return 'Cartão de Crédito';
      case 'debit_card':
        return 'Cartão de Débito';
      case 'cash':
        return 'Dinheiro';
      case 'bank_slip':
        return 'Boleto';
      default:
        return pay == 'unknown' ? 'Ausente' : pay;
    }
  }
}
