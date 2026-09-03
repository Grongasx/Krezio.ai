import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../../../../core/ml/local_nlp_engine.dart';
import '../../../../core/theme/krezio_theme.dart';
import '../../../../core/repositories/financial_repository.dart';

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
  final FinancialRepository? repository;
  final VoidCallback onToggleTheme;
  final bool isDarkMode;

  const ChatScreen({
    super.key,
    required this.engine,
    this.repository,
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
  
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechEnabled = false;

  FinancialTransactionDraft? _activeDraft;
  FinancialTransactionDraft? _lastCompletedDraft;
  double _lastLatencyMs = 0.0;

  final List<String> _quickSuggestions = [
    'gastei 50',
    'gastei 45,90 no mercado no pix',
    'gastei 150 no mercado no débito e 35 no uber no pix',
    'minha academia de 120 no crédito vence todo dia 10',
    'quanto eu gastei com mercado este mês?',
  ];

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _addInitialWelcomeMessage();
  }

  String _selectedLocaleId = 'pt-BR';

  /// Convert locale ID to BCP 47 hyphen format for Web Speech API
  String _toBcp47(String localeId) => localeId.replaceAll('_', '-');

  void _initSpeech() async {
    try {
      _speechEnabled = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted) {
              setState(() {
                _isListening = false;
              });
            }
          }
        },
        onError: (errorNotification) {
          if (mounted) {
            setState(() {
              _isListening = false;
            });
          }
        },
      );
      if (_speechEnabled) {
        // Check available locales and find best Portuguese match
        final locales = await _speech.locales();
        stt.LocaleName? ptBR;
        stt.LocaleName? ptAny;
        for (final loc in locales) {
          final id = loc.localeId.replaceAll('_', '-').toLowerCase();
          if (id == 'pt-br') { ptBR = loc; break; }
          if (id.startsWith('pt') && ptAny == null) { ptAny = loc; }
        }
        final best = ptBR ?? ptAny;
        if (best != null) {
          _selectedLocaleId = _toBcp47(best.localeId);
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      _speechEnabled = false;
    }
  }

  void _setVoiceLanguage(String localeId, String label) {
    setState(() {
      _selectedLocaleId = localeId;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🎙️ Idioma do microfone: $label'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleListening() async {
    if (!_speechEnabled) {
      _initSpeech();
      return;
    }

    if (_isListening) {
      await _speech.stop();
      if (mounted) {
        setState(() {
          _isListening = false;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isListening = true;
        });
      }
      await _speech.listen(
        localeId: _selectedLocaleId,
        cancelOnError: false,
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        onResult: (result) {
          if (mounted) {
            setState(() {
              _textController.text = result.recognizedWords;
            });
          }
        },
      );
    }
  }

  void _addInitialWelcomeMessage() {
    _messages.add(
      ChatMessage(
        id: 'welcome',
        sender: MessageSender.assistant,
        text: 'Olá! Sou o assistente virtual do Krezio.ai, guiado por dados. Como posso te ajudar com suas finanças hoje?\n\nDigite um gasto, receita, cole uma notificação de banco ou faça perguntas sobre seus valores.',
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

    // 1. Check for Contextual Corrections on Previous Completed Transaction
    final lower = text.toLowerCase();
    final isCorrectionIntent = _lastCompletedDraft != null &&
        (_activeDraft == null || _activeDraft!.isComplete) &&
        (lower.startsWith('na verdade') ||
            lower.startsWith('troca') ||
            lower.startsWith('muda') ||
            lower.startsWith('cancela') ||
            lower.startsWith('apaga') ||
            lower.startsWith('foi no') ||
            lower.startsWith('foi em') ||
            lower.startsWith('desconsidera'));

    if (isCorrectionIntent) {
      final updated = widget.engine.applyCorrection(_lastCompletedDraft!, text);
      _lastCompletedDraft = updated.isCanceled ? null : updated;
      _lastLatencyMs = updated.latencyMs;

      final assistantMsg = ChatMessage(
        id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
        sender: MessageSender.assistant,
        text: updated.clarificationPrompt ?? 'Lançamento atualizado com sucesso! ✨',
        timestamp: DateTime.now(),
        draft: updated.isCanceled ? null : updated,
        isMergedUpdate: true,
      );

      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        setState(() {
          _messages.add(assistantMsg);
        });
        _scrollToBottom();
      });
      return;
    }

    // 2. Check for Multi-Transaction Batch Split
    if (_activeDraft == null || _activeDraft!.isComplete) {
      final multiDrafts = widget.engine.parseMulti(text);
      if (multiDrafts.length >= 2) {
        final buffer = StringBuffer();
        buffer.writeln('Identifiquei ${multiDrafts.length} lançamentos:');
        for (int i = 0; i < multiDrafts.length; i++) {
          final d = multiDrafts[i];
          final amt = d.amount != null ? 'R\$ ${d.amount!.toStringAsFixed(2).replaceAll('.', ',')}' : '';
          final pay = _formatPayment(d.paymentMethod, d.installments);
          buffer.writeln('${i + 1}. $amt com ${d.description} ($pay)');
        }
        buffer.write('\nTodos foram registrados com sucesso! 🎉');

        for (final d in multiDrafts) {
          widget.repository?.addTransactionFromDraft(d);
        }

        _lastCompletedDraft = multiDrafts.last;
        _lastLatencyMs = multiDrafts.fold(0.0, (acc, d) => acc + d.latencyMs);

        final assistantMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          sender: MessageSender.assistant,
          text: buffer.toString(),
          timestamp: DateTime.now(),
          draft: multiDrafts.first,
        );

        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          setState(() {
            _messages.add(assistantMsg);
          });
          _scrollToBottom();
        });
        return;
      }
    }

    // 3. Process Standard Single-Turn or Follow-up Merge
    FinancialTransactionDraft draft;
    bool isMerged = false;

    if (_activeDraft != null && !_activeDraft!.isComplete) {
      draft = widget.engine.mergeDrafts(_activeDraft!, text);
      isMerged = true;
    } else {
      draft = widget.engine.parse(text);
    }

    String responseText = draft.clarificationPrompt ?? 'Lançamento registrado com sucesso! 🎉';

    if (draft.isComplete) {
      widget.repository?.addTransactionFromDraft(draft);

      final amountStr = draft.amount != null ? 'R\$ ${draft.amount!.toStringAsFixed(2).replaceAll('.', ',')}' : '';
      final itemOrPlace = (draft.description.isNotEmpty && draft.description != 'unknown' && draft.description != 'expense_other')
          ? ' com ${draft.description}'
          : '';

      final bankTag = draft.bankSource != null ? ' via ${draft.bankSource}' : '';
      final recurrentTag = draft.isRecurrent ? ' (Recorrente todo dia ${draft.dueDay ?? 10})' : '';

      if (draft.intent == 'income') {
        responseText = 'Pronto! Receita de $amountStr$itemOrPlace$bankTag adicionada ao seu saldo. ✨';
      } else if (draft.intent == 'transfer') {
        responseText = 'Pronto! Transferência de $amountStr$itemOrPlace$bankTag registrada com sucesso. 💸';
      } else if (draft.paymentMethod == 'credit_card' && draft.installments != null && draft.installments! > 1 && draft.amount != null) {
        final perInst = (draft.amount! / draft.installments!).toStringAsFixed(2).replaceAll('.', ',');
        responseText = 'Pronto! Registrei $amountStr$itemOrPlace no crédito em ${draft.installments}x de R\$ $perInst$recurrentTag. 🎉';
      } else if (draft.paymentMethod != 'unknown') {
        final payName = _formatPayment(draft.paymentMethod, draft.installments);
        responseText = 'Pronto! Despesa de $amountStr$itemOrPlace no $payName$bankTag$recurrentTag registrada com sucesso. 🎉';
      } else {
        responseText = 'Pronto! Lançamento de $amountStr$itemOrPlace registrado com sucesso. 🎉';
      }

      if (draft.budgetInsight != null) {
        responseText += '\n\n${draft.budgetInsight}';
      }

      _lastCompletedDraft = draft;
      _activeDraft = null; // Transaction completed!
    } else {
      _activeDraft = draft; // Keep listening for missing context
    }
    _lastLatencyMs = draft.latencyMs;

    if (draft.intent == 'query') {
      final itemOrPlace = (draft.description.isNotEmpty && draft.description != 'unknown' && draft.description != 'expense_other')
          ? ' para ${draft.description}'
          : '';
      responseText = 'Consultando seus registros$itemOrPlace... Tudo em ordem!';
      _activeDraft = null;
    } else if (draft.intent == 'unknown' && !isMerged) {
      responseText = draft.clarificationPrompt ?? 'Como posso te ajudar com suas finanças hoje?';
      _activeDraft = null;
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
          PopupMenuButton<String>(
            icon: const Icon(Icons.language_rounded),
            tooltip: 'Idioma da Voz',
            onSelected: (localeId) {
              final labels = {
                'pt-BR': 'Português (Brasil)',
                'en-US': 'English (United States)',
                'es-ES': 'Español (España)',
              };
              _setVoiceLanguage(localeId, labels[localeId] ?? localeId);
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'pt-BR',
                child: Row(
                  children: [
                    const Text('🇧🇷 '),
                    const SizedBox(width: 8),
                    Text('Português (Brasil)', style: TextStyle(fontWeight: _selectedLocaleId.contains('pt') ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'en-US',
                child: Row(
                  children: [
                    const Text('🇺🇸 '),
                    const SizedBox(width: 8),
                    Text('English (US)', style: TextStyle(fontWeight: _selectedLocaleId.contains('en') ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'es-ES',
                child: Row(
                  children: [
                    const Text('🇪🇸 '),
                    const SizedBox(width: 8),
                    Text('Español (España)', style: TextStyle(fontWeight: _selectedLocaleId.contains('es') ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              ),
            ],
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
                    color: _isListening ? Colors.redAccent : (isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface),
                    borderRadius: KrezioTheme.borderRadius,
                    child: InkWell(
                      borderRadius: KrezioTheme.borderRadius,
                      onTap: _toggleListening,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                          color: _isListening ? Colors.white : (isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText),
                          size: 20,
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

          // Contextual Quick Action Chips for Missing Slots
          if (!isUser && msg.draft != null && !msg.draft!.isComplete) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: _buildMissingSlotsQuickChips(msg.draft!, isDark),
            ),
          ],

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

  Widget _buildMissingSlotsQuickChips(FinancialTransactionDraft draft, bool isDark) {
    if (draft.missingSlots.contains('installments')) {
      final installmentOptions = [
        {'label': '⚡ À vista (1x)', 'value': 'à vista'},
        {'label': '💳 2x', 'value': 'em 2x'},
        {'label': '💳 3x', 'value': 'em 3x'},
        {'label': '💳 6x', 'value': 'em 6x'},
        {'label': '💳 10x', 'value': 'em 10x'},
        {'label': '💳 12x', 'value': 'em 12x'},
      ];

      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: installmentOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _sendMessage(opt['value']!),
          );
        }).toList(),
      );
    }

    if (draft.missingSlots.contains('category')) {
      final categoryOptions = [
        {'label': '🛒 Mercado', 'value': 'no mercado'},
        {'label': '🍔 Alimentação', 'value': 'restaurante / lanche'},
        {'label': '🚗 Transporte', 'value': 'uber / combustível'},
        {'label': '💊 Farmácia', 'value': 'na farmácia'},
        {'label': '🏠 Moradia', 'value': 'conta de casa'},
      ];

      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: categoryOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _sendMessage(opt['value']!),
          );
        }).toList(),
      );
    }

    if (draft.isRecurrent && (draft.missingSlots.contains('due_day') || draft.missingSlots.contains('recurrence_duration'))) {
      final nowDay = DateTime.now().day;
      final subOptions = <Map<String, String>>[];
      if (draft.missingSlots.contains('due_day')) {
        subOptions.addAll([
          {'label': '📅 Renova hoje (dia $nowDay)', 'value': 'renova dia $nowDay'},
          {'label': '📅 Todo dia 5', 'value': 'todo dia 5'},
          {'label': '📅 Todo dia 10', 'value': 'todo dia 10'},
          {'label': '📅 Todo dia 15', 'value': 'todo dia 15'},
        ]);
      }
      if (draft.missingSlots.contains('recurrence_duration')) {
        subOptions.addAll([
          {'label': '♾️ Tempo indeterminado', 'value': 'tempo indeterminado'},
          {'label': '📅 Plano Anual', 'value': 'anual'},
          {'label': '📅 12 meses', 'value': '12 meses'},
        ]);
      }
      if (draft.missingSlots.contains('payment_method')) {
        subOptions.addAll([
          {'label': '💳 Crédito', 'value': 'no crédito'},
          {'label': '⚡ Pix', 'value': 'no pix'},
          {'label': '💳 Débito', 'value': 'no débito'},
        ]);
      }
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: subOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _sendMessage(opt['value']!),
          );
        }).toList(),
      );
    }

    if (draft.missingSlots.contains('payment_method')) {
      final isCardAmbiguous = draft.rawText.toLowerCase().contains('cart') || draft.rawText.toLowerCase().contains('cratao');
      final paymentOptions = isCardAmbiguous
          ? [
              {'label': '💳 Débito', 'value': 'no débito'},
              {'label': '💳 Crédito', 'value': 'no crédito'},
              {'label': '⚡ Pix', 'value': 'no pix'},
              {'label': '💵 Dinheiro', 'value': 'em dinheiro'},
            ]
          : [
              {'label': '⚡ Pix', 'value': 'no pix'},
              {'label': '💳 Débito', 'value': 'no débito'},
              {'label': '💳 Crédito', 'value': 'no crédito'},
              {'label': '💵 Dinheiro', 'value': 'em dinheiro'},
              {'label': '📄 Boleto', 'value': 'no boleto'},
            ];

      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: paymentOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _sendMessage(opt['value']!),
          );
        }).toList(),
      );
    }

    if (draft.missingSlots.length == 1 && draft.missingSlots.contains('amount')) {
      final amountOptions = [
        {'label': 'R\$ 20', 'value': '20'},
        {'label': 'R\$ 35', 'value': '35'},
        {'label': 'R\$ 50', 'value': '50'},
        {'label': 'R\$ 100', 'value': '100'},
      ];

      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: amountOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _sendMessage(opt['value']!),
          );
        }).toList(),
      );
    }

    return const SizedBox.shrink();
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
                  _formatPayment(draft.paymentMethod, draft.installments),
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

          if (draft.bankSource != null || draft.isRecurrent) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (draft.bankSource != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: KrezioColors.aiPurple.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '🏦 ${draft.bankSource}',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: KrezioColors.aiPurple),
                    ),
                  ),
                if (draft.isRecurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: KrezioColors.emeraldGreen.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      draft.dueDay != null
                          ? '🔁 Recorrente (Dia ${draft.dueDay}${draft.recurrenceDuration != null ? " • ${draft.recurrenceDuration}" : ""})'
                          : '🔁 Assinatura Mensal${draft.recurrenceDuration != null ? " (${draft.recurrenceDuration})" : ""}',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: KrezioColors.emeraldGreen),
                    ),
                  ),
              ],
            ),
          ],

          if (draft.missingSlots.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: KrezioColors.friendlyOrange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Slots ausentes: ${draft.missingSlots.map(_formatMissingSlotName).join(", ")}',
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
      case 'expense_other':
        return 'Outros / Serviços';
      case 'income_other':
        return 'Outras Receitas';
      default:
        return cat == 'unknown' ? 'Ausente' : cat;
    }
  }

  String _formatPayment(String pay, [int? installments]) {
    switch (pay) {
      case 'pix':
        return 'PIX';
      case 'credit_card':
        if (installments != null && installments > 1) {
          return 'Crédito (${installments}x)';
        } else if (installments == 1) {
          return 'Crédito (À vista)';
        }
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

  String _formatMissingSlotName(String slot) {
    switch (slot) {
      case 'amount':
        return 'Valor';
      case 'payment_method':
        return 'Forma de pagamento';
      case 'category':
        return 'Categoria';
      case 'installments':
        return 'Parcelas';
      case 'due_day':
        return 'Dia de renovação';
      case 'recurrence_duration':
        return 'Prazo da assinatura';
      default:
        return slot;
    }
  }
}
