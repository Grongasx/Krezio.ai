import 'package:flutter/foundation.dart';

/// Categories of financial and personal calendar events
enum CalendarEventCategory {
  salary,
  dividend,
  loanReceivable,
  billPayment,
  personalReminder,
}

/// A calendar event consulted or scheduled by the Krezio AI
class CalendarEvent {
  final String id;
  final String title;
  final DateTime dateTime;
  final CalendarEventCategory category;
  final double? amount;
  final String? personName;
  final String? notes;
  final bool isAutomated;

  CalendarEvent({
    required this.id,
    required this.title,
    required this.dateTime,
    required this.category,
    this.amount,
    this.personName,
    this.notes,
    this.isAutomated = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'dateTime': dateTime.toIso8601String(),
    'category': category.name,
    'amount': amount,
    'personName': personName,
    'notes': notes,
    'isAutomated': isAutomated,
  };
}

/// Real-Time Calendar Service.
/// Computes actual business days, Brazilian bank holidays (FEBRABAN),
/// calculates the 5th business day for salary paydays, and manages scheduled reminders.
/// Ready to bridge into native Android/iOS calendar plugins in production.
class RealtimeCalendarService extends ChangeNotifier {
  static final RealtimeCalendarService _instance = RealtimeCalendarService._internal();
  factory RealtimeCalendarService() => _instance;

  RealtimeCalendarService._internal() {
    _seedDefaultEvents();
  }

  final List<CalendarEvent> _events = [];

  List<CalendarEvent> get events => List.unmodifiable(_events);

  /// Brazilian National & Bank Holidays (fixed and variable dates)
  static final Set<String> _fixedHolidays = {
    '01-01', // Confraternização Universal
    '04-21', // Tiradentes
    '05-01', // Dia do Trabalhador
    '09-07', // Independência do Brasil
    '10-12', // Nossa Senhora Aparecida
    '11-02', // Finados
    '11-15', // Proclamação da República
    '11-20', // Consciência Negra
    '12-25', // Natal
  };

  void _seedDefaultEvents() {
    final now = DateTime.now();
    final salaryDate = getFifthBusinessDay(DateTime(now.year, now.month));
    final dividendDate = DateTime(now.year, now.month, 15);

    _events.addAll([
      CalendarEvent(
        id: 'cal-seed-1',
        title: 'Previsão de Salário (5º Dia Útil)',
        dateTime: salaryDate,
        category: CalendarEventCategory.salary,
        notes: 'Data estimada legal para crédito salarial',
      ),
      CalendarEvent(
        id: 'cal-seed-2',
        title: 'Data Com / Pagamento Dividendos FIIs',
        dateTime: dividendDate,
        category: CalendarEventCategory.dividend,
        notes: 'Rendimento mensal de fundos imobiliários',
      ),
    ]);
  }

  /// Good Friday (Sexta-feira da Paixão) — a national holiday whose date
  /// follows Easter (Meeus/Jones/Butcher algorithm).
  static DateTime goodFriday(int year) {
    final a = year % 19;
    final b = year ~/ 100;
    final c = year % 100;
    final d = b ~/ 4;
    final e = b % 4;
    final f = (b + 8) ~/ 25;
    final g = (b - f + 1) ~/ 3;
    final h = (19 * a + b - d - g + 15) % 30;
    final i = c ~/ 4;
    final k = c % 4;
    final l = (32 + 2 * e + 2 * i - h - k) % 7;
    final m = (a + 11 * h + 22 * l) ~/ 451;
    final month = (h + l - 7 * m + 114) ~/ 31;
    final day = ((h + l - 7 * m + 114) % 31) + 1;
    return DateTime(year, month, day).subtract(const Duration(days: 2));
  }

  /// National holidays: the fixed dates plus Good Friday.
  static bool isHoliday(DateTime date) {
    final key = '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    if (_fixedHolidays.contains(key)) return true;
    final gf = goodFriday(date.year);
    return gf.month == date.month && gf.day == date.day;
  }

  /// A *bank* day (dia bancário): Monday to Friday, not a holiday. Banks
  /// don't clear on Saturdays — this is the notion for boletos/compensação.
  bool isBusinessDay(DateTime date) {
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      return false;
    }
    return !isHoliday(date);
  }

