import 'cesar_text.dart';
import 'local_nlp_engine.dart';
import 'pt_number_words.dart';

enum CategoryCommandKind { create, rename, delete, setLimit, moveAll }

/// "cria a categoria Pets com limite de 200", "renomeia a categoria pets
/// para animais", "apaga a categoria pets", "meu limite de lazer é 800 por
/// mês", "move tudo de pets para animais". Names keep the user's spelling.
class CategoryCommand {
  final CategoryCommandKind kind;

  /// The category named (as typed): the one created, renamed, removed…
  final String name;

  /// rename: the new name; moveAll: the destination category.
  final String? target;
  final double? limit;

  const CategoryCommand(this.kind, this.name, {this.target, this.limit});

  @override
  String toString() => 'CategoryCommand($kind, "$name", target=$target, limit=$limit)';
}

/// Parses chat commands that manage categories and budgets. Pure; the
/// assistant applies them to the repository.
class CategoryCommandParser {
  CategoryCommandParser._();

  static const _num = r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s*(mil|k)?';

  static double? _amount(RegExpMatch m, int group) {
    var v = LocalFinancialNlpEngine.cleanAndParseAmount(m.group(group));
    if (v != null && m.group(group + 1) != null) v *= 1000;
    return v;
  }

  /// Text in the user's spelling for a span of the folded text (fold keeps
  /// length, so indexes line up).
  static String _orig(String lowerOriginal, String folded, int start, int end) {
    if (lowerOriginal.length != folded.length) return folded.substring(start, end).trim();
    return lowerOriginal.substring(start, end).trim();
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _cleanName(String s) => s
      .replaceAll(RegExp(r'''^["'“]+|["'”.!?]+$'''), '')
      .replaceFirst(RegExp(r'^(?:a|o|de|da|do)\s+', caseSensitive: false), '')
      .trim();

  static CategoryCommand? parse(String text) {
    final raw = PtNumberWords.normalize(text.trim());
    // Punctuation → spaces, without changing the length (so spans map back).
    final lower = raw.toLowerCase().replaceAll(RegExp(r'[?!;:]'), ' ');
    final f = CesarText.fold(lower);
    // Dart has no group offsets: locate the group's text inside the match
    // (from the end for the last group, e.g. the new name after "para").
    String orig(RegExpMatch m, int g) {
      final text = m.group(g)!;
      final last = g == m.groupCount || m.group(g + 1) == null;
      final start = last ? f.lastIndexOf(text, m.end - text.length) : f.indexOf(text, m.start);
      if (start < 0) return _cleanName(text);
      return _cleanName(_orig(lower, f, start, start + text.length));
    }

    final create = RegExp(r'^\s*(?:(?:voce\s+)?(?:pode\s+)?(?:cria|crie|criar|adiciona|adicione|cadastra|cadastre|faz|faca|abre|abra)|quero\s+(?:criar|uma|um)|nova)\s+'
            r'(?:uma\s+|a\s+)?(?:nova\s+)?categoria\s+(?:nova\s+)?(?:chamada\s+|com\s+o\s+nome\s+(?:de\s+)?|de\s+nome\s+|pra\s+|para\s+|de\s+)?(.+?)'
            r'(?:\s*,?\s+(?:com|de)\s+(?:um\s+)?(?:limite|orcamento|teto)(?:\s+mensal)?\s+(?:de\s+)?(?:r\$\s*)?' + _num + r'(?:\s+(?:reais|por\s+mes|ao\s+mes|mensais))*)?\s*$')
        .firstMatch(f);
    if (create != null) {
      final name = orig(create, 1);
      if (name.isEmpty || RegExp(r'\d').hasMatch(name)) return null;
      return CategoryCommand(CategoryCommandKind.create, _capitalize(name), limit: create.group(2) == null ? null : _amount(create, 2));
    }

    final rename = RegExp(r'^\s*(?:renomeia|renomeie|renomear|muda\s+o\s+nome\s+da|mude\s+o\s+nome\s+da|troca\s+o\s+nome\s+da|troque\s+o\s+nome\s+da|altera\s+o\s+nome\s+da)\s+'
            r'(?:a\s+)?categoria\s+(.+?)\s+(?:pra|para|por|como)\s+(.+?)\s*$')
        .firstMatch(f);
    if (rename != null) {
      return CategoryCommand(CategoryCommandKind.rename, orig(rename, 1), target: _capitalize(orig(rename, 2)));
    }

    final delete = RegExp(r'^\s*(?:apaga|apague|apagar|exclui|exclua|excluir|remove|remova|remover|deleta|delete|deletar|tira|tire)\s+(?:a\s+)?categoria\s+(.+?)\s*$')
        .firstMatch(f);
    if (delete != null) return CategoryCommand(CategoryCommandKind.delete, orig(delete, 1));

    final move = RegExp(r'^\s*(?:move|mova|mover|passa|passe|transfere|transfira|joga)\s+(?:tudo|todos(?:\s+os\s+lancamentos)?|os\s+lancamentos)\s+(?:de|da|do)\s+'
            r'(?:categoria\s+)?(.+?)\s+(?:pra|para|pro)\s+(?:a\s+)?(?:categoria\s+)?(.+?)\s*$')
        .firstMatch(f);
    if (move != null) return CategoryCommand(CategoryCommandKind.moveAll, orig(move, 1), target: orig(move, 2));

    // Budget limit: "meu limite de lazer é 800 por mês", "define orçamento de
    // mercado em 1000", "aumenta o limite de mercado pra 1500".
    final limitA = RegExp(r'^\s*(?:o\s+)?(?:meu\s+)?(?:limite|orcamento|teto)(?:\s+mensal)?\s+(?:de|do|da|com|pra|para)\s+(.+?)\s+'
            r'(?:e|eh|sera|vai\s+ser|fica|passa\s+a\s+ser|agora\s+e|de|:)\s+(?:de\s+)?(?:r\$\s*)?' + _num + r'(?:\s+(?:reais|por\s+mes|ao\s+mes|mensais|no\s+mes))*\s*$')
        .firstMatch(f);
    final limitB = RegExp(r'^\s*(?:define|defina|definir|coloca|coloque|poe|bota|muda|mude|altera|altere|aumenta|aumente|diminui|diminua|reduz|reduza|ajusta|ajuste|atualiza|atualize|seta|sete)\s+'
            r'(?:o\s+|um\s+)?(?:meu\s+)?(?:limite|orcamento|teto)(?:\s+mensal)?\s+(?:de|do|da|com|pra|para)\s+(.+?)\s+(?:em|pra|para|como|de|por)\s+(?:r\$\s*)?' + _num +
            r'(?:\s+(?:reais|por\s+mes|ao\s+mes|mensais|no\s+mes))*\s*$')
        .firstMatch(f);
    final limitC = RegExp(r'^\s*(?:quero\s+gastar|vou\s+gastar)\s+(?:no\s+maximo|ate)\s+(?:r\$\s*)?' + _num + r'(?:\s+reais)?\s+(?:com|de|em|no|na)\s+(.+?)(?:\s+(?:por|ao|no)\s+mes)?\s*$')
        .firstMatch(f);
    if (limitA != null || limitB != null) {
      final m = (limitA ?? limitB)!;
      final v = _amount(m, 2);
      if (v == null) return null;
      return CategoryCommand(CategoryCommandKind.setLimit, orig(m, 1), limit: v);
    }
    if (limitC != null) {
      final v = _amount(limitC, 1);
      if (v == null) return null;
      return CategoryCommand(CategoryCommandKind.setLimit, orig(limitC, 3), limit: v);
    }
    return null;
  }
}
