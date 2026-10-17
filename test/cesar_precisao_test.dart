import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/keyword_typo_corrector.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';

import '_qa/chaos_r3_support.dart';
import 'analytics_test.dart' as a;

/// Afinamento de conversa (rodada R3): erros de digitação, gíria, vários
/// itens numa frase, comentários sem intenção de lançar, perguntas e
/// análises que o César não entendia, referências por mês e por dois dias.
void main() {
  late LocalFinancialNlpEngine engine;
  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  // 6 meses de histórico (salário, aluguel, Netflix, Spotify, mercado, Uber,
  // farmácia, iFood), hoje = 16/10/2026.
  Sim3 chat() => Sim3(engine, a.repo(), now: () => a.now);

  FinancialTransaction tx(String id, String title, double v, DateTime d, String cat, String pay) =>
      FinancialTransaction(id: id, title: title, amount: v, type: TransactionType.expense, category: cat, paymentMethod: pay, date: d);

  /// Poucos lançamentos com datas conhecidas, para as referências.
  Sim3 small() => Sim3(
      engine,
      a.repo(txs: [
        tx('mercant', 'Mercado Extra', 512.30, DateTime(2026, 9, 20, 12), 'supermarket', 'debit_card'),
        tx('cinema', 'Cinemark', 64, DateTime(2026, 10, 11, 12), 'leisure', 'credit_card'),
        tx('farm', 'Farmácia Pague Menos', 57.80, DateTime(2026, 10, 14, 12), 'health', 'debit_card'),
        tx('posto', 'Posto Shell', 189, DateTime(2026, 10, 15, 12), 'transport', 'debit_card'),
        tx('ifood', 'iFood', 41.50, DateTime(2026, 10, 16, 12), 'leisure', 'pix'),
      ]),
      now: () => a.now);

  group('digitação', () {
    test('letra dobrada no fim, k no lugar de c e palavras novas', () {
      expect(KeywordTypoCorrector.correct('aluguell'), 'aluguel');
      expect(KeywordTypoCorrector.correct('debitoo'), 'debito');
      expect(KeywordTypoCorrector.correct('merkado'), 'mercado');
      expect(KeywordTypoCorrector.correct('interneet'), 'internet');
      expect(KeywordTypoCorrector.correct('onbus'), 'onibus');
      expect(KeywordTypoCorrector.correct('dentsta'), 'dentista');
      expect(KeywordTypoCorrector.correct('açouge'), 'acougue', reason: 'com acento, só a letra que falta');
      expect(KeywordTypoCorrector.correct('uberr', isKnownWord: (w) => w == 'uber'), 'uber');
    });

    test('palavras de verdade continuam como estão', () {
      for (final w in ['cereja', 'gostei', 'solário', 'escolha', 'boletos', 'condômino', 'mercados']) {
        expect(KeywordTypoCorrector.correct(w), isNull, reason: w);
      }
      expect(KeywordTypoCorrector.correctText('gastei 88 na framacia', accented: true), 'gastei 88 na farmácia');
    });

    test('a frase com erros vira o lançamento certo, com o título corrigido', () {
      final aluguel = engine.parse('paguie 220 de aluguell no bolto');
      expect([aluguel.intent, aluguel.amount, aluguel.category, aluguel.paymentMethod, aluguel.isComplete], ['expense', 220, 'housing', 'bank_slip', true]);
      final uber = engine.parse('gatei 19 no uberr no pix');
      expect([uber.category, uber.paymentMethod, uber.isComplete], ['transport', 'pix', true]);
      final farm = engine.parse('gastei 88 na framacia no debitoo');
      expect([farm.category, farm.paymentMethod, farm.description], ['health', 'debit_card', 'Farmácia']);
      final bus = engine.parse('gastie 13 no onbus');
      expect([bus.category, bus.description], ['transport', 'Ônibus']);
      expect(engine.parse('gastei 22 no merkado ontem no pics').category, 'supermarket');
    });
  });

  group('gíria', () {
    test('verbos, dinheiro e lugares de gíria', () {
      final lava = engine.parse('soltei 25 pro cara do lava rápido em espécie');
      expect([lava.intent, lava.amount, lava.category, lava.paymentMethod, lava.description, lava.isComplete],
          ['expense', 25, 'transport', 'cash', 'Lava-rápido', true]);
      final rango = engine.parse('o rango de hoje saiu 34 no débito');
      expect([rango.category, rango.description, rango.isComplete], ['leisure', 'Rango', true]);
      final happy = engine.parse('queimei 45 no happy hour ontem no pix');
      expect([happy.intent, happy.category, happy.dateOffsetDays, happy.description], ['expense', 'leisure', -1, 'Happy hour']);
      expect(engine.parse('paguei 16 de pedágio no dinheirinho').paymentMethod, 'cash');
      final moto = engine.parse('peguei o mototáxi, 8 reais no dinheiro');
      expect([moto.category, moto.description], ['transport', 'Mototáxi']);
      expect(engine.parse('gastei 15 mangos no açaí no pix').amount, 15);
      expect(engine.parse('paguei 12 na padoca no débito').category, 'supermarket');
    });

    test('gíria sem valor não vira gasto', () {
      expect(engine.parse('queimei a mão no fogão').amount, isNull);
      expect(engine.parse('soltei o cachorro no parque').amount, isNull);
    });
  });

  group('vários itens', () {
    test('gorjeta e taxa ficam na categoria do item', () {
      final barber = engine.parseMulti('paguei 60 no barbeiro e 20 de gorjeta no pix');
      expect(barber.map((d) => d.amount), [60, 20]);
      expect(barber[1].category, barber[0].category);
      expect(barber.every((d) => d.isComplete), isTrue);
      final pizza = engine.parseMulti('pedi uma pizza de 60 e 8 de taxa de entrega no pix');
      expect([pizza[1].description, pizza[1].category], ['Taxa de entrega', 'leisure']);
    });

    test('a volta é a mesma corrida; pão é mercado', () {
      final uber = engine.parseMulti('uber de 19 pra ir e 23 pra voltar no pix');
      expect(uber.map((d) => [d.amount, d.category, d.description]), [
        [19, 'transport', 'Uber'],
        [23, 'transport', 'Uber'],
      ]);
      final cafe = engine.parseMulti('gastei 12,50 no café e 8,90 no pão no débito');
      expect(cafe.map((d) => d.category), ['leisure', 'supermarket']);
      expect(engine.parseMulti('almoço 32 e janta 48 no pix').map((d) => d.category), ['leisure', 'leisure']);
      final back = engine.parseMulti('peguei um uber de 32 até o centro e voltei de ônibus por 5,50 no pix');
      expect(back.map((d) => [d.amount, d.description]), [
        [32, 'Uber'],
        [5.5, 'Ônibus'],
      ]);
    });
  });

  group('comentários', () {
    test('respondem com os números e não abrem lançamento', () {
      const cases = {
        'a gasolina subiu de novo, absurdo': 'comment:complaint',
        'nossa, a conta de luz veio alta': 'comment:complaint',
        'o aluguel aqui é muito caro': 'comment:complaint',
        'acho que tô gastando muito com uber': 'comment:worry',
        'gastei demais esse fim de semana': 'comment:worry',
        'minha esposa reclamou que eu gasto muito': 'comment:mood',
        'preciso parar de pedir ifood': 'comment:resolution',
        'hoje eu não vou gastar nada': 'comment:resolution',
        'meu salário não dá pra nada': 'comment:income',
        'queria ganhar mais': 'comment:income',
        'hoje é dia de pagamento aqui na firma': 'comment:income',
        'amanhã vou no mercado': 'comment:plan',
        'semana que vem tenho que pagar o IPVA': 'comment:plan',
        'nossa que semana difícil': 'comment:mood',
        'que caro tá tudo': 'comment:mood',
        'odeio pagar boleto': 'comment:mood',
        'a feira hoje tava ótima': 'comment:positive',
      };
      for (final e in cases.entries) {
        final c = chat();
        final before = c.repo.transactions.length;
        final r = c.send(e.key);
        expect(r.route, e.value, reason: '${e.key} → ${r.text}');
        expect(c.repo.transactions.length, before, reason: e.key);
        expect(c.active, isNull, reason: '${e.key}: nenhum rascunho aberto');
      }
    });

    test('com dados: aluguel na renda, salário e o que entra', () {
      expect(chat().send('o aluguel aqui é muito caro').text, contains('30%'));
      expect(chat().send('meu salário não dá pra nada').text, contains('R\$ 5.000,00'));
      expect(chat().send('acho que tô gastando muito com uber').text, contains('Uber'));
    });

    test('"preciso parar de pedir ifood": oferece um limite, "sim" aplica e "desfaz" volta', () {
      // Com o limite de lazer já estourado no mês, avisa em vez de oferecer.
      expect(chat().send('preciso parar de pedir ifood').text, contains('já passou do limite'));
      final c = small();
      final before = c.repo.budgets.firstWhere((b) => b.category == 'leisure').monthlyLimit;
      final r = c.send('preciso parar de pedir ifood');
      expect(r.text, contains('Quer que eu baixe o limite'));
      final set = c.send('sim');
      expect(set.route, 'budget_set');
      final now = c.repo.budgets.firstWhere((b) => b.category == 'leisure').monthlyLimit;
      expect(now, lessThan(before));
      c.send('desfaz');
      expect(c.repo.budgets.firstWhere((b) => b.category == 'leisure').monthlyLimit, before);
    });

    test('lançamentos de verdade continuam lançamentos', () {
      expect(chat().send('gastei 40 no uber no pix').route, 'saved');
      expect(chat().send('paguei a conta de luz').route, 'ask', reason: 'falta o valor');
      expect(chat().send('tô pensando em trocar de carro').route, 'planner:purchase_ask');
      expect(chat().send('será que compensa assinar o gamepass?').route, 'planner:purchase_ask');
      expect(chat().send('preciso economizar').route, 'planner:save_more');
    });
  });

  group('perguntas', () {
    double spentFrom(Sim3 c, DateTime start) => c.repo.transactions
        .where((t) => t.type == TransactionType.expense && !t.date.isBefore(start) && !t.date.isAfter(a.now))
        .fold(0.0, (x, t) => x + t.amount);

    test('"foi embora", "últimos 7 dias", "mais salgado", "dinheiro vivo"', () {
      expect(chat().send('quanto já foi embora esse mês?').route, 'report:spending');
      final c = chat();
      final week = c.send('quanto gastei nos últimos 7 dias?');
      expect(week.route, 'report:spending');
      expect(week.text, contains('nos últimos 7 dias'));
      expect(week.text, contains(CesarText.money(spentFrom(c, DateTime(2026, 10, 10)))));
      final big = chat().send('qual foi meu gasto mais salgado esse mês?');
      expect([big.route, big.text.contains('Aluguel')], ['report:largestExpense', true]);
      final cash = chat().send('quanto saiu no dinheiro vivo?');
      expect(cash.route, 'report:spending');
      expect(cash.text, isNot(contains('vivo')), reason: 'é dinheiro, não a operadora');
    });

    test('ranking: "e o menor?", "e o segundo maior?", "qual meu segundo maior gasto?"', () {
      final c = chat();
      c.send('qual foi o maior gasto do mês?');
      expect(c.send('e o menor?').route, 'report:smallestExpense');
      final d = chat();
      d.send('qual meu maior gasto do mês?');
      expect(d.send('e o segundo maior?').text, contains('segundo maior'));
      expect(chat().send('qual meu segundo maior gasto?').text, contains('segundo maior'));
    });

    test('categoria que pesa, orçamento no geral, comparação de uma coisa', () {
      expect(chat().send('qual categoria tá pesando mais?').route, 'report:topCategory');
      expect(chat().send('o que mais pesa no meu orçamento?').route, 'report:topCategory');
      final budget = chat().send('estou dentro do orçamento?');
      expect(budget.route, 'report:budgetRemaining');
      expect(budget.text, contains('No total'));
      expect(chat().send('gastei mais esse mês ou no passado?').route, 'report:overview');
      final ifood = chat().send('tô gastando mais com ifood que no mês passado?');
      expect(ifood.route, 'report:overview');
      expect(ifood.text, contains('com iFood'));
      expect(chat().send('quando foi a última vez que fui à farmácia?').text, contains('Farmácia'));
    });
  });

  group('análises', () {
    test('médias por dia, semana e mês, de tudo ou de uma categoria', () {
      expect(chat().send('em média quanto eu gasto por dia?').route, 'advice:daily_average');
      expect(chat().send('quanto gasto por semana em média?').route, 'advice:weekly_average');
      expect(chat().send('qual meu gasto médio diário com mercado?').text, contains('com mercado'));
      expect(chat().send('quanto eu gasto em média por mês com uber?').route, 'advice:monthly_average');
    });

    test('ano, dia da semana, mês recorde', () {
      expect(chat().send('quanto eu gasto por ano com netflix?').text, contains('R\$ 670,80'));
      expect(chat().send('qual dia da semana eu mais gasto?').route, 'advice:weekday');
      expect(chat().send('qual foi o mês que eu mais gastei?').route, 'advice:peak_month');
    });

    test('em quanto tempo junto, aumento de salário, "sem o ifood"', () {
      expect(chat().send('em quanto tempo eu junto 5 mil guardando 500 por mês?').text, contains('10 meses'));
      expect(chat().send('se meu salário aumentar 10%, quanto sobra por mês?').text, contains('R\$ 5.500,00'));
      final without = chat().send('quanto eu teria hoje se não tivesse pedido ifood?');
      expect([without.route, without.text.contains('iFood')], ['hypothesis', true]);
      final cut = chat().send('se eu cortar delivery quanto economizo?');
      expect(cut.text, contains('Só este mês'));
    });

    test('"me avisa se eu passar de 500 no lazer" vira o limite', () {
      final c = chat();
      expect(c.send('me avisa se eu passar de 500 no lazer').route, 'budget_set');
      expect(c.repo.budgets.firstWhere((b) => b.category == 'leisure').monthlyLimit, 500);
    });
  });

  group('referências', () {
    test('"o mercado de setembro foi 530" corrige o de setembro', () {
      final c = small();
      expect(c.send('o mercado de setembro foi 530').route, 'edited');
      expect(c.repo.transactions.firstWhere((t) => t.id == 'mercant').amount, 530);
    });

    test('"o do cinema foi 46 e no pix" corrige sem perguntar', () {
      final c = small();
      expect(c.send('o do cinema foi 46 e no pix').route, 'edited');
      final t = c.repo.transactions.firstWhere((t) => t.id == 'cinema');
      expect([t.amount, t.paymentMethod], [46, 'pix']);
    });

    test('"apaga os gastos de ontem e de hoje" pega os dois dias', () {
      final c = small();
      final ask = c.send('apaga os gastos de ontem e de hoje');
      expect(ask.route, 'confirm_delete');
      expect(ask.text, allOf(contains('Posto Shell'), contains('iFood')));
      c.send('sim');
      final ids = c.repo.transactions.map((t) => t.id).toSet();
      expect(ids.containsAll(['posto', 'ifood']), isFalse);
      expect(ids, containsAll(['farm', 'cinema', 'mercant']));
    });
  });

  test('"paguei 90" ⏎ "luz" ⏎ "boleto": título e forma de pagamento das respostas', () {
    final c = small();
    c.send('paguei 90');
    expect(c.send('luz').text, contains('Luz'));
    expect(c.send('boleto').route, 'saved');
    final t = c.repo.transactions.firstWhere((t) => t.amount == 90);
    expect([t.title, t.category, t.paymentMethod], ['Luz', 'housing', 'bank_slip']);
  });

  group('rodada de frases novas', () {
    test('fatura do cartão não vira gasto em dobro', () {
      final c = chat();
      final before = c.repo.transactions.length;
      final r = c.send('paguei a fatura do cartão 1.540');
      expect(r.route, 'planner:card_bill');
      expect(c.repo.transactions.length, before);
      expect(chat().send('paguei a fatura da vivo 120 no pix').route, isNot('planner:card_bill'), reason: 'conta de telefone é conta');
    });

    test('Pix para parente, recarga de celular, salão, gorjeta do garçom, tv', () {
      final sis = engine.parse('dei 100 pra minha irmã no pix');
      expect([sis.intent, sis.description, sis.isComplete], ['transfer', 'Irmã', true]);
      expect(engine.parse('mandei 50 pro meu pai no pix').description, 'Pai');
      final top = engine.parse('coloquei 50 de crédito no celular');
      expect([top.category, top.paymentMethod, top.description], ['housing', 'unknown', 'Recarga de celular']);
      final salao = engine.parse('gastei 250 no salão de beleza no crédito à vista');
      expect([salao.category, salao.description, salao.isComplete], ['expense_other', 'Salão de beleza', true]);
      expect(engine.parse('deixei 15 de gorjeta pro garçom no pix').category, 'leisure');
      final tv = engine.parse('gastei 1.200 numa tv em 10x no cartão de crédito');
      expect([tv.category, tv.description, tv.installments], ['housing', 'Televisão', 10]);
    });

    test('empréstimo: o dia de pagar é o da cobrança, não o do lançamento', () {
      final now = DateTime.now();
      final d = engine.parse('emprestei 300 pro carlos ele me paga dia 10');
      expect(d.dateOffsetDays, 0);
      final due = d.targetDate!;
      expect(due.day, 10);
      expect(due.isAfter(DateTime(now.year, now.month, now.day)), isTrue);
      final next = engine.parse('emprestei 300 pro carlos ele me paga mês que vem');
      expect(next.isComplete, isTrue);
      expect(next.targetDate!.month, DateTime(now.year, now.month + 1).month);
      expect(engine.parse('emprestei 50 pra minha irmã, ela devolve sexta').personName, 'Irmã');
    });

    test('perguntas: economizei, ainda posso gastar, média da semana, meta', () {
      expect(chat().send('quanto eu economizei esse mês?').route, 'report:savings');
      expect(chat().send('quanto ainda posso gastar esse mês?').route, 'report:dailyBudget');
      expect(chat().send('quanto eu gastei em média por dia essa semana?').text, contains('esta semana'));
      final c = chat();
      expect(c.send('quero juntar 2000 até dezembro pra comprar um celular').route, isNot('ask'));
      expect(c.repo.goals.any((g) => g.title == 'Celular'), isTrue, reason: 'não "Comprar um celular"');
      final adiant = chat().send('dia 3 recebi 1500 de adiantamento do salário');
      expect(adiant.text, isNot(contains('dívida')));
    });

    test('comentários e planos novos', () {
      expect(chat().send('a vida tá cara demais').route, 'comment:mood');
      expect(chat().send('preciso controlar melhor meus gastos').route, 'comment:resolution');
      expect(chat().send('acho que o ifood tá me quebrando').route, 'comment:worry');
      final cdb = chat().send('qual a diferença entre cdb e poupança?');
      expect(cdb.route, 'planner:knowledge');
      expect(cdb.text, allOf(contains('CDB'), contains('Poupança')));
      final c = chat();
      expect(c.send('tenho uma dívida de 3 mil no cartão, como eu pago?').route, 'planner:payoff');
      expect(c.send('sim').route, 'planner:debt_created');
    });

    test('"em 3x" e "à vista" logo depois do lançamento', () {
      final c = small();
      c.send('gastei 25 na padaria no débito');
      c.send('não, foi no crédito');
      expect(c.send('em 3x').route, 'edited');
      final t = c.repo.transactions.firstWhere((t) => t.title == 'Padaria');
      expect([t.paymentMethod, t.installments], ['credit_card', 3]);
      final d = small();
      d.send('comprei um fone de 200 no crédito à vista');
      expect(d.send('à vista').route, 'confirm');
    });
  });

  test('dinheiro arredonda o centavo para cima no meio', () {
    expect(CesarText.money(2611.6 / 16), 'R\$ 163,23');
    expect(CesarText.money(163.225), 'R\$ 163,23');
    expect(CesarText.money(-0.001), 'R\$ 0,00');
    expect(CesarText.money(-200.3), '-R\$ 200,30');
    expect(CesarText.money(1400), 'R\$ 1.400,00');
  });
}
