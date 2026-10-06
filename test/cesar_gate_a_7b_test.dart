// Corretor, Portão do lote A, etapa 7b (PLANO_CESAR.md): valores/multi, datas,
// rascunho e resolvedor — achados de docs/qa/findings-aceite-lote-a.md (ACC-A-*)
// e docs/qa/findings-caos-lote-a.md (CHAOS-A-*). As frases daqui são NOVAS (não
// estão nos achados nem nas baterias): provam que as regras estruturais
// generalizam e que, na dúvida, o César pergunta em vez de gravar errado.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/temporal_date_parser.dart';
import 'package:krezio_ai/ai/transaction_command_parser.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  int offsetTo(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(today().year, today().month, today().day)).inDays;

  /// Dias até o último [weekday] (1–7 dias atrás), como o César lê "segunda".
  int lastWeekday(int weekday) {
    var back = (today().weekday - weekday) % 7;
    if (back == 0) back = 7;
    return -back;
  }

  /// "dia N" do mês passado.
  int dayOfLastMonth(int n) => offsetTo(DateTime(today().year, today().month - 1, n));

  /// Resposta [text] a um rascunho pendente, como o chat decide.
  FinancialTransactionDraft turn(FinancialTransactionDraft pending, String text) =>
      engine.startsNewTransaction(pending, text) ? engine.parse(text) : engine.mergeDrafts(pending, text);

  /// 2+ valores monetários nunca viram menos lançamentos em silêncio: ou o
  /// lote tem todos, ou a frase pergunta ("split").
  void expectAllValuesOrAsk(String p, List<double> values) {
    final multi = engine.parseMulti(p);
    if (multi.length >= 2) {
      expect(multi.map((d) => d.amount).toList()..sort(), [...values]..sort(), reason: p);
    } else {
      final d = engine.parse(p);
      expect(d.isComplete, isFalse, reason: '$p → ${d.amount} ${d.missingSlots}');
    }
  }

  // ───────────────────────────── A) valores / multi ─────────────────────────────

  group('ACC-A-012 / CHAOS-A-018 / CHAOS-A-010: o valor não some perto de "dia N", "N dias atrás", "dd/mm", "mês passado"', () {
    final cases = <String, (double, int?)>{
      'comprei um casaco de 240 dia 3 no pix': (240, null),
      'paguei o condomínio de 780 dia 10 no boleto': (780, null),
      'gastei 45 dia 2 na lavanderia no débito': (45, null),
      'gastei no dia 4 90 no petshop no pix': (90, null),
      'paguei 64 2 dias atrás na farmácia no pix': (64, -2),
      'gastei 18 10 dias atrás no estacionamento no pix': (18, -10),
      'recebi 300 12/09 de consultoria no pix': (300, null),
      'paguei 150 05/09 no dentista no débito': (150, null),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value.$1, reason: '${d.amount} ${d.missingSlots} ${d.clarificationPrompt}');
        expect(d.missingSlots, isNot(contains('amount')));
        expect(d.missingSlots, isNot(contains('split')));
        if (e.value.$2 != null) expect(d.dateOffsetDays, e.value.$2);
      });
    }
    test('"dd/mm" colado ao valor é a data, não o valor', () {
      final d = engine.parse('recebi 300 12/09 de consultoria no pix');
      expect(d.dateOffsetDays, offsetTo(DateTime(today().month > 9 || (today().month == 9 && today().day >= 12) ? today().year : today().year - 1, 9, 12)));
    });
    // CHAOS-A-004 (cadeia): "N mês passado" não é duração — o valor fica e o dia é perguntado.
    for (final p in ['a vizinha me pagou 80 mês passado pela costura no pix', 'meu cliente pagou 450 mês passado do site no pix']) {
      test('mês passado: $p', () {
        final d = engine.parse(p);
        expect(d.amount, isNotNull, reason: d.clarificationPrompt);
        expect(d.intent, 'income');
        expect(d.missingSlots, contains('date'));
        expect(d.isComplete, isFalse);
      });
    }
  });

  group('ACC-A-006: número com unidade (ml, l, kg, g) não é preço', () {
    const cases = {
      'comprei 2 garrafas de 2l por 18 no pix': 18.0,
      'comprei 4 pacotes de 500g por 32 no dinheiro': 32.0,
      'peguei 6 latinhas de 350ml por 24 no débito': 24.0,
      'comprei 3 potes de 1kg por 45 no pix': 45.0,
      'levei 2 galões de 5 litros por 16 no dinheiro': 16.0,
      // controle: quantidade × preço unitário continua valendo
      'comprei 3 cervejas de 12 no pix': 36.0,
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value, reason: '${d.missingSlots} ${d.clarificationPrompt}');
        expect(d.missingSlots, isNot(contains('split')));
      });
    }
  });

  group('ACC-A-014: número de endereço/lugar não é um 2º valor', () {
    const cases = {
      'gastei 35 na padaria da rua 9 no pix': 35.0,
      'paguei 25 de estacionamento no bloco 4 no débito': 25.0,
      'paguei 40 de táxi até o portão 3 no pix': 40.0,
      'paguei 55 no salão da quadra 4 no pix': 55.0,
      'gastei 70 no restaurante do piso 2 no débito': 70.0,
      'gastei 30 na banca da praça 5 no dinheiro': 30.0,
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value);
        expect(d.missingSlots, isNot(contains('split')), reason: d.clarificationPrompt);
        expect(engine.parseMulti(e.key), hasLength(1));
      });
    }
    test('rede de segurança: "no mercado 30 no pix" (segundo valor sem separador) ainda pergunta', () {
      final d = engine.parse('gastei 50 no mercado 30 no pix');
      expect(d.isComplete, isFalse);
      expect(d.missingSlots, contains('split'));
    });
  });

  group('ACC-A-013: "+" e "/" separam itens', () {
    final cases = <String, List<double>>{
      'pão 8 + leite 6 no dinheiro': [8, 6],
      'táxi 35 / pedágio 12 no débito': [35, 12],
      'cinema 40 + pipoca 25 + estacionamento 10 no pix': [40, 25, 10],
      'gastei 30 no açougue + 15 na padaria no pix': [30, 15],
      'farmácia 22 / mercado 60 no pix': [22, 60],
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final multi = engine.parseMulti(e.key);
        expect(multi.map((d) => d.amount).toList(), e.value, reason: multi.map((d) => d.rawText).join(' | '));
        expect(multi.every((d) => d.paymentMethod != 'unknown'), isTrue);
      });
    }
    test('controle: "10/09" continua data (não separa)', () {
      expect(engine.parseMulti('gastei 50 em 10/09 no mercado no pix'), hasLength(1));
    });
  });

  group('ACC-A-005: "depois … mais N", 1º item depois de "hoje:" e "tudo no X"', () {
    final cases = <String, (List<double>, String, int)>{
      'passei na padaria e gastei 12, depois na farmácia mais 30, tudo no pix': ([12, 30], 'pix', 0),
      'gastei 20 no uber, depois mais 45 no restaurante no débito': ([20, 45], 'debit_card', 0),
      'ontem: pedágio 9, estacionamento 15, lanche 22, tudo no pix': ([9, 15, 22], 'pix', -1),
      'hoje: pão 7, leite 5, tudo no dinheiro': ([7, 5], 'cash', 0),
      'gastei 60 no mercado e depois mais 25 na feira no crédito à vista': ([60, 25], 'credit_card', 0),
      'almoço 35, sobremesa 12, tudo no débito': ([35, 12], 'debit_card', 0),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final multi = engine.parseMulti(e.key);
        expect(multi.map((d) => d.amount).toList(), e.value.$1, reason: multi.map((d) => d.rawText).join(' | '));
        for (final d in multi) {
          expect(d.paymentMethod, e.value.$2, reason: d.rawText);
          expect(d.dateOffsetDays, e.value.$3, reason: d.rawText);
        }
      });
    }
  });

  group('CHAOS-A-006: valores iguais e itens sem separador contam', () {
    final cases = <String, List<double>>{
      'gastei 30 na farmácia 30 no mercado no pix': [30, 30],
      'pizza 45 refri 12 no pix': [45, 12],
      'uber 18 lanche 18 no débito': [18, 18],
      'gastei 40 no bar e 40 no restaurante no pix': [40, 40],
      'paguei 25 no cabeleireiro 25 na manicure no dinheiro': [25, 25],
      'recebi 100 do joão 100 da maria no pix': [100, 100],
    };
    for (final e in cases.entries) {
      test(e.key, () => expectAllValuesOrAsk(e.key, e.value));
    }
    test('frase com o mesmo valor repetido e um só lançamento pergunta', () {
      final d = engine.parse('gastei 20 no pastel 20 no caldo de cana no pix');
      if (engine.parseMulti('gastei 20 no pastel 20 no caldo de cana no pix').length < 2) {
        expect(d.missingSlots, contains('split'));
      }
    });
  });

  group('CHAOS-A-007: resposta com 2 números ao "quanto foi?" pergunta qual', () {
    for (final a in ['70 ou 80', 'uns 30 ou 35', 'entre 100 e 120', '45 e 20', 'acho que 60, talvez 65']) {
      test('comprei no açougue no pix ⏎ $a', () {
        final d = turn(engine.parse('comprei no açougue no pix'), a);
        expect(d.isComplete, isFalse, reason: '${d.amount} ${d.missingSlots}');
        expect(d.clarificationPrompt, isNotNull);
      });
    }
    test('depois da pergunta, "80" completa', () {
      final asked = turn(engine.parse('comprei no açougue no pix'), '70 ou 80');
      final d = turn(asked, '80');
      expect(d.isComplete, isTrue, reason: '${d.missingSlots} ${d.clarificationPrompt}');
      expect(d.amount, 80);
    });
    for (final a in {'foi 70': 70.0, 'setenta e cinco': 75.0, 'R\$ 64,90': 64.9}.entries) {
      test('controle: ${a.key}', () {
        final d = turn(engine.parse('comprei no açougue no pix'), a.key);
        expect(d.amount, a.value);
        expect(d.isComplete, isTrue, reason: '${d.missingSlots}');
      });
    }
  });

  // ─────────────────────────────── B) datas ───────────────────────────────

  group('ACC-A-003: "há/faz/tem N dias", com número por extenso', () {
    const cases = {
      'faz três dias paguei 60 no barbeiro no pix': -3,
      'há cinco dias gastei 25 na lotérica no dinheiro': -5,
      'tem 2 dias que recebi 150 de bico no pix': -2,
      'gastei 80 na costureira tem quatro dias no pix': -4,
      'uns três dias atrás paguei 44 de lanche no pix': -3,
      'há dez dias comprei um livro de 55 no débito': -10,
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.dateOffsetDays, e.value, reason: '${d.missingSlots} ${d.clarificationPrompt}');
        expect(d.amount, isNotNull);
      });
    }
  });

  group('ACC-A-004: data futura ou não convertida com certeza → pergunta, não grava', () {
    for (final p in [
      'paguei 90 no mecânico na próxima segunda no pix',
      'recebi 300 de aluguel semana que vem no pix',
      'gastei 120 no dentista mês que vem no débito',
      'comprei um tênis de 200 na semana retrasada no pix',
      'paguei 45 de luz sexta que vem no pix',
      'recebi 500 daqui a 3 dias no pix',
      'gastei 70 no mês retrasado na ótica no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.isComplete, isFalse, reason: 'gravaria com offset ${d.dateOffsetDays}');
        expect(d.missingSlots, contains('date'));
      });
    }
    test('controle: "sexta passada" é data passada e grava', () {
      final d = engine.parse('gastei 30 no mercado sexta passada no pix');
      expect(d.isComplete, isTrue);
      expect(d.dateOffsetDays, lastWeekday(DateTime.friday));
    });
  });

  group('ACC-A-019: "dia N do mês passado" e "N de <mês>"', () {
    final cases = <String, int>{
      'paguei 40 na lavanderia dia 12 do mês passado no pix': dayOfLastMonth(12),
      'recebi 700 de freela no dia 3 do mês passado no pix': dayOfLastMonth(3),
      'gastei 25 no dia 28 do mês passado na farmácia no débito': dayOfLastMonth(28),
      'paguei 15 de estacionamento dia 1 do mês passado no pix': dayOfLastMonth(1),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.isComplete, isTrue, reason: '${d.missingSlots} ${d.clarificationPrompt}');
        expect(d.dateOffsetDays, e.value);
      });
    }
    test('"15 de agosto" é data (passada)', () {
      final d = engine.parse('comprei um fone de 90 em 15 de agosto no pix');
      final y = today().month > 8 || (today().month == 8 && today().day >= 15) ? today().year : today().year - 1;
      expect(d.amount, 90);
      expect(d.dateOffsetDays, offsetTo(DateTime(y, 8, 15)));
    });
  });

  group('CHAOS-A-013: data só com palavra inteira ("totem", "projeto", "objeto")', () {
    final cases = <String, int>{
      'gastei 40 no totem de autoatendimento no pix': 0,
      'paguei 12 no Totem Burger no débito': 0,
      'paguei 300 do projeto ontem no pix': -1,
      'comprei um objeto de 20 anteontem no pix': -2,
      'gastei 9 no totem do cinema no dinheiro': 0,
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.dateOffsetDays, e.value);
      });
    }
    // "fim de semana" sem dizer o dia: grava no sábado e AVISA a data
    // assumida (antes caía em "3 dias atrás" calado; a pergunta que a 7b
    // tentou regrediu a bateria r2). Decisão pendente: perguntar ou assumir.
    int lastSaturday() {
      final w = today().weekday;
      return w == DateTime.saturday ? 0 : (w == DateTime.sunday ? -1 : -(w + 1));
    }
    for (final p in [
      'gastei 200 no mercado no fim de semana no pix',
      'rolou um bico de 180 no fim de semana, caiu no pix',
      'no fds torrei 90 no bar no débito',
      'fim de semana passado paguei 45 de pizza no crédito à vista',
      'recebi 300 de freela no fim de semana no pix',
    ]) {
      test('"fim de semana" assume sábado e avisa: $p', () {
        final d = engine.parse(p);
        expect(d.isComplete, isTrue, reason: '${d.missingSlots} ${d.clarificationPrompt}');
        expect(d.dateOffsetDays, lastSaturday());
        expect(d.assumptionNote, contains('sábado'));
        expect(d.assumptionNote, contains('domingo'));
      });
    }
    test('"foi domingo" corrige a data assumida do fim de semana', () {
      // O aviso ensina "foi domingo": tem de ser uma edição de data no chat.
      final c = TransactionCommandParser.parse('foi domingo', now: DateTime.now(), budgets: const []);
      expect(c?.kind, ChatCommandKind.edit);
      expect(offsetTo(c!.changes.date!), lastWeekday(DateTime.sunday));
    });
    test('"Bar Fim de Semana" (nome) não vira data nem aviso', () {
      final d = engine.parse('gastei 50 no Bar Fim de Semana no pix');
      expect(d.dateOffsetDays, 0);
      expect(d.assumptionNote ?? '', isNot(contains('sábado')));
    });
  });

  group('CHAOS-A-014: "N/M" só é data com cara de data', () {
    for (final p in [
      'paguei a prestação 4/12 de 230 no pix',
      'comprei 1/2 quilo de presunto por 22 no dinheiro',
      'paguei o boleto parcela 2/6 de 180 no pix',
      'comprei 1/4 de queijo por 15 no pix',
      'paguei 60 do episódio 3/8 do curso no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.dateOffsetDays, 0, reason: d.clarificationPrompt);
        expect(d.missingSlots, isNot(contains('date')));
      });
    }
    test('dd/mm ainda à frente vira pergunta, não "ano passado" em silêncio', () {
      final ahead = today().add(const Duration(days: 40));
      final dm = '${ahead.day}/${ahead.month}';
      final d = engine.parse('gastei 50 no mercado em $dm no pix');
      expect(d.isComplete, isFalse);
      expect(d.missingSlots, contains('date'));
    });
    test('controle: "em 10/09"-like passado continua data', () {
      final past = today().subtract(const Duration(days: 12));
      final d = engine.parse('gastei 50 no mercado em ${past.day}/${past.month} no pix');
      expect(d.dateOffsetDays, -12);
    });
  });

  group('CHAOS-A-008: a data dita na resposta vale no merge', () {
    test('foram 40 anteontem', () {
      final d = turn(engine.parse('gastei na feira no pix'), 'foram 40 anteontem');
      expect((d.amount, d.dateOffsetDays, d.isComplete), (40.0, -2, true));
    });
    test('70 ontem', () {
      final d = turn(engine.parse('paguei o chaveiro no dinheiro'), '70 ontem');
      expect((d.amount, d.dateOffsetDays), (70.0, -1));
    });
    test('deu 28 na sexta', () {
      final d = turn(engine.parse('gastei na lanchonete no débito'), 'deu 28 na sexta');
      expect((d.amount, d.dateOffsetDays), (28.0, lastWeekday(DateTime.friday)));
    });
    test('foi 50 há 3 dias', () {
      final d = turn(engine.parse('paguei a manicure no pix'), 'foi 50 há 3 dias');
      expect((d.amount, d.dateOffsetDays), (50.0, -3));
    });
    test('35 depois de amanhã → pergunta', () {
      final d = turn(engine.parse('comprei remédio no pix'), '35 depois de amanhã');
      expect(d.isComplete, isFalse);
      expect(d.missingSlots, contains('date'));
    });
    // Quando César já perguntou "quando foi?", outra data que não dá para
    // gravar recebe a pergunta de data — não "não entendi" pedindo valor,
    // lugar e pagamento que já foram ditos.
    for (final t in [
      ['paguei 90 de luz amanhã no pix', 'depois de amanhã'],
      ['gastei 90 no mercado mês passado no pix', 'depois de amanhã'],
      ['paguei 40 na farmácia próxima sexta no débito', 'semana que vem'],
      ['paguei 25 na padaria amanhã no dinheiro', 'daqui a 2 dias'],
    ]) {
      test('${t[0]} ⏎ ${t[1]} → pergunta a data de novo', () {
        final d = turn(engine.parse(t[0]), t[1]);
        expect(d.isComplete, isFalse);
        expect(d.missingSlots, ['date']);
        expect(d.clarificationPrompt, isNot(contains('Não entendi')));
        expect(d.clarificationPrompt, isNot(contains('forma de pagamento')));
      });
    }
    test('… e a resposta seguinte válida grava', () {
      final asked = turn(turn(engine.parse('paguei 90 de luz amanhã no pix'), 'depois de amanhã'), 'foi ontem');
      expect((asked.amount, asked.dateOffsetDays, asked.isComplete), (90.0, -1, true));
    });
    for (final t in [
      ['gastei no mercado no pix', '60 no fim de semana'],
      ['paguei 90 de luz amanhã no pix', 'foi no fds'],
    ]) {
      test('${t[0]} ⏎ ${t[1]} → sábado, com aviso', () {
        final d = turn(engine.parse(t[0]), t[1]);
        expect(d.isComplete, isTrue);
        expect(d.dateOffsetDays, lessThanOrEqualTo(0));
        expect(d.assumptionNote, contains('sábado'));
      });
    }
    test('controle: só o valor fica hoje', () {
      final d = turn(engine.parse('paguei a manicure no pix'), '50');
      expect((d.amount, d.dateOffsetDays, d.isComplete), (50.0, 0, true));
    });
  });

  group('CHAOS-A-009: a data dita uma vez vale para todos os itens', () {
    final cases = <String, List<int>>{
      'anteontem gastei 20 na padaria e 35 no açougue no pix': [-2, -2],
      'gastei 15 no uber e 22 no lanche no débito ontem': [-1, -1],
      'segunda gastei 12 no café e 30 no almoço no pix': [lastWeekday(DateTime.monday), lastWeekday(DateTime.monday)],
      'ontem gastei 10 no ônibus, 25 no almoço e 8 no café, tudo no pix': [-1, -1, -1],
      'há 4 dias paguei 50 de luz e 70 de água no pix': [-4, -4],
      // datas diferentes por item: cada um a sua
      'gastei 20 ontem no bar e 30 hoje no mercado no pix': [-1, 0],
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final multi = engine.parseMulti(e.key);
        expect(multi.map((d) => d.dateOffsetDays).toList(), e.value, reason: multi.map((d) => d.rawText).join(' | '));
      });
    }
  });

  group('CHAOS-A-020: palavra de data dentro de nome próprio', () {
    for (final p in [
      'gastei 60 no Boteco Sábado no pix',
      'paguei 35 na Padaria Domingo no débito',
      'gastei 40 no Quinta Grill no pix',
      'gastei 25 no Restaurante Dia 10 no pix',
      'almocei 38 no Sabor de Segunda no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.dateOffsetDays, 0);
        expect(d.missingSlots, isNot(contains('date')));
      });
    }
    test('em minúsculas, dia colado ao nome: usa a data, mas avisa', () {
      final d = engine.parse('gastei 70 na pizzaria sábado no pix');
      expect(d.dateOffsetDays, lastWeekday(DateTime.saturday));
      expect(d.assumptionNote, isNotNull);
      expect(d.assumptionNote, contains('sábado'));
    });
    test('controle: "na segunda" é data clara, sem aviso', () {
      final d = engine.parse('gastei 70 no mercado na segunda no pix');
      expect(d.dateOffsetDays, lastWeekday(DateTime.monday));
      expect(d.assumptionNote, isNull);
    });
  });

  // ───────────────────────────── C) rascunho ─────────────────────────────

  group('ACC-A-007 / ACC-A-008 / CHAOS-A-011: frase nova com verbo+objeto próprios substitui o rascunho', () {
    test('paguei o seguro do carro ⏎ comprei um lanche ontem, 18 no pix', () {
      final pending = engine.parse('paguei o seguro do carro');
      expect(engine.startsNewTransaction(pending, 'comprei um lanche ontem, 18 no pix'), isTrue);
      final d = turn(pending, 'comprei um lanche ontem, 18 no pix');
      expect((d.amount, d.dateOffsetDays), (18.0, -1));
    });
    for (final t in [
      ['paguei a academia', 'gastei 14 de sorvete no dinheiro'],
      ['paguei o dentista', 'pedi um açaí de 25 no pix'],
      ['paguei o encanador', 'comprei uma lâmpada de 20 no débito'],
      ['paguei a mensalidade do inglês', 'almocei 32 no shopping no pix'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0]);
        expect(engine.startsNewTransaction(pending, t[1]), isTrue);
      });
    }
    test('multi novo com rascunho pendente não é fundido', () {
      final pending = engine.parse('paguei o uber de ontem');
      expect(engine.startsNewTransaction(pending, 'gastei 30 no cinema e 20 na pipoca no pix'), isTrue);
    });
    // Respostas ao "quanto foi?" continuam completando.
    for (final t in [
      ['paguei a luz', 'paguei 130 no pix', 130.0],
      ['paguei a luz', 'paguei 130 da luz no pix', 130.0],
      ['gastei no mercado', 'gastei 90 lá no débito', 90.0],
    ]) {
      test('resposta: ${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0] as String);
        expect(engine.startsNewTransaction(pending, t[1] as String), isFalse);
        expect(engine.mergeDrafts(pending, t[1] as String).amount, t[2]);
      });
    }
  });

  group('ACC-A-017 / CHAOS-A-016: resposta legítima ao "quanto foi?" completa (número puro nunca é nome de app)', () {
    for (final t in [
      ['paguei o gás', 'saiu 110 no boleto', 110.0],
      ['paguei o condomínio', 'custou 650 no pix', 650.0],
      ['gastei na feira no pix', '99', 99.0],
      ['gastei no açougue no pix', 'deu 99', 99.0],
      ['paguei a internet no pix', 'foi 99,90', 99.9],
      ['gastei no mercado no pix', 'R\$ 99', 99.0],
      ['paguei a escola', 'custou 1200 no boleto', 1200.0],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0] as String);
        expect(engine.startsNewTransaction(pending, t[1] as String), isFalse);
        final d = engine.mergeDrafts(pending, t[1] as String);
        expect(d.amount, t[2]);
        expect(d.category, isNot('transport'));
      });
    }
  });

  group('CHAOS-A-012: frase nova sem valor não responde a pergunta de outro assunto', () {
    for (final t in [
      ['paguei 90 de luz amanhã no pix', 'recebi meu vale'],
      ['gastei 60 no posto', 'a maria me mandou um pix'],
      ['assinei o spotify por 22 no crédito', 'gastei no mercado dia 5 no pix'],
      ['paguei o eletricista', 'comprei pão na padaria'],
      ['gastei 35 no açougue', 'recebi o aluguel da sala'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0]);
        expect(pending.isComplete, isFalse);
        expect(engine.startsNewTransaction(pending, t[1]), isTrue);
      });
    }
    // Respostas de verdade continuam respostas.
    for (final t in [
      ['gastei 60 no posto', 'no pix'],
      ['gastei 45 no pix', 'gastei no mercado'],
      ['assinei o spotify por 22 no crédito', 'dia 5'],
      ['paguei 90 de luz amanhã no pix', 'foi hoje'],
    ]) {
      test('resposta: ${t[0]} ⏎ ${t[1]}', () {
        final pending = engine.parse(t[0]);
        expect(engine.startsNewTransaction(pending, t[1]), isFalse);
      });
    }
  });

  group('Regressão r2: valor antigo ("era 150") não vence o atual ("deu 187")', () {
    // O número depois de um verbo no imperfeito/condicional ("era", "custava",
    // "vinha", "valia", "seria") descreve como as coisas estavam; o fato é o
    // valor do verbo perfectivo ("deu", "veio", "saiu", "ficou").
    for (final t in [
      ['o mercado que era 150 semana passada hoje deu 187, paguei no débito', 187.0],
      ['o mercado que era 150 hoje deu 187, paguei no débito', 187.0],
      ['a feira que custava 60 hoje saiu 75 no pix', 75.0],
      ['o gás vinha 110 e dessa vez veio 130 no pix', 130.0],
      ['a mensalidade que valia 200 ficou 240 no boleto', 240.0],
      ['o corte que era uns 40 hoje deu 55 no dinheiro', 55.0],
      ['a conta de água que costumava ser 80 veio 96 no débito', 96.0],
      ['o uber que seria 30 deu 42 no crédito', 42.0],
    ]) {
      test(t[0] as String, () {
        final d = engine.parse(t[0] as String);
        expect(d.amount, t[1]);
      });
    }
    test('só o valor antigo dito continua sendo o valor', () {
      expect(engine.parse('o almoço era 35 no pix').amount, 35.0);
    });
  });

  // ───────────────────────────── D) resolvedor ─────────────────────────────

  FinancialTransaction tx(String id, String title, double amount, DateTime date, String cat) => FinancialTransaction(
      id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: date);

  Future<(FinancialRepository, CesarAssistant)> seeded(DateTime now, List<FinancialTransaction> seeds) async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    for (final t in seeds) {
      repo.addTransaction(t);
    }
    return (repo, CesarAssistant(repository: repo, engine: engine, now: () => now));
  }

  /// Ordem do chat: comando → pergunta. null = o chat leria como lançamento novo.
  AssistantReply? say(CesarAssistant a, String text) {
    a.beginTurn();
    final c = a.handleCommand(text);
    if (c != null && c.rewrittenInput == null) return c;
    return a.handleQuestion(text);
  }

  String state(FinancialRepository r, List<FinancialTransaction> seeds) => (r.transactions
          .where((t) => seeds.any((s) => s.id == t.id))
          .map((t) => '${t.id}:${t.amount}:${t.paymentMethod}:${t.date.day}/${t.date.month}:${t.title}')
          .toList()
        ..sort())
      .join(',');

  final tue29 = DateTime(2026, 9, 29, 12); // terça
  List<FinancialTransaction> refSeeds() => [
        tx('taxi', 'Táxi', 25, DateTime(2026, 9, 23, 10), 'transport'), // quarta
        tx('horti', 'Hortifruti', 45, DateTime(2026, 9, 26, 10), 'supermarket'), // sábado
        tx('cine', 'Cinema', 40, DateTime(2026, 9, 26, 20), 'leisure'), // sábado
        tx('farm', 'Farmácia', 22, DateTime(2026, 9, 14, 10), 'health'), // segunda
      ];

  group('ACC-A-015: "passa o X pra N" com X existente é edição, não transferência', () {
    // [frase, id que muda (null = nada muda, só sugere), valor novo]
    for (final t in [
      ['passa o táxi de sábado pra 30', null, null], // do achado: não há táxi no sábado
      ['passa o táxi de quarta pra 30', 'taxi', 30.0],
      ['passa a farmácia pra 30', 'farm', 30.0],
      ['passa o cinema pra 55', 'cine', 55.0],
      ['passa o hortifruti de sábado pra 48', 'horti', 48.0],
      ['passa o valor do táxi pra 28', 'taxi', 28.0],
      ['passa o cinema de ontem pra 50', null, null],
    ]) {
      test(t[0] as String, () async {
        final seeds = refSeeds();
        final (repo, a) = await seeded(tue29, seeds);
        final before = state(repo, seeds);
        final r = say(a, t[0] as String);
        expect(r, isNotNull, reason: 'não pode virar rascunho de transferência');
        if (t[1] == null) {
          expect(r!.route, 'not_found');
          expect(state(repo, seeds), before);
        } else {
          expect(r!.route, 'edited');
          expect(repo.transactions.firstWhere((x) => x.id == t[1]).amount, t[2]);
        }
      });
    }
    test('controle: "passa 30 pro joão" (sem lançamento com esse nome) não vira edição', () async {
      final seeds = refSeeds();
      final (repo, a) = await seeded(tue29, seeds);
      final before = state(repo, seeds);
      expect(say(a, 'passa 30 pro joão')?.route, anyOf(isNull, isNot('edited')));
      expect(state(repo, seeds), before);
    });
  });

  group('ACC-A-016: com UMA sugestão, "sim/esse/pode ser" seleciona (exclusão ainda confirma)', () {
    // [pedido, aceite, id, campo esperado]
    for (final t in [
      ['muda o hortifruti de quinta pra 50', 'sim', 'horti', 'amount:50.0'],
      ['o cinema de domingo foi 60', 'esse', 'cine', 'amount:60.0'],
      ['o táxi de sexta foi no débito', 'pode ser', 'taxi', 'pay:debit_card'],
      ['a farmácia do dia 15 foi 30', 'sim', 'farm', 'amount:30.0'],
      // novas
      ['troca o cinema de sexta pra 45', 'isso', 'cine', 'amount:45.0'],
      ['o hortifruti de ontem foi no dinheiro', 'esse mesmo', 'horti', 'pay:cash'],
      ['a farmácia do dia 16 foi 25', 'pode', 'farm', 'amount:25.0'],
      ['corrige o táxi de segunda pra 27', 'sim', 'taxi', 'amount:27.0'],
    ]) {
      test('${t[0]} ⏎ ${t[1]}', () async {
        final seeds = refSeeds();
        final (repo, a) = await seeded(tue29, seeds);
        final before = state(repo, seeds);
        expect(say(a, t[0])!.route, 'not_found');
        expect(state(repo, seeds), before, reason: 'nada muda antes do aceite');
        expect(say(a, t[1])?.route, 'edited');
        final x = repo.transactions.firstWhere((e) => e.id == t[2]);
        final kv = t[3].split(':');
        expect(kv[0] == 'amount' ? '${x.amount}' : x.paymentMethod, kv[1]);
      });
    }
    for (final t in [
      ['apaga o táxi de sexta', 'esse', 'taxi'],
      ['deleta o cinema de quinta', 'sim', 'cine'],
      ['exclui a farmácia do dia 15', 'pode ser', 'farm'],
    ]) {
      test('exclusão confirma: ${t[0]} ⏎ ${t[1]} ⏎ sim', () async {
        final seeds = refSeeds();
        final (repo, a) = await seeded(tue29, seeds);
        expect(say(a, t[0])!.route, 'not_found');
        expect(say(a, t[1])!.route, 'confirm_delete');
        expect(repo.transactions.any((x) => x.id == t[2]), isTrue, reason: 'só apaga depois do "sim" da confirmação');
        expect(say(a, 'sim')!.route, 'deleted');
        expect(repo.transactions.any((x) => x.id == t[2]), isFalse);
      });
    }
  });

  group('CHAOS-A-015: palavra de categoria não seleciona outro título quando a data filtra', () {
    // Posto na terça, Uber na segunda; "gasolina/combustível de segunda" nunca é o Uber.
    for (final now in [
      DateTime(2026, 10, 1, 12),
      DateTime(2027, 3, 1, 12),
      DateTime(2026, 12, 31, 23, 59, 59),
      DateTime(2026, 10, 4, 12),
      DateTime(2026, 10, 5, 12),
    ]) {
      int back(int wd) {
        final d = (now.weekday - wd + 7) % 7;
        return d == 0 ? 7 : d;
      }

      List<FinancialTransaction> seeds() => [
            tx('posto', 'Posto', 150, DateTime(now.year, now.month, now.day - back(DateTime.tuesday), 9), 'transport'),
            tx('uber', 'Uber', 30, DateTime(now.year, now.month, now.day - back(DateTime.monday), 9), 'transport'),
          ];
      for (final p in [
        'muda a gasolina de segunda pra 90',
        'muda o combustível de segunda pra 90',
        'a gasolina de segunda foi 80',
        'o abastecimento de segunda foi no débito',
        'corrige o etanol de segunda pra 70',
      ]) {
        test('${now.day}/${now.month}: $p', () async {
          final s = seeds();
          final (repo, a) = await seeded(now, s);
          final before = state(repo, s);
          final r = say(a, p);
          expect(r?.route, isNot('edited'));
          expect(state(repo, s), before);
          expect(r?.text ?? '', isNot(contains('Uber')));
        });
      }
      test('${now.day}/${now.month}: apaga a gasolina de segunda ⏎ sim não oferece o Uber', () async {
        final s = seeds();
        final (repo, a) = await seeded(now, s);
        final r1 = say(a, 'apaga a gasolina de segunda')!;
        expect(r1.route, isNot('confirm_delete'));
        expect(r1.text, isNot(contains('Uber')));
        final r2 = say(a, 'sim');
        expect(r2?.text ?? '', isNot(contains('Uber')));
        expect(repo.transactions.any((x) => x.id == 'uber'), isTrue);
      });
    }
  });

  group('CHAOS-A-021: título com palavra de data casa pelo título', () {
    List<FinancialTransaction> seeds() => [
          tx('pz', 'Pizzaria Sábado', 70, DateTime(2026, 9, 25, 20), 'leisure'), // sexta
          tx('bar', 'Bar Dia 7', 50, DateTime(2026, 9, 20, 20), 'leisure'),
          tx('burger', 'Sexta Burger', 38, DateTime(2026, 9, 22, 20), 'leisure'), // terça
          tx('padoca', 'Padaria Domingo', 12, DateTime(2026, 9, 24, 8), 'supermarket'), // quinta
        ];
    for (final t in [
      ['muda a pizzaria sábado pra 90', 'pz', 'amount:90.0'],
      ['muda o bar dia 7 pra 90', 'bar', 'amount:90.0'],
      // novas
      ['a pizzaria sábado foi no débito', 'pz', 'pay:debit_card'],
      ['o bar dia 7 foi 65', 'bar', 'amount:65.0'],
      ['corrige o sexta burger pra 42', 'burger', 'amount:42.0'],
      ['a padaria domingo foi 15', 'padoca', 'amount:15.0'],
    ]) {
      test(t[0], () async {
        final s = seeds();
        final (repo, a) = await seeded(tue29, s);
        expect(say(a, t[0])?.route, 'edited');
        final x = repo.transactions.firstWhere((e) => e.id == t[1]);
        final kv = t[2].split(':');
        expect(kv[0] == 'amount' ? '${x.amount}' : x.paymentMethod, kv[1]);
      });
    }
    for (final t in [
      ['apaga a pizzaria sábado', 'Pizzaria Sábado'],
      ['apaga o bar do dia 7', 'Bar Dia 7'],
      ['exclui a padaria domingo', 'Padaria Domingo'],
    ]) {
      test(t[0], () async {
        final (_, a) = await seeded(tue29, seeds());
        final r = say(a, t[0])!;
        expect(r.route, 'confirm_delete');
        expect(r.text, contains(t[1]));
      });
    }
    test('controle: a data ainda filtra quando o título não tem a palavra', () async {
      final s = [...seeds(), tx('pz2', 'Pizzaria Bella', 60, DateTime(2026, 9, 26, 20), 'leisure')];
      final (repo, a) = await seeded(tue29, s);
      expect(say(a, 'muda a pizzaria bella de sábado pra 66')?.route, 'edited');
      expect(repo.transactions.firstWhere((e) => e.id == 'pz2').amount, 66);
      expect(repo.transactions.firstWhere((e) => e.id == 'pz').amount, 70);
    });
  });

  group('r2: "joga fora a feira de segunda" apaga a feira de segunda (com confirmação)', () {
    for (final p in ['joga fora a feira de segunda', 'some com a feira de segunda', 'tira a feira de segunda', 'apaga a feira de segunda-feira']) {
      test(p, () async {
        final s = [
          tx('feira', 'Feira livre', 45, DateTime(2026, 9, 21, 9), 'supermarket'), // segunda retrasada
          tx('padaria', 'Padaria', 20, DateTime(2026, 9, 28, 8), 'supermarket'), // segunda (ontem)
        ];
        final (repo, a) = await seeded(DateTime(2026, 9, 29, 12), s);
        final r = say(a, p)!;
        expect(r.text, isNot(contains('Padaria')));
        if (r.route == 'not_found') say(a, 'sim');
        expect(say(a, 'sim')?.route, 'deleted');
        expect(repo.transactions.any((x) => x.id == 'feira'), isFalse);
        expect(repo.transactions.any((x) => x.id == 'padaria'), isTrue);
      });
    }
  });

  group('CHAOS-A-004 (cadeia): "o chefe pagou 120 mês passado" não perde o valor', () {
    for (final p in [
      'o chefe pagou 120 mês passado do extra no dinheiro',
      'meu patrão pagou 300 mês passado da hora extra no pix',
      'a cliente pagou 95 mês passado da encomenda no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.intent, 'income');
        expect(d.amount, isNotNull);
        expect(d.missingSlots, contains('date'), reason: 'mês passado: pergunta o dia');
      });
    }
    test('cadeia do achado: me obrigaram a pagar 250 de multa ⏎ o chefe pagou 120 mês passado do extra no dinheiro', () {
      final pending = engine.parse('me obrigaram a pagar 250 de multa');
      final d = turn(pending, 'o chefe pagou 120 mês passado do extra no dinheiro');
      expect((d.intent, d.amount), ('income', 120.0));
      expect(d.missingSlots, contains('date'));
    });
  });

  // ───────────────────────────── E) P3 ─────────────────────────────

  group('CHAOS-A-024: "de volta", "de novo", "de graça" não são nome de devedor', () {
    for (final p in [
      'sexta recebi 7 de volta no uber',
      'recebi 12 de volta na farmácia no pix',
      'ganhei 20 de volta da loja no pix',
      'recebi de novo 30 no pix',
      'recebi 10 de graça no app',
      'ontem recebi 9 de volta do ifood no pix',
    ]) {
      test(p, () {
        expect(DebtPaymentParser.parse(p), isNull);
        final d = engine.parse(p);
        expect(d.intent, 'income');
      });
    }
    for (final e in {'recebi 50 de volta do joão': 'João', 'recebi 40 de volta da maria': 'Maria'}.entries) {
      test('controle: ${e.key} ainda é pagamento de ${e.value}', () {
        expect(DebtPaymentParser.parse(e.key)?.personName, e.value);
      });
    }
  });

  group('ACC-A-020: categoria, título e pergunta pelo nome do lugar', () {
    for (final p in ['paguei 130 de consulta no débito', 'paguei 200 na consulta com o dermatologista no pix', 'a consulta deu 180 no crédito à vista']) {
      test('consulta é saúde: $p', () => expect(engine.parse(p).category, 'health'));
    }
    test('comprei material de construção ⏎ paguei 130 de consulta no débito', () {
      final d = turn(engine.parse('comprei material de construção'), 'paguei 130 de consulta no débito');
      expect((d.amount, d.category, d.isComplete), (130.0, 'health', true));
    });
    for (final e in {
      'a mensalidade do pilates é 120, todo dia 5 no pix': 'Pilates',
      'a mensalidade da natação é 150, todo dia 10 no boleto': 'Natação',
    }.entries) {
      test('título: ${e.key}', () => expect(engine.parse(e.key).description, e.value));
    }
    for (final e in {'gastei com o veterinário': 'Veterinário', 'paguei o dentista': 'Dentista', 'gastei com a manicure': 'Manicure'}.entries) {
      test('pergunta pelo nome: ${e.key}', () {
        final q = engine.parse(e.key).clarificationPrompt!;
        expect(q, contains(e.value));
        expect(q, isNot(contains('gastei com')));
      });
    }
    for (final p in [
      'recebi 500 de freela e gastei 120 no mercado, tudo no pix',
      'gastei 30 na padaria e 50 no açougue, tudo no débito',
      'recebi 200 de venda e paguei 80 de luz, tudo no pix',
    ]) {
      test('"tudo no X" vale para todos os itens: $p', () {
        final m = engine.parseMulti(p);
        expect(m.length, 2);
        for (final d in m) {
          expect(d.paymentMethod, isNot('unknown'));
          expect(d.missingSlots, isNot(contains('payment_method')));
        }
      });
    }
  });

  test('SpokenDayParser: "próxima sexta" não é a sexta passada', () {
    final r = SpokenDayParser.parse('paguei na proxima sexta', now: DateTime(2026, 9, 30), allowFuture: true);
    expect(r?.day?.start, DateTime(2026, 10, 2));
  });
}