  /// A *working* day (dia útil) in the sense of "5º dia útil" for salary:
  /// Monday to **Saturday**, minus Sundays and holidays. That is how the CLT
  /// (art. 459) counts the payday, and what the user means by "dia útil" —
  /// November/2026 is 3, 4, 5, 6, 7 → the 5th is Saturday the 7th. The bank
  /// notion ([isBusinessDay]) is a different thing and is kept apart.
  static bool isWorkingDay(DateTime date) => date.weekday != DateTime.sunday && !isHoliday(date);

  /// The [n]-th working day ([isWorkingDay]: Saturday counts) of the month
  /// of [month] — "5º dia útil" lands on a different date every month.
  static DateTime nthBusinessDay(DateTime month, int n) {
    var count = 0;
    var current = DateTime(month.year, month.month, 1);
    while (current.month == month.month) {
      if (isWorkingDay(current) && ++count == n) return current;
      current = DateTime(current.year, current.month, current.day + 1);
    }
    return DateTime(month.year, month.month, n.clamp(1, 28));
  }

  /// The next [n]-th working day on or after [referenceDate] (today by default).
  static DateTime nextNthBusinessDay(int n, {DateTime? referenceDate}) {
    final ref = referenceDate ?? DateTime.now();
    final today = DateTime(ref.year, ref.month, ref.day);
    final thisMonth = nthBusinessDay(ref, n);
    if (!thisMonth.isBefore(today)) return thisMonth;
    return nthBusinessDay(DateTime(ref.year, ref.month + 1), n);
  }

  /// The 5th working day (5º dia útil, Saturday counts — see
  /// [isWorkingDay]) of the month of [month]: the salary payday.
  DateTime getFifthBusinessDay(DateTime month) => nthBusinessDay(month, 5);

  /// Returns the next upcoming salary payday (5th business day).
  /// If today is before or on this month's 5th business day, returns this month's.
  /// Otherwise returns next month's 5th business day.
  DateTime getNextSalaryPayday({DateTime? referenceDate}) {
    final ref = referenceDate ?? DateTime.now();
    final currentMonthFifth = getFifthBusinessDay(DateTime(ref.year, ref.month));

    if (ref.isBefore(currentMonthFifth) ||
        (ref.year == currentMonthFifth.year && ref.month == currentMonthFifth.month && ref.day == currentMonthFifth.day)) {
      return currentMonthFifth;
    }

    // Next month
    final nextMonth = ref.month == 12 ? DateTime(ref.year + 1, 1) : DateTime(ref.year, ref.month + 1);
    return getFifthBusinessDay(nextMonth);
  }

  /// Adds a new calendar event / reminder in real time
  CalendarEvent addEvent({
    required String title,
    required DateTime dateTime,
    required CalendarEventCategory category,
    double? amount,
    String? personName,
    String? notes,
    bool isAutomated = true,
  }) {
    final event = CalendarEvent(
      id: 'cal-${DateTime.now().millisecondsSinceEpoch}-${_events.length + 1}',
      title: title,
      dateTime: dateTime,
      category: category,
      amount: amount,
      personName: personName,
      notes: notes,
      isAutomated: isAutomated,
    );
    _events.insert(0, event);
    notifyListeners();
    return event;
  }

  /// Removes an event
  void removeEvent(String id) {
    _events.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  /// Returns human-readable label for a date
  static String formatDateLabel(DateTime date) {
    final dayStr = date.day.toString().padLeft(2, '0');
    final monthStr = date.month.toString().padLeft(2, '0');
    final weekdayName = _getWeekdayName(date.weekday);
    return '$dayStr/$monthStr ($weekdayName)';
  }

  static String _getWeekdayName(int weekday) {
    switch (weekday) {
      case DateTime.monday:
        return 'segunda-feira';
      case DateTime.tuesday:
        return 'terça-feira';
      case DateTime.wednesday:
        return 'quarta-feira';
      case DateTime.thursday:
        return 'quinta-feira';
      case DateTime.friday:
        return 'sexta-feira';
      case DateTime.saturday:
        return 'sábado';
      case DateTime.sunday:
        return 'domingo';
      default:
        return '';
    }
  }
}
