// Teste do caos — Item 2, lote A, REVALIDAÇÃO FINAL depois de 7a, 7b, 7c
// (`EntrySafetyGate`) e 7d (`PendingReplyCheck`) — etapa 6'' do portão de
// qualidade do PLANO_CESAR.md (cesar-chaos).
//
// NÃO falha a suíte: só imprime, com o prefixo `CHAOS-C|`.
//   flutter test test/_qa/chaos_lote_a_r3_test.dart 2>&1 | grep "CHAOS-C|"
//   # só violações: ... | grep -E "CHAOS-C\|(ALVO-V|GATECLOCK-V|CHECKCLOCK-V|REFCLOCK-V|MIN|RESUMO|FUZZ\| primeira)"
//   # todas as violações do fuzz: C_ALLV=1 flutter test test/_qa/chaos_lote_a_r3_test.dart
//   # mais volume:  C_SEEDS=60 C_LEN=300 flutter test test/_qa/chaos_lote_a_r3_test.dart
//
// Vocabulário, títulos de fixtures e seeds NOVOS (20261300+n). Mira:
// - `EntrySafetyGate`: deixar passar erro (direção, data, números, intenção)
//   e perguntar à toa (falso positivo medido por tipo, com denominador);
// - `PendingReplyCheck`: pendências encadeadas (rascunho → pergunta no meio →
//   comando → resposta tardia → desfazer), mudança de assunto, respostas
//   ambíguas, "passa/muda/edita" sozinhos, "na verdade o X…", 2+ sugestões,
//   títulos numéricos e com palavra de data;
// - desfazer exato (oráculo de snapshots), Extrato (edição externa),
//   reinício do app e snapshot da nuvem no meio de pendências;
// - relógio injetado no gate, no PendingReplyCheck e no CesarAssistant
//   (1º do mês, 29/02, 31/12, 01/01, domingo × segunda).
// Invariantes: todos os do chaos_r3_support / chaos_lote_a / chaos_lote_a_r2 +
// "nenhuma pergunta repetida 3× seguidas sem saída" + "nenhum estado pendente
// sobrevive a uma frase nova completa sem aviso".
//
// `SimC` é o `SimB` do chaos_lote_a_r2_test.dart com o único passo que a 7d
// mudou no `_sendMessage`: o lote (passo 6) também roda quando um rascunho
// está pendente e a frase é assunto novo, e avisa que deixou o rascunho de lado.
// Achados em docs/qa/findings-caos-lote-a-r3.md (IDs CHAOS-C-…).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/entry_safety_gate.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/pending_reply_check.dart';
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

const monthNames = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const wdNames = {1: 'segunda', 2: 'terça', 3: 'quarta', 4: 'quinta', 5: 'sexta', 6: 'sábado', 7: 'domingo'};

/// Um turno com o oráculo. Estende o `LT` do r2 com o que esta rodada mede.
class LC extends b.LT {
  bool fullNew = false; // frase nova completa (assunto novo): nenhum estado pendente pode sobreviver a ela sem aviso
  bool noEdit = false; // nenhum registro existente pode mudar neste turno
  bool orphan = false; // resposta solta sem pendência (depois de reinício): não pode virar lançamento
  bool discount = false; // "ganhei N de desconto": nunca receita
  bool dateAskOk = false; // forma ambígua: perguntar a data é aceitável
  bool hasMarker = false; // a frase tem marcador de data resolvível
  bool plainFact = false; // fato simples no passado (medir "soa como plano" à toa)
  bool lateAnswer = false; // resposta tardia (depois de pergunta/comando/op no meio)
  String? op; // '⟲reinicio' | '⟲nuvem' | '⟲extrato-edita[:título]' | '⟲extrato-apaga[:título]'
  LC(super.text, super.family);
}

LC opTurn(String op) => LC(op, 'op')..op = op;

// ───────────────────────── simulador do chat (ordem ATUAL, pós-7d) ─────────────────────────

class SimC {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  FinancialTransactionDraft? last;
  List<String> lastIds = const [];
  List<FinancialTransactionDraft>? pendingBatch;

  /// Snapshot do repositório antes de cada `recordCreated` deste turno (uma
  /// entrada por grupo na pilha do desfazer).
  final List<Snap3> preSaves = [];
  static int _goalSeq = 0;

  SimC(this.engine, this.repo, {DateTime Function()? now}) : assistant = CesarAssistant(repository: repo, engine: engine, now: now);

  bool get draftPending => active != null && !active!.isComplete;
  bool get anyPending => draftPending || pendingBatch != null || assistant.hasPendingQuestion;

  R3Reply send(String input) {
    preSaves.clear();
    final r = _send(input.trim());
    final notice = assistant.takeNotice();
    if (notice != null) return R3Reply(r.route, '$notice\n\n${r.text}', r.draft);
    return r;
  }

