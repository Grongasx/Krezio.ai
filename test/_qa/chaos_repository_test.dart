// Teste do caos — fuzzing do FinancialRepository com verificação de invariantes.
//
// NÃO falha a suíte: imprime violações (já minimizadas) com o prefixo `CHAOS|`.
//   flutter test test/_qa/chaos_repository_test.dart 2>&1 | grep "CHAOS|"
// Reproduzir: os seeds estão em `_seeds`; cada violação é minimizada até a menor
// sequência de operações (a partir de um repositório recém-criado, com o seed
// de demonstração) que ainda a reproduz. Achados em docs/qa/findings-caos.md.
//
// Regras de invariante escritas de acordo com o código real:
// - `totalBalance` = Σ receitas − Σ (despesas + transferências)  (transferência
//   também sai do saldo — ver `totalBalance`).
// - `currentSpent` = Σ despesas (só `expense`, não `transfer`) do MÊS CORRENTE
//   daquela categoria — ver `_recalculateBudgets`.
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/budget_category.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/persistence_service.dart';

/// Persistência nula: o fuzzer mede a lógica em memória; serializar tudo a
/// cada operação deixaria o teste lento sem testar nada novo.
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

const _seeds = [20260923, 1, 42];
const _opsPerSeed = 2000;

const _builtinCats = ['supermarket', 'leisure', 'transport', 'housing', 'health', 'education'];
const _otherCats = ['salary', 'income_other', 'expense_other', 'pets', 'roupas', 'cafe', 'unknown'];
const _payments = ['pix', 'credit_card', 'debit_card', 'cash', 'bank_slip', 'unknown'];
const _catNames = ['Pets', 'pets', 'PETS ', 'Roupas', 'Café', 'cafe', 'Supermarket', 'Supermercado', 'Saúde & Farmácia', '!!!', '', '  ', 'Viagem 2027', 'Lazer'];
const _types = TransactionType.values;

/// Uma operação é só dados (tipo + números sorteados); índices viram "o i-ésimo
/// item existente" (módulo o tamanho) na hora de executar, então a mesma lista
/// pode ser reexecutada e encolhida pela minimização.
class _Op {
  final String kind;
  final List<num> n;
  _Op(this.kind, this.n);
  @override
  String toString() => '$kind(${n.map((x) => x is double ? x.toStringAsFixed(2) : '$x').join(',')})';
}

double _amount(Random r) {
  // 6% de valores hostis: 0, negativo, NaN, infinito, gigante, sub-centavo.
  if (r.nextInt(100) < 6) return [0.0, -10.0, double.nan, double.infinity, 1e15, 0.001][r.nextInt(6)];
  return (r.nextInt(500000) + 1) / 100;
}

_Op _randomOp(Random r) {
  final k = r.nextInt(100);
  if (k < 16) return _Op('addTx', [r.nextInt(3), _amount(r), r.nextInt(20), r.nextInt(100) - 60]);
  if (k < 32) {
    return _Op('addDraft', [r.nextInt(3), _amount(r), r.nextInt(20), r.nextInt(6), r.nextInt(80) - 45, r.nextInt(4) == 0 ? r.nextInt(12) : 1, r.nextInt(4)]);
  }
  if (k < 36) return _Op('addDraftBurst', [_amount(r), _amount(r), r.nextInt(20), r.nextInt(20)]);
  if (k < 44) return _Op('update', [r.nextInt(1 << 20), r.nextInt(3), _amount(r), r.nextInt(20), r.nextInt(100) - 60]);
  if (k < 52) return _Op('delete', [r.nextInt(1 << 20)]);
  if (k < 60) return _Op('correct', [r.nextInt(1 << 20), r.nextInt(4), r.nextBool() ? _amount(r) : -1, r.nextInt(20), r.nextInt(6), r.nextInt(5)]);
  if (k < 65) return _Op('addCat', [r.nextInt(_catNames.length), _amount(r)]);
  if (k < 69) return _Op('renameCat', [r.nextInt(1 << 20), r.nextInt(_catNames.length)]);
  if (k < 72) return _Op('removeCat', [r.nextInt(1 << 20)]);
  if (k < 74) return _Op('setLimit', [r.nextInt(1 << 20), _amount(r)]);
  if (k < 77) return _Op('addGoal', [_amount(r)]);
  if (k < 81) return _Op('contribute', [r.nextInt(1 << 20), _amount(r)]);
  if (k < 82) return _Op('deleteGoal', [r.nextInt(1 << 20)]);
  if (k < 85) return _Op('addReminder', [_amount(r)]);
  if (k < 90) return _Op('debtPay', [r.nextInt(1 << 20), _amount(r)]);
  if (k < 92) return _Op('toggleRem', [r.nextInt(1 << 20)]);
  if (k < 93) return _Op('removeRem', [r.nextInt(1 << 20)]);
  if (k < 96) return _Op('bill', [r.nextInt(31) + 1, r.nextInt(31) + 1, r.nextBool() ? _amount(r) : -1]);
  return _Op('remember', [r.nextInt(20)]);
}

