// Bateria de QA de conversação do César (agente cesar-tester).
//
// NÃO é um teste de regressão: não usa `expect`, nunca falha a suíte. Roda
// centenas de frases no motor real e imprime só as divergências entre o
// esperado e o obtido, mais um placar por eixo. Os achados vão para
// docs/qa/findings-conversa.md.
//
// Rodar:  flutter test test/_qa/conversation_probe_test.dart 2>&1 | grep -E "FAIL|AXIS|TOTAL"
//
// `ChatSim` espelha a ordem de checagens de `_sendMessage` em
// lib/features/chat/presentation/screens/chat_screen.dart (cancelar pendente →
// multi pendente → CesarAssistant.handleCommand (editar/excluir/desfazer/
// corrigir/categorias/metas) → vencimento do recorrente → dívida → metas →
// posso comprar/gastar → CesarAssistant.handleQuestion (perguntas, conversa)
// → multi-lançamento → parse/merge), usando o próprio CesarAssistant que o
// chat usa, sem widget, para medir o que o usuário realmente vê no chat —
// inclusive o que é salvo no repositório.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────── simulador do chat ───────────────────────────

class Reply {
  final String route;
  final String text;
  final FinancialTransactionDraft? draft;
  Reply(this.route, this.text, [this.draft]);

  @override
  String toString() {
    final d = draft;
    final t = text.replaceAll('\n', ' ');
    final shortText = t.length > 140 ? '${t.substring(0, 140)}…' : t;
    if (d == null || route == 'multi') return '[$route] "$shortText"';
    return '[$route] ${d.intent} ${d.amount} ${d.category} ${d.paymentMethod} inst=${d.installments} d=${d.dateOffsetDays} rec=${d.isRecurrent} missing=${d.missingSlots} prompt="${d.clarificationPrompt ?? ''}"';
  }
}

class ChatSim {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  FinancialTransactionDraft? last;
  List<String> lastIds = const [];
  List<FinancialTransactionDraft>? pendingBatch;
  final List<Reply> log = [];

  ChatSim(this.engine, this.repo) : assistant = CesarAssistant(repository: repo, engine: engine);

  Reply send(String input) {
    final r = _send(input.trim());
    log.add(r);
    return r;
  }

  void _saved(List<String> ids) {
    lastIds = ids;
    assistant.recordCreated(ids);
  }

  Reply _send(String input) {
    var text = input;
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();

    // 0. cancelar rascunho pendente
    if (active != null && !active!.isComplete && engine.isCancelCommand(text)) {
      active = null;
      return Reply('cancel_pending', 'Tudo bem, descartei esse lançamento.');
    }

    // 0b. resposta à pergunta compartilhada de um multi-lançamento pendente
    if (pendingBatch != null) {
      final batch = pendingBatch!;
      if (engine.isCancelCommand(text)) {
        pendingBatch = null;
        return Reply('cancel_pending', 'Tudo bem, descartei esses lançamentos.');
      }
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (!engine.startsNewTransaction(firstOpen, text)) {
        final merged = engine.mergeMultiDrafts(batch, text);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          pendingBatch = null;
          return _saveBatch(merged);
        }
        pendingBatch = merged;
        return Reply('ask_multi', prompt);
      }
      pendingBatch = null;
    }

    // 1. CesarAssistant: editar/excluir/desfazer/corrigir, categorias, metas,
    //    "mais 20 de gorjeta" (ou reescreve "e 30 na padaria" como lançamento)
    final cmd = assistant.handleCommand(text, hasPendingDraft: active != null && !active!.isComplete);
    if (cmd != null && cmd.rewrittenInput != null) {
      text = cmd.rewrittenInput!;
    } else if (cmd != null) {
      active = null;
      if (lastIds.any(cmd.removedIds.contains)) {
        lastIds = const [];
        last = null;
      }
      return Reply(cmd.route, cmd.text);
    }

    // 1b. regra de vencimento do último recorrente
    final lower = text.toLowerCase();
    if (last != null &&
        (active == null || active!.isComplete) &&
        last!.isRecurrent &&
        RegExp(r'dia\s+[uú]til|\b(?:todo|vence(?:\s+no)?|cai(?:\s+no)?)\s+dia\s+\d').hasMatch(lower) &&
        !RegExp(r'\d+(?:[.,]\d+)?\s*(?:reais|real)|r\$').hasMatch(lower)) {
      final updated = engine.applyCorrection(last!, text);
      last = updated;
      for (final id in lastIds) {
        repo.applyDraftCorrection(id, updated);
      }
      return Reply('correction', updated.clarificationPrompt ?? 'Lançamento atualizado com sucesso!', updated);
    }

    // 2. pagamento de dívida (sem dívida no nome: segue como receita comum)
    String? preface;
    final debt = DebtPaymentParser.parse(text);
    if (debt != null) {
      final matches = repo.findDebtorsByName(debt.personName);
      if (matches.isEmpty) {
        preface = DebtPaymentParser.noOpenDebtNote(debt.personName);
      } else if (matches.length == 1) {
        final res = repo.applyDebtPayment(matches.first.id, debt.amountPaid);
        return Reply('debt', '${debt.personName} pagou ${res.amountPaid}; resta ${res.remainingBalance}');
      } else {
        return Reply('debt', 'ambíguo: ${debt.personName} (${matches.length})');
      }
    }

    // 3. metas
    final goalCreation = GoalParser.parseCreation(text);
    if (goalCreation != null) {
      repo.addGoal(FinancialGoal(
        id: 'goal-${repo.goals.length + 1}',
        title: goalCreation.title,
        targetAmount: goalCreation.targetAmount,
        targetDate: goalCreation.targetDate,
      ));
      return Reply('goal_create', 'Meta criada: "${goalCreation.title}" ${goalCreation.targetAmount}');
    }
    final goalContribution = GoalParser.parseContribution(text);
    if (goalContribution != null) {
      final matches = repo.findGoalsByTitle(goalContribution.goalTitle);
      if (matches.length == 1) {
        final g = repo.contributeToGoal(matches.first.id, goalContribution.amount);
        return Reply('goal_contrib', '"${g.title}" ${g.savedAmount}/${g.targetAmount}');
      }
      return Reply('goal_contrib', 'meta não encontrada: "${goalContribution.goalTitle}" (${matches.length})');
    }

    // 4. posso comprar / posso gastar
    final afford = AffordabilityAnalyzer(repository: repo).analyze(text);
    if (afford != null) {
      return Reply('afford:${afford.verdict.name}', '${afford.spokenText} ${afford.formattedText}');
    }

    // 5. perguntas sobre os dados, conversa e ajuda (CesarAssistant)
    final answer = assistant.handleQuestion(text);
    if (answer != null) {
      active = null;
      return Reply(answer.route, '${answer.spokenText} || ${answer.text}');
    }

