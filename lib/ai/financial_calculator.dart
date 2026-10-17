import 'dart:math';

import 'cesar_text.dart';
import 'pt_number_words.dart';

/// An answer of the calculator: chat text, spoken version, route name.
class CalcAnswer {
  final String text;
  final String spokenText;
  final String route;
  const CalcAnswer(this.text, this.route, {String? spoken}) : spokenText = spoken ?? text;
}

/// The money math people ask a friend who is good with numbers: a share
/// ("quanto é 15% de 230?"), a discount or a raise ("230 com 15% de
/// desconto"), what share one value is of another, how much a change was in
/// percent, installments with interest (Price table), paying in cash with a
/// discount × in installments with no interest, how much a value or a monthly
/// deposit grows, and the four operations ("quanto é 1250 dividido por 4?").
/// Nothing is recorded; every answer shows the math. Pure Dart.
class FinancialCalculator {
  FinancialCalculator._();

  /// Yield used when the user doesn't say one: about 0.8% a month, close to
  /// what a bond tied to the Selic pays.
  static const defaultMonthlyRate = 0.008;

  static const _num = r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)(\s*mil)?';
  static const _pct = r'(\d+(?:[.,]\d+)?)\s*(?:%|por\s*cento)';
  static const _rateUnit = r'(?:\s*(ao\s+mes|a\s*m|mensal|por\s+mes|ao\s+ano|a\s*a|anual|por\s+ano))?';

  /// Asks for a result ("quanto é", "calcula", "dá quanto", a "?").
  static final _asks = RegExp(r'\b(?:quanto|quantos|qual|calcula|calcule|calcular|faz\s+a\s+conta|faca\s+a\s+conta|da\s+quanto|fica\s+quanto|vale\s+(?:mais\s+)?a\s+pena|compensa|melhor)\b');

  static double _value(String digits, String? thousand) {
    final raw = digits.contains(RegExp(r'\.\d{3}')) ? digits.replaceAll('.', '').replaceAll(',', '.') : digits.replaceAll(',', '.');
    final v = double.parse(raw);
    return thousand != null && thousand.trim().isNotEmpty ? v * 1000 : v;
  }

  static double _rate(String digits) => double.parse(digits.replaceAll(',', '.')) / 100;

  /// The monthly rate of [rate] said per [unit] ("ao ano" → compounded down).
  static double _monthly(double rate, String? unit) {
    if (unit != null && RegExp(r'ano|a\s*a|anual').hasMatch(unit)) return pow(1 + rate, 1 / 12) - 1;
    return rate;
  }

  static String _m(double v) => CesarText.money(v);
  static String _p(double ratio, {int decimals = 1}) {
    final v = ratio * 100;
    final s = (v - v.roundToDouble()).abs() < 0.05 ? v.round().toString() : v.toStringAsFixed(decimals).replaceAll('.', ',');
    return '$s%';
  }

  /// The answer to [text], or null when it isn't a calculation.
  static CalcAnswer? answer(String text) {
    final s = PtNumberWords.normalize(CesarText.simplify(text)).replaceAll(r'r$', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!RegExp(r'\d').hasMatch(s)) return null;
    final asks = _asks.hasMatch(s) || text.trim().endsWith('?');
    if (!asks) return null;
    return _cashOrInstallments(s) ??
        _installmentsWithInterest(s) ??
        _monthlyGrowth(s) ??
        _lumpGrowth(s) ??
        _shareOf(s) ??
        _changeInPercent(s) ??
        _withPercent(s) ??
        _percentOf(s) ??
        _arithmetic(s);
  }

  /// "quanto é 15% de 230?"
  static CalcAnswer? _percentOf(String s) {
    final m = RegExp('$_pct\\s+(?:de|do|da|sobre|em\\s+cima\\s+de)\\s+$_num').firstMatch(s);
    if (m == null) return null;
    final r = _rate(m.group(1)!), base = _value(m.group(2)!, m.group(3));
    final t = '${m.group(1)!}% de ${_m(base)} = **${_m(base * r)}**.';
    return CalcAnswer('🧮 $t', 'calc', spoken: t.replaceAll('**', ''));
  }

  /// "230 com 15% de desconto", "230 mais 10%", "1200 com 5% de juros".
  static CalcAnswer? _withPercent(String s) {
    final m = RegExp('$_num\\s+(com|mais|menos|\\+|-)\\s+(?:um\\s+|uma\\s+)?$_pct(?:\\s+de\\s+(desconto|juros|acrescimo|aumento|taxa|reajuste|gorjeta|servico))?')
        .firstMatch(s);
    if (m == null) return null;
    final base = _value(m.group(1)!, m.group(2));
    final op = m.group(3)!;
    final r = _rate(m.group(4)!);
    final kind = m.group(5);
    final bool down;
    if (op == 'menos' || op == '-') {
      down = true;
    } else if (op == 'com') {
      if (kind == null) return null; // "com 15%" says neither way
      down = kind == 'desconto';
    } else {
      down = false;
    }
    final result = down ? base * (1 - r) : base * (1 + r);
    final what = down ? 'desconto de ${_m(base * r)}' : 'acréscimo de ${_m(base * r)}';
    final t = '${_m(base)} ${down ? '−' : '+'} ${m.group(4)!}% = **${_m(result)}** ($what).';
    return CalcAnswer('🧮 $t', 'calc', spoken: t.replaceAll('**', ''));
  }

  /// "45 é quantos % de 300?"
  static CalcAnswer? _shareOf(String s) {
    final m = RegExp('$_num\\s+(?:e|eh|representa|equivale\\s+a|da)\\s+quant[oa]s?\\s+(?:%|por\\s*cento)\\s+(?:de|do|da)\\s+$_num').firstMatch(s) ??
        RegExp('(?:quanto|qual)\\s+(?:por\\s*cento|%|e\\s+a\\s+porcentagem)\\s+(?:e\\s+|de\\s+)?$_num\\s+(?:de|do|da|em)\\s+$_num').firstMatch(s);
    if (m == null) return null;
    final part = _value(m.group(1)!, m.group(2)), whole = _value(m.group(3)!, m.group(4));
    if (whole == 0) return null;
    final t = '${_m(part)} é **${_p(part / whole)}** de ${_m(whole)}.';
    return CalcAnswer('🧮 $t', 'calc', spoken: t.replaceAll('**', ''));
  }

  /// "de 200 pra 250 é quanto por cento?", "subiu de 55,90 pra 59,90, quanto % foi?"
  static CalcAnswer? _changeInPercent(String s) {
    if (!RegExp(r'%|por\s*cento|porcentagem|percentual').hasMatch(s)) return null;
    final m = RegExp('\\bde\\s+$_num\\s+(?:pra|para|a)\\s+$_num').firstMatch(s);
    if (m == null) return null;
    final from = _value(m.group(1)!, m.group(2)), to = _value(m.group(3)!, m.group(4));
    if (from == 0) return null;
    final change = to / from - 1;
    final word = change >= 0 ? 'aumento' : 'queda';
    final t = 'De ${_m(from)} para ${_m(to)}: **${change >= 0 ? '+' : '−'}${_p(change.abs())}** ($word de ${_m((to - from).abs())}).';
    return CalcAnswer('🧮 $t', 'calc', spoken: t.replaceAll('**', ''));
  }

  /// "quanto fica 2000 em 12x com juros de 2% ao mês?"
  static CalcAnswer? _installmentsWithInterest(String s) {
    final m = RegExp('$_num\\s+(?:reais\\s+)?(?:em|parcelad[oa]s?\\s+em|dividid[oa]s?\\s+em)\\s+(\\d{1,3})\\s*(?:x|vezes|parcelas|meses)\\s+'
            '(?:com|a)\\s+(?:juros\\s+de\\s+|taxa\\s+de\\s+|juros\\s+)?$_pct$_rateUnit')
        .firstMatch(s);
    if (m == null) return null;
    final principal = _value(m.group(1)!, m.group(2));
    final n = int.parse(m.group(3)!);
    final i = _monthly(_rate(m.group(4)!), m.group(5));
    if (n <= 0 || principal <= 0) return null;
    final parcel = i == 0 ? principal / n : principal * i / (1 - pow(1 + i, -n));
    final total = parcel * n;
    final interest = total - principal;
    final t = 'Em ${n}x com juros de ${_p(i, decimals: 2)} ao mês, a parcela fica **${_m(parcel)}**: total de ${_m(total)} — '
        '${_m(interest)} de juros (${_p(interest / principal)} a mais).';
    return CalcAnswer('🧮 $t\n\n_Tabela Price (parcelas iguais)._', 'calc', spoken: t.replaceAll('**', ''));
  }

  /// Present value of [n] installments of [parcel], the first one in a month,
  /// money that could yield [rate] a month meanwhile.
  static double _presentValue(double parcel, int n, double rate) => parcel * (1 - pow(1 + rate, -n)) / rate;

  /// "1000 à vista com 10% de desconto ou em 10x sem juros?", "à vista 900
  /// ou 10x de 100?"
  static CalcAnswer? _cashOrInstallments(String s) {
    if (!RegExp(r'\ba\s+vista\b|\bavista\b').hasMatch(s) || !RegExp(r'\d\s*x\b|\d+\s+(?:vezes|parcelas)\b').hasMatch(s)) return null;
    if (!RegExp(r'\bou\b|\bvs\b|\bversus\b|compensa|vale\s+(?:mais\s+)?a\s+pena|melhor').hasMatch(s)) return null;
    final count = RegExp(r'(\d{1,3})\s*(?:x|vezes|parcelas)\b').firstMatch(s);
    if (count == null) return null;
    final n = int.parse(count.group(1)!);
    if (n < 2) return null;
    double? cash, parcel, price;
    final parcelSaid = RegExp('(\\d{1,3})\\s*(?:x|vezes|parcelas)\\s+de\\s+$_num').firstMatch(s);
    if (parcelSaid != null) parcel = _value(parcelSaid.group(2)!, parcelSaid.group(3));
    final discount = RegExp('$_pct\\s+de\\s+desconto').firstMatch(s);
    final cashSaid = RegExp('\\ba\\s+vista\\s+(?:por\\s+|de\\s+|a\\s+|sai\\s+|fica\\s+)?$_num(?!\\s*(?:%|por\\s*cento))').firstMatch(s) ??
        RegExp('$_num\\s+(?:reais\\s+)?a\\s+vista').firstMatch(s);
    // The price: a value not of the installments nor the discount ("1000 à vista com 10%…").
    for (final v in RegExp(_num).allMatches(s)) {
      final at = v.start;
      if (parcelSaid != null && at >= parcelSaid.start && at < parcelSaid.end) continue;
      if (discount != null && at >= discount.start && at < discount.end) continue;
      if (at == count.start) continue;
      price ??= _value(v.group(1)!, v.group(2));
    }
    if (discount != null) {
      final base = price ?? (parcel != null ? parcel * n : null);
      if (base == null) return null;
      cash = base * (1 - _rate(discount.group(1)!));
      parcel ??= base / n;
    } else if (cashSaid != null) {
      cash = _value(cashSaid.group(1)!, cashSaid.group(2));
      if (parcel == null) {
        // "à vista 900 ou 1000 em 10x": the other value is the installment total.
        final others = RegExp(_num).allMatches(s).map((v) => _value(v.group(1)!, v.group(2))).where((v) => v != cash && v != n).toList();
        if (others.isEmpty) return null;
        parcel = others.first / n;
      }
    } else {
      return null;
    }
    if (cash <= 0 || parcel <= 0) return null;
    const i = defaultMonthlyRate;
    final pv = _presentValue(parcel, n, i);
    final total = parcel * n;
    final cashWins = cash <= pv;
    final diff = (pv - cash).abs();
    final verdict = cashWins
        ? '**à vista sai mais barato**: você economiza uns ${_m(diff)} em relação ao parcelado.'
        : '**o parcelado sai mais barato**: deixando o dinheiro rendendo enquanto paga, você ganha uns ${_m(diff)}.';
    final t = 'À vista: ${_m(cash)}. Parcelado: $n × ${_m(parcel)} = ${_m(total)}. Como o dinheiro parado renderia uns '
        '${_p(i)} ao mês, as parcelas valem hoje ${_m(pv)} — então $verdict';
    const caveat = '\n\n💡 Se pagar à vista tirar dinheiro da sua reserva de emergência, o parcelado sem juros pode ser mais seguro.';
    return CalcAnswer('🧮 $t$caveat', 'calc', spoken: t.replaceAll('**', ''));
  }

  static ({double rate, bool said}) _rateIn(String s) {
    final r = RegExp('(?:a|rendendo|com\\s+rendimento\\s+de|com\\s+juros\\s+de|com\\s+taxa\\s+de|que\\s+rende|rende|taxa\\s+de)\\s+$_pct$_rateUnit').firstMatch(s);
    if (r == null) return (rate: defaultMonthlyRate, said: false);
    return (rate: _monthly(_rate(r.group(1)!), r.group(2)), said: true);
  }

  static int? _months(String count, String unit) {
    final n = int.tryParse(count);
    if (n == null || n <= 0) return null;
    return unit.startsWith('ano') ? n * 12 : n;
  }

  /// "se eu investir 200 por mês por 5 anos, quanto vou ter?"
  static CalcAnswer? _monthlyGrowth(String s) {
    final m = RegExp('\\b(?:investir|investindo|aplicar|aplicando|guardar|guardando|poupar|poupando|depositar|depositando|juntar|juntando|colocar|colocando)\\s+'
            '$_num\\s*(?:reais\\s+)?(?:por|todo|ao|cada)\\s+mes\\s+(?:por|durante|em|ao\\s+longo\\s+de)\\s+(\\d{1,3})\\s+(anos?|meses)')
        .firstMatch(s);
    if (m == null) return null;
    final pmt = _value(m.group(1)!, m.group(2));
    final n = _months(m.group(3)!, m.group(4)!);
    if (n == null || pmt <= 0) return null;
    final rate = _rateIn(s);
    final i = rate.rate;
    final fv = i == 0 ? pmt * n : pmt * (pow(1 + i, n) - 1) / i;
    final put = pmt * n;
    final note = rate.said ? '' : '\n\n_Considerei ${_p(i)} ao mês, perto do que paga um título atrelado à Selic. Para outra taxa, diga, por exemplo, "a 1% ao mês"._';
    final t = 'Guardando ${_m(pmt)} por mês durante $n meses a ${_p(i, decimals: 2)} ao mês, você junta uns **${_m(fv)}**: '
        '${_m(put)} seus e ${_m(fv - put)} de rendimento.';
    return CalcAnswer('📈 $t$note', 'calc', spoken: t.replaceAll('**', ''));
  }

  /// "quanto rende 10 mil em 2 anos?"
  static CalcAnswer? _lumpGrowth(String s) {
    final m = RegExp('\\b(?:quanto\\s+(?:rende|renderia|vira|viraria|fica|ficaria|vai\\s+render)|rende\\s+quanto)\\s+(?:r\\s*)?$_num\\s*(?:reais\\s+)?'
            '(?:em|por|durante|depois\\s+de|apos)\\s+(\\d{1,3})\\s+(anos?|meses)')
        .firstMatch(s);
    if (m == null) return null;
    final p = _value(m.group(1)!, m.group(2));
    final n = _months(m.group(3)!, m.group(4)!);
    if (n == null || p <= 0) return null;
    final rate = _rateIn(s);
    final fv = p * pow(1 + rate.rate, n);
    final note = rate.said ? '' : '\n\n_Considerei ${_p(rate.rate)} ao mês, perto do que paga um título atrelado à Selic, antes do Imposto de Renda._';
    final t = '${_m(p)} rendendo ${_p(rate.rate, decimals: 2)} ao mês por $n meses viram **${_m(fv)}** — ${_m(fv - p)} de rendimento.';
    return CalcAnswer('📈 $t$note', 'calc', spoken: t.replaceAll('**', ''));
  }

  /// "quanto é 1250 dividido por 4?", "37 vezes 12".
  static CalcAnswer? _arithmetic(String s) {
    final m = RegExp('^(?:(?:quanto|qto)\\s+(?:e|eh|da|fica|deu|vai\\s+dar)|calcula|calcule|faz)\\s+$_num\\s*(mais|menos|vezes|x|\\*|dividido\\s+por|divido\\s+por|/|sobre|\\+|-)\\s*$_num\\s*\$')
        .firstMatch(s);
    if (m == null) return null;
    final a = _value(m.group(1)!, m.group(2)), b = _value(m.group(4)!, m.group(5));
    final op = m.group(3)!;
    double r;
    String sign;
    if (op == 'mais' || op == '+') {
      r = a + b;
      sign = '+';
    } else if (op == 'menos' || op == '-') {
      r = a - b;
      sign = '−';
    } else if (op == 'vezes' || op == 'x' || op == '*') {
      r = a * b;
      sign = '×';
    } else {
      if (b == 0) return const CalcAnswer('🧮 Não dá para dividir por zero. 🙂', 'calc');
      r = a / b;
      sign = '÷';
    }
    String fmt(double v) {
      final cents = (v * 100).round();
      final whole = cents % 100 == 0;
      return whole ? (cents ~/ 100).toString() : v.toStringAsFixed(2).replaceAll('.', ',');
    }

    final t = '${fmt(a)} $sign ${fmt(b)} = **${fmt(r)}**';
    return CalcAnswer('🧮 $t', 'calc', spoken: t.replaceAll('**', ''));
  }
}
