import 'cesar_text.dart';
import 'local_nlp_engine.dart';
import 'pt_number_words.dart';

/// "o jantar deu 240, dividi com mais 3" → my part 60, 180 to receive.
class BillSplit {
  final String description;
  final double total;

  /// People, me included.
  final int people;

  /// Names of the others, when said ("dividi com o joão e a ana").
  final List<String> others;

  /// True when the user explicitly said everyone paid their own share on the spot
  /// ("cada um pagou sua parte" / "paguei só minha parte"): no receivable is created.
  final bool onlyMyShare;

  const BillSplit({
    required this.description,
    required this.total,
    required this.people,
    this.others = const [],
    this.onlyMyShare = false,
  });

  int get _totalCents => (total * 100).round();
  int get _myCents => (_totalCents / people).round();

  double get myShare => _myCents / 100;
  double get toReceive => onlyMyShare ? 0.0 : (_totalCents - _myCents) / 100;
  double get perPerson => myShare;

  /// Cent-balanced share for the [index]-th participant so myShare + sum(others) == total.
  double shareForOther(int index) {
    if (onlyMyShare) return 0.0;
    final rem = _totalCents - _myCents;
    final count = others.isEmpty ? (people - 1) : others.length;
    if (count <= 0) return 0.0;
    final base = rem ~/ count;
    final extra = rem % count;
    return (base + (index < extra ? 1 : 0)) / 100;
  }
}

/// Reads a split bill from a sentence. Pure Dart.
class BillSplitParser {
  BillSplitParser._();

  static final _value = RegExp(
    r'(?:r\s*\$?\s*)?(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)',
  );

  static final _onlyMyShareRe = RegExp(
    r'\bcada\s+um\s+pagou\s+(?:a\s+)?(?:sua|seu|o\s+seu|a\s+sua|suas?)\b|'
    r'\bpaguei\s+(?:so|apenas)\s+(?:a\s+)?minha\s+parte\b|'
    r'\bso\s+(?:a\s+)?minha\s+parte\b|'
    r'\bpaguei\s+minha\s+parte\b',
  );

  static const _genericTitles = {
    'total',
    'valor',
    'conta',
    'tudo',
    'isso',
    'gasto',
    'despesa',
    'pagamento',
    'divisao',
    'parte',
    'metade',
    'resto',
  };

  static const _ignoreNames = {
    'mais',
    'todo',
    'todos',
    'galera',
    'pessoal',
    'amigos',
    'amigas',
    'gente',
    'mim',
    'nos',
    'eles',
    'elas',
    'cada',
  };

  static BillSplit? parse(String text) {
    final s = CesarText.simplify(text);
    // Only a split that happened ("dividi", "rachamos"): "vou dividir" is a
    // plan, and "dividi em 3x no cartão" is an installment, not people.
    final split = RegExp(r'\b(?:dividi|dividimos|divide|divida|rachei|rachamos|racharam|dividiram)\b').firstMatch(s);
    if (split == null) return null;
    if (RegExp(r'\b(?:vou|vamos|vamo|quero|queremos|posso|da\s+pra|penso\s+em|pretendo)\s+(?:dividir|rachar)\b').hasMatch(s)) {
      return null;
    }
    if (RegExp(r'\b\d+\s*x\b|\bvezes\b|\bparcel\w*|\bprestac\w*').hasMatch(s)) return null;

    final after = s.substring(split.end);
    final before = s.substring(0, split.start);

    // How many people: "com mais 3", "com 2 amigos", "em 3", "entre 4 pessoas", "com o joão e a ana".
    int? people;
    Match? peopleMatchInAfter;

    final more = RegExp(r'\bcom\s+mais\s+(\w+)').firstMatch(after) ??
        RegExp(r'\bcom\s+mais\s+(\w+)').firstMatch(s);
    final withOtherCount = RegExp(r'\bcom\s+(\w+)\s+(?:amigos?|amigas?|pessoas?|colegas?|brothers?)\b').firstMatch(after);
    final among = RegExp(r'\b(?:em|entre|por|pra|para)\s+(\w+)(?:\s*(?:pessoas|amigos|amigas|pessoa|partes))?\b').firstMatch(after);

    if (more != null) {
      final n = PtNumberWords.parse(more.group(1)!) ?? int.tryParse(more.group(1)!);
      if (n != null) {
        people = n.toInt() + 1;
        if (more.input == after) peopleMatchInAfter = more;
      }
    } else if (withOtherCount != null) {
      final n = PtNumberWords.parse(withOtherCount.group(1)!) ?? int.tryParse(withOtherCount.group(1)!);
      if (n != null) {
        people = n.toInt() + 1;
        peopleMatchInAfter = withOtherCount;
      }
    } else if (among != null) {
      final n = PtNumberWords.parse(among.group(1)!) ?? int.tryParse(among.group(1)!);
      if (n != null) {
        people = n.toInt();
        peopleMatchInAfter = among;
      }
    }

    final others = <String>[];
    final names = RegExp(r'\bcom\s+(?:o|a|os|as)?\s*([a-z]+(?:\s*(?:,|e)\s*(?:o|a)?\s*[a-z]+)*)').firstMatch(after);
    if (names != null) {
      for (final n in names.group(1)!.split(RegExp(r'\s*(?:,|\be\b)\s*'))) {
        final name = n.replaceFirst(RegExp(r'^(?:o|a)\s+'), '').trim();
        if (name.isNotEmpty && !_ignoreNames.contains(name) && int.tryParse(name) == null) {
          // Keep the spelling the user typed ("joão", not "joao").
          final typed = text.split(RegExp(r'[^\p{L}]+', unicode: true)).firstWhere(
              (w) => CesarText.fold(w) == name, orElse: () => name);
          others.add('${typed[0].toUpperCase()}${typed.substring(1)}');
        }
      }
      if (others.isNotEmpty && people == null) people = others.length + 1;
    }
    if (people == null || people < 2 || people > 50) return null;

    // The total: prefer numbers before "dividi", otherwise search `after` excluding
    // the people-count span so "dividimos em 3, o total deu 300" never grabs "3".
    final normalizedBefore = PtNumberWords.normalize(before);
    final sanitizedAfter = peopleMatchInAfter == null
        ? after
        : '${after.substring(0, peopleMatchInAfter.start)} ${after.substring(peopleMatchInAfter.end)}';
    final normalizedAfter = PtNumberWords.normalize(sanitizedAfter);

    double? total = _extractTotal(normalizedBefore) ?? _extractTotal(normalizedAfter);
    if (total == null || total <= 0) return null;

    final title = _extractTitle(before: before, after: after, full: s, originalText: text);
    final onlyMyShare = _onlyMyShareRe.hasMatch(s);
    return BillSplit(
      description: title,
      total: total,
      people: people,
      others: others,
      onlyMyShare: onlyMyShare,
    );
  }

