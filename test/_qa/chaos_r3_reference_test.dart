// Teste do caos, rodada 3 (cesar-chaos) — referências ambíguas (nome × data),
// limites de data com relógio injetado, e cadeias de desfazer.
//
// NÃO falha a suíte: imprime com o prefixo `CHAOS-R3|`. Violações: `CHAOS-R3|VIOL|`.
//   flutter test test/_qa/chaos_r3_reference_test.dart 2>&1 | grep "CHAOS-R3|"
//
// Relógio: o CesarAssistant recebe `now` fixo (padrão: terça 2026-09-29 12:00).
// Os registros de referência são gravados com data explícita (não pelo motor),
// então o resultado não depende do dia em que a bateria roda — exceto a seção
// "motor", que usa DateTime.now() (o motor não aceita relógio).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/persistence_service.dart';

import 'chaos_r3_support.dart';

class _NullPersistence extends PersistenceService {
  @override
  Future<bool> hasPersistedData() async => false;
  @override
  Future<void> markSeeded() async {}
  @override
  Future<void> saveTransactions(items) async {}
  @override
  Future<void> saveReminders(items) async {}
  @override
  Future<void> saveBudgets(items) async {}
  @override
  Future<void> saveGoals(items) async {}
  @override
  Future<void> saveCategoryOverrides(Map<String, String> overrides) async {}
  @override
  Future<void> clearAll() async {}
}

int violations = 0;
void viol(String id, String msg) {
  violations++;
  print('CHAOS-R3|VIOL| $id: $msg');
}

FinancialTransaction tx(String id, String title, double amount, DateTime date,
        {String cat = 'supermarket', String pay = 'pix', TransactionType type = TransactionType.expense}) =>
    FinancialTransaction(id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: pay, date: date);

/// Repositório sem o seed de demonstração, só com [txs].
FinancialRepository repoWith(List<FinancialTransaction> txs) {
  final r = FinancialRepository(persistence: _NullPersistence());
  for (final t in r.transactions.toList()) {
    r.deleteTransaction(t.id);
  }
  for (final t in txs) {
    r.addTransaction(t);
  }
  return r;
}

