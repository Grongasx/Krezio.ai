import 'category_name_matcher.dart';

/// Converts Brazilian-Portuguese spoken numbers into digits, so the amount
/// extractor only ever has to deal with "52,90" instead of "cinquenta e dois
/// reais e noventa centavos". Voice transcription writes numbers out in full,
/// and before this only a single word right before "reais" was understood —
/// "cinquenta e dois reais" was saved as R$ 2,00.
///
/// Covers: units/teens/tens/hundreds joined by "e" ("cento e vinte e cinco"),
/// "mil"/"milhão" multipliers, also after digits ("10 mil", "1,5 mil"),
/// "meio" ("meio milhão", "um milhão e meio", "dois e meio"), "vírgula"
/// decimals ("vinte e cinco vírgula cinquenta") and cents ("doze reais e
/// cinquenta centavos", "50 reais e 90 centavos", "um real e cinquenta").
///
/// Pure and stateless — see `test/pt_number_words_test.dart`.
class PtNumberWords {
  PtNumberWords._();

  static const Map<String, int> _units = {
    'um': 1, 'uma': 1, 'dois': 2, 'duas': 2, 'tres': 3, 'quatro': 4, 'cinco': 5,
    'seis': 6, 'sete': 7, 'oito': 8, 'nove': 9,
  };
  static const Map<String, int> _teens = {
    'dez': 10, 'onze': 11, 'doze': 12, 'treze': 13, 'quatorze': 14, 'catorze': 14,
    'quinze': 15, 'dezesseis': 16, 'dezasseis': 16, 'dezessete': 17, 'dezassete': 17,
    'dezoito': 18, 'dezenove': 19, 'dezanove': 19,
  };
  static const Map<String, int> _tens = {
    'vinte': 20, 'trinta': 30, 'quarenta': 40, 'cinquenta': 50, 'cincoenta': 50,
    'sessenta': 60, 'setenta': 70, 'oitenta': 80, 'noventa': 90,
  };
  static const Map<String, int> _hundreds = {
    'cem': 100, 'cento': 100, 'duzentos': 200, 'duzentas': 200, 'trezentos': 300, 'trezentas': 300,
    'quatrocentos': 400, 'quatrocentas': 400, 'quinhentos': 500, 'quinhentas': 500,
    'seiscentos': 600, 'seiscentas': 600, 'setecentos': 700, 'setecentas': 700,
    'oitocentos': 800, 'oitocentas': 800, 'novecentos': 900, 'novecentas': 900,
  };
  static const Map<String, int> _multipliers = {
    'mil': 1000, 'milhao': 1000000, 'milhoes': 1000000,
  };
  static const Set<String> _currencyWords = {'real', 'reais'};
  static const Set<String> _centWords = {'centavo', 'centavos'};

  static final RegExp _tokenPattern = RegExp(r'\d+(?:[.,]\d+)*|[a-zà-ÿ]+', caseSensitive: false);

  /// Value of a text that is *only* a number ("mil e quinhentos",
  /// "cinquenta e dois reais e noventa centavos", "10 mil"), or null.
  static double? parse(String phrase) {
    final tokens = _tokenize(phrase);
    if (tokens.isEmpty) return null;
    final read = _readAmount(tokens, 0, allowBareDigits: true);
    if (read == null || read.end != tokens.length) return null;
    return read.value;
  }

  /// [text] with every spoken number replaced by digits (pt-BR decimal comma,
  /// no thousands separator). Everything else — including case — is kept, so
  /// it is safe to run before any keyword matching. A lone "um"/"uma" is an
  /// article ("comprei um tênis") and only becomes 1 before "real"/"reais".
  static String normalize(String text) {
    final tokens = _tokenize(text);
    if (tokens.isEmpty) return text;
    final out = StringBuffer();
    var cursor = 0;
    var i = 0;
    while (i < tokens.length) {
      final read = _readAmount(tokens, i, allowBareDigits: false);
      if (read == null) {
        i++;
        continue;
      }
      out.write(text.substring(cursor, tokens[i].start));
      out.write(_format(read.value));
      if (read.currency != null) out.write(' ${read.currency}');
      cursor = tokens[read.end - 1].end;
      i = read.end;
    }
    out.write(text.substring(cursor));
    return out.toString();
  }

  static String _format(double v) {
    if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
    return v.toStringAsFixed(2).replaceAll('.', ',');
  }

  static List<_Token> _tokenize(String text) {
    final tokens = <_Token>[];
    var previousEnd = 0;
    for (final m in _tokenPattern.allMatches(text)) {
      // Only whitespace since the previous token: a comma or period ends a
      // spoken number ("dois, três").
      final joined = tokens.isEmpty || text.substring(previousEnd, m.start).trim().isEmpty;
      tokens.add(_Token(CategoryNameMatcher.foldAccents(m.group(0)!.toLowerCase()), m.start, m.end, joined));
      previousEnd = m.end;
    }
    return tokens;
  }

