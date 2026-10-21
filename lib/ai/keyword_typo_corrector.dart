import 'category_name_matcher.dart';

/// Forgives typos in the handful of words César relies on to understand an
/// entry — the verb ("gstei", "gasteu"), the place/category ("mercadp",
/// "farmasia", "acadmia") and the payment method ("credto") — by snapping a
/// token to the closest keyword within a small edit distance.
///
/// "Fixing" an ordinary word into a keyword files an entry wrong in silence
/// ("solário" → salário made an expense an income; "delito" → débito picked
/// the payment method; "almaço" → almoço, "pradaria" → padaria picked the
/// category). So the rule is structural, not a list of exceptions: **an edit
/// only counts when it is a plausible slip of the finger**, the way a typo
/// actually happens on a phone keyboard:
/// - a missing letter ("mercao", "credto") or two swapped letters ("gsatei");
/// - a letter replaced by a *neighbouring key* ("mercadp": o→p, "gasteu":
///   i→u) or by one that sounds the same ("farmasia": c→s, "viajem": g→j);
/// - an extra letter that repeats or neighbours the letter next to it
///   ("mercaddo").
/// A real word that differs by a vowel far away on the keyboard ("solario",
/// "almaco", "podaria"), an unrelated consonant ("delito", "demito",
/// "pagaria") or an inserted syllable ("pradaria", "facilidade",
/// "presidente") is a different word, not a typo — left alone.
///
/// On top of that:
/// - only keywords of 6+ letters are targets (short words have too many
///   neighbours: "posto" ↔ "porto", "pix" ↔ "fix");
/// - 1 edit is allowed, 2 only for keywords of 10+ letters; keywords that
///   decide the *type* of the entry ("salario", "recebi", "transferi") never
///   get more than 1;
/// - the first letter must match (people rarely mistype the first letter,
///   and it rules out "cantar" → "jantar");
/// - tokens shorter than 5 letters or with digits are never touched;
/// - a token written with an accent or "ç" was spelled on purpose (and voice
///   transcription always spells real words) — typos drop accents, they
///   don't add them; only a missing letter is fixed there ("açouge");
/// - a doubled last letter ("aluguell", "debitoo", "uberr") is always a slip:
///   it is dropped when what is left is a keyword or a known word;
/// - the few real words that *are* one plausible slip away from a keyword
///   ("gostei", "lance", "vagem", "pararia") are protected, as is anything
///   the caller says is a known word (the model's vocabulary).
///
/// Pure Dart, no Flutter.
class KeywordTypoCorrector {
  KeywordTypoCorrector._();

  /// Canonical (accent-free) spellings. Other code matches these with
  /// `contains`, so the folded form is what it expects.
  static const keywords = <String>[
    // verbs that open an entry
    'gastei', 'paguei', 'comprei', 'recebi', 'transferi', 'abasteci',
    // places / categories
    'mercado', 'supermercado', 'padaria', 'farmacia', 'drogaria', 'restaurante',
    'academia', 'gasolina', 'aluguel', 'salario', 'condominio', 'combustivel',
    'estacionamento', 'faculdade', 'mensalidade', 'almoco', 'jantar', 'lanche',
    'viagem', 'cinema', 'brinquedo', 'presente',
    'internet', 'onibus', 'dentista', 'acougue', 'pedagio', 'remedio', 'remedios',
    'shopping', 'pizzaria', 'lanchonete', 'hamburguer', 'sorvete', 'cerveja',
    'barbeiro', 'cabeleireiro', 'manicure', 'veterinario', 'oficina', 'escola', 'hortifruti',
    // payment methods
    'credito', 'debito', 'dinheiro', 'boleto',
  ];

  /// Real words one or two edits away from a keyword — never corrected.
  static const protectedWords = <String>{
    'gostei', 'gastem', 'gastes', 'gaste', 'gasta', 'gastou', 'gasto', 'gastos',
    'paguem', 'pague', 'pagou',
    'compre', 'comprem', 'compra', 'compras', 'comprou',
    'recebe', 'receba', 'recebeu', 'recebem',
    'transfere', 'transferir',
    'abastece', 'abastecer',
    'mercador', 'mercadoria', 'mercadorias',
    'academico', 'academica', 'academicos', 'academicas',
    'alugue', 'alugou', 'alugar',
    'credita', 'credite', 'creditou', 'creditar',
    'debita', 'debite', 'debitou', 'debitar', 'debate', 'debates',
    'bolero', 'boleta',
    'almoca', 'almocar', 'almocou',
    'jantou', 'jantas', 'janta',
    'lancha', 'lanchas', 'lanchou',
    'virgem', 'viagens',
    'presenta', 'presentes', 'presencial', 'pressente', 'pressentes',
    'cinemas',
    // one plausible slip away from a keyword, but real words (R2-CHAOS-001…006)
    'lance', 'lances', 'vagem', 'vagens', 'pararia', 'recebo', 'recebes', 'recebei',
    'jantam', 'jantes', 'jante', 'gastam', 'gastas', 'pagues', 'compres',
    'devido', 'devida', 'boleia', 'bolota', 'deito', 'visagem', 'visagens',
    'cereja', 'cerejas', 'condomino', 'condominos', 'escolha', 'escolhas',
  };