String _fold(String s) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  var out = s.toLowerCase().trim();
  for (var i = 0; i < from.length; i++) {
    out = out.replaceAll(from[i], to[i]);
  }
  return out;
}

int _applied = 0;

class _Runner {
  final repo = FinancialRepository(persistence: _NullPersistence());
  int _idCounter = 0;
  final violations = <String, String>{}; // tipo → detalhe (primeira ocorrência)
  final _knownBad = <String>{};

  String _cat(int i) {
    final customs = repo.budgets.where((b) => b.isCustom).map((b) => b.category).toList();
    final all = [..._builtinCats, ..._otherCats, ...customs];
    return all[i % all.length];
  }

  String _sig(FinancialTransaction t) => '${t.id}|${t.amount}|${t.type}|${t.category}|${t.paymentMethod}|${t.date}|${t.installments}';

  void _v(String kind, String detail) => violations.putIfAbsent(kind, () => detail);

  FinancialTransactionDraft _draft({required String intent, double? amount, required String category, required String payment, int offset = 0, int? repeat, int? inst, String desc = 'Fuzz'}) =>
      FinancialTransactionDraft(
        intent: intent,
        intentConfidence: 1,
        category: category,
        paymentMethod: payment,
        amount: amount,
        dateOffsetDays: offset,
        description: desc,
        rawText: desc,
        latencyMs: 0,
        isComplete: true,
        missingSlots: const [],
        repeatDays: repeat,
        installments: inst,
      );

  /// Executa [op] e checa invariantes específicos da operação; exceções viram violação.
  ///
  /// Roda na zona raiz: o repositório encadeia um `_persistAll()` (futuro) por
  /// mutação, e na zona do teste cada futuro captura cadeia de stack trace —
  /// com ~13 mil operações isso custava ~20s só para drenar a fila no fim.
  void apply(_Op op) => Zone.root.run(() => _apply(op));

