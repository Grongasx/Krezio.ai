// Bateria de QA de conversação do César — RODADA 2 (generalização).
//
// A bateria antiga (conversation_probe_test.dart) está 217/217 porque o César
// foi corrigido em cima exatamente daquelas frases. Esta bateria usa SÓ frases
// inéditas (outras lojas, valores, verbos, regionalismos, idades e níveis de
// escolaridade) para medir se as correções generalizam.
//
// NÃO é teste de regressão: não usa `expect`, nunca falha a suíte. Imprime só as
// divergências e um placar por eixo. Achados em docs/qa/findings-conversa-r2.md.
//
// Rodar:  flutter test test/_qa/conversation_r2_probe_test.dart 2>&1 | grep -E "R2FAIL|R2AXIS|R2TOTAL"
//
// Reusa o `ChatSim` da bateria antiga (espelha `_sendMessage` do chat, com o
// `CesarAssistant` real e um `FinancialRepository` de verdade).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_probe_test.dart' show ChatSim, Reply;

// ─────────────────────────── modelos de caso ───────────────────────────

class Tx {
  final String axis;
  final String phrase;
  final Set<String>? intent;
  final double? amount;
  final Set<String>? cat;
  final String? pay;
  final int? inst;
  final int? day;
  final bool? recurrent;
  final bool complete;
  final Set<String>? route;
  Tx(this.axis, this.phrase,
      {Object? i, this.amount, Object? cat, this.pay, this.inst, this.day, this.recurrent, this.complete = true, Object? route})
      : intent = i == null ? null : (i is String ? {i} : (i as Set<String>)),
        cat = cat == null ? null : (cat is String ? {cat} : (cat as Set<String>)),
        route = route == null ? null : (route is String ? {route} : (route as Set<String>));
}

class Qa {
  final List<String> before; // turnos anteriores (contexto de pergunta)
  final String phrase;
  final String desc;
  final bool Function(String route) routeOk;
  final List<String> contains;
  Qa(this.phrase, this.desc, this.routeOk, [this.contains = const [], this.before = const []]);
}

class Scn {
  final String axis;
  final String name;
  final List<String> turns;
  final String expected;
  final String? Function(ChatSim s, List<Reply> r) check;
  final bool seeded;
  Scn(this.axis, this.name, this.turns, this.expected, this.check, {this.seeded = false});
}

// ─────────────────────────── helpers ───────────────────────────

bool isReport(String r) => r.startsWith('report:') && r != 'report:unknown';
bool notSaved(String r) => !r.contains('saved') && r != 'multi';
bool rt(String r, List<String> ok) => ok.contains(r);

DateTime _day(int back) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - back, 12);
}

/// Dias atrás até o último [weekday] (1=seg … 7=dom), nunca 0 nem 1 (evita
/// colidir com "hoje"/"ontem").
int daysBackTo(int weekday) {
  var d = (DateTime.now().weekday - weekday + 7) % 7;
  if (d < 2) d += 7;
  return d;
}

/// Lançamentos antigos para testar referência ("o do posto de terça",
/// "aquele de 89"). Os dados de demonstração (init-1..5) também continuam lá.
void seedRefs(FinancialRepository repo) {
  FinancialTransaction t(String id, String title, double amount, int back, String cat, String pay) => FinancialTransaction(
      id: 'seed-$id', title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: pay, date: _day(back));
  repo.addTransaction(t('pizza', 'Pizzaria Bella Napoli', 89, 9, 'leisure', 'pix'));
  repo.addTransaction(t('feira', 'Feira livre', 45, daysBackTo(DateTime.monday), 'supermarket', 'cash'));
  repo.addTransaction(t('posto', 'Posto Ipiranga', 150, daysBackTo(DateTime.tuesday), 'transport', 'debit_card'));
  repo.addTransaction(t('drogasil', 'Drogasil', 62.30, 1, 'health', 'credit_card'));
  repo.addTransaction(t('pad2', 'Padaria Estrela', 18, 1, 'supermarket', 'pix'));
  repo.addTransaction(t('pad1', 'Padaria Estrela', 12, 0, 'supermarket', 'pix'));
  repo.addTransaction(t('99', 'Corrida 99', 23, 0, 'transport', 'pix'));
}

List<FinancialTransaction> mine(ChatSim s) =>
    s.repo.transactions.where((t) => !t.id.startsWith('init-') && !t.id.startsWith('seed-')).toList();

FinancialTransaction? tx(ChatSim s, String id) {
  for (final t in s.repo.transactions) {
    if (t.id == id) return t;
  }
  return null;
}

String fmt(FinancialTransaction t) =>
    '${t.title} ${t.amount} ${t.category} ${t.paymentMethod} ${t.type.name} inst=${t.installments} rec=${t.isRecurrent} due=${t.dueDay} ${t.date.day}/${t.date.month}';
String dumpMine(ChatSim s) => 'novos: [${mine(s).map(fmt).join(' ; ')}]';
String dumpId(ChatSim s, String id) => tx(s, id) == null ? '$id APAGADO' : '$id: ${fmt(tx(s, id)!)}';

/// Nenhum lançamento novo foi criado e o seed [id] satisfaz [ok].
String? seedIs(ChatSim s, String id, bool Function(FinancialTransaction? t) ok) {
  final created = mine(s);
  if (created.isNotEmpty) return 'criou lançamento novo em vez de editar/apagar: ${dumpMine(s)} / ${dumpId(s, id)}';
  return ok(tx(s, id)) ? null : dumpId(s, id);
}

/// Exclusão: o turno [turn] tem de pedir confirmação e, com "sim", [id] some.
String? deletedSeed(ChatSim s, List<Reply> r, int turn, String id) {
  if (r.length <= turn || r[turn].route != 'confirm_delete') {
    return 'não pediu confirmação no turno ${turn + 1}: ${r.length > turn ? r[turn] : '-'}';
  }
  return seedIs(s, id, (t) => t == null);
}

String? only(ChatSim s, bool Function(List<FinancialTransaction> m) ok) => ok(mine(s)) ? null : dumpMine(s);

// ─────────────────────────── 1 turno ───────────────────────────

