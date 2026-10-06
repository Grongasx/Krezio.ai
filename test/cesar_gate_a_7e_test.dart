// Corretor, Portão do lote A, etapa 7e (PLANO_CESAR.md) — critério B do
// usuário: rede de confirmação por certeza + fechar os caminhos de gravação
// que não passavam pelo EntrySafetyGate.
//
// A regra: todo lançamento sai pelo EntrySafetyGate, que lê a CERTEZA de
// TODOS os turnos que formaram o rascunho (EntryCertainty):
// - certeza ALTA (fato contado: verbo de dinheiro no passado/hábito, quem
//   pagou quem, item + valor sem verbo) → grava;
// - certeza BAIXA → mostra o lançamento montado e pergunta "Registro assim?
//   (sim/não)": "sim" grava, "não" descarta, o resto segue o PendingReplyCheck;
// - irrealidade explícita (não-evento, intenção, obrigação, pergunta
//   avaliativa) → não grava e responde como simulação/comentário.
// Achados: docs/qa/findings-aceite-lote-a-r3.md (ACC-C-*) e
// docs/qa/findings-caos-lote-a-r3.md (CHAOS-C-*). Cada grupo tem a frase do
// achado, frases NOVAS e controles; e há um grupo de ≥ 60 lançamentos claros
// inéditos para medir a taxa de "Registro assim?" (meta ≤ 5%).
//
// Caminhos de gravação/edição × gate (o que este arquivo cobre):
// 1. frase única (`parse`) → gate (intent, direção, números, data, certeza);
// 2. resposta a rascunho (`mergeDrafts`) → gate com TODOS os turnos;
// 3. lote (`parseMulti`/`mergeMultiDrafts`) → números da frase inteira + certeza;
// 4. empréstimo (`isReminder` loan_receivable) → intent + data (CHAOS-C-007);
// 5. correção livre / "o que mudar?" (`CesarAssistant`) → não-evento não edita (CHAOS-C-004);
// 6. "na verdade/na real o X foi N" (`ReferenceEditParser`) → X tem de existir (CHAOS-C-005/006);
// 7. edição/exclusão por nome não presente no título → confirma mostrando o item (decisão ii).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/entry_certainty.dart';
import 'package:krezio_ai/ai/entry_safety_gate.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Uma resposta do chat simulado.
class Reply {
  final String route;
  final String text;
  const Reply(this.route, this.text);
  bool get asksConfirm => text.contains('Registro assim?');
  @override
  String toString() => '[$route] $text';
}

/// O `_sendMessage` do chat (chat_screen.dart), na ordem atual: cancelar →
/// lote pendente (cancelar, "e se…", resposta) → comandos do assistente →
/// dívida → "posso comprar" → perguntas → lote (também com rascunho pendente
/// e frase nova) → resposta ao rascunho ou frase nova.
class Chat {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  List<FinancialTransactionDraft>? batch;
  final log = <Reply>[];

  Chat(this.engine, this.repo) : assistant = CesarAssistant(repository: repo, engine: engine);

  bool get draftPending => active != null && !active!.isComplete;

  Reply send(String input) {
    final r = _send(input.trim());
    final notice = assistant.takeNotice();
    final out = notice == null ? r : Reply(r.route, '$notice\n\n${r.text}');
    log.add(out);
    return out;
  }

  Reply _send(String input) {
    var text = input;
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();
    if (draftPending && engine.isCancelCommand(text, pending: active)) {
      active = null;
      return const Reply('cancel_pending', 'Tudo bem, descartei esse lançamento. Nada foi registrado.');
    }
    if (batch != null) {
      final b = batch!;
      final firstOpen = b.firstWhere((d) => !d.isComplete, orElse: () => b.first);
      if (engine.isCancelCommand(text, pending: firstOpen)) {
        batch = null;
        return const Reply('cancel_pending', 'Tudo bem, descartei esses lançamentos.');
      }
      final whatIf = assistant.hypothesisReply(text);
      if (whatIf != null) return Reply(whatIf.route, whatIf.text);
      if (!engine.startsNewTransaction(firstOpen, text)) {
        final merged = engine.mergeMultiDrafts(b, text);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          batch = null;
          return _saveBatch(merged);
        }
        batch = merged;
        return Reply('ask_multi', prompt);
      }
      batch = null;
    }
    final cmd = assistant.handleCommand(text, hasPendingDraft: draftPending);
    if (cmd != null && cmd.rewrittenInput != null) {
      text = cmd.rewrittenInput!;
    } else if (cmd != null) {
      return Reply(cmd.route, cmd.text);
    }
    String? preface;
    final debt = DebtPaymentParser.parse(text);
    if (debt != null) {
      final matches = repo.findDebtorsByName(debt.personName);
      if (matches.isEmpty) {
        preface = DebtPaymentParser.noOpenDebtNote(debt.personName);
      } else {
        return Reply('debt', debt.personName);
      }
    }
    final afford = AffordabilityAnalyzer(repository: repo).analyze(text);
    if (afford != null) return Reply('afford', afford.formattedText);
    final answer = assistant.handleQuestion(text);
    if (answer != null) return Reply(answer.route, answer.text);

