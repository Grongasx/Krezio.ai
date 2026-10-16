import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/services/calendar_service.dart';

void main() {
  group('RealtimeCalendarService - Dias Úteis e 5º Dia Útil Bancário', () {
    late RealtimeCalendarService calendarService;

    setUp(() {
      calendarService = RealtimeCalendarService();
    });

    test('Identifica sábados e domingos como não úteis', () {
      // 2026-10-03 é sábado, 2026-10-04 é domingo
      expect(calendarService.isBusinessDay(DateTime(2026, 10, 3)), false);
      expect(calendarService.isBusinessDay(DateTime(2026, 10, 4)), false);
      // 2026-10-05 é segunda-feira
      expect(calendarService.isBusinessDay(DateTime(2026, 10, 5)), true);
    });

    test('Identifica feriado nacional (Natal 25/12) como não útil', () {
      expect(calendarService.isBusinessDay(DateTime(2026, 12, 25)), false);
    });

    // O 5º dia útil (salário, CLT art. 459) conta o sábado; domingo e
    // feriado não (feedback 2026-10-16). isBusinessDay (dia bancário) segue
    // sem sábado.
    test('Calcula 5º dia útil para mês que começa em fim de semana ou dia 1', () {
      // Outubro de 2026: 1 qui, 2 sex, 3 sáb, (4 dom), 5 seg, 6 ter → dia 6
      final fifth = calendarService.getFifthBusinessDay(DateTime(2026, 10));
      expect(fifth.year, 2026);
      expect(fifth.month, 10);
      expect(fifth.day, 6);
      expect(fifth.weekday, DateTime.tuesday);
    });

    test('Calcula 5º dia útil para mês com feriado no início (ex: Maio / Dia do Trabalho)', () {
      // Maio de 2026: 1 sex (feriado), 2 sáb, (3 dom), 4 seg, 5 ter, 6 qua, 7 qui → dia 7
      final fifth = calendarService.getFifthBusinessDay(DateTime(2026, 5));
      expect(fifth.day, 7);
      expect(fifth.weekday, DateTime.thursday);
    });

    test('getNextSalaryPayday retorna próxima data com base na data de referência', () {
      // Antes do 5º dia útil de Outubro de 2026 (dia 6)
      final paydayBefore = calendarService.getNextSalaryPayday(referenceDate: DateTime(2026, 10, 2));
      expect(paydayBefore.day, 6);
      expect(paydayBefore.month, 10);

      // Depois: Novembro — 1 dom, 2 Finados, 3 ter, 4 qua, 5 qui, 6 sex, 7 sáb → dia 7
      final paydayAfter = calendarService.getNextSalaryPayday(referenceDate: DateTime(2026, 10, 15));
      expect(paydayAfter.month, 11);
      expect(paydayAfter.day, 7);
    });

    test('Adiciona evento no calendário em tempo real e dispara notificação', () {
      int notifyCount = 0;
      calendarService.addListener(() => notifyCount++);

      final event = calendarService.addEvent(
        title: 'Cobrar João (Empréstimo)',
        dateTime: DateTime(2026, 10, 7),
        category: CalendarEventCategory.loanReceivable,
        amount: 150.0,
        personName: 'João',
      );

      expect(event.title, 'Cobrar João (Empréstimo)');
      expect(calendarService.events.first.id, event.id);
      expect(notifyCount, 1);
    });
  });
}
