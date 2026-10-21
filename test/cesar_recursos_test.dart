import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/financial_calculator.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';

import '_qa/chaos_r3_support.dart';
import 'analytics_test.dart' as a;

/// Recursos novos do César: calculadora financeira, busca com filtros,
/// "por que gastei tanto?", repetidos, o que ele notou, saldo numa data,
/// cancelar assinatura, editar meta e notas nos lançamentos.
void main() {
  late LocalFinancialNlpEngine engine;
  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  // 6 meses de histórico (salário dia 5, aluguel, Netflix e Spotify fixos,
  // mercado, Uber, farmácia, iFood), hoje = 16/10/2026.
  Sim3 chat({List<FinancialGoal> goals = const []}) => Sim3(engine, a.repo(goals: goals), now: () => a.now);

  FinancialTransaction tx(String id, String title, double v, DateTime d, String cat, String pay) =>
      FinancialTransaction(id: id, title: title, amount: v, type: TransactionType.expense, category: cat, paymentMethod: pay, date: d);

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

  group('calculadora', () {
    String? calc(String s) => FinancialCalculator.answer(s)?.text;

    test('porcentagem, desconto, quanto por cento, variação', () {
      expect(calc('quanto é 15% de 230?'), contains('R\$ 34,50'));
      expect(calc('230 com 15% de desconto dá quanto?'), contains('R\$ 195,50'));
      expect(calc('quanto fica 1200 mais 10%?'), contains('R\$ 1.320,00'));
      expect(calc('45 é quantos % de 300?'), contains('15%'));
      expect(calc('a netflix foi de 55,90 pra 59,90, quanto por cento subiu?'), contains('+7,2%'));
    });

    test('juros, à vista × parcelado, quanto rende', () {
      expect(calc('quanto fica 2000 em 12x com juros de 2% ao mês?'), contains('R\$ 189,12'));
      expect(calc('vale mais a pena pagar 1000 à vista com 10% de desconto ou em 10x sem juros?'), contains('à vista sai mais barato'));
      expect(calc('à vista 900 ou 10x de 100, o que compensa?'), contains('R\$ 957,37'));
      expect(calc('se eu investir 200 por mês por 5 anos, quanto vou ter?'), contains('R\$ 15.324,77'));
      expect(calc('se eu guardar 300 por mês durante 2 anos a 1% ao mês quanto junto?'), contains('R\$ 8.092,04'));
      expect(calc('quanto rende 10 mil em 2 anos?'), contains('R\$ 12.107,45'));
      expect(calc('quanto é 1250 dividido por 4?'), contains('312,50'));
      expect(calc('quanto é 37 vezes 12?'), contains('444'));
    });

    test('não é conta: lançamentos e perguntas sobre os dados', () {
      for (final p in ['gastei 15% do salário no mercado', 'gastei 50 no mercado no pix', 'quanto gastei esse mês?', 'paguei 230 com 15% de desconto no pix']) {
        expect(FinancialCalculator.answer(p), isNull, reason: p);
      }
      expect(chat().send('vale a pena comprar um celular de 2000 à vista com 5% de desconto ou em 10x?').route, 'calc');
    });
  });

  group('busca', () {
    test('valor, forma de pagamento, nome e período', () {
      final c = small();
      final big = c.send('mostra os gastos acima de 100 esse mês');
      expect(big.route, 'report:search');
      expect(big.text, contains('Posto Shell'));
      expect(big.text, isNot(contains('iFood')), reason: 'R\$ 41,50 está abaixo do filtro');
      final ifood = small().send('quais compras eu fiz no ifood?');
      expect(ifood.text, contains('iFood'));
      expect(ifood.text, isNot(contains('Cinemark')), reason: 'o nome filtra pelo título, não pela categoria');
      expect(small().send('o que eu paguei no pix essa semana?').route, 'report:search');
      expect(small().send('quais gastos entre 50 e 200 esse mês?').text, allOf(contains('Posto Shell'), contains('Farmácia'), isNot(contains('iFood'))));
    });

    test('refinar: "e no débito?"', () {
      final c = small();
      c.send('mostra os gastos acima de 50');
      final debit = c.send('e no débito?');
      expect(debit.route, 'report:search');
      expect(debit.text, allOf(contains('Posto Shell'), isNot(contains('Cinemark'))));
    });

    test('lançamento com "mais de" continua lançamento', () {
      expect(small().send('gastei mais de 100 no mercado ontem no pix').route, isNot('report:search'));
    });
  });

  group('entender os dados', () {
    test('"por que gastei tanto?", o que notou, repetidos', () {
      expect(chat().send('por que eu gastei tanto esse mês?').route, 'advice:why');
      expect(chat().send('o que aconteceu com meu dinheiro esse mês?').route, 'advice:why');
      final notes = chat().send('o que você notou nos meus gastos?');
      expect(notes.route, 'advice:insights');
      expect(notes.text, contains('O que eu notei'));
      final c = small();
      expect(c.send('tem algum lançamento duplicado?').text, contains('Não achei'));
      c.send('gastei 40 no mercado no pix');
      c.send('gastei 40 no mercado no pix');
      final dup = c.send('lancei alguma coisa duas vezes?');
      expect(dup.route, 'advice:duplicates');
      expect(dup.text, contains('apaga o #'));
    });

    test('saldo numa data: dia 25, quando cair o salário', () {
      final day = chat().send('quanto vou ter dia 25?');
      expect(day.route, 'advice:balance_on');
      expect(day.text, contains('25/10'));
      final salary = chat().send('quanto eu vou ter quando cair o salário?');
      expect(salary.text, contains('05/11'));
      expect(chat().send('quero ter uma casa própria').route, isNot('advice:balance_on'));
    });
  });

  group('assinaturas', () {
    test('"cancelei a netflix" tira dos fixos depois do sim; "desfaz" volta', () {
      final c = chat();
      bool netflixFixed() {
        final list = c.repo.transactions.where((t) => t.title == 'Netflix').toList()..sort((x, y) => y.date.compareTo(x.date));
        return list.first.isRecurrent;
      }

      expect(netflixFixed(), isTrue);
      expect(c.send('cancelei a netflix').route, 'planner:cancel_subscription_ask');
      expect(c.send('sim').route, 'planner:cancel_subscription');
      expect(netflixFixed(), isFalse);
      c.send('desfaz');
      expect(netflixFixed(), isTrue);
      final no = chat();
      no.send('cancela a assinatura do spotify');
      expect(no.send('não').route, 'planner:cancel');
    });

    test('"cancela aquele ifood de 41,50" continua apagando o lançamento', () {
      expect(small().send('cancela aquele ifood de 41,50').route, 'confirm_delete');
    });
  });

  group('metas', () {
    List<FinancialGoal> trip() => [
          FinancialGoal(id: 'g1', title: 'Viagem', targetAmount: 10000, savedAmount: 2000, targetDate: DateTime(2027, 8, 31), createdAt: DateTime(2026, 7, 16)),
        ];

    test('valor, prazo e nome por chat, com desfazer', () {
      final c = chat(goals: trip());
      expect(c.send('aumenta a meta da viagem pra 12 mil').route, 'planner:goal_edited');
      expect(c.repo.goals.single.targetAmount, 12000);
      c.send('desfaz');
      expect(c.repo.goals.single.targetAmount, 10000);
      final d = chat(goals: trip());
      d.send('adia a meta da viagem pra dezembro de 2027');
      expect([d.repo.goals.single.targetDate!.year, d.repo.goals.single.targetDate!.month], [2027, 12]);
      final r = chat(goals: trip());
      r.send('renomeia a meta da viagem pra Viagem pra Europa');
      expect(r.repo.goals.single.title, 'Viagem pra Europa');
      expect(chat(goals: trip()).send('muda o prazo da meta do carro pra julho').route, 'planner:goal_not_found');
    });
  });

  group('notas', () {
    test('anotar, achar pela busca e ver no lançamento', () {
      final c = small();
      final r = c.send('anota no posto de ontem: viagem pra praia');
      expect(r.route, 'note_added');
      expect(c.repo.transactions.firstWhere((t) => t.id == 'posto').notes, 'viagem pra praia');
      expect(c.send('quais gastos com praia?').text, contains('Posto Shell'));
      expect(c.send('quanto foi o posto?').text, contains('viagem pra praia'));
    });

    test('"nesse" é o último; "desfaz" tira a nota; frase de lançamento continua lançamento', () {
      final c = small();
      c.send('gastei 80 na farmácia no pix');
      expect(c.send('anota nesse: remédio da minha mãe').route, 'note_added');
      final farm = c.repo.transactions.firstWhere((t) => t.amount == 80);
      expect(farm.notes, 'remédio da minha mãe');
      c.send('desfaz');
      expect(c.repo.transactions.firstWhere((t) => t.amount == 80).notes, isNull);
      final d = small();
      expect(d.send('anota no caderno: gastei 50 na padaria no pix').route, 'saved');
    });
  });
}