final txCases = <Tx>[
  // ── formal ──
  Tx('formal', 'Venho registrar o pagamento do IPTU, no valor de R\$ 1.380,00, quitado por boleto bancário.', i: 'expense', amount: 1380, cat: 'housing', pay: 'bank_slip'),
  Tx('formal', 'Registre uma receita de R\$ 7.850,00 referente aos honorários advocatícios deste mês.', i: 'income', amount: 7850),
  Tx('formal', 'Informo a aquisição de medicamentos na Drogasil, totalizando R\$ 156,80, pagos no débito.', i: 'expense', amount: 156.80, cat: 'health', pay: 'debit_card'),
  Tx('formal', 'Procedi ao pagamento da fatura de energia elétrica, R\$ 243,17, via Pix.', i: 'expense', amount: 243.17, cat: 'housing', pay: 'pix'),
  Tx('formal', 'Anote, por obséquio: despesa de R\$ 64,00 com táxi, paga em espécie.', i: 'expense', amount: 64, cat: 'transport', pay: 'cash'),
  Tx('formal', 'Recebi a restituição do imposto de renda no montante de R\$ 2.310,45.', i: 'income', amount: 2310.45),
  Tx('formal', 'Transferi R\$ 1.000,00 da minha conta para a conta da minha esposa.', i: 'transfer', amount: 1000),
  Tx('formal', 'Efetuei a quitação da mensalidade escolar do meu filho, R\$ 1.120,00, por boleto.', i: 'expense', amount: 1120, cat: 'education', pay: 'bank_slip'),
  Tx('formal', 'Contratei um seguro residencial no valor de R\$ 89,90 mensais, debitado no cartão de crédito.', i: 'expense', amount: 89.90, pay: 'credit_card', recurrent: true),
  Tx('formal', 'Adquiri um notebook de R\$ 4.599,00 parcelado em 12 vezes no cartão de crédito.', i: 'expense', amount: 4599, pay: 'credit_card', inst: 12),
  Tx('formal', 'Paguei a anuidade do conselho profissional: R\$ 612,00, em boleto.', i: 'expense', amount: 612, pay: 'bank_slip'),
  Tx('formal', 'Lançar entrada de R\$ 480,00 proveniente de aluguel de vaga de garagem.', i: 'income', amount: 480),
  Tx('formal', 'Despendi R\$ 37,50 em estacionamento rotativo hoje pela manhã, pagos no Pix.', i: 'expense', amount: 37.50, cat: 'transport', pay: 'pix'),
  Tx('formal', 'O valor de R\$ 199,00 referente ao plano odontológico foi pago no débito.', i: 'expense', amount: 199, cat: 'health', pay: 'debit_card'),
  Tx('formal', 'Realizei um aporte de R\$ 3.500,00 em CDB.', i: {'expense', 'transfer'}, amount: 3500, cat: 'investment'),
  Tx('formal', 'Recebi R\$ 900,00 a título de pensão alimentícia.', i: 'income', amount: 900),
  Tx('formal', 'Registro de despesa com hospedagem: R\$ 720,00, cartão de crédito à vista.', i: 'expense', amount: 720, pay: 'credit_card'),
  Tx('formal', 'Comunico o pagamento da taxa de licenciamento do veículo, R\$ 160,26, por Pix.', i: 'expense', amount: 160.26, cat: 'transport', pay: 'pix'),
  Tx('formal', 'Solicito que conste uma despesa de R\$ 52,00 com cópias e encadernação.', i: 'expense', amount: 52),
  Tx('formal', 'Recebimento de R\$ 1.275,00 referente à venda de móveis usados, via transferência.', i: 'income', amount: 1275),

  // ── coloquial + regionalismos ──
  Tx('coloquial', 'bah, gastei 35 pila no cacetinho e no leite, paguei no pix', i: 'expense', amount: 35, pay: 'pix'),
  Tx('coloquial', 'tchê, abasteci 200 pila no posto, foi no débito', i: 'expense', amount: 200, cat: 'transport', pay: 'debit_card'),
  Tx('coloquial', 'oxe, paguei 70 conto na feira, em dinheiro', i: 'expense', amount: 70, cat: 'supermarket', pay: 'cash'),
  Tx('coloquial', 'mainha me deu 100 de presente', i: 'income', amount: 100),
  Tx('coloquial', 'mano, torrei 90 no rolê de sábado no pix', i: 'expense', amount: 90, cat: 'leisure', pay: 'pix'),
  Tx('coloquial', 'mermão, gastei 48 com biscoito e mate na praia, no dinheiro', i: 'expense', amount: 48, pay: 'cash'),
  Tx('coloquial', 'uai, paguei 25 no pão de queijo no pix', i: 'expense', amount: 25, pay: 'pix'),
  Tx('coloquial', 'arrumei um bico de ajudante e ganhei 350', i: 'income', amount: 350),
  Tx('coloquial', 'mainha me deu 100 de presente no pix', i: 'income', amount: 100, pay: 'pix'),
  Tx('coloquial', 'saiu 60 da minha conta pro busão do mês', i: 'expense', amount: 60, cat: 'transport'),
  Tx('coloquial', 'meti o louco e comprei um videogame de 2500 em 10x no cartão', i: 'expense', amount: 2500, pay: 'credit_card', inst: 10),
  Tx('coloquial', 'caiu o décimo terceiro, 2800', i: 'income', amount: 2800),
  Tx('coloquial', 'paguei 15 no espetinho do seu zé no pix', i: 'expense', amount: 15, cat: 'leisure', pay: 'pix'),
  Tx('coloquial', 'deixei 110 no açougue no débito', i: 'expense', amount: 110, pay: 'debit_card'),
  Tx('coloquial', 'tomei um prejuízo de 200 com o conserto da moto', i: 'expense', amount: 200, cat: 'transport'),
  Tx('coloquial', 'o patrão depositou 1900 da quinzena', i: 'income', amount: 1900),
  Tx('coloquial', 'rachamos a gasolina da viagem, minha parte foi 85 no pix', i: 'expense', amount: 85, cat: 'transport', pay: 'pix'),
  Tx('coloquial', 'gastei uma nota, 300 no salão, no crédito à vista', i: 'expense', amount: 300, pay: 'credit_card'),
  Tx('coloquial', 'fui no hortifruti e deixei 58 lá, passei no débito', i: 'expense', amount: 58, cat: 'supermarket', pay: 'debit_card'),
  Tx('coloquial', 'mó susto, a conta de água veio 210, paguei no boleto', i: 'expense', amount: 210, cat: 'housing', pay: 'bank_slip'),
  Tx('coloquial', 'vixe, gastei 130 no zé delivery ontem no pix', i: 'expense', amount: 130, cat: 'leisure', pay: 'pix', day: -1),
  Tx('coloquial', 'peguei um 99 de 27 no pix', i: 'expense', amount: 27, cat: 'transport', pay: 'pix'),
  Tx('coloquial', 'faturei 150 vendendo brigadeiro', i: 'income', amount: 150),
  Tx('coloquial', 'o guri precisou de remédio, 42 na farmácia no dinheiro', i: 'expense', amount: 42, cat: 'health', pay: 'cash'),
  Tx('coloquial', 'paguei a conta da agua 80 real', i: 'expense', amount: 80, cat: 'housing'),
  Tx('coloquial', 'minha filha, hoje paguei a luz, deu cento e trinta, paguei na lotérica em dinheiro', i: 'expense', amount: 130, cat: 'housing', pay: 'cash'),

  // ── voz transcrita ──
  Tx('voz', 'gastei setenta e três reais e quarenta centavos no atacadão no débito', i: 'expense', amount: 73.40, cat: 'supermarket', pay: 'debit_card'),
  Tx('voz', 'paguei novecentos e oitenta de aluguel no pix', i: 'expense', amount: 980, cat: 'housing', pay: 'pix'),
  Tx('voz', 'recebi três mil duzentos e cinquenta de salário', i: 'income', amount: 3250, cat: 'salary'),
  Tx('voz', 'coloquei cento e oitenta de gasolina no crédito à vista', i: 'expense', amount: 180, cat: 'transport', pay: 'credit_card'),
  Tx('voz', 'gastei dezoito e noventa na drogaria no pix', i: 'expense', amount: 18.90, cat: 'health', pay: 'pix'),
  Tx('voz', 'paguei duzentos e quinze reais de internet no boleto', i: 'expense', amount: 215, cat: 'housing', pay: 'bank_slip'),
  Tx('voz', 'recebi seiscentos e quarenta de comissão no pix', i: 'income', amount: 640, pay: 'pix'),
  Tx('voz', 'gastei quatro reais e cinquenta de pão', i: 'expense', amount: 4.50),
  Tx('voz', 'paguei mil quinhentos e noventa de condomínio', i: 'expense', amount: 1590, cat: 'housing'),
  Tx('voz', 'gastei sessenta e dois vírgula trinta no ifood no crédito à vista', i: 'expense', amount: 62.30, cat: 'leisure', pay: 'credit_card'),
  Tx('voz', 'transferi dois mil pra conta poupança', i: 'transfer', amount: 2000),
  Tx('voz', 'comprei uma bicicleta de oitocentos e noventa no crédito em cinco vezes', i: 'expense', amount: 890, pay: 'credit_card', inst: 5),
  Tx('voz', 'gastei nove e cinquenta no ônibus', i: 'expense', amount: 9.50, cat: 'transport'),
  Tx('voz', 'paguei trezentos e trinta e três de ipva no pix', i: 'expense', amount: 333, cat: 'transport', pay: 'pix'),
  Tx('voz', 'recebi quatrocentos e oitenta de aluguel da casa', i: 'income', amount: 480),
  Tx('voz', 'gastei onze reais no estacionamento no dinheiro', i: 'expense', amount: 11, cat: 'transport', pay: 'cash'),
  Tx('voz', 'gastei vinte e dois no açaí no pix ponto final', i: 'expense', amount: 22, pay: 'pix'),
  Tx('voz', 'paguei cem conto na consulta da veterinária no débito', i: 'expense', amount: 100, pay: 'debit_card'),
  Tx('voz', 'gastei mil e oitocentos no dentista em seis vezes no crédito', i: 'expense', amount: 1800, cat: 'health', pay: 'credit_card', inst: 6),
  Tx('voz', 'recebi cinco mil e quinhentos de salário ontem', i: 'income', amount: 5500, cat: 'salary', day: -1),
  Tx('voz', 'paguei quarenta e oito e setenta de luz no pix', i: 'expense', amount: 48.70, cat: 'housing', pay: 'pix'),
  Tx('voz', 'gastei trinta e cinco reais no cinema com pipoca no crédito à vista', i: 'expense', amount: 35, cat: 'leisure', pay: 'credit_card'),

  // ── digitação ruim ──
  Tx('typo', 'gasteii 55 no atacadao no pixi', i: 'expense', amount: 55, cat: 'supermarket', pay: 'pix'),
  Tx('typo', 'paquei 120 de agua no bolet', i: 'expense', amount: 120, cat: 'housing', pay: 'bank_slip'),
  Tx('typo', 'reccebi 1700 do salario', i: 'income', amount: 1700, cat: 'salary'),
  Tx('typo', 'gastie 38 na drogasil no debto', i: 'expense', amount: 38, cat: 'health', pay: 'debit_card'),
  Tx('typo', 'comprie 22 de pao na padariaa', i: 'expense', amount: 22),
  Tx('typo', 'TRANSFERI 450 PRA POUPANÇA', i: 'transfer', amount: 450),
  Tx('typo', 'gastei 90 no restaurnte no pix', i: 'expense', amount: 90, cat: 'leisure', pay: 'pix'),
  Tx('typo', 'abasteci 150 no psoto no credito a vista', i: 'expense', amount: 150, cat: 'transport', pay: 'credit_card'),
  Tx('typo', 'pagei 75 na farmacai no dinheiro', i: 'expense', amount: 75, cat: 'health', pay: 'cash'),
  Tx('typo', 'gatsei 40 no uber no pix', i: 'expense', amount: 40, cat: 'transport', pay: 'pix'),
  Tx('typo', 'recebi 250 de fretee', i: 'income', amount: 250),
  Tx('typo', 'gastei 33,9 no mercado no piks', i: 'expense', amount: 33.90, cat: 'supermarket', pay: 'pix'),
  Tx('typo', 'Paguei R\$99,90 na Academia no Credito a Vista', i: 'expense', amount: 99.90, cat: 'health', pay: 'credit_card'),
  Tx('typo', 'gastei 1.500,00 na geladeira em 10 x no credito', i: 'expense', amount: 1500, pay: 'credit_card', inst: 10),
  Tx('typo', 'gastei r\$45 no ifood', i: 'expense', amount: 45, cat: 'leisure'),
  Tx('typo', 'GASTEI 18 REAIS NO ONIBUS', i: 'expense', amount: 18, cat: 'transport'),
  Tx('typo', 'gastei 60,00reais no cinema no debito', i: 'expense', amount: 60, cat: 'leisure', pay: 'debit_card'),
  Tx('typo', 'gasteii 25 no estacionameto no pix', i: 'expense', amount: 25, cat: 'transport', pay: 'pix'),
  Tx('typo', 'recebii 300 de pix do meu tio', i: 'income', amount: 300, pay: 'pix'),
  Tx('typo', 'pguei 130 na conta de luz', i: 'expense', amount: 130, cat: 'housing'),

  // ── frase longa com ruído ──
  Tx('ruido', 'depois da reunião das 14h, passei na drogasil e gastei 47 no débito', i: 'expense', amount: 47, cat: 'health', pay: 'debit_card'),
  Tx('ruido', 'meu carro tem 15 anos e ontem deu problema, paguei 380 no mecânico no pix', i: 'expense', amount: 380, cat: 'transport', pay: 'pix', day: -1),
  Tx('ruido', 'minha filha de 5 anos fez aniversário e gastei 260 no bolo e nos docinhos no crédito à vista', i: 'expense', amount: 260, pay: 'credit_card'),
  Tx('ruido', 'o ônibus da linha 432 atrasou, peguei um uber de 29 no pix', i: 'expense', amount: 29, cat: 'transport', pay: 'pix'),
  Tx('ruido', 'comprei 2 kg de carne no açougue, deu 96 no débito', i: 'expense', amount: 96, pay: 'debit_card'),
  Tx('ruido', 'a vizinha do 101 me vendeu um sofá por 700, paguei no pix', i: 'expense', amount: 700, pay: 'pix'),
  Tx('ruido', 'a cerveja tava 4,99 mas no fim gastei 60 no bar no pix', i: 'expense', amount: 60, cat: 'leisure', pay: 'pix'),
  Tx('ruido', 'fiz 3 horas extras e o chefe pagou 180 no pix', i: 'income', amount: 180, pay: 'pix'),
  Tx('ruido', 'paguei a parcela 4 de 10 do celular, 210 no boleto', i: 'expense', amount: 210, pay: 'bank_slip'),
  Tx('ruido', 'rodei 40 km até o outlet e gastei 320 em roupa no crédito em 2x', i: 'expense', amount: 320, pay: 'credit_card', inst: 2),
  Tx('ruido', 'o mercado que era 150 semana passada hoje deu 187, paguei no débito', i: 'expense', amount: 187, cat: 'supermarket', pay: 'debit_card'),
  Tx('ruido', 'às 7 da manhã já tinha gastado 12 no café da padaria no pix', i: 'expense', amount: 12, pay: 'pix'),
  Tx('ruido', 'meu irmão de 17 anos me pediu 50 e eu mandei no pix', i: {'transfer', 'expense'}, amount: 50, pay: 'pix'),
  Tx('ruido', 'tava com fome, fui no bob\'s, pedi 2 combos e deu 78 no crédito à vista', i: 'expense', amount: 78, cat: 'leisure', pay: 'credit_card'),
  Tx('ruido', 'usei o cartão final 4321 pra pagar 89 na farmácia', i: 'expense', amount: 89, cat: 'health'),
  Tx('ruido', 'ganhei 500 no bolão do escritório, 10 pessoas acertaram', i: 'income', amount: 500),
  Tx('ruido', 'depois de 2 semanas sem ir no mercado, gastei 410 no pix', i: 'expense', amount: 410, cat: 'supermarket', pay: 'pix'),
  Tx('ruido', 'bateu 38 graus hoje, comprei um ventilador de 199 no pix', i: 'expense', amount: 199, pay: 'pix'),
  Tx('ruido', 'a conta da clínica deu 350, o plano cobriu 200 e eu paguei 150 no débito', i: 'expense', amount: 150, cat: 'health', pay: 'debit_card'),
  Tx('ruido', 'sexta passada recebi 1200 de um trabalho extra no pix', i: 'income', amount: 1200, pay: 'pix'),

  // ── todos os tipos ──
  Tx('tipos', 'comprei uma máquina de lavar de 2400 em 12x no cartão', i: 'expense', amount: 2400, pay: 'credit_card', inst: 12),
  Tx('tipos', 'assinatura do amazon prime 19,90 todo mês no crédito dia 3', i: 'expense', amount: 19.90, pay: 'credit_card', recurrent: true),
  Tx('tipos', 'a internet de 110 vence todo dia 20', i: 'expense', amount: 110, cat: 'housing'),
  Tx('tipos', 'emprestei 250 pro Marcos', amount: 250),
  Tx('tipos', 'contratei uma diarista a 180 por dia por 4 dias', i: 'expense', amount: 180),
  Tx('tipos', 'comprei 4 pneus a 350 cada', i: 'expense', amount: 1400),
  Tx('tipos', 'paguei 6 meses de curso de inglês de 250', i: 'expense', amount: 1500, cat: 'education'),
  Tx('tipos', 'meu salário de 3800 cai todo dia 30', i: 'income', amount: 3800, cat: 'salary', recurrent: true),
  Tx('tipos', 'passei 800 da poupança pra conta corrente', i: 'transfer', amount: 800),
  Tx('tipos', 'o disney+ é 33,90 por mês no débito todo dia 12', i: 'expense', amount: 33.90, pay: 'debit_card', recurrent: true),
  Tx('tipos', 'recebi 42 de rendimento da poupança', i: 'income', amount: 42),
  Tx('tipos', 'comprei 3 pães de 2,50 cada', i: 'expense', amount: 7.50),
  Tx('tipos', 'vendi meu videogame usado por 1100', i: 'income', amount: 1100),
  Tx('tipos', 'a empresa me reembolsou 230 de combustível', i: 'income', amount: 230),
  Tx('tipos', 'paguei 1200 de IPVA em 3x no cartão', i: 'expense', amount: 1200, cat: 'transport', pay: 'credit_card', inst: 3),
  Tx('tipos', 'comprei 10 unidades de 8 reais de água mineral', i: 'expense', amount: 80),
  Tx('tipos', 'gastei 40 no posto e 25 no lava-jato no débito', route: 'multi'),
  Tx('tipos', 'paguei 150 de gás e 60 de água no pix', route: 'multi'),
  Tx('tipos', 'recebi 300 do aluguel e 200 de freela', route: {'multi', 'ask_multi'}),
  Tx('tipos', 'comprei 3 bolos por 45', i: 'expense', amount: 45),
  Tx('tipos', 'paguei 4 meses de mensalidade do clube de 90', i: 'expense', amount: 360),
  Tx('tipos', 'o Pedro me deve 120 do show', amount: 120),
  Tx('tipos', 'quero juntar 10 mil pra dar entrada num carro até dezembro de 2027', route: 'goal_create'),
  Tx('tipos', 'posso gastar 400 num jantar hoje?', route: {'afford:yes', 'afford:no', 'afford:caution', 'afford:warning', 'afford:ok'}),

  // ── parece comando, mas é lançamento ──
  Tx('ambiguo', 'cancelei a academia mas tive que pagar 150 de multa no pix', i: 'expense', amount: 150, pay: 'pix'),
  Tx('ambiguo', 'desfiz a mala e fui no mercado, 90 no débito', i: 'expense', amount: 90, cat: 'supermarket', pay: 'debit_card'),
  Tx('ambiguo', 'troquei o óleo do carro, 180 no crédito à vista', i: 'expense', amount: 180, cat: 'transport', pay: 'credit_card'),
  Tx('ambiguo', 'mudei de academia, a nova custa 99 por mês no pix todo dia 10', i: 'expense', amount: 99, pay: 'pix', recurrent: true),
  Tx('ambiguo', 'corrigi prova no fim de semana e recebi 200 de extra', i: 'income', amount: 200),
  Tx('ambiguo', 'acabou a luz e comprei vela, 15 em dinheiro', i: 'expense', amount: 15, pay: 'cash'),
  Tx('ambiguo', 'repeti o prato no restaurante, deu 62 no pix', i: 'expense', amount: 62, cat: 'leisure', pay: 'pix'),
  Tx('ambiguo', 'editei um vídeo pra um cliente e ganhei 350', i: 'income', amount: 350),
  Tx('ambiguo', 'voltei atrás e comprei o celular, 1800 em 12x no crédito', i: 'expense', amount: 1800, pay: 'credit_card', inst: 12),
  Tx('ambiguo', 'desisti do curso, mas paguei 120 da matrícula no pix', i: 'expense', amount: 120, cat: 'education', pay: 'pix'),
  Tx('ambiguo', 'o último ônibus da noite custou 5,50 no dinheiro', i: 'expense', amount: 5.50, cat: 'transport', pay: 'cash'),
  Tx('ambiguo', 'a última parcela do carro, 890 no boleto', i: 'expense', amount: 890, pay: 'bank_slip'),
  Tx('ambiguo', 'sim, gastei 40 no açougue no pix', i: 'expense', amount: 40, pay: 'pix'),
  Tx('ambiguo', 'esquece o que eu falei ontem, hoje gastei 30 na feira no pix', i: 'expense', amount: 30, cat: 'supermarket', pay: 'pix', day: 0),
  Tx('ambiguo', 'arranquei um dente, paguei 400 no dentista no pix', i: 'expense', amount: 400, cat: 'health', pay: 'pix'),
  Tx('ambiguo', 'excluí o app de delivery mas antes pedi uma pizza de 65 no pix', i: 'expense', amount: 65, cat: 'leisure', pay: 'pix'),
  Tx('ambiguo', 'deletei minhas redes e fui ao cinema, 44 no débito', i: 'expense', amount: 44, cat: 'leisure', pay: 'debit_card'),
  Tx('ambiguo', 'o de sempre: 12 no café da esquina no pix', i: 'expense', amount: 12, pay: 'pix'),
  Tx('ambiguo', 'renovei a cnh, 280 no boleto', i: 'expense', amount: 280, pay: 'bank_slip'),
  Tx('ambiguo', 'não era pra gastar mas gastei 75 na shein no pix', i: 'expense', amount: 75, pay: 'pix'),
  Tx('ambiguo', 'na verdade, hoje eu gastei 20 no pastel no pix', i: 'expense', amount: 20, pay: 'pix'),
  Tx('ambiguo', 'mais um mês, mais 1400 de aluguel pago no pix', i: 'expense', amount: 1400, cat: 'housing', pay: 'pix'),
  Tx('ambiguo', 'apaguei 3 velinhas no meu aniversário e gastei 120 na festa no pix', i: 'expense', amount: 120, pay: 'pix'),
];