  void _apply(_Op op) {
    _applied++;
    final txs = repo.transactions;
    final before = txs.length;
    final n = op.n;
    try {
      switch (op.kind) {
        case 'addTx':
          final id = 'fz-${_idCounter++}';
          repo.addTransaction(FinancialTransaction(
            id: id,
            title: 'Fuzz $id',
            amount: n[1].toDouble(),
            type: _types[n[0].toInt()],
            category: _cat(n[2].toInt()),
            paymentMethod: 'pix',
            date: DateTime.now().add(Duration(days: n[3].toInt())),
          ));
          // Valor fora de [R$ 0,01; R$ 100 bi] (NaN, ∞, sub-centavo) é recusado de propósito.
          if (_validMoney(n[1]) && repo.transactions.length != before + 1) _v('ADD_COUNT', '$op: $before -> ${repo.transactions.length}');
        case 'addDraft':
          final saved = repo.addTransactionFromDraft(_draft(
            intent: const ['expense', 'income', 'transfer'][n[0].toInt()],
            amount: n[1].toDouble(),
            category: _cat(n[2].toInt()),
            payment: _payments[n[3].toInt()],
            offset: n[4].toInt(),
            repeat: n[5].toInt(),
            inst: n[6].toInt() == 0 ? null : n[6].toInt() * 3,
          ));
          if (repo.transactions.length != before + saved.length) _v('DRAFT_COUNT', '$op: $before + ${saved.length} != ${repo.transactions.length}');
        case 'addDraftBurst':
          // O que o chat faz num multi-lançamento ("20 no uber e 30 no mercado"):
          // salva vários rascunhos em sequência, no mesmo milissegundo.
          final a = repo.addTransactionFromDraft(_draft(intent: 'expense', amount: n[0].toDouble(), category: _cat(n[2].toInt()), payment: 'pix', desc: 'Uber'));
          final b = repo.addTransactionFromDraft(_draft(intent: 'expense', amount: n[1].toDouble(), category: _cat(n[3].toInt()), payment: 'pix', desc: 'Mercado'));
          if (a.isNotEmpty && b.isNotEmpty && a.first.id == b.first.id) {
            _v('BURST_SAME_ID', '$op: dois lançamentos do mesmo lote receberam o id ${a.first.id}');
          }
        case 'update':
          if (txs.isEmpty) return;
          final old = txs[n[0].toInt() % txs.length];
          repo.updateTransaction(FinancialTransaction(
            id: old.id,
            title: old.title,
            amount: n[2].toDouble(),
            type: _types[n[1].toInt()],
            category: _cat(n[3].toInt()),
            paymentMethod: old.paymentMethod,
            date: DateTime.now().add(Duration(days: n[4].toInt())),
          ));
          if (repo.transactions.length != before) _v('UPDATE_COUNT', '$op');
        case 'delete':
          if (txs.isEmpty) return;
          final id = txs[n[0].toInt() % txs.length].id;
          repo.deleteTransaction(id);
          if (repo.transactions.length != before - 1) {
            _v('DELETE_REMOVES_MORE_THAN_ONE', '$op: apagar o id $id removeu ${before - repo.transactions.length} lançamentos');
          }
        case 'correct':
          if (txs.isEmpty) return;
          final target = txs[n[0].toInt() % txs.length];
          final others = {for (final t in txs) if (t.id != target.id) _sig(t)};
          final amt = n[2].toDouble();
          repo.applyDraftCorrection(
              target.id,
              _draft(
                intent: const ['expense', 'income', 'transfer', 'unknown'][n[1].toInt()],
                amount: amt < 0 ? null : amt,
                category: _cat(n[3].toInt()),
                payment: _payments[n[4].toInt()],
                inst: n[5].toInt() < 2 ? null : n[5].toInt(),
              ));
          final after = {for (final t in repo.transactions) if (t.id != target.id) _sig(t)};
          if (repo.transactions.length != before) _v('CORRECT_COUNT', '$op');
          if (after.length != others.length || !after.containsAll(others)) _v('CORRECT_TOUCHES_OTHERS', '$op: alterou outro lançamento');
        case 'addCat':
          final builtinsBefore = {for (final b in repo.budgets) if (!b.isCustom) b.category: b.name};
          final name = _catNames[n[0].toInt()];
          final created = repo.addBudgetCategory(name, n[1].toDouble());
          final builtinsAfter = {for (final b in repo.budgets) if (!b.isCustom) b.category: b.name};
          if (builtinsBefore.toString() != builtinsAfter.toString()) {
            _v('ADDCAT_OVERWRITES_BUILTIN', '$op: addBudgetCategory("$name") renomeou categoria nativa: $builtinsBefore -> $builtinsAfter');
          }
          if (created.name.trim().isEmpty) _v('ADDCAT_EMPTY_NAME', '$op: criou categoria "${created.name}" (código ${created.category})');
        case 'renameCat':
          final customs = repo.budgets.where((b) => b.isCustom).toList();
          if (customs.isEmpty) return;
          final c = customs[n[0].toInt() % customs.length];
          final spentBefore = c.currentSpent;
          final ok = repo.renameBudgetCategory(c.category, _catNames[n[1].toInt()]);
          final c2 = repo.budgets.firstWhere((b) => b.category == c.category, orElse: () => c);
          if (!repo.budgets.any((b) => b.category == c.category)) _v('RENAME_CHANGES_CODE', '$op');
          if (c2.currentSpent != spentBefore && !(c2.currentSpent.isNaN && spentBefore.isNaN)) _v('RENAME_CHANGES_SPENT', '$op: $spentBefore -> ${c2.currentSpent}');
          if (ok && c2.name != _catNames[n[1].toInt()].trim()) _v('RENAME_NAME', '$op');
        case 'removeCat':
          final bs = repo.budgets;
          final b = bs[n[0].toInt() % bs.length];
          repo.removeBudgetCategory(b.category);
          if (repo.transactions.length != before) _v('REMOVECAT_DELETES_TX', '$op');
          if (!b.isCustom && !repo.budgets.any((x) => x.category == b.category)) _v('REMOVECAT_BUILTIN', '$op');
        case 'setLimit':
          final bs = repo.budgets;
          repo.setBudgetLimit(bs[n[0].toInt() % bs.length].category, n[1].toDouble());
        case 'addGoal':
          repo.addGoal(FinancialGoal(id: 'goal-${_idCounter++}', title: 'Meta $_idCounter', targetAmount: n[0].toDouble()));
        case 'contribute':
          final gs = repo.goals;
          if (gs.isEmpty) return;
          final g = gs[n[0].toInt() % gs.length];
          final u = repo.contributeToGoal(g.id, n[1].toDouble());
          // Aporte NaN/∞/negativo é recusado de propósito (a meta não muda).
          if (_validMoney(n[1]) && (u.savedAmount - (g.savedAmount + n[1].toDouble())).abs() > 1e-6) _v('CONTRIBUTE_DELTA', '$op');
        case 'deleteGoal':
          final gs = repo.goals;
          if (gs.isEmpty) return;
          repo.deleteGoal(gs[n[0].toInt() % gs.length].id);
        case 'addReminder':
          repo.addReminder(FinancialReminder(
            id: 'rem-${_idCounter++}',
            title: 'Cobrar Fulano',
            personName: 'Fulano',
            amount: n[0].toDouble(),
            targetDate: DateTime.now().add(const Duration(days: 10)),
            type: ReminderType.loanReceivable,
          ));
        case 'debtPay':
          final rs = repo.reminders;
          if (rs.isEmpty) return;
          final r = rs[n[0].toInt() % rs.length];
          final balBefore = repo.totalBalance;
          // Since CHAOS-024 a settled debt refuses a new payment (StateError):
          // the refusal is the expected outcome, not an exception to report.
          if (r.isCompleted) {
            try {
              final res = repo.applyDebtPayment(r.id, n[1].toDouble());
              _v('DEBTPAY_ON_COMPLETED', '$op: pagamento aceito numa cobrança já quitada (${r.title}); gerou receita ${res.transaction.amount}');
            } on StateError {
              // recusado, como esperado
            }
            return;
          }
          final res = repo.applyDebtPayment(r.id, n[1].toDouble());
          if (repo.transactions.length != before + 1) _v('DEBTPAY_COUNT', '$op');
          final delta = repo.totalBalance - balBefore;
          if (delta.isFinite && balBefore.abs() < 1e12 && (delta - n[1].toDouble()).abs() > 1e-6 * max(1, balBefore.abs())) _v('DEBTPAY_BALANCE', '$op: saldo mudou $delta');
          if (r.isCompleted) _v('DEBTPAY_ON_COMPLETED', '$op: pagamento aceito numa cobrança já quitada (${r.title}); gerou receita ${res.transaction.amount}');
        case 'toggleRem':
          final rs = repo.reminders;
          if (rs.isEmpty) return;
          repo.toggleReminderCompleted(rs[n[0].toInt() % rs.length].id);
        case 'removeRem':
          final rs = repo.reminders;
          if (rs.isEmpty) return;
          repo.removeReminder(rs[n[0].toInt() % rs.length].id);
        case 'bill':
          final a = n[2].toDouble();
          repo.addBillWithMargin(title: 'Conta fuzz', billingDay: n[0].toInt(), dueDay: n[1].toInt(), amount: a < 0 ? null : a);
        case 'remember':
          // Memória de categoria: próximos rascunhos "Fuzz" vão para essa categoria.
          repo.rememberCategoryOverride('Fuzz', _cat(n[0].toInt()));
      }
    } on ArgumentError {
      // Recusa intencional de entrada inválida (nome vazio, valor inválido).
    } on StateError {
      // Recusa intencional de estado inválido (ex.: dívida já quitada).
    } catch (err) {
      _v('EXCEPTION:${op.kind}', '$op: $err');
    }
    _checkGlobal(op);
  }

