import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../local_nlp_engine.dart';
import '../financial_report_rag_engine.dart';
import '../debt_payment_parser.dart';
import '../affordability_analyzer.dart';
import '../cesar_assistant.dart';
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

  FinancialTransactionDraft? activeDraft;

  /// Unfinished multi-transaction batch (see [LocalFinancialNlpEngine.parseMulti]).
  List<FinancialTransactionDraft>? pendingBatch;
  bool _isDisposed = false;
  bool _isSttInitialized = false;
  Timer? _speechTimeoutTimer;
  Timer? _silenceDebounceTimer;

  void Function(FinancialTransactionDraft completedDraft)? onTransactionCompleted;
  void Function(ReportRagResult reportResult)? onReportGenerated;

  /// A reply from [assistant] (edit, delete, undo, answer) for the chat log.
  void Function(AssistantReply reply)? onAssistantReply;

  Future<void> initialize() async {
    await voiceSynthesis.initialize();
    voiceSynthesis.onCompletion = _handleCesarSpeechCompleted;
    await _ensureSttInitialized();
  }

  Future<bool> _ensureSttInitialized() async {
    if (_isSttInitialized) return true;
    try {
      _isSttInitialized = await speechToText.initialize(
        onStatus: (status) {
          debugPrint('[VoiceConversationController] STT Status: $status');
          if (status == 'done' || status == 'notListening') {
            if (stateNotifier.value == VoiceState.listening) {
              final words = userTranscriptNotifier.value.trim();
              if (words.isNotEmpty) {
                _silenceDebounceTimer?.cancel();
                _processCurrentTranscript();
              } else if (isHandsFreeNotifier.value && !isMutedNotifier.value && !_isDisposed) {
                // In Chrome Web Speech, auto-restart listening after silence in hands-free mode
                Future.delayed(const Duration(milliseconds: 350), () {
                  if (stateNotifier.value == VoiceState.listening && !_isDisposed) {
                    _startListeningInternal();
                  }
                });
              }
            }
          }
        },
        onError: (error) {
          debugPrint('[VoiceConversationController] STT Error: ${error.errorMsg}');
          if ((error.errorMsg == 'error_no_match' || error.errorMsg == 'no-speech') &&
              isHandsFreeNotifier.value &&
              !_isDisposed) {
            _startListeningInternal();
          } else if (stateNotifier.value == VoiceState.listening) {
            audioLevelNotifier.value = 0.0;
          }
        },
      );
      return _isSttInitialized;
    } catch (e) {
      debugPrint('[VoiceConversationController] STT Init Error: $e');
      return false;
    }
  }

  /// Starts the voice conversation session.
  Future<void> startConversation({bool speakGreeting = true}) async {
    stateNotifier.value = VoiceState.idle;
    userTranscriptNotifier.value = '';
    activeDraft = null;

    if (speakGreeting && !isSpeakerMutedNotifier.value) {
      const greeting = 'Olá! Sou o César. Pode falar o que deseja lançar ou consultar.';
      await _speakAsCesar(greeting);
    } else {
      await startListening();
    }
  }

  /// Opens the microphone and listens for user speech.
  Future<void> startListening() async {
    if (_isDisposed || isMutedNotifier.value) return;

    _silenceDebounceTimer?.cancel();
    await voiceSynthesis.stop();

    final hasSpeech = await _ensureSttInitialized();
    if (!hasSpeech) {
      debugPrint('[VoiceConversationController] Microphone permission or speech not available');
      return;
    }

    await _startListeningInternal();
  }

  Future<void> _startListeningInternal() async {
    if (_isDisposed || isMutedNotifier.value) return;

    try {
      if (speechToText.isListening) {
        await speechToText.stop();
        await Future.delayed(const Duration(milliseconds: 150));
      }

      stateNotifier.value = VoiceState.listening;
      audioLevelNotifier.value = 0.20;
      userTranscriptNotifier.value = '';

      await speechToText.listen(
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) {
            userTranscriptNotifier.value = result.recognizedWords;
          }

          // 1. Immediate finalize if engine flagged finalResult
          if (result.finalResult && words.isNotEmpty) {
            _silenceDebounceTimer?.cancel();
            _processCurrentTranscript();
            return;
          }

          // 2. Continuous Voice Activity Detection (VAD) via silence debounce
          // 1.2s of silence after speech guarantees natural, snappy finalization.
          if (words.isNotEmpty) {
            _silenceDebounceTimer?.cancel();
            _silenceDebounceTimer = Timer(const Duration(milliseconds: 1200), () {
              if (stateNotifier.value == VoiceState.listening && userTranscriptNotifier.value.trim().isNotEmpty) {
                _processCurrentTranscript();
              }
            });
          }
        },
        onSoundLevelChange: (level) {
          final normalized = (level + 10) / 20.0;
          audioLevelNotifier.value = normalized.clamp(0.05, 1.0);
        },
        pauseFor: const Duration(seconds: 3),
      );
    } catch (e) {
      debugPrint('[VoiceConversationController] _startListeningInternal error: $e');
    }
  }

  /// Manually commits whatever words have been transcribed so far without waiting.
  void manualCommitSpeech() {
    _silenceDebounceTimer?.cancel();
    if (userTranscriptNotifier.value.trim().isNotEmpty) {
      _processCurrentTranscript();
    } else if (stateNotifier.value != VoiceState.listening) {
      startListening();
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

  void _processCurrentTranscript() {
    _silenceDebounceTimer?.cancel();
    var phrase = userTranscriptNotifier.value.trim();
    if (phrase.isEmpty) return;

    stopListening();
    stateNotifier.value = VoiceState.thinking;

    final lower = phrase.toLowerCase();
    String? conversationalResponse;
    if (repository != null) engine.setCustomCategories(repository!.customCategoryNames);

    // 0. Same as the chat: edit / delete / undo / corrections ("não, foi
    // 45", "apaga o uber de ontem", "desfaz") and answers to César's own
    // pending question (confirm a delete). A "cancela" for a draft still
    // being asked about stays with the draft logic below.
    final assistant = this.assistant;
    if (assistant != null) {
      assistant.beginTurn();
      final hasPendingEarly = activeDraft != null && !activeDraft!.isComplete;
      if (pendingBatch == null && !(hasPendingEarly && engine.isCancelCommand(phrase, pending: activeDraft))) {
        final reply = assistant.handleCommand(phrase, hasPendingDraft: hasPendingEarly);
        if (reply != null && reply.rewrittenInput != null) {
          phrase = reply.rewrittenInput!;
        } else if (reply != null) {
          activeDraft = null;
          onAssistantReply?.call(reply);
          _speakAsCesar(reply.spokenText);
          return;
        }
      }

      // 1. Questions about the data, with follow-ups ("e ontem?").
      final answer = assistant.handleQuestion(phrase);
      if (answer != null) {
        activeDraft = null;
        onAssistantReply?.call(answer);
        _speakAsCesar(answer.spokenText);
        return;
      }
    }

    // 1. Process Report & Analytical Queries via RAG Engine
    if (assistant == null && ragEngine != null && FinancialReportRagEngine.isReportQuery(phrase)) {
      final reportResult = ragEngine!.generateReport(phrase);
      activeDraft = null;
      onReportGenerated?.call(reportResult);
      _speakAsCesar(reportResult.spokenText);
      return;
    }

    // 2. Check for Debt Repayment ("o João me pagou a dívida dele, porém apenas 70 reais")
    // With no open debt in that name it is ordinary income — it goes on to
    // the normal parse below (same as the chat).
    String? preface;
    if (repository != null) {
      final debtPayment = DebtPaymentParser.parse(phrase);
      final List<FinancialReminder> matches = debtPayment == null ? const [] : repository!.findDebtorsByName(debtPayment.personName);
      if (debtPayment != null && matches.isEmpty) {
        preface = DebtPaymentParser.noOpenDebtNote(debtPayment.personName);
      } else if (debtPayment != null) {
        String responseText;

        if (matches.length > 1) {
          responseText = 'Encontrei mais de uma cobrança pendente no nome de ${debtPayment.personName}. Pode me dizer o valor original da dívida?';
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
        _speakAsCesar(responseText);
        return;
      }
    }

    // 3. Check for Affordability Questions ("posso comprar um notebook de 3000?")
    if (repository != null) {
      final affordability = AffordabilityAnalyzer(repository: repository!).analyze(phrase);
      if (affordability != null) {
        activeDraft = null;
        _speakAsCesar(affordability.spokenText);
        return;
      }
    }

    // 4. Handle common conversational questions directly & empathetically
    if (lower.contains('quem e voce') || lower.contains('quem é você') || lower.contains('quem e vc') || lower.contains('quem é vc')) {
      conversationalResponse = 'Eu sou o César, seu consultor financeiro inteligente no Krezio.ai!';
    } else if (lower.contains('como funciona') || lower.contains('o que voce faz') || lower.contains('o que você faz') || lower.contains('ajuda') || lower.contains('o que posso falar') || lower.contains('como te usar')) {
      conversationalResponse = 'Você pode me falar seus gastos, receitas ou pedir para registrar empréstimos. Por exemplo: "Gastei 50 no almoço no débito", "Recebi 3000 de salário" ou "Emprestei 100 pro João". O que gostaria de fazer?';
    } else if (lower.contains('obrigado') || lower.contains('valeu') || lower.contains('obrigada') || lower.contains('muito obrigado')) {
      conversationalResponse = 'Por nada! Estou sempre por aqui para te ajudar a manter suas finanças organizadas.';
    } else if (lower == 'ola' || lower == 'olá' || lower == 'oi' || lower == 'e ai' || lower == 'e aí') {
      conversationalResponse = 'Olá! Tudo bem? Pode me falar o que deseja lançar ou consultar hoje.';
    }

    if (conversationalResponse != null) {
      activeDraft = null;
      _speakAsCesar(conversationalResponse);
      return;
    }

    // 5. Process financial transaction speech 100% on-device in under 5ms
    FinancialTransactionDraft draft;
    if (repository != null) engine.setCustomCategories(repository!.customCategoryNames);
    final hasPending = activeDraft != null && !activeDraft!.isComplete;
    if (hasPending && engine.isCancelCommand(phrase, pending: activeDraft)) {
      activeDraft = null;
      _speakAsCesar('Tudo bem, descartei esse lançamento. Nada foi registrado.');
      return;
    }

    // Unfinished multi-transaction batch: this phrase answers its question
    // (same rules as the chat), unless it is a brand-new sentence.
    if (pendingBatch != null) {
      final batch = pendingBatch!;
      if (engine.isCancelCommand(phrase, pending: batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first))) {
        pendingBatch = null;
        _speakAsCesar('Tudo bem, descartei esses lançamentos. Nada foi registrado.');
        return;
      }
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (!engine.startsNewTransaction(firstOpen, phrase)) {
        final merged = engine.mergeMultiDrafts(batch, phrase);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          pendingBatch = null;
          _completeBatch(merged);
        } else {
          pendingBatch = merged;
          _speakAsCesar(prompt);
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
          _speakAsCesar('$dropped$prompt');
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

    activeDraft = draft;

    String responseText;
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
      onTransactionCompleted?.call(draft);
      final amountStr = draft.amount != null ? 'de R\$ ${draft.amount!.toStringAsFixed(2).replaceAll('.', ',')}' : '';
      if (draft.billingDay != null && draft.paymentMarginDays != null) {
        responseText = 'Anotado! Boleto de ${draft.description} registrado: cai dia ${draft.billingDay} com vencimento no dia ${draft.dueDay}, margem de ${draft.paymentMarginDays} dias para pagar.';
      } else if (draft.isReminder && draft.reminderType == 'loan_receivable') {
        responseText = 'Combinado! Lembrete de empréstimo registrado $amountStr. Te avisarei na data combinada!';
      } else if (draft.isReminder && draft.reminderType == 'dividend') {
        responseText = 'Excelente! Lembrete de dividendos registrado $amountStr no seu calendário!';
      } else if (draft.intent == 'income') {
        responseText = 'Perfeito! Receita $amountStr registrada com sucesso no seu planejamento!';
      } else {
        responseText = 'Anotado! Despesa $amountStr lançada com sucesso no Krezio.ai!';
      }
      if (!isMerged && draft.assumptionNote != null) responseText += ' ${draft.assumptionNote}';
      activeDraft = null; // Clear draft upon completion
    } else {
      responseText = draft.clarificationPrompt ?? 'Não consegui identificar essa transação. Pode me dizer o valor e onde foi gasto?';
      activeDraft = null; // Clear draft to avoid locking into a broken merge loop
    }

    if (preface != null) responseText = '$preface $responseText';
    if (discardedNotice != null) responseText = '$discardedNotice $responseText';
    _speakAsCesar(responseText);
  }

  /// Hands every item of a complete batch to the chat (which saves each one)
  /// and says how many were recorded.
  void _completeBatch(List<FinancialTransactionDraft> drafts, {String notice = ''}) {
    for (final d in drafts) {
      onTransactionCompleted?.call(d);
    }
    final total = drafts.fold(0.0, (acc, d) => acc + (d.amount ?? 0));
    _speakAsCesar('${notice}Anotado!${drafts.length} lançamentos registrados, somando R\$ ${total.toStringAsFixed(2).replaceAll('.', ',')}.');
  }

  Future<void> _speakAsCesar(String text) async {
    cesarSpeechNotifier.value = text;
    stateNotifier.value = VoiceState.speaking;
    audioLevelNotifier.value = 0.6; // Pulsing during speech

    if (!isSpeakerMutedNotifier.value) {
      await voiceSynthesis.speak(text);
    } else {
      // If speaker is muted, wait briefly and trigger completion
      _speechTimeoutTimer?.cancel();
      _speechTimeoutTimer = Timer(const Duration(seconds: 2), _handleCesarSpeechCompleted);
    }
  }

  void _handleCesarSpeechCompleted() {
    if (_isDisposed) return;
    audioLevelNotifier.value = 0.0;

    if (stateNotifier.value == VoiceState.speaking) {
      if (isHandsFreeNotifier.value && !isMutedNotifier.value) {
        // Wait 300ms for browser audio device context to cleanly switch from playback to record
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!_isDisposed && isHandsFreeNotifier.value && !isMutedNotifier.value) {
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
    _speechTimeoutTimer?.cancel();
    _silenceDebounceTimer?.cancel();
    await stopListening();
    await voiceSynthesis.stop();
    if (!_isDisposed) {
      stateNotifier.value = VoiceState.idle;
      audioLevelNotifier.value = 0.0;
      activeDraft = null;
      pendingBatch = null;
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _speechTimeoutTimer?.cancel();
    _silenceDebounceTimer?.cancel();
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
  }
}
