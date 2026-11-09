import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import '../../../ai/cesar_text.dart';
import '../../../backend/repositories/financial_repository.dart';

/// Keeps the Android home screen widget (saldo do mês + "Falar com o César")
/// up to date after every change in the data.
class HomeWidgetSync {
  static const _provider = 'com.krezio.ai.KrezioWidgetProvider';
  static Future<void> _writes = Future.value();

  final FinancialRepository repository;
  bool _active = false;
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
    if (!supported || _active) return;
    _active = true;
    repository.addListener(_push);
    _push();
  }

  void stop() {
    _active = false;
    repository.removeListener(_push);
  }

  static Future<void> clear() {
    if (!supported) return Future.value();
    return _enqueue(() => _update('—', 'Abra o app para ver seus dados'));
  }

  void _push() => _enqueue(() async {
        if (!_active) return;
        final v = values(repository);
        await _update(v.balance, v.detail);
      });

  static Future<void> _enqueue(Future<void> Function() write) {
    return _writes = _writes.then((_) => write()).catchError((Object error) {
      debugPrint('[HomeWidgetSync] $error');
    });
  }

  static Future<void> _update(String balance, String detail) async {
    await HomeWidget.saveWidgetData<String>('month_balance', balance);
    await HomeWidget.saveWidgetData<String>('month_detail', detail);
    await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
  }
}
