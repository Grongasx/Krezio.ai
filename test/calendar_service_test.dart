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

    test('Calcula 5º dia útil para mês que começa em fim de semana ou dia 1', () {
      // Outubro de 2026:
      // Dia 1: Quinta (1º dia útil)
      // Dia 2: Sexta (2º dia útil)
      // Dia 3: Sábado (não útil)
      // Dia 4: Domingo (não útil)
      // Dia 5: Segunda (3º dia útil)
      // Dia 6: Terça (4º dia útil)
      // Dia 7: Quarta (5º dia útil)
      final fifth = calendarService.getFifthBusinessDay(DateTime(2026, 10));
      expect(fifth.year, 2026);
      expect(fifth.month, 10);
      expect(fifth.day, 7);
      expect(fifth.weekday, DateTime.wednesday);
    });

    test('Calcula 5º dia útil para mês com feriado no início (ex: Maio / Dia do Trabalho)', () {
      // Maio de 2026:
      // Dia 1: Sexta (Feriado do Trabalho -> não útil)
      // Dia 2: Sábado (não útil)
      // Dia 3: Domingo (não útil)
      // Dia 4: Segunda (1º dia útil)
      // Dia 5: Terça (2º dia útil)
      // Dia 6: Quarta (3º dia útil)
      // Dia 7: Quinta (4º dia útil)
      // Dia 8: Sexta (5º dia útil)
      final fifth = calendarService.getFifthBusinessDay(DateTime(2026, 5));
      expect(fifth.day, 8);
      expect(fifth.weekday, DateTime.friday);
    });

    test('getNextSalaryPayday retorna próxima data com base na data de referência', () {
      // Antes do 5º dia útil de Outubro de 2026 (dia 7)
      final paydayBefore = calendarService.getNextSalaryPayday(referenceDate: DateTime(2026, 10, 2));
      expect(paydayBefore.day, 7);
      expect(paydayBefore.month, 10);

      // Depois do 5º dia útil de Outubro de 2026 (ex: dia 15)
      // Próximo é Novembro:
      // Nov 1: Domingo (não útil)
      // Nov 2: Segunda (Feriado Finados -> não útil)
      // Nov 3: Terça (1º)
      // Nov 4: Quarta (2º)
      // Nov 5: Quinta (3º)
      // Nov 6: Sexta (4º)
      // Nov 7/8: Fim de semana
      // Nov 9: Segunda (5º)
      final paydayAfter = calendarService.getNextSalaryPayday(referenceDate: DateTime(2026, 10, 15));
      expect(paydayAfter.month, 11);
      expect(paydayAfter.day, 9);
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
