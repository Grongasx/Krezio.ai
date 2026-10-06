import 'cesar_text.dart';
import 'local_nlp_engine.dart';
import 'pt_number_words.dart';

enum GoalCommandKind { contribute, withdraw, delete }

/// "coloquei mais 100 na viagem", "tira 50 da meta", "apaga a meta da viagem".
class GoalCommand {
  final GoalCommandKind kind;

  /// Words naming the goal ("viagem"); '' when the user said just "a meta".
  final String goalTerm;

  /// Whether the word "meta" was said — without it, the phrase is only a
  /// goal command if [goalTerm] matches an existing goal ("coloquei 50 no
  /// carro" with no goal "carro" is an ordinary expense).
  final bool saidMeta;
  final double? amount;

  const GoalCommand(this.kind, this.goalTerm, {required this.saidMeta, this.amount});

  @override
  String toString() => 'GoalCommand($kind, "$goalTerm", meta=$saidMeta, $amount)';
}

/// Goal contributions, withdrawals and deletion in free language, including
/// without the word "meta" (the goal is then recognized by its name). Pure;
/// [GoalParser] still handles creating goals.
class GoalCommandParser {
  GoalCommandParser._();

  static const _num = r'(?:r\$\s*)?(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s*(?:reais|real|conto|contos|pila)?';

  static GoalCommand? parse(String text) {
    if (text.trim().endsWith('?')) return null;
    final s = CesarText.simplify(PtNumberWords.normalize(text)).replaceFirst(RegExp(r'^(?:cesar\s+)?(?:eu\s+|ja\s+|hoje\s+)*'), '');
    final saidMeta = RegExp(r'\bmetas?\b').hasMatch(s);

    String clean(String? g) => (g ?? '')
        .replaceFirst(RegExp(r'^(?:(?:a|o|minha|meu|da|do|de|pra|para|na|no)\s+)*'), '')
        .replaceFirst(RegExp(r'^metas?\s*(?:(?:da|do|de|pra|para)\s+)?'), '')
        .replaceFirst(RegExp(r'^(?:(?:a|o|minha|meu)\s+)*'), '')
        .trim();

    final add = RegExp('^(?:guardei|coloquei|depositei|juntei|economizei|poupei|separei|botei|pus|adicionei|aportei|guarda|coloca|deposita|separa|bota|adiciona)'
            '\\s+(?:mais\\s+)?$_num\\s+(?:(?:na|no|pra|para|pro|em)\\s+)(.+)\$')
        .firstMatch(s);
    if (add != null) {
      final v = LocalFinancialNlpEngine.cleanAndParseAmount(add.group(1));
      if (v == null || v <= 0) return null;
      return GoalCommand(GoalCommandKind.contribute, clean(add.group(2)), saidMeta: saidMeta, amount: v);
    }

    final take = RegExp('^(?:tira|tire|tirei|retira|retire|retirei|saquei|saca|resgatei|resgata|resgate|peguei|usei)\\s+$_num\\s+(?:da|do|de)\\s+(.+)\$')
        .firstMatch(s);
    if (take != null) {
      final v = LocalFinancialNlpEngine.cleanAndParseAmount(take.group(1));
      if (v == null || v <= 0) return null;
      return GoalCommand(GoalCommandKind.withdraw, clean(take.group(2)), saidMeta: saidMeta, amount: v);
    }

    final del = RegExp(r'^(?:apaga|apague|exclui|exclua|remove|remova|deleta|delete|cancela|cancele|desiste\s+da|desisti\s+da)\s+(?:a\s+|minha\s+)*meta\b\s*(.*)$')
        .firstMatch(s);
    if (del != null) return GoalCommand(GoalCommandKind.delete, clean(del.group(1)), saidMeta: true);
    return null;
  }
}
