import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/data_export.dart';
import 'package:krezio_ai/backend/services/pin_lock.dart';
import 'package:krezio_ai/frontend/features/legal/legal_documents.dart';
import 'package:krezio_ai/frontend/features/onboarding/onboarding_screen.dart';
import 'package:krezio_ai/frontend/theme/theme_controller.dart';

void main() {
  group('7.2 PIN', () {
    test('só 4 a 6 dígitos, com confirmação; guardado com hash', () async {
      final store = MemoryPinStore();
      final lock = PinLock(store);
      expect(await lock.setPin('123', '123'), isFalse);
      expect(await lock.setPin('1234567', '1234567'), isFalse);
      expect(await lock.setPin('1234', '1235'), isFalse);
      expect(await lock.setPin('4821', '4821'), isTrue);
      expect(await lock.isEnabled, isTrue);
      expect(store.data.values.any((v) => v.contains('4821')), isFalse, reason: 'nunca em texto');
      expect(await lock.check('4821'), PinCheck.ok);
    });

    test('5 erros pedem 30 s de espera', () async {
      var now = DateTime(2026, 10, 16, 12);
      final lock = PinLock(MemoryPinStore(), now: () => now);
      await lock.setPin('1111', '1111');
      for (var i = 0; i < 4; i++) {
        expect(await lock.check('0000'), PinCheck.wrong);
      }
      expect(await lock.check('0000'), PinCheck.lockedOut);
      expect(await lock.check('1111'), PinCheck.lockedOut, reason: 'nem o certo passa durante a espera');
      expect(lock.secondsLeft, 30);
      now = now.add(const Duration(seconds: 31));
      expect(await lock.check('1111'), PinCheck.ok);
    });

    test('digitar 4 dígitos de um PIN de 6 não conta erro', () async {
      final lock = PinLock(MemoryPinStore());
      await lock.setPin('123456', '123456');
      expect(await lock.matches('1234'), isFalse);
      expect(lock.triesLeft, PinLock.maxTries);
      expect(await lock.matches('123456'), isTrue);
    });

    test('bloqueio automático depois do tempo configurado em segundo plano', () async {
      var now = DateTime(2026, 10, 16, 12);
      final lock = PinLock(MemoryPinStore(), now: () => now);
      final left = now;
      expect(await lock.shouldLockOnResume(left), isFalse, reason: 'sem PIN não bloqueia');
      await lock.setPin('1111', '1111');
      now = now.add(const Duration(seconds: 30));
      expect(await lock.shouldLockOnResume(left), isFalse);
      now = now.add(const Duration(seconds: 31));
      expect(await lock.shouldLockOnResume(left), isTrue);
      await lock.setAutoLockAfter(Duration.zero);
      expect(await lock.shouldLockOnResume(now), isTrue);
    });
  });

  group('7.3 exportação', () {
    test('CSV abre no Excel com acentos: BOM, ponto e vírgula, vírgula decimal', () {
      final repo = FinancialRepository();
      repo.replaceAllFromCloud(
        transactions: [
          FinancialTransaction(
              id: '1', title: 'Açougue; "do Zé"', amount: 1234.5, type: TransactionType.expense, category: 'supermarket',
              paymentMethod: 'pix', date: DateTime(2026, 10, 3)),
          FinancialTransaction(
              id: '2', title: 'Salário', amount: 5000, type: TransactionType.income, category: 'salary', paymentMethod: 'pix',
              date: DateTime(2026, 10, 5)),
        ],
        reminders: [],
        budgets: repo.budgets.toList(),
        goals: [],
        categoryOverrides: {},
      );
      final csv = DataExport.transactionsCsv(repo);
      expect(csv.startsWith('﻿'), isTrue);
      final lines = csv.substring(1).trim().split('\r\n');
      expect(lines.first, startsWith('Data;Título;Tipo;Valor'));
      expect(lines[1], startsWith('05/10/2026;Salário;Receita;5000,00;'));
      expect(lines[2], contains('"Açougue; ""do Zé"""'));
      expect(lines[2], contains('-1234,50'));
      final json = jsonDecode(DataExport.toJson(repo)) as Map<String, dynamic>;
      expect((json['transactions'] as List).length, 2);
      expect(json.keys, containsAll(['accounts', 'budgets', 'goals', 'reminders', 'preferences']));
    });
  });

  group('7.3 / 7.4 documentos, tema e primeiro uso', () {
    test('aceite guarda versão e data; versão nova pede de novo', () {
      final v = LegalDocuments.acceptedValue(DateTime(2026, 10, 16));
      expect(v, startsWith('${LegalDocuments.version}|2026-10-16'));
      expect(LegalDocuments.isCurrent(v), isTrue);
      expect(LegalDocuments.isCurrent('0.9|2026-01-01'), isFalse);
      expect(LegalDocuments.isCurrent(null), isFalse);
    });

    test('tema: claro, escuro e seguir o sistema', () {
      expect(ThemeController.parse(ThemeController.nameOf(ThemeMode.system)), ThemeMode.system);
      expect(ThemeController.isDark(ThemeMode.system, Brightness.dark), isTrue);
      expect(ThemeController.isDark(ThemeMode.system, Brightness.light), isFalse);
      expect(ThemeController.isDark(ThemeMode.light, Brightness.dark), isFalse);
    });

    test('orçamento sugerido pela renda: metade para o essencial, arredondado', () {
      final b = OnboardingScreen.suggestedBudgets(4000, {});
      expect(b.keys, containsAll(['housing', 'supermarket', 'transport', 'leisure']));
      expect(b.values.reduce((a, c) => a + c), closeTo(2000, 20));
      expect(b.values.every((v) => v % 10 == 0), isTrue);
      expect(OnboardingScreen.suggestedBudgets(3000, {'health'}), {'health': 1500.0});
    });
  });
}
