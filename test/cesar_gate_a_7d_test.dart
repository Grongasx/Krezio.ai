// Corretor, Portão do lote A, etapa 7d (PLANO_CESAR.md): o fluxo de conversa.
// Uma checagem única — PendingReplyCheck: "esta mensagem é a resposta ao que
// está pendente, ou é um assunto novo (comando, pergunta, não-evento,
// lançamento com história própria)?" — vale para todos os estados em que o
// César espera o usuário: rascunho sem valor/pagamento/categoria/data, conta
// recorrente, lote, "o que você quer mudar?", sugestão "não achei — é esse?",
// escolha entre vários. Achados: docs/qa/findings-aceite-lote-a-r2.md (ACC-B-*)
// e docs/qa/findings-caos-lote-a-r2.md (CHAOS-B-*). Além da frase do achado,
// cada grupo tem frases NOVAS e controles contra falso positivo.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/hypothesis_detector.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/pending_reply_check.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// O `_sendMessage` do chat, na ordem atual (sem dívida/metas/"posso
/// comprar", que não entram aqui): cancelar → lote pendente → comandos do
/// assistente → perguntas → lote (também quando a frase é assunto novo com
/// rascunho pendente) → resposta ao rascunho ou frase nova.
class ChatSim {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  List<FinancialTransactionDraft>? batch;

  ChatSim(this.engine, this.repo) : assistant = CesarAssistant(repository: repo, engine: engine);

  bool get draftPending => active != null && !active!.isComplete;