    final pendingNow = draftPending;
    if (!pendingNow || engine.startsNewTransaction(active!, text)) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        final dropped = pendingNow ? LocalFinancialNlpEngine.discardedDraftNotice(active!) : null;
        active = null;
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) return _saveBatch(multi);
        batch = multi;
        return Reply('ask_multi', dropped == null ? prompt : '$dropped\n\n$prompt');
      }
    }
    FinancialTransactionDraft draft;
    var merged = false;
    String? discarded;
    if (pendingNow && !engine.startsNewTransaction(active!, text)) {
      draft = engine.mergeDrafts(active!, text);
      merged = true;
    } else {
      if (pendingNow) discarded = LocalFinancialNlpEngine.discardedDraftNotice(active!);
      draft = engine.parse(text);
    }
    if (draft.isComplete) draft = repo.applyCategoryMemory(draft);
    var route = 'ask';
    var reply = draft.clarificationPrompt ?? '';
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      assistant.recordCreated(repo.addTransactionFromDraft(draft).map((t) => t.id).toList());
      if (draft.isReminder) {
        repo.addReminder(FinancialReminder(
          id: 'rem-${repo.reminders.length + 1}',
          title: draft.description,
          personName: draft.personName,
          amount: draft.amount,
          targetDate: draft.targetDate ?? DateTime.now().add(const Duration(days: 30)),
          type: draft.reminderType == 'loan_receivable' ? ReminderType.loanReceivable : ReminderType.general,
        ));
      }
      route = 'saved';
      reply = 'Registrado: ${draft.intent} ${draft.amount} ${draft.description}';
      active = null;
    } else if (!draft.isComplete) {
      active = draft;
    }
    if (draft.intent == 'query') {
      route = 'query';
      reply = engine.replyForQuestion(draft);
      active = null;
    } else if (draft.intent == 'unknown' && !merged) {
      route = 'unknown';
      active = null;
    }
    if (preface != null) reply = '$preface\n\n$reply';
    if (discarded != null) reply = '$discarded\n\n$reply';
    return Reply(route, reply);
  }

  Reply _saveBatch(List<FinancialTransactionDraft> drafts) {
    for (final d in drafts) {
      assistant.recordCreated(repo.addTransactionFromDraft(d).map((t) => t.id).toList());
    }
    return Reply('multi', drafts.map((d) => '${d.amount} ${d.description}').join('; '));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime back(int days) {
    final t = today();
    return DateTime(t.year, t.month, t.day - days, 12);
  }

  const weekdayNames = ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
  String wd(int days) => weekdayNames[back(days).weekday - 1];

  FinancialTransaction tx(String id, String title, double amount, int daysBack, String cat, {TransactionType type = TransactionType.expense}) =>
      FinancialTransaction(id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: 'pix', date: back(daysBack));

  // Registros antigos (fora da conversa) para edição/exclusão.
  List<FinancialTransaction> seeds() => [
        tx('belo', '7 Belo', 12, 2, 'supermarket'),
        tx('milhas', '123 Milhas', 640, 3, 'transport'),
        tx('pizzaria', 'Pizzaria Sábado à Noite', 26, 1, 'leisure'),
        tx('posto', 'Posto Shell', 150, 4, 'transport'),
        tx('hamb', 'Hamburgueria', 62, 4, 'leisure'),
        tx('pet', 'Pet Shop', 120, 5, 'expense_other'),
        tx('acougue', 'Açougue', 95, 6, 'supermarket'),
        tx('sapataria', 'Sapataria', 70, 3, 'expense_other'),
        tx('flor', 'Floricultura', 85, 2, 'expense_other'),
        tx('vet', 'Clínica Veterinária', 210, 5, 'health'),
      ];

  Future<Chat> chat({bool seeded = true}) async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    if (seeded) {
      for (final t in seeds()) {
        repo.addTransaction(t);
      }
    }
    return Chat(engine, repo);
  }

  String seedState(Chat c) => (c.repo.transactions
          .where((t) => seeds().any((s) => s.id == t.id))
          .map((t) => '${t.id}:${t.amount}:${t.title}:${t.type.name}:${t.category}:${t.date.day}')
          .toList()
        ..sort())
      .join(',');

  List<FinancialTransaction> created(Chat c) => c.repo.transactions.where((t) => !seeds().any((s) => s.id == t.id)).toList();
  FinancialTransaction rec(Chat c, String id) => c.repo.transactions.firstWhere((t) => t.id == id);

  /// Respostas automáticas a perguntas de produto (como as baterias do QA):
  /// forma de pagamento, parcelas, categoria/lugar, prazo, dia de vencimento.
  String? autoAnswer(Reply r) {
    final t = r.text.toLowerCase();
    if (r.asksConfirm) return null;
    if (t.contains('parcelad') || t.contains('à vista')) return 'à vista';
    if (t.contains('forma de pagamento') || t.contains('qual foi o meio') || t.contains('como você pagou') || t.contains('como esse valor')) {
      return 'pix';
    }
    if (t.contains('onde foi') || t.contains('categoria') || t.contains('com o que foi')) return 'outros';
    if (t.contains('prazo')) return 'sem prazo';
    if (t.contains('que dia') && t.contains('vence')) return 'dia 10';
    return null;
  }

  /// Diz [turns] e responde as perguntas de produto até no máximo 4 vezes.
  Future<(Chat, List<Reply>)> converse(List<String> turns, {bool seeded = false, Chat? on}) async {
    final c = on ?? await chat(seeded: seeded);
    final out = <Reply>[];
    for (final t in turns) {
      var r = c.send(t);
      out.add(r);
      for (var i = 0; i < 4; i++) {
        final a = autoAnswer(r);
        if (a == null || !(c.draftPending || c.batch != null)) break;
        r = c.send(a);
        out.add(r);
      }
    }
    return (c, out);
  }

  // ───────────────────────── a certeza ─────────────────────────

  group('EntryCertainty: como a certeza é lida (todos os turnos)', () {
    for (final t in [
      ['paguei 47 na farmácia no débito'],
      ['almoço 32 no pix'],
      ['180 do encanador no pix'],
      ['o mecânico me cobrou 350 no pix'],
      ['pago 85 de academia todo mês'],
      ['levei o cachorro no veterinário, 120 no pix'],
      ['a escola recebeu de mim 600 da matrícula'],
      ['paguei o seguro', 'deu 230'],
    ]) {
      test('alta: ${t.join(' ⏎ ')}', () => expect(EntryCertainty.read(t).high, isTrue, reason: '${EntryCertainty.read(t)}'));
    }
    for (final t in [
      ['gastei 50 no mercado?'],
      ['comprar um tênis de 300 no pix'],
      ['compro um fone de 90 no pix'],
      ['pagarei 120 de luz no boleto'],
      ['não sei se paguei os 80 da luz'],
      ['a compra de 640 foi recusada no cartão'],
      ['o mercado tá caro, 300 no pix'],
      ['tenho a conta de luz', 'no pix, 140'],
    ]) {
      test('baixa: ${t.join(' ⏎ ')}', () => expect(EntryCertainty.read(t).high, isFalse, reason: '${EntryCertainty.read(t)}'));
    }
  });

  group('Rede de confirmação: baixa certeza mostra o lançamento e pergunta "Registro assim?"', () {
    const unsure = [
      'o mercado tá caro, 300 no pix',
      'compro um fone de 90 no pix',
      'minha internet anda lenta, 99 no boleto',
    ];
    for (final p in unsure) {
      test('"$p" → mostra e pergunta, nada gravado', () async {
        final c = await chat(seeded: false);
        final r = c.send(p);
        expect(r.asksConfirm, isTrue, reason: '$r');
        expect(r.text, contains('R\$'), reason: 'mostra o lançamento montado');
        expect(c.repo.transactions, isEmpty);
      });
      test('"$p" ⏎ "sim" grava', () async {
        final c = await chat(seeded: false);
        c.send(p);
        final r = c.send('sim');
        expect(c.repo.transactions, hasLength(1), reason: '$r');
      });
      test('"$p" ⏎ "não" descarta', () async {
        final c = await chat(seeded: false);
        c.send(p);
        c.send('não');
        expect(c.repo.transactions, isEmpty);
        expect(c.draftPending, isFalse);
        c.send('sim');
        expect(c.repo.transactions, isEmpty, reason: '"sim" depois do "não" não ressuscita o lançamento');
      });
    }
    for (final p in [
      'sei lá se valeu a pena, mas paguei 75 na aula de dança no pix',
      'não sei se isso entra, mas gastei 9 de água no dinheiro',
      'nem sei se fiz bem mas comprei uma mochila de 140 no débito',
    ]) {
      test('controle: dúvida sobre outra coisa não derruba o fato — "$p" grava', () async {
        final (c, out) = await converse([p]);
        expect(c.repo.transactions, hasLength(1), reason: out.join('\n'));
      });
    }
    for (final p in [
      // fato passado contado de qualquer sujeito
      'entrou 300 da cliente da marmita no pix',
      'rolou um açaí de 22 no pix',
      'a criança precisou de vacina, 160 na clínica no débito',
      'o condomínio de 540 já foi pago no boleto',
      'à tarde já tinha gastado 18 no lanche no pix',
      // a falha vem antes e o fato fecha a frase
      'o app deu erro, então paguei 60 no balcão no pix',
      'não era pra eu gastar, mas gastei 31 de pizza no pix',
    ]) {
      test('controle: "$p" grava sem "Registro assim?"', () async {
        final (c, out) = await converse([p]);
        expect(out.any((r) => r.asksConfirm), isFalse, reason: out.join('\n'));
        expect(c.repo.transactions, hasLength(1), reason: out.join('\n'));
      });
    }
    for (final p in ['paguei 50 no mercado mas deu erro', 'transferi 80 pro joão e voltou, não compensou']) {
      test('a falha fecha a frase: "$p" não grava calado', () async {
        final (c, out) = await converse([p]);
        expect(c.repo.transactions, isEmpty, reason: out.join('\n'));
      });
    }
    test('frase nova completa no lugar do "sim" é assunto novo (PendingReplyCheck)', () async {
      final c = await chat(seeded: false);
      c.send('o mercado tá caro, 300 no pix');
      final r = c.send('gastei 42 na padaria no débito');
      expect(created(c).map((t) => t.amount), [42.0], reason: '$r');
      expect(c.draftPending, isFalse);
    });
    test('"no débito" no lugar do "sim" corrige o campo e pergunta de novo', () async {
      final c = await chat(seeded: false);
      c.send('compro um fone de 90 no pix');
      final r = c.send('no débito');
      expect(c.repo.transactions, isEmpty, reason: '$r');
      expect(r.asksConfirm, isTrue, reason: '$r');
      c.send('sim');
      expect(c.repo.transactions.single.paymentMethod, 'debit_card');
    });
  });

  // ───────────────────────── irrealidade (P0) ─────────────────────────

  /// Nada gravado depois de [turns] (respondendo as perguntas de produto
  /// automaticamente e, se perguntar "Registro assim?", sem confirmar).
  Future<void> expectNothingSaved(List<String> turns) async {
    final (c, out) = await converse(turns);
    expect(c.repo.transactions, isEmpty, reason: out.join('\n'));
  }

  group('ACC-C-001: pergunta avaliativa / dúvida não grava (responde como simulação)', () {
    for (final t in [
      ['pensando aqui: um notebook de 4500 em 10x pesa quanto por mes?'], // do achado
      ['seria loucura gastar 500 num show?', 'pix'], // do achado
      ['to na duvida se compro a air fryer de 380 ou nao', 'pix'], // do achado
      ['compensa pagar 1200 num celular novo?', 'pix'],
      ['vale a pena torrar 300 num tênis de corrida?'],
      ['seria muito gastar 250 no aniversário do meu pai?'],
      ['tô pensando se pego aquele curso de 600', 'no pix'],
      ['será que rola um rodízio de 120 hoje?', 'débito'],
    ]) {
      test(t.join(' ⏎ '), () => expectNothingSaved(t));
    }
    test('a resposta fala em simulação/plano', () async {
      final c = await chat(seeded: false);
      final r = c.send('seria loucura gastar 500 num show?');
      expect(r.text.toLowerCase(), anyOf(contains('simula'), contains('plano'), contains('não registrei'), contains('posso')), reason: '$r');
    });
  });

  group('ACC-C-002 / CHAOS-C-003: não-evento não grava, nem completado pelo 2º turno', () {
    for (final t in [
      ['ia gastar 90 no barzinho mas fiquei em casa', 'pix'], // ACC-C-002
      ['era pra eu receber 300 hoje mas o cliente furou', 'pix'],
      ['nem cheguei a pagar os 45 do estacionamento, o cara liberou', 'saiu'],
      ['o pix de 95 não foi, deu erro', 'no mercado'], // CHAOS-C-003
      ['era pra eu pagar 140 hoje mas esqueci', 'luz no pix'],
      ['ia pagar 77 hoje mas desisti', 'no mercado no pix'],
      ['a compra de 640 foi recusada no cartão', 'no mercado no pix'],
      ['não cheguei a gastar os 215', 'saiu'],
      // novas
      ['ia comprar um tênis de 280 mas acabou o estoque', 'pix'],
      ['era pra ter caído 500 do freela hoje mas não caiu', 'pix'],
      ['o boleto de 320 voltou, não compensou', 'no boleto'],
      ['tentei pagar 60 no ifood mas o cartão foi negado', 'crédito'],
    ]) {
      test(t.join(' ⏎ '), () => expectNothingSaved(t));
    }
    test('controle: "paguei 45 do estacionamento no pix" grava', () async {
      final (c, out) = await converse(['paguei 45 do estacionamento no pix']);
      expect(created(c).map((t) => t.amount), [45.0], reason: out.join('\n'));
    });
  });

  group('CHAOS-C-001 / CHAOS-C-002: intenção/obrigação não grava, mesmo completada no 2º turno', () {
    for (final t in [
      ['talvez eu gaste 215 no mercado no pix'], // do achado
      ['talvez eu pague 80 de luz no pix'],
      ['minha ideia é gastar 140 no presente no pix'],
      ['a ideia é gastar 140 no presente no pix'],
      ['vou ter que gastar 600 no conserto do carro', 'no pix'],
      ['preciso pagar 140 de luz até sexta', 'no pix'],
      ['devo gastar uns 250 na festa no pix', 'no buffet'],
      ['pode ser que eu pague 380 no conserto', 'na oficina no pix'],
      ['tenho que pagar 380 de iptu semana que vem', 'no boleto'],
      ['falta pagar 640 do cartão', 'pix'], // CHAOS-C-002
      // novas
      ['tô precisando pagar 90 do gás', 'dinheiro'],
      ['ainda falta quitar 300 do empréstimo', 'pix'],
      ['semana que vem tenho que depositar 200 pro meu irmão', 'pix'],
      ['quem sabe eu compre uma cadeira de 450 no pix'],
      ['minha meta é gastar no máximo 800 no mercado'],
    ]) {
      test(t.join(' ⏎ '), () => expectNothingSaved(t));
    }
    test('"falta pagar 640 do cartão" nunca vira receita', () async {
      final (c, out) = await converse(['falta pagar 640 do cartão', 'pix', 'sim']);
      expect(c.repo.transactions.where((t) => t.type == TransactionType.income), isEmpty, reason: out.join('\n'));
    });
    for (final p in ['tive que pagar 380 de iptu no boleto', 'precisei gastar 600 no conserto do carro no pix', 'paguei 140 de luz no pix']) {
      test('controle (fato): "$p" grava', () async {
        final (c, out) = await converse([p]);
        expect(c.repo.transactions, hasLength(1), reason: out.join('\n'));
      });
    }
  });

  group('CHAOS-C-004: não-evento não edita o último nem em "o que mudar?"', () {
    for (final t in [
      ['paguei 52 no guincho no débito', 'era pra eu pagar 77 hoje mas esqueci'], // do achado
      ['paguei 52 no guincho no débito', 'muda', 'falta pagar 26 do cartão'],
      ['paguei 52 no guincho no débito', 'muda', 'minha ideia é gastar 52 no presente no pix'],
      ['paguei 52 no guincho no débito', 'devo gastar uns 13 na festa no pix'],
      ['paguei 52 no guincho no débito', 'tenho que pagar 7 de iptu semana que vem'],
      // novas
      ['paguei 52 no guincho no débito', 'ia pagar 30 hoje mas desisti'],
      ['paguei 52 no guincho no débito', 'corrige', 'o pix de 40 deu erro'],
    ]) {
      test(t.join(' ⏎ '), () async {
        final (c, out) = await converse(t);
        final txs = c.repo.transactions;
        expect(txs.map((x) => x.amount), [52.0], reason: out.join('\n'));
        expect(txs.single.date.day, today().day);
      });
    }
    test('controle: "paguei 52 no guincho no débito" ⏎ "na verdade foi 57" corrige', () async {
      final (c, out) = await converse(['paguei 52 no guincho no débito', 'na verdade foi 57']);
      expect(c.repo.transactions.single.amount, 57.0, reason: out.join('\n'));
    });
  });

  // ───────────────────────── caminhos fora do gate ─────────────────────────

  group('CHAOS-C-007: empréstimo (isReminder) passa pelo gate de data', () {
    String ddmm(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    test('data futura dd/mm pergunta (do achado)', () async {
      final f = today().add(const Duration(days: 14));
      final c = await chat(seeded: false);
      final r = c.send('emprestei 64 no dia ${ddmm(f)} pro meu primo no pix');
      expect(c.repo.transactions, isEmpty, reason: '$r');
    });
    test('"mês que vem emprestei 7…" pergunta (do achado)', () async {
      final c = await chat(seeded: false);
      final r = c.send('mês que vem emprestei 7 pro meu primo no dinheiro');
      expect(c.repo.transactions, isEmpty, reason: '$r');
    });
    test('"mês passado no dia 16 emprestei 52…" grava no dia 16 do mês passado ou pergunta (do achado)', () async {
      final c = await chat(seeded: false);
      final r = c.send('mês passado no dia 16 emprestei 52 pro meu primo no dinheiro');
      final t = today();
      for (final x in c.repo.transactions) {
        expect(DateTime(x.date.year, x.date.month, x.date.day), DateTime(t.year, t.month - 1, 16), reason: '$r');
      }
    });
    test('nova: "semana que vem empresto 100 pra minha tia" não grava hoje', () async {
      final c = await chat(seeded: false);
      final r = c.send('semana que vem vou emprestar 100 pra minha tia no pix');
      expect(c.repo.transactions.where((x) => x.date.day == today().day), isEmpty, reason: '$r');
    });
    test('controle: "emprestei 50 pro meu primo anteontem no pix" grava anteontem', () async {
      final c = await chat(seeded: false);
      final r = c.send('emprestei 50 pro meu primo anteontem no pix');
      expect(c.repo.transactions.map((x) => x.date.day), [back(2).day], reason: '$r');
    });
  });

  group('CHAOS-C-008 / ACC-C-003: "deu N o X e M o Y", contagens e "ambos" não perdem um item', () {
    for (final t in [
      ['deu 52 o almoço e 39 a sobremesa no pix', 91.0], // CHAOS-C-008
      ['foi 52 o almoço e 39 a sobremesa no pix', 91.0],
      ['anteontem na hora do almoço: deu 64 o almoço e 26 a sobremesa no débito', 90.0],
      ['dois cafés 9 e um pão de queijo 6 no débito', 15.0], // ACC-C-003
      ['dentista 200 e remedio 37 ambos no debito', 237.0],
      // novas
      ['saiu 30 o uber e 18 o lanche no débito', 48.0],
      ['três pastéis 21 e um caldo de cana 8 no dinheiro', 29.0],
      ['academia 110 e nutricionista 250 os dois no pix', 360.0],
      ['custou 45 a camisa e 80 a calça no débito', 125.0],
    ]) {
      test('${t[0]} → nunca um só valor gravado calado', () async {
        final (c, out) = await converse([t[0] as String]);
        final saved = c.repo.transactions;
        if (saved.isNotEmpty) {
          expect(saved.fold<double>(0, (a, x) => a + x.amount), t[1], reason: out.join('\n'));
        } else {
          expect(out.last.route, isNot('saved'), reason: out.join('\n'));
        }
      });
    }
    test('"deu 52 o almoço e 39 a sobremesa no pix" vira 2 lançamentos', () async {
      final (c, out) = await converse(['deu 52 o almoço e 39 a sobremesa no pix']);
      expect(c.repo.transactions.map((t) => t.amount).toList()..sort(), [39.0, 52.0], reason: out.join('\n'));
    });
    test('"dentista 200 e remedio 37 ambos no debito" vira 2 lançamentos no débito', () async {
      final (c, out) = await converse(['dentista 200 e remedio 37 ambos no debito']);
      expect(c.repo.transactions.map((t) => t.amount).toList()..sort(), [37.0, 200.0], reason: out.join('\n'));
      expect(c.repo.transactions.every((t) => t.paymentMethod == 'debit_card'), isTrue);
    });
    test('anteontem: os 2 itens na data dita', () async {
      final (c, out) = await converse(['anteontem na hora do almoço: deu 64 o almoço e 26 a sobremesa no débito']);
      expect(c.repo.transactions.every((t) => t.date.day == back(2).day), isTrue, reason: out.join('\n'));
    });
    test('controle: "o almoço deu 52 e a sobremesa 39 no pix" (já funcionava)', () async {
      final (c, out) = await converse(['o almoço deu 52 e a sobremesa 39 no pix']);
      expect(c.repo.transactions.fold<double>(0, (a, x) => a + x.amount), 91.0, reason: out.join('\n'));
    });
  });

  group('ACC-C-006: idades / 2 números na resposta não viram o valor', () {
    for (final t in [
      ['comprei bala pros meninos', 'eles tem 5 e 8 anos'], // do achado
      ['paguei a festa da minha filha', 'ela fez 7 anos'],
      ['comprei um presente pro meu sobrinho', 'ele tem 12 anos'],
      ['paguei a escolinha dos gêmeos', 'eles têm 4 anos'],
      ['comprei os uniformes', 'um de 6 e outro de 9 anos'],
    ]) {
      test(t.join(' ⏎ '), () async {
        final (c, out) = await converse(t);
        expect(c.repo.transactions, isEmpty, reason: out.join('\n'));
      });
    }
    test('dois valores na resposta perguntam qual', () async {
      final (c, out) = await converse(['comprei bala pros meninos', '5 e 8']);
      expect(c.repo.transactions, isEmpty, reason: out.join('\n'));
    });
    test('controle: "comprei bala pros meninos" ⏎ "deu 12" grava 12', () async {
      final (c, out) = await converse(['comprei bala pros meninos', 'deu 12']);
      expect(c.repo.transactions.map((t) => t.amount), [12.0], reason: out.join('\n'));
    });
  });

  group('CHAOS-C-005: "na verdade/na real o X foi N" com título numérico edita o X', () {
    for (final t in [
      ['na verdade o 7 belo foi 15', 'belo', 15.0], // do achado
      ['na real o 7 belo deu 15', 'belo', 15.0],
      ['na verdade o 123 milhas foi 700', 'milhas', 700.0],
      // novas
      ['na vdd o 7 belo foi 16', 'belo', 16.0],
      ['pensando bem o 123 milhas foi 690', 'milhas', 690.0],
    ]) {
      test('gastei 64 no açaí no pix ⏎ ${t[0]}', () async {
        final c = await chat();
        c.send('gastei 64 no açaí no pix');
        var r = c.send(t[0] as String);
        if (r.route == 'not_found' || r.route == 'confirm' || r.route == 'ask_correction_or_new') r = c.send('sim');
        expect(created(c).map((x) => x.amount), [64.0], reason: 'o açaí não muda — ${c.log.join('\n')}');
        expect(rec(c, t[1] as String).amount, t[2], reason: c.log.join('\n'));
      });
    }
    test('na verdade a pizzaria foi 26 ⏎ na verdade o 7 belo foi 15 (a pizzaria fica)', () async {
      final c = await chat();
      c.send('na verdade a pizzaria foi 26');
      c.send('na verdade o 7 belo foi 15');
      expect(rec(c, 'pizzaria').amount, 26.0, reason: c.log.join('\n'));
      expect(rec(c, 'belo').amount, 15.0, reason: c.log.join('\n'));
    });
  });

  group('CHAOS-C-006: "na verdade o X foi N" com X inexistente → "não achei"', () {
    for (final t in [
      ['recebi 300 do freela no pix', 'na verdade o açougue de hoje foi 23'],
      ['recebi 300 do freela no pix', 'na verdade o cinema foi 23'], // do achado (X inexistente, foco = receita)
      ['recebi 300 do freela no pix', 'na real a lavanderia deu 40'],
    ]) {
      test(t.join(' ⏎ '), () async {
        final c = await chat();
        final before = seedState(c);
        c.send(t[0]);
        final r = c.send(t[1]);
        expect(seedState(c), before, reason: '$r');
        final made = created(c);
        expect(made.single.amount, 300.0, reason: '$r');
        expect(made.single.type, TransactionType.income, reason: '$r');
        expect(r.text.toLowerCase(), contains('não achei'), reason: '$r');
      });
    }
    test('na verdade a pizzaria foi 26 ⏎ na verdade o cinema foi 77 (registro antigo só editado não é reescrito)', () async {
      final c = await chat();
      c.send('na verdade a pizzaria foi 26');
      final r = c.send('na verdade o cinema foi 77');
      expect(rec(c, 'pizzaria').title, 'Pizzaria Sábado à Noite', reason: '$r');
      expect(rec(c, 'pizzaria').amount, 26.0, reason: '$r');
    });
    test('passa o 7 belo pra 14 ⏎ na verdade o cinema foi 30 (o 7 Belo fica)', () async {
      final c = await chat();
      c.send('passa o 7 belo pra 14');
      final r = c.send('na verdade o cinema foi 30');
      expect(rec(c, 'belo').title, '7 Belo', reason: '$r');
      expect(rec(c, 'belo').amount, 14.0, reason: c.log.join('\n'));
    });
  });

  // ───────────────────────── direção e data ─────────────────────────

  group('ACC-C-004 / ACC-C-007 / CHAOS-C-009: direção sem herdar o lançamento anterior', () {
    test('a seguradora indenizou 3800 do carro batido ⏎ pix → receita', () async {
      final (c, out) = await converse(['a seguradora indenizou 3800 do carro batido', 'pix']);
      expect(c.repo.transactions.single.type, TransactionType.income, reason: out.join('\n'));
    });
    test('fiz um corre de 90 hj ⏎ pix → receita ou pergunta, nunca transferência', () async {
      final (c, out) = await converse(['fiz um corre de 90 hj', 'pix']);
      expect(c.repo.transactions.where((t) => t.type != TransactionType.income), isEmpty, reason: out.join('\n'));
    });
    test('dei um dinheiro pro pedreiro da obra ⏎ R\$ 1.500 → despesa 1500', () async {
      final (c, out) = await converse(['dei um dinheiro pro pedreiro da obra', 'R\$ 1.500']);
      expect(c.repo.transactions.single.type, TransactionType.expense, reason: out.join('\n'));
      expect(c.repo.transactions.single.amount, 1500.0);
    });
    test('ACC-C-007: oi ⏎ paguei o encanador ⏎ recebi 400 da mãe ⏎ 180 do encanador no pix', () async {
      final (c, out) = await converse(['oi cesar', 'paguei o encanador', 'ah antes que eu esqueça recebi 400 da minha mãe no pix', '180 do encanador no pix']);
      final byAmount = {for (final t in c.repo.transactions) t.amount: t.type};
      expect(byAmount[400.0], TransactionType.income, reason: out.join('\n'));
      expect(byAmount[180.0], TransactionType.expense, reason: out.join('\n'));
    });
    for (final t in [
      // novas: frase sem verbo depois de uma receita
      ['recebi 2000 de salário no pix', '90 da diarista no pix'],
      ['recebi 150 de gorjeta no pix', '35 do chaveiro no dinheiro'],
      ['me pagaram 500 do freela no pix', 'eletricista 120 no pix'],
    ]) {
      test('${t.join(' ⏎ ')} → o 2º é despesa (ou pergunta)', () async {
        final (c, out) = await converse(t);
        final firstAmount = engine.parse(t[0]).amount;
        final second = c.repo.transactions.where((x) => x.amount != firstAmount);
        expect(second.where((x) => x.type != TransactionType.expense), isEmpty, reason: out.join('\n'));
      });
    }
    test('CHAOS-C-009: peguei 500 emprestado com a minha mãe no pix ⏎ no banco → nunca despesa', () async {
      final (c, out) = await converse(['peguei 500 emprestado com a minha mãe no pix', 'no banco']);
      expect(c.repo.transactions.where((t) => t.type == TransactionType.expense), isEmpty, reason: out.join('\n'));
    });
    for (final p in ['peguei 300 emprestado do meu irmão no pix', 'pedi 200 emprestado pro meu pai e ele mandou no pix', 'tomei 1000 emprestado no banco']) {
      test('nova: "$p" nunca vira despesa', () async {
        final (c, out) = await converse([p]);
        expect(c.repo.transactions.where((t) => t.type == TransactionType.expense), isEmpty, reason: out.join('\n'));
      });
    }
  });

  group('ACC-C-015 / ACC-C-018: sem "eu" como sujeito, a direção vem do papel ou pergunta mantendo o valor', () {
    for (final t in [
      ['o motoboy recebeu 15 de mim pela entrega', '15'],
      ['a escola recebeu de mim 600 da matricula', '600'],
      ['quem bancou o jantar de 160 fui eu', '160'],
      ['meu cunhado acertou comigo os 180 da bicicleta', '180'],
      ['75 com o dentista', '75'],
      ['acertamos 400 do carro eu e o lucas', '400'],
      ['mexemo 200 la com o tio do bar', '200'],
      ['pix 130 joana', '130'], // ACC-C-018
      // novas
      ['a diarista levou 150 de mim hoje', '150'],
      ['pix 80 marcelo', '80'],
    ]) {
      test('${t[0]} → não perde o valor', () async {
        final c = await chat(seeded: false);
        final r = c.send(t[0]);
        expect(r.text, isNot(contains('gasto ou uma receita, e qual o valor')), reason: '$r');
        // Gravou, ou o rascunho pendente guardou o valor (a pergunta pode ser
        // outra: a forma de pagamento, "entrou ou saiu?").
        if (c.repo.transactions.isEmpty) expect(c.active?.amount, double.parse(t[1]), reason: '$r');
      });
    }
    for (final p in ['mexemos 200 com o tio do bar', 'rolou 150 com o vizinho']) {
      test('sem lado dito, o palpite "receita" do classificador é perguntado: "$p"', () async {
        final c = await chat(seeded: false);
        final r = c.send(p);
        expect(c.repo.transactions, isEmpty, reason: '$r');
        expect(r.text.toLowerCase(), allOf(contains('entrou'), contains('saiu')), reason: '$r');
      });
    }
    test('ACC-C-018: "pix 130 joana" pergunta "entrou ou saiu?"', () async {
      final c = await chat(seeded: false);
      final r = c.send('pix 130 joana');
      expect(r.text.toLowerCase(), allOf(contains('entrou'), contains('saiu'), contains('130')), reason: '$r');
    });
    test('papel: "o motoboy recebeu 15 de mim" é despesa', () async {
      final (c, out) = await converse(['o motoboy recebeu 15 de mim pela entrega', 'pix']);
      expect(c.repo.transactions.where((t) => t.type == TransactionType.income), isEmpty, reason: out.join('\n'));
    });
    test('papel: "meu cunhado acertou comigo os 180" é receita (ou pergunta)', () async {
      final (c, out) = await converse(['meu cunhado acertou comigo os 180 da bicicleta', 'pix']);
      expect(c.repo.transactions.where((t) => t.type == TransactionType.expense), isEmpty, reason: out.join('\n'));
    });
  });

  group('ACC-C-005: "trasanteontem" é 3 dias atrás', () {
    for (final p in [
      'trasantontem gastei 60 na feira no dinheiro', // do achado
      'trasanteontem gastei 60 na feira no dinheiro',
      'tresantontem paguei 60 na feira no dinheiro',
      'trasantonte paguei 60 de feira no dinheiro',
    ]) {
      test(p, () async {
        final (c, out) = await converse([p]);
        expect(c.repo.transactions.map((t) => t.date.day), [back(3).day], reason: out.join('\n'));
      });
    }
  });

  group('ACC-C-020: "mês passado no dia N" é o dia N do mês passado (também no empréstimo)', () {
    DateTime lastMonth(int d) {
      final t = today();
      return DateTime(t.year, t.month - 1, d);
    }

    for (final t in [
      ['mês passado no dia 12 gastei 230 no dentista no pix', 12],
      ['no mês passado, dia 3, paguei 90 de luz no pix', 3],
      ['mês passado no dia 16 emprestei 52 pro meu primo no dinheiro', 16], // CHAOS-C-007
    ]) {
      test(t[0] as String, () async {
        final (c, out) = await converse([t[0] as String]);
        final saved = c.repo.transactions;
        expect(saved, hasLength(1), reason: out.join('\n'));
        final d = saved.single.date;
        expect(DateTime(d.year, d.month, d.day), lastMonth(t[1] as int), reason: out.join('\n'));
      });
    }
  });

  group('CHAOS-C-014: "Amanhã" depois de nome com hífen é nome de loja', () {
    for (final p in ['paguei 35 no Lava-Jato Amanhã no pix', 'gastei 22 na Auto-Escola Hoje no débito', 'recebi 39 de gorjeta no Pet-Shop Amanhã no dinheiro']) {
      test(p, () async {
        final (c, out) = await converse([p]);
        expect(c.repo.transactions.map((t) => t.date.day), [today().day], reason: out.join('\n'));
      });
    }
    test('controle: "paguei 35 no lava-jato amanhã no pix" (minúsculo) pergunta a data', () async {
      final (c, out) = await converse(['paguei 35 no lava-jato amanhã no pix']);
      expect(c.repo.transactions, isEmpty, reason: out.join('\n'));
    });
  });

  group('Sem falso "entrou ou saiu?": dar/deixar/doar um valor é saída', () {
    for (final p in ['deixei 26 de gorjeta pro garçom', 'doei 50 pra creche no débito', 'deixamos 40 de caixinha pro entregador no pix']) {
      test(p, () async {
        final c = await chat(seeded: false);
        final r = c.send(p);
        expect(r.text, isNot(contains('Fiquei na dúvida')), reason: '$r');
      });
    }
  });

  // ───────────────────────── decisões do usuário ─────────────────────────

  group('Decisão (i): rascunho pendente + frase com verbo próprio e outro objeto = lançamento novo com aviso', () {
    for (final t in [
      ['paguei a lanchonete', 'tomei um café de 9', 9.0], // do achado
      ['paguei o flanelinha no dinheiro', 'paguei 140 de pedágio no pix', 140.0],
      ['comprei o pão', 'tomei um suco de 7 no pix', 7.0],
      ['paguei a farmácia', 'comprei um protetor de 60 no pix', 60.0],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () async {
        final c = await chat(seeded: false);
        c.send(t[0] as String);
        final r = c.send(t[1] as String);
        expect(r.text, contains('Deixei de lado'), reason: '$r');
        for (var i = 0; i < 3 && c.draftPending; i++) {
          final a = autoAnswer(c.log.last);
          if (a == null) break;
          c.send(a);
        }
        expect(c.repo.transactions.map((x) => x.amount), [t[2]], reason: c.log.join('\n'));
        final title = c.repo.transactions.single.title.toLowerCase();
        expect(title, isNot(contains((t[0] as String).split(' ').last)), reason: 'não é o rascunho anterior');
      });
    }
    for (final t in [
      ['paguei a lanchonete', 'deu 230', 'lanchonete'],
      ['paguei o seguro', 'foi 1500 no boleto', 'seguro'],
      ['comprei o presente', 'custou 88', 'presente'],
    ]) {
      test('controle: ${t[0]} ⏎ ${t[1]} completa', () async {
        final (c, out) = await converse([t[0], t[1]]);
        expect(c.repo.transactions.single.title.toLowerCase(), contains(t[2]), reason: out.join('\n'));
      });
    }
  });

  group('Decisão (ii): editar/apagar por nome que não está no título sempre confirma mostrando o item', () {
    test('muda a gasolina de ${'<dia>'} pra 47 (só "Posto Shell") → "é esse?" e nada muda', () async {
      final c = await chat();
      final before = seedState(c);
      final r = c.send('muda a gasolina de ${wd(4)} pra 47');
      expect(r.text, contains('Posto Shell'), reason: '$r');
      expect(seedState(c), before);
      c.send('sim');
      expect(rec(c, 'posto').amount, 47.0, reason: c.log.join('\n'));
    });
    test('… ⏎ "não" não muda nada', () async {
      final c = await chat();
      final before = seedState(c);
      c.send('muda a gasolina de ${wd(4)} pra 47');
      c.send('não');
      expect(seedState(c), before);
    });
    for (final p in ['o combustível de ${'D4'} foi 160', 'corrige o lanche de D4 pra 50', 'muda a carne de D6 pra 100', 'o bicho de D5 foi 99']) {
      test(p, () async {
        final c = await chat();
        final before = seedState(c);
        final text = p.replaceAll('D4', wd(4)).replaceAll('D5', wd(5)).replaceAll('D6', wd(6));
        final r = c.send(text);
        expect(seedState(c), before, reason: '$r');
      });
    }
    test('apagar pela categoria: confirma mostrando o item, nada sai sem "sim"', () async {
      final c = await chat();
      final before = seedState(c);
      final r = c.send('apaga a gasolina de ${wd(4)}');
      expect(r.text, contains('Posto Shell'), reason: '$r');
      expect(seedState(c), before);
    });
    test('controle: nome no título edita direto ("muda o posto de D4 pra 47")', () async {
      final c = await chat();
      c.send('muda o posto de ${wd(4)} pra 47');
      expect(rec(c, 'posto').amount, 47.0, reason: c.log.join('\n'));
    });
  });

  // ───────────────────────── P1 estruturais ─────────────────────────

  group('ACC-C-008: edição sem verbo em outros moldes edita o registro citado', () {
    for (final t in [
      ['hamburgueria do ${'D4'} na real deu 58', 'hamb', 58.0], // do achado
      ['na vdd o pet shop foi 115', 'pet', 115.0],
      ['o açougue lá da ${'D6'} saiu por 90 conto', 'acougue', 90.0],
      ['o açougue foi 92 viu', 'acougue', 92.0],
      ['e a sapataria, foi 78 na verdade', 'sapataria', 78.0],
      // novas
      ['a floricultura na real custou 88', 'flor', 88.0],
      ['nvdd a sapataria deu 75', 'sapataria', 75.0],
    ]) {
      final text = (t[0] as String).replaceAll('D4', wd(4)).replaceAll('D6', wd(6));
      test(text, () async {
        final c = await chat();
        c.send(text);
        if (c.log.last.route == 'ask_correction_or_new') c.send('correção');
        expect(rec(c, t[1] as String).amount, t[2], reason: c.log.join('\n'));
        expect(created(c), isEmpty, reason: 'nada de lançamento novo — ${c.log.join('\n')}');
      });
    }
  });

  group('ACC-C-009: "ajusta/aumenta a X pra N" edita', () {
    for (final t in [
      ['ajusta a hamburgueria pra 55', 'hamb', 55.0],
      ['aumenta a floricultura pra 100', 'flor', 100.0],
      ['diminui a sapataria pra 60', 'sapataria', 60.0],
      ['reajusta o pet shop pra 130', 'pet', 130.0],
    ]) {
      test(t[0] as String, () async {
        final c = await chat();
        c.send(t[0] as String);
        expect(rec(c, t[1] as String).amount, t[2], reason: c.log.join('\n'));
        expect(created(c), isEmpty);
      });
    }
  });

  group('ACC-C-010: "caso vc não saiba, …" é fato', () {
    for (final p in [
      'caso vc nao saiba, a academia me cobrou 110 no debito',
      'caso você não saiba, paguei 70 de gás no pix',
      'caso não saiba, gastei 35 no estacionamento no débito',
    ]) {
      test(p, () async {
        final (c, out) = await converse([p]);
        expect(c.repo.transactions, hasLength(1), reason: out.join('\n'));
        expect(c.repo.transactions.single.title.toLowerCase(), isNot(contains('caso')), reason: 'o aparte não vira título');
      });
    }
  });

  group('ACC-C-011: "muda" com rascunho aberto pergunta o que mudar, e "pra 45" muda o valor', () {
    for (final t in [
      ['comprei um guarda chuva de 40 no pix', 'muda', 'pra 45', 45.0], // do achado
      ['comprei uma capinha de 30 no pix', 'corrige', 'pra 35', 35.0],
      ['paguei 80 na lavagem do sofá no pix', 'altera', 'pra 85', 85.0],
    ]) {
      test('${t[0]} ⏎ ${t[1]} ⏎ ${t[2]}', () async {
        final c = await chat(seeded: false);
        c.send(t[0] as String);
        final r = c.send(t[1] as String);
        // (Com o rascunho aberto ou já gravado, "muda" pergunta o que mudar —
        // nunca vira o nome do lugar.)
        expect(c.repo.transactions.where((x) => x.title.toLowerCase() == t[1]), isEmpty, reason: '$r');
        expect(r.text.toLowerCase(), contains('mudar'), reason: '$r');
        c.send(t[2] as String);
        for (var i = 0; i < 3 && c.draftPending; i++) {
          final a = autoAnswer(c.log.last);
          if (a == null) break;
          c.send(a);
        }
        expect(c.repo.transactions.map((x) => x.amount), [t[3]], reason: c.log.join('\n'));
        expect(c.repo.transactions.single.title.toLowerCase(), isNot(t[1]));
      });
    }
  });

  group('ACC-C-012: "X é N e vence dia D todo mês" mantém o valor', () {
    for (final t in [
      ['a mensalidade da faculdade é 890 e vence dia 12 todo mês', 890.0, 12],
      ['o aluguel é 1400 e vence todo dia 5', 1400.0, 5],
      ['meu plano de saúde é 320 e vence dia 20 todo mês', 320.0, 20],
    ]) {
      test(t[0] as String, () async {
        final c = await chat(seeded: false);
        final r = c.send(t[0] as String);
        expect(r.text, isNot(contains('Quanto você')), reason: '$r');
        final d = c.active;
        if (d != null) {
          expect(d.amount, t[1], reason: '$r');
        } else {
          expect(c.repo.transactions.first.amount, t[1], reason: '$r');
        }
      });
    }
  });

  group('ACC-C-013: "larga mão disso" descarta o rascunho', () {
    for (final a in ['larga mão disso, outra hora resolvo', 'deixa pra depois', 'outra hora eu vejo isso']) {
      test('paguei o seguro ⏎ $a', () async {
        final c = await chat(seeded: false);
        c.send('paguei o seguro');
        c.send(a);
        expect(c.draftPending, isFalse, reason: c.log.join('\n'));
        expect(c.repo.transactions, isEmpty);
      });
    }
  });

  group('ACC-C-014: desconto + valor pago grava o valor pago', () {
    for (final t in [
      ['ganhei 40 de desconto no tenis e paguei 260 no débito', 260.0],
      ['consegui 15 de desconto e paguei 85 no pix', 85.0],
      ['paguei 120 no pix, já com 30 de desconto', 120.0],
    ]) {
      test(t[0] as String, () async {
        final (c, out) = await converse([t[0] as String]);
        expect(c.repo.transactions.map((x) => x.amount), [t[1]], reason: out.join('\n'));
        expect(c.repo.transactions.single.type, TransactionType.expense);
      });
    }
  });

  group('CHAOS-C-010: comando/pergunta com lote pendente não é engolido', () {
    test('lote ⏎ apaga o 7 belo → pede confirmação de exclusão', () async {
      final c = await chat();
      c.send('gastei 64 na farmácia e 13 na ótica');
      final r = c.send('apaga o 7 belo');
      expect(r.route, 'confirm_delete', reason: '$r');
    });
    test('lote ⏎ qual meu saldo? → responde', () async {
      final c = await chat();
      c.send('gastei 64 na farmácia e 13 na ótica');
      final r = c.send('qual meu saldo?');
      expect(r.text, isNot(contains('Anotei 2 lançamentos')), reason: '$r');
    });
    test('controle: lote ⏎ pix grava os dois', () async {
      final c = await chat(seeded: false);
      c.send('gastei 64 na farmácia e 13 na ótica');
      c.send('pix');
      expect(c.repo.transactions.map((t) => t.amount).toList()..sort(), [13.0, 64.0], reason: c.log.join('\n'));
    });
  });

  // ───────────────────────── taxa de "Registro assim?" ─────────────────────────

  group('Meta: ≤ 5% de "Registro assim?" em lançamentos claros inéditos', () {
    // 66 frases claras, variadas, que nenhum teste/bateria usa: verbos,
    // registros, gírias, voz sem pontuação, ordem trocada, receitas e
    // transferências.
    const clear = [
      'paguei 47 na farmácia no débito',
      'gastei 32 reais de almoço no pix',
      'comprei um carregador de 59 no débito',
      'recebi 1200 do freela no pix',
      'caiu meu salário de 3500 hoje',
      'torrei 80 no cinema com a namorada no débito',
      'abasteci 200 no posto no débito',
      'uber 23 no pix',
      'almoço 38 no débito',
      'mercado 312 no débito',
      'ontem paguei 90 de internet no boleto',
      'anteontem gastei 15 de pão na padaria em dinheiro',
      'transferi 300 pra minha mãe no pix',
      'mandei 50 pro joão no pix',
      'me pagaram 400 do conserto no pix',
      'o cliente me pagou 250 no pix',
      'vendi minha bicicleta por 700 no pix',
      'paguei a conta de luz de 187 no pix',
      'deixei 120 no salão de beleza no débito',
      'saiu 65 a pizza ontem no pix',
      'foi 28 o estacionamento no débito',
      'comprei remédio de 43 na drogaria no dinheiro',
      'a gente pagou 140 no rodízio no débito',
      'meu chefe depositou 800 de bônus na minha conta',
      'ganhei 150 de gorjeta em dinheiro',
      'recebi 90 de reembolso da empresa no pix',
      'paguei 35 no corte de cabelo em dinheiro',
      'gastei 210 em roupas na loja no débito',
      'botei 100 de gasolina no débito',
      'acabei de pagar 58 no açaí no pix',
      'gastamos 260 no mercado ontem no débito',
      'paguei 12 no ônibus em dinheiro',
      'gastei 19,90 no lanche no pix',
      'paguei 1.250 de aluguel no boleto',
      'recebi 1800 do aluguel do apartamento no pix',
      'comprei um fone de 129 no pix',
      'fiz um pix de 60 pra minha irmã',
      'paguei 22 no café da manhã no débito',
      'tomei um açaí de 18 no pix',
      'jantei fora e gastei 130 no débito',
      'paguei a academia 110 no débito',
      'gastei 300 no dentista no pix',
      'paguei 60 na consulta do veterinário no pix',
      'comprei ração de 89 no pix',
      'paguei o encanador 180 em dinheiro',
      'recebi 200 da venda do sofá no pix',
      'entrou 950 de comissão no pix',
      'paguei 70 no presente da minha mãe no pix',
      'gastei 25 de sorvete no pix',
      'comprei um livro de 54 no pix',
      'paguei 16 de estacionamento no shopping no débito',
      'gastei 95 na feira no dinheiro',
      'comprei pão e leite deu 18 no débito',
      'o mecânico me cobrou 350 no pix',
      'pagamos 220 de conta de água no boleto',
      'paguei 48 de gás no dinheiro',
      'gastei 33 na lavanderia no pix',
      'ontem à noite paguei 95 no bar no débito',
      'segunda paguei 40 de táxi no pix',
      'comprei uma camiseta de 70 no débito',
      'paguei 15 no lava rápido no pix',
      'gastei 27 no hortifruti no débito',
      'bah gastei 45 pila no xis ontem no pix',
      'oxente paguei 30 no mototáxi em dinheiro',
      'hj dei 20 pro flanelinha em dinheiro',
      'dentista 250 no débito',
    ];
    test('${clear.length} frases claras → no máximo 5% pedem confirmação, e todas gravam', () async {
      final asked = <String>[];
      final notSaved = <String>[];
      for (final p in clear) {
        final (c, out) = await converse([p]);
        if (out.any((r) => r.asksConfirm)) asked.add('$p → ${out.firstWhere((r) => r.asksConfirm)}');
        if (c.repo.transactions.isEmpty && !out.any((r) => r.asksConfirm)) notSaved.add('$p → ${out.join(' | ')}');
      }
      // ignore: avoid_print
      print('7E_CONFIRM_RATE ${asked.length}/${clear.length}\n${asked.join('\n')}');
      expect(clear.length, greaterThanOrEqualTo(60));
      expect(asked.length / clear.length, lessThanOrEqualTo(0.05), reason: asked.join('\n'));
      expect(notSaved, isEmpty, reason: notSaved.join('\n'));
    });
  });

  // Sanidade do formato da pergunta.
  test('confirmQuestion mostra tipo, valor, título, pagamento e dia', () {
    final d = engine.parse('compro um fone de 90 no pix');
    final q = EntrySafetyGate.confirmQuestion(d.copyWith(isComplete: true, missingSlots: const []));
    expect(q, contains('R\$ 90,00'));
    expect(q, contains('Pix'));
    expect(q, contains('Registro assim? (sim/não)'));
  });
}
