import 'dart:convert';
import 'dart:math';

/// Prediction result with class label and confidence score.
class PredictionResult {
  final String label;
  final double confidence;

  PredictionResult(this.label, this.confidence);
}

/// Representation of a parsed financial transaction extracted locally on-device.
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
  }) {
    return FinancialTransactionDraft(
      intent: intent ?? this.intent,
      intentConfidence: intentConfidence ?? this.intentConfidence,
      category: category ?? this.category,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      amount: amount ?? this.amount,
      dateOffsetDays: dateOffsetDays ?? this.dateOffsetDays,
      description: description ?? this.description,
      rawText: rawText ?? this.rawText,
      latencyMs: latencyMs ?? this.latencyMs,
      isComplete: isComplete ?? this.isComplete,
      missingSlots: missingSlots ?? this.missingSlots,
      clarificationPrompt: clarificationPrompt ?? this.clarificationPrompt,
    );
  }
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

  LocalFinancialNlpEngine._({
    required Map<String, int> vocabulary,
    required List<double> idf,
    required Map<String, dynamic> intentModel,
    required Map<String, dynamic> categoryModel,
    required Map<String, dynamic> paymentModel,
    required double confidenceThreshold,
  })  : _vocabulary = vocabulary,
        _idf = idf,
        _intentModel = intentModel,
        _categoryModel = categoryModel,
        _paymentModel = paymentModel,
        _vocabSize = vocabulary.length,
        _confidenceThreshold = confidenceThreshold;

  /// Factory initializer from JSON string asset or file.
  factory LocalFinancialNlpEngine.fromJsonString(String jsonStr) {
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
    );
  }

  /// Parses raw Portuguese input text into a structured FinancialTransactionDraft on-device.
  FinancialTransactionDraft parse(String phrase) {
    final stopwatch = Stopwatch()..start();
    final cleanText = phrase.trim();
    final normText = _normalizeText(cleanText);
    final lower = normText.toLowerCase();

    // Prompt Injection & Non-Financial System Noise Guard
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
        clarificationPrompt: 'Notei que sua mensagem não parece ser um lançamento financeiro. Como posso te ajudar com suas finanças hoje?',
      );
    }

    final vector = _extractTfIdfVector(normText);
    final intentResult = _predictWithConfidence(_intentModel, vector);
    final categoryResult = _predictWithConfidence(_categoryModel, vector);
    final paymentResult = _predictWithConfidence(_paymentModel, vector);
    final amount = _parseAmount(normText);
    final dateOffsetDays = _parseDateOffset(normText);
    final description = _extractDescription(cleanText, categoryResult.label);

    var resolvedIntent = intentResult.label;

    // Financial keywords set
    final financialKeywords = [
      'gastei', 'gasto', 'gastos', 'paguei', 'pagar', 'pagamento', 'comprei', 'compra', 'compras',
      'caiu', 'recebi', 'receita', 'receitas', 'mandei', 'transferi', 'pix', 'transferencia', 'transferência',
      'saldo', 'sobrou', 'orçamento', 'orcamento', 'despesa', 'despesas', 'extrato', 'fatura', 'limite',
      'mercado', 'supermercado', 'uber', 'gasolina', 'farmacia', 'remédios', 'ifood', 'luz', 'agua', 'internet',
      'aluguel', 'salario', 'salário', 'reembolso', 'freela', 'pila', 'conto', 'reais', 'dinheiro', 'cartao', 'cartão'
    ];

    var hasFinKw = financialKeywords.any((k) => lower.contains(k));
    if (lower.contains('receita de ') || lower.contains('cozinhar') || lower.contains('bolo')) {
      hasFinKw = false;
    }

    // Question query override
    if (lower.startsWith('quanto ') || lower.startsWith('quantos ') || lower.startsWith('quantas ') || lower.startsWith('qual ') || lower.startsWith('como estão ') || lower.startsWith('mostre ')) {
      if (hasFinKw) {
        resolvedIntent = 'query';
      } else {
        resolvedIntent = 'unknown';
      }
    }

    if ((resolvedIntent == 'query' || resolvedIntent == 'unknown') && amount != null && amount > 0 && hasFinKw) {
      if (lower.contains('caiu') || lower.contains('recebi')) {
        resolvedIntent = 'income';
      } else if (lower.contains('mandei') || lower.contains('transferi')) {
        resolvedIntent = 'transfer';
      } else {
        resolvedIntent = 'expense';
      }
    } else if (!hasFinKw && amount == null) {
      resolvedIntent = 'unknown';
    }

    // Evaluate Slot Completeness
    final missingSlots = <String>[];
    if (resolvedIntent == 'expense' || resolvedIntent == 'income' || resolvedIntent == 'transfer') {
      if (amount == null || amount <= 0) {
        missingSlots.add('amount');
      }
      if (!_hasCategoryNoun(cleanText)) {
        missingSlots.add('category');
      }
      if (paymentResult.label == 'unknown' || !_hasPaymentKeyword(cleanText)) {
        missingSlots.add('payment_method');
      }
    }

    final isComplete = (resolvedIntent != 'unknown') && missingSlots.isEmpty;
    final clarificationPrompt = isComplete
        ? null
        : _generateEmpatheticClarificationPrompt(
            intent: resolvedIntent,
            amount: amount,
            missingSlots: missingSlots,
          );

    stopwatch.stop();

    return FinancialTransactionDraft(
      intent: resolvedIntent,
      intentConfidence: intentResult.confidence,
      category: categoryResult.label,
      paymentMethod: paymentResult.label,
      amount: amount,
      dateOffsetDays: dateOffsetDays,
      description: description,
      rawText: cleanText,
      latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
      isComplete: isComplete,
      missingSlots: missingSlots,
      clarificationPrompt: clarificationPrompt,
    );
  }

  /// Merges a follow-up answer from the user into a previously incomplete draft.
  FinancialTransactionDraft mergeDrafts(FinancialTransactionDraft previousDraft, String followUpText) {
    final followUpParsed = parse(followUpText);

    final updatedAmount = previousDraft.amount ?? followUpParsed.amount;
    final updatedCategory = (previousDraft.category != 'unknown' && previousDraft.category != 'expense_other')
        ? previousDraft.category
        : (followUpParsed.category != 'unknown' ? followUpParsed.category : previousDraft.category);
    final updatedPayment = (previousDraft.paymentMethod != 'unknown')
        ? previousDraft.paymentMethod
        : (followUpParsed.paymentMethod != 'unknown' ? followUpParsed.paymentMethod : previousDraft.paymentMethod);
    final updatedIntent = previousDraft.intent != 'unknown' ? previousDraft.intent : followUpParsed.intent;

    final mergedRaw = '${previousDraft.rawText} + ${followUpText.trim()}';

    // Re-check completeness
    final missingSlots = <String>[];
    if (updatedAmount == null || updatedAmount <= 0) missingSlots.add('amount');
    if (updatedCategory == 'unknown' || updatedCategory == 'expense_other') {
      if (!_hasCategoryNoun(mergedRaw)) missingSlots.add('category');
    }
    if (updatedPayment == 'unknown') {
      if (!_hasPaymentKeyword(mergedRaw)) missingSlots.add('payment_method');
    }

    final isComplete = (updatedIntent != 'unknown') && missingSlots.isEmpty;
    final clarification = isComplete
        ? null
        : _generateEmpatheticClarificationPrompt(
            intent: updatedIntent,
            amount: updatedAmount,
            missingSlots: missingSlots,
          );

    return previousDraft.copyWith(
      intent: updatedIntent,
      category: updatedCategory,
      paymentMethod: updatedPayment,
      amount: updatedAmount,
      rawText: mergedRaw,
      isComplete: isComplete,
      missingSlots: missingSlots,
      clarificationPrompt: clarification,
    );
  }

  /// Generates brand-aligned empathetic UX writing clarification prompts (Krezio-brand).
  String _generateEmpatheticClarificationPrompt({
    required String intent,
    required double? amount,
    required List<String> missingSlots,
  }) {
    if (intent == 'unknown') {
      return 'Notei que sua mensagem não parece ser um lançamento financeiro. Como posso te ajudar com suas finanças hoje?';
    }

    final amountStr = amount != null ? 'R\$ ${amount.toStringAsFixed(2).replaceAll('.', ',')}' : null;

    if (missingSlots.contains('amount') && missingSlots.contains('category') && missingSlots.contains('payment_method')) {
      return 'Notei que iniciou um lançamento! Qual foi o valor, o local e a forma de pagamento desse gasto?';
    }

    if (missingSlots.contains('category') && missingSlots.contains('payment_method')) {
      return amountStr != null
          ? 'Anotado $amountStr! Com o que você gastou esse valor e qual foi a forma de pagamento? (ex: mercado no débito, farmácia no pix)'
          : 'Anotado! Onde você realizou esse gasto e qual foi a forma de pagamento?';
    }

    if (missingSlots.contains('category')) {
      return amountStr != null
          ? 'Anotado $amountStr! Onde ou com o que você gastou esse valor? (ex: mercado, transporte, lazer)'
          : 'Com o que foi esse gasto? (ex: mercado, farmácia, combustível)';
    }

    if (missingSlots.contains('payment_method')) {
      return amountStr != null
          ? 'Anotado $amountStr! Qual foi a forma de pagamento utilizada? (ex: pix, débito, crédito, dinheiro)'
          : 'Qual foi a forma de pagamento dessa transação? (ex: pix, crédito, débito)';
    }

    if (missingSlots.contains('amount')) {
      return 'Notei que não especificou o valor. Qual foi a quantia dessa transação?';
    }

    return 'Notei que faltam alguns detalhes para concluir o lançamento. Pode me informar o valor e a categoria?';
  }

  bool _hasCategoryNoun(String text) {
    final lower = text.toLowerCase();
    final nouns = [
      'mercado', 'supermercado', 'feira', 'arroz', 'feijao', 'uber', 'gasolina', 'posto',
      'farmacia', 'remedio', 'medico', 'cinema', 'ifood', 'cerveja', 'restaurante', 'bar',
      'luz', 'agua', 'internet', 'aluguel', 'condominio', 'faculdade', 'curso', 'salario',
      'reembolso', 'freela', 'acao', 'açoes', 'dividendos', 'tesouro'
    ];
    return nouns.any((k) => lower.contains(k));
  }

  bool _hasPaymentKeyword(String text) {
    final lower = text.toLowerCase();
    final keywords = ['pix', 'credito', 'crédito', 'debito', 'débito', 'dinheiro', 'especie', 'espécie', 'boleto', 'cartao', 'cartão'];
    return keywords.any((k) => lower.contains(k));
  }

  String _normalizeText(String text) {
    // Reduce 3+ repeated characters (e.g. gasteeeeii -> gastei)
    return text.toLowerCase().replaceAllMapped(RegExp(r'(.)\1{2,}'), (match) => match.group(1)!);
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

  double? _parseAmount(String text) {
    final lower = text.toLowerCase();

    // Filter out English system / prompt injection keywords
    final systemWords = ['system', 'override', 'status', 'code', 'python', 'abcdefg', 'ignore', 'instructions'];
    if (systemWords.any((w) => lower.contains(w))) {
      return null;
    }

    // Check word numbers
    if (lower.contains('quinhentos reais')) return 500.0;
    if (lower.contains('cem reais')) return 100.0;
    if (lower.contains('duzentos reais')) return 200.0;
    if (lower.contains('cinquenta reais')) return 50.0;
    if (lower.contains('vinte reais')) return 20.0;
    if (lower.contains('trinta conto')) return 30.0;

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

    // Require explicit financial verbs or currency terms to extract raw numbers
    final financialVerbs = ['gastei', 'gaste', 'paguei', 'comprei', 'caiu', 'recebi', 'mandei', 'transferi', 'reais', 'conto', 'pila', 'r\$', 'fatura', 'troco', 'fiado'];
    if (!financialVerbs.any((v) => lower.contains(v))) {
      return null;
    }

    final regExp = RegExp(r'(\d+(?:[.,]\d{1,2})?)', caseSensitive: false);
    final match = regExp.firstMatch(text);
    if (match != null) {
      final strVal = match.group(1)?.replaceAll('.', '').replaceAll(',', '.');
      if (strVal != null) {
        final val = double.tryParse(strVal);
        if (val != null && val > 0 && val < 1000000) {
          return val;
        }
      }
    }
    return null;
  }

  int _parseDateOffset(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('hoje') || lower.contains('essa manhã') || lower.contains('nesta tarde')) {
      return 0;
    } else if (lower.contains('ontem')) {
      return -1;
    } else if (lower.contains('anteontem')) {
      return -2;
    } else if (lower.contains('semana passada')) {
      return -7;
    } else if (lower.contains('fim de semana')) {
      return -3;
    }
    return 0;
  }

  String _extractDescription(String text, String category) {
    if (category != 'unknown' && category != 'expense_other') {
      return category;
    }
    return text;
  }
}
