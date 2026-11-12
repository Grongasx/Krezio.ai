import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../../../../../ai/local_nlp_engine.dart';
import '../../../../../ai/chat_draft_tracker.dart';
import '../../../../../ai/transaction_code.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../navigation/krezio_routes.dart';
import '../../../../../backend/services/feedback_service.dart';
import '../../../../../backend/models/financial_reminder.dart';
import '../../../../../backend/models/budget_category.dart';
import '../../../../../backend/services/calendar_service.dart';
import '../../../../../ai/voice/voice_synthesis_service.dart';
import '../../../../../ai/voice/voice_conversation_controller.dart';
import '../../../../../backend/config/app_environment.dart';
import '../../../../../ai/financial_report_rag_engine.dart';
import '../../../../../ai/debt_payment_parser.dart';
import '../../../../../ai/goal_parser.dart';
import '../../../../../ai/affordability_analyzer.dart';
import '../../../../../ai/cesar_assistant.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../../../../../backend/models/financial_goal.dart';
import '../../../homologation/presentation/screens/neural_inspector_screen.dart';
import '../../../dashboard/presentation/widgets/category_donut_chart.dart';
import '../widgets/report_bar_chart.dart';
import '../widgets/voice_conversation_modal.dart';
import '../../../../../backend/services/money.dart';

enum MessageSender { user, assistant }

class ChatMessage {
  final String id;
  final MessageSender sender;
  final String text;
  final DateTime timestamp;
  final FinancialTransactionDraft? draft;
  final bool isMergedUpdate;
  final String? spokenText;
  final ReportChartData? chart;

  /// Identity of the draft this card shows: its quick-reply chips act on
  /// that draft (or on what it was saved as), not on the pending one.
  final String? draftKey;

  /// Records this card was saved as — their codes ("#4821") are shown on it.
  final List<String> transactionIds;

  ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.draft,
    this.isMergedUpdate = false,
    this.spokenText,
    this.chart,
    this.draftKey,
    this.transactionIds = const [],
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
  final FocusNode _messageFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechEnabled = false;

  FinancialTransactionDraft? _activeDraft;
  FinancialTransactionDraft? _lastCompletedDraft;

  /// A multi-transaction message ("50 no mercado e 30 na farmácia") still
  /// missing something — nothing is saved until every item is complete.
  List<FinancialTransactionDraft>? _pendingBatch;

  /// Ids of the transaction(s) [_lastCompletedDraft] was saved as (several for
  /// daily payments), so a follow-up correction ("na verdade é roupas") or
  /// "cancela" changes the real records, not just the chat card.
  List<String> _lastSavedTransactionIds = const [];

  /// Which card each draft belongs to, and what it was saved as.
  final ChatDraftTracker _drafts = ChatDraftTracker();

  /// "Isso ajudou?" votes already given, per message id.
  final Map<String, bool> _rated = {};
  double _lastLatencyMs = 0.0;

  late final VoiceSynthesisService _voiceSynthesis = VoiceSynthesisService();

  /// Edit/delete/undo by chat, corrections and questions about the data —
  /// shared with the voice conversation so both keep the same context.
  late final CesarAssistant? _assistant =
      widget.repository == null ? null : CesarAssistant(repository: widget.repository!, engine: widget.engine);

  late final VoiceConversationController _voiceController = VoiceConversationController(
    engine: widget.engine,
    repository: widget.repository,
    voiceSynthesisService: _voiceSynthesis,
    sttInstance: _speech,
    assistant: _assistant,
  );