  void _checkGlobal(_Op op) {
    final txs = repo.transactions;
    final now = DateTime.now();

    // I1 — saldo recalculado do zero.
    var inc = 0.0, out = 0.0;
    for (final t in txs) {
      if (t.type == TransactionType.income) {
        inc += t.amount;
      } else {
        out += t.amount;
      }
    }
    final expected = inc - out;
    final bal = repo.totalBalance;
    final balOk = (bal.isNaN && expected.isNaN) || bal == expected || (bal - expected).abs() <= 1e-6 * max(1.0, expected.abs());
    if (!balOk) _v('I1_BALANCE', 'após $op: totalBalance=$bal esperado=$expected');

    // I2 — ids únicos.
    final ids = <String>{};
    for (final t in txs) {
      if (!ids.add(t.id)) {
        _v('I2_DUPLICATE_ID', 'após $op: id ${t.id} repetido');
        break;
      }
    }

    // I3 — valores válidos. Chaveado pela operação que introduziu o valor
    // ruim, para separar "addTransaction aceita qualquer coisa" de
    // "addTransactionFromDraft deixa passar NaN" etc.
    for (final t in txs) {
      if (_knownBad.contains(t.id)) continue;
      if (t.amount.isNaN || t.amount.isInfinite || t.amount <= 0) {
        _knownBad.add(t.id);
        _v('I3_BAD_AMOUNT@${op.kind}', 'após $op: ${t.id} "${t.title}" amount=${t.amount}');
      } else if (t.amount < 0.01) {
        _knownBad.add(t.id);
        _v('I3_SUBCENT_AMOUNT', 'após $op: ${t.id} amount=${t.amount}');
      }
    }

    // I4 — currentSpent = despesas do mês corrente daquela categoria.
    for (final b in repo.budgets) {
      final spent = txs
          .where((t) => t.type == TransactionType.expense && t.category == b.category && t.date.year == now.year && t.date.month == now.month)
          .fold(0.0, (a, t) => a + t.amount);
      final ok = (spent.isNaN && b.currentSpent.isNaN) || (b.currentSpent - spent).abs() <= 1e-6 * max(1.0, spent.abs());
      if (!ok) {
        _v('I4_CURRENT_SPENT', 'após $op: ${b.category} currentSpent=${b.currentSpent} esperado=$spent');
        break;
      }
    }

    // I5/I6 — códigos e nomes de categoria únicos.
    final codes = <String>{};
    final names = <String>{};
    for (final b in repo.budgets) {
      if (!codes.add(b.category)) _v('I5_DUPLICATE_CATEGORY_CODE', 'após $op: ${b.category}');
      if (!names.add(_fold(b.name))) _v('I6_DUPLICATE_CATEGORY_NAME', 'após $op: dois orçamentos exibidos como "${b.name}"');
    }

    // I7 — metas.
    for (final g in repo.goals) {
      if (_knownBad.contains(g.id)) continue;
      if (!g.savedAmount.isFinite || g.savedAmount < 0) {
        _knownBad.add(g.id);
        _v('I7_GOAL_SAVED@${op.kind}', 'após $op: savedAmount=${g.savedAmount}');
      } else if (!g.targetAmount.isFinite || g.targetAmount <= 0) {
        _knownBad.add(g.id);
        _v('I7_GOAL_TARGET@${op.kind}', 'após $op: targetAmount=${g.targetAmount}');
      }
    }

    // I8 — cobranças: saldo devedor nunca negativo/NaN; quitada ⇔ saldo 0 não é exigido
    // (toggle manual), mas saldo > anterior sem nova dívida é bug.
    for (final r in repo.reminders) {
      final a = r.amount;
      if (_knownBad.contains(r.id)) continue;
      if (a != null && (!a.isFinite || a < 0)) {
        _knownBad.add(r.id);
        _v('I8_REMINDER_AMOUNT@${op.kind}', 'após $op: ${r.id} amount=$a');
      }
    }

    // I9 — agregados do mês coerentes entre si.
    final byCat = repo.categoryExpensesThisMonth.values.fold(0.0, (a, x) => a + x);
    final transfers = txs
        .where((t) => t.type == TransactionType.transfer && t.date.year == now.year && t.date.month == now.month)
        .fold(0.0, (a, t) => a + t.amount);
    final me = repo.monthExpense;
    if (me.isFinite && ((byCat + transfers) - me).abs() > 1e-6 * max(1.0, me.abs())) {
      _v('I9_MONTH_EXPENSE', 'após $op: monthExpense=$me Σcategorias+transf=${byCat + transfers}');
    }
  }
}

