import '../../backend/services/money.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../local_nlp_engine.dart';
import '../financial_report_rag_engine.dart';
import '../debt_payment_parser.dart';
import '../goal_parser.dart';
import '../affordability_analyzer.dart';
import '../cesar_assistant.dart';
import '../../backend/models/financial_goal.dart';
import '../../backend/models/financial_reminder.dart';
import '../../backend/repositories/financial_repository.dart';
import 'voice_synthesis_service.dart';

enum VoiceState {
  idle,
  listening,
  thinking,
  speaking,
  paused,
}

/// Represents a single spoken turn in the live voice session.
class VoiceTurn {
  final bool isUser;
  final String text;
  final DateTime timestamp;
  final bool isTransactionSaved;

  const VoiceTurn({
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.isTransactionSaved = false,
  });
}

/// Orchestrates the 100% on-device voice conversation loop between the user and César.
class VoiceConversationController {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository? repository;
  late final FinancialReportRagEngine? ragEngine;
  final VoiceSynthesisService voiceSynthesis;
  final stt.SpeechToText speechToText;

  /// Shared with the chat: edit/delete/undo, corrections and questions about
  /// the data, with the same history and context as the typed conversation.
  final CesarAssistant? assistant;

  VoiceConversationController({
    required this.engine,
    this.repository,
    VoiceSynthesisService? voiceSynthesisService,
    stt.SpeechToText? sttInstance,
    this.assistant,
  })  : voiceSynthesis = voiceSynthesisService ?? VoiceSynthesisService(),
        speechToText = sttInstance ?? stt.SpeechToText(),
        ragEngine = repository != null ? FinancialReportRagEngine(repository: repository) : null;

  final ValueNotifier<VoiceState> stateNotifier = ValueNotifier<VoiceState>(VoiceState.idle);
  final ValueNotifier<String> userTranscriptNotifier = ValueNotifier<String>('');
  final ValueNotifier<String> cesarSpeechNotifier = ValueNotifier<String>('');
  final ValueNotifier<double> audioLevelNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> isHandsFreeNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool> isMutedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isSpeakerMutedNotifier = ValueNotifier<bool>(false);

  /// Recent turns in the active César Live session for multi-turn visual context.
  final ValueNotifier<List<VoiceTurn>> conversationHistoryNotifier =
      ValueNotifier<List<VoiceTurn>>(const []);

  /// Human-readable hint when César is waiting for a missing slot (e.g. payment method or amount).
  final ValueNotifier<String?> pendingSlotHintNotifier = ValueNotifier<String?>(null);

  /// Quick-tap chips shown in César Live so the user can answer with 1 tap or by voice.
  final ValueNotifier<List<String>> quickRepliesNotifier = ValueNotifier<List<String>>(const [
    'Quanto gastei este mês?',
    'Qual meu saldo?',
    'Contas da semana',
  ]);

  FinancialTransactionDraft? activeDraft;

  /// Unfinished multi-transaction batch (see [LocalFinancialNlpEngine.parseMulti]).
  List<FinancialTransactionDraft>? pendingBatch;
  bool _isDisposed = false;
  bool _isSttInitialized = false;
  bool _isSessionActive = false;
  bool _isProcessingTurn = false;
  String? _resolvedLocaleId;
  Timer? _speechTimeoutTimer;
  Timer? _silenceDebounceTimer;
  Timer? _postSpeechRestartTimer;

  /// Whether a César Live conversation session is currently active.
  bool get isSessionActive => _isSessionActive;

  /// Hands-free ends after this long listening without hearing anything.
  Duration idleTimeout = const Duration(seconds: 60);
  Timer? _idleTimer;

  /// Set by "tchau César": the conversation ends once César says goodbye.
  bool _endAfterSpeaking = false;

  /// The hands-free conversation ended by itself ("tchau César" or silence).
  VoidCallback? onConversationEnded;

