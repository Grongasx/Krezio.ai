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
  final int? installments; // 1 = à vista / parcela única, 2..N = parcelado
  final bool isRecurrent;
  final int? dueDay; // 1..31
  final String? frequency; // 'monthly', 'weekly', 'yearly'
  final String? bankSource; // 'Nubank', 'Itaú', 'Inter', 'Bradesco', etc.
  final String? budgetInsight;
  final bool isCorrection;
  final bool isCanceled;
  final String? recurrenceDuration;

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
    this.frequency,
    this.recurrenceDuration,
    this.bankSource,
    this.budgetInsight,
    this.isCorrection = false,
    this.isCanceled = false,
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
        'frequency': frequency,
        'recurrence_duration': recurrenceDuration,
        'bank_source': bankSource,
        'budget_insight': budgetInsight,
        'is_correction': isCorrection,
        'is_canceled': isCanceled,
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
    String? frequency,
    String? recurrenceDuration,
    String? bankSource,
    String? budgetInsight,
    bool? isCorrection,
    bool? isCanceled,
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
      installments: installments ?? this.installments,
      isRecurrent: isRecurrent ?? this.isRecurrent,
      dueDay: dueDay ?? this.dueDay,
      frequency: frequency ?? this.frequency,
      recurrenceDuration: recurrenceDuration ?? this.recurrenceDuration,
      bankSource: bankSource ?? this.bankSource,
      budgetInsight: budgetInsight ?? this.budgetInsight,
      isCorrection: isCorrection ?? this.isCorrection,
      isCanceled: isCanceled ?? this.isCanceled,
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
        clarificationPrompt: 'Como posso te ajudar com suas finanças hoje?',
      );
    }

    final vector = _extractTfIdfVector(normText);
    final intentResult = _predictWithConfidence(_intentModel, vector);
    final categoryResult = _predictWithConfidence(_categoryModel, vector);
    final paymentResult = _predictWithConfidence(_paymentModel, vector);
    final amount = _parseAmount(normText);
    final dateOffsetDays = _parseDateOffset(normText);
    final description = _extractDescription(cleanText, categoryResult.label);
    final recurrence = _parseRecurrence(cleanText);

    var resolvedIntent = intentResult.label;

    // Financial keywords set
    final financialKeywords = [
      'gastei', 'gasto', 'gastos', 'paguei', 'pagar', 'pagamento', 'comprei', 'compra', 'compras',
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
      'violão', 'violao', 'guitarra', 'bateria', 'piano'
    ];

    bool hasFinKw = financialKeywords.any((k) => lower.contains(k));
    if (lower.startsWith('como ') || lower.startsWith('que horas') || lower.startsWith('o dia ') || lower.startsWith('qual a capital')) {
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

    if (lower.startsWith('gastei') || lower.startsWith('comprei') || lower.startsWith('paguei') || lower.startsWith('abasteci') ||
        lower.startsWith('assinei') || lower.startsWith('pedi ') || lower.startsWith('almocei') || lower.startsWith('jantei') || lower.startsWith('lanchei') ||
        lower.startsWith('renovei') || lower.startsWith('contratei') || lower.startsWith('recarreguei')) {
      resolvedIntent = 'expense';
    }

    if (lower.contains('uber ') || lower.startsWith('uber') || lower.contains('gasolina') || lower.contains('abasteci') || lower.contains('posto ')) {
      if (resolvedIntent != 'query') resolvedIntent = 'expense';
    }

    if ((resolvedIntent == 'query' || resolvedIntent == 'unknown' || resolvedIntent == 'transfer') && amount != null && amount > 0 && hasFinKw) {
      if (lower.contains('caiu') || lower.contains('recebi') || lower.contains('me mandou') || lower.contains('me transferiu') || lower.contains('salario') || lower.contains('salário')) {
        resolvedIntent = 'income';
      } else if (lower.contains('mandei') || lower.contains('transferi para') || lower.contains('transferi pra')) {
        resolvedIntent = 'transfer';
      } else if (!lower.contains('transferi') && !lower.contains('mandei')) {
        resolvedIntent = 'expense';
      }
    } else if (!hasFinKw && amount == null) {
      resolvedIntent = 'unknown';
    }

    final hasCategoryNoun = _hasCategoryNoun(normText);
    var resolvedCategory = _resolveContextualCategory(lower, categoryResult.label);

    if (!hasCategoryNoun && resolvedCategory == 'unknown') {
      resolvedCategory = 'unknown';
    }

    final resolvedPaymentMethod = _resolvePaymentMethod(cleanText, paymentResult.label);
    final resolvedInstallments = (resolvedPaymentMethod == 'credit_card' || _hasInstallmentKeyword(cleanText))
        ? _parseInstallments(cleanText)
        : null;

    // Evaluate Slot Completeness strictly: NEVER flag a slot as missing if it was already identified!
    final missingSlots = <String>[];
    if (resolvedIntent == 'expense' || resolvedIntent == 'income' || resolvedIntent == 'transfer') {
      if (amount == null || amount <= 0) {
        missingSlots.add('amount');
      }
      
      final isCategoryIdentified = hasCategoryNoun && resolvedCategory != 'unknown';
      if (!isCategoryIdentified && resolvedIntent == 'expense') {
        missingSlots.add('category');
      }
      
      final isPaymentIdentified = resolvedPaymentMethod != 'unknown';
      if (!isPaymentIdentified) {
        missingSlots.add('payment_method');
      }

      // For credit card expenses, check if installments were clarified
      if (resolvedIntent == 'expense' && resolvedPaymentMethod == 'credit_card' && resolvedInstallments == null) {
        missingSlots.add('installments');
      }

      // For new subscriptions formulation, track due_day and recurrence_duration
      final isNewSubscription = lower.contains('assinei') || lower.contains('assinar') || lower.contains('contratei') || lower.contains('mensalidade');
      if (isNewSubscription) {
        if (recurrence['due_day'] == null) {
          missingSlots.add('due_day');
        }
        if (recurrence['recurrence_duration'] == null) {
          missingSlots.add('recurrence_duration');
        }
      }
    }

    final isComplete = (resolvedIntent != 'unknown') && missingSlots.isEmpty;
    final clarificationPrompt = isComplete
        ? null
        : _generateEmpatheticClarificationPrompt(
            intent: resolvedIntent,
            amount: amount,
            category: resolvedCategory,
            paymentMethod: resolvedPaymentMethod,
            description: description,
            missingSlots: missingSlots,
            rawText: cleanText,
            isRecurrent: recurrence['is_recurrent'] as bool? ?? false,
            dueDay: recurrence['due_day'] as int?,
            recurrenceDuration: recurrence['recurrence_duration'] as String?,
          );

    final budgetInsight = isComplete
        ? _generateBudgetInsight(resolvedIntent, resolvedCategory, amount, recurrence['is_recurrent'] as bool? ?? false)
        : null;

    stopwatch.stop();

    return FinancialTransactionDraft(
      intent: resolvedIntent,
      intentConfidence: intentResult.confidence,
      category: resolvedCategory,
      paymentMethod: resolvedPaymentMethod,
      amount: amount,
      dateOffsetDays: dateOffsetDays,
      description: description,
      rawText: cleanText,
      latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
      isComplete: isComplete,
      missingSlots: missingSlots,
      clarificationPrompt: clarificationPrompt,
      installments: resolvedInstallments,
      isRecurrent: recurrence['is_recurrent'] as bool? ?? false,
      dueDay: recurrence['due_day'] as int?,
      frequency: recurrence['frequency'] as String?,
      recurrenceDuration: recurrence['recurrence_duration'] as String?,
      budgetInsight: budgetInsight,
    );
  }

  /// Parses multi-transaction inputs (e.g. "Gastei 150 no mercado no debito e 35 no uber no pix")
  List<FinancialTransactionDraft> parseMulti(String phrase) {
    final clean = phrase.trim();

    // Check if phrase contains multiple transactions separated by commas (not decimal numbers), semicolons, or conjunctions
    final separatorPattern = RegExp(r'\s*(?:,(?!\d)|;|\be\b|\balém\s+de\b|\balem\s+de\b|\bmais\b)\s*', caseSensitive: false);
    final segments = clean.split(separatorPattern);

    if (segments.length >= 2) {
      final drafts = <FinancialTransactionDraft>[];
      for (final seg in segments) {
        final segTrim = seg.trim();
        if (segTrim.isEmpty) continue;
        
        final draft = parse(segTrim);
        if (draft.intent != 'unknown' && draft.amount != null) {
          drafts.add(draft);
        }
      }

      if (drafts.length >= 2) {
        return drafts;
      }
    }

    return [parse(phrase)];
  }

  /// Applies post-transaction corrections or cancellations in the next turn
  FinancialTransactionDraft applyCorrection(FinancialTransactionDraft lastTx, String correctionText) {
    final lower = correctionText.toLowerCase().trim();

    // 1. Cancellation / Undo
    if (lower.contains('cancela') || lower.contains('apaga') || lower.contains('exclui') || lower.contains('desconsidera') || lower.contains('deleta')) {
      return lastTx.copyWith(
        isCanceled: true,
        isCorrection: true,
        clarificationPrompt: 'Pronto! O último lançamento (${lastTx.description}) foi cancelado com sucesso. 🗑️',
      );
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
    double? newAmount;
    final isInstallmentOnly = RegExp(r'^(?:foi\s+)?(?:em\s+)?\d{1,2}\s*(?:x|vezes|parcelas)$', caseSensitive: false).hasMatch(correctionText.trim());
    if (!isInstallmentOnly) {
      newAmount = _parseAmount(correctionText) ?? _extractAmountFromFollowUp(correctionText);
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

    return lastTx.copyWith(
      amount: updatedAmount,
      paymentMethod: updatedPayment,
      installments: updatedInstallments,
      category: updatedCategory,
      description: updatedDesc,
      isCorrection: true,
      isComplete: true,
      missingSlots: [],
      clarificationPrompt: 'Pronto! Atualizei seu lançamento de ${lastTx.description} para $updatedDesc. ✨',
    );
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
      dateOffsetDays: 0,
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
  Map<String, dynamic> _parseRecurrence(String text) {
    final lower = text.toLowerCase();
    bool isRecurrent = false;
    int? dueDay;
    String? frequency;
    String? recurrenceDuration;

    final dueMatch = RegExp(r'(?:todo\s+dia|vence\s+dia|vencimento\s+dia|renova\s+dia|renovação\s+dia|renovacao\s+dia|no\s+dia|dia)\s+(\d{1,2})\b', caseSensitive: false).firstMatch(lower);
    if (dueMatch != null) {
      final d = int.tryParse(dueMatch.group(1) ?? '');
      if (d != null && d >= 1 && d <= 31) {
        dueDay = d;
        isRecurrent = true;
        frequency = 'monthly';
      }
    }

    if (lower.contains('mensalmente') || lower.contains('todo mês') || lower.contains('todo mes') ||
        lower.contains('assinatura') || lower.contains('assinei') || lower.contains('assinar') ||
        lower.contains('mensalidade') || lower.contains('mensalidades') || lower.contains('recorrente') ||
        lower.contains('plano mensal') || lower.contains('plano de celular') || lower.contains('plano celular') ||
        lower.contains('plano controle') || lower.contains('renovação') || lower.contains('renovacao') ||
        lower.contains('renova') || lower.contains('renovei')) {
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

    return {
      'is_recurrent': isRecurrent,
      'due_day': dueDay,
      'frequency': frequency,
      'recurrence_duration': recurrenceDuration,
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
    final followUpParsed = parse(followUpText);

    // 1. Contextual Amount resolution (e.g. user answered just "700" or "vintao")
    double? updatedAmount = previousDraft.amount;
    if (updatedAmount == null || updatedAmount <= 0) {
      updatedAmount = followUpParsed.amount ?? _extractAmountFromFollowUp(followUpText);
    }

    // 2. Contextual Category resolution
    var updatedCategory = previousDraft.category;
    if (updatedCategory == 'unknown' || updatedCategory == 'expense_other') {
      if (followUpParsed.category != 'unknown' && followUpParsed.category != 'expense_other') {
        updatedCategory = followUpParsed.category;
      } else if (_hasCategoryNoun(followUpText)) {
        updatedCategory = followUpParsed.category;
      }
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
    final followUpInst = followUpParsed.installments ?? _parseInstallments(followUpText);
    if (followUpInst != null && followUpInst > 0) {
      updatedInstallments = followUpInst;
      if (updatedPayment == 'unknown') {
        updatedPayment = 'credit_card';
      }
    } else if (updatedInstallments == null && (updatedPayment == 'credit_card' || previousDraft.missingSlots.contains('installments'))) {
      updatedInstallments = followUpParsed.installments ?? _parseInstallments(followUpText);
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

    final updatedIntent = previousDraft.intent != 'unknown' ? previousDraft.intent : followUpParsed.intent;
    final mergedRaw = '${previousDraft.rawText} + ${followUpText.trim()}';

    // Re-check completeness strictly
    final missingSlots = <String>[];
    if (updatedAmount == null || updatedAmount <= 0) missingSlots.add('amount');
    
    final isCatIdentified = (updatedCategory != 'unknown' && updatedCategory != 'expense_other') || _hasCategoryNoun(mergedRaw);
    if (!isCatIdentified) missingSlots.add('category');

    final isPayIdentified = updatedPayment != 'unknown';
    if (!isPayIdentified) missingSlots.add('payment_method');

    if (updatedIntent == 'expense' && updatedPayment == 'credit_card' && updatedInstallments == null) {
      missingSlots.add('installments');
    }

    final isNewSub = mergedRaw.toLowerCase().contains('assinei') || mergedRaw.toLowerCase().contains('assinar') || mergedRaw.toLowerCase().contains('contratei') || mergedRaw.toLowerCase().contains('mensalidade');
    if (updatedIsRecurrent && isNewSub) {
      if (updatedDueDay == null) missingSlots.add('due_day');
      if (updatedDuration == null) missingSlots.add('recurrence_duration');
    }

    final isComplete = (updatedIntent != 'unknown') && missingSlots.isEmpty;
    final clarification = isComplete
        ? null
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
      installments: updatedInstallments,
      isRecurrent: updatedIsRecurrent,
      dueDay: updatedDueDay,
      recurrenceDuration: updatedDuration,
    );
  }

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

  double? _extractAmountFromFollowUp(String text) {
    final std = _parseAmount(text);
    if (std != null) return std;

    final lower = text.toLowerCase().trim();
    final slangMap = <String, double>{
      'vintão': 20.0, 'vintao': 20.0, 'vintinha': 20.0, 'vinte': 20.0,
      'dezão': 10.0, 'dezao': 10.0, 'dezinha': 10.0, 'dez': 10.0,
      'cinquentão': 50.0, 'cinquentao': 50.0, 'cinquentinha': 50.0, 'cinquenta': 50.0,
      'quarenta': 40.0, 'quarentinha': 40.0, 'trinta': 30.0, 'trintinha': 30.0,
      'quinze': 15.0, 'quinzinha': 15.0, 'cinco': 5.0, 'dois': 2.0, 'um': 1.0,
      'cem': 100.0, 'cemzão': 100.0, 'cemzao': 100.0, 'cemzinho': 100.0,
      'duzentos': 200.0, 'trezentos': 300.0, 'quatrocentos': 400.0, 'quinhentos': 500.0,
      'seiscentos': 600.0, 'setecentos': 700.0, 'oitocentos': 800.0, 'novecentos': 900.0,
      'mil': 1000.0, 'barão': 1000.0, 'barao': 1000.0, 'um barão': 1000.0, 'dois paus': 2000.0
    };
    for (final entry in slangMap.entries) {
      if (lower == entry.key || lower.startsWith('${entry.key} ')) {
        return entry.value;
      }
    }

    // Direct number extraction: "700", "700,00", "67.90", "R$ 700", "700 reais"
    final cleanStr = lower.replaceAll('r\$', '').replaceAll('reais', '').replaceAll('real', '').replaceAll('conto', '').replaceAll('pila', '').trim();
    final regExp = RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)');
    final match = regExp.firstMatch(cleanStr);
    if (match != null) {
      final val = cleanAndParseAmount(match.group(1));
      if (val != null && val > 0 && val < 1000000000) {
        return val;
      }
    }
    return null;
  }

  /// Systematically classifies input text into one of Krezio's financial categories
  /// based on comprehensive lexical, brand, and entity indicators.
  static String _resolveContextualCategory(String lower, String modelPredicted) {
    // 1. EDUCAÇÃO, PLATAFORMAS & INTELIGÊNCIAS ARTIFICIAIS
    if (lower.contains('faculdade') || lower.contains('mensalidade escolar') || lower.contains('escola') || lower.contains('creche') ||
        lower.contains('pós-graduação') || lower.contains('pos-graduacao') || lower.contains('mba') || lower.contains('curso') ||
        lower.contains('udemy') || lower.contains('coursera') || lower.contains('alura') || lower.contains('hotmart') ||
        lower.contains('livro') || lower.contains('apostila') || lower.contains('material escolar') || lower.contains('estácio') ||
        lower.contains('estacio') || lower.contains('puc') || lower.contains('fgv') || lower.contains('unip') || lower.contains('anhanguera') ||
        lower.contains('claude') || lower.contains('chatgpt') || lower.contains('chat gpt') || lower.contains('openai') ||
        lower.contains('anthropic') || lower.contains('gemini') || lower.contains('copilot') || lower.contains('perplexity') ||
        lower.contains('deepseek') || lower.contains('midjourney') || lower.contains('cursor') || lower.contains('duolingo') ||
        lower.contains('cambly') || lower.contains('open english') || lower.contains('descomplica') || lower.contains('rocketseat')) {
      return 'education';
    }

    // 2. SALÁRIO E RECEITAS TRABALHISTAS
    if (lower.contains('salario') || lower.contains('salário') || lower.contains('adiantamento') || lower.contains('vale refeição') ||
        lower.contains('vale alimentação') || lower.contains('décimo terceiro') || lower.contains('13º') || lower.contains('13o') ||
        lower.contains('férias') || lower.contains('ferias') || lower.contains('pró-labore') || lower.contains('pro-labore') ||
        lower.contains('comissão') || lower.contains('comissao') || lower.contains('plr') || lower.contains('bônus') || lower.contains('bonus')) {
      return 'salary';
    }

    // 3. INVESTIMENTOS
    if (lower.contains('investimento') || lower.contains('aporte') || lower.contains('ações') || lower.contains('acoes') ||
        lower.contains('dividendos') || lower.contains('rendimento') || lower.contains('jcp') || lower.contains('tesouro direto') ||
        lower.contains('tesouro selic') || lower.contains('cdb') || lower.contains('lci') || lower.contains('lca') ||
        lower.contains('fii') || lower.contains('cripto') || lower.contains('bitcoin') || lower.contains('btc') ||
        lower.contains('ethereum') || lower.contains('eth') || lower.contains('binance') || lower.contains('nuinvest') ||
        lower.contains('xp') || lower.contains('rico') || lower.contains('btg')) {
      return 'investment';
    }

    // 4. SAÚDE, FARMÁCIA & FITNESS
    if (lower.contains('farmacia') || lower.contains('farmácia') || lower.contains('droga raia') || lower.contains('drogasil') ||
        lower.contains('pague menos') || lower.contains('panvel') || lower.contains('pacheco') || lower.contains('extrafarma') ||
        lower.contains('drogaria') || lower.contains('remedio') || lower.contains('remédio') || lower.contains('medicamento') ||
        lower.contains('dipirona') || lower.contains('paracetamol') || lower.contains('ibuprofeno') || lower.contains('dorflex') ||
        lower.contains('neosaldina') || lower.contains('benegrip') || lower.contains('buscopan') || lower.contains('antialérgico') ||
        lower.contains('antialergico') || lower.contains('smart fit') || lower.contains('smartfit') || lower.contains('bluefit') ||
        lower.contains('bio ritmo') || lower.contains('selfit') || lower.contains('academia') || lower.contains('musculação') ||
        lower.contains('musculacao') || lower.contains('crossfit') || lower.contains('pilates') || lower.contains('whey') ||
        lower.contains('creatina') || lower.contains('growth') || lower.contains('max titanium') || lower.contains('integralmedica') ||
        lower.contains('medico') || lower.contains('médico') || lower.contains('consulta médica') || lower.contains('psicologo') ||
        lower.contains('psicólogo') || lower.contains('terapia') || lower.contains('dentista') || lower.contains('ortodontista') ||
        lower.contains('exame') || lower.contains('laboratório') || lower.contains('fleury') || lower.contains('delboni') ||
        lower.contains('ótica') || lower.contains('otica') || lower.contains('lentes de contato') || lower.contains('plano de saúde') ||
        lower.contains('unimed') || lower.contains('amil') || lower.contains('bradesco saúde') || lower.contains('sulamerica') ||
        lower.contains('notredame') || lower.contains('hapvida') ||
        lower.contains('gympass') || lower.contains('wellhub') || lower.contains('totalpass')) {
      return 'health';
    }

    // 5. TRANSPORTE, COMBUSTÍVEL & VEÍCULOS
    if (lower.contains('gasolina') || lower.contains('etanol') || lower.contains('combustível') || lower.contains('combustivel') ||
        lower.contains('diesel') || lower.contains('gnv') || lower.contains('aditivada') || lower.contains('posto ') ||
        lower.contains('posto shell') || lower.contains('posto ipiranga') || lower.contains('posto petrobras') || lower.contains('posto br') ||
        lower.contains('posto ale') || lower.contains('shell') || lower.contains('ipiranga') || lower.contains('petrobras') ||
        lower.contains('graal') || lower.contains('abastecer') || lower.contains('abasteci') || lower.contains('uber') ||
        RegExp(r'\b(?:na|no|pela|pelo|app)\s+99\b|\b99\s*(?:pop|taxis|taxi|moto)\b').hasMatch(lower) || lower.contains('taxi') ||
        lower.contains('táxi') || lower.contains('corrida') || lower.contains('indrive') || lower.contains('cabify') ||
        lower.contains('onibus') || lower.contains('ônibus') || lower.contains('busão') || lower.contains('metro') ||
        lower.contains('metrô') || lower.contains('trem') || lower.contains('bilhete único') || lower.contains('bilhete unico') ||
        lower.contains('cartão top') || lower.contains('pedagio') || lower.contains('pedágio') || lower.contains('sem parar') ||
        lower.contains('conectcar') || lower.contains('veloe') || lower.contains('latam') || RegExp(r'\b(?:linha|linhas|cia|aérea|aerea)?\s*gol\b').hasMatch(lower) ||
        lower.contains('azul') || lower.contains('passagem aérea') || lower.contains('moto') || lower.contains('motocicleta') ||
        lower.contains('carro') || lower.contains('veiculo') || lower.contains('veículo') || lower.contains('ipva') ||
        lower.contains('multa') || lower.contains('detran') || lower.contains('licenciamento') || lower.contains('pneu') ||
        lower.contains('oficina') || lower.contains('mecanico') || lower.contains('mecânico') || lower.contains('estacionamento') ||
        lower.contains('estapar') || lower.contains('zona azul') || lower.contains('localiza') || lower.contains('movida') ||
        lower.contains('unidas') || lower.contains('troca de óleo') || lower.contains('alinhamento') || lower.contains('balanceamento')) {
      return 'transport';
    }

    // 6. ALIMENTAÇÃO, LAZER, FAST FOOD, INSTRUMENTOS & STREAMING
    if (RegExp(r'\b(mc|bk)\b').hasMatch(lower) || lower.contains('mcdonald') || lower.contains('mequi') || lower.contains('méqui') ||
        lower.contains('burger king') || lower.contains('subway') || lower.contains('bobs') || lower.contains('giraffas') ||
        lower.contains('habibs') || lower.contains('ragazzo') || lower.contains('spoleto') || lower.contains('outback') ||
        lower.contains('madero') || lower.contains('jeronimo') || lower.contains('popeyes') || lower.contains('kfc') ||
        lower.contains('pizza hut') || lower.contains('dominos') || lower.contains('taco bell') || lower.contains('coco bambu') ||
        lower.contains('bacio di latte') || lower.contains('cacau show') || lower.contains('kopenhagen') || lower.contains('dengo') ||
        lower.contains('brasil cacau') || lower.contains('starbucks') || lower.contains('the coffee') || lower.contains('we coffee') ||
        lower.contains('rei do mate') || lower.contains('ifood') || lower.contains('zé delivery') || lower.contains('ze delivery') ||
        lower.contains('rappi') || lower.contains('aiqfome') || lower.contains('pastel') || lower.contains('lanche') ||
        lower.contains('pizza') || lower.contains('hamburguer') || lower.contains('hambúrguer') || lower.contains('burger') ||
        lower.contains('esfirra') || lower.contains('esfiha') || lower.contains('kibe') || lower.contains('coxinha') ||
        lower.contains('pão de queijo') || lower.contains('tapioca') || lower.contains('açaí') || lower.contains('acai') ||
        lower.contains('sushi') || lower.contains('sashimi') || lower.contains('temaki') || lower.contains('yakisoba') ||
        lower.contains('poke') || lower.contains('churrasco') || lower.contains('picanha') || lower.contains('parmegiana') ||
        lower.contains('feijoada') || lower.contains('marmita') || lower.contains('marmitex') || lower.contains('almoço') ||
        lower.contains('almoco') || lower.contains('jantar') || lower.contains('cafezinho') || lower.contains('cappuccino') ||
        lower.contains('cerveja') || lower.contains('chope') || lower.contains('chopp') || lower.contains('drink') ||
        lower.contains('caipirinha') || lower.contains('gin') || lower.contains('vodka') || lower.contains('whisky') ||
        lower.contains('refrigerante') || lower.contains('refri') || lower.contains('milkshake') || lower.contains('sorvete') ||
        lower.contains('brigadeiro') || lower.contains('trufa') || lower.contains('chocolate') || lower.contains('restaurante') ||
        lower.contains('bar ') || lower.contains('barzinho') || lower.contains('boteco') || lower.contains('pub') ||
        lower.contains('pizzaria') || lower.contains('hamburgueria') || lower.contains('churrascaria') || lower.contains('cafeteria') ||
        lower.contains('cinema') || lower.contains('cinemark') || lower.contains('cinepolis') || lower.contains('cinépolis') ||
        lower.contains('uci') || lower.contains('teatro') || lower.contains('show') || lower.contains('ingresso') ||
        lower.contains('sympla') || lower.contains('eventim') || lower.contains('parque') || lower.contains('hopi hari') ||
        lower.contains('beto carrero') || lower.contains('museu') || lower.contains('balada') || lower.contains('netflix') ||
        lower.contains('spotify') || lower.contains('amazon prime') || lower.contains('prime video') || lower.contains('disney') ||
        lower.contains('hbo') || lower.contains('max') || lower.contains('globoplay') || lower.contains('apple tv') ||
        lower.contains('deezer') || lower.contains('youtube premium') || lower.contains('crunchyroll') || lower.contains('twitch') ||
        lower.contains('paramount') || lower.contains('star+') || lower.contains('star plus') || lower.contains('audible') || lower.contains('kindle unlimited') ||
        lower.contains('steam') || lower.contains('playstation') || lower.contains('psn') || lower.contains('ps plus') || lower.contains('xbox') ||
        lower.contains('game pass') || lower.contains('gamepass') || lower.contains('nintendo') || lower.contains('epic games') || lower.contains('roblox') ||
        lower.contains('videogame') || lower.contains('console') ||
        lower.contains('violão') || lower.contains('violao') || lower.contains('guitarra') || lower.contains('baixo') ||
        lower.contains('cavaquinho') || lower.contains('ukulele') || lower.contains('bateria') || lower.contains('teclado musical') ||
        lower.contains('piano') || lower.contains('flauta') || lower.contains('saxofone') || lower.contains('trompete') ||
        lower.contains('sanfona') || lower.contains('acordeon') || lower.contains('gaita') || lower.contains('violino') ||
        lower.contains('instrumento musical') || lower.contains('amplificador') || lower.contains('pedal de guitarra') || lower.contains('microfone')) {
      return 'leisure';
    }

    // 7. SUPERMERCADO, HORTIFRUTI & COMPRAS DO MÊS
    if (lower.contains('mercado') || lower.contains('supermercado') || lower.contains('feira') || lower.contains('hortifruti') ||
        lower.contains('sacolão') || lower.contains('sacolao') || lower.contains('açougue') || lower.contains('acougue') ||
        lower.contains('peixaria') || lower.contains('mercearia') || lower.contains('carrefour') || lower.contains('pão de açúcar') ||
        lower.contains('pao de acucar') || lower.contains('extra') || lower.contains('assai') || lower.contains('assaí') ||
        lower.contains('atacadao') || lower.contains('atacadão') || lower.contains('sams club') || lower.contains('sam\'s club') ||
        lower.contains('big') || lower.contains('dia') || lower.contains('hirota') || lower.contains('mambo') ||
        lower.contains('st marche') || lower.contains('sonda') || lower.contains('zaffari') || lower.contains('oxxo') ||
        lower.contains('arroz') || lower.contains('feijao') || lower.contains('feijão') || lower.contains('óleo de cozinha') ||
        lower.contains('azeite') || lower.contains('leite') || lower.contains('ovos') || lower.contains('manteiga') ||
        lower.contains('detergente') || lower.contains('sabão em pó') || lower.contains('amaciante') || lower.contains('papel higiênico') ||
        lower.contains('frango congelado') || lower.contains('carne moída') || lower.contains('peito de frango')) {
      return 'supermarket';
    }

    // 8. MORADIA, CONTAS DE CASA & TELECOM
    if (lower.contains('enel') || lower.contains('cpfl') || lower.contains('light') || lower.contains('cemig') ||
        lower.contains('copel') || lower.contains('sabesp') || lower.contains('copasa') || lower.contains('sanepar') ||
        lower.contains('comgás') || lower.contains('comgas') || lower.contains('vivo') || lower.contains('claro') ||
        RegExp(r'\b(tim|oi)\b').hasMatch(lower) ||
        lower.contains('plano de celular') || lower.contains('plano celular') || lower.contains('plano móvel') || lower.contains('plano movel') ||
        lower.contains('plano de internet') || lower.contains('recarga de celular') || lower.contains('recarga celular') ||
        lower.contains('claro flex') || lower.contains('vivo easy') || lower.contains('tim beta') || lower.contains('tim controle') ||
        lower.contains('claro controle') || lower.contains('vivo controle') ||
        lower.contains('luz') || lower.contains('energia') ||
        lower.contains('água') || lower.contains('agua') || RegExp(r'\b(gás|gas)\b').hasMatch(lower) ||
        lower.contains('botijão') || lower.contains('internet') || lower.contains('wifi') || lower.contains('aluguel') ||
        lower.contains('condominio') || lower.contains('condomínio') || lower.contains('iptu') || lower.contains('quintoandar') ||
        lower.contains('loft') || lower.contains('diarista') || lower.contains('faxina') || lower.contains('sofa') ||
        lower.contains('sofá') || lower.contains('cama') || lower.contains('colchão') || lower.contains('colchao') ||
        lower.contains('geladeira') || lower.contains('fogao') || lower.contains('fogão') || lower.contains('microondas') ||
        lower.contains('micro-ondas') || lower.contains('airfryer') || lower.contains('liquidificador') || lower.contains('máquina de lavar') ||
        lower.contains('maquina de lavar') || lower.contains('ar condicionado') || lower.contains('leroy merlin') || lower.contains('telhanorte') ||
        lower.contains('tok&stok') || lower.contains('tok stok') || lower.contains('camicado') || lower.contains('ortobom') ||
        lower.contains('colchão emma') || lower.contains('emma colchões')) {
      return 'housing';
    }

    // 9. COMPRAS, VESTUÁRIO, MARKETPLACES, ELETRÔNICOS & PET
    if (lower.contains('amazon') || lower.contains('mercado livre') || lower.contains('mercadolivre') || lower.contains('shopee') ||
        lower.contains('shein') || lower.contains('aliexpress') || lower.contains('magalu') || lower.contains('magazine luiza') ||
        lower.contains('casas bahia') || lower.contains('ponto frio') || lower.contains('fast shop') || lower.contains('kabum') ||
        lower.contains('pichau') || lower.contains('terabyte') || lower.contains('americanas') || lower.contains('zara') ||
        lower.contains('renner') || lower.contains('c&a') || lower.contains('riachuelo') || lower.contains('h&m') ||
        lower.contains('marisa') || lower.contains('hering') || lower.contains('reserva') || lower.contains('lacoste') ||
        lower.contains('calvin klein') || lower.contains('farm') || lower.contains('nike') || lower.contains('adidas') ||
        lower.contains('puma') || lower.contains('asics') || lower.contains('mizuno') || lower.contains('vans') ||
        lower.contains('all star') || lower.contains('converse') || lower.contains('olympikus') || lower.contains('havaianas') ||
        lower.contains('arezzo') || lower.contains('schutz') || lower.contains('melissa') || lower.contains('centauro') ||
        lower.contains('decathlon') || lower.contains('netshoes') || lower.contains('vivara') || lower.contains('pandora') ||
        lower.contains('swarovski') || lower.contains('sephora') || lower.contains('boticario') || lower.contains('boticário') ||
        (lower.contains('natura') && !lower.contains('assinatura')) || lower.contains('avon') || lower.contains('apple') || lower.contains('iphone') ||
        lower.contains('ipad') || lower.contains('macbook') || lower.contains('samsung') || lower.contains('xiaomi') ||
        lower.contains('dell') || lower.contains('notebook') || lower.contains('computador') || lower.contains('celular') ||
        lower.contains('smartphone') || lower.contains('fone') || lower.contains('headset') || lower.contains('teclado') ||
        lower.contains('mouse') || lower.contains('monitor') || lower.contains('smartwatch') || lower.contains('kindle') ||
        lower.contains('cobasi') || lower.contains('petz') || lower.contains('zee dog') || lower.contains('pet shop') ||
        lower.contains('ração') || lower.contains('racao') || lower.contains('areia de gato') || lower.contains('antipulgas') ||
        lower.contains('veterinário') || lower.contains('veterinario') || lower.contains('banho e tosa') || lower.contains('roupa') ||
        lower.contains('roupas') || lower.contains('camisa') || lower.contains('camiseta') || lower.contains('calça') ||
        lower.contains('calca') || lower.contains('vestido') || lower.contains('casaco') || lower.contains('tênis') ||
        lower.contains('tenis') || lower.contains('sapato') || lower.contains('perfume') || lower.contains('maquiagem')) {
      return 'expense_other';
    }

    if (modelPredicted != 'unknown') {
      return modelPredicted;
    }
    return 'unknown';
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
        lower.contains('udemy') || lower.contains('alura') || lower.contains('estácio') || lower.contains('estacio') ||
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

    // ── 1. CENÁRIOS DE GASTOS (EXPENSE) ──
    if (intent == 'expense') {
      // ── MENSALIDADES E ASSINATURAS RECORRENTES ──
      final isSubscriptionFormulation = isRecurrent && (missingSlots.contains('due_day') || missingSlots.contains('recurrence_duration'));
      if (isSubscriptionFormulation) {
        final prep = _withPreposition(subjectLabel);

        // A. Falta Valor e Pagamento (ex: "hoje eu assinei o claude code")
        if (!hasAmount && !hasPayment) {
          return 'Anotado a assinatura $prep! Qual o valor e como você pagou? Além disso, que dia ela renova e a assinatura tem tempo para terminar (ex: anual ou indeterminado)?';
        }

        // B. Falta apenas Pagamento (já tem valor, ex: "assinei o claude de 110 no cartao")
        if (hasAmount && !hasPayment) {
          if (isCardAmbiguous) {
            return 'Anotado $amountStr $prep! Você passou no cartão de crédito ou de débito? E que dia ela renova e a assinatura tem tempo para terminar?';
          }
          return 'Anotado $amountStr na assinatura $prep! Qual foi a forma de pagamento, que dia ela renova e a assinatura tem tempo para terminar (ex: anual ou indeterminado)?';
        }

        // C. Falta apenas Valor (já tem pagamento, ex: "assinei o claude no pix")
        if (!hasAmount && hasPayment) {
          return 'Anotado a assinatura $prep no $paymentLabel! Qual o valor mensal, que dia ela renova e a assinatura tem tempo para terminar?';
        }

        // D. Já tem Valor e Pagamento (ex: "assinei o claude de 100 no pix")
        if (missingSlots.contains('due_day') && missingSlots.contains('recurrence_duration')) {
          return 'Anotado $amountStr na assinatura $prep! Que dia ela renova todo mês e a assinatura tem tempo para terminar (ex: anual ou tempo indeterminado)?';
        } else if (missingSlots.contains('due_day')) {
          return 'Perfeito! Em que dia do mês a assinatura $prep renova todo mês?';
        } else if (missingSlots.contains('recurrence_duration')) {
          return 'Anotado que renova todo dia $dueDay! A assinatura $prep tem tempo para terminar ou é por tempo indeterminado?';
        }
      }

      // Falta APENAS Parcelamento no Cartão de Crédito
      if (missingSlots.length == 1 && missingSlots.contains('installments')) {
        final prep = _withPreposition(subjectLabel);
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
    return nouns.any((k) => lower.contains(k));
  }

  bool _hasPaymentKeyword(String text) {
    final lower = text.toLowerCase();
    final hasBoletoAsMethod = lower.contains('no boleto') || lower.contains('via boleto') ||
        lower.contains('em boleto') || lower.contains('pelo boleto') || lower.contains('parcelado no boleto');
    final hasInstallmentsAsMethod = lower.contains('parcel') || RegExp(r'\b\d{1,2}\s*x\b').hasMatch(lower);
    final keywords = [
      'pix', 'pics', 'piquis', 'pyks', 'piks', 'px',
      'credito', 'crédito', 'crebito',
      'debito', 'débito', 'debto', 'debitto', 'debiro',
      'dinheiro', 'dinhero', 'dinheru', 'dindin', 'especie', 'espécie'
    ];
    return keywords.any((k) => lower.contains(k)) || hasBoletoAsMethod || hasInstallmentsAsMethod;
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

  int? _parseInstallments(String text) {
    final lower = text.toLowerCase().trim();

    // 1. Single payment / À vista mentions
    final singleTerms = [
      'à vista', 'a vista', 'sem parcelar', 'não foi parcelado', 'nao foi parcelado',
      'não parcelei', 'nao parcelei', 'não parcelado', 'nao parcelado', 'única parcela',
      'unica parcela', 'parcela única', 'parcela unica', 'em 1x', '1x', '1 vez', 'uma vez',
      'nao parcelar', 'não parcelar', 'não parcele', 'nao parcele'
    ];
    for (final term in singleTerms) {
      if (lower.contains(term)) {
        return 1;
      }
    }
    if (lower == 'não' || lower == 'nao' || lower == '1' || lower == 'nenhuma' || lower == 'nenhum') {
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
      r'(?:parcelei\s+em|parceley\s+em|parcelado\s+em|parcelada\s+em|dividido\s+em|dividi\s+em|em)\s+(\d{1,2})\s*(?:vezes|vezez|veze|parcelas|x|mensalidades)?\b'
      r'|'
      r'\bde\s+(\d{1,2})\s*(?:vezes|vezez|veze|parcelas|mensalidades|x)\b'
      r'|'
      r'\b(\d{1,2})\s*(?:vezes|vezez|veze|parcelas|mensalidades)\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (phrasingMatch != null) {
      final str = phrasingMatch.group(1) ?? phrasingMatch.group(2) ?? phrasingMatch.group(3);
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
    if (RegExp(r'^\d{1,2}$').hasMatch(lower)) {
      final count = int.tryParse(lower);
      if (count != null && count >= 1 && count <= 99) {
        return count;
      }
    }

    return null;
  }

  String _resolvePaymentMethod(String text, String modelPrediction) {
    final lower = text.toLowerCase();
    if (lower.contains('pix') || lower.contains('pics') || lower.contains('piquis') || lower.contains('pyks')) {
      return 'pix';
    }
    if (lower.contains('crédito') || lower.contains('credito') || lower.contains('crdito') || lower.contains('kredito') || lower.contains('crebito') ||
        lower.contains('parcelado') || lower.contains('parcelada') || lower.contains('parcelei') || lower.contains('parceley') ||
        lower.contains('parcelamento') || lower.contains('parcelas') || RegExp(r'\b\d{1,2}\s*x\b').hasMatch(lower)) {
      if (!lower.contains('no boleto') && !lower.contains('via boleto') && !lower.contains('em boleto') && !lower.contains('pelo boleto')) {
        return 'credit_card';
      }
    }
    if (lower.contains('débito') || lower.contains('debito') || lower.contains('debto') || lower.contains('debitto')) {
      return 'debit_card';
    }
    if (lower.contains('dinheiro') || lower.contains('dinhero') || lower.contains('dinheru') || lower.contains('dindin') || lower.contains('espécie') || lower.contains('especie') || lower.contains('notas')) {
      return 'cash';
    }
    // "boleto" is only a payment method if phrased as a method (e.g., "no boleto", "via boleto")
    // When phrased as "paguei o boleto", "paguei um boleto de 700", it is the bill/item being paid!
    if (lower.contains('no boleto') || lower.contains('via boleto') || lower.contains('em boleto') || lower.contains('pelo boleto') || lower.contains('parcelado no boleto')) {
      return 'bank_slip';
    }
    // Generic "cartão" without credit or debit specified is AMBIGUOUS and must be clarified
    if (lower.contains('cartão') || lower.contains('cartao') || lower.contains('cartaozinho') || lower.contains('cratao') || lower.contains('cattao')) {
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
  };

  String _normalizeText(String text) {
    // 1. Reduce 3+ repeated letters (e.g. gasteeeeii -> gastei), preserving numbers (1000, 3000)
    var clean = text.toLowerCase().replaceAllMapped(
      RegExp(r'([a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ])\1{2,}'),
      (match) => match.group(1)!,
    );
    
    // 2. Token-level typo normalization
    final tokens = clean.split(RegExp(r'\s+'));
    final normalizedTokens = tokens.map((t) => _commonTypoCorrections[t] ?? t);
    return normalizedTokens.join(' ');
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
      if (lower.contains(entry.key)) {
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

    // 1. High-priority explicit currency patterns (R$ 50, 50 reais, 50 conto)
    final explicitCurrencyPatterns = [
      RegExp(r'r\$\s*(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)', caseSensitive: false),
      RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s*(?:reais|real|rea|conto|contos|pila|pilas)\b', caseSensitive: false),
      RegExp(r'(?:por|de|custou|valor de|gastei|paguei|saiu|deu|comprei|transferi|enviei|mandei|recebi|abasteci|passei)\s+(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)\b', caseSensitive: false),
    ];

    for (final pat in explicitCurrencyPatterns) {
      final match = pat.firstMatch(lower);
      if (match != null) {
        final val = cleanAndParseAmount(match.group(1));
        if (val != null && val > 0 && val < 1000000000) {
          return val;
        }
      }
    }

    // Require explicit financial verbs, brand names, currency terms, or monetary context to extract raw numbers
    final financialVerbs = [
      'gastei', 'gaste', 'gastar', 'gasto', 'gastos', 'paguei', 'paga', 'pagar', 'pagamento',
      'comprei', 'compra', 'comprar', 'compras', 'caiu', 'recebi', 'receber', 'receita',
      'mandei', 'mandou', 'manda', 'transferi', 'transferiu', 'transferir', 'enviou', 'enviei',
      'abasteci', 'abasteceu', 'abastecer', 'passei', 'passou', 'passar', 'saiu', 'deu', 'debitou',
      'desembolsei', 'soltei', 'torrei', 'deixei', 'fechei', 'entrou', 'custou', 'ficou',
      'reais', 'real', 'rea', 'conto', 'contos', 'pila', 'pilas', 'r\$', 'fatura', 'troco', 'fiado',
      'pix', 'pics', 'pyks', 'debito', 'débito', 'credito', 'crédito', 'dinheiro', 'dinhero', 'dinheru', 'dindin', 'boleto', 'cartao', 'cartão',
      'vintao', 'vintão', 'dezao', 'dezão', 'cinquentao', 'cinquentão', 'cemzao', 'cemzão',
      'duzentao', 'duzentão', 'quinhentao', 'quinhentão', 'barao', 'barão', 'pau', 'paus',
      'uber', '99', 'ifood', 'rappi', 'ze delivery', 'mcdonalds', 'shell', 'ipiranga',
      'carrefour', 'extra', 'drogasil', 'raia', 'mercado', 'posto', 'farmacia', 'aluguel',
      'pastel', 'pizza', 'lanche', 'padaria', 'compras'
    ];
    if (!financialVerbs.any((v) => lower.contains(v))) {
      return null;
    }

    // Remove unit measurements from search text so they don't get captured by raw number fallback (e.g. 5kg, 500g, 2l)
    final textWithoutUnits = lower.replaceAll(RegExp(r'\b\d+(?:[.,]\d+)?\s*(?:kg|g|mg|l|ml|m|cm|mm|w|watts|hz|btu|ah|amperes|unidades|pecas|peças)\b', caseSensitive: false), ' ');

    final regExp = RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)', caseSensitive: false);
    final match = regExp.firstMatch(textWithoutUnits);
    if (match != null) {
      final val = cleanAndParseAmount(match.group(1));
      if (val != null && val > 0 && val < 1000000000) {
        return val;
      }
    }
    return null;
  }

  int _parseDateOffset(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('hoje') || lower.contains('hoji') || lower.contains('hoj') || lower.contains('oje') || lower.contains('essa manhã') || lower.contains('nesta tarde')) {
      return 0;
    } else if (lower.contains('ontem') || lower.contains('onterm') || lower.contains('onté') || lower.contains('otem')) {
      return -1;
    } else if (lower.contains('anteontem') || lower.contains('antiotem') || lower.contains('anti-ontem') || lower.contains('ante-ontem')) {
      return -2;
    } else if (lower.contains('semana passada')) {
      return -7;
    } else if (lower.contains('fim de semana')) {
      return -3;
    }
    return 0;
  }

  String _extractDescription(String text, String category) {
    final lower = text.toLowerCase();

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
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }

    if (category != 'unknown' && category != 'expense_other') {
      return _getFriendlyCategoryName(category);
    }
    return text;
  }
}