// ─────────────────────────── perguntas (formulações inéditas) ───────────────────────────
// Dados de demonstração do mês: salário 4.500; despesas 1.948,40 (aluguel 1.400,
// Carrefour 380,50 débito, academia 119,90 crédito, uber 48 pix); saldo 2.551,60;
// João deve 150.

final qaCases = <Qa>[
  Qa('quanto que eu torrei esse mês?', 'report:spending 1.948,40', (r) => r == 'report:spending', ['1.948,40']),
  Qa('me diz o total de despesas de setembro', 'report:spending 1.948,40 (mês pelo nome)', (r) => r == 'report:spending', ['1.948,40']),
  Qa('qual foi a minha despesa mais cara?', 'maior gasto 1.400', isReport, ['1.400']),
  Qa('com o que eu mais gastei?', 'categoria top (Moradia)', isReport, ['Moradia']),
  Qa('onde foi parar meu dinheiro?', 'relatório (categorias/resumo)', isReport),
  Qa('quanto eu ainda tenho?', 'saldo 2.551,60', (r) => r == 'report:overview', ['2.551,60']),
  Qa('sobrou quanto do salário?', 'saldo 2.551,60', (r) => r == 'report:overview', ['2.551,60']),
  Qa('fiquei negativo?', 'overview (positivo)', (r) => r == 'report:overview'),
  Qa('quanto entrou de dinheiro esse mês?', 'receitas 4.500', isReport, ['4.500']),
  Qa('quanto eu ganhei em setembro?', 'receitas 4.500', isReport, ['4.500']),
  Qa('tem algum boleto pra pagar?', 'report:bills', (r) => r == 'report:bills'),
  Qa('o que vence nos próximos dias?', 'report:bills', (r) => r == 'report:bills'),
  Qa('alguém ainda não me pagou?', 'report:debtors João', (r) => r == 'report:debtors', ['João']),
  Qa('o joão me deve quanto?', 'report:debtors 150', (r) => r == 'report:debtors', ['150']),
  Qa('quanto foi de uber esse mês?', 'report:spending 48,00', (r) => r == 'report:spending', ['48,00']),
  Qa('quanto saiu no débito?', 'report:spending 380,50', (r) => r == 'report:spending', ['380,50']),
  Qa('quanto gastei no cartão de crédito esse mês?', 'report:spending 119,90', (r) => r == 'report:spending', ['119,90']),
  Qa('quanto tô pagando de academia?', 'report:spending 119,90', (r) => r == 'report:spending', ['119,90']),
  Qa('quanto eu posso gastar hoje?', 'orçamento diário', isReport),
  Qa('gastei mais ou menos que em agosto?', 'comparação', (r) => r == 'report:overview'),
  Qa('tô gastando demais?', 'overview/comparação', isReport),
  Qa('lista meus gastos', 'lista de lançamentos', isReport, ['Aluguel']),
  Qa('quanto paguei de condomínio?', 'relatório (0 ou "não teve")', isReport),
  Qa('quantas corridas de uber eu fiz esse mês?', 'contagem (1)', isReport, ['1']),
  Qa('qual foi a compra mais barata do mês?', 'menor gasto 48,00', isReport, ['48,00']),
  Qa('quando paguei a academia pela última vez?', 'última vez (academia)', isReport, ['Academia']),
  Qa('como tá minha vida financeira?', 'overview', (r) => r == 'report:overview'),
  Qa('faz um resumo do mês pra mim', 'overview/resumo', isReport),
  Qa('dá pra comprar uma tv de 3 mil?', 'afford', (r) => r.startsWith('afford')),
  Qa('consigo bancar uma viagem de 1500?', 'afford', (r) => r.startsWith('afford')),
  Qa('como vão minhas metas?', 'metas (nenhuma ainda)', (r) => r == 'report:goals' || r.startsWith('goal')),
  Qa('quanto ainda posso gastar no mercado?', 'orçamento restante 819,50', isReport, ['819,50']),
  Qa('cê faz o quê?', 'ajuda', (r) => r == 'help'),
  Qa('se eu errar um valor, como conserto?', 'ajuda (como corrigir)', (r) => r == 'help'),
  Qa('valeu, César', 'agradecimento', (r) => r == 'smalltalk'),
  Qa('e aí, beleza?', 'saudação', (r) => r == 'smalltalk'),
  Qa('qual é a média que eu gasto por dia?', 'média diária (1.948,40 / dias)', isReport),
  Qa('quanto gastei de transporte na semana passada?', 'report:spending (período)', (r) => r == 'report:spending'),
  // follow-ups com formulação nova
  Qa('e de transporte?', 'follow-up → 48,00', (r) => r == 'report:spending', ['48,00'], ['quanto foi de mercado esse mês?']),
  Qa('e o que entrou?', 'follow-up → receitas 4.500', isReport, ['4.500'], ['quanto saiu esse mês?']),
  Qa('e no crédito?', 'follow-up → 119,90', (r) => r == 'report:spending', ['119,90'], ['quanto gastei no pix?']),
  Qa('e anteontem?', 'follow-up com período', (r) => r == 'report:spending', [], ['quanto gastei hoje?']),
];

