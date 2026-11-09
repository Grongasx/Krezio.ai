import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _emulatorToken(String uid, String project) {
  String segment(Map<String, Object> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${segment({'alg': 'none', 'typ': 'JWT'})}.${segment({
        'aud': project,
        'iss': 'https://securetoken.google.com/$project',
        'iat': now,
        'exp': now + 3600,
        'auth_time': now,
        'sub': uid,
        'user_id': uid,
        'firebase': {'sign_in_provider': 'password'},
      })}.';
}

void main() {
  final host = Platform.environment['FIRESTORE_EMULATOR_HOST'];
  final project =
      Platform.environment['GCLOUD_PROJECT'] ?? 'demo-krezio-sprint';

  test('regras reais isolam usuários e rejeitam snapshots anteriores ao reset',
      () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final owner = 'owner-${DateTime.now().microsecondsSinceEpoch}';
    final url = Uri.parse(
        'http://$host/v1/projects/$project/databases/(default)/documents/users/$owner');

    Future<int> request(String? uid, {int? epoch, bool write = false}) async {
      final request = await client.openUrl(write ? 'PATCH' : 'GET', url);
      if (uid != null) {
        request.headers.set(HttpHeaders.authorizationHeader,
            'Bearer ${_emulatorToken(uid, project)}');
      }
      if (write) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({
          'fields': {
            if (epoch != null) 'resetEpoch': {'integerValue': '$epoch'},
            'transactions': {
              'arrayValue': {'values': <Object>[]}
            },
          },
        }));
      }
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await request(owner, write: true), HttpStatus.ok);
    expect(await request(owner), HttpStatus.ok);
    expect(await request('other'), HttpStatus.forbidden);
    expect(await request('other', write: true), HttpStatus.forbidden);
    expect(await request(null), HttpStatus.forbidden);
    expect(await request(owner, epoch: 1, write: true), HttpStatus.ok);
    expect(await request(owner, write: true), HttpStatus.forbidden);
    expect(await request(owner, epoch: 0, write: true), HttpStatus.forbidden);
    expect(await request(owner, epoch: 3, write: true), HttpStatus.forbidden);
    expect(await request(owner, epoch: 1, write: true), HttpStatus.ok);
  },
      skip: host == null
          ? 'Defina FIRESTORE_EMULATOR_HOST para validar firestore.rules no emulador.'
          : false);
}