  static bool _isDigits(String t) => RegExp(r'^\d').hasMatch(t);

  static bool _isNumberWord(String t) =>
      _units.containsKey(t) || _teens.containsKey(t) || _tens.containsKey(t) || _hundreds.containsKey(t) || _multipliers.containsKey(t);

  /// Reads "<integer part> [vírgula <decimals>] [reais [e <cents> [centavos]]]"
  /// starting at [start]. Returns null when nothing there needs converting
  /// (a plain "50" stays as is unless [allowBareDigits]).
  static _Read? _readAmount(List<_Token> tokens, int start, {required bool allowBareDigits}) {
    final integer = _readInteger(tokens, start);
    if (integer == null) {
      // "cinquenta centavos" with nothing before is handled as an integer of
      // 50 followed by the cents word below; nothing else starts a number.
      return null;
    }
    var value = integer.value;
    var end = integer.end;
    var changed = integer.hasWords || integer.hasMultiplier;

    // "oitenta e sete e cinquenta", "dezenove e noventa": a spoken price
    // says the cents after one more "e" (the word order rules above stop
    // before it, since "sete" can't be followed by "cinquenta").
    if (integer.hasWords && end + 1 < tokens.length && tokens[end].joined && tokens[end].text == 'e' && tokens[end + 1].joined) {
      final cents = _readInteger(tokens, end + 1);
      if (cents != null && cents.hasWords && !cents.hasMultiplier && cents.value >= 10 && cents.value <= 99 && cents.value == cents.value.roundToDouble()) {
        value += cents.value / 100;
        end = cents.end;
        changed = true;
      }
    }

    // "vinte e cinco vírgula cinquenta" → 25,50
    if (end + 1 < tokens.length && tokens[end].joined && tokens[end].text == 'virgula') {
      final dec = _readDecimals(tokens, end + 1);
      if (dec != null) {
        value += dec.value;
        end = dec.end;
        changed = true;
      }
    }

    // "cinquenta centavos" → 0,50
    if (end < tokens.length && tokens[end].joined && _centWords.contains(tokens[end].text) && value < 100 && !integer.hasMultiplier) {
      return _Read(value / 100, end + 1, null);
    }

    String? currency;
    if (end < tokens.length && tokens[end].joined && _currencyWords.contains(tokens[end].text)) {
      currency = tokens[end].text == 'real' ? 'real' : 'reais';
      final afterCurrency = end + 1;
      // "... reais e noventa centavos" / "um real e cinquenta"
      if (afterCurrency + 1 < tokens.length && tokens[afterCurrency].joined && tokens[afterCurrency].text == 'e' && tokens[afterCurrency + 1].joined) {
        final cents = _readInteger(tokens, afterCurrency + 1);
        if (cents != null && cents.value < 100 && cents.value == cents.value.roundToDouble() && !cents.hasMultiplier) {
          final hasCentWord = cents.end < tokens.length && tokens[cents.end].joined && _centWords.contains(tokens[cents.end].text);
          // Without "centavos" only the fully spoken form counts ("um real e
          // cinquenta"); "50 reais e 30 na farmácia" is a second purchase.
          if (hasCentWord || (integer.hasWords && cents.hasWords)) {
            value += cents.value / 100;
            end = hasCentWord ? cents.end + 1 : cents.end;
            changed = true;
            return _Read(value, end, currency);
          }
        }
      }
      if (changed || allowBareDigits) return _Read(value, afterCurrency, currency);
    }

    if (!changed && !allowBareDigits) return null;
    // A lone article: "comprei um tênis", "uma vez".
    if (integer.isLoneArticle && currency == null && !allowBareDigits) return null;
    return _Read(value, end, null);
  }

  static _Read? _readDecimals(List<_Token> tokens, int start) {
    var i = start;
    var zeros = '';
    while (i < tokens.length && tokens[i].joined && tokens[i].text == 'zero') {
      zeros += '0';
      i++;
    }
    if (i >= tokens.length || !tokens[i].joined) return null;
    String digits;
    int end;
    if (_isDigits(tokens[i].text) && RegExp(r'^\d{1,2}$').hasMatch(tokens[i].text)) {
      digits = tokens[i].text;
      end = i + 1;
    } else {
      final part = _readInteger(tokens, i);
      if (part == null || part.hasMultiplier || part.value >= 100) return null;
      digits = part.value.round().toString();
      end = part.end;
    }
    return _Read(double.parse('0.$zeros$digits'), end, null);
  }

