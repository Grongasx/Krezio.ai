import 'category_name_matcher.dart';
import 'entry_certainty.dart';
import 'hypothesis_detector.dart';
import 'local_nlp_engine.dart';
import 'money_direction.dart';
import 'pt_number_words.dart';
import 'temporal_date_parser.dart';

/// Which of the gate's checks stopped an entry.
enum GateCheck {
  /// A hypothesis or an intention ("se eu gastar…", "pretendo comprar…"):
  /// nothing happened yet, so nothing is recorded.
  intent,

  /// The words say the money went one way, the draft records the other.
  direction,

  /// A discount is not money coming in ("ganhei 30 de desconto").
  discount,

  /// A money number nobody accounted for, or two numbers for one value.
  numbers,

  /// A time word that is not the date being recorded.
  date,

  /// Nothing wrong was found, but nothing says for sure it happened
  /// ([EntryCertainty]): the entry is shown and confirmed before saving.
  certainty,
}

/// What [EntrySafetyGate.review] decided: [ok], or the one question to ask
/// (it becomes the pending slot [slot] of the draft).
class GateVerdict {
  final GateCheck? check;
  final String? slot;
  final String? question;

  const GateVerdict.ok()
      : check = null,
        slot = null,
        question = null;

  const GateVerdict.ask(GateCheck this.check, this.slot, String this.question);

  bool get ok => check == null;

  /// [draft] turned into a reply that ends the conversation about it: nothing
  /// is saved (no value, not an entry) and nothing stays pending — the chat
  /// shows [reply] the way it shows an answer to a question.
  static FinancialTransactionDraft closed(FinancialTransactionDraft draft, String reply) => draft.copyWith(
        intent: 'query',
        isComplete: true,
        missingSlots: const [],
        clearAmount: true,
        clarificationPrompt: reply,
        isReminder: false,
        settledChecks: {...draft.settledChecks, 'closed'},
      );

  /// [draft] held back with this question as its pending slot. An intention
  /// is not an entry at all: it leaves as `unknown`, so nobody saves it and
  /// the chat only shows the answer.
  FinancialTransactionDraft applyTo(FinancialTransactionDraft draft, {bool afterAnswer = false}) {
    if (ok) return draft;
    if (check == GateCheck.intent) {
      // An answer that turns out to be about something that didn't happen
      // closes the conversation about it: the draft leaves as a reply only
      // (an `unknown` merged draft would stay pending in the chat).
      if (afterAnswer) return closed(draft, question!);
      return draft.copyWith(intent: 'unknown', isComplete: false, missingSlots: const [], clarificationPrompt: question);
    }
    if (check == GateCheck.certainty) {
      return draft.copyWith(isComplete: false, missingSlots: const ['confirm'], clarificationPrompt: question);
    }
    final slots = [slot!, ...draft.missingSlots.where((s) => s != slot)];
    if (check == GateCheck.discount) {
      // The value said was the discount: what was paid is asked, and the
      // type is settled (it is a purchase) so "entrou ou saiu?" isn't asked.
      return draft.copyWith(
        intent: 'expense',
        category: const {'income_other', 'salary', 'investment'}.contains(draft.category) ? 'unknown' : draft.category,
        clearAmount: true,
        isComplete: false,
        missingSlots: slots,
        clarificationPrompt: question,
        settledChecks: {...draft.settledChecks, 'type'},
      );
    }
    return draft.copyWith(isComplete: false, missingSlots: slots, clarificationPrompt: question);
  }
}