  /// "tchau", "tchau César", "até mais", "pode parar", "obrigado, tchau".
  static bool isGoodbye(String phrase) {
    var s = phrase.toLowerCase().trim();
    const from = 'áàâãéêíóôõúç';
    const to = 'aaaaeeiooouc';
    for (var i = 0; i < from.length; i++) {
      s = s.replaceAll(from[i], to[i]);
    }
    s = s.replaceAll(RegExp(r'[.,!?]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return RegExp(r'^(?:(?:ok|ta|beleza|valeu|obrigad[oa]|era\s+isso|so\s+isso)\s+)*'
            r'(?:tchau|ate\s+mais|ate\s+logo|ate\s+amanha|ate\s+depois|encerra|encerrar|pode\s+parar|para\s+de\s+ouvir|desliga|fim)'
            r'(?:\s+(?:cesar|obrigad[oa]))*$')
        .hasMatch(s);
  }

  /// Computes an adaptive silence debounce duration for endpointing user speech:
  /// - Short (850–1050ms) when the utterance is a complete transaction, command, question, or slot answer.
  /// - Longer (1650–1850ms) when the user pauses mid-sentence on an incomplete draft or preposition.
  Duration computeSilenceDebounce(String partialTranscript) {
    final trimmed = partialTranscript.trim();
    if (trimmed.isEmpty) return const Duration(milliseconds: 1200);
    if (isGoodbye(trimmed)) return const Duration(milliseconds: 850);

    // Trailing conjunction or preposition indicates user is pausing mid-phrase ("gastei 50 no...")
    if (RegExp(
      r'\b(no|na|nos|nas|de|do|da|dos|das|pro|pra|para|com|em|e|ou|por|uns|umas|mais)\s*$',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return const Duration(milliseconds: 1850);
    }

    if (activeDraft != null && !activeDraft!.isComplete) {
      if (engine.isCancelCommand(trimmed, pending: activeDraft)) {
        return const Duration(milliseconds: 900);
      }
      final merged = engine.mergeDrafts(activeDraft!, trimmed);
      if (merged.isComplete) {
        return const Duration(milliseconds: 950);
      }
      return const Duration(milliseconds: 1450);
    }

    if (pendingBatch != null) {
      final firstOpen = pendingBatch!.firstWhere((d) => !d.isComplete, orElse: () => pendingBatch!.first);
      if (engine.isCancelCommand(trimmed, pending: firstOpen)) {
        return const Duration(milliseconds: 900);
      }
      final merged = engine.mergeMultiDrafts(pendingBatch!, trimmed);
      if (engine.multiClarificationPrompt(merged) == null) {
        return const Duration(milliseconds: 950);
      }
      return const Duration(milliseconds: 1450);
    }

    final draft = engine.parse(trimmed);
    if (LocalFinancialNlpEngine.isRecordable(draft) || draft.intent == 'query' || draft.isReportQuery) {
      return const Duration(milliseconds: 1050);
    }
    if (!draft.isComplete && draft.intent != 'unknown') {
      // User started a transaction ("gastei 50 no mercado") — give extra time to say "no pix"
      return const Duration(milliseconds: 1650);
    }
    return const Duration(milliseconds: 1200);
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    if (!isHandsFreeNotifier.value) return;
    _idleTimer = Timer(idleTimeout, () {
      if (_isDisposed || stateNotifier.value != VoiceState.listening) return;
      if (userTranscriptNotifier.value.trim().isNotEmpty) return;
      _endConversation();
    });
  }

  Future<void> _endConversation() async {
    _endAfterSpeaking = false;
    _idleTimer?.cancel();
    await stopConversation();
    if (!_isDisposed) onConversationEnded?.call();
  }

  /// Fired whenever the user finishes speaking a phrase in César Live.
  void Function(String userPhrase)? onUserSpoken;

  /// Fired when César produces a standalone conversational/system reply (goals, debt, affordability, cancel).
  void Function(String text, {String? spokenText})? onSystemMessage;

  void Function(FinancialTransactionDraft completedDraft)? onTransactionCompleted;
  void Function(ReportRagResult reportResult)? onReportGenerated;

  /// A reply from [assistant] (edit, delete, undo, answer) for the chat log.
  void Function(AssistantReply reply)? onAssistantReply;

  Future<void> initialize() async {
    await voiceSynthesis.initialize();
    voiceSynthesis.onCompletion = _handleCesarSpeechCompleted;
    await _ensureSttInitialized();
  }

  /// Handles STT status notifications (called directly or forwarded from ChatScreen's shared SpeechToText).
  void handleExternalSttStatus(String status) {
    if (_isDisposed || !_isSessionActive) return;
    debugPrint('[VoiceConversationController] STT Status: $status');
    if (status == 'done' || status == 'notListening') {
      if (stateNotifier.value == VoiceState.listening && !_isProcessingTurn) {
        final words = userTranscriptNotifier.value.trim();
        if (words.isNotEmpty) {
          _silenceDebounceTimer?.cancel();
          _processCurrentTranscript();
        } else if (isHandsFreeNotifier.value && !isMutedNotifier.value && !_isDisposed) {
          // In Chrome Web Speech / mobile STT, auto-restart listening after silence in hands-free mode
          Future.delayed(const Duration(milliseconds: 350), () {
            if (!_isDisposed &&
                _isSessionActive &&
                stateNotifier.value == VoiceState.listening &&
                !_isProcessingTurn) {
              _startListeningInternal();
            }
          });
        }
      }
    }
  }

  /// Handles STT error notifications (called directly or forwarded from ChatScreen's shared SpeechToText).
  void handleExternalSttError(dynamic error) {
    if (_isDisposed || !_isSessionActive) return;
    String errorMsg;
    try {
      errorMsg = (error.errorMsg as String?) ?? error.toString();
    } catch (_) {
      errorMsg = error.toString();
    }
    debugPrint('[VoiceConversationController] STT Error: $errorMsg');
    final msg = errorMsg.toLowerCase();
    final isRecoverable = msg.contains('no_match') ||
        msg.contains('no-speech') ||
        msg.contains('speech_timeout') ||
        msg.contains('timeout') ||
        msg.contains('error_7') ||
        msg.contains('error_6') ||
        msg.contains('client') ||
        msg.contains('busy');
    if (isRecoverable &&
        isHandsFreeNotifier.value &&
        !isMutedNotifier.value &&
        !_isDisposed) {
      Future.delayed(const Duration(milliseconds: 250), () {
        if (!_isDisposed &&
            _isSessionActive &&
            stateNotifier.value == VoiceState.listening &&
            isHandsFreeNotifier.value &&
            !isMutedNotifier.value &&
            !_isProcessingTurn) {
          _startListeningInternal();
        }
      });
    } else if (stateNotifier.value == VoiceState.listening) {
      audioLevelNotifier.value = 0.0;
    }
  }

  Future<bool> _ensureSttInitialized() async {
    if (_isSttInitialized) return true;
    try {
      if (speechToText.isAvailable) {
        _isSttInitialized = true;
      } else {
        _isSttInitialized = await speechToText.initialize(
          onStatus: handleExternalSttStatus,
          onError: handleExternalSttError,
        );
      }
      if (_isSttInitialized && _resolvedLocaleId == null) {
        try {
          final locales = await speechToText.locales();
          stt.LocaleName? ptBR;
          stt.LocaleName? ptAny;
          for (final loc in locales) {
            final id = loc.localeId.replaceAll('_', '-').toLowerCase();
            if (id == 'pt-br') {
              ptBR = loc;
              break;
            }
            if (id.startsWith('pt') && ptAny == null) {
              ptAny = loc;
            }
          }
          final best = ptBR ?? ptAny;
          if (best != null) {
            _resolvedLocaleId = best.localeId.replaceAll('_', '-');
          }
        } catch (_) {}
      }
      return _isSttInitialized;
    } catch (e) {
      debugPrint('[VoiceConversationController] STT Init Error: $e');
      return false;
    }
  }

  /// Starts the voice conversation session.
  Future<void> startConversation({bool speakGreeting = true}) async {
    _isSessionActive = true;
    _isProcessingTurn = false;
    _endAfterSpeaking = false;
    voiceSynthesis.onCompletion = _handleCesarSpeechCompleted;
    stateNotifier.value = VoiceState.idle;
    userTranscriptNotifier.value = '';
    activeDraft = null;
    pendingBatch = null;
    conversationHistoryNotifier.value = const [];
    _syncPendingInteractiveState();

    if (speakGreeting && !isSpeakerMutedNotifier.value) {
      const greeting = 'Olá! Sou o César. Pode falar o que deseja lançar ou consultar.';
      _appendTurn(isUser: false, text: greeting);
      await _speakAsCesar(greeting);
    } else {
      await startListening();
    }
  }

  /// Opens the microphone and listens for user speech.
  Future<void> startListening() async {
    if (_isDisposed || isMutedNotifier.value) return;
    _isSessionActive = true;
    _isProcessingTurn = false;

    _postSpeechRestartTimer?.cancel();
    _silenceDebounceTimer?.cancel();
    await voiceSynthesis.stop();

    final hasSpeech = await _ensureSttInitialized();
    if (!hasSpeech) {
      debugPrint('[VoiceConversationController] Microphone permission or speech not available');
      return;
    }

    await _startListeningInternal();
    _armIdleTimer();
  }

  Future<void> _startListeningInternal() async {
    if (_isDisposed || isMutedNotifier.value) return;

    try {
      if (speechToText.isListening) {
        await speechToText.stop();
        await Future.delayed(const Duration(milliseconds: 150));
      }
      if (_isDisposed || isMutedNotifier.value) return;
      if (stateNotifier.value == VoiceState.speaking || stateNotifier.value == VoiceState.thinking) return;

      stateNotifier.value = VoiceState.listening;
      audioLevelNotifier.value = 0.20;
      userTranscriptNotifier.value = '';

      await speechToText.listen(
        localeId: _resolvedLocaleId,
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
        onResult: (result) {
          if (_isDisposed || stateNotifier.value != VoiceState.listening || _isProcessingTurn) return;
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) {
            userTranscriptNotifier.value = result.recognizedWords;
            _armIdleTimer();
          }

          // 1. Immediate finalize if engine flagged finalResult
          if (result.finalResult && words.isNotEmpty) {
            _silenceDebounceTimer?.cancel();
            _processCurrentTranscript();
            return;
          }

          // 2. Continuous Voice Activity Detection (VAD) via adaptive silence debounce
          if (words.isNotEmpty) {
            _silenceDebounceTimer?.cancel();
            final waitDuration = computeSilenceDebounce(words);
            _silenceDebounceTimer = Timer(waitDuration, () {
              if (!_isDisposed &&
                  stateNotifier.value == VoiceState.listening &&
                  !_isProcessingTurn &&
                  userTranscriptNotifier.value.trim().isNotEmpty) {
                _processCurrentTranscript();
              }
            });
          }
        },
        onSoundLevelChange: (level) {
          final normalized = (level + 10) / 20.0;
          audioLevelNotifier.value = normalized.clamp(0.05, 1.0);
        },
        pauseFor: const Duration(seconds: 6),
        listenFor: const Duration(seconds: 45),
      );
    } catch (e) {
      debugPrint('[VoiceConversationController] _startListeningInternal error: $e');
    }
  }

  /// Manually commits whatever words have been transcribed so far and stops recording.
  void manualCommitSpeech() {
    stopRecordingUserSpeech(processTranscript: true);
  }

  /// Submits a quick-reply chip or suggested phrase directly into the César Live loop.
  Future<void> submitQuickPhrase(String phrase) async {
    final trimmed = phrase.trim();
    if (_isDisposed || trimmed.isEmpty) return;
    _silenceDebounceTimer?.cancel();
    _postSpeechRestartTimer?.cancel();
    _idleTimer?.cancel();
    await voiceSynthesis.stop();
    userTranscriptNotifier.value = trimmed;
    _isProcessingTurn = false;
    stateNotifier.value = VoiceState.listening;
    _processCurrentTranscript();
  }

  /// Stops recording the user's microphone immediately.
  /// If [processTranscript] is true and words were recognized, sends them to César;
  /// otherwise pauses the microphone so it does not auto-restart.
  Future<void> stopRecordingUserSpeech({bool processTranscript = true}) async {
    _silenceDebounceTimer?.cancel();
    _idleTimer?.cancel();
    _postSpeechRestartTimer?.cancel();
    if (processTranscript && userTranscriptNotifier.value.trim().isNotEmpty) {
      _processCurrentTranscript();
      return;
    }
    stateNotifier.value = VoiceState.paused;
    await stopListening();
  }

  /// Immediately stops César's ongoing speech without waiting for it to finish.
  /// When [resumeListening] is true (barge-in), immediately opens the microphone for the user.
  Future<void> interruptCesarSpeech({bool resumeListening = false}) async {
    _postSpeechRestartTimer?.cancel();
    _speechTimeoutTimer?.cancel();
    _idleTimer?.cancel();
    audioLevelNotifier.value = 0.0;
    if (!_isDisposed) {
      stateNotifier.value = VoiceState.idle;
    }
    await voiceSynthesis.stop();
    if (resumeListening && !_isDisposed && !isMutedNotifier.value) {
      await startListening();
    }
  }

  /// Stops listening to the user.
  Future<void> stopListening() async {
    _silenceDebounceTimer?.cancel();
    try {
      await speechToText.stop();
      audioLevelNotifier.value = 0.0;
    } catch (e) {
      debugPrint('[VoiceConversationController] stopListening error: $e');
    }
  }

  void _appendTurn({
    required bool isUser,
    required String text,
    bool isTransactionSaved = false,
  }) {
    if (_isDisposed || text.trim().isEmpty) return;
    final updated = List<VoiceTurn>.from(conversationHistoryNotifier.value)
      ..add(VoiceTurn(
        isUser: isUser,
        text: text.trim(),
        timestamp: DateTime.now(),
        isTransactionSaved: isTransactionSaved,
      ));
    if (updated.length > 12) {
      updated.removeRange(0, updated.length - 12);
    }
    conversationHistoryNotifier.value = List<VoiceTurn>.unmodifiable(updated);
  }

  void _syncPendingInteractiveState({String? lastSpoken}) {
    if (_isDisposed) return;
    if (activeDraft != null && !activeDraft!.isComplete) {
      final missing = activeDraft!.missingSlots;
      if (missing.contains('payment_method')) {
        pendingSlotHintNotifier.value = 'Falta informar: Forma de pagamento';
        quickRepliesNotifier.value = const [
          'No Pix',
          'No débito',
          'No crédito',
          'Em dinheiro',
          'Cancelar',
        ];
      } else if (missing.contains('amount')) {
        pendingSlotHintNotifier.value = 'Falta informar: Valor do lançamento';
        quickRepliesNotifier.value = const [
          'R\$ 25',
          'R\$ 50',
          'R\$ 100',
          'Cancelar',
        ];
      } else {
        pendingSlotHintNotifier.value = 'Aguardando complemento do lançamento';
        quickRepliesNotifier.value = const [
          'No Pix',
          'No débito',
          'Cancelar',
        ];
      }
      return;
    }

    if (pendingBatch != null && pendingBatch!.isNotEmpty) {
      pendingSlotHintNotifier.value = 'Falta informar: Forma de pagamento dos ${pendingBatch!.length} itens';
      quickRepliesNotifier.value = const [
        'Tudo no Pix',
        'Tudo no débito',
        'Tudo no crédito',
        'Cancelar',
      ];
      return;
    }

    final lowerSpoken = (lastSpoken ?? '').toLowerCase();
    if (lowerSpoken.contains('confirma') ||
        lowerSpoken.contains('tem certeza') ||
        lowerSpoken.contains('pode apagar') ||
        lowerSpoken.contains('quer mesmo')) {
      pendingSlotHintNotifier.value = 'Confirmação pendente';
      quickRepliesNotifier.value = const [
        'Sim, confirmo',
        'Não, cancela',
      ];
      return;
    }

    pendingSlotHintNotifier.value = null;
    quickRepliesNotifier.value = const [
      'Quanto gastei este mês?',
      'Qual meu saldo?',
      'Contas da semana',
      'Desfazer último',
    ];
  }

  void _respondAndSpeak(
    String spokenText, {
    String? chatText,
    bool isTransactionSaved = false,
    bool notifySystemMessage = false,
  }) {
    _appendTurn(
      isUser: false,
      text: spokenText,
      isTransactionSaved: isTransactionSaved,
    );
    _syncPendingInteractiveState(lastSpoken: spokenText);
    if (notifySystemMessage) {
      onSystemMessage?.call(chatText ?? spokenText, spokenText: spokenText);
    }
    _speakAsCesar(spokenText);
  }

  void _processCurrentTranscript() {
    if (_isProcessingTurn ||
        stateNotifier.value == VoiceState.thinking ||
        stateNotifier.value == VoiceState.speaking) {
      return;
    }
    _postSpeechRestartTimer?.cancel();
    _silenceDebounceTimer?.cancel();
    _idleTimer?.cancel();
    var phrase = userTranscriptNotifier.value.trim();
    if (phrase.isEmpty) return;

    _isProcessingTurn = true;
    stateNotifier.value = VoiceState.thinking;
    stopListening();

    _appendTurn(isUser: true, text: phrase);
    onUserSpoken?.call(phrase);

    if (isGoodbye(phrase)) {
      _endAfterSpeaking = true;
      _respondAndSpeak('Até mais! Quando precisar, é só me chamar.');
      return;
    }

    final lower = phrase.toLowerCase();
    String? conversationalResponse;
    if (repository != null) engine.setCustomCategories(repository!.customCategoryNames);

    // 0a. Cancel an incomplete pending draft immediately ("cancela", "esquece")
    final hasPendingEarly = activeDraft != null && !activeDraft!.isComplete;
    if (hasPendingEarly && engine.isCancelCommand(phrase, pending: activeDraft)) {
      activeDraft = null;
      _respondAndSpeak(
        'Tudo bem, descartei esse lançamento. Nada foi registrado.',
        chatText: 'Tudo bem, descartei esse lançamento. Nada foi registrado. 👍',
        notifySystemMessage: true,
      );
      return;
    }

    // 0b. Same as the chat: edit / delete / undo / corrections ("não, foi
    // 45", "apaga o uber de ontem", "desfaz") and answers to César's own
    // pending question (confirm a delete).
    final assistant = this.assistant;
    if (assistant != null) {
      assistant.beginTurn();
      if (pendingBatch == null) {
        final reply = assistant.handleCommand(phrase, hasPendingDraft: hasPendingEarly);
        if (reply != null && reply.rewrittenInput != null) {
          phrase = reply.rewrittenInput!;
        } else if (reply != null) {
          activeDraft = null;
          onAssistantReply?.call(reply);
          _respondAndSpeak(reply.spokenText);
          return;
        }
      }

      // 1. Questions about the data, with follow-ups ("e ontem?").
      if (pendingBatch == null) {
        final answer = assistant.handleQuestion(phrase);
        if (answer != null) {
          activeDraft = null;
          onAssistantReply?.call(answer);
          _respondAndSpeak(answer.spokenText);
          return;
        }
      }
    }

    // 1. Process Report & Analytical Queries via RAG Engine
    if (assistant == null && ragEngine != null && FinancialReportRagEngine.isReportQuery(phrase)) {
      final reportResult = ragEngine!.generateReport(phrase);
      activeDraft = null;
      onReportGenerated?.call(reportResult);
      _respondAndSpeak(reportResult.spokenText);
      return;
    }

    // 2. Check for Debt Repayment ("o João me pagou a dívida dele, porém apenas 70 reais")
    // With no open debt in that name it is ordinary income — it goes on to
    // the normal parse below (same as the chat).
    String? preface;
    if (repository != null) {
      final debtPayment = DebtPaymentParser.parse(phrase);
      final List<FinancialReminder> matches =
          debtPayment == null ? const [] : repository!.findDebtorsByName(debtPayment.personName);
      if (debtPayment != null && matches.isEmpty) {
        preface = DebtPaymentParser.noOpenDebtNote(debtPayment.personName);
      } else if (debtPayment != null) {
        String responseText;

        if (matches.length > 1) {
          responseText =
              'Encontrei mais de uma cobrança pendente no nome de ${debtPayment.personName}. Pode me dizer o valor original da dívida?';
        } else {
          final result = repository!.applyDebtPayment(matches.first.id, debtPayment.amountPaid);
          responseText = DebtPaymentParser.paymentReply(
            debtPayment.personName,
            paid: result.amountPaid,
            remaining: result.remainingBalance,
            fullyPaid: result.isFullyPaid,
            excess: result.excess,
          ).replaceAll(' 🎉', '');
        }

        activeDraft = null;
        _respondAndSpeak(responseText, notifySystemMessage: true);
        return;
      }
    }

    // 3. Check for Savings Goal creation / contribution ("quero juntar 5000 pra viagem", "guardei 100 na meta da viagem")
    if (repository != null) {
      final goalCreation = GoalParser.parseCreation(phrase);
      if (goalCreation != null) {
        final goal = FinancialGoal(
          id: 'goal-${DateTime.now().millisecondsSinceEpoch}',
          title: goalCreation.title,
          targetAmount: goalCreation.targetAmount,
          targetDate: goalCreation.targetDate,
        );
        repository!.addGoal(goal);

        final targetStr = Money.brl(goalCreation.targetAmount);
        var responseText = 'Meta criada! Vou te ajudar a juntar $targetStr para "${goalCreation.title}".';
        final monthly = goal.suggestedMonthlyContribution;
        if (monthly != null) {
          responseText += ' Guardando ${Money.brl(monthly)} por mês você chega lá a tempo.';
        } else {
          responseText += ' Quando quiser, é só me dizer quanto guardou.';
        }

        activeDraft = null;
        _respondAndSpeak(
          responseText,
          chatText: '$responseText 🎯',
          isTransactionSaved: true,
          notifySystemMessage: true,
        );
        return;
      }

      final goalContribution = GoalParser.parseContribution(phrase);
      if (goalContribution != null) {
        final matches = repository!.findGoalsByTitle(goalContribution.goalTitle);
        String responseText;

        if (matches.isEmpty) {
          responseText =
              'Não encontrei nenhuma meta chamada "${goalContribution.goalTitle}". Quer criar uma nova meta com esse valor?';
        } else if (matches.length > 1) {
          responseText =
              'Encontrei mais de uma meta parecida com "${goalContribution.goalTitle}". Pode ser mais específico?';
        } else {
          final updated = repository!.contributeToGoal(matches.first.id, goalContribution.amount);
          final savedStr = Money.brl(updated.savedAmount);
          final targetStr = Money.brl(updated.targetAmount);
          if (updated.isCompleted) {
            responseText = 'Parabéns! Você bateu a meta "${updated.title}": $savedStr guardados!';
          } else {
            final percent = (updated.progress * 100).toStringAsFixed(0);
            responseText = 'Anotado! "${updated.title}" já tem $savedStr de $targetStr guardados ($percent%).';
          }
        }

        activeDraft = null;
        _respondAndSpeak(
          responseText,
          isTransactionSaved: matches.length == 1,
          notifySystemMessage: true,
        );
        return;
      }
    }

    // 4. Check for Affordability Questions ("posso comprar um notebook de 3000?")
    if (repository != null) {
      final affordability = AffordabilityAnalyzer(repository: repository!).analyze(phrase);
      if (affordability != null) {
        activeDraft = null;
        _respondAndSpeak(
          affordability.spokenText,
          chatText: affordability.formattedText,
          notifySystemMessage: true,
        );
        return;
      }
    }

    // 5. Handle common conversational questions directly & empathetically
    if (lower.contains('quem e voce') ||
        lower.contains('quem é você') ||
        lower.contains('quem e vc') ||
        lower.contains('quem é vc')) {
      conversationalResponse = 'Eu sou o César, seu consultor financeiro inteligente no Krezio.ai!';
    } else if (lower.contains('como funciona') ||
        lower.contains('o que voce faz') ||
        lower.contains('o que você faz') ||
        lower.contains('ajuda') ||
        lower.contains('o que posso falar') ||
        lower.contains('como te usar')) {
      conversationalResponse =
          'Você pode me falar seus gastos, receitas ou pedir para registrar empréstimos. Por exemplo: "Gastei 50 no almoço no débito", "Recebi 3000 de salário" ou "Emprestei 100 pro João". O que gostaria de fazer?';
    } else if (lower.contains('obrigado') ||
        lower.contains('valeu') ||
        lower.contains('obrigada') ||
        lower.contains('muito obrigado')) {
      conversationalResponse = 'Por nada! Estou sempre por aqui para te ajudar a manter suas finanças organizadas.';
    } else if (lower == 'ola' || lower == 'olá' || lower == 'oi' || lower == 'e ai' || lower == 'e aí') {
      conversationalResponse = 'Olá! Tudo bem? Pode me falar o que deseja lançar ou consultar hoje.';
    }

    if (conversationalResponse != null) {
      activeDraft = null;
      _respondAndSpeak(conversationalResponse, notifySystemMessage: true);
      return;
    }

    // 6. Process financial transaction speech 100% on-device in under 5ms
    FinancialTransactionDraft draft;
    if (repository != null) engine.setCustomCategories(repository!.customCategoryNames);
    final hasPending = activeDraft != null && !activeDraft!.isComplete;

    // Unfinished multi-transaction batch: this phrase answers its question
    // (same rules as the chat), unless it is a brand-new sentence.
    if (pendingBatch != null) {
      final batch = pendingBatch!;
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (engine.isCancelCommand(phrase, pending: firstOpen)) {
        pendingBatch = null;
        _respondAndSpeak(
          'Tudo bem, descartei esses lançamentos. Nada foi registrado.',
          chatText: 'Tudo bem, descartei esses lançamentos. Nada foi registrado. 👍',
          notifySystemMessage: true,
        );
        return;
      }
      final whatIf = assistant?.hypothesisReply(phrase);
      if (whatIf != null) {
        onAssistantReply?.call(whatIf);
        _respondAndSpeak(whatIf.spokenText);
        return;
      }
      if (!engine.startsNewTransaction(firstOpen, phrase)) {
        final merged = engine.mergeMultiDrafts(batch, phrase);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          pendingBatch = null;
          _completeBatch(merged);
        } else {
          pendingBatch = merged;
          _respondAndSpeak(prompt, notifySystemMessage: true);
        }
        return;
      }
      pendingBatch = null;
    }

    // A batch is also a new subject when a draft was pending: it replaces
    // the draft, and César says so (same as the chat, CHAOS-B-007).
    if (!hasPending || engine.startsNewTransaction(activeDraft!, phrase)) {
      final multi = engine.parseMulti(phrase);
      if (multi.length >= 2) {
        final dropped = hasPending ? '${LocalFinancialNlpEngine.discardedDraftNotice(activeDraft!)} ' : '';
        activeDraft = null;
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) {
          _completeBatch(multi, notice: dropped);
        } else {
          pendingBatch = multi;
          _respondAndSpeak('$dropped$prompt', notifySystemMessage: true);
        }
        return;
      }
    }

