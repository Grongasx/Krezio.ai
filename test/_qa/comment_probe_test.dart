import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_probe_test.dart' show ChatSim;
import 'conversation_r3_probe_test.dart' show seedA;

void main() {
  test('comment probe', () async {
    SharedPreferences.setMockInitialValues({});
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final p in [
      'a gasolina subiu de novo, absurdo',
      'tô duro esse mês',
      'nossa, a conta de luz veio alta',
      'preciso parar de pedir ifood',
      'acho que tô gastando muito com uber',
      'o aluguel aqui é muito caro',
      'meu salário não dá pra nada',
      'queria ganhar mais',
      'hoje eu não vou gastar nada',
      'amanhã vou no mercado',
      'semana que vem tenho que pagar o IPVA',
      'se o dólar subir eu tô ferrado',
      'nossa que semana difícil',
      'tô pensando em trocar de carro',
      'minha esposa reclamou que eu gasto muito',
      'hoje é dia de pagamento aqui na firma',
      'odeio pagar boleto',
      'a feira hoje tava ótima',
      'será que compensa assinar o gamepass?',
      'o pão na padaria daqui custa 12 reais, um roubo',
      'a Netflix aumentou pra 59, vou cancelar',
      'meu vizinho gastou 5 mil numa tv',
      'o uber tá cobrando 40 pra ir no centro, absurdo',
      'o quilo do café no mercado tá 30 reais',
      'a gasolina tá pela hora da morte',
      'tô gastando demais com mercado',
      'o mercado tá muito caro',
      'que caro tá tudo',
      'esse mês foi puxado',
      'gastei demais esse fim de semana',
      'acho que exagerei no ifood',
      'minha conta de água veio absurda',
      'o ifood tá caro demais',
      'preciso economizar',
      'quero gastar menos com lazer',
      'vou cortar o uber',
    ]) {
      final repo = FinancialRepository();
      seedA(repo);
      final sim = ChatSim(engine, repo);
      final r = sim.send(p);
      // ignore: avoid_print
      print('CM| [${r.route}] $p => ${r.text.replaceAll('\n', ' ⏎ ')}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