/// The one check every entry passes before it can be saved — whatever path
/// built it (a sentence, an answer merged into a draft, a piece of a batch,
/// a debt payment). César's readers of type, value and date live in many
/// places and each has its own rules; this gate looks at the *result*
/// against *everything the user said* for it, and asks instead of saving
/// when they don't agree (Portão do lote A, etapa 7c). Generic checks:
///
/// 1. **Intent** — a hypothesis or an intention is not a fact
///    ([HypothesisDetector]).
/// 2. **Direction** — who pays whom in the words ([MoneyDirectionDetector])
///    must match income × expense in the draft; a discount is not income.
/// 3. **Numbers** — every number must be explained: the value used, a count
///    × price, installments, a date/time, a measure, an identifier after a
///    noun ("box 12", "placa QWE-4521"), an ordinal, part of a name. A money
///    number left over, or two numbers side by side for one value, is asked.
/// 4. **Date** — a time word that is not where the recorded date came from
///    ("domingão", "dia vinte e cinco", "esses dias") is asked. "hoje" only
///    wins when it is the only time word; words inside a "se/caso" clause or
///    a street/shop name ("rua 25 de março", "Café Amanhã") are not dates.
///
/// Answers to the gate's own questions are kept in
/// [FinancialTransactionDraft.settledChecks], so it never asks twice. Pure
/// Dart; the engine calls it on every draft it hands out
/// ([LocalFinancialNlpEngine.parse], `mergeDrafts`, `parseMulti`), so the chat
/// and the voice controller inherit it without any logic of their own.
class EntrySafetyGate {
  EntrySafetyGate._();

  static const _txIntents = {'expense', 'income', 'transfer'};

  /// The gate's decision on [draft]. [turns] are the texts that built it
  /// (default: its `rawText`, turns joined by " + "). [normalize] is the
  /// engine's own reading of a text (typos fixed: "salrio" → "salário"), so
  /// the gate judges the words the engine understood, not the raw keys.
  static GateVerdict review(FinancialTransactionDraft draft,
      {List<String>? turns, DateTime? now, String Function(String text)? normalize}) {
    if (!_txIntents.contains(draft.intent) || draft.isReportQuery || draft.isCanceled) {
      return const GateVerdict.ok();
    }
    final said = turns ?? draft.rawText.split(' + ');
    if (draft.isReminder) {
      // A loan ("emprestei 64 pro meu primo") is a transfer saved with a
      // reminder: its date is the transfer's, read and checked like any
      // entry's (CHAOS-C-007). Other reminders aren't entries.
      if (draft.reminderType != 'loan_receivable') return const GateVerdict.ok();
      for (final v in [checkIntent(said), checkDate(draft, said, now: now)]) {
        if (!v.ok) return v;
      }
      return const GateVerdict.ok();
    }
    for (final v in [
      checkIntent(said),
      checkDirection(draft, said, normalize: normalize),
      checkNumbers(draft, said),
      checkDate(draft, said, now: now),
      checkCertainty(draft, said),
    ]) {
      if (!v.ok) return v;
    }
    return const GateVerdict.ok();
  }

  static String _fold(String s) => CategoryNameMatcher.foldAccents(s.toLowerCase());

  static String _brl(double v) {
    final fixed = v.toStringAsFixed(2).replaceAll('.', ',');
    return 'R\$ $fixed';
  }

  // ───────────────────────────── 1. intent ─────────────────────────────

  static const notHappenedReply = 'Entendi que isso não chegou a acontecer, então não registrei nada. 👍 '
      'Se aconteceu, me conte de novo (ex.: "gastei 50 no mercado no pix").';

  /// A hypothesis/intention, or something that didn't happen — in the story
  /// (the first turn) or in any answer after it: "paguei o seguro" ⏎ "ah
  /// não, deu erro" is no entry either. Every turn counts, so a plan
  /// completed by its answers ("tenho que pagar 380 de iptu" ⏎ "no boleto")
  /// is still a plan (CHAOS-C-001).
  static GateVerdict checkIntent(List<String> turns) {
    // "não gastei os 66 que tinha separado pro bar", "quase comprei um tênis
    // de 300": it didn't happen — no record and no draft to ask about (7d).
    if (HypothesisDetector.notHappened(turns.first)) return const GateVerdict.ask(GateCheck.intent, null, notHappenedReply);
    for (final t in turns.skip(1)) {
      // (Answers only by the words of a failure: "não, no pix" is no denial.)
      if (HypothesisDetector.mentionsFailure(t) && HypothesisDetector.notHappened(t)) {
        return const GateVerdict.ask(GateCheck.intent, null, notHappenedReply);
      }
    }
    if (HypothesisDetector.detect(turns.first) == null) return const GateVerdict.ok();
    return const GateVerdict.ask(GateCheck.intent, null,
        'Isso soa como um plano ou uma simulação, então não registrei nada. Quando acontecer, é só me contar (ex.: "gastei 50 no mercado no pix").');
  }

