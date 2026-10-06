/// Matches spoken/typed words against user-created category names, forgiving
/// accents, case and singular/plural ("roupa" ↔ "Roupas", "funcionário" ↔
/// "Funcionários"). Pure Dart so both the NLP engine and the repository can
/// use it without pulling in Flutter.
class CategoryNameMatcher {
  CategoryNameMatcher._();

  static const _from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  static const _to = 'aaaaaeeeeiiiiooooouuuucn';

  static String foldAccents(String text) {
    var result = text;
    for (var i = 0; i < _from.length; i++) {
      result = result.replaceAll(_from[i], _to[i]);
    }
    return result;
  }

  /// Lowercased, accent-free tokens with a plural "s"/"es" dropped, so
  /// "Roupas" and "roupa" produce the same key.
  static List<String> tokens(String text) {
    return foldAccents(text.toLowerCase())
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .map(_singular)
        .toList();
  }

  static String _singular(String token) {
    if (token.length > 4 && token.endsWith('oes')) return '${token.substring(0, token.length - 3)}ao';
    if (token.length > 4 && (token.endsWith('res') || token.endsWith('zes'))) return token.substring(0, token.length - 2);
    if (token.length > 3 && token.endsWith('s')) return token.substring(0, token.length - 1);
    return token;
  }

  /// Whether [name] and [other] are the same category name once normalized.
  static bool sameName(String name, String other) {
    final a = tokens(name);
    return a.isNotEmpty && a.join(' ') == tokens(other).join(' ');
  }

  /// Store-name endings glued to a word: "petshop" is a shop for pets.
  static const _shopSuffixes = {'shop', 'store', 'center', 'house', 'mania', 'point'};

  /// Whether the (normalized) [token] is [name] glued to a store ending —
  /// "petshop" for "pet". Only those endings count, so "casamento" is not
  /// "casa" and "carrossel" is not "carro".
  static bool isCompoundOf(String token, String name) {
    if (name.length < 3 || token.length <= name.length || !token.startsWith(name)) return false;
    final rest = token.substring(name.length);
    return _shopSuffixes.contains(rest) || _shopSuffixes.contains(_singular(rest));
  }

  /// Whether [text] mentions [name] as a whole-word sequence, e.g.
  /// "comprei ração pro pet" mentions "Pets".
  static bool mentions(String text, String name) {
    final needle = tokens(name);
    if (needle.isEmpty) return false;
    final hay = tokens(text);
    if (needle.length == 1 && hay.any((t) => isCompoundOf(t, needle.first))) return true;
    for (var i = 0; i + needle.length <= hay.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }
}