    var isMerged = false;
    String? discardedNotice;
    if (hasPending && !engine.startsNewTransaction(activeDraft!, phrase)) {
      draft = engine.mergeDrafts(activeDraft!, phrase);
      isMerged = true;
    } else {
      // Same as the chat: say so when a new sentence drops a pending draft.
      if (hasPending) discardedNotice = LocalFinancialNlpEngine.discardedDraftNotice(activeDraft!);
      draft = engine.parse(phrase);
    }

    if (draft.isComplete && repository != null) {
      draft = repository!.applyCategoryMemory(draft);
    }

    activeDraft = draft;

    String responseText;
    bool savedTransaction = false;
    if (!draft.isComplete && draft.clarificationPrompt != null) {
      responseText = draft.clarificationPrompt!;
    } else if (draft.isReportQuery && ragEngine != null) {
      final report = ragEngine!.generateReport(phrase);
      responseText = report.spokenText;
      onReportGenerated?.call(report);
      activeDraft = null;
    } else if (draft.intent == 'query') {
      responseText = engine.replyForQuestion(draft);
      activeDraft = null;
    } else if (LocalFinancialNlpEngine.isRecordable(draft)) {
      savedTransaction = true;
      onTransactionCompleted?.call(draft);
      final amountStr = draft.amount != null ? 'de ${Money.brl(draft.amount!)}' : '';
      if (draft.billingDay != null && draft.paymentMarginDays != null) {
        responseText =
            'Pronto! Anotei o boleto de ${draft.description}: fecha dia ${draft.billingDay} e vence no dia ${draft.dueDay}, com ${draft.paymentMarginDays} dias de margem.';
      } else if (draft.isReminder && draft.reminderType == 'loan_receivable') {
        responseText = 'Combinado! Anotei o empréstimo $amountStr. Eu te lembro na data combinada.';
      } else if (draft.isReminder && draft.reminderType == 'dividend') {
        responseText = 'Perfeito! Deixei o lembrete de dividendos $amountStr agendado.';
      } else if (draft.intent == 'income') {
        responseText = 'Boa! Registrei a receita $amountStr.';
      } else {
        responseText = 'Pronto! Anotei a despesa $amountStr.';
      }
      if (!isMerged && draft.assumptionNote != null) responseText += ' ${draft.assumptionNote}';
      activeDraft = null; // Clear draft upon completion
    } else {
      responseText = draft.clarificationPrompt ??
          'Não consegui identificar essa transação. Pode me dizer o valor e onde foi gasto?';
      activeDraft = null; // Clear draft to avoid locking into a broken merge loop
    }

