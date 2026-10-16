import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/services/sync_merge.dart';

Map<String, dynamic> r(String id, double v) => {'id': id, 'amount': v};
List<Map<String, dynamic>> m(List<Map<String, dynamic>> base, List<Map<String, dynamic>> local, List<Map<String, dynamic>> remote,
        {bool noBase = false}) =>
    SyncMerge.mergeById(base: noBase ? null : base, local: local, remote: remote, idOf: (x) => x['id'] as String);
Map<String, double> asMap(List<Map<String, dynamic>> l) => {for (final x in l) x['id'] as String: (x['amount'] as num).toDouble()};

void main() {
  final base = [r('a', 10), r('b', 20)];

  test('mudança só de um lado vence (local ou remota)', () {
    expect(asMap(m(base, [r('a', 11), r('b', 20)], base)), {'a': 11, 'b': 20});
    expect(asMap(m(base, base, [r('a', 10), r('b', 22)])), {'a': 10, 'b': 22});
  });

  test('aparelhos editando registros diferentes ao mesmo tempo: nada se perde', () {
    final merged = m(base, [r('a', 11), r('b', 20)], [r('a', 10), r('b', 22)]);
    expect(asMap(merged), {'a': 11, 'b': 22});
  });

  test('adições dos dois lados entram', () {
    expect(asMap(m(base, [...base, r('c', 30)], [...base, r('d', 40)])), {'a': 10, 'b': 20, 'c': 30, 'd': 40});
  });

  test('exclusão de um lado se propaga', () {
    expect(asMap(m(base, [r('b', 20)], base)), {'b': 20}, reason: 'apagado aqui');
    expect(asMap(m(base, base, [r('a', 10)])), {'a': 10}, reason: 'apagado no outro aparelho');
  });

  test('conflito no mesmo registro: este aparelho vence', () {
    expect(asMap(m(base, [r('a', 11), r('b', 20)], [r('a', 99), r('b', 20)])), {'a': 11, 'b': 20});
  });

  test('apagado de um lado e editado do outro: a edição vence', () {
    expect(asMap(m(base, [r('b', 20)], [r('a', 15), r('b', 20)])), {'a': 15, 'b': 20});
    expect(asMap(m(base, [r('a', 15), r('b', 20)], [r('b', 20)])), {'a': 15, 'b': 20});
  });

  test('sem base (primeira sincronização): união, local vence', () {
    expect(asMap(m(const [], [r('a', 1)], [r('a', 2), r('z', 9)], noBase: true)), {'a': 1, 'z': 9});
  });

  test('ordem de chaves e inteiro como double não contam como mudança', () {
    final remoteSameData = [
      {'amount': 10.0, 'id': 'a'},
      {'amount': 20.0, 'id': 'b'},
    ];
    expect(asMap(m(base, [r('a', 11), r('b', 20)], remoteSameData)), {'a': 11, 'b': 20});
  });

  test('mapa de memória de categoria segue as mesmas regras', () {
    final merged = SyncMerge.mergeMap(
      base: {'mercado do zé': 'leisure', 'padaria': 'food'},
      local: {'mercado do zé': 'leisure', 'padaria': 'food', 'açougue': 'supermarket'},
      remote: {'mercado do zé': 'supermarket'},
    );
    expect(merged, {'mercado do zé': 'supermarket', 'açougue': 'supermarket'});
  });
}
