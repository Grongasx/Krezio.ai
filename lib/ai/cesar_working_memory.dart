import 'cesar_text.dart';

/// Topic of the active conversational frame.
enum WorkingMemoryTopic {
  none,
  expense,
  debt,
  goal,
  report,
  split,
}

/// A structured memory frame storing discourse entities across conversational turns.
/// Managed with strict TTL (turn decay) to avoid context bleeding.
class WorkingMemoryFrame {
  final String? personName;
  final String? category;
  final String? transactionId;
  final double? transactionAmount;
  final String? transactionTitle;
  final String? goalTitle;
  final WorkingMemoryTopic topic;
  final int turn;
  final int ttl;

  const WorkingMemoryFrame({
    this.personName,
    this.category,
    this.transactionId,
    this.transactionAmount,
    this.transactionTitle,
    this.goalTitle,
    this.topic = WorkingMemoryTopic.none,
    required this.turn,
    this.ttl = 3,
  });

  WorkingMemoryFrame copyWith({
    String? personName,
    String? category,
    String? transactionId,
    double? transactionAmount,
    String? transactionTitle,
    String? goalTitle,
    WorkingMemoryTopic? topic,
    int? turn,
    int? ttl,
  }) {
    return WorkingMemoryFrame(
      personName: personName ?? this.personName,
      category: category ?? this.category,
      transactionId: transactionId ?? this.transactionId,
      transactionAmount: transactionAmount ?? this.transactionAmount,
      transactionTitle: transactionTitle ?? this.transactionTitle,
      goalTitle: goalTitle ?? this.goalTitle,
      topic: topic ?? this.topic,
      turn: turn ?? this.turn,
      ttl: ttl ?? this.ttl,
    );
  }
}

/// Represents an archived historical turn in working memory.
class WorkingMemoryTurnRecord {
  final int turn;
  final String input;
  final WorkingMemoryTopic topic;
  final String? entity;

  const WorkingMemoryTurnRecord({
    required this.turn,
    required this.input,
    required this.topic,
    this.entity,
  });
}

/// On-Device Conversational Working Memory for César.
///
/// Implements:
/// 1. Dual-Pass Anaphora & Reference Resolution
/// 2. Structured State Frame (bounded O(1) memory footprint)
/// 3. Context Gating & TTL Decay (prevents catastrophic context bleeding)
/// 4. Hard Disruption Reset (cancela, esquece, mudei de ideia)
class CesarWorkingMemory {
  int _currentTurn = 0;
  WorkingMemoryFrame? _frame;
  final List<WorkingMemoryTurnRecord> _history = [];
  static const int maxHistoryLength = 5;

  int get currentTurn => _currentTurn;
  WorkingMemoryFrame? get activeFrame => _frame;
  String? get lastPersonName => _frame?.personName;
  String? get lastCategory => _frame?.category;
  String? get lastGoalTitle => _frame?.goalTitle;
  String? get lastTransactionId => _frame?.transactionId;
  double? get lastTransactionAmount => _frame?.transactionAmount;
  String? get lastTransactionTitle => _frame?.transactionTitle;
  WorkingMemoryTopic get activeTopic => _frame?.topic ?? WorkingMemoryTopic.none;
  List<WorkingMemoryTurnRecord> get history => List.unmodifiable(_history);

  /// Called at the beginning of each assistant turn.
  void beginTurn() {
    _currentTurn++;
    if (_frame != null) {
      final newTtl = _frame!.ttl - 1;
      if (newTtl <= 0) {
        _frame = null; // Evict expired frame
      } else {
        _frame = _frame!.copyWith(ttl: newTtl);
      }
    }
  }

  /// Hard reset gate: returns true if the input signals an intent disruption
  /// or cancellation, requiring the working memory to be purged.
  bool checkAndApplyDisruption(String input) {
    final s = CesarText.simplify(input);
    final isDisruption = RegExp(
      r'^(?:cancela|cancelar|esquece|esqueça|desconsidera|desiste|desisti|deixa\s+pra\s+l[aá]|'
      r'deixa\s+quieto|mudei\s+de\s+ideia|outra\s+coisa|limpar\s+hist[oó]rico|nova\s+conversa)\b',
    ).hasMatch(s);

    if (isDisruption) {
      clear();
      return true;
    }
    return false;
  }

  /// Registers or updates the active working memory frame with fresh entities.
  void updateFrame({
    String? personName,
    String? category,
    String? transactionId,
    double? transactionAmount,
    String? transactionTitle,
    String? goalTitle,
    WorkingMemoryTopic? topic,
    int ttl = 3,
  }) {
    _frame = WorkingMemoryFrame(
      personName: personName ?? _frame?.personName,
      category: category ?? _frame?.category,
      transactionId: transactionId ?? _frame?.transactionId,
      transactionAmount: transactionAmount ?? _frame?.transactionAmount,
      transactionTitle: transactionTitle ?? _frame?.transactionTitle,
      goalTitle: goalTitle ?? _frame?.goalTitle,
      topic: topic ?? _frame?.topic ?? WorkingMemoryTopic.none,
      turn: _currentTurn,
      ttl: ttl,
    );
  }