  // ───────────────────────────── 2. direction ─────────────────────────────

  /// "ganhei 30 de desconto", "consegui 15% de desconto": the value is what
  /// was *not* paid. (Cashback, refunds and returns are money in.)
  static final _discount = RegExp(
    r'\b(?:ganhei|consegui|tive|peguei|levei|obtive|recebi|deram|me\s+deram|me\s+deu)\s+(?:um\s+|uns\s+)?'
    r'(?:(?:r\$\s*)?\d[\d.,]*\s*(?:reais|real|conto|contos|pila|pilas|%|por\s*cento)?\s+)?(?:de\s+)?(?:desconto|abatimento)\b',
  );
  static final _moneyBack = RegExp(r'\b(?:cashback|estorno|reembolso|devolu[cç]ao|troco)\b');

  static GateVerdict checkDirection(FinancialTransactionDraft draft, List<String> turns,
      {String Function(String text)? normalize}) {
    if (draft.settledChecks.contains('type') || draft.missingSlots.contains('type')) return const GateVerdict.ok();
    // (Typos fixed the way the engine fixed them: "meu salrio cai todo dia
    // 5" is the salary falling, not a bill due on the 5th.)
    final text = turns.map(normalize ?? (t) => t).join(' . ');
    final s = _fold(text);
    if (draft.intent == 'income' && _discount.hasMatch(s) && !_moneyBack.hasMatch(s)) {
      return const GateVerdict.ask(GateCheck.discount, 'amount',
          'Desconto não é dinheiro entrando, então não lancei como receita. Quanto você pagou no fim, já com o desconto?');
    }
    final dir = MoneyDirectionDetector.detect(text);
    // A value moved "with someone" by a verb nobody classified ("mexemos 200
    // com o tio do bar") says no side: the classifier's guess of income is
    // asked, not saved.
    final clash = (draft.intent == 'income' && (dir == MoneyDirection.outgoing || dir == MoneyDirection.unclear)) ||
        (draft.intent != 'income' && dir == MoneyDirection.incoming);
    if (!clash) return const GateVerdict.ok();
    return GateVerdict.ask(GateCheck.direction, 'type', LocalFinancialNlpEngine.typeQuestion(draft.amount));
  }

  // ───────────────────────────── 3. numbers ─────────────────────────────

  static final _number = RegExp(r'(?<![\d.,/])(\d+(?:[.,]\d{1,2})?)(?![\d.,]?\d|\s*/\s*\d)');

  /// A date span ("há 3 dias", "faz seis dias", "3 dias atrás"): its number
  /// is a date, never a count to multiply a value by (CHAOS-B-005).
  static final _spanNumber = RegExp(
      r'\b(?:ha|faz|tem)\s+(?:uns\s+|umas\s+)?(\d+)\s+(?:dias?|semanas?|mes|meses|anos?)\b|\b(\d+)\s+(?:dias?|semanas?|meses|anos?)\s+atras\b');

  /// Values of numbers that are part of a capitalized name in the middle
  /// of the sentence ("Restaurante Sexta-Feira 13", "Loja 25 de Março").
  static List<double> _nameNumbers(String raw) {
    final out = <double>[];
    for (final m in RegExp(r'(?<=\S\s+)[A-ZÀ-Ý][\wÀ-ÿ]*(?:[-\s][A-ZÀ-Ý][\wÀ-ÿ]*)*\s+(\d{1,4})\b').allMatches(raw)) {
      final v = double.tryParse(m.group(1)!);
      if (v != null) out.add(v);
    }
    return out;
  }

  /// Two numbers for one value: "80 90 reais", "uns 30 a 40", "50 ou 60",
  /// "entre 100 e 120" — neither of them a date, a span, a count or a measure.
  static final _pair = RegExp(
      r'(?<![\d.,/])(?:entre\s+)?(?:r\$\s*)?(\d+(?:[.,]\d{1,2})?)\s+(?:a|ou|e)?\s*(?:r\$\s*)?(\d+(?:[.,]\d{1,2})?)(?![\d.,]?\d|\s*/)');

