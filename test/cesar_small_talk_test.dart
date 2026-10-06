import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_small_talk.dart';

void main() {
  final morning = DateTime(2026, 9, 23, 9);
  SmallTalkReply? r(String s) => CesarSmallTalk.reply(s, now: morning);

  group('FEAT-008 / CONV-027 — conversa e ajuda', () {
    test('cumprimentos', () {
      for (final p in ['oi', 'Oi!', 'olá', 'e aí', 'bom dia césar, tudo bem?', 'boa noite', 'oi césar', 'tudo bem?', 'fala cesar']) {
        expect(r(p)?.kind, 'greeting', reason: p);
      }
      expect(r('oi')!.text, startsWith('Bom dia!'));
      expect(r('bom dia césar, tudo bem?')!.text, contains('Tudo ótimo'));
      expect(r('boa noite')!.text, startsWith('Boa noite!'));
    });

    test('agradecimento e despedida', () {
      for (final p in ['obrigado!', 'obrigada', 'valeu', 'muito obrigado pela ajuda', 'vlw']) {
        expect(r(p)?.kind, 'thanks', reason: p);
      }
      expect(r('tchau')?.kind, 'farewell');
    });

    test('o que você sabe fazer', () {
      for (final p in ['o que você sabe fazer?', 'o que você faz?', 'me ajuda', 'ajuda', 'como funciona?', 'o que eu posso te pedir?']) {
        final a = r(p);
        expect(a?.kind, 'help', reason: p);
        expect(a!.text, allOf(contains('Registrar'), contains('Apagar'), contains('desfaz'), contains('Perguntar')));
      }
    });

    test('como fazer X', () {
      expect(r('como eu apago um lançamento?')!.text, contains('apaga o uber de ontem'));
      expect(r('como faço pra desfazer?')!.text, contains('desfaz'));
      expect(r('como eu mudo o valor de um gasto?')!.text, contains('não, foi 45'));
      expect(r('como eu registro um gasto?')!.text, contains('gastei 50 no mercado'));
      expect(r('como crio uma meta?')!.text, contains('quero juntar'));
      expect(r('como eu vejo quanto gastei?')!.text, contains('quanto gastei esse mês'));
    });

    test('quem é você', () {
      expect(r('quem é você?')?.kind, 'identity');
    });
  });

  group('não é conversa', () {
    for (final p in [
      'gastei 50 no mercado',
      'oi, gastei 50 no mercado',
      'como estão minhas finanças?',
      'quanto gastei esse mês?',
      'me ajuda a lançar 50 no mercado',
      'obrigado, gastei 30 no uber',
      'apaga o último',
    ]) {
      test(p, () => expect(r(p), isNull));
    }
  });
}
