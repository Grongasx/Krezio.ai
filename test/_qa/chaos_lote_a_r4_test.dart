// Teste do caos — Item 2, lote A, REVALIDAÇÃO r4 depois da 7e (rede de
// confirmação: `EntryCertainty` + 5º check do `EntrySafetyGate`,
// `_confirmBatchIfUnsure`, empréstimo pelo gate) — etapa 6''' do portão de
// qualidade do PLANO_CESAR.md (cesar-chaos).
//
// NÃO falha a suíte: só imprime, com o prefixo `CHAOS-D|`.
//   flutter test test/_qa/chaos_lote_a_r4_test.dart 2>&1 | grep "CHAOS-D|"
//   # só violações: ... | grep -E "CHAOS-D\|(ALVO-V|CTRL-V|GATECLOCK-V|CERT-V|MIN|RESUMO|FUZZ\| primeira)"
//   # todas as violações do fuzz: D_ALLV=1 flutter test test/_qa/chaos_lote_a_r4_test.dart
//   # mais volume:  D_SEEDS=60 D_LEN=300 flutter test test/_qa/chaos_lote_a_r4_test.dart
//   # sonda (reproduzir uma sequência): D_PROBE='frase 1 ⏎ frase 2' flutter test test/_qa/chaos_lote_a_r4_test.dart --plain-name sonda
//
// Vocabulário, títulos de fixtures e seeds NOVOS (20261400+n). Mira:
// - a rede de certeza: frases que deveriam ser certeza baixa e passam como
//   alta (gravação errada sem confirmação = P0) e frases claras que pedem
//   "Registro assim?" (falso positivo, medido por tipo, com denominador);
// - o estado "Registro assim?": sim/não/correção/frase nova/pergunta/
//   comando/desfazer/reinício/Extrato no meio; "sim" grava exatamente o que
//   foi mostrado e nada mais;
// - os caminhos de gravação listados pela 7e (parse, mergeDrafts, lote,
//   empréstimo, notificação bancária, correção livre, "o que mudar?",
//   "na verdade o X…", edição/exclusão, cópias "repete/mais N/o mesmo de
//   ontem", dívida, vencimento recorrente, metas): algum grava sem checagem?
// Invariantes: todos os do chaos_lote_a_r3 + "o que é gravado após 'sim' é
// idêntico ao que foi mostrado" + "nenhum 'Registro assim?' em frase clara do
// conjunto de controle".
//
// `SimD` é o `SimC` do chaos_lote_a_r3_test.dart conferido contra o
// `_sendMessage` atual (pós-7e): o único passo que mudou no chat é que o
// "cancela" do passo 0 e do lote (0b) passa o rascunho pendente
// (`isCancelCommand(text, pending: …)`), para o "não" ao "Registro assim?"
// descartar. A confirmação em si mora no rascunho (slot 'confirm') e no lote
// (`multiClarificationPrompt` → "Registro assim?"), sem passo novo no chat.
// Achados em docs/qa/findings-caos-lote-a-r4.md (IDs CHAOS-D-…).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/entry_certainty.dart';
import 'package:krezio_ai/ai/entry_safety_gate.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chaos_lote_a_r2_test.dart' as b;
import 'chaos_r3_support.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
final DateTime today = _day(DateTime.now());
String ddmmyy(DateTime d) => b.ddmmyy(d);
DateTime back(int n, [DateTime? now]) => b.back(n, now);
DateTime wdLast(int wd, [DateTime? now]) => b.wdLast(wd, now);
DateTime? diaN(int n, [DateTime? now]) => b.diaN(n, now);
int dayDiff(DateTime a, DateTime from) => DateTime.utc(a.year, a.month, a.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
String dm(DateTime d) => '${d.day}/${d.month}';

const monthNames = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const wdNames = {1: 'segunda', 2: 'terça', 3: 'quarta', 4: 'quinta', 5: 'sexta', 6: 'sábado', 7: 'domingo'};

final confirmRe = RegExp(r'Registro assim\?');

/// Um turno com o oráculo. Estende o `LT` do r2 com o que esta rodada mede.
class LD extends b.LT {
  bool fullNew = false; // frase nova completa: nenhum estado pendente sobrevive sem aviso
  bool noEdit = false; // nenhum registro existente pode mudar neste turno
  bool orphan = false; // resposta solta sem pendência: não pode virar lançamento
  bool discount = false;
  bool dateAskOk = false;
  bool hasMarker = false;
  bool plainFact = false;
  /// Frase clara do conjunto de controle (fato no passado, verbo de dinheiro
  /// explícito, sem dúvida): "Registro assim?" aqui é falso positivo (P2).
  bool ctrl = false;
  /// Frase que NÃO diz com certeza que aconteceu (não é plano explícito):
  /// gravar sem "Registro assim?" é P0 quando o "evento" não é dinheiro que
  /// se moveu (`lowIsWrong`), P1 quando só faltou confirmar.
  bool lowCert = false;
  bool lowIsWrong = true;
  /// Resposta ao "Registro assim?": 'sim' | 'nao' | 'fix' | outro.
  String? confirmReply;
  String? op; // '⟲reinicio' | '⟲nuvem' | '⟲extrato-edita[:título]' | '⟲extrato-apaga[:título]'
  LD(super.text, super.family);
}

LD opTurn(String op) => LD(op, 'op')..op = op;

/// O que o "Registro assim?" mostrou: um item por lançamento, lido do TEXTO
/// mostrado ao usuário (e do rascunho, para o tipo de coisa que o texto não diz).
class Shown {
  final String kind; // despesa | receita | transferência
  final double? amount;
  final String what;
  final String pay; // '' | 'no Pix' | ...
  final String when; // hoje | ontem | dd/mm
  final int? repeatDays;
  final bool recurrent;
  final int? installments;
  Shown(this.kind, this.amount, this.what, this.pay, this.when, {this.repeatDays, this.recurrent = false, this.installments});
  @override
  String toString() => '$kind ${amount ?? '-'} "$what" $pay $when${(repeatDays ?? 1) > 1 ? ' ×$repeatDays dias' : ''}${recurrent ? ' REC' : ''}';
}

/// Lê "Vou registrar **despesa de R$ 380,00 — Air fryer, no Pix, hoje**".
Shown? parseShownSingle(String text, FinancialTransactionDraft? d) {
  final m = RegExp(r'Vou registrar \*\*(despesa|receita|transferência)(?: de R\$ ([\d.]+,\d{2}))?(?: — (.*?))?(?:, (no Pix|no crédito|no débito|em dinheiro|no boleto)(?: em (\d+)x)?)?, (hoje|ontem|\d{2}/\d{2})\*\*')
      .firstMatch(text);
  if (m == null) return null;
  final amount = m.group(2) == null ? null : double.parse(m.group(2)!.replaceAll('.', '').replaceAll(',', '.'));
  return Shown(m.group(1)!, amount, m.group(3) ?? '', m.group(4) ?? '', m.group(6)!,
      repeatDays: d?.repeatDays, recurrent: d?.isRecurrent ?? false, installments: m.group(5) == null ? null : int.parse(m.group(5)!));
}

/// "Anotei 2 lançamentos: R$ 30,00 (Farmácia) e R$ 20,00 (Padaria). Registro assim?"
List<Shown>? parseShownBatch(String text, List<FinancialTransactionDraft>? batch) {
  final m = RegExp(r'Anotei (\d+) lançamentos: (.*)\. Registro assim\?').firstMatch(text);
  if (m == null) return null;
  final items = RegExp(r'R\$ ([\d.]+,\d{2}) \(([^)]*)\)').allMatches(m.group(2)!).toList();
  return [
    for (var i = 0; i < items.length; i++)
      Shown(batch != null && i < batch.length ? (batch[i].intent == 'income' ? 'receita' : (batch[i].intent == 'transfer' ? 'transferência' : 'despesa')) : '?',
          double.parse(items[i].group(1)!.replaceAll('.', '').replaceAll(',', '.')), items[i].group(2)!, '', '?',
          repeatDays: batch != null && i < batch.length ? batch[i].repeatDays : null, recurrent: batch != null && i < batch.length && batch[i].isRecurrent),
  ];
}

// ───────────────────────── simulador do chat (ordem ATUAL, pós-7e) ─────────────────────────

class SimD {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  FinancialTransactionDraft? last;
  List<String> lastIds = const [];
  List<FinancialTransactionDraft>? pendingBatch;
  final List<Snap3> preSaves = [];
  static int _goalSeq = 0;

  /// Quem gravou neste turno (rota de gravação), para os achados por caminho.
  final List<String> savePaths = [];

  SimD(this.engine, this.repo, {DateTime Function()? now}) : assistant = CesarAssistant(repository: repo, engine: engine, now: now);

  bool get draftPending => active != null && !active!.isComplete;
  bool get anyPending => draftPending || pendingBatch != null || assistant.hasPendingQuestion;
  bool get confirmPending =>
      (draftPending && active!.missingSlots.contains('confirm')) ||
      (pendingBatch != null && pendingBatch!.any((d) => !d.isComplete && d.missingSlots.contains('confirm')));

  R3Reply send(String input) {
    preSaves.clear();
    savePaths.clear();
    final r = _send(input.trim());
    final notice = assistant.takeNotice();
    if (notice != null) return R3Reply(r.route, '$notice\n\n${r.text}', r.draft);
    return r;
  }

  List<String> _add(FinancialTransactionDraft d, String path) {
    preSaves.add(Snap3.of(repo));
    savePaths.add(path);
    return repo.addTransactionFromDraft(d).map((t) => t.id).toList();
  }

  void _saved(List<String> ids) {
    lastIds = ids;
    assistant.recordCreated(ids);
  }

  void _sync(AssistantReply reply) {
    if (lastIds.any(reply.removedIds.contains)) {
      lastIds = const [];
      last = null;
    }
  }

  R3Reply _send(String input) {
    var text = input;
    if (text.isEmpty) return R3Reply('empty_ignored', '(chat ignora mensagem vazia)');
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();

    // 0 (7e): o rascunho pendente vai junto — "não" ao "Registro assim?" descarta.
    if (active != null && !active!.isComplete && engine.isCancelCommand(text, pending: active)) {
      active = null;
      return R3Reply('cancel_pending', 'Tudo bem, descartei esse lançamento. Nada foi registrado. 👍');
    }

    if (pendingBatch != null) {
      final batch = pendingBatch!;
      if (engine.isCancelCommand(text, pending: batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first))) {
        pendingBatch = null;
        return R3Reply('cancel_pending', 'Tudo bem, descartei esses lançamentos. Nada foi registrado. 👍');
      }
      final whatIf = assistant.hypothesisReply(text);
      if (whatIf != null) return R3Reply(whatIf.route, whatIf.text);
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (!engine.startsNewTransaction(firstOpen, text)) {
        final merged = engine.mergeMultiDrafts(batch, text);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          pendingBatch = null;
          return _saveBatch(merged, path: 'lote-resposta');
        }
        pendingBatch = merged;
        return R3Reply('ask_multi', prompt);
      }
      pendingBatch = null;
    }

    final cmd = assistant.handleCommand(text, hasPendingDraft: active != null && !active!.isComplete);
    if (cmd != null && cmd.rewrittenInput != null) {
      text = cmd.rewrittenInput!;
    } else if (cmd != null) {
      _sync(cmd);
      active = null;
      if (cmd.route == 'saved') savePaths.add('assistente:${cmd.route}');
      return R3Reply(cmd.route, cmd.text);
    }

    final lower = text.toLowerCase();
    if (last != null &&
        (active == null || active!.isComplete) &&
        last!.isRecurrent &&
        RegExp(r'dia\s+[uú]til|\b(?:todo|vence(?:\s+no)?|cai(?:\s+no)?)\s+dia\s+\d').hasMatch(lower) &&
        !RegExp(r'\d+(?:[.,]\d+)?\s*(?:reais|real)|r\$').hasMatch(lower)) {
      final updated = engine.applyCorrection(last!, text);
      last = updated.isCanceled ? null : updated;
      final before = repo.transactions.where((t) => lastIds.contains(t.id)).toList();
      if (!updated.isCanceled) assistant.recordExternalEdit(before);
      for (final id in lastIds) {
        if (updated.isCanceled) {
          repo.deleteTransaction(id);
        } else {
          repo.applyDraftCorrection(id, updated);
        }
      }
      if (updated.isCanceled) lastIds = const [];
      return R3Reply(updated.isCanceled ? 'correction_cancel' : 'correction', updated.clarificationPrompt ?? 'Lançamento atualizado com sucesso!', updated);
    }

    String? preface;
    final debt = DebtPaymentParser.parse(text);
    if (debt != null) {
      final matches = repo.findDebtorsByName(debt.personName);
      if (matches.isEmpty) {
        preface = DebtPaymentParser.noOpenDebtNote(debt.personName);
      } else if (matches.length == 1) {
        final res = repo.applyDebtPayment(matches.first.id, debt.amountPaid);
        return R3Reply('debt', '${debt.personName} pagou ${res.amountPaid}; resta ${res.remainingBalance}');
      } else {
        return R3Reply('debt', 'ambíguo: ${debt.personName}');
      }
    }

    final goalCreation = GoalParser.parseCreation(text);
    if (goalCreation != null) {
      repo.addGoal(FinancialGoal(id: 'goal-d-${++_goalSeq}', title: goalCreation.title, targetAmount: goalCreation.targetAmount, targetDate: goalCreation.targetDate));
      return R3Reply('goal_create', 'Meta criada: "${goalCreation.title}" ${goalCreation.targetAmount}');
    }
    final goalContribution = GoalParser.parseContribution(text);
    if (goalContribution != null) {
      final matches = repo.findGoalsByTitle(goalContribution.goalTitle);
      if (matches.length == 1) {
        final g = repo.contributeToGoal(matches.first.id, goalContribution.amount);
        return R3Reply('goal_contrib_legacy', '"${g.title}" ${g.savedAmount}/${g.targetAmount}');
      }
      return R3Reply('goal_contrib_legacy', 'meta não encontrada: "${goalContribution.goalTitle}"');
    }

    final afford = AffordabilityAnalyzer(repository: repo).analyze(text);
    if (afford != null) return R3Reply('afford:${afford.verdict.name}', afford.formattedText);

    final answer = assistant.handleQuestion(text);
    if (answer != null) {
      _sync(answer);
      active = null;
      return R3Reply(answer.route, answer.text);
    }

    final pendingDraft = active != null && !active!.isComplete;
    if (!pendingDraft || engine.startsNewTransaction(active!, text)) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        final dropped = pendingDraft ? LocalFinancialNlpEngine.discardedDraftNotice(active!) : null;
        active = null;
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) {
          final r = _saveBatch(multi, path: 'lote');
          return dropped == null ? r : R3Reply(r.route, '$dropped\n\n${r.text}', r.draft);
        }
        pendingBatch = multi;
        return R3Reply('ask_multi', dropped == null ? prompt : '$dropped\n\n$prompt');
      }
    }

    FinancialTransactionDraft draft;
    var merged = false;
    String? discardedNotice;
    if (active != null && !active!.isComplete && !engine.startsNewTransaction(active!, text)) {
      draft = engine.mergeDrafts(active!, text);
      merged = true;
    } else {
      if (active != null && !active!.isComplete) discardedNotice = LocalFinancialNlpEngine.discardedDraftNotice(active!);
      draft = engine.parse(text);
    }
    if (draft.isComplete) draft = repo.applyCategoryMemory(draft);

    var route = draft.isComplete ? 'saved' : 'ask';
    var responseText = draft.clarificationPrompt ?? 'Lançamento registrado: ${draft.amount} ${draft.description} ${draft.category} ${draft.paymentMethod}';
    if (draft.isComplete && !merged && draft.assumptionNote != null) responseText = '$responseText ${draft.assumptionNote}';
    if (draft.isComplete && draft.budgetInsight != null) responseText = '$responseText ${draft.budgetInsight}';
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      _saved(_add(draft, merged ? 'merge' : (draft.bankSource != null ? 'notificação' : (draft.isReminder ? 'empréstimo' : 'parse'))));
      if (draft.isReminder) {
        repo.addReminder(FinancialReminder(
          id: 'rem-d-${repo.reminders.length + 1}-${DateTime.now().microsecondsSinceEpoch}',
          title: draft.description,
          personName: draft.personName,
          amount: draft.amount,
          targetDate: draft.targetDate ?? DateTime.now().add(const Duration(days: 30)),
          type: draft.reminderType == 'loan_receivable'
              ? ReminderType.loanReceivable
              : (draft.reminderType == 'dividend' ? ReminderType.dividend : ReminderType.general),
        ));
      }
      last = draft;
      active = null;
    } else if (!draft.isComplete) {
      active = draft;
    }
    if (draft.intent == 'query') {
      route = 'query';
      responseText = engine.replyForQuestion(draft);
      active = null;
    } else if (draft.intent == 'unknown' && !merged) {
      route = 'unknown';
      active = null;
    }
    if (preface != null) responseText = '$preface\n\n$responseText';
    if (discardedNotice != null) responseText = '$discardedNotice\n\n$responseText';
    return R3Reply(route, responseText, draft);
  }

  R3Reply _saveBatch(List<FinancialTransactionDraft> drafts, {required String path}) {
    for (final d in drafts) {
      _saved(_add(d, path));
    }
    last = drafts.last;
    return R3Reply('multi', 'Identifiquei ${drafts.length} lançamentos: ${drafts.map((d) => '${d.amount} ${d.description}').join('; ')}');
  }
}

