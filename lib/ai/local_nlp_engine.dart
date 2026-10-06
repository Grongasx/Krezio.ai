import 'dart:convert';
import 'dart:math';
import '../backend/services/calendar_service.dart';
import 'financial_report_rag_engine.dart';
import 'category_name_matcher.dart';
import 'pt_number_words.dart';
import 'transaction_command_parser.dart';
import 'keyword_typo_corrector.dart';
import 'money_direction.dart';
import 'hypothesis_detector.dart';
import 'temporal_date_parser.dart';
import 'entry_certainty.dart';
import 'entry_safety_gate.dart';
import 'pending_reply_check.dart';

/// Prediction result with class label and confidence score.
class PredictionResult {
  final String label;
  final double confidence;

  PredictionResult(this.label, this.confidence);
}

/// Representation of a parsed financial transaction extracted locally on-device.
/// A "quantity × unit price" amount found in a phrase, e.g. "3 unidades a 20
/// reais cada" → 3 × 20 = 60.
class QuantityPricing {
  final int quantity;
  final double unitPrice;
  final double total;
  final String matchedText;

  const QuantityPricing({
    required this.quantity,
    required this.unitPrice,
    required this.total,
    required this.matchedText,
  });

  static String _brl(double v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';

  /// "🧮 3 × R$ 20,00 = R$ 60,00"
  String get breakdown => '🧮 $quantity × ${_brl(unitPrice)} = ${_brl(total)}';
}

enum ContradictionKind { payment, direction, date }

/// Something in a sentence that can't all be true at once ("no pix e no
/// crédito", "gastei e recebi", "dia 45").
class Contradiction {
  final ContradictionKind kind;

  /// What conflicts, in words ("Pix e crédito", "dia 45 não existe").
  final String detail;

  const Contradiction(this.kind, this.detail);

  String question(double? amount) {
    final value = amount != null && amount > 0 ? QuantityPricing._brl(amount) : 'esse valor';
    switch (kind) {
      case ContradictionKind.payment:
        return 'Você falou em $detail. Qual foi a forma de pagamento de $value? Se foi dividido, me diga quanto em cada um.';
      case ContradictionKind.direction:
        return 'Fiquei na dúvida: $value foi um gasto ou uma entrada? Me mande de novo só o que aconteceu, '
            'ex.: "gastei 50 no mercado no pix" ou "recebi 50 no pix".';
      case ContradictionKind.date:
        return 'Não registrei ainda porque a data não fecha ($detail). Quando foi esse lançamento de $value? (ex: hoje, ontem)';
    }
  }
}

/// "50 reais o dia durante 10 dias" → rate 50, 10 days.
class DailyRate {
  final double rate;
  final int days;

  const DailyRate({required this.rate, required this.days});

  double get total => double.parse((rate * days).toStringAsFixed(2));

  /// "🧮 10 dias × R$ 50,00 = R$ 500,00"
  String get breakdown => '🧮 $days dias × ${QuantityPricing._brl(rate)} = ${QuantityPricing._brl(total)}';
}

class FinancialTransactionDraft {
  final String intent; // 'expense', 'income', 'transfer', 'query', 'unknown'
  final double intentConfidence;
  final String category; // 'supermarket', 'transport', 'health', 'leisure', etc.
  final String paymentMethod; // 'pix', 'credit_card', 'debit_card', 'cash', 'bank_slip', 'unknown'
  final double? amount;
  final int dateOffsetDays;
  final String description;
  final String rawText;
  final double latencyMs;
  final bool isComplete;
  final List<String> missingSlots;
  final String? clarificationPrompt;
  final int? installments; // 1 = à vista / parcela única, 2..N = parcelado
  final bool isRecurrent;
  final int? dueDay; // 1..31
  /// "todo 5º dia útil": the N-th business day of each month. The calendar
  /// date moves month to month, so [dueDay] then only holds the *next* one.
  final int? dueBusinessDay;
  /// "50 reais o dia durante 10 dias": [amount] is the daily rate and this
  /// many daily expenses get recorded, one per day.
  final int? repeatDays;
  final int? billingDay; // Day bill is issued / arrives
  final int? paymentMarginDays; // Days between billing and due date
  final bool isReportQuery;
  final String? reportType;
  final String? frequency; // 'monthly', 'weekly', 'yearly'
  final String? bankSource; // 'Nubank', 'Itaú', 'Inter', 'Bradesco', etc.
  final String? budgetInsight;
  final bool isCorrection;
  final bool isCanceled;
  final String? recurrenceDuration;
  final bool isReminder;
  final String? reminderType; // 'loan_receivable', 'dividend', 'bill_payment', 'general'
  final String? personName;
  final DateTime? targetDate;
  final String? calendarConsultationNote;

  /// What César assumed without asking ("Considerei sem prazo para
  /// terminar…"), to be said when the entry is confirmed.
  final String? assumptionNote;

  /// Checks of [EntrySafetyGate] the user already answered ("type", "date",
  /// "split") — never asked again for this draft.
  final Set<String> settledChecks;

  FinancialTransactionDraft({
    required this.intent,
    required this.intentConfidence,
    required this.category,
    required this.paymentMethod,
    this.amount,
    required this.dateOffsetDays,
    required this.description,
    required this.rawText,
    required this.latencyMs,
    required this.isComplete,
    required this.missingSlots,
    this.clarificationPrompt,
    this.installments,
    this.isRecurrent = false,
    this.dueDay,
    this.dueBusinessDay,
    this.repeatDays,
    this.billingDay,
    this.paymentMarginDays,
    this.isReportQuery = false,
    this.reportType,
    this.frequency,
    this.recurrenceDuration,
    this.bankSource,
    this.budgetInsight,
    this.isCorrection = false,
    this.isCanceled = false,
    this.isReminder = false,
    this.reminderType,
    this.personName,
    this.targetDate,
    this.calendarConsultationNote,
    this.assumptionNote,
    this.settledChecks = const {},
  });

  Map<String, dynamic> toJson() => {
        'intent': intent,
        'intent_confidence': intentConfidence,
        'category': category,
        'payment_method': paymentMethod,
        'amount': amount,
        'date_offset_days': dateOffsetDays,
        'description': description,
        'raw_text': rawText,
        'latency_ms': latencyMs,
        'is_complete': isComplete,
        'missing_slots': missingSlots,
        'clarification_prompt': clarificationPrompt,
        'installments': installments,
        'is_recurrent': isRecurrent,
        'due_day': dueDay,
        'due_business_day': dueBusinessDay,
        'repeat_days': repeatDays,
        'billing_day': billingDay,
        'payment_margin_days': paymentMarginDays,
        'is_report_query': isReportQuery,
        'report_type': reportType,
        'frequency': frequency,
        'recurrence_duration': recurrenceDuration,
        'bank_source': bankSource,
        'budget_insight': budgetInsight,
        'is_correction': isCorrection,
        'is_canceled': isCanceled,
        'is_reminder': isReminder,
        'reminder_type': reminderType,
        'person_name': personName,
        'target_date': targetDate?.toIso8601String(),
        'calendar_consultation_note': calendarConsultationNote,
        'assumption_note': assumptionNote,
      };

  FinancialTransactionDraft copyWith({
    String? intent,
    double? intentConfidence,
    String? category,
    String? paymentMethod,
    double? amount,
    int? dateOffsetDays,
    String? description,
    String? rawText,
    double? latencyMs,
    bool? isComplete,
    List<String>? missingSlots,
    String? clarificationPrompt,
    int? installments,
    bool? isRecurrent,
    int? dueDay,
    int? dueBusinessDay,
    bool clearDueBusinessDay = false,
    int? repeatDays,
    int? billingDay,
    int? paymentMarginDays,
    bool? isReportQuery,
    String? reportType,
    String? frequency,
    String? recurrenceDuration,
    String? bankSource,
    String? budgetInsight,
    bool? isCorrection,
    bool? isCanceled,
    bool? isReminder,
    String? reminderType,
    String? personName,
    DateTime? targetDate,
    String? calendarConsultationNote,
    String? assumptionNote,
    bool clearAmount = false,
    Set<String>? settledChecks,
  }) {
    return FinancialTransactionDraft(
      intent: intent ?? this.intent,
      intentConfidence: intentConfidence ?? this.intentConfidence,
      category: category ?? this.category,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      amount: clearAmount ? null : (amount ?? this.amount),
      dateOffsetDays: dateOffsetDays ?? this.dateOffsetDays,
      description: description ?? this.description,
      rawText: rawText ?? this.rawText,
      latencyMs: latencyMs ?? this.latencyMs,
      isComplete: isComplete ?? this.isComplete,
      missingSlots: missingSlots ?? this.missingSlots,
      clarificationPrompt: clarificationPrompt ?? this.clarificationPrompt,
      installments: installments ?? this.installments,
      isRecurrent: isRecurrent ?? this.isRecurrent,
      dueDay: dueDay ?? this.dueDay,
      dueBusinessDay: clearDueBusinessDay ? null : (dueBusinessDay ?? this.dueBusinessDay),
      repeatDays: repeatDays ?? this.repeatDays,
      billingDay: billingDay ?? this.billingDay,
      paymentMarginDays: paymentMarginDays ?? this.paymentMarginDays,
      isReportQuery: isReportQuery ?? this.isReportQuery,
      reportType: reportType ?? this.reportType,
      frequency: frequency ?? this.frequency,
      recurrenceDuration: recurrenceDuration ?? this.recurrenceDuration,
      bankSource: bankSource ?? this.bankSource,
      budgetInsight: budgetInsight ?? this.budgetInsight,
      isCorrection: isCorrection ?? this.isCorrection,
      isCanceled: isCanceled ?? this.isCanceled,
      isReminder: isReminder ?? this.isReminder,
      reminderType: reminderType ?? this.reminderType,
      personName: personName ?? this.personName,
      targetDate: targetDate ?? this.targetDate,
      calendarConsultationNote: calendarConsultationNote ?? this.calendarConsultationNote,
      assumptionNote: assumptionNote ?? this.assumptionNote,
      settledChecks: settledChecks ?? this.settledChecks,
    );
  }
}

/// Active feature extracted from the input text with its TF, IDF, and combined weight.
class ActiveFeatureTrace {
  final String token;
  final int index;
  final double tf;
  final double idf;
  final double value;

  const ActiveFeatureTrace({
    required this.token,
    required this.index,
    required this.tf,
    required this.idf,
    required this.value,
  });
}

/// Probability and raw score for an individual class in a classifier.
class ClassifierProbabilityTrace {
  final String label;
  final double score;
  final double probability;

  const ClassifierProbabilityTrace({
    required this.label,
    required this.score,
    required this.probability,
  });
}

/// Detailed inference trace for one classification model (Intent, Category, or Payment).
class ModelInferenceTrace {
  final String modelName;
  final String predictedLabel;
  final double confidence;
  final List<ClassifierProbabilityTrace> probabilities;

  const ModelInferenceTrace({
    required this.modelName,
    required this.predictedLabel,
    required this.confidence,
    required this.probabilities,
  });
}

/// Trace detailing why installments were or were not required.
class InstallmentDecisionTrace {
  final int? installments;
  final bool isCreditCard;
  final bool isSubscription;
  final bool isAnnual;
  final bool isExempt;
  final String explanation;

  const InstallmentDecisionTrace({
    this.installments,
    required this.isCreditCard,
    required this.isSubscription,
    required this.isAnnual,
    required this.isExempt,
    required this.explanation,
  });
}

/// Full transparent trace of the neural network / ML pipeline execution.
class NeuralThoughtTrace {
  final String rawText;
  final String normalizedText;
  final List<String> rawTokens;
  final List<String> normalizedTokens;
  final Map<String, String> typoFixes;
  final List<String> ngrams;
  final List<ActiveFeatureTrace> activeFeatures;
  final ModelInferenceTrace intentModel;
  final ModelInferenceTrace categoryModel;
  final ModelInferenceTrace paymentModel;
  final double? parsedAmount;
  final int dateOffsetDays;
  final String extractedDescription;
  final bool isRecurrent;
  final int? dueDay;
  final String? frequency;
  final String? recurrenceDuration;
  final InstallmentDecisionTrace installmentDecision;
  final List<String> missingSlots;
  final bool isComplete;
  final String? clarificationPrompt;
  final String? budgetInsight;
  final double latencyMs;
  final FinancialTransactionDraft draft;

  const NeuralThoughtTrace({
    required this.rawText,
    required this.normalizedText,
    required this.rawTokens,
    required this.normalizedTokens,
    required this.typoFixes,
    required this.ngrams,
    required this.activeFeatures,
    required this.intentModel,
    required this.categoryModel,
    required this.paymentModel,
    this.parsedAmount,
    required this.dateOffsetDays,
    required this.extractedDescription,
    required this.isRecurrent,
    this.dueDay,
    this.frequency,
    this.recurrenceDuration,
    required this.installmentDecision,
    required this.missingSlots,
    required this.isComplete,
    this.clarificationPrompt,
    this.budgetInsight,
    required this.latencyMs,
    required this.draft,
  });
}

/// Pure Dart, 100% On-Device Financial NLP Engine for Krezio.ai with Anti-Hallucination & Slot Completion.
class LocalFinancialNlpEngine {
  final Map<String, int> _vocabulary;
  final List<double> _idf;
  final Map<String, dynamic> _intentModel;
  final Map<String, dynamic> _categoryModel;
  final Map<String, dynamic> _paymentModel;
  final int _vocabSize;
  final double _confidenceThreshold;
  final RealtimeCalendarService calendarService;

  /// User-created categories (display name → internal code). The trained model
  /// only knows the built-in ones, so the app hands these over (see
  /// [setCustomCategories]) and the engine matches them by name in the text.
  Map<String, String> _customCategories = const {};

  void setCustomCategories(Map<String, String> nameToCode) {
    _customCategories = Map.unmodifiable(nameToCode);
  }

  /// Code of the custom category whose name appears in [text], if any.
  String? matchCustomCategory(String text) {
    for (final entry in _customCategories.entries) {
      if (CategoryNameMatcher.mentions(text, entry.key) || CategoryNameMatcher.mentions(text, entry.value.replaceAll('_', ' '))) {
        return entry.value;
      }
    }
    return null;
  }

  /// "cancela", "cancelar lançamento", "esquece", "deixa pra lá"... — the user
  /// giving up on the transaction César is still asking questions about.
  bool isCancelCommand(String text, {FinancialTransactionDraft? pending}) {
    // "não" to "Registro assim?" drops the entry (7e).
    if (pending != null && pending.missingSlots.contains('confirm') && EntrySafetyGate.declinesEntry(text)) return true;
    final lower = CategoryNameMatcher.foldAccents(text.toLowerCase().trim());
    // "apaga o do sacolão" while César asks about another entry names a
    // saved record: the assistant acts on it and drops the draft (R2-CONV-007).
    if (TransactionCommandParser.namesSpecificRecord(text, now: DateTime.now(), budgets: const [])) return false;
    // "não cancela" / "não apaga" is the opposite.
    if (RegExp(r'\b(?:nao|nem)\s+(?:\w+\s+)?(?:cancel|apag|exclu|delet|remov|descart|desfa)').hasMatch(lower)) return false;
    return RegExp(r'\bcancel(?:a|ar|e|o|ado|amento)\b').hasMatch(lower) ||
        // "apaga isso", "exclui", "deleta", "desfaz" while César is still
        // asking about the draft: it was read as the answer (category) and
        // the draft got saved.
        RegExp(r'^(?:apaga|apague|apagar|exclui|exclua|excluir|deleta|delete|deletar|remove|remova|remover|descarta|descarte|'
                r'descartar|desfaz|desfaca|desfazer)\b')
            .hasMatch(lower) ||
        RegExp(r'^(?:esquece|esqueca|desconsidera|desiste|desisti|aborta|abortar|deixa quieto|joga fora|jogue fora|nao,? deixa)\b').hasMatch(lower) ||
        lower.contains('deixa pra la') ||
        // "larga mão disso", "outra hora eu resolvo", "deixa pra depois"
        // (ACC-C-013).
        RegExp(r'^(?:ah\s+|ai\s+|nao\s+)?larga\s+(?:a\s+)?mao\b|\boutra\s+hora\s+(?:eu\s+)?(?:resolvo|vejo|falo|registro|lanco|anoto|te\s+falo)\b|'
                r'^(?:deixa|deixe)\s+(?:isso\s+|esse\s+)?(?:pra|para)\s+depois\b|^depois\s+(?:eu\s+)?(?:vejo|resolvo|te\s+falo|registro)\b|'
                r'^(?:esquece|esqueca)\s+(?:isso|esse|essa)\b|^(?:nao|nem)\s+(?:vou|quero)\s+(?:mais\s+)?(?:registrar|lancar|anotar)\b')
            .hasMatch(lower) ||
        lower.contains('deixa para la') ||
        lower.contains('nao quero mais') ||
        lower.contains('nao precisa mais') ||
        lower.contains('nao registra') ||
        lower.contains('nao lanca');
  }

  /// Whether [text], typed while César is still asking about [pending], is a
  /// brand-new transaction rather than an answer to his question. Without
  /// this, "comprei uma blusa de 500 no pix" got merged into an older,
  /// unfinished draft and saved with *its* type and description.
  bool startsNewTransaction(FinancialTransactionDraft pending, String text) {
    // The check every pending state shares ([PendingReplyCheck]): something
    // that didn't happen ("por pouco não torrei 118") is never the answer —
    // read on its own it records nothing (7d).
    if (PendingReplyCheck.isNonEvent(text) && HypothesisDetector.detect(pending.rawText.split(' + ').first) == null) return true;
    // A command about saved records or a question of its own is a subject
    // of its own — also for a batch waiting for its payment, which ate "apaga
    // o 7 belo" and "qual meu saldo?" and asked the same again (CHAOS-C-010).
    if (PendingReplyCheck.isCommand(text, now: DateTime.now()) || _asksSomethingElse(text)) return true;
    // Several entries in one sentence are never the answer to one draft's
    // question ("comprei pão" ⏎ "almoço 32 e janta 48 no pix"): a new
    // batch (CHAOS-B-007).
    if (!_readingBatch && RegExp(r'\d[\d.,]*\D+\d').hasMatch(text) && parseMulti(text).length >= 2) return true;
    final fresh = parse(text);
    if (!const {'expense', 'income', 'transfer'}.contains(fresh.intent)) {
      // "vendi umas roupas no brechó" while César asks the plumber's value:
      // no value, so the classifier didn't call it an entry, but it tells
      // its own story (ACC-B-015).
      final way = MoneyDirectionDetector.detect(text);
      final dir = way == MoneyDirection.incoming ? 'income' : (way == MoneyDirection.outgoing ? 'expense' : null);
      return dir != null && !pending.missingSlots.contains('type') && PendingReplyCheck.tellsAnotherStory(text, pendingSubject(pending), textDirection: dir);
    }
    // "99", "deu 99", "R$ 99", "saiu 110 no boleto": only a value (and the
    // payment/date) is an answer, never a new entry — even when "99" is also
    // the name of an app (ACC-A-017, CHAOS-A-016).
    if (pending.missingSlots.contains('amount') && _isBareValueAnswer(text)) return false;
    if (fresh.amount == null || fresh.amount! <= 0) return _valuelessSentenceIsNew(pending, fresh, text);
    // César asked "quanto foi?": "500 reais", "foi 30 no pix", "o mercado deu
    // 230" answer it. Before, *any* sentence was taken as the answer, and
    // "recebi 300 de salário" was saved as the pending "Mercado" expense
    // (CHAOS-R3-001).
    if (pending.missingSlots.contains('amount')) return _replacesValuelessDraft(pending, fresh, text);
    return text.trim().split(RegExp(r'\s+')).length >= 3;
  }

  /// "qual meu saldo?", "quanto gastei ontem?": a question that opens with an
  /// interrogative word — not an unsure answer ("foi no débito?").
  static bool _asksSomethingElse(String text) =>
      PendingReplyCheck.isQuestion(text) &&
      RegExp(r'^(?:e\s+)?(?:qual|quais|quanto|quantos|quantas|quando|onde|como|quem|cade|o\s+que|oque|por\s*que|pq|sera)\b')
          .hasMatch(CategoryNameMatcher.foldAccents(text.toLowerCase().trim()));

  /// With a draft still missing its value, [text] is a new entry (not the
  /// answer) when it carries its own story: the money going the other way
  /// ("recebi…" while asking about a purchase), another thing named ("o uber
  /// foi 30" while asking about the mercado), or — when the pending draft
  /// came from a comment with no entry verb at all ("a feira hoje tava
  /// ótima", CONV-R3-012) — any sentence that tells an entry.
  bool _replacesValuelessDraft(FinancialTransactionDraft pending, FinancialTransactionDraft fresh, String text) {
    final folded = CategoryNameMatcher.foldAccents(text.toLowerCase());
    final pendingRaw = pending.rawText.split(' + ').first;
    final freshSignal = _firstPersonEntryVerb.hasMatch(folded) ||
        PendingReplyCheck.ownMoneyVerb(folded) != null ||
        MoneyDirectionDetector.detect(text) != MoneyDirection.unknown;
    final pendingFolded = CategoryNameMatcher.foldAccents(pendingRaw.toLowerCase());
    final pendingSignal = _firstPersonEntryVerb.hasMatch(pendingFolded) ||
        PendingReplyCheck.ownMoneyVerb(pendingFolded) != null ||
        MoneyDirectionDetector.detect(pendingRaw) != MoneyDirection.unknown;
    final freshNamed = fresh.category != 'unknown' && _hasCategoryNoun(_normalizeText(text));
    if (!pendingSignal) return freshSignal || freshNamed;
    const txIntents = {'expense', 'income', 'transfer'};
    if (txIntents.contains(pending.intent) && fresh.intent != pending.intent && (freshSignal || freshNamed)) return true;
    // "paguei o encanador" ⏎ "comprei uma lâmpada de 20 no débito": its own
    // verb and its own object — another purchase, not the plumber's value
    // (ACC-A-007/008, CHAOS-A-011).
    if (_tellsAnotherObject(pending, fresh, text)) return true;
    return freshNamed && pending.category != 'unknown' && pending.category != 'expense_other' && fresh.category != pending.category;
  }

  /// A sentence with no value, typed while César asks about [pending], is a
  /// new entry when it tells its own story: the user's own entry verb and
  /// either the money going the other way ("gastei 35 no açougue" ⏎ "recebi
  /// o aluguel da sala") or another object ("paguei o eletricista" ⏎
  /// "comprei pão na padaria"). "no pix", "dia 5", "foi hoje", "gastei no
  /// mercado" (naming what the draft lacked) stay answers (CHAOS-A-012).
  bool _valuelessSentenceIsNew(FinancialTransactionDraft pending, FinancialTransactionDraft fresh, String text) {
    // "levantei 2000" ⏎ "recebi": the answer to "entrou ou saiu?".
    if (pending.missingSlots.contains('type')) return false;
    final folded = CategoryNameMatcher.foldAccents(text.toLowerCase());
    final ownVerb = _firstPersonEntryVerb.hasMatch(folded) || PendingReplyCheck.ownMoneyVerb(folded) != null;
    if (!ownVerb) return false;
    const txIntents = {'expense', 'income', 'transfer'};
    if (txIntents.contains(pending.intent) && fresh.intent != pending.intent) return true;
    return _tellsAnotherObject(pending, fresh, text);
  }

  /// 'income'/'expense' for a sentence with no value whose own money verb
  /// says the way ("vendi…" in, "almocei…" out); null when it doesn't.
  static String? _valuelessEntryIntent(String text) {
    final folded = CategoryNameMatcher.foldAccents(text.toLowerCase());
    if (PendingReplyCheck.ownMoneyVerb(folded) == null || HypothesisDetector.notHappened(text)) return null;
    final way = MoneyDirectionDetector.detect(text);
    if (way == MoneyDirection.incoming) return 'income';
    if (way == MoneyDirection.outgoing) return 'expense';
    // A consumption verb ("almocei", "tomei") is a purchase only with
    // something bought named ("no restaurante"); "tomei um banho" is not.
    if (way == MoneyDirection.unknown &&
        RegExp(r'\b(?:almocei|jantei|lanchei|tomei|comi|bebi|comprei|paguei|gastei|abasteci|pedi|torrei)\b').hasMatch(folded) &&
        !const {'unknown', 'expense_other'}.contains(_resolveContextualCategory(folded, 'unknown'))) {
      return 'expense';
    }
    return null;
  }

  /// What [pending] is about, for [PendingReplyCheck]: every turn said for
  /// it and its title.
  static PendingSubject pendingSubject(FinancialTransactionDraft pending) => PendingSubject(
        '${pending.rawText.replaceAll(' + ', ' ')} ${pending.description}',
        direction: pending.intent,
        category: pending.category,
      );

  /// Whether [text] tells, with its own money verb, an entry about something
  /// the [pending] draft never mentioned ("pago 85 de inglês todo mês" ⏎
  /// "paguei a academia no pix"; "comprei ração" ⏎ "o síndico me cobrou 30
  /// de multa") — the shared [PendingReplyCheck] rule.
  bool _tellsAnotherObject(FinancialTransactionDraft pending, FinancialTransactionDraft fresh, String text) {
    return PendingReplyCheck.tellsAnotherStory(text, pendingSubject(pending), textCategory: fresh.category);
  }

  /// "99", "deu 99", "R$ 99,90", "foram uns 40", "saiu 110 no boleto",
  /// "custou 650 no pix ontem": a value and nothing but how/when it was paid.
  static bool _isBareValueAnswer(String text) {
    final folded = CategoryNameMatcher.foldAccents(PtNumberWords.normalize(text.toLowerCase().trim()));
    if (!RegExp(r'\d').hasMatch(folded)) return false;
    final rest = folded
        .replaceAll(RegExp(r'r\$|\d+(?:[.,]\d+)*'), ' ')
        .split(RegExp(r'[^a-z]+'))
        .where((w) => w.isNotEmpty && !_bareAnswerWords.contains(w))
        .toList();
    return rest.isEmpty;
  }

  static const Set<String> _bareAnswerWords = {
    'foi', 'foram', 'deu', 'deram', 'saiu', 'sairam', 'custou', 'custaram', 'ficou', 'ficaram', 'fechou', 'total', 'era', 'eram',
    'e', 'uns', 'umas', 'tipo', 'so', 'mais', 'ou', 'menos', 'exatamente', 'certinho', 'reais', 'real', 'conto', 'contos', 'pila',
    'pilas', 'no', 'na', 'em', 'via', 'pelo', 'pela', 'o', 'a', 'de', 'do', 'da', 'pix', 'debito', 'credito', 'cartao', 'vista',
    'dinheiro', 'boleto', 'especie', 'x', 'vezes', 'parcelado', 'parcelada', 'hoje', 'ontem', 'anteontem', 'dia', 'ha', 'faz',
    'dias', 'atras', 'segunda', 'terca', 'quarta', 'quinta', 'sexta', 'sabado', 'domingo', 'passada', 'passado', 'acho', 'que',
    'talvez', 'entre', 'quase', 'cerca', 'valor', 'ao', 'todo', 'depois', 'amanha', 'centavos',
  };

  LocalFinancialNlpEngine._({
    required Map<String, int> vocabulary,
    required List<double> idf,
    required Map<String, dynamic> intentModel,
    required Map<String, dynamic> categoryModel,
    required Map<String, dynamic> paymentModel,
    required double confidenceThreshold,
    RealtimeCalendarService? calendarService,
  })  : _vocabulary = vocabulary,
        _idf = idf,
        _intentModel = intentModel,
        _categoryModel = categoryModel,
        _paymentModel = paymentModel,
        _vocabSize = vocabulary.length,
        _confidenceThreshold = confidenceThreshold,
        calendarService = calendarService ?? RealtimeCalendarService();

  /// Factory initializer from JSON string asset or file.
  factory LocalFinancialNlpEngine.fromJsonString(String jsonStr, {RealtimeCalendarService? calendarService}) {
    final Map<String, dynamic> data = jsonDecode(jsonStr);
    final Map<String, dynamic> meta = data['meta'] ?? {};
    final Map<String, dynamic> vocabRaw = data['vocabulary'];
    final Map<String, int> vocabulary = vocabRaw.map((k, v) => MapEntry(k, (v as num).toInt()));
    final List<double> idf = (data['idf'] as List).map((e) => (e as num).toDouble()).toList();
    final models = data['models'] as Map<String, dynamic>;

    return LocalFinancialNlpEngine._(
      vocabulary: vocabulary,
      idf: idf,
      intentModel: models['intent'],
      categoryModel: models['category'],
      paymentModel: models['payment_method'],
      confidenceThreshold: (meta['confidence_threshold'] as num?)?.toDouble() ?? 0.55,
      calendarService: calendarService,
    );
  }

  /// Parses raw Portuguese input text into a structured FinancialTransactionDraft on-device.
  /// Every draft leaves through [EntrySafetyGate] (see [_guard]).
  FinancialTransactionDraft parse(String phrase) {
    final draft = _parseRaw(phrase);
    // One sentence is one turn, even when it has a "+" ("14 no açougue + 66
    // na padaria") — the " + " of [mergeDrafts]' rawText is not a turn here.
    final guarded = _guard(draft, turns: [draft.rawText]);
    return _asOneOfMany(phrase, guarded) ?? guarded;
  }

  bool _readingBatch = false;

  /// A sentence the batch reader splits into several entries ("175 açougue
  /// 9 padaria", "23 açougue 14 padaria") read as *one* entry — the chat
  /// does that when another draft is pending — keeps one value and drops
  /// the others in silence (CHAOS-B-007). Same reading as [parseMulti]:
  /// then it asks.
  FinancialTransactionDraft? _asOneOfMany(String phrase, FinancialTransactionDraft draft) {
    final recordable = isRecordable(draft.missingSlots.length == 1 && draft.missingSlots.single == 'confirm' ? draft.copyWith(isComplete: true) : draft);
    if (_readingBatch || !recordable || RegExp(r'\d[\d.,]*\D+\d').allMatches(phrase).isEmpty) return null;
    _readingBatch = true;
    final List<FinancialTransactionDraft> batch;
    try {
      batch = parseMulti(phrase);
    } finally {
      _readingBatch = false;
    }
    if (batch.length < 2) return null;
    return draft.copyWith(
      isComplete: false,
      missingSlots: ['split', ...draft.missingSlots.where((s) => s != 'split')],
      clarificationPrompt: splitQuestion([for (final d in batch) d.amount ?? 0]),
    );
  }

  /// The single exit of every draft this engine hands out — a sentence
  /// ([parse]), an answer merged into a draft ([mergeDrafts]) or a batch
  /// ([parseMulti], [mergeMultiDrafts]): [EntrySafetyGate] checks it against
  /// all that was said and turns a disagreement into a question instead of
  /// a wrong record. The chat and the voice controller only call these
  /// methods, so both inherit it (Portão do lote A, etapa 7c).
  FinancialTransactionDraft _guard(FinancialTransactionDraft draft, {List<String>? turns}) =>
      EntrySafetyGate.review(draft, turns: turns, now: DateTime.now(), normalize: _normalizeText)
          .applyTo(draft, afterAnswer: (turns ?? draft.rawText.split(' + ')).length > 1);

  /// Public for [EntrySafetyGate]: whether the number [raw] (with the text
  /// [before]/[after] it, folded) is a time, date, span, count, measure,
  /// identifier or ordinal — anything but money.
  static bool isNonValueNumber(String raw, String before, String after) => _isNonValueNumber(raw, before, after);

  /// "caso você não saiba, …", "só pra você saber, …": an aside that only
  /// introduces the fact — not part of the entry nor of its title (ACC-C-010).
  static final RegExp _leadingAside = RegExp(
      r'^\s*(?:(?:caso|se)\s+(?:voce|você|vc|tu|ce)\s+(?:nao|não)\s+(?:saiba|sabe|lembre|lembra)|(?:so\s+|só\s+)?(?:pra|para)\s+(?:voce|você|vc)\s+saber)\s*,\s*',
      caseSensitive: false);

  FinancialTransactionDraft _parseRaw(String phrase) {
    final stopwatch = Stopwatch()..start();
    final cleanText = phrase.trim().replaceFirst(_leadingAside, '');
    final normText = _normalizeText(cleanText);
    final lower = normText.toLowerCase();

    // 0. Auto-identificação e Reconhecimento do Nome: "César"
    final isIdentityQuery = lower.contains('quem e voce') ||
        lower.contains('quem é você') ||
        lower.contains('quem eh voce') ||
        lower.contains('quem eh vc') ||
        lower.contains('quem e vc') ||
        lower.contains('qual seu nome') ||
        lower.contains('qual é o seu nome') ||
        lower.contains('qual e o seu nome') ||
        lower.contains('qual e seu nome') ||
        lower.contains('como vc se chama') ||
        lower.contains('como você se chama') ||
        lower.contains('quem é cesar') ||
        lower.contains('quem e cesar') ||
        lower.contains('quem é o cesar') ||
        lower.contains('quem e o cesar');

    if (isIdentityQuery) {
      stopwatch.stop();
      return FinancialTransactionDraft(
        intent: 'query',
        intentConfidence: 1.0,
        category: 'unknown',
        paymentMethod: 'unknown',
        amount: null,
        dateOffsetDays: 0,
        description: 'Apresentação',
        rawText: cleanText,
        latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
        isComplete: true,
        missingSlots: [],
        clarificationPrompt: 'Eu sou o César! Seu copiloto financeiro do Krezio.ai, 100% on-device. Posso registrar seus gastos, receitas, agendar lembretes de empréstimos, dividendos e muito mais. O que você gostaria de lançar agora?',
      );
    }

    // Saudação direta ao César (ex: "oi cesar", "cesar", "olá cesar", "fala cesar", "e ai cesar")
    final isCesarGreeting = RegExp(r'^(?:oi|ol[áa]|fala|opa|e\s+a[íi]|ei|ow)?\s*c[eé]sa+r\s*[,:!?-]*$', caseSensitive: false).hasMatch(cleanText);
    if (isCesarGreeting) {
      stopwatch.stop();
      return FinancialTransactionDraft(
        intent: 'unknown',
        intentConfidence: 1.0,
        category: 'unknown',
        paymentMethod: 'unknown',
        amount: null,
        dateOffsetDays: 0,
        description: 'Saudação',
        rawText: cleanText,
        latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
        isComplete: false,
        missingSlots: [],
        clarificationPrompt: 'Oi! Sou o César. Como posso ajudar com suas finanças agora?',
      );
    }

    // 1. Bank SMS & Notification Handler
    final bankDraft = _parseBankNotification(cleanText);
    if (bankDraft != null) {
      stopwatch.stop();
      return bankDraft;
    }

    // 2. Prompt Injection & Non-Financial System Noise Guard
    final systemKeywords = ['system override', 'status code', 'ignore todas', 'abcdefg'];
    if (systemKeywords.any((w) => lower.contains(w))) {
      stopwatch.stop();
      return FinancialTransactionDraft(
        intent: 'unknown',
        intentConfidence: 1.0,
        category: 'unknown',
        paymentMethod: 'unknown',
        amount: null,
        dateOffsetDays: 0,
        description: cleanText,
        rawText: cleanText,
        latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
        isComplete: false,
        missingSlots: [],
        clarificationPrompt: 'Eu sou o César! Como posso te ajudar com suas finanças hoje?',
      );
    }

    final vector = _extractTfIdfVector(normText);
    final intentResult = _predictWithConfidence(_intentModel, vector);
    final categoryResult = _predictWithConfidence(_categoryModel, vector);
    final paymentResult = _predictWithConfidence(_paymentModel, vector);
    // Spoken numbers as digits ("dois boletos de cento e cinquenta").
    final numLower = PtNumberWords.normalize(lower);
    final quantityPricing = _parseQuantityTimesPrice(numLower);
    // "50 reais o dia durante 10 dias": the amount is the daily rate, and the
    // draft carries how many daily expenses to record.
    final dailyRate = _parseDailyRate(numLower);
    final amount = dailyRate?.rate ?? quantityPricing?.total ?? _parseAmount(normText) ?? _amountByRole(normText, numLower);
    // With the "3 x 15" span removed, so a multiplication isn't mistaken for
    // "3x" installments on the credit card.
    final paymentText = quantityPricing == null
        ? cleanText
        : numLower.replaceFirst(quantityPricing.matchedText, ' ');
    final description = _extractDescription(cleanText, categoryResult.label);
    final recurrence = _parseRecurrence(normText);
    // A recurring due day ("todo dia 10") is not the date of the entry.
    // …unless it was said bare after the user's own past verb: "paguei a
    // netflix de 55 dia 12" was paid on the 12th (ACC-A-012) — the renewal
    // day may be the same, but the entry is not today's.
    final dayIsDueDay = recurrence['due_day'] != null &&
        !(recurrence['bare_day'] == true && _firstPersonEntryVerb.hasMatch(CategoryNameMatcher.foldAccents(lower)));
    // Date words inside a proper name ("no Bar Dia 7") are not the date.
    // Without "se/caso" clauses, streets named after dates, and "hoje" when
    // another day is said too (CHAOS-B-002/003, ACC-B-005).
    final dateText = EntrySafetyGate.entryDateText(_normalizeText(withoutNameDates(cleanText)), skipDayNumber: dayIsDueDay);
    final dateOffsetDays = _parseDateOffset(dateText, skipDayNumber: dayIsDueDay);
    // "paguei 4 meses de mensalidade do clube de 90": N months paid at once is
    // one payment of N × V, not a new monthly subscription to set up.
    final prepaidMonths = quantityPricing != null && RegExp(r'\bmes(?:es)?\b').hasMatch(quantityPricing.matchedText);
    if (prepaidMonths) {
      recurrence['is_recurrent'] = false;
      recurrence['due_day'] = null;
      recurrence['due_business_day'] = null;
      recurrence['recurrence_duration'] = null;
    }

    var resolvedIntent = intentResult.label;

    // Financial keywords set
    final financialKeywords = [
      'gastei', 'gasto', 'gastos', 'paguei', 'pagar', 'pagamento', 'comprei', 'compra', 'compras',
      'gastando', 'gastou', 'pagando', 'pagou', 'comprando', 'larguei', 'torrei', 'desembolsei',
      'caiu', 'recebi', 'receita', 'receitas', 'mandei', 'transferi', 'pix', 'transferencia', 'transferência',
      'saldo', 'sobrou', 'orçamento', 'orcamento', 'despesa', 'despesas', 'extrato', 'fatura', 'limite',
      'mercado', 'supermercado', 'uber', 'gasolina', 'farmacia', 'remédios', 'ifood', 'luz', 'agua', 'internet',
      'aluguel', 'salario', 'salário', 'reembolso', 'freela', 'pila', 'pilas', 'conto', 'contos', 'reais', 'dinheiro', 'cartao', 'cartão',
      'vintao', 'vintão', 'dezao', 'dezão', 'cinquentao', 'cinquentão', 'cemzao', 'cemzão', 'duzentao', 'duzentão',
      'quinhentao', 'quinhentão', 'barao', 'barão', 'baroes', 'barões', 'pau', 'paus',
      'quarentinha', 'cinquentinha', 'trintinha', 'vintinha', 'quinzenha', 'quinzinha', 'dezinha', 'cinquinha', 'cemzinho',
      'derreal', 'deisreal', 'doirreal', 'doisreal', 'umreal', 'cincreal', 'cincoreal', 'vintireal', 'vinti real', 'vintireais', 'vinti reais',
      'trintareal', 'quarentareal', 'cinquentareal', 'cemreal', 'milreal',
      'mcdonalds', 'mcdonald', 'mc', 'burger king', 'bk', 'outback', 'subway', 'starbucks', 'habibs', 'ragazzo',
      'spoleto', 'dominos', 'pizza hut', 'cacau show', 'kopenhagen', 'dengo', 'bobs', 'giraffas', 'madero', 'jeronimo', 'bacio di latte',
      'vivara', 'zara', 'renner', 'c&a', 'riachuelo', 'h&m', 'marisa', 'hering', 'reserva', 'lacoste', 'calvin klein',
      'pandora', 'swarovski', 'sephora', 'boticario', 'boticário', 'natura', 'avon', 'centauro', 'decathlon', 'nike',
      'adidas', 'puma', 'asics', 'mizuno', 'vans', 'havaianas', 'arezzo', 'schutz', 'melissa', 'amazon', 'mercado livre',
      'mercadolivre', 'shopee', 'shein', 'aliexpress', 'magalu', 'casas bahia', 'ponto frio', 'fast shop', 'kabum',
      'terabyte', 'pichau', 'americanas', 'apple', 'iphone', 'samsung', 'xiaomi', 'dell', 'nintendo', 'playstation', 'xbox', 'steam',
      'carrefour', 'pão de açúcar', 'pao de acucar', 'extra', 'assai', 'assaí', 'atacadao', 'atacadão', 'sams club',
      'droga raia', 'drogasil', 'pague menos', 'extrafarma', 'panvel', 'pacheco', 'smart fit', 'smartfit', 'bluefit',
      'cobasi', 'petz', 'unimed', 'enel', 'sabesp', 'claro', 'vivo', 'tim', 'latam', 'gol', 'azul',
      'leroy merlin', 'telhanorte', 'tok&stok', 'alura', 'udemy', 'estacio', 'puc',
      'assinei', 'assinei o', 'assinei a', 'assinar', 'assinatura', 'assinaturas', 'mensalidade',
      'renovei', 'renovei o', 'renovei a', 'renovar', 'renovação', 'renovacao',
      'contratei', 'contratei o', 'contratei a', 'contratar',
      'recarreguei', 'recarga', 'recargas', 'coloquei crédito', 'coloquei credito',
      'plano de celular', 'plano celular', 'plano móvel', 'plano movel', 'plano controle', 'plano de internet',
      'claro flex', 'vivo easy', 'tim beta', 'tim controle', 'claro controle', 'vivo controle',
      'spotify', 'netflix', 'amazon prime', 'prime video', 'disney plus', 'disney+', 'hbo max', 'globoplay',
      'deezer', 'apple tv', 'paramount', 'paramount+', 'star+', 'star plus', 'crunchyroll', 'youtube premium',
      'game pass', 'gamepass', 'psn', 'ps plus', 'gympass', 'wellhub', 'totalpass',
      'claude code', 'claude', 'chatgpt', 'chat gpt', 'openai', 'anthropic', 'gemini', 'copilot', 'perplexity',
      'deepseek', 'midjourney', 'cursor', 'duolingo', 'cambly', 'open english', 'descomplica', 'rocketseat',
      'violão', 'violao', 'guitarra', 'bateria', 'piano',
      'emprestei', 'emprestar', 'deve', 'me paga', 'cobrar', 'dividendo', 'dividendos', 'proventos'
    ];

    bool hasFinKw = financialKeywords.any((k) => lower.contains(k));
    if (lower.startsWith('como ') || lower.startsWith('que horas') || lower.startsWith('o dia ') || lower.startsWith('qual a capital')) {
      hasFinKw = false;
    }

    // Report query detection using FinancialReportRagEngine
    final isReport = FinancialReportRagEngine.isReportQuery(normText) || FinancialReportRagEngine.isReportQuery(cleanText);
    String? reportType;
    if (isReport) {
      resolvedIntent = 'query';
      if (lower.contains('devendo') || lower.contains('deve') || lower.contains('cobrar') || lower.contains('pagar')) {
        reportType = 'debtors';
      } else if (lower.contains('gastei') || lower.contains('gasto') || lower.contains('despesa')) {
        reportType = 'spending';
      } else if (lower.contains('boleto') || lower.contains('conta') || lower.contains('vencer')) {
        reportType = 'bills';
      } else {
        reportType = 'overview';
      }
    } else if (lower.startsWith('quanto ') || lower.startsWith('quantos ') || lower.startsWith('quantas ') || lower.startsWith('qual ') || lower.startsWith('como estão ') || lower.startsWith('mostre ')) {
      if (hasFinKw) {
        resolvedIntent = 'query';
      } else {
        resolvedIntent = 'unknown';
      }
    }

    if (lower.startsWith('gastei') || lower.startsWith('comprei') || lower.startsWith('paguei') || lower.startsWith('abasteci') ||
        lower.startsWith('assinei') || lower.startsWith('pedi ') || lower.startsWith('almocei') || lower.startsWith('jantei') || lower.startsWith('lanchei') ||
        lower.startsWith('renovei') || lower.startsWith('contratei') || lower.startsWith('recarreguei')) {
      resolvedIntent = 'expense';
    }

    if (lower.contains('uber ') || lower.startsWith('uber') || lower.contains('gasolina') || lower.contains('abasteci') || lower.contains('posto ')) {
      if (resolvedIntent != 'query') resolvedIntent = 'expense';
    }

    // ── LEMBRETES INTELIGENTES, EMPRÉSTIMOS A RECEBER & DIVIDENDOS ──
    final isLoan = !isReport &&
        (lower.contains('emprestei') ||
            lower.contains('emprestar') ||
            lower.contains('enprestei') ||
            lower.contains('imprestei') ||
            lower.contains('inprestei') ||
            lower.contains('me deve') ||
            lower.contains('vai me pagar') ||
            lower.contains('vai me acertar') ||
            lower.contains('vai me devolver') ||
            lower.contains('ele me paga') ||
            lower.contains('ela me paga') ||
            lower.contains('ele me devolve') ||
            lower.contains('ela me devolve') ||
            lower.contains('prometeu pagar') ||
            lower.contains('prometeu me pagar') ||
            lower.contains('prometeu acertar') ||
            lower.contains('prometeu devolver'));

    final mentionsSalaryOrPayment = lower.contains('salário') ||
        lower.contains('salario') ||
        lower.contains('pagamento') ||
        lower.contains('holerite') ||
        lower.contains('pro-labore') ||
        lower.contains('pró-labore');

    final mentionsDebtorPaydayTrigger = (mentionsSalaryOrPayment &&
            (lower.contains('cair') ||
                lower.contains('cai') ||
                lower.contains('sair') ||
                lower.contains('sai') ||
                lower.contains('receber') ||
                lower.contains('recebe') ||
                lower.contains('dele') ||
                lower.contains('dela') ||
                lower.contains('dia do') ||
                lower.contains('quando') ||
                lower.contains('qdo') ||
                lower.contains('qndo'))) ||
        lower.contains('quando ele receber') ||
        lower.contains('quando ela receber') ||
        lower.contains('quando ele tiver') ||
        lower.contains('quando ela tiver') ||
        lower.contains('qdo receber') ||
        lower.contains('qndo receber');

    final isSalaryPaydayHeuristic = isLoan && mentionsDebtorPaydayTrigger;

    final isDividend = !isReport &&
        (lower.contains('dividendo') ||
            lower.contains('dividendos') ||
            lower.contains('dividento') ||
            lower.contains('dividentos') ||
            lower.contains('divendo') ||
            lower.contains('divendos') ||
            lower.contains('provento') ||
            lower.contains('proventos') ||
            lower.contains('rendimentos da bolsa') ||
            lower.contains('rendimento fii') ||
            lower.contains('rendimentos fii') ||
            lower.contains('jcp') ||
            lower.contains('juros sobre capital'));

    bool isReminder = false;
    String? reminderType;
    String? personName;
    DateTime? targetReminderDate;
    String? calendarConsultationNote;
    int? resolvedDueDay = recurrence['due_day'] as int?;

    if (isLoan) {
      isReminder = true;
      reminderType = 'loan_receivable';
      personName = _extractPersonName(cleanText);
      resolvedIntent = 'transfer';
      if (isSalaryPaydayHeuristic) {
        final payday = calendarService.getNextSalaryPayday();
        targetReminderDate = payday;
        resolvedDueDay = payday.day;
        final dateLabel = RealtimeCalendarService.formatDateLabel(payday);
        calendarConsultationNote = '5º dia útil bancário consultado no calendário em tempo real: $dateLabel';
      }
    } else if (isDividend && (lower.contains('lembr') || lower.contains('aviso') || lower.contains('quando') || lower.contains('cai') || lower.contains('dia') || lower.contains('receber'))) {
      isReminder = true;
      reminderType = 'dividend';
      resolvedIntent = 'income';
      final now = DateTime.now();
      targetReminderDate = DateTime(now.year, now.month, 15);
      resolvedDueDay = 15;
      calendarConsultationNote = 'Data Com / Pagamento de Dividendos consultada no calendário em tempo real: dia 15';
    }

    final hasIncomeKeywords = lower.contains('salario') ||
        lower.contains('salário') ||
        lower.contains('pró-labore') ||
        lower.contains('pro-labore') ||
        lower.contains('meu pagamento') ||
        lower.contains('minha renda') ||
        lower.contains('recebo meu') ||
        lower.contains('recebi meu') ||
        lower.contains('caiu meu') ||
        lower.contains('cai meu') ||
        lower.contains('salario cai') ||
        lower.contains('salário cai') ||
        (lower.contains('cai') && (lower.contains('salario') || lower.contains('salário'))) ||
        (lower.contains('recebo') && (lower.contains('dia') || lower.contains('mês') || lower.contains('mes'))) ||
        (lower.contains('cai') && lower.contains('dia') && !lower.contains('fatura') && !lower.contains('vence')) ||
        lower.startsWith('recebi') ||
        lower.startsWith('recebo') ||
        lower.startsWith('ganhei') ||
        lower.startsWith('faturei') ||
        _mentionsMoneyComingIn(lower) ||
        // "me reembolsaram 60 do almoço", "a maria me devolveu 50"
        RegExp(r'\bme\s+(?:reembols\w+|devolveu|devolveram|pagou|pagaram|transferiu|transferiram|mandou|mandaram)\b|\bfui\s+reembolsad[oa]\b')
            .hasMatch(lower);

    if (isReminder && reminderType == 'loan_receivable') {
      // Intent already established as transfer
    } else if (hasIncomeKeywords && !lower.startsWith('quanto') && !lower.startsWith('qual') && !lower.startsWith('como estão')) {
      resolvedIntent = 'income';
    } else if ((resolvedIntent == 'query' || resolvedIntent == 'unknown' || resolvedIntent == 'transfer') && amount != null && amount > 0 && hasFinKw) {
      if (lower.contains('caiu') || lower.contains('recebi') || lower.contains('me mandou') || lower.contains('me transferiu')) {
        resolvedIntent = 'income';
      } else if (lower.contains('mandei') || lower.contains('transferi para') || lower.contains('transferi pra')) {
        resolvedIntent = 'transfer';
      } else if (!lower.contains('transferi') && !lower.contains('mandei')) {
        resolvedIntent = 'expense';
      }
    } else if (!hasFinKw && amount == null) {
      // "vendi umas roupas no brechó", "almocei no restaurante por quilo":
      // the user's own money verb tells an entry even before the value is
      // said — César asks the value instead of "não consegui identificar"
      // (ACC-B-015).
      resolvedIntent = _valuelessEntryIntent(cleanText) ?? 'unknown';
    }

    // Money going out that the classifier read otherwise: "Efetuei um
    // pagamento de R$ 1.250,90 referente ao aluguel" (was saved as income),
    // "larguei 200 na balada", "dei 20 pro flanelinha", "rachei a conta do
    // bar, deu 45 pra mim" (was a transfer).
    if (!isReminder && !isReport) {
      if (_isOwnAccountTransfer(lower)) {
        resolvedIntent = 'transfer';
      } else if (_isPayingOut(lower)) {
        resolvedIntent = 'expense';
      }
    }

    // Who pays whom decides the type (R2-CONV-002/003/017): the user paying
    // (paguei, o pagamento da taxa, saiu da minha conta) is an expense; money
    // given/paid/deposited to the user (me deu, o chefe pagou 180, ganhei,
    // "registre uma receita") is income. Both at once → ask, never guess.
    var askType = false;
    // (The classifier's "query" doesn't stop it when the sentence tells an
    // amount with no question word: "bati 300 de gorjeta essa semana".)
    final asksSomething = RegExp(r'^(?:quanto|quantos|quantas|qual|quais|como|quando|onde|quem|cade|o\s+que|mostr|list|ver\b)')
        .hasMatch(CategoryNameMatcher.foldAccents(lower.trim()));
    if (!isReminder && !isReport && amount != null && amount > 0 && !cleanText.trim().endsWith('?') &&
        (resolvedIntent != 'query' || !asksSomething) && !_isOwnAccountTransfer(lower)) {
      switch (MoneyDirectionDetector.detect(normText)) {
        case MoneyDirection.outgoing:
          if (resolvedIntent == 'income' || resolvedIntent == 'unknown') resolvedIntent = 'expense';
        case MoneyDirection.incoming:
          if (_employeeBeingPaid(lower) == null) resolvedIntent = 'income';
        case MoneyDirection.unclear:
          // A verb nobody knows the direction of ("levantei 2000", "catei
          // 70"): ask "entrou ou saiu?" instead of letting the classifier
          // record it in silence (ACC-A-001/011) — unless the classifier is
          // sure it's a purchase *and* the sentence names what was bought
          // ("derreti 180 no rodízio", "catei um uber de 21").
          final surePurchase = resolvedIntent == 'expense' && intentResult.confidence >= 0.6 && _hasCategoryNoun(normText);
          if (!surePurchase) {
            askType = true;
            if (resolvedIntent == 'unknown') resolvedIntent = 'expense';
          }
        case MoneyDirection.conflict:
          askType = true;
          if (resolvedIntent == 'unknown') resolvedIntent = 'expense';
        case MoneyDirection.unknown:
          break;
      }
    }

    // A value with a verb nobody classified and no side said ("acertamos
    // 400 do carro eu e o lucas", "mexemo 200 lá com o tio do bar"): César
    // asks "R$ N entrou ou saiu?" keeping the value, instead of "gasto ou
    // receita, e qual o valor?", which lost it (ACC-C-015).
    if (!isReminder && !isReport && resolvedIntent == 'unknown' && amount != null && amount > 0 && !asksSomething &&
        !cleanText.trim().endsWith('?') && RegExp(r'\b[a-z]{3,}(?:ei|ou|amos|emo|aram|eram|eu|iu)\b').hasMatch(CategoryNameMatcher.foldAccents(lower))) {
      resolvedIntent = 'expense';
      askType = true;
    }

    if (!isReminder && !isReport && resolvedIntent == 'expense' && !askType && amount != null &&
        _barePixWithName.hasMatch(CategoryNameMatcher.foldAccents(lower.trim())) &&
        MoneyDirectionDetector.detect(normText) == MoneyDirection.unknown) {
      askType = true;
    }

    // A transfer is a move of money the words must say ("transferi",
    // "mandei", "pix pra", "TED", "depositei na poupança"). The classifier
    // also picks it for sentences that say nothing of the kind — "fiz um
    // corre de 90", "dei um dinheiro pro pedreiro" — and then it was saved
    // as a transfer in silence (ACC-C-004). Without such words, who pays
    // whom decides, or César asks "entrou ou saiu?" keeping the value.
    if (!isReminder && !isReport && resolvedIntent == 'transfer' && !_saysTransfer(lower)) {
      switch (MoneyDirectionDetector.detect(normText)) {
        case MoneyDirection.outgoing:
          resolvedIntent = 'expense';
        case MoneyDirection.incoming:
          resolvedIntent = 'income';
        default:
          resolvedIntent = 'expense';
          if (amount != null && amount > 0) askType = true;
      }
    }

    // Paying an employee ("paguei o salário do funcionário", "contratei uma
    // diarista, pago 1650 todo 5º dia útil") is an expense, even though
    // "salário" normally means money coming *in*. A hire is an ongoing
    // monthly cost with no end date, not a subscription with a plan length.
    final worker = (isReminder || isReport) ? null : _employeeBeingPaid(lower);
    final isPayroll = worker != null;
    if (isPayroll) {
      resolvedIntent = 'expense';
      if (dailyRate == null &&
          (lower.contains('contratei') || RegExp(r'\btod[oa]s?\b|\bmensal|\bpor m[eê]s\b|\bao m[eê]s\b').hasMatch(lower))) {
        recurrence['is_recurrent'] = true;
        recurrence['recurrence_duration'] ??= 'indeterminado';
      }
    }
    if (dailyRate != null) {
      // A fixed run of daily payments, not a monthly recurrence/subscription.
      if (resolvedIntent != 'income') resolvedIntent = 'expense';
      recurrence['is_recurrent'] = false;
      recurrence['due_day'] = null;
      recurrence['due_business_day'] = null;
      recurrence['recurrence_duration'] = null;
      resolvedDueDay = null;
    }

    // A new subscription/monthly fee with no end said ("assinei a netflix",
    // "mensalidade da faculdade") runs until cancelled: assume that instead
    // of asking, and say so. Only an explicit "anual"/"6 meses" changes it.
    String? assumptionNote;
    // ("todo dia 5" also defaulted it to "indeterminado" silently before.)
    final saidLength = RegExp(r'indeterminad|sem prazo|tem prazo|tem tempo|at[eé] cancelar|anual|semestral|trimestral|\d+\s*(?:meses|anos?)\b|um ano')
        .hasMatch(lower);
    if (dailyRate == null && !isPayroll && !isReminder && _isNewSubscriptionPhrase(lower) &&
        (recurrence['is_recurrent'] as bool? ?? false) && !saidLength) {
      recurrence['recurrence_duration'] ??= 'indeterminado';
      assumptionNote = openEndedAssumptionNote;
    }
    if (assumptionNote == null && dateOffsetDays < 0) assumptionNote = _gluedWeekdayNote(dateText, dateOffsetDays);
    assumptionNote ??= _weekendNote(dateText);

    // A user-created category named in the sentence wins over the model's
    // guess among the built-in ones (it can't know them).
    final customCategory = (resolvedIntent == 'expense' && !isReminder) ? matchCustomCategory(cleanText) : null;

    final hasCategoryNoun = _hasCategoryNoun(normText) || customCategory != null || isPayroll;
    var resolvedCategory = isReminder && reminderType == 'loan_receivable'
        ? 'expense_other'
        : (isReminder && reminderType == 'dividend' ? 'investment' : _resolveContextualCategory(lower, categoryResult.label));

    if (!hasCategoryNoun && resolvedCategory == 'unknown' && !isReminder) {
      resolvedCategory = 'unknown';
    }
    // An income can't carry an expense category ("entrada de 500" has no
    // category noun at all) — file it under generic income instead.
    if (resolvedIntent == 'income' && !const {'salary', 'income_other', 'investment'}.contains(resolvedCategory)) {
      resolvedCategory = 'income_other';
    }
    // …nor an expense an income one ("paguei 120 da matrícula" was filed
    // under "outras receitas" by the classifier).
    if (resolvedIntent == 'expense' && const {'salary', 'income_other'}.contains(resolvedCategory) && !isPayroll &&
        !_hasTerm(lower, 'salário') && !_hasTerm(lower, 'salario')) {
      resolvedCategory = 'unknown';
    }
    if (customCategory != null) {
      resolvedCategory = customCategory;
    } else if (isPayroll) {
      resolvedCategory = 'expense_other';
    }

    var resolvedPaymentMethod = _resolvePaymentMethod(paymentText, paymentResult.label);
    if (isReminder || (resolvedPaymentMethod == 'unknown' && resolvedIntent == 'income' && resolvedCategory == 'salary')) {
      if (resolvedPaymentMethod == 'unknown') {
        resolvedPaymentMethod = 'pix';
      }
    }
    int? resolvedInstallments = (resolvedPaymentMethod == 'credit_card' || _hasInstallmentKeyword(paymentText))
        ? _parseInstallments(paymentText)
        : null;

    String resolvedDescription = description;
    if (prepaidMonths) {
      // "Meses" is not a name: use what the months were of ("Curso de inglês").
      final what = RegExp(r'\bmes(?:es)?\s+d[eoa]s?\s+([a-zà-úç]+(?:\s+d[eoa]s?\s+[a-zà-úç]+)?)').firstMatch(numLower);
      if (what != null) {
        final t = what.group(1)!;
        resolvedDescription = '${t[0].toUpperCase()}${t.substring(1)} (${quantityPricing.quantity} meses)';
      }
    }
    if (isReminder && reminderType == 'loan_receivable') {
      resolvedDescription = (personName != null && personName.isNotEmpty)
          ? 'Cobrar $personName (Empréstimo)'
          : 'Cobrar Empréstimo';
    } else if (isReminder && reminderType == 'dividend') {
      final tickerMatch = RegExp(r'\b([a-zA-Z]{4}\s*\d{1,2})\b').firstMatch(cleanText);
      final ticker = tickerMatch != null ? tickerMatch.group(1)!.replaceAll(' ', '').toUpperCase() : null;
      resolvedDescription = ticker != null ? 'Receber Dividendos $ticker' : 'Receber Dividendos';
    } else if (isPayroll) {
      resolvedDescription = dailyRate != null
          ? 'Diária de $worker'
          : (worker.startsWith('funcion') ? 'Salário de funcionário' : 'Pagamento de $worker');
    }

    final isSubscription = recurrence['is_recurrent'] as bool? ?? false;
    final isAnnualSubscription = isSubscription &&
        (recurrence['recurrence_duration'] == 'anual' ||
            lower.contains('anual') ||
            lower.contains('12 meses') ||
            lower.contains('1 ano') ||
            lower.contains('um ano') ||
            lower.contains('plano anual'));

    // Evaluate Slot Completeness strictly: NEVER flag a slot as missing if it was already identified!
    final missingSlots = <String>[];
    if (askType) missingSlots.add('type');
    if (resolvedIntent == 'expense' || resolvedIntent == 'income' || resolvedIntent == 'transfer') {
      if (amount == null || amount <= 0) {
        missingSlots.add('amount');
      }
      
      final isCategoryIdentified = (hasCategoryNoun && resolvedCategory != 'unknown') || (isReminder && reminderType == 'loan_receivable');
      if (!isCategoryIdentified && resolvedIntent == 'expense') {
        missingSlots.add('category');
      }
      
      final isPaymentIdentified = resolvedPaymentMethod != 'unknown' || (isReminder && reminderType == 'loan_receivable');
      if (!isPaymentIdentified) {
        missingSlots.add('payment_method');
      }

      // For credit card expenses, check if installments were clarified.
      // Business Rule: Monthly/indefinite subscriptions paid on credit card are NOT installment-based (single recurring monthly charge, installments = 1).
      // Only annual subscriptions (or regular credit purchases) can be paid in installments!
      if (resolvedIntent == 'expense' && resolvedPaymentMethod == 'credit_card' && resolvedInstallments == null) {
        if (isSubscription && !isAnnualSubscription) {
          resolvedInstallments = 1;
        } else {
          missingSlots.add('installments');
        }
      }

      // For new subscriptions formulation, track due_day and recurrence_duration
      final isNewSubscription = _isNewSubscriptionPhrase(lower) && !prepaidMonths;
      if (dailyRate != null) {
        // Nothing to ask: the day count and rate are both known.
      } else if (isPayroll) {
        if ((recurrence['is_recurrent'] as bool? ?? false) && resolvedDueDay == null) {
          missingSlots.add('due_day');
        }
      } else if (isNewSubscription) {
        if (recurrence['due_day'] == null) {
          missingSlots.add('due_day');
        }
        if (recurrence['recurrence_duration'] == null) {
          missingSlots.add('recurrence_duration');
        }
      }
    }

    if (isReport) {
      missingSlots.clear();
    }

    // No category word in the sentence: the classifier's guess is not kept
    // (R2-CONV-013: "25 no lava-jato" went out as "saúde / farmácia", and an
    // answer César didn't understand then saved it there). Name the entry
    // after what was said instead of the guessed category's label.
    if (missingSlots.contains('category') && customCategory == null) {
      resolvedCategory = 'unknown';
      if (resolvedDescription == description) resolvedDescription = _extractDescription(cleanText, 'unknown');
    }

    // Two payment methods, "gastei e recebi", a day that doesn't exist or a
    // date in the future: ask instead of picking one in silence (CHAOS-017).
    String? contradictionPrompt;
    if (!isReport && !isReminder && const {'expense', 'income', 'transfer'}.contains(resolvedIntent)) {
      final c = detectContradiction(lower);
      if (c != null) {
        contradictionPrompt = c.question(amount);
        switch (c.kind) {
          case ContradictionKind.payment:
            resolvedPaymentMethod = 'unknown';
            resolvedInstallments = null;
            missingSlots.remove('installments');
            if (!missingSlots.contains('payment_method')) missingSlots.add('payment_method');
          case ContradictionKind.direction:
            // Nothing can be recorded until the user says which one it was.
            resolvedIntent = 'unknown';
          case ContradictionKind.date:
            missingSlots.add('date');
        }
      }
    }

    // A date that can't be recorded as said: ask (CHAOS-R3-002).
    if (contradictionPrompt == null && !isReport && !isReminder && const {'expense', 'income', 'transfer'}.contains(resolvedIntent)) {
      final q = _dateQuestion(dateText, amount, skipDayNumber: dayIsDueDay);
      if (q != null) {
        contradictionPrompt = q;
        missingSlots.add('date');
      }
    }

    // Two or more money values but only one entry (CONV-R3-002) is asked by
    // [EntrySafetyGate] (see [_guard]), for every path, not only here.

    final isComplete = isReport || ((resolvedIntent != 'unknown') && missingSlots.isEmpty);
    final clarificationPrompt = isComplete
        ? null
        : contradictionPrompt ?? (askType ? typeQuestion(amount) : null) ?? _generateEmpatheticClarificationPrompt(
            intent: resolvedIntent,
            amount: amount,
            category: resolvedCategory,
            paymentMethod: resolvedPaymentMethod,
            description: resolvedDescription,
            missingSlots: missingSlots,
            rawText: cleanText,
            isRecurrent: recurrence['is_recurrent'] as bool? ?? false,
            dueDay: resolvedDueDay,
            recurrenceDuration: recurrence['recurrence_duration'] as String?,
            isReminder: isReminder,
            reminderType: reminderType,
            personName: personName,
            targetDate: targetReminderDate,
            calendarConsultationNote: calendarConsultationNote,
            assumptionNote: assumptionNote,
          );

    final insight = isComplete
        ? _generateBudgetInsight(resolvedIntent, resolvedCategory, amount, recurrence['is_recurrent'] as bool? ?? false)
        : null;
    final breakdown = dailyRate?.breakdown ?? quantityPricing?.breakdown;
    final budgetInsight = (isComplete && breakdown != null)
        ? [breakdown, if (insight != null) insight].join('\n')
        : insight;

    stopwatch.stop();

    return FinancialTransactionDraft(
      intent: resolvedIntent,
      intentConfidence: intentResult.confidence,
      category: resolvedCategory,
      paymentMethod: resolvedPaymentMethod,
      amount: amount,
      dateOffsetDays: dateOffsetDays,
      description: resolvedDescription,
      rawText: cleanText,
      latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
      isComplete: isComplete,
      missingSlots: missingSlots,
      clarificationPrompt: clarificationPrompt,
      installments: resolvedInstallments,
      isRecurrent: recurrence['is_recurrent'] as bool? ?? false,
      dueDay: resolvedDueDay,
      dueBusinessDay: isReminder ? null : recurrence['due_business_day'] as int?,
      repeatDays: dailyRate?.days,
      billingDay: recurrence['billing_day'] as int?,
      paymentMarginDays: recurrence['payment_margin_days'] as int?,
      isReportQuery: isReport,
      reportType: reportType,
      frequency: recurrence['frequency'] as String?,
      recurrenceDuration: recurrence['recurrence_duration'] as String?,
      budgetInsight: budgetInsight,
      isReminder: isReminder,
      reminderType: reminderType,
      personName: personName,
      targetDate: targetReminderDate,
      calendarConsultationNote: calendarConsultationNote,
      assumptionNote: assumptionNote,
    );
  }

  /// Money values in [numLower] (spoken numbers already digits) other than
  /// [chosen]: numbers that aren't dates, times, counts, installments,
  /// measures or part of a name ("s23"), nor context after a descriptive
  /// verb ("a conta deu 350"), and that read as a value — a money cue before
  /// them, or an item after them ("30 na farmácia", "80 de água").
  static List<double> otherMoneyValues(String numLower, double chosen) {
    final lower = CategoryNameMatcher.foldAccents(numLower.toLowerCase());
    final out = <double>[];
    // The same value said twice is two values ("gastei 50 no mercado 50 na
    // farmácia", CHAOS-A-006): only one occurrence is the chosen one.
    var chosenSeen = false;
    for (final m in _amountCandidatePattern.allMatches(lower)) {
      final raw = m.group(1)!;
      final value = cleanAndParseAmount(raw);
      if (value == null || value <= 0) continue;
      if (!chosenSeen && (value - chosen).abs() < 0.005) {
        chosenSeen = true;
        continue;
      }
      final before = lower.substring(0, m.start);
      final after = lower.substring(m.end);
      // "2k"/"1,5k" is one value; "s23" is part of a name; the "08" of "31/08" is a month.
      if (RegExp(r'[a-z]$|\d\s*/\s*$').hasMatch(before) || RegExp(r'^\s*k\b').hasMatch(after) || _isNonValueNumber(raw, before, after)) {
        continue;
      }
      if (RegExp(r'\b(?:deu|daria|cobriu|cobre|era|eram|seria|custava|veio|vinha|ficou|devia|valia|reembolsou|descontou|abateu|'
              r'sobrou|sobraram|faltou|faltaram|troco|limite|saldo|meta|orcamento|tinha|tenho)\s+(?:(?:so|uns|de|r\$)\s*)*$')
              .hasMatch(before) ||
          // "mais de 50", "menos que 30" compare; a bare "e mais 23 na
          // padaria" is one more value (CHAOS-B-007).
          RegExp(r'\b(?:mais|menos)\s+(?:de|do\s+que|que)\s+(?:(?:so|uns|r\$)\s*)*$').hasMatch(before)) {
        continue;
      }
      final itemAfter = RegExp(r'^\s*(?:reais|real|conto|contos|pila|pilas)?(?:\s+(?:hoje|ontem|anteontem))?\s+(?:de|do|da|no|na|em|pro|pra|com|pelo|pela)\s+[a-z]')
          .hasMatch(after);
      final cue = _valueCueScore(before, after);
      // A number that names a place ("o mercado da rua 7", "pro terminal 2",
      // "no bloco 4"): no money cue, right after a noun that is not something
      // bought, and nothing but the payment/date after it (ACC-A-014).
      if (cue <= 0 && _isPlaceNumber(before, after)) continue;
      if (cue > 0 || itemAfter) out.add(value);
    }
    return out;
  }

  static final RegExp _nounBeforeNumber =
      RegExp(r'\b(?:o|a|os|as|do|da|dos|das|de|no|na|nos|nas|pro|pra|para|ao|ate|num|numa)\s+([a-z]{2,})\s*$');
  static final RegExp _onlyPaymentOrDateAfter = RegExp(
      r'^\s*(?:[,.;!]|$|(?:(?:no|na|em|via|pelo|pela|tudo\s+no)\s+)?(?:pix|credito|debito|dinheiro|boleto|cartao|especie)\b|'
      r'(?:hoje|ontem|anteontem)\b|(?:dia|em)\s+\d)');

  /// Whether a bare number is the number of a place ("rua 9", "quadra 4",
  /// "piso 2"): after a non-purchasable noun introduced by an article or
  /// preposition, with only the payment, a date or the end after it.
  static bool _isPlaceNumber(String before, String after) {
    final noun = _nounBeforeNumber.firstMatch(before)?.group(1);
    if (noun == null || _moneyContextWords.contains(noun)) return false;
    if (!_onlyPaymentOrDateAfter.hasMatch(after)) return false;
    return _resolveContextualCategory(noun, 'unknown') == 'unknown';
  }

  /// Asked when one sentence carries several values and César can't split it.
  static String splitQuestion(List<double> values) {
    final shown = values.take(3).map(QuantityPricing._brl).join(' e ');
    return 'Vi mais de um valor nessa frase ($shown) e não quero registrar errado. '
        'Se são gastos separados, me mande um de cada vez (ex.: "gastei 30 na farmácia no pix"); '
        'se é um lançamento só, me diga qual é o valor certo.';
  }

  /// Said before the reply when a brand-new sentence replaces a draft César
  /// was still asking about ("gastei 50" ⏎ "comprei uma blusa de 500 no
  /// pix") — the old one is dropped, and the user must know it wasn't saved.
  static String discardedDraftNotice(FinancialTransactionDraft pending) {
    final amount = pending.amount;
    final what = amount != null && amount > 0
        ? 'o lançamento anterior de ${QuantityPricing._brl(amount)}'
        : 'o lançamento anterior';
    return 'Deixei de lado $what, que ainda estava incompleto — ele não foi registrado.';
  }

  static const _methodWords = r'(pix|credito|crédito|debito|débito|dinheiro|boleto)';
  static final RegExp _twoMethods = RegExp(
    r'\b(?:no|na|em|via|pelo|pela)\s+' + _methodWords + r'\s+(?:e|ou)\s+(?:(?:no|na|em|via|pelo|pela)\s+)?(?:cart[aã]o\s+de\s+)?' + _methodWords + r'\b',
  );
  static final RegExp _bothDirections = RegExp(
    r'\b(?:gastei|paguei|comprei)\s+(?:e|ou)\s+(?:recebi|ganhei)\b|\b(?:recebi|ganhei)\s+(?:e|ou)\s+(?:gastei|paguei|comprei)\b',
  );
  static final RegExp _dayNumber = RegExp(r'\bdia\s+(\d{1,4})\b');
  static final RegExp _daysAgo = RegExp(r'\bh[aá]\s+(\d{1,7})\s+dias?\b');
  static final RegExp _futureYear = RegExp(r'\bano\s+que\s+vem\b|\bpr[oó]ximo\s+ano\b|\bano\s+seguinte\b');

  static String _methodKey(String w) => CategoryNameMatcher.foldAccents(w);

  /// A contradiction or impossible date in [lower] that César must ask about
  /// instead of resolving in silence, or null. Pure — see CHAOS-017.
  static Contradiction? detectContradiction(String lower) {
    final two = _twoMethods.firstMatch(lower);
    if (two != null && _methodKey(two.group(1)!) != _methodKey(two.group(2)!)) {
      return Contradiction(ContradictionKind.payment, '${_methodLabel(two.group(1)!)} e ${_methodLabel(two.group(2)!)}');
    }
    if (_bothDirections.hasMatch(lower)) return const Contradiction(ContradictionKind.direction, '');
    for (final m in _dayNumber.allMatches(lower)) {
      final n = int.parse(m.group(1)!);
      if (n < 1 || n > 31) return Contradiction(ContradictionKind.date, 'dia $n não existe');
    }
    final ago = _daysAgo.firstMatch(lower);
    if (ago != null && int.parse(ago.group(1)!) > 366) {
      return Contradiction(ContradictionKind.date, 'há ${ago.group(1)} dias é mais de um ano atrás');
    }
    if (_futureYear.hasMatch(lower)) return const Contradiction(ContradictionKind.date, 'essa data ainda não chegou');
    return null;
  }

  static String _methodLabel(String w) {
    switch (_methodKey(w)) {
      case 'pix':
        return 'Pix';
      case 'credito':
        return 'crédito';
      case 'debito':
        return 'débito';
      default:
        return _methodKey(w);
    }
  }

  /// Asked when the sentence says the money both came in and went out.
  static String typeQuestion(double? amount) {
    final value = amount != null && amount > 0 ? QuantityPricing._brl(amount) : 'esse valor';
    return 'Fiquei na dúvida: $value **entrou** pra você (receita) ou **saiu** do seu bolso (despesa)?';
  }

  static final RegExp _answerIncoming = RegExp(
    r'\b(?:entrou|entrada|receita|recebi|recebimento|ganhei|ganho|pra\s+mim|foi\s+pra\s+mim|me\s+(?:deu|deram|pagou|pagaram)|entrou\s+pra\s+mim)\b',
  );
  static final RegExp _answerOutgoing = RegExp(
    r'\b(?:saiu|saida|gasto|gastei|despesa|paguei|pagamento|eu\s+que\s+paguei|do\s+meu\s+bolso)\b',
  );

  /// The type named in an answer to [typeQuestion], or null.
  static String? typeFromAnswer(String answer) {
    final s = CategoryNameMatcher.foldAccents(answer.toLowerCase());
    final isIn = _answerIncoming.hasMatch(s), isOut = _answerOutgoing.hasMatch(s);
    if (isIn == isOut) return null;
    return isIn ? 'income' : 'expense';
  }

  /// What César says about a "someone owes me" reminder — asking the value
  /// ([amount] null) or confirming it. The payday date is only claimed when it
  /// was actually looked up ([targetDate]); before, a sentence without a date
  /// read "o 5º dia útil bancário cai no dia no 5º dia útil bancário"
  /// (R2-CONV-014).
  static String loanReminderText({String? personName, DateTime? targetDate, double? amount}) {
    final person = (personName != null && personName.isNotEmpty) ? 'o $personName' : 'essa pessoa';
    final when = targetDate != null
        ? 'Consultei o calendário em tempo real: o 5º dia útil bancário cai em ${RealtimeCalendarService.formatDateLabel(targetDate)}. '
        : '';
    if (amount == null || amount <= 0) {
      return 'Entendido! ${when}Vou agendar um lembrete para você cobrar $person${targetDate != null ? ' nessa data' : ''}. Qual foi o valor que você emprestou para ele?';
    }
    return 'Pronto! ${when}Agendei um lembrete para você cobrar $person sobre ${QuantityPricing._brl(amount)}${targetDate != null ? ' nessa data' : ''}. 🔔';
  }

  /// What César says when it assumed a subscription has no end date.
  static const openEndedAssumptionNote = 'Considerei sem prazo para terminar — se for plano anual, me avise.';

  /// "assinei", "assinar", "contratei", "mensalidade": a new recurring charge
  /// whose renewal day matters.
  static bool _isNewSubscriptionPhrase(String lower) =>
      lower.contains('assinei') || lower.contains('assinar') || lower.contains('contratei') || lower.contains('mensalidade');

  /// Parses multi-transaction inputs (e.g. "Gastei 150 no mercado no debito e 35 no uber no pix")
  List<FinancialTransactionDraft> parseMulti(String phrase) {
    // Spoken numbers become digits first, or "cinquenta e dois reais" would
    // be split at its "e" into two purchases.
    final clean = _withImplicitSeparators(PtNumberWords.normalize(phrase.trim()));

    // Items are separated by commas (not decimal numbers), semicolons,
    // conjunctions, "+", "/" between items (not "10/09"), "depois (no…)"
    // and "mais" — but "mais N" stays with its item: "depois na farmácia
    // mais 30" is one item (ACC-A-005/013).
    final separatorPattern = RegExp(
        r'\s*(?:,(?!\d)|;|\be\b|\balém\s+de\b|\balem\s+de\b|\bmais\b(?!\s+(?:r\$\s*)?\d)|\s\+\s*|\+\s*(?=[a-zà-úç])|\s/\s*|(?<=\d)\s*/\s*(?=[a-zà-úç])|'
        r'\bdepois\s+(?=(?:no|na|nos|nas|num|numa|em|mais|fui)\b|[a-z]{3,}ei\b)|'
        // "lanche 9,50 | refri 6", "…gasolina daí paguei 12 de
        // estacionamento" (ACC-B-009): "daí"/"aí" then another verb or place.
        r'\s*\|\s*|\b(?:da[ií]|a[ií]\s+depois|e\s+a[ií])\s+(?=(?:no|na|num|numa|em|fui|fomos)\b|[a-z]{3,}(?:ei|i)\b))\s*',
        caseSensitive: false);
    // "faz três dias: açougue: 260, padaria: 85", "ontem — pão 8, leite 6":
    // a date opening the list, before a colon/dash, is the date of every
    // item (the 7c left "Padaria R$ 260" three days ago and lost the 85).
    String? batchDate;
    var listBody = clean;
    final opening = RegExp(r'^\s*([^:]{2,40}?)\s*(?::|\s-\s|\s—\s)\s*').firstMatch(clean);
    if (opening != null) {
      final head = CategoryNameMatcher.foldAccents(opening.group(1)!.toLowerCase());
      if (_saysDate(_normalizeText(head)) && !_firstPersonEntryVerb.hasMatch(head) && _pickAmount(head, requireMoneyContext: false) == null) {
        batchDate = head;
        listBody = clean.substring(opening.end);
      }
    }
    // "açougue: 260" is "açougue 260".
    listBody = listBody.replaceAll(RegExp(r'(?<=[a-zA-ZÀ-ÿ])\s*:\s*(?=(?:r\$\s*)?\d)', caseSensitive: false), ' ');
    // "dentista 200 e remédio 37 ambos no débito": the closing "ambos no
    // débito"/"os dois ontem" is said of the whole batch — a piece of its
    // own, not part of the last item (ACC-C-003, the 37 vanished).
    listBody = listBody.replaceFirstMapped(
        RegExp(r'(?<=\d)\s*,?\s+((?:ambos|ambas|os\s+dois|as\s+duas|tudo|todos|todas)\b[^\d]*)$', caseSensitive: false), (m) => ', ${m.group(1)}');
    final rawSegments = listBody.split(separatorPattern).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

    // "tudo no débito", "no pix": the payment said once for the whole batch.
    String? batchPayment;
    // "…, tudo anteontem", "…, tudo no dia 21": the date said once for the
    // whole batch, as a piece of its own (CHAOS-B-008).
    // "fui na feira e gastei 35": a piece with no value that sets the scene
    // for the next piece's own verb goes with it (ACC-A-005).
    final segments = <String>[];
    String? carry;
    for (var i = 0; i < rawSegments.length; i++) {
      var seg = rawSegments[i];
      final f = CategoryNameMatcher.foldAccents(seg.toLowerCase());
      if (_paymentOnlyPiece.hasMatch(f)) {
        batchPayment = f;
        continue;
      }
      if (_batchDatePiece.hasMatch(f) && _pickAmount(f, requireMoneyContext: false) == null && _saysDate(_normalizeText(f))) {
        batchDate = f;
        continue;
      }
      if (carry != null) {
        seg = '$carry $seg';
        carry = null;
      }
      final nextHasOwnVerb = i + 1 < rawSegments.length &&
          RegExp(r'^\s*(?:(?:hoje|ontem|anteontem|eu)\s+)?[a-z]{3,}ei\b')
              .hasMatch(CategoryNameMatcher.foldAccents(rawSegments[i + 1].toLowerCase()));
      if (!RegExp(r'\d').hasMatch(f) && nextHasOwnVerb && !_firstPersonEntryVerb.hasMatch(f)) {
        carry = seg;
        continue;
      }
      segments.add(seg);
    }
    if (carry != null) segments.add(carry);

    // "a conta deu 350, o plano cobriu 200 e eu paguei 150 no débito": when
    // one piece has the user's own entry verb, a piece with another verb of
    // its own ("deu", "cobriu", "era", "custou") only gives context — its
    // number is not a purchase (R2-CONV-005). Its words stay (they may name
    // the category: "clínica"), its value goes.
    if (segments.length >= 2) {
      final folded = segments.map((p) => CategoryNameMatcher.foldAccents(p.toLowerCase())).toList();
      // Only when the user's own verb carries a value ("paguei 150 no
      // débito"), not a quantity ("comprei 2 cafés, deu 18 no total").
      final ownValue = RegExp('${_firstPersonEntryVerb.pattern}\\s+(?:r\\\$\\s*)?\\d[\\d.,]*(?:\\s*(?:reais|real|conto|contos|pila))?(?:\\s+(?:no|na|em|de|do|da|pro|pra|com|via)\\b|\\s*\$)');
      if (folded.any(ownValue.hasMatch)) {
        var rebuilt = false;
        final pieces = <String>[];
        for (var i = 0; i < segments.length; i++) {
          final isContext = !_firstPersonEntryVerb.hasMatch(folded[i]) && _contextVerb.hasMatch(folded[i]) && RegExp(r'\d').hasMatch(folded[i]);
          if (isContext) rebuilt = true;
          pieces.add(isContext ? segments[i].replaceAll(RegExp(r'(?:r\$\s*)?\d[\d.,]*\s*(?:reais|real|conto|contos|pila)?', caseSensitive: false), ' ') : segments[i]);
        }
        if (rebuilt) return parseMulti(pieces.join(', ').replaceAll(RegExp(r'\s+'), ' '));
      }
    }

    if (segments.length >= 2) {
      final drafts = <FinancialTransactionDraft>[];
      final sources = <String>[];
      // A verbless piece before a piece with its own verb is context ("moro
      // no apartamento 302 e paguei 450"), not an item of its own.
      final anyVerbPiece = segments.any((p) => _multiPieceVerb.hasMatch(CategoryNameMatcher.foldAccents(p.toLowerCase())));
      for (final seg in segments) {
        final segTrim = seg.trim();
        if (segTrim.isEmpty) continue;

        var draft = parse(segTrim);
        // "gastei 50 no mercado e 30 na farmácia", "recebi 300 do aluguel e
        // 200 de freela": a piece with no verb of its own shares the first
        // one's verb — whatever the classifier made of the bare piece (it
        // read "200 de freela" as having no value, and the 200 vanished).
        // Only a piece shaped like an item — a value and the name of what it
        // paid, in any order: "30 de calibragem", "leite por 6", "janta 48",
        // "um caderno de 20" (CONV-R3-002) — is one; "não 45", "é 1450", "mas
        // era pra ter gastado só 30" are comments on the first value.
        final foldedSeg = CategoryNameMatcher.foldAccents(segTrim.toLowerCase());
        final hasVerb = _multiPieceVerb.hasMatch(foldedSeg);
        if (!hasVerb || draft.amount == null) {
          final ownVerb = RegExp(r'^\s*[a-z]{3,}ei\s').hasMatch(foldedSeg);
          final item = (drafts.isEmpty && !hasVerb && anyVerbPiece && !ownVerb) ? null : _itemPiece(foldedSeg);
          if (item != null) {
            const verbFor = {'expense': 'gastei', 'income': 'recebi', 'transfer': 'transferi'};
            // A first piece with no known verb ("almoço 32 e janta 48",
            // "coloquei 100 de gasolina e…") is a purchase.
            final verb = drafts.isNotEmpty ? verbFor[drafts.first.intent] : (hasVerb ? null : 'gastei');
            if (verb != null) {
              final inherited = parse('$verb $item');
              if (inherited.amount != null) draft = inherited;
            }
          } else if (drafts.isNotEmpty && !hasVerb) {
            continue;
          }
        }
        if (const {'expense', 'income', 'transfer'}.contains(draft.intent) && draft.amount != null) {
          drafts.add(draft);
          sources.add(segTrim);
        }
      }

      if (drafts.length >= 2) {
        // Every money value of the sentence must be one of the items: a value
        // no item took was lost in silence (CHAOS-B-007). The sentence as a
        // whole then asks ([EntrySafetyGate]).
        if (EntrySafetyGate.unexplainedMoney(clean, [for (final d in drafts) d.amount!]).isNotEmpty) return [parse(phrase)];
        final dated = _shareDate(drafts, sources, batchDate: batchDate);
        if (dated == null) return [parse(phrase)];
        return _confirmBatchIfUnsure(_sharePaymentMethod(dated, batchPayment: batchPayment), phrase);
      }
    }

    return [parse(phrase)];
  }

  /// The items of a batch get the verb of the first one ("…e 30 na
  /// farmácia" → "gastei 30 na farmácia"), so their own words always look
  /// sure. Whether the batch happened is judged on the whole sentence
  /// ([EntryCertainty]): when it is unsure, every item waits for one
  /// "Registro assim?" (7e).
  List<FinancialTransactionDraft> _confirmBatchIfUnsure(List<FinancialTransactionDraft> drafts, String phrase) {
    if (EntryCertainty.read([phrase]).high) return drafts;
    return [
      for (final d in drafts)
        d.missingSlots.contains('confirm') || d.settledChecks.contains('certainty')
            ? d
            : d.copyWith(
                isComplete: false,
                missingSlots: [...d.missingSlots, 'confirm'],
                clarificationPrompt: d.missingSlots.isEmpty ? EntrySafetyGate.confirmQuestion(d) : d.clarificationPrompt,
              ),
    ];
  }

  /// "tudo ontem", "foi tudo no dia 21", "ambos anteontem": a date for the
  /// whole batch (checked to say a date and no value by the caller).
  static final RegExp _batchDatePiece =
      RegExp(r'^(?:e\s+)?(?:(?:foi|foram)\s+)?(?:tudo|todos?|todas?|ambos|ambas|os\s+dois|as\s+duas)\b(?:\s+(?:foi|foram))?\s+(?!(?:no|na|em|via|pelo|pela)\s+(?:pix|debito|credito|dinheiro|boleto|cartao)\b)');

  static final RegExp _paymentOnlyPiece = RegExp(
      r'^(?:(?:foi|foram|paguei|pago)\s+)?(?:tudo|todos?|todas?|ambos|os\s+dois|as\s+duas)?\s*(?:foi\s+|foram\s+)?(?:no|na|em|via|pelo|pela)?\s*'
      r'(?:pix|debito|credito(?:\s+a\s+vista)?|dinheiro|boleto|especie|cartao(?:\s+de\s+(?:debito|credito))?)[.!]?$');

  /// "ontem gastei 30 no mercado e 20 no cinema": the date said once (in
  /// any piece) is the date of every item that didn't say its own
  /// (CHAOS-A-009). Items with different dates keep each their own. Null
  /// when that date can't be recorded as said (ahead, a whole month): the
  /// caller then asks instead of splitting.
  List<FinancialTransactionDraft>? _shareDate(List<FinancialTransactionDraft> drafts, List<String> sources, {String? batchDate}) {
    if (batchDate != null && _dateQuestion(EntrySafetyGate.entryDateText(_normalizeText(batchDate)), null) != null) return null;
    final said = <int?>[];
    for (var i = 0; i < drafts.length; i++) {
      if (drafts[i].missingSlots.contains('date')) return null;
      final src = _normalizeText(withoutNameDates(sources[i]));
      if (!_saysDate(src)) {
        said.add(null);
        continue;
      }
      // An item rebuilt from its piece ("ontem: pedágio 9" → "gastei 9 de
      // pedágio", "30 hoje no mercado") lost the date words: read them from
      // the piece as said (ACC-A-005, CHAOS-A-009). A recurring due day
      // ("todo dia 5") keeps what [parse] made of it.
      final d = drafts[i];
      said.add(d.dueDay != null || d.dateOffsetDays != 0 ? d.dateOffsetDays : _parseDateOffset(src));
    }
    final distinct = said.whereType<int>().toSet();
    final shared = batchDate != null
        ? _parseDateOffset(EntrySafetyGate.entryDateText(_normalizeText(batchDate)))
        : (distinct.length == 1 ? distinct.first : null);
    return [
      for (var i = 0; i < drafts.length; i++)
        if (said[i] != null)
          drafts[i].copyWith(dateOffsetDays: said[i])
        else if (shared != null)
          drafts[i].copyWith(dateOffsetDays: shared)
        else
          drafts[i]
    ];
  }

  /// Inserts the separator the user left out between two items: "almoço 32
  /// janta 48" (a value, then another name with its value) and "gastei 50
  /// no mercado 50 na farmácia" (a value after a name, then what it paid) —
  /// without it both values became one entry (CHAOS-A-006).
  static String _withImplicitSeparators(String text) {
    final folded = CategoryNameMatcher.foldAccents(text.toLowerCase());
    if (folded.length != text.length) return text;
    final values = <RegExpMatch>[];
    for (final m in _amountCandidatePattern.allMatches(folded)) {
      final raw = m.group(1)!;
      if (!RegExp(r'^\d').hasMatch(raw)) continue;
      if (_isNonValueNumber(raw, folded.substring(0, m.start), folded.substring(m.end))) continue;
      // "2 cafés 9": a small count before a plural thing and its value.
      if (RegExp(r'^\d{1,2}$').hasMatch(raw) && RegExp(r'^\s+[a-z]{3,}s\b(?:\s+[a-z]+){0,3}?\s+(?:r\$\s*)?\d').hasMatch(folded.substring(m.end))) continue;
      values.add(m);
    }
    if (values.length < 2) return text;
    final cuts = <int>{};
    // "23 açougue 14 padaria": the value comes first, then its name — the
    // next item starts at the next value (CHAOS-B-007).
    final valueFirst = RegExp(r'^\s*(?:r\$\s*)?$').hasMatch(folded.substring(0, values.first.start));
    for (var i = 0; i < values.length; i++) {
      final m = values[i];
      final before = folded.substring(0, m.start);
      final after = folded.substring(m.end);
      // "32 janta 48": another name and value right after this value.
      // "18 uber volta 18": a name of two words too (ACC-B-009).
      final nextName = RegExp(r'^\s+([a-z]{3,})(?:\s+[a-z]{3,})?\s+\d').firstMatch(after)?.group(1);
      if (i + 1 < values.length && nextName != null && !_notItemWords.contains(nextName) && !_nonCountPlurals.contains(nextName) &&
          !_wordsAfterValue.contains(nextName) && !RegExp(r'^(?:dias?|semanas?|mes|meses|anos?|horas?|parcelas?|vezes)$').hasMatch(nextName)) {
        cuts.add(valueFirst ? values[i + 1].start : m.end);
      }
      // "no mercado 50 na farmácia": a value after a name, followed by what
      // it paid — the start of a new item (not the payment: "rua 7 no pix").
      if (i > 0) {
        final nameBefore = RegExp(r'([a-z]{3,})\s+((?:mais\s+)?)$').firstMatch(before);
        final itemAfter = RegExp(r'^\s*(?:reais|real|conto|contos|pila|pilas)?\s+(?:no|na|nos|nas|de|do|da|em|pro|pra|com)\s+([a-z]+)').firstMatch(after);
        if (nameBefore != null && itemAfter != null && !_notItemWords.contains(nameBefore.group(1)) &&
            !_moneyContextWords.contains(nameBefore.group(1)) &&
            !RegExp(r'^(?:pix|debito|credito|dinheiro|boleto|cartao|especie)$').hasMatch(itemAfter.group(1)!)) {
          cuts.add(m.start - nameBefore.group(2)!.length);
        }
      }
    }
    if (cuts.isEmpty) return text;
    final sorted = cuts.toList()..sort();
    final out = StringBuffer();
    var last = 0;
    for (final c in sorted) {
      out.write(text.substring(last, c).trimRight());
      out.write(', ');
      last = c;
    }
    out.write(text.substring(last).trimLeft());
    return out.toString();
  }

  static final RegExp _multiPieceVerb = RegExp(
    r'\b(?:gastei|paguei|comprei|recebi|ganhei|transferi|mandei|torrei|pedi|abasteci|almocei|jantei|lanchei|depositei|caiu|entrou|'
    r'me\s+(?:deu|pagou|mandou|transferiu))\b',
  );

  static final RegExp _firstPersonEntryVerb = RegExp(
    r'\b(?:gastei|gastamos|paguei|pagamos|comprei|compramos|recebi|recebemos|ganhei|transferi|mandei|torrei|pedi|abasteci|almocei|jantei|lanchei|depositei|desembolsei)\b',
  );

  /// Verbs of a piece that only describes ("deu", "cobriu", "era 150").
  static final RegExp _contextVerb = RegExp(
    r'\b(?:deu|daria|cobriu|cobre|cobria|era|eram|seria|custou|custava|custa|veio|vinha|tava|estava|ficou|saiu|devia|valia|vale|reembolsou|descontou|abateu)\b',
  );

  /// Words that can't start the name of an item: negations, fillers,
  /// descriptive verbs ("não 45", "foi 30", "total 80", "tipo 20").
  static const Set<String> _notItemWords = {
    'nao', 'sim', 'mas', 'so', 'ja', 'foi', 'era', 'eh', 'e', 'tambem', 'total', 'tudo', 'isso', 'esse', 'essa', 'ai',
    'entao', 'depois', 'antes', 'mais', 'menos', 'quase', 'cerca', 'tipo', 'com', 'sem', 'no', 'na', 'de', 'do', 'da',
    'pra', 'pro', 'para', 'por', 'que', 'porque', 'pq', 'hoje', 'ontem', 'anteontem', 'dia', 'deu', 'ficou', 'custou',
    'saiu', 'sendo', 'valor', 'preco', 'tava', 'estava', 'seria', 'uns', 'umas', 'cada', 'sobrou', 'faltou', 'troco',
  };

  /// [folded] (a multi-entry piece) as "value de what + rest" when it is one
  /// item: "30 de calibragem no débito", "leite por 6", "janta 48 no pix",
  /// "um caderno de 20", "coloquei 100 de gasolina" (the piece's own verb,
  /// any first-person "-ei" word, is dropped). Null when it isn't an item.
  static String? _itemPiece(String folded) {
    // "hoje: ônibus 5", "depois na farmácia mais 30": the date said up front
    // (shared by the batch, see [_shareDate]) and "mais" before the value
    // are not part of the item (ACC-A-005).
    var p = folded.trim().replaceFirst(RegExp(r'^(?:hoje|ontem|anteontem)\s*[:,-]\s*'), '');
    // "dois cafés 9", "3 pães 6": a count before the thing, then the value
    // of them all — the count is not part of the name nor the value
    // (ACC-C-003).
    p = p.replaceFirst(RegExp(r'^(?:\d{1,2}|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez)\s+(?=[a-z]{3,}(?:\s+[a-z]+){0,3}?\s+(?:r\$\s*)?\d)'), '');
    // "30 hoje no mercado": a date word between the value and what it paid
    // is the item's date (read from the piece by [_shareDate]), not its name.
    p = p.replaceAll(RegExp(r'\s+(?:hoje|ontem|anteontem)\b(?=\s)'), '');
    p = p.replaceFirst(RegExp(r'^(?:e|mais|outros?|outras?|tambem|depois)\s+'), '');
    p = p.replaceFirst(RegExp(r'^[a-z]{3,}ei\s+'), '');
    p = p.replaceAll(RegExp(r'\bmais\s+(?=(?:r\$\s*)?\d)'), '');
    if (_contextVerb.hasMatch(p)) return null;
    if (_verblessItem.hasMatch(p)) return p;
    // "23 açougue", "14 padaria no pix": the value, then its name.
    // ("39 a sobremesa no pix": an article may come before the name,
    // CHAOS-C-008.)
    final valueThenName = RegExp(r'^(?:r\$\s*)?(\d[\d.,]*)\s+(?:(?:o|a|os|as)\s+)?([a-z]{3,}(?:\s+[a-z]{3,})?)((?:\s+(?:no|na|em|via|pelo|pela|tudo)\s+.*)?)$').firstMatch(p);
    if (valueThenName != null && !_notItemWords.contains(valueThenName.group(2)!.split(' ').first) &&
        !_wordsAfterValue.contains(valueThenName.group(2)!.split(' ').first) &&
        !_isNonValueNumber(valueThenName.group(1)!, '', ' ${valueThenName.group(2)}${valueThenName.group(3)}')) {
      return '${valueThenName.group(1)} de ${valueThenName.group(2)}${valueThenName.group(3)}';
    }
    // "na farmácia 30", "no açougue 80": the place, then its value.
    final placed = RegExp(r'^(no|na|nos|nas|num|numa|em|pro|pra)\s+([a-z][a-z -]*?)\s+(?:r\$\s*)?(\d[\d.,]*)(?![\d.,]?\d)(.*)$').firstMatch(p);
    if (placed != null && placed.group(2)!.split(' ').length <= 3 && !_notItemWords.contains(placed.group(2)!.split(' ').first) &&
        !_isNonValueNumber(placed.group(3)!, '${placed.group(1)} ${placed.group(2)} ', placed.group(4)!)) {
      return '${placed.group(3)} ${placed.group(1)} ${placed.group(2)}${placed.group(4)}';
    }
    final m = RegExp(r'^(?:(?:um|uma|uns|umas|o|a|os|as)\s+)?([a-z][a-z -]*?)\s+(?:(?:por|de|a)\s+)?(?:r\$\s*)?(\d[\d.,]*)'
            r'(\s*(?:reais|real|conto|contos|pila|pilas))?(?![\d.,]?\d)(.*)$')
        .firstMatch(p);
    if (m == null) return null;
    final name = m.group(1)!.trim();
    final words = name.split(' ');
    if (words.length > 4 || words.first.length < 3 || _notItemWords.contains(words.first)) return null;
    final raw = m.group(2)!;
    final rest = m.group(4)!;
    final unit = m.group(3) ?? '';
    final before = p.substring(0, m.end - rest.length - unit.length - raw.length);
    if (_isNonValueNumber(raw, before, '$unit$rest')) return null;
    return '$raw de $name$rest';
  }

  static final RegExp _verblessItem = RegExp(
    r'^(?:(?:mais|outros?|outras?|uns|umas)\s+)?(?:r\$\s*)?\d[\d.,]*\s*(?:reais|real|conto|contos|pila|pilas)?\s+'
    r'(?:de|do|da|dos|das|no|na|nos|nas|num|numa|em|com|pro|pra|pela|pelo)\s+[a-z]',
  );

  /// "gastei 50 no mercado e 30 na farmácia no pix": the payment said once
  /// at the end is for every item that didn't name its own.
  List<FinancialTransactionDraft> _sharePaymentMethod(List<FinancialTransactionDraft> drafts, {String? batchPayment}) {
    // "…, tudo no débito": said as a piece of its own, it is for every item
    // that didn't name another (ACC-A-005).
    if (batchPayment != null && drafts.any((d) => d.paymentMethod == 'unknown')) {
      return [for (final d in drafts) d.paymentMethod == 'unknown' ? mergeDrafts(d, batchPayment) : d];
    }
    final known = drafts.map((d) => d.paymentMethod).where((p) => p != 'unknown').toSet();
    if (known.length != 1) return drafts;
    var answer = _paymentAnswerWords[known.first];
    if (answer == null) return drafts;
    // "…e um caderno de 20 no crédito à vista": the "à vista"/"em 3x" said
    // with the card goes along with it, or César asked it again.
    final counts = drafts.where((d) => d.paymentMethod == 'credit_card').map((d) => d.installments).whereType<int>().toSet();
    if (known.first == 'credit_card' && counts.length == 1) {
      answer = counts.first <= 1 ? 'crédito à vista' : 'crédito em ${counts.first}x';
    }
    return [for (final d in drafts) d.paymentMethod == 'unknown' ? mergeDrafts(d, answer) : d];
  }

  static const Map<String, String> _paymentAnswerWords = {
    'pix': 'pix',
    'debit_card': 'débito',
    'credit_card': 'crédito',
    'cash': 'dinheiro',
    'bank_slip': 'no boleto',
  };

  /// Applies an answer to a batch from [parseMulti] that still has open
  /// questions. When every open item lacks the payment method, César asked
  /// one shared question ("foram no Pix?") and the answer goes to all of
  /// them; otherwise he asked about the first open item only.
  List<FinancialTransactionDraft> mergeMultiDrafts(List<FinancialTransactionDraft> pending, String followUp) {
    final open = pending.where((d) => !d.isComplete).toList();
    if (open.isEmpty) return pending;
    // "e se fosse no pix?" asks about the batch, it doesn't answer it: the
    // payment method inside a hypothesis saved both entries (CHAOS-A-003).
    if (HypothesisDetector.detect(followUp) != null) return pending;
    final shared = open.every((d) => d.missingSlots.contains('payment_method')) || open.every(_onlyConfirming);
    final result = <FinancialTransactionDraft>[];
    var answeredOne = false;
    for (final d in pending) {
      if (!d.isComplete && (shared || !answeredOne)) {
        result.add(mergeDrafts(d, followUp));
        answeredOne = true;
      } else {
        result.add(d);
      }
    }
    return result;
  }

  /// The single question César asks about an unfinished batch, or null when
  /// every item is complete.
  String? multiClarificationPrompt(List<FinancialTransactionDraft> drafts) {
    final open = drafts.where((d) => !d.isComplete).toList();
    if (open.isEmpty) return null;
    if (open.every(_onlyConfirming)) {
      final items = drafts.map((d) => '${QuantityPricing._brl(d.amount ?? 0)} (${d.description})').join(' e ');
      return 'Anotei ${drafts.length} lançamentos: $items. Registro assim? (sim/não)';
    }
    if (open.every((d) => d.missingSlots.contains('payment_method'))) {
      final items = open.map((d) => '${QuantityPricing._brl(d.amount ?? 0)} (${d.description})').join(' e ');
      return 'Anotei ${drafts.length} lançamentos. Qual foi a forma de pagamento de $items? '
          'Se foi a mesma, é só dizer: Pix, débito, crédito ou dinheiro.';
    }
    final first = open.first;
    return 'Sobre o lançamento de ${QuantityPricing._brl(first.amount ?? 0)} (${first.description}): '
        '${first.clarificationPrompt ?? 'pode me dar mais detalhes?'}';
  }

  /// Only "Registro assim?" is left to answer.
  static bool _onlyConfirming(FinancialTransactionDraft d) => d.missingSlots.length == 1 && d.missingSlots.single == 'confirm';

  /// Whether a draft should become a saved record. A question ("qual meu
  /// saldo?") is complete too, but it must never be saved nor become the
  /// "último lançamento" that "apaga o último" would then delete.
  /// The money value said in [text], even with no entry verb around it
  /// ("imagina se eu gastasse 1000 numa viagem"): the same choice of number
  /// as [parse], without requiring a money word. Null when there is none.
  double? valueMentioned(String text) =>
      _parseAmount(text) ?? _pickAmount(PtNumberWords.normalize(text.toLowerCase()), requireMoneyContext: false);

  static bool isRecordable(FinancialTransactionDraft draft) =>
      draft.isComplete && !draft.isReportQuery && const {'expense', 'income', 'transfer'}.contains(draft.intent);

  /// Honest answer for a question César can't answer yet. Replaces
  /// "Consultando seus registros... Tudo em ordem!", which consulted nothing.
  static const String unansweredQuestionReply =
      'Ainda não sei responder essa pergunta. Tente, por exemplo: "quanto gastei esse mês?", "qual meu maior gasto?", '
      '"tô no vermelho?", "quais foram meus últimos lançamentos?" ou "o que você sabe fazer?".';

  /// Reply for a `query` draft that no report handled.
  String replyForQuestion(FinancialTransactionDraft draft) => draft.clarificationPrompt ?? unansweredQuestionReply;

  FinancialTransactionDraft? _applyDueRuleCorrection(FinancialTransactionDraft lastTx, String lower) {
    if (RegExp(r'dia\s+[uú]til').hasMatch(lower)) {
      // No ordinal ("é todo dia útil") keeps the rule already in use, or the
      // usual payday rule (5º dia útil).
      final n = parseBusinessDayOrdinal(lower) ?? lastTx.dueBusinessDay ?? 5;
      final next = RealtimeCalendarService.nextNthBusinessDay(n);
      final nextLabel = '${next.day.toString().padLeft(2, '0')}/${next.month.toString().padLeft(2, '0')}';
      return lastTx.copyWith(
        dueBusinessDay: n,
        dueDay: next.day,
        isCorrection: true,
        isComplete: true,
        missingSlots: [],
        clarificationPrompt: 'Pronto! Agora vence todo $nº dia útil do mês — a data muda a cada mês. O próximo cai em $nextLabel. ✨',
      );
    }
    // "não é todo dia 7, é todo dia 10": the last day mentioned is the new one.
    final days = RegExp(r'\b(?:todo|vence(?:\s+no)?|cai(?:\s+no)?|pago(?:\s+no)?)\s+dia\s+(\d{1,2})\b').allMatches(lower).toList();
    if (days.isEmpty) return null;
    final d = int.tryParse(days.last.group(1)!);
    if (d == null || d < 1 || d > 31) return null;
    return lastTx.copyWith(
      dueDay: d,
      clearDueBusinessDay: true,
      isCorrection: true,
      isComplete: true,
      missingSlots: [],
      clarificationPrompt: 'Pronto! Agora vence todo dia $d. ✨',
    );
  }

  /// Applies post-transaction corrections or cancellations in the next turn
  FinancialTransactionDraft applyCorrection(FinancialTransactionDraft lastTx, String correctionText) {
    final lower = correctionText.toLowerCase().trim();

    // Nothing was recorded (an empty/unknown draft): there is nothing to
    // correct, and a "correction" must not turn it into a complete entry.
    if (lastTx.intent == 'unknown' || lastTx.amount == null || lastTx.amount! <= 0) {
      return lastTx.copyWith(
        isCorrection: true,
        clarificationPrompt: 'Ainda não registrei nada para corrigir. Me diga o lançamento completo, ex.: "gastei 50 no mercado no pix".',
      );
    }

    // 0. "isso mesmo" / "isso aí, valeu": a confirmation, not a correction.
    if (isConfirmation(correctionText)) {
      return lastTx.copyWith(
        isCorrection: true,
        clarificationPrompt: 'Combinado, fica registrado assim mesmo! 👍',
      );
    }

    // 1. Cancellation / Undo
    if (_isCancelRequest(lower)) {
      return lastTx.copyWith(
        isCanceled: true,
        isCorrection: true,
        clarificationPrompt: 'Pronto! O último lançamento (${lastTx.description}) foi cancelado com sucesso. 🗑️',
      );
    }

    // 1b. Due-date rule on a recurring item: "não é todo dia sete, é todo dia
    // útil" / "é todo quinto dia útil" / "vence todo dia 10".
    if (lastTx.isRecurrent) {
      final dueCorrection = _applyDueRuleCorrection(lastTx, lower);
      if (dueCorrection != null) return dueCorrection;
    }

    // 2. Installments correction
    final installments = _parseInstallments(correctionText);
    int? updatedInstallments = lastTx.installments;
    if (installments != null) {
      updatedInstallments = installments;
    }

    // 3. Payment method correction
    var updatedPayment = lastTx.paymentMethod;
    if (_hasPaymentKeyword(correctionText)) {
      updatedPayment = _resolvePaymentMethod(correctionText, lastTx.paymentMethod);
    }

    // 4. Amount correction
    // The installment count ("no crédito em 2x") must not be read as the new
    // amount — strip it before looking for a value.
    final amountText = PtNumberWords.normalize(correctionText.toLowerCase())
        .replaceAll(RegExp(r'(?:\bem\s+)?\b\d{1,2}\s*(?:x\b|vezes\b|parcelas?\b)', caseSensitive: false), ' ')
        .trim();
    double? newAmount;
    if (RegExp(r'\d').hasMatch(amountText) && _looksLikeAmountCorrection(lower)) {
      newAmount = _parseAmount(amountText) ?? _extractAmountFromFollowUp(amountText);
    }
    final updatedAmount = newAmount ?? lastTx.amount;

    // 5. Category/Item correction
    var updatedCategory = lastTx.category;
    var updatedDesc = lastTx.description;
    if (_hasCategoryNoun(correctionText)) {
      updatedDesc = _extractDescription(correctionText, lastTx.category);
      if (updatedDesc.toLowerCase().contains('farmacia')) updatedCategory = 'health';
      else if (updatedDesc.toLowerCase().contains('uber')) updatedCategory = 'transport';
      else if (updatedDesc.toLowerCase().contains('mercado')) updatedCategory = 'supermarket';
    }

    // 5b. Explicit category-name correction (e.g. "na verdade é lazer, não moradia",
    // "muda a categoria pra transporte") — takes priority over the noun-based guess
    // above since the user is naming the category directly, not a new item.
    final explicitCategory = _extractExplicitCategoryCorrection(correctionText);
    if (explicitCategory != null) {
      updatedCategory = explicitCategory;
    }

    final changedSomething = updatedAmount != lastTx.amount ||
        updatedPayment != lastTx.paymentMethod ||
        updatedInstallments != lastTx.installments ||
        updatedCategory != lastTx.category ||
        updatedDesc != lastTx.description;

    return lastTx.copyWith(
      amount: updatedAmount,
      paymentMethod: updatedPayment,
      installments: updatedInstallments,
      category: updatedCategory,
      description: updatedDesc,
      isCorrection: true,
      isComplete: true,
      missingSlots: [],
      // Saying "Atualizei" when nothing changed made the user believe a fix
      // (a date, a type, "não cancela") had been applied.
      clarificationPrompt: changedSomething
          ? 'Pronto! Mudei ${_describeCorrection(lastTx, updatedAmount, updatedPayment, updatedInstallments, updatedCategory, updatedDesc)} '
              'em ${lastTx.description}. ✏️'
          : 'Não entendi o que mudar, então o lançamento de ${lastTx.description} continua como estava. '
              'Me diga o valor, a categoria ou a forma de pagamento certa.',
    );
  }

  /// A number in a correction is a new value only when the sentence reads
  /// like one ("na verdade foi 45", "não, 45", "45 reais", just "45") — not
  /// "tenho 30 anos", "nasci em 1995" or "o ônibus 474 atrasou" (CHAOS-026).
  static bool _looksLikeAmountCorrection(String lower) {
    final f = CategoryNameMatcher.foldAccents(lower).replaceAll(RegExp(r'[!?.,;:]+(?!\d)'), ' ').trim();
    if (RegExp(r'^(?:r\$\s*)?\d+(?:[.,]\d{1,2})?\s*(?:reais|real|conto|contos|pila)?$').hasMatch(f)) return true;
    if (RegExp(r'\b(?:reais|real|conto|contos|pila|pilas)\b|r\$').hasMatch(f)) return true;
    return RegExp(r'^(?:nao|ops|opa|epa|na verdade|na real|foi|era|e|eh|sao|muda|mude|mudar|troca|troque|corrige|corrija|'
            r'o valor|valor|deu|ficou|custou|paguei|gastei|recebi|coloca|coloque|poe|bota|altera|altere|atualiza)\b')
        .hasMatch(f);
  }

  /// "o valor de R$ 50,00 para R$ 45,00 e a forma de pagamento de Pix para
  /// crédito" — what a correction changed, for the confirmation (CONV-034).
  String _describeCorrection(FinancialTransactionDraft before, double? amount, String payment, int? installments,
      String category, String description) {
    String brl(double? v) => v == null ? '—' : QuantityPricing._brl(v);
    final parts = <String>[];
    if (amount != before.amount) parts.add('o valor de ${brl(before.amount)} para ${brl(amount)}');
    if (payment != before.paymentMethod || installments != before.installments) {
      final inst = (installments ?? 1) > 1 ? ' em ${installments}x' : '';
      parts.add('a forma de pagamento de ${_getFriendlyPaymentName(before.paymentMethod)} para ${_getFriendlyPaymentName(payment)}$inst');
    }
    if (category != before.category) {
      parts.add('a categoria de ${_getFriendlyCategoryName(before.category)} para ${_getFriendlyCategoryName(category)}');
    }
    if (description != before.description && parts.isEmpty) parts.add('a descrição para $description');
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} e ${parts.last}';
  }

  /// "isso mesmo", "isso aí, valeu", "ok", "certo", "perfeito" — the user
  /// agreeing with what César just did.
  bool isConfirmation(String text) {
    final lower = CategoryNameMatcher.foldAccents(text.toLowerCase().trim());
    const word = r'(?:isso|mesmo|msm|ai|exato|exatamente|certo|certinho|ok|okay|beleza|blz|perfeito|correto|sim|valeu|vlw|'
        r'obrigad[oa]|brigad[oa]|show|top|otimo|tudo\s+certo|pode\s+ser|isso\s+ai)';
    return RegExp('^$word(?:[\\s,!.]+$word)*[\\s,!.]*\$').hasMatch(lower);
  }

  /// Cancel/delete the record — but not "não cancela" and not "desconsidera
  /// o valor, foi no débito" (dropping one field, not the whole record).
  bool _isCancelRequest(String text) {
    final lower = CategoryNameMatcher.foldAccents(text.toLowerCase());
    final verb = RegExp(r'\b(?:cancel\w*|apag\w*|exclu\w*|delet\w*|desconsider\w*|remov\w*|descart\w*)').firstMatch(lower);
    if (verb == null) return false;
    if (RegExp(r'\b(?:nao|nem)\s+(?:\w+\s+)?$').hasMatch(lower.substring(0, verb.start))) return false;
    final rest = lower.substring(verb.end);
    if (RegExp(r'^\s*(?:o|a|essa|esse)\s+(?:valor|categoria|forma|pagamento|data|parcela\w*|descri\w*)\b').hasMatch(rest)) return false;
    return true;
  }

  static const Map<String, String> _categoryNamesByWord = {
    'lazer': 'leisure',
    'moradia': 'housing',
    'casa': 'housing',
    'transporte': 'transport',
    'saude': 'health',
    'saúde': 'health',
    'mercado': 'supermarket',
    'supermercado': 'supermarket',
    'educacao': 'education',
    'educação': 'education',
    'investimento': 'investment',
    'investimentos': 'investment',
    'salario': 'salary',
    'salário': 'salary',
    'outros': 'expense_other',
    'outras': 'expense_other',
    'outro': 'expense_other',
    'alimentacao': 'leisure',
    'alimentação': 'leisure',
    'contas': 'housing',
  };

  /// The category a follow-up answer names by its label ("outros", "lazer",
  /// "saúde", "moradia") — the answer to "onde foi o gasto?" can be the
  /// category itself, not a place. Before, "outros" was "não entendi" unless
  /// some other word happened to contain a category keyword.
  static String? _categoryNamedInAnswer(String text) {
    final lower = text.toLowerCase().trim();
    for (final entry in _categoryNamesByWord.entries) {
      if (_hasTerm(lower, entry.key)) return entry.value;
    }
    return null;
  }

  /// Detects the user naming a category directly in a correction, e.g. "na
  /// verdade é lazer, não moradia", "muda a categoria pra transporte", "isso é
  /// saúde". Returns the matched internal category code, or null if the
  /// correction doesn't explicitly name one of Krezio's categories.
  String? _extractExplicitCategoryCorrection(String correctionText) {
    final lower = correctionText.toLowerCase();
    final categoryWords = _categoryNamesByWord.keys.join('|');
    final pattern = RegExp(
      r'(?:na verdade (?:é|e|foi)|isso (?:é|e|foi)|categoria (?:é|e|foi)?\s*(?:pra|para)?|'
      r'muda(?:r)?\s+(?:a\s+)?categoria\s+(?:pra|para)?)\s*(' + categoryWords + r')\b',
    );
    final match = pattern.firstMatch(lower);
    if (match == null) return null;
    return _categoryNamesByWord[match.group(1)];
  }

  /// Extracts bank SMS / Push notification into a structured draft
  FinancialTransactionDraft? _parseBankNotification(String text) {
    final lower = text.toLowerCase();
    
    final hasBankName = lower.contains('nubank') || lower.contains('bradesco') || lower.contains('itau') || lower.contains('santander') || lower.contains('c6') || lower.contains('inter');
    final hasSmsPattern = (lower.contains('compra') && lower.contains('aprovada')) ||
        lower.contains('compra aprovada') ||
        lower.contains('pix enviado') ||
        lower.contains('pix recebido') ||
        lower.contains('transferência enviada') ||
        lower.contains('transferencia enviada');
    final hasColonHeader = lower.contains('itaucard') || lower.contains('cartoes:') || lower.contains('cartões:') || lower.contains('inter:') || lower.contains('nubank:') || lower.contains('c6 bank:') || (lower.contains('bradesco') && lower.contains(':')) || (lower.contains('santander') && lower.contains(':'));
    final isBankSms = hasSmsPattern || (hasBankName && hasColonHeader);

    if (!isBankSms) return null;

    String bank = 'Banco';
    if (lower.contains('nubank')) bank = 'Nubank';
    else if (lower.contains('itau') || lower.contains('itaucard')) bank = 'Itaú';
    else if (lower.contains('inter')) bank = 'Inter';
    else if (lower.contains('bradesco')) bank = 'Bradesco';
    else if (lower.contains('c6')) bank = 'C6 Bank';
    else if (lower.contains('santander')) bank = 'Santander';
    else if (lower.contains('caixa')) bank = 'Caixa';
    else if (lower.contains('mercado pago')) bank = 'Mercado Pago';

    final amountMatch = RegExp(r'r\$\s*([\d\.,]+)', caseSensitive: false).firstMatch(text);
    double? val;
    if (amountMatch != null) {
      val = cleanAndParseAmount(amountMatch.group(1));
    }

    String paymentMethod = 'credit_card';
    if (lower.contains('pix')) paymentMethod = 'pix';
    else if (lower.contains('debito') || lower.contains('débito')) paymentMethod = 'debit_card';
    else if (lower.contains('boleto')) paymentMethod = 'bank_slip';

    String intent = 'expense';
    if (lower.contains('recebido') || lower.contains('recebeu')) {
      intent = 'income';
    } else if (lower.contains('pix enviado') || lower.contains('transferência') || lower.contains('transferencia') || lower.contains('enviado para') || lower.contains('transferiu')) {
      intent = 'transfer';
    }

    String merchant = _extractDescription(text, 'expense_other');
    final emMatch = RegExp(r'(?:em|no|na|para)\s+([A-Z0-9\s\.\-]{3,30})(?:\s+\d{2}/\d{2}|\s+às|\s+as|\s*$)', caseSensitive: false).firstMatch(text);
    if (emMatch != null) {
      merchant = emMatch.group(1)!.trim();
    }

    var category = 'expense_other';
    if (merchant.toLowerCase().contains('madero') || merchant.toLowerCase().contains('ifood') || merchant.toLowerCase().contains('mcdonald')) {
      category = 'leisure';
    } else if (merchant.toLowerCase().contains('padaria') || merchant.toLowerCase().contains('carrefour') || merchant.toLowerCase().contains('mercado')) {
      category = 'supermarket';
    } else if (merchant.toLowerCase().contains('uber') || merchant.toLowerCase().contains('posto')) {
      category = 'transport';
    }

    return FinancialTransactionDraft(
      intent: intent,
      intentConfidence: 1.0,
      category: category,
      paymentMethod: paymentMethod,
      amount: val,
      // The notification says when the purchase was ("25/08 às 19:42"): that
      // is the date, not the day it was pasted into the chat.
      dateOffsetDays: _parseDateOffset(EntrySafetyGate.entryDateText(_normalizeText(text))),
      description: merchant,
      rawText: text,
      latencyMs: 1.0,
      isComplete: val != null && val > 0,
      missingSlots: val == null ? ['amount'] : [],
      bankSource: bank,
      clarificationPrompt: null,
    );
  }

  /// Detects recurrence, subscriptions, due days and duration/expiration
  static const Map<String, int> _ordinalWords = {
    'primeiro': 1, 'segundo': 2, 'terceiro': 3, 'quarto': 4, 'quinto': 5,
    'sexto': 6, 'setimo': 7, 'sétimo': 7, 'oitavo': 8, 'nono': 9, 'decimo': 10, 'décimo': 10,
  };

  /// "quinto dia útil" / "5º dia util" / "5 dia útil" → 5. A bare "dia útil"
  /// (no ordinal) returns null — callers decide the default.
  int? parseBusinessDayOrdinal(String lower) {
    final m = RegExp(r'\b(primeiro|segundo|terceiro|quarto|quinto|sexto|s[eé]timo|oitavo|nono|d[eé]cimo|\d{1,2})\s*[ºo°]?\s+dia\s+[uú]til\b')
        .firstMatch(lower);
    if (m == null) return null;
    final raw = m.group(1)!;
    final n = _ordinalWords[raw] ?? int.tryParse(raw);
    return (n != null && n >= 1 && n <= 22) ? n : null;
  }

  /// Words that make "dia N" a monthly due day rather than the date of a
  /// one-off entry: recurrence words and habitual presents ("pago 120 de
  /// internet dia 10", "meu salário cai dia 5") — not "foi pago dia 5".
  static final RegExp _recurrenceCue = RegExp(
    r'\b(?:tod[oa]s?|mensal\w*|vence\w*|vencimento|assin\w*|renova\w*|recorrente|sempre|mensalidades?|'
    r'(?<!\b(?:foi|foram|ja|ta|esta|estava|tinha|fica|ficou|sera|seria)\s)pago|pagamos|recebo|recebemos|cai|caem|'
    r'debita|debitam|desconta|descontam|fecha|cobra|cobram)\b',
  );

  Map<String, dynamic> _parseRecurrence(String text) {
    // "todo santo dia 20" is "todo dia 20" (ACC-B-014).
    final lower = text.toLowerCase().replaceAll(RegExp(r'\btodo\s+santo\s+dia\b'), 'todo dia');
    bool isRecurrent = false;
    bool bareDayOnly = false;
    int? dueDay;
    int? dueBusinessDay;
    int? billingDay;
    int? paymentMarginDays;
    String? frequency;
    String? recurrenceDuration;

    // Margin bill pattern: "boleto de luz cai todo dia 1, porém vence no dia 5"
    final marginMatch = RegExp(
      r'cai\s+(?:todo\s+|td\s+)?dia\s+(\d{1,2})[,\s]+(?:por[ée]m|porem|mas|e|com\s+vencimento\s+no|com\s+vencimento)\s+(?:vence\s+(?:no\s+)?dia\s+|no\s+dia\s+|dia\s+)(\d{1,2})',
      caseSensitive: false,
    ).firstMatch(lower);

    if (marginMatch != null) {
      final bDay = int.tryParse(marginMatch.group(1) ?? '');
      final dDay = int.tryParse(marginMatch.group(2) ?? '');
      if (bDay != null && dDay != null && bDay >= 1 && bDay <= 31 && dDay >= 1 && dDay <= 31) {
        billingDay = bDay;
        dueDay = dDay;
        paymentMarginDays = (dDay - bDay).abs();
        isRecurrent = true;
        frequency = 'monthly';
      }
    } else if (parseBusinessDayOrdinal(lower) != null) {
      // "todo quinto dia útil" — the actual date moves month to month, so keep
      // the rule and use the next occurrence as the due day for display.
      dueBusinessDay = parseBusinessDayOrdinal(lower);
      dueDay = RealtimeCalendarService.nextNthBusinessDay(dueBusinessDay!).day;
      if (RegExp(r'\btod[oa]s?\b|\bmensal|\bpor m[eê]s\b|\bao m[eê]s\b').hasMatch(lower)) {
        isRecurrent = true;
        frequency = 'monthly';
      }
    } else {
      final dueMatch = RegExp(r'(?:todo\s+dia|vence\s+dia|vencimento\s+dia|renova\s+dia|renovação\s+dia|renovacao\s+dia|no\s+dia|dia)\s+(\d{1,2})\b', caseSensitive: false).firstMatch(lower);
      if (dueMatch != null) {
        final d = int.tryParse(dueMatch.group(1) ?? '');
        if (d != null && d >= 1 && d <= 31) {
          dueDay = d;
          // A bare "dia 28" ("gastei 50 no mercado dia 28") is the date of a
          // one-off entry; only a word of recurrence ("todo", "vence",
          // "mensal", "assinatura") or a habitual present ("pago", "cai")
          // makes it a monthly due day (CHAOS-R3-003).
          final bare = !RegExp(r'^(?:todo|vence|vencimento|renova)').hasMatch(dueMatch.group(0)!.toLowerCase());
          if (!bare || _recurrenceCue.hasMatch(CategoryNameMatcher.foldAccents(lower))) {
            isRecurrent = true;
            frequency = 'monthly';
          } else {
            bareDayOnly = true;
          }
        }
      }
    }

    if (lower.contains('mensalmente') || lower.contains('todo mês') || lower.contains('todo mes') ||
        // "R$ 89,90 mensais", "plano mensal" (R2-CONV-019).
        RegExp(r'\bmensa(?:l|is)(?![a-zà-úç])').hasMatch(lower) ||
        lower.contains('assinatura') || lower.contains('assinei') || lower.contains('asinei') || lower.contains('assinar') || lower.contains('asinar') ||
        lower.contains('mensalidade') || lower.contains('mensalidades') || lower.contains('recorrente') ||
        lower.contains('plano mensal') || lower.contains('plano de celular') || lower.contains('plano celular') ||
        lower.contains('plano controle') || lower.contains('renovação') || lower.contains('renovacao') ||
        lower.contains('renova') || lower.contains('renovei') ||
        lower.contains('netflix') || lower.contains('netflx') || lower.contains('spotify') || lower.contains('spotfy') ||
        lower.contains('gympass') || lower.contains('wellhub') || lower.contains('totalpass')) {
      isRecurrent = true;
      frequency = 'monthly';
    }

    if (lower.contains('indeterminado') || lower.contains('tempo indeterminado') || lower.contains('sem prazo') ||
        lower.contains('não tem prazo') || lower.contains('nao tem prazo') || lower.contains('não tem tempo') ||
        lower.contains('nao tem tempo') || lower.contains('até cancelar') || lower.contains('ate cancelar')) {
      recurrenceDuration = 'indeterminado';
      isRecurrent = true;
    } else if (lower.contains('anual') || lower.contains('12 meses') || lower.contains('1 ano') || lower.contains('um ano') || lower.contains('plano anual')) {
      recurrenceDuration = 'anual';
      isRecurrent = true;
    } else if (lower.contains('6 meses') || lower.contains('semestral')) {
      recurrenceDuration = '6 meses';
      isRecurrent = true;
    } else if (lower.contains('3 meses') || lower.contains('trimestral')) {
      recurrenceDuration = '3 meses';
      isRecurrent = true;
    }

    if (lower.contains('automaticamente') || lower.contains('todo dia') || lower.contains('salario') || lower.contains('salário')) {
      if (dueDay != null && !bareDayOnly) {
        recurrenceDuration ??= 'indeterminado';
        isRecurrent = true;
        frequency ??= 'monthly';
      }
    }

    // Nothing else made it recurring: "dia N" was just the day it happened.
    if (bareDayOnly && !isRecurrent) dueDay = null;

    return {
      'is_recurrent': isRecurrent,
      'due_day': dueDay,
      'due_business_day': dueBusinessDay,
      'billing_day': billingDay,
      'payment_margin_days': paymentMarginDays,
      'frequency': frequency,
      'recurrence_duration': recurrenceDuration,
      // "dia N" said with no recurrence word of its own (the recurrence came
      // from elsewhere, e.g. "netflix"): it may also be the entry's date.
      'bare_day': bareDayOnly,
    };
  }

  /// Generates proactive, empathetic micro-insights based on category and volume
  String? _generateBudgetInsight(String intent, String category, double? amount, bool isRecurrent) {
    if (intent != 'expense' || amount == null) return null;

    if (isRecurrent) {
      return '💡 Lembrete: este valor será computado automaticamente todo mês.';
    }

    if (amount >= 200) {
      if (category == 'supermarket') {
        return '💡 Dica: Compras de mercado concentradas ajudam a economizar no mês.';
      }
      return '💡 Dica: Gastos com compras e lazer já somam uma parcela importante dos variáveis.';
    }

    return null;
  }

  /// Merges a follow-up answer from the user into a previously incomplete draft.
  FinancialTransactionDraft mergeDrafts(FinancialTransactionDraft previousDraft, String followUpText) {
    // "Registro assim? (sim/não)" — the confirmation net of [EntrySafetyGate]:
    // "sim" records the entry as shown, "não" drops it; anything else is read
    // as an answer (a correction of a field) and the entry is shown again.
    final confirming = previousDraft.missingSlots.contains('confirm');
    if (confirming && EntrySafetyGate.confirmsEntry(followUpText)) {
      final rest = previousDraft.missingSlots.where((s) => s != 'confirm').toList();
      return _guard(
          previousDraft.copyWith(
            isComplete: rest.isEmpty && previousDraft.intent != 'unknown',
            missingSlots: rest,
            settledChecks: {...previousDraft.settledChecks, 'certainty'},
          ),
          turns: previousDraft.rawText.split(' + '));
    }
    if (confirming && EntrySafetyGate.declinesEntry(followUpText)) return GateVerdict.closed(previousDraft, declinedEntryReply);
    // "muda" with the draft still open: what to change? The draft waits
    // (ACC-C-011: "muda" became the name of the place and was saved).
    if (_bareEditRequest.hasMatch(CategoryNameMatcher.foldAccents(followUpText.toLowerCase().trim()).replaceAll(RegExp(r'[!.?,]'), '').trim())) {
      final value = previousDraft.amount != null && previousDraft.amount! > 0 ? ' de ${QuantityPricing._brl(previousDraft.amount!)}' : '';
      return previousDraft.copyWith(
          clarificationPrompt: 'O que você quer mudar nesse lançamento$value? Diga o novo valor, a data ou a forma de pagamento '
              '(ex.: "pra 45", "foi ontem", "no débito")${previousDraft.clarificationPrompt == null || confirming ? '.' : ' — e depois me responda: ${previousDraft.clarificationPrompt}'}');
    }
    if (confirming) {
      // "no débito", "foi 85", "foi ontem" in place of the "sim": a fix of a
      // field of the entry shown — applied, and the entry shown again. (The
      // answer slots only fill what is missing; here nothing is.)
      final fixed = applyCorrection(previousDraft, followUpText);
      final changed = !fixed.isCanceled &&
          (fixed.amount != previousDraft.amount ||
              fixed.paymentMethod != previousDraft.paymentMethod ||
              fixed.dateOffsetDays != previousDraft.dateOffsetDays ||
              fixed.intent != previousDraft.intent ||
              fixed.installments != previousDraft.installments ||
              fixed.category != previousDraft.category);
      if (changed) {
        final rest = previousDraft.missingSlots.where((s) => s != 'confirm').toList();
        // The fixed entry passes the gate again (a new date may be in the
        // future, a new value may clash), with every turn said.
        final shown = _guard(
            fixed.copyWith(isCorrection: false, isComplete: rest.isEmpty, missingSlots: rest, clarificationPrompt: previousDraft.clarificationPrompt),
            turns: [...previousDraft.rawText.split(' + '), followUpText]);
        if (!shown.isComplete) return shown;
        return shown.copyWith(isComplete: false, missingSlots: const ['confirm'], clarificationPrompt: EntrySafetyGate.confirmQuestion(shown));
      }
    }
    final merged = _mergeAnswer(previousDraft, followUpText);
    // A batch whose sentence was unsure keeps asking its confirmation until
    // it is answered (the items' own words may look sure: "30 na farmácia").
    if (confirming && !merged.missingSlots.contains('confirm') && !merged.settledChecks.contains('certainty') &&
        !merged.settledChecks.contains('closed') && const {'expense', 'income', 'transfer'}.contains(merged.intent)) {
      return merged.copyWith(
        isComplete: false,
        missingSlots: [...merged.missingSlots, 'confirm'],
        clarificationPrompt: merged.missingSlots.isEmpty ? EntrySafetyGate.confirmQuestion(merged) : merged.clarificationPrompt,
      );
    }
    return merged;
  }

  /// What César says when the user answers "não" to "Registro assim?".
  static const declinedEntryReply = 'Tudo bem, não registrei nada. 👍 Se quiser, me conte de novo do jeito certo.';

  /// "muda", "corrige", "altera isso" said alone.
  static final RegExp _bareEditRequest = RegExp(
      r'^(?:(?:quero|pode|da\s+pra)\s+)?(?:muda|mudar|mude|altera|alterar|altere|corrige|corrigir|corrija|troca|trocar|troque|edita|editar|arruma|arrumar)'
      r'(?:\s+(?:isso|ai|ele|esse|essa|o\s+lancamento|uma\s+coisa|algo|por\s+favor))?$');

  /// "pra 45", "muda pra 45", "corrige o valor pra 45": a new value for the
  /// draft being asked about.
  static final RegExp _newValueForDraft = RegExp(
      r'^(?:(?:muda|mude|altera|altere|corrige|corrija|troca|troque|passa|coloca|bota|poe)\s+)?(?:(?:o|a)\s+)?(?:valor\s+)?(?:pra|para|por)\s+'
      r'(?:r\$\s*)?(\d+(?:[.,]\d{1,2})?)\s*(?:reais|real|conto|contos)?$');

  FinancialTransactionDraft _mergeAnswer(FinancialTransactionDraft previousDraft, String followUpText) {
    // A hypothesis never completes a draft, and a draft that came from a
    // hypothesis is never completed (CHAOS-A-002/003): "se o joão me pagar
    // 200" ⏎ "no pix" saved R$ 200. The draft stays as it was; the
    // hypothetical one is dropped and the answer read on its own.
    if (HypothesisDetector.detect(followUpText) != null) return previousDraft;
    if (HypothesisDetector.detect(previousDraft.rawText.split(' + ').first) != null) return parse(followUpText);
    final followUpParsed = parse(followUpText);

    // 1. Contextual Amount resolution (e.g. user answered just "700" or "vintao")
    double? updatedAmount = previousDraft.amount;
    String? additionNote;
    List<double>? valueChoices;
    // Answer to [splitQuestion]: the value said is the one to record.
    final answeringSplit = previousDraft.missingSlots.contains('split');
    var splitAnswered = false;
    final newValue = _newValueForDraft.firstMatch(CategoryNameMatcher.foldAccents(followUpText.toLowerCase().trim()).replaceAll(RegExp(r'[!?]'), '').trim());
    if (newValue != null && (cleanAndParseAmount(newValue.group(1)) ?? 0) > 0) {
      // "muda" ⏎ "pra 45": the value said replaces the draft's (ACC-C-011).
      updatedAmount = cleanAndParseAmount(newValue.group(1));
      if (answeringSplit) splitAnswered = true;
    } else if (answeringSplit) {
      final said = followUpParsed.amount ?? _extractAmountFromFollowUp(followUpText);
      if (said != null && said > 0) {
        updatedAmount = said;
        splitAnswered = true;
      }
    } else if (updatedAmount == null || updatedAmount <= 0) {
      // "70 ou 80", "entre 100 e 120", "acho que 60, talvez 65": two values
      // for one entry — ask which one instead of keeping the first (CHAOS-A-007).
      final said = _valuesInAnswer(followUpText);
      if (said.length >= 2) {
        valueChoices = said;
      } else {
        updatedAmount = followUpParsed.amount ?? _extractAmountFromFollowUp(followUpText);
      }
    } else {
      // "mais 20 de gorjeta" while César asks something else: add it to the
      // value instead of ignoring it and repeating the same question.
      final extra = _parseAddedAmount(followUpText);
      if (extra != null) {
        final total = double.parse((updatedAmount + extra).toStringAsFixed(2));
        additionNote = 'Somei: ${QuantityPricing._brl(updatedAmount)} + ${QuantityPricing._brl(extra)} = ${QuantityPricing._brl(total)}.';
        updatedAmount = total;
      }
    }

    // 2. Contextual Category resolution
    // Only trust the classifier's category guess when the follow-up text actually
    // contains a recognizable category noun/keyword — a bare number like "50" gets
    // a category prediction from the ML model too, but it's noise, not signal.
    var updatedCategory = previousDraft.category;
    // Answering with the name of one of the user's own categories ("roupas",
    // "pets") files it there — the trained model has never seen those names.
    final followUpCustomCategory = previousDraft.intent == 'income' ? null : matchCustomCategory(followUpText);
    final namedCategory = previousDraft.intent == 'expense' && previousDraft.missingSlots.contains('category')
        ? _categoryNamedInAnswer(followUpText)
        : null;
    if (followUpCustomCategory != null) {
      updatedCategory = followUpCustomCategory;
    } else if ((updatedCategory == 'unknown' || updatedCategory == 'expense_other') && _hasCategoryNoun(followUpText)) {
      updatedCategory = followUpParsed.category;
    } else if (namedCategory != null) {
      updatedCategory = namedCategory;
    }
    // "Onde foi o gasto?" ⏎ "loja" / "compras" / "numa banca": a place said
    // in a few words is the answer even when it names no category César
    // knows — it was "Não entendi" in a loop (CHAOS-B-020).
    String? placeAnswer;
    if (previousDraft.missingSlots.contains('category') &&
        previousDraft.intent == 'expense' &&
        (updatedCategory == 'unknown' || (updatedCategory == 'expense_other' && followUpCustomCategory == null && namedCategory == null))) {
      placeAnswer = _placeAnswer(followUpText);
      if (placeAnswer != null) updatedCategory = 'expense_other';
    }

    // 3. Contextual Payment resolution
    var updatedPayment = previousDraft.paymentMethod;
    if (updatedPayment == 'unknown') {
      final directPay = _resolvePaymentMethod(followUpText, followUpParsed.paymentMethod);
      if (directPay != 'unknown') {
        updatedPayment = directPay;
      } else if (followUpParsed.paymentMethod != 'unknown') {
        updatedPayment = followUpParsed.paymentMethod;
      }
    }

    // 4. Contextual Installment resolution (if credit card or if installments mentioned in follow-up)
    int? updatedInstallments = previousDraft.installments;
    // A bare "6" is an installment count when César asked about installments,
    // or when the purchase was on an unspecified "cartão" (6x implies credit).
    final askingInstallments = previousDraft.missingSlots.contains('installments') ||
        (previousDraft.missingSlots.contains('payment_method') && RegExp(r'cart[aã]o').hasMatch(previousDraft.rawText.toLowerCase()));
    final followUpInst = followUpParsed.installments ?? _parseInstallments(followUpText, allowBareCount: askingInstallments);
    if (followUpInst != null && followUpInst > 0) {
      updatedInstallments = followUpInst;
      if (updatedPayment == 'unknown') {
        updatedPayment = 'credit_card';
      }
    } else if (updatedInstallments == null && (updatedPayment == 'credit_card' || askingInstallments)) {
      updatedInstallments = followUpParsed.installments ?? _parseInstallments(followUpText, allowBareCount: askingInstallments);
    }

    // 5. Contextual Recurrence resolution (due day and duration for subscriptions)
    bool updatedIsRecurrent = previousDraft.isRecurrent || followUpParsed.isRecurrent;
    int? updatedDueDay = previousDraft.dueDay ?? followUpParsed.dueDay;
    String? updatedDuration = previousDraft.recurrenceDuration ?? followUpParsed.recurrenceDuration;

    final lowerFollow = followUpText.toLowerCase().trim();
    if (updatedIsRecurrent) {
      if (updatedDueDay == null) {
        final dayMatch = RegExp(r'(?:renova\s+dia|todo\s+dia|vence\s+dia|renovação\s+dia|renovacao\s+dia|no\s+dia|dia)\s+(\d{1,2})\b', caseSensitive: false).firstMatch(lowerFollow);
        if (dayMatch != null) {
          final d = int.tryParse(dayMatch.group(1) ?? '');
          if (d != null && d >= 1 && d <= 31) updatedDueDay = d;
        } else if (lowerFollow.contains('hoje')) {
          updatedDueDay = DateTime.now().day;
        } else if (RegExp(r'^\s*(\d{1,2})\s*$').hasMatch(lowerFollow)) {
          final d = int.tryParse(lowerFollow);
          if (d != null && d >= 1 && d <= 31) updatedDueDay = d;
        }
      }

      // An assumed "sem prazo" gives way to a length said in the answer
      // ("dia 10, é plano anual").
      if (previousDraft.assumptionNote == openEndedAssumptionNote &&
          RegExp(r'anual|12 meses|\b1 ano|um ano|6 meses|semestral|3 meses|trimestral').hasMatch(lowerFollow)) {
        updatedDuration = null;
      }
      if (updatedDuration == null) {
        if (lowerFollow.contains('indeterminado') || lowerFollow.contains('tempo indeterminado') || lowerFollow.contains('sem prazo') ||
            lowerFollow.contains('não tem prazo') || lowerFollow.contains('nao tem prazo') || lowerFollow.contains('não tem tempo') ||
            lowerFollow.contains('nao tem tempo') || lowerFollow.contains('até cancelar') || lowerFollow.contains('ate cancelar') ||
            lowerFollow == 'não' || lowerFollow == 'nao') {
          updatedDuration = 'indeterminado';
        } else if (lowerFollow.contains('anual') || lowerFollow.contains('12 meses') || lowerFollow.contains('1 ano') || lowerFollow.contains('um ano')) {
          updatedDuration = 'anual';
        } else if (lowerFollow.contains('6 meses') || lowerFollow.contains('semestral')) {
          updatedDuration = '6 meses';
        } else if (lowerFollow.contains('3 meses') || lowerFollow.contains('trimestral')) {
          updatedDuration = '3 meses';
        }
      }
    }

    var updatedIntent = previousDraft.intent != 'unknown' ? previousDraft.intent : followUpParsed.intent;
    final mergedRaw = '${previousDraft.rawText} + ${followUpText.trim()}';

    // Re-check completeness strictly
    final missingSlots = <String>[];

    // Answer to "entrou ou saiu?" (see [typeQuestion]).
    if (previousDraft.missingSlots.contains('type')) {
      final answered = typeFromAnswer(followUpText);
      if (answered == null) {
        missingSlots.add('type');
      } else {
        updatedIntent = answered;
        if (answered == 'income' && !const {'salary', 'income_other', 'investment'}.contains(updatedCategory)) {
          updatedCategory = 'income_other';
        } else if (answered == 'expense' && const {'salary', 'income_other', 'investment'}.contains(updatedCategory)) {
          updatedCategory = _resolveContextualCategory(_normalizeText(previousDraft.rawText), 'unknown');
          if (const {'salary', 'income_other', 'investment'}.contains(updatedCategory)) updatedCategory = 'unknown';
        }
      }
    }

    // Answer to "quando foi?" after an impossible date (CHAOS-017).
    var updatedOffset = previousDraft.dateOffsetDays;
    String? answerDateQuestion;
    String? weekendNote;
    if (previousDraft.missingSlots.contains('date')) {
      final answer = _normalizeText(followUpText);
      final dayOfLastMonth = RegExp(r'^(?:foi\s+)?(?:(?:no\s+)?dia\s+)?(\d{1,2})$').firstMatch(answer.trim());
      if (detectContradiction(answer)?.kind == ContradictionKind.date) {
        missingSlots.add('date');
      } else if ((answerDateQuestion = _dateQuestion(answer, updatedAmount)) != null) {
        // Another date that can't be recorded ("depois de amanhã"): the date
        // question again, not "não entendi" asking for what was already said.
        missingSlots.add('date');
      } else if (dayOfLastMonth != null && RegExp(r'\bm[eê]s\s+passado\b').hasMatch(previousDraft.rawText.toLowerCase())) {
        // "Em que dia do mês passado?" ⏎ "dia 15": the 15th of last month.
        final now = DateTime.now();
        final n = int.parse(dayOfLastMonth.group(1)!);
        if (n < 1 || n > DateTime(now.year, now.month, 0).day) {
          missingSlots.add('date');
        } else {
          updatedOffset = SpokenDay(start: DateTime(now.year, now.month - 1, n), end: DateTime(now.year, now.month - 1, n), label: '', matched: '')
              .offsetFrom(now);
        }
      } else {
        updatedOffset = _parseDateOffset(answer);
        weekendNote = _weekendNote(answer);
      }
    } else if (!updatedIsRecurrent && !previousDraft.missingSlots.contains('due_day')) {
      // "quanto foi?" ⏎ "70 ontem", "deu 28 na sexta": the date said in the
      // answer is the entry's date — it was dropped and the entry saved as
      // today (CHAOS-A-008). It also wins over a date the draft already had:
      // the answer is the latest word (CHAOS-B-009). A day still ahead or a
      // span is asked, as when recording.
      final answer = EntrySafetyGate.entryDateText(_normalizeText(withoutNameDates(followUpText)));
      if (_saysDate(answer)) {
        answerDateQuestion = _dateQuestion(answer, updatedAmount);
        if (answerDateQuestion != null) {
          missingSlots.add('date');
        } else {
          updatedOffset = _parseDateOffset(answer);
          weekendNote = _weekendNote(answer);
        }
      }
    }
    if (valueChoices != null) {
      missingSlots.add('amount');
    } else if (updatedAmount == null || updatedAmount <= 0) {
      missingSlots.add('amount');
    }
    if (answeringSplit && !splitAnswered) missingSlots.add('split');
    
    if (previousDraft.isReminder && previousDraft.reminderType == 'loan_receivable') {
      if (updatedCategory == 'unknown') updatedCategory = 'expense_other';
      if (updatedPayment == 'unknown') updatedPayment = 'pix';
    } else {
      final isCatIdentified = (updatedCategory != 'unknown' && updatedCategory != 'expense_other') ||
          namedCategory != null ||
          placeAnswer != null ||
          _hasCategoryNoun(mergedRaw) ||
          (updatedIntent != 'expense' && updatedCategory != 'unknown') ||
          (updatedCategory != 'unknown' && !previousDraft.missingSlots.contains('category'));
      if (!isCatIdentified) missingSlots.add('category');

      if (updatedPayment == 'unknown' && updatedIntent == 'income' && updatedCategory == 'salary') {
        updatedPayment = 'pix';
      }

      final isPayIdentified = updatedPayment != 'unknown';
      if (!isPayIdentified) {
        if (updatedIntent != 'income' || updatedCategory != 'salary') {
          missingSlots.add('payment_method');
        }
      }
    }

    final isAnnualSub = updatedIsRecurrent &&
        (updatedDuration == 'anual' ||
            mergedRaw.toLowerCase().contains('anual') ||
            mergedRaw.toLowerCase().contains('12 meses') ||
            mergedRaw.toLowerCase().contains('1 ano') ||
            mergedRaw.toLowerCase().contains('um ano') ||
            mergedRaw.toLowerCase().contains('plano anual'));

    if (updatedIntent == 'expense' && updatedPayment == 'credit_card' && updatedInstallments == null) {
      if (updatedIsRecurrent && !isAnnualSub) {
        updatedInstallments = 1;
      } else {
        missingSlots.add('installments');
      }
    }

    final isNewSub = _isNewSubscriptionPhrase(mergedRaw.toLowerCase());
    if (updatedIsRecurrent && isNewSub) {
      if (updatedDueDay == null) missingSlots.add('due_day');
      if (updatedDuration == null) missingSlots.add('recurrence_duration');
    }

    final isComplete = (updatedIntent != 'unknown') && missingSlots.isEmpty;
    var clarification = isComplete
        ? null
        : valueChoices != null
            ? valueChoiceQuestion(valueChoices)
            : answerDateQuestion ?? (missingSlots.contains('type')
            ? typeQuestion(updatedAmount)
            : missingSlots.contains('split')
                ? 'Qual é o valor certo desse lançamento? Se eram gastos separados, me mande um de cada vez (ex.: "gastei 30 na farmácia no pix").'
                : _generateEmpatheticClarificationPrompt(
            intent: updatedIntent,
            amount: updatedAmount,
            category: updatedCategory,
            paymentMethod: updatedPayment,
            description: previousDraft.description,
            missingSlots: missingSlots,
            rawText: mergedRaw,
            isRecurrent: updatedIsRecurrent,
            dueDay: updatedDueDay,
            recurrenceDuration: updatedDuration,
            isReminder: previousDraft.isReminder,
            reminderType: previousDraft.reminderType,
            personName: previousDraft.personName,
            targetDate: previousDraft.targetDate,
            calendarConsultationNote: previousDraft.calendarConsultationNote,
          ));
    var unanswered = false;
    if (clarification != null) {
      // Never repeat the exact same question as if nothing was said: tell the
      // user the answer didn't fill anything (or what was added).
      final madeProgress = additionNote != null ||
          placeAnswer != null ||
          valueChoices != null ||
          answerDateQuestion != null ||
          updatedIntent != previousDraft.intent ||
          (previousDraft.missingSlots.contains('type') && !missingSlots.contains('type')) ||
          updatedAmount != previousDraft.amount ||
          updatedCategory != previousDraft.category ||
          updatedPayment != previousDraft.paymentMethod ||
          updatedInstallments != previousDraft.installments ||
          updatedDueDay != previousDraft.dueDay ||
          updatedDuration != previousDraft.recurrenceDuration ||
          (previousDraft.missingSlots.contains('date') && !missingSlots.contains('date'));
      final stillBadDate = missingSlots.contains('date') ? detectContradiction(_normalizeText(followUpText)) : null;
      // "sim"/"foi parcelada" to "parcelada ou à vista?" is half an answer:
      // ask only for the count instead of "não entendi" and the same question.
      final saidInstalledOnly = missingSlots.contains('installments') &&
          RegExp(r'^(?:sim|s|foi|foi sim|sim foi|parcelad[oa]|parcelei|foi parcelad[oa]|sim parcelad[oa]|sim parcelei)$')
              .hasMatch(CategoryNameMatcher.foldAccents(lowerFollow).replaceAll(RegExp(r'[!.,]'), '').trim());
      if (stillBadDate != null) {
        clarification = stillBadDate.question(updatedAmount);
      } else if (saidInstalledOnly) {
        clarification = 'Em quantas vezes foi parcelada? (ex: 3x — ou "à vista")';
      } else if (additionNote != null) {
        clarification = '$additionNote $clarification';
      } else if (!madeProgress && previousDraft.settledChecks.contains(_unansweredMark)) {
        // The same question a third time is a loop: offer a way out instead
        // of repeating it (CHAOS-B-020).
        clarification = 'Ainda não consegui encaixar essa resposta. $clarification ${_wayOut(missingSlots)}';
      } else if (!madeProgress) {
        clarification = 'Não entendi essa resposta. $clarification';
      }
      unanswered = !madeProgress && stillBadDate == null && !saidInstalledOnly && additionNote == null;
    }

    // What the user just answered of the gate's questions is settled: it is
    // never asked again for this draft.
    final settled = {
      ...previousDraft.settledChecks.where((c) => c != _unansweredMark || unanswered),
      if (unanswered) _unansweredMark,
      for (final slot in const ['type', 'date', 'split'])
        if (previousDraft.missingSlots.contains(slot) && !missingSlots.contains(slot)) slot,
    };

    return _guard(previousDraft.copyWith(
      settledChecks: settled,
      intent: updatedIntent,
      category: updatedCategory,
      paymentMethod: updatedPayment,
      amount: updatedAmount,
      rawText: mergedRaw,
      isComplete: isComplete,
      missingSlots: missingSlots,
      clarificationPrompt: clarification,
      installments: updatedInstallments,
      dateOffsetDays: updatedOffset,
      isRecurrent: updatedIsRecurrent,
      dueDay: updatedDueDay,
      recurrenceDuration: updatedDuration,
      isReminder: previousDraft.isReminder,
      reminderType: previousDraft.reminderType,
      personName: previousDraft.personName,
      targetDate: previousDraft.targetDate,
      calendarConsultationNote: previousDraft.calendarConsultationNote,
      assumptionNote: weekendNote,
      description: placeAnswer,
    ), turns: [...previousDraft.rawText.split(' + '), followUpText.trim()]);
  }

  /// Kept in [FinancialTransactionDraft.settledChecks] while the last answer
  /// filled nothing: the next unanswered reply gets a way out, not the same
  /// question again.
  static const _unansweredMark = 'unanswered';

  /// The way out of a question asked twice already.
  static String _wayOut(List<String> missing) {
    if (missing.contains('category')) {
      return 'Se preferir, responda "outros" que eu registro em Outras despesas — ou "cancela" para deixar pra lá.';
    }
    if (missing.contains('payment_method')) {
      return 'Responda só a forma (ex.: "pix", "débito", "dinheiro") — ou "cancela" para deixar pra lá.';
    }
    if (missing.contains('amount')) return 'Responda só o valor (ex.: "45") — ou "cancela" para deixar pra lá.';
    return 'Se preferir, diga "cancela" para deixar esse lançamento pra lá.';
  }

  /// "loja", "compras", "numa banca", "foi na feirinha": a place/thing said
  /// in a few words, as the answer to "onde foi o gasto?" — or null when it
  /// isn't one (a value, a payment, a date, "não sei", a sentence).
  String? _placeAnswer(String text) {
    var s = CategoryNameMatcher.foldAccents(text.toLowerCase()).replaceAll(RegExp(r'[!?.,;:"]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceFirst(RegExp(r'^(?:(?:foi|era|e|eh|la|ali|aqui)\s+)*(?:(?:no|na|nos|nas|num|numa|em|de|do|da|uma|um|o|a)\s+)*'), '');
    if (s.isEmpty || RegExp(r'\d').hasMatch(s)) return null;
    final words = s.split(' ');
    if (words.length > 4 || words.any((w) => w.length < 2 && !const {'e', 'a', 'o'}.contains(w))) return null;
    if (words.any(_notAPlaceAnswer.contains) || words.any((w) => RegExp(r'^[a-z]{2,}(?:ei|ou|aram|eram)$').hasMatch(w))) return null;
    if (_resolvePaymentMethod(text, 'unknown') != 'unknown' || _saysDate(_normalizeText(text))) return null;
    if (!RegExp(r'[a-z]{3,}').hasMatch(words.first)) return null;
    // The same last words as typed (accents kept): "numa banca" → "Banca".
    final typed = text.trim().replaceAll(RegExp(r'[!?.,;:"]'), ' ').trim().split(RegExp(r'\s+'));
    if (typed.length < words.length) return null;
    final kept = typed.skip(typed.length - words.length).join(' ');
    return kept[0].toUpperCase() + kept.substring(1);
  }

  static const Set<String> _notAPlaceAnswer = {
    'sim', 'nao', 'sei', 'lembro', 'ok', 'okay', 'isso', 'nada', 'nenhum', 'nenhuma', 'qualquer', 'tanto', 'faz', 'talvez',
    'acho', 'quanto', 'qual', 'quando', 'onde', 'como', 'porque', 'pq', 'cancela', 'esquece', 'deixa', 'hoje', 'ontem',
    'reais', 'real', 'valor', 'obrigado', 'obrigada', 'valeu', 'oi', 'ola', 'bom', 'boa', 'dia', 'tarde', 'noite', 'cesar',
    'outro', 'outros', 'outra', 'outras', 'mesmo', 'mesma', 'pode', 'ser', 'claro', 'beleza', 'blz', 'certo', 'exato',
    'esse', 'essa', 'aquele', 'aquela', 'aquilo', 'coisa', 'algo', 'tudo', 'ninguem', 'ja', 'agora', 'depois',
  };

  /// Safely parses monetary amounts handling pt-BR (67,90 or 1.250,50) and international/keyboard (67.90 or 1,250.50).
  static double? cleanAndParseAmount(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;

    if (s.startsWith('.') || s.startsWith(',')) {
      s = '0$s';
    }

    // Both '.' and ',' present: determines which is the decimal separator
    if (s.contains('.') && s.contains(',')) {
      final lastDot = s.lastIndexOf('.');
      final lastComma = s.lastIndexOf(',');
      if (lastComma > lastDot) {
        // Brazilian format: 1.250,50 -> 1250.50
        s = s.replaceAll('.', '').replaceAll(',', '.');
      } else {
        // US/International format: 1,250.50 -> 1250.50
        s = s.replaceAll(',', '');
      }
      return double.tryParse(s);
    }

    // Only ',' present
    if (s.contains(',')) {
      final commaParts = s.split(',');
      if (commaParts.length == 2) {
        // Standard decimal: "67,90", "67,9", "1250,50" -> "67.90", "1250.50"
        s = s.replaceAll(',', '.');
      } else {
        // Multiple commas: e.g. "1,000,000"
        s = s.replaceAll(',', '');
      }
      return double.tryParse(s);
    }

    // Only '.' present
    if (s.contains('.')) {
      final dotParts = s.split('.');
      if (dotParts.length == 2) {
        final decPart = dotParts[1];
        // In Brazil, "1.000" or "2.500" or "10.000" (dot followed by exactly 3 digits) is thousands separator.
        // Dot followed by 1 or 2 digits ("67.90", "67.9", "1250.50", "0.99") is ALWAYS a decimal separator!
        if (decPart.length == 3 && dotParts[0].isNotEmpty) {
          s = s.replaceAll('.', '');
        } else {
          // Keep '.' as decimal separator (e.g. 67.90 -> 67.90)
        }
      } else {
        // Multiple dots: e.g. "1.000.000"
        s = s.replaceAll('.', '');
      }
      return double.tryParse(s);
    }

    // Plain integer
    return double.tryParse(s);
  }

  /// The money values said in an answer to "quanto foi?" ("70 ou 80" →
  /// [70, 80]): numbers that aren't days, spans, counts or times.
  static List<double> _valuesInAnswer(String text) {
    final lower = CategoryNameMatcher.foldAccents(PtNumberWords.normalize(text.toLowerCase()));
    final out = <double>[];
    for (final m in _amountCandidatePattern.allMatches(lower)) {
      final value = cleanAndParseAmount(m.group(1));
      if (value == null || value <= 0) continue;
      final before = lower.substring(0, m.start), after = lower.substring(m.end);
      if (RegExp(r'[a-z]$').hasMatch(before)) continue;
      // "120 130 por aí": two bare values side by side in an answer are two
      // guesses — read each without its neighbour (ACC-B-020).
      final soloBefore = before.replaceFirst(RegExp(r'(?:^|(?<=\s))\d{2,}(?:[.,]\d+)?\s+$'), '');
      final soloAfter = after.replaceFirst(RegExp(r'^\s+\d{2,}(?:[.,]\d+)?(?=\s|$)'), '');
      final besideAnother = m.group(1)!.length >= 2 && (soloBefore != before || soloAfter != after);
      if (besideAnother ? _isNonValueNumber(m.group(1)!, soloBefore, soloAfter) : _isNonValueNumber(m.group(1)!, before, after)) continue;
      out.add(value);
    }
    return out;
  }

  /// Asked when the answer to "quanto foi?" carried more than one value.
  static String valueChoiceQuestion(List<double> values) =>
      'Você falou ${values.take(3).map(QuantityPricing._brl).join(' e ')} — qual foi o valor certo? '
      'Se foram gastos separados, me mande um de cada vez.';

  /// "mais 20", "e mais 20 de gorjeta", "+ 20" → 20 (not "mais 2 parcelas").
  double? _parseAddedAmount(String text) {
    final lower = CategoryNameMatcher.foldAccents(PtNumberWords.normalize(text.toLowerCase().trim()));
    final m = RegExp(r'^(?:e\s+)?(?:mais|\+)\s*(?:r\$\s*)?(\d+(?:[.,]\d{1,2})?)').firstMatch(lower);
    if (m == null) return null;
    if (_isNonValueNumber(m.group(1)!, '', lower.substring(m.end))) return null;
    final value = cleanAndParseAmount(m.group(1));
    return (value != null && value > 0) ? value : null;
  }

  double? _extractAmountFromFollowUp(String text) {
    final std = _parseAmount(text);
    if (std != null) return std;

    // "um"/"uma" alone answers "quanto?" with 1, not an article.
    final raw = text.toLowerCase().trim();
    final lower = PtNumberWords.normalize(RegExp(r'^(?:um|uma)$').hasMatch(raw) ? '1' : raw);
    // Number words are already digits; only the money slang is left.
    final slangMap = <String, double>{
      'vintão': 20.0, 'vintao': 20.0, 'vintinha': 20.0,
      'dezão': 10.0, 'dezao': 10.0, 'dezinha': 10.0,
      'cinquentão': 50.0, 'cinquentao': 50.0, 'cinquentinha': 50.0,
      'quarentinha': 40.0, 'trintinha': 30.0, 'quinzinha': 15.0,
      'cemzão': 100.0, 'cemzao': 100.0, 'cemzinho': 100.0,
      'barão': 1000.0, 'barao': 1000.0, 'um barão': 1000.0, 'dois paus': 2000.0
    };
    for (final entry in slangMap.entries) {
      if (lower == entry.key || lower.startsWith('${entry.key} ')) {
        return entry.value;
      }
    }

    // A bare answer ("700", "R$ 700", "700 reais") — but still never a day,
    // time, installment count or card ending ("no pix dia 10", "em 3x",
    // "meu cpf termina em 12" used to become the value).
    return _pickAmount(lower, requireMoneyContext: false);
  }

  /// Public, rule-based category guess for arbitrary text — no amount, payment
  /// method, or ML vector required. Used by features like the affordability
  /// check ("posso comprar um notebook de 3000?") that need a category hint
  /// without going through full transaction parsing.
  static String guessCategoryFromText(String text) {
    return _resolveContextualCategory(text.toLowerCase(), 'unknown');
  }

  /// Systematically classifies input text into one of Krezio's financial categories
  /// based on comprehensive lexical, brand, and entity indicators.
  // "Estácio" (the college) — as a word, not inside "estacionamento".
  static final RegExp _estacioBrand = RegExp(r'\bestacio\b');

  // "Dia" (the supermarket chain) — not "dia 15", "todo dia", "no dia 5",
  // "há 3 dias" (dates were filing things under supermarket).
  static final RegExp _diaSupermarket = RegExp(
    r'\bdia\b(?!\s*(?:\d|primeiro|[uú]til|seguinte|anterior|inteiro|todo|de\s|do\s|da\s))',
  );
  static final RegExp _diaAsDate = RegExp(r'\b(?:todo|esse|este|nesse|neste|outro|mesmo|um|o|por|ao|cada|bom|meio)\s+dia\b');

  // Filling up the car is transport even when the sentence mentions where the
  // user was coming from ("na volta da academia, abasteci 100 no posto" was
  // filed under health). "posto de saúde" is not a gas station.
  static final RegExp _fuelPurchase = RegExp(
    r'\babastec\w*|\b(?:gasolina|etanol|combust[ií]vel|diesel)(?![a-zà-úç])|\bposto(?![a-zà-úç])(?!\s+de\s+sa[uú]de)',
  );

  /// Whether [term] names a specific kind of purchase (fuel) that the
  /// record titled [title] is not, though both share a category: "a
  /// gasolina" can be the "Posto", not the "Uber" (CHAOS-A-015). A title that
  /// is only a category's label says nothing about the kind.
  /// The other side of [namesOtherKind]: "a gasolina" and the "Posto Shell"
  /// are the same kind of purchase — the word names the record as surely
  /// as its title would.
  static bool namesSameKind(String term, String title) =>
      _fuelPurchase.hasMatch(CategoryNameMatcher.foldAccents(term.toLowerCase())) &&
      _fuelPurchase.hasMatch(CategoryNameMatcher.foldAccents(title.toLowerCase()));

  static bool namesOtherKind(String term, String title) {
    if (isCategoryLabel(title)) return false;
    final t = CategoryNameMatcher.foldAccents(term.toLowerCase());
    final r = CategoryNameMatcher.foldAccents(title.toLowerCase());
    return _fuelPurchase.hasMatch(t) && !_fuelPurchase.hasMatch(r);
  }

  // Eating out, in its verb forms too ("acabei almoçando fora", "jantei"), and
  // coffee ("2 cafés"), trips and hotels — leisure & food. "almofada" is not
  // food. (`\b` is ASCII-only in Dart, so word ends use a lookahead.)
  static final RegExp _eatingOutOrTrip = RegExp(
    r'\b(?:almo[cç](?:o|os|ando|ei|amos|ar)|jant(?:ar|ei|ando|amos)|lanch(?:ei|ando|onete)|'
    r'caf[eé]s?|viage(?:m|ns)|hotel|hot[eé]is|pousada|airbnb|hospedagem)(?![a-zà-úç])',
  );

  // Bakery = everyday groceries (was asked "onde foi o gasto?" every time).
  static final RegExp _bakery = RegExp(r'\b(?:padarias?|panificadora)(?![a-zà-úç])');

  // Gifts and toys have an obvious category: "outros gastos",
  // without asking the category again.
  static final RegExp _giftsAndToys = RegExp(r'\b(?:presentes?|brinquedos?)(?![a-zà-úç])');

  static String _resolveContextualCategory(String lower, String modelPredicted) {
    if (_fuelPurchase.hasMatch(lower)) return 'transport';

    // 1. EDUCAÇÃO, PLATAFORMAS & INTELIGÊNCIAS ARTIFICIAIS
    if (_hasTermOrDiminutive(lower, 'faculdade') || _hasTermOrDiminutive(lower, 'matrícula') || _hasTermOrDiminutive(lower, 'matricula') || _hasTermOrDiminutive(lower, 'mensalidade escolar') || _hasTermOrDiminutive(lower, 'escola') || _hasTermOrDiminutive(lower, 'escolar') || _hasTermOrDiminutive(lower, 'creche') ||
        _hasTermOrDiminutive(lower, 'pós-graduação') || _hasTermOrDiminutive(lower, 'pos-graduacao') || _hasTermOrDiminutive(lower, 'mba') || _hasTermOrDiminutive(lower, 'curso') ||
        _hasTermOrDiminutive(lower, 'udemy') || _hasTermOrDiminutive(lower, 'coursera') || _hasTermOrDiminutive(lower, 'alura') || _hasTermOrDiminutive(lower, 'hotmart') ||
        _hasTermOrDiminutive(lower, 'livro') || _hasTermOrDiminutive(lower, 'apostila') || _hasTermOrDiminutive(lower, 'material escolar') || _hasTermOrDiminutive(lower, 'estácio') ||
        _estacioBrand.hasMatch(lower) || _hasTermOrDiminutive(lower, 'puc') || _hasTermOrDiminutive(lower, 'fgv') || _hasTermOrDiminutive(lower, 'unip') || _hasTermOrDiminutive(lower, 'anhanguera') ||
        _hasTermOrDiminutive(lower, 'claude') || _hasTermOrDiminutive(lower, 'chatgpt') || _hasTermOrDiminutive(lower, 'chat gpt') || _hasTermOrDiminutive(lower, 'openai') ||
        _hasTermOrDiminutive(lower, 'anthropic') || _hasTermOrDiminutive(lower, 'gemini') || _hasTermOrDiminutive(lower, 'copilot') || _hasTermOrDiminutive(lower, 'perplexity') ||
        _hasTermOrDiminutive(lower, 'deepseek') || _hasTermOrDiminutive(lower, 'midjourney') || _hasTermOrDiminutive(lower, 'cursor') || _hasTermOrDiminutive(lower, 'duolingo') ||
        _hasTermOrDiminutive(lower, 'cambly') || _hasTermOrDiminutive(lower, 'open english') || _hasTermOrDiminutive(lower, 'descomplica') || _hasTermOrDiminutive(lower, 'rocketseat')) {
      return 'education';
    }

    // 2. SALÁRIO E RECEITAS TRABALHISTAS
    if (_hasTermOrDiminutive(lower, 'salario') || _hasTermOrDiminutive(lower, 'salário') || _hasTermOrDiminutive(lower, 'adiantamento') || _hasTermOrDiminutive(lower, 'vale refeição') ||
        _hasTermOrDiminutive(lower, 'vale alimentação') || _hasTermOrDiminutive(lower, 'décimo terceiro') || _hasTermOrDiminutive(lower, '13º') || _hasTermOrDiminutive(lower, '13o') ||
        _hasTermOrDiminutive(lower, 'férias') || _hasTermOrDiminutive(lower, 'ferias') || _hasTermOrDiminutive(lower, 'pró-labore') || _hasTermOrDiminutive(lower, 'pro-labore') ||
        _hasTermOrDiminutive(lower, 'comissão') || _hasTermOrDiminutive(lower, 'comissao') || _hasTermOrDiminutive(lower, 'plr') || _hasTermOrDiminutive(lower, 'bônus') || _hasTermOrDiminutive(lower, 'bonus')) {
      return 'salary';
    }

    // 3. INVESTIMENTOS
    if (_hasTermOrDiminutive(lower, 'investimento') || _hasTermOrDiminutive(lower, 'aporte') || _hasTermOrDiminutive(lower, 'ações') || _hasTermOrDiminutive(lower, 'acoes') ||
        _hasTermOrDiminutive(lower, 'dividendos') || _hasTermOrDiminutive(lower, 'rendimento') || _hasTermOrDiminutive(lower, 'jcp') || _hasTermOrDiminutive(lower, 'tesouro direto') ||
        _hasTermOrDiminutive(lower, 'tesouro selic') || _hasTermOrDiminutive(lower, 'cdb') || _hasTermOrDiminutive(lower, 'lci') || _hasTermOrDiminutive(lower, 'lca') ||
        _hasTermOrDiminutive(lower, 'fii') || _hasTermOrDiminutive(lower, 'cripto') || _hasTermOrDiminutive(lower, 'bitcoin') || _hasTermOrDiminutive(lower, 'btc') ||
        _hasTermOrDiminutive(lower, 'ethereum') || _hasTermOrDiminutive(lower, 'eth') || _hasTermOrDiminutive(lower, 'binance') || _hasTermOrDiminutive(lower, 'nuinvest') ||
        _hasTermOrDiminutive(lower, 'xp') || _hasTermOrDiminutive(lower, 'rico') || _hasTermOrDiminutive(lower, 'btg')) {
      return 'investment';
    }

    // 4. SAÚDE, FARMÁCIA & FITNESS
    if (_hasTermOrDiminutive(lower, 'farmacia') || _hasTermOrDiminutive(lower, 'farmácia') || _hasTermOrDiminutive(lower, 'droga raia') || _hasTermOrDiminutive(lower, 'drogasil') ||
        _hasTermOrDiminutive(lower, 'pague menos') || _hasTermOrDiminutive(lower, 'panvel') || _hasTermOrDiminutive(lower, 'pacheco') || _hasTermOrDiminutive(lower, 'extrafarma') ||
        _hasTermOrDiminutive(lower, 'drogaria') || _hasTermOrDiminutive(lower, 'remedio') || _hasTermOrDiminutive(lower, 'remédio') || _hasTermOrDiminutive(lower, 'medicamento') ||
        _hasTermOrDiminutive(lower, 'dipirona') || _hasTermOrDiminutive(lower, 'paracetamol') || _hasTermOrDiminutive(lower, 'ibuprofeno') || _hasTermOrDiminutive(lower, 'dorflex') ||
        _hasTermOrDiminutive(lower, 'neosaldina') || _hasTermOrDiminutive(lower, 'benegrip') || _hasTermOrDiminutive(lower, 'buscopan') || _hasTermOrDiminutive(lower, 'antialérgico') ||
        _hasTermOrDiminutive(lower, 'antialergico') || _hasTermOrDiminutive(lower, 'smart fit') || _hasTermOrDiminutive(lower, 'smartfit') || _hasTermOrDiminutive(lower, 'bluefit') ||
        _hasTermOrDiminutive(lower, 'bio ritmo') || _hasTermOrDiminutive(lower, 'selfit') || _hasTermOrDiminutive(lower, 'academia') || _hasTermOrDiminutive(lower, 'musculação') ||
        _hasTermOrDiminutive(lower, 'musculacao') || _hasTermOrDiminutive(lower, 'crossfit') || _hasTermOrDiminutive(lower, 'pilates') || _hasTermOrDiminutive(lower, 'whey') ||
        _hasTermOrDiminutive(lower, 'creatina') || _hasTermOrDiminutive(lower, 'growth') || _hasTermOrDiminutive(lower, 'max titanium') || _hasTermOrDiminutive(lower, 'integralmedica') ||
        _hasTermOrDiminutive(lower, 'medico') || _hasTermOrDiminutive(lower, 'médico') || _hasTermOrDiminutive(lower, 'consulta médica') || _hasTermOrDiminutive(lower, 'consulta') || _hasTermOrDiminutive(lower, 'psicologo') ||
        _hasTermOrDiminutive(lower, 'psicólogo') || _hasTermOrDiminutive(lower, 'terapia') || _hasTermOrDiminutive(lower, 'dentista') || _hasTermOrDiminutive(lower, 'odontológico') || _hasTermOrDiminutive(lower, 'odontologico') || _hasTermOrDiminutive(lower, 'dental') || _hasTermOrDiminutive(lower, 'ortodontista') ||
        _hasTermOrDiminutive(lower, 'exame') || _hasTermOrDiminutive(lower, 'laboratório') || _hasTermOrDiminutive(lower, 'fleury') || _hasTermOrDiminutive(lower, 'delboni') ||
        _hasTermOrDiminutive(lower, 'ótica') || _hasTermOrDiminutive(lower, 'otica') || _hasTermOrDiminutive(lower, 'lentes de contato') || _hasTermOrDiminutive(lower, 'plano de saúde') ||
        _hasTermOrDiminutive(lower, 'unimed') || _hasTermOrDiminutive(lower, 'amil') || _hasTermOrDiminutive(lower, 'bradesco saúde') || _hasTermOrDiminutive(lower, 'sulamerica') ||
        _hasTermOrDiminutive(lower, 'notredame') || _hasTermOrDiminutive(lower, 'hapvida') ||
        _hasTermOrDiminutive(lower, 'gympass') || _hasTermOrDiminutive(lower, 'wellhub') || _hasTermOrDiminutive(lower, 'totalpass')) {
      return 'health';
    }

    // 5. TRANSPORTE, COMBUSTÍVEL & VEÍCULOS
    if (_hasTermOrDiminutive(lower, 'gasolina') || _hasTermOrDiminutive(lower, 'etanol') || _hasTermOrDiminutive(lower, 'combustível') || _hasTermOrDiminutive(lower, 'combustivel') ||
        _hasTermOrDiminutive(lower, 'diesel') || _hasTermOrDiminutive(lower, 'gnv') || _hasTermOrDiminutive(lower, 'aditivada') || _hasTermOrDiminutive(lower, 'posto ') ||
        _hasTermOrDiminutive(lower, 'posto shell') || _hasTermOrDiminutive(lower, 'posto ipiranga') || _hasTermOrDiminutive(lower, 'posto petrobras') || _hasTermOrDiminutive(lower, 'posto br') ||
        _hasTermOrDiminutive(lower, 'posto ale') || _hasTermOrDiminutive(lower, 'shell') || _hasTermOrDiminutive(lower, 'ipiranga') || _hasTermOrDiminutive(lower, 'petrobras') ||
        _hasTermOrDiminutive(lower, 'graal') || _hasTermOrDiminutive(lower, 'abastecer') || _hasTermOrDiminutive(lower, 'abasteci') || _hasTermOrDiminutive(lower, 'uber') ||
        RegExp(r'\b(?:na|no|pela|pelo|app)\s+99\b|\b99\s*(?:pop|taxis|taxi|moto)\b').hasMatch(lower) || _hasTermOrDiminutive(lower, 'taxi') ||
        _hasTermOrDiminutive(lower, 'táxi') || _hasTermOrDiminutive(lower, 'corrida') || _hasTermOrDiminutive(lower, 'indrive') || _hasTermOrDiminutive(lower, 'cabify') ||
        _hasTermOrDiminutive(lower, 'onibus') || _hasTermOrDiminutive(lower, 'ônibus') || _hasTermOrDiminutive(lower, 'busão') || _hasTermOrDiminutive(lower, 'metro') ||
        _hasTermOrDiminutive(lower, 'metrô') || _hasTermOrDiminutive(lower, 'trem') || _hasTermOrDiminutive(lower, 'bilhete único') || _hasTermOrDiminutive(lower, 'bilhete unico') ||
        _hasTermOrDiminutive(lower, 'cartão top') || _hasTermOrDiminutive(lower, 'pedagio') || _hasTermOrDiminutive(lower, 'pedágio') || _hasTermOrDiminutive(lower, 'sem parar') ||
        _hasTermOrDiminutive(lower, 'conectcar') || _hasTermOrDiminutive(lower, 'veloe') || _hasTermOrDiminutive(lower, 'latam') || RegExp(r'\b(?:linha|linhas|cia|aérea|aerea)?\s*gol\b').hasMatch(lower) ||
        _hasTermOrDiminutive(lower, 'azul') || _hasTermOrDiminutive(lower, 'passagem aérea') || _hasTermOrDiminutive(lower, 'moto') || _hasTermOrDiminutive(lower, 'motocicleta') ||
        _hasTermOrDiminutive(lower, 'carro') || _hasTermOrDiminutive(lower, 'veiculo') || _hasTermOrDiminutive(lower, 'veículo') || _hasTermOrDiminutive(lower, 'automovel') || _hasTermOrDiminutive(lower, 'automóvel') ||
        _hasTermOrDiminutive(lower, 'bike') || _hasTermOrDiminutive(lower, 'bicicleta') || _hasTermOrDiminutive(lower, 'patinete') || _hasTermOrDiminutive(lower, 'ipva') ||
        _hasTermOrDiminutive(lower, 'multa') || _hasTermOrDiminutive(lower, 'detran') || _hasTermOrDiminutive(lower, 'licenciamento') || _hasTermOrDiminutive(lower, 'pneu') ||
        _hasTermOrDiminutive(lower, 'oficina') || _hasTermOrDiminutive(lower, 'mecanico') || _hasTermOrDiminutive(lower, 'mecânico') || _hasTermOrDiminutive(lower, 'estacionamento') || _hasTermOrDiminutive(lower, 'flanelinha') ||
        _hasTermOrDiminutive(lower, 'estapar') || _hasTermOrDiminutive(lower, 'zona azul') || _hasTermOrDiminutive(lower, 'localiza') || _hasTermOrDiminutive(lower, 'movida') ||
        _hasTermOrDiminutive(lower, 'unidas') || _hasTermOrDiminutive(lower, 'troca de óleo') || _hasTermOrDiminutive(lower, 'alinhamento') || _hasTermOrDiminutive(lower, 'balanceamento')) {
      return 'transport';
    }

    // 6. ALIMENTAÇÃO, LAZER, FAST FOOD, INSTRUMENTOS & STREAMING
    if (RegExp(r'\b(mc|bk)\b').hasMatch(lower) || _hasTermOrDiminutive(lower, 'mcdonald') || _hasTermOrDiminutive(lower, 'mequi') || _hasTermOrDiminutive(lower, 'méqui') ||
        _hasTermOrDiminutive(lower, 'burger king') || _hasTermOrDiminutive(lower, 'subway') || _hasTermOrDiminutive(lower, 'bobs') || _hasTermOrDiminutive(lower, 'giraffas') ||
        _hasTermOrDiminutive(lower, 'habibs') || _hasTermOrDiminutive(lower, 'ragazzo') || _hasTermOrDiminutive(lower, 'spoleto') || _hasTermOrDiminutive(lower, 'outback') ||
        _hasTermOrDiminutive(lower, 'madero') || _hasTermOrDiminutive(lower, 'jeronimo') || _hasTermOrDiminutive(lower, 'popeyes') || _hasTermOrDiminutive(lower, 'kfc') ||
        _hasTermOrDiminutive(lower, 'pizza hut') || _hasTermOrDiminutive(lower, 'dominos') || _hasTermOrDiminutive(lower, 'taco bell') || _hasTermOrDiminutive(lower, 'coco bambu') ||
        _hasTermOrDiminutive(lower, 'bacio di latte') || _hasTermOrDiminutive(lower, 'cacau show') || _hasTermOrDiminutive(lower, 'kopenhagen') || _hasTermOrDiminutive(lower, 'dengo') ||
        _hasTermOrDiminutive(lower, 'brasil cacau') || _hasTermOrDiminutive(lower, 'starbucks') || _hasTermOrDiminutive(lower, 'the coffee') || _hasTermOrDiminutive(lower, 'we coffee') ||
        _hasTermOrDiminutive(lower, 'rei do mate') || _hasTermOrDiminutive(lower, 'ifood') || _hasTermOrDiminutive(lower, 'zé delivery') || _hasTermOrDiminutive(lower, 'ze delivery') ||
        _hasTermOrDiminutive(lower, 'rappi') || _hasTermOrDiminutive(lower, 'aiqfome') || _hasTermOrDiminutive(lower, 'pastel') || _hasTermOrDiminutive(lower, 'pastelaria') || _hasTermOrDiminutive(lower, 'lanche') ||
        _hasTermOrDiminutive(lower, 'pizza') || _hasTermOrDiminutive(lower, 'hamburguer') || _hasTermOrDiminutive(lower, 'hambúrguer') || _hasTermOrDiminutive(lower, 'burger') ||
        _hasTermOrDiminutive(lower, 'esfirra') || _hasTermOrDiminutive(lower, 'esfiha') || _hasTermOrDiminutive(lower, 'kibe') || _hasTermOrDiminutive(lower, 'coxinha') ||
        _hasTermOrDiminutive(lower, 'pão de queijo') || _hasTermOrDiminutive(lower, 'tapioca') || _hasTermOrDiminutive(lower, 'açaí') || _hasTermOrDiminutive(lower, 'acai') ||
        _hasTermOrDiminutive(lower, 'sushi') || _hasTermOrDiminutive(lower, 'sashimi') || _hasTermOrDiminutive(lower, 'temaki') || _hasTermOrDiminutive(lower, 'yakisoba') ||
        _hasTermOrDiminutive(lower, 'poke') || _hasTermOrDiminutive(lower, 'churrasco') || _hasTermOrDiminutive(lower, 'picanha') || _hasTermOrDiminutive(lower, 'parmegiana') ||
        _hasTermOrDiminutive(lower, 'feijoada') || _hasTermOrDiminutive(lower, 'marmita') || _hasTermOrDiminutive(lower, 'marmitex') || _hasTermOrDiminutive(lower, 'almoço') ||
        _hasTermOrDiminutive(lower, 'almoco') || _hasTermOrDiminutive(lower, 'jantar') || _hasTermOrDiminutive(lower, 'cafezinho') || _hasTermOrDiminutive(lower, 'cappuccino') ||
        _hasTermOrDiminutive(lower, 'cerveja') || _hasTermOrDiminutive(lower, 'chope') || _hasTermOrDiminutive(lower, 'chopp') || _hasTermOrDiminutive(lower, 'drink') ||
        _hasTermOrDiminutive(lower, 'caipirinha') || _hasTermOrDiminutive(lower, 'gin') || _hasTermOrDiminutive(lower, 'vodka') || _hasTermOrDiminutive(lower, 'whisky') ||
        _hasTermOrDiminutive(lower, 'refrigerante') || _hasTermOrDiminutive(lower, 'refri') || _hasTermOrDiminutive(lower, 'milkshake') || _hasTermOrDiminutive(lower, 'sorvete') || _hasTermOrDiminutive(lower, 'sorveteria') ||
        _hasTermOrDiminutive(lower, 'brigadeiro') || _hasTermOrDiminutive(lower, 'trufa') || _hasTermOrDiminutive(lower, 'chocolate') ||
        _hasTermOrDiminutive(lower, 'docinho') || _hasTermOrDiminutive(lower, 'docinhos') || _hasTermOrDiminutive(lower, 'doce') || _hasTermOrDiminutive(lower, 'doces') ||
        _hasTermOrDiminutive(lower, 'bala') || _hasTermOrDiminutive(lower, 'balas') || _hasTermOrDiminutive(lower, 'bombom') || _hasTermOrDiminutive(lower, 'bombons') ||
        _hasTermOrDiminutive(lower, 'pirulito') || _hasTermOrDiminutive(lower, 'chiclete') || _hasTermOrDiminutive(lower, 'chicletes') || _hasTermOrDiminutive(lower, 'guloseima') ||
        _hasTermOrDiminutive(lower, 'paçoca') || _hasTermOrDiminutive(lower, 'pacoca') || _hasTermOrDiminutive(lower, 'pé-de-moleque') || _hasTermOrDiminutive(lower, 'pe-de-moleque') ||
        _hasTermOrDiminutive(lower, 'marshmallow') || _hasTermOrDiminutive(lower, 'pudim') || _hasTermOrDiminutive(lower, 'biscoito') || _hasTermOrDiminutive(lower, 'bolacha') ||
        _hasTermOrDiminutive(lower, 'salgadinho') || _hasTermOrDiminutive(lower, 'pipoca') || _hasTermOrDiminutive(lower, 'restaurante') ||
        // "\bbar\b": also "a conta do bar," (a comma or the end after it).
        RegExp(r'\bbar\b').hasMatch(lower) || _hasTermOrDiminutive(lower, 'barzinho') || _hasTermOrDiminutive(lower, 'boteco') || _hasTermOrDiminutive(lower, 'pub') ||
        _hasTermOrDiminutive(lower, 'pizzaria') || _hasTermOrDiminutive(lower, 'hamburgueria') || _hasTermOrDiminutive(lower, 'churrascaria') || _hasTermOrDiminutive(lower, 'cafeteria') ||
        _hasTermOrDiminutive(lower, 'cinema') || _hasTermOrDiminutive(lower, 'cinemark') || _hasTermOrDiminutive(lower, 'cinepolis') || _hasTermOrDiminutive(lower, 'cinépolis') ||
        _hasTermOrDiminutive(lower, 'uci') || _hasTermOrDiminutive(lower, 'teatro') || _hasTermOrDiminutive(lower, 'show') || _hasTermOrDiminutive(lower, 'ingresso') ||
        _hasTermOrDiminutive(lower, 'sympla') || _hasTermOrDiminutive(lower, 'eventim') || _hasTermOrDiminutive(lower, 'parque') || _hasTermOrDiminutive(lower, 'hopi hari') ||
        _hasTermOrDiminutive(lower, 'beto carrero') || _hasTermOrDiminutive(lower, 'museu') || _hasTermOrDiminutive(lower, 'balada') || _hasTermOrDiminutive(lower, 'netflix') ||
        _hasTermOrDiminutive(lower, 'spotify') || _hasTermOrDiminutive(lower, 'amazon prime') || _hasTermOrDiminutive(lower, 'prime video') || _hasTermOrDiminutive(lower, 'disney') ||
        _hasTermOrDiminutive(lower, 'hbo') || _hasTermOrDiminutive(lower, 'max') || _hasTermOrDiminutive(lower, 'globoplay') || _hasTermOrDiminutive(lower, 'apple tv') ||
        _hasTermOrDiminutive(lower, 'deezer') || _hasTermOrDiminutive(lower, 'youtube premium') || _hasTermOrDiminutive(lower, 'crunchyroll') || _hasTermOrDiminutive(lower, 'twitch') ||
        _hasTermOrDiminutive(lower, 'paramount') || _hasTermOrDiminutive(lower, 'star+') || _hasTermOrDiminutive(lower, 'star plus') || _hasTermOrDiminutive(lower, 'audible') || _hasTermOrDiminutive(lower, 'kindle unlimited') ||
        _hasTermOrDiminutive(lower, 'steam') || _hasTermOrDiminutive(lower, 'playstation') || _hasTermOrDiminutive(lower, 'psn') || _hasTermOrDiminutive(lower, 'ps plus') || _hasTermOrDiminutive(lower, 'xbox') ||
        _hasTermOrDiminutive(lower, 'game pass') || _hasTermOrDiminutive(lower, 'gamepass') || _hasTermOrDiminutive(lower, 'nintendo') || _hasTermOrDiminutive(lower, 'epic games') || _hasTermOrDiminutive(lower, 'roblox') ||
        _hasTermOrDiminutive(lower, 'videogame') || _hasTermOrDiminutive(lower, 'console') ||
        _hasTermOrDiminutive(lower, 'violão') || _hasTermOrDiminutive(lower, 'violao') || _hasTermOrDiminutive(lower, 'guitarra') || _hasTermOrDiminutive(lower, 'baixo') ||
        _hasTermOrDiminutive(lower, 'cavaquinho') || _hasTermOrDiminutive(lower, 'ukulele') || _hasTermOrDiminutive(lower, 'bateria') || _hasTermOrDiminutive(lower, 'teclado musical') ||
        _hasTermOrDiminutive(lower, 'piano') || _hasTermOrDiminutive(lower, 'flauta') || _hasTermOrDiminutive(lower, 'saxofone') || _hasTermOrDiminutive(lower, 'trompete') ||
        _hasTermOrDiminutive(lower, 'sanfona') || _hasTermOrDiminutive(lower, 'acordeon') || _hasTermOrDiminutive(lower, 'gaita') || _hasTermOrDiminutive(lower, 'violino') ||
        _hasTermOrDiminutive(lower, 'instrumento musical') || _hasTermOrDiminutive(lower, 'amplificador') || _hasTermOrDiminutive(lower, 'pedal de guitarra') || _hasTermOrDiminutive(lower, 'microfone') ||
        _eatingOutOrTrip.hasMatch(lower)) {
      return 'leisure';
    }

    // 7. SUPERMERCADO, HORTIFRUTI & COMPRAS DO MÊS
    if (_hasTermOrDiminutive(lower, 'mercado') || _hasTermOrDiminutive(lower, 'supermercado') || _hasTermOrDiminutive(lower, 'feira') || _hasTermOrDiminutive(lower, 'hortifruti') ||
        _hasTermOrDiminutive(lower, 'sacolão') || _hasTermOrDiminutive(lower, 'sacolao') || _hasTermOrDiminutive(lower, 'açougue') || _hasTermOrDiminutive(lower, 'acougue') ||
        _hasTermOrDiminutive(lower, 'peixaria') || _hasTermOrDiminutive(lower, 'mercearia') || _hasTermOrDiminutive(lower, 'carrefour') || _hasTermOrDiminutive(lower, 'pão de açúcar') ||
        _hasTermOrDiminutive(lower, 'pao de acucar') || _hasTermOrDiminutive(lower, 'extra') || _hasTermOrDiminutive(lower, 'assai') || _hasTermOrDiminutive(lower, 'assaí') ||
        _hasTermOrDiminutive(lower, 'atacadao') || _hasTermOrDiminutive(lower, 'atacadão') || _hasTermOrDiminutive(lower, 'sams club') || _hasTermOrDiminutive(lower, 'sam\'s club') ||
        _hasTermOrDiminutive(lower, 'big') || (_diaSupermarket.hasMatch(lower) && !_diaAsDate.hasMatch(lower)) || _hasTermOrDiminutive(lower, 'hirota') || _hasTermOrDiminutive(lower, 'mambo') ||
        _hasTermOrDiminutive(lower, 'st marche') || _hasTermOrDiminutive(lower, 'sonda') || _hasTermOrDiminutive(lower, 'zaffari') || _hasTermOrDiminutive(lower, 'oxxo') ||
        _hasTermOrDiminutive(lower, 'arroz') || _hasTermOrDiminutive(lower, 'feijao') || _hasTermOrDiminutive(lower, 'feijão') || _hasTermOrDiminutive(lower, 'óleo de cozinha') ||
        _hasTermOrDiminutive(lower, 'azeite') || _hasTermOrDiminutive(lower, 'leite') || _hasTermOrDiminutive(lower, 'ovos') || _hasTermOrDiminutive(lower, 'manteiga') ||
        _hasTermOrDiminutive(lower, 'detergente') || _hasTermOrDiminutive(lower, 'sabão em pó') || _hasTermOrDiminutive(lower, 'amaciante') || _hasTermOrDiminutive(lower, 'papel higiênico') ||
        _hasTermOrDiminutive(lower, 'frango congelado') || _hasTermOrDiminutive(lower, 'carne moída') || _hasTermOrDiminutive(lower, 'peito de frango') ||
        _bakery.hasMatch(lower)) {
      return 'supermarket';
    }

    // 8. MORADIA, CONTAS DE CASA & TELECOM
    if (_hasTermOrDiminutive(lower, 'enel') || _hasTermOrDiminutive(lower, 'cpfl') || _hasTermOrDiminutive(lower, 'light') || _hasTermOrDiminutive(lower, 'cemig') ||
        _hasTermOrDiminutive(lower, 'copel') || _hasTermOrDiminutive(lower, 'sabesp') || _hasTermOrDiminutive(lower, 'copasa') || _hasTermOrDiminutive(lower, 'sanepar') ||
        _hasTermOrDiminutive(lower, 'comgás') || _hasTermOrDiminutive(lower, 'comgas') || _hasTermOrDiminutive(lower, 'vivo') || _hasTermOrDiminutive(lower, 'claro') ||
        RegExp(r'\b(tim|oi)\b').hasMatch(lower) ||
        _hasTermOrDiminutive(lower, 'plano de celular') || _hasTermOrDiminutive(lower, 'plano celular') || _hasTermOrDiminutive(lower, 'plano móvel') || _hasTermOrDiminutive(lower, 'plano movel') ||
        _hasTermOrDiminutive(lower, 'plano de internet') || _hasTermOrDiminutive(lower, 'recarga de celular') || _hasTermOrDiminutive(lower, 'recarga celular') ||
        _hasTermOrDiminutive(lower, 'claro flex') || _hasTermOrDiminutive(lower, 'vivo easy') || _hasTermOrDiminutive(lower, 'tim beta') || _hasTermOrDiminutive(lower, 'tim controle') ||
        _hasTermOrDiminutive(lower, 'claro controle') || _hasTermOrDiminutive(lower, 'vivo controle') ||
        _hasTermOrDiminutive(lower, 'luz') || _hasTermOrDiminutive(lower, 'energia') ||
        _hasTermOrDiminutive(lower, 'água') || _hasTermOrDiminutive(lower, 'agua') || RegExp(r'\b(gás|gas)\b').hasMatch(lower) ||
        _hasTermOrDiminutive(lower, 'botijão') || _hasTermOrDiminutive(lower, 'internet') || _hasTermOrDiminutive(lower, 'wifi') || _hasTermOrDiminutive(lower, 'aluguel') || _hasTermOrDiminutive(lower, 'aluguéis') || _hasTermOrDiminutive(lower, 'alugueis') ||
        _hasTermOrDiminutive(lower, 'condominio') || _hasTermOrDiminutive(lower, 'condomínio') || _hasTermOrDiminutive(lower, 'iptu') || _hasTermOrDiminutive(lower, 'quintoandar') ||
        _hasTermOrDiminutive(lower, 'loft') || _hasTermOrDiminutive(lower, 'diarista') || _hasTermOrDiminutive(lower, 'faxina') || _hasTermOrDiminutive(lower, 'sofa') ||
        _hasTermOrDiminutive(lower, 'sofá') || _hasTermOrDiminutive(lower, 'cama') || _hasTermOrDiminutive(lower, 'colchão') || _hasTermOrDiminutive(lower, 'colchao') ||
        _hasTermOrDiminutive(lower, 'geladeira') || _hasTermOrDiminutive(lower, 'fogao') || _hasTermOrDiminutive(lower, 'fogão') || _hasTermOrDiminutive(lower, 'microondas') ||
        _hasTermOrDiminutive(lower, 'micro-ondas') || _hasTermOrDiminutive(lower, 'airfryer') || _hasTermOrDiminutive(lower, 'air fryer') || _hasTermOrDiminutive(lower, 'liquidificador') || _hasTermOrDiminutive(lower, 'máquina de lavar') ||
        _hasTermOrDiminutive(lower, 'maquina de lavar') || _hasTermOrDiminutive(lower, 'secadora') || _hasTermOrDiminutive(lower, 'ar condicionado') || _hasTermOrDiminutive(lower, 'ventilador') ||
        _hasTermOrDiminutive(lower, 'aquecedor') || _hasTermOrDiminutive(lower, 'purificador de água') || _hasTermOrDiminutive(lower, 'purificador de agua') || _hasTermOrDiminutive(lower, 'aspirador de pó') ||
        _hasTermOrDiminutive(lower, 'aspirador de po') || _hasTermOrDiminutive(lower, 'exaustor') || _hasTermOrDiminutive(lower, 'coifa') || _hasTermOrDiminutive(lower, 'forno elétrico') ||
        _hasTermOrDiminutive(lower, 'forno eletrico') ||
        // Móveis ('mesa'/'estante' use word boundaries so they don't misfire on
        // 'mesada' or 'restante', which are unrelated common Portuguese words)
        RegExp(r'\bmesas?\b').hasMatch(lower) || _hasTermOrDiminutive(lower, 'cadeira') || _hasTermOrDiminutive(lower, 'escrivaninha') ||
        RegExp(r'\bestantes?\b').hasMatch(lower) ||
        _hasTermOrDiminutive(lower, 'guarda-roupa') || _hasTermOrDiminutive(lower, 'guarda roupa') || _hasTermOrDiminutive(lower, 'armário') || _hasTermOrDiminutive(lower, 'armario') ||
        _hasTermOrDiminutive(lower, 'cômoda') || _hasTermOrDiminutive(lower, 'comoda') || _hasTermOrDiminutive(lower, 'criado-mudo') || _hasTermOrDiminutive(lower, 'criado mudo') ||
        _hasTermOrDiminutive(lower, 'rack') || _hasTermOrDiminutive(lower, 'aparador') || _hasTermOrDiminutive(lower, 'banqueta') || _hasTermOrDiminutive(lower, 'puff') ||
        _hasTermOrDiminutive(lower, 'estofado') || _hasTermOrDiminutive(lower, 'poltrona') || _hasTermOrDiminutive(lower, 'tapete') || _hasTermOrDiminutive(lower, 'cortina') ||
        _hasTermOrDiminutive(lower, 'persiana') || _hasTermOrDiminutive(lower, 'espelho') || _hasTermOrDiminutive(lower, 'prateleira') || _hasTermOrDiminutive(lower, 'luminária') ||
        _hasTermOrDiminutive(lower, 'luminaria') || _hasTermOrDiminutive(lower, 'abajur') ||
        // Utensílios domésticos
        _hasTermOrDiminutive(lower, 'panela') || _hasTermOrDiminutive(lower, 'panela de pressão') || _hasTermOrDiminutive(lower, 'panela de pressao') ||
        _hasTermOrDiminutive(lower, 'jogo de panelas') || _hasTermOrDiminutive(lower, 'talheres') || _hasTermOrDiminutive(lower, 'louça') || _hasTermOrDiminutive(lower, 'louca') ||
        _hasTermOrDiminutive(lower, 'jogo de jantar') ||
        _hasTermOrDiminutive(lower, 'leroy merlin') || _hasTermOrDiminutive(lower, 'telhanorte') ||
        _hasTermOrDiminutive(lower, 'tok&stok') || _hasTermOrDiminutive(lower, 'tok stok') || _hasTermOrDiminutive(lower, 'camicado') || _hasTermOrDiminutive(lower, 'ortobom') ||
        _hasTermOrDiminutive(lower, 'colchão emma') || _hasTermOrDiminutive(lower, 'emma colchões')) {
      return 'housing';
    }

    // 9. COMPRAS, VESTUÁRIO, MARKETPLACES, ELETRÔNICOS & PET
    if (_hasTermOrDiminutive(lower, 'amazon') || _hasTermOrDiminutive(lower, 'mercado livre') || _hasTermOrDiminutive(lower, 'mercadolivre') || _hasTermOrDiminutive(lower, 'shopee') ||
        _hasTermOrDiminutive(lower, 'shein') || _hasTermOrDiminutive(lower, 'aliexpress') || _hasTermOrDiminutive(lower, 'magalu') || _hasTermOrDiminutive(lower, 'magazine luiza') ||
        _hasTermOrDiminutive(lower, 'casas bahia') || _hasTermOrDiminutive(lower, 'ponto frio') || _hasTermOrDiminutive(lower, 'fast shop') || _hasTermOrDiminutive(lower, 'kabum') ||
        _hasTermOrDiminutive(lower, 'pichau') || _hasTermOrDiminutive(lower, 'terabyte') || _hasTermOrDiminutive(lower, 'americanas') || _hasTermOrDiminutive(lower, 'zara') ||
        _hasTermOrDiminutive(lower, 'renner') || _hasTermOrDiminutive(lower, 'c&a') || _hasTermOrDiminutive(lower, 'riachuelo') || _hasTermOrDiminutive(lower, 'h&m') ||
        _hasTermOrDiminutive(lower, 'marisa') || _hasTermOrDiminutive(lower, 'hering') || _hasTermOrDiminutive(lower, 'reserva') || _hasTermOrDiminutive(lower, 'lacoste') ||
        _hasTermOrDiminutive(lower, 'calvin klein') || _hasTermOrDiminutive(lower, 'farm') || _hasTermOrDiminutive(lower, 'nike') || _hasTermOrDiminutive(lower, 'adidas') ||
        _hasTermOrDiminutive(lower, 'puma') || _hasTermOrDiminutive(lower, 'asics') || _hasTermOrDiminutive(lower, 'mizuno') || _hasTermOrDiminutive(lower, 'vans') ||
        _hasTermOrDiminutive(lower, 'all star') || _hasTermOrDiminutive(lower, 'converse') || _hasTermOrDiminutive(lower, 'olympikus') || _hasTermOrDiminutive(lower, 'havaianas') ||
        _hasTermOrDiminutive(lower, 'arezzo') || _hasTermOrDiminutive(lower, 'schutz') || _hasTermOrDiminutive(lower, 'melissa') || _hasTermOrDiminutive(lower, 'centauro') ||
        _hasTermOrDiminutive(lower, 'decathlon') || _hasTermOrDiminutive(lower, 'netshoes') || _hasTermOrDiminutive(lower, 'vivara') || _hasTermOrDiminutive(lower, 'pandora') ||
        _hasTermOrDiminutive(lower, 'swarovski') || _hasTermOrDiminutive(lower, 'sephora') || _hasTermOrDiminutive(lower, 'boticario') || _hasTermOrDiminutive(lower, 'boticário') ||
        (_hasTermOrDiminutive(lower, 'natura') && !_hasTermOrDiminutive(lower, 'assinatura')) || _hasTermOrDiminutive(lower, 'avon') || _hasTermOrDiminutive(lower, 'apple') || _hasTermOrDiminutive(lower, 'iphone') ||
        _hasTermOrDiminutive(lower, 'ipad') || _hasTermOrDiminutive(lower, 'macbook') || _hasTermOrDiminutive(lower, 'samsung') || _hasTermOrDiminutive(lower, 'xiaomi') ||
        _hasTermOrDiminutive(lower, 'dell') || _hasTermOrDiminutive(lower, 'notebook') || _hasTermOrDiminutive(lower, 'computador') || _hasTermOrDiminutive(lower, 'celular') ||
        _hasTermOrDiminutive(lower, 'smartphone') || _hasTermOrDiminutive(lower, 'fone') || _hasTermOrDiminutive(lower, 'headset') || _hasTermOrDiminutive(lower, 'teclado') ||
        _hasTermOrDiminutive(lower, 'mouse') || _hasTermOrDiminutive(lower, 'monitor') || _hasTermOrDiminutive(lower, 'smartwatch') || _hasTermOrDiminutive(lower, 'kindle') ||
        _hasTermOrDiminutive(lower, 'cobasi') || _hasTermOrDiminutive(lower, 'petz') || _hasTermOrDiminutive(lower, 'zee dog') || _hasTermOrDiminutive(lower, 'pet shop') ||
        _hasTermOrDiminutive(lower, 'ração') || _hasTermOrDiminutive(lower, 'racao') || _hasTermOrDiminutive(lower, 'areia de gato') || _hasTermOrDiminutive(lower, 'antipulgas') ||
        _hasTermOrDiminutive(lower, 'veterinário') || _hasTermOrDiminutive(lower, 'veterinario') || _hasTermOrDiminutive(lower, 'banho e tosa') || _hasTermOrDiminutive(lower, 'roupa') ||
        _hasTermOrDiminutive(lower, 'roupas') || _hasTermOrDiminutive(lower, 'camisa') || _hasTermOrDiminutive(lower, 'camiseta') || _hasTermOrDiminutive(lower, 'calça') ||
        _hasTermOrDiminutive(lower, 'calca') || _hasTermOrDiminutive(lower, 'vestido') || _hasTermOrDiminutive(lower, 'casaco') || _hasTermOrDiminutive(lower, 'tênis') ||
        _hasTermOrDiminutive(lower, 'tenis') || _hasTermOrDiminutive(lower, 'sapato') || _hasTermOrDiminutive(lower, 'perfume') || _hasTermOrDiminutive(lower, 'maquiagem') ||
        _giftsAndToys.hasMatch(lower)) {
      return 'expense_other';
    }

    // Everyday places and services said in colloquial/regional Portuguese
    // (R2-CONV-023). Checked last, so a bill named in the same sentence
    // ("paguei a luz na lotérica") keeps its own category.
    if (_everydayHousing.hasMatch(lower)) return 'housing';
    if (_everydayLeisure.hasMatch(lower)) return 'leisure';
    if (_everydayTransport.hasMatch(lower)) return 'transport';
    if (_everydayHealth.hasMatch(lower)) return 'health';
    if (_everydayServices.hasMatch(lower)) return 'expense_other';

    if (modelPredicted != 'unknown') {
      return modelPredicted;
    }
    return 'unknown';
  }

  static final RegExp _everydayHousing = RegExp(
      r'\b(?:seguro\s+(?:residencial|da\s+casa|do\s+apartamento|do\s+ap[eê])|iptu|diarista|faxineira|encanador|eletricista|g[aá]s\s+de\s+cozinha|botij[aã]o|'
      // Fixing something of the house is housing, not the car (ACC-B-018).
      r'(?:conserto|reparo|manuten[cç][aã]o|instala[cç][aã]o)\s+d[aoe]s?\s+(?:chuveiro|torneira|pia|geladeira|fog[aã]o|telhado|port[aã]o|janela|'
      r'vaso|descarga|m[aá]quina\s+de\s+lavar|ar[\s-]condicionado|interfone|tomada|fia[cç][aã]o|encanamento))(?![a-zà-úç])');
  static final RegExp _everydayLeisure = RegExp(
      r"\b(?:rol[eê]s?|rolezinho|espetinhos?|churrasquinho|combos?|bob'?s|caldo\s+de\s+cana|quiosque|lanchonete|boteco|petiscos?|porç[aã]o|porcao)(?![a-zà-úç])");
  static final RegExp _everydayTransport =
      RegExp(r'\b(?:lava[\s-]?(?:jato|r[aá]pido)|lavagem\s+d[oe]\s+carro|borracharia|funilaria|guincho|vistoria|mototaxi|moto[\s-]t[aá]xi)(?![a-zà-úç])');
  static final RegExp _everydayHealth =
      RegExp(r'\b(?:cl[ií]nicas?|hospital|pronto[\s-]socorro|fisioterap\w*|nutricionista|pediatra|vacinas?|consult[oó]rio)(?![a-zà-úç])');
  static final RegExp _everydayServices = RegExp(
      r'\b(?:barbeiro|barbearia|cabeleireir[oa]|manicure|banca(?:\s+de\s+(?:jornal|revista))?|lot[eé]rica|costureira|lavanderia|cart[oó]rio|xerox|despachante)(?![a-zà-úç])');

  static String? _extractPersonName(String text) {
    final patterns = [
      RegExp(r'(?:para\s+o\s+amigo|para\s+o\s+colega|para\s+o\s+primo|pro\s+amigo|pro\s+colega|pro\s+primo|pra\s+o\s+amigo|p/\s*o\s+amigo)\s+([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]+)', caseSensitive: false),
      RegExp(r'(?:para\s+a\s+amiga|para\s+a\s+colega|para\s+a\s+prima|pra\s+amiga|pra\s+colega|pra\s+prima|p/\s*a\s+amiga)\s+([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]+)', caseSensitive: false),
      RegExp(r'(?:para\s+o|pra\s+o|p/\s*o|pro|ao)\s+([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]+)', caseSensitive: false),
      RegExp(r'(?:para\s+a|pra\s+a|p/\s*a|pra|à)\s+([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]+)', caseSensitive: false),
      RegExp(r'(?:o|a)\s+([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]+)\s+(?:me\s+deve|prometeu|disse|falo|vai\s+me)', caseSensitive: false),
      RegExp(r'(?:cobrar|cobre|avise|avisar)\s+(?:o|a)?\s*([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]+)', caseSensitive: false),
    ];
    final stopWords = [
      'mim', 'ele', 'ela', 'eles', 'elas', 'dinheiro', 'conta', 'casa', 'meu', 'minha',
      'alguem', 'alguém', 'um', 'uma', 'amigo', 'amiga', 'colega', 'primo', 'prima',
      'quando', 'qdo', 'qndo', 'se', 'salario', 'salário', 'pagamento',
      'cesar', 'césar', 'cezar', 'cézar'
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final raw = m.group(1)?.trim();
        if (raw != null && raw.isNotEmpty && raw.length > 1) {
          if (!stopWords.contains(raw.toLowerCase())) {
            return raw[0].toUpperCase() + raw.substring(1).toLowerCase();
          }
        }
      }
    }
    return null;
  }

  static String _withPreposition(String name) {
    final lower = name.toLowerCase();
    // Feminine establishments / services
    if (lower.contains('shopee') || lower.contains('shein') || lower.contains('farmácia') || lower.contains('farmacia') ||
        lower.contains('drogasil') || lower.contains('droga raia') || lower.contains('pacheco') || lower.contains('drogaria') ||
        lower.contains('padaria') || lower.contains('vivara') || lower.contains('zara') || lower.contains('marisa') ||
        lower.contains('renner') || lower.contains('c&a') || lower.contains('riachuelo') || lower.contains('hering') ||
        lower.contains('cacau show') || lower.contains('kopenhagen') || lower.contains('dengo') || lower.contains('magalu') ||
        lower.contains('magazine luiza') || lower.contains('casas bahia') || lower.contains('steam') || lower.contains('netflix') ||
        lower.contains('udemy') || lower.contains('alura') || lower.contains('estácio') || _estacioBrand.hasMatch(lower) ||
        lower.contains('puc') || lower.contains('smart fit') || lower.contains('smartfit') || lower.contains('bluefit') ||
        lower.contains('bio ritmo') || lower.contains('selfit') || lower.contains('academia') || lower.contains('cobasi') ||
        lower.contains('enel') || lower.contains('sabesp') || lower.contains('comgás') || lower.contains('comgas') ||
        lower.contains('claro') || lower.contains('vivo') || lower.contains('tim') || lower.contains('latam') ||
        lower.contains('gol') || lower.contains('azul') || lower.contains('sephora') || lower.contains('pandora') ||
        lower.contains('centauro') || lower.contains('decathlon') || lower.contains('netshoes') || lower.contains('apple') ||
        lower.contains('faculdade') || lower.contains('escola') || lower.contains('feira') || lower.contains('oficina') ||
        lower.contains('guitarra') || lower.contains('bateria') || lower.contains('flauta') || lower.contains('sanfona') ||
        lower.contains('openai') || lower.contains('anthropic') ||
        lower.contains('clínica') || lower.contains('clinica') || lower.contains('ótica') || lower.contains('otica')) {
      return 'na $name';
    }
    // Masculine establishments / services / items
    if (lower.contains('mcdonald') || lower.contains('mc') || lower.contains('bk') || lower.contains('burger king') ||
        lower.contains('subway') || lower.contains('outback') || lower.contains('habib') || lower.contains('ragazzo') ||
        lower.contains('spoleto') || lower.contains('bobs') || lower.contains('madero') || lower.contains('jeronimo') ||
        lower.contains('giraffas') || lower.contains('starbucks') || lower.contains('the coffee') || lower.contains('bacio di latte') ||
        lower.contains('mercado') || lower.contains('supermercado') || lower.contains('carrefour') || lower.contains('pão de açúcar') ||
        lower.contains('pao de acucar') || lower.contains('assai') || lower.contains('assaí') || lower.contains('extra') ||
        lower.contains('atacadão') || lower.contains('atacadao') || lower.contains('sams club') || lower.contains('sam\'s club') ||
        lower.contains('oxxo') || lower.contains('posto') || lower.contains('shell') || lower.contains('ipiranga') ||
        lower.contains('petrobras') || lower.contains('ale') || lower.contains('uber') || lower.contains('99') ||
        lower.contains('ifood') || lower.contains('zé delivery') || lower.contains('ze delivery') || lower.contains('rappi') ||
        lower.contains('spotify') || lower.contains('mercado livre') || lower.contains('mercadolivre') || lower.contains('kabum') ||
        lower.contains('pichau') || lower.contains('terabyte') || lower.contains('petz') || lower.contains('leroy merlin') ||
        lower.contains('telhanorte') || lower.contains('tok&stok') || lower.contains('tok stok') || lower.contains('quintoandar') ||
        lower.contains('sem parar') || lower.contains('conectcar') || lower.contains('veloe') || lower.contains('cinema') ||
        lower.contains('cinemark') || lower.contains('cinepolis') || lower.contains('cinépolis') || lower.contains('uci') ||
        lower.contains('restaurante') || lower.contains('bar') || lower.contains('boteco') || lower.contains('pub') ||
        lower.contains('açougue') || lower.contains('acougue') || lower.contains('hospital') || lower.contains('laboratório') ||
        lower.contains('laboratorio') || lower.contains('detran') || lower.contains('shopping') ||
        lower.contains('violão') || lower.contains('violao') || lower.contains('piano') || lower.contains('cavaquinho') ||
        lower.contains('ukulele') || lower.contains('baixo') || lower.contains('teclado') || lower.contains('amplificador') ||
        lower.contains('microfone') ||
        lower.contains('claude') || lower.contains('chatgpt') || lower.contains('chat gpt') || lower.contains('gemini') ||
        lower.contains('copilot') || lower.contains('perplexity') || lower.contains('deepseek') || lower.contains('midjourney') ||
        lower.contains('cursor') || lower.contains('duolingo') ||
        lower.contains('plano') || lower.contains('gympass') || lower.contains('wellhub') || lower.contains('totalpass')) {
      return 'no $name';
    }
    return 'com $name';
  }

  /// Generates brand-aligned empathetic UX writing clarification prompts (Krezio-brand).
  String _generateEmpatheticClarificationPrompt({
    required String intent,
    required double? amount,
    required String category,
    required String paymentMethod,
    required String description,
    required List<String> missingSlots,
    String rawText = '',
    bool isRecurrent = false,
    int? dueDay,
    String? recurrenceDuration,
    bool isReminder = false,
    String? reminderType,
    String? personName,
    DateTime? targetDate,
    String? calendarConsultationNote,
    String? assumptionNote,
  }) {
    if (intent == 'unknown') {
      return 'Não consegui identificar essa transação. Você pode me dizer se foi um gasto ou uma receita, e qual o valor?';
    }

    final hasAmount = amount != null && amount > 0;
    final amountStr = hasAmount ? 'R\$ ${amount.toStringAsFixed(2).replaceAll('.', ',')}' : null;
    final hasCategory = category != 'unknown' && category != 'expense_other';
    final hasPayment = paymentMethod != 'unknown';

    final categoryLabel = _getFriendlyCategoryName(category);
    final paymentLabel = _getFriendlyPaymentName(paymentMethod);
    final subjectLabel = (description.isNotEmpty && description != 'unknown' && description != 'expense_other')
        ? description
        : categoryLabel;
    final isCardAmbiguous = rawText.toLowerCase().contains('cart') || rawText.toLowerCase().contains('cratao') || rawText.toLowerCase().contains('cattao');

    // ── 0. CENÁRIOS DE LEMBRETES & EMPRÉSTIMOS A RECEBER ──
    if (isReminder) {
      if (reminderType == 'loan_receivable') {
        if (missingSlots.contains('amount')) return loanReminderText(personName: personName, targetDate: targetDate, amount: null);
      } else if (reminderType == 'dividend') {
        if (missingSlots.contains('amount')) {
          return 'Qual a previsão do valor dos dividendos que você espera receber?';
        }
      }
    }

    // ── 1. CENÁRIOS DE GASTOS (EXPENSE) ──
    if (intent == 'expense') {
      // ── MENSALIDADES E ASSINATURAS RECORRENTES ──
      // Only what is really missing is asked (payment, value, renewal day).
      // The length is assumed "sem prazo" when not said, and the question says
      // so. A "mensalidade" (college, school, gym) is not called "assinatura".
      final isSubscriptionFormulation = isRecurrent && (missingSlots.contains('due_day') || missingSlots.contains('recurrence_duration'));
      if (isSubscriptionFormulation) {
        final prep = _withPreposition(subjectLabel);
        final noun = rawText.toLowerCase().contains('mensalidade') ? 'mensalidade' : 'assinatura';
        final renews = noun == 'mensalidade' ? 'vence' : 'renova';
        final note = assumptionNote == null ? '' : ' $assumptionNote';
        final isAnnual = recurrenceDuration == 'anual' ||
            rawText.toLowerCase().contains('anual') ||
            rawText.toLowerCase().contains('1 ano') ||
            rawText.toLowerCase().contains('12 meses');

        final asks = <String>[
          if (!hasAmount) 'qual o valor por mês',
          if (!hasPayment) isCardAmbiguous ? 'foi no cartão de crédito ou de débito' : 'qual foi a forma de pagamento',
          if (isAnnual && missingSlots.contains('installments')) 'foi parcelada (ex: em 12x) ou em 1x',
          if (missingSlots.contains('due_day')) 'que dia ela $renews todo mês',
          if (missingSlots.contains('recurrence_duration')) 'ela tem prazo para terminar (ex: anual) ou é por tempo indeterminado',
        ];
        final lead = hasAmount
            ? 'Anotei $amountStr de ${isAnnual ? '$noun anual' : noun} $prep!'
            : 'Anotei a $noun $prep!';
        if (asks.isEmpty) return '$lead$note';
        final question = asks.length == 1 ? asks.first : '${asks.sublist(0, asks.length - 1).join(', ')} e ${asks.last}';
        return '$lead ${question[0].toUpperCase()}${question.substring(1)}?$note';
      }

      // Falta APENAS Parcelamento no Cartão de Crédito
      if (missingSlots.length == 1 && missingSlots.contains('installments')) {
        final prep = _withPreposition(subjectLabel);
        final isAnnual = isRecurrent &&
            (recurrenceDuration == 'anual' ||
                rawText.toLowerCase().contains('anual') ||
                rawText.toLowerCase().contains('1 ano') ||
                rawText.toLowerCase().contains('12 meses'));
        if (isAnnual) {
          if (hasAmount) {
            return 'Anotado a assinatura anual de $amountStr $prep no crédito! Foi parcelada (ex: em 12x) ou em 1x?';
          }
          return 'Essa assinatura anual no crédito foi parcelada (ex: em 12x) ou à vista?';
        }
        if (hasAmount && (hasCategory || description.isNotEmpty)) {
          return 'Essa compra de $amountStr $prep no crédito foi parcelada ou à vista? (ex: em 3x)';
        } else if (hasAmount) {
          return 'Essa compra de $amountStr no crédito foi parcelada ou à vista? (ex: em 3x)';
        } else if (hasCategory || description.isNotEmpty) {
          return 'O gasto $prep no crédito foi parcelado ou à vista? (ex: em 3x)';
        }
        return 'Essa compra no crédito foi parcelada ou à vista? (ex: em 3x)';
      }

      // Falta APENAS a Forma de Pagamento
      if (missingSlots.length == 1 && missingSlots.contains('payment_method')) {
        final prep = _withPreposition(subjectLabel);
        if (isCardAmbiguous) {
          if (hasAmount && (hasCategory || description.isNotEmpty)) {
            return 'Anotado $amountStr $prep! Você passou no cartão de crédito ou de débito?';
          } else if (hasAmount) {
            return 'Anotado $amountStr! Esse cartão foi no crédito ou no débito?';
          } else if (hasCategory || description.isNotEmpty) {
            return 'O gasto $prep no cartão foi no crédito ou no débito?';
          }
          return 'Você passou no cartão de crédito ou de débito?';
        }
        if (hasAmount && (hasCategory || description.isNotEmpty)) {
          return 'Qual a forma de pagamento de $amountStr $prep? (ex: Pix, Débito, Crédito)';
        } else if (hasAmount) {
          return 'Qual foi a forma de pagamento desse gasto de $amountStr? (ex: Pix, Débito, Crédito)';
        } else if (hasCategory || description.isNotEmpty) {
          return 'Como você pagou esse gasto $prep? (ex: Pix, Cartão, Dinheiro)';
        }
        return 'Qual foi a forma de pagamento? (ex: Pix, Débito, Crédito)';
      }

      // Falta APENAS o Valor (Amount)
      if (missingSlots.length == 1 && missingSlots.contains('amount')) {
        final prep = _withPreposition(subjectLabel);
        if ((hasCategory || description.isNotEmpty) && hasPayment) {
          return 'Qual foi o valor gasto $prep no $paymentLabel?';
        } else if (hasCategory || description.isNotEmpty) {
          return 'Quanto você gastou $prep?';
        } else if (hasPayment) {
          return 'Qual foi o valor pago no $paymentLabel?';
        }
        return 'Qual foi o valor dessa despesa?';
      }

      // Falta APENAS a Categoria / Local
      if (missingSlots.length == 1 && missingSlots.contains('category')) {
        if (hasAmount && hasPayment) {
          return 'Onde foi o gasto de $amountStr no $paymentLabel? (ex: mercado, restaurante)';
        } else if (hasAmount) {
          return 'Onde você gastou esse valor de $amountStr? (ex: mercado, restaurante)';
        }
        return 'Onde ou com o que você realizou essa despesa?';
      }

      // Falta Valor e Parcelamento (no crédito)
      if (missingSlots.contains('amount') && missingSlots.contains('installments')) {
        final prep = _withPreposition(subjectLabel);
        return 'Qual o valor desse gasto $prep no crédito e em quantas vezes foi feito?';
      }

      // Falta Categoria e Parcelamento (no crédito)
      if (missingSlots.contains('category') && missingSlots.contains('installments')) {
        return 'Anotado $amountStr no crédito! Onde foi o gasto e foi parcelado em quantas vezes?';
      }

      // Falta Valor e Pagamento (tem Categoria/Descrição)
      if (missingSlots.contains('amount') && missingSlots.contains('payment_method') && !missingSlots.contains('category')) {
        final prep = _withPreposition(subjectLabel);
        if (isCardAmbiguous) {
          return 'Quanto você gastou $prep, e você passou no cartão de crédito ou de débito?';
        }
        return 'Quanto você gastou $prep e qual foi a forma de pagamento?';
      }

      // Falta Categoria e Pagamento (tem Valor)
      if (missingSlots.contains('category') && missingSlots.contains('payment_method') && !missingSlots.contains('amount')) {
        if (isCardAmbiguous) {
          return 'Anotado $amountStr! Onde foi o gasto, e você passou no cartão de crédito ou de débito?';
        }
        return 'Anotado $amountStr! Onde foi o gasto e qual a forma de pagamento? (ex: mercado no débito)';
      }

      // Falta Valor e Categoria
      if (missingSlots.contains('amount') && missingSlots.contains('category')) {
        if (hasPayment) {
          return 'Qual foi o valor e onde foi essa despesa no $paymentLabel?';
        }
        if (missingSlots.contains('payment_method')) {
          return 'Qual foi o valor, onde foi o gasto e qual a forma de pagamento?';
        }
        return 'Qual foi o valor e onde foi essa despesa?';
      }

      // Faltam todos os slots
      return 'Qual foi o valor, onde foi o gasto e qual a forma de pagamento dessa despesa?';
    }

    // ── 2. CENÁRIOS DE RECEITAS (INCOME) ──
    if (intent == 'income') {
      if (missingSlots.contains('amount')) {
        if (isRecurrent && dueDay != null) {
          final label = (subjectLabel.isNotEmpty && subjectLabel != 'unknown') ? subjectLabel : 'salário';
          return 'Entendido! Vou programar o registro automático do seu $label todo dia $dueDay no seu planejamento. Qual é o valor líquido que você recebe?';
        } else if (isRecurrent) {
          final label = (subjectLabel.isNotEmpty && subjectLabel != 'unknown') ? subjectLabel : 'salário';
          return 'Entendido! Vou programar o registro recorrente do seu $label. Qual é o valor líquido que você recebe?';
        }
        return 'Qual foi o valor recebido?';
      }
      if (missingSlots.contains('category')) {
        return amountStr != null
            ? 'De onde veio esse valor de $amountStr? (ex: salário, freela, reembolso)'
            : 'Qual a origem dessa receita? (ex: salário, freela, reembolso)';
      }
      if (missingSlots.contains('payment_method')) {
        return 'Como esse valor entrou na conta? (ex: Pix, TED, Dinheiro)';
      }
    }

    // ── 3. CENÁRIOS DE TRANSFERÊNCIAS (TRANSFER) ──
    if (intent == 'transfer') {
      if (missingSlots.contains('amount')) {
        return 'Qual o valor que você transferiu?';
      }
      if (missingSlots.contains('payment_method')) {
        return 'Qual foi o meio da transferência? (ex: Pix, TED)';
      }
    }

    return 'Faltam alguns detalhes para concluir. Pode me informar o que falta?';
  }

  /// Whether [title] is just a category's label ("supermercado / feira") —
  /// how older entries were named when the word said wasn't in the
  /// vocabulary. Such records can only be found by their category.
  static bool isCategoryLabel(String title) {
    final t = CategoryNameMatcher.foldAccents(title.toLowerCase().trim());
    const codes = ['supermarket', 'transport', 'health', 'leisure', 'housing', 'education', 'salary', 'investment', 'expense_other', 'income_other'];
    return codes.any((c) => CategoryNameMatcher.foldAccents(_getFriendlyCategoryName(c)) == t);
  }

  static String _getFriendlyCategoryName(String category) {
    switch (category) {
      case 'supermarket':
        return 'supermercado / feira';
      case 'transport':
        return 'transporte / combustível';
      case 'health':
        return 'saúde / farmácia';
      case 'leisure':
        return 'alimentação / lazer';
      case 'housing':
        return 'moradia / contas';
      case 'education':
        return 'educação';
      case 'salary':
        return 'salário';
      case 'investment':
        return 'investimentos';
      case 'expense_other':
        return 'outras despesas';
      case 'income_other':
        return 'outras receitas';
      default:
        return category;
    }
  }

  static String _getFriendlyPaymentName(String paymentMethod) {
    switch (paymentMethod) {
      case 'pix':
        return 'Pix';
      case 'credit_card':
        return 'cartão de crédito';
      case 'debit_card':
        return 'cartão de débito';
      case 'cash':
        return 'dinheiro';
      case 'bank_slip':
        return 'boleto';
      default:
        return paymentMethod;
    }
  }

  bool _hasCategoryNoun(String text) {
    final lower = text.toLowerCase();
    if (_resolveContextualCategory(lower, 'unknown') != 'unknown') {
      return true;
    }
    final nouns = [
      'mercado', 'supermercado', 'feira', 'arroz', 'feijao', 'feijão', 'uber', 'gasolina', 'posto',
      'farmacia', 'farmácia', 'remedio', 'remédio', 'remedios', 'remédios', 'medico', 'médico',
      'cinema', 'ifood', 'cerveja', 'restaurante', 'bar', 'luz', 'agua', 'água', 'internet',
      'aluguel', 'condominio', 'condomínio', 'faculdade', 'curso', 'salario', 'salário',
      'reembolso', 'freela', 'acao', 'açoes', 'ações', 'dividendos', 'tesouro', 'mcdonalds', 'mc donalds',
      'burger king', 'bk', 'outback', 'subway', 'starbucks', 'habibs', 'ragazzo', 'spoleto',
      'dominos', 'pizza hut', 'cacau show', 'kopenhagen', 'bobs', 'giraffas', 'madero', 'bacio di latte',
      'vivara', 'zara', 'renner', 'c&a', 'riachuelo', 'h&m', 'marisa', 'hering', 'reserva', 'lacoste',
      'pandora', 'swarovski', 'sephora', 'boticario', 'boticário', 'natura', 'avon', 'centauro',
      'decathlon', 'nike', 'adidas', 'puma', 'asics', 'mizuno', 'vans', 'havaianas', 'arezzo',
      'schutz', 'melissa', 'amazon', 'mercado livre', 'mercadolivre', 'shopee', 'shein', 'aliexpress',
      'magalu', 'casas bahia', 'ponto frio', 'fast shop', 'kabum', 'americanas', 'apple', 'samsung',
      'playstation', 'xbox', 'steam', 'carrefour', 'pão de açúcar', 'extra', 'assai', 'atacadao',
      'droga raia', 'drogasil', 'pague menos', 'panvel', 'shell', 'ipiranga', 'petrobras', 'graal',
      '99', 'movida', 'localiza', 'leroy merlin', 'telhanorte', 'tok&stok',
      // Comidas e Bebidas
      'pastel', 'cafe', 'café', 'cafezinho', 'cappuccino', 'almoço', 'almoco', 'jantar', 'lanche',
      'pizza', 'hamburguer', 'hambúrguer', 'burger', 'sushi', 'temaki', 'yakisoba', 'esfiha', 'kibe',
      'coxinha', 'churrasco', 'picanha', 'bife', 'parmegiana', 'moqueca', 'feijoada', 'lasanha',
      'espaguete', 'massa', 'acai', 'açaí', 'sorvete', 'milkshake', 'bolo', 'brigadeiro', 'trufa',
      'chocolate', 'chopp', 'chope', 'cerveja', 'drink', 'caipirinha', 'gin', 'suco', 'refrigerante',
      // Objetos, Eletrônicos & Tech
      'notebook', 'computador', 'celular', 'smartphone', 'mouse', 'teclado', 'monitor', 'fone',
      'headset', 'airpods', 'carregador', 'cabo', 'smartwatch', 'relogio', 'relógio', 'camera',
      'videogame', 'console', 'controle', 'kindle', 'tv', 'televisao', 'placa de video', 'memoria',
      // Móveis, Eletrodomésticos & Casa
      'sofa', 'sofá', 'mesa', 'cadeira', 'cama', 'colchao', 'colchão', 'armario', 'armário', 'rack',
      'geladeira', 'fogao', 'fogão', 'microondas', 'micro-ondas', 'airfryer', 'air fryer', 'liquidificador',
      'ventilador', 'ar condicionado', 'chuveiro', 'toalha', 'lencol', 'lençol', 'edredom', 'panela',
      // Vestuário, Calçados & Joias
      'anel', 'alianca', 'aliança', 'joia', 'jóia', 'pulseira', 'colar', 'brinco', 'oculos', 'óculos',
      'tenis', 'tênis', 'sapato', 'sandalia', 'sandália', 'chinelo', 'bota', 'camisa', 'camiseta',
      'calca', 'calça', 'bermuda', 'short', 'vestido', 'casaco', 'jaqueta', 'moletom', 'lingerie',
      'cueca', 'sutia', 'sutiã', 'biquini', 'biquíni', 'bolsa', 'mochila', 'carteira', 'cinto',
      // Farmácia, Saúde & Remédios
      'dipirona', 'paracetamol', 'ibuprofeno', 'dorflex', 'neosaldina', 'antialergico', 'vitamina',
      'whey', 'creatina', 'suplemento', 'protetor solar', 'hidratante', 'shampoo', 'perfume', 'desodorante',
      // Contas, Boletos & Moradia
      'boleto', 'boletos', 'fatura', 'faturas', 'mensalidade', 'prestacao', 'prestação', 'parcela',
      'parcelas', 'financiamento', 'iptu', 'ipva', 'multa', 'licenciamento', 'carne', 'carnê',
      // Veículos, Moto & Transporte
      'moto', 'motocicleta', 'carro', 'automovel', 'automóvel', 'veiculo', 'veículo', 'bike', 'bicicleta',
      'uber', '99', 'taxi', 'táxi', 'onibus', 'ônibus', 'metro', 'metrô', 'trem', 'passagem',
      'gasolina', 'etanol', 'combustivel', 'combustível', 'diesel', 'posto', 'pneu', 'pneus',
      'bateria', 'oleo', 'óleo', 'freio', 'pastilha', 'amortecedor', 'filtro', 'capacete', 'oficina',
      'mecanico', 'mecânico', 'estacionamento', 'pedagio', 'pedágio',
      // Materiais de Construção & Reforma
      'cimento', 'tinta', 'piso', 'porcelanato', 'argamassa', 'cano', 'fio', 'disjuntor', 'ferramenta',
      // Papelaria, Livros & Educação
      'caderno', 'livro', 'livros', 'caneta', 'estojo', 'sulfite', 'mochila escolar', 'calculadora'
    ];
    return nouns.any((k) => _hasTermOrDiminutive(lower, k));
  }

  /// "boleto" as the means of payment: after a preposition ("no/via/em/pelo/
  /// por/com boleto") or as "boleto bancário" (R2-CONV-019: "quitado por
  /// boleto bancário"). "paguei o boleto de 700" names the bill instead.
  static final RegExp _boletoAsMethod =
      RegExp(r'\b(?:no|via|em|pelo|por|com)\s+boleto(?![a-zà-úç])|\bboleto\s+banc[aá]rio(?![a-zà-úç])');

  bool _hasPaymentKeyword(String text) {
    final lower = text.toLowerCase();
    final hasBoletoAsMethod = _boletoAsMethod.hasMatch(lower);
    final hasInstallmentsAsMethod = lower.contains('parcel') || RegExp(r'\b\d{1,2}\s*x\b').hasMatch(lower);
    final keywords = [
      'pix', 'pixx', 'pixi', 'pics', 'piquis', 'pyks', 'piks', 'px',
      'credito', 'crédito', 'crebito',
      'debito', 'débito', 'debto', 'debitto', 'debiro',
      'dinheiro', 'dinhero', 'dinheru', 'dindin', 'especie', 'espécie'
    ];
    return keywords.any((k) => _hasTerm(lower, k)) || hasBoletoAsMethod || hasInstallmentsAsMethod;
  }

  bool _hasInstallmentKeyword(String text) {
    final lower = text.toLowerCase();
    return lower.contains('parcel') ||
        lower.contains('vista') ||
        lower.contains('sem parcelar') ||
        lower.contains('vezes') ||
        lower.contains('não') ||
        lower.contains('nao') ||
        RegExp(r'\b\d{1,2}\s*x\b').hasMatch(lower);
  }

  /// Installment count in [text]. A bare number or "não" ("30", "1") only
  /// counts when César is actually asking about installments
  /// ([allowBareCount]) — otherwise "gastei 50 no mercado" ⏎ "30" was saved
  /// on the credit card in 30x.
  int? _parseInstallments(String text, {bool allowBareCount = false}) {
    final lower = text.toLowerCase().trim();

    // 1. Single payment / À vista mentions
    final singleTerms = [
      'à vista', 'a vista', 'sem parcelar', 'não foi parcelado', 'nao foi parcelado',
      'não parcelei', 'nao parcelei', 'não parcelado', 'nao parcelado', 'única parcela',
      'unica parcela', 'parcela única', 'parcela unica', 'uma vez',
      'nao parcelar', 'não parcelar', 'não parcele', 'nao parcele'
    ];
    for (final term in singleTerms) {
      if (lower.contains(term)) {
        return 1;
      }
    }
    // Any denied "parcelar": "não quero parcelar", "nem vou parcelar", "não
    // precisa parcelar", "nada de parcela" — the answer is "à vista".
    if (RegExp(r'(?<![\wÀ-ÿ])(?:n[ãa]o|nem|sem|nada\s+de|nunca)\s+(?:[a-zà-ÿ]+\s+){0,3}parcel', caseSensitive: false).hasMatch(lower)) return 1;
    // "1x" / "1 vez" as whole numbers — "11x" and "11 vezes" are not one.
    if (RegExp(r'(?<!\d)1\s*x\b|(?<!\d)1\s+vez\b').hasMatch(lower)) return 1;
    if (allowBareCount && (lower == 'não' || lower == 'nao' || lower == '1' || lower == 'nenhuma' || lower == 'nenhum')) {
      return 1;
    }

    // 2. Direct Nx patterns (e.g. 10x, 3x, 12x, 24x, 2 x)
    final nxMatch = RegExp(r'\b(\d{1,2})\s*x\b', caseSensitive: false).firstMatch(lower);
    if (nxMatch != null) {
      final count = int.tryParse(nxMatch.group(1)!);
      if (count != null && count >= 1 && count <= 99) {
        return count;
      }
    }

    // 3. Phrasing: "em 3 vezes", "parcelei em 10", "em 6 parcelas", "dividido em 4", "10 vezes", "3 parcelas"
    final phrasingMatch = RegExp(
      r'(?:parcelei\s+em|parceley\s+em|parcelado\s+em|parcelada\s+em|dividido\s+em|dividi\s+em)\s+(\d{1,2})\s*(?:vezes|vezez|veze|parcelas|x|mensalidades)?\b'
      r'|'
      // A plain "em N" needs the unit ("foi em 2 lojas" and "termina em 12"
      // are not installments) unless it is the whole answer ("em 12").
      r'\bem\s+(\d{1,2})\s*(?:vezes|vezez|veze|parcelas|x|mensalidades)\b'
      r'|'
      r'^em\s+(\d{1,2})$'
      r'|'
      r'\bde\s+(\d{1,2})\s*(?:vezes|vezez|veze|parcelas|mensalidades|x)\b'
      r'|'
      r'\b(\d{1,2})\s*(?:vezes|vezez|veze|parcelas|mensalidades)\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (phrasingMatch != null) {
      final str = phrasingMatch.group(1) ?? phrasingMatch.group(2) ?? phrasingMatch.group(3) ?? phrasingMatch.group(4) ?? phrasingMatch.group(5);
      if (str != null) {
        final count = int.tryParse(str);
        if (count != null && count >= 1 && count <= 99) {
          return count;
        }
      }
    }

    // 4. Word numbers: "vinte e quatro vezes", "duas vezes", "três vezes", "quatro vezes", etc.
    final wordMap = {
      'vinte e quatro vezes': 24, 'vinte e quatro parcelas': 24, '24 vezes': 24,
      'dezoito vezes': 18, 'dezoito parcelas': 18, '18 vezes': 18,
      'doze vezes': 12, 'doze parcelas': 12,
      'onze vezes': 11, 'onze parcelas': 11,
      'dez vezes': 10, 'dez parcelas': 10,
      'nove vezes': 9, 'nove parcelas': 9,
      'oito vezes': 8, 'oito parcelas': 8,
      'sete vezes': 7, 'sete parcelas': 7,
      'seis vezes': 6, 'seis parcelas': 6,
      'cinco vezes': 5, 'cinco parcelas': 5,
      'quatro vezes': 4, 'quatro parcelas': 4,
      'três vezes': 3, 'tres vezes': 3, 'três parcelas': 3, 'tres parcelas': 3, 'tres x': 3,
      'duas vezes': 2, 'duas parcelas': 2, 'dois x': 2,
      'uma vez': 1, 'uma parcela': 1,
    };
    for (final entry in wordMap.entries) {
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }

    // 5. In follow-up context, if user just typed a pure number e.g. "3", "10", "12", "2"
    if (allowBareCount && RegExp(r'^\d{1,2}$').hasMatch(lower)) {
      final count = int.tryParse(lower);
      if (count != null && count >= 1 && count <= 99) {
        return count;
      }
    }

    return null;
  }

  String _resolvePaymentMethod(String text, String modelPrediction) {
    // "no credto", "no debto": forgive typos in the method itself.
    final lower = KeywordTypoCorrector.correctText(text.toLowerCase(), isKnownWord: _vocabulary.containsKey);
    if (_hasTerm(lower, 'pix') || _hasTerm(lower, 'pixx') || _hasTerm(lower, 'pixi') || _hasTerm(lower, 'piks') || _hasTerm(lower, 'pics') ||
        _hasTerm(lower, 'piquis') || _hasTerm(lower, 'pyks')) {
      return 'pix';
    }
    if (_hasTerm(lower, 'crédito') || _hasTerm(lower, 'credito') || _hasTerm(lower, 'crdito') || _hasTerm(lower, 'kredito') || _hasTerm(lower, 'crebito') ||
        _hasTerm(lower, 'parcelado') || _hasTerm(lower, 'parcelada') || _hasTerm(lower, 'parcelei') || _hasTerm(lower, 'parceley') ||
        _hasTerm(lower, 'parcelamento') || _hasTerm(lower, 'parcelas') || RegExp(r'\b\d{1,2}\s*x\b').hasMatch(lower)) {
      if (!_boletoAsMethod.hasMatch(lower)) {
        return 'credit_card';
      }
    }
    if (_hasTerm(lower, 'débito') || _hasTerm(lower, 'debito') || _hasTerm(lower, 'debto') || _hasTerm(lower, 'debitto')) {
      return 'debit_card';
    }
    if (_hasTerm(lower, 'dinheiro') || _hasTerm(lower, 'dinhero') || _hasTerm(lower, 'dinheru') || _hasTerm(lower, 'dindin') || _hasTerm(lower, 'espécie') || _hasTerm(lower, 'especie') || _hasTerm(lower, 'notas')) {
      return 'cash';
    }
    // "boleto" is only a payment method if phrased as a method (e.g., "no boleto", "via boleto")
    // When phrased as "paguei o boleto", "paguei um boleto de 700", it is the bill/item being paid!
    if (_boletoAsMethod.hasMatch(lower)) {
      return 'bank_slip';
    }
    // Generic "cartão" without credit or debit specified is AMBIGUOUS and must be clarified
    if (_hasTerm(lower, 'cartão') || _hasTerm(lower, 'cartao') || _hasTerm(lower, 'cartaozinho') || _hasTerm(lower, 'cratao') || _hasTerm(lower, 'cattao')) {
      return 'unknown';
    }
    return 'unknown';
  }

  static final Map<String, String> _commonTypoCorrections = {
    'gaste': 'gastei',
    'gastey': 'gastei',
    'gastie': 'gastei',
    'conprei': 'comprei',
    'compry': 'comprei',
    'conpre': 'comprei',
    'pagei': 'paguei',
    'pague': 'paguei',
    'pagyei': 'paguei',
    'resebi': 'recebi',
    'receby': 'recebi',
    'trasferi': 'transferi',
    'transfery': 'transferi',
    'abastecy': 'abasteci',
    'avasteci': 'abasteci',
    'parceley': 'parcelei',
    'vezez': 'vezes',
    'crebito': 'credito',
    'cratao': 'cartao',
    'cattao': 'cartao',
    'carrefur': 'carrefour',
    'carefur': 'carrefour',
    'carrefou': 'carrefour',
    'méqui': 'mcdonalds',
    'mequi': 'mcdonalds',
    'macdonalds': 'mcdonalds',
    'mc': 'mcdonalds',
    'mac': 'mcdonalds',
    'bk': 'burger king',
    'burguer': 'burger',
    'ifod': 'ifood',
    'yfood': 'ifood',
    'ubr': 'uber',
    'yber': 'uber',
    'drogazil': 'drogasil',
    'vivra': 'vivara',
    'vyvara': 'vivara',
    'farmassia': 'farmacia',
    'farmacya': 'farmacia',
    'supermercardo': 'supermercado',
    'mercardo': 'mercado',
    'alugueu': 'aluguel',
    'alugel': 'aluguel',
    'restorante': 'restaurante',
    'gazolina': 'gasolina',
    'pics': 'pix',
    'piquis': 'pix',
    'pyks': 'pix',
    'hoji': 'hoje',
    'ojie': 'hoje',
    'onterm': 'ontem',
    'otem': 'ontem',
    'salariuo': 'salario',
    'salariu': 'salario',
    'salrio': 'salario',
    'slario': 'salario',
    'saláro': 'salario',
    'sallario': 'salario',
    'salarioo': 'salario',
    'salariio': 'salario',
    'enprestei': 'emprestei',
    'inprestei': 'emprestei',
    'imprestei': 'emprestei',
    'eprestei': 'emprestei',
    'empreste': 'emprestei',
    'enprestar': 'emprestar',
    'imprestar': 'emprestar',
    'dise': 'disse',
    'falo': 'disse',
    'falow': 'disse',
    'pagameto': 'pagamento',
    'pagamentu': 'pagamento',
    'qndo': 'quando',
    'qdo': 'quando',
    'dividentos': 'dividendos',
    'dividento': 'dividendo',
    'divendo': 'dividendo',
    'divendos': 'dividendos',
    'provento': 'proventos',
    'asinei': 'assinei',
    'asinar': 'assinar',
    'asinatura': 'assinatura',
    'netflx': 'netflix',
    'netflis': 'netflix',
    'spotfy': 'spotify',
  };

  String _normalizeText(String text) {
    // 1. Reduce 3+ repeated letters (e.g. gasteeeeii -> gastei), preserving numbers (1000, 3000)
    var clean = text.toLowerCase().replaceAllMapped(
      RegExp(r'([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ])\1{2,}'),
      (match) => match.group(1)!,
    );
    // "segunda-feira" is a day, not a "feira" (the market): "foi 47 na
    // segunda-feira" was titled "Feira" in groceries and taken for a new
    // purchase instead of the answer (CHAOS-B-018).
    clean = _withoutWeekdayFeira(clean);

    // 2. Token-level typo normalization
    final tokens = clean.split(RegExp(r'\s+'));
    final normalizedTokens = tokens.map((t) => _commonTypoCorrections[t] ?? t);
    // 3. Near-miss spellings of category/payment/verb keywords ("mercadp",
    //    "farmasia", "credto", "gstei") — see KeywordTypoCorrector for the
    //    false-positive guards.
    return KeywordTypoCorrector.correctText(normalizedTokens.join(' '), isKnownWord: _vocabulary.containsKey);
  }

  List<double> _extractTfIdfVector(String text) {
    final normText = _normalizeText(text);
    final tokens = normText.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final ngrams = <String>[];

    ngrams.addAll(tokens);
    for (int i = 0; i < tokens.length - 1; i++) {
      ngrams.add('${tokens[i]} ${tokens[i + 1]}');
    }

    final Map<int, int> counts = {};
    for (final ng in ngrams) {
      if (_vocabulary.containsKey(ng)) {
        final idx = _vocabulary[ng]!;
        counts[idx] = (counts[idx] ?? 0) + 1;
      }
    }

    final vector = List<double>.filled(_vocabSize, 0.0);
    final double totalTokens = tokens.isEmpty ? 1.0 : tokens.length.toDouble();

    counts.forEach((idx, count) {
      final tf = count / totalTokens;
      vector[idx] = tf * _idf[idx];
    });

    return vector;
  }

  PredictionResult _predictWithConfidence(Map<String, dynamic> model, List<double> vector) {
    // Check if zero features matched vocabulary
    final sumVec = vector.fold<double>(0.0, (a, b) => a + b);
    if (sumVec == 0.0) {
      return PredictionResult('unknown', 1.0);
    }

    final List<String> classes = (model['classes'] as List).cast<String>();
    final List<double> intercepts = (model['intercept'] as List).map((e) => (e as num).toDouble()).toList();
    final List<dynamic> coefMatrix = model['coef'];

    final scores = List<double>.filled(classes.length, 0.0);

    for (int cIdx = 0; cIdx < classes.length; cIdx++) {
      double score = intercepts[cIdx];
      final List<double> weights = (coefMatrix[cIdx] as List).map((e) => (e as num).toDouble()).toList();

      for (int fIdx = 0; fIdx < vector.length; fIdx++) {
        final val = vector[fIdx];
        if (val != 0.0) {
          score += weights[fIdx] * val;
        }
      }
      scores[cIdx] = score;
    }

    final maxScore = scores.reduce(max);
    final expScores = scores.map((s) => exp(s - maxScore)).toList();
    final sumExp = expScores.reduce((a, b) => a + b);
    final probs = expScores.map((e) => e / sumExp).toList();

    int bestIndex = 0;
    double maxProb = 0.0;
    for (int i = 0; i < probs.length; i++) {
      if (probs[i] > maxProb) {
        maxProb = probs[i];
        bestIndex = i;
      }
    }

    if (maxProb < _confidenceThreshold) {
      return PredictionResult('unknown', maxProb);
    }

    return PredictionResult(classes[bestIndex], maxProb);
  }

  /// "Entrada de 500", "entrou 200 no pix", "teve uma entrada de 300" — money
  /// coming in. Excludes the down-payment sense ("dei entrada de 5 mil no
  /// carro", "5000 de entrada") and tickets ("entrada do cinema"), which are
  /// expenses, and "entrou na fatura/no cartão", which is a charge.
  static final RegExp _moneyInCue = RegExp(
    r'\b(?:recebi|recebo|recebemos|recebimento|caiu|entrou|pagamento\s+recebido|me\s+pag\w+|me\s+devolv\w+|me\s+reembols\w+|'
    r'me\s+transferi\w*|me\s+mand\w+)\b',
  );

  /// The user paying something (a bill, a night out, a tip) even without
  /// "paguei"/"gastei": "efetuei um pagamento", "o pagamento do aluguel",
  /// "larguei 200", "dei 20 pro flanelinha", "rachei a conta".
  bool _isPayingOut(String lower) {
    final l = CategoryNameMatcher.foldAccents(lower);
    if (_moneyInCue.hasMatch(l)) return false;
    if (RegExp(r'\b(?:salario|pro-?labore|holerite)\b').hasMatch(l) && _employeeBeingPaid(l) == null) return false;
    return RegExp(r'\b(?:efetuei|efetuamos|realizei|realizamos|fiz|fizemos)\s+(?:o\s+|um\s+|uma\s+|a\s+)?pagamento\b').hasMatch(l) ||
        RegExp(r'\bpagamento\s+(?:d[oa]s?|referente\s+(?:a|ao|a\s+o)|de)\s+(?:minha\s+|meu\s+|uma\s+|um\s+)?(?:aluguel|contas?|boletos?|fatura|'
                r'mensalidade|luz|agua|internet|condominio|iptu|ipva|parcela|prestacao|financiamento|escola|faculdade|academia|plano|'
                r'seguro|energia|gas|telefone|celular|cartao)\b')
            .hasMatch(l) ||
        RegExp(r'\b(?:larguei|torrei|desembolsei|rachei|rachamos|dividimos\s+a\s+conta|dividi\s+a\s+conta)\b').hasMatch(l) ||
        RegExp(r'^dei\s+(?:r\$\s*)?\d').hasMatch(l);
  }

  /// "75 com o dentista", "o motoboy recebeu 15 de mim": no money word next
  /// to the number, but who pays whom is said — the number is the value
  /// (ACC-C-015). Null when the words say no side.
  double? _amountByRole(String normText, String numLower) {
    final way = MoneyDirectionDetector.detect(normText);
    if (way != MoneyDirection.incoming && way != MoneyDirection.outgoing) {
      // "mexemo 200 lá com o tio do bar": a number right on a conjugated
      // verb, with no thing counted after it, is what the verb moved — the
      // value is kept and César asks which way it went (ACC-C-015).
      final onVerb = RegExp(r'\b[a-z]{3,}(?:ei|ou|amos|emos|emo|imos|aram|eram|eu|iu)\s+(?:uns\s+|umas\s+)?(\d+(?:[.,]\d{1,2})?)'
              r'(?=\s*(?:$|[,.;!]|(?:reais|real|conto|contos|pila|la|ali|aqui|com|no|na|nos|nas|de|do|da|pra|pro|para|em|hoje|ontem)\b))')
          .firstMatch(CategoryNameMatcher.foldAccents(numLower));
      return onVerb == null ? null : cleanAndParseAmount(onVerb.group(1));
    }
    return _pickAmount(numLower, requireMoneyContext: false);
  }

  /// "pix 130 joana", "pix de 80 do carlos": a pix, a value and a name —
  /// nothing says which way it went (ACC-C-018).
  static final RegExp _barePixWithName = RegExp(
      r'^(?:(?:um|o)\s+)?pix\s+(?:de\s+)?(?:r\$\s*)?\d[\d.,]*\s*(?:reais\s+|conto\s+)?(?:(?:pr[oa]|d[oa]|com|pel[oa])\s+)?(?:(?:o|a|seu|dona)\s+)?[a-z]{3,}(?:\s+[a-z]{3,})?$');

  /// Words that say money was moved, not spent nor earned.
  static final RegExp _transferWords = RegExp(
    r'\b(?:transferi|transferimos|transferiu|transferencia|transferir|transf|ted|doc|pixei|pix\s+(?:pr[oa]|para|de\s+(?:r\$\s*)?\d+[\d.,]*\s*(?:reais\s+)?pr[oa]|pra)|'
    r'mandei|mandamos|enviei|enviamos|repassei|repassamos|emprestei|depositei|depositamos|deposito|saquei|saque|guardei|'
    r'apliquei|investi|poupanca|cofrinho|caixinha|reserva)\b',
  );

  bool _saysTransfer(String lower) => _transferWords.hasMatch(CategoryNameMatcher.foldAccents(lower)) || _isOwnAccountTransfer(lower);

  /// Moving money to one's own savings/investment: "lance uma transferência
  /// de R$ 500 para minha conta poupança" (was read as an expense).
  bool _isOwnAccountTransfer(String lower) {
    final l = CategoryNameMatcher.foldAccents(lower);
    if (_moneyInCue.hasMatch(l)) return false;
    return RegExp(r'\btransfer(?:encia|i|ir)\b.*\b(?:para|pra|pro)\s+(?:a\s+|o\s+|minha\s+|meu\s+)*'
            r'(?:conta\s+(?:poupanca|investimento|corrente)|poupanca|investimentos?|corretora|reserva|cofrinho|caixinha)\b')
        .hasMatch(l);
  }

  bool _mentionsMoneyComingIn(String lower) {
    if (RegExp(r'\bentrou\b').hasMatch(lower)) {
      return !RegExp(r'fatura|cart[aã]o|cr[eé]dito|d[eé]bito|cobran[cç]a').hasMatch(lower);
    }
    if (!RegExp(r'\bentradas?\b').hasMatch(lower)) return false;
    final isDownPayment =
        RegExp(r'\b(?:dei|dar|dou|daria|paguei|pagar|pago|pagando|de)\s+(?:a\s+|uma\s+|o\s+valor\s+da\s+)?entrada\b').hasMatch(lower) ||
            RegExp(r'\bentrada\s+(?:do|da|no|na|de\s+um|de\s+uma)\s+(?:carro|moto|apartamento|apto|casa|im[oó]vel|financiamento|cons[oó]rcio|terreno)').hasMatch(lower);
    final isTicket = RegExp(
      r'\bentradas?\s+(?:do|da|no|na|pro|pra|para|de)\s+(?:o\s+|a\s+)?(?:cinema|show|teatro|festa|evento|museu|parque|jogo|est[aá]dio|balada|boate|exposi[cç][aã]o)',
    ).hasMatch(lower);
    return !isDownPayment && !isTicket;
  }

  /// Someone the user employs or hires being paid — "paguei o salário do
  /// funcionário", "contratei um pedreiro pagando 50 o dia". Returns the
  /// worker as written ("pedreiro"), or null.
  String? _employeeBeingPaid(String lower) {
    final match = RegExp(
      r'\b(funcion[aá]ri[oa]s?|empregad[oa]s?|diaristas?|bab[aá]s?|faxineir[oa]s?|colaborador(?:a|es|as)?|'
      r'caseir[oa]s?|jardineir[oa]s?|cuidador(?:a|es|as)?|estagi[aá]ri[oa]s?|motorista particular|dom[eé]stica|'
      r'pedreir[oa]s?|serventes?|ajudantes?|eletricistas?|encanador(?:a|es)?|pintor(?:a|es)?|marceneir[oa]s?|'
      r'mestre de obras|montador(?:a|es)?|serralheir[oa]s?|vidraceir[oa]s?|prestador(?:a)? de servi[cç]os?|freelancer)\b',
    ).firstMatch(lower);
    if (match == null) return null;
    // The user *is* the worker when the money comes to them: "recebi 350 da
    // diária de pedreiro", "me pagaram 140 pela diária" (ACC-B-001, CHAOS-B-006).
    if (RegExp(r'\b(?:recebi|recebemos|ganhei|ganhamos|faturei|cobrei|tirei|me\s+(?:pagou|pagaram|deu|deram|acertou|acertaram|transferiu|'
            r'transferiram|mandou|mandaram|depositou|depositaram|pixou))\b')
        .hasMatch(CategoryNameMatcher.foldAccents(lower))) {
      return null;
    }
    final isPaying = RegExp(r'\b(?:sal[aá]rio|pag(?:ar|uei|o|a|amos|amento|ando)|contratei|contratar|folha|di[aá]rias?)\b').hasMatch(lower);
    return isPaying ? match.group(1) : null;
  }

  static const Map<String, int> _dayCountWords = {
    'dois': 2, 'tres': 3, 'três': 3, 'quatro': 4, 'cinco': 5, 'seis': 6, 'sete': 7, 'oito': 8,
    'nove': 9, 'dez': 10, 'onze': 11, 'doze': 12, 'quinze': 15, 'vinte': 20, 'trinta': 30,
  };

  /// "50 reais o dia durante 10 dias", "diária de 80 por 5 dias", "10 diárias
  /// de 120" → rate + day count. Needs both: a rate alone is a single payment.
  DailyRate? _parseDailyRate(String lower) {
    final rateMatch = RegExp(r'(?:r\$\s*)?' + _pricePattern + _currencyPattern + r'\s*(?:o|por|ao|cada|a)\s+dia\b').firstMatch(lower) ??
        RegExp(r'\bdi[aá]rias?\s+(?:de\s+)?(?:r\$\s*)?' + _pricePattern).firstMatch(lower) ??
        RegExp(r'(?:r\$\s*)?' + _pricePattern + _currencyPattern + r'\s*(?:a|por|de)?\s*di[aá]ria\b').firstMatch(lower);
    if (rateMatch == null) return null;
    final rate = cleanAndParseAmount(rateMatch.group(1));
    if (rate == null || rate <= 0) return null;

    final counts = _dayCountWords.keys.join('|');
    final daysMatch = RegExp(r'(?:durante|por|pelos?|em|nos?)\s+(\d{1,3}|' + counts + r')\s+dias\b').firstMatch(lower) ??
        RegExp(r'\b(\d{1,3}|' + counts + r')\s+(?:dias\s+(?:de\s+)?(?:trabalho|servi[cç]o|obra)|di[aá]rias)\b').firstMatch(lower);
    if (daysMatch == null) return null;
    final raw = daysMatch.group(1)!;
    final days = _dayCountWords[raw] ?? int.tryParse(raw);
    if (days == null || days < 2 || days > 366) return null;
    return DailyRate(rate: rate, days: days);
  }

  static const Map<String, int> _quantityWords = {
    'dois': 2, 'duas': 2, 'tres': 3, 'três': 3, 'quatro': 4, 'cinco': 5,
    'seis': 6, 'sete': 7, 'oito': 8, 'nove': 9, 'dez': 10, 'doze': 12, 'vinte': 20,
  };

  static const String _qtyPattern = r'(\d{1,4}|dois|duas|tres|três|quatro|cinco|seis|sete|oito|nove|dez|doze|vinte)';
  // (?!\d): never a prefix of a longer number — "de 500g" is not a price of 50 (ACC-A-006).
  static const String _pricePattern = r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?!\d)';
  static const String _unitWordPattern = r'(?:unidades?|und|itens?|pe[cç]as?)';
  static const String _currencyPattern = r'(?:\s*(?:reais|real|conto|contos|pila|pilas))?';

  static final List<RegExp> _quantityTimesPricePatterns = [
    // "2 * 30", "3 × 15 reais", "10 unidades x 5", "4 vezes 12,50" — but not
    // "em 3x" / "de 3x" (installments) or "3 x 100 ... 10x" style counts.
    RegExp(r'(?<!\bem\s)(?<!\bde\s)\b' + _qtyPattern + r'\s*(?:' + _unitWordPattern + r'\s*)?(?:\*|×|\bx\b|x(?=\s*\d)|\bvezes\b)\s*(?:r\$\s*)?' +
        _pricePattern + r'(?!\s*(?:x|vezes|parcelas?)\b)' + _currencyPattern),
    // "5 unidades de 12 reais", "10 itens de cerveja a 5 reais"
    RegExp(r'\b' + _qtyPattern + r'\s*' + _unitWordPattern + r'\b(?:\s+(?:de\s+)?[a-zà-úç]+){0,3}?\s+(?:de|a|custando)\s+(?:r\$\s*)?' +
        _pricePattern + _currencyPattern),
    // "4 camisetas de 50 reais cada", "3 cervejas a 12 cada", "2 pizzas por R$ 40 cada uma"
    RegExp(r'\b' + _qtyPattern + r'\s+(?:[a-zà-úç]+\s+){1,4}?(?:de|a|por|custando)\s+(?:r\$\s*)?' + _pricePattern + _currencyPattern +
        r'\s*(?:cada|a\s+unidade|por\s+unidade|o\s+item|por\s+item)\b'),
    // "5 bolachas de 2,75", "2 pizzas de 40 reais", "paguei 2 boletos de 150" —
    // a counted plural noun priced with "de"/"a" is a unit price ("por" reads
    // as the total: "3 bolos por 25"). Measures are excluded ("10 litros de
    // gasolina", "50 reais de uber"), but paid periods count like items:
    // "paguei 3 meses de academia de 100" is 3 × 100 (it used to be R$ 3).
    // The noun may carry a few qualifiers: "6 meses de curso de inglês de
    // 250", "4 meses de mensalidade do clube de 90" (R2-CONV-012).
    RegExp(r'\b' + _qtyPattern + r'\s+(?!(?:' + _nonCountablePlurals + r')\b)[a-zà-úç]+s(?:\s+(?:d[eoa]s?\s+)?[a-zà-úç]+){0,4}?\s+(?:de|a)\s+(?:r\$\s*)?' +
        _pricePattern + r'(?!\s*(?:x|vezes|parcelas?|meses|dias|anos|%)\b)' + _notAMeasure + _currencyPattern),
  ];

  /// A number glued to a measure ("600ml", "2l", "500g", "5 litros") is the
  /// size of the item, not its price: "3 cervejas de 600ml por 27" is R$ 27,
  /// not 3 × 600 (ACC-A-006).
  static const String _notAMeasure = r'(?!\s*(?:ml|l|kg|g|mg|cm|mm|m|km|gb|tb|mb|w|v|litros?|quilos?|gramas?|metros?|polegadas?)\b)';

  static const String _nonCountablePlurals =
      r'reais|contos|pilas|paus|mil|litros|quilos|kgs|gramas|metros|mls|parcelas|vezes|anos|horas|minutos|'
      r'pessoas|filhos|anos|centavos|porcento|dolares|dólares|euros';

  /// Detects "quantity × unit price" phrasing and returns the total, so
  /// "comprei 3 unidades a 20 reais cada" is R$ 60 instead of R$ 20. Only
  /// fires on unambiguous cues — an explicit operator ("*", "×", "x" or
  /// "vezes" between two numbers), a unit word ("5 unidades de 12 reais"), or
  /// "cada"/"por unidade" — because "3 bolos por 25 reais" alone could just as
  /// well be the total, and "parcelado em 3x" is an installment count.
  QuantityPricing? _parseQuantityTimesPrice(String lower) {
    final isInstallmentPhrase = lower.contains('parcel');
    for (var i = 0; i < _quantityTimesPricePatterns.length; i++) {
      final match = _quantityTimesPricePatterns[i].firstMatch(lower);
      if (match == null) continue;
      // "há 3 dias … consulta de 47", "faz seis dias veio a conta de 85": a
      // date span is when, never a count to multiply by (CHAOS-B-005).
      if (RegExp(r'\b(?:ha|há|faz|tem)\s+(?:uns\s+|umas\s+)?$').hasMatch(lower.substring(0, match.start)) ||
          RegExp(r'^\s*(?:dias?|semanas?|meses|anos?)\s+atr[aá]s').hasMatch(lower.substring(match.start + match.group(1)!.length))) {
        continue;
      }
      // In an installment sentence only an explicit "*"/"×" counts as math.
      if (i == 0 && isInstallmentPhrase && !RegExp(r'[*×]').hasMatch(match.group(0)!)) continue;

      final qtyRaw = match.group(1)!;
      final quantity = _quantityWords[qtyRaw] ?? int.tryParse(qtyRaw);
      final unitPrice = cleanAndParseAmount(match.group(2));
      if (quantity == null || quantity < 2 || unitPrice == null || unitPrice <= 0) continue;

      final total = double.parse((quantity * unitPrice).toStringAsFixed(2));
      if (total >= 1000000000) continue;
      return QuantityPricing(quantity: quantity, unitPrice: unitPrice, total: total, matchedText: match.group(0)!);
    }
    return null;
  }

  double? _parseAmount(String text) {
    // Spoken numbers first: "cinquenta e dois reais e noventa centavos",
    // "mil e duzentos", "10 mil" all become plain digits.
    final lower = PtNumberWords.normalize(text.toLowerCase());

    // Filter out English system / prompt injection keywords
    final systemWords = ['system', 'override', 'status', 'code', 'python', 'abcdefg', 'ignore', 'instructions'];
    if (systemWords.any((w) => lower.contains(w))) {
      return null;
    }

    // Brazilian Portuguese monetary slang values
    final slangMap = <String, double>{
      'vintão': 20.0, 'vintao': 20.0, 'vintinha': 20.0, 'vinte conto': 20.0, 'vinte pila': 20.0, 'vinte reais': 20.0, 'vinti real': 20.0, 'vintireal': 20.0, 'vinti reais': 20.0, 'vintireais': 20.0,
      'dezão': 10.0, 'dezao': 10.0, 'dezinha': 10.0, 'dezinho': 10.0, 'dez conto': 10.0, 'dez pila': 10.0, 'dez reais': 10.0, 'derreal': 10.0, 'deisreal': 10.0, 'desreal': 10.0, 'dezreal': 10.0,
      'cinquentão': 50.0, 'cinquentao': 50.0, 'cinquentinha': 50.0, 'cinquenta conto': 50.0, 'cinquenta pila': 50.0, 'cinquenta reais': 50.0, 'cinquentareal': 50.0, 'cinquenta real': 50.0, 'cinquentareais': 50.0,
      'quarenta conto': 40.0, 'quarenta pila': 40.0, 'quarenta reais': 40.0, 'quarentinha': 40.0, 'quarentareal': 40.0, 'quarenta real': 40.0, 'quarentareais': 40.0,
      'trinta conto': 30.0, 'trinta pila': 30.0, 'trinta reais': 30.0, 'trintinha': 30.0, 'trintareal': 30.0, 'trinta real': 30.0, 'trintareais': 30.0,
      'quinzenha': 15.0, 'quinzinha': 15.0, 'quinze conto': 15.0, 'quinze reais': 15.0,
      'cinquinha': 5.0, 'cinquinho': 5.0, 'cinco conto': 5.0, 'cinco pila': 5.0, 'cinco reais': 5.0, 'cincreal': 5.0, 'cincoreal': 5.0, 'cinco real': 5.0,
      'doirreal': 2.0, 'doisreal': 2.0, 'doireais': 2.0, 'dois reais': 2.0, 'dois real': 2.0,
      'umreal': 1.0, 'umrea': 1.0, 'umreais': 1.0, 'um real': 1.0,
      'cemzão': 100.0, 'cemzao': 100.0, 'cemzinho': 100.0, 'cemzinha': 100.0, 'cem conto': 100.0, 'cem pila': 100.0, 'cem reais': 100.0, 'cemreal': 100.0, 'cem real': 100.0, 'cemreais': 100.0,
      'duzentão': 200.0, 'duzentao': 200.0, 'duzentos reais': 200.0, 'duzentosreal': 200.0, 'duzentos real': 200.0,
      'quinhentão': 500.0, 'quinhentao': 500.0, 'quinhentos reais': 500.0, 'quinhentosreal': 500.0, 'quinhentos real': 500.0,
      'um barão': 1000.0, 'um barao': 1000.0, 'barão': 1000.0, 'barao': 1000.0, 'milreal': 1000.0, 'mil real': 1000.0, 'milreais': 1000.0,
      'dois barões': 2000.0, 'dois baroes': 2000.0, '2 barões': 2000.0, '2 baroes': 2000.0,
      'um pau': 1000.0, '1 pau': 1000.0, 'dois paus': 2000.0, '2 paus': 2000.0, 'cinco paus': 5000.0, '5 paus': 5000.0,
    };
    for (final entry in slangMap.entries) {
      // Whole words only: "1 pau" must not fire inside "21 paus".
      if (_containsWord(lower, entry.key)) {
        return entry.value;
      }
    }

    // Check "1,5k" or "2k"
    final kRegExp = RegExp(r'(\d+(?:[.,]\d+)?)\s*k\b', caseSensitive: false);
    final kMatch = kRegExp.firstMatch(lower);
    if (kMatch != null) {
      final strVal = kMatch.group(1)?.replaceAll(',', '.');
      if (strVal != null) {
        final val = double.tryParse(strVal);
        if (val != null) return val * 1000.0;
      }
    }

    return _pickAmount(lower, requireMoneyContext: true);
  }

  // Endings that keep a keyword the same word: plural and diminutive
  // ("boletos", "cafezinho", "cartões"). Anything else after the keyword makes
  // it a different word — "mercador" is not "mercado", "picsou" is not "pics",
  // "extrato" is not "extra", "família" is not "amil".
  static const Set<String> _sameWordEndings = {
    '', 's', 'es', 'zinho', 'zinha', 'zinhos', 'zinhas', 'inho', 'inha', 'inhos', 'inhas', 'ão', 'ões',
  };
  static bool _isWordChar(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x61 && u <= 0x7a) || (u >= 0x41 && u <= 0x5a) || (u >= 0x30 && u <= 0x39) || (u >= 0xc0 && u <= 0xff && u != 0xd7 && u != 0xf7);
  }

  /// Whether [term] (a category/payment keyword) is *said* in [text]: it
  /// must start a word and end one, give or take a plural/diminutive ending.
  /// Replaces raw `contains`, which matched keywords inside unrelated words
  /// (R2-CHAOS-006/020): "picsou" fixed the payment as Pix, "mercador" filed
  /// under Supermercado.
  static bool _hasTerm(String text, String term) {
    if (term.isEmpty) return false;
    final startsWithWordChar = _isWordChar(term[0]);
    final endsWithWordChar = _isWordChar(term[term.length - 1]);
    var from = 0;
    while (true) {
      final i = text.indexOf(term, from);
      if (i == -1) return false;
      from = i + 1;
      if (startsWithWordChar && i > 0 && _isWordChar(text[i - 1])) continue;
      if (!endsWithWordChar) return true;
      var end = i + term.length;
      while (end < text.length && _isWordChar(text[end])) {
        end++;
      }
      if (_sameWordEndings.contains(text.substring(i + term.length, end))) return true;
    }
  }

  static const Set<String> _diminutiveEndings = {'inho', 'inha', 'inhos', 'inhas'};

  /// [_hasTerm], plus the diminutive that drops the keyword's last vowel
  /// ("mercadinho", "lanchinho", "cervejinha", "carrinho").
  static bool _hasTermOrDiminutive(String text, String term) {
    if (_hasTerm(text, term)) return true;
    if (term.length < 4 || !RegExp(r'[a-z][aoe]$').hasMatch(term)) return false;
    final stem = term.substring(0, term.length - 1);
    var from = 0;
    while (true) {
      final i = text.indexOf(stem, from);
      if (i == -1) return false;
      from = i + 1;
      if (i > 0 && _isWordChar(text[i - 1])) continue;
      var end = i + stem.length;
      while (end < text.length && _isWordChar(text[end])) {
        end++;
      }
      if (_diminutiveEndings.contains(text.substring(i + stem.length, end))) return true;
    }
  }

  static bool _containsWord(String text, String word) {
    final wordChar = RegExp(r'[a-z0-9à-ÿ]');
    var from = 0;
    while (true) {
      final i = text.indexOf(word, from);
      if (i == -1) return false;
      final end = i + word.length;
      final beforeOk = i == 0 || !wordChar.hasMatch(text[i - 1]);
      final afterOk = end >= text.length || !wordChar.hasMatch(text[end]);
      if (beforeOk && afterOk) return true;
      from = i + 1;
    }
  }

  // ── Which number in the sentence is the value? ──
  //
  // "a conta de luz que era pra ser uns 100 veio 187", "depois de 3 horas no
  // trânsito paguei 25", "meu filho de 8 anos... gastei 120": the first number
  // used to win. Now every number is a candidate; times, days, spans, ages,
  // years, installment counts, quantities ("2 pizzas") and card/CPF endings
  // are thrown out, and among the rest the one tied to money wins — currency
  // ("R$", "reais") over a spending verb ("gastei", "deu", "veio") over a
  // preposition ("de", "por") over a bare number. Nothing left → null, so
  // César asks for the value instead of guessing.

  static final RegExp _amountCandidatePattern = RegExp(
    // Thousands groups can't start with 0 ("0.004" is not 4).
    r'(?<![\d.,])([1-9]\d{0,2}(?:\.\d{3})+(?:,\d{1,2})?|[1-9]\d{0,2}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?|[.,]\d{1,2})(?![.,]?\d)',
  );

  static final RegExp _currencyBefore = RegExp(r'r\$\s*$');
  static final RegExp _currencyAfter = RegExp(r'^\s*(?:reais|real|rea|conto|contos|pila|pilas|paus?|centavos)\b');
  static final RegExp _valueVerbBefore = RegExp(
    r'\b(?:gastei|gasto|gastando|gastar|gastou|gastamos|gaste|paguei|pagar|pagando|pago|pagou|paga|pagamos|comprei|compramos|'
    r'custou|custa|custando|custaram|saiu|sai|deu|dando|veio|vem|foi|ficou|fica|fechou|total|totalizou|valor|valendo|'
    r'recebi|recebo|receber|recebemos|ganhei|ganho|faturei|vendi|entrou|caiu|transferi|mandei|enviei|abasteci|passei|'
    r'torrei|larguei|dei|desembolsei|soltei|deixei|emprestei|emprestar|empresta|emprestou|devolveu|reembolsaram|reembolsou|'
    r'era|eram|seria|cobrou|cobraram|debitou|deve|devem|devia|depositou|depositaram|depositei|pagaram|transferiu|mandou|mandaram|acertou|'
    // Money arriving or handed over informally (CONV-R3-001): "pingou 90", "me descolou 200".
    r'pingou|pingaram|cairam|entraram|chegou|chegaram|brotou|rendeu|descolei|descolou|adiantou|arrumou|'
    // A habitual arrival: "todo dia 20 cai 1200 da aposentadoria" (ACC-B-014).
    r'cai|caem|entra|entram|pinga|sairam|saem)\s+'
    r'(?:(?:de|uns|umas|um|tipo|so|apenas|quase|cerca\s+de|aproximadamente|mais\s+de|mais\s+ou\s+menos|exatamente|'
    r'exatos|o|a|os|as|mais|r\$)\s*)*$',
  );
  /// A verb form right before the number, by its shape rather than a list:
  /// a first-person past ("arranjei 150", "embolsei 200", "bati 300" at the
  /// start of a clause), someone doing something *to me* ("me devolveram
  /// 30", "me descontaram 50") or a hypothetical form ("se eu gastasse 1000",
  /// "se meu salário fosse 5000"). The number such a verb takes is its value
  /// (ACC-A-011, CHAOS-A-019/023).
  static final RegExp _verbShapeBefore = RegExp(
    // …or someone else's past ("o mecânico levou 280", "descontaram 55 do
    // salário", ACC-B-012).
    r'(?:\b[a-z]{2,}ei|(?:^|\beu\s+|[,;.]\s*)[a-z]{2,}(?:[tdbmvr]i|gui)|\bme\s+[a-z]+(?:ou|eu|iu|aram|eram|iram)|\b[a-z]{3,}(?:ou|aram|eram|iram)|'
    r'\b[a-z]{2,}(?:asse|esse|isse|assem|essem|issem)|\b(?:fosse|fossem|for|forem|der|derem|sair|sairem))\s+'
    r'(?:(?:uns|umas|mais|quase|r\$)\s*)*$',
  );
  static final RegExp _prepositionBefore = RegExp(r'\b(?:de|por|pra|para|a|com)\s+(?:(?:uns|umas|r\$)\s*)*$');

  // Words that may follow a value without making it look like a count.
  static const Set<String> _wordsAfterValue = {
    'no', 'na', 'nos', 'nas', 'num', 'numa', 'em', 'de', 'do', 'da', 'dos', 'das', 'pra', 'pro', 'pras', 'pros', 'para',
    'por', 'pelo', 'pela', 'com', 'e', 'ou', 'hoje', 'ontem', 'anteontem', 'agora', 'ja', 'so', 'que', 'mas', 'porque',
    'pq', 'la', 'ai', 'aqui', 'a', 'o', 'as', 'os', 'ao', 'aos', 'mesmo', 'tambem', 'ne', 'tudo', 'total', 'cada', 'via',
    'ate', 'esse', 'essa', 'este', 'esta', 'nesse', 'nessa', 'neste', 'nesta', 'semana', 'foi', 'deu', 'sem', 'fora',
    'certinho', 'redondo', 'redondos', 'inteiro', 'inteiros',
  };
  // Plurals that are not things being counted.
  static const Set<String> _nonCountPlurals = {
    'reais', 'contos', 'pilas', 'paus', 'centavos', 'milhoes', 'dolares', 'euros', 'nos', 'nas', 'dos', 'das', 'os', 'as',
    'aos', 'pelos', 'pelas', 'pras', 'pros', 'mais', 'menos', 'depois', 'apos', 'antes', 'atras', 'pois', 'mas', 'mensais',
    'anuais', 'semanais', 'iguais', 'apenas', 'uns', 'umas', 'redondos', 'inteiros', 'certinhos', 'tres', 'vs',
    // Singular words ending in -s: "pagou 120 mês passado" is not 120 months (ACC-A-012).
    'mes',
  };
  static const Set<String> _countUnitWords = {'unidade', 'unidades', 'und', 'item', 'itens', 'peca', 'pecas'};

  /// True when the number [raw] (with the text [before]/[after] it) is a
  /// time, date, span, age, year, count, installment number or ID rather
  /// than an amount of money.
  static bool _isNonValueNumber(String raw, String before, String after) {
    // Money words always mean money: "R$ 22", "15 reais".
    if (_currencyBefore.hasMatch(before) || _currencyAfter.hasMatch(after)) return false;
    final isInteger = RegExp(r'^\d+$').hasMatch(raw);

    // "1e9": not a number anyone says (neither the 1 nor the 9).
    if (RegExp(r'^[a-z]\d').hasMatch(after) || RegExp(r'\d[a-z]$').hasMatch(before)) return true;
    // Time of day: "22h", "22h30", "22:30", "10 da manhã", "às 22", "3 horas".
    if (RegExp(r'^(?:h\d{0,2}|hs|hrs?)\b|^:\d{2}').hasMatch(after)) return true;
    if (RegExp(r'^\s*(?:horas?|hrs?|min|minutos?)\b').hasMatch(after)) return true;
    if (RegExp(r'^\s*(?:da|de)\s+(?:manha|tarde|noite|madrugada)\b').hasMatch(after)) return true;
    if (isInteger && RegExp(r'\b(?:as|pelas|das)\s*$').hasMatch(before)) return true;
    // Which installment: "a parcela 4 de 10", "prestação nº 3" (R2 ruído).
    if (isInteger && RegExp(r'\b(?:parcelas?|prestac\w*)\s+(?:n[ºo°]?\s*)?(?:\d+\s*(?:de|/)\s*)?$').hasMatch(before)) return true;
    // Calendar day or date: "dia 15", "todo dia 10", "15/03", "15 de março".
    if (isInteger && RegExp(r'\bdias?\s*$').hasMatch(before)) return true;
    // The month of a "dd/mm" ("50 10/09": the 09 is September, not R$ 9).
    if (isInteger && RegExp(r'\d\s*/\s*$').hasMatch(before)) return true;
    if (RegExp(r'^\s*(?:/\s*\d|de\s+(?:janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)\b)')
        .hasMatch(after)) {
      return true;
    }
    // Spans, installments, percentages and measures: "3 dias", "8 anos",
    // "3x", "10 vezes", "20%", "5 litros", "600ml". A span word that is itself
    // a date doesn't make the number before it a span: in "de 199 dia 21" the
    // "dia 21" is the date and 199 the value; in "pagou 120 mês passado" the
    // month is when, not how long (ACC-A-012, CHAOS-A-004/018).
    if (RegExp(r'^\s*(?:(?:dias?(?!\s+\d)|(?:semanas?|mes|meses|anos?)(?!\s+(?:passad[oa]s?|retrasad[oa]s?|que\s+vem)\b)|'
            r'noites?|vezes|parcelas?|prestac\w*|km|kg|g|mg|l|ml|m|cm|mm|'
            r'litros?|quilos?|gramas?|metros?|por\s*cento|gb|mb|tb|gigas?|megas?|polegadas?|pol|watts?|w|volts?|v|hz|mah|mp|'
            r'cv|cc|cilindradas|btus?|graus?)\b|x\b|%)')
        .hasMatch(after)) {
      return true;
    }
    // A number coordinated with a measured one shares its unit: "eles têm 5
    // e 8 anos", "3 ou 4 dias", "2 a 3 quilos" — the 5 is an age, not R$ 5
    // (ACC-C-006).
    // ("um de 6 e outro de 9 anos" too.)
    if (RegExp(r'^\s*(?:e|ou|a)\s+(?:(?:o|a)\s+)?(?:outr[oa]s?\s+)?(?:de\s+|com\s+)?\d+(?:[.,]\d+)?\s*(?:anos?|meses|mes|dias?|semanas?|horas?|minutos?|noites?|km|kg|quilos?|litros?|metros?|'
            r'gramas?|ml|g|l|m|cm|vezes|parcelas?|x)\b')
        .hasMatch(after)) {
      return true;
    }
    // An ordinal: "a 2ª parcela", "o 3º andar" (CHAOS-B-022).
    if (isInteger && RegExp(r'^(?:[ªº°]|[ao](?=\s))').hasMatch(after)) return true;
    // A number right after "no/na/num/numa" with no noun between is where
    // ("moro no 402", "fico na 12", "paguei 30 no 99"), never how much: money
    // is said "de 402", "por 402", "402 reais" (ACC-B-008).
    if (isInteger && RegExp(r'(?:^|\s)(?:no|na|num|numa)\s*$').hasMatch(before) &&
        !RegExp(r'\b(?:foi|deu|saiu|ficou|custou|fechou|total)\s+(?:no|na)\s*$').hasMatch(before)) {
      return true;
    }
    // A code: "placa QWE-4521", "cep 01310-100".
    if (RegExp(r'[a-z]{2,}-$|\d{5}-$').hasMatch(before) || (raw.length >= 5 && RegExp(r'^-\d').hasMatch(after))) return true;
    // "kit 5 em 1", "dividi 300 em 3": the number after "N em" is not money.
    if (isInteger && raw.length == 1 && RegExp(r'\d\s+em\s+$').hasMatch(before)) return true;
    // The number of a place, a seat, a class or a model, right after its
    // noun ("box 12", "vaga 40", "consultório 1102", "aula 5") — never money
    // (ACC-B-007/010). Words that can also name what was bought ("camisa
    // 10", "aro 14", "iphone 15") only when another number is the price.
    if (isInteger && RegExp(r'\b(?:box|vaga|vagas|apartamento|ap|consultorio|placa|terminal|lote|quadra|bloco|andar|piso|portao|'
            r'guiche|assento|poltrona|leito|cabine|setor|fila|plataforma|rua|avenida|av|travessa|rodovia|br|rota|protocolo|senha|'
            r'turma|aula|sessao|rodada|episodio|temporada|capitulo|edicao|versao|geracao|unidade\s+n|km)\s*(?:n[ºo°.]*\s*)?$')
        .hasMatch(before)) {
      return true;
    }
    if (isInteger &&
        RegExp(r'\b(?:camisa|camiseta|kit|aro|tamanho|numeracao|modelo|iphone|galaxy|redmi|moto|playstation|ps|xbox|ipad|macbook|'
                r'windows|android|mesa|quarto|casa|loja|sala|serie|chuteira|tenis)\s*$')
            .hasMatch(before) &&
        RegExp(r'(?:r\$\s*|\b(?:por|de|custou|paguei|deu|saiu|gastei|foi)\s+(?:r\$\s*)?)\d').hasMatch('$before $after')) {
      return true;
    }
    // A count in the singular before a priced item: "2 pão de queijo por 9",
    // "3 cerveja por 27" — the price is the other number (CHAOS-B-022).
    if (isInteger && raw.length <= 2) {
      final next = RegExp(r'^\s+([a-z]+)').firstMatch(after)?.group(1);
      if (next != null && next.length > 2 && !_wordsAfterValue.contains(next) && !_nonCountPlurals.contains(next) &&
          !_moneyContextWords.contains(next) && RegExp(r'\b(?:por|a|cada|custando)\s+(?:r\$\s*)?\d').hasMatch(after)) {
        return true;
      }
    }
    // Card/document endings and other identifiers: "cartão final 1234",
    // "meu cpf termina em 12", "o ônibus 474", phone numbers.
    if (RegExp(r'(?:\bfinal|\bfinais|\btermin\w*\s+(?:em|com)|\bcpf|\bcnpj|\brg|\bcep|\bnumero|\bwhats\w*|\bagencia|'
            r'\bchave|\bapto|\bsala)\s*(?:e|eh|:)?\s*$')
        .hasMatch(before)) {
      return true;
    }
    // A bus/line number ("o ônibus 474", "pego a linha 175") — but in a list
    // of prices "ônibus 5, almoço 28" the 5 is the fare (ACC-A-005).
    if (isInteger && (raw.length >= 3 || RegExp(r'\b(?:o|a|do|da|no|na|pelo|pela|num|numa)\s+(?:linha|onibus)\s*$').hasMatch(before)) &&
        RegExp(r'\b(?:linha|onibus)\s*$').hasMatch(before)) {
      return true;
    }
    if (RegExp(r'^\d{9,}$').hasMatch(raw)) return true;
    // A card limit is not a purchase: "meu cartão tem limite de 5000".
    if (RegExp(r'\blimite\s+(?:de\s+)?$').hasMatch(before)) return true;
    // Two bare numbers side by side ("gastei 5 0 no mercado"): no way to
    // tell which one is meant — unless the neighbour is a date or a span
    // ("gastei 50 10/09", "gastei 50 3 dias atrás", "no dia 5 50 no
    // mercado"): then this one is the value (CHAOS-A-010/018).
    final dateOrSpanAfter = RegExp(r'^\s+\d{1,2}\s*/\s*\d|^\s+\d{1,4}\s+(?:dias?|semanas?|mes|meses|anos?)\b').hasMatch(after);
    final dateBefore = RegExp(r'(?:\bdias?\s+\d{1,2}|\d{1,2}\s*/\s*\d{1,2}(?:\s*/\s*\d{2,4})?)\s+$').hasMatch(before);
    if ((RegExp(r'^\s+\d').hasMatch(after) && !dateOrSpanAfter) || (RegExp(r'\d\s+$').hasMatch(before) && !dateBefore)) return true;
    // A year: "nasci em 1995", "desde 2020".
    if (isInteger && RegExp(r'^(?:19|20)\d{2}$').hasMatch(raw) && RegExp(r'\b(?:em|desde|ano(?:\s+de)?)\s*$').hasMatch(before)) {
      return true;
    }
    // A count before what is counted: "2 pizzas", "3 cafés", "2 lojas",
    // "3 itens", "1 pizza".
    if (isInteger) {
      final next = RegExp(r'^\s+([a-z]+)').firstMatch(after)?.group(1);
      if (next != null) {
        if (_countUnitWords.contains(next)) return true;
        if (next.length > 2 && next.endsWith('s') && !_nonCountPlurals.contains(next) && !_wordsAfterValue.contains(next)) return true;
        if (raw == '1' && !_wordsAfterValue.contains(next)) return true;
      }
    }
    return false;
  }

  /// How strongly the context marks this number as the money value:
  /// currency 6, spending verb 4, preposition 2, nothing 0 — minus 1 when a
  /// noun follows it ("recebi 2 pix de 50": the 2 reads like a count).
  static int _valueCueScore(String before, String after) {
    if (_currencyBefore.hasMatch(before) || _currencyAfter.hasMatch(after)) return 6;
    final next = RegExp(r'^\s+([a-z]+)').firstMatch(after)?.group(1);
    final nounAfter = next != null && !_wordsAfterValue.contains(next) && !_moneyContextWords.contains(next);
    final cue = (_valueVerbBefore.hasMatch(before) || _verbShapeBefore.hasMatch(before)) ? 4 : (_prepositionBefore.hasMatch(before) ? 2 : 0);
    return cue - (nounAfter ? 1 : 0);
  }

  /// The money value in [text] (spoken numbers already turned into digits),
  /// or null. With [requireMoneyContext], a number with no cue at all is only
  /// taken when the sentence talks about money somewhere ("uber 28").
  double? _pickAmount(String text, {required bool requireMoneyContext}) {
    final lower = CategoryNameMatcher.foldAccents(text.toLowerCase());
    final candidates = <(double, int, bool, bool)>[];
    for (final m in _amountCandidatePattern.allMatches(lower)) {
      final raw = m.group(1)!;
      final value = cleanAndParseAmount(raw);
      if (value == null || value <= 0 || value >= 1000000000) continue;
      final before = lower.substring(0, m.start);
      final after = lower.substring(m.end);
      if (_isNonValueNumber(raw, before, after)) continue;
      // "a conta deu 350, o plano cobriu 200 e eu paguei 150": the value is
      // the one after the user's own verb; numbers after a descriptive verb
      // ("deu", "cobriu", "era") are context (R2-CONV-005).
      final mine = RegExp(r'\b(?:gastei|gastamos|paguei|pagamos|comprei|compramos|recebi|ganhei|transferi|mandei|torrei|abasteci|depositei|desembolsei)\s+(?:(?:so|mais|uns|umas|r\$)\s*)?$').hasMatch(before);
      final context = RegExp(r'\b(?:deu|daria|cobriu|cobre|era|eram|seria|custou|custava|veio|vinha|ficou|saiu|devia|valia|reembolsou|descontou|abateu)\s+(?:(?:so|uns|r\$)\s*)?$').hasMatch(before);
      // "o mercado que era 150 hoje deu 187", "o uber que seria 30 deu 42": a
      // number after an imperfect or conditional verb describes how things
      // were (or would be), not what happened — it loses a tie with the
      // value of a perfective verb ("deu", "veio", "saiu"). Alone, it is
      // still the value ("o almoço era 35 no pix").
      final formerState = RegExp(r'\b(?:era|eram|seria|seriam|daria|custava|custavam|vinha|vinham|valia|devia|costumava\s+ser)\s+(?:(?:so|uns|umas|r\$)\s*)?$')
          .hasMatch(before);
      // "ganhei 40 de desconto … e paguei 260": the discount is what was
      // not paid — never the value when another one is said (ACC-C-014).
      final discount = RegExp(r'^\s*(?:reais|real|conto|contos|%)?\s*(?:de\s+)?(?:desconto|abatimento)\b').hasMatch(after);
      candidates.add((value, _valueCueScore(before, after) - (formerState ? 1 : 0) - (discount ? 8 : 0), mine && !discount, context));
    }
    final anyMine = candidates.any((c) => c.$3);
    double? best;
    var bestScore = -2;
    for (final c in candidates) {
      final score = c.$2 + (anyMine && c.$3 ? 2 : 0) - (anyMine && c.$4 ? 3 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = c.$1;
      }
    }
    if (best == null) return null;
    if (bestScore <= 0 && requireMoneyContext && !_moneyContextWords.any((w) => lower.contains(w))) return null;
    return best;
  }

  // Require explicit financial verbs, brand names, currency terms, or monetary
  // context before taking a number with no cue next to it.
  static const List<String> _moneyContextWords = [
    'gastei', 'gaste', 'gastar', 'gasto', 'gastos', 'paguei', 'paga', 'pagar', 'pagamento',
    'comprei', 'compra', 'comprar', 'compras', 'caiu', 'recebi', 'receber', 'receita',
    'mandei', 'mandou', 'manda', 'transferi', 'transferiu', 'transferir', 'enviou', 'enviei',
    'abasteci', 'abasteceu', 'abastecer', 'passei', 'passou', 'passar', 'saiu', 'deu', 'debitou',
    'desembolsei', 'soltei', 'torrei', 'deixei', 'fechei', 'entrou', 'custou', 'ficou',
    'emprestei', 'emprestar', 'empresta', 'emprestou', 'emprestimo', 'empréstimo',
    'ganhei', 'faturei', 'vendi', 'entrada', 'depositou', 'depositaram', 'depositei', 'pagaram', 'honorarios', 'honorários', 'receita',
    'reais', 'real', 'rea', 'conto', 'contos', 'pila', 'pilas', 'r\$', 'fatura', 'troco', 'fiado',
    'pix', 'pics', 'pyks', 'debito', 'débito', 'credito', 'crédito', 'dinheiro', 'dinhero', 'dinheru', 'dindin', 'boleto', 'cartao', 'cartão',
    'vintao', 'vintão', 'dezao', 'dezão', 'cinquentao', 'cinquentão', 'cemzao', 'cemzão',
    'duzentao', 'duzentão', 'quinhentao', 'quinhentão', 'barao', 'barão', 'pau', 'paus',
    'uber', '99', 'ifood', 'rappi', 'ze delivery', 'mcdonalds', 'shell', 'ipiranga',
    'carrefour', 'extra', 'drogasil', 'raia', 'mercado', 'posto', 'farmacia', 'aluguel',
    'pastel', 'pizza', 'lanche', 'padaria', 'compras',
    // What a bill is called, and who charged/received it (ACC-C-012/015):
    // "a mensalidade da faculdade é 890", "o motoboy recebeu 15 de mim".
    'mensalidade', 'assinatura', 'parcela', 'prestacao', 'taxa', 'multa', 'condominio', 'iptu', 'ipva', 'custa', 'cobrou',
    'cobraram', 'recebeu', 'receberam', 'bancou', 'acertou', 'acertamos', 'de mim', 'comigo'
  ];


  /// "hoje" and its spellings, as whole words ("hj", "oje") — never inside
  /// another word ("projeto", "objeto" read as "hoje" before, CHAOS-A-013).
  static final RegExp _todayWord = RegExp(r'\b(?:hoje|hj|hoji|oje)\b|\b(?:essa|esta|nesta|nessa)\s+(?:manha|tarde|noite)\b');

  /// Misspelled "ontem" as a whole word ("totem" is not "otem").
  static final RegExp _yesterdayTypo = RegExp(r'\b(?:onterm|onte|otem|ontei)\b');

  int _parseDateOffset(String text, {bool skipDayNumber = false}) {
    final lower = CategoryNameMatcher.foldAccents(text.toLowerCase());
    if (_todayWord.hasMatch(lower)) return 0;
    if (_yesterdayTypo.hasMatch(lower) && !RegExp(r'\bante\s*-?\s*|\banti').hasMatch(lower)) return -1;
    // ("semana passada" alone is a span â€” asked, see [_dateQuestion]; with a
    // weekday it is that day, ACC-B-004/CHAOS-B-024.)
    // "segunda", "sábado passado", "há 3 dias", "31/08", "dia 28": the same
    // reading of dates as the reference resolver (CHAOS-R3-002). Spans ("mês
    // passado", "fim de semana") and days still ahead are asked about in
    // [parse], not guessed.
    final said = _spokenDay(lower, skipDayNumber: skipDayNumber);
    final day = said?.day;
    if (day != null && (!day.isRange || _isWeekendSpan(day))) {
      final offset = day.offsetFrom(DateTime.now());
      if (offset <= 0) return offset;
    }
    return 0;
  }

  /// "no fim de semana", "no fds": two days, too short a span to stop the
  /// entry with a question — it goes on the Saturday and César says so
  /// ([_weekendNote]), so a Sunday is one "foi domingo" away.
  static bool _isWeekendSpan(SpokenDay day) => day.isRange && day.label == 'do fim de semana';

  static String? _weekendNote(String dateText) {
    final day = _spokenDay(dateText)?.day;
    if (day == null || !_isWeekendSpan(day) || day.offsetFrom(DateTime.now()) > 0) return null;
    final dd = '${day.start.day.toString().padLeft(2, '0')}/${day.start.month.toString().padLeft(2, '0')}';
    return 'Considerei o sábado ($dd) como o dia do fim de semana. Se foi no domingo, me diga "foi domingo" que eu corrijo a data.';
  }

  /// The date said in [text] (see [SpokenDayParser]), with "amanhã" read too.
  static SpokenDayResult? _spokenDay(String text, {bool skipDayNumber = false}) => SpokenDayParser.parse(
        SpokenDayParser.normalizeWeekdays(CategoryNameMatcher.foldAccents(text.toLowerCase())),
        now: DateTime.now(),
        allowFuture: true,
        skipDayNumber: skipDayNumber,
      );

  /// Whether [text] says when it happened ("hoje" included).
  bool _saysDate(String text) {
    final lower = CategoryNameMatcher.foldAccents(text.toLowerCase());
    return _todayWord.hasMatch(lower) || _yesterdayTypo.hasMatch(lower) || _spokenDay(lower) != null;
  }

  /// Time said in a way no date can be taken from with certainty ("há duas
  /// semanas", "3 meses atrás", "no próximo feriado"): asked, never
  /// recorded as today in silence (ACC-A-004).
  static final RegExp _uncertainTimeMarker = RegExp(
    r'\b(?:(?:ha|faz|tem)\s+(?:uns\s+|umas\s+)?\w+\s+(?:semanas?|mes|meses|anos?)|\w+\s+(?:semanas?|mes|meses|anos?)\s+atras|'
    r'daqui\s+a\s+\w+\s+(?:semanas?|mes|meses)|proxim[oa]s?\s+(?:feriado|quinzena|dia\s+\d{1,2})|'
    r'(?:semana|mes|ano)\s+retrasad[oa])\b',
  );

  /// Why the date said for a new entry can't be recorded as is — a day that
  /// doesn't exist, a span ("mês passado", "fim de semana") or a day still
  /// ahead ("amanhã", "próxima sexta") — as the question to ask, or null.
  /// Never guessed in silence (CHAOS-R3-002, ACC-A-004).
  static String? _dateQuestion(String text, double? amount, {bool skipDayNumber = false}) {
    final said = _spokenDay(text, skipDayNumber: skipDayNumber);
    final value = amount != null && amount > 0 ? QuantityPricing._brl(amount) : 'esse valor';
    if (said == null) {
      final folded = CategoryNameMatcher.foldAccents(text.toLowerCase());
      if (_uncertainTimeMarker.hasMatch(folded) || EntrySafetyGate.vagueTime.hasMatch(folded)) {
        return 'Quando foi esse lançamento de $value? Me diga o dia (ex.: "ontem", "segunda", "dia 15").';
      }
      return null;
    }
    if (said.invalid != null) return Contradiction(ContradictionKind.date, said.invalid!).question(amount);
    final day = said.day!;
    if (day.isRange && day.label == 'do mês passado') {
      return 'Em que dia do mês passado foi esse lançamento de $value? (ex.: "dia 15")';
    }
    if (day.isRange && day.start.isAfter(DateTime.now())) {
      return 'Não registrei ainda porque essa data ainda não chegou (${day.label.replaceFirst(RegExp(r'^d[aeo] '), '')}). '
          'Se já pagou, me diga quando foi (ex.: hoje, ontem); se é uma conta futura, diga "me lembra de pagar…".';
    }
    if (day.isRange && !_isWeekendSpan(day)) {
      return 'Em que dia ${day.label} foi esse lançamento de $value? (ex.: "sábado", "dia 15")';
    }
    if (!day.isRange && day.offsetFrom(DateTime.now()) > 0) {
      return 'Não registrei ainda porque essa data ainda não chegou (${day.label.replaceFirst(RegExp(r'^d[eo] '), '')}). '
          'Se já pagou, me diga quando foi (ex.: hoje, ontem); se é uma conta futura, diga "me lembra de pagar…".';
    }
    return null;
  }

  static const _weekdayNames = r'(segunda|terca|quarta|quinta|sexta|sabado|domingo)';

  /// [raw] (as typed, with capitals) without the date words that are part of
  /// a proper name: "no Bar Dia 7", "na Pizzaria Sábado", "no Sexta Burger",
  /// "no Bar Fim de Semana" — a date word capitalized in the middle of the
  /// sentence names a place, it is not a date (CHAOS-A-013/020).
  static String withoutNameDates(String raw) {
    return raw.replaceAllMapped(
      RegExp(r'(?<=[A-Za-zÀ-ÿ0-9][^.!?:;\n]*\s)(?:Segunda|Terça|Terca|Quarta|Quinta|Sexta|Sábado|Sabado|Domingo|Dia\s+\d{1,2}|Fim\s+de\s+Semana)\b'),
      (m) => 'Nome',
    ).replaceAllMapped(
      // After another capitalized word: "Café Amanhã", "Padaria Hoje",
      // "Loja 25 de Março", "Praça 15 de Novembro" (CHAOS-B-003/023), also
      // after a hyphenated one: "Lava-Jato Amanhã" (CHAOS-C-014).
      RegExp(r'(?<=\S\s+[A-ZÀ-Ý][\wÀ-ÿ]*(?:-[\wÀ-ÿ]+)*\s+)(?:Amanhã|Amanha|Hoje|Ontem|\d{1,2}\s+de\s+(?:Janeiro|Fevereiro|Março|Marco|Abril|Maio|Junho|'
          r'Julho|Agosto|Setembro|Outubro|Novembro|Dezembro))(?![\wÀ-ÿ])'),
      (m) => 'Nome',
    );
  }

  /// When a lowercase weekday comes right after a noun ("na pizzaria
  /// sábado", "no mercado segunda"), it may be the date or part of the
  /// place's name: César takes the date and says so (CHAOS-A-020).
  static String? _gluedWeekdayNote(String dateText, int offset) {
    final lower = SpokenDayParser.normalizeWeekdays(CategoryNameMatcher.foldAccents(dateText.toLowerCase()));
    final m = RegExp('\\b(?:no|na|nos|nas|do|da|pelo|pela)\\s+([a-z]{3,})\\s+$_weekdayNames\\b(?!\\s+(?:passad|retrasad|que\\s+vem))').firstMatch(lower);
    if (m == null || _notItemWords.contains(m.group(1)) || _moneyContextWords.contains(m.group(1)) && m.group(1) != 'mercado') return null;
    final when = DateTime.now().add(Duration(days: offset));
    final dd = '${when.day.toString().padLeft(2, '0')}/${when.month.toString().padLeft(2, '0')}';
    final name = m.group(2)!.replaceAll('terca', 'terça').replaceAll('sabado', 'sábado');
    return 'Considerei a data de $name ($dd). Se "$name" faz parte do nome do lugar, me diga que eu corrijo a data.';
  }

  /// "segunda-feira" → "segunda" (lowercase text): the day, not a "feira".
  static String _withoutWeekdayFeira(String lower) =>
      lower.replaceAllMapped(RegExp(r'(?<![\wÀ-ÿ])(segunda|ter[cç]a|quarta|quinta|sexta)\s*-?\s*feira(?![\wÀ-ÿ])'), (m) => m.group(1)!);

  String _extractDescription(String text, String category) {
    final lower = _withoutWeekdayFeira(text.toLowerCase());

    if (RegExp(r'\bmc\b').hasMatch(lower) || lower.contains('mcdonald') || lower.contains('mequi') || lower.contains('méqui')) {
      return "McDonald's";
    }
    if (RegExp(r'\bbk\b').hasMatch(lower) || lower.contains('burger king') || lower.contains('burguer king')) {
      return "Burger King";
    }
    if (RegExp(r'\b(?:na|no|pela|pelo|app)\s+99\b|\b99\s*(?:pop|taxis|taxi|moto)\b').hasMatch(lower)) {
      return "99";
    }

    final brandAliases = {
      'outback': "Outback",
      'subway': "Subway",
      'starbucks': "Starbucks",
      'habibs': "Habib's",
      'ragazzo': "Ragazzo",
      'spoleto': "Spoleto",
      'dominos': "Domino's",
      'pizza hut': "Pizza Hut",
      'cacau show': "Cacau Show",
      'kopenhagen': "Kopenhagen",
      'bobs': "Bob's",
      'giraffas': "Giraffas",
      'madero': "Madero",
      'bacio di latte': "Bacio di Latte",
      'vivara': "Vivara",
      'zara': "Zara",
      'renner': "Renner",
      'c&a': "C&A",
      'riachuelo': "Riachuelo",
      'h&m': "H&M",
      'marisa': "Marisa",
      'hering': "Hering",
      'reserva': "Reserva",
      'lacoste': "Lacoste",
      'pandora': "Pandora",
      'swarovski': "Swarovski",
      'sephora': "Sephora",
      'boticario': "O Boticário",
      'boticário': "O Boticário",
      'natura': "Natura",
      'centauro': "Centauro",
      'decathlon': "Decathlon",
      'nike': "Nike",
      'adidas': "Adidas",
      'puma': "Puma",
      'asics': "Asics",
      'mizuno': "Mizuno",
      'vans': "Vans",
      'havaianas': "Havaianas",
      'amazon': "Amazon",
      'mercado livre': "Mercado Livre",
      'mercadolivre': "Mercado Livre",
      'shopee': "Shopee",
      'shein': "Shein",
      'aliexpress': "AliExpress",
      'magalu': "Magalu",
      'casas bahia': "Casas Bahia",
      'kabum': "KaBuM!",
      'apple': "Apple",
      'samsung': "Samsung",
      'playstation': "PlayStation",
      'xbox': "Xbox",
      'steam': "Steam",
      'netflix': "Netflix",
      'spotify': "Spotify",
      'openai': "OpenAI",
      'carrefour': "Carrefour",
      'pão de açúcar': "Pão de Açúcar",
      'pao de acucar': "Pão de Açúcar",
      'extra': "Extra",
      'assai': "Assaí",
      'assaí': "Assaí",
      'atacadao': "Atacadão",
      'atacadão': "Atacadão",
      'droga raia': "Droga Raia",
      'drogasil': "Drogasil",
      'pague menos': "Pague Menos",
      'panvel': "Panvel",
      'shell': "Shell",
      'ipiranga': "Ipiranga",
      'petrobras': "Petrobras",
      'graal': "Graal",
      'uber': "Uber",
      'movida': "Movida",
      'localiza': "Localiza",
      'unimed': "Unimed",
      'amil': "Amil",
      'bradesco saúde': "Bradesco Saúde",
      'bradesco saude': "Bradesco Saúde",
      'sulamerica': "SulAmérica",
      'notredame': "NotreDame Intermédica",
      'hapvida': "Hapvida",
      'fleury': "Fleury",
      'delboni': "Delboni",
      'smart fit': "Smart Fit",
      'smartfit': "Smart Fit",
      'bluefit': "Bluefit",
      'bio ritmo': "Bio Ritmo",
      'selfit': "Selfit",
      'growth': "Growth Suplementos",
      'max titanium': "Max Titanium",
      'integralmedica': "IntegralMedica",
      'cobasi': "Cobasi",
      'petz': "Petz",
      'zee dog': "Zee.Dog",
      'zee.dog': "Zee.Dog",
      'enel': "Enel",
      'sabesp': "Sabesp",
      'comgás': "Comgás",
      'comgas': "Comgás",
      'cpfl': "CPFL",
      'light': "Light",
      'cemig': "Cemig",
      'copel': "Copel",
      'vivo': "Vivo",
      'claro': "Claro",
      'tim': "TIM",
      'sem parar': "Sem Parar",
      'conectcar': "ConectCar",
      'veloe': "Veloe",
      'latam': "LATAM",
      'gol': "GOL",
      'azul': "Azul Linhas Aéreas",
      'pacheco': "Drogarias Pacheco",
      'drogaria são paulo': "Drogaria São Paulo",
      'drogaria sao paulo': "Drogaria São Paulo",
      'extrafarma': "Extrafarma",
      'drogaria araujo': "Drogaria Araujo",
      'jeronimo': "Jeronimo",
      'popeyes': "Popeyes",
      'kfc': "KFC",
      'coco bambu': "Coco Bambu",
      'dengo': "Dengo Chocolates",
      'brasil cacau': "Brasil Cacau",
      'the coffee': "The Coffee",
      'we coffee': "We Coffee",
      'rei do mate': "Rei do Mate",
      'zé delivery': "Zé Delivery",
      'ze delivery': "Zé Delivery",
      'rappi': "Rappi",
      'aiqfome': "Aiqfome",
      'sams club': "Sam's Club",
      'oxxo': "Oxxo",
      'camicado': "Camicado",
      'ortobom': "Ortobom",
      'colchão emma': "Emma Colchões",
      'emma': "Emma Colchões",
      'quintoandar': "QuintoAndar",
      'udemy': "Udemy",
      'coursera': "Coursera",
      'alura': "Alura",
      'hotmart': "Hotmart",
      'estácio': "Estácio",
      'estacio': "Estácio",
      'puc': "PUC",
      'fgv': "FGV",
      'unip': "UNIP",
      'disney': "Disney+",
      'disney plus': "Disney+",
      'hbo': "HBO Max",
      'max': "Max",
      'globoplay': "Globoplay",
      'apple tv': "Apple TV",
      'deezer': "Deezer",
      'youtube premium': "YouTube Premium",
      'crunchyroll': "Crunchyroll",
      'twitch': "Twitch",
      'roblox': "Roblox",
      'epic games': "Epic Games",
      'pichau': "Pichau",
      'terabyte': "Terabyte",
      'iphone': "iPhone",
      'ipad': "iPad",
      'macbook': "MacBook",
      'olympikus': "Olympikus",
      'all star': "Converse All Star",
      'converse': "Converse",
      'netshoes': "Netshoes",
      'nubank': "Nubank",
      'banco inter': "Banco Inter",
      'leroy merlin': "Leroy Merlin",
      'telhanorte': "Telhanorte",
      'tok&stok': "Tok&Stok",
      // Common items, bills and categories
      'aluguel': 'Aluguel',
      'condomínio': 'Condomínio',
      'condominio': 'Condomínio',
      'fatura': 'Fatura',
      'conta de luz': 'Conta de Luz',
      'conta de água': 'Conta de Água',
      'luz': 'Luz',
      'água': 'Água',
      'agua': 'Água',
      'internet': 'Internet',
      'faculdade': 'Faculdade',
      'curso': 'Curso',
      'gasolina': 'Gasolina',
      'combustível': 'Combustível',
      'estacionamento': 'Estacionamento',
      'pedágio': 'Pedágio',
      'pedagio': 'Pedágio',
      'passagem': 'Passagem',
      'supermercado': 'Supermercado',
      'mercado': 'Mercado',
      'feira': 'Feira',
      'padaria': 'Padaria',
      'farmácia': 'Farmácia',
      'farmacia': 'Farmácia',
      'remédio': 'Remédio',
      'remedio': 'Remédio',
      'restaurante': 'Restaurante',
      'lanche': 'Lanche',
      'almoço': 'Almoço',
      'jantar': 'Jantar',
      'café': 'Café',
      'cafezinho': 'Café',
      'pastel': 'Pastel',
      'pizza': 'Pizza',
      'hambúrguer': 'Hambúrguer',
      'hamburguer': 'Hambúrguer',
      'sushi': 'Sushi',
      'churrasco': 'Churrasco',
      'cerveja': 'Cerveja',
      'salário': 'Salário',
      'salario': 'Salário',
      'freelance': 'Freelance',
      'freela': 'Freelance',
      'reembolso': 'Reembolso',
      'dividendos': 'Dividendos',
      'rendimento': 'Rendimento',
      'notebook': 'Notebook',
      'computador': 'Computador',
      'celular': 'Celular',
      'smartphone': 'Smartphone',
      'televisão': 'Televisão',
      'televisao': 'Televisão',
      'tv': 'Televisão',
      'tênis': 'Tênis',
      'tenis': 'Tênis',
      'sofá': 'Sofá',
      'sofa': 'Sofá',
      'geladeira': 'Geladeira',
      'fogão': 'Fogão',
      'armário': 'Armário',
      'armario': 'Armário',
      'violão': 'Violão',
      'violao': 'Violão',
      'guitarra': 'Guitarra',
      'baixo': 'Baixo',
      'bateria': 'Bateria',
      'cavaquinho': 'Cavaquinho',
      'ukulele': 'Ukulele',
      'piano': 'Piano',
      'teclado musical': 'Teclado Musical',
      'saxofone': 'Saxofone',
      'flauta': 'Flauta',
      'violino': 'Violino',
      'microfone': 'Microfone',
      'amplificador': 'Amplificador',
      'claude code': 'Claude Code',
      'claude': 'Claude',
      'chatgpt': 'ChatGPT',
      'chat gpt': 'ChatGPT',
      'gemini': 'Gemini',
      'copilot': 'Copilot',
      'perplexity': 'Perplexity',
      'deepseek': 'DeepSeek',
      'midjourney': 'Midjourney',
      'cursor': 'Cursor',
      'duolingo': 'Duolingo',
      'cambly': 'Cambly',
      'open english': 'Open English',
      'anthropic': 'Anthropic',
      'descomplica': 'Descomplica',
      'rocketseat': 'Rocketseat',
      'plano de celular': 'Plano de Celular',
      'plano celular': 'Plano de Celular',
      'plano de internet': 'Plano de Internet',
      'recarga de celular': 'Recarga de Celular',
      'recarga': 'Recarga',
      'paramount': 'Paramount+',
      'paramount+': 'Paramount+',
      'star+': 'Star+',
      'star plus': 'Star+',
      'audible': 'Audible',
      'kindle unlimited': 'Kindle Unlimited',
      'gympass': 'Gympass',
      'wellhub': 'Wellhub',
      'totalpass': 'TotalPass',
      'ps plus': 'PlayStation Plus',
    };

    for (final entry in brandAliases.entries) {
      if (entry.key == 'natura') {
        if (RegExp(r'\b(natura)\b').hasMatch(lower) && !lower.contains('assinatura') && !lower.contains('assinaturas')) {
          return entry.value;
        }
        continue;
      }
      // "estacionamento" is not the Estácio college.
      if (entry.key == 'estacio' && !_estacioBrand.hasMatch(lower)) continue;
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }

    // No known brand/item: name it after what the user said — the thing
    // bought, the place or the kind of income ("comprei um fone de 300" →
    // "Fone", "gastei 32 no sacolão" → "Sacolão", "recebi 250 de comissão" →
    // "Comissão"). Before, a word outside the vocabulary fell back to the
    // category's label ("supermercado / feira"), so "apaga o sacolão" later
    // found nothing (R2-CONV-006/R2-FEAT-003). The label is the last resort.
    final said = _objectOrPlaceNoun(lower);
    if (said != null) return said;
    if (category != 'unknown' && category != 'expense_other') {
      return _getFriendlyCategoryName(category);
    }
    return text;
  }

  static const _notANoun = {
    'pix', 'pics', 'debito', 'débito', 'credito', 'crédito', 'cartao', 'cartão', 'dinheiro', 'boleto', 'especie', 'espécie',
    'dia', 'hoje', 'ontem', 'anteontem', 'semana', 'mes', 'mês', 'ano', 'hora', 'horas', 'valor', 'total', 'pagamento',
    'reais', 'real', 'conto', 'contos', 'pila', 'vista', 'vez', 'vezes', 'parcela', 'parcelas', 'isso', 'algo', 'coisa',
    'coisas', 'mesmo', 'mesma', 'fim', 'volta', 'caminho', 'final', 'meio', 'conta',
    'minha', 'meu', 'meus', 'minhas', 'sua', 'seu', 'nossa', 'nosso', 'uma', 'uns', 'umas', 'mim', 'ele', 'ela', 'voce', 'você',
    'lugar', 'rua', 'gasto', 'gastos', 'compra', 'compras', 'lançamento', 'lancamento', 'entrada', 'saída', 'saida',
    'receita', 'despesa', 'manhã', 'manha', 'tarde', 'noite', 'cada', 'mais', 'menos', 'verdade', 'quem', 'que',
  };

  /// Meals said as a verb ("almocei no quilo") are named by the meal: that is
  /// how the user refers to them later ("o almoço foi 36").
  static const _mealVerbs = {'almocei': 'Almoço', 'almoçamos': 'Almoço', 'almocamos': 'Almoço', 'jantei': 'Jantar', 'jantamos': 'Jantar', 'lanchei': 'Lanche'};

  /// The noun right after "comprei/paguei/gastei (um/uma…)" or after
  /// "no/na/em", skipping payment words, dates and numbers. Null if none.
  static String? _objectOrPlaceNoun(String lower) {
    const word = r'([a-zà-úç]{3,}(?:-[a-zà-úç]{2,})?)';
    for (final e in _mealVerbs.entries) {
      if (RegExp('(?:^|[\\s,])${e.key}(?:[\\s,.!]|\$)').hasMatch(lower)) return e.value;
    }
    final patterns = [
      // "o pagamento do IPTU", "a quitação da mensalidade", "a conta de água".
      // "a mensalidade do pilates", "a assinatura da academia" (ACC-A-020).
      RegExp(r'\b(?:pagamento|quita[cç][aã]o|conta|fatura|taxa|boleto|parcela|presta[cç][aã]o|mensalidade|assinatura|plano)\s+(?:d[oa]s?|de)\s+(?:(?:minha|meu|uma|um)\s+)?' + word),
      RegExp(r'\b(?:comprei|paguei|peguei|pedi|ganhei|vendi|recebi|assinei|contratei)\s+(?:(?:um|uma|uns|umas|o|a|os|as|meu|minha|meus|minhas)\s+)?(?:\d+\s+)?' + word),
      // "recebi 250 de comissão", "gastei 12 de estacionamento".
      RegExp(r'\d(?:[\d.,]*\d)?\s*(?:reais|real|conto|contos|pila|pilas)?\s+(?:de|do|da|com)\s+(?:(?:o|a|um|uma)\s+)?' + word),
      RegExp(r'\b(?:na|no|numa|num|em|pela|pelo)\s+' + word),
      // "gastei com o veterinário": what the money went to (ACC-A-020).
      RegExp(r'\b(?:gastei|gastamos|paguei|pagamos|gasto)\s+(?:\S+\s+){0,2}?com\s+(?:(?:o|a|os|as|um|uma|meu|minha)\s+)?' + word),
      RegExp(r'\b(?:pra|pro|para)\s+(?:(?:a|o)\s+)?' + word),
    ];
    for (final p in patterns) {
      for (final m in p.allMatches(lower)) {
        final w = m.group(1)!;
        if (_notANoun.contains(w) || PtNumberWords.normalize(w) != w) continue;
        if (const {'iptu', 'ipva', 'cnh', 'iof', 'fgts', 'inss', 'crlv', 'dpvat', 'mei', 'das'}.contains(w)) return w.toUpperCase();
        return w[0].toUpperCase() + w.substring(1);
      }
    }
    return null;
  }

  ModelInferenceTrace _predictDetailed(String modelName, Map<String, dynamic> model, List<double> vector) {
    final List<String> classes = (model['classes'] as List).cast<String>();
    final List<double> intercepts = (model['intercept'] as List).map((e) => (e as num).toDouble()).toList();
    final List<dynamic> coefMatrix = model['coef'];

    final scores = List<double>.filled(classes.length, 0.0);

    for (int cIdx = 0; cIdx < classes.length; cIdx++) {
      double score = intercepts[cIdx];
      final List<double> weights = (coefMatrix[cIdx] as List).map((e) => (e as num).toDouble()).toList();

      for (int fIdx = 0; fIdx < vector.length; fIdx++) {
        final val = vector[fIdx];
        if (val != 0.0) {
          score += weights[fIdx] * val;
        }
      }
      scores[cIdx] = score;
    }

    final maxScore = scores.reduce(max);
    final expScores = scores.map((s) => exp(s - maxScore)).toList();
    final sumExp = expScores.reduce((a, b) => a + b);
    final probs = expScores.map((e) => e / sumExp).toList();

    int bestIndex = 0;
    double maxProb = 0.0;
    final List<ClassifierProbabilityTrace> probTraces = [];

    for (int i = 0; i < classes.length; i++) {
      probTraces.add(ClassifierProbabilityTrace(
        label: classes[i],
        score: scores[i],
        probability: probs[i],
      ));
      if (probs[i] > maxProb) {
        maxProb = probs[i];
        bestIndex = i;
      }
    }

    probTraces.sort((a, b) => b.probability.compareTo(a.probability));

    return ModelInferenceTrace(
      modelName: modelName,
      predictedLabel: classes[bestIndex],
      confidence: maxProb,
      probabilities: probTraces,
    );
  }

  /// Inspects and traces the complete neural/ML inference pipeline on-device.
  NeuralThoughtTrace inspect(String phrase) {
    final stopwatch = Stopwatch()..start();
    final cleanText = phrase.trim();
    final normText = _normalizeText(cleanText);
    final lower = normText.toLowerCase();

    // 1. Raw tokens & Typo tracing
    final rawTokens = cleanText.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final normalizedTokens = normText.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final Map<String, String> typoFixes = {};
    for (final t in rawTokens) {
      final clean = t.toLowerCase().replaceAll(RegExp(r'[^\wáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]'), '');
      if (_commonTypoCorrections.containsKey(clean)) {
        typoFixes[clean] = _commonTypoCorrections[clean]!;
      }
    }

    // 2. N-grams & TF-IDF feature extraction
    final ngrams = <String>[];
    ngrams.addAll(normalizedTokens);
    for (int i = 0; i < normalizedTokens.length - 1; i++) {
      ngrams.add('${normalizedTokens[i]} ${normalizedTokens[i + 1]}');
    }

    final Map<int, int> counts = {};
    final Map<int, String> indexToToken = {};
    for (final ng in ngrams) {
      if (_vocabulary.containsKey(ng)) {
        final idx = _vocabulary[ng]!;
        counts[idx] = (counts[idx] ?? 0) + 1;
        indexToToken[idx] = ng;
      }
    }

    final vector = List<double>.filled(_vocabSize, 0.0);
    final double totalTokens = normalizedTokens.isEmpty ? 1.0 : normalizedTokens.length.toDouble();
    final List<ActiveFeatureTrace> activeFeatures = [];

    counts.forEach((idx, count) {
      final tf = count / totalTokens;
      final val = tf * _idf[idx];
      vector[idx] = val;
      activeFeatures.add(ActiveFeatureTrace(
        token: indexToToken[idx] ?? 'feat_$idx',
        index: idx,
        tf: tf,
        idf: _idf[idx],
        value: val,
      ));
    });

    activeFeatures.sort((a, b) => b.value.compareTo(a.value));

    // 3. Dense Classifier Inferences
    final intentTrace = _predictDetailed('intent', _intentModel, vector);
    final categoryTrace = _predictDetailed('category', _categoryModel, vector);
    final paymentTrace = _predictDetailed('payment_method', _paymentModel, vector);

    // 4. Slots & Draft Parse
    final draft = parse(phrase);

    final isSubscription = draft.isRecurrent;
    final isAnnual = isSubscription &&
        (draft.recurrenceDuration == 'anual' ||
            lower.contains('anual') ||
            lower.contains('12 meses') ||
            lower.contains('1 ano') ||
            lower.contains('um ano') ||
            lower.contains('plano anual'));

    final isCredit = draft.paymentMethod == 'credit_card';
    final isExempt = isCredit && isSubscription && !isAnnual;

    String explanation;
    if (!isCredit) {
      explanation = 'Forma de pagamento não é cartão de crédito: não requer parcelamento.';
    } else if (isExempt) {
      explanation = 'Assinatura mensal/recorrente no crédito: cobrança avulsa mensal (isenta de parcelamento, 1x).';
    } else if (isAnnual) {
      if (draft.installments != null && draft.installments! > 1) {
        explanation = 'Assinatura anual no crédito parcelada em ${draft.installments}x.';
      } else {
        explanation = 'Assinatura anual no crédito: permite parcelamento em até 12x.';
      }
    } else {
      if (draft.installments != null && draft.installments! > 1) {
        explanation = 'Compra no crédito parcelada em ${draft.installments}x.';
      } else {
        explanation = 'Compra comum no crédito: requer desambiguação de parcelas.';
      }
    }

    final installmentTrace = InstallmentDecisionTrace(
      installments: draft.installments,
      isCreditCard: isCredit,
      isSubscription: isSubscription,
      isAnnual: isAnnual,
      isExempt: isExempt,
      explanation: explanation,
    );

    stopwatch.stop();

    return NeuralThoughtTrace(
      rawText: cleanText,
      normalizedText: normText,
      rawTokens: rawTokens,
      normalizedTokens: normalizedTokens,
      typoFixes: typoFixes,
      ngrams: ngrams,
      activeFeatures: activeFeatures,
      intentModel: intentTrace,
      categoryModel: categoryTrace,
      paymentModel: paymentTrace,
      parsedAmount: draft.amount,
      dateOffsetDays: draft.dateOffsetDays,
      extractedDescription: draft.description,
      isRecurrent: draft.isRecurrent,
      dueDay: draft.dueDay,
      frequency: draft.frequency,
      recurrenceDuration: draft.recurrenceDuration,
      installmentDecision: installmentTrace,
      missingSlots: draft.missingSlots,
      isComplete: draft.isComplete,
      clarificationPrompt: draft.clarificationPrompt,
      budgetInsight: draft.budgetInsight,
      latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
      draft: draft,
    );
  }
}