// ─────────────────────────── edição/exclusão por referência (com seeds) ───────────────────────────

final refScenarios = <Scn>[
  Scn('referencia', 'posto de terça valor', ['o do posto de terça foi 170'], 'posto = 170', (s, r) => seedIs(s, 'seed-posto', (t) => t?.amount == 170), seeded: true),
  Scn('referencia', 'aquele de 89 dinheiro', ['aquele de 89 foi no dinheiro'], 'pizzaria = cash', (s, r) => seedIs(s, 'seed-pizza', (t) => t?.paymentMethod == 'cash'), seeded: true),
  Scn('referencia', 'apaga aquele de 89', ['apaga aquele de 89', 'sim'], 'confirma e apaga pizzaria', (s, r) => deletedSeed(s, r, 0, 'seed-pizza'), seeded: true),
  Scn('referencia', 'drogasil de ontem valor', ['a drogasil de ontem na real foi 26,30'], 'drogasil = 26,30', (s, r) => seedIs(s, 'seed-drogasil', (t) => t?.amount == 26.30), seeded: true),
  Scn('referencia', 'joga fora a feira de segunda', ['joga fora a feira de segunda', 'sim'], 'confirma e apaga feira', (s, r) => deletedSeed(s, r, 0, 'seed-feira'), seeded: true),
  Scn('referencia', '99 de hoje débito', ['o 99 de hoje foi no débito'], '99 = debit', (s, r) => seedIs(s, 'seed-99', (t) => t?.paymentMethod == 'debit_card'), seeded: true),
  Scn('referencia', 'a corrida de hoje foi 32', ['a corrida de hoje foi 32'], '99 = 32', (s, r) => seedIs(s, 'seed-99', (t) => t?.amount == 32), seeded: true),
  Scn('referencia', 'passa o carrefour pro crédito', ['passa o carrefour pro crédito'], 'carrefour = credit', (s, r) => seedIs(s, 'init-2', (t) => t?.paymentMethod == 'credit_card'), seeded: true),
  Scn('referencia', 'academia agora 129,90', ['a academia agora é 129,90'], 'academia = 129,90 (ou pergunta)', (s, r) {
    final t = tx(s, 'init-4')!;
    if (mine(s).isNotEmpty) return 'criou lançamento novo: ${dumpMine(s)}';
    return t.amount == 129.90 || r.last.route == 'choose' || r.last.route == 'ask_target' ? null : '${dumpId(s, 'init-4')} ${r.last}';
  }, seeded: true),
  Scn('referencia', 'exclui a padaria (2 candidatas) → "a de 18" → sim', ['exclui a padaria', 'a de 18', 'sim'], 'pergunta qual; apaga a de 18', (s, r) {
    if (r[0].route != 'choose') return 'não perguntou qual: ${r[0]}';
    return deletedSeed(s, r, 1, 'seed-pad2') ?? (tx(s, 'seed-pad1') == null ? 'apagou a padaria errada' : null);
  }, seeded: true),
  Scn('referencia', 'apaga a padaria de ontem → pode apagar', ['apaga a padaria de ontem', 'pode apagar'], 'apaga a de ontem (18)', (s, r) => deletedSeed(s, r, 0, 'seed-pad2') ?? (tx(s, 'seed-pad1') == null ? 'apagou a de hoje também' : null), seeded: true),
  Scn('referencia', 'aquele uber de 48 no cartão de crédito', ['aquele uber de 48 foi no cartão de crédito'], 'uber = credit', (s, r) => seedIs(s, 'init-5', (t) => t?.paymentMethod == 'credit_card'), seeded: true),
  Scn('referencia', 'o de 380,50 foi no pix', ['o de 380,50 foi no pix'], 'carrefour = pix', (s, r) => seedIs(s, 'init-2', (t) => t?.paymentMethod == 'pix'), seeded: true),
  Scn('referencia', 'bota a drogasil em lazer', ['bota a drogasil em lazer'], 'drogasil = leisure', (s, r) => seedIs(s, 'seed-drogasil', (t) => t?.category == 'leisure'), seeded: true),
  Scn('referencia', 'renomeia o posto de terça pra Shell', ['renomeia o posto de terça pra Shell'], 'título Shell', (s, r) => seedIs(s, 'seed-posto', (t) => t?.title == 'Shell'), seeded: true),
  Scn('referencia', 'tira a corrida de hoje → isso', ['tira a corrida de hoje', 'isso'], 'apaga 99', (s, r) => deletedSeed(s, r, 0, 'seed-99'), seeded: true),
  Scn('referencia', 'remove o lançamento de 62,30 → confirmo', ['remove o lançamento de 62,30', 'confirmo'], 'apaga drogasil', (s, r) => deletedSeed(s, r, 0, 'seed-drogasil'), seeded: true),
  Scn('referencia', 'o do posto foi no pix (com ruído)', ['o do posto foi pra encher o tanque do carro da minha mãe, foi no pix'], 'posto = pix', (s, r) => seedIs(s, 'seed-posto', (t) => t?.paymentMethod == 'pix'), seeded: true),
  Scn('referencia', 'o de 150 na verdade foi 105', ['o de 150 na verdade foi 105'], 'posto = 105', (s, r) => seedIs(s, 'seed-posto', (t) => t?.amount == 105), seeded: true),
  Scn('referencia', 'apaga o de 7 mil (não existe)', ['apaga o de 7 mil'], 'não acha, não apaga nada, não cria nada', (s, r) {
    final n = s.repo.transactions.length;
    return r.last.route == 'not_found' && n == 12 && mine(s).isEmpty ? null : '${r.last} (n=$n)';
  }, seeded: true),
  Scn('referencia', 'exclui a netflix (não existe)', ['exclui a netflix'], 'não acha, não cria nada', (s, r) => r.last.route == 'not_found' && mine(s).isEmpty ? null : '${r.last} ${dumpMine(s)}', seeded: true),
  Scn('referencia', 'muda o valor daquele de 89 pra 95', ['muda o valor daquele de 89 pra 95'], 'pizzaria = 95', (s, r) => seedIs(s, 'seed-pizza', (t) => t?.amount == 95), seeded: true),
  Scn('referencia', 'deleta o uber e o 99 (dois alvos)', ['deleta o uber e o 99', 'sim'], 'confirma e apaga os dois', (s, r) {
    if (r[0].route != 'confirm_delete') return 'não pediu confirmação: ${r[0]}';
    final gone = [tx(s, 'init-5') == null, tx(s, 'seed-99') == null];
    return gone.every((g) => g) && mine(s).isEmpty ? null : 'uber apagado=${gone[0]} 99 apagado=${gone[1]} ${r.map((e) => e.toString()).join(' | ')}';
  }, seeded: true),
  Scn('referencia', 'apaga tudo de hoje', ['apaga tudo de hoje', 'sim'], 'confirma e apaga padaria 12 + 99', (s, r) {
    if (r[0].route != 'confirm_delete') return 'não pediu confirmação: ${r[0]}';
    return tx(s, 'seed-pad1') == null && tx(s, 'seed-99') == null && tx(s, 'seed-pad2') != null ? null : '${dumpId(s, 'seed-pad1')} / ${dumpId(s, 'seed-99')} / ${dumpId(s, 'seed-pad2')}';
  }, seeded: true),
  Scn('referencia', 'a feira foi 54 e não 45', ['a feira foi 54 e não 45'], 'feira = 54', (s, r) => seedIs(s, 'seed-feira', (t) => t?.amount == 54), seeded: true),
  Scn('referencia', 'tira aquele de 62,30 → não', ['tira aquele de 62,30', 'não, deixa'], 'confirma; com "não" mantém', (s, r) => r[0].route == 'confirm_delete' && tx(s, 'seed-drogasil') != null && mine(s).isEmpty ? null : r.map((e) => e.toString()).join(' | '), seeded: true),
  Scn('referencia', 'aquele lançamento de 1400 tá errado, é 1450', ['aquele lançamento de 1400 tá errado, é 1450'], 'aluguel = 1450', (s, r) => seedIs(s, 'init-3', (t) => t?.amount == 1450), seeded: true),
  Scn('referencia', 'foi 26 o 99 de hoje', ['foi 26 o 99 de hoje'], '99 = 26', (s, r) => seedIs(s, 'seed-99', (t) => t?.amount == 26), seeded: true),
  Scn('referencia', 'o da drogasil foi no débito, não no crédito', ['o da drogasil foi no débito, não no crédito'], 'drogasil = debit', (s, r) => seedIs(s, 'seed-drogasil', (t) => t?.paymentMethod == 'debit_card'), seeded: true),
  Scn('referencia', 'nem era 150 o posto, era 140', ['nem era 150 o posto, era 140'], 'posto = 140', (s, r) => seedIs(s, 'seed-posto', (t) => t?.amount == 140), seeded: true),
  Scn('referencia', 'a pizzaria foi 98, não 89', ['a pizzaria foi 98, não 89'], 'pizzaria = 98', (s, r) => seedIs(s, 'seed-pizza', (t) => t?.amount == 98), seeded: true),
  Scn('referencia', 'aquele uber foi 58', ['aquele uber foi 58'], 'uber = 58', (s, r) => seedIs(s, 'init-5', (t) => t?.amount == 58), seeded: true),
  Scn('referencia', 'o mercado do dia 10 foi no crédito', ['o mercado do dia 10 foi no crédito'], 'carrefour = credit', (s, r) => seedIs(s, 'init-2', (t) => t?.paymentMethod == 'credit_card'), seeded: true),
  Scn('referencia', 'some com o do 99 → manda ver', ['some com o do 99', 'manda ver'], 'apaga 99', (s, r) => deletedSeed(s, r, 0, 'seed-99'), seeded: true),
  Scn('referencia', 'o salário desse mês veio 4700', ['o salário desse mês veio 4700'], 'edita salário para 4700 ou pergunta — nunca cria 2º salário em silêncio', (s, r) {
    final dup = mine(s).where((t) => t.type == TransactionType.income).toList();
    if (dup.isNotEmpty) return 'criou salário novo: ${dumpMine(s)} / ${dumpId(s, 'init-1')}';
    return null;
  }, seeded: true),
  Scn('referencia', 'a pizza de sábado passado foi no crédito à vista', ['a pizza foi no crédito à vista'], 'pizzaria = credit', (s, r) => seedIs(s, 'seed-pizza', (t) => t?.paymentMethod == 'credit_card'), seeded: true),
];

