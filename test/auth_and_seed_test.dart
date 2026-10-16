import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/auth_service.dart';
import 'package:krezio_ai/backend/services/auth_validators.dart';

void main() {
  group('AuthValidators', () {
    test('e-mail', () {
      expect(AuthValidators.email('ana@gmail.com'), isNull);
      expect(AuthValidators.email(' ana.souza@empresa.com.br '), isNull);
      expect(AuthValidators.email(''), 'Digite seu e-mail');
      for (final bad in ['ana', 'ana@', 'ana@gmail', '@gmail.com', 'ana @gmail.com', 'ana@gmail.c']) {
        expect(AuthValidators.email(bad), 'E-mail inválido', reason: bad);
      }
    });

    test('senha nova: 8+ caracteres, com letras e números', () {
      expect(AuthValidators.newPassword('krezio2026'), isNull);
      expect(AuthValidators.newPassword('Ação1234'), isNull, reason: 'letra acentuada conta como letra');
      expect(AuthValidators.newPassword(''), 'Crie uma senha');
      expect(AuthValidators.newPassword('abc123'), 'Use pelo menos 8 caracteres');
      expect(AuthValidators.newPassword('somenteletras'), 'Use letras e números');
      expect(AuthValidators.newPassword('12345678'), 'Use letras e números');
    });

    test('login não exige a regra de senha forte (contas antigas continuam entrando)', () {
      expect(AuthValidators.loginPassword('123456'), isNull);
      expect(AuthValidators.loginPassword(''), 'Digite sua senha');
    });

    test('confirmação e termos', () {
      expect(AuthValidators.confirmPassword('krezio2026', 'krezio2026'), isNull);
      expect(AuthValidators.confirmPassword('krezio2025', 'krezio2026'), 'As senhas não são iguais');
      expect(AuthValidators.confirmPassword('', 'krezio2026'), 'Repita a senha');
      expect(AuthValidators.termsAccepted(true), isNull);
      expect(AuthValidators.termsAccepted(false), isNotNull);
    });
  });

  test('mensagens do Firebase sempre em português', () {
    expect(AuthService.friendlyMessage('email-already-in-use'), 'Esse e-mail já tem conta. Quer entrar?');
    expect(AuthService.friendlyMessage('invalid-credential'), 'E-mail ou senha incorretos.');
    expect(AuthService.friendlyMessage('network-request-failed'), contains('internet'));
    expect(AuthService.friendlyMessage('too-many-requests'), contains('Muitas tentativas'));
    expect(AuthService.friendlyMessage('algo-novo'), startsWith('Não foi possível'));
  });

  group('dados de demonstração nunca ficam no futuro (#30)', () {
    test('dia que ainda não chegou vai para o mesmo dia do mês anterior', () {
      expect(FinancialRepository.seedDate(DateTime(2026, 10, 1), 10), DateTime(2026, 9, 10));
      expect(FinancialRepository.seedDate(DateTime(2026, 10, 14), 10), DateTime(2026, 10, 10));
      expect(FinancialRepository.seedDate(DateTime(2026, 10, 10), 10), DateTime(2026, 10, 10), reason: 'hoje vale');
    });

    test('virada de ano e mês anterior mais curto', () {
      expect(FinancialRepository.seedDate(DateTime(2027, 1, 3), 14), DateTime(2026, 12, 14));
      expect(FinancialRepository.seedDate(DateTime(2027, 3, 1), 30), DateTime(2027, 2, 28));
    });

    test('em qualquer dia do mês, nenhum lançamento de demonstração é futuro', () {
      for (var d = 1; d <= 31; d++) {
        final now = DateTime(2026, 10, d);
        for (final day in [5, 8, 10, 12, 14]) {
          expect(FinancialRepository.seedDate(now, day).isAfter(now), isFalse, reason: 'hoje $d, dia $day');
        }
      }
    });

    test('o seed real de hoje não tem data futura', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 23, 59, 59);
      for (final t in FinancialRepository().transactions) {
        expect(t.date.isAfter(today), isFalse, reason: '${t.title} em ${t.date}');
      }
    });
  });
}
