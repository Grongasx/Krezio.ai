import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/config/app_version.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/feedback_service.dart';

void main() {
  test('AppVersion acompanha o pubspec', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.trim(), 'version: ${AppVersion.name}+${AppVersion.build}');
  });

  test('nenhum caractere de controle no código (\\b virado backspace por script)', () {
    final bad = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final text = f.readAsStringSync();
      if (RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]').hasMatch(text)) bad.add(f.path);
    }
    expect(bad, isEmpty);
  });

  test('feedback: conta votos e manda a versão, sem o texto das respostas', () {
    final repo = FinancialRepository();
    final f = FeedbackService(repo);
    f.rateAnswer(helpful: true);
    f.rateAnswer(helpful: true);
    f.rateAnswer(helpful: false);
    expect([f.helpful, f.notHelpful], [2, 1]);
    final msg = f.compose('O César não entendeu "paguei a luz"', platform: 'android', now: DateTime(2026, 10, 16, 9, 30));
    expect(msg, contains('Krezio.ai ${AppVersion.label} · android · 2026-10-16 09:30'));
    expect(msg, contains('2 ajudaram, 1 não ajudaram'));
  });

  test('assinatura: keystore e key.properties fora do git', () {
    final ignore = File('.gitignore').readAsStringSync();
    expect(ignore, contains('android/key.properties'));
    expect(ignore, contains('*.jks'));
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('KREZIO_KEYSTORE_PASSWORD'));
    expect(gradle, isNot(contains('storePassword = "')), reason: 'nenhuma senha escrita no gradle');
  });

  test('ícone em todas as densidades, com o adaptativo', () {
    for (final d in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      expect(File('android/app/src/main/res/mipmap-$d/ic_launcher.png').existsSync(), isTrue, reason: d);
      expect(File('android/app/src/main/res/mipmap-$d/ic_launcher_foreground.png').existsSync(), isTrue, reason: d);
    }
    expect(File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml').existsSync(), isTrue);
  });
}