    // 6. multi-lançamento (pergunta compartilhada quando falta pagamento)
    if (active == null || active!.isComplete) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) return _saveBatch(multi);
        pendingBatch = multi;
        active = null;
        return Reply('ask_multi', prompt);
      }
    }

    // 7. parse / merge
    FinancialTransactionDraft draft;
    var merged = false;
    String? discardedNotice;
    if (active != null && !active!.isComplete && !engine.startsNewTransaction(active!, text)) {
      draft = engine.mergeDrafts(active!, text);
      merged = true;
    } else {
      // Como o chat: avisa quando a frase nova descarta um rascunho pendente.
      if (active != null && !active!.isComplete) {
        discardedNotice = LocalFinancialNlpEngine.discardedDraftNotice(active!);
      }
      draft = engine.parse(text);
    }
    if (draft.isComplete) draft = repo.applyCategoryMemory(draft);

    var route = draft.isComplete ? 'saved' : 'ask';
    var responseText = draft.clarificationPrompt ?? 'registrado';
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      _saved(repo.addTransactionFromDraft(draft).map((t) => t.id).toList());
      if (draft.isReminder) {
        repo.addReminder(FinancialReminder(
          id: 'rem-${repo.reminders.length + 1}',
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
    if (discardedNotice != null) responseText = '$discardedNotice\n\n$responseText';
    if (preface != null) responseText = '$preface $responseText';
    return Reply(route, responseText, draft);
  }

  Reply _saveBatch(List<FinancialTransactionDraft> drafts) {
    for (final d in drafts) {
      _saved(repo.addTransactionFromDraft(d).map((t) => t.id).toList());
    }
    last = drafts.last;
    return Reply('multi',
        drafts.map((d) => '${d.intent} ${d.amount} ${d.category} ${d.paymentMethod} "${d.description}"').join(' | '), drafts.last);
  }
}

// ─────────────────────────── casos ───────────────────────────

class TxCase {
  final String axis;
  final String phrase;
  final Set<String>? intent;
  final double? amount;
  final Set<String>? cat;
  final String? pay;
  final int? inst;
  final int? day;
  final bool? recurrent;
  final bool complete;
  final String? route;
  TxCase(this.axis, this.phrase,
      {Object? i, this.amount, Object? cat, this.pay, this.inst, this.day, this.recurrent, this.complete = true, this.route})
      : intent = i == null ? null : (i is String ? {i} : (i as Set<String>)),
        cat = cat == null ? null : (cat is String ? {cat} : (cat as Set<String>));
}

class QaCase {
  final String phrase;
  final bool Function(String route) routeOk;
  final String routeDesc;
  final List<String> contains;
  QaCase(this.phrase, this.routeDesc, this.routeOk, [this.contains = const []]);
}

class Scn {
  final String axis;
  final String name;
  final List<String> turns;
  final String expected;
  final String? Function(ChatSim sim, List<Reply> r) check; // null = passou
  final void Function(ChatSim sim)? setup;
  Scn(this.axis, this.name, this.turns, this.expected, this.check, {this.setup});
}

bool isReport(String r) => r.startsWith('report:') && r != 'report:unknown';
bool notSaved(String r) => !r.contains('saved') && !r.contains('SAVED') && r != 'multi';

final txCases = <TxCase>[
  // ── formal ──
  TxCase('formal', 'Efetuei um pagamento de R\$ 1.250,90 referente ao aluguel via boleto.', i: 'expense', amount: 1250.90, cat: 'housing', pay: 'bank_slip'),
  TxCase('formal', 'Realizei uma compra no valor de R\$ 89,90 na farmácia utilizando cartão de débito.', i: 'expense', amount: 89.90, cat: 'health', pay: 'debit_card'),
  TxCase('formal', 'Recebi o pagamento do meu salário no valor de R\$ 5.200,00.', i: 'income', amount: 5200, cat: 'salary'),
  TxCase('formal', 'Gostaria de registrar uma despesa de R\$ 230,00 com supermercado, paga em dinheiro.', i: 'expense', amount: 230, cat: 'supermarket', pay: 'cash'),
  TxCase('formal', 'Por gentileza, lance uma transferência de R\$ 500,00 para minha conta poupança.', i: 'transfer', amount: 500),
  TxCase('formal', 'Registre, por favor, o pagamento da mensalidade da faculdade: R\$ 780,00 no boleto.', i: 'expense', amount: 780, cat: 'education', pay: 'bank_slip'),
  TxCase('formal', 'Adquiri um par de tênis por R\$ 399,99 no cartão de crédito em 3 parcelas.', i: 'expense', amount: 399.99, pay: 'credit_card', inst: 3),
  TxCase('formal', 'Informo que recebi R\$ 1.500,00 referentes a um trabalho freelance.', i: 'income', amount: 1500),
  TxCase('formal', 'Foi debitado o valor de R\$ 67,45 referente à conta de luz.', i: 'expense', amount: 67.45, cat: 'housing'),
  TxCase('formal', 'Houve um gasto de R\$ 42,00 com combustível no dia de ontem, pago via Pix.', i: 'expense', amount: 42, cat: 'transport', pay: 'pix', day: -1),
  TxCase('formal', 'Quitei a fatura da internet no valor de R\$ 119,90 por meio de débito automático.', i: 'expense', amount: 119.90, cat: 'housing'),
  TxCase('formal', 'Solicito o registro de uma consulta médica no valor de R\$ 300,00, paga com cartão de crédito.', i: 'expense', amount: 300, cat: 'health', pay: 'credit_card'),
  TxCase('formal', 'Apliquei R\$ 2.000,00 no Tesouro Direto.', i: {'expense', 'transfer'}, amount: 2000, cat: 'investment'),
  TxCase('formal', 'Recebi R\$ 350,00 de rendimentos de aluguel de imóvel.', i: 'income', amount: 350),
  TxCase('formal', 'Registrar despesa: almoço executivo, R\$ 38,50, cartão de débito.', i: 'expense', amount: 38.50, cat: 'leisure', pay: 'debit_card'),
  TxCase('formal', 'Paguei R\$ 2.450,00 de condomínio através de transferência bancária.', i: 'expense', amount: 2450, cat: 'housing'),

  // ── coloquial / gíria ──
  TxCase('coloquial', 'torrei 50 conto no bar', i: 'expense', amount: 50, cat: 'leisure'),
  TxCase('coloquial', 'caiu o salário, 3200', i: 'income', amount: 3200, cat: 'salary'),
  TxCase('coloquial', 'passei 30 no débito na padaria', i: 'expense', amount: 30, pay: 'debit_card'),
  TxCase('coloquial', 'gastei uns 80 pila no ifood', i: 'expense', amount: 80, cat: 'leisure'),
  TxCase('coloquial', 'mandei um pix de 100 pro meu irmão', i: {'transfer', 'expense'}, amount: 100, pay: 'pix'),
  TxCase('coloquial', 'rachei a conta do bar, deu 45 pra mim', i: 'expense', amount: 45, cat: 'leisure'),
  TxCase('coloquial', 'pintou um freela de 600', i: 'income', amount: 600),
  TxCase('coloquial', 'larguei 200 na balada ontem', i: 'expense', amount: 200, cat: 'leisure', day: -1),
  TxCase('coloquial', 'abasteci o possante, 150 no crédito', i: 'expense', amount: 150, cat: 'transport', pay: 'credit_card'),
  TxCase('coloquial', 'comprei um lanche de 25 conto', i: 'expense', amount: 25, cat: 'leisure'),
  TxCase('coloquial', 'o chefe me pagou 1500 do bico', i: 'income', amount: 1500),
  TxCase('coloquial', 'caí na besteira e gastei 300 na shopee', i: 'expense', amount: 300),
  TxCase('coloquial', 'dei 20 pro flanelinha', i: 'expense', amount: 20),
  TxCase('coloquial', 'recebi 50 conto da minha vó', i: 'income', amount: 50),
  TxCase('coloquial', 'meti 120 no mercado no pix', i: 'expense', amount: 120, cat: 'supermarket', pay: 'pix'),
  TxCase('coloquial', 'uber de 18 conto', i: 'expense', amount: 18, cat: 'transport'),
  TxCase('coloquial', 'gastei 2k no notebook', i: 'expense', amount: 2000),
  TxCase('coloquial', 'gastei 1,5k na viagem', i: 'expense', amount: 1500),

  // ── voz transcrita ──
  TxCase('voz', 'gastei cinquenta e dois reais e noventa centavos no mercado no pix', i: 'expense', amount: 52.90, cat: 'supermarket', pay: 'pix'),
  TxCase('voz', 'paguei mil e duzentos de aluguel', i: 'expense', amount: 1200, cat: 'housing'),
  TxCase('voz', 'recebi dois mil e quinhentos de salario', i: 'income', amount: 2500, cat: 'salary'),
  TxCase('voz', 'gastei trinta reais no uber', i: 'expense', amount: 30, cat: 'transport'),
  TxCase('voz', 'comprei um remedio de quarenta e cinco reais na farmacia', i: 'expense', amount: 45, cat: 'health'),
  TxCase('voz', 'paguei cento e vinte reais de luz no boleto', i: 'expense', amount: 120, cat: 'housing', pay: 'bank_slip'),
  TxCase('voz', 'gastei vinte e cinco vírgula cinquenta na padaria', i: 'expense', amount: 25.50),
  TxCase('voz', 'gastei quinze reais hoje no almoço no débito', i: 'expense', amount: 15, pay: 'debit_card'),
  TxCase('voz', 'recebi trezentos reais de um freela', i: 'income', amount: 300),
  TxCase('voz', 'transferi quinhentos reais pra minha mãe', i: 'transfer', amount: 500),
  TxCase('voz', 'gastei oitenta e sete e cinquenta no posto', i: 'expense', amount: 87.50, cat: 'transport'),
  TxCase('voz', 'paguei dois mil reais no conserto do carro', i: 'expense', amount: 2000, cat: 'transport'),
  TxCase('voz', 'gastei cem reais no cinema ontem', i: 'expense', amount: 100, cat: 'leisure', day: -1),
  TxCase('voz', 'comprei um tenis de trezentos e noventa e nove no credito em tres vezes', i: 'expense', amount: 399, pay: 'credit_card', inst: 3),
  TxCase('voz', 'paguei setecentos e cinquenta de condominio', i: 'expense', amount: 750, cat: 'housing'),
  TxCase('voz', 'gastei doze reais e cinquenta centavos de onibus', i: 'expense', amount: 12.50, cat: 'transport'),
  TxCase('voz', 'gastei um real e cinquenta no chiclete', i: 'expense', amount: 1.50),
  TxCase('voz', 'gastei cinquenta reais no mercado ponto', i: 'expense', amount: 50, cat: 'supermarket'),

  // ── digitação ruim ──
  TxCase('typo', 'gasteu 40 no mercadp no pics', i: 'expense', amount: 40, cat: 'supermarket', pay: 'pix'),
  TxCase('typo', 'recebie 300', i: 'income', amount: 300, complete: false),
  TxCase('typo', 'GASTEI 50 NO MERCADO NO PIX', i: 'expense', amount: 50, cat: 'supermarket', pay: 'pix'),
  TxCase('typo', 'gastie 25 na farmasia', i: 'expense', amount: 25, cat: 'health'),
  TxCase('typo', 'pagei 100 de luz', i: 'expense', amount: 100, cat: 'housing'),
  TxCase('typo', 'comprei 30 de gazolina', i: 'expense', amount: 30, cat: 'transport'),
  TxCase('typo', 'gastei 60 no restaurate no credto', i: 'expense', amount: 60, cat: 'leisure', pay: 'credit_card'),
  TxCase('typo', 'recebi meu salaio de 4000', i: 'income', amount: 4000, cat: 'salary'),
  TxCase('typo', 'gastei 15 no ubr', i: 'expense', amount: 15, cat: 'transport'),
  TxCase('typo', 'transferi 200 pra maria no pixx', i: 'transfer', amount: 200, pay: 'pix'),
  TxCase('typo', 'gastei 45,90 no mercao', i: 'expense', amount: 45.90, cat: 'supermarket'),
  TxCase('typo', 'paguei 89 na acadmia', i: 'expense', amount: 89, cat: 'health'),
  TxCase('typo', 'gstei 22 na padaria', i: 'expense', amount: 22),
  TxCase('typo', 'Gastei R\$50 no Mercado', i: 'expense', amount: 50, cat: 'supermarket'),
  TxCase('typo', 'gastei 50reais no mercado', i: 'expense', amount: 50, cat: 'supermarket'),
  TxCase('typo', 'gastei r\$ 1.200 no celular', i: 'expense', amount: 1200),
  TxCase('typo', 'gastei 1200.50 no celular', i: 'expense', amount: 1200.50),

  // ── frase longa com ruído ──
  TxCase('ruido', 'hoje foi corrido, saí cedo e acabei almoçando fora, deu 45 no crédito', i: 'expense', amount: 45, cat: 'leisure', pay: 'credit_card'),
  TxCase('ruido', 'cara nem te conto, fui no mercado com a minha mãe e no fim gastei 230 no débito', i: 'expense', amount: 230, cat: 'supermarket', pay: 'debit_card'),
  TxCase('ruido', 'depois de 3 horas no trânsito ainda tive que pagar 25 de estacionamento', i: 'expense', amount: 25, cat: 'transport'),
  TxCase('ruido', 'meu filho de 8 anos pediu um brinquedo e acabei gastando 120 na loja', i: 'expense', amount: 120),
  TxCase('ruido', 'lá pelas 10 da manhã passei na farmácia e gastei 35 no pix', i: 'expense', amount: 35, cat: 'health', pay: 'pix'),
  TxCase('ruido', 'ontem, dia chuvoso, peguei um uber de 32 reais pra voltar do trabalho', i: 'expense', amount: 32, cat: 'transport', day: -1),
  TxCase('ruido', 'trabalhei 12 horas e recebi 400 de diária no pix', i: 'income', amount: 400, pay: 'pix'),
  TxCase('ruido', 'a conta de luz que era pra ser uns 100 veio 187 esse mês, paguei no boleto', i: 'expense', amount: 187, cat: 'housing', pay: 'bank_slip'),
  TxCase('ruido', 'fui no aniversário do joão, levei um presente de 80 reais', i: 'expense', amount: 80),
  TxCase('ruido', 'moro no apartamento 302 e paguei 450 de condomínio', i: 'expense', amount: 450, cat: 'housing'),
  TxCase('ruido', 'comprei 2 cafés e um pão de queijo, deu 18 no total', i: 'expense', amount: 18),
  TxCase('ruido', 'sabe aquele tênis que eu queria? finalmente comprei, 350 no crédito em 2x', i: 'expense', amount: 350, pay: 'credit_card', inst: 2),
  TxCase('ruido', 'na volta da academia, às 19h, abasteci 100 no posto', i: 'expense', amount: 100, cat: 'transport'),
  TxCase('ruido', 'o mercado tava lotado, fiquei 40 minutos na fila e gastei 210', i: 'expense', amount: 210, cat: 'supermarket'),
  TxCase('ruido', 'minha chefe liberou o bônus de fim de ano, caiu 2000 na conta', i: 'income', amount: 2000),
  TxCase('ruido', 'gastei 50 no mercado, mas era pra ter gastado só 30', i: 'expense', amount: 50, cat: 'supermarket'),

  // ── todos os tipos ──
  TxCase('tipos', 'comprei uma geladeira de 3000 em 10x no crédito', i: 'expense', amount: 3000, pay: 'credit_card', inst: 10),
  TxCase('tipos', 'assinei a netflix por 55,90 por mês', i: 'expense', amount: 55.90, recurrent: true),
  TxCase('tipos', 'conta de água de 90 vence dia 15', i: 'expense', amount: 90, cat: 'housing'),
  TxCase('tipos', 'emprestei 100 pro joão', amount: 100),
  TxCase('tipos', 'contratei um pedreiro pagando 50 reais o dia durante 10 dias', i: 'expense', amount: 50),
  TxCase('tipos', 'comprei 3 camisetas a 40 cada', i: 'expense', amount: 120),
  TxCase('tipos', 'paguei 3 meses de academia de 100', i: 'expense', amount: 300, cat: 'health'),
  TxCase('tipos', 'meu salário de 4500 cai todo quinto dia útil', i: 'income', amount: 4500, cat: 'salary', recurrent: true),
  TxCase('tipos', 'transferi 1000 da conta corrente para a poupança', i: 'transfer', amount: 1000),
  TxCase('tipos', 'spotify 21,90 todo mês no crédito', i: 'expense', amount: 21.90, pay: 'credit_card', recurrent: true),
  TxCase('tipos', 'paguei a fatura do cartão de 1800', i: {'expense', 'transfer'}, amount: 1800),
  TxCase('tipos', 'recebi 85 de dividendos', i: 'income', amount: 85),
  TxCase('tipos', 'paguei 2 cafés de 7 reais cada', i: 'expense', amount: 14),
  TxCase('tipos', 'vendi minha bike por 800', i: 'income', amount: 800),
  TxCase('tipos', 'me reembolsaram 60 do almoço', i: 'income', amount: 60),
  TxCase('tipos', 'paguei 250 de ipva no pix', i: 'expense', amount: 250, cat: 'transport', pay: 'pix'),
  TxCase('tipos', 'comprei 5 unidades de 12 reais no mercado', i: 'expense', amount: 60, cat: 'supermarket'),
  // Regra de produto: sem forma de pagamento, dois gastos numa frase geram UMA
  // pergunta compartilhada ("ask_multi") — nunca salvam direto sem saber o pagamento.
  TxCase('tipos', 'gastei 50 no mercado e 30 na farmácia', route: 'ask_multi'),
  TxCase('tipos', 'gastei 50 no mercado e 30 na farmácia no pix', route: 'multi'),
  TxCase('tipos', 'paguei 100 de luz e 80 de água no boleto', route: 'multi'),
  // números por voz — variações para isolar a causa
  TxCase('voz', 'gastei cinquenta reais no mercado no pix', i: 'expense', amount: 50, cat: 'supermarket', pay: 'pix'),
  TxCase('voz', 'gastei duzentos reais no mercado no pix', i: 'expense', amount: 200, cat: 'supermarket', pay: 'pix'),
  TxCase('voz', 'gastei cento e cinquenta no mercado no pix', i: 'expense', amount: 150, cat: 'supermarket', pay: 'pix'),
  TxCase('voz', 'gastei quarenta e cinco no mercado no pix', i: 'expense', amount: 45, cat: 'supermarket', pay: 'pix'),
  TxCase('voz', 'gastei mil reais no mercado no pix', i: 'expense', amount: 1000, cat: 'supermarket', pay: 'pix'),
  TxCase('voz', 'gastei vinte conto no uber no pix', i: 'expense', amount: 20, cat: 'transport', pay: 'pix'),
  // datas e números que não são valor
  TxCase('ruido', 'gastei 50 no mercado anteontem no pix', i: 'expense', amount: 50, cat: 'supermarket', pay: 'pix', day: -2),
  TxCase('ruido', 'dia 10 gastei 50 no mercado no pix', i: 'expense', amount: 50, cat: 'supermarket', pay: 'pix'),
  TxCase('ruido', 'gastei 50 no mercado dia 10 no pix', i: 'expense', amount: 50, cat: 'supermarket', pay: 'pix'),
  TxCase('ruido', 'às 8 da noite gastei 60 no restaurante no pix', i: 'expense', amount: 60, cat: 'leisure', pay: 'pix'),
  TxCase('ruido', 'comprei 2 pizzas no ifood, deu 90 no pix', i: 'expense', amount: 90, cat: 'leisure', pay: 'pix'),
  TxCase('formal', 'Efetuei o pagamento do aluguel de 1250 no boleto', i: 'expense', amount: 1250, cat: 'housing', pay: 'bank_slip'),
  TxCase('formal', 'Efetuei uma compra de 80 reais no mercado no pix', i: 'expense', amount: 80, cat: 'supermarket', pay: 'pix'),
  TxCase('formal', 'paguei a mensalidade da faculdade de 780 no boleto', i: 'expense', amount: 780, cat: 'education', pay: 'bank_slip'),
  TxCase('typo', 'gastei 0 no mercado no pix', complete: false),
  TxCase('typo', 'gastei R\$ 10 mil no carro no pix', i: 'expense', amount: 10000, pay: 'pix'),
];

final qaCases = <QaCase>[
  QaCase('quanto gastei esse mês?', 'report:spending', (r) => r == 'report:spending', ['1.948,40']),
  QaCase('quanto gastei com uber?', 'report:spending', (r) => r == 'report:spending', ['48,00']),
  QaCase('quanto gastei com mercado esse mês?', 'report:spending', (r) => r == 'report:spending', ['380,50']),
  QaCase('quanto gastei com transporte esse mês?', 'report:spending', (r) => r == 'report:spending', ['48,00']),
  QaCase('quanto gastei em saúde?', 'report:spending', (r) => r == 'report:spending', ['119,90']),
  QaCase('quanto gastei com alimentação?', 'report:spending de Lazer & Alimentação (não o total geral)', (r) => r == 'report:spending', ['alimenta']),
  QaCase('quanto gastei no pix esse mês?', 'report:spending', (r) => r == 'report:spending', ['48,00']),
  QaCase('qual meu maior gasto?', 'report (maior gasto = Aluguel 1.400)', isReport, ['1.400']),
  QaCase('qual categoria eu mais gasto?', 'report (Moradia)', isReport, ['Moradia']),
  QaCase('quanto sobrou?', 'report:overview', (r) => r == 'report:overview'),
  QaCase('qual meu saldo?', 'report:overview', (r) => r == 'report:overview'),
  QaCase('quanto eu tenho na conta?', 'report:overview', (r) => r == 'report:overview'),
  QaCase('tô no vermelho?', 'report:overview', (r) => r == 'report:overview'),
  QaCase('quanto recebi esse mês?', 'report (receitas 4.500)', isReport, ['4.500']),
  QaCase('tenho conta vencendo?', 'report:bills', (r) => r == 'report:bills'),
  QaCase('quais contas vencem essa semana?', 'report:bills', (r) => r == 'report:bills'),
  QaCase('quem me deve?', 'report:debtors', (r) => r == 'report:debtors', ['João']),
  QaCase('alguém tá me devendo?', 'report:debtors', (r) => r == 'report:debtors', ['João']),
  QaCase('gastei mais que mês passado?', 'report:overview', (r) => r == 'report:overview'),
  QaCase('estou gastando mais que no mês passado?', 'report:overview', (r) => r == 'report:overview'),
  QaCase('quanto eu gastei ontem?', 'report:spending', (r) => r == 'report:spending'),
  QaCase('me mostra um gráfico dos meus gastos', 'report:spending', (r) => r == 'report:spending'),
  QaCase('quais foram meus últimos lançamentos?', 'report (lista)', isReport, ['Uber']),
  QaCase('quanto falta pra minha meta?', 'resposta sobre metas', (r) => notSaved(r) && r != 'unknown'),
  QaCase('quanto posso gastar por dia até o fim do mês?', 'report (orçamento diário)', isReport),
  QaCase('o que você sabe fazer?', 'ajuda (lista de capacidades)', (r) => r == 'help'),
  QaCase('o que você faz?', 'ajuda (lista de capacidades)', (r) => r == 'help'),
  QaCase('oi', 'saudação, sem salvar', (r) => notSaved(r)),
  QaCase('obrigado!', 'agradecimento, sem salvar', (r) => notSaved(r)),
  QaCase('bom dia césar, tudo bem?', 'saudação, sem salvar', (r) => notSaved(r)),
  QaCase('quanto paguei de aluguel?', 'report:spending', (r) => r == 'report:spending', ['1.400']),
  QaCase('quanto gastei na semana passada?', 'report:spending', (r) => r == 'report:spending'),
];

FinancialTransaction? txById(FinancialRepository repo, String id) {
  for (final t in repo.transactions) {
    if (t.id == id) return t;
  }
  return null;
}

// O repositório insere o mais novo na posição 0.
FinancialTransaction? newest(FinancialRepository repo, int baseline) =>
    repo.transactions.length > baseline ? repo.transactions.first : null;

bool hasTitle(FinancialRepository repo, String sub) =>
    repo.transactions.any((t) => t.title.toLowerCase().contains(sub));

String? afterSaved(ChatSim s, List<Reply> r, bool Function(FinancialTransaction? t, int count) ok, int baseline) {
  final saved = s.repo.transactions.where((t) => !t.id.startsWith('init-')).toList();
  // O repositório insere o mais novo na posição 0: `t` é o último salvo.
  final t = saved.isEmpty ? null : saved.first;
  return ok(t, saved.length) ? null : 'repo: ${saved.map((t) => '${t.title} ${t.amount} ${t.category} ${t.paymentMethod} ${t.type.name} ${t.date.day}/${t.date.month}').join(' ; ')}';
}

/// Regra de produto: excluir SEMPRE pede confirmação. O turno de exclusão
/// (índice [deleteTurn]) tem de responder com a pergunta de confirmação
/// (`confirm_delete`), e o turno "sim" seguinte remove o lançamento.
String? deletedAfterConfirm(ChatSim s, List<Reply> r, int deleteTurn, bool Function(FinancialTransaction? t, int count) ok) {
  if (r.length <= deleteTurn || r[deleteTurn].route != 'confirm_delete') {
    return 'não pediu confirmação: ${r.length > deleteTurn ? r[deleteTurn] : '(sem resposta)'}';
  }
  return afterSaved(s, r, ok, 5);
}

final scenarios = <Scn>[
  // ── edição / exclusão / desfazer por chat ──
  Scn('edicao', 'apaga o último', ['gastei 50 no mercado no pix', 'apaga o último', 'sim'], 'pede confirmação; com "sim", lançamento removido',
      (s, r) => deletedAfterConfirm(s, r, 1, (t, n) => n == 0)),
  Scn('edicao', 'desfaz', ['gastei 50 no mercado no pix', 'desfaz'], 'lançamento removido',
      (s, r) => afterSaved(s, r, (t, n) => n == 0, 5)),
  Scn('edicao', 'exclui esse lançamento', ['gastei 50 no mercado no pix', 'exclui esse lançamento', 'sim'], 'pede confirmação; com "sim", lançamento removido',
      (s, r) => deletedAfterConfirm(s, r, 1, (t, n) => n == 0)),
  Scn('edicao', 'deleta', ['gastei 50 no mercado no pix', 'deleta', 'sim'], 'pede confirmação; com "sim", lançamento removido',
      (s, r) => deletedAfterConfirm(s, r, 1, (t, n) => n == 0)),
  Scn('edicao', 'cancela (após salvo)', ['gastei 50 no mercado no pix', 'cancela', 'sim'], 'pede confirmação; com "sim", lançamento removido',
      (s, r) => deletedAfterConfirm(s, r, 1, (t, n) => n == 0)),
  Scn('edicao', 'muda o valor pra 80', ['gastei 50 no mercado no pix', 'muda o valor pra 80'], 'valor 80',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 80, 5)),
  Scn('edicao', 'na verdade foi 45', ['gastei 50 no mercado no pix', 'na verdade foi 45'], 'valor 45',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45, 5)),
  Scn('edicao', 'não, foi 45', ['gastei 50 no mercado no pix', 'não, foi 45'], 'valor 45 (1 lançamento)',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45, 5)),
  Scn('edicao', 'ops era 45', ['gastei 50 no mercado no pix', 'ops, era 45'], 'valor 45 (1 lançamento)',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45, 5)),
  Scn('edicao', 'corrige pra 45', ['gastei 50 no mercado no pix', 'corrige pra 45'], 'valor 45 (1 lançamento)',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45, 5)),
  Scn('edicao', 'o valor certo é 45', ['gastei 50 no mercado no pix', 'o valor certo é 45'], 'valor 45 (1 lançamento)',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45, 5)),
  Scn('edicao', 'troca pra débito', ['gastei 50 no mercado no pix', 'troca pra débito'], 'débito',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.paymentMethod == 'debit_card', 5)),
  Scn('edicao', 'foi no crédito em 3x', ['comprei um fone de 300 no pix', 'na verdade foi no crédito em 3x'], 'crédito 3x, valor 300',
      // Respostas de comando não carregam rascunho: confere o registro salvo.
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.paymentMethod == 'credit_card' && t.amount == 300 && t.installments == 3, 5)),
  Scn('edicao', 'esse era lazer', ['gastei 50 no mercado no pix', 'esse era lazer'], 'categoria leisure',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.category == 'leisure', 5)),
  Scn('edicao', 'muda a categoria pra transporte', ['gastei 50 no mercado no pix', 'muda a categoria pra transporte'], 'categoria transport',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.category == 'transport', 5)),
  Scn('edicao', 'coloca em lazer', ['gastei 50 no mercado no pix', 'coloca em lazer'], 'categoria leisure',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.category == 'leisure', 5)),
  Scn('edicao', 'na verdade foi ontem', ['gastei 50 no mercado no pix', 'na verdade foi ontem'], 'data = ontem',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.date.day == DateTime.now().subtract(const Duration(days: 1)).day, 5)),
  Scn('edicao', 'na verdade foi uma entrada', ['gastei 50 no mercado no pix', 'na verdade foi uma entrada'], 'tipo receita',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.type == TransactionType.income, 5)),
  Scn('edicao', 'exclui o uber (não é o último)', ['exclui o uber'], 'remove "Uber Viagens" (ou pergunta qual)',
      // Passa se removeu, ou se pediu confirmação sem abrir um lançamento novo.
      (s, r) => !hasTitle(s.repo, 'uber') || (r.last.route != 'ask' && notSaved(r.last.route) && r.last.text.toLowerCase().contains('uber')) ? null : 'uber continua: ${r.last}'),
  Scn('edicao', 'apaga o aluguel', ['apaga o aluguel'], 'remove/pergunta sobre aluguel',
      (s, r) => !hasTitle(s.repo, 'aluguel') || (r.last.route != 'ask' && notSaved(r.last.route) && r.last.text.toLowerCase().contains('aluguel')) ? null : 'aluguel continua: ${r.last}'),
  Scn('edicao', 'muda o valor do aluguel pra 1500', ['muda o valor do aluguel pra 1500'], 'aluguel = 1500',
      (s, r) => s.repo.transactions.firstWhere((t) => t.id == 'init-3').amount == 1500 ? null : 'aluguel=${s.repo.transactions.firstWhere((t) => t.id == 'init-3').amount} ${r.last}'),
  Scn('edicao', 'apaga os dois últimos', ['gastei 50 no mercado no pix', 'gastei 30 na padaria no débito', 'apaga os dois últimos', 'sim'], 'pede confirmação; com "sim", 0 lançamentos novos',
      (s, r) => deletedAfterConfirm(s, r, 2, (t, n) => n == 0)),
  Scn('edicao', 'edita o último lançamento', ['gastei 50 no mercado no pix', 'edita o último lançamento'], 'pergunta o que mudar, sem novo lançamento',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 50 && notSaved(r.last.route) && !r.last.text.contains('Não consegui identificar'), 5)),
  Scn('edicao', 'renomeia categoria pets→animais', ['renomeia a categoria pets para animais'], 'categoria renomeada',
      (s, r) => s.repo.budgets.any((b) => b.name.toLowerCase() == 'animais') ? null : '${r.last}',
      setup: (s) => s.repo.addBudgetCategory('Pets', 200)),
  Scn('edicao', 'cria categoria por chat', ['cria uma categoria chamada viagens'], 'categoria criada',
      (s, r) => s.repo.budgets.any((b) => b.name.toLowerCase() == 'viagens') ? null : '${r.last}'),
  Scn('edicao', 'define orçamento por chat', ['meu limite de lazer é 800 por mês'], 'orçamento leisure=800',
      (s, r) => s.repo.budgets.firstWhere((b) => b.category == 'leisure').monthlyLimit == 800 ? null : '${r.last}'),
  Scn('edicao', 'nome de categoria custom como correção', ['gastei 80 na petshop no pix', 'pets'], 'categoria Pets',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.category == s.repo.findCustomCategoryCode('pets'), 5),
      setup: (s) => s.repo.addBudgetCategory('Pets', 200)),

  // ── contexto / multi-turno ──
  Scn('contexto', 'só "pix"', ['gastei 50 no mercado', 'pix'], '50 supermarket pix',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 50 && t.paymentMethod == 'pix', 5)),
  Scn('contexto', 'só "200"', ['paguei o mercado no pix', '200'], '200 supermarket pix',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 200 && t.category == 'supermarket', 5)),
  Scn('contexto', 'só "mercado"', ['gastei 80 no pix', 'mercado'], '80 supermarket',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 80 && t.category == 'supermarket', 5)),
  Scn('contexto', 'só "uns 200" depois "debito"', ['gastei no mercado', 'uns 200', 'debito'], '200 supermarket debit',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 200 && t.paymentMethod == 'debit_card', 5)),
  Scn('contexto', '"gastei 40" ⏎ "no mercado no débito"', ['gastei 40', 'no mercado no débito'], '40 supermarket debit',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 40 && t.category == 'supermarket' && t.paymentMethod == 'debit_card', 5)),
  Scn('contexto', 'cancela no meio', ['gastei no mercado', 'cancela'], 'nada salvo',
      (s, r) => afterSaved(s, r, (t, n) => n == 0 && r.last.route == 'cancel_pending', 5)),
  Scn('contexto', 'esquece no meio', ['gastei 50', 'esquece'], 'nada salvo',
      (s, r) => afterSaved(s, r, (t, n) => n == 0, 5)),
  // Regra B: "blusa" não tem categoria conhecida, então o César pergunta a
  // categoria da blusa (uma vez). O que importa aqui: os 50 não são salvos e a
  // pergunta passa a ser sobre os 500, com aviso de descarte.
  Scn('contexto', 'frase nova no meio', ['gastei 50', 'comprei uma blusa de 500 no pix'], 'blusa 500 (salva ou perguntando a categoria), 50 descartado com aviso',
      (s, r) => !s.repo.transactions.any((x) => !x.id.startsWith('init-') && x.amount == 50) &&
              (r.last.route == 'saved' || (r.last.draft?.amount == 500 && r.last.text.contains('não foi registrado')))
          ? null
          : '${r.last} / ${afterSaved(s, r, (t, n) => false, 5)}'),
  Scn('contexto', 'pergunta no meio de rascunho', ['gastei 50', 'quanto gastei esse mês?'], 'responde relatório, não salva 50',
      (s, r) => r.last.route == 'report:spending' && s.repo.transactions.every((x) => x.id.startsWith('init-')) ? null : '${r.last} / ${afterSaved(s, r, (t, n) => false, 5)}'),
  Scn('contexto', 'resposta sem sentido', ['gastei 50', 'não sei'], 'continua perguntando, não inventa',
      (s, r) => afterSaved(s, r, (t, n) => n == 0 || (t!.category != 'unknown'), 5) == null && r.last.route != 'saved' ? null : '${r.last} / ${afterSaved(s, r, (t, n) => false, 5)}'),
  Scn('contexto', '"e ontem?" após pergunta', ['quanto gastei esse mês?', 'e ontem?'], 'report:spending com ontem',
      (s, r) => r.last.route == 'report:spending' && r.last.text.contains('ontem') ? null : '${r.last}'),
  Scn('contexto', '"e com mercado?" após pergunta', ['quanto gastei com uber?', 'e com mercado?'], 'report:spending 380,50',
      (s, r) => r.last.route == 'report:spending' && r.last.text.contains('380,50') ? null : '${r.last}'),
  Scn('contexto', '"e no mês passado?" após pergunta', ['quanto gastei com mercado esse mês?', 'e no mês passado?'], 'report:spending mês passado',
      (s, r) => r.last.route == 'report:spending' && r.last.text.toLowerCase().contains('passado') ? null : '${r.last}'),
  Scn('contexto', 'duas correções seguidas', ['gastei 50 no mercado no pix', 'na verdade foi 45', 'na verdade foi no débito'], '45 debit',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45 && t.paymentMethod == 'debit_card', 5)),
  Scn('contexto', 'correção encadeada com "e"', ['gastei 50 no mercado no pix', 'na verdade foi 45', 'e foi no débito'], '45 debit (1 lançamento)',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45 && t.paymentMethod == 'debit_card', 5)),
  Scn('contexto', '"e 30 na padaria" herda contexto', ['gastei 50 no mercado no pix', 'e 30 na padaria'], '2 lançamentos, 30 padaria',
      (s, r) => afterSaved(s, r, (t, n) => n == 2 && t!.amount == 30, 5)),
  Scn('contexto', '"o anterior" ', ['gastei 50 no mercado no pix', 'gastei 30 na padaria no débito', 'apaga o anterior', 'sim'], 'pede confirmação; com "sim", remove o de 50',
      (s, r) => deletedAfterConfirm(s, r, 2, (t, n) => n == 1 && t!.amount == 30)),
  Scn('contexto', '"repete o último"', ['gastei 12 no café no pix', 'repete o último'], '2 lançamentos de 12',
      (s, r) => afterSaved(s, r, (t, n) => n == 2 && t!.amount == 12, 5)),
  // Regra C: compra no crédito sem parcelas pergunta "parcelado ou à vista?".
  // A gorjeta soma (120) e a pergunta de parcelas vem uma vez; com "à vista", salva.
  Scn('contexto', '"mais 20 de gorjeta"', ['gastei 100 no restaurante no crédito', 'mais 20 de gorjeta', 'à vista'], 'soma 120 (ou novo 20) e salva após "à vista"',
      (s, r) => afterSaved(s, r, (t, n) => (n == 2 && t!.amount == 20) || (n == 1 && t!.amount == 120), 5)),
  Scn('contexto', '"o mesmo de ontem"', ['gastei o mesmo de ontem no almoço'], 'pergunta o valor (não inventa)',
      (s, r) => notSaved(r.last.route) ? null : '${r.last}'),
  Scn('contexto', 'meta: criar e aportar', ['quero juntar 5000 para uma viagem até dezembro', 'guardei 200 na meta da viagem'], 'meta com 200',
      (s, r) => s.repo.goals.isNotEmpty && s.repo.goals.first.savedAmount == 200 ? null : '${r.map((e) => e.toString()).join(' | ')}'),
  Scn('contexto', 'meta: "coloquei mais 100 na viagem"', ['quero juntar 5000 para uma viagem até dezembro', 'coloquei mais 100 na viagem'], 'meta com 100',
      (s, r) => s.repo.goals.isNotEmpty && s.repo.goals.first.savedAmount == 100 ? null : '${r.map((e) => e.toString()).join(' | ')}'),
  Scn('contexto', 'dívida paga', ['o joão me pagou 50 da dívida'], 'João deve 100',
      (s, r) => s.repo.findDebtorsByName('João').isNotEmpty && s.repo.findDebtorsByName('João').first.amount == 100 ? null : '${r.last}'),
  Scn('contexto', 'dívida paga (sem "me")', ['o joão pagou 50 do que me devia'], 'João deve 100',
      (s, r) => s.repo.findDebtorsByName('João').isNotEmpty && s.repo.findDebtorsByName('João').first.amount == 100 ? null : '${r.last} / ${afterSaved(s, r, (t, n) => false, 5)}'),
  Scn('contexto', 'dois gastos numa frase ⏎ "pix"', ['gastei 50 no mercado e 30 na farmácia', 'pix'], '2 lançamentos (50 mercado, 30 farmácia)',
      (s, r) => afterSaved(s, r, (t, n) => n == 2, 5)),
  Scn('contexto', 'valor por voz errado ⏎ "pix"', ['comprei um remedio de quarenta e cinco reais na farmacia', 'pix'], '45 salvo',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 45, 5)),
  // "padaria" passou a ser categoria conhecida (rodada 2), o que tirava a
  // pergunta pendente deste cenário. Usa um item sem categoria para manter a
  // intenção original: apagar durante uma pergunta pendente não salva nada.
  Scn('edicao', '"apaga isso" com pergunta pendente', ['gastei 30 no débito', 'apaga isso'], 'nada salvo',
      (s, r) => afterSaved(s, r, (t, n) => n == 0, 5)),
  Scn('edicao', 'pergunta entre lançamento e "apaga o último"', ['gastei 50 no mercado no pix', 'qual meu saldo?', 'apaga o último', 'sim'], 'pede confirmação; com "sim", 50 removido (e resposta honesta)',
      (s, r) => deletedAfterConfirm(s, r, 2, (t, n) => n == 0)),
  Scn('edicao', 'relatório entre lançamento e "apaga o último"', ['gastei 50 no mercado no pix', 'quanto gastei esse mês?', 'apaga o último', 'sim'], 'pede confirmação; com "sim", 50 removido',
      (s, r) => deletedAfterConfirm(s, r, 2, (t, n) => n == 0)),
  Scn('edicao', 'muda pra 200', ['gastei 50 no mercado no pix', 'muda pra 200'], 'valor 200',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 200, 5)),
  Scn('edicao', '"isso foi no crédito" (correção de pagamento)', ['gastei 50 no mercado no pix', 'isso foi no crédito'], 'crédito, sem perguntar de novo',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.paymentMethod == 'credit_card', 5)),
  Scn('edicao', '"apaga" corrige multi inteiro', ['gastei 50 no mercado e 30 na farmácia no pix', 'apaga o último', 'sim'], 'pede confirmação; com "sim", só o de 30 removido',
      (s, r) => deletedAfterConfirm(s, r, 1, (t, n) => n == 1 && t!.amount == 50)),
  Scn('contexto', 'recebi 300 do joão (deve 150)', ['recebi 300 do joão'], 'quita 150 e trata o excedente (pergunta ou receita)',
      // Registrar os 300 como recebidos e encerrar a cobrança é aceitável; o excedente
      // não comentado vira achado P3 à parte.
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 300 && s.repo.findDebtorsByName('João').isEmpty, 5)),
  Scn('edicao', 'multi-lançamento gera IDs únicos', ['gastei 50 no mercado e 30 na farmácia no pix'], 'IDs distintos',
      (s, r) {
        final ids = s.repo.transactions.map((t) => t.id).toList();
        return ids.toSet().length == ids.length ? null : 'IDs duplicados: ${ids.where((i) => !i.startsWith('init-')).toList()}';
      }),
  Scn('contexto', 'a maria me devolveu 50 (sem dívida)', ['a maria me devolveu 50'], 'oferece registrar como receita',
      (s, r) => afterSaved(s, r, (t, n) => n == 1 && t!.amount == 50, 5) == null || r.last.text.toLowerCase().contains('receita') ? null : '${r.last}'),
  Scn('contexto', 'posso comprar', ['posso comprar um celular de 2000?'], 'afford:*', (s, r) => r.last.route.startsWith('afford') ? null : '${r.last}'),
  Scn('contexto', 'dá pra gastar 300 no fds?', ['dá pra gastar 300 nesse fim de semana?'], 'afford:* sem salvar',
      (s, r) => r.last.route.startsWith('afford') ? null : '${r.last}'),
];

