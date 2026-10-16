import '../models/financial_transaction.dart';

/// One deductible expense or income source line of the report.
class TaxLine {
  final String label;
  final double total;
  final int count;
  const TaxLine(this.label, this.total, this.count);
}

/// Help for the Imposto de Renda (IRPF) of a calendar year: deductible
/// expenses (health and education) and income per source. It only organizes
/// what the user recorded — the official rules and limits (education has a
/// yearly cap per person, health has none) are in the Receita Federal guide.
/// Pure Dart.
class TaxReport {
  final int year;
  final List<FinancialTransaction> health;
  final List<FinancialTransaction> education;
  final List<TaxLine> incomeBySource;

  const TaxReport._(this.year, this.health, this.education, this.incomeBySource);

  static const deductibleCategories = {'health': 'Saúde', 'education': 'Educação'};

  factory TaxReport.build(Iterable<FinancialTransaction> all, int year) {
    final ofYear = all.where((t) => t.date.year == year).toList()..sort((a, b) => a.date.compareTo(b.date));
    final health = ofYear.where((t) => t.type == TransactionType.expense && t.category == 'health').toList();
    final education = ofYear.where((t) => t.type == TransactionType.expense && t.category == 'education').toList();
    final sources = <String, List<FinancialTransaction>>{};
    for (final t in ofYear.where((t) => t.type == TransactionType.income)) {
      sources.putIfAbsent(_source(t.title), () => []).add(t);
    }
    final lines = [
      for (final e in sources.entries) TaxLine(e.key, e.value.fold(0.0, (a, t) => a + t.amount), e.value.length),
    ]..sort((a, b) => b.total.compareTo(a.total));
    return TaxReport._(year, health, education, lines);
  }

  /// "Salário Empresa X" and "salário empresa x" are the same source.
  static String _source(String title) {
    final t = title.trim();
    return t.isEmpty ? 'Outras receitas' : t[0].toUpperCase() + t.substring(1);
  }

  double get healthTotal => health.fold(0.0, (a, t) => a + t.amount);
  double get educationTotal => education.fold(0.0, (a, t) => a + t.amount);
  double get incomeTotal => incomeBySource.fold(0.0, (a, l) => a + l.total);

  static String _money(double v) => v.toStringAsFixed(2).replaceAll('.', ',');
  static String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  static String _cell(String v) => v.contains(';') || v.contains('"') ? '"${v.replaceAll('"', '""')}"' : v;

  /// The report as CSV for Excel (UTF-8 with BOM, ";", decimal comma).
  String toCsv() {
    final rows = <String>[
      'Relatório para o Imposto de Renda $year (Krezio.ai)',
      'Confira os limites e as regras no programa da Receita Federal.',
      '',
      'DESPESAS DEDUTÍVEIS',
      'Tipo;Data;Descrição;Valor',
      for (final t in health) 'Saúde;${_date(t.date)};${_cell(t.title)};${_money(t.amount)}',
      for (final t in education) 'Educação;${_date(t.date)};${_cell(t.title)};${_money(t.amount)}',
      'Total saúde;;;${_money(healthTotal)}',
      'Total educação;;;${_money(educationTotal)}',
      '',
      'RENDIMENTOS POR FONTE',
      'Fonte;Lançamentos;Total',
      for (final l in incomeBySource) '${_cell(l.label)};${l.count};${_money(l.total)}',
      'Total;;${_money(incomeTotal)}',
    ];
    return '﻿${rows.join('\r\n')}\r\n';
  }
}