  List<String> _add(FinancialTransactionDraft d) {
    preSaves.add(Snap3.of(repo));
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

    if (active != null && !active!.isComplete && engine.isCancelCommand(text)) {
      active = null;
      return R3Reply('cancel_pending', 'Tudo bem, descartei esse lançamento.');
    }

    if (pendingBatch != null) {
      final batch = pendingBatch!;
      if (engine.isCancelCommand(text)) {
        pendingBatch = null;
        return R3Reply('cancel_pending', 'Tudo bem, descartei esses lançamentos.');
      }
      final whatIf = assistant.hypothesisReply(text);
      if (whatIf != null) return R3Reply(whatIf.route, whatIf.text);
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (!engine.startsNewTransaction(firstOpen, text)) {
        final merged = engine.mergeMultiDrafts(batch, text);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          pendingBatch = null;
          return _saveBatch(merged);
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
      repo.addGoal(FinancialGoal(id: 'goal-c-${++_goalSeq}', title: goalCreation.title, targetAmount: goalCreation.targetAmount, targetDate: goalCreation.targetDate));
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

    // 6 (7d): o lote também é assunto novo com rascunho pendente — e avisa.
    final pendingDraft = active != null && !active!.isComplete;
    if (!pendingDraft || engine.startsNewTransaction(active!, text)) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        final dropped = pendingDraft ? LocalFinancialNlpEngine.discardedDraftNotice(active!) : null;
        active = null;
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) {
          final r = _saveBatch(multi);
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
      _saved(_add(draft));
      if (draft.isReminder) {
        repo.addReminder(FinancialReminder(
          id: 'rem-c-${repo.reminders.length + 1}-${DateTime.now().microsecondsSinceEpoch}',
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

  R3Reply _saveBatch(List<FinancialTransactionDraft> drafts) {
    for (final d in drafts) {
      _saved(_add(d));
    }
    last = drafts.last;
    return R3Reply('multi', 'Identifiquei ${drafts.length} lançamentos: ${drafts.map((d) => '${d.amount} ${d.description}').join('; ')}');
  }
}

// ───────────────────────── fixtures (títulos NOVOS) ─────────────────────────
// Hoje (2026-10-01) é quinta e 1º do mês: ontem (qua 30/09) já é o mês passado.

List<FinancialTransaction> fixturesC([DateTime? now]) {
  final t = _day(now ?? today);
  FinancialTransaction f(String id, String title, double amount, String cat, DateTime d, {TransactionType type = TransactionType.expense}) =>
      FinancialTransaction(id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: 'pix', date: d.add(const Duration(hours: 12)));
  return [
    f('cx-padaria-oh', 'Padaria Ontem e Hoje', 22, 'supermarket', back(3, t)),
    f('cx-bar-7d', 'Bar 7 Dias', 71, 'leisure', back(1, t)),
    f('cx-emporio-d1', 'Empório Dia 1', 33, 'supermarket', back(4, t)),
    f('cx-feira-da-seg', 'Feira da Segunda', 59, 'supermarket', wdLast(5, t)),
    f('cx-feira-seg', 'Feira', 44, 'supermarket', wdLast(1, t)),
    f('cx-feira-sab', 'Feira', 46, 'supermarket', wdLast(6, t)),
    f('cx-7belo', '7 Belo', 12, 'leisure', back(2, t)),
    f('cx-123milhas', '123 Milhas', 640, 'leisure', back(6, t)),
    f('cx-pizzaria-sab', 'Pizzaria Sábado à Noite', 88, 'leisure', wdLast(3, t)),
    f('cx-quitanda-dom', 'Quitanda do Domingos', 27, 'supermarket', wdLast(2, t)),
    f('cx-lavajato', 'Lava-Jato Amanhã', 35, 'transport', back(2, t)),
    f('cx-otica', 'Ótica 2000', 290, 'health', back(9, t)),
    f('cx-costureira', 'Costureira', 60, 'expense_other', back(5, t)),
    f('cx-oficina', 'Oficina do Tião', 420, 'transport', wdLast(7, t)),
    f('cx-garagem', 'Garagem alugada', 300, 'income_other', back(2, t), type: TransactionType.income),
    f('cx-freela', 'Freela de design', 850, 'income_other', back(7, t), type: TransactionType.income),
  ];
}

Future<FinancialRepository> freshRepoC([DateTime? now]) async {
  SharedPreferences.setMockInitialValues({});
  final repo = FinancialRepository();
  await repo.initialize();
  for (final t in fixturesC(now)) {
    repo.addTransaction(t);
  }
  repo.addGoal(FinancialGoal(id: 'g-notebook', title: 'Notebook', targetAmount: 4000, savedAmount: 500));
  repo.addGoal(FinancialGoal(id: 'g-viagem', title: 'Viagem', targetAmount: 2500));
  repo.addReminder(FinancialReminder(
      id: 'rem-rafa', title: 'Rafa me deve', personName: 'Rafa', amount: 220, targetDate: today.add(const Duration(days: 20)), type: ReminderType.loanReceivable));
  return repo;
}

// ───────────────────────── oráculo de datas (formas NOVAS) ─────────────────────────

class DF {
  final String text;
  final DateTime? exp;
  final bool ask;
  final Set<DateTime> alt;
  final bool vague;
  final bool askOk;
  DF(this.text, this.exp, {this.ask = false, this.alt = const {}, this.vague = false, this.askOk = false});
}

DF dateFragC(Random rng, DateTime now) {
  final t = _day(now);
  T p<T>(List<T> l) => l[rng.nextInt(l.length)];
  final r = rng.nextInt(100);
  if (r < 10) return DF(p(['ontem no fim da tarde', 'ontem depois do almoço', 'ontem à noitinha', 'ontem bem cedo']), back(1, t));
  if (r < 15) return DF(p(['anteontem de noite', 'anteontem na hora do almoço']), back(2, t));
  if (r < 23) {
    final n = p([3, 4, 5, 8, 9, 12]);
    final w = const {3: 'três', 4: 'quatro', 5: 'cinco', 8: 'oito', 9: 'nove', 12: 'doze'}[n]!;
    final f = rng.nextInt(3);
    if (f == 0) return DF('há $w dias', back(n, t));
    if (f == 1) return DF('faz $w dias', back(n, t));
    return DF('$n dias atrás', back(n, t));
  }
  if (r < 26) return DF('faz uma semana', back(7, t), askOk: true);
  if (r < 38) {
    final wd = 1 + rng.nextInt(7);
    final name = wdNames[wd]!;
    final lastD = wdLast(wd, t);
    final same = wd == t.weekday;
    final g = wd >= 6 ? 'o' : 'a';
    final f = rng.nextInt(4);
    if (f == 0) return DF('$name passad$g', lastD);
    if (f == 1) return DF('n$g $name de manhã', lastD, alt: same ? {t} : const {});
    if (f == 2) return DF('$name à tarde', lastD, alt: same ? {t} : const {});
    return DF('n$g $name retrasad$g', DateTime(lastD.year, lastD.month, lastD.day - 7));
  }
  if (r < 50) {
    final n = p([1, 2, 15, 28, 29, 30, 31, 1 + rng.nextInt(28)]);
    final d = diaN(n, t);
    final txt = n == 1 && rng.nextBool() ? 'dia 1º' : (rng.nextBool() ? 'dia $n' : 'no dia $n');
    return DF(txt, d, ask: d == null);
  }
  if (r < 58) {
    if (rng.nextInt(4) == 0) {
      final d = DateTime(t.year, t.month, t.day + 1 + rng.nextInt(20));
      return DF('${p(['em', 'no dia'])} ${d.day}/${d.month}', null, ask: true);
    }
    final d = back(1 + rng.nextInt(40), t);
    final dd = rng.nextBool() ? d.day.toString().padLeft(2, '0') : '${d.day}';
    final mm = rng.nextBool() ? d.month.toString().padLeft(2, '0') : '${d.month}';
    return DF('${p(['em', 'no dia'])} $dd/$mm', d);
  }
  if (r < 63) {
    final d = back(2 + rng.nextInt(48), t);
    return DF('${p(['em ', ''])}${d.day} de ${monthNames[d.month - 1]}', d);
  }
  if (r < 68) {
    final n = 1 + rng.nextInt(28);
    return DF('mês passado no dia $n', DateTime(t.year, t.month - 1, n), askOk: true);
  }
  if (r < 75) {
    return DF(p(['amanhã cedo', 'depois de amanhã', 'semana que vem', 'no próximo sábado', 'mês que vem', 'daqui a dois dias', 'amanhã à noite']), null, ask: true);
  }
  if (r < 80) {
    final f = rng.nextInt(3);
    if (f == 0) return DF('há duas semanas', back(14, t), askOk: true);
    return DF(p(['mês retrasado', 'semana retrasada']), null, ask: true);
  }
  if (r < 86) return DF(p(['dia desses', 'há uns dias', 'recentemente', 'no meio do mês', 'outro dia']), null, vague: true);
  return DF(p(['hoje na hora do almoço', 'hoje mais cedo', 'agorinha', 'hoje à tarde', 'hj de manhã']), t);
}

// ───────────────────────── gerador ─────────────────────────

class GenC {
  final Random rng;
  final int length;
  GenC(this.rng, this.length);
  int _n = 0;
  final List<LC> _q = [];

  T pick<T>(List<T> l) => l[rng.nextInt(l.length)];
  static const _amts = [7, 13, 26, 39, 52, 64, 77, 95, 140, 215, 380, 1240];
  int amt() => pick(_amts);
  int other(int a) {
    var x = amt();
    while (x == a) {
      x = amt();
    }
    return x;
  }

  static const _pays = [' no pix', ' no débito', ' no dinheiro', ' no crédito à vista', ''];

  /// [texto com {A}/{P}, direção, óbvia?, perguntar a direção é aceitável?]
  static const _cores = <List<Object>>[
    ['o freguês me pagou {A}{P}', 'income', true, false],
    ['minha sogra me mandou {A}{P}', 'income', true, false],
    ['a empresa me reembolsou {A}{P}', 'income', true, false],
    ['recebi {A} de gorjeta{P}', 'income', true, false],
    ['a vizinha me pagou {A} pela costura{P}', 'income', true, false],
    ['faturei {A} no bazar{P}', 'income', true, false],
    ['vendi {A} em salgados{P}', 'income', true, false],
    ['ganhei {A} de cashback{P}', 'income', true, false],
    ['a loja me estornou {A}{P}', 'income', true, false],
    ['recebi {A} pela revisão do tcc{P}', 'income', true, false],
    ['meu cunhado me pagou os {A} que devia{P}', 'income', true, false],
    ['entrou um pix de {A} da cliente', 'income', true, false],
    ['lucrei {A} na revenda{P}', 'income', true, false],
    ['o aluguel da garagem rendeu {A}{P}', 'income', false, true],
    ['peguei {A} emprestado com a minha mãe{P}', 'income', false, true],
    ['paguei {A} pro eletricista{P}', 'expense', true, false],
    ['dei {A} pro flanelinha{P}', 'expense', true, false],
    ['mandei {A} pra minha irmã{P}', 'expense', true, false],
    ['quitei {A} da fatura{P}', 'expense', true, false],
    ['o mecânico me cobrou {A}{P}', 'expense', true, false],
    ['tive que pagar {A} de multa do condomínio{P}', 'expense', true, false],
    ['deixei {A} de gorjeta pro garçom{P}', 'expense', true, false],
    ['contribuí com {A} na vaquinha{P}', 'expense', true, false],
    ['doei {A} pra creche{P}', 'expense', true, false],
    ['a farmácia me cobrou {A}{P}', 'expense', true, false],
    ['recebi a conta de gás de {A}', 'expense', true, false],
    ['chegou a fatura da internet de {A}', 'expense', true, false],
    ['me cobraram {A} de taxa de entrega{P}', 'expense', true, false],
    ['paguei a diarista, deu {A}{P}', 'expense', true, false],
    ['torrei {A} no shopping{P}', 'expense', true, false],
    ['pixei {A} pro pintor', 'expense', true, false],
    ['devolvi {A} que o joão tinha me emprestado{P}', 'expense', false, true],
    ['emprestei {A} pro meu primo{P}', 'expense', false, true],
  ];

  /// Palavra de data só no NOME do lugar/endereço. [proper]: nome próprio
  /// (lido como data = P0); senão ambíguo.
  static const _titlePlaces = <List<Object>>[
    [' na Padaria Ontem e Hoje', true],
    [' no Bar 7 Dias', true],
    [' no Empório Dia 1', true],
    [' na Pizzaria Sábado à Noite', true],
    [' na Quitanda do Domingos', true],
    [' no Lava-Jato Amanhã', true],
    [' numa loja da avenida 9 de julho', true],
    [' na rua 1º de maio', true],
    [' na travessa 2 de dezembro', true],
    [' no Sacolão 24 Horas', true],
    [' na Ótica Segunda Visão', true],
    [' no Bar Fim de Tarde', true],
    [' no Hotel Quinta das Flores', true],
    [' na Feira da Segunda', false],
  ];

  LC next(FinancialRepository repo) {
    _n++;
    if (_q.isNotEmpty) return _q.removeAt(0);
    if (_n > length) return LC('⟲fim', 'fim');
    final r = rng.nextInt(1000);
    if (r < 120) return _launch();
    if (r < 210) return _values();
    if (r < 280) return _multi();
    if (r < 390) return _intent();
    if (r < 540) return _chain();
    if (r < 690) return _edit();
    if (r < 740) return _loop();
    if (r < 800) return _undo();
    if (r < 850) return opTurn(pick(['⟲reinicio', '⟲nuvem', '⟲extrato-edita', '⟲extrato-apaga']));
    return _noise();
  }

  LC _launch() {
    final core = pick(_cores);
    final tmpl = core[0] as String;
    final a = amt();
    final useTitle = rng.nextInt(4) == 0;
    final tp = pick(_titlePlaces);
    var body = tmpl.replaceAll('{A}', '$a').replaceAll('{P}', useTitle && tmpl.contains('{P}') ? tp[0] as String : '');
    if (useTitle && !tmpl.contains('{P}')) body = '$body${tp[0]}';
    final pay = tmpl.contains('{P}') ? pick(_pays) : (rng.nextBool() ? pick(_pays) : '');
    final d = rng.nextInt(3) == 0 ? null : dateFragC(rng, today);
    String text;
    if (d == null) {
      text = '$body$pay';
    } else {
      final pos = rng.nextInt(3);
      if (pos == 0) {
        text = '${d.text} $body$pay';
      } else if (pos == 1) {
        final i = body.indexOf('$a') + '$a'.length;
        text = '${body.substring(0, i)} ${d.text}${body.substring(i)}$pay';
      } else {
        text = '$body$pay ${d.text}';
      }
    }
    final lt = LC(text, useTitle ? 'lançar-título' : 'lançar')
      ..dir = core[1] as String
      ..obviousDir = core[2] as bool
      ..dirAskOk = core[3] as bool
      ..single = a.toDouble()
      ..plainFact = true;
    if (d == null) {
      lt.expDate = today;
      lt.titleDate = useTitle;
      if (useTitle && !(tp[1] as bool)) lt.family = 'lançar-título-ambíguo';
    } else {
      lt.expDate = d.vague ? null : d.exp;
      lt.expAlt = d.alt;
      lt.mustAsk = d.ask;
      lt.vagueDate = d.vague;
      lt.dateAskOk = d.askOk;
      lt.hasMarker = !d.ask && !d.vague && d.exp != null;
    }
    if (rng.nextInt(14) == 0) {
      // desconto: nunca receita
      final x = amt();
      return LC(pick(['ganhei $x de desconto na ótica no pix', 'consegui $x de abatimento no conserto no pix', 'me deram $x de desconto no tênis no pix']), 'desconto')
        ..discount = true;
    }
    return lt;
  }

  LC _values() {
    final a = amt();
    final t = pick(<List<Object>>[
      ['paguei $a na consulta do box 7 no pix', a],
      ['gastei $a no lanche do apto 302 no pix', a],
      ['comprei um vinho safra 2019 por $a no pix', a],
      ['paguei $a na mensalidade do 3º ano no pix', a],
      ['gastei $a em 6 latinhas no pix', a],
      ['comprei uma bateria 60 amperes por $a no pix', a],
      ['gastei $a na loja 3 do térreo no pix', a],
      ['comprei um celular de 128 gigas por $a no pix', a],
      ['gastei $a no voo das 6h40 no pix', a],
      ['paguei $a na sala 1204 no pix', a],
      ['gastei $a com 2 kg de carne no pix', a],
      ['paguei $a de pedágio na BR 101 no pix', a],
      ['comprei o jogo FIFA 26 por $a no pix', a],
      ['paguei $a pelo plano de 500 mega no pix', a],
      ['gastei $a na 3ª sessão de fisio no pix', a],
      ['paguei $a no 1º dia de aula no pix', a],
      ['comprei 12 ovos caipira por $a no pix', a],
      ['paguei $a no conserto do fogão de 4 bocas no pix', a],
      ['gastei $a na farmácia da quadra 405 no pix', a],
      ['paguei $a na vacina da 2ª dose no pix', a],
      ['comprei 5 metros de tecido por $a no pix', a],
      ['paguei $a no corte com 15% de desconto no pix', a],
      ['paguei $a no rodízio às 20h no pix', a],
      ['gastei $a no Hotel 3 Estrelas no pix', a, true],
      ['gastei $a no Bar 7 Dias no pix', a, true],
      ['paguei $a no Sacolão 24 Horas no pix', a, true],
      ['gastei $a no Empório Dia 1 no pix', a, true],
      ['paguei $a na Ótica 2000 no pix', a, true],
      ['paguei $a no 123 Milhas no pix', a, true],
      ['gastei $a no 7 Belo no pix', a, true],
    ]);
    return LC(t[0] as String, 'um-valor')
      ..dir = 'expense'
      ..single = (t[1] as num).toDouble()
      ..oneValueOnly = true
      ..titleDate = t.length > 2
      ..expDate = today
      ..plainFact = true;
  }

  LC _multi() {
    final a = amt(), c = other(a);
    final r = rng.nextInt(100);
    if (r < 70) {
      final tmpl = pick(<String>[
        'gastei $a na farmácia e $c na ótica',
        '$a no pão, $c no leite',
        'paguei $a de água, $c de luz',
        'deu $a o almoço e $c a sobremesa',
        'gastei $a reais na feira e $c reais no açougue',
        'comprei pão por $a e leite por $c',
        'gastei $a pila no posto, $c pila no lava-jato',
        'na quitanda $a e no açougue $c',
        'paguei $a no guincho e mais $c na borracharia',
        'foram $a de uber e $c de pedágio',
        '$a de cerveja e $c de carvão',
        'paguei $a de gás e $a de água',
        'gastei $a no pão, $c no leite e $a no café',
      ]);
      var text = '$tmpl${pick(_pays)}';
      final vals = RegExp(r'\b\d+\b').allMatches(tmpl).map((m) => double.parse(m.group(0)!)).toList();
      DateTime? exp = today;
      var ask = false;
      var vague = false;
      if (rng.nextInt(3) == 0) {
        final d = dateFragC(rng, today);
        final pos = rng.nextInt(2);
        text = pos == 0 ? '${d.text}: $text' : '$text, tudo ${d.text}';
        exp = d.vague ? null : d.exp;
        ask = d.ask;
        vague = d.vague;
      }
      return LC(text, 'multi')
        ..dir = 'expense'
        ..values = vals
        ..expDate = exp
        ..mustAsk = ask
        ..vagueDate = vague;
    }
    final m = pick(<List<Object>>[
      ['recebi $a do freela e paguei $c de imposto no pix', {a.toDouble(): 'income', c.toDouble(): 'expense'}],
      ['vendi a bike por $a e gastei $c na oficina no pix', {a.toDouble(): 'income', c.toDouble(): 'expense'}],
      ['a cliente me pagou $a e eu gastei $c no mercado no pix', {a.toDouble(): 'income', c.toDouble(): 'expense'}],
    ]);
    return LC(m[0] as String, 'multi-misto')
      ..values = [a.toDouble(), c.toDouble()]
      ..valueDir = m[1] as Map<double, String>
      ..expDate = today;
  }

  LC _intent() {
    final a = amt();
    final r = rng.nextInt(100);
    if (r < 55) {
      final t = pick(<String>[
        'tô a fim de gastar $a num tênis no pix',
        'to querendo comprar um fone de $a no pix',
        'tenho que pagar $a de iptu semana que vem',
        'vou ter que gastar $a no conserto do carro',
        'preciso pagar $a de luz até sexta',
        'devo gastar uns $a na festa no pix',
        'se eu fosse gastar $a no cinema',
        'supondo que eu gaste $a na feira no pix',
        'digamos que eu receba $a de bônus',
        'e se eu recebesse $a?',
        'vou receber $a do freela amanhã',
        'talvez eu gaste $a no mercado no pix',
        'pode ser que eu pague $a no conserto',
        'to cogitando comprar um sofá de $a',
        'estou orçando uma reforma de $a',
        'me ofereceram um celular por $a',
        'ainda vou pagar os $a do dentista',
        'falta pagar $a do cartão',
        'pensei em gastar $a no salão no pix',
        'minha ideia é gastar $a no presente no pix',
      ]);
      if (rng.nextInt(2) == 0) _q.add(LC(pick(['no pix', 'no débito', 'é isso', 'beleza', 'pode ser', 'no mercado no pix', 'saiu', 'na loja, no débito']), 'intenção-cont')..hyp = true);
      return LC(t, 'intenção')..hyp = true;
    }
    if (r < 72) {
      final t = pick(<String>[
        'quase paguei $a num ingresso',
        'desisti do tênis de $a',
        'não cheguei a gastar os $a',
        'o pix de $a não foi, deu erro',
        'a compra de $a foi recusada no cartão',
        'no fim não gastei os $a da feira',
        'era pra eu pagar $a hoje mas esqueci',
      ]);
      if (rng.nextInt(2) == 0) {
        _q.add(LC(pick(['no pix', 'saiu', 'no mercado no pix', 'na loja, no crédito', 'luz no pix']), 'não-aconteceu-cont')
          ..hyp = true
          ..notHappened = true);
      }
      return LC(t, 'não-aconteceu')
        ..hyp = true
        ..notHappened = true;
    }
    final t = pick(<List<Object>>[
      ['paguei $a no conserto, se não me engano no pix', 'expense'],
      ['recebi $a do freela no pix, caso você queira anotar', 'income'],
      ['gastei $a na farmácia no pix, se for pra lembrar', 'expense'],
      ['comprei $a de ração no pix porque se acabar é ruim', 'expense'],
      ['pagamos $a de luz no pix, se bem me lembro', 'expense'],
      ['fui ao mercado e gastei $a no pix, caso precise', 'expense'],
      ['a vizinha me pagou $a no pix, se ela pedir recibo te falo', 'income'],
      ['gastei $a no açaí no pix mesmo se tava caro', 'expense'],
    ]);
    return LC(t[0] as String, 'fato-com-se')
      ..hyp = false
      ..dir = t[1] as String
      ..single = a.toDouble()
      ..expDate = today;
  }

  static const _drafts = <List<String>>[
    ['paguei o flanelinha no dinheiro', 'expense', 'flanelinha'],
    ['comprei areia pro gato no pix', 'expense', 'areia'],
    ['gastei na oficina no débito', 'expense', 'oficina'],
    ['a vizinha me pagou no pix', 'income', 'vizinha'],
    ['gastei na quitanda no pix', 'expense', 'quitanda'],
    ['comprei um presente pra minha mãe no crédito à vista', 'expense', 'presente'],
    ['recebi o aluguel da garagem no pix', 'income', 'garagem'],
    ['paguei o guincho no pix', 'expense', 'guincho'],
  ];

  static const _newSentences = <List<String>>[
    ['gastei {A} no chaveiro do bairro no pix', 'expense', 'chaveiro'],
    ['recebi {A} da cliente da costura no pix', 'income', 'cliente'],
    ['paguei {A} de pedágio no pix', 'expense', 'pedagio'],
    ['comprei um guarda-chuva de {A} no pix', 'expense', 'guarda'],
    ['o eletricista me cobrou {A} no pix', 'expense', 'eletricista'],
    ['vendi uma bicicleta por {A} no pix', 'income', 'bicicleta'],
    ['abasteci {A} no posto no débito', 'expense', 'posto'],
  ];

  LC _fullNew(String? oldWord) {
    final a = amt();
    final f = pick(_newSentences);
    return LC(f[0].replaceAll('{A}', '$a'), 'frase-nova')
      ..fullNew = true
      ..dir = f[1]
      ..single = a.toDouble()
      ..expDate = today
      ..newWord = f[2]
      ..oldWord = f[2] == oldWord ? null : oldWord;
  }

  /// Rascunho → (pergunta | comando | hipótese | ambígua | op | frase nova)* → resposta tardia → desfaz?
  LC _chain() {
    final d = pick(_drafts);
    final start = LC(d[0], 'rascunho')..dir = d[1];
    final steps = rng.nextInt(3);
    var dropped = false;
    for (var i = 0; i < steps; i++) {
      final k = rng.nextInt(9);
      if (k == 0) {
        _q.add(LC(pick(['quanto gastei ontem?', 'qual meu saldo?', 'quanto falta pra meta do notebook?', 'o que você sabe fazer?']), 'meio-pergunta')..noEdit = true);
      } else if (k == 1) {
        final c = pick(<List<String>>[
          ['apaga o 7 belo', '7 belo'],
          ['apaga a costureira', 'costureira'],
          ['muda o 123 milhas pra 600', '123 milhas'],
          ['passa a ótica 2000 pra 280', 'otica'],
        ]);
        _q.add(LC(c[0], 'meio-comando')..named = c[1]);
        if (c[0].startsWith('apaga') && rng.nextBool()) _q.add(LC(pick(['sim', 'não', 'pode apagar']), 'confirma')..named = c[1]);
      } else if (k == 2) {
        _q.add(LC(pick(['e se fosse 90?', 'se fosse no débito mudava algo?', 'e se fosse no crédito?']), 'meio-hipótese')
          ..hyp = true
          ..noEdit = true);
      } else if (k == 3) {
        _q.add(LC(pick(['sei lá', 'não lembro', 'hm', 'depende', 'calma aí']), 'meio-ambígua')..noEdit = true);
      } else if (k == 4) {
        _q.add(opTurn(pick(['⟲reinicio', '⟲nuvem', '⟲extrato-edita', '⟲extrato-apaga'])));
      } else if (k == 5) {
        _q.add(_fullNew(d[2]));
        dropped = true;
      } else if (k == 6) {
        _q.add(LC('desfaz', 'meio-desfaz'));
      } else if (k == 7) {
        _q.add(LC(pick(['por pouco não gastei 40 no bar', 'quase comprei um tênis de 300']), 'meio-não-aconteceu')
          ..hyp = true
          ..notHappened = true
          ..noEdit = true);
      } else {
        final x = amt(), y = other(x);
        _q.add(LC('gastei $x na farmácia e $y na ótica', 'meio-lote')
          ..fullNew = true
          ..values = [x.toDouble(), y.toDouble()]
          ..dir = 'expense');
        dropped = true;
      }
    }
    final a = amt();
    final lateAns = LC(pick(['$a', 'foi $a', 'deu $a', '$a no pix', 'uns $a', 'acho que $a']), 'resposta-tardia')
      ..single = a.toDouble()
      ..dir = dropped ? null : d[1]
      ..lateAnswer = true;
    _q.add(lateAns);
    if (rng.nextInt(3) == 0) _q.add(LC('desfaz', 'desfaz'));
    if (rng.nextInt(4) == 0) _q.add(LC('desfaz', 'desfaz'));
    return start;
  }

  static const _editTargets = <List<Object?>>[
    ['passa o 7 belo pra {A}', '7 belo', true],
    ['muda o 123 milhas pra {A}', '123 milhas', true],
    ['apaga o 123 milhas', '123 milhas', false],
    ['muda a padaria ontem e hoje pra {A}', 'padaria', true],
    ['apaga a padaria ontem e hoje', 'padaria', false],
    ['muda o bar 7 dias pra {A}', 'bar 7 dias', true],
    ['muda o empório dia 1 pra {A}', 'emporio', true],
    ['apaga a feira da segunda', 'feira', false],
    ['muda a feira de sábado pra {A}', 'feira', true],
    ['muda a feira de quarta pra {A}', 'feira', true],
    ['apaga a feira de quarta', 'feira', false],
    ['na verdade a pizzaria foi {A}', 'pizzaria', true],
    ['na real a quitanda deu {A}', 'quitanda', true],
    ['pensando bem o lava-jato foi {A}', 'lava', true],
    ['na verdade foi {A} a costureira', 'costureira', true],
    ['corrigindo: a oficina foi {A}', 'oficina', true],
    ['na verdade o açougue foi {A}', 'acougue', true],
    ['na verdade o cinema foi {A}', 'cinema', true],
    ['na verdade a feira foi {A}', 'feira', true],
    ['na verdade o 7 belo foi {A}', '7 belo', true],
    ['na verdade o empório dia 1 foi {A}', 'emporio', true],
    ['na verdade o domingos foi {A}', 'domingos', true],
    ['o 7 belo foi {A}', '7 belo', true],
    ['a ótica 2000 foi {A}', 'otica', true],
    ['passa a garagem pra {A}', 'garagem', true],
    ['muda o freela pra {A}', 'freela', true],
    ['apaga o freela de design', 'freela', false],
    ['muda o domingos pra {A}', 'domingos', true],
    ['apaga o do domingos', 'domingos', false],
    ['muda a quitanda de terça pra {A}', 'quitanda', true],
    ['muda o almoço de ontem pra {A}', 'almoco', true],
    ['muda o mercado de terça pra {A}', 'mercado', true],
    ['muda o conserto de domingo pra {A}', 'conserto', true],
    ['muda o 123 de sábado passado pra {A}', '123', true],
  ];

  static const _starts = <List<String>>[
    ['gastei {A} no açaí do bairro no pix', 'acai', 'expense'],
    ['paguei {A} no guincho no débito', 'guincho', 'expense'],
    ['recebi {A} de comissão do bazar no pix', 'bazar', 'income'],
    ['comprei um ventilador de {A} no pix', 'ventilador', 'expense'],
  ];

  LC _edit() {
    final r = rng.nextInt(100);
    if (r < 45) {
      // "passa/muda/edita…" sozinho depois de um lançamento
      final a = amt();
      final s = pick(_starts);
      final start = LC(s[0].replaceAll('{A}', '$a'), 'edição-base')
        ..dir = s[2]
        ..single = a.toDouble()
        ..expDate = today;
      _q.add(LC(pick(['passa', 'muda', 'edita', 'corrige', 'altera', 'troca', 'quero mudar', 'muda isso']), 'edição-sozinho')..named = s[1]);
      final c = other(a);
      final k = rng.nextInt(12);
      if (k == 0 || k == 1) {
        _q.add(_fullNew(null)..noEdit = true);
      } else if (k == 2) {
        _q.add(LC('$c', 'edição-valor')
          ..named = s[1]
          ..editValue = c.toDouble());
      } else if (k == 3) {
        _q.add(LC('pra $c', 'edição-valor')
          ..named = s[1]
          ..editValue = c.toDouble());
      } else if (k == 4) {
        _q.add(LC('foi no débito', 'edição-campo')..named = s[1]);
      } else if (k == 5) {
        final tgt = pick(_editTargets.where((e) => (e[0] as String).startsWith('na ')).toList());
        _q.add(LC((tgt[0] as String).replaceAll('{A}', '$c'), 'edição-na-verdade')
          ..named = tgt[1] as String
          ..editValue = c.toDouble());
      } else if (k == 6) {
        _q.add(LC('apaga o 123 milhas', 'edição-comando')..named = '123 milhas');
        if (rng.nextBool()) _q.add(LC('sim', 'confirma')..named = '123 milhas');
      } else if (k == 7) {
        _q.add(LC(pick(['quanto gastei hoje?', 'qual foi meu maior gasto?']), 'edição-pergunta')..noEdit = true);
      } else if (k == 8) {
        _q.add(LC('por pouco não gastei $c no bar', 'edição-não-aconteceu')
          ..noEdit = true
          ..hyp = true
          ..notHappened = true);
      } else if (k == 9) {
        _q.add(LC('muda', 'edição-sozinho')..named = s[1]);
        _q.add(LC('muda', 'edição-sozinho')..named = s[1]);
      } else if (k == 10) {
        _q.add(LC('e se fosse $c?', 'edição-hipótese')
          ..noEdit = true
          ..hyp = true);
      } else {
        _q.add(opTurn('⟲reinicio'));
        _q.add(LC('$c', 'resposta-órfã')
          ..noEdit = true
          ..orphan = true);
      }
      return start;
    }
    final a = amt();
    final t = pick(_editTargets);
    final txt = (t[0] as String).replaceAll('{A}', '$a');
    final lt = LC(txt, 'editar-apagar')
      ..named = t[1] as String
      ..editValue = (t[2] as bool) ? a.toDouble() : null;
    final isDelete = txt.startsWith('apaga');
    if (rng.nextInt(5) == 0) _q.add(opTurn(pick(['⟲nuvem', '⟲reinicio', '⟲extrato-edita', '⟲extrato-apaga'])));
    if (isDelete) {
      if (rng.nextInt(4) > 0) _q.add(LC(pick(['sim', 'essa', 'pode ser', '2', 'o segundo', 'não', 'nenhum']), 'confirma')..named = t[1] as String);
      if (rng.nextInt(3) == 0) _q.add(LC(pick(['sim', 'pode apagar', 'não']), 'confirma')..named = t[1] as String);
    } else if (rng.nextInt(2) == 0) {
      _q.add(LC(pick(['sim', 'esse', 'pode ser', 'isso mesmo', '1', 'a primeira', 'não', 'nenhum']), 'confirma')
        ..named = t[1] as String
        ..editValue = lt.editValue);
      if (rng.nextInt(3) == 0) {
        _q.add(LC(pick(['sim', '2', 'o de sábado']), 'confirma')
          ..named = t[1] as String
          ..editValue = lt.editValue);
      }
    }
    if (rng.nextInt(6) == 0) _q.add(LC('desfaz', 'desfaz'));
    return lt;
  }

  /// Respostas que não resolvem, em série — "pergunta repetida 3× sem saída".
  LC _loop() {
    final r = rng.nextInt(3);
    final n = 3 + rng.nextInt(2);
    if (r == 0) {
      final d = pick(_drafts);
      for (var i = 0; i < n; i++) {
        _q.add(LC(pick(['sei lá', 'não lembro', 'hm', 'depende', 'calma aí', '?', 'não sei te dizer']), 'loop')..noEdit = true);
      }
      _q.add(LC(pick(['cancela', 'esquece', '${amt()}']), 'loop-saída'));
      return LC(d[0], 'rascunho')..dir = d[1];
    }
    if (r == 1) {
      final a = amt();
      for (var i = 0; i < n; i++) {
        _q.add(LC(pick(['sei lá', 'qualquer um', 'tanto faz', 'o de sempre', 'hm']), 'loop')..noEdit = true);
      }
      _q.add(LC(pick(['no pix', 'cancela']), 'loop-saída'));
      return LC('gastei $a no açaí', 'rascunho-sem-pagamento')..dir = 'expense';
    }
    for (var i = 0; i < n; i++) {
      _q.add(LC(pick(['7', '9', '8', 'o quinto', 'o de 30']), 'loop')
        ..named = 'feira'
        ..noEdit = true);
    }
    _q.add(LC(pick(['nenhum', '1']), 'loop-saída')..named = 'feira');
    return LC(pick(['apaga a feira', 'muda a feira pra 50']), 'escolha')..named = 'feira';
  }

  LC _undo() {
    final a = amt();
    final r = rng.nextInt(4);
    if (r == 0) {
      _q.add(LC('desfaz', 'desfaz'));
      if (rng.nextBool()) _q.add(LC('desfaz', 'desfaz'));
      return LC('gastei $a no açaí do bairro no pix', 'lançar')
        ..dir = 'expense'
        ..single = a.toDouble()
        ..expDate = today;
    }
    if (r == 1) {
      _q.add(LC('sim', 'confirma')..named = '7 belo');
      _q.add(LC('desfaz', 'desfaz'));
      return LC('apaga o 7 belo', 'editar-apagar')..named = '7 belo';
    }
    if (r == 2) {
      _q.add(LC('desfaz', 'desfaz'));
      _q.add(LC('desfaz', 'desfaz'));
      final c = other(a);
      return LC('gastei $a na farmácia e $c na ótica no pix', 'multi')
        ..dir = 'expense'
        ..values = [a.toDouble(), c.toDouble()]
        ..expDate = today;
    }
    return LC('desfaz', 'desfaz');
  }

  LC _noise() => LC(
      pick([
        'beleza então', 'hmmm', 'kkk', 'pera', 'ok obrigado', 'e aí?', 'tá certo', '30', 'domingo passado', 'se sim', 'caso contrário', 'passa',
        'muda', 'edita', 'muda pra 40', 'desfaz', 'cancela', 'quanto gastei hoje?', 'qual meu saldo?', 'o que você sabe fazer?', 'sim', 'não',
      ]),
      'ruído');
}

// ───────────────────────── execução + invariantes ─────────────────────────

const _recWords =
    r'\b(?:todo|toda|todos|todas|mensal|mensalmente|mensalidade|assinatura|assinei|assino|vence|vencimento|cai|sempre|por mes|ao mes|semanal|semanalmente|anual|fixo|fixa|recorrente|pago|recebo|ganho|plano)\b';
const _catRecWords = r'\b(?:aluguel|salario|netflix|spotify|academia|condominio|internet|escola|pensao|curso|ingles)\b';

final _askDirRe = RegExp(r'entrou\*\* pra você|Fiquei na dúvida');
final _askSplitRe = RegExp(r'Vi mais de um valor|qual foi o valor certo', caseSensitive: false);
final _askDateRe = RegExp(r'Quando foi esse lançamento|essa data ainda não chegou|Em que dia|não tem dia|não existe dia|não existe|mais de um ano');
final _assumedDateRe = RegExp(r'Considerei (?:a data|o sábado)');
final _intentReplyRe = RegExp(r'soa como um plano|não chegou a acontecer|É só uma simulação|simulação, então não registrei');
final _noticeRe = RegExp(r'Deixei de lado|Não apaguei|Não mudei|descartei|deixei (?:tudo )?como estava|não registrei');
final _exitHintRe = RegExp(r'cancela|esquece|nenhum|deixa pra lá', caseSensitive: false);
const _askedAbout = {'ask_changes', 'choose', 'not_found', 'confirm_delete', 'ask_correction_or_new', 'confirm'};
const _newPendingRoutes = {'confirm_delete', 'choose', 'not_found', 'ask_changes', 'ask_correction_or_new', 'ask_target', 'goal_choose', 'ask', 'ask_multi'};

/// Severidade do tipo de violação (para o resumo; a tabela final é revisada à mão).
String sev(String kind) {
  const p0 = {
    'excecao', 'id_duplicado', 'valor_invalido', 'saldo', 'currentSpent', 'persistencia', 'apagou_sem_sim', 'mudou_sem_comando', 'hipotese_salva',
    'nao_aconteceu_salvo', 'tipo_trocado', 'tipo_trocado_multi', 'valor_trocado', 'data_errada', 'data_errada_multi', 'data_do_titulo', 'data_futura',
    'data_nao_perguntada', 'multi_valor_um_lancamento', 'multi_valor_parcial', 'multi_somado', 'multi_valor_inventado', 'frase_nova_fundida',
    'registro_mudou_sem_pedido', 'editou_sem_nome', 'edit_valor_errado', 'apagou_outro', 'desfaz_impreciso', 'desfaz_sem_historico_mudou',
    'desfaz_ressuscitou_extrato', 'desconto_virou_receita', 'recorrente_sem_palavra', 'transferencia_virou_edicao',
  };
  const p1 = {
    'pendente_sobreviveu', 'pergunta_repetida_3x', 'fato_virou_hipotese', 'resposta_nao_fundida', 'desfaz_nao_desfez', 'desfaz_reverteu_extrato',
    'sugestao_sim_falhou', 'recorrente_por_categoria', 'frase_nova_fundida_pendente', 'resposta_orfa_salva',
  };
  if (p0.contains(kind)) return 'P0';
  if (p1.contains(kind)) return 'P1';
  return 'P2';
}

final routeCount = <String, int>{};
final statCount = <String, int>{};
void stat(String k) => statCount[k] = (statCount[k] ?? 0) + 1;

class RunC {
  final List<b.VA> v;
  final List<LC> sent;
  RunC(this.v, this.sent);
}

Future<RunC> runC(LocalFinancialNlpEngine engine, {List<LC>? fixed, GenC? gen, bool verbose = false, List<String>? trace}) async {
  var repo = await freshRepoC();
  var sim = SimC(engine, repo);
  final v = <b.VA>[];
  final sent = <LC>[];
  String? prevRoute;
  var prevText = '';
  final undoStack = <Snap3>[];
  var stale = false;
  final extDeleted = <String>{};
  final extEdited = <String, String>{};
  final qHistory = <List<String>>[]; // [pergunta normalizada, entrada, pendente?]
  var loopFlagged = false;

  for (var i = 0; i < (fixed?.length ?? 100000); i++) {
    final lt = fixed != null ? fixed[i] : gen!.next(repo);
    if (lt.text == '⟲fim') break;
    sent.add(lt);
    void violOp(String kind, String detail) => v.add(b.VA(kind, '[${lt.text}] $detail', i));

    // ── operações fora do chat ──
    if (lt.op != null) {
      final op = lt.op!;
      try {
        if (op == '⟲reinicio') {
          await repo.flushPendingWrites();
          final mem = Snap3.of(repo);
          final r2 = FinancialRepository();
          await r2.initialize();
          final disk = Snap3.of(r2);
          if (!mem.sameAll(disk)) violOp('persistencia', 'memória ≠ disco: ${mem.diff(disk, withOverrides: true)}');
          repo = r2;
          sim = SimC(engine, repo);
          undoStack.clear();
          stale = false;
          prevRoute = 'op';
          prevText = '';
        } else if (op == '⟲nuvem') {
          repo.replaceAllFromCloud(
              transactions: repo.transactions.toList(),
              reminders: repo.reminders.toList(),
              budgets: repo.budgets.toList(),
              goals: repo.goals.toList(),
              categoryOverrides: Map.of(repo.categoryOverrides));
          undoStack.clear();
          stale = false;
          prevRoute = 'op';
        } else {
          final parts = op.split(':');
          final title = parts.length > 1 ? parts[1] : null;
          FinancialTransaction? target;
          if (title != null) {
            target = repo.transactions.where((t) => t.title == title).firstOrNull;
          } else {
            target = repo.transactions.where((t) => sim.lastIds.contains(t.id)).firstOrNull ??
                (repo.transactions.where((t) => t.id.startsWith('cx-')).toList()..sort((a, c) => a.id.compareTo(c.id))).firstOrNull;
          }
          if (target != null) {
            if (parts[0] == '⟲extrato-edita') {
              final upd = target.copyWith(amount: target.amount + 7);
              repo.updateTransaction(upd);
              extEdited[target.id] = jsonEncode(repo.transactions.firstWhere((t) => t.id == target!.id).toJson());
            } else {
              repo.deleteTransaction(target.id);
              extDeleted.add(target.id);
              extEdited.remove(target.id);
            }
            undoStack.clear();
            stale = true;
          }
        }
      } catch (e, st) {
        violOp('excecao', '$e ${st.toString().split('\n').take(2).join(' | ')}');
        break;
      }
      for (final p in repoInvariants(repo)) {
        violOp(p.split(':').first, p);
      }
      trace?.add('${i + 1}. $op');
      if (verbose) print('CHAOS-C|TRACE| ${i + 1}. $op');
      continue;
    }

    final hadDraft = sim.draftPending ? sim.active : null;
    final hadBatch = sim.pendingBatch;
    final hadAsst = sim.assistant.hasPendingQuestion;
    final pendingBefore = hadDraft != null || hadBatch != null || hadAsst;
    final before = Snap3.of(repo);
    final remB = b.remSnap(repo);
    R3Reply r;
    try {
      r = sim.send(lt.text);
    } catch (e, st) {
      v.add(b.VA('excecao', '"${lt.text}" → $e ${st.toString().split('\n').take(2).join(' | ')}', i));
      break;
    }
    final after = Snap3.of(repo);
    final remA = b.remSnap(repo);
    routeCount[r.route] = (routeCount[r.route] ?? 0) + 1;
    final reply = r.text.replaceAll('\n', ' ');
    final shortReply = reply.length > 170 ? '${reply.substring(0, 170)}…' : reply;
    void viol(String kind, String detail) => v.add(b.VA(kind, '"${lt.text}" → [${r.route}] $detail', i));
    trace?.add('${i + 1}. "${lt.text}" → ${r.short}');
    if (verbose) print('CHAOS-C|TRACE| ${i + 1}. "${lt.text}" → ${r.short}');

    if (r.text.trim().isEmpty) viol('resposta_vazia', '');
    for (final p in repoInvariants(repo)) {
      viol(p.split(':').first, p);
    }
    final s = CesarText.simplify(lt.text);
    final added = after.tx.keys.where((k) => !before.tx.containsKey(k)).map((k) => jsonDecode(after.tx[k]!) as Map).toList();
    final removed = before.tx.keys.where((k) => !after.tx.containsKey(k)).toList();
    final changed = before.tx.keys.where((k) => after.tx.containsKey(k) && after.tx[k] != before.tx[k]).toList();
    final isUndo = r.route == 'undo';
    final dataChanged = !before.sameData(after);

    // ── nada some sem "sim" / nada muda sem comando ──
    final confirmedDelete = prevRoute == 'confirm_delete' && yesRe.hasMatch(s);
    if (removed.isNotEmpty && !((r.route == 'deleted' && confirmedDelete) || isUndo || r.route == 'correction_cancel')) {
      viol('apagou_sem_sim', 'removeu ${removed.map((k) => describeTx(before.tx[k]!)).take(3).toList()} (antes: [$prevRoute])');
    }
    if (changed.isNotEmpty && !const {'edited', 'undo', 'correction'}.contains(r.route)) {
      viol('mudou_sem_comando', 'mudou ${changed.map((k) => '${describeTx(before.tx[k]!)} ⇒ ${describeTx(after.tx[k]!)}').take(2).toList()}');
    }
    if (r.route == 'deleted' && removed.isEmpty) viol('disse_que_apagou_sem_apagar', shortReply);
    if (r.route == 'edited' && !dataChanged) viol('disse_que_mudou_sem_mudar', shortReply);
    if (added.isNotEmpty && _askDateRe.hasMatch(prevText) && RegExp(r'^(?:sei la|nao lembro|nao sei|sei nao|nem lembro)').hasMatch(s)) {
      viol('data_assumida_apos_nao_sei', 'salvou ${added.map((m) => '${m['title']} ${m['amount']} em ${ddmmyy(_day(DateTime.parse(m['date'] as String)))}').toList()} depois de "${lt.text}" à pergunta da data :: $shortReply');
    }
    if (lt.noEdit && !isUndo && (changed.isNotEmpty || removed.isNotEmpty)) {
      viol('registro_mudou_sem_pedido',
          '${[...changed.map((k) => '${describeTx(before.tx[k]!)} ⇒ ${describeTx(after.tx[k]!)}'), ...removed.map((k) => 'APAGOU ${describeTx(before.tx[k]!)}')].take(2).toList()} :: $shortReply');
    }
    if (lt.orphan && added.isNotEmpty) viol('resposta_orfa_salva', 'salvou ${added.map((m) => '${m['title']} ${m['amount']}').toList()} sem nada pendente');

    // ── desfazer exato (pilha de snapshots) ──
    if (isUndo || r.route == 'undo_failed') {
      if (undoStack.isNotEmpty) {
        final exp = undoStack.removeLast();
        if (isUndo && !after.sameData(exp)) {
          viol(dataChanged ? 'desfaz_impreciso' : 'desfaz_nao_desfez', 'esperado voltar ao snapshot anterior; diferença: ${after.diff(exp)}');
        }
      } else if (!stale && dataChanged) {
        viol('desfaz_sem_historico_mudou', before.diff(after));
      } else if (stale) {
        for (final id in extDeleted) {
          if (after.tx.containsKey(id) && !before.tx.containsKey(id)) viol('desfaz_ressuscitou_extrato', 'voltou ${describeTx(after.tx[id]!)} que o usuário apagou no Extrato');
        }
        for (final e in extEdited.entries) {
          if (before.tx[e.key] == e.value && after.tx[e.key] != null && after.tx[e.key] != e.value) {
            viol('desfaz_reverteu_extrato', '${describeTx(e.value)} ⇒ ${describeTx(after.tx[e.key]!)}');
          }
        }
      }
      stat('desfaz_conferido');
    } else if (r.route == 'undo_limit') {
      undoStack.clear();
    } else if (r.route == 'undo_empty') {
      if (undoStack.isNotEmpty && !stale) viol('desfaz_nao_desfez', 'disse que não há nada para desfazer com ${undoStack.length} ação(ões) na conversa');
      if (dataChanged) viol('desfaz_sem_historico_mudou', before.diff(after));
    } else if (dataChanged) {
      if (sim.preSaves.isNotEmpty) {
        undoStack.addAll(sim.preSaves);
      } else {
        undoStack.add(before);
      }
    }

    // ── hipótese / intenção / "não aconteceu" nunca grava ──
    if (lt.hyp == true) {
      final goalsChanged = before.goals.toString() != after.goals.toString();
      if (added.isNotEmpty || changed.isNotEmpty || removed.isNotEmpty || goalsChanged || remA.toString() != remB.toString()) {
        viol(lt.notHappened ? 'nao_aconteceu_salvo' : 'hipotese_salva',
            'mudou dados: +${added.map((m) => '${m['title']} ${m['amount']} ${m['type']}').toList()} Δ=${changed.length + removed.length} Δmetas=$goalsChanged Δdívidas=${remA.toString() != remB.toString()} :: $shortReply');
      }
    }
    if (lt.hyp == false) {
      stat('fp_intencao_fato_se_total');
      if (r.route == 'hypothesis' || (_intentReplyRe.hasMatch(reply) && added.isEmpty)) {
        stat('fp_intencao_fato_se');
        viol('fato_virou_hipotese', shortReply);
      }
    }
    if (lt.plainFact && !pendingBefore) {
      stat('fp_intencao_fato_total');
      if (_intentReplyRe.hasMatch(reply) && added.isEmpty) {
        stat('fp_intencao_fato');
        viol('fato_simples_virou_plano', shortReply);
      }
    }
    if (lt.discount) {
      for (final m in added) {
        if (m['type'] == 'income') viol('desconto_virou_receita', 'salvou ${m['title']} ${m['amount']} income');
      }
    }

    // ── perguntas a mais (P2), medidas com denominador ──
    if (!pendingBefore) {
      if (lt.obviousDir) {
        stat('fp_direcao_total');
        if (_askDirRe.hasMatch(reply) && added.isEmpty) {
          stat('fp_direcao');
          viol('pergunta_direcao_obvia', shortReply);
        }
      }
      if (lt.oneValueOnly) {
        stat('fp_split_total');
        if (_askSplitRe.hasMatch(reply)) {
          stat('fp_split');
          viol('split_a_toa', shortReply);
        }
      }
      if (lt.titleDate && !lt.mustAsk) {
        stat('fp_data_titulo_total');
        if (added.isEmpty && _askDateRe.hasMatch(reply)) {
          stat('fp_data_titulo');
          viol('data_perguntada_a_toa', shortReply);
        }
      }
      if (lt.hasMarker && !lt.titleDate) {
        stat('fp_data_marcador_total');
        if (added.isEmpty && _askDateRe.hasMatch(reply)) {
          stat(lt.dateAskOk ? 'fp_data_marcador_ambiguo' : 'fp_data_marcador');
          if (!lt.dateAskOk) viol('data_perguntada_a_toa_marcador', shortReply);
        }
      }
    }

    // ── lançamentos novos ──
    if (!isUndo && added.isNotEmpty) {
      final plural = added.length > 1;
      for (final m in added) {
        final date = _day(DateTime.parse(m['date'] as String));
        final typ = m['type'] as String;
        final amount = (m['amount'] as num).toDouble();
        final rec = m['isRecurrent'] == true;
        final desc = '${m['title']} ${CesarText.money(amount)} $typ em ${ddmmyy(date)}${rec ? ' RECORRENTE dueDay=${m['dueDay']}' : ''}';
        if (!rec && date.isAfter(today)) viol('data_futura', 'salvou $desc');
        if (lt.mustAsk && !rec) viol('data_nao_perguntada', 'salvou $desc (a data dita é futura/inexistente/período)');
        if (lt.vagueDate && !rec) viol(_assumedDateRe.hasMatch(reply) ? 'data_vaga_com_aviso' : 'data_vaga_assumida', 'salvou $desc (data vaga, sem perguntar)');
        final wantDate = lt.valueDate[amount] ?? lt.expDate;
        if (wantDate != null && !rec && date != wantDate && !lt.expAlt.contains(date)) {
          final kind = lt.titleDate
              ? (_assumedDateRe.hasMatch(reply) || lt.family == 'lançar-título-ambíguo' ? 'data_do_titulo_ambigua' : 'data_do_titulo')
              : (plural ? 'data_errada_multi' : 'data_errada');
          viol(kind, 'salvou $desc, esperado ${ddmmyy(wantDate)}');
        }
        if (rec && !RegExp(_recWords).hasMatch(s) && !lt.recurrenceOk) {
          viol(RegExp(_catRecWords).hasMatch(s) ? 'recorrente_por_categoria' : 'recorrente_sem_palavra', 'salvou $desc');
        }
        if (lt.dir != null && !plural && typ != 'transfer' && typ != lt.dir) viol('tipo_trocado', 'frase com sinal de ${lt.dir}, salvou $desc');
        if (lt.single != null && !plural) {
          final ok = (amount - lt.single!).abs() < 0.005 || lt.singleAlt.any((x) => (x - amount).abs() < 0.005);
          if (!ok) viol('valor_trocado', 'esperado ${CesarText.money(lt.single!)}, salvou $desc');
        }
        if (lt.newWord != null && lt.oldWord != null) {
          final title = CesarText.fold(m['title'] as String);
          if (title.contains(lt.oldWord!) && !title.contains(lt.newWord!)) viol('frase_nova_fundida', 'salvou $desc no rascunho antigo "${lt.oldWord}"');
        }
      }
      if (lt.values.length >= 2 && added.length < lt.values.length) {
        final amounts = added.map((m) => (m['amount'] as num).toDouble()).toList();
        final missing = [...lt.values];
        for (final a in amounts) {
          final j = missing.indexWhere((x) => (x - a).abs() < 0.005);
          if (j >= 0) missing.removeAt(j);
        }
        viol(added.length == 1 ? 'multi_valor_um_lancamento' : 'multi_valor_parcial',
            '${lt.values.length} valores ${lt.values.map(CesarText.money).toList()} → ${added.length} lançamento(s) ${added.map((m) => '${m['title']} ${m['amount']}').toList()}; perdeu ${missing.map(CesarText.money).toList()}');
      }
      for (final m in added) {
        final want = lt.valueDir[(m['amount'] as num).toDouble()];
        if (want != null && m['type'] != want && m['type'] != 'transfer') viol('tipo_trocado_multi', 'valor ${m['amount']} devia ser $want, salvou ${m['title']} ${m['type']}');
      }
      if (lt.values.length >= 2) {
        final sum = lt.values.fold(0.0, (a, c) => a + c);
        for (final m in added) {
          final amount = (m['amount'] as num).toDouble();
          if (!lt.values.any((x) => (x - amount).abs() < 0.005)) viol((amount - sum).abs() < 0.005 ? 'multi_somado' : 'multi_valor_inventado', 'salvou ${m['title']} $amount de ${lt.values}');
        }
      }
    }
    if (lt.pendingAnswer && reply.contains('Deixei de lado')) viol('resposta_nao_fundida', 'resposta a "quanto foi?" abriu outro lançamento: $shortReply');
    if (lt.lateAnswer) stat(added.isNotEmpty ? 'resposta_tardia_salvou' : 'resposta_tardia_nao_salvou');

    // ── frase nova completa × estado pendente ──
    if (lt.fullNew && pendingBefore) {
      stat('frase_nova_com_pendencia');
      final notice = _noticeRe.hasMatch(reply);
      final draftSurvived = hadDraft != null && identical(sim.active, hadDraft);
      final batchSurvived = hadBatch != null && identical(sim.pendingBatch, hadBatch);
      final asstSurvived = hadAsst && sim.assistant.hasPendingQuestion && !_newPendingRoutes.contains(r.route);
      if (draftSurvived || batchSurvived || asstSurvived) {
        final what = draftSurvived ? 'rascunho "${hadDraft.rawText}"' : (batchSurvived ? 'lote pendente' : 'pergunta do César (antes: [$prevRoute])');
        viol(notice ? 'pendente_sobreviveu_com_aviso' : 'pendente_sobreviveu', '$what continua pendente :: $shortReply');
      } else if (!notice && (added.isNotEmpty || r.route == 'ask' || r.route == 'ask_multi')) {
        final what = hadDraft != null ? 'rascunho' : (hadBatch != null ? 'lote' : 'pergunta do César [$prevRoute]');
        stat('pendente_descartado_sem_aviso_$what');
        viol('pendente_descartado_sem_aviso', '$what descartado em silêncio :: $shortReply');
      }
      if (sim.draftPending && hadDraft != null && !identical(sim.active, hadDraft) && sim.active!.rawText.contains(hadDraft.rawText.split(' + ').first)) {
        viol('frase_nova_fundida_pendente', 'a frase nova entrou no rascunho antigo, que segue pendente: "${sim.active!.rawText}" :: $shortReply');
      }
    }

    // ── pergunta repetida 3× seguidas sem saída ──
    final pendingAfter = sim.anyPending;
    final qn = reply.replaceAll(RegExp(r'\s+'), ' ').trim();
    qHistory.add([pendingAfter && r.route != 'saved' ? qn : '', s]);
    if (qHistory.length >= 3) {
      final l3 = qHistory.sublist(qHistory.length - 3);
      final same = l3.every((e) => e[0].isNotEmpty && e[0] == l3.first[0]);
      final distinctInputs = l3.map((e) => e[1]).toSet().length >= 2;
      if (same && distinctInputs && !loopFlagged) {
        loopFlagged = true;
        final exit = _exitHintRe.hasMatch(qn);
        if (exit) {
          stat('pergunta_repetida_3x_com_saida');
        } else {
          viol('pergunta_repetida_3x', 'mesma pergunta 3× (${l3.map((e) => '"${e[1]}"').join(', ')}): $shortReply');
        }
      }
      if (!same) loopFlagged = false;
    }

    // ── edição/exclusão só atinge registro cujo título contém o nome dito ──
    if (lt.named != null && !isUndo) {
      final nm = CesarText.fold(lt.named!);
      bool hasName(String json) => CesarText.fold((jsonDecode(json) as Map)['title'] as String).contains(nm);
      if (r.route == 'edited') {
        for (final k in changed) {
          if (!hasName(before.tx[k]!)) {
            final cat = (jsonDecode(before.tx[k]!) as Map)['category'];
            // "Mostrou o item" = César perguntou sobre ele (não basta a confirmação de salvamento).
            final shown = prevText.contains((jsonDecode(before.tx[k]!) as Map)['title'] as String) && _askedAbout.contains(prevRoute);
            viol(shown ? 'editou_outro_com_confirmacao' : (CesarText.categoryWords[nm] == cat ? 'editou_por_categoria' : 'editou_sem_nome'),
                'mudou ${describeTx(before.tx[k]!)} ⇒ ${describeTx(after.tx[k]!)} (nome dito "${lt.named}") :: $shortReply');
          } else if (lt.editValue != null) {
            final a0 = ((jsonDecode(before.tx[k]!) as Map)['amount'] as num).toDouble();
            final a1 = ((jsonDecode(after.tx[k]!) as Map)['amount'] as num).toDouble();
            if ((a1 - lt.editValue!).abs() > 0.005 && (a1 - a0).abs() > 0.005) viol('edit_valor_errado', 'pediu ${lt.editValue}, gravou ${describeTx(after.tx[k]!)}');
          }
        }
      }
      if (r.route == 'deleted') {
        for (final k in removed) {
          final title = (jsonDecode(before.tx[k]!) as Map)['title'] as String;
          if (!hasName(before.tx[k]!)) {
            viol(prevText.contains(title) ? 'confirmou_outro_nome' : 'apagou_outro', 'apagou "$title" (nome dito "${lt.named}") :: confirmação: "${prevText.replaceAll('\n', ' ')}"');
          }
        }
      }
      if (prevText.contains('Os mais próximos') && RegExp(r'^(?:sim|esse|essa|pode ser|isso)').hasMatch(s) && RegExp(r'Não consegui identificar').hasMatch(reply)) {
        viol('sugestao_sim_falhou', 'sugestão anterior: "${prevText.replaceAll('\n', ' ')}" :: $shortReply');
      }
    }
    prevRoute = r.route;
    prevText = r.text;
  }
  return RunC(v, sent);
}

Future<List<LC>> minimizeC(LocalFinancialNlpEngine engine, List<LC> turns, String kind, Stopwatch sw, int deadlineMs) async {
  Future<bool> fails(List<LC> ts) async => (await runC(engine, fixed: ts)).v.any((x) => x.kind == kind);
  var cur = List<LC>.from(turns);
  final first = (await runC(engine, fixed: cur)).v.where((x) => x.kind == kind).toList();
  if (first.isEmpty) return cur;
  cur = cur.sublist(0, first.first.turn + 1);
  for (var k = 1; k <= min(4, cur.length); k++) {
    final cand = cur.sublist(cur.length - k);
    if (await fails(cand)) return cand;
  }
  var chunk = max(1, cur.length ~/ 2);
  while (chunk >= 1) {
    var i = 0;
    var progressed = false;
    while (i < cur.length) {
      if (sw.elapsedMilliseconds > deadlineMs) return cur;
      final end = min(cur.length, i + chunk);
      final cand = [...cur.sublist(0, i), ...cur.sublist(end)];
      if (cand.isNotEmpty && await fails(cand)) {
        cur = cand;
        progressed = true;
      } else {
        i += chunk;
      }
    }
    if (!progressed) chunk ~/= 2;
  }
  return cur;
}

// ───────────────────────── casos-alvo determinísticos ─────────────────────────

LC C(String t,
        {String? dir,
        bool obvious = false,
        double? single,
        List<double> values = const [],
        DateTime? exp,
        Set<DateTime> expAlt = const {},
        bool ask = false,
        bool? hyp,
        bool notHappened = false,
        String? named,
        double? edit,
        bool title = false,
        bool vague = false,
        bool answer = false,
        bool one = false,
        bool fullNew = false,
        bool noEdit = false,
        bool orphan = false,
        bool discount = false,
        bool marker = false,
        bool askOk = false,
        bool fact = false,
        String? newWord,
        String? oldWord,
        Map<double, String> valueDir = const {}}) =>
    LC(t, 'alvo')
      ..dir = dir
      ..obviousDir = obvious
      ..single = single
      ..values = values
      ..expDate = exp
      ..expAlt = expAlt
      ..mustAsk = ask
      ..hyp = hyp
      ..notHappened = notHappened
      ..named = named
      ..editValue = edit
      ..titleDate = title
      ..vagueDate = vague
      ..pendingAnswer = answer
      ..oneValueOnly = one
      ..fullNew = fullNew
      ..noEdit = noEdit
      ..orphan = orphan
      ..discount = discount
      ..hasMarker = marker
      ..dateAskOk = askOk
      ..plainFact = fact
      ..newWord = newWord
      ..oldWord = oldWord
      ..valueDir = valueDir;

String dm(DateTime d) => '${d.day}/${d.month}';

List<List<LC>> targetedC() {
  final t = today;
  final prev20 = back(20);
  final tomorrow = DateTime(t.year, t.month, t.day + 1);
  LC inc(String s, double v) => C(s, dir: 'income', obvious: true, single: v, exp: t, fact: true);
  LC exp(String s, double v) => C(s, dir: 'expense', obvious: true, single: v, exp: t, fact: true);
  LC dt(String s, double v, DateTime? d, {Set<DateTime> alt = const {}, bool askOk = false}) =>
      C(s, dir: 'expense', single: v, exp: d, expAlt: alt, marker: d != null, askOk: askOk, fact: true);
  LC ttl(String s, double v) => C(s, dir: 'expense', single: v, exp: t, title: true, fact: true);
  LC one(String s, double v) => C(s, dir: 'expense', single: v, exp: t, one: true, fact: true);
  LC hyp(String s) => C(s, hyp: true);
  LC nh(String s) => C(s, hyp: true, notHappened: true);
  LC fse(String s, String d, double v) => C(s, dir: d, single: v, exp: t, hyp: false);
  return [
    // ── A. gate: direção ──
    [inc('o freguês me pagou 230 no pix', 230)],
    [inc('minha sogra me mandou 150 no pix', 150)],
    [inc('a empresa me reembolsou 87 no pix', 87)],
    [inc('recebi 35 de gorjeta no dinheiro', 35)],
    [inc('faturei 410 no bazar no pix', 410)],
    [inc('vendi 180 em salgados no pix', 180)],
    [inc('ganhei 22 de cashback no pix', 22)],
    [inc('a loja me estornou 64 no pix', 64)],
    [inc('lucrei 300 na revenda no pix', 300)],
    [inc('entrou um pix de 95 da cliente', 95)],
    [inc('meu cunhado me pagou os 200 que devia no pix', 200)],
    [inc('a vizinha me pagou 45 pela costura no pix', 45)],
    [inc('recebi 120 pela revisão do tcc no pix', 120)],
    [exp('paguei 120 pro eletricista no pix', 120)],
    [exp('dei 5 pro flanelinha no dinheiro', 5)],
    [exp('mandei 250 pra minha irmã no pix', 250)],
    [exp('quitei 900 da fatura no pix', 900)],
    [exp('o mecânico me cobrou 380 no pix', 380)],
    [exp('tive que pagar 150 de multa do condomínio no pix', 150)],
    [exp('deixei 12 de gorjeta pro garçom no dinheiro', 12)],
    [exp('contribuí com 40 na vaquinha no pix', 40)],
    [exp('doei 60 pra creche no pix', 60)],
    [exp('a farmácia me cobrou 47 no débito', 47)],
    [exp('me cobraram 9 de taxa de entrega no pix', 9)],
    [exp('paguei a diarista, deu 180 no pix', 180)],
    [exp('torrei 260 no shopping no pix', 260)],
    [exp('pixei 70 pro pintor', 70)],
    [C('recebi a conta de gás de 118'), C('no boleto', dir: 'expense', single: 118, exp: t)],
    [C('chegou a fatura da internet de 99'), C('no pix', dir: 'expense', single: 99, exp: t)],
    [C('devolvi 100 que o joão tinha me emprestado no pix', dir: 'expense', single: 100, exp: t)],
    [C('peguei 500 emprestado com a minha mãe no pix', dir: 'income', single: 500, exp: t)],
    [C('emprestei 300 pro meu primo no pix', dir: 'expense', single: 300, exp: t)],
    [C('o aluguel da garagem rendeu 300 no pix', dir: 'income', single: 300, exp: t)],
    [C('ganhei 40 de desconto na ótica no pix', discount: true)],
    [C('consegui 25 de abatimento no conserto no pix', discount: true)],
    [C('me deram 30 de desconto no tênis no pix', discount: true)],
    // ── B. gate: datas (relativas a hoje) ──
    [dt('gastei 47 na quitanda ontem no fim da tarde no pix', 47, back(1))],
    [dt('paguei 30 no guincho anteontem de noite no pix', 30, back(2))],
    [dt('há quatro dias paguei 85 na costureira no pix', 85, back(4))],
    [dt('paguei 60 no chaveiro 9 dias atrás no pix', 60, back(9))],
    [dt('faz uma semana gastei 33 no açaí no pix', 33, back(7), askOk: true)],
    [dt('gastei 41 na feira quinta passada no pix', 41, wdLast(4))],
    [dt('gastei 41 no hortifruti na quinta de manhã no pix', 41, wdLast(4), alt: {t})],
    [dt('paguei 20 no estacionamento no domingo à tarde no pix', 20, wdLast(7))],
    [dt('paguei 20 no estacionamento na terça retrasada no pix', 20, DateTime(wdLast(2).year, wdLast(2).month, wdLast(2).day - 7))],
    [dt('gastei 18 no açaí dia 1º no pix', 18, diaN(1))],
    [dt('gastei 18 no açaí no dia 30 no pix', 18, diaN(30))],
    [C('gastei 18 no açaí dia 31 no pix', dir: 'expense', ask: diaN(31) == null, exp: diaN(31))],
    [dt('gastei 18 no açaí em ${dm(back(1))} no pix', 18, back(1))],
    [C('gastei 18 no açaí no dia ${dm(tomorrow)} no pix', dir: 'expense', ask: true)],
    [dt('gastei 18 no açaí ${prev20.day} de ${monthNames[prev20.month - 1]} no pix', 18, prev20)],
    [dt('mês passado no dia 12 gastei 75 no guincho no pix', 75, DateTime(t.year, t.month - 1, 12), askOk: true)],
    [C('gastei 52 na feira amanhã cedo no pix', dir: 'expense', ask: true)],
    [C('gastei 52 na feira no próximo sábado no pix', dir: 'expense', ask: true)],
    [C('gastei 52 na feira dia desses no pix', dir: 'expense', vague: true)],
    [C('gastei 52 na feira recentemente no pix', dir: 'expense', vague: true)],
    [dt('hoje na hora do almoço gastei 29 no açaí no pix', 29, t)],
    [dt('hoje lembrei que paguei 64 no guincho anteontem no pix', 64, back(2))],
    [dt('agorinha paguei 15 no estacionamento no pix', 15, t)],
    [dt('ontem à noitinha a vizinha me pagou 45 pela costura no pix', 45, back(1))..dir = 'income'],
    [dt('o mecânico me cobrou 380 há cinco dias no pix', 380, back(5))],
    // títulos com palavra de data
    [ttl('gastei 22 na Padaria Ontem e Hoje no pix', 22)],
    [ttl('gastei 71 no Bar 7 Dias no pix', 71)],
    [ttl('gastei 33 no Empório Dia 1 no pix', 33)],
    [ttl('gastei 88 na Pizzaria Sábado à Noite no pix', 88)],
    [ttl('gastei 27 na Quitanda do Domingos no pix', 27)],
    [ttl('paguei 35 no Lava-Jato Amanhã no pix', 35)],
    [ttl('gastei 90 numa loja da avenida 9 de julho no pix', 90)],
    [ttl('gastei 40 na rua 1º de maio no pix', 40)],
    [ttl('gastei 40 na travessa 2 de dezembro no pix', 40)],
    [ttl('gastei 55 no Sacolão 24 Horas no pix', 55)],
    [ttl('paguei 290 na Ótica Segunda Visão no pix', 290)],
    [ttl('gastei 61 no Bar Fim de Tarde no pix', 61)],
    [ttl('paguei 400 no Hotel Quinta das Flores no pix', 400)],
    [C('gastei 44 na Feira da Segunda no pix', dir: 'expense', single: 44)],
    [C('ontem gastei 71 no Bar 7 Dias no pix', dir: 'expense', single: 71, exp: back(1), marker: true)],
    [C('gastei 33 no Empório Dia 1 no domingo no pix', dir: 'expense', single: 33, exp: wdLast(7), marker: true)],
    // ── C. gate: números ──
    [one('paguei 64 na consulta do box 7 no pix', 64)],
    [one('gastei 39 no lanche do apto 302 no pix', 39)],
    [one('comprei um vinho safra 2019 por 95 no pix', 95)],
    [one('paguei 380 na mensalidade do 3º ano no pix', 380)],
    [one('gastei 26 em 6 latinhas no pix', 26)],
    [one('comprei uma bateria 60 amperes por 380 no pix', 380)],
    [one('gastei 77 na loja 3 do térreo no pix', 77)],
    [one('comprei um celular de 128 gigas por 1240 no pix', 1240)],
    [one('gastei 215 no voo das 6h40 no pix', 215)],
    [one('paguei 140 na sala 1204 no pix', 140)],
    [one('gastei 77 com 2 kg de carne no pix', 77)],
    [one('paguei 13 de pedágio na BR 101 no pix', 13)],
    [one('comprei o jogo FIFA 26 por 215 no pix', 215)],
    [one('paguei 95 pelo plano de 500 mega no pix', 95)],
    [one('gastei 140 na 3ª sessão de fisio no pix', 140)],
    [one('paguei 52 no 1º dia de aula no pix', 52)],
    [one('comprei 12 ovos caipira por 26 no pix', 26)],
    [one('paguei 140 no conserto do fogão de 4 bocas no pix', 140)],
    [one('gastei 39 na farmácia da quadra 405 no pix', 39)],
    [one('paguei 95 na vacina da 2ª dose no pix', 95)],
    [one('comprei 5 metros de tecido por 64 no pix', 64)],
    [one('paguei 52 no corte com 15% de desconto no pix', 52)],
    [one('paguei 140 no rodízio às 20h no pix', 140)],
    [one('gastei 380 no Hotel 3 Estrelas no pix', 380)..titleDate = true],
    [one('paguei 64 no 123 Milhas no pix', 64)..titleDate = true],
    [one('gastei 13 no 7 Belo no pix', 13)..titleDate = true],
    [C('gastei 23 na farmácia e 14 na ótica no pix', dir: 'expense', values: [23, 14])],
    [C('39 no pão, 13 no leite no pix', dir: 'expense', values: [39, 13])],
    [C('paguei 95 de água, 140 de luz no pix', dir: 'expense', values: [95, 140])],
    [C('deu 64 o almoço e 26 a sobremesa no pix', dir: 'expense', values: [64, 26])],
    [C('gastei 52 reais na feira e 77 reais no açougue no pix', dir: 'expense', values: [52, 77])],
    [C('comprei pão por 13 e leite por 7 no pix', dir: 'expense', values: [13, 7])],
    [C('gastei 140 pila no posto, 39 pila no lava-jato no pix', dir: 'expense', values: [140, 39])],
    [C('na quitanda 26 e no açougue 77 no pix', dir: 'expense', values: [26, 77])],
    [C('paguei 215 no guincho e mais 64 na borracharia no pix', dir: 'expense', values: [215, 64])],
    [C('foram 39 de uber e 13 de pedágio no pix', dir: 'expense', values: [39, 13])],
    [C('52 de cerveja e 77 de carvão no pix', dir: 'expense', values: [52, 77])],
    [C('paguei 95 de gás e 95 de água no pix', dir: 'expense', values: [95, 95])],
    [C('gastei 13 no pão, 7 no leite e 13 no café no pix', dir: 'expense', values: [13, 7, 13])],
    [C('gastei 23 na farmácia e 14 na ótica no pix, tudo anteontem', dir: 'expense', values: [23, 14], exp: back(2))],
    [C('ontem: gastei 23 na farmácia e 14 na ótica no pix', dir: 'expense', values: [23, 14], exp: back(1))],
    [C('recebi 380 do freela e paguei 52 de imposto no pix', values: [380, 52], valueDir: {380: 'income', 52: 'expense'})],
    [C('vendi a bike por 640 e gastei 140 na oficina no pix', values: [640, 140], valueDir: {640: 'income', 140: 'expense'})],
    [C('a cliente me pagou 215 e eu gastei 95 no mercado no pix', values: [215, 95], valueDir: {215: 'income', 95: 'expense'})],
    // ── D. gate: intenção / não aconteceu / fato com "se" ──
    [hyp('tô a fim de gastar 300 num tênis no pix')],
    [hyp('to querendo comprar um fone de 200 no pix')],
    [hyp('tenho que pagar 380 de iptu semana que vem')],
    [hyp('vou ter que gastar 600 no conserto do carro')],
    [hyp('preciso pagar 140 de luz até sexta')],
    [hyp('devo gastar uns 250 na festa no pix')],
    [hyp('se eu fosse gastar 60 no cinema')],
    [hyp('supondo que eu gaste 95 na feira no pix')],
    [hyp('digamos que eu receba 1240 de bônus')],
    [hyp('e se eu recebesse 380?')],
    [hyp('vou receber 640 do freela amanhã')],
    [hyp('talvez eu gaste 215 no mercado no pix')],
    [hyp('pode ser que eu pague 380 no conserto')],
    [hyp('to cogitando comprar um sofá de 1240')],
    [hyp('estou orçando uma reforma de 1240')],
    [hyp('me ofereceram um celular por 640')],
    [hyp('ainda vou pagar os 380 do dentista')],
    [hyp('falta pagar 640 do cartão')],
    [hyp('pensei em gastar 95 no salão no pix')],
    [hyp('minha ideia é gastar 140 no presente no pix')],
    [hyp('to a fim de gastar 300 num tênis'), C('no pix', hyp: true)],
    [hyp('supondo que eu gaste 95 na feira'), C('no débito', hyp: true)],
    [hyp('vou ter que gastar 600 no conserto do carro'), hyp('no pix')],
    [hyp('preciso pagar 140 de luz até sexta'), hyp('no pix')],
    [hyp('devo gastar uns 250 na festa no pix'), hyp('no buffet')],
    [hyp('pode ser que eu pague 380 no conserto'), hyp('na oficina no pix')],
    [hyp('estou orçando uma reforma de 1240'), hyp('na loja de material no pix')],
    [hyp('falta pagar 640 do cartão'), hyp('pix')],
    [hyp('me ofereceram um celular por 640'), hyp('saiu')],
    [hyp('tenho que pagar 380 de iptu semana que vem'), hyp('no boleto')],
    [nh('não cheguei a gastar os 215'), nh('saiu')],
    [nh('o pix de 95 não foi, deu erro'), nh('no mercado')],
    [nh('a compra de 640 foi recusada no cartão'), nh('na loja, no crédito')],
    [nh('era pra eu pagar 140 hoje mas esqueci'), nh('luz no pix')],
    [nh('quase paguei 140 num ingresso')],
    [nh('desisti do tênis de 380')],
    [nh('não cheguei a gastar os 215')],
    [nh('o pix de 95 não foi, deu erro')],
    [nh('a compra de 640 foi recusada no cartão')],
    [nh('no fim não gastei os 52 da feira')],
    [nh('era pra eu pagar 140 hoje mas esqueci')],
    [fse('paguei 380 no conserto, se não me engano no pix', 'expense', 380)],
    [fse('recebi 640 do freela no pix, caso você queira anotar', 'income', 640)],
    [fse('gastei 39 na farmácia no pix, se for pra lembrar', 'expense', 39)],
    [fse('comprei 77 de ração no pix porque se acabar é ruim', 'expense', 77)],
    [fse('pagamos 215 de luz no pix, se bem me lembro', 'expense', 215)],
    [fse('fui ao mercado e gastei 140 no pix, caso precise', 'expense', 140)],
    [fse('a vizinha me pagou 45 no pix, se ela pedir recibo te falo', 'income', 45)],
    [fse('gastei 13 no açaí no pix mesmo se tava caro', 'expense', 13)],
    // ── E. pendências encadeadas ──
    [C('paguei o flanelinha no dinheiro'), C('quanto gastei ontem?', noEdit: true), C('5', single: 5)],
    [C('gastei na quitanda no pix'), C('apaga o 7 belo', named: '7 belo'), C('sim', named: '7 belo'), C('47', single: 47, dir: 'expense')],
    [C('gastei na quitanda no pix'), C('apaga o 7 belo', named: '7 belo'), C('47', single: 47, dir: 'expense', noEdit: true)],
    [C('comprei areia pro gato no pix'), C('e se fosse 90?', hyp: true, noEdit: true), C('45', single: 45, dir: 'expense'), C('desfaz')],
    [C('a vizinha me pagou no pix'), C('gastei 30 no chaveiro do bairro no pix', fullNew: true, dir: 'expense', single: 30, exp: t, newWord: 'chaveiro', oldWord: 'vizinha'), C('desfaz')],
    [C('paguei o guincho no pix'), opTurn('⟲reinicio'), C('150', noEdit: true, orphan: true)],
    [C('paguei o guincho no pix'), opTurn('⟲nuvem'), C('150', single: 150, dir: 'expense')],
    [C('apaga o 123 milhas', named: '123 milhas'), opTurn('⟲nuvem'), C('sim', named: '123 milhas', noEdit: true)],
    [C('apaga o 123 milhas', named: '123 milhas'), opTurn('⟲reinicio'), C('sim', named: '123 milhas', noEdit: true)],
    [C('apaga o 123 milhas', named: '123 milhas'), opTurn('⟲extrato-edita:123 Milhas'), C('sim', named: '123 milhas'), C('desfaz')],
    [C('apaga o 123 milhas', named: '123 milhas'), opTurn('⟲extrato-apaga:123 Milhas'), C('sim', named: '123 milhas'), C('desfaz')],
    [C('muda a feira de quarta pra 30', named: 'feira', edit: 30), C('sim', named: 'feira', edit: 30), C('2', named: 'feira', edit: 30)],
    [C('muda a feira de quarta pra 30', named: 'feira', edit: 30), C('gastei 30 no chaveiro do bairro no pix', fullNew: true, dir: 'expense', single: 30, exp: t), C('sim', noEdit: true)],
    [C('apaga a feira', named: 'feira'), C('gastei 30 no chaveiro do bairro no pix', fullNew: true, dir: 'expense', single: 30, exp: t), C('1', noEdit: true)],
    [C('apaga o 7 belo', named: '7 belo'), C('recebi 95 da cliente da costura no pix', fullNew: true, dir: 'income', single: 95, exp: t), C('sim', noEdit: true)],
    [C('gastei 23 na farmácia e 14 na ótica'), C('recebi 200 da cliente da costura no pix', fullNew: true, dir: 'income', single: 200, exp: t), C('no pix')],
    [C('gastei 23 na farmácia e 14 na ótica'), C('apaga o 7 belo', named: '7 belo'), C('no pix')],
    [C('gastei 23 na farmácia e 14 na ótica'), C('quanto gastei ontem?'), C('no pix')],
    [C('paguei o guincho no pix'), C('gastei 23 na farmácia e 14 na ótica no pix', fullNew: true, values: [23, 14], dir: 'expense')],
    [C('paguei o guincho no pix'), C('quanto gastei ontem?', noEdit: true), C('apaga o 7 belo', named: '7 belo'), C('sim', named: '7 belo'), C('foi 150', single: 150), C('desfaz'), C('desfaz')],
    [C('paguei o guincho no pix'), C('passa o 7 belo pra 14', named: '7 belo', edit: 14), C('150', single: 150, dir: 'expense', noEdit: true)],
    [C('comprei um presente pra minha mãe no crédito à vista'), C('por pouco não gastei 40 no bar', hyp: true, notHappened: true, noEdit: true), C('215', single: 215, dir: 'expense')],
    [C('recebi o aluguel da garagem no pix'), C('abasteci 140 no posto no débito', fullNew: true, dir: 'expense', single: 140, exp: t, newWord: 'posto', oldWord: 'garagem')],
    [C('recebi o aluguel da garagem no pix'), C('foi 300 no domingo', single: 300, dir: 'income', exp: wdLast(7), answer: true)],
    [C('gastei na oficina no débito'), C('o eletricista me cobrou 95 no pix', fullNew: true, dir: 'expense', single: 95, exp: t, newWord: 'eletricista', oldWord: 'oficina')],
    [C('comprei areia pro gato no pix'), C('vendi uma bicicleta por 380 no pix', fullNew: true, dir: 'income', single: 380, exp: t, newWord: 'bicicleta', oldWord: 'areia')],
    // respostas ambíguas / pergunta repetida
    [C('paguei o flanelinha no dinheiro'), C('sei lá', noEdit: true), C('não lembro', noEdit: true), C('hm', noEdit: true), C('depende', noEdit: true), C('cancela')],
    [C('gastei 52 no açaí'), C('sei lá', noEdit: true), C('tanto faz', noEdit: true), C('o de sempre', noEdit: true), C('no pix')],
    [C('apaga a feira', named: 'feira'), C('7', noEdit: true), C('9', noEdit: true), C('8', noEdit: true), C('nenhum')],
    [C('muda a feira pra 50', named: 'feira', edit: 50), C('o quinto', noEdit: true), C('o de 30', noEdit: true), C('9', noEdit: true), C('1', named: 'feira', edit: 50)],
    [C('gastei 77 na feira dia desses no pix'), C('sei lá', noEdit: true), C('não lembro', noEdit: true), C('hm', noEdit: true)],
    [C('fiquei com 52 da vaquinha'), C('sei lá', noEdit: true), C('hm', noEdit: true), C('não sei te dizer', noEdit: true)],
    // ── F. estados de edição ──
    [C('gastei 35 no açaí do bairro no pix'), C('passa', named: 'acai'), C('gastei 30 no chaveiro do bairro no pix', fullNew: true, noEdit: true, dir: 'expense', single: 30, exp: t)],
    [C('gastei 35 no açaí do bairro no pix'), C('edita', named: 'acai'), C('na verdade a pizzaria foi 95', named: 'pizzaria', edit: 95)],
    [C('gastei 35 no açaí do bairro no pix'), C('muda', named: 'acai'), C('muda', named: 'acai'), C('muda', named: 'acai')],
    [C('gastei 35 no açaí do bairro no pix'), C('corrige', named: 'acai'), C('quanto gastei hoje?', noEdit: true)],
    [C('gastei 35 no açaí do bairro no pix'), C('altera', named: 'acai'), opTurn('⟲reinicio'), C('40', noEdit: true, orphan: true)],
    [C('gastei 35 no açaí do bairro no pix'), C('troca', named: 'acai'), C('por pouco não gastei 50 no bar', noEdit: true, hyp: true, notHappened: true)],
    [C('recebi 640 de comissão do bazar no pix'), C('passa', named: 'bazar'), C('e se fosse 700?', noEdit: true, hyp: true)],
    [C('gastei 35 no açaí do bairro no pix'), C('muda', named: 'acai'), C('pra 38', named: 'acai', edit: 38)],
    [C('gastei 35 no açaí do bairro no pix'), C('quero mudar', named: 'acai'), C('foi no débito', named: 'acai')],
    [C('gastei 35 no açaí do bairro no pix'), C('muda isso', named: 'acai'), C('apaga o 123 milhas', named: '123 milhas'), C('sim', named: '123 milhas')],
    [C('paguei 64 no guincho no débito'), C('passa', named: 'guincho'), C('o eletricista me cobrou 95 no pix', fullNew: true, noEdit: true, dir: 'expense', single: 95, exp: t)],
    [C('comprei um ventilador de 140 no pix'), C('edita', named: 'ventilador'), C('vendi uma bicicleta por 380 no pix', fullNew: true, noEdit: true, dir: 'income', single: 380, exp: t)],
    [C('comprei um ventilador de 140 no pix'), C('muda', named: 'ventilador'), C('esquece', noEdit: true), C('39', noEdit: true)],
    // "na verdade o X…"
    [C('na verdade a pizzaria foi 95', named: 'pizzaria', edit: 95)],
    [C('na real a quitanda deu 31', named: 'quitanda', edit: 31)],
    [C('pensando bem o lava-jato foi 40', named: 'lava', edit: 40)],
    [C('na verdade foi 65 a costureira', named: 'costureira', edit: 65)],
    [C('corrigindo: a oficina foi 410', named: 'oficina', edit: 410)],
    [C('gastei 20 no açaí no pix'), C('na verdade o açougue foi 23', named: 'acougue', edit: 23)],
    [C('gastei 20 no açaí no pix'), C('na verdade o cinema foi 23', named: 'cinema', edit: 23)],
    [C('na verdade a feira foi 50', named: 'feira', edit: 50), C('2', named: 'feira', edit: 50)],
    [C('na verdade o 7 belo foi 15', named: '7 belo', edit: 15)],
    [C('na verdade o 123 milhas foi 700', named: '123 milhas', edit: 700)],
    [C('na verdade a padaria ontem e hoje foi 25', named: 'padaria', edit: 25)],
    [C('na verdade o empório dia 1 foi 36', named: 'emporio', edit: 36)],
    [C('na verdade o domingos foi 30', named: 'domingos', edit: 30)],
    [C('na verdade o bar 7 dias foi 70', named: 'bar 7 dias', edit: 70)],
    [C('gastei 20 no açaí no pix'), C('na verdade foi 22', named: 'acai', edit: 22)],
    // resolvedor: títulos numéricos / com palavra de data / 2+ sugestões
    [C('passa o 7 belo pra 14', named: '7 belo', edit: 14)],
    [C('muda o 123 milhas pra 610', named: '123 milhas', edit: 610)],
    [C('apaga o 123 milhas', named: '123 milhas'), C('sim', named: '123 milhas')],
    [C('muda a padaria ontem e hoje pra 24', named: 'padaria', edit: 24)],
    [C('muda o bar 7 dias pra 70', named: 'bar 7 dias', edit: 70)],
    [C('muda o empório dia 1 pra 30', named: 'emporio', edit: 30)],
    [C('apaga a feira da segunda', named: 'feira'), C('sim', named: 'feira')],
    [C('muda a feira de sábado pra 47', named: 'feira', edit: 47)],
    [C('muda a feira de quarta pra 47', named: 'feira', edit: 47), C('sim', named: 'feira', edit: 47)],
    [C('apaga a feira de quarta', named: 'feira'), C('sim', named: 'feira'), C('sim', named: 'feira', noEdit: true)],
    [C('muda o domingos pra 30', named: 'domingos', edit: 30)],
    [C('apaga o do domingos', named: 'domingos'), C('sim', named: 'domingos')],
    [C('muda a quitanda de terça pra 31', named: 'quitanda', edit: 31)],
    [C('muda o almoço de ontem pra 90', named: 'almoco', edit: 90), C('sim', named: 'almoco', edit: 90)],
    [C('muda o mercado de terça pra 30', named: 'mercado', edit: 30), C('sim', named: 'mercado', edit: 30)],
    [C('muda o conserto de domingo pra 400', named: 'conserto', edit: 400)],
    [C('a ótica 2000 foi 280', named: 'otica', edit: 280)],
    [C('o 7 belo foi 13', named: '7 belo', edit: 13)],
    [C('passa a garagem pra 320', named: 'garagem', edit: 320)],
    [C('muda o freela pra 900', named: 'freela', edit: 900)],
    [C('muda o 123 de sábado passado pra 600', named: '123', edit: 600)],
    [C('apaga o 2000', named: '2000'), C('sim', named: '2000')],
    [C('muda o 7 pra 14', named: '7', edit: 14)],
    // reproduções mínimas do fuzz (confirmadas em repositório novo)
    [C('gastei 64 no açaí no pix'), C('na verdade o 7 belo foi 15', named: '7 belo', edit: 15)],
    [C('gastei 64 no açaí no pix'), C('na real o 7 belo deu 15', named: '7 belo', edit: 15)],
    [C('gastei 64 no açaí no pix'), C('na verdade o 123 milhas foi 700', named: '123 milhas', edit: 700)],
    [C('recebi 300 do freela no pix'), C('na verdade o açougue foi 23', named: 'acougue', edit: 23)],
    [C('na verdade a pizzaria foi 26', named: 'pizzaria', edit: 26), C('na verdade o açougue foi 77', named: 'acougue', edit: 77)],
    [C('passa o 7 belo pra 14', named: '7 belo', edit: 14), C('na verdade o cinema foi 30', named: 'cinema', edit: 30)],
    [C('paguei 52 no guincho no débito'), C('era pra eu pagar 77 hoje mas esqueci', hyp: true, notHappened: true, noEdit: true)],
    [nh('ia pagar 77 hoje mas desisti'), nh('no mercado no pix')],
    [C('peguei 500 emprestado com a minha mãe no pix'), C('no banco', dir: 'income', single: 500)],
    [C('emprestei 64 no dia ${dm(DateTime(t.year, t.month, t.day + 14))} pro meu primo no pix', ask: true)],
    [C('mês passado no dia 16 emprestei 52 pro meu primo no dinheiro', exp: DateTime(t.year, t.month - 1, 16), marker: true)],
    [C('emprestei 52 pro meu primo anteontem no pix', exp: back(2), marker: true)],
    [C('foi 52 o almoço e 39 a sobremesa no pix', values: [52, 39])],
    [C('gastei 64 na farmácia e 13 na ótica'), C('qual meu saldo?'), C('qual meu saldo?')],
    [C('gastei 64 na farmácia e 13 na ótica'), C('apaga o 7 belo', named: '7 belo'), C('apaga o 7 belo', named: '7 belo')],
    // ── G. desfazer, Extrato, reinício, nuvem ──
    [C('gastei 35 no açaí do bairro no pix'), C('muda pra 38', named: 'acai', edit: 38), C('desfaz'), C('desfaz'), C('desfaz')],
    [C('apaga o 7 belo', named: '7 belo'), C('sim', named: '7 belo'), C('desfaz')],
    [C('gastei 23 na farmácia e 14 na ótica no pix'), C('desfaz'), C('desfaz')],
    [C('passa o 7 belo pra 14', named: '7 belo', edit: 14), opTurn('⟲extrato-apaga:7 Belo'), C('desfaz')],
    [C('passa o 7 belo pra 14', named: '7 belo', edit: 14), opTurn('⟲extrato-edita:7 Belo'), C('desfaz')],
    [C('gastei 35 no açaí do bairro no pix'), opTurn('⟲reinicio'), C('desfaz', noEdit: true)],
    [C('gastei 35 no açaí do bairro no pix'), opTurn('⟲nuvem'), C('desfaz', noEdit: true)],
    [C('gastei 35 no açaí do bairro no pix'), C('passa', named: 'acai'), opTurn('⟲extrato-apaga'), C('40', noEdit: true)],
    [C('gastei 35 no açaí do bairro no pix'), C('passa', named: 'acai'), opTurn('⟲nuvem'), C('40', noEdit: true)],
    [C('muda a feira de quarta pra 30', named: 'feira', edit: 30), opTurn('⟲nuvem'), C('sim', noEdit: true)],
    [C('apaga a feira', named: 'feira'), opTurn('⟲extrato-apaga:Feira da Segunda'), C('1', named: 'feira'), C('sim', named: 'feira'), C('desfaz')],
    [C('gastei 35 no açaí do bairro no pix'), C('apaga o último', named: 'acai'), C('sim', named: 'acai'), C('desfaz'), C('desfaz')],
  ];
}

// ───────────────────────── relógio injetado ─────────────────────────

final clocks = <String, DateTime>{
  '1º do mês (qui, hoje real)': DateTime(2026, 10, 1, 10),
  '29/02 (ter)': DateTime(2028, 2, 29, 12),
  '01/03 bissexto (qua)': DateTime(2028, 3, 1, 8),
  '31/12 23:59:59 (qui)': DateTime(2026, 12, 31, 23, 59, 59),
  '01/01 00:00:01 (sex)': DateTime(2027, 1, 1, 0, 0, 1),
  'domingo': DateTime(2026, 10, 4, 12),
  'segunda 00:00:01': DateTime(2026, 10, 5, 0, 0, 1),
  '01/03 (seg)': DateTime(2027, 3, 1, 9),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  test('CHAOS-C casos-alvo', () async {
    var n = 0, bad = 0;
    final byKind = <String, int>{};
    for (final seq in targetedC()) {
      n += seq.length;
      final trace = <String>[];
      final res = await runC(engine, fixed: seq, trace: trace);
      final label = seq.map((e) => '"${e.text}"').join(' ⏎ ');
      print('CHAOS-C|ALVO| $label ⇒ ${trace.join(' ⏎ ')}');
      for (final x in res.v) {
        bad++;
        byKind[x.kind] = (byKind[x.kind] ?? 0) + 1;
        print('CHAOS-C|ALVO-V| ${sev(x.kind)} ${x.kind}: $label :: ${x.detail}');
      }
    }
    print('CHAOS-C|RESUMO| alvo: ${targetedC().length} sequências, $n turnos, $bad violações: $byKind');
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('CHAOS-C relógio injetado no EntrySafetyGate', () {
    var n = 0, fp = 0, fn = 0;
    for (final ck in clocks.entries) {
      final now = ck.value;
      final t = _day(now);
      final prevFirst = DateTime(t.year, t.month - 1, 1);
      final cases = <List<Object?>>[
        ['ontem', back(1, t)],
        ['anteontem', back(2, t)],
        ['há três dias', back(3, t)],
        ['no domingo', wdLast(7, t), t.weekday == 7 ? t : null],
        ['na segunda', wdLast(1, t), t.weekday == 1 ? t : null],
        ['sábado passado', wdLast(6, t)],
        ['na sexta retrasada', DateTime(wdLast(5, t).year, wdLast(5, t).month, wdLast(5, t).day - 7)],
        ['dia 1º', diaN(1, t)],
        ['dia 29', diaN(29, t)],
        ['dia 30', diaN(30, t)],
        ['dia 31', diaN(31, t)],
        ['em ${dm(back(1, t))}', back(1, t)],
        ['em ${dm(DateTime(t.year, t.month, t.day + 1))}', null],
        ['em 29/02', b.ddmmOracle(29, 2, t).date],
        ['em 31/12', b.ddmmOracle(31, 12, t).date],
        ['${back(10, t).day} de ${monthNames[back(10, t).month - 1]}', back(10, t)],
        ['dia 15 do mês passado', DateTime(prevFirst.year, prevFirst.month, 15)],
        ['hoje', t],
        ['hoje cedo', t],
      ];
      for (final c in cases) {
        n++;
        final marker = c[0] as String;
        final exp = c[1] as DateTime?;
        final alt = c.length > 2 ? c[2] as DateTime? : null;
        final phrase = 'gastei 47 na quitanda $marker no pix';
        final d0 = engine.parse(phrase);
        final base = d0.copyWith(
            intent: 'expense', amount: 47, isComplete: true, missingSlots: const [], settledChecks: d0.settledChecks.difference({'date'}));
        if (exp != null) {
          final good = base.copyWith(dateOffsetDays: dayDiff(exp, t));
          final vg = EntrySafetyGate.review(good, turns: [phrase], now: now);
          if (!vg.ok) {
            final okAlt = alt != null && EntrySafetyGate.review(base.copyWith(dateOffsetDays: dayDiff(alt, t)), turns: [phrase], now: now).ok;
            if (!okAlt) {
              fp++;
              print('CHAOS-C|GATECLOCK-V| falso_positivo hoje=${ck.key} ${ddmmyy(now)} "$phrase" com a data certa ${ddmmyy(exp)} → ${vg.check?.name}: ${vg.question}');
            }
          }
          final wrongOffset = dayDiff(exp, t) == 0 ? -1 : 0;
          final vw = EntrySafetyGate.review(base.copyWith(dateOffsetDays: wrongOffset), turns: [phrase], now: now);
          final wrongIsAlt = alt != null && dayDiff(alt, t) == wrongOffset;
          if (vw.ok && !wrongIsAlt) {
            fn++;
            print('CHAOS-C|GATECLOCK-V| deixou_passar hoje=${ck.key} ${ddmmyy(now)} "$phrase" gravaria ${ddmmyy(DateTime(t.year, t.month, t.day + wrongOffset))} (certo: ${ddmmyy(exp)})');
          }
        } else {
          final v0 = EntrySafetyGate.review(base.copyWith(dateOffsetDays: 0), turns: [phrase], now: now);
          if (v0.ok) {
            fn++;
            print('CHAOS-C|GATECLOCK-V| futura_ou_inexistente_passou hoje=${ck.key} ${ddmmyy(now)} "$phrase" gravaria hoje');
          }
        }
      }
      for (final title in [
        'no Empório Dia 1', 'na Feira da Segunda', 'no Bar 7 Dias', 'na Pizzaria Sábado à Noite', 'numa loja da avenida 9 de julho',
        'na travessa 2 de dezembro', 'no Lava-Jato Amanhã', 'na Quitanda do Domingos', 'no Hotel Quinta das Flores',
      ]) {
        n++;
        final phrase = 'gastei 47 $title no pix';
        final d0 = engine.parse(phrase);
        final base = d0.copyWith(intent: 'expense', amount: 47, isComplete: true, missingSlots: const [], settledChecks: d0.settledChecks.difference({'date'}), dateOffsetDays: 0);
        final v = EntrySafetyGate.review(base, turns: [phrase], now: now);
        if (!v.ok) {
          fp++;
          print('CHAOS-C|GATECLOCK-V| falso_positivo_titulo hoje=${ck.key} ${ddmmyy(now)} "$phrase" → ${v.check?.name}: ${v.question}');
        }
      }
    }
    print('CHAOS-C|RESUMO| gate×relógio: ${clocks.length} relógios, $n frases, falsos positivos $fp, deixou passar $fn');
  });

  test('CHAOS-C relógio injetado no PendingReplyCheck', () {
    const subject = PendingSubject('paguei a quitanda no pix Quitanda', direction: 'expense', category: 'supermarket');
    final cases = <String, TopicShift>{
      'apaga a feira de domingo': TopicShift.command,
      'muda o sacolão de ontem pra 30': TopicShift.command,
      'exclui o 7 belo de anteontem': TopicShift.command,
      'desfaz': TopicShift.command,
      '47': TopicShift.none,
      'foi 47 no domingo': TopicShift.none,
      '47 dia 29': TopicShift.none,
      'deu 47 ontem': TopicShift.none,
      'no débito': TopicShift.none,
      '47 reais na segunda': TopicShift.none,
      'foi dia 31': TopicShift.none,
      'foi 47, na quitanda do domingos': TopicShift.none,
      'gastei 30 no chaveiro no pix': TopicShift.newEntry,
      'recebi 200 da vizinha no pix': TopicShift.newEntry,
      'por pouco não gastei 30': TopicShift.nonEvent,
      'se eu gastar 30 amanhã': TopicShift.nonEvent,
      'quanto gastei no domingo?': TopicShift.question,
    };
    var n = 0, bad = 0;
    for (final ck in clocks.entries) {
      for (final c in cases.entries) {
        n++;
        final fresh = engine.parse(c.key);
        final tx = const {'expense', 'income', 'transfer'}.contains(fresh.intent);
        final got = PendingReplyCheck.classify(c.key, subject,
            textDirection: tx ? fresh.intent : null, textCategory: tx ? fresh.category : null, commands: true, now: ck.value);
        if (got != c.value) {
          bad++;
          print('CHAOS-C|CHECKCLOCK-V| hoje=${ck.key} "${c.key}" → ${got.name} (esperado ${c.value.name})');
        }
      }
    }
    print('CHAOS-C|RESUMO| PendingReplyCheck×relógio: ${clocks.length} relógios, $n leituras, $bad divergências');
  });

  test('CHAOS-C relógio injetado no CesarAssistant (pendências de edição)', () async {
    var n = 0, bad = 0;
    for (final ck in clocks.entries) {
      final now = ck.value;
      final t = _day(now);
      DateTime at(DateTime d) => DateTime(d.year, d.month, d.day, 0, 30);
      FinancialTransaction f(String id, String title, double amount, String cat, DateTime d) =>
          FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: at(d));
      final fx = [
        f('k-feira-dom', 'Feira', 61, 'supermarket', wdLast(7, now)),
        f('k-feira-seg', 'Feira', 62, 'supermarket', wdLast(1, now)),
        f('k-feira-da-seg', 'Feira da Segunda', 63, 'supermarket', wdLast(5, now)),
        f('k-emporio', 'Empório Dia 1', 64, 'supermarket', diaN(1, now) ?? back(3, t)),
        f('k-7belo', '7 Belo', 65, 'leisure', back(1, t)),
        f('k-padaria', 'Padaria Ontem e Hoje', 66, 'supermarket', back(2, t)),
        f('k-pizzaria', 'Pizzaria Sábado à Noite', 67, 'leisure', wdLast(7, now)),
        f('k-quitanda', 'Quitanda do Domingos', 68, 'supermarket', wdLast(2, now)),
      ];
      bool sameDay(FinancialTransaction x, DateTime d) => _day(x.date) == _day(d);
      final cases = <List<Object>>[
        [['apaga a feira da segunda', 'sim'], (FinancialTransaction x) => x.title.startsWith('Feira')],
        [['muda a feira de domingo pra 91'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(7, now))],
        [['muda a feira de quarta pra 92', 'sim', '1'], (FinancialTransaction x) => x.title.startsWith('Feira')],
        [['na verdade a feira de domingo foi 93'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(7, now))],
        [['muda o empório dia 1 pra 94'], (FinancialTransaction x) => x.title.startsWith('Empório')],
        [['passa o 7 belo pra 95'], (FinancialTransaction x) => x.title == '7 Belo'],
        [['apaga a padaria ontem e hoje', 'sim'], (FinancialTransaction x) => x.title.startsWith('Padaria')],
        [['muda o 7 belo de ontem pra 96'], (FinancialTransaction x) => x.title == '7 Belo'],
        [['muda a feira de domingo pra 97', 'gastei 30 no chaveiro no pix', '!sim'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(7, now))],
        [['apaga a feira de quarta', 'sim', '!sim'], (FinancialTransaction x) => false],
        [['muda o domingos pra 98'], (FinancialTransaction x) => x.title.startsWith('Quitanda')],
        [['muda o almoço de domingo pra 99', 'sim'], (FinancialTransaction x) => x.title.startsWith('Pizzaria')],
        [['muda a pizzaria sábado à noite pra 100'], (FinancialTransaction x) => x.title.startsWith('Pizzaria')],
        [['apaga a feira de sábado', 'sim'], (FinancialTransaction x) => false],
        [['muda a feira do dia 1 pra 101', 'sim'], (FinancialTransaction x) => x.title.startsWith('Feira') && x.date.day == 1],
        [['passa', '!gastei 30 no chaveiro no pix'], (FinancialTransaction x) => false],
      ];
      for (final c in cases) {
        final turns = c[0] as List<String>;
        final allowed = c[1] as bool Function(FinancialTransaction);
        SharedPreferences.setMockInitialValues({});
        final repo = FinancialRepository();
        await repo.initialize();
        for (final x in [...repo.transactions]) {
          repo.deleteTransaction(x.id);
        }
        for (final x in fx) {
          repo.addTransaction(x);
        }
        final sim = SimC(engine, repo, now: () => now);
        var prevText = '';
        var prevRoute = '';
        for (final raw in turns) {
          n++;
          final noEdit = raw.startsWith('!');
          final turn = noEdit ? raw.substring(1) : raw;
          final before = {for (final x in repo.transactions) x.id: x};
          final bs = Snap3.of(repo);
          final r = sim.send(turn);
          final aSnap = Snap3.of(repo);
          final removed = bs.tx.keys.where((k) => !aSnap.tx.containsKey(k)).toList();
          final changed = bs.tx.keys.where((k) => aSnap.tx.containsKey(k) && aSnap.tx[k] != bs.tx[k]).toList();
          final label = turns.map((e) => '"${e.replaceFirst('!', '')}"').join(' ⏎ ');
          for (final k in [...removed, ...changed]) {
            final x = before[k]!;
            if (removed.contains(k) && !(prevRoute == 'confirm_delete' && yesRe.hasMatch(CesarText.simplify(turn)))) {
              bad++;
              print('CHAOS-C|REFCLOCK-V| apagou_sem_sim hoje=${ck.key}: $label → [${r.route}] ${x.title}');
            }
            if (noEdit) {
              bad++;
              print('CHAOS-C|REFCLOCK-V| mudou_depois_de_frase_nova hoje=${ck.key}: $label → [${r.route}] ${x.title} ${CesarText.money(x.amount)} :: ${r.text.replaceAll('\n', ' ')}');
              continue;
            }
            if (allowed(x)) continue;
            bad++;
            print('CHAOS-C|REFCLOCK-V| ${prevText.contains(x.title) ? 'confirmou_outro' : 'atingiu_outro'} hoje=${ck.key} ${ddmmyy(now)}: $label → [${r.route}] '
                '${removed.contains(k) ? 'apagou' : 'mudou'} ${x.title} ${CesarText.money(x.amount)} de ${ddmmyy(x.date)} :: ${r.text.replaceAll('\n', ' ')}');
          }
          for (final k in changed) {
            final d = _day(DateTime.parse((jsonDecode(aSnap.tx[k]!) as Map)['date'] as String));
            if (d.isAfter(t)) {
              bad++;
              print('CHAOS-C|REFCLOCK-V| data_futura hoje=${ck.key}: $label → ${describeTx(aSnap.tx[k]!)}');
            }
          }
          prevText = r.text;
          prevRoute = r.route;
          print('CHAOS-C|REFCLOCK| hoje=${ck.key} ${ddmmyy(now)} "$turn" → ${r.short}');
        }
      }
    }
    print('CHAOS-C|RESUMO| assistente×relógio: ${clocks.length} relógios, $n turnos, $bad violações');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('CHAOS-C fuzz (seeds novas 20261300+n)', () async {
    final sw = Stopwatch()..start();
    final seeds = int.tryParse(Platform.environment['C_SEEDS'] ?? '') ?? 32;
    final length = int.tryParse(Platform.environment['C_LEN'] ?? '') ?? 250;
    var turns = 0;
    final firstBy = <String, List<LC>>{};
    final firstSeed = <String, int>{};
    final countBy = <String, int>{};
    final distinct = <String, Set<String>>{};
    routeCount.clear();
    statCount.clear();
    for (var n = 1; n <= seeds; n++) {
      final seed = 20261300 + n;
      final res = await runC(engine, gen: GenC(Random(seed), length));
      turns += res.sent.length;
      for (final x in res.v) {
        if (Platform.environment['C_ALLV'] == '1') print('CHAOS-C|FUZZ-V| ${sev(x.kind)} ${x.kind} seed=$seed turno ${x.turn + 1}: ${x.detail}');
        countBy[x.kind] = (countBy[x.kind] ?? 0) + 1;
        (distinct[x.kind] ??= {}).add(res.sent[x.turn].text.replaceAll(RegExp(r'\d+'), '#'));
        if (!firstBy.containsKey(x.kind)) {
          firstBy[x.kind] = res.sent;
          firstSeed[x.kind] = seed;
          print('CHAOS-C|FUZZ| primeira ${sev(x.kind)} ${x.kind} seed=$seed turno ${x.turn + 1}: ${x.detail}');
        }
      }
      print('CHAOS-C|FUZZ| seed=$seed turnos=${res.sent.length} violações=${res.v.length} (${sw.elapsedMilliseconds} ms)');
    }
    print('CHAOS-C|RESUMO| fuzz: $seeds seeds × $length = $turns turnos; ${sw.elapsedMilliseconds} ms');
    final kinds = countBy.keys.toList()..sort((a, c) => sev(a).compareTo(sev(c)));
    print('CHAOS-C|RESUMO| violações por tipo: ${kinds.map((k) => '${sev(k)} $k=${countBy[k]}').join(', ')}');
    for (final e in distinct.entries) {
      print('CHAOS-C|FUZZ-FORMAS| ${e.key} (${e.value.length} formas): ${e.value.take(30).join(' | ')}');
    }
    final routes = routeCount.entries.toList()..sort((a, c) => c.value.compareTo(a.value));
    print('CHAOS-C|RESUMO| rotas: ${routes.map((e) => '${e.key}=${e.value}').join(' ')}');
    final st = statCount.keys.toList()..sort();
    print('CHAOS-C|RESUMO| estatísticas: ${st.map((k) => '$k=${statCount[k]}').join(', ')}');
    for (final kind in firstBy.keys) {
      final m = await minimizeC(engine, firstBy[kind]!, kind, sw, sw.elapsedMilliseconds + 25000);
      final trace = <String>[];
      final res = await runC(engine, fixed: m, trace: trace);
      final x = res.v.firstWhere((e) => e.kind == kind, orElse: () => b.VA(kind, '(não reproduziu)', -1));
      print('CHAOS-C|MIN| ${sev(kind)} $kind (seed ${firstSeed[kind]}, ${m.length} turnos): ${m.map((e) => '"${e.text}"').join(' ⏎ ')}  ⇒  ${x.detail}  ‖ ${trace.join(' ⏎ ')}');
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
