import 'cesar_text.dart';
import 'pt_number_words.dart';

/// "o jantar deu 240, dividi com mais 3" → my part 60, 180 to receive.
class BillSplit {
  final String description;
  final double total;

  /// People, me included.
  final int people;

  /// Names of the others, when said ("dividi com o joão e a ana").
  final List<String> others;

  const BillSplit({required this.description, required this.total, required this.people, this.others = const []});

  double get myShare => (total * 100 / people).round() / 100;
  double get toReceive => total - myShare;
  double get perPerson => myShare;
}

/// Reads a split bill from a sentence. Pure Dart.
class BillSplitParser {
  BillSplitParser._();

  static final _value = RegExp(r'(?:r\s*\$?\s*)?(\d+(?:[.,]\d{1,2})?)');

  static BillSplit? parse(String text) {
    final s = CesarText.simplify(text);
    // Only a split that happened ("dividi", "rachamos"): "vou dividir" is a
    // plan, and "dividi em 3x no cartão" is an installment, not people.
    final split = RegExp(r'\b(?:dividi|dividimos|rachei|rachamos|racharam|dividiram)\b').firstMatch(s);
    if (split == null) return null;
    if (RegExp(r'\b\d+\s*x\b|\bvezes\b|\bparcel\w*|\bprestac\w*').hasMatch(s)) return null;

    // How many people: "com mais 3", "em 4", "entre 4 pessoas", "com o joão e a ana".
    int? people;
    final more = RegExp(r'\bcom\s+mais\s+(\w+)').firstMatch(s);
    final among = RegExp(r'\b(?:em|entre|por|pra|para)\s+(\w+)\s*(?:pessoas|amigos|pessoa)?\b').firstMatch(s.substring(split.end));
    if (more != null) {
      final n = PtNumberWords.parse(more.group(1)!) ?? int.tryParse(more.group(1)!);
      if (n != null) people = n.toInt() + 1;
    } else if (among != null) {
      final n = PtNumberWords.parse(among.group(1)!) ?? int.tryParse(among.group(1)!);
      if (n != null) people = n.toInt();
    }
    final others = <String>[];
    if (people == null) {
      final names = RegExp(r'\bcom\s+(?:o|a|os|as)?\s*([a-z]+(?:\s*(?:,|e)\s*(?:o|a)?\s*[a-z]+)*)').firstMatch(s.substring(split.end));
      if (names != null) {
        for (final n in names.group(1)!.split(RegExp(r'\s*(?:,|\be\b)\s*'))) {
          final name = n.replaceFirst(RegExp(r'^(?:o|a)\s+'), '').trim();
          if (name.isNotEmpty && !const {'mais', 'todo', 'todos', 'galera', 'pessoal', 'amigos'}.contains(name)) {
            // Keep the spelling the user typed ("joão", not "joao").
            final typed = text.split(RegExp(r'[^\p{L}]+', unicode: true)).firstWhere(
                (w) => CesarText.fold(w) == name, orElse: () => name);
            others.add(typed[0].toUpperCase() + typed.substring(1));
          }
        }
        if (others.isNotEmpty) people = others.length + 1;
      }
    }
    if (people == null || people < 2 || people > 50) return null;

    // The total: the value before "dividi" (or anywhere).
    final before = s.substring(0, split.start);
    final m = _value.allMatches(before).lastOrNull ?? _value.firstMatch(s.substring(split.end));
    if (m == null) return null;
    final total = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    if (total == null || total <= 0) return null;

    final what = RegExp(r'\b(?:o|a)\s+([a-z ]+?)\s+(?:deu|foi|ficou|custou|saiu)\b').firstMatch(before)?.group(1)?.trim() ??
        RegExp(r'\b(?:no|na|do|da)\s+([a-z ]+?)(?:\s+(?:deu|foi|ficou|custou|saiu)|,|$)').firstMatch(before)?.group(1)?.trim() ??
        'Conta dividida';
    final title = what[0].toUpperCase() + what.substring(1);
    return BillSplit(description: title, total: total, people: people, others: others);
  }
}