// ─────────────────────────── vários turnos (conversas longas) ───────────────────────────

String? chain(List<String? Function()> checks) {
  for (final c in checks) {
    final p = c();
    if (p != null) return p;
  }
  return null;
}

final convScenarios = <Scn>[
  Scn('conversa', 'gasolina → pergunta → corrige → desfaz', ['botei 60 de gasolina no pix', 'quanto já gastei com combustível esse mês?', 'na real foi 65', 'desfaz'],
      'gasolina volta a 60 (1 lançamento); a pergunta responde com transporte', (s, r) => chain([
            () => r[1].route == 'report:spending' ? null : 'pergunta: ${r[1]}',
            () => only(s, (m) => m.length == 1 && m.first.amount == 60 && m.first.category == 'transport'),
          ])),
  Scn('conversa', 'ração → categoria → saldo → apaga → sim', ['comprei ração pro cachorro 130 no débito', 'outros', 'quanto sobrou?', 'apaga a ração', 'sim'],
      'nada salvo no fim', (s, r) => chain([
            () => r[2].route == 'report:overview' ? null : 'saldo: ${r[2]}',
            () => r[3].route == 'confirm_delete' ? null : 'apaga: ${r[3]}',
            () => only(s, (m) => m.isEmpty),
          ])),
  Scn('conversa', 'barbeiro → categoria → hoje? → débito → obrigado', ['paguei 45 no barbeiro no pix', 'outros', 'quanto gastei hoje?', 'muda pra débito', 'valeu'],
      'barbeiro 45 débito; resposta de hoje contém 45', (s, r) => chain([
            () => r[2].route == 'report:spending' && r[2].text.contains('45') ? null : 'hoje: ${r[2]}',
            () => only(s, (m) => m.length == 1 && m.first.paymentMethod == 'debit_card' && m.first.amount == 45),
            () => notSaved(r[4].route) ? null : 'valeu salvou: ${r[4]}',
          ])),
  Scn('conversa', 'pintura → pix → 850 → saldo', ['recebi 800 de um serviço de pintura', 'pix', 'na verdade foi 850', 'qual é o meu saldo agora?'],
      'receita 850; saldo 3.401,60', (s, r) => chain([
            () => only(s, (m) => m.length == 1 && m.first.amount == 850 && m.first.type == TransactionType.income),
            () => r[3].text.contains('3.401,60') ? null : 'saldo: ${r[3]}',
          ])),
  Scn('conversa', 'sacolão + banca → apaga sacolão → sim → desfaz', ['gastei 32 no sacolão no dinheiro', 'gastei 18 na banca de jornal no pix', 'apaga o do sacolão', 'sim', 'desfaz'],
      'os dois existem no fim', (s, r) => chain([
            () => r[2].route == 'confirm_delete' ? null : 'apaga: ${r[2]}',
            () => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 32) && m.any((t) => t.amount == 18)),
          ])),
  Scn('conversa', 'fogão crédito → 6x → pergunta → exclui → não', ['comprei um fogão de 1200 no crédito', 'em 6x', 'quanto gastei no crédito esse mês?', 'exclui o fogão', 'não'],
      'fogão 1200 6x continua', (s, r) => chain([
            () => r[2].route == 'report:spending' && r[2].text.contains('1.319,90') ? null : 'crédito: ${r[2]}',
            () => r[3].route == 'confirm_delete' ? null : 'exclui: ${r[3]}',
            () => only(s, (m) => m.length == 1 && m.first.installments == 6 && m.first.amount == 1200),
          ])),
  Scn('conversa', 'gás → corrige → "e ontem" farmácia → apaga gás → sim', ['paguei o gás 120 em dinheiro', 'o gás era 125', 'e ontem gastei 40 na farmácia no débito', 'apaga o gás', 'sim'],
      'só farmácia 40 ontem', (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 40 && m.first.date.day == _day(1).day)),
  Scn('conversa', 'rascunho → pergunta → novo → desfaz', ['gastei 70', 'quanto eu tenho de saldo?', 'comprei pão 9 no pix', 'desfaz'],
      'nada salvo (70 descartado, pão desfeito)', (s, r) => chain([
            () => r[1].route == 'report:overview' ? null : 'saldo: ${r[1]}',
            () => only(s, (m) => m.isEmpty),
          ])),
  Scn('conversa', 'comissão → recebi? → apaga → sim → recebi?', ['recebi 250 de comissão no pix', 'quanto recebi esse mês?', 'apaga a comissão', 'sim', 'quanto recebi esse mês?'],
      '4.750 depois 4.500', (s, r) => chain([
            () => r[1].text.contains('4.750') ? null : 'antes: ${r[1]}',
            () => r[4].text.contains('4.500') ? null : 'depois: ${r[4]}',
            () => only(s, (m) => m.isEmpty),
          ])),
  Scn('conversa', 'tênis 4x → 5x → desfaz', ['comprei tênis pro guri 280 no crédito em 4x', 'o tênis foi em 5x', 'desfaz'],
      'tênis 4x', (s, r) => only(s, (m) => m.length == 1 && m.first.installments == 4 && m.first.amount == 280)),
  Scn('conversa', 'almoço + janta → corrige almoço → hoje?', ['almocei no quilo, 38 no débito', 'jantei, 52 no ifood no pix', 'o almoço foi 36', 'quanto gastei hoje?'],
      'almoço 36, janta 52; hoje = 88', (s, r) => chain([
            () => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 36) && m.any((t) => t.amount == 52)),
            () => r[3].text.contains('88') ? null : 'hoje: ${r[3]}',
          ])),
  Scn('conversa', 'pendente → esquece → internet → tá certo', ['comprei um presente pra mainha', 'esquece', 'paguei 90 de internet no boleto', 'tá certo'],
      '1 lançamento 90 housing', (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 90 && m.first.category == 'housing')),
  Scn('conversa', 'mercadinho → débito → não, pix', ['gastei 40 no mercadinho', 'foi no débito', 'não, foi no pix'],
      '40 pix (1 lançamento)', (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 40 && m.first.paymentMethod == 'pix')),
  Scn('conversa', 'transferência → saldo → apaga → sim → saldo', ['transferi 300 pra poupança no pix', 'qual meu saldo?', 'apaga a transferência', 'sim', 'qual meu saldo?'],
      'saldo 2.251,60 → 2.551,60', (s, r) => chain([
            () => r[1].text.contains('2.251,60') ? null : 'saldo com transferência: ${r[1]}',
            () => r[4].text.contains('2.551,60') ? null : 'saldo depois: ${r[4]}',
            () => only(s, (m) => m.isEmpty),
          ])),
  Scn('conversa', 'cervejas → muda pra 32', ['paguei 3 cervejas por 24 no bar no pix', 'muda pra 32'],
      '32 (1 lançamento)', (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 32)),
  Scn('conversa', 'deezer sem dia → dia 5', ['assinei o deezer 22,90 por mês no crédito', 'dia 5'],
      'deezer recorrente, dia 5', (s, r) => only(s, (m) => m.length == 1 && m.first.isRecurrent && m.first.dueDay == 5 && m.first.amount == 22.90)),
  Scn('conversa', 'luz → "e 95 de água" → apaga água → sim', ['paguei 200 de luz no boleto', 'e 95 de água', 'apaga a água', 'sim'],
      'só luz 200', (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 200)),
  Scn('conversa', 'venda → recebi? → e gastei? → desfaz', ['vendi um celular usado por 600 no pix', 'quanto recebi esse mês?', 'e quanto gastei?', 'desfaz'],
      'nada salvo; perguntas respondidas', (s, r) => chain([
            () => r[1].text.contains('5.100') ? null : 'recebi: ${r[1]}',
            () => r[2].route == 'report:spending' ? null : 'gastei: ${r[2]}',
            () => only(s, (m) => m.isEmpty),
          ])),
  Scn('conversa', 'pet shop → por quê? → muda pra lazer', ['gastei 55 no pet shop no pix', 'por que você botou isso aí?', 'muda pra lazer'],
      'categoria leisure', (s, r) => chain([
            () => r[1].route == 'explain' ? null : 'explicação: ${r[1]}',
            () => only(s, (m) => m.length == 1 && m.first.category == 'leisure'),
          ])),
  Scn('conversa', 'café → de novo → hoje com café?', ['tomei um café de 8 conto no pix', 'de novo', 'quanto gastei com café hoje?'],
      '2 cafés de 8; pergunta com 16', (s, r) => chain([
            () => only(s, (m) => m.length == 2 && m.every((t) => t.amount == 8)),
            () => r[2].text.contains('16') ? null : 'pergunta: ${r[2]}',
          ])),
  Scn('conversa', 'dentista pendente → pergunta → repete completo', ['gastei 150 no dentista', 'quanto gastei com saúde?', 'gastei 150 no dentista no pix'],
      '1 lançamento 150 pix', (s, r) => only(s, (m) => m.length == 1 && m.first.paymentMethod == 'pix')),
  Scn('conversa', 'emprestei → quem deve? → pagou 30', ['emprestei 80 pra Carla', 'quem me deve?', 'a Carla me pagou 30'],
      'Carla deve 50', (s, r) => chain([
            () => r[1].text.contains('Carla') ? null : 'quem deve: ${r[1]}',
            () {
              final d = s.repo.findDebtorsByName('Carla');
              return d.isNotEmpty && d.first.amount == 50 ? null : 'Carla: ${d.map((e) => e.amount).toList()} ${r[2]}';
            },
          ])),
  Scn('conversa', 'meta celular → guardei 400 → quanto falta?', ['quero guardar 3000 pra trocar de celular até março', 'guardei 400 pro celular', 'quanto falta pra meta do celular?'],
      'meta 400/3000; falta 2.600', (s, r) => chain([
            () => s.repo.goals.isNotEmpty && s.repo.goals.first.savedAmount == 400 ? null : 'metas: ${s.repo.goals.map((g) => '${g.title} ${g.savedAmount}').toList()} / ${r[1]}',
            () => r[2].text.contains('2.600') ? null : 'falta: ${r[2]}',
            () => only(s, (m) => m.isEmpty),
          ])),
  Scn('conversa', 'estacionamento + lava-jato → apaga os dois → sim', ['gastei 12 de estacionamento no pix', 'gastei 30 no lava-jato no pix', 'apaga os dois', 'sim'],
      'nada salvo', (s, r) => only(s, (m) => m.isEmpty)),
  Scn('conversa', '6 turnos: freela + mercado → corrige freela → apaga mercado → sim → desfaz', ['recebi 1200 de freela no pix', 'gastei 300 no mercado no débito', 'o freela foi 1300', 'apaga o mercado', 'sim', 'desfaz'],
      'freela 1300 + mercado 300', (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 1300 && t.type == TransactionType.income) && m.any((t) => t.amount == 300))),
  Scn('conversa', 'diarista pendente → valor por voz → pix', ['paguei a diarista', 'cento e vinte', 'pix'],
      '120 pix', (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 120 && m.first.paymentMethod == 'pix')),
  Scn('conversa', 'pastel → dinheiro vivo', ['torrei 30 no pastel', 'foi no dinheiro vivo'],
      '30 cash', (s, r) => only(s, (m) => m.length == 1 && m.first.paymentMethod == 'cash')),
  Scn('conversa', 'mercado → "ah, e foi ontem" → "e no crédito" → à vista', ['gastei 210 no assaí no pix', 'ah, e foi ontem', 'e foi no crédito, não no pix', 'à vista'],
      '210 crédito ontem (1 lançamento)', (s, r) => only(s, (m) => m.length == 1 && m.first.paymentMethod == 'credit_card' && m.first.date.day == _day(1).day)),
  Scn('conversa', 'crédito sem parcelas → pergunta no meio → à vista?', ['comprei uma jaqueta de 260 na renner no crédito', 'quanto tenho de saldo?', 'à vista'],
      'pergunta descarta rascunho (aviso) ou mantém; "à vista" sozinho não cria lixo', (s, r) => only(s, (m) => m.isEmpty || (m.length == 1 && m.first.amount == 260))),
  Scn('conversa', 'lança → troca de assunto (meta) → apaga o último → sim', ['gastei 28 na lotérica no pix', 'quero juntar 2000 pra uma bike até julho', 'apaga o último', 'sim'],
      'apaga a lotérica (não a meta)', (s, r) => chain([
            () => only(s, (m) => m.isEmpty),
            () => s.repo.goals.isNotEmpty ? null : 'meta sumiu',
          ])),
  Scn('conversa', 'duas entradas → "o primeiro foi 15"', ['gastei 10 na tapioca no pix', 'gastei 25 no restaurante no pix', 'o primeiro foi 15'],
      'tapioca 15, caldo 25', (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 15) && m.any((t) => t.amount == 25))),
  Scn('conversa', 'lança → "cancela" → "não" → "quanto gastei hoje?"', ['gastei 66 no hortifruti no débito', 'cancela', 'não', 'quanto gastei hoje?'],
      'hortifruti continua; hoje = 66', (s, r) => chain([
            () => r[1].route == 'confirm_delete' ? null : 'cancela: ${r[1]}',
            () => only(s, (m) => m.length == 1 && m.first.amount == 66),
            () => r[3].text.contains('66') ? null : 'hoje: ${r[3]}',
          ])),
];