// ───────────────────────── fixtures (títulos NOVOS) ─────────────────────────
// Hoje (2026-10-01/02): títulos com palavras de resposta ("Sim", "Ok",
// "Talvez", "Não Sei", "Pode Ser", "Será"), numéricos e duplicados.

List<FinancialTransaction> fixturesD([DateTime? now]) {
  final t = _day(now ?? today);
  FinancialTransaction f(String id, String title, double amount, String cat, DateTime d, {TransactionType type = TransactionType.expense}) =>
      FinancialTransaction(id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: 'pix', date: d.add(const Duration(hours: 12)));
  return [
    f('dx-bar-sim', 'Bar Sim Senhor', 48, 'leisure', back(1, t)),
    f('dx-mercadinho-talvez', 'Mercadinho Talvez', 63, 'supermarket', back(2, t)),
    f('dx-loja-pode-ser', 'Loja Pode Ser', 120, 'expense_other', back(3, t)),
    f('dx-lanchonete-nao-sei', 'Lanchonete Não Sei', 29, 'leisure', back(4, t)),
    f('dx-pastelaria-3', 'Pastelaria 3 Irmãos', 18, 'leisure', back(1, t)),
    f('dx-restaurante-1900', 'Restaurante 1900', 145, 'leisure', back(5, t)),
    f('dx-acai-quem-sabe', 'Açaí Quem Sabe', 22, 'leisure', back(2, t)),
    f('dx-padaria-ok', 'Padaria Ok', 16, 'supermarket', back(6, t)),
    f('dx-sacolao-sera', 'Sacolão Será', 57, 'supermarket', wdLast(3, t)),
    f('dx-posto-isso-ai', 'Posto Isso Aí', 210, 'transport', wdLast(2, t)),
    f('dx-feira-a', 'Feira', 41, 'supermarket', back(3, t)),
    f('dx-feira-b', 'Feira', 43, 'supermarket', back(8, t)),
    f('dx-sala', 'Aluguel da sala', 900, 'income_other', back(3, t), type: TransactionType.income),
    f('dx-bico', 'Bico de garçom', 180, 'income_other', back(8, t), type: TransactionType.income),
  ];
}