  static List<double>? _twoValuesForOne(String s) {
    for (final m in _pair.allMatches(s)) {
      final joint = s.substring(m.start, m.end);
      // "e" only joins two values in "entre N e M".
      if (RegExp(r'\d\s+e\s+').hasMatch(joint) && !joint.startsWith('entre')) continue;
      final before = s.substring(0, m.start), after = s.substring(m.end);
      final a = m.group(1)!, b = m.group(2)!;
      final midStart = m.start + joint.indexOf(a) + a.length;
      final mid = s.substring(midStart, m.start + joint.lastIndexOf(b));
      if (LocalFinancialNlpEngine.isNonValueNumber(b, s.substring(0, m.end - b.length), after)) continue;
      // The first one is judged without its neighbour (side by side is
      // exactly what is being asked about).
      if (LocalFinancialNlpEngine.isNonValueNumber(a, before, mid.isEmpty ? ' ' : mid.replaceAll(RegExp(r'\d'), ''))) continue;
      if (RegExp(r'\bdias?\s+$|\d\s*/\s*$|\b(?:as|das|pelas)\s+$').hasMatch(before)) continue;
      final x = LocalFinancialNlpEngine.cleanAndParseAmount(a), y = LocalFinancialNlpEngine.cleanAndParseAmount(b);
      if (x == null || y == null || x <= 0 || y <= 0) continue;
      return [x, y];
    }
    return null;
  }

  /// The money values in [text] left unexplained by [used] (the values the
  /// entries took): what a sentence says beyond them. Used for one entry
  /// and for a whole batch.
  static List<double> unexplainedMoney(String text, List<double> used) {
    if (used.isEmpty) return const [];
    final s = _fold(PtNumberWords.normalize(text.toLowerCase()));
    var others = LocalFinancialNlpEngine.otherMoneyValues(s, used.first);
    for (final u in used.skip(1)) {
      final i = others.indexWhere((o) => (o - u).abs() < 0.005);
      if (i >= 0) others = [...others]..removeAt(i);
    }
    for (final n in _nameNumbers(text)) {
      final i = others.indexWhere((o) => (o - n).abs() < 0.005);
      if (i >= 0) others = [...others]..removeAt(i);
    }
    // A discount said next to the price paid ("ganhei 40 de desconto e paguei
    // 260") is explained: it is what was not paid (ACC-C-014).
    for (final m in RegExp(r'(\d+(?:[.,]\d{1,2})?)\s*(?:reais|real|conto|contos)?\s*(?:de\s+)?(?:desconto|abatimento)\b').allMatches(s)) {
      final v = LocalFinancialNlpEngine.cleanAndParseAmount(m.group(1));
      final i = v == null ? -1 : others.indexWhere((o) => (o - v).abs() < 0.005);
      if (i >= 0) others = [...others]..removeAt(i);
    }
    return others;
  }

  static GateVerdict checkNumbers(FinancialTransactionDraft draft, List<String> turns) {
    final amount = draft.amount;
    if (amount == null || amount <= 0 || draft.repeatDays != null) return const GateVerdict.ok();
    if (draft.settledChecks.contains('split') || draft.missingSlots.any(const {'split', 'type', 'amount'}.contains)) {
      return const GateVerdict.ok();
    }
    // In a conversation, the earlier turns were already checked: only the
    // last one can bring a new number.
    final text = turns.last;
    final s = _fold(PtNumberWords.normalize(text.toLowerCase()));
    final values = [
      for (final m in _number.allMatches(s))
        if (LocalFinancialNlpEngine.cleanAndParseAmount(m.group(1)) case final v? when v > 0) v,
    ];
    final said = values.any((v) => (v - amount).abs() < 0.005);
    if (!said) {
      // A value computed from the sentence (count × price) is explained —
      // unless the count is a date span: "há 3 dias … consulta de 47" is 47.
      final spans = {
        for (final m in _spanNumber.allMatches(s)) double.parse(m.group(1) ?? m.group(2)!),
      };
      for (final a in values) {
        for (final b in values) {
          if ((a * b - amount).abs() < 0.005) {
            if (spans.contains(a) || spans.contains(b)) {
              final plain = spans.contains(a) ? b : a;
              return GateVerdict.ask(GateCheck.numbers, 'split',
                  'Qual foi o valor certo desse lançamento? Não multipliquei pelos dias, porque "${(spans.contains(a) ? a : b).toInt()} dias" '
                  'é quando foi (ex.: "${plain.toStringAsFixed(0)}").');
            }
            return const GateVerdict.ok();
          }
        }
      }
      return const GateVerdict.ok();
    }
    final pair = _twoValuesForOne(s);
    if (pair != null && pair.any((v) => (v - amount).abs() < 0.005)) {
      return GateVerdict.ask(GateCheck.numbers, 'split', LocalFinancialNlpEngine.valueChoiceQuestion(pair));
    }
    final others = unexplainedMoney(text, [amount]);
    if (others.isEmpty) return const GateVerdict.ok();
    return GateVerdict.ask(GateCheck.numbers, 'split', LocalFinancialNlpEngine.splitQuestion([amount, ...others]));
  }