  /// Keywords that decide whether the entry is money in or out: a false
  /// correction flips the type, so they never get the 2-edit allowance.
  static const _typeKeywords = {'salario', 'recebi', 'transferi'};

  static int _maxDistanceFor(String keyword) {
    if (keyword.length >= 10 && !_typeKeywords.contains(keyword)) return 2;
    if (keyword.length >= 6) return 1;
    return 0;
  }

  // Phone keyboard (QWERTY/ABNT2) rows with their horizontal stagger, to tell
  // a slip of the finger ("mercadp") from a different word ("mercador").
  static const _rows = ['qwertyuiop', 'asdfghjklç', 'zxcvbnm'];
  static const _rowOffsets = [0.0, 0.25, 0.75];
  static final Map<String, (int, double)> _keyPos = {
    for (var r = 0; r < _rows.length; r++)
      for (var i = 0; i < _rows[r].length; i++) _rows[r][i]: (r, i + _rowOffsets[r]),
  };

  /// Keys that touch each other on the keyboard.
  static bool areNeighbourKeys(String a, String b) {
    final pa = _keyPos[a], pb = _keyPos[b];
    if (pa == null || pb == null || a == b) return false;
    if (pa.$1 == pb.$1) return (pa.$2 - pb.$2).abs() == 1;
    return (pa.$1 - pb.$1).abs() == 1 && (pa.$2 - pb.$2).abs() < 1;
  }

  // Letters that sound alike in Portuguese spelling ("farmasia", "viajem",
  // "merkado").
  static const _soundAlike = ['scz', 'gj', 'ck'];

  static bool _plausibleSubstitution(String typed, String intended) =>
      areNeighbourKeys(typed, intended) || _soundAlike.any((g) => g.contains(typed) && g.contains(intended));

  /// An extra letter typed next to [neighbours]: a repeat or a neighbouring key.
  static bool _plausibleInsertion(String extra, List<String> neighbours) =>
      neighbours.any((n) => n == extra || areNeighbourKeys(extra, n));

  /// The keyword [token] is a typo of, or null when it isn't one (or is
  /// already spelled right). [isKnownWord] lets the caller protect more
  /// real words (e.g. the model's vocabulary).
  static String? correct(String token, {bool Function(String word)? isKnownWord}) {
    final lowerToken = token.toLowerCase();
    final t = CategoryNameMatcher.foldAccents(lowerToken);
    if (t.length < 5 || RegExp(r'[^a-z]').hasMatch(t)) return null;
    if (keywords.contains(t) || protectedWords.contains(t)) return null;
    if (isKnownWord != null && (isKnownWord(t) || isKnownWord(token.toLowerCase()))) return null;
    // A doubled last letter ("aluguell", "debitoo", "uberr") is a key held
    // too long, not an ending — Portuguese words don't end in one. Any known
    // word, short brands included, once the extra letter is gone.
    if (t[t.length - 1] == t[t.length - 2]) {
      final single = t.substring(0, t.length - 1);
      if (keywords.contains(single) || (isKnownWord != null && isKnownWord(single))) return single;
    }
    // Accents/"ç" mean the word was spelled on purpose ("solário", "almaço"):
    // typos drop letters, they don't add accents. Only a letter missing from
    // a keyword is still fixed ("açouge").
    if (RegExp(r'[à-ÿ]').hasMatch(lowerToken)) {
      for (final k in keywords) {
        if (k.length == t.length + 1 && k[0] == t[0] && _missingOneLetter(t, k)) return k;
      }
      return null;
    }

    String? best;
    var bestDistance = 99;
    for (final k in keywords) {
      final limit = _maxDistanceFor(k);
      if (limit == 0 || k[0] != t[0]) continue;
      // The keyword plus an ending ("boletos", "mercados", "academias") is the
      // same word inflected, not a typo — and "2 boletos de 150" needs the plural.
      if (t.startsWith(k)) return null;
      if ((k.length - t.length).abs() > limit) continue;
      final d = typoDistance(t, k, limit: limit);
      if (d <= limit && d < bestDistance) {
        best = k;
        bestDistance = d;
      } else if (d <= limit && d == bestDistance) {
        // Two keywords equally close: ambiguous, don't guess.
        best = null;
      }
    }
    return best;
  }

