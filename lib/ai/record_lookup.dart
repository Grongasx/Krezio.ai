import 'cesar_text.dart';
import 'transaction_code.dart';

/// What the user wants to know about one record.
enum LookupAspect { all, amount, date, payment, category }

class RecordLookup {
  final LookupAspect aspect;

  /// The words naming the record ("o restaurante", "o uber de ontem", "#4821").
  final String reference;

  const RecordLookup(this.aspect, this.reference);
}

/// Questions about ONE saved record, so César can remember it and point at it:
/// "qual foi o valor do restaurante?", "quanto foi o uber de ontem?", "quando
/// foi a farmácia?", "como paguei o mercado?", "lembra do restaurante?",
/// "me mostra o #4821".
///
/// Totals stay with the Q&A engine: "quanto gastei com restaurante?" (a verb of
/// spending, "com") asks for a sum, not for a record. Pure Dart.
class RecordLookupParser {
  RecordLookupParser._();

  static const _article = r'(?:o|a|os|as|aquele|aquela|esse|essa)';

  static RecordLookup? parse(String text) {
    final s = CesarText.simplify(text).replaceFirst(RegExp(r'^(?:cesar\s+|ei\s+|e\s+ai\s+)+'), '');
    final hasCode = TransactionCode.find(text) != null;

    // "lembra do restaurante?", "você lembra da farmácia de ontem?"
    final remember = RegExp(r'^(?:(?:voce|vc|tu)\s+)?(?:se\s+)?lembra\s+(?:d[oa]s?|de)\s+(.+)$').firstMatch(s);
    if (remember != null) return RecordLookup(LookupAspect.all, remember.group(1)!);

    // "me mostra o restaurante", "mostra o #4821", "abre o lançamento 4821"
    final show = RegExp('^(?:me\\s+)?(?:mostra|mostre|abre|abra|ve|veja|exibe)\\s+($_article\\s+.+|#\\s*\\d+.*)\$').firstMatch(s);
    if (show != null && (hasCode || !RegExp(r'\b(?:gastos|despesas|lancamentos|receitas|extrato|grafico|resumo)\b').hasMatch(show.group(1)!))) {
      return RecordLookup(LookupAspect.all, show.group(1)!);
    }

    // "qual foi o valor do restaurante?", "qual a data da farmácia?"
    final field = RegExp('^(?:qual|quais)\\s+(?:foi|e|era)?\\s*(?:o|a)?\\s*(valor|preco|data|dia|forma\\s+de\\s+pagamento|pagamento|categoria)\\s+(?:d[oa]|de)\\s+(.+)\$')
        .firstMatch(s);
    // ("qual dia da semana eu mais gasto?" asks about a pattern, not a record.)
    if (field != null && !RegExp(r'^(?:semana|mes)\b').hasMatch(field.group(2)!)) return RecordLookup(_aspect(field.group(1)!), field.group(2)!);

    // "quanto foi o restaurante?", "quanto deu o uber de ontem?", "quanto custou a pizza?"
    final howMuch = RegExp('^quanto\\s+(?:foi|deu|custou|saiu|ficou)\\s+($_article\\s+.+)\$').firstMatch(s);
    if (howMuch != null) return RecordLookup(LookupAspect.amount, howMuch.group(1)!);

    // "quando foi o mercado?", "quando eu paguei o aluguel?"
    final when = RegExp('^quando\\s+(?:foi|(?:eu\\s+)?(?:paguei|comprei|gastei\\s+com|lancei))\\s+($_article\\s+.+)\$').firstMatch(s);
    // "quando foi a última vez que paguei aluguel?" asks the Q&A engine
    // ("última vez"), not about one record named here.
    // ("quando paguei a academia pela última vez?" asks the last of many —
    // the reports' "última vez".)
    if (when != null && !RegExp(r'^(?:a|o)\s+(?:ultima|ultimo|primeira|primeiro)\s+(?:vez|dia)').hasMatch(when.group(1)!) &&
        !RegExp(r'\b(?:ultima|primeira)\s+vez\b').hasMatch(s)) {
      return RecordLookup(LookupAspect.date, when.group(1)!);
    }

    // "como paguei o mercado?", "como foi pago o aluguel?"
    final how = RegExp('^como\\s+(?:(?:eu\\s+)?paguei|foi\\s+pag[oa])\\s+($_article\\s+.+)\$').firstMatch(s);
    if (how != null) return RecordLookup(LookupAspect.payment, how.group(1)!);

    // "o que foi o #4821?", "o #4821" alone.
    if (hasCode && RegExp(r'^(?:o\s+que\s+(?:foi|e)\s+)?(?:o\s+)?(?:lancamento\s+|registro\s+)?#?\s*\d+$').hasMatch(s.replaceAll('#', '').trim())) {
      return RecordLookup(LookupAspect.all, text);
    }
    return null;
  }

  static LookupAspect _aspect(String word) {
    if (word.startsWith('valor') || word.startsWith('preco')) return LookupAspect.amount;
    if (word == 'data' || word == 'dia') return LookupAspect.date;
    if (word.contains('pagamento')) return LookupAspect.payment;
    return LookupAspect.category;
  }
}