// Depois de um lançamento, frases que PARECEM correção/comando mas são lançamento novo.
final ambigScenarios = <Scn>[
  Scn('ambiguo', 'troquei o pneu da bike (após lançar)', ['gastei 50 no atacadão no pix', 'troquei o pneu da bike, 45 no pix'], 'novo lançamento 45, atacadão intacto',
      (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 50) && m.any((t) => t.amount == 45))),
  Scn('ambiguo', 'cancelei o plano + multa (após lançar)', ['gastei 50 no atacadão no pix', 'cancelei o plano da claro e paguei 80 de multa no pix'], 'novo 80, nada apagado',
      (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 80))),
  Scn('ambiguo', 'desfiz uma compra, estorno (após lançar)', ['gastei 50 no atacadão no pix', 'desfiz uma compra e recebi 120 de estorno no pix'], 'receita 120 nova, sem desfazer',
      (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 120 && t.type == TransactionType.income))),
  Scn('ambiguo', 'mudei de plano de celular (após lançar)', ['gastei 50 no atacadão no pix', 'mudei o plano do celular, agora pago 60 por mês no débito dia 15'], 'novo 60 recorrente; 50 intacto',
      (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 50) && m.any((t) => t.amount == 60))),
  Scn('ambiguo', 'apaguei a lousa... (após lançar)', ['gastei 50 no atacadão no pix', 'apaguei o quadro da escola e ganhei 100 de aula particular no pix'], 'receita 100 nova',
      (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 100))),
  Scn('ambiguo', 'o último capítulo... (após lançar)', ['gastei 50 no atacadão no pix', 'comprei o último livro da saga, 59 no pix'], 'novo 59',
      (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 59) && m.any((t) => t.amount == 50))),
  Scn('ambiguo', '"era pra ser 30 mas deu 45" (após lançar outro)', ['gastei 50 no atacadão no pix', 'o corte de cabelo era pra ser 30 mas deu 45 no pix'], 'novo 45; atacadão continua 50',
      (s, r) => only(s, (m) => m.any((t) => t.amount == 50) && (m.any((t) => t.amount == 45) || r.last.draft?.amount == 45))),
  Scn('ambiguo', 'repete o último (de verdade é comando) com voz', ['comprei água de 5 no pix', 'lança de novo esse mesmo'], '2 lançamentos de 5',
      (s, r) => only(s, (m) => m.length == 2 && m.every((t) => t.amount == 5))),
  Scn('ambiguo', '"na verdade, hoje eu gastei…" (após lançar outro)', ['gastei 50 no atacadão no pix', 'na verdade, hoje eu gastei 20 no pastel no pix'], 'novo 20 (ou pergunta); atacadão continua 50',
      (s, r) => only(s, (m) => m.any((t) => t.amount == 50 && t.title == 'Atacadão'))),
  Scn('ambiguo', '"ah, e hoje também gastei…" (após lançar)', ['gastei 50 no atacadão no pix', 'ah, e hoje também gastei 20 no pastel no pix'], '2 lançamentos',
      (s, r) => only(s, (m) => m.length == 2 && m.any((t) => t.amount == 50) && m.any((t) => t.amount == 20))),
  Scn('ambiguo', 'cancela minha assinatura do spotify', ['cancela minha assinatura do spotify'], 'não cria despesa',
      (s, r) => only(s, (m) => m.isEmpty)),
  Scn('ambiguo', 'não gastei nada hoje', ['não gastei nada hoje'], 'não salva nada', (s, r) => only(s, (m) => m.isEmpty)),
  Scn('ambiguo', '"sim" solto sem pergunta', ['sim'], 'não salva nada, não quebra', (s, r) => only(s, (m) => m.isEmpty)),
  Scn('ambiguo', '"45" solto sem contexto', ['45'], 'pergunta o que foi, não salva', (s, r) => only(s, (m) => m.isEmpty)),
];

