import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/category_command_parser.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CategoryCommandParser (FEAT-005/006)', () {
    test('criar, com e sem limite, mantendo a grafia', () {
      final a = CategoryCommandParser.parse('cria uma categoria chamada viagens')!;
      expect(a.kind, CategoryCommandKind.create);
      expect(a.name, 'Viagens');
      expect(a.limit, isNull);
      final b = CategoryCommandParser.parse('cria a categoria Pets com limite de 200')!;
      expect(b.name, 'Pets');
      expect(b.limit, 200);
      expect(CategoryCommandParser.parse('crie uma nova categoria de Presentes')!.name, 'Presentes');
      expect(CategoryCommandParser.parse('cria a categoria Educação dos filhos com limite de mil reais')!.limit, 1000);
    });

    test('renomear, apagar, mover tudo', () {
      final r = CategoryCommandParser.parse('renomeia a categoria pets para animais')!;
      expect(r.kind, CategoryCommandKind.rename);
      expect(r.name, 'pets');
      expect(r.target, 'Animais');
      expect(CategoryCommandParser.parse('muda o nome da categoria Pets para Bichos')!.target, 'Bichos');
      expect(CategoryCommandParser.parse('apaga a categoria pets')!.kind, CategoryCommandKind.delete);
      final m = CategoryCommandParser.parse('move tudo de pets para animais')!;
      expect(m.kind, CategoryCommandKind.moveAll);
      expect(m.target, 'animais');
    });

    test('limite de orçamento em várias formas', () {
      for (final e in {
        'meu limite de lazer é 800 por mês': 800.0,
        'define orçamento de mercado em 1000': 1000.0,
        'aumenta o limite de mercado pra 1500': 1500.0,
        'o orçamento de transporte agora é 300 reais': 300.0,
        'quero gastar no máximo 500 com lazer': 500.0,
      }.entries) {
        final c = CategoryCommandParser.parse(e.key);
        expect(c?.kind, CategoryCommandKind.setLimit, reason: e.key);
        expect(c!.limit, e.value, reason: e.key);
      }
      expect(CategoryCommandParser.parse('meu limite de lazer é 800 por mês')!.name, 'lazer');
    });

    test('não dispara em lançamentos nem perguntas', () {
      for (final p in ['gastei 50 no mercado', 'quanto ainda posso gastar com lazer?', 'posso gastar 300 no mercado?', 'esse era lazer',
        'apaga o uber', 'paguei a fatura do cartão, estourou o limite', 'criei coragem e gastei 200 na loja']) {
        expect(CategoryCommandParser.parse(p), isNull, reason: p);
      }
    });
  });

  group('Categorias e orçamentos pelo chat (assistente)', () {
    late LocalFinancialNlpEngine engine;
    setUpAll(() async {
      engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    });

    Future<(FinancialRepository, CesarAssistant)> fresh() async {
      SharedPreferences.setMockInitialValues({});
      final repo = FinancialRepository();
      await repo.clearAllData();
      return (repo, CesarAssistant(repository: repo, engine: engine));
    }

    AssistantReply? say(CesarAssistant a, String t) {
      a.beginTurn();
      return a.handleCommand(t) ?? a.handleQuestion(t);
    }

    test('cria categoria e desfaz', () async {
      final (repo, a) = await fresh();
      final r = say(a, 'cria uma categoria chamada viagens')!;
      expect(r.route, 'category_created');
      expect(repo.budgets.any((b) => b.name == 'Viagens'), isTrue);
      expect(repo.getProactiveAlerts().where((x) => x.message.contains('Viagens')), isEmpty, reason: 'sem limite não é estouro');
      say(a, 'desfaz');
      expect(repo.budgets.any((b) => b.name == 'Viagens'), isFalse);
    });

    test('renomeia categoria própria; padrão é protegida', () async {
      final (repo, a) = await fresh();
      repo.addBudgetCategory('Pets', 200);
      expect(say(a, 'renomeia a categoria pets para animais')!.route, 'category_renamed');
      expect(repo.budgets.any((b) => b.name == 'Animais'), isTrue);
      expect(say(a, 'renomeia a categoria lazer para diversão')!.text, contains('categoria padrão'));
    });

    test('apagar categoria pede confirmação', () async {
      final (repo, a) = await fresh();
      repo.addBudgetCategory('Pets', 200);
      expect(say(a, 'apaga a categoria pets')!.route, 'confirm_delete');
      expect(repo.findCustomCategoryCode('pets'), isNotNull);
      expect(say(a, 'sim')!.route, 'category_deleted');
      expect(repo.findCustomCategoryCode('pets'), isNull);
      say(a, 'desfaz');
      expect(repo.findCustomCategoryCode('pets'), isNotNull);
    });

    test('define orçamento e responde o saldo do orçamento', () async {
      final (repo, a) = await fresh();
      repo.addTransaction(FinancialTransaction(
          id: 'x', title: 'Cinema', amount: 100, type: TransactionType.expense, category: 'leisure', paymentMethod: 'pix', date: DateTime.now()));
      final r = say(a, 'meu limite de lazer é 800 por mês')!;
      expect(r.route, 'budget_set');
      expect(r.text, contains('R\$ 800,00'));
      expect(r.text, contains('R\$ 700,00'));
      expect(repo.budgets.firstWhere((b) => b.category == 'leisure').monthlyLimit, 800);
      expect(say(a, 'quanto ainda posso gastar com lazer?')!.text, contains('R\$ 700,00'));
      say(a, 'desfaz');
      expect(repo.budgets.firstWhere((b) => b.category == 'leisure').monthlyLimit, 600);
    });

    test('move tudo de uma categoria para outra (e desfaz)', () async {
      final (repo, a) = await fresh();
      repo.addBudgetCategory('Pets', 200);
      repo.addBudgetCategory('Animais', 300);
      final pets = repo.findCustomCategoryCode('pets')!;
      repo.addTransaction(FinancialTransaction(id: 'r', title: 'Ração', amount: 90, type: TransactionType.expense, category: pets, paymentMethod: 'pix', date: DateTime.now()));
      expect(say(a, 'move tudo de pets para animais')!.text, contains('Movi 1 lançamento'));
      expect(repo.transactions.single.category, repo.findCustomCategoryCode('animais'));
      say(a, 'desfaz');
      expect(repo.transactions.single.category, pets);
    });
  });
}