  /// How the keywords that carry an accent are written, for titles
  /// ("onbus" is the "Ônibus", not the "Onibus").
  static const _accented = {
    'farmacia': 'farmácia', 'salario': 'salário', 'condominio': 'condomínio', 'combustivel': 'combustível',
    'almoco': 'almoço', 'credito': 'crédito', 'debito': 'débito', 'onibus': 'ônibus', 'acougue': 'açougue',
    'pedagio': 'pedágio', 'remedio': 'remédio', 'remedios': 'remédios', 'hamburguer': 'hambúrguer',
    'veterinario': 'veterinário',
  };

  /// [text] with every typo'd keyword replaced by its canonical spelling;
  /// everything else (spacing, punctuation, digits) is left as it was. With
  /// [accented], the replacement is spelled with its accents (for titles).
  static String correctText(String text, {bool Function(String word)? isKnownWord, bool accented = false}) {
    return text.replaceAllMapped(RegExp(r'[a-zA-ZÀ-ÿ]+'), (m) {
      final word = m.group(0)!;
      final fixed = correct(word, isKnownWord: isKnownWord);
      if (fixed == null) return word;
      return accented ? (_accented[fixed] ?? fixed) : fixed;
    });
  }

  /// Like [distance], but only counting edits that look like a slip of the
  /// finger (see the class comment): deletions, adjacent transpositions,
  /// substitutions by a neighbouring/sound-alike letter and insertions of a
  /// repeated/neighbouring letter. Any other edit pushes the result past
  /// [limit]. [typed] is the user's token, [intended] the keyword.
  static int typoDistance(String typed, String intended, {int limit = 2}) {
    final a = typed, b = intended;
    final n = a.length, m = b.length;
    if ((n - m).abs() > limit) return limit + 1;
    final impossible = limit + 1;
    // Full table: the words are short, and transpositions look two rows back.
    final d = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = 1; i <= n; i++) {
      // Extra letters before the keyword starts: only repeats/neighbours.
      d[i][0] = _plausibleInsertion(a[i - 1], [if (i < n) a[i], if (i > 1) a[i - 2]]) ? d[i - 1][0] + 1 : impossible + i;
    }
    for (var j = 1; j <= m; j++) {
      d[0][j] = j; // letters missing from the token
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final same = a[i - 1] == b[j - 1];
        var v = same ? d[i - 1][j - 1] : impossible + 1;
        if (!same && _plausibleSubstitution(a[i - 1], b[j - 1])) v = _min(v, d[i - 1][j - 1] + 1);
        // A letter missing from the token.
        v = _min(v, d[i][j - 1] + 1);
        // An extra letter in the token, next to what it was typed beside.
        if (_plausibleInsertion(a[i - 1], [if (i > 1) a[i - 2], if (i < n) a[i]])) v = _min(v, d[i - 1][j] + 1);
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) v = _min(v, d[i - 2][j - 2] + 1);
        d[i][j] = v;
      }
    }
    return d[n][m] > limit ? limit + 1 : d[n][m];
  }

  static int _min(int a, int b) => a < b ? a : b;

  /// Whether [short] is [long] with exactly one letter left out.
  static bool _missingOneLetter(String short, String long) {
    var i = 0;
    while (i < short.length && short[i] == long[i]) {
      i++;
    }
    return short.substring(i) == long.substring(i + 1);
  }

  /// Optimal-string-alignment distance (Levenshtein plus adjacent
  /// transpositions, so "gsatei" is one edit from "gastei"). Stops early and
  /// returns `limit + 1` once the distance must exceed [limit].
  static int distance(String a, String b, {int limit = 1 << 30}) {
    final n = a.length, m = b.length;
    if ((n - m).abs() > limit) return limit + 1;
    var prev2 = List<int>.filled(m + 1, 0);
    var prev = List<int>.generate(m + 1, (j) => j);
    var cur = List<int>.filled(m + 1, 0);
    for (var i = 1; i <= n; i++) {
      cur[0] = i;
      var rowMin = cur[0];
      for (var j = 1; j <= m; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var v = prev[j] + 1;
        if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
        if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] && prev2[j - 2] + 1 < v) {
          v = prev2[j - 2] + 1;
        }
        cur[j] = v;
        if (v < rowMin) rowMin = v;
      }
      if (rowMin > limit) return limit + 1;
      final tmp = prev2;
      prev2 = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[m];
  }
}