  static double? _extractTotal(String fragment) {
    final matches = _value.allMatches(fragment).toList();
    for (var i = matches.length - 1; i >= 0; i--) {
      final m = matches[i];
      final parsed = LocalFinancialNlpEngine.parseBoundedAmount(
        m.group(1),
        before: fragment.substring(0, m.start),
      );
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  static String _extractTitle({
    required String before,
    required String after,
    required String full,
    required String originalText,
  }) {
    String? pickValid(String? raw) {
      if (raw == null) return null;
      var cleaned = raw
          .replaceAll(RegExp(r'\b(?:ontem|hoje|anteontem|agora|amanha)\b'), ' ')
          .replaceFirst(RegExp(r'^(?:o|a|os|as|um|uma|uns|umas)\s+'), '')
          .replaceFirst(RegExp(r'^(?:conta|total|valor|gasto)\s+(?:de|do|da|dos|das)\s+'), '')
          .replaceFirst(RegExp(r'\s+(?:(?:o\s+)?total|(?:a\s+)?conta|(?:o\s+)?valor)$'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleaned.isEmpty || _genericTitles.contains(cleaned)) return null;
      if (RegExp(r'^\d+$').hasMatch(cleaned)) return null;
      // If multi-word includes trailing "de ...", keep meaningful head ("pizza" from "pizza de 120").
      cleaned = cleaned.replaceFirst(RegExp(r'\s+de\s+\d.*$'), '').trim();
      if (cleaned.isEmpty || _genericTitles.contains(cleaned)) return null;
      return cleaned;
    }

    final candidates = <String?>[
      // 1. "o jantar deu 240", "a pizza foi 90" (rejects "o total deu 320")
      for (final m in RegExp(r'\b(?:o|a|um|uma)\s+([a-z0-9 ]+?)\s+(?:deu|foi|ficou|custou|saiu)\b').allMatches(before))
        m.group(1),
      // 2. "a conta do bar deu 200", "o total do jantar deu 320"
      for (final m in RegExp(r'\b(?:conta|total|valor|gasto)\s+(?:de|do|da|dos|das)\s+([a-z0-9 ]+?)(?:\s+(?:deu|foi|ficou|custou|saiu)|,|$)').allMatches(full))
        m.group(1),
      // 3. "fui em um jantar, o total deu 320", "fomos no outback ontem"
      for (final m in RegExp(
        r'\b(?:em|no|na|num|numa|do|da)\s+(?:um|uma)?\s*([a-z0-9 ]+?)(?=\s*(?:,|\.|;|$|\b(?:que|(?:e\s+)?(?:o\s+)?total|(?:e\s+)?(?:a\s+)?conta|(?:e\s+)?(?:o\s+)?valor|e\s+(?:deu|foi)|ontem|hoje|anteontem|deu|foi|ficou|custou|saiu)\b))',
      ).allMatches(before))
        m.group(1),
      // 4. "rachei uma pizza de 120 com mais 2", "dividimos um uber de 45 em 3"
      RegExp(r'^\s*(?:o|a|um|uma)?\s*([a-z0-9 ]+?)(?=\s*(?:\bde\s+(?:r\$\s*)?\d|\bcom\b|\bem\b|\bentre\b|\bpra\b|\bpara\b|,|$))')
          .firstMatch(after)
          ?.group(1),
    ];

    for (final raw in candidates) {
      final valid = pickValid(raw);
      if (valid != null) {
        return _restoreOriginalCasingAndAccents(valid, originalText);
      }
    }
    return 'Conta dividida';
  }

  static String _restoreOriginalCasingAndAccents(String folded, String originalText) {
    final origWords = originalText.split(RegExp(r'[^\p{L}0-9-]+', unicode: true)).where((w) => w.isNotEmpty).toList();
    final parts = folded.split(' ');
    final out = <String>[];
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      final orig = origWords.firstWhere((w) => CesarText.fold(w) == p, orElse: () => p);
      if (i == 0) {
        out.add('${orig[0].toUpperCase()}${orig.substring(1)}');
      } else {
        out.add(orig.toLowerCase());
      }
    }
    return out.join(' ');
  }
}
