import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import '../../../ai/cesar_text.dart';
import '../../../backend/repositories/financial_repository.dart';

/// Keeps the Android home screen widget (saldo do mês + "Falar com o César")
/// up to date after every change in the data.
class HomeWidgetSync {
  static const _provider = 'com.krezio.ai.KrezioWidgetProvider';

  final FinancialRepository repository;
  HomeWidgetSync(this.repository);

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// What the widget shows.
  static ({String balance, String detail}) values(FinancialRepository r) {
    final income = r.monthIncome;
    final expense = r.monthExpense;
    return (
      balance: CesarText.money(income - expense),
      detail: 'Entradas ${CesarText.money(income)} · Saídas ${CesarText.money(expense)}',
    );
  }

  void start() {
    if (!supported) return;
    repository.addListener(_push);
    _push();
  }

  void stop() => repository.removeListener(_push);

  Future<void> _push() async {
    final v = values(repository);
    try {
      await HomeWidget.saveWidgetData<String>('month_balance', v.balance);
      await HomeWidget.saveWidgetData<String>('month_detail', v.detail);
      await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
    } catch (e) {
      debugPrint('[HomeWidgetSync] $e');
    }
  }
}
