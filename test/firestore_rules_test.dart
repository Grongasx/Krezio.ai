import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

/// As regras publicadas (firestore.rules): cada usuário só acessa users/{uid}.
void main() {
  final rules = File('firestore.rules').readAsStringSync().replaceFirst(RegExp(r"rules_version = '2';\s*"), '');

  test('o dono lê e grava o próprio documento; outro usuário recebe permissão negada', () async {
    final auth = StreamController<Map<String, dynamic>?>.broadcast();
    final db = FakeFirebaseFirestore(securityRules: rules, authObject: auth.stream);
    auth.add({'uid': 'ana'});
    await Future<void>.delayed(Duration.zero);

    await db.doc('users/ana').set({'transactions': []});
    expect((await db.doc('users/ana').get()).exists, isTrue);
    await expectLater(db.doc('users/bruno').set({'x': 1}), throwsA(anything));
    await expectLater(db.doc('users/bruno').get(), throwsA(anything));
    await expectLater(db.doc('outra_colecao/qualquer').set({'x': 1}), throwsA(anything));
    await auth.close();
  });

  test('sem login, nada é acessível', () async {
    final db = FakeFirebaseFirestore(securityRules: rules);
    await expectLater(db.doc('users/ana').get(), throwsA(anything));
  });
}