Future<FinancialRepository> freshRepoD([DateTime? now]) async {
  SharedPreferences.setMockInitialValues({});
  final repo = FinancialRepository();
  await repo.initialize();
  for (final t in fixturesD(now)) {
    repo.addTransaction(t);
  }
  repo.addGoal(FinancialGoal(id: 'g-moto', title: 'Moto', targetAmount: 9000, savedAmount: 700));
  repo.addGoal(FinancialGoal(id: 'g-intercambio', title: 'Intercâmbio', targetAmount: 15000));
  repo.addReminder(FinancialReminder(
      id: 'rem-bia', title: 'Bia me deve', personName: 'Bia', amount: 180, targetDate: today.add(const Duration(days: 15)), type: ReminderType.loanReceivable));
  return repo;
}

// ───────────────────────── sonda ─────────────────────────

Future<List<String>> probeSeq(LocalFinancialNlpEngine engine, List<String> turns) async {
  final repo = await freshRepoD();
  final sim = SimD(engine, repo);
  final out = <String>[];
  for (final t in turns) {
    if (t.startsWith('⟲')) {
      if (t == '⟲reinicio') {
        await repo.flushPendingWrites();
      }
      out.add(t);
      continue;
    }
    final before = Snap3.of(repo);
    final r = sim.send(t);
    final after = Snap3.of(repo);
    final added = after.tx.keys.where((k) => !before.tx.containsKey(k)).map((k) => describeTx(after.tx[k]!)).toList();
    final changed = before.tx.keys.where((k) => after.tx.containsKey(k) && after.tx[k] != before.tx[k]).map((k) => '${describeTx(before.tx[k]!)}⇒${describeTx(after.tx[k]!)}').toList();
    final removed = before.tx.keys.where((k) => !after.tx.containsKey(k)).map((k) => describeTx(before.tx[k]!)).toList();
    final d = r.draft;
    out.add('"$t" → ${r.short}'
        '${added.isEmpty ? '' : ' +$added'}${changed.isEmpty ? '' : ' Δ$changed'}${removed.isEmpty ? '' : ' −$removed'}'
        '${d == null ? '' : ' {${d.intent} ${d.amount} ${d.description} ${d.paymentMethod} off=${d.dateOffsetDays} miss=${d.missingSlots} rep=${d.repeatDays} rec=${d.isRecurrent}}'}'
        '${sim.confirmPending ? ' [CONFIRM-PENDENTE]' : ''}${sim.savePaths.isEmpty ? '' : ' via=${sim.savePaths}'}');
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  test('sonda', () async {
    final env = Platform.environment['D_PROBE'];
    final file = Platform.environment['D_PROBE_FILE'];
    final seqs = <List<String>>[
      if (env != null) env.split(' ⏎ '),
      if (file != null)
        for (final l in File(file).readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.startsWith('#'))) l.split(' ⏎ '),
    ];
    for (final s in seqs) {
      final out = await probeSeq(engine, s);
      print('CHAOS-D|SONDA| ${out.join(' ⏎ ')}');
      print('CHAOS-D|SONDA-CERT| ${EntryCertainty.read([s.first])}');
    }
  });
}