  // ───────────────────────────── 4. date ─────────────────────────────

  static const _wd = r'(?:segunda|terca|quarta|quinta|sexta|sabado|domingo)';
  static const _month = r'(?:janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)';
  static const _count = r'(?:\d{1,4}|um|uma|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|quinze|vinte|trinta)';

  /// A time word right on an amount, with or without its verb: "hoje
  /// gastei 30", "hoje cedo repassei 14", "hoje deu 187", "hoje 1350 na
  /// banca", "ontem gastei 9". Not "hoje faz 3 dias", "hoje dia 15", "hoje
  /// lembrei que…".
  static const _onAmountTail =
      r'(?:(?:cedo|mais\s+cedo|de\s+manha|a\s+tarde|a\s+noite|agora)\s+)?(?:eu\s+)?'
      r'(?:(?!(?:faz|tem|ha|dia|as|completa|completou|sao|e)\b)[a-z]{2,}\s+)?(?:(?:uns|umas|so|mais|r\$)\s*)*'
      r'\d+(?:[.,]\d+)?(?!\d|[.,]\d|\s*(?:dias?|semanas?|mes|meses|anos?|horas?|h\b|:|/))';
  static final _todayOnTheEntry = RegExp(r'\bhoje\s+' '$_onAmountTail');
  static final _onAmount = RegExp(r'^\s*,?\s*' '$_onAmountTail');

  /// "meu carro tem 15 anos": an age, said of a subject at the start of the
  /// clause — not "paguei a conta tem 3 dias".
  static final _ageSubjectBefore = RegExp(
      r'(?:^|[,;:.!?]|\b(?:e|mas|que|porque|pois)\s)\s*(?:(?:meu|minha|meus|minhas|o|a|os|as|seu|sua|seus|suas|nosso|nossa)\s+[a-z]+(?:\s+[a-z]+)?|ele|ela|eles|elas|eu|voce|vc)\s+$');

  static final _todayWord = RegExp(r'\b(?:hoje|hj|hoji|oje)\b|\b(?:essa|esta|nesta|nessa)\s+(?:manha|tarde|noite)\b');

  /// Time said in a way no day can be taken from: asked, never assumed.
  static final vagueTime = RegExp(
    r'\besses\s+dias\b|\b(?:uns|alguns)\s+dias\s+atras\b|\b(?:ha|faz|tem)\s+(?:uns|alguns)\s+dias\b|\boutro\s+dia\b|'
    r'\b(?:um\s+)?dia\s+desses\b|\b(?:no\s+|n[oa]\s+)?(?:comeco|comecinho|inicio|fim|final|finalzinho|meio)\s+do\s+mes\b|'
    r'\brecentemente\b|\b(?:ha|faz)\s+(?:um\s+)?(?:tempo|tempinho)\b|\buns\s+tempos?\s+atras\b',
  );