  /// (rota, texto) da resposta.
  (String, String) send(String input) {
    var text = input.trim();
    assistant.beginTurn();
    if (draftPending && engine.isCancelCommand(text)) {
      active = null;
      return ('cancel_pending', 'descartei');
    }
    if (batch != null) {
      final b = batch!;
      final firstOpen = b.firstWhere((d) => !d.isComplete, orElse: () => b.first);
      if (!engine.startsNewTransaction(firstOpen, text)) {
        final merged = engine.mergeMultiDrafts(b, text);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          batch = null;
          return _saveBatch(merged);
        }
        batch = merged;
        return ('ask_multi', prompt);
      }
      batch = null;
    }
    final cmd = assistant.handleCommand(text, hasPendingDraft: draftPending);
    if (cmd != null && cmd.rewrittenInput != null) {
      text = cmd.rewrittenInput!;
    } else if (cmd != null) {
      return (cmd.route, cmd.text);
    }
    final answer = assistant.handleQuestion(text);
    if (answer != null) return (answer.route, answer.text);
    if (!draftPending || engine.startsNewTransaction(active!, text)) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        active = null;
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) return _saveBatch(multi);
        batch = multi;
        return ('ask_multi', prompt);
      }
    }
    FinancialTransactionDraft draft;
    if (draftPending && !engine.startsNewTransaction(active!, text)) {
      draft = engine.mergeDrafts(active!, text);
    } else {
      draft = engine.parse(text);
    }
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      assistant.recordCreated(repo.addTransactionFromDraft(draft).map((t) => t.id).toList());
      active = null;
      return ('saved', '${draft.amount} ${draft.description}');
    }
    active = draft.isComplete || draft.intent == 'unknown' ? null : draft;
    return (draft.intent == 'unknown' ? 'unknown' : 'ask', draft.clarificationPrompt ?? '');
  }

  (String, String) _saveBatch(List<FinancialTransactionDraft> drafts) {
    for (final d in drafts) {
      assistant.recordCreated(repo.addTransactionFromDraft(d).map((t) => t.id).toList());
    }
    return ('multi', drafts.map((d) => '${d.amount} ${d.description}').join('; '));
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

  /// O nome do dia da semana de [days] dias atrás (use 2–6: sem ambiguidade).
  String wd(int days) => weekdayNames[back(days).weekday - 1];

  /// Dias até o último [weekday] (1–7 dias atrás).
  int lastWeekday(int weekday) {
    var b = (today().weekday - weekday) % 7;
    if (b == 0) b = 7;
    return -b;
  }

  /// Resposta [text] a um rascunho pendente, como o chat decide.
  FinancialTransactionDraft turn(FinancialTransactionDraft pending, String text) =>
      engine.startsNewTransaction(pending, text) ? engine.parse(text) : engine.mergeDrafts(pending, text);

  FinancialTransaction tx(String id, String title, double amount, int daysBack, String cat, {TransactionType type = TransactionType.expense}) =>
      FinancialTransaction(id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: 'pix', date: back(daysBack));

  List<FinancialTransaction> seeds() => [
        tx('mercado', 'Mercado Dia a Dia', 132, 1, 'supermarket'),
        tx('horti', 'Hortifruti', 41, 1, 'supermarket'),
        tx('superbp', 'Supermercado Bom Preço', 210, 2, 'supermarket'),
        tx('padaria', 'Padaria Estrela', 12, 2, 'supermarket'),
        tx('lanch', 'Lanchonete Avenida', 27, 3, 'leisure'),
        tx('n99', '99', 23, 3, 'transport'),
        tx('estac', 'Estacionamento Centro', 15, 4, 'transport'),
        tx('livraria', 'Livraria', 33, 4, 'education'),
        tx('cinema', 'Cinema', 40, 5, 'leisure'),
        tx('acougue', 'Açougue', 77, 6, 'supermarket'),
        tx('drogaria', 'Drogaria Central', 52, 6, 'health'),
        tx('sacolao', 'Sacolão', 38, 9, 'supermarket'),
      ];

  Future<ChatSim> chat() async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    for (final t in seeds()) {
      repo.addTransaction(t);
    }
    return ChatSim(engine, repo);
  }

  FinancialTransaction rec(ChatSim c, String id) => c.repo.transactions.firstWhere((t) => t.id == id);

  /// Os lançamentos semeados, como estavam.
  String seedState(ChatSim c) => (c.repo.transactions
          .where((t) => seeds().any((s) => s.id == t.id))
          .map((t) => '${t.id}:${t.amount}:${t.title}:${t.paymentMethod}:${t.date.day}')
          .toList()
        ..sort())
      .join(',');

  List<FinancialTransaction> created(ChatSim c) => c.repo.transactions.where((t) => !seeds().any((s) => s.id == t.id)).toList();

  // ───────────────────────── a checagem única ─────────────────────────

  group('PendingReplyCheck: resposta × assunto novo (a regra comum)', () {
    const ration = PendingSubject('comprei ração pro cachorro no pix Ração', direction: 'expense', category: 'pets');
    const market = PendingSubject('Mercado Supermercado', direction: 'expense', category: 'supermarket', isRecord: true);
    for (final t in [
      // [texto, assunto, esperado]
      ['50', ration, TopicShift.none],
      ['deu 89 no pix', ration, TopicShift.none],
      ['paguei 89 na ração', ration, TopicShift.none],
      ['o veterinário me cobrou 120 de consulta', ration, TopicShift.newEntry],
      ['quanto gastei com o cachorro esse mês?', ration, TopicShift.question],
      ['por pouco não torrei 118 no cassino', ration, TopicShift.nonEvent],
      ['se eu comprar mais um saco de 90 fica caro?', ration, TopicShift.nonEvent],
      ['45', market, TopicShift.none],
      ['foi no débito', market, TopicShift.none],
      ['paguei 45 no mercado', market, TopicShift.none],
      ['gastei 30 na padaria no pix', market, TopicShift.newEntry],
      ['apaga o sacolão', market, TopicShift.command],
      ['desfaz', market, TopicShift.command],
    ]) {
      test('"${t[0]}" → ${t[2]}', () {
        final text = t[0] as String;
        final fresh = engine.parse(text);
        final tx = const {'expense', 'income', 'transfer'}.contains(fresh.intent);
        expect(
            PendingReplyCheck.classify(text, t[1] as PendingSubject,
                textDirection: tx ? fresh.intent : null, textCategory: tx ? fresh.category : null, commands: true),
            t[2]);
      });
    }
  });

  // ───────────────────────── rascunho × frase nova ─────────────────────────

  group('ACC-B-008: número de endereço/lugar não completa o rascunho', () {
    for (final t in [
      ['comprei cerveja', 'moro no 402'], // do achado
      ['paguei o pedreiro', 'ele mora na 15'],
      ['comprei uma pizza', 'fiquei no 12 esperando'],
      ['gastei com o táxi', 'desci no 300 da avenida'],
      ['comprei pão', 'a padaria fica na 7'],
      ['paguei a diarista', 'ela trabalha num 2 quartos'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final d = turn(engine.parse(t[0]), t[1]);
        expect(d.amount, isNull, reason: '${d.amount} ${d.clarificationPrompt}');
        expect(LocalFinancialNlpEngine.isRecordable(d), isFalse);
      });
    }
    for (final t in [
      ['comprei cerveja', '12', 12.0],
      ['comprei cerveja', 'deu 12 no pix', 12.0],
      ['comprei cerveja', 'foi no 12 mesmo', 12.0],
    ]) {
      test('controle: ${t[0]} ⏎ ${t[1]} completa o valor', () {
        expect(turn(engine.parse(t[0] as String), t[1] as String).amount, t[2]);
      });
    }
    test('controle: "paguei 30 no 99 no pix" é R\$ 30 no app 99', () {
      final d = engine.parse('paguei 30 no 99 no pix');
      expect(d.amount, 30.0);
    });
  });

  group('ACC-B-015: venda/consumo sem valor é lançamento (pergunta o valor) e substitui o rascunho', () {
    test('paguei o bombeiro hidráulico ⏎ vendi umas roupas no brechó (do achado)', () {
      final pending = engine.parse('paguei o bombeiro hidráulico');
      expect(engine.startsNewTransaction(pending, 'vendi umas roupas no brechó'), isTrue);
      final d = engine.parse('vendi umas roupas no brechó');
      expect(d.intent, 'income');
      expect(d.missingSlots, contains('amount'));
    });
    test('almocei no restaurante por quilo ⏎ 36 ontem (do achado)', () {
      final first = engine.parse('almocei no restaurante por quilo');
      expect(first.intent, 'expense');
      expect(first.missingSlots, contains('amount'));
      final d = turn(first, '36 ontem');
      expect(d.amount, 36.0);
      expect(d.dateOffsetDays, -1);
    });
    for (final t in [
      ['vendi meu celular velho', 'income'],
      ['vendi a bicicleta da minha filha', 'income'],
      ['jantei numa pizzaria', 'expense'],
      ['lanchei na padaria da esquina', 'expense'],
      ['tomei um café na lanchonete', 'expense'],
    ]) {
      test('"${t[0]}" → ${t[1]} perguntando o valor', () {
        final d = engine.parse(t[0]);
        expect(d.intent, t[1]);
        expect(d.missingSlots, contains('amount'));
      });
    }
    test('"paguei o eletricista" ⏎ "vendi meu celular velho" é outro assunto', () {
      expect(engine.startsNewTransaction(engine.parse('paguei o eletricista'), 'vendi meu celular velho'), isTrue);
    });
    for (final p in ['tomei um banho', 'comi demais hoje']) {
      test('controle: "$p" não vira rascunho', () {
        expect(engine.parse(p).intent, 'unknown');
      });
    }
  });

  group('CHAOS-B-010: frase nova com verbo e objeto próprios não completa o rascunho', () {
    for (final t in [
      ['comprei ração pro cachorro no pix', 'o síndico me cobrou 30 de multa no pix'], // do achado
      ['o inquilino me pagou no pix', 'vendi a cadeira por 14 no pix'], // do achado
      ['paguei a lanchonete quinta avenida no pix', 'agora há pouco me mandaram pagar 37 de taxa de lixo no pix'], // do achado
      ['comprei areia pro gato no pix', 'o mecânico me cobrou 120 da revisão no pix'],
      ['o cliente me pagou no pix', 'vendi o sofá por 300 no pix'],
      ['paguei a academia no débito', 'a vizinha me cobrou 25 do bolo no pix'],
      ['comprei remédio no pix', 'a escola me cobrou 80 de material no pix'],
      ['paguei o encanador no dinheiro', 'o taxista me cobrou 42 da corrida no dinheiro'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        expect(engine.startsNewTransaction(engine.parse(t[0]), t[1]), isTrue);
      });
    }
    for (final t in [
      ['comprei ração pro cachorro no pix', 'deu 89'],
      ['comprei ração pro cachorro no pix', 'paguei 89 na ração'],
      ['o cliente me pagou no pix', 'ele me pagou 300'],
      ['paguei a academia no débito', 'foi 99'],
    ]) {
      test('controle: ${t[0]} ⏎ ${t[1]} é a resposta', () {
        expect(engine.startsNewTransaction(engine.parse(t[0]), t[1]), isFalse);
      });
    }
  });

  group('CHAOS-B-011: conta recorrente pendente × frase nova sem valor', () {
    for (final t in [
      ['pago 85 de inglês todo mês', 'paguei a academia no pix'], // do achado
      ['a internet de 99 vence dia 5', 'gastei no mercado no débito'], // do achado
      ['a mensalidade do curso de 1350 vence dia 22', 'paguei o chaveiro no pix'], // do achado
      ['pago 120 de plano de saúde todo mês', 'comprei pão na padaria no pix'],
      ['a conta de luz de 180 vence dia 10', 'paguei o encanador no dinheiro'],
      ['todo mês pago 60 de academia', 'gastei no açougue no débito'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0]);
        expect(pending.isComplete, isFalse, reason: 'premissa: a conta ainda pergunta algo');
        expect(engine.startsNewTransaction(pending, t[1]), isTrue);
        expect(engine.parse(t[1]).amount, isNull, reason: 'a frase nova pergunta o próprio valor');
      });
    }
    for (final t in [
      ['pago 85 de inglês todo mês', 'no pix'],
      ['pago 85 de inglês todo mês', 'paguei no débito'],
      ['a internet de 99 vence dia 5', 'pago no boleto'],
    ]) {
      test('controle: ${t[0]} ⏎ ${t[1]} responde a conta', () {
        expect(engine.startsNewTransaction(engine.parse(t[0]), t[1]), isFalse);
      });
    }
  });

  group('CHAOS-B-007 (com rascunho pendente): lote novo substitui o rascunho e vira os lançamentos', () {
    for (final t in [
      ['paguei o chaveiro no pix', 'gastei 47 no açougue e mais 23 na padaria no dinheiro', 2], // do achado
      ['comprei pão', 'almoço 32 e janta 48 no pix', 2],
      ['paguei o eletricista', 'lanche 9 | refri 6 no dinheiro', 2],
      ['comprei um presente', 'gastei 20 no uber e 35 no cinema no pix', 2],
      ['paguei a diarista', 'coloquei 50 de gasolina daí paguei 12 de estacionamento no pix', 2],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () async {
        final c = await chat();
        c.send(t[0] as String);
        expect(c.draftPending, isTrue, reason: 'premissa');
        final r = c.send(t[1] as String);
        expect(r.$1, anyOf('multi', 'ask_multi'), reason: r.$2);
        expect(created(c).length + (c.batch?.length ?? 0), t[2]);
        expect(c.draftPending, isFalse);
      });
    }
  });

  group('CHAOS-B-018: "foi N na segunda-feira" responde o rascunho de receita', () {
    for (final t in [
      ['recebi o acerto do bico no pix', 'foi 47 na segunda-feira', 47.0, DateTime.monday], // do achado
      ['recebi a comissão no pix', 'caiu 300 na terça-feira', 300.0, DateTime.tuesday],
      ['o cliente me pagou no pix', 'foi 150 na sexta-feira', 150.0, DateTime.friday],
      ['gastei no sacolão no pix', 'deu 80 na quarta-feira', 80.0, DateTime.wednesday],
      ['recebi o aluguel da sala no pix', 'foram 900 na quinta-feira', 900.0, DateTime.thursday],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0] as String);
        expect(engine.startsNewTransaction(pending, t[1] as String), isFalse);
        final d = engine.mergeDrafts(pending, t[1] as String);
        expect(d.amount, t[2]);
        expect(d.intent, pending.intent);
        expect(d.dateOffsetDays, lastWeekday(t[3] as int));
      });
    }
    test('"segunda-feira" não vira o título "Feira" (supermercado)', () {
      final d = engine.parse('gastei 47 na segunda-feira no pix');
      expect(d.description.toLowerCase(), isNot('feira'));
      expect(d.category, isNot('supermarket'));
    });
    test('controle: "a feira de domingo deu 60" ainda é a feira', () {
      expect(engine.parse('gastei 60 na feira no pix').category, 'supermarket');
    });
  });

  group('CHAOS-B-020: "onde foi?" aceita um lugar dito em poucas palavras, e não repete em loop', () {
    for (final t in [
      ['gastei 150 na rua 25 de março no pix', 'loja', 'Loja'], // do achado
      ['gastei 95 na Loja 25 de Março no pix', 'compras', 'Compras'], // do achado
      ['gastei 150 na rua 25 de março no pix', 'numa banca', 'Banca'],
      ['gastei 150 na rua 25 de março no pix', 'foi no camelô', 'Camelô'],
      ['gastei 150 na rua 25 de março no pix', 'brechó', 'Brechó'],
      ['gastei 150 na rua 25 de março no pix', 'na loja de 1,99 da esquina', null],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0]!);
        expect(pending.missingSlots, contains('category'), reason: 'premissa: ${pending.clarificationPrompt}');
        final d = engine.mergeDrafts(pending, t[1]!);
        if (t[2] == null) {
          // Um número na resposta não é o lugar — mas também não grava errado.
          expect(d.amount, pending.amount);
          return;
        }
        expect(d.isComplete, isTrue, reason: '${d.clarificationPrompt}');
        expect(d.description, t[2]);
        expect(d.amount, pending.amount);
      });
    }
    test('a mesma pergunta não se repete uma 3ª vez sem oferecer saída', () {
      var d = engine.parse('gastei 150 na rua 25 de março no pix');
      final asked = <String>[d.clarificationPrompt!];
      for (final a in ['não sei', 'sei lá', 'hmm']) {
        d = engine.mergeDrafts(d, a);
        asked.add(d.clarificationPrompt!);
      }
      // 1ª: a pergunta; 2ª: "não entendi" + a pergunta; da 3ª em diante, a saída.
      expect(asked[2], isNot(asked[1]));
      for (final q in asked.skip(2)) {
        expect(q.toLowerCase(), allOf(contains('outros'), contains('cancela')));
      }
      final out = engine.mergeDrafts(d, 'outros');
      expect(out.isComplete, isTrue);
      expect(out.category, 'expense_other');
    });
    for (final a in ['pix', 'ontem', 'sim', 'não sei']) {
      test('controle: "$a" não é lugar', () {
        final d = engine.mergeDrafts(engine.parse('gastei 150 na rua 25 de março no pix'), a);
        expect(d.missingSlots, contains('category'));
      });
    }
  });

  // ───────────────────────── restos da 7c ─────────────────────────

  group('Não-evento não grava nem vira rascunho pendente (resto da 7c)', () {
    for (final p in [
      'não gastei os 66 que tinha separado pro bar', // do achado
      'por pouco não torrei 118 no cassino',
      'quase comprei um tênis de 300 no pix',
      'nem paguei a academia esse mês',
      'desisti de comprar o sofá de 1200',
      'ainda não paguei a luz de 150',
      'nunca recebi os 200 do joão',
    ]) {
      test('"$p"', () {
        expect(HypothesisDetector.notHappened(p), isTrue);
        final d = engine.parse(p);
        expect(LocalFinancialNlpEngine.isRecordable(d), isFalse);
        expect(const {'expense', 'income', 'transfer'}.contains(d.intent), isFalse, reason: 'não pode ficar como rascunho pendente');
      });
    }
    for (final t in [
      ['não paguei no crédito, paguei 50 no pix', 50.0],
      ['nem gastei muito, foi 30 no mercado no pix', 30.0],
      ['gastei quase 50 no mercado no pix', 50.0],
      ['não lembro a hora, mas paguei 25 no uber no pix', 25.0],
    ]) {
      test('controle (fato): "${t[0]}"', () {
        final d = engine.parse(t[0] as String);
        expect(HypothesisDetector.notHappened(t[0] as String), isFalse);
        expect(d.amount, t[1]);
        expect(d.intent, 'expense');
      });
    }
    test('não-evento ⏎ "entrou 9 no pix de comissão" grava só a comissão', () async {
      final c = await chat();
      expect(c.send('não gastei os 66 que tinha separado pro bar').$1, 'unknown');
      expect(c.draftPending, isFalse);
      c.send('entrou 9 no pix de comissão');
      expect(created(c).map((t) => '${t.amount} ${t.type.name}').toList(), ['9.0 income']);
    });
    test('com rascunho pendente, um não-evento não é a resposta', () {
      expect(engine.startsNewTransaction(engine.parse('comprei ração no pix'), 'por pouco não torrei 118 no cassino'), isTrue);
    });
  });

  group('Lista com data na frente ("faz três dias: açougue: 260, padaria: 85") é um lote na data dita (resto da 7c)', () {
    for (final t in [
      ['faz três dias: açougue: 260, padaria: 85', [260.0, 85.0], -3], // do achado
      ['ontem — pão 8, leite 6 no débito', [8.0, 6.0], -1],
      ['anteontem: farmácia 40, padaria 12, tudo no pix', [40.0, 12.0], -2],
      ['há dois dias: uber 18, almoço 30 no pix', [18.0, 30.0], -2],
    ]) {
      test('${t[0]}', () {
        final b = engine.parseMulti(t[0] as String);
        expect(b.map((d) => d.amount).toList(), t[1]);
        expect(b.every((d) => d.dateOffsetDays == t[2]), isTrue, reason: b.map((d) => d.dateOffsetDays).join(','));
      });
    }
    test('… ⏎ "paguei o chaveiro" ⏎ "66": o chaveiro é outro assunto e fica com a data de hoje', () async {
      final c = await chat();
      c.send('faz três dias: açougue: 260, padaria: 85');
      c.send('paguei o chaveiro');
      c.send('66');
      c.send('pix');
      final chave = created(c).where((t) => t.amount == 66).toList();
      for (final t in chave) {
        expect(DateTime(t.date.year, t.date.month, t.date.day), today());
      }
      expect(created(c).where((t) => t.amount == 66 && t.title.toLowerCase().contains('padaria')), isEmpty);
    });
  });

  group('"não quero parcelar" como resposta = à vista (resto da 7c)', () {
    for (final a in ['não quero parcelar', 'nem vou parcelar', 'não precisa parcelar', 'sem parcelar', 'nada de parcelar', 'não, não parcelei']) {
      test('comprei uma tv de 2000 no crédito ⏎ $a', () {
        final d = engine.mergeDrafts(engine.parse('comprei uma tv de 2000 no crédito'), a);
        expect(d.installments, 1);
        expect(d.isComplete, isTrue, reason: '${d.clarificationPrompt}');
      });
    }
    test('controle: "parcelei em 3" = 3x', () {
      expect(engine.mergeDrafts(engine.parse('comprei uma tv de 2000 no crédito'), 'parcelei em 3').installments, 3);
    });
  });

  // ───────────────────────── estados de edição ─────────────────────────

  group('CHAOS-B-012: depois de "passa/muda/corrige/edita" sozinho, só uma mudança muda o registro', () {
    Future<(ChatSim, FinancialTransaction)> afterOpen(String verb) async {
      final c = await chat();
      c.send('gastei 50 no mercado no pix');
      final mine = created(c).single;
      expect(c.send(verb).$1, 'ask_changes');
      return (c, mine);
    }

    for (final t in [
      ['passa', 'gastei 30 na padaria no pix'], // do achado
      ['muda', 'recebi 300 de freela no pix'], // do achado
      ['edita', 'apaga o sacolão'], // do achado
      ['corrige', 'por pouco não torrei 118 no cassino'], // do achado
      ['altera', 'quanto gastei essa semana?'],
      ['passa', 'comprei uma blusa de 80 no débito'],
      ['muda', 'a vizinha me pagou 40 do bolo no pix'],
      ['edita', 'muda o cinema pra 45'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () async {
        final (c, mine) = await afterOpen(t[0]);
        c.send(t[1]);
        final now = rec(c, mine.id);
        expect('${now.title} ${now.amount} ${now.type.name} ${now.paymentMethod}', 'Mercado 50.0 expense pix');
      });
    }
    test('"passa" ⏎ "gastei 30 na padaria no pix" grava a padaria', () async {
      final (c, _) = await afterOpen('passa');
      c.send('gastei 30 na padaria no pix');
      expect(created(c).map((t) => t.amount).toList()..sort(), [30.0, 50.0]);
    });
    test('"edita" ⏎ "muda o cinema pra 45" muda o Cinema', () async {
      final (c, _) = await afterOpen('edita');
      c.send('muda o cinema pra 45');
      expect(rec(c, 'cinema').amount, 45.0);
    });
    for (final t in [
      ['passa', '45', 'amount', 45.0],
      ['muda', 'foi no débito', 'pay', 'debit_card'],
      ['corrige', 'paguei 45', 'amount', 45.0],
      ['edita', 'paguei 45 no mercado', 'amount', 45.0],
    ]) {
      test('controle: ${t[0]} ⏎ ${t[1]} muda o registro', () async {
        final (c, mine) = await afterOpen(t[0] as String);
        c.send(t[1] as String);
        final now = rec(c, mine.id);
        expect(t[2] == 'amount' ? now.amount : now.paymentMethod, t[3]);
      });
    }
  });

  group('CHAOS-B-013: "na verdade o X foi N" com X existente edita o X, não o último', () {
    for (final t in [
      ['me devolveram 175 no pix', 'na verdade o açougue foi 23', 'acougue', 23.0], // do achado
      ['gastei 66 na banca no pix', 'na verdade o açougue foi 14', 'acougue', 14.0], // do achado
      ['gastei 66 na banca no pix', 'aliás, a padaria estrela foi 14', 'padaria', 14.0],
      ['paguei 20 de uber no pix', 'na real o cinema foi 35', 'cinema', 35.0],
      ['comprei um livro de 50 no pix', 'me enganei, o sacolão foi 41', 'sacolao', 41.0],
      ['recebi 300 de freela no pix', 'na verdade a drogaria central foi 49', 'drogaria', 49.0],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () async {
        final c = await chat();
        c.send(t[0] as String);
        final mine = created(c).single;
        c.send(t[1] as String);
        expect(rec(c, t[2] as String).amount, t[3]);
        final last = rec(c, mine.id);
        expect('${last.title} ${last.amount}', '${mine.title} ${mine.amount}', reason: 'o último não muda');
      });
    }
    test('controle: "gastei 50 no mercado" ⏎ "na verdade o mercado foi 45" corrige o que acabou de lançar', () async {
      final c = await chat();
      c.send('gastei 50 no mercado no pix');
      final mine = created(c).single;
      c.send('na verdade o mercado foi 45');
      expect(rec(c, mine.id).amount, 45.0);
      expect(rec(c, 'mercado').amount, 132.0);
    });
    test('controle: "na verdade foi 45" corrige o último', () async {
      final c = await chat();
      c.send('gastei 50 na banca no pix');
      final mine = created(c).single;
      c.send('na verdade foi 45');
      expect(rec(c, mine.id).amount, 45.0);
    });
  });

  group('CHAOS-B-016: título numérico ("passa o 99 pra 25")', () {
    for (final t in [
      'passa o 99 pra 25', // do achado
      'muda o 99 pra 25',
      'bota o 99 como 25',
      'troca o 99 pra 25 reais',
    ]) {
      test(t, () async {
        final c = await chat();
        c.send(t);
        expect(rec(c, 'n99').amount, 25.0);
        expect(created(c), isEmpty, reason: 'não pode virar transferência');
      });
    }
    test('passa o 99 de ${'<dia>'} pra 28 (com o dia)', () async {
      final c = await chat();
      c.send('passa o 99 de ${wd(3)} pra 28');
      expect(rec(c, 'n99').amount, 28.0);
    });
    test('controle: "passa 99 pro joão" não edita o 99', () async {
      final c = await chat();
      final before = seedState(c);
      c.send('passa 99 pro joão');
      expect(seedState(c), before);
    });
    test('controle: "passa o 77 pra 30" (nenhum título "77") não mexe em nada', () async {
      final c = await chat();
      final before = seedState(c);
      c.send('passa o 77 pra 30');
      expect(seedState(c), before);
    });
  });

  group('ACC-B-016: verbos regionais e vocativo/ruído nos comandos', () {
    for (final t in [
      ['bota a drogaria de ${'D6'} como 60', 'drogaria', 60.0], // do achado
      ['ô césar muda aí o açougue da ${'D6'} que foi 86 na verdade', 'acougue', 86.0], // do achado
      ['põe o cinema como 45', 'cinema', 45.0],
      ['e aí césar, troca lá a padaria estrela pra 15', 'padaria', 15.0],
      ['coloca o cinema de ${'D5'} como 42', 'cinema', 42.0],
      ['ô cesar, muda aí o sacolão que foi 39', 'sacolao', 39.0],
    ]) {
      final text = (t[0] as String).replaceAll('D6', wd(6)).replaceAll('D5', wd(5));
      test(text, () async {
        final c = await chat();
        c.send(text);
        expect(rec(c, t[1] as String).amount, t[2]);
      });
    }
    for (final t in [
      ['joga no lixo o sacolão', 'pode apagar', 'sacolao'], // do achado
      ['manda pro lixo o 99', 'sim', 'n99'],
      ['ô cesar apaga aí o cinema', 'sim', 'cinema'],
      ['joga no lixo aquele da livraria', 'pode', 'livraria'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () async {
        final c = await chat();
        expect(c.send(t[0]).$1, 'confirm_delete');
        c.send(t[1]);
        expect(c.repo.transactions.any((x) => x.id == t[2]), isFalse);
      });
    }
  });

  // ───────────────────────── resolvedor ─────────────────────────

  group('CHAOS-B-014: palavra de categoria sem título correspondente só oferece (nunca edita direto)', () {
    for (final t in [
      ['muda o uber de D4 pra 40', 'Estacionamento'], // do achado (o uber → Estacionamento)
      ['o uber de D4 foi 40', 'Estacionamento'], // do achado
      ['muda o curso de D4 pra 40', 'Livraria'], // do achado (curso → Livraria)
      ['muda o transporte de D4 pra 20', 'Estacionamento'],
      ['muda o estudo de D4 pra 50', 'Livraria'],
      ['passa a saúde de D6 pra 70', 'Drogaria'],
    ]) {
      final text = t[0].replaceAll('D4', wd(4)).replaceAll('D6', wd(6));
      test(text, () async {
        final c = await chat();
        final before = seedState(c);
        final r = c.send(text);
        expect(seedState(c), before, reason: r.$2);
        expect(r.$2, contains(t[1]), reason: 'mostra o item');
      });
    }
    test('… ⏎ "sim" aplica a mudança no item mostrado', () async {
      final c = await chat();
      c.send('muda o curso de ${wd(4)} pra 40');
      c.send('sim');
      expect(rec(c, 'livraria').amount, 40.0);
    });
    test('… ⏎ "não" não muda nada', () async {
      final c = await chat();
      final before = seedState(c);
      c.send('muda o uber de ${wd(4)} pra 40');
      c.send('não');
      expect(seedState(c), before);
    });
    test('apaga o uber de D4 ⏎ sim ⏎ sim: a exclusão ainda confirma mostrando o item', () async {
      final c = await chat();
      c.send('apaga o uber de ${wd(4)}');
      final r = c.send('sim');
      expect(r.$1, 'confirm_delete');
      expect(r.$2, contains('Estacionamento'));
      expect(c.repo.transactions.any((x) => x.id == 'estac'), isTrue);
    });
  });

  group('CHAOS-B-026: casamento só por categoria do mesmo tipo também confirma', () {
    for (final t in [
      ['muda a feira de ontem pra 70', ['Mercado Dia a Dia', 'Hortifruti']], // do achado
      ['muda a comida de D3 pra 30', ['Lanchonete Avenida']], // do achado
      ['muda o remédio de D6 pra 60', ['Drogaria Central']], // do achado
      ['o restaurante de D3 foi 31', ['Lanchonete Avenida']],
      ['muda a farmácia de D6 pra 58', ['Drogaria Central']],
      ['muda o lazer de D5 pra 44', ['Cinema']],
    ]) {
      final text = (t[0] as String).replaceAll('D3', wd(3)).replaceAll('D5', wd(5)).replaceAll('D6', wd(6));
      test(text, () async {
        final c = await chat();
        final before = seedState(c);
        final r = c.send(text);
        expect(seedState(c), before, reason: r.$2);
        for (final title in t[1] as List<String>) {
          expect(r.$2, contains(title));
        }
      });
    }
    test('… ⏎ "sim" confirma e muda', () async {
      final c = await chat();
      c.send('muda o remédio de ${wd(6)} pra 60');
      c.send('sim');
      expect(rec(c, 'drogaria').amount, 60.0);
    });
    test('controle: pelo título ("muda a lanchonete de D3 pra 30") muda direto', () async {
      final c = await chat();
      c.send('muda a lanchonete de ${wd(3)} pra 30');
      expect(rec(c, 'lanch').amount, 30.0);
    });
    test('controle: "muda a drogaria pra 55" muda direto', () async {
      final c = await chat();
      c.send('muda a drogaria pra 55');
      expect(rec(c, 'drogaria').amount, 55.0);
    });
  });

  group('CHAOS-B-025: 2+ sugestões + "sim" → "qual deles?" listando', () {
    for (final yes in ['sim', 'esse', 'pode ser', 'isso']) {
      test('apaga o mercado de D4 ⏎ $yes', () async {
        final c = await chat();
        final first = c.send('apaga o mercado de ${wd(4)}');
        expect(first.$1, 'not_found');
        final r = c.send(yes);
        expect(r.$1, 'choose', reason: r.$2);
        expect(r.$2, contains('Mercado Dia a Dia'));
        expect(r.$2, contains('Supermercado Bom Preço'));
      });
    }
    test('… ⏎ "sim" ⏎ "2" ⏎ "sim" apaga o escolhido (com confirmação)', () async {
      final c = await chat();
      c.send('apaga o mercado de ${wd(4)}');
      final list = c.send('sim').$2;
      final second = list.split('\n').firstWhere((l) => l.startsWith('2.'));
      final id = second.contains('Bom Preço') ? 'superbp' : 'mercado';
      expect(c.send('2').$1, 'confirm_delete');
      c.send('sim');
      expect(c.repo.transactions.any((x) => x.id == id), isFalse);
    });
    test('… ⏎ "muda o mercado de ontem pra 140" (comando novo) sai da escolha', () async {
      final c = await chat();
      c.send('apaga o mercado de ${wd(4)}');
      c.send('sim');
      c.send('muda o mercado dia a dia pra 140');
      expect(rec(c, 'mercado').amount, 140.0);
    });
  });

  group('ACC-B-020 (P3): dois valores soltos na resposta → "qual dos dois?"', () {
    for (final a in ['120 130 por aí', '45 50', 'uns 80 90', '200 250 acho']) {
      test('comprei material escolar ⏎ $a', () {
        final d = engine.mergeDrafts(engine.parse('comprei material escolar'), a);
        expect(d.amount, isNull);
        expect(d.clarificationPrompt, contains('qual foi o valor certo'));
      });
    }
    test('controle: "50 10/09" é valor e data', () {
      final d = engine.mergeDrafts(engine.parse('comprei material escolar'), '50 10/09');
      expect(d.amount, 50.0);
    });
  });

  group('ACC-B-018 (P2): conserto de coisa da casa é moradia', () {
    for (final p in [
      'me custou 80 o conserto do chuveiro', // do achado
      'paguei 150 no conserto da geladeira no pix',
      'gastei 400 no reparo do telhado no pix',
      'paguei 220 na manutenção do ar-condicionado no pix',
      'paguei 90 na instalação da torneira no débito',
    ]) {
      test(p, () => expect(engine.parse(p).category, 'housing'));
    }
    test('controle: conserto do carro não é moradia', () {
      expect(engine.parse('paguei 300 no conserto do carro no pix').category, isNot('housing'));
    });
  });

  // ───────────────────────── separadores ─────────────────────────

  group('ACC-B-009: separadores "|", "daí" e "X ida N X volta N"', () {
    for (final t in [
      ['uber ida 18 uber volta 18 no pix', [18.0, 18.0]], // do achado
      ['lanche 9,50 | refri 6 no dinheiro', [9.5, 6.0]], // do achado
      ['coloquei 50 de gasolina daí paguei 12 de estacionamento no pix', [50.0, 12.0]], // do achado
      ['pão 8 | leite 6 | café 15 no débito', [8.0, 6.0, 15.0]],
      ['gastei 20 no almoço aí depois paguei 8 de café no pix', [20.0, 8.0]],
      ['paguei 30 no mercado daí fui na farmácia e gastei 20 no pix', [30.0, 20.0]],
      ['táxi ida 25 táxi volta 30 no pix', [25.0, 30.0]],
    ]) {
      test('${t[0]}', () {
        final b = engine.parseMulti(t[0] as String);
        expect(b.map((d) => d.amount).toList(), t[1]);
      });
    }
    test('controle: "fui daí pro mercado e gastei 40 no pix" é um lançamento', () {
      expect(engine.parseMulti('fui daí pro mercado e gastei 40 no pix').length, 1);
    });
  });

  // ─────────────── achados na medição da 7d (caos 6'' do fuzz) ───────────────

  group('CHAOS-B-010 (resto): devolução/estorno é outro acontecimento, não o valor do recebimento pendente', () {
    for (final t in [
      ['o inquilino me pagou no pix', 'me devolveram 118 no pix'], // do fuzz (seed 20261210)
      ['o cliente me pagou no pix', 'me estornaram 50 no pix'],
      ['recebi o aluguel da sala no pix', 'a loja me devolveu 80 no pix'],
      ['meu chefe me pagou no pix', 'me reembolsaram 45 do uber no pix'],
      ['recebi do joão no pix', 'o banco me estornou 30 da tarifa'],
      ['a cliente me pagou no dinheiro', 'me restituíram 200 do imposto no pix'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0]);
        expect(pending.missingSlots, contains('amount'));
        expect(engine.startsNewTransaction(pending, t[1]), isTrue);
      });
    }
    for (final t in [
      ['recebi o reembolso do plano no pix', 'me devolveram 118'],
      ['o inquilino me pagou no pix', 'ele me pagou 1200'],
      ['o inquilino me pagou no pix', 'foram 1200'],
      ['me devolveram o dinheiro da passagem no pix', 'foram 230'],
    ]) {
      test('controle: ${t[0]} ⏎ ${t[1]} é a resposta', () {
        expect(engine.startsNewTransaction(engine.parse(t[0]), t[1]), isFalse);
      });
    }
  });

  group('CHAOS-B-006 (resto): "<verbo> N <fazendo algo>" é entrada, mesmo com lugar ou data d/m', () {
    for (final p in [
      'dia 15/6 tirei 118 vendendo trufa no Hortifruti Terça Verde no pix', // do fuzz (seed 20261224)
      'fiz 200 vendendo bolo na feira no pix',
      'fiz 150 lavando carro no posto no dinheiro',
      'dia 3/9 levantei 250 dando aula de violão no pix',
      '12/9 fiz 80 cortando grama no dinheiro',
      'tirei 60 fazendo unha na casa da vizinha no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.intent, isNot('expense'), reason: '${d.intent} ${d.category} ${d.clarificationPrompt}');
        expect(d.intent == 'income' || d.missingSlots.contains('type'), isTrue, reason: '${d.intent} ${d.clarificationPrompt}');
      });
    }
    for (final p in [
      'perdi 200 apostando no jogo no pix',
      'gastei 50 andando de uber no pix',
      'deixei 30 jogando sinuca no bar no dinheiro',
    ]) {
      test('controle: "$p" não é entrada', () {
        expect(engine.parse(p).intent, isNot('income'));
      });
    }
  });
}