  static const _suggestionCategories = [
    (
      'Lançamentos',
      Icons.flash_on,
      [
        ('Gasto no mercado', 'Gastei 45,90 no mercado no Pix'),
        ('Almoço / restaurante', 'Paguei 58 no almoço no débito'),
        ('Abastecer combustível', 'Abasteci 150 no posto via Pix'),
        ('Compra parcelada', 'Comprei um tênis de 299 no crédito em 3x'),
        ('Receber salário', 'Recebi 3.500 de salário no Pix'),
        ('Conta recorrente', 'Todo mês pago 120 de internet dia 10 no Pix'),
      ],
    ),
    (
      'Dividir & Empréstimos',
      Icons.group_outlined,
      [
        ('Dividir conta do jantar', 'Fui em um jantar, o total deu 320, dividimos em 3'),
        ('Dividir transporte / Uber', 'Rachei o Uber de 45 com um amigo'),
        ('Empréstimo (5º dia útil)', 'Emprestei 150 pro João, ele disse que ia pagar quando recebesse'),
        ('Receber dívida total', 'O João me pagou tudo'),
        ('Receber parte da dívida', 'A Maria me acertou 50 reais'),
      ],
    ),
    (
      'Consultas & Boletos',
      Icons.analytics_outlined,
      [
        ('Gastos com mercado', 'Quanto eu gastei com mercado este mês?'),
        ('Boletos da semana', 'Quais boletos vencem essa semana?'),
        ('Maior gasto do mês', 'Qual foi meu maior gasto este mês?'),
        ('Saldo disponível', 'Quanto ainda posso gastar este mês?'),
        ('Quem está me devendo', 'Quem está me devendo e quanto falta receber?'),
      ],
    ),
    (
      'Planejar & Economizar',
      Icons.lightbulb_outline,
      [
        ('Simular compra', 'Posso gastar 200 no restaurante hoje?'),
        ('Cortar delivery', 'Se eu cortar delivery quanto economizo?'),
        ('Resumo da semana', 'Como foram meus gastos nesta semana?'),
        ('Status dos orçamentos', 'Como estão meus orçamentos este mês?'),
      ],
    ),
    (
      'Ajustes & Correções',
      Icons.edit_outlined,
      [
        ('Desfazer último', 'Desfaz o último lançamento'),
        ('Corrigir valor', 'Na verdade foi 52'),
        ('Trocar pagamento', 'Muda a forma de pagamento do último para Pix'),
        ('Excluir lançamento', 'Apaga o último lançamento'),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _voiceSynthesis.initialize();
    _voiceController.onUserSpoken = (userPhrase) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          id: 'voice-user-${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.user,
          text: userPhrase,
          timestamp: DateTime.now(),
        ));
      });
      _scrollToBottom();
    };
    _voiceController.onSystemMessage = (text, {spokenText}) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          id: 'voice-sys-${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.assistant,
          text: text,
          timestamp: DateTime.now(),
          spokenText: spokenText,
        ));
      });
      _scrollToBottom();
    };
    _voiceController.onTransactionCompleted = (completedDraft) {
      if (!mounted) return;
      final draftKey = _drafts.startDraft();
      _saveCompletedDraft(completedDraft);
      _drafts.saved(_lastSavedTransactionIds);
      final amountStr = completedDraft.amount != null ? Money.brl(completedDraft.amount!) : '';
      final itemOrPlace = (completedDraft.description.isNotEmpty &&
              completedDraft.description != 'unknown' &&
              completedDraft.description != 'expense_other')
          ? ' com ${completedDraft.description}'
          : '';
      final cardText = completedDraft.intent == 'income'
          ? 'Pronto! Receita de $amountStr$itemOrPlace adicionada ao seu saldo. ✨'
          : 'Pronto! Lançamento de $amountStr$itemOrPlace registrado por voz. 🎉';
      setState(() {
        _lastCompletedDraft = completedDraft;
        _activeDraft = null;
        _lastLatencyMs = completedDraft.latencyMs;
        _messages.add(ChatMessage(
          id: 'voice-tx-${DateTime.now().microsecondsSinceEpoch}',
          sender: MessageSender.assistant,
          text: cardText,
          timestamp: DateTime.now(),
          draft: completedDraft,
          draftKey: draftKey,
          transactionIds: _lastSavedTransactionIds,
        ));
      });
      _scrollToBottom();
    };
    _voiceController.onAssistantReply = (reply) {
      if (!mounted) return;
      _syncAfterAssistant(reply);
      _drafts.dropped();
      setState(() {
        _activeDraft = null;
        _messages.add(ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          sender: MessageSender.assistant,
          text: reply.text,
          timestamp: DateTime.now(),
          spokenText: reply.spokenText,
          chart: reply.chart,
        ));
      });
      _scrollToBottom();
    };
    _voiceController.onReportGenerated = (reportResult) {
      if (!mounted) return;
      final assistantMsg = ChatMessage(
        id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
        sender: MessageSender.assistant,
        text: reportResult.formattedText,
        timestamp: DateTime.now(),
        spokenText: reportResult.spokenText,
        chart: reportResult.chart,
      );
      setState(() {
        _messages.add(assistantMsg);
      });
      _scrollToBottom();
    };
    _addInitialWelcomeMessage();
    KrezioRoutes.pendingLink.addListener(_onLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onLink());
  }

  /// "krezio://app/chat?frase=gastei 30 no uber" sends the sentence;
  /// "…?voz=1" opens the voice conversation.
  void _onLink() {
    final link = KrezioRoutes.pendingLink.value;
    if (!mounted || link == null || KrezioRoutes.tabFor(link.path) != KrezioRoutes.tabs.indexOf(KrezioRoutes.chat)) return;
    final phrase = KrezioRoutes.phraseIn(link);
    final voice = KrezioRoutes.wantsVoice(link);
    if (phrase == null && !voice) return;
    KrezioRoutes.pendingLink.value = null;
    if (phrase != null) _sendMessage(phrase);
    if (voice) _openVoiceConversationModal();
  }

  @override
  void dispose() {
    KrezioRoutes.pendingLink.removeListener(_onLink);
    _textController.dispose();
    _messageFocus.dispose();
    _scrollController.dispose();
    _voiceController.dispose();
    // VoiceSynthesisService is an app-wide singleton: disposing it here killed
    // its notifiers for the rest of the session (e.g. voice broke after
    // signing out and back in, which rebuilds this screen). Just stop it.
    _voiceSynthesis.stop();
    super.dispose();
  }

  void _openVoiceConversationModal() {
    _stopListeningIfActive();
    VoiceConversationModal.show(context, _voiceController);
  }

  void _saveCompletedDraft(FinancialTransactionDraft draft) {
    _lastSavedTransactionIds = _saveDraft(draft);
    _assistant?.recordCreated(_lastSavedTransactionIds);

    if (draft.isReminder && widget.repository != null) {
      final reminder = FinancialReminder(
        id: 'rem-${DateTime.now().millisecondsSinceEpoch}',
        title: draft.description,
        personName: draft.personName,
        amount: draft.amount,
        targetDate: draft.targetDate ?? DateTime.now().add(const Duration(days: 30)),
        type: draft.reminderType == 'loan_receivable'
            ? ReminderType.loanReceivable
            : (draft.reminderType == 'dividend' ? ReminderType.dividend : ReminderType.general),
        notes: draft.calendarConsultationNote,
      );
      widget.repository!.addReminder(reminder);

      widget.engine.calendarService.addEvent(
        title: reminder.title,
        dateTime: reminder.targetDate,
        category: draft.reminderType == 'loan_receivable'
            ? CalendarEventCategory.loanReceivable
            : (draft.reminderType == 'dividend' ? CalendarEventCategory.dividend : CalendarEventCategory.personalReminder),
        amount: reminder.amount,
        personName: reminder.personName,
        notes: reminder.notes,
      );
    }
  }

  String _selectedLocaleId = 'pt-BR';

  /// Convert locale ID to BCP 47 hyphen format for Web Speech API
  String _toBcp47(String localeId) => localeId.replaceAll('_', '-');

  void _initSpeech() async {
    try {
      _speechEnabled = await _speech.initialize(
        onStatus: (status) {
          if (_voiceController.isSessionActive) {
            _voiceController.handleExternalSttStatus(status);
          }
          if (status == 'done' || status == 'notListening') {
            if (mounted && _isListening) {
              setState(() {
                _isListening = false;
              });
            }
          }
        },
        onError: (errorNotification) {
          if (_voiceController.isSessionActive) {
            _voiceController.handleExternalSttError(errorNotification);
          }
          if (mounted && _isListening) {
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

  Future<void> _stopListeningIfActive() async {
    if (_isListening || _speech.isListening) {
      if (mounted) {
        setState(() {
          _isListening = false;
        });
      } else {
        _isListening = false;
      }
      try {
        await _speech.stop();
      } catch (_) {}
    }
  }

  void _toggleListening() async {
    if (!_speechEnabled) {
      _initSpeech();
      return;
    }

    if (_isListening) {
      await _stopListeningIfActive();
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
          if (!mounted || !_isListening) return;
          setState(() {
            _textController.text = result.recognizedWords;
          });
        },
      );
    }
  }

  /// Extracts a trailing category name from a correction phrase, e.g. "na
  /// verdade é pets" -> "pets", "muda a categoria pra assinaturas de app" ->
  /// "assinaturas de app". Used to match against the user's custom categories
  /// when the built-in category names in the engine don't apply.
  String? _extractSpokenCategoryName(String text) {
    final lower = text.toLowerCase();
    final match = RegExp(
      r'(?:na verdade (?:é|e|foi)|isso (?:é|e|foi)|categoria (?:é|e|foi)?\s*(?:pra|para)?|'
      r'muda(?:r)?\s+(?:a\s+)?categoria\s+(?:pra|para)?)\s*([a-zà-ÿ0-9\s]+)\s*$',
    ).firstMatch(lower);
    final name = match?.group(1)?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  void _addInitialWelcomeMessage() {
    _messages.add(
      ChatMessage(
        id: 'welcome',
        sender: MessageSender.assistant,
        text: 'Olá${_assistant?.userName != null ? ', ${_assistant!.userName}' : ''}! Eu sou o César, seu copiloto financeiro no Krezio.ai, e interpreto comandos no seu aparelho. Como posso te ajudar com suas finanças hoje?\n\nDigite um gasto, receita, agende um lembrete, cole notificações de banco ou me pergunte o que quiser!',
        timestamp: DateTime.now(),
      ),
    );

    // Proactive alerts: César opens the conversation mentioning anything
    // time-sensitive on its own, instead of waiting to be asked.
    final alerts = widget.repository?.getProactiveAlerts() ?? const [];
    if (alerts.isNotEmpty) {
      final bullet = alerts.take(3).map((a) => '- ${a.message}').join('\n');
      _messages.add(
        ChatMessage(
          id: 'proactive-${DateTime.now().millisecondsSinceEpoch}',
          sender: MessageSender.assistant,
          text: '⚡ Antes de mais nada, um alerta:\n\n$bullet',
          timestamp: DateTime.now(),
        ),
      );
    }
    // Weekly summary (once a week) and out-of-pattern spending.
    for (final note in _assistant?.openingNotes() ?? const <String>[]) {
      _messages.add(ChatMessage(
        id: 'note-${DateTime.now().microsecondsSinceEpoch}-${_messages.length}',
        sender: MessageSender.assistant,
        text: note,
        timestamp: DateTime.now(),
      ));
    }
  }

  void _sendMessage(String input) {
    _stopListeningIfActive();
    var text = input.trim();
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

    // The engine only knows the built-in categories; hand it the user's own
    // so "comprei roupas" or answering "roupa" lands in their "Roupas".
    if (widget.repository != null) {
      widget.engine.setCustomCategories(widget.repository!.customCategoryNames);
    }
    _assistant?.beginTurn();

    // 0. "cancela" / "esquece" while César is still asking about a draft —
    // drop it instead of merging the words into it and asking again.
    if (_activeDraft != null && !_activeDraft!.isComplete && widget.engine.isCancelCommand(text, pending: _activeDraft)) {
      _activeDraft = null;
      _drafts.dropped();
      _replyAsAssistant('Tudo bem, descartei esse lançamento. Nada foi registrado. 👍');
      return;
    }

    // 0b. Answer to the shared question about an unfinished batch ("foram no
    // Pix?"). A brand-new sentence drops the batch and is handled normally.
    if (_pendingBatch != null) {
      final batch = _pendingBatch!;
      if (widget.engine.isCancelCommand(text, pending: batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first))) {
        _pendingBatch = null;
        _replyAsAssistant('Tudo bem, descartei esses lançamentos. Nada foi registrado. 👍');
        return;
      }
      // "e se fosse no pix?" asks about the batch — answer it and keep the
      // batch waiting; merged, it saved both entries (CHAOS-A-003).
      final whatIf = _assistant?.hypothesisReply(text);
      if (whatIf != null) {
        _showAssistantReply(whatIf, speak: true);
        return;
      }
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (!widget.engine.startsNewTransaction(firstOpen, text)) {
        final merged = widget.engine.mergeMultiDrafts(batch, text);
        final prompt = widget.engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          _pendingBatch = null;
          _saveBatch(merged);
        } else {
          _pendingBatch = merged;
          _replyAsAssistant(prompt);
        }
        return;
      }
      _pendingBatch = null;
    }

    // 1. Edit / delete / undo by chat and free-language corrections ("não,
    // foi 45", "esse era lazer", "exclui o uber de ontem", "desfaz"), plus
    // answers to César's own pending questions (confirm a delete, pick one).
    final assistant = _assistant;
    if (assistant != null) {
      final reply = assistant.handleCommand(text, hasPendingDraft: _activeDraft != null && !_activeDraft!.isComplete);
      if (reply != null && reply.rewrittenInput != null) {
        // "e 30 na padaria" → "gastei 30 na padaria no pix": continue as a new entry.
        text = reply.rewrittenInput!;
      } else if (reply != null) {
        _showAssistantReply(reply, speak: false);
        return;
      }
    }

    // 1b. Due-date rule on the last recurring entry ("é todo quinto dia
    // útil", "vence todo dia 10") — the one correction the engine's draft
    // logic still owns. Everything else is handled by the assistant above.
    final lower = text.toLowerCase();
    final isCorrectionIntent = _lastCompletedDraft != null &&
        (_activeDraft == null || _activeDraft!.isComplete) &&
        _lastCompletedDraft!.isRecurrent &&
        RegExp(r'dia\s+[uú]til|\b(?:todo|vence(?:\s+no)?|cai(?:\s+no)?)\s+dia\s+\d').hasMatch(lower) &&
        !RegExp(r'\d+(?:[.,]\d+)?\s*(?:reais|real)|r\$').hasMatch(lower);

    if (isCorrectionIntent) {
      final previousDraft = _lastCompletedDraft!;
      var updated = widget.engine.applyCorrection(previousDraft, text);
      _lastCompletedDraft = updated.isCanceled ? null : updated;
      _lastLatencyMs = updated.latencyMs;

      // The engine only recognizes Krezio's built-in category names. If it
      // didn't change anything, see if the user instead named one of *their*
      // custom categories (e.g. "na verdade é pets").
      if (!updated.isCanceled && updated.category == previousDraft.category && widget.repository != null) {
        final spokenName = _extractSpokenCategoryName(text);
        final customCode = (spokenName != null ? widget.repository!.findCustomCategoryCode(spokenName) : null) ??
            widget.engine.matchCustomCategory(text);
        if (customCode != null && customCode != updated.category) {
          final categoryName = widget.repository!.budgets.firstWhere((b) => b.category == customCode).name;
          updated = updated.copyWith(
            category: customCode,
            clarificationPrompt: 'Pronto! Movi esse lançamento para a categoria $categoryName. ✨',
          );
          _lastCompletedDraft = updated;
        }
      }

      // Apply the correction to the saved record itself (or delete it on
      // "cancela") — otherwise only the chat card changed.
      if (widget.repository != null) {
        final before = widget.repository!.transactions.where((t) => _lastSavedTransactionIds.contains(t.id)).toList();
        final learnsCategory = !updated.isCanceled && updated.category != previousDraft.category;
        if (!updated.isCanceled) {
          _assistant?.recordExternalEdit(before,
              learned: learnsCategory ? {updated.description: widget.repository!.recallCategoryOverride(updated.description)} : const {});
        }
        for (final savedId in _lastSavedTransactionIds) {
          if (updated.isCanceled) {
            widget.repository!.deleteTransaction(savedId);
          } else {
            widget.repository!.applyDraftCorrection(savedId, updated);
          }
        }
        if (updated.isCanceled) _lastSavedTransactionIds = const [];
      }

      // Category memory: once the user corrects how something is categorized,
      // remember it (persisted) so future transactions described the same way
      // are categorized correctly right away — no need to correct twice.
      if (!updated.isCanceled && updated.category != previousDraft.category) {
        widget.repository?.rememberCategoryOverride(updated.description, updated.category);
      }

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

    // 2. Check for Debt Repayment ("o João me pagou a dívida dele, porém apenas 70 reais")
    // With no open debt in that name it is ordinary income ("a maria me
    // devolveu 50", "o chefe me pagou 1500") — it continues below as a normal
    // entry instead of ending the conversation with nothing recorded.
    String? preface;
    if (widget.repository != null) {
      final resolved = DebtPaymentParser.resolveForRepository(text, widget.repository!);
      final debtPayment = resolved?.match;
      final List<FinancialReminder> matches = resolved?.matches ?? const [];
      if (debtPayment != null && matches.isEmpty) {
        preface = DebtPaymentParser.noOpenDebtNote(debtPayment.personName);
      } else if (debtPayment != null) {
        String responseText;

        if (matches.length > 1) {
          responseText = 'Encontrei mais de uma cobrança pendente no nome de ${debtPayment.personName}. '
              'Pode me dizer o valor original da dívida para eu identificar qual é?';
        } else {
          final result = widget.repository!.applyDebtPayment(matches.first.id, debtPayment.amountPaid);
          responseText = DebtPaymentParser.paymentReply(
            debtPayment.personName,
            paid: result.amountPaid,
            remaining: result.remainingBalance,
            fullyPaid: result.isFullyPaid,
            excess: result.excess,
          );
        }

        final assistantMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          sender: MessageSender.assistant,
          text: responseText,
          timestamp: DateTime.now(),
        );

        _voiceSynthesis.speak(responseText);

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

    // 3. Check for Savings Goal creation/contribution
    // ("quero juntar 5000 para uma viagem até dezembro" / "guardei 100 na minha meta da viagem")
    if (widget.repository != null) {
      final goalCreation = GoalParser.parseCreation(text);
      if (goalCreation != null) {
        final goal = FinancialGoal(
          id: 'goal-${DateTime.now().millisecondsSinceEpoch}',
          title: goalCreation.title,
          targetAmount: goalCreation.targetAmount,
          targetDate: goalCreation.targetDate,
        );
        widget.repository!.addGoal(goal);

        final targetStr = '${Money.brl(goalCreation.targetAmount)}';
        var responseText = 'Meta criada! Vou te ajudar a juntar $targetStr para "${goalCreation.title}".';
        final monthly = goal.suggestedMonthlyContribution;
        if (monthly != null) {
          responseText += ' Guardando ${Money.brl(monthly)} por mês você chega lá a tempo. 🎯';
        } else {
          responseText += ' Quando quiser, é só me dizer quanto guardou. 🎯';
        }

        final assistantMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          sender: MessageSender.assistant,
          text: responseText,
          timestamp: DateTime.now(),
        );
        _voiceSynthesis.speak(responseText);
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          setState(() => _messages.add(assistantMsg));
          _scrollToBottom();
        });
        return;
      }

      final goalContribution = GoalParser.parseContribution(text);
      if (goalContribution != null) {
        final matches = widget.repository!.findGoalsByTitle(goalContribution.goalTitle);
        String responseText;

        if (matches.isEmpty) {
          responseText = 'Não encontrei nenhuma meta chamada "${goalContribution.goalTitle}". Quer criar uma nova meta com esse valor?';
        } else if (matches.length > 1) {
          responseText = 'Encontrei mais de uma meta parecida com "${goalContribution.goalTitle}". Pode ser mais específico?';
        } else {
          final updated = widget.repository!.contributeToGoal(matches.first.id, goalContribution.amount);
          final savedStr = '${Money.brl(updated.savedAmount)}';
          final targetStr = '${Money.brl(updated.targetAmount)}';
          if (updated.isCompleted) {
            responseText = 'Parabéns! 🎉 Você bateu a meta "${updated.title}": $savedStr guardados!';
          } else {
            final percent = (updated.progress * 100).toStringAsFixed(0);
            responseText = 'Anotado! "${updated.title}" já tem $savedStr de $targetStr guardados ($percent%).';
          }
        }

        final assistantMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          sender: MessageSender.assistant,
          text: responseText,
          timestamp: DateTime.now(),
        );
        _voiceSynthesis.speak(responseText);
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          setState(() => _messages.add(assistantMsg));
          _scrollToBottom();
        });
        return;
      }
    }

    // 4. Check for Affordability Questions ("posso comprar um notebook de 3000?")
    if (widget.repository != null) {
      final affordability = AffordabilityAnalyzer(repository: widget.repository!).analyze(text);
      if (affordability != null) {
        final assistantMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          sender: MessageSender.assistant,
          text: affordability.formattedText,
          timestamp: DateTime.now(),
          spokenText: affordability.spokenText,
        );
        _voiceSynthesis.speak(affordability.formattedText);
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          setState(() => _messages.add(assistantMsg));
          _scrollToBottom();
        });
        return;
      }
    }

    // 5. Questions about the data ("qual meu maior gasto?", "tô no
    // vermelho?", "quanto gastei com mercado?" ⏎ "e no mês passado?").
    if (assistant != null) {
      final answer = assistant.handleQuestion(text, hasPendingDraft: _activeDraft != null && !_activeDraft!.isComplete);
      if (answer != null) {
        _showAssistantReply(answer, speak: true);
        return;
      }
    } else if (widget.repository != null && FinancialReportRagEngine.isReportQuery(text)) {
      final ragEngine = FinancialReportRagEngine(repository: widget.repository!);
      final reportResult = ragEngine.generateReport(text, history: _messages);

      final assistantMsg = ChatMessage(
        id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
        sender: MessageSender.assistant,
        text: reportResult.formattedText,
        timestamp: DateTime.now(),
        spokenText: reportResult.spokenText,
        chart: reportResult.chart,
      );

      _voiceSynthesis.speak(reportResult.formattedText);

      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        setState(() {
          _messages.add(assistantMsg);
          _activeDraft = null;
          _drafts.dropped();
        });
        _scrollToBottom();
      });
      return;
    }

    // 6. Check for Multi-Transaction Batch Split — also when the batch is a
    // new subject typed while a draft was pending ("paguei o chaveiro" ⏎
    // "gastei 47 no açougue e mais 23 na padaria"): it replaces the draft,
    // and César says so (CHAOS-B-007).
    final draftPending = _activeDraft != null && !_activeDraft!.isComplete;
    if (!draftPending || widget.engine.startsNewTransaction(_activeDraft!, text)) {
      final multiDrafts = widget.engine.parseMulti(text);
      if (multiDrafts.length >= 2) {
        final dropped = draftPending ? LocalFinancialNlpEngine.discardedDraftNotice(_activeDraft!) : null;
        _activeDraft = null;
        _drafts.dropped();
        // Items with something missing (no payment method said) are asked
        // about first — saving them as they were lost/mixed data.
        final prompt = widget.engine.multiClarificationPrompt(multiDrafts);
        if (prompt == null) {
          _saveBatch(multiDrafts, notice: dropped);
        } else {
          _pendingBatch = multiDrafts;
          _replyAsAssistant(dropped == null ? prompt : '$dropped\n\n$prompt');
        }
        return;
      }
    }

    // 7. Process Standard Single-Turn or Follow-up Merge
    FinancialTransactionDraft draft;
    bool isMerged = false;
    String? discardedNotice;

    // A full new sentence ("comprei uma blusa de 500 no pix") while a draft
    // is pending starts a new transaction instead of being merged into the
    // old one (which saved it with the old draft's type and description).
    if (_activeDraft != null && !_activeDraft!.isComplete && !widget.engine.startsNewTransaction(_activeDraft!, text)) {
      draft = widget.engine.mergeDrafts(_activeDraft!, text);
      isMerged = true;
    } else {
      // Say so when this drops a draft César was still asking about.
      if (_activeDraft != null && !_activeDraft!.isComplete) {
        discardedNotice = LocalFinancialNlpEngine.discardedDraftNotice(_activeDraft!);
      }
      draft = widget.engine.parse(text);
    }
    final draftKey = isMerged ? _drafts.continueDraft() : _drafts.startDraft();

    // Show the category the user already taught César for items like this one,
    // so the chat card matches what actually gets saved to the repository.
    if (draft.isComplete && widget.repository != null) {
      draft = widget.repository!.applyCategoryMemory(draft);
    }

    String responseText = draft.clarificationPrompt ?? 'Lançamento registrado com sucesso! 🎉';

    // A question ("qual meu saldo?") is "complete" too, but it is not a
    // record: saving it or making it the last transaction meant "apaga o
    // último" then claimed to delete the question and kept the real one.
    final recordable = LocalFinancialNlpEngine.isRecordable(draft);
    if (recordable) {
      _lastSavedTransactionIds = _saveDraft(draft);
      _assistant?.recordCreated(_lastSavedTransactionIds);
      _drafts.saved(_lastSavedTransactionIds);

      if (draft.isReminder && widget.repository != null) {
        final reminder = FinancialReminder(
          id: 'rem-${DateTime.now().millisecondsSinceEpoch}',
          title: draft.description,
          personName: draft.personName,
          amount: draft.amount,
          targetDate: draft.targetDate ?? DateTime.now().add(const Duration(days: 30)),
          type: draft.reminderType == 'loan_receivable'
              ? ReminderType.loanReceivable
              : (draft.reminderType == 'dividend' ? ReminderType.dividend : ReminderType.general),
          notes: draft.calendarConsultationNote,
        );
        widget.repository!.addReminder(reminder);

        widget.engine.calendarService.addEvent(
          title: reminder.title,
          dateTime: reminder.targetDate,
          category: draft.reminderType == 'loan_receivable'
              ? CalendarEventCategory.loanReceivable
              : (draft.reminderType == 'dividend' ? CalendarEventCategory.dividend : CalendarEventCategory.personalReminder),
          amount: reminder.amount,
          personName: reminder.personName,
          notes: reminder.notes,
        );
      }

      final amountStr = draft.amount != null ? Money.brl(draft.amount!) : '';
      final itemOrPlace = (draft.description.isNotEmpty && draft.description != 'unknown' && draft.description != 'expense_other')
          ? ' com ${draft.description}'
          : '';

      final bankTag = draft.bankSource != null ? ' via ${draft.bankSource}' : '';
      final recurrentTag = draft.isRecurrent ? ' (Recorrente ${_dueRuleLabel(draft)})' : '';

      if (draft.billingDay != null && draft.paymentMarginDays != null) {
        responseText = 'Pronto! Boleto de ${draft.description} registrado: cai todo dia ${draft.billingDay} e vence no dia ${draft.dueDay ?? 5} (margem de ${draft.paymentMarginDays} dias para pagar). 📄';
      } else if (draft.isReminder && draft.reminderType == 'loan_receivable') {
        responseText = LocalFinancialNlpEngine.loanReminderText(
          personName: draft.personName,
          targetDate: draft.targetDate,
          amount: draft.amount,
          fromSalaryAnalogy: draft.calendarConsultationNote?.contains('5º dia útil') ?? false,
        );
      } else if (draft.isReminder && draft.reminderType == 'dividend') {
        final dateLabel = draft.targetDate != null
            ? RealtimeCalendarService.formatDateLabel(draft.targetDate!)
            : 'no dia ${draft.dueDay ?? 15}';
        responseText = 'Pronto! Agendei um lembrete para você receber seus ${draft.description} no dia $dateLabel! 📈';
      } else if (draft.intent == 'income') {
        if (draft.isRecurrent && draft.dueDay != null) {
          responseText = 'Pronto! Programei o recebimento recorrente de $amountStr$itemOrPlace ${_dueRuleLabel(draft)} no seu planejamento. ✨';
        } else {
          responseText = 'Pronto! Receita de $amountStr$itemOrPlace$bankTag adicionada ao seu saldo. ✨';
        }
      } else if ((draft.repeatDays ?? 1) > 1 && draft.amount != null) {
        final days = draft.repeatDays!;
        final start = DateTime.now().add(Duration(days: draft.dateOffsetDays));
        final end = start.add(Duration(days: days - 1));
        String fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
        final payName = draft.paymentMethod != 'unknown' ? ' no ${_formatPayment(draft.paymentMethod, null)}' : '';
        responseText = 'Pronto! Registrei $days diárias de $amountStr$itemOrPlace$payName, uma por dia de ${fmt(start)} a ${fmt(end)}. 🎉';
      } else if (draft.intent == 'transfer') {
        responseText = 'Pronto! Transferência de $amountStr$itemOrPlace$bankTag registrada com sucesso. 💸';
      } else if (draft.paymentMethod == 'credit_card' && draft.installments != null && draft.installments! > 1 && draft.amount != null) {
        final perInst = Money.brl(draft.installmentValue ?? draft.amount! / draft.installments!);
        // "todo dia 10" with installments is when each installment is due —
        // not a monthly charge of the whole price.
        final dueTag = draft.installmentDueDay != null ? ', com vencimento todo dia ${draft.installmentDueDay}' : '';
        responseText = 'Pronto! Registrei $amountStr$itemOrPlace no crédito em ${draft.installments}x de $perInst$dueTag$recurrentTag. 🎉';
      } else if (draft.paymentMethod != 'unknown') {
        final payName = _formatPayment(draft.paymentMethod, draft.installments);
        responseText = 'Pronto! Despesa de $amountStr$itemOrPlace no $payName$bankTag$recurrentTag registrada com sucesso. 🎉';
      } else {
        responseText = 'Pronto! Lançamento de $amountStr$itemOrPlace registrado com sucesso. 🎉';
      }

      if (draft.budgetInsight != null) {
        responseText += '\n\n${draft.budgetInsight}';
      }
      // Recorded in one go with something assumed ("sem prazo"): say it now.
      if (!isMerged && draft.assumptionNote != null) {
        responseText += '\n\n${draft.assumptionNote}';
      }

      _lastCompletedDraft = draft;
      _activeDraft = null; // Transaction completed!
    } else if (!draft.isComplete) {
      _activeDraft = draft; // Keep listening for missing context
    }
    _lastLatencyMs = draft.latencyMs;

    if (draft.intent == 'query') {
      responseText = widget.engine.replyForQuestion(draft);
      _activeDraft = null;
      _drafts.dropped();
    } else if (draft.intent == 'unknown' && !isMerged) {
      responseText = draft.clarificationPrompt ?? 'Como posso te ajudar com suas finanças hoje?';
      _activeDraft = null;
      _drafts.dropped();
    }

    if (preface != null) responseText = '$preface\n\n$responseText';
    if (discardedNotice != null) responseText = '$discardedNotice\n\n$responseText';
    final notice = _assistant?.takeNotice();
    if (notice != null) responseText = '$notice\n\n$responseText';

    final assistantMsg = ChatMessage(
      id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
      sender: MessageSender.assistant,
      text: responseText,
      timestamp: DateTime.now(),
      draft: draft.intent != 'unknown' ? draft : null,
      isMergedUpdate: isMerged,
      draftKey: draftKey,
      transactionIds: recordable ? _lastSavedTransactionIds : const [],
    );

    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() {
        _messages.add(assistantMsg);
      });
      _scrollToBottom();
    });
  }

  /// Shows a reply from [CesarAssistant] and keeps the chat's own "last
  /// entry" state in step with what it changed or deleted.
  void _showAssistantReply(AssistantReply reply, {required bool speak}) {
    _syncAfterAssistant(reply);
    _activeDraft = null;
    _drafts.dropped();
    final notice = _assistant?.takeNotice();
    final text = notice == null ? reply.text : '$notice\n\n${reply.text}';
    if (speak) _voiceSynthesis.speak(text);
    FinancialTransactionDraft? cardDraft;
    List<String> cardIds = const [];
    if (reply.route == 'split' && reply.changedIds.isNotEmpty && widget.repository != null) {
      final txId = reply.changedIds.first;
      final tx = widget.repository!.transactions.cast<FinancialTransaction?>().firstWhere(
        (t) => t?.id == txId,
        orElse: () => null,
      );
      if (tx != null) {
        final today = DateTime.now();
        final todayOnly = DateTime(today.year, today.month, today.day);
        final txOnly = DateTime(tx.date.year, tx.date.month, tx.date.day);
        cardIds = [txId];
        cardDraft = FinancialTransactionDraft(
          intent: 'expense',
          intentConfidence: 1.0,
          category: tx.category,
          paymentMethod: tx.paymentMethod,
          amount: tx.amount,
          dateOffsetDays: txOnly.difference(todayOnly).inDays,
          description: tx.title,
          rawText: tx.notes ?? tx.title,
          latencyMs: 0.0,
          isComplete: true,
          missingSlots: const [],
        );
      }
    }

    final assistantMsg = ChatMessage(
      id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
      sender: MessageSender.assistant,
      text: text,
      timestamp: DateTime.now(),
      spokenText: reply.spokenText,
      chart: reply.chart,
      draft: cardDraft,
      transactionIds: cardIds,
    );
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _messages.add(assistantMsg));
      _scrollToBottom();
    });
  }

  /// The recurring due-day correction still works on [_lastCompletedDraft]
  /// and writes it back to the record — so it must mirror edits and
  /// deletions made by the assistant, or it would restore old values.
  void _syncAfterAssistant(AssistantReply reply) {
    if (_lastSavedTransactionIds.any(reply.removedIds.contains)) {
      _lastSavedTransactionIds = const [];
      _lastCompletedDraft = null;
      return;
    }
    final repo = widget.repository;
    if (repo == null || _lastCompletedDraft == null || !_lastSavedTransactionIds.any(reply.changedIds.contains)) return;
    final matches = repo.transactions.where((t) => t.id == _lastSavedTransactionIds.first);
    if (matches.isEmpty) return;
    final tx = matches.first;
    _lastCompletedDraft = _lastCompletedDraft!.copyWith(
      amount: tx.amount,
      category: tx.category,
      paymentMethod: tx.paymentMethod,
      installments: tx.installments,
      description: tx.title,
      intent: tx.type == TransactionType.income ? 'income' : (tx.type == TransactionType.transfer ? 'transfer' : 'expense'),
    );
  }

  /// "todo 5º dia útil (próximo: 07/10)" or "todo dia 12".
  String _dueRuleLabel(FinancialTransactionDraft draft) {
    if (draft.dueBusinessDay != null) {
      final next = RealtimeCalendarService.nextNthBusinessDay(draft.dueBusinessDay!);
      return 'todo ${draft.dueBusinessDay}º dia útil, próximo em ${next.day.toString().padLeft(2, '0')}/${next.month.toString().padLeft(2, '0')}';
    }
    return 'todo dia ${draft.dueDay ?? 10}';
  }

  /// Saves every item of a complete multi-transaction batch and confirms it.
  void _saveBatch(List<FinancialTransactionDraft> drafts, {String? notice}) {
    final buffer = StringBuffer();
    if (notice != null) buffer.writeln(notice);
    final allIds = <String>[];
    final idsPerDraft = <List<String>>[];
    for (final d in drafts) {
      final createdIds = _saveDraft(d);
      idsPerDraft.add(createdIds);
      allIds.addAll(createdIds);
    }
    _lastSavedTransactionIds = allIds;
    _assistant?.recordCreated(allIds);

    buffer.writeln('Identifiquei ${drafts.length} lançamentos:');
    for (int i = 0; i < drafts.length; i++) {
      final d = drafts[i];
      final amt = d.amount != null ? Money.brl(d.amount!) : '';
      final pay = _formatPayment(d.paymentMethod, d.installments);
      final code = idsPerDraft[i].isEmpty ? '' : ' ${TransactionCode.label(idsPerDraft[i].first)}';
      buffer.writeln('${i + 1}. $amt com ${d.description} ($pay)$code');
    }
    buffer.write('\nTodos foram registrados com sucesso! 🎉');

    _lastCompletedDraft = drafts.last;
    _lastLatencyMs = drafts.fold(0.0, (acc, d) => acc + d.latencyMs);

    final assistantMsg = ChatMessage(
      id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
      sender: MessageSender.assistant,
      text: buffer.toString(),
      timestamp: DateTime.now(),
      draft: drafts.first,
      transactionIds: allIds,
    );

    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() {
        _messages.add(assistantMsg);
      });
      _scrollToBottom();
    });
  }

  List<String> _saveDraft(FinancialTransactionDraft draft) =>
      (widget.repository?.addTransactionFromDraft(draft) ?? const []).map((t) => t.id).toList();

  void _replyAsAssistant(String text) {
    final assistantMsg = ChatMessage(
      id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
      sender: MessageSender.assistant,
      text: text,
      timestamp: DateTime.now(),
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
      _drafts.dropped();
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
              padding: const EdgeInsets.all(KrezioSpace.sm),
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
            const SizedBox(width: KrezioSpace.md),
            Expanded(
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'César • Krezio.ai',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: KrezioFont.title,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Seu Copiloto Financeiro On-Device',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: KrezioFont.caption,
                    color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                  ),
                ),
              ],
            ),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<AppEnvironment>(
            valueListenable: EnvironmentConfig.environmentNotifier,
            builder: (context, env, _) {
              if (env != AppEnvironment.homologation) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: KrezioSpace.sm),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NeuralInspectorScreen(
                          engine: widget.engine,
                          initialQuery: _textController.text.isNotEmpty
                              ? _textController.text
                              : (_lastCompletedDraft?.rawText ?? _activeDraft?.rawText),
                          isDark: widget.isDarkMode,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm, vertical: KrezioSpace.xs),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [KrezioColors.aiPurple, Color(0xFF6366F1)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: KrezioColors.aiPurple.withOpacity(0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.hub, color: Colors.white, size: 14),
                        SizedBox(width: KrezioSpace.xs),
                        Text(
                          'XAI / NLP',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: KrezioFont.micro,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          // Latency badge: only where there is room (not on a phone).
          if (_lastLatencyMs > 0 && MediaQuery.sizeOf(context).width >= 480)
            Container(
              margin: const EdgeInsets.only(right: KrezioSpace.sm),
              padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.xs),
              decoration: BoxDecoration(
                color: KrezioColors.emeraldGreen.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: KrezioColors.emeraldGreen.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bolt, color: KrezioColors.emeraldGreen, size: 14),
                  const SizedBox(width: KrezioSpace.xs),
                  Text(
                    '${_lastLatencyMs.toStringAsFixed(1)} ms',
                    style: const TextStyle(
                      color: KrezioColors.emeraldGreen,
                      fontSize: KrezioFont.caption,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          // Botão de Chamada de Voz com o César (100% On-Device)
          Tooltip(
            message: 'Conversar por voz com o César',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _openVoiceConversationModal,
              child: Container(
                margin: const EdgeInsets.only(right: KrezioSpace.sm),
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm, vertical: KrezioSpace.xs),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [KrezioColors.aiPurple, Color(0xFF6366F1)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: KrezioColors.aiPurple.withOpacity(0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.record_voice_over, color: Colors.white, size: 14),
                    SizedBox(width: KrezioSpace.xs),
                    Text(
                      'VOZ',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: KrezioFont.micro,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
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
                    const SizedBox(width: KrezioSpace.sm),
                    Text('Português (Brasil)', style: TextStyle(fontWeight: _selectedLocaleId.contains('pt') ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'en-US',
                child: Row(
                  children: [
                    const Text('🇺🇸 '),
                    const SizedBox(width: KrezioSpace.sm),
                    Text('English (US)', style: TextStyle(fontWeight: _selectedLocaleId.contains('en') ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'es-ES',
                child: Row(
                  children: [
                    const Text('🇪🇸 '),
                    const SizedBox(width: KrezioSpace.sm),
                    Text('Español (España)', style: TextStyle(fontWeight: _selectedLocaleId.contains('es') ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              ),
            ],
          ),
          // The theme switch lives in Ajustes → Aparência; on a phone there
          // was no room left for the title.
          if (MediaQuery.sizeOf(context).width >= 480)
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
            // Quick Suggestions Bar (Quick Action + Categorized Dropdowns)
            Container(
              height: 50,
              padding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm),
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg),
                scrollDirection: Axis.horizontal,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.flash_on, size: 14, color: KrezioColors.aiPurple),
                    label: const Text('Registrar gasto', style: TextStyle(fontSize: KrezioFont.small)),
                    backgroundColor: bgSurface,
                    side: BorderSide(
                      color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                    ),
                    onPressed: () {
                      const text = 'Gastei 45,90 no mercado no Pix';
                      _textController.value = const TextEditingValue(
                        text: text,
                        selection: TextSelection.collapsed(offset: text.length),
                      );
                      _messageFocus.requestFocus();
                    },
                  ),
                  const SizedBox(width: KrezioSpace.sm),
                  for (final (catTitle, catIcon, items) in _suggestionCategories) ...[
                    PopupMenuButton<String>(
                      tooltip: 'Sugestões: $catTitle',
                      offset: const Offset(0, 38),
                      color: bgSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                        ),
                      ),
                      onSelected: (text) {
                        _textController.value = TextEditingValue(
                          text: text,
                          selection: TextSelection.collapsed(offset: text.length),
                        );
                        _messageFocus.requestFocus();
                      },
                      itemBuilder: (_) => [
                        for (final (label, text) in items)
                          PopupMenuItem<String>(
                            value: text,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 270),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: KrezioFont.small,
                                      fontWeight: FontWeight.w600,
                                      color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '"$text"',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: KrezioFont.caption,
                                      color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: bgSurface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(catIcon, size: 14, color: KrezioColors.aiPurple),
                            const SizedBox(width: 6),
                            Text(
                              catTitle,
                              style: TextStyle(
                                fontSize: KrezioFont.small,
                                fontWeight: FontWeight.w500,
                                color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.arrow_drop_down,
                              size: 16,
                              color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: KrezioSpace.sm),
                  ],
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1),

            // Chat Messages List
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(KrezioSpace.lg),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  return _buildMessageBubble(msg, isDark);
                },
              ),
            ),

            // Active Voice / Recording Control Bar
            ValueListenableBuilder<bool>(
              valueListenable: _voiceSynthesis.isSpeakingNotifier,
              builder: (context, isCesarSpeaking, _) {
                if (!_isListening && !isCesarSpeaking) return const SizedBox.shrink();
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
                  decoration: BoxDecoration(
                    color: isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface,
                    border: Border(
                      top: BorderSide(color: isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder),
                    ),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: KrezioSpace.sm,
                    runSpacing: KrezioSpace.xs,
                    children: [
                      if (_isListening)
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.xs),
                          ),
                          icon: const Icon(Icons.stop_circle_rounded, size: 16),
                          label: const Text('Parar de gravar', style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold)),
                          onPressed: _toggleListening,
                        ),
                      if (isCesarSpeaking)
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.xs),
                          ),
                          icon: const Icon(Icons.stop_circle_rounded, size: 16),
                          label: const Text('Parar fala do César', style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold)),
                          onPressed: () => _voiceSynthesis.stop(),
                        ),
                    ],
                  ),
                );
              },
            ),

            // Input Bar
            Container(
              padding: const EdgeInsets.all(KrezioSpace.md),
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
                      focusNode: _messageFocus,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _sendMessage,
                      decoration: InputDecoration(
                        hintText: 'Digite um gasto (ex: gastei 50 no mercado)...',
                        hintStyle: TextStyle(
                          fontSize: KrezioFont.body,
                          color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
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
                  const SizedBox(width: KrezioSpace.sm),
                  Tooltip(
                    message: _isListening ? 'Parar de gravar' : 'Gravar minha fala',
                    child: Material(
                      color: _isListening ? Colors.redAccent : (isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface),
                      borderRadius: KrezioTheme.borderRadius,
                      child: InkWell(
                        borderRadius: KrezioTheme.borderRadius,
                        onTap: _toggleListening,
                        child: Padding(
                          padding: const EdgeInsets.all(KrezioSpace.md),
                          child: Icon(
                            _isListening ? Icons.stop_rounded : Icons.mic_none_rounded,
                            color: _isListening ? Colors.white : (isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText),
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: KrezioSpace.sm),
                  Material(
                    color: KrezioColors.aiPurple,
                    borderRadius: KrezioTheme.borderRadius,
                    child: InkWell(
                      borderRadius: KrezioTheme.borderRadius,
                      onTap: () => _sendMessage(_textController.text),
                      child: const Padding(
                        padding: EdgeInsets.all(KrezioSpace.md),
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

  /// Renders César's messages with a lightweight Markdown-lite parser: the RAG report
  /// engine produces "### headers", "**bold**", "`code`" and "- bullet" lines that used
  /// to be dumped into a plain Text widget and show up as literal asterisks and hashes.
  Widget _buildFormattedMessage(String text, Color textColor) {
    final lines = text.split('\n');
    final children = <Widget>[];

    for (final line in lines) {
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: KrezioSpace.sm));
        continue;
      }

      if (line.startsWith('#### ')) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: KrezioSpace.hair, bottom: KrezioSpace.xs),
          child: Text(
            line.substring(5),
            style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.w700, color: textColor),
          ),
        ));
      } else if (line.startsWith('### ')) {
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
          child: Text(
            line.substring(4),
            style: TextStyle(fontSize: KrezioFont.bodyLarge, fontWeight: FontWeight.w700, color: textColor),
          ),
        ));
      } else if (line.startsWith('- ')) {
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: KrezioSpace.xs),
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(text: '•  ', style: TextStyle(fontSize: KrezioFont.body, height: 1.4, color: textColor)),
                ..._parseInlineMarkdown(line.substring(2), textColor),
              ],
            ),
          ),
        ));
      } else {
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: KrezioSpace.xs),
          child: RichText(text: TextSpan(children: _parseInlineMarkdown(line, textColor))),
        ));
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  /// Parses inline "**bold**", "*italic*" and "`code`" spans within a single line.
  /// Order matters: `**` must be tried before the single-`*` alternative, otherwise
  /// "**João**" would be read as two adjacent italic markers instead of one bold span.
  List<InlineSpan> _parseInlineMarkdown(String text, Color textColor) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`');
    final baseStyle = TextStyle(fontSize: KrezioFont.body, height: 1.4, color: textColor);
    int last = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: baseStyle));
      }

      final bold = match.group(1);
      final italic = match.group(2);
      final code = match.group(3);
      if (bold != null) {
        spans.add(TextSpan(text: bold, style: baseStyle.copyWith(fontWeight: FontWeight.w700)));
      } else if (italic != null) {
        spans.add(TextSpan(text: italic, style: baseStyle.copyWith(fontStyle: FontStyle.italic, color: textColor.withOpacity(0.75))));
      } else if (code != null) {
        spans.add(TextSpan(
          text: code,
          style: baseStyle.copyWith(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
            color: KrezioColors.aiPurple,
          ),
        ));
      }
      last = match.end;
    }

    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: baseStyle));
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: baseStyle));
    }

    return spans;
  }

  /// Renders the chart attached to a report message: a category donut (reusing the
  /// dashboard's chart) for spending breakdowns, or a generic bar chart for anything
  /// shaped as label/value pairs (debtors, bills, income vs. expense).
  Widget _buildReportChart(ReportChartData chart, bool isDark) {
    if (chart.categoryValues != null) {
      return SizedBox(
        width: 220,
        child: CategoryDonutChart(categoryData: chart.categoryValues!, isDark: isDark),
      );
    }
    if (chart.barValues != null) {
      return SizedBox(
        width: 260,
        child: ReportBarChart(data: chart.barValues!, isDark: isDark),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isDark) {
    final isUser = msg.sender == MessageSender.user;
    final isGreeting = !isUser && _messages.isNotEmpty && identical(msg, _messages.first);
    final assistantSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    // Aligns secondary elements (feedback, chips, receipt card) with the
    // left edge of César's bubble: 32 px avatar + 8 px gap = 40 px.
    const assistantIndent = KrezioSpace.xxxl + KrezioSpace.sm;

    return Padding(
      padding: const EdgeInsets.only(bottom: KrezioSpace.lg),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser) ...[
                Container(
                  padding: const EdgeInsets.all(KrezioSpace.sm),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        KrezioColors.aiPurple.withValues(alpha: 0.24),
                        KrezioColors.aiPurpleDark.withValues(alpha: 0.14),
                      ],
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: KrezioColors.aiPurple.withValues(alpha: 0.28),
                    ),
                  ),
                  child: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurpleLight, size: 16),
                ),
                const SizedBox(width: KrezioSpace.sm),
              ],
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
                    decoration: BoxDecoration(
                      color: isUser
                          ? KrezioColors.aiPurple
                          : isGreeting
                              ? Color.alphaBlend(KrezioColors.aiPurple.withValues(alpha: 0.10), assistantSurface)
                              : assistantSurface,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isUser ? 16 : 4),
                        bottomRight: Radius.circular(isUser ? 4 : 16),
                      ),
                      border: !isUser
                          ? Border.all(
                              color: isDark
                                  ? KrezioColors.darkBorder.withValues(alpha: 0.75)
                                  : KrezioColors.lightBorder,
                            )
                          : null,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: isUser
                        ? Text(
                            msg.text,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: KrezioFont.body,
                              height: 1.4,
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildFormattedMessage(
                                msg.text,
                                isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                              ),
                              if (msg.chart != null) ...[
                                const SizedBox(height: KrezioSpace.md),
                                _buildReportChart(msg.chart!, isDark),
                              ],
                            ],
                          ),
                  ),
                ),
              ),
              if (!isUser) ...[
                const SizedBox(width: KrezioSpace.sm),
                ValueListenableBuilder<VoiceAvailability>(
                  valueListenable: _voiceSynthesis.availabilityNotifier,
                  builder: (_, availability, child) => availability == VoiceAvailability.unavailable
                    ? const SizedBox.shrink()
                    : ValueListenableBuilder<bool>(
                        valueListenable: _voiceSynthesis.isSpeakingNotifier,
                        builder: (_, isSpeaking, __) => IconButton(
                          icon: Icon(
                            isSpeaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
                            size: 18,
                          ),
                          color: isSpeaking
                              ? Colors.redAccent
                              : (isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText),
                          tooltip: isSpeaking ? 'Parar fala do César' : 'Ouvir César falando',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          onPressed: () {
                            if (isSpeaking) {
                              _voiceSynthesis.stop();
                            } else {
                              _voiceSynthesis.speak(msg.text.isNotEmpty ? msg.text : (msg.spokenText ?? ''));
                            }
                          },
                        ),
                      ),
                ),
              ],
            ],
          ),

          // "Isso ajudou?" on César's answers (not on entry cards or the greeting).
          if (!isUser && msg.draft == null && msg.id != 'welcome' && widget.repository != null)
            Padding(
              padding: const EdgeInsets.only(left: assistantIndent, top: KrezioSpace.xs),
              child: _rated.containsKey(msg.id)
                  ? Text('Obrigado pelo retorno!',
                      style: TextStyle(fontSize: KrezioFont.caption, color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Isso ajudou?',
                            style: TextStyle(fontSize: KrezioFont.caption, color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText)),
                        for (final up in const [true, false])
                          IconButton(
                            icon: Icon(up ? Icons.thumb_up_alt_outlined : Icons.thumb_down_alt_outlined, size: 14),
                            tooltip: up ? 'Ajudou' : 'Não ajudou',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: () {
                              FeedbackService(widget.repository!).rateAnswer(helpful: up);
                              setState(() => _rated[msg.id] = up);
                            },
                          ),
                      ],
                    ),
            ),

          // Contextual Quick Action Chips for Missing Slots
          if (!isUser && msg.draft != null && !msg.draft!.isComplete) ...[
            const SizedBox(height: KrezioSpace.sm),
            Padding(
              padding: const EdgeInsets.only(left: assistantIndent),
              child: _buildMissingSlotsQuickChips(msg, isDark),
            ),
          ],

          // Embedded Transaction Inspector Card if draft present
          if (msg.draft != null) ...[
            const SizedBox(height: KrezioSpace.sm),
            Padding(
              padding: const EdgeInsets.only(left: assistantIndent),
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  EnvironmentConfig.environmentNotifier,
                  widget.repository,
                ]),
                builder: (context, _) => _buildTransactionInspectorCard(
                  msg.draft!, isDark, msg.isMergedUpdate, ids: msg.transactionIds,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A quick-reply chip acts on the card it belongs to: the pending draft, the
  /// records that card was saved as ("muda o #4821 pra pix"), or the draft that
  /// was left aside, brought back.
  void _onSlotChip(ChatMessage msg, String value) {
    final key = msg.draftKey;
    if (key == null) {
      _sendMessage(value);
      return;
    }
    switch (_drafts.targetFor(key)) {
      case ChipOnActiveDraft():
        _sendMessage(value);
      case ChipOnSavedRecords(:final transactionIds):
        _sendMessage('muda o ${TransactionCode.label(transactionIds.first)} pra $value');
      case ChipOnStaleDraft():
        final back = msg.draft;
        if (back == null) {
          _sendMessage(value);
          return;
        }
        _activeDraft = back;
        _drafts.reactivate(key);
        _sendMessage(value);
    }
  }

  Widget _buildMissingSlotsQuickChips(ChatMessage msg, bool isDark) {
    final draft = msg.draft!;
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
              style: const TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _onSlotChip(msg, opt['value']!),
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
        for (final b in widget.repository?.budgets ?? const <BudgetCategory>[])
          if (b.isCustom) {'label': '🏷️ ${b.name}', 'value': b.name},
      ];

      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: categoryOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _onSlotChip(msg, opt['value']!),
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
              style: const TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _onSlotChip(msg, opt['value']!),
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
      // The method used most goes first, marked — a suggestion, never assumed.
      const valueOf = {'pix': 'no pix', 'debit_card': 'no débito', 'credit_card': 'no crédito', 'cash': 'em dinheiro', 'bank_slip': 'no boleto'};
      final usual = valueOf[widget.repository?.mostUsedPaymentMethod];
      final usualIdx = paymentOptions.indexWhere((o) => o['value'] == usual);
      if (usualIdx >= 0) {
        final o = paymentOptions.removeAt(usualIdx);
        paymentOptions.insert(0, {'label': '${o['label']} · o que você mais usa', 'value': o['value']!});
      }

      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: paymentOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _onSlotChip(msg, opt['value']!),
          );
        }).toList(),
      );
    }

    if (draft.missingSlots.length == 1 && draft.missingSlots.contains('amount')) {
      final isSalary = draft.intent == 'income' && draft.category == 'salary';
      final isLoan = draft.isReminder && draft.reminderType == 'loan_receivable';
      final amountOptions = isSalary
          ? [
              {'label': 'R\$ 2.500', 'value': '2500'},
              {'label': 'R\$ 3.500', 'value': '3500'},
              {'label': 'R\$ 4.500', 'value': '4500'},
              {'label': 'R\$ 6.000', 'value': '6000'},
            ]
          : (isLoan
              ? [
                  {'label': 'R\$ 50', 'value': '50'},
                  {'label': 'R\$ 100', 'value': '100'},
                  {'label': 'R\$ 150', 'value': '150'},
                  {'label': 'R\$ 200', 'value': '200'},
                  {'label': 'R\$ 300', 'value': '300'},
                ]
              : [
                  {'label': 'R\$ 20', 'value': '20'},
                  {'label': 'R\$ 35', 'value': '35'},
                  {'label': 'R\$ 50', 'value': '50'},
                  {'label': 'R\$ 100', 'value': '100'},
                ]);

      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: amountOptions.map((opt) {
          return ActionChip(
            label: Text(
              opt['label']!,
              style: const TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.w600),
            ),
            backgroundColor: isDark ? KrezioColors.darkSurface : Colors.white,
            side: const BorderSide(color: KrezioColors.aiPurple, width: 1),
            onPressed: () => _onSlotChip(msg, opt['value']!),
          );
        }).toList(),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildTransactionInspectorCard(FinancialTransactionDraft draft, bool isDark, bool isMerged, {List<String> ids = const []}) {
    final currentIds = widget.repository?.transactions.map((tx) => tx.id).toSet() ?? <String>{};
    final saved = ids.isNotEmpty && ids.every(currentIds.contains);
    final missing = draft.missingSlots.isEmpty ? null : draft.missingSlots.first;
    final status = switch ((saved, ids.isNotEmpty, missing)) {
      (true, _, _) => 'Registrado',
      (_, true, _) => 'Alterado ou removido',
      (_, _, 'confirm') => 'Aguardando confirmação',
      (_, _, 'payment_method') => 'Falta pagamento',
      (_, _, 'amount') => 'Falta valor',
      (_, _, 'category') => 'Falta categoria',
      (_, _, 'date') => 'Falta data',
      (_, _, null) => 'Não registrado',
      _ => 'Aguardando detalhes',
    };
    final statusColor = saved ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange;
    final intentColor = _getIntentColor(draft.intent);
    final baseSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final cardSurface = Color.alphaBlend(
      intentColor.withValues(alpha: isDark ? 0.05 : 0.025),
      baseSurface,
    );
    final primaryText = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryText = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    final borderColor = isDark
        ? statusColor.withValues(alpha: saved ? 0.28 : 0.42)
        : statusColor.withValues(alpha: saved ? 0.30 : 0.45);
    final dividerColor = (isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder).withValues(alpha: 0.65);

    final title = _draftDisplayTitle(draft);
    final dateLabel = _formatDraftDate(draft.dateOffsetDays);
    final categoryName = _formatCategory(draft.category);
    final paymentName = _formatPayment(draft.paymentMethod, draft.installments);
    final amountText = draft.amount != null ? Money.brl(draft.amount!) : 'Valor pendente';
    final amountColor = draft.amount == null
        ? KrezioColors.friendlyOrange
        : (draft.intent == 'income'
            ? KrezioColors.emeraldGreen
            : (draft.intent == 'transfer' ? KrezioColors.aiPurpleLight : primaryText));
    final installmentLine = (draft.paymentMethod == 'credit_card' &&
            draft.installments != null &&
            draft.installments! > 1 &&
            draft.amount != null)
        ? '${draft.installments}x de ${Money.brl(draft.installmentValue ?? draft.amount! / draft.installments!)}'
        : null;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Container(
        key: const ValueKey('chat-transaction-card'),
        width: double.infinity,
        decoration: BoxDecoration(
          color: cardSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 1.1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.26 : 0.06),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Subtle top semantic accent bar
              Container(
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      intentColor.withValues(alpha: 0.9),
                      statusColor.withValues(alpha: 0.65),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.md, KrezioSpace.lg, KrezioSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Header row: intent + #code + updated badge + status pill
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: KrezioSpace.sm,
                            runSpacing: KrezioSpace.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm, vertical: 3),
                                decoration: BoxDecoration(
                                  color: intentColor.withValues(alpha: isDark ? 0.16 : 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(_intentIcon(draft.intent), size: 12, color: intentColor),
                                    const SizedBox(width: 4),
                                    Text(
                                      _formatIntentName(draft.intent),
                                      style: TextStyle(
                                        color: intentColor,
                                        fontSize: KrezioFont.micro,
                                        letterSpacing: 0.4,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (ids.isNotEmpty)
                                Tooltip(
                                  message: 'Use este código para falar deste lançamento, ex.: "apaga o ${TransactionCode.label(ids.first)}"',
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: dividerColor),
                                    ),
                                    child: Text(
                                      ids.length == 1 ? TransactionCode.label(ids.first) : '${TransactionCode.label(ids.first)} +${ids.length - 1}',
                                      style: TextStyle(
                                        color: secondaryText,
                                        fontSize: KrezioFont.micro,
                                        fontWeight: FontWeight.w600,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ),
                                ),
                              if (isMerged)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: KrezioColors.aiPurple.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.sync_rounded, size: 11, color: KrezioColors.aiPurpleLight),
                                      SizedBox(width: 3),
                                      Text(
                                        'Atualizado',
                                        style: TextStyle(
                                          color: KrezioColors.aiPurpleLight,
                                          fontSize: KrezioFont.micro,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: KrezioSpace.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm, vertical: 3),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: isDark ? 0.14 : 0.10),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                saved ? Icons.check_circle_rounded : Icons.schedule_rounded,
                                size: 12,
                                color: statusColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                status,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: KrezioFont.micro,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: KrezioSpace.md),

                    // 2. Hero section: description + date on left, hero amount on right
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: primaryText,
                                  fontSize: KrezioFont.bodyLarge,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                dateLabel,
                                style: TextStyle(
                                  color: secondaryText,
                                  fontSize: KrezioFont.caption,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: KrezioSpace.md),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              amountText,
                              style: TextStyle(
                                color: amountColor,
                                fontSize: draft.amount != null ? 20 : KrezioFont.body,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            if (installmentLine != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                installmentLine,
                                style: TextStyle(
                                  color: secondaryText,
                                  fontSize: KrezioFont.micro,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: KrezioSpace.md),
                    Divider(height: 1, thickness: 1, color: dividerColor),
                    const SizedBox(height: KrezioSpace.md),

                    // 3. Structured metadata pills (clean wrap on both 360px phone & wide web)
                    Wrap(
                      spacing: KrezioSpace.sm,
                      runSpacing: KrezioSpace.sm,
                      children: [
                        _buildCardMetaPill(
                          icon: _categoryIcon(draft.category),
                          label: 'Categoria',
                          value: categoryName,
                          isMissing: draft.category == 'unknown',
                          accentColor: intentColor,
                          isDark: isDark,
                        ),
                        _buildCardMetaPill(
                          icon: _paymentIcon(draft.paymentMethod),
                          label: 'Pagamento',
                          value: paymentName,
                          isMissing: draft.paymentMethod == 'unknown',
                          accentColor: KrezioColors.aiPurple,
                          isDark: isDark,
                        ),
                        if (draft.bankSource != null)
                          _buildCardMetaPill(
                            icon: Icons.account_balance_outlined,
                            label: 'Conta',
                            value: draft.bankSource!,
                            accentColor: KrezioColors.aiPurple,
                            isDark: isDark,
                          ),
                        if (draft.isRecurrent)
                          _buildCardMetaPill(
                            icon: Icons.repeat_rounded,
                            label: 'Recorrente',
                            value: draft.dueDay != null || draft.dueBusinessDay != null
                                ? '${draft.dueBusinessDay != null ? "${draft.dueBusinessDay}º dia útil" : "Dia ${draft.dueDay}"}${draft.recurrenceDuration != null ? " · ${draft.recurrenceDuration}" : ""}'
                                : 'Mensal${draft.recurrenceDuration != null ? " (${draft.recurrenceDuration})" : ""}',
                            accentColor: KrezioColors.emeraldGreen,
                            isDark: isDark,
                          ),
                        if (EnvironmentConfig.isHomologation)
                          _buildCardMetaPill(
                            icon: Icons.bolt_rounded,
                            label: 'Latência',
                            value: '${draft.latencyMs.toStringAsFixed(1)} ms',
                            accentColor: KrezioColors.emeraldGreen,
                            isDark: isDark,
                          ),
                      ],
                    ),

                    if (draft.isReminder) ...[
                      const SizedBox(height: KrezioSpace.md),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.sm),
                        decoration: BoxDecoration(
                          color: KrezioColors.friendlyOrange.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: KrezioColors.friendlyOrange.withValues(alpha: 0.28)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.event_available_rounded, size: 15, color: KrezioColors.friendlyOrange),
                            const SizedBox(width: KrezioSpace.sm),
                            Expanded(
                              child: Text(
                                draft.calendarConsultationNote ?? 'Lembrete agendado no seu calendário',
                                style: const TextStyle(
                                  fontSize: KrezioFont.caption,
                                  fontWeight: FontWeight.w600,
                                  color: KrezioColors.friendlyOrange,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    if (draft.missingSlots.isNotEmpty) ...[
                      const SizedBox(height: KrezioSpace.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: 6),
                        decoration: BoxDecoration(
                          color: KrezioColors.friendlyOrange.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.edit_note_rounded, size: 14, color: KrezioColors.friendlyOrange),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Slots ausentes: ${draft.missingSlots.map(_formatMissingSlotName).join(", ")}',
                                style: const TextStyle(
                                  color: KrezioColors.friendlyOrange,
                                  fontSize: KrezioFont.caption,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    ValueListenableBuilder<AppEnvironment>(
                      valueListenable: EnvironmentConfig.environmentNotifier,
                      builder: (context, env, _) {
                        if (env != AppEnvironment.homologation) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: KrezioSpace.md),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => NeuralInspectorScreen(
                                    engine: widget.engine,
                                    initialQuery: draft.rawText,
                                    isDark: widget.isDarkMode,
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.sm),
                              decoration: BoxDecoration(
                                color: KrezioColors.aiPurple.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: KrezioColors.aiPurple.withValues(alpha: 0.30)),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.hub_outlined, color: KrezioColors.aiPurple, size: 14),
                                  SizedBox(width: KrezioSpace.sm),
                                  Text(
                                    'Inspecionar Pipeline NLP & XAI (Homologação)',
                                    style: TextStyle(
                                      fontSize: KrezioFont.caption,
                                      fontWeight: FontWeight.bold,
                                      color: KrezioColors.aiPurple,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardMetaPill({
    required IconData icon,
    required String label,
    required String value,
    required Color accentColor,
    required bool isDark,
    bool isMissing = false,
  }) {
    final pillColor = isMissing ? KrezioColors.friendlyOrange : accentColor;
    final pillBg = isMissing
        ? KrezioColors.friendlyOrange.withValues(alpha: isDark ? 0.12 : 0.08)
        : (isDark ? KrezioColors.darkSurfaceVariant.withValues(alpha: 0.85) : const Color(0xFFF3F4F6));
    final border = isMissing
        ? KrezioColors.friendlyOrange.withValues(alpha: 0.30)
        : (isDark ? KrezioColors.darkBorder.withValues(alpha: 0.6) : KrezioColors.lightBorder);
    final labelColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    final valueColor = isMissing
        ? KrezioColors.friendlyOrange
        : (isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: 7),
      decoration: BoxDecoration(
        color: pillBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: pillColor.withValues(alpha: isDark ? 0.16 : 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 13, color: pillColor),
          ),
          const SizedBox(width: KrezioSpace.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: KrezioFont.micro, color: labelColor, height: 1.1),
                ),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: KrezioFont.small,
                    fontWeight: FontWeight.w600,
                    color: valueColor,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _draftDisplayTitle(FinancialTransactionDraft draft) {
    final desc = draft.description.trim();
    if (desc.isNotEmpty && desc != 'unknown' && desc != 'expense_other' && desc != 'income_other') {
      return '${desc[0].toUpperCase()}${desc.substring(1)}';
    }
    if (draft.category != 'unknown') return _formatCategory(draft.category);
    return _formatIntentName(draft.intent);
  }

  String _formatDraftDate(int offsetDays) {
    if (offsetDays == 0) return 'Hoje';
    if (offsetDays == -1) return 'Ontem';
    if (offsetDays == -2) return 'Anteontem';
    if (offsetDays == 1) return 'Amanhã';
    final d = DateTime.now().add(Duration(days: offsetDays));
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }

  IconData _intentIcon(String intent) {
    return switch (intent) {
      'income' => Icons.arrow_downward_rounded,
      'expense' => Icons.arrow_upward_rounded,
      'transfer' => Icons.swap_horiz_rounded,
      'query' => Icons.search_rounded,
      _ => Icons.receipt_long_outlined,
    };
  }

  IconData _categoryIcon(String category) {
    return switch (category) {
      'supermarket' => Icons.shopping_cart_outlined,
      'transport' => Icons.directions_car_outlined,
      'health' => Icons.favorite_border_rounded,
      'leisure' => Icons.restaurant_outlined,
      'housing' => Icons.home_outlined,
      'education' => Icons.school_outlined,
      'salary' => Icons.work_outline_rounded,
      'investment' => Icons.trending_up_rounded,
      _ => Icons.category_outlined,
    };
  }

  IconData _paymentIcon(String payment) {
    return switch (payment) {
      'pix' => Icons.qr_code_2_rounded,
      'credit_card' => Icons.credit_card_rounded,
      'debit_card' => Icons.credit_card_outlined,
      'cash' => Icons.payments_outlined,
      'bank_slip' => Icons.receipt_long_outlined,
      _ => Icons.payment_outlined,
    };
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
        if (cat == 'unknown') return 'Ausente';
        // Custom, user-created category — show its display name, not the raw code.
        for (final b in widget.repository?.budgets ?? const []) {
          if (b.category == cat) return b.name;
        }
        return cat;
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