  /// The time words of one sentence, in order.
  static final _marker = RegExp(
    '\\b(?:semana\\s+(?:passada|retrasada)\\s*,?\\s+(?:n[ao]s?\\s+|de\\s+|em\\s+)?$_wd|$_wd\\s+(?:d[ao]\\s+|na\\s+)?semana\\s+(?:passada|retrasada))\\b|'
    '\\b(?:dia\\s+)?\\d{1,2}\\s+do\\s+mes\\s+(?:passado|retrasado)\\b|'
    '\\b(?:dia\\s+)?\\d{1,2}\\s+de\\s+$_month\\b|'
    '\\bhoje\\b|\\bdepois\\s+de\\s+amanha\\b|\\bante\\s*-?\\s*ontem\\b|\\bantes\\s+de\\s+ontem\\b|\\bontem\\b|\\bamanha\\b|'
    '\\b(?:ha|faz|tem)\\s+(?:uns\\s+|umas\\s+)?$_count\\s+(?:dias?|semanas?|mes|meses|anos?)\\b|'
    '\\b(?:uns\\s+|umas\\s+)?$_count\\s+(?:dias?|semanas?|meses|anos?)\\s+atras\\b|\\bdaqui\\s+a\\s+\\S+\\s+dias?\\b|'
    '\\b(?:semana|mes|ano)\\s+(?:passad[oa]|retrasad[oa]|que\\s+vem)\\b|\\bproxim[oa]\\s+(?:semana|mes|ano|$_wd)\\b|'
    '\\b$_wd\\s+(?:passad[oa]|retrasad[oa]|que\\s+vem)\\b|\\bfim\\s+de\\s+semana\\b|\\bfds\\b|'
    // ("dia 28/8" is the dd/mm read below, not "dia 28" of this month.)
    '\\bdia\\s+\\d{1,2}\\b(?!\\s*/\\s*\\d)|'
    '(?<!\\btod[ao]s?\\s)(?<!\\bas\\s)\\b$_wd\\b(?!\\s+(?:via|vez|parcela|prestacao|mao|opcao|chamada|etapa|fase|dose|quinzena|semana|hora|colocad[oa]|avenida|rua|praca)\\b)',
  );

  /// A "dia N" that is a recurring due day, not the day of the entry.
  static final _dueBefore = RegExp(r'\b(?:todo|toda|todos|santo|vence|vencem|vencimento|renova|renovam|cai|caem|debita|debitam)\s+(?:o\s+|no\s+|os\s+)?$');

