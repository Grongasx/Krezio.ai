import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/voice/voice_conversation_controller.dart';
import 'package:krezio_ai/ai/voice/voice_synthesis_service.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class MockVoiceSynthesisService extends VoiceSynthesisService {
  MockVoiceSynthesisService() : super.internal();

  String? lastSpokenText;
  int speakCount = 0;
  int stopCount = 0;

  @override
  Future<void> initialize({String language = 'pt-BR'}) async {}

  @override
  Future<void> speak(String text) async {
    lastSpokenText = text;
    speakCount++;
    isSpeakingNotifier.value = true;
    currentSpokenTextNotifier.value = text;
    onStart?.call();
    // Simulate speech completion callback
    Future.microtask(() {
      isSpeakingNotifier.value = false;
      currentSpokenTextNotifier.value = null;
      onCompletion?.call();
    });
  }

  @override
  Future<void> stop() async {
    stopCount++;
    isSpeakingNotifier.value = false;
    currentSpokenTextNotifier.value = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalFinancialNlpEngine engine;
  late MockVoiceSynthesisService mockVoiceSynthesis;
  late VoiceConversationController controller;

  setUpAll(() async {
    final modelFile = File('models/on_device/krezio_nlp_model.json');
    final jsonStr = await modelFile.readAsString();
    engine = LocalFinancialNlpEngine.fromJsonString(jsonStr);
  });

  setUp(() {
    mockVoiceSynthesis = MockVoiceSynthesisService();
    controller = VoiceConversationController(
      engine: engine,
      voiceSynthesisService: mockVoiceSynthesis,
      sttInstance: stt.SpeechToText(),
    );
  });

  tearDown(() {
    controller.dispose();
  });

  group('VoiceConversationController: Máquina de Estados e Loop Conversacional', () {
    test('Estado inicial é idle e mãos-livres ativo por padrão', () {
      expect(controller.stateNotifier.value, VoiceState.idle);
      expect(controller.isHandsFreeNotifier.value, true);
      expect(controller.isMutedNotifier.value, false);
      expect(controller.isSpeakerMutedNotifier.value, false);
    });

    test('Alternância de Mute, Speaker e Mãos Livres', () {
      controller.toggleMute();
      expect(controller.isMutedNotifier.value, true);

      controller.toggleMute();
      expect(controller.isMutedNotifier.value, false);

      controller.toggleSpeaker();
      expect(controller.isSpeakerMutedNotifier.value, true);

      controller.toggleHandsFree();
      expect(controller.isHandsFreeNotifier.value, false);
    });

    test('Fala do César atualiza estado e notifica texto falado', () async {
      await controller.startConversation(speakGreeting: true);
      expect(controller.stateNotifier.value, VoiceState.speaking);
      expect(mockVoiceSynthesis.lastSpokenText, contains('Olá! Sou o César.'));
      expect(controller.cesarSpeechNotifier.value, contains('César'));
    });

    test('Processamento on-device de fala de despesa completa', () async {
      FinancialTransactionDraft? capturedDraft;
      controller.onTransactionCompleted = (draft) {
        capturedDraft = draft;
      };

      // Simula o transcript concluído
      controller.userTranscriptNotifier.value = 'gastei 50 no mercado no debito';
      // Injeta diretamente no fluxo
      final draft = engine.parse('gastei 50 no mercado no debito');
      controller.onTransactionCompleted?.call(draft);

      expect(draft.isComplete, true);
      expect(draft.amount, 50.0);
      expect(draft.category, 'supermarket');
      expect(draft.paymentMethod, 'debit_card');
      expect(capturedDraft, isNotNull);
      expect(capturedDraft?.amount, 50.0);
    });

    test('Processamento de empréstimo e retorno conversacional', () {
      final draft = engine.parse('emprestei dinheiro pro joao quando o salario dele cair');
      expect(draft.isComplete, false);
      expect(draft.isReminder, true);
      expect(draft.personName, 'Joao');
      expect(draft.missingSlots.contains('amount'), true);

      // Segundo turno na conversa
      final merged = engine.mergeDrafts(draft, '150');
      expect(merged.isComplete, true);
      expect(merged.amount, 150.0);
      expect(merged.personName, 'Joao');
    });

    test('VAD adaptativo: frases completas encerram rápido e frases incompletas aguardam mais', () {
      final goodbyeWait = controller.computeSilenceDebounce('tchau César');
      final completeWait = controller.computeSilenceDebounce('gastei 50 no mercado no pix');
      final incompleteWait = controller.computeSilenceDebounce('gastei 50 no mercado');
      final midPrepositionWait = controller.computeSilenceDebounce('gastei 50 no');

      expect(goodbyeWait.inMilliseconds, lessThanOrEqualTo(900));
      expect(completeWait.inMilliseconds, lessThanOrEqualTo(1100));
      expect(incompleteWait.inMilliseconds, greaterThanOrEqualTo(1600));
      expect(midPrepositionWait.inMilliseconds, greaterThanOrEqualTo(1800));
    });

    test('Fluxo multi-turno com dicas de slot pendente e quick-reply no César Live', () async {
      FinancialTransactionDraft? completed;
      final spokenUserPhrases = <String>[];
      controller.onUserSpoken = spokenUserPhrases.add;
      controller.onTransactionCompleted = (d) => completed = d;

      await controller.submitQuickPhrase('gastei 80 no mercado');
      expect(controller.activeDraft, isNotNull);
      expect(controller.activeDraft!.isComplete, isFalse);
      expect(controller.pendingSlotHintNotifier.value, contains('Forma de pagamento'));
      expect(controller.quickRepliesNotifier.value, contains('No Pix'));

      await controller.submitQuickPhrase('No Pix');
      expect(completed, isNotNull);
      expect(completed!.isComplete, isTrue);
      expect(completed!.amount, 80.0);
      expect(completed!.paymentMethod, 'pix');
      expect(controller.pendingSlotHintNotifier.value, isNull);
      expect(spokenUserPhrases, ['gastei 80 no mercado', 'No Pix']);
      expect(controller.conversationHistoryNotifier.value.length, greaterThanOrEqualTo(4));
    });

    test('Criação e aporte em metas financeiras por voz no César Live', () async {
      final repo = FinancialRepository();
      final liveWithRepo = VoiceConversationController(
        engine: engine,
        repository: repo,
        voiceSynthesisService: mockVoiceSynthesis,
        sttInstance: stt.SpeechToText(),
      );
      addTearDown(liveWithRepo.dispose);

      await liveWithRepo.submitQuickPhrase('quero juntar 5000 para viagem');
      expect(repo.goals.any((g) => g.title.toLowerCase().contains('viagem')), isTrue);
      expect(liveWithRepo.cesarSpeechNotifier.value, contains('Meta criada!'));

      await liveWithRepo.submitQuickPhrase('guardei 500 na meta da viagem');
      final updatedGoal = repo.goals.firstWhere((g) => g.title.toLowerCase().contains('viagem'));
      expect(updatedGoal.savedAmount, 500.0);
      expect(liveWithRepo.cesarSpeechNotifier.value, contains('10%'));
    });
  });

  group('VoiceSynthesisService: Calibração Acústica e Normalização Fonética', () {
    late VoiceSynthesisService service;

    setUp(() {
      service = VoiceSynthesisService.internal();
    });

    test('Parâmetros do Modelo Neural ONNX do César', () {
      expect(service.modelName, 'pt_BR-faber-medium.onnx');
      expect(service.architecture, 'Piper VITS (ONNX)');
      expect(service.sampleRate, 22050);
      expect(service.speechRate, 1.0);
      expect(service.volume, 1.0);
    });


    test('Normalização de moeda para fala humana agradável', () {
      expect(
        service.preprocessTextForSpeech(r'Anotado! Despesa de R$ 150,00 lançada com sucesso!'),
        'Anotado! Despesa de 150 reais lançada com sucesso!',
      );
      expect(
        service.preprocessTextForSpeech(r'Café de R$ 8,50 registrado.'),
        'Café de 8 reais e 50 centavos registrado.',
      );
      expect(
        service.preprocessTextForSpeech(r'Receita de R$ 1,00 recebida.'),
        'Receita de 1 real recebida.',
      );
      // Regression: thousands-separated amounts used to leave a mangled remainder,
      // e.g. "R$ 1.948,40" -> "1 real e 94 centavos8,40" (the lone-digit regex only
      // consumed the "1" before the thousands dot).
      expect(
        service.preprocessTextForSpeech(r'Você gastou um total de R$ 1.948,40 este mês.'),
        'Você gastou um total de 1948 reais e 40 centavos este mês.',
      );
      expect(
        service.preprocessTextForSpeech(r'Saldo de R$ 10.000 disponível.'),
        'Saldo de 10000 reais disponível.',
      );
    });


    test('Normalização de porcentagem e pronúncia Krezio.ai', () {
      expect(
        service.preprocessTextForSpeech('Você já economizou 15% no Krezio.ai este mês.'),
        'Você já economizou 15 por cento no Krézio ai este mês.',
      );
    });
  });
}