/// Reexecuta [ops] num repositório novo; true se a violação [kind] aparece.
bool _reproduces(List<_Op> ops, String kind) {
  final r = _Runner();
  for (final op in ops) {
    r.apply(op);
    if (r.violations.containsKey(kind)) return true;
  }
  return false;
}

/// ddmin simplificado: remove blocos (metade, quarto, … um) enquanto a
/// violação continuar reproduzindo.
List<_Op> _minimize(List<_Op> ops, String kind) {
  var cur = List.of(ops);
  var chunk = max(1, cur.length ~/ 2);
  var budget = 600; // teto de reexecuções para manter o teste rápido
  while (chunk >= 1 && budget > 0) {
    var removedAny = false;
    for (var start = 0; start < cur.length && budget > 0;) {
      final cand = [...cur.sublist(0, start), ...cur.sublist(min(cur.length, start + chunk))];
      budget--;
      if (cand.isNotEmpty && _reproduces(cand, kind)) {
        cur = cand;
        removedAny = true;
      } else {
        start += chunk;
      }
    }
    if (!removedAny) {
      if (chunk == 1) break;
      chunk = max(1, chunk ~/ 2);
    }
  }
  return cur;
}

void main() {
  test('chaos: fuzzing do FinancialRepository com invariantes', () async {
    final sw = Stopwatch()..start();
    final found = <String, (int, String, List<_Op>)>{};
    var totalOps = 0;
    for (final seed in _seeds) {
      // ignore: avoid_print
      print('CHAOS|SEED|$seed ops=$_opsPerSeed');
      final rnd = Random(seed);
      final runner = _Runner();
      final history = <_Op>[];
      for (var i = 0; i < _opsPerSeed; i++) {
        final op = _randomOp(rnd);
        history.add(op);
        final known = runner.violations.keys.toSet();
        runner.apply(op);
        totalOps++;
        for (final k in runner.violations.keys) {
          if (known.contains(k) || found.containsKey(k)) continue;
          found[k] = (seed, runner.violations[k]!, List.of(history));
        }
      }
    }

    for (final entry in found.entries) {
      final (seed, detail, history) = entry.value;
      final minimal = _minimize(history, entry.key);
      final stable = _reproduces(minimal, entry.key);
      // ignore: avoid_print
      print('CHAOS|${entry.key}|seed=$seed passo=${history.length}|$detail');
      // ignore: avoid_print
      print('CHAOS|${entry.key}|mínimo (${minimal.length} ops${stable ? '' : ', instável/depende de tempo'}): ${minimal.join(' → ')}');
    }
    // ignore: avoid_print
    print('CHAOS|RESUMO|seeds=$_seeds operações=$totalOps violações_distintas=${found.length} ops_executadas_incl_minimização=$_applied tempo=${sw.elapsedMilliseconds}ms');
    await Future<void>.delayed(Duration.zero); // drena os _persistAll pendentes
    // 6000 operações + minimização levam ~50 s nesta máquina: mais que o
    // limite padrão de 30 s do flutter_test (sonda, não teste de regressão).
  }, timeout: const Timeout(Duration(minutes: 3)));

  // Cenários determinísticos que confirmam (ou descartam) as hipóteses que o
  // fuzzer levantou — cada um imprime `CHAOS|CENARIO|...` só quando viola.
  test('chaos: cenários determinísticos do repositório', () {
    void report(String name, bool violated, String detail) {
      // ignore: avoid_print
      if (violated) print('CHAOS|CENARIO|$name|$detail');
    }

    FinancialTransactionDraft d(double? amount, {String intent = 'expense', String cat = 'supermarket', String desc = 'Fuzz'}) => FinancialTransactionDraft(
        intent: intent, intentConfidence: 1, category: cat, paymentMethod: 'pix', amount: amount, dateOffsetDays: 0,
        description: desc, rawText: desc, latencyMs: 0, isComplete: true, missingSlots: const []);

    // Multi-lançamento do chat: dois rascunhos salvos no mesmo milissegundo.
    var r = FinancialRepository(persistence: _NullPersistence());
    final a = r.addTransactionFromDraft(d(20, desc: 'Uber', cat: 'transport'));
    final b = r.addTransactionFromDraft(d(30, desc: 'Mercado'));
    final n0 = r.transactions.length;
    r.deleteTransaction(b.first.id);
    report('MULTI_SAME_ID_DELETE', a.first.id == b.first.id && r.transactions.length == n0 - 2,
        'ids ${a.first.id}/${b.first.id}; apagar só o Mercado apagou também o Uber (${n0 - r.transactions.length} removidos)');

    // NaN/infinito passam pelo filtro `amount <= 0` de addTransactionFromDraft.
    for (final bad in [double.nan, double.infinity]) {
      r = FinancialRepository(persistence: _NullPersistence());
      final saved = r.addTransactionFromDraft(d(bad));
      report('DRAFT_ACCEPTS_$bad', saved.isNotEmpty, 'salvou amount=$bad; totalBalance=${r.totalBalance}');
    }

    // Pagamento de dívida com valor 0 / negativo.
    for (final amt in [0.0, -50.0]) {
      r = FinancialRepository(persistence: _NullPersistence());
      final rem = r.reminders.firstWhere((x) => x.type == ReminderType.loanReceivable);
      // Since CHAOS-016 the repository refuses (ArgumentError) instead of accepting.
      try {
        final res = r.applyDebtPayment(rem.id, amt);
        report('DEBTPAY_$amt', true, 'aceito: receita de ${res.transaction.amount}, saldo devedor ${rem.amount} -> ${res.remainingBalance}');
      } on ArgumentError {
        report('DEBTPAY_$amt', false, 'recusado');
      }
    }

    // Meta: aporte negativo.
    r = FinancialRepository(persistence: _NullPersistence());
    r.addGoal(FinancialGoal(id: 'g', title: 'Viagem', targetAmount: 1000));
    final g = r.contributeToGoal('g', -300);
    report('GOAL_NEGATIVE', g.savedAmount < 0, 'savedAmount=${g.savedAmount}');

    // Categoria com nome igual ao de uma nativa / nome só com símbolos.
    r = FinancialRepository(persistence: _NullPersistence());
    final dup = r.addBudgetCategory('Supermercado', 500);
    report('ADDCAT_DUP_DISPLAY_NAME', r.budgets.where((x) => _fold(x.name) == 'supermercado').length > 1,
        'criou ${dup.category}/"${dup.name}" ao lado da nativa supermarket/"Supermercado"');
    final sym = r.addBudgetCategory('!!!', 100);
    final sym2 = r.addBudgetCategory('???', 200);
    report('ADDCAT_SYMBOLS_COLLIDE', sym.category == sym2.category,
        '"!!!" e "???" viram o mesmo código "${sym.category}"; o segundo sobrescreveu o primeiro (nome agora "${sym2.name}")');

    // Excluir categoria custom e recriar: gasto do mês some do orçamento.
    r = FinancialRepository(persistence: _NullPersistence());
    r.addBudgetCategory('Pets', 300);
    r.addTransactionFromDraft(d(120, cat: 'pets', desc: 'Ração'));
    r.removeBudgetCategory('pets');
    final again = r.addBudgetCategory('Pets', 300);
    report('READD_CATEGORY_SPENT_ZERO', again.currentSpent == 0,
        'após recriar "Pets", currentSpent=${again.currentSpent} mas há R\$ 120 de despesa em pets neste mês');

    // Conta com margem sem valor vira despesa de R$ 0.
    r = FinancialRepository(persistence: _NullPersistence());
    r.addBillWithMargin(title: 'Internet', billingDay: 5, dueDay: 15);
    report('BILL_ZERO_AMOUNT', r.transactions.first.amount == 0, 'lançamento "Internet" com amount=0.0');

    // Transferência reduz o saldo total (conta como saída) mas não entra em orçamento.
    r = FinancialRepository(persistence: _NullPersistence());
    final bal0 = r.totalBalance;
    r.addTransactionFromDraft(d(1000, intent: 'transfer', desc: 'Transferência pra poupança'));
    report('TRANSFER_REDUCES_BALANCE', r.totalBalance == bal0 - 1000, 'saldo $bal0 -> ${r.totalBalance} por uma transferência');

    // Correção com intent 'unknown' vira despesa (troca o tipo de uma receita).
    r = FinancialRepository(persistence: _NullPersistence());
    final inc = r.addTransactionFromDraft(d(500, intent: 'income', cat: 'salary', desc: 'Freela')).first;
    r.applyDraftCorrection(inc.id, d(null, intent: 'unknown', cat: 'unknown'));
    final after = r.transactions.firstWhere((t) => t.id == inc.id);
    report('CORRECTION_UNKNOWN_FLIPS_TYPE', after.type != TransactionType.income, 'receita virou ${after.type} com um rascunho de intent "unknown"');
  });
}

/// Mesma faixa que o repositório aceita como dinheiro: R$ 0,01 a R$ 100 bilhões.
bool _validMoney(num v) => v.isFinite && v >= 0.01 && v <= 1e11;