  /// [text] (lowercase, accents folded, spoken numbers as digits) with what
  /// is not the date of the entry taken out: a "se/caso" clause ("se ontem
  /// foi caro, hoje…", "mesmo se chover amanhã"), streets and shops named
  /// after dates ("rua 25 de março"), and "hoje" when another day is also
  /// said ("hoje lembrei que gastei … ontem", CHAOS-B-002). Shared by the
  /// engine (to read the date) and the gate (to check it).
  static String entryDateText(String text, {bool skipDayNumber = false, DateTime? now}) {
    var s = SpokenDayParser.normalizeWeekdays(_fold(PtNumberWords.normalize(text.toLowerCase())));
    // A "se/caso" clause up to its punctuation (hedges keep theirs).
    s = s.replaceAllMapped(RegExp(r'\b(?:mesmo\s+)?(?:se|caso)\b(?!\s+(?:eu\s+)?n[aã]o\s+me\s+engan|\s+(?:eu\s+)?(?:bem\s+)?me\s+lembr)[^,;:.!?]*'),
        // (Not when the clause tells a fact in the past: "se eu gastei 45
        // ontem, registra" keeps its "ontem".)
        (m) => RegExp(r'\b[a-z]{3,}ei\b').hasMatch(m.group(0)!) ? m.group(0)! : ' ' * m.group(0)!.length);
    s = s.replaceAll(RegExp(r'\b(?:hj|hoji|oje)\b'), 'hoje');
    // "mês passado no dia 12 gastei 230" is "dia 12 do mês passado": one
    // date, said month first (ACC-C-020) — read as a span plus a day of
    // this month, it was asked.
    s = s.replaceAllMapped(RegExp(r'\b(?:no\s+|em\s+)?mes\s+(passado|retrasado)\s*,?\s+(?:no\s+|em\s+)?dia\s+(\d{1,2})\b(?!\s*/)'),
        (m) => 'dia ${m.group(2)} do mes ${m.group(1)}');
    // An age ("meu carro tem 15 anos") is not when anything happened.
    s = s.replaceAllMapped(RegExp(r'\btem\s+(?:uns\s+|umas\s+)?\d{1,4}\s+(?:anos?|meses|mes|semanas?|dias?)\b'),
        (m) => _ageSubjectBefore.hasMatch(s.substring(0, m.start)) ? ' ' * m.group(0)!.length : m.group(0)!);
    s = s.replaceAllMapped(RegExp('\\b(\\d{1,2})\\s+de\\s+$_month\\b'),
        (m) => SpokenDayParser.isPlaceBeforeNamedDate(s.substring(0, m.start)) ? 'lugar' : m.group(0)!);
    // "hoje" on the verb that carries the amount is the entry's day; other
    // time words then describe something else ("esquece o que eu falei
    // ontem, hoje gastei 30", "o mercado que era 150 semana passada hoje
    // deu 187", "hoje cedo repassei 14 … no açougue domingo").
    if (_todayOnTheEntry.hasMatch(s)) {
      return s
          // (A day on another amount stays: "ontem gastei 9 … e hoje 1350"
          // has two dates for two values — asked.)
          .replaceAllMapped(_marker,
              (m) => m.group(0) == 'hoje' || _onAmount.hasMatch(s.substring(m.end)) ? m.group(0)! : ' ' * m.group(0)!.length)
          .replaceAllMapped(vagueTime, (m) => ' ' * m.group(0)!.length);
    }
    if (_todayWord.hasMatch(s)) {
      final rest = s.replaceAll(_todayWord, ' ');
      final other = SpokenDayParser.parse(rest, now: now ?? DateTime.now(), allowFuture: true, skipDayNumber: skipDayNumber);
      if (other != null || vagueTime.hasMatch(rest)) s = rest;
    }
    return s;
  }

  static GateVerdict checkDate(FinancialTransactionDraft draft, List<String> turns, {DateTime? now}) {
    if (draft.settledChecks.contains('date') || draft.missingSlots.contains('date')) return const GateVerdict.ok();
    final clock = now ?? DateTime.now();
    for (final turn in turns.reversed) {
      final s = entryDateText(LocalFinancialNlpEngine.withoutNameDates(turn), now: clock);
      final markers = <String>[];
      for (final m in _marker.allMatches(s)) {
        final t = m.group(0)!;
        final dayN = RegExp(r'^dia\s+(\d{1,2})$').firstMatch(t);
        if (dayN != null) {
          final n = int.parse(dayN.group(1)!);
          if (_dueBefore.hasMatch(s.substring(0, m.start)) || (draft.isRecurrent && (draft.dueDay == n || draft.billingDay == n))) continue;
        }
        markers.add(t);
      }
      final dm = SpokenDayParser.dateLikeDayMonth(s);
      if (dm != null) markers.add('em ${dm.group(0)}');
      final vague = vagueTime.hasMatch(s);
      if (markers.isEmpty && !vague) continue;
      final value = draft.amount != null && draft.amount! > 0 ? _brl(draft.amount!) : 'esse valor';
      final ask = GateVerdict.ask(GateCheck.date, 'date',
          'Quando foi esse lançamento de $value? Me diga o dia (ex.: "ontem", "segunda", "dia 15").');
      if (vague) return ask;
      final offsets = <int>{};
      for (final t in markers) {
        final r = SpokenDayParser.parse(t, now: clock, allowFuture: true);
        final d = r?.day;
        if (d == null) return ask;
        if (d.isRange) {
          // "fim de semana" goes on the Saturday, with a note (decision
          // pending); any other span needs the day.
          final inside = !DateTime(clock.year, clock.month, clock.day + draft.dateOffsetDays).isBefore(d.start) &&
              !DateTime(clock.year, clock.month, clock.day + draft.dateOffsetDays).isAfter(d.end);
          if (d.label == 'do fim de semana' && inside) continue;
          return ask;
        }
        offsets.add(d.offsetFrom(clock));
      }
      if (offsets.isEmpty) return const GateVerdict.ok();
      if (offsets.length > 1 || offsets.first != draft.dateOffsetDays || offsets.first > 0) return ask;
      return const GateVerdict.ok();
    }
    return const GateVerdict.ok();
  }