// ─────────────────────────── execução ───────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  ChatSim fresh() => ChatSim(engine, FinancialRepository());

  test('conversation probe', () {
    final pass = <String, int>{};
    final total = <String, int>{};
    void score(String axis, bool ok) {
      total[axis] = (total[axis] ?? 0) + 1;
      if (ok) pass[axis] = (pass[axis] ?? 0) + 1;
    }

    // single-turn
    for (final c in txCases) {
      final problems = <String>[];
      Reply? r;
      try {
        final sim = fresh();
        r = sim.send(c.phrase);
        final d = r.draft;
        if (c.route != null) {
          if (r.route != c.route) problems.add('route ${r.route}≠${c.route}');
        } else if (d == null) {
          problems.add('route ${r.route} (sem rascunho)');
        } else {
          // Perguntar a forma de pagamento quando a frase não diz qual é
          // comportamento aceitável ("na dúvida, pergunta") — não conta como falha.
          // Idem para "parcelado ou à vista?" numa compra no crédito (vira P3 de
          // polimento, registrado à parte).
          // Regra C (2026-09-24): em assinatura/mensalidade sem dia dito, perguntar o
          // dia de vencimento também é o comportamento certo.
          final onlyAsksPayment = d.missingSlots.every((m) =>
              (m == 'payment_method' && c.pay == null) ||
              (m == 'installments' && c.inst == null) ||
              (m == 'due_day' && c.day == null));
          if (c.complete && !d.isComplete && !onlyAsksPayment) problems.add('ficou perguntando ${d.missingSlots}');
          if (c.intent != null && !c.intent!.contains(d.intent)) problems.add('intent ${d.intent}≠${c.intent}');
          if (c.amount != null && (d.amount == null || (d.amount! - c.amount!).abs() > 0.001)) problems.add('valor ${d.amount}≠${c.amount}');
          if (c.cat != null && !c.cat!.contains(d.category)) problems.add('cat ${d.category}≠${c.cat}');
          if (c.pay != null && d.paymentMethod != c.pay) problems.add('pag ${d.paymentMethod}≠${c.pay}');
          if (c.inst != null && d.installments != c.inst) problems.add('parc ${d.installments}≠${c.inst}');
          if (c.day != null && d.dateOffsetDays != c.day) problems.add('dia ${d.dateOffsetDays}≠${c.day}');
          if (c.recurrent != null && d.isRecurrent != c.recurrent) problems.add('rec ${d.isRecurrent}≠${c.recurrent}');
        }
      } catch (e) {
        problems.add('EXCEPTION $e');
      }
      final ok = problems.isEmpty;
      score(c.axis, ok);
      if (!ok) {
        final silent = r != null && r.route.contains('aved') &&
            problems.any((p) => p.startsWith('valor') || p.startsWith('intent') || p.startsWith('dia'));
        print('FAIL [${c.axis}]${silent ? ' [P0?]' : ''} "${c.phrase}" => $r || ${problems.join('; ')}');
      }
    }

    // Q&A
    for (final q in qaCases) {
      Reply? r;
      var ok = false;
      try {
        final sim = fresh();
        r = sim.send(q.phrase);
        // "Não consegui identificar essa transação" nunca é resposta boa a uma pergunta/saudação.
        ok = q.routeOk(r.route) && q.contains.every((s) => r!.text.contains(s)) && notSaved(r.route) &&
            !r.text.contains('Não consegui identificar');
      } catch (e) {
        r = Reply('EXCEPTION', '$e');
      }
      score('qa', ok);
      if (!ok) print('FAIL [qa] "${q.phrase}" => $r || esperado: ${q.routeDesc} ${q.contains}');
    }

    // multi-turno
    for (final s in scenarios) {
      String? problem;
      final sim = fresh();
      try {
        s.setup?.call(sim);
        for (final t in s.turns) {
          sim.send(t);
        }
        problem = s.check(sim, sim.log);
      } catch (e) {
        problem = 'EXCEPTION $e';
      }
      score(s.axis, problem == null);
      if (problem != null) {
        print('FAIL [${s.axis}] ${s.name}: ${s.turns.join(' ⏎ ')} || esperado: ${s.expected} || $problem');
        for (var i = 0; i < sim.log.length; i++) {
          print('FAIL      turno ${i + 1} "${i < s.turns.length ? s.turns[i] : ''}" => ${sim.log[i]}');
        }
      }
    }

    var p = 0, t = 0;
    for (final axis in total.keys) {
      p += pass[axis] ?? 0;
      t += total[axis]!;
      print('AXIS $axis ${pass[axis] ?? 0}/${total[axis]}');
    }
    print('TOTAL $p/$t');
  });
}