  /// Integer part: digits with an optional multiplier ("10 mil", "1,5 mil"),
  /// or number words. Word order is enforced (hundreds → tens → units, and
  /// multipliers decreasing) so two separate numbers — "dois três" — are
  /// never glued into one.
  static _Integer? _readInteger(List<_Token> tokens, int start) {
    if (start >= tokens.length) return null;
    var i = start;
    double total = 0;
    double group = 0;
    int? lastMultiplier;
    String lastClass = 'none'; // none | hundred | ten | teen | unit | digit
    var hasWords = false;
    var hasMultiplier = false;
    var wordCount = 0;
    var lastWord = '';

    bool accepts(String cls) {
      switch (lastClass) {
        case 'none':
          return true;
        case 'hundred':
          return cls == 'ten' || cls == 'teen' || cls == 'unit';
        case 'ten':
          return cls == 'unit';
        default:
          return false;
      }
    }

    String? classOf(String t) {
      if (_hundreds.containsKey(t)) return 'hundred';
      if (_tens.containsKey(t)) return 'ten';
      if (_teens.containsKey(t)) return 'teen';
      if (_units.containsKey(t)) return 'unit';
      return null;
    }

    int valueOf(String t) => _hundreds[t] ?? _tens[t] ?? _teens[t] ?? _units[t]!;

    // First token: digits (only as the start of a "N mil" group) or a word.
    final first = tokens[i].text;
    if (_isDigits(first)) {
      final v = _parseDigits(first);
      if (v == null) return null;
      group = v;
      lastClass = 'digit';
      i++;
      final hasMult = i < tokens.length && tokens[i].joined && _multipliers.containsKey(tokens[i].text);
      if (!hasMult) return _Integer(v, i, hasWords: false, hasMultiplier: false, isLoneArticle: false);
    } else if (first == 'meio' && i + 1 < tokens.length && tokens[i + 1].joined && _multipliers.containsKey(tokens[i + 1].text)) {
      group = 0.5;
      lastClass = 'digit';
      hasWords = true;
      i++;
    } else if (!_isNumberWord(first)) {
      return null;
    }

    while (i < tokens.length) {
      final tok = tokens[i];
      if (i > start && !tok.joined) break;
      final t = tok.text;
      final cls = classOf(t);
      if (cls != null) {
        if (!accepts(cls)) break;
        group += valueOf(t);
        lastClass = cls;
        hasWords = true;
        wordCount++;
        lastWord = t;
        i++;
        continue;
      }
      final mult = _multipliers[t];
      if (mult != null) {
        if (lastMultiplier != null && mult >= lastMultiplier) break;
        total += (group == 0 ? 1 : group) * mult;
        group = 0;
        lastMultiplier = mult;
        lastClass = 'none';
        hasWords = true;
        hasMultiplier = true;
        wordCount++;
        lastWord = t;
        i++;
        continue;
      }
      if (t == 'e' && i + 1 < tokens.length && tokens[i + 1].joined) {
        final next = tokens[i + 1].text;
        final nextCls = classOf(next);
        if (next == 'meio' && (lastMultiplier != null || group > 0)) {
          // "um milhão e meio" / "dois e meio"
          if (group == 0 && lastMultiplier != null) {
            total += lastMultiplier / 2;
          } else {
            group += 0.5;
          }
          hasWords = true;
          wordCount++;
          i += 2;
          break;
        }
        // "e" only glues when the next word continues this number: after a
        // multiplier anything smaller, otherwise the class order above.
        if (nextCls != null && (lastClass == 'none' ? lastMultiplier != null : accepts(nextCls))) {
          i++;
          continue;
        }
        break;
      }
      break;
    }

    if (i == start) return null;
    // "cento" never stands alone ("dez por cento").
    if (wordCount == 1 && lastWord == 'cento') return null;
    final value = total + group;
    final isLoneArticle = wordCount == 1 && (lastWord == 'um' || lastWord == 'uma') && !hasMultiplier;
    return _Integer(value, i, hasWords: hasWords, hasMultiplier: hasMultiplier, isLoneArticle: isLoneArticle);
  }

  static double? _parseDigits(String raw) {
    var s = raw;
    if (s.contains('.') && s.contains(',')) {
      s = s.lastIndexOf(',') > s.lastIndexOf('.') ? s.replaceAll('.', '').replaceAll(',', '.') : s.replaceAll(',', '');
    } else if (s.contains(',')) {
      s = s.split(',').length == 2 ? s.replaceAll(',', '.') : s.replaceAll(',', '');
    } else if (s.contains('.')) {
      final parts = s.split('.');
      if (parts.length != 2 || parts[1].length == 3) s = s.replaceAll('.', '');
    }
    return double.tryParse(s);
  }
}

class _Token {
  final String text;
  final int start;
  final int end;

  /// Separated from the previous token by whitespace only.
  final bool joined;

  _Token(this.text, this.start, this.end, this.joined);
}

class _Integer {
  final double value;
  final int end;
  final bool hasWords;
  final bool hasMultiplier;
  final bool isLoneArticle;

  _Integer(this.value, this.end, {required this.hasWords, required this.hasMultiplier, required this.isLoneArticle});
}

class _Read {
  final double value;
  final int end;
  final String? currency;

  _Read(this.value, this.end, this.currency);
}
