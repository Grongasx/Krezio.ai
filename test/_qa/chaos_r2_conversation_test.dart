// Teste do caos, rodada 2 (cesar-chaos) — conversa com estado.
//
// NÃO falha a suíte: imprime violações (minimizadas) com o prefixo `R2|`.
//   flutter test test/_qa/chaos_r2_conversation_test.dart 2>&1 | grep "R2|"
//
// Cobre a superfície nova desde a rodada 1: CesarAssistant (editar/excluir
// com confirmação, desfazer, categorias, metas, perguntas), ChatActionHistory,
// TransactionReferenceResolver, KeywordTypoCorrector. Usa o `ChatSim` da
// bateria de conversação (mesma ordem de checagens do `_sendMessage`).
// Achados em docs/qa/findings-caos-r2.md.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/keyword_typo_corrector.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/budget_category.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/persistence_service.dart';

import 'conversation_probe_test.dart' show ChatSim, Reply;

class _NullPersistence extends PersistenceService {
  @override
  Future<bool> hasPersistedData() async => false;
  @override
  Future<void> markSeeded() async {}
  @override
  Future<void> saveTransactions(List<FinancialTransaction> items) async {}
  @override
  Future<void> saveReminders(List<FinancialReminder> items) async {}
  @override
  Future<void> saveBudgets(List<BudgetCategory> items) async {}
  @override
  Future<void> saveGoals(List<FinancialGoal> items) async {}
  @override
  Future<void> saveCategoryOverrides(Map<String, String> overrides) async {}
  @override
  Future<void> clearAll() async {}
}

// ───────────────────────── estado / invariantes ─────────────────────────

class Snap {
  final Map<String, String> tx;
  final Map<String, String> budgets;
  final Map<String, String> goals;
  Snap(this.tx, this.budgets, this.goals);

  factory Snap.of(FinancialRepository r) => Snap(
        {for (final t in r.transactions) t.id: jsonEncode(t.toJson())},
        {for (final b in r.budgets) b.category: '${b.name}|${b.monthlyLimit}|${b.isCustom}'},
        {for (final g in r.goals) g.id: '${g.title}|${g.targetAmount}|${g.savedAmount}|${g.isCompleted}'},
      );

  bool sameAs(Snap o) => _eq(tx, o.tx) && _eq(budgets, o.budgets) && _eq(goals, o.goals);

  static bool _eq(Map<String, String> a, Map<String, String> b) => a.length == b.length && a.keys.every((k) => b[k] == a[k]);

  String diff(Snap o) {
    final out = <String>[];
    void d(String name, Map<String, String> a, Map<String, String> b) {
      for (final k in {...a.keys, ...b.keys}) {
        if (a[k] != b[k]) {
          String short(String? v) => v == null ? '∅' : (v.length > 90 ? '${v.substring(0, 90)}…' : v);
          out.add('$name[$k]: ${short(a[k])} → ${short(b[k])}');
        }
      }
    }

    d('tx', tx, o.tx);
    d('budget', budgets, o.budgets);
    d('goal', goals, o.goals);
    return out.take(4).join(' ; ');
  }
}

final _yes = RegExp(
    r'^(?:sim|s|isso|pode|pode sim|pode apagar|pode excluir|apaga|apague|exclui|confirmo|confirma|confirmado|claro|ok|okay|beleza|blz|manda|manda ver|com certeza|certeza|yes|uhum|aham|isso mesmo|sim pode|sim apaga|sim por favor)(?:\s+(?:sim|pode|apagar|apaga|por favor|cesar|isso))*$');