String state(FinancialRepository r) => r.transactions.map((t) => '${t.title}:${t.amount.toStringAsFixed(0)}@${CesarText.ddmm(t.date)}').join(', ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  // ───────────────────────── nome × data ─────────────────────────
  test('CHAOS-R3 referência ambígua nome × data', () {
    final now = DateTime(2026, 9, 29, 12); // terça
    List<FinancialTransaction> base() => [
          tx('feira-sab', 'Feira', 80, DateTime(2026, 9, 26, 10)), // sábado
          tx('feira-ter', 'Feira', 60, DateTime(2026, 9, 22, 10)), // terça passada
          tx('padaria-seg', 'Padaria', 25, DateTime(2026, 9, 28, 8)), // segunda (supermarket)
          tx('posto-seg', 'Posto', 150, DateTime(2026, 9, 28, 18), cat: 'transport'),
          tx('uber-dom', 'Uber', 30, DateTime(2026, 9, 27, 22), cat: 'transport'),
          tx('mercado-31', 'Mercado', 200, DateTime(2026, 8, 31, 9)),
          tx('racao-seg', 'Ração do Thor', 90, DateTime(2026, 9, 28, 9), cat: 'pets'),
        ];

    // Cada caso: frases; o "nome" que o usuário disse; datas aceitáveis (dd/mm) ou vazio.
    final cases = <List<Object>>[
      [['apaga a feira de segunda', 'sim'], 'feira', <String>[]],
      [['apaga a feira de segunda-feira', 'sim'], 'feira', <String>[]],
      [['exclui a feira do dia 28', 'sim'], 'feira', <String>[]],
      [['muda a feira de segunda pra 90'], 'feira', <String>[]],
      [['a feira de segunda foi 90'], 'feira', <String>[]],
      [['a feira de segunda foi no débito'], 'feira', <String>[]],
      [['muda o mercado de segunda pra 10'], 'mercado', <String>[]],
      [['apaga o mercado de segunda', 'sim'], 'mercado', <String>[]],
      [['apaga o uber de segunda', 'sim'], 'uber', <String>[]],
      [['muda o uber de segunda pra 40'], 'uber', <String>[]],
      [['o uber de segunda foi 40'], 'uber', <String>[]],
      [['apaga a gasolina de segunda', 'sim'], 'gasolina', <String>[]],
      [['apaga a farmácia de segunda', 'sim'], 'farmacia', <String>[]],
      [['apaga a feira de terça', 'sim'], 'feira', ['22/09']],
      [['apaga a feira de sábado', 'sim'], 'feira', ['26/09']],
      [['muda a feira do dia 26 pra 85'], 'feira', ['26/09']],
      [['apaga a feira de hoje', 'sim'], 'feira', <String>[]],
      [['apaga a feira', '1', 'sim'], 'feira', ['26/09', '22/09']],
      [['muda a feira pra 70'], 'feira', ['26/09', '22/09']],
      [['apaga o de 80 de segunda', 'sim'], '', <String>[]],
      [['apaga o de 25 de sábado', 'sim'], '', <String>[]],
      [['apaga a padaria de sábado', 'sim'], 'padaria', <String>[]],
      [['apaga o mercado do dia 31', 'sim'], 'mercado', ['31/08']],
      [['apaga o mercado de 31/09', 'sim'], 'mercado', <String>[]],
      [['apaga a ração de segunda', 'sim'], 'racao', ['28/09']],
      [['apaga os pets de segunda', 'sim'], 'pets', ['28/09']],
      [['apaga o thor', 'sim'], 'thor', ['28/09']],
      [['apaga a feira de domingo', 'sim'], 'feira', <String>[]],
      [['apaga a feira de ontem', 'sim'], 'feira', <String>[]],
      [['muda a feira de ontem pra 1'], 'feira', <String>[]],
      [['apaga a feira de semana passada', 'sim'], 'feira', ['22/09', '26/09']],
    ];

    for (final c in cases) {
      final steps = c[0] as List<String>;
      final name = c[1] as String;
      final okDates = c[2] as List<String>;
      final repo = repoWith(base());
      repo.addBudgetCategory('Pets', 200);
      final sim = Sim3(engine, repo, now: () => now);
      final log = <String>[];
      var prevText = '';
      var prevRoute = '';
      for (final st in steps) {
        final before = {for (final t in repo.transactions) t.id: t};
        final r = sim.send(st);
        log.add('"$st" → ${r.short}');
        final after = {for (final t in repo.transactions) t.id: t};
        final removed = before.keys.where((k) => !after.containsKey(k)).map((k) => before[k]!).toList();
        final changed = before.keys.where((k) => after.containsKey(k) && after[k]!.toJson().toString() != before[k]!.toJson().toString()).map((k) => before[k]!).toList();
        bool nameOk(FinancialTransaction t) => name.isEmpty || CesarText.fold(t.title).contains(name);
        bool dateOk(FinancialTransaction t) => okDates.isEmpty || okDates.contains(CesarText.ddmm(t.date));
        if (r.route == 'confirm_delete' || r.route == 'choose') {
          // a confirmação mostra claramente algo que NÃO tem o nome dito?
          final shown = repo.transactions.where((t) => r.text.contains('${t.title} (')).toList();
          for (final t in shown) {
            if (!nameOk(t) && r.route == 'confirm_delete') {
              viol('confirma_outro_nome', '${steps.join(' ⏎ ')} — a confirmação oferece "${t.title}" (${CesarText.ddmm(t.date)}) para o nome "$name": ${r.text.replaceAll('\n', ' ')}');
            }
          }
        }
        for (final t in removed) {
          if (!prevText.contains(t.title) || !prevText.contains(CesarText.money(t.amount)) || prevRoute != 'confirm_delete') {
            viol('apagou_sem_mostrar', '${steps.join(' ⏎ ')} — apagou ${t.title} ${CesarText.money(t.amount)} sem estar na confirmação');
          }
          if (!nameOk(t) || !dateOk(t)) {
            viol('apagou_outro', '${steps.join(' ⏎ ')} — apagou ${t.title} de ${CesarText.ddmm(t.date)} (nome "$name", datas $okDates) — confirmação: "${prevText.replaceAll('\n', ' ')}"');
          }
        }
        for (final t in changed) {
          if (!nameOk(t)) {
            viol('editou_outro_nome', '${steps.join(' ⏎ ')} — sem confirmação, mudou ${t.title} de ${CesarText.ddmm(t.date)} (${CesarText.money(t.amount)} → ${CesarText.money(after[t.id]!.amount)}) para o nome "$name": ${r.text.replaceAll('\n', ' ')}');
          } else if (!dateOk(t) && okDates.isNotEmpty) {
            viol('editou_outra_data', '${steps.join(' ⏎ ')} — mudou ${t.title} de ${CesarText.ddmm(t.date)} (datas pedidas $okDates)');
          }
        }
        prevText = r.text;
        prevRoute = r.route;
      }
      print('CHAOS-R3|REF| ${log.join(' ⏎ ')} || ${state(repo)}');
    }
  });

  // ───────────────────────── limites de data (relógio injetado) ─────────────────────────
  test('CHAOS-R3 limites de data', () {
    void run(String label, DateTime now, List<FinancialTransaction> txs, List<String> steps, bool Function(FinancialRepository, List<R3Reply>) ok, String expectation) {
      final repo = repoWith(txs);
      final sim = Sim3(engine, repo, now: () => now);
      final replies = <R3Reply>[];
      for (final st in steps) {
        replies.add(sim.send(st));
      }
      final good = ok(repo, replies);
      final line = '$label [hoje ${CesarText.ddmm(now)}/${now.year}] ${steps.map((s) => '"$s"').join(' ⏎ ')} → ${replies.map((r) => r.short).join(' ⏎ ')} || ${state(repo)}';
      print('CHAOS-R3|DATE| ${good ? 'ok  ' : 'FALHA'} $line');
      if (!good) viol('data', '$line — esperado: $expectation');
    }

    bool has(FinancialRepository r, String id) => r.transactions.any((t) => t.id == id);
    FinancialTransaction get(FinancialRepository r, String id) => r.transactions.firstWhere((t) => t.id == id);

    // virada de mês: hoje 01/10, setembro tem 30 dias
    final d1 = DateTime(2026, 10, 1, 9);
    final octTx = [tx('m30', 'Mercado', 30, DateTime(2026, 9, 30, 20)), tx('m01', 'Mercado', 45, DateTime(2026, 10, 1, 8)), tx('m31a', 'Mercado', 70, DateTime(2026, 8, 31, 8))];
    run('D1', d1, octTx, ['apaga o mercado do dia 31', 'sim'], (r, _) => has(r, 'm30') && has(r, 'm01') && has(r, 'm31a'), 'dia 31 (set. não tem) não apaga nada');
    run('D2', d1, octTx, ['apaga o mercado de ontem', 'sim'], (r, _) => !has(r, 'm30') && has(r, 'm01'), 'apaga o de 30/09');
    run('D3', d1, octTx, ['muda o mercado do dia 30 pra 5'], (r, _) => get(r, 'm30').amount == 5 && get(r, 'm01').amount == 45, 'muda o de 30/09');
    run('D4', d1, octTx, ['apaga o mercado de 31/08', 'sim'], (r, _) => !has(r, 'm31a') && has(r, 'm30'), 'apaga o de 31/08');
    run('D5', d1, octTx, ['muda o mercado de ontem pra dia 31'], (r, _) => get(r, 'm30').date.month != 10 && get(r, 'm30').date.isBefore(DateTime(2026, 10, 2)), 'não pode ir para 01/10 nem para o futuro');
    run('D6', d1, octTx, ['apaga o mercado do mês passado', 'sim'], (r, _) => has(r, 'm01') && has(r, 'm31a'), 'só o de setembro');
    run('D7', d1, octTx, ['apaga o mercado de 01/10', 'sim'], (r, _) => !has(r, 'm01') && has(r, 'm30'), 'apaga o de hoje');

    final t29 = DateTime(2026, 9, 29, 12);
    final sepTx = [tx('fs', 'Feira', 80, DateTime(2026, 9, 26, 10))];
    run('D8', t29, sepTx, ['muda a data da feira pra 15/12'], (r, _) => !get(r, 'fs').date.isAfter(t29), 'não vai para o futuro (15/12/2026)');
    run('D9', t29, sepTx, ['a feira foi dia 45'], (r, _) => get(r, 'fs').date.day == 26, 'dia 45 não existe: não muda');
    run('D10', t29, sepTx, ['muda a data da feira pra 31/02'], (r, _) => get(r, 'fs').date.day == 26 && get(r, 'fs').date.month == 9, '31/02 não existe: não muda');
    run('D11', t29, sepTx, ['muda a data da feira pra 10/13'], (r, _) => get(r, 'fs').date.month == 9, 'mês 13 não existe: não muda');
    run('D12', t29, sepTx, ['muda a data da feira pra dia 0'], (r, _) => get(r, 'fs').date.day == 26, 'dia 0 não existe: não muda');

    // 29/02 em ano bissexto (2028) e não bissexto (2026, 2027)
    final l1 = DateTime(2028, 3, 1, 10);
    final leap = [tx('f29', 'Feira', 29, DateTime(2028, 2, 29, 9)), tx('f28', 'Feira', 28, DateTime(2028, 2, 28, 9)), tx('f01', 'Feira', 1, DateTime(2028, 3, 1, 8))];
    run('L1', l1, leap, ['apaga a feira de 29/02', 'sim'], (r, _) => !has(r, 'f29') && has(r, 'f28') && has(r, 'f01'), 'apaga 29/02/2028');
    run('L2', l1, leap, ['apaga a feira do dia 29', 'sim'], (r, _) => !has(r, 'f29') && has(r, 'f28'), 'apaga 29/02/2028');
    run('L3', l1, leap, ['apaga a feira de ontem', 'sim'], (r, _) => !has(r, 'f29') && has(r, 'f28'), 'apaga 29/02/2028');
    run('L4', l1, leap, ['apaga a feira de anteontem', 'sim'], (r, _) => !has(r, 'f28') && has(r, 'f29'), 'apaga 28/02/2028');
    run('L5', l1, leap, ['muda a feira de ontem pra 290'], (r, _) => get(r, 'f29').amount == 290 && get(r, 'f28').amount == 28, 'muda 29/02');
    final n1 = DateTime(2027, 3, 1, 10);
    final noLeap = [tx('g28', 'Feira', 28, DateTime(2027, 2, 28, 9)), tx('g01', 'Feira', 1, DateTime(2027, 3, 1, 8)), tx('g29a', 'Feira', 290, DateTime(2027, 1, 29, 9))];
    run('N1', n1, noLeap, ['apaga a feira de 29/02', 'sim'], (r, _) => r.transactions.length == 3, '29/02/2027 não existe: nada apagado');
    run('N2', n1, noLeap, ['apaga a feira do dia 29', 'sim'], (r, _) => r.transactions.length == 3, 'fevereiro/2027 sem dia 29: nada apagado (nem 29/01)');
    run('N3', n1, noLeap, ['apaga a feira do dia 30', 'sim'], (r, _) => r.transactions.length == 3, 'nada apagado');
    run('N4', n1, noLeap, ['apaga a feira de ontem', 'sim'], (r, _) => !has(r, 'g28') && has(r, 'g01'), 'apaga 28/02');
    run('N5', n1, noLeap, ['muda a feira de ontem pra 29/02'], (r, _) => get(r, 'g28').date.day == 28 && get(r, 'g28').date.month == 2, 'data inexistente: não muda');
    run('N6', n1, noLeap, ['a feira de ontem foi dia 30'], (r, _) => get(r, 'g28').date.month == 2 && get(r, 'g28').date.day == 28, 'fev sem 30: não muda');

    // dia 31 e virada de ano
    final y1 = DateTime(2027, 1, 1, 0, 30);
    final ny = [tx('y31', 'Ceia', 310, DateTime(2026, 12, 31, 21)), tx('y01', 'Ceia', 10, DateTime(2027, 1, 1, 0, 10)), tx('y30', 'Uber', 30, DateTime(2026, 12, 30, 23, 59))];
    run('Y1', y1, ny, ['apaga a ceia de ontem', 'sim'], (r, _) => !has(r, 'y31') && has(r, 'y01'), 'apaga 31/12/2026');
    run('Y2', y1, ny, ['apaga a ceia do dia 31', 'sim'], (r, _) => !has(r, 'y31') && has(r, 'y01'), 'apaga 31/12/2026');
    run('Y3', y1, ny, ['apaga a ceia de 31/12', 'sim'], (r, _) => !has(r, 'y31'), 'apaga 31/12/2026');
    run('Y4', y1, ny, ['apaga o uber de anteontem', 'sim'], (r, _) => !has(r, 'y30'), 'apaga 30/12 23:59');
    run('Y5', y1, ny, ['apaga a ceia do mês passado', 'sim'], (r, _) => !has(r, 'y31') && has(r, 'y01'), 'apaga a de dezembro');
    run('Y6', y1, ny, ['apaga a ceia de hoje', 'sim'], (r, _) => !has(r, 'y01') && has(r, 'y31'), 'apaga a de 01/01 00:10');
    run('Y7', y1, ny, ['muda a ceia de ontem pra hoje'], (r, _) => get(r, 'y31').date.year == 2027 || true, '(só observação)');
    run('Y8', y1, ny, ['apaga a ceia da semana passada', 'sim'], (r, _) => has(r, 'y01'), 'não apaga a de hoje');

    // meia-noite: registro às 23:59 de ontem × 00:00 de hoje
    final m1 = DateTime(2026, 9, 29, 0, 0, 5);
    final mid = [tx('ontem2359', 'Lanche', 12, DateTime(2026, 9, 28, 23, 59, 59)), tx('hoje0000', 'Lanche', 13, DateTime(2026, 9, 29, 0, 0, 0))];
    run('M1', m1, mid, ['apaga o lanche de ontem', 'sim'], (r, _) => !has(r, 'ontem2359') && has(r, 'hoje0000'), 'apaga o das 23:59:59');
    run('M2', m1, mid, ['apaga o lanche de hoje', 'sim'], (r, _) => has(r, 'ontem2359') && !has(r, 'hoje0000'), 'apaga o das 00:00');
    run('M3', m1, mid, ['muda o lanche de ontem pra 20'], (r, _) => get(r, 'ontem2359').amount == 20 && get(r, 'hoje0000').amount == 13, 'muda o das 23:59:59');

    // 31 de agosto (hoje é dia 31)
    final a31 = DateTime(2026, 8, 31, 15);
    final aug = [tx('a31', 'Açougue', 95, DateTime(2026, 8, 31, 10)), tx('j31', 'Açougue', 88, DateTime(2026, 7, 31, 10)), tx('a30', 'Açougue', 77, DateTime(2026, 8, 30, 10))];
    run('A1', a31, aug, ['apaga o açougue do dia 31', 'sim'], (r, _) => !has(r, 'a31') && has(r, 'j31'), 'dia 31 = hoje');
    run('A2', a31, aug, ['apaga o açougue de 31/07', 'sim'], (r, _) => !has(r, 'j31') && has(r, 'a31'), '31/07');
    run('A3', a31, aug, ['o açougue do dia 30 foi 70'], (r, _) => get(r, 'a30').amount == 70 && get(r, 'a31').amount == 95, 'muda 30/08');
    run('A4', a31, aug, ['apaga o açougue de 31/08/2025', 'sim'], (r, _) => r.transactions.length == 3, 'ano passado: não existe; nada apagado');
  });

  // ───────────────────────── motor: datas relativas ao salvar (DateTime.now real) ─────────────────────────
  test('CHAOS-R3 motor: data ao lançar', () {
    final today = DateTime.now();
    final t0 = DateTime(today.year, today.month, today.day);
    String dm(DateTime d) => CesarText.ddmm(d);
    final lastDayPrev = DateTime(today.year, today.month, 0);
    for (final p in [
      'gastei 50 no mercado ontem no pix',
      'gastei 50 no mercado anteontem no pix',
      'gastei 50 no mercado dia 31 no pix',
      'gastei 50 no mercado dia 30 no pix',
      'gastei 50 no mercado dia ${today.day + 1 > 31 ? 1 : today.day + 1} no pix',
      'gastei 50 no mercado dia 1 no pix',
      'gastei 50 no mercado dia 29/02 no pix',
      'gastei 50 no mercado dia 31/09 no pix',
      'gastei 50 no mercado dia 31/08 no pix',
      'gastei 50 no mercado em ${dm(t0.add(const Duration(days: 1)))} no pix',
      'gastei 50 no mercado em ${dm(lastDayPrev)} no pix',
      'gastei 50 no mercado segunda no pix',
      'gastei 50 no mercado na segunda-feira no pix',
      'gastei 50 no mercado terça no pix',
      'gastei 50 no mercado sábado passado no pix',
      'gastei 50 no mercado semana passada no pix',
      'gastei 50 no mercado mês passado no pix',
      'gastei 50 no mercado há 3 dias no pix',
      'gastei 50 no mercado amanhã no pix',
      'gastei 50 no mercado dia 0 no pix',
      'gastei 50 no mercado dia 32 no pix',
    ]) {
      final repo = repoWith(const []);
      final sim = Sim3(engine, repo);
      final r = sim.send(p);
      final saved = repo.transactions.map((t) => dm(t.date)).join(',');
      final future = repo.transactions.any((t) => DateTime(t.date.year, t.date.month, t.date.day).isAfter(t0));
      print('CHAOS-R3|ENGDATE| ${future ? 'FUTURO' : 'ok    '} "$p" → ${r.short} || salvo em [$saved] (hoje ${dm(t0)})');
      if (future && !p.contains('amanhã')) viol('data_futura_motor', '"$p" salvou em [$saved] (hoje ${dm(t0)}) sem perguntar');
    }
  });

  // ───────────────────────── cadeias de desfazer ─────────────────────────
  test('CHAOS-R3 desfazer em cadeia', () {
    void chain(String label, List<FinancialTransaction> txs, List<String> steps, {void Function(FinancialRepository)? setup, bool Function(FinancialRepository)? endOk, String? expect}) {
      final repo = repoWith(txs);
      repo.addBudgetCategory('Pets', 200);
      repo.addGoal(FinancialGoal(id: 'g-fone', title: 'Fone', targetAmount: 150, savedAmount: 40));
      setup?.call(repo);
      final sim = Sim3(engine, repo);
      final snaps = <Snap3>[Snap3.of(repo)];
      final lines = <String>[];
      final pushedAt = <int>[]; // índice do snapshot de antes de cada ação empilhada
      for (final st in steps) {
        final before = Snap3.of(repo);
        final lenB = sim.assistant.history.length;
        final lastB = sim.assistant.history.last;
        final r = sim.send(st);
        final after = Snap3.of(repo);
        lines.add('"$st" → ${r.short}');
        if (r.route == 'undo') {
          if (pushedAt.isEmpty) {
            viol('undo_sem_acao', '$label: "$st" desfez algo que a bateria não viu empilhar');
          } else {
            final idx = pushedAt.removeLast();
            if (idx >= 0 && !after.sameData(snaps[idx])) viol('undo_impreciso', '$label: "${steps.join(' ⏎ ')}" — o desfaz nº ${lines.length} deixou: ${snaps[idx].diff(after)}');
          }
        } else {
          var pushes = sim.assistant.history.length - lenB;
          if (pushes == 0 && lenB == 20 && !identical(lastB, sim.assistant.history.last)) pushes = 1;
          if (pushes > 0) {
            pushedAt.add(snaps.length - 1);
            for (var j = 1; j < pushes; j++) {
              pushedAt.add(-1);
            }
          }
          if (pushes < 0) pushedAt.clear();
          while (pushedAt.length > 20) {
            pushedAt.removeAt(0);
          }
          if (pushes == 0 && !before.sameData(after) && sim.assistant.history.length < 20) {
            print('CHAOS-R3|UNDO| $label: "$st" mudou dados sem empilhar');
          }
        }
        snaps.add(after);
        final inv = repoInvariants(repo);
        if (inv.isNotEmpty) viol('invariante', '$label: "$st" → $inv');
      }
      final good = endOk == null || endOk(repo);
      print('CHAOS-R3|UNDO| $label ${good ? 'ok' : 'FALHA'}: ${lines.join(' ⏎ ')} || ${state(repo)} | overrides=${repo.categoryOverrides}');
      if (!good) viol('undo_fim', '$label: ${steps.join(' ⏎ ')} — esperado: $expect; obtido: ${state(repo)}');
    }

    final now = DateTime.now();
    final base = [tx('b1', 'Feira', 80, now.subtract(const Duration(days: 3))), tx('b2', 'Padaria', 25, now.subtract(const Duration(days: 1)))];

    chain('U1 criar→editar→apagar→desfaz×3', base,
        ['gastei 40 no açougue no pix', 'muda pra 45', 'apaga o último', 'sim', 'desfaz', 'desfaz', 'desfaz', 'desfaz'],
        endOk: (r) => r.transactions.length == 2, expect: 'volta ao início (2 registros)');
    chain('U2 editar×2→apagar→desfaz×3', base,
        ['gastei 40 no açougue no pix', 'muda pra 45', 'na verdade foi no débito', 'apaga esse', 'sim', 'desfaz', 'desfaz', 'desfaz'],
        endOk: (r) => r.transactions.any((t) => t.title.toLowerCase().contains('açougue') && t.amount == 40 && t.paymentMethod == 'pix'),
        expect: 'Açougue 40 no Pix');
    chain('U3 apagar registro antigo→editar outro→desfaz×2', base,
        ['apaga a feira', 'sim', 'muda a padaria pra 30', 'desfaz', 'desfaz'],
        endOk: (r) => r.transactions.length == 2 && r.transactions.firstWhere((t) => t.id == 'b2').amount == 25, expect: 'feira de volta e padaria 25');
    chain('U4 25 lançamentos→28 desfaz', base, [
      for (var i = 0; i < 25; i++) 'gastei ${10 + i} no mercado no pix',
      for (var i = 0; i < 28; i++) 'desfaz',
    ], endOk: (r) => r.transactions.length == 2 + 5, expect: 'sobram os 5 primeiros (limite 20)');
    chain('U5 exatamente 20→21 desfaz', base, [
      for (var i = 0; i < 20; i++) 'gastei ${10 + i} no mercado no pix',
      for (var i = 0; i < 21; i++) 'desfaz',
    ], endOk: (r) => r.transactions.length == 2, expect: 'volta ao início');
    chain('U6 21 ações mistas (edições) → 22 desfaz', base, [
      'gastei 10 no mercado no pix',
      for (var i = 0; i < 20; i++) 'muda pra ${11 + i}',
      for (var i = 0; i < 22; i++) 'desfaz',
    ], endOk: (r) => r.transactions.any((t) => t.title.toLowerCase().contains('mercado') && t.amount == 10), expect: 'a loja z volta a 10? (a criação saiu da pilha: fica 10)');
    chain('U7 apagar 3 de uma vez→editar→desfaz×2', base,
        ['gastei 11 no mercado no pix', 'gastei 12 na farmácia no pix', 'gastei 13 no uber no pix', 'apaga os 3 últimos', 'sim', 'muda a feira pra 81', 'desfaz', 'desfaz'],
        endOk: (r) => r.transactions.length == 5, expect: 'as 3 lojas de volta');
    chain('U8 lote de 2 → desfaz (um só?)', base, ['gastei 50 na feira e 30 na padaria no pix', 'desfaz'],
        endOk: (r) => r.transactions.length == 2, expect: 'um "desfaz" desfaz a mensagem inteira (2 lançamentos)');
    chain('U9 diárias → desfaz', base, ['contratei uma diarista pagando 100 o dia durante 3 dias no pix', 'desfaz'],
        endOk: (r) => r.transactions.length == 2, expect: 'remove as 3 diárias');
    chain('U10 categoria corrigida → desfaz → lançar igual', base,
        ['gastei 40 no mercado do zé no pix', 'esse era lazer', 'desfaz', 'gastei 41 no mercado do zé no pix'],
        endOk: (r) => !r.transactions.any((t) => t.amount == 41 && t.category == 'leisure'),
        expect: 'depois de desfazer a troca para Lazer, o próximo "quiosque do zé" não vai para Lazer sem perguntar');
    chain('U11 meta completada → desfaz', base, ['guardei 120 na meta do fone', 'desfaz'],
        endOk: (r) => r.goals.firstWhere((g) => g.id == 'g-fone').savedAmount == 40 && !r.goals.firstWhere((g) => g.id == 'g-fone').isCompleted,
        expect: 'Fone volta a 40, não concluída');
    chain('U12 tirar mais do que tem → desfaz', base, ['tira 100 da meta do fone', 'desfaz'],
        endOk: (r) => r.goals.firstWhere((g) => g.id == 'g-fone').savedAmount == 40, expect: 'Fone volta a 40');
    chain('U13 apagar categoria com lançamentos → desfaz', [...base, tx('p1', 'Ração', 90, now, cat: 'pets')], ['apaga a categoria pets', 'sim', 'desfaz'],
        endOk: (r) => r.budgets.any((b) => b.category == 'pets'), expect: 'Pets de volta com o mesmo código');
    chain('U14 mover tudo → desfaz', [...base, tx('p1', 'Ração', 90, now, cat: 'pets')], ['move tudo de pets para lazer', 'desfaz'],
        endOk: (r) => r.transactions.firstWhere((t) => t.id == 'p1').category == 'pets', expect: 'Ração volta para pets');
    chain('U15 desfaz com exclusão pendente → sim', base, ['gastei 40 no açougue no pix', 'apaga a feira', 'desfaz', 'sim'],
        endOk: (r) => r.transactions.any((t) => t.id == 'b1'), expect: 'o "sim" depois do desfaz não apaga a feira');
    chain('U16 desfaz → refaz? ("desfaz o desfaz")', base, ['gastei 40 no açougue no pix', 'desfaz', 'desfaz o desfaz'],
        endOk: (r) => true, expect: '(observação)');
    chain('U17 editar via Extrato no meio → desfaz', base, ['gastei 40 no açougue no pix', 'muda pra 45', 'desfaz'], endOk: (r) => true, expect: '(obs.)');
    chain('U18 renomear → criar de novo → desfaz×2', base, ['renomeia a categoria pets para bichos', 'cria a categoria pets', 'desfaz', 'desfaz'],
        endOk: (r) => r.budgets.where((b) => b.isCustom).map((b) => b.name).join(',') == 'Pets', expect: 'só Pets');
    chain('U19 limite → criar com limite → desfaz×2', base, ['meu limite de pets é 150', 'cria a categoria pets com limite de 300', 'desfaz', 'desfaz'],
        endOk: (r) => r.budgets.firstWhere((b) => b.category == 'pets').monthlyLimit == 200, expect: 'limite volta a 200');
    chain('U20 "mais 5 de gorjeta" → apagar o principal → desfaz×2', base,
        ['gastei 40 no restaurante no pix', 'mais 5 de gorjeta', 'apaga o anterior', 'sim', 'desfaz', 'desfaz'],
        endOk: (r) => r.transactions.length == 3, expect: 'restaurante de volta, gorjeta desfeita');
    print('CHAOS-R3|TOTAL| violações nesta bateria: $violations');
  });
}
