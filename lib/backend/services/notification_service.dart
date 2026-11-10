import 'package:flutter/material.dart';
import '../repositories/financial_repository.dart';
import 'money.dart';
import '../../frontend/theme/krezio_theme.dart';

enum KrezioNotificationKind {
  billReminder,
  receivableReminder,
  dailyTransactionLog,
}

class KrezioPushNotification {
  final String id;
  final String title;
  final String body;
  final KrezioNotificationKind kind;
  final DateTime scheduledAt;

  const KrezioPushNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.kind,
    required this.scheduledAt,
  });
}

/// Manages push/local notifications for app reminders (bills & receivables)
/// and daily reminders to log transactions in Krezio.ai.
class NotificationService {
  static const String prefRemindersPushEnabled = 'push_reminders_enabled';
  static const String prefDailyLogReminderEnabled = 'push_daily_log_enabled';
  static const String prefDailyLogReminderHour = 'push_daily_log_hour';
  static const String prefLastNotifiedDay = 'push_last_notified_day';

  final FinancialRepository repository;

  const NotificationService(this.repository);

  bool get remindersPushEnabled =>
      (repository.preference(prefRemindersPushEnabled) ?? 'true') == 'true';

  set remindersPushEnabled(bool value) =>
      repository.setPreference(prefRemindersPushEnabled, value ? 'true' : 'false', notify: true);

  bool get dailyLogReminderEnabled =>
      (repository.preference(prefDailyLogReminderEnabled) ?? 'true') == 'true';

  set dailyLogReminderEnabled(bool value) =>
      repository.setPreference(prefDailyLogReminderEnabled, value ? 'true' : 'false', notify: true);

  int get dailyLogReminderHour =>
      int.tryParse(repository.preference(prefDailyLogReminderHour) ?? '20') ?? 20;

  set dailyLogReminderHour(int hour) =>
      repository.setPreference(prefDailyLogReminderHour, hour.clamp(0, 23).toString(), notify: true);

  /// Evaluates all pending notifications for due/upcoming reminders and daily transaction logging.
  List<KrezioPushNotification> evaluatePendingNotifications({DateTime? now}) {
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    final notifications = <KrezioPushNotification>[];

    if (remindersPushEnabled) {
      for (final r in repository.reminders.where((r) => !r.isCompleted)) {
        final target = DateTime(r.targetDate.year, r.targetDate.month, r.targetDate.day);
        final diffDays = target.difference(today).inDays;
        if (diffDays <= 3) {
          final isReceivable = r.isReceivable;
          final valText = r.amount != null ? ' (${r.amountPrefix}${Money.brl(r.amount!)})' : '';
          final whenLabel = diffDays < 0
              ? 'está em atraso há ${-diffDays} dia(s)'
              : diffDays == 0
                  ? 'vence hoje!'
                  : diffDays == 1
                      ? 'vence amanhã'
                      : 'vence em $diffDays dias';
          notifications.add(
            KrezioPushNotification(
              id: 'push-rem-${r.id}',
              title: isReceivable ? 'Conta a Receber 💰' : 'Lembrete de Pagamento 🔔',
              body: '${r.title}$valText $whenLabel.',
              kind: isReceivable
                  ? KrezioNotificationKind.receivableReminder
                  : KrezioNotificationKind.billReminder,
              scheduledAt: current,
            ),
          );
        }
      }
    }

    if (dailyLogReminderEnabled) {
      final loggedToday = repository.transactions.any((t) =>
          t.date.year == today.year &&
          t.date.month == today.month &&
          t.date.day == today.day);
      if (!loggedToday) {
        notifications.add(
          KrezioPushNotification(
            id: 'push-daily-log-${today.toIso8601String().substring(0, 10)}',
            title: 'Hora de registrar seus lançamentos 📝',
            body: 'Ainda não vimos lançamentos hoje. Conte para o César seus gastos ou receitas do dia!',
            kind: KrezioNotificationKind.dailyTransactionLog,
            scheduledAt: DateTime(today.year, today.month, today.day, dailyLogReminderHour),
          ),
        );
      }
    }

    return notifications;
  }

  /// Dispatches a visible push notification banner in the app if not yet shown today,
  /// or immediately when [force] is true.
  void dispatchIfDue(BuildContext context, {bool force = false}) {
    final now = DateTime.now();
    final dayKey = '${now.year}-${now.month}-${now.day}';
    if (!force && repository.preference(prefLastNotifiedDay) == dayKey) {
      return;
    }

    final pending = evaluatePendingNotifications(now: now);
    if (pending.isEmpty && !force) return;

    repository.setPreference(prefLastNotifiedDay, dayKey);
    final first = pending.isNotEmpty
        ? pending.first
        : KrezioPushNotification(
            id: 'push-test',
            title: 'Notificações Push Krezio Ativas 🔔',
            body: 'Você receberá alertas dos seus lembretes e aviso diário às ${dailyLogReminderHour.toString().padLeft(2, '0')}:00 para fazer lançamentos.',
            kind: KrezioNotificationKind.dailyTransactionLog,
            scheduledAt: now,
          );

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        backgroundColor: KrezioColors.darkSurface,
        content: Row(
          children: [
            const Icon(Icons.notifications_active, color: KrezioColors.emeraldGreen, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    first.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                  ),
                  Text(
                    first.body,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