  /// Records the completed turn in the ring buffer history.
  void recordTurn(String input, {WorkingMemoryTopic? topic, String? entity}) {
    final record = WorkingMemoryTurnRecord(
      turn: _currentTurn,
      input: input,
      topic: topic ?? activeTopic,
      entity: entity ?? _frame?.personName ?? _frame?.goalTitle ?? _frame?.category,
    );
    _history.add(record);
    if (_history.length > maxHistoryLength) {
      _history.removeAt(0);
    }
  }

  /// Clears active memory frame and history.
  void clear() {
    _frame = null;
    _history.clear();
  }

  /// Second Pass: Resolves anaphoras and elliptical references in [input]
  /// using the active structured frame. Returns the enriched/rewritten input,
  /// or null if no anaphoric substitution was performed.
  String? resolveAnaphora(String input) {
    if (_frame == null) return null;
    final s = CesarText.simplify(input);

    // 1. Person anaphora: "ele me pagou 50", "ele quitou", "quanto ele ainda deve?", "ela me pagou"
    final person = _frame!.personName;
    if (person != null && person.isNotEmpty) {
      // Matches "ele/ela me pagou...", "ele pagou...", "ele quitou...", "recebi dele/dela..."
      final personRef = RegExp(r'\b(?:ele|ela)\s+(?:j[aá]\s+)?(?:me\s+)?(?:pagou|devolveu|quitou|acertou)\b');
      if (personRef.hasMatch(s)) {
        return input.replaceFirst(RegExp(r'\b(?:ele|ela)\b', caseSensitive: false), 'o $person');
      }

      final quantoEleDeve = RegExp(r'\b(?:quanto|qual\s+valor)\s+(?:que\s+)?(?:ele|ela)\s+(?:ainda\s+)?(?:me\s+)?(?:deve|falta|tem\s+que\s+pagar)\b');
      if (quantoEleDeve.hasMatch(s)) {
        return input.replaceFirst(RegExp(r'\b(?:ele|ela)\b', caseSensitive: false), 'o $person');
      }

      final eleQuitou = RegExp(r'\b(?:ele|ela)\s+(?:j[aá]\s+)?(?:quitou|pagou\s+tudo|acertou\s+tudo)\b');
      if (eleQuitou.hasMatch(s)) {
        return input.replaceFirst(RegExp(r'\b(?:ele|ela)\b', caseSensitive: false), 'o $person');
      }
    }

    // 2. Goal anaphora: "guardei mais 200 nela", "guardei 100 na meta", "quanto falta nela?"
    final goal = _frame!.goalTitle;
    if (goal != null && goal.isNotEmpty) {
      final goalRef = RegExp(r'\b(?:guardei|juntei|coloquei|depositei|adicionei)\s+(?:mais\s+)?(?:r\$\s*)?(\d+(?:[.,]\d+)?)\s*(?:reais)?\s+(?:nela|nessa\s+meta|na\s+meta)\b');
      final mGoal = goalRef.firstMatch(s);
      if (mGoal != null) {
        final amount = mGoal.group(1)!;
        return 'guardei $amount na meta $goal';
      }

      final howMuchGoal = RegExp(r'\b(?:quanto|quanto\s+dinheiro)\s+(?:ainda\s+)?(?:falta|tenho|tem)\s+(?:nela|nessa\s+meta|na\s+meta)\b');
      if (howMuchGoal.hasMatch(s)) {
        return 'quanto falta para a meta $goal';
      }
    }

    // 3. Category/Cut anaphora: "e se eu cortar isso?", "cortar isso pela metade"
    final cat = _frame!.category;
    if (cat != null && cat.isNotEmpty) {
      final cutThis = RegExp(r'\b(?:se\s+eu\s+)?(?:cortar|reduzir|diminuir)\s+(?:isso|esse\s+gasto|essa\s+categoria|esses\s+gastos)\b');
      if (cutThis.hasMatch(s)) {
        return input.replaceFirst(RegExp(r'\b(?:isso|esse\s+gasto|essa\s+categoria|esses\s+gastos)\b', caseSensitive: false), cat);
      }
    }

    // 4. Follow-up Bill Split: "divide em 3", "divide com o Pedro e a Ana" without amount
    final txAmount = _frame!.transactionAmount;
    final txTitle = _frame!.transactionTitle;
    if (txAmount != null && txTitle != null && txAmount > 0 && _frame!.topic == WorkingMemoryTopic.expense) {
      final splitFollowUp = RegExp(r'^(?:divide|divida|dividi|dividir|particiona|reparte)\s+(?:isso|esse\s+gasto|a\s+conta)?\s*(?:em\s+(\d+|duas?|tr[eê]s|quatro|cinco)\s*(?:pessoas?|partes?)?)?(?:\s*com\s+(.+))?$');
      if (splitFollowUp.hasMatch(s) && RegExp(r'\b(?:em|com)\b').hasMatch(s) && !RegExp(r'\d+[.,]\d+|\b\d+\s+reais\b').hasMatch(s)) {
        // Synthesize standard split text with inherited amount and title
        return 'o $txTitle deu ${txAmount.toStringAsFixed(2)}, $input';
      }
    }

    return null;
  }
}