  // ───────────────────────────── 5. certainty ─────────────────────────────

  /// The confirmation net (7e): a draft about to be saved whose words don't
  /// say for sure it happened ([EntryCertainty]) is shown and confirmed
  /// first — "Registro assim? (sim/não)". Only a complete draft is
  /// confirmed (the other questions come first), and only once.
  static GateVerdict checkCertainty(FinancialTransactionDraft draft, List<String> turns) {
    if (!draft.isComplete || draft.missingSlots.isNotEmpty || draft.settledChecks.contains('certainty')) return const GateVerdict.ok();
    if (draft.bankSource != null) return const GateVerdict.ok();
    if (EntryCertainty.read(turns).high) return const GateVerdict.ok();
    return GateVerdict.ask(GateCheck.certainty, 'confirm', confirmQuestion(draft));
  }

  static const _paymentNames = {
    'pix': 'no Pix',
    'credit_card': 'no crédito',
    'debit_card': 'no débito',
    'cash': 'em dinheiro',
    'bank_slip': 'no boleto',
  };

  /// "Vou registrar **despesa de R$ 380,00 — Air fryer, no Pix, hoje**.
  /// Registro assim? (sim/não)".
  static String confirmQuestion(FinancialTransactionDraft d, {DateTime? now}) {
    final kind = d.intent == 'income' ? 'receita' : (d.intent == 'transfer' ? 'transferência' : 'despesa');
    final value = d.amount != null && d.amount! > 0 ? ' de ${_brl(d.amount!)}' : '';
    final what = d.description.trim().isEmpty || d.description == 'unknown' ? '' : ' — ${d.description}';
    final inst = (d.installments ?? 1) > 1 ? ' em ${d.installments}x' : '';
    final pay = _paymentNames[d.paymentMethod] == null ? '' : ', ${_paymentNames[d.paymentMethod]}$inst';
    final clock = now ?? DateTime.now();
    final day = DateTime(clock.year, clock.month, clock.day + d.dateOffsetDays);
    final when = d.dateOffsetDays == 0
        ? 'hoje'
        : d.dateOffsetDays == -1
            ? 'ontem'
            : '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}';
    return 'Vou registrar **$kind$value$what$pay, $when**. Registro assim? (sim/não)';
  }

  static String _plain(String text) => _fold(text).replaceAll(RegExp(r'[!.,]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// "sim", "pode", "isso", "registra", "confirmo" — yes to "Registro assim?".
  static bool confirmsEntry(String text) => RegExp(
          r'^(?:sim|s|ss|isso|isso mesmo|isso ai|pode|pode sim|pode registrar|pode lancar|pode anotar|registra|registre|lanca|anota|'
          r'confirmo|confirma|confirmado|claro|ok|okay|beleza|blz|certo|exato|correto|uhum|aham|yes|com certeza|manda ver|bora|'
          r'foi sim|sim foi|aconteceu sim|foi isso|e isso|eh isso|isso foi|sim registra|sim pode|sim por favor|positivo)'
          r'(?:\s+(?:sim|pode|registra|cesar|por favor|isso|mesmo|ai))*$')
      .hasMatch(_plain(text));

  /// "não", "não registra", "deixa", "nada" — no to "Registro assim?".
  static bool declinesEntry(String text) => RegExp(
          r'^(?:nao|n|nn|nem|negativo|nada|deixa|deixa pra la|deixa quieto|esquece|melhor nao|nao registra|nao precisa|'
          r'nao foi|nao aconteceu|nao e isso|nao eh isso|errado|ta errado|cancela)'
          // (Only the "no" itself: "não, foi 50" corrects the entry.)
          r'(?:\s+(?:nao|registra|precisa|obrigado|obrigada|valeu|cesar|deixa|pra|la|esquece|isso|foi|aconteceu|quero|mais))*$')
      .hasMatch(_plain(text));
}