String _simp(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[áàâã]'), 'a')
    .replaceAll(RegExp('[éê]'), 'e')
    .replaceAll('í', 'i')
    .replaceAll(RegExp('[óôõ]'), 'o')
    .replaceAll('ú', 'u')
    .replaceAll('ç', 'c')
    .replaceAll(RegExp(r'[.,!?;:]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class Violation {
  final String kind;
  final String detail;
  final int turn; // índice do turno que violou
  Violation(this.kind, this.detail, this.turn);
}

/// Quantas vezes cada rota apareceu no fuzz (para o relatório de volume).
final routeCount = <String, int>{};

const _pendingRoutes = {'confirm_delete', 'choose', 'ask_changes'};

class RunResult {
  final List<Violation> violations;
  final int turns;
  final bool undoAllChecked;
  final Set<String> nonUndoableRoutes;
  final List<String> sent;
  RunResult(this.violations, this.turns, this.undoAllChecked, this.nonUndoableRoutes, [this.sent = const []]);
}

FinancialRepository _newRepo() {
  final repo = FinancialRepository(persistence: _NullPersistence());
  repo.addGoal(FinancialGoal(id: 'g-viagem', title: 'Viagem', targetAmount: 5000));
  repo.addGoal(FinancialGoal(id: 'g-carro', title: 'Carro novo', targetAmount: 20000, savedAmount: 300));
  repo.addBudgetCategory('Pets', 200);
  return repo;
}

double _money(double v) => (v * 100).roundToDouble() / 100;

/// Roda [turns] numa conversa nova e checa invariantes após cada turno.
/// Com [undoAll], ao final desfaz tudo e compara com o estado inicial.
RunResult runConversation(LocalFinancialNlpEngine engine, List<String> fixedTurns,
    {bool undoAll = true, bool stopAtFirst = false, TurnGen? gen, int length = 0}) {
  final turns = gen == null ? fixedTurns : <String>[];
  final total = gen == null ? fixedTurns.length : length;
  final repo = _newRepo();
  final sim = ChatSim(engine, repo);
  final initial = Snap.of(repo);
  final v = <Violation>[];
  final removals = <String, int>{};
  final restores = <String, int>{};
  var nonUndoable = false;
  final nonUndoableRoutes = <String>{};
  var truncated = false;
  String? prevRoute;
  String prevText = '';

  for (var i = 0; i < total; i++) {
    if (gen != null) turns.add(gen.next(repo));
    final t = turns[i];
    final before = Snap.of(repo);
    final pendBefore = sim.assistant.hasPendingQuestion;
    final hBefore = sim.assistant.history.length;
    Reply r;
    try {
      r = sim.send(t);
    } catch (e) {
      v.add(Violation('excecao', '"$t" → $e', i));
      break;
    }
    final after = Snap.of(repo);
    routeCount[r.route] = (routeCount[r.route] ?? 0) + 1;
    if (sim.assistant.history.length >= 20) truncated = true;

    if (r.text.trim().isEmpty) v.add(Violation('resposta_vazia', '"$t" → [${r.route}]', i));

    // ids únicos, valores válidos
    final ids = repo.transactions.map((x) => x.id).toList();
    if (ids.toSet().length != ids.length) v.add(Violation('id_duplicado', '"$t" → [${r.route}]', i));
    for (final x in repo.transactions) {
      if (!x.amount.isFinite || x.amount < 0.01) v.add(Violation('valor_invalido', '"$t" → ${x.title} ${x.amount}', i));
    }

    // saldo recalculado do zero
    var inc = 0.0, out = 0.0;
    for (final x in repo.transactions) {
      if (x.type == TransactionType.income) {
        inc += x.amount;
      } else {
        out += x.amount;
      }
    }
    if ((inc - out - repo.totalBalance).abs() > 0.005) v.add(Violation('saldo', '"$t" → ${inc - out} ≠ ${repo.totalBalance}', i));
    // gasto do mês por categoria
    final now = DateTime.now();
    for (final b in repo.budgets) {
      final spent = repo.transactions
          .where((x) => x.type == TransactionType.expense && x.category == b.category && x.date.year == now.year && x.date.month == now.month)
          .fold(0.0, (a, x) => a + x.amount);
      if ((_money(spent) - _money(b.currentSpent)).abs() > 0.005) {
        v.add(Violation('currentSpent', '"$t" → ${b.name} ${b.currentSpent} ≠ $spent', i));
      }
    }

    final s = _simp(t);
    final confirmedDelete = prevRoute == 'confirm_delete' && _yes.hasMatch(s);

    // nada apagado sem "sim" logo antes (ou desfazer)
    final removedTx = before.tx.keys.where((k) => !after.tx.containsKey(k)).toList();
    if (removedTx.isNotEmpty) {
      final ok = (r.route == 'deleted' && confirmedDelete) || r.route == 'undo';
      if (!ok) v.add(Violation('apagou_sem_sim', '"$t" → [${r.route}] removeu ${removedTx.length} (prev=$prevRoute)', i));
      if (r.route == 'deleted') {
        for (final id in removedTx) {
          final title = (jsonDecode(before.tx[id]!) as Map)['title'] as String;
          if (removedTx.length <= 10 && !prevText.contains(title)) {
            v.add(Violation('apagou_outro', '"$t" apagou "$title", que não estava na confirmação: "${prevText.replaceAll('\n', ' ')}"', i));
          }
        }
      }
      for (final id in removedTx) {
        removals[id] = (removals[id] ?? 0) + 1;
      }
    }
    final removedCats = before.budgets.keys.where((k) => !after.budgets.containsKey(k)).toList();
    if (removedCats.isNotEmpty && !((r.route == 'category_deleted' && confirmedDelete) || r.route == 'undo')) {
      v.add(Violation('categoria_apagada_sem_sim', '"$t" → [${r.route}] removeu $removedCats', i));
    }
    final removedGoals = before.goals.keys.where((k) => !after.goals.containsKey(k)).toList();
    if (removedGoals.isNotEmpty && !((r.route == 'goal_deleted' && confirmedDelete) || r.route == 'undo')) {
      v.add(Violation('meta_apagada_sem_sim', '"$t" → [${r.route}] removeu $removedGoals', i));
    }

    // desfazer
    final addedTx = after.tx.keys.where((k) => !before.tx.containsKey(k)).toList();
    if (r.route == 'undo') {
      for (final id in addedTx) {
        restores[id] = (restores[id] ?? 0) + 1;
        if (restores[id]! > (removals[id] ?? 0)) v.add(Violation('ressuscitou_demais', '"$t" trouxe $id de volta sem ter sido apagado de novo', i));
      }
      if (addedTx.isNotEmpty && removedTx.isNotEmpty) v.add(Violation('undo_misto', 'um "desfaz" adicionou e removeu ao mesmo tempo', i));
    }
    if (r.route == 'undo_empty' && !before.sameAs(after)) v.add(Violation('undo_vazio_mudou', before.diff(after), i));
    if (r.route != 'undo' && !before.sameAs(after) && sim.assistant.history.length <= hBefore && !truncated) {
      nonUndoable = true;
      nonUndoableRoutes.add('${r.route} "$t"');
    }

    // pendência nunca presa
    if (pendBefore && sim.assistant.hasPendingQuestion && !_pendingRoutes.contains(r.route)) {
      v.add(Violation('pendencia_presa', '"$t" → [${r.route}] e a pergunta continua pendente', i));
    }
    // "desfaz" engolido por uma pergunta de rascunho/multi
    if (s == 'desfaz' && (r.route == 'ask' || r.route == 'ask_multi')) {
      v.add(Violation('desfaz_engolido', '"desfaz" virou resposta de rascunho pendente: [${r.route}] ${r.text.replaceAll('\n', ' ')}', i));
    }

    prevRoute = r.route;
    prevText = r.text;
    if (stopAtFirst && v.isNotEmpty) return RunResult(v, i + 1, false, nonUndoableRoutes);
  }

  var checked = false;
  if (undoAll && !nonUndoable && !truncated && v.every((x) => x.kind != 'excecao')) {
    sim.active = null;
    sim.pendingBatch = null;
    checked = true;
    for (var k = 0; k < 40; k++) {
      Reply r;
      try {
        r = sim.send('desfaz');
      } catch (e) {
        v.add(Violation('excecao', '"desfaz" (desfazer tudo) → $e', turns.length));
        break;
      }
      if (r.route == 'undo_empty') break;
      if (r.route != 'undo') {
        v.add(Violation('desfaz_nao_desfez', '"desfaz" → [${r.route}] ${r.text}', turns.length));
        break;
      }
    }
    final end = Snap.of(repo);
    if (!end.sameAs(initial)) {
      final d = initial.diff(end);
      final first = d.split(' ; ').first;
      final what = first.substring(0, first.indexOf('['));
      final how = first.contains('→ ∅') ? 'sumiu' : (first.contains(': ∅ →') ? 'sobrou' : 'mudou');
      v.add(Violation('desfazer_tudo_difere:$what-$how', d, turns.length));
    }
  }
  return RunResult(v, turns.length, checked, nonUndoableRoutes, turns);
}

// ───────────────────────── gerador de turnos ─────────────────────────

class TurnGen {
  final Random rng;
  TurnGen(this.rng);

  T pick<T>(List<T> l) => l[rng.nextInt(l.length)];
  int amount() => pick([10, 20, 30, 45, 50, 50, 50, 80, 100, 120, 250]);

  /// Exploração: R2_EXCLUDE="com limite" tira frases de um achado já conhecido
  /// para o fuzz achar os outros.
  static final _exclude = Platform.environment['R2_EXCLUDE'];

  String next(FinancialRepository repo) {
    for (var k = 0; k < 20; k++) {
      final t = _next(repo);
      if (_exclude == null || _exclude!.isEmpty || !t.contains(_exclude!)) return t;
    }
    return 'qual meu saldo?';
  }

  String _next(FinancialRepository repo) {
    final roll = rng.nextInt(100);
    final amounts = repo.transactions.map((t) => t.amount).toList();
    final a = amount();
    if (roll < 22) {
      return pick([
        'gastei $a no mercado no pix',
        'paguei $a de luz no boleto',
        'recebi $a de freela no pix',
        'gastei $a na padaria no débito',
        'gastei $a no uber no pix',
        'gastei $a em pets no pix',
        'gastei $a',
        'gastei no mercado',
        'gastei $a no mercado e 30 na farmácia',
        'gastei $a no mercado e 30 na farmácia no pix',
        'comprei um fone de $a no crédito',
        'contratei um pedreiro pagando $a reais o dia durante 3 dias no pix',
      ]);
    }
    if (roll < 30) {
      return pick(['quanto gastei esse mês?', 'qual meu saldo?', 'e ontem?', 'quais foram meus últimos lançamentos?', 'quanto falta pra minha meta?', 'o que você sabe fazer?']);
    }
    if (roll < 42) {
      return pick([
        'na verdade foi $a',
        'muda pra $a',
        'troca pra débito',
        'esse era lazer',
        'na verdade foi ontem',
        'muda o valor do aluguel pra ${a * 10}',
        'na verdade foi uma entrada',
        'muda o anterior pra $a',
        'o uber foi no crédito',
        'edita o último lançamento',
        'pets',
      ]);
    }
    if (roll < 56) {
      final existing = amounts.isEmpty ? a : pick(amounts);
      final n = existing == existing.roundToDouble() ? existing.toStringAsFixed(0) : existing.toStringAsFixed(2).replaceAll('.', ',');
      return pick([
        'apaga o último',
        'apaga o de $n',
        'apaga o uber',
        'exclui o mercado',
        'apaga os dois últimos',
        'apaga o anterior',
        'apaga esse',
        'apaga os lançamentos de hoje',
        'apaga o de ontem',
        'cancela',
      ]);
    }
    if (roll < 70) {
      return pick(['sim', 'sim', 'não', '1', '2', 'o segundo', 'nenhum', 'ok', 'pode apagar', 's']);
    }
    if (roll < 82) return 'desfaz';
    if (roll < 90) {
      return pick([
        'cria a categoria viagens',
        'cria a categoria pets com limite de 300',
        'renomeia a categoria pets para animais',
        'renomeia a categoria animais para pets',
        'apaga a categoria pets',
        'apaga a categoria animais',
        'move tudo de pets para lazer',
        'meu limite de lazer é 700',
        'meu limite de pets é 150',
      ]);
    }
    if (roll < 95) {
      return pick(['guardei 100 na meta da viagem', 'tira 50 da meta da viagem', 'apaga a meta da viagem', 'guardei 200 no carro novo', 'apaga a meta do carro']);
    }
    return pick(['asdf', '💸💸', '???', 'sim sim sim', 'apaga', 'muda', 'o de 50', 'repete o último', 'mais 20 de gorjeta', 'e 30 na padaria', 'esquece', '']);
  }
}

/// Menor subsequência de [turns] que ainda produz uma violação [kind].
List<String> minimize(LocalFinancialNlpEngine engine, List<String> turns, String kind, Stopwatch sw, int deadlineMs) {
  bool fails(List<String> ts) => runConversation(engine, ts, undoAll: kind.startsWith('desfazer_tudo_difere') || kind == 'desfaz_nao_desfez').violations.any((x) => x.kind == kind);
  var cur = List<String>.from(turns);
  // corta a cauda depois da primeira violação
  final first = runConversation(engine, cur, undoAll: false, stopAtFirst: false).violations.where((x) => x.kind == kind).toList();
  if (first.isNotEmpty && first.first.turn < cur.length) {
    final cut = cur.sublist(0, first.first.turn + 1);
    if (fails(cut)) cur = cut;
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (var i = 0; i < cur.length; i++) {
      if (sw.elapsedMilliseconds > deadlineMs) return cur;
      final cand = [...cur.sublist(0, i), ...cur.sublist(i + 1)];
      if (fails(cand)) {
        cur = cand;
        changed = true;
        break;
      }
    }
  }
  return cur;
}

// ───────────────────────── execução ─────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  test('R2 fuzz de conversa com estado', () {
    final sw = Stopwatch()..start();
    // Mais volume: R2_SEEDS=300 R2_MIN_MS=600000 flutter test ...
    final seeds = int.tryParse(Platform.environment['R2_SEEDS'] ?? '') ?? 30;
    final minMs = int.tryParse(Platform.environment['R2_MIN_MS'] ?? '') ?? 20000;
    const length = 20;
    var turns = 0, undoAllRuns = 0;
    final firstByKind = <String, List<String>>{};
    final firstSeed = <String, int>{};
    final countByKind = <String, int>{};
    final nonUndoRoutes = <String, int>{};
    for (var seed = 1; seed <= seeds; seed++) {
      final res = runConversation(engine, const [], gen: TurnGen(Random(20260924 + seed)), length: length);
      final ts = res.sent;
      turns += res.turns;
      if (res.undoAllChecked) undoAllRuns++;
      for (final r in res.nonUndoableRoutes) {
        nonUndoRoutes[r] = (nonUndoRoutes[r] ?? 0) + 1;
      }
      for (final x in res.violations) {
        countByKind[x.kind] = (countByKind[x.kind] ?? 0) + 1;
        if (!firstByKind.containsKey(x.kind)) {
          firstByKind[x.kind] = ts;
          firstSeed[x.kind] = 20260924 + seed;
          print('R2|FUZZ| primeira ${x.kind} seed=${20260924 + seed} turno ${x.turn + 1}: ${x.detail}');
        }
      }
    }
    print('R2|FUZZ| $seeds conversas, $turns turnos, desfazer-tudo checado em $undoAllRuns; ${sw.elapsedMilliseconds} ms');
    print('R2|FUZZ| violações por tipo: $countByKind');
    final routes = routeCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    print('R2|FUZZ| rotas: ${routes.map((e) => '${e.key}=${e.value}').join(' ')}');
    print('R2|FUZZ| rotas que mudaram dados sem entrar na pilha de desfazer: $nonUndoRoutes');
    for (final kind in firstByKind.keys) {
      if (sw.elapsedMilliseconds > minMs - 2000) {
        print('R2|MIN| $kind: sem tempo para minimizar');
        continue;
      }
      final min = minimize(engine, firstByKind[kind]!, kind, sw, minMs);
      final res = runConversation(engine, min, undoAll: kind.startsWith('desfazer_tudo_difere') || kind == 'desfaz_nao_desfez');
      final x = res.violations.firstWhere((e) => e.kind == kind, orElse: () => Violation(kind, '(não reproduziu)', -1));
      print('R2|MIN| $kind (seed ${firstSeed[kind]}): ${min.map((e) => '"$e"').join(' ⏎ ')}  ⇒  ${x.detail}');
    }
    print('R2|FUZZ| total ${sw.elapsedMilliseconds} ms');
  });

  // ───────────── desfazer adversarial ─────────────

  test('R2 desfazer adversarial', () async {
    String state(FinancialRepository r) =>
        'tx=${r.transactions.length} cats=${r.budgets.where((b) => b.isCustom).map((b) => '${b.name}:${b.category}:${b.monthlyLimit}').toList()} '
        'goals=${r.goals.map((g) => '${g.title}:${g.savedAmount}').toList()}';

    Future<void> run(String name, List<Object> steps) async {
      final repo = _newRepo();
      final sim = ChatSim(engine, repo);
      final lines = <String>[];
      for (final s in steps) {
        try {
          if (s is String) {
            final r = sim.send(s);
            lines.add('"$s" → [${r.route}] ${r.text.replaceAll('\n', ' ').substring(0, min(110, r.text.replaceAll('\n', ' ').length))} | ${state(repo)}');
          } else if (s is Future<void> Function(FinancialRepository)) {
            await s(repo);
            lines.add('(ação externa) | ${state(repo)}');
          }
        } catch (e) {
          lines.add('"$s" → EXCEÇÃO $e');
        }
      }
      print('R2|UNDO| $name');
      for (final l in lines) {
        print('R2|UNDO|    $l');
      }
    }

    Future<void> clear(FinancialRepository r) => r.clearAllData();
    Future<void> deleteGoalOutside(FinancialRepository r) async => r.deleteGoal('g-viagem');
    Future<void> removePetsOutside(FinancialRepository r) async => r.removeBudgetCategory('pets');

    await run('U1 editar para categoria apagada, desfazer', [
      'gastei 30 no mercado no pix',
      'pets',
      'apaga a categoria pets',
      'sim',
      'desfaz',
      'desfaz',
      'desfaz',
    ]);
    await run('U2 apagar ⏎ sim ⏎ Limpar Histórico ⏎ desfaz', ['gastei 50 no mercado no pix', 'apaga o último', 'sim', clear, 'desfaz']);
    await run('U3 lançar ⏎ Limpar Histórico ⏎ desfaz', ['gastei 50 no mercado no pix', clear, 'desfaz']);
    await run('U4 aporte na meta ⏎ Limpar Histórico ⏎ desfaz', ['guardei 100 na meta da viagem', clear, 'desfaz']);
    await run('U5 aporte ⏎ meta apagada fora do chat ⏎ desfaz', ['guardei 100 na meta da viagem', deleteGoalOutside, 'desfaz']);
    await run('U6 retirada ⏎ meta apagada fora do chat ⏎ desfaz', ['tira 50 da meta do carro novo', deleteGoalOutside, 'desfaz', 'desfaz']);
    await run('U7 criar categoria já existente com limite ⏎ desfaz', ['cria a categoria pets com limite de 300', 'desfaz']);
    await run('U8 renomear ⏎ outra categoria pega o nome antigo ⏎ desfaz', [
      'renomeia a categoria pets para animais',
      'cria a categoria pets',
      'desfaz',
      'desfaz',
    ]);
    await run('U8b renomear ⏎ "Pets" criada fora do chat ⏎ desfaz', [
      'renomeia a categoria pets para animais',
      (FinancialRepository r) async => r.addBudgetCategory('Pets', 0),
      'desfaz',
    ]);
    await run('U9 limite ⏎ categoria apagada fora ⏎ desfaz', ['meu limite de pets é 150', removePetsOutside, 'desfaz']);
    await run('U10 apagar categoria ⏎ sim ⏎ recriar com o mesmo nome ⏎ desfaz ⏎ desfaz', [
      'gastei 40 em pets no pix',
      'apaga a categoria pets',
      'sim',
      'cria a categoria pets com limite de 999',
      'desfaz',
      'desfaz',
    ]);
    await run('U11 mover tudo ⏎ apagar destino ⏎ desfaz ×3', [
      'gastei 40 em pets no pix',
      'cria a categoria bichos',
      'move tudo de pets para bichos',
      'apaga a categoria bichos',
      'sim',
      'desfaz',
      'desfaz',
      'desfaz',
    ]);
    await run('U12 apagar meta ⏎ sim ⏎ desfaz ⏎ desfaz (meta volta 1 vez)', ['apaga a meta da viagem', 'sim', 'desfaz', 'desfaz']);
    await run('U13 apagar ⏎ sim ⏎ desfaz ⏎ desfaz ⏎ desfaz', ['gastei 50 no mercado no pix', 'apaga o último', 'sim', 'desfaz', 'desfaz', 'desfaz']);

    // Pilha longa: 25 lançamentos, 26 "desfaz".
    {
      final repo = _newRepo();
      final sim = ChatSim(engine, repo);
      final base = repo.transactions.length;
      for (var i = 1; i <= 25; i++) {
        sim.send('gastei ${i + 10} no mercado no pix');
      }
      final routes = <String>[];
      for (var i = 0; i < 26; i++) {
        routes.add(sim.send('desfaz').route);
      }
      final left = repo.transactions.length - base;
      print('R2|UNDO| U14 pilha longa: 25 lançamentos + 26 desfaz → ${routes.where((r) => r == 'undo').length} desfeitos, '
          'sobraram $left do chat; última resposta: "${sim.log.last.text}"');
    }
    // Desfaz depois de uma diária (grupo de vários ids).
    await run('U15 diária ⏎ apaga o último ⏎ sim ⏎ desfaz', [
      'contratei um pedreiro pagando 50 reais o dia durante 3 dias no pix',
      'apaga o último',
      'sim',
      'desfaz',
    ]);
    // "desfaz" durante rascunho pendente e pergunta de multi.
    await run('U16 "desfaz" com rascunho pendente', ['gastei 50 no mercado no pix', 'gastei 30', 'desfaz', 'desfaz']);
    await run('U17 "desfaz" com pergunta de multi pendente', ['gastei 50 no mercado no pix', 'gastei 20 no uber e 30 na farmácia', 'desfaz', 'desfaz']);
    await run('U19 aporte na meta com rascunho pendente ⏎ desfaz ⏎ desfaz', [
      'gastei 50 no mercado no pix',
      'gastei 30',
      'guardei 100 na meta da viagem',
      'desfaz',
      'desfaz',
    ]);
    await run('U20 criar categoria ⏎ lançar nela ⏎ desfaz ×2', ['cria a categoria viagens', 'gastei 80 em viagens no pix', 'desfaz', 'desfaz']);
    await run('U18 editar ⏎ apagar fora do chat ⏎ desfaz (pula para ação mais antiga?)', [
      'gastei 50 no mercado no pix',
      'gastei 30 na padaria no pix',
      'muda pra 35',
      (FinancialRepository r) async => r.deleteTransaction(r.transactions.first.id),
      'desfaz',
    ]);
  });

  // ───────────── corretor de digitação: falsos positivos ─────────────

  test('R2 corretor de digitação — falsos positivos', () {
    // Palavra comum que o corretor transformaria em palavra-chave (sem o
    // vocabulário do modelo, que o motor usa como proteção extra).
    const words = [
      'picsou', 'debate', 'credor', 'credora', 'mercador', 'delito', 'demito', 'juntar', 'pagaria', 'pradaria', 'podaria',
      'presidente', 'prudente', 'pretende', 'presenca', 'facilidade', 'brinquei', 'almaco', 'aluguei', 'recebo', 'solario',
      'drogado', 'viajem', 'bolota', 'lances', 'cinemark', 'jantam', 'boleia', 'mercedes', 'padrinha', 'abasteço', 'transfira',
      'restaurant', 'condominial', 'gasolinas', 'mercearia', 'dinheirama', 'salarial', 'academico', 'cineasta', 'vintage',
      'gastar', 'pagava', 'comprido', 'compreendi', 'recibo', 'recebia', 'presente', 'presentinho', 'credencial', 'debitado',
      'boletim', 'faculdade', 'facilitade', 'almoxarife', 'jantinha', 'lanchonete', 'alugueis', 'aluguem', 'domingo',
      'padeiro', 'pedaria', 'farmaceutico', 'farinha', 'fazenda', 'mercante', 'merecido', 'gastrite', 'gaston', 'pagode',
      'comprimido', 'comprimento', 'receita', 'recesso', 'debora', 'credito', 'boleiro', 'boleira', 'cinema', 'vitagem',
    ];
    final corrected = <String, String>{};
    for (final w in words) {
      final c = KeywordTypoCorrector.correct(w);
      if (c != null) corrected[w] = c;
    }
    print('R2|TYPO| sem vocabulário: ${corrected.length}/${words.length} viram palavra-chave: $corrected');

    // Efeito real no motor (com a proteção do vocabulário): frase com a
    // palavra vs a mesma frase com uma palavra neutra no lugar.
    const pairs = <List<String>>[
      ['gastei 50 no pagode no pix', 'gastei 50 no show no pix'],
      ['paguei 200 pra juntar as peças do carro no pix', 'paguei 200 pra montar as peças do carro no pix'],
      ['gastei 80 no hotel presidente no pix', 'gastei 80 no hotel central no pix'],
      ['gastei 80 no posto presidente no pix', 'gastei 80 no posto central no pix'],
      ['gastei 120 em presidente prudente no pix', 'gastei 120 em ribeirão preto no pix'],
      ['comprei papel almaço por 10 no pix', 'comprei papel sulfite por 10 no pix'],
      ['aluguei um carro por 200 no pix', 'peguei um carro por 200 no pix'],
      ['aluguei uma bicicleta por 30 no pix', 'peguei uma bicicleta por 30 no pix'],
      ['gastei 50 na facilidade do app no pix', 'gastei 50 na loja do app no pix'],
      ['paguei 300 de multa pelo delito no pix', 'paguei 300 de multa pelo erro no pix'],
      ['paguei 40 pro credor no pix', 'paguei 40 pro fulano no pix'],
      ['paguei 40 pra credora no pix', 'paguei 40 pra fulana no pix'],
      ['paguei 100 no debate no pix', 'paguei 100 no evento no pix'],
      ['gastei 30 no mercador no pix', 'gastei 30 no vendedor no pix'],
      ['gastei 25 com a presença do palhaço no pix', 'gastei 25 com a vinda do palhaço no pix'],
      ['gastei 50 porque brinquei na feira no pix', 'gastei 50 porque passeei na feira no pix'],
      ['gastei 60 na pradaria no pix', 'gastei 60 na chácara no pix'],
      ['o que eu pagaria 50 no pix', 'o que eu daria 50 no pix'],
      ['gastei 70 no drogado no pix', 'gastei 70 no fulano no pix'],
      ['gastei 90 no cinemark no pix', 'gastei 90 no shopping no pix'],
      ['paguei 35 no boletim da escola no pix', 'paguei 35 na apostila da escola no pix'],
      ['gastei 20 de recibo no pix', 'gastei 20 de xerox no pix'],
      ['recebo 3000 de salário todo mês', 'recebi 3000 de salário'],
      ['gastei 40 na lanchonete no pix', 'gastei 40 na loja no pix'],
      ['paguei 15 no comprimido no pix', 'paguei 15 no negócio no pix'],
      ['gastei 45 na gastrite no pix', 'gastei 45 na consulta no pix'],
      ['comprei 30 de farinha no pix', 'comprei 30 de arroz no pix'],
      ['gastei 100 na fazenda no pix', 'gastei 100 no sítio no pix'],
      ['gastei 50 no picsou no pix', 'gastei 50 no fulano no pix'],
      ['comprei um vintage de 80 no pix', 'comprei um casaco de 80 no pix'],
      ['gastei 30 na merecida pizza no pix', 'gastei 30 na gostosa pizza no pix'],
      ['paguei 60 na mercearia no pix', 'paguei 60 na loja no pix'],
      ['paguei 50 na credencial do evento no pix', 'paguei 50 na entrada do evento no pix'],
      ['comprei um vestido comprido de 150 no pix', 'comprei um vestido longo de 150 no pix'],
      ['dei 30 de presentinho pra ana no pix', 'dei 30 de lembrancinha pra ana no pix'],
      ['gastei 50 na farmácia bar no pix', 'gastei 50 no bar no pix'],
      ['gastei 100 no crediário no pix', 'gastei 100 no carnê no pix'],
      ['gastei 40 no debitado no pix', 'gastei 40 no fulano no pix'],
      ['paguei 25 pro boleiro no pix', 'paguei 25 pro fulano no pix'],
      ['paguei 25 pra boleira no pix', 'paguei 25 pra fulana no pix'],
      ['gastei 30 com a padrinha no pix', 'gastei 30 com a madrinha no pix'],
      ['gastei 30 no padeiro no pix', 'gastei 30 no fulano no pix'],
      // frases mais naturais para os casos suspeitos
      ['comprei um bloco de papel almaço de 12 reais no pix', 'comprei um bloco de papel sulfite de 12 reais no pix'],
      ['paguei 30 pela facilidade de entrega no pix', 'paguei 30 pela taxa de entrega no pix'],
      ['gastei 50 que eu pagaria de novo no pix', 'gastei 50 que eu gastaria de novo no pix'],
      ['paguei 80 pro jardineiro que podaria a árvore no pix', 'paguei 80 pro jardineiro que cortaria a árvore no pix'],
      ['gastei 40 no solário do clube no pix', 'gastei 40 na piscina do clube no pix'],
      ['paguei 50 que recebo de volta semana que vem no pix', 'paguei 50 que ganho de volta semana que vem no pix'],
      ['gastei 200 na viagem pra presidente prudente no pix', 'gastei 200 na viagem pra ribeirão preto no pix'],
      // sem forma de pagamento: a palavra vira pagamento?
      ['paguei 300 de multa pelo delito', 'paguei 300 de multa pelo erro'],
      ['gastei 100 com o advogado, demito ele amanhã', 'gastei 100 com o advogado, troco ele amanhã'],
      ['paguei 40 pro credor', 'paguei 40 pro fulano'],
      ['paguei 40 pra credora', 'paguei 40 pra fulana'],
      ['paguei 100 no debate', 'paguei 100 no evento'],
      ['gastei 50 no picsou', 'gastei 50 no fulano'],
      ['paguei 35 do boletim', 'paguei 35 da apostila'],
      ['paguei 25 pro boleiro', 'paguei 25 pro fulano'],
      ['gastei 60 na boleia do caminhão', 'gastei 60 na cabine do caminhão'],
      ['gastei 80 no credenciamento', 'gastei 80 no cadastramento'],
      ['paguei 90 na dinheirama', 'paguei 90 na lojinha'],
      ['gastei 70 no debitado', 'gastei 70 no fulano'],
      ['comprei um vestido comprido de 150', 'comprei um vestido longo de 150'],
      ['gastei 45 no bolo da boleira', 'gastei 45 no bolo da confeiteira'],
    ];
    var diffs = 0;
    for (final p in pairs) {
      final a = engine.parse(p[0]);
      final b = engine.parse(p[1]);
      final ka = '${a.intent}/${a.category}/${a.paymentMethod}/${a.amount}';
      final kb = '${b.intent}/${b.category}/${b.paymentMethod}/${b.amount}';
      if (ka != kb) {
        diffs++;
        print('R2|TYPO| DIFERE "${p[0]}" → $ka complete=${a.isComplete} | neutro "${p[1]}" → $kb');
      }
    }
    print('R2|TYPO| ${pairs.length} pares, $diffs diferem');
  });

  // ───────────── resolvedor de referência ─────────────

  test('R2 resolvedor de referência', () async {
    Future<(FinancialRepository, CesarAssistant)> make(DateTime now, List<FinancialTransaction> txs) async {
      final repo = FinancialRepository(persistence: _NullPersistence());
      await repo.clearAllData();
      for (final t in txs) {
        repo.addTransaction(t);
      }
      return (repo, CesarAssistant(repository: repo, engine: engine, now: () => now));
    }

    FinancialTransaction tx(String id, String title, double amount, DateTime d, {String cat = 'expense_other'}) =>
        FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: d);

    String say(CesarAssistant a, String text) {
      a.beginTurn();
      final r = a.handleCommand(text);
      return r == null ? '(null → segue o pipeline)' : '[${r.route}] ${r.text.replaceAll('\n', ' ')}';
    }

    void report(String name, List<String> lines) {
      print('R2|REF| $name');
      for (final l in lines) {
        print('R2|REF|    $l');
      }
    }

    // Três de 50.
    {
      final now = DateTime(2026, 9, 24, 15);
      final (_, a) = await make(now, [
        tx('a', 'Mercado', 50, DateTime(2026, 9, 24, 9)),
        tx('b', 'Uber', 50, DateTime(2026, 9, 23, 9)),
        tx('c', 'Farmácia', 50, DateTime(2026, 9, 22, 9)),
      ]);
      report('R1 três de 50', [say(a, 'apaga o de 50'), say(a, 'o de 50'), say(a, 'apaga o de 50'), say(a, '3'), say(a, 'sim')]);
    }
    // Três de 50 via ChatSim: responder "o de 50"/"4" à escolha vira lançamento?
    {
      final repo = FinancialRepository(persistence: _NullPersistence());
      final sim = ChatSim(engine, repo);
      sim.send('gastei 50 no mercado no pix');
      sim.send('gastei 50 no uber no pix');
      sim.send('gastei 50 na farmácia no pix');
      final before = repo.transactions.length;
      final r1 = sim.send('apaga o de 50');
      final r2 = sim.send('o de 50');
      final r3 = sim.send('apaga o de 50');
      final r4 = sim.send('4');
      report('R1b três de 50 no chat', ['$r1', '$r2', '$r3', '$r4', 'lançamentos: $before → ${repo.transactions.length}']);
    }
    // Virada de ano.
    {
      final now = DateTime(2027, 1, 1, 10);
      final (_, a) = await make(now, [tx('p', 'Padaria', 20, DateTime(2026, 12, 31, 8)), tx('q', 'Uber', 33, DateTime(2027, 1, 1, 8))]);
      report('R3 virada de ano (hoje 01/01/2027; Padaria em 31/12/2026)', [
        say(a, 'apaga a padaria de ontem'),
        say(a, 'não'),
        say(a, 'apaga o do dia 31'),
        say(a, 'não'),
        say(a, 'apaga o de 31/12'),
        say(a, 'apaga a padaria do mês passado'),
        say(a, 'não'),
        say(a, 'apaga a padaria de quinta'),
        say(a, 'não'),
      ]);
    }
    // Dia 31 num mês de 30 dias.
    {
      final now = DateTime(2026, 10, 1, 10);
      final (_, a) = await make(now, [tx('m', 'Mercado', 40, DateTime(2026, 10, 1, 8)), tx('n', 'Mercado', 41, DateTime(2026, 9, 30, 8))]);
      report('R4 "dia 31" com setembro de 30 dias (hoje 01/10)', [say(a, 'apaga o mercado do dia 31'), say(a, 'não'), say(a, 'muda o mercado do dia 31 pra 99')]);
    }
    // Fevereiro.
    {
      final now = DateTime(2027, 3, 1, 10);
      final (_, a) = await make(now, [tx('f', 'Mercado', 40, DateTime(2027, 3, 1, 8)), tx('g', 'Mercado', 42, DateTime(2027, 2, 28, 8))]);
      report('R5 "dia 29/30" depois de fevereiro (hoje 01/03/2027)', [say(a, 'apaga o mercado do dia 29'), say(a, 'não'), say(a, 'apaga o mercado do dia 30')]);
    }
    // Milhar com ponto.
    {
      final now = DateTime(2026, 9, 24, 15);
      final (_, a) = await make(now, [tx('al', 'Aluguel', 1400, DateTime(2026, 9, 8, 8), cat: 'housing'), tx('tv', 'TV', 1400.5, DateTime(2026, 9, 9, 8))]);
      report('R6 valor com milhar', [say(a, 'apaga o de 1.400'), say(a, 'não'), say(a, 'apaga o de R\$ 1.400,00'), say(a, 'não'), say(a, 'apaga o de 1400,50')]);
    }
    // Referência a lançamento já apagado.
    {
      final repo = FinancialRepository(persistence: _NullPersistence());
      final sim = ChatSim(engine, repo);
      final lines = <String>[];
      for (final t in ['gastei 50 no mercado no pix', 'gastei 30 na padaria no pix', 'apaga esse', 'sim', 'muda pra 80', 'apaga esse']) {
        lines.add('"$t" → ${sim.send(t)}');
      }
      lines.add('mercado agora: ${repo.transactions.where((t) => t.title.toLowerCase().contains('mercado') && !t.id.startsWith('init')).map((t) => t.amount).toList()}');
      report('R7 "esse" depois de apagar "esse"', lines);
    }
    {
      final repo = FinancialRepository(persistence: _NullPersistence());
      final sim = ChatSim(engine, repo);
      final lines = <String>[];
      for (final t in ['apaga o uber', 'sim', 'apaga o uber', 'muda o uber pra 10']) {
        lines.add('"$t" → ${sim.send(t)}');
      }
      report('R8 referência ao uber já apagado', lines);
    }
    // Dia 0 / dia 99 / 45/13.
    {
      final now = DateTime(2026, 9, 24, 15);
      final (_, a) = await make(now, [tx('z', 'Mercado', 40, DateTime(2026, 8, 31, 8)), tx('w', 'Mercado', 41, DateTime(2026, 9, 24, 8))]);
      report('R9 datas absurdas', [say(a, 'apaga o mercado do dia 0'), say(a, 'não'), say(a, 'apaga o mercado de 45/13'), say(a, 'não'), say(a, 'apaga o mercado do dia 99')]);
    }
  });
}