// ─────────────────────────── execução ───────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  ChatSim fresh({bool seeded = false}) {
    final repo = FinancialRepository();
    if (seeded) seedRefs(repo);
    return ChatSim(engine, repo);
  }

  test('conversation probe r2 (generalização)', () {
    final pass = <String, int>{};
    final total = <String, int>{};
    void score(String axis, bool ok) {
      total[axis] = (total[axis] ?? 0) + 1;
      if (ok) pass[axis] = (pass[axis] ?? 0) + 1;
    }

    for (final c in txCases) {
      final problems = <String>[];
      Reply? r;
      try {
        final sim = fresh();
        r = sim.send(c.phrase);
        final d = r.draft;
        if (c.route != null) {
          if (!c.route!.contains(r.route) && !(c.route!.any((x) => x.startsWith('afford')) && r.route.startsWith('afford'))) {
            problems.add('route ${r.route}≠${c.route}');
          }
        } else if (d == null) {
          problems.add('route ${r.route} (sem rascunho)');
        } else {
          // Regras de produto: perguntar pagamento (quando a frase não diz),
          // "parcelado ou à vista?" no crédito, o dia de uma assinatura e a
          // categoria (uma vez) de algo desconhecido NÃO são falha.
          final okAsk = d.missingSlots.every((m) =>
              (m == 'payment_method' && c.pay == null) ||
              (m == 'installments' && c.inst == null) ||
              (m == 'due_day' && c.day == null) ||
              (m == 'category' && c.cat == null));
          if (c.complete && !d.isComplete && !okAsk) problems.add('ficou perguntando ${d.missingSlots}');
          if (c.intent != null && !c.intent!.contains(d.intent)) problems.add('intent ${d.intent}≠${c.intent}');
          if (c.amount != null && (d.amount == null || (d.amount! - c.amount!).abs() > 0.001)) problems.add('valor ${d.amount}≠${c.amount}');
          if (c.cat != null && !c.cat!.contains(d.category)) problems.add('cat ${d.category}≠${c.cat}');
          if (c.pay != null && d.paymentMethod != c.pay) problems.add('pag ${d.paymentMethod}≠${c.pay}');
          if (c.inst != null && d.installments != c.inst) problems.add('parc ${d.installments}≠${c.inst}');
          if (c.day != null && d.dateOffsetDays != c.day) problems.add('dia ${d.dateOffsetDays}≠${c.day}');
          if (c.recurrent != null && d.isRecurrent != c.recurrent) problems.add('rec ${d.isRecurrent}≠${c.recurrent}');
        }
      } catch (e) {
        problems.add('EXCEPTION $e');
      }
      final ok = problems.isEmpty;
      score(c.axis, ok);
      if (!ok) {
        final silent = r != null && (r.route == 'saved' || r.route == 'multi') &&
            problems.any((p) => p.startsWith('valor') || p.startsWith('intent') || p.startsWith('dia'));
        print('R2FAIL [${c.axis}]${silent ? ' [P0?]' : ''} "${c.phrase}" => $r || ${problems.join('; ')}');
      }
    }

    for (final q in qaCases) {
      Reply? r;
      var ok = false;
      try {
        final sim = fresh();
        for (final b in q.before) {
          sim.send(b);
        }
        r = sim.send(q.phrase);
        ok = q.routeOk(r.route) && q.contains.every((s) => r!.text.contains(s)) && notSaved(r.route) &&
            !r.text.contains('Não consegui identificar') && mine(sim).isEmpty;
      } catch (e) {
        r = Reply('EXCEPTION', '$e');
      }
      score('qa', ok);
      if (!ok) print('R2FAIL [qa] ${q.before.isEmpty ? '' : '${q.before.join(' ⏎ ')} ⏎ '}"${q.phrase}" => $r || esperado: ${q.desc} ${q.contains}');
    }

    for (final s in [...refScenarios, ...convScenarios, ...ambigScenarios]) {
      String? problem;
      final sim = fresh(seeded: s.seeded);
      try {
        for (final t in s.turns) {
          sim.send(t);
        }
        problem = s.check(sim, sim.log);
      } catch (e, st) {
        problem = 'EXCEPTION $e ${st.toString().split('\n').take(3).join(' ')}';
      }
      score(s.axis, problem == null);
      if (problem != null) {
        print('R2FAIL [${s.axis}] ${s.name}: ${s.turns.join(' ⏎ ')} || esperado: ${s.expected} || $problem');
        for (var i = 0; i < sim.log.length; i++) {
          print('R2FAIL      turno ${i + 1} "${s.turns[i]}" => ${sim.log[i]}');
        }
      }
    }

    var p = 0, t = 0;
    for (final axis in total.keys) {
      p += pass[axis] ?? 0;
      t += total[axis]!;
      print('R2AXIS $axis ${pass[axis] ?? 0}/${total[axis]}');
    }
    print('R2TOTAL $p/$t');
  });
}
