import 'dart:convert';

import 'package:http/http.dart' as http;

/// Currencies a transaction can be recorded in; totals are always in reais.
class Currencies {
  Currencies._();

  static const String base = 'BRL';
  static const Map<String, String> symbols = {'BRL': 'R\$', 'USD': 'US\$', 'EUR': '€', 'GBP': '£', 'ARS': 'AR\$'};
  static const Map<String, String> names = {
    'BRL': 'Real',
    'USD': 'Dólar',
    'EUR': 'Euro',
    'GBP': 'Libra',
    'ARS': 'Peso argentino',
  };

  /// "US$ 20,00".
  static String format(String currency, double value) =>
      '${symbols[currency] ?? currency} ${value.toStringAsFixed(2).replaceAll('.', ',')}';

  /// Value in reais of [amount] in a currency at [rate] (reais per unit),
  /// rounded to cents.
  static double toBase(double amount, double rate) => (amount * rate * 100).round() / 100;
}

/// The day's exchange rate (reais per unit), from a public quote service.
/// The rate used is stored with the transaction, so totals never change when
/// the rate does. Offline, the user types the rate.
class CurrencyService {
  final http.Client _client;
  CurrencyService({http.Client? client}) : _client = client ?? http.Client();

  /// Reais per one unit of [currency], or null (offline, unknown currency).
  Future<double?> rateToBrl(String currency) async {
    if (currency == Currencies.base) return 1;
    try {
      final res = await _client
          .get(Uri.parse('https://economia.awesomeapi.com.br/json/last/$currency-BRL'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final quote = data['${currency}BRL'] as Map<String, dynamic>?;
      return double.tryParse('${quote?['bid']}');
    } catch (_) {
      return null;
    }
  }
}