    if (preface != null) responseText = '$preface $responseText';
    if (discardedNotice != null) responseText = '$discardedNotice $responseText';
    _respondAndSpeak(
      responseText,
      isTransactionSaved: savedTransaction,
      notifySystemMessage: !savedTransaction && draft.isReportQuery == false,
    );
  }

  /// Hands every item of a complete batch to the chat (which saves each one)
  /// and says how many were recorded.
  void _completeBatch(List<FinancialTransactionDraft> drafts, {String notice = ''}) {
    for (final d in drafts) {
      final applied = (d.isComplete && repository != null) ? repository!.applyCategoryMemory(d) : d;
      onTransactionCompleted?.call(applied);
    }
    final total = drafts.fold(0.0, (acc, d) => acc + (d.amount ?? 0));
    _respondAndSpeak(
      '${notice}Anotado! ${drafts.length} lançamentos registrados, somando ${Money.brl(total)}.',
      isTransactionSaved: true,
    );
  }

  Future<void> previewVoice() async {
    if (_isDisposed ||
        isSpeakerMutedNotifier.value ||
        stateNotifier.value == VoiceState.thinking ||
        _endAfterSpeaking) {
      return;
    }
    if (stateNotifier.value == VoiceState.listening) {
      await stopListening();
      if (_isDisposed || isSpeakerMutedNotifier.value) return;
    }
    await _speakAsCesar('Olá! Sou o César. Esta é uma amostra da minha voz.');
  }

  Future<void> _speakAsCesar(String text) async {
    _postSpeechRestartTimer?.cancel();
    _idleTimer?.cancel();
    _isProcessingTurn = false;
    cesarSpeechNotifier.value = text;
    stateNotifier.value = VoiceState.speaking;
    audioLevelNotifier.value = 0.6; // Pulsing during speech
    voiceSynthesis.onCompletion = _handleCesarSpeechCompleted;

    if (!isSpeakerMutedNotifier.value) {
      await voiceSynthesis.speak(text);
    } else {
      // If speaker is muted, wait briefly and trigger completion
      _speechTimeoutTimer?.cancel();
      _speechTimeoutTimer = Timer(const Duration(seconds: 2), _handleCesarSpeechCompleted);
    }
  }

  void _handleCesarSpeechCompleted() {
    if (_isDisposed || !_isSessionActive) return;
    audioLevelNotifier.value = 0.0;

    if (stateNotifier.value == VoiceState.speaking) {
      if (_endAfterSpeaking) {
        _endConversation();
        return;
      }
      if (isHandsFreeNotifier.value && !isMutedNotifier.value) {
        // Wait 300ms for browser/mobile audio context to cleanly switch from playback to record
        _postSpeechRestartTimer?.cancel();
        _postSpeechRestartTimer = Timer(const Duration(milliseconds: 300), () {
          if (!_isDisposed &&
              _isSessionActive &&
              isHandsFreeNotifier.value &&
              !isMutedNotifier.value &&
              stateNotifier.value == VoiceState.speaking &&
              !voiceSynthesis.isSpeakingNotifier.value) {
            startListening();
          }
        });
      } else {
        stateNotifier.value = VoiceState.idle;
      }
    }
  }

  void toggleMute() {
    isMutedNotifier.value = !isMutedNotifier.value;
    if (isMutedNotifier.value) {
      stopListening();
      if (stateNotifier.value == VoiceState.listening) {
        stateNotifier.value = VoiceState.paused;
      }
    } else {
      if (stateNotifier.value == VoiceState.paused || stateNotifier.value == VoiceState.idle) {
        startListening();
      }
    }
  }

  void toggleSpeaker() {
    isSpeakerMutedNotifier.value = !isSpeakerMutedNotifier.value;
    if (isSpeakerMutedNotifier.value) {
      voiceSynthesis.stop();
    }
  }

  void toggleHandsFree() {
    isHandsFreeNotifier.value = !isHandsFreeNotifier.value;
  }

  Future<void> pauseOrResume() async {
    _postSpeechRestartTimer?.cancel();
    if (stateNotifier.value == VoiceState.paused) {
      stateNotifier.value = VoiceState.idle;
      await startListening();
    } else {
      stateNotifier.value = VoiceState.paused;
      await stopListening();
      await voiceSynthesis.stop();
    }
  }

  Future<void> stopConversation() async {
    if (_isDisposed) return;
    _isSessionActive = false;
    _isProcessingTurn = false;
    _postSpeechRestartTimer?.cancel();
    _speechTimeoutTimer?.cancel();
    _silenceDebounceTimer?.cancel();
    _idleTimer?.cancel();
    if (voiceSynthesis.onCompletion == _handleCesarSpeechCompleted) {
      voiceSynthesis.onCompletion = null;
    }
    await stopListening();
    await voiceSynthesis.stop();
    if (!_isDisposed) {
      stateNotifier.value = VoiceState.idle;
      audioLevelNotifier.value = 0.0;
      activeDraft = null;
      pendingBatch = null;
      pendingSlotHintNotifier.value = null;
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isSessionActive = false;
    _postSpeechRestartTimer?.cancel();
    _idleTimer?.cancel();
    _speechTimeoutTimer?.cancel();
    _silenceDebounceTimer?.cancel();
    if (voiceSynthesis.onCompletion == _handleCesarSpeechCompleted) {
      voiceSynthesis.onCompletion = null;
    }
    try {
      speechToText.stop();
      voiceSynthesis.stop();
    } catch (_) {}
    stateNotifier.dispose();
    userTranscriptNotifier.dispose();
    cesarSpeechNotifier.dispose();
    audioLevelNotifier.dispose();
    isHandsFreeNotifier.dispose();
    isMutedNotifier.dispose();
    isSpeakerMutedNotifier.dispose();
    conversationHistoryNotifier.dispose();
    pendingSlotHintNotifier.dispose();
    quickRepliesNotifier.dispose();
  }
}
