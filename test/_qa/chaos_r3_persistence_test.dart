// Teste do caos, rodada 3 (cesar-chaos) — persistência no meio de fluxos pendentes.
//
// NÃO falha a suíte: imprime com o prefixo `CHAOS-R3|`. Violações: `CHAOS-R3|VIOL|`.
//   flutter test test/_qa/chaos_r3_persistence_test.dart 2>&1 | grep "CHAOS-R3|"
//
// Repositório real sobre SharedPreferences mockado. "Reinício" = flush das
// gravações + FinancialRepository novo + initialize() + chat novo (a conversa
// não sobrevive ao reinício no app). Também: snapshot da nuvem e edição/
// exclusão pela tela de Extrato entre a pergunta do César e a resposta.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chaos_r3_support.dart';

int violations = 0;
void viol(String id, String msg) {
  violations++;
  print('CHAOS-R3|VIOL| $id: $msg');
}

String st(FinancialRepository r) =>
    r.transactions.where((t) => !t.id.startsWith('init-')).map((t) => '${t.title}:${t.amount.toStringAsFixed(0)}@${CesarText.ddmm(t.date)}/${t.paymentMethod}').join(', ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 12);
  List<FinancialTransaction> base() => [
        FinancialTransaction(id: 'p-feira', title: 'Feira', amount: 80, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: today.subtract(const Duration(days: 3))),
        FinancialTransaction(id: 'p-padaria', title: 'Padaria', amount: 25, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: today.subtract(const Duration(days: 1))),
        FinancialTransaction(id: 'p-uber', title: 'Uber', amount: 30, type: TransactionType.expense, category: 'transport', paymentMethod: 'pix', date: today.subtract(const Duration(days: 2))),
      ];

  Future<FinancialRepository> boot() async {
    final r = FinancialRepository();
    await r.initialize();
    return r;
  }

  Future<FinancialRepository> restart(FinancialRepository old) async {
    await old.flushPendingWrites();
    final mem = Snap3.of(old);
    final r = await boot();
    final disk = Snap3.of(r);
    if (!mem.sameAll(disk)) viol('persistencia', 'memória ≠ disco depois do reinício: ${mem.diff(disk, withOverrides: true)}');
    return r;
  }

  /// Passos: String = mensagem no chat; '⟲reinício'; '⟲nuvem'; ou função sobre o repositório (Extrato).
  Future<void> scenario(String name, List<Object> steps, bool Function(FinancialRepository r, List<R3Reply> replies) ok, String expectation) async {
    SharedPreferences.setMockInitialValues({});
    var repo = await boot();
    for (final t in base()) {
      repo.addTransaction(t);
    }
    var sim = Sim3(engine, repo);
    final replies = <R3Reply>[];
    final log = <String>[];
    try {
      for (final s in steps) {
        if (s == '⟲reinício') {
          repo = await restart(repo);
          sim = Sim3(engine, repo);
          log.add('⟲reinício');
        } else if (s == '⟲nuvem') {
          repo.replaceAllFromCloud(
              transactions: repo.transactions.toList(),
              reminders: repo.reminders.toList(),
              budgets: repo.budgets.toList(),
              goals: repo.goals.toList(),
              categoryOverrides: Map.of(repo.categoryOverrides));
          log.add('⟲nuvem');
        } else if (s is String) {
          final r = sim.send(s);
          replies.add(r);
          log.add('"$s" → ${r.short}');
        } else if (s is void Function(FinancialRepository)) {
          s(repo);
          log.add('(Extrato) ${st(repo)}');
        }
        final inv = repoInvariants(repo);
        if (inv.isNotEmpty) viol('invariante', '$name: $inv');
      }
      repo = await restart(repo);
    } catch (e, stack) {
      viol('excecao', '$name: $e ${stack.toString().split('\n').take(2).join(' | ')}');
    }
    final good = ok(repo, replies);
    print('CHAOS-R3|PERSIST| ${good ? 'ok   ' : 'FALHA'} $name: ${log.join(' ⏎ ')} || ${st(repo)}');
    if (!good) viol('persist', '$name — esperado: $expectation; obtido: ${st(repo)}');
  }

  bool has(FinancialRepository r, String id) => r.transactions.any((t) => t.id == id);
  FinancialTransaction? get(FinancialRepository r, String id) => r.transactions.where((t) => t.id == id).firstOrNull;
  int added(FinancialRepository r) => r.transactions.where((t) => !t.id.startsWith('init-') && !t.id.startsWith('p-')).length;

  test('CHAOS-R3 persistência com fluxo pendente', () async {
    await scenario('P1 confirmação pendente ⏎ reinício ⏎ sim', ['apaga a feira', '⟲reinício', 'sim'],
        (r, _) => has(r, 'p-feira'), 'o "sim" depois do reinício não apaga nada');
    await scenario('P2 confirmação ⏎ sim ⏎ reinício', ['apaga a feira', 'sim', '⟲reinício'], (r, _) => !has(r, 'p-feira'), 'a exclusão persiste');
    await scenario('P3 confirmação ⏎ sim ⏎ reinício ⏎ desfaz', ['apaga a feira', 'sim', '⟲reinício', 'desfaz'],
        (r, rep) => !has(r, 'p-feira') && rep.last.route.startsWith('undo'), 'desfazer não existe mais (pilha é da conversa); feira continua apagada');
    await scenario('P4 pergunta de categoria ⏎ reinício ⏎ resposta', ['gastei 50 na loja do zé no pix', '⟲reinício', 'mercado'],
        (r, _) => added(r) == 0, 'nada salvo: o rascunho não sobrevive e "mercado" sozinho não vira lançamento');
    await scenario('P5 pergunta de pagamento ⏎ reinício ⏎ "no pix"', ['gastei 50 no mercado', '⟲reinício', 'no pix'],
        (r, _) => added(r) == 0, 'nada salvo');
    await scenario('P6 pergunta de valor ⏎ reinício ⏎ "50"', ['gastei no mercado no pix', '⟲reinício', '50'],
        (r, _) => added(r) == 0, 'nada salvo (um "50" solto não vira lançamento sem contexto)');
    await scenario('P7 multi pendente ⏎ reinício ⏎ "pix"', ['gastei 50 na feira e 30 na padaria', '⟲reinício', 'pix'],
        (r, _) => added(r) == 0, 'nada salvo');
    await scenario('P8 escolha pendente ⏎ reinício ⏎ "1"', ['apaga a feira', 'não', 'gastei 80 na feira no pix', 'apaga a feira', '⟲reinício', '1', 'sim'],
        (r, _) => r.transactions.where((t) => t.title == 'Feira').length == 2, 'nada apagado');
    await scenario('P9 confirmação ⏎ nuvem ⏎ sim', ['apaga a feira', '⟲nuvem', 'sim'], (r, _) => has(r, 'p-feira'), 'snapshot da nuvem zera a pendência');
    await scenario('P10 confirmação ⏎ Extrato muda o valor ⏎ sim ⏎ desfaz', [
      'apaga a feira',
      (FinancialRepository r) => r.updateTransaction(get(r, 'p-feira')!.copyWith(amount: 85)),
      'sim',
      'desfaz',
    ], (r, _) => get(r, 'p-feira')?.amount == 85, 'desfazer devolve a versão atual (85), não a de antes da edição no Extrato (80)');
    await scenario('P11 confirmação ⏎ Extrato apaga o mesmo ⏎ sim ⏎ desfaz', [
      'apaga a feira',
      (FinancialRepository r) => r.deleteTransaction('p-feira'),
      'sim',
      'desfaz',
    ], (r, rep) => !has(r, 'p-feira') && !rep[1].text.startsWith('Pronto, apaguei'),
        'não diz "apaguei" algo que já não existia, e o desfaz não ressuscita o que o usuário apagou no Extrato');
    await scenario('P12 "o que mudar?" ⏎ Extrato muda o valor ⏎ "foi no débito"', [
      'edita a feira',
      (FinancialRepository r) => r.updateTransaction(get(r, 'p-feira')!.copyWith(amount: 85)),
      'foi no débito',
    ], (r, _) => get(r, 'p-feira')?.amount == 85 && get(r, 'p-feira')?.paymentMethod == 'debit_card', 'muda só a forma de pagamento; o valor 85 do Extrato fica');
    await scenario('P13 escolha ⏎ Extrato apaga a opção 1 ⏎ "1" ⏎ sim', [
      'gastei 81 na feira no pix',
      'apaga a feira',
      (FinancialRepository r) => r.deleteTransaction(r.transactions.firstWhere((t) => t.title == 'Feira' && t.amount == 81).id),
      '1',
      'sim',
      'desfaz',
    ], (r, _) => !r.transactions.any((t) => t.title == 'Feira' && t.amount == 81), 'a opção apagada no Extrato não volta');
    await scenario('P14 correção ou novo? ⏎ reinício ⏎ "correção"', ['gastei 40 no mercado no pix', 'na verdade gastei 45 no mercado no pix', '⟲reinício', 'correção'],
        (r, _) => r.transactions.where((t) => t.title == 'Mercado').length == 1, 'nada muda');
    await scenario('P15 categoria corrigida persiste a memória ⏎ reinício ⏎ lançar igual', ['gastei 40 no mercado do zé no pix', 'esse era lazer', '⟲reinício', 'gastei 30 no mercado no pix'],
        (r, _) => true, '(observação: memória de categoria sobrevive ao reinício)');
    await scenario('P16 desfazer tudo ⏎ reinício', ['gastei 40 no mercado no pix', 'muda pra 45', 'apaga o último', 'sim', 'desfaz', 'desfaz', 'desfaz', '⟲reinício'],
        (r, _) => added(r) == 0, 'volta a zero e fica assim no disco');
    await scenario('P17 20 lançamentos sem flush intermediário ⏎ reinício', [for (var i = 0; i < 20; i++) 'gastei ${10 + i} no mercado no pix', '⟲reinício'],
        (r, _) => added(r) == 20, '20 no disco');
    await scenario('P18 limpar histórico com confirmação pendente ⏎ sim', [
      'apaga a feira',
      (FinancialRepository r) => r.clearAllData(),
      'sim',
    ], (r, rep) => rep.last.route != 'deleted', 'o "sim" não confirma nada depois da limpeza');
    await scenario('P19 categoria apagada pendente ⏎ reinício ⏎ sim', ['cria a categoria pets', 'apaga a categoria pets', '⟲reinício', 'sim'],
        (r, _) => r.budgets.any((b) => b.category == 'pets'), 'Pets continua');
    print('CHAOS-R3|TOTAL| violações nesta bateria: $violations');
  });
}
