/// Short code shown on each transaction card ("#4821") so the user can point
/// at it later: "apaga o #4821", "o #4821 foi 50", "lançamento 4821".
///
/// Ids are millisecond timestamps, so their last 4 digits are effectively
/// unique in a person's history; when two do collide, the resolver finds both
/// and César asks which one. Ids that aren't numeric (demo data, "init-3")
/// use their digits, or the whole id.
class TransactionCode {
  TransactionCode._();

  static String of(String id) {
    final digits = id.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 4) return digits.substring(digits.length - 4);
    return digits.isNotEmpty ? digits : id.toUpperCase();
  }

  /// "#4821".
  static String label(String id) => '#${of(id)}';

  /// Whether [id] is the record the user called [code] ("4821", "#4821").
  static bool matches(String id, String code) {
    final c = code.replaceAll('#', '').trim();
    if (c.isEmpty) return false;
    return of(id) == c || (c.length >= 4 && id.endsWith(c));
  }

  /// The code said in [text], or null: "#4821", "# 4821", "id 4821",
  /// "código 4821", "lançamento 4821", "registro nº 4821".
  static String? find(String text) {
    final m = RegExp(r'#\s*(\d{1,13})\b').firstMatch(text) ??
        RegExp(r'\b(?:id|c[oó]digo|cod|lan[cç]amento|registro)\s+(?:n[ºo°.]?\s*|n[uú]mero\s+)?#?(\d{3,13})\b', caseSensitive: false)
            .firstMatch(text);
    return m?.group(1);
  }
}
