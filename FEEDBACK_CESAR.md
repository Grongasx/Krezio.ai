# Feedback por etapa — César v0.5

> Um bloco por etapa concluída do [PLANO_CESAR.md](PLANO_CESAR.md): o que foi feito, números,
> problemas encontrados, decisões tomadas e o que vem a seguir. Mais recente no fim.

---

## Item 0 — Pré-requisitos · 2026-09-29

**Feito**
- Branch `feat/cesar-v0.5` criada a partir de `master` (as ~75 alterações sem commit vieram junto; **nenhum commit feito**).
- Linha de base: `flutter test` → **767 ✅ / 1 ❌**; `flutter analyze lib` → 0 erros (113 infos/warnings antigos).

**Problemas encontrados**
- ❌ `financial_qa_engine_test.dart` › "orçamento diário até o fim do mês": o **teste** dependia da data.
  Faltando 2 dias para o fim do mês o valor passa de R$ 1.000 e o app formata "1.600,00" (certo), mas o teste
  esperava "1600,00". Corrigido no teste (formato BRL com milhar). O app estava certo. Agora 23/23.
- ⚠️ Bateria r2 (só imprime) caiu de 279/279 para **278/279**, também por causa da data:
  "joga fora a feira de segunda ⏎ sim" propôs apagar **Padaria Estrela (ontem)** em vez da **Feira livre (21/09)**.
  Hoje é terça, então "segunda" = ontem, e o resolvedor preferiu a data ao nome. O "sim" do usuário apagaria o
  item errado → registrado como achado para o Item 2 (P1: pede confirmação, então não é silencioso).

**Pendente com o usuário**
- 0.1 Backup (commit + push) — não autorizado ainda. O projeto segue **sem backup**.
- 0.3 As 5 decisões do HANDOFF — sem resposta; mantido o comportamento atual em todas.

**Próximo:** Item 1 — Rodada 3 de medição (`cesar-tester` + `cesar-chaos` em paralelo).

---

## Item 1 — Rodada 3 de medição · 2026-09-29

**Feito**
- `cesar-tester` → `test/_qa/conversation_r3_probe_test.dart` (287 casos inéditos) + `docs/qa/findings-conversa-r3.md`.
- `cesar-chaos` → `test/_qa/chaos_r3_{support,fuzz,reference,persistence}_test.dart` + `docs/qa/findings-caos-r3.md`.
- Os dois agentes não conseguiram gravar o `.md` de achados; salvei o conteúdo que devolveram.
- Conferido por mim: placar da conversa reproduzido (210/267); violações do caos reproduzidas; suíte **775/775** (768 + 7 baterias novas, que só imprimem).

**Números**
| Métrica | Valor |
|---|---|
| Conversa R3TOTAL | **210/267 (78,7%)** — r1/r2 davam 100%: confirma o overfitting previsto no HANDOFF |
| Por eixo | voz 35/35 · multi-turno 31/35 · referência 34/39 · typo 27/35 · perguntas 27/38 · gíria 25/35 · multi 16/25 · comentário 15/25 |
| Eixo futuro (Itens 3–5) | 0/20 (esperado: ainda não existe) |
| Caos | 24 seeds · 7.826 turnos · 1.012 "desfaz" conferidos (0 imprecisos) · saldo/ids/persistência: 0 violações |

**Achados** — 7 P0, 13 P1, o resto P2/P3:
- P0 conversa: receita em gíria vira despesa (CONV-001); 2º item de "almoço 32 e janta 48" some (002); "se eu comprar… em 10x, quanto fica?" **salva** a compra (003).
- P0 caos: frase nova completa é fundida num rascunho sem valor — "recebi 300 de salário" vira despesa "Mercado" (CHAOS-001); data dita ao lançar ("segunda", "há 3 dias", "31/08") é ignorada e grava hoje (002); "dia 28" vira recorrência mensal (003); "muda a feira de segunda pra 90" muda a **Padaria** sem confirmar (004).
- Pontos fortes confirmados: voz 100%, desfazer exato, persistência sem perda.

**Avaliação:** o César está bem mais frágil em frases novas do que as baterias antigas mostravam. Os P0 são todos "registra errado em silêncio" — exatamente o pior tipo de bug pela estrela-guia. Item 2 começa por eles.

**Próximo:** Item 2 — `cesar-fixer` em lotes: (A) os 7 P0 → portão; (B) P1 + pendências do HANDOFF → portão; (C) P2 estruturais.

---

## Item 2 · Lote A (7 P0) — etapas 1–4 · 2026-09-29 · ⏸️ PAUSADO

**Feito (`cesar-fixer`)**
- 7 P0 corrigidos com regra estrutural (não frase a frase): fusão indevida de rascunho sem valor; receita informal;
  segmentação de multi-lançamento + invariante "2+ valores nunca viram 1 lançamento em silêncio"; `HypothesisDetector`
  (hipótese não registra); datas faladas ao lançar via `SpokenDayParser` compartilhado; "dia N" só é recorrência com
  sinal de recorrência; resolvedor não troca o nome dito por casamento de categoria.
- 130 testes novos em `test/cesar_p0_r3_test.dart` (frase do achado + 5–12 inéditas por ID), escritos antes da correção.

**Conferido por mim**
- Suíte **905/905**, analyze 0 erros. Conversa r3 **210 → 216/267**. Caos r3 **38 → 19** violações (restantes = lote B).
- Revisão parcial do código novo: sem defeito aparente; risco de falso positivo no `HypothesisDetector` anotado.

**Problema encontrado:** depois de "Não achei 'feira' de segunda… o mais próximo é Feira em 21/09", responder "sim"
não é entendido. Por isso a r2 caiu para 278/279 (a regra nova está certa; falta aceitar o "sim"). Vai para a etapa 7.

**Avaliação:** ganho real, porém modesto no placar geral (+6), porque a maioria das falhas da r3 é P1/P2 (lote B).
O que importa neste lote — nenhum "registra errado em silêncio" dos 7 casos — está coberto por teste.

**Pausado** durante as etapas 5 (aceite com frases inéditas) e 6 (caos focado). Retomar por `CONTINUAR.md`.

---

## Item 2 · Lote A — etapa 5 (aceite, frases inéditas) · 2026-09-30 · ❌ REPROVADO

**Feito:** `cesar-tester` completou e rodou `test/_qa/acceptance_lote_a_probe_test.dart` (244 casos, sobreposição com
testes existentes checada por Jaccard ≥ 0,65). Achados salvos em `docs/qa/findings-aceite-lote-a.md`. Placar conferido por mim.

| Eixo | Resultado | Meta 90% |
|---|---|---|
| 1 receita informal | 34/44 (77%) | ❌ |
| 2 multi-lançamento | 31/38 (82%) | ❌ |
| 3 hipóteses | 31/40 (78%) | ❌ |
| 4 datas ao lançar | 32/42 (76%) | ❌ |
| 5 rascunho sem valor | 34/38 (89,5%) | ❌ por pouco |
| 6 nome × dia | 36/42 (86%) — 97% sem o "sim" à sugestão | ❌/✅ |
| **Total** | **198/244 (81,1%)** · 17 casos P0 (7 achados) | ❌ |

**Diagnóstico:** as correções do lote A são **listas fechadas** (verbos de receita, formatos de data, formatos de item).
Resolvem as frases dos testes e falham nas vizinhas ("apurei", "há dois dias", "depois no açougue mais 80", "600ml").
O eixo 6 (resolvedor) generalizou bem: nenhuma edição/exclusão errada.

**Lição (vai para a etapa 7):** além de ampliar cobertura, cada área precisa de uma **rede de segurança** que troque
"grava errado em silêncio" por "pergunta": direção do dinheiro incerta → "entrou ou saiu?"; marcador temporal não
interpretado → perguntar a data; contagem de valores monetários (sem unidades) > lançamentos gerados → perguntar;
"se/caso" só é hipótese se a oração principal não tiver verbo no pretérito.

**Próximo:** aguardar etapa 6 (caos) e mandar os dois conjuntos de achados para a etapa 7.

---

## Item 2 · Lote A — etapa 6 (caos focado) · 2026-09-30 · ❌ REPROVADO

**Feito:** `cesar-chaos` completou e rodou `test/_qa/chaos_lote_a_test.dart` (5.773 turnos/leituras: 194 casos-alvo, 564 leituras
do `SpokenDayParser` com relógio injetado, 156 turnos de referência com relógio, fuzz 24 seeds × 200). Achados salvos em
`docs/qa/findings-caos-lote-a.md` (24 IDs). Resumo conferido por mim.

**Bom:** 0 exceções, saldo/ids/persistência intactos, nada apagado sem "sim"; `SpokenDayParser` 0 divergências em datas-limite;
**sem regressão** nas seeds da r3 (os 3 tipos P0 da linha de base continuam em 0).

**Ruim:** 16 P0 novos, vindos de entradas que a r3 não gerava. Maiores: fato com "se/caso" virando hipótese (152 — **regressão
do lote A**, o risco que eu tinha anotado), direção trocada (151), 2+ valores → 1 lançamento (118), hipótese salva (103), data do
multi perdida (103), "totem" lido como "ontem" e "parcela 3/10" lido como data (novos no lote A).

**Avaliação:** confirma a etapa 5 — as regras novas são estreitas demais onde deveriam ser amplas (hipóteses, receita) e amplas
demais onde deveriam ser estreitas ("se"+-ar/-er/-ir, qualquer d/m como data). A etapa 7 precisa de regras gramaticais +
redes de segurança, não de mais listas.

**Decisão para o usuário (nova):** CHAOS-A-022 — "gastei 25 na netflix" vira **recorrente** só pela categoria streaming. É desenho ou bug?

**Próximo:** etapa 7 em dois lotes sequenciais do `cesar-fixer`: 7a (direção + hipótese), 7b (valores, datas, rascunho, resolvedor).

---

## Item 2 · Lote A — etapa 7a (direção + hipóteses) · 2026-09-30 · ✅ concluída

**Feito (`cesar-fixer`):** regras reescritas por papel/gramática em vez de listas: `MoneyDirection.unclear` → César
pergunta "entrou ou saiu?" para verbo desconhecido; cobrança como objeto (multa, fatura, boleto, taxa…) nunca vira receita;
"me X pagar/gastar" = despesa; venda = entrada; `HypothesisDetector` reescrito (marcadores explícitos, "se/caso" em qualquer
posição com verbo reconhecido por radical+morfologia, **fato no passado vence o "se"**, "caso" substantivo); hipótese não
completa rascunho nem lote (`CesarAssistant.hypothesisReply`, chamado pelo chat antes do merge do lote). 74 testes novos em
`test/cesar_gate_a_7a_test.dart`.

**Conferido por mim:** aceite **198 → 218/244 (89,3%)**, P0 17 → 10 (todos do escopo 7b); eixo 1 44/44, eixo 3 40/40;
analyze 0 erros; testes do portão 204/204. Relatado pelo agente: suíte 984/984; caos fato→hipótese **152 → 0**, hipótese salva
103 → 5, tipo trocado 151 → 31 (restos = rascunho fundido, 7b); r3 217/267; sem regressão nas seeds r3.

**Ressalvas:** ACC-A-018 parcial ("quanto sobra" com valor hipotético → Item 3). r2 277/279: os 2 casos "posto de terça" dependem
do dia da semana de hoje (sem mudança no resolvedor) — reavaliar na 7b junto com o resolvedor.
Escolha de engenharia a informar ao usuário: verbo desconhecido **sempre** pergunta "entrou ou saiu?", salvo quando a frase
nomeia a compra e o classificador tem ≥ 0,6.

**Próximo:** etapa 7b (valores, datas, rascunho, resolvedor).

---

## ⏸️ Pausa · 2026-09-30

Pausado a pedido do usuário logo após lançar a etapa 7b. O agente foi parado ainda medindo a linha de base — **nenhum arquivo
mudou**. Estado: suíte 984/984, aceite 218/244, analyze 0 erros. Retomar pela etapa 7b em `CONTINUAR.md` (prompt pronto lá).

---

## ⏸️ Pausa no meio da etapa 7b · 2026-09-30

O `cesar-fixer` foi parado **durante** a 7b (reescrevendo `SpokenDayParser.parse`). Estado conferido: analyze 0 erros; testes que
já existiam verdes (622/622 nos arquivos centrais); `test/cesar_gate_a_7b_test.dart` **101 ✅ / 28 ❌** — as falhas são a
especificação do que falta (resposta com 2 números, data na resposta, frase nova sem valor, "99", unidades, "mês passado" …).
**A suíte completa está vermelha de propósito até a 7b terminar.** `lib/ai/` fora do git → não há como reverter; seguir do disco.
Lista exata e prompt de retomada em `CONTINUAR.md`.

---

## Item 2 · Lote A — etapa 7b (andamento) · 2026-09-30

A 2ª execução da 7b caiu por erro de API (limite de sessão) no meio de `mergeDrafts`. Estado conferido depois: analyze 0 erros,
`test/cesar_gate_a_7b_test.dart` **129/129** (eram 101/28). Relançado o `cesar-fixer` só para finalizar: suíte completa, revisar a
edição interrompida, cobrir IDs sem teste e apagar as sondas `probe7b*`.

---

## Item 2 · Lote A — etapa 7b (valores, datas, rascunho, resolvedor) · 2026-09-30 · ✅ concluída

**Feito (`cesar-fixer`, 3 execuções — 2 interrompidas):** todos os IDs do escopo 7b corrigidos com grupo de teste em
`test/cesar_gate_a_7b_test.dart` (238 casos). Destaques: contagem de valores monetários num ponto único (unidades, endereços,
frações excluídos; valores iguais contam; "+", "/", "depois… mais"); resposta com 2 números → pergunta; data da resposta aplicada no
merge; data dita uma vez vale para o multi; `_parseDateOffset` sem substrings ("totem", "Bar Fim de Semana"); dd/mm só com
contexto; frase nova com verbo+objeto próprios substitui o rascunho; "99" como resposta = valor; com uma sugestão, "sim" seleciona;
bug real achado: busca pelo título do resolvedor usava `'\b'` sem raw string (backspace) e nunca casava.
Duas regressões deixadas pela execução interrompida foram pegas pelas baterias `_qa` e corrigidas ("era 150… deu 187" gravava 150).

**Conferido por mim:** caos lote A — "relógio" foi de 0 para **27 divergências**; investiguei: é dd/mm ainda não chegado no ano
("31/12" em 30/09). O motor agora **pergunta** ("essa data ainda não chegou") em vez de assumir o ano passado — comportamento
seguro e coerente com a regra "data futura → perguntar"; a divergência é a premissa do oráculo, não bug.
Relatado: suíte **1222/1222**; analyze 0 erros; aceite 243/244 (**contaminado**: o corretor viu essas frases — não conta para o
portão); r3 **220/267**; r2 277/279 ("posto de terça", depende do dia); CHAOS-R3|VIOL 19; fuzz lote A: multi 118→33, data multi
103→17, tipo trocado 151→5, hipótese salva 103→4.

**Decisões para o usuário (novas):** "no fim de semana" sem dizer o dia — hoje grava no **sábado e avisa**; preferir perguntar?

**Próximo:** repetir etapas 5 e 6 com frases/seeds **novas** (arquivos novos, `_r2`), porque as baterias de lote A já foram vistas
pelo corretor.

---

## Item 2 · Lote A — etapa 5' (revalidação, frases inéditas r2) · 2026-09-30 · ❌ REPROVADO

**Feito:** `cesar-tester` → `test/_qa/acceptance_lote_a_r2_probe_test.dart` (254 casos; Jaccard < 0,6 contra **todo** `test/**` e
`docs/qa/*.md`, por script; regionalismos, WhatsApp, voz). Achados em `docs/qa/findings-aceite-lote-a-r2.md` (salvo por mim). Total conferido.

| Eixo | r1 (antes de 7a/7b) | r2 (agora, frases novas) |
|---|---|---|
| 1 direção | 77% | 75,6% ❌ |
| 2 multi/valores | 82% | 75,0% ❌ |
| 3 hipóteses | 78% | **90,2% ✅** |
| 4 datas | 76% | 82,9% ❌ |
| 5 rascunho | 89,5% | **92,7% ✅** |
| 6 nome × data | 86% | **92,9% ✅** |
| Total / P0 | 81,1% / 17 | **84,6% / 14** |

**Avaliação:** hipóteses, rascunho e resolvedor **generalizaram** (aprovados em frases que ninguém viu). Direção, valores e datas
**não**: as três "redes de segurança" ainda dependem de listas e só disparam em casos estreitos (ex.: "entrou ou saiu?" só sem
categoria; "data não convertida → pergunta" só para algumas formas; números de identificação só os listados).

**Mudança de estratégia para a próxima correção (7c):** em vez de ampliar cada regra, criar **um portão único antes de gravar**
(`EntrySafetyGate`, classe pura) que rode em todo caminho de salvamento (parse, merge, multi; chat e voz) com 3 checagens
genéricas: (1) coerência de direção — qualquer marcador de entrada × rótulo de despesa (ou o inverso) → "entrou ou saiu?";
(2) a frase tem token temporal e a data resolvida é "hoje" sem palavra "hoje/agora" → perguntar a data; (3) todo número da frase
precisa estar "explicado" (valor usado, parcela, data, unidade, identificador após substantivo) — sobrou número → perguntar.
Assim a rede pega o que as listas não previram.

**Próximo:** aguardar caos 6' e então 7c.

---

## Item 2 · Lote A — etapa 6' (revalidação, caos com seeds novas) · 2026-09-30 · ❌ REPROVADO

**Feito:** `cesar-chaos` → `test/_qa/chaos_lote_a_r2_test.dart` (~7.400 turnos/leituras; fuzz 24 × 250 com vocabulário e títulos
novos — "Café Amanhã", "Loja 25 de Março", "Lanchonete Quinta Avenida"…; `SimB` espelha o `_sendMessage` atual). Achados em
`docs/qa/findings-caos-lote-a-r2.md` (salvo por mim; 28 IDs).

**Bom:** 0 exceção/saldo/ids/perda de dados; nada apagado sem "sim"; **0 regressão** nas seeds antigas (lote A idêntico à 7b, r3 = 19);
`SpokenDayParser` 0 divergências. `pendencia_presa` (6) no r3 é artefato do oráculo (sugestão pendente é desenho da 7b; o "sim" ainda confirma).

**Ruim:** 14 P0 — intenção futura salva ("pretendo/quero/vou gastar…"), qualquer "hoje" vence a data dita, endereço "7 de setembro"
vira data, "há 3 dias … consulta de 47" vira R$ 141 (a 7b tornou "há N dias" data, e a diária ainda multiplica), "passa"/"muda"
sozinho + frase seguinte reescreve o último lançamento, "na verdade o açougue foi 23" reescreve o último em vez do Açougue.
P2 em volume: split à toa (106), "entrou ou saiu?" em frase óbvia (42), pergunta de data à toa (41) — as redes da 7a/7b
**perguntam demais** em alguns casos e **de menos** em outros.

**Avaliação:** duas classes de defeito: (1) as decisões de direção/data/valor ficam espalhadas por vários caminhos
(parse, merge, multi, dívida, edição) e cada um tem suas próprias regras — um conserta, outro escapa; (2) o fluxo de
comando/edição ("passa", "na verdade…") tem estados que aceitam qualquer coisa como resposta.

**Próximo — 7c e 7d (sequenciais):**
- **7c — `EntrySafetyGate`** (classe pura, chamada no ÚNICO ponto antes de gravar qualquer lançamento — parse, merge, multi,
  dívida, recorrente; chat e voz): coerência de direção, marcador temporal não resolvido, números não explicados, intenção/hipótese.
  Com metas dos dois lados: 0 P0 **e** queda dos falsos positivos (split à toa, "entrou ou saiu?" óbvio, data à toa).
- **7d — fluxo de conversa:** rascunho (frase nova × resposta), estados de edição ("passa"/"muda" sozinho, "na verdade o X…"),
  resolvedor (palavra de categoria × título, 2+ sugestões + "sim").

---

## Item 2 · Lote A — etapa 7c (andamento) · 2026-10-01

A 1ª execução da 7c construiu `lib/ai/entry_safety_gate.dart` + `test/cesar_gate_a_7c_test.dart` (218/218) e caiu por limite de uso
antes da suíte completa. Rodei eu: **+1443 −3** — regressões em `cesar_gate_a_7a_test` ("consegui 260 dando aula particular"),
`nlp_engine_test` (parser de notificação Nubank; salário recorrente com erros ortográficos). Apaguei as sondas probe7c*.
Relançado o `cesar-fixer` só para: corrigir as 3, medir as baterias e fechar os status.

---

## Item 2 · Lote A — etapa 7c (`EntrySafetyGate`) · 2026-10-01 · ✅ concluída

**Feito (`cesar-fixer`, 2 execuções):** `lib/ai/entry_safety_gate.dart` — portão único chamado pelo motor em `_guard` (usado por
`parse` e `mergeDrafts`; `parseMulti`/`mergeMultiDrafts` passam por eles; chat e voz herdam sem lógica própria). Ordem: intenção/
hipótese → direção (inclui desconto) → números → data, sempre contra **tudo** o que o usuário disse; quando algo não bate, pergunta
(sem repetir pergunta já respondida). As 3 regressões da 1ª execução foram corrigidas na causa — em 2 delas o gate estava certo e o
erro era anterior (leitor de notificação Nubank gravava sempre hoje; gate lia o texto cru em vez do normalizado). 273 testes em
`test/cesar_gate_a_7c_test.dart`.

**Conferido por mim:** aceite r2 **215 → 244/254 (96,1%)**, P0 14 → **1** (ACC-B-008, escopo 7d). Quedas r3 (220 → 218) e r2 (277 → 276)
são **artefato da virada do mês** — as baterias usam "setembro" por nome e dados semeados "deste mês" (ex.: "quanto gastei em setembro?"
esperava o "mês passado"); nenhuma é pergunta do gate.
Relatado: suíte **1501/1501**, analyze 0 erros. Falsos positivos do caos: split à toa **106 → 0**, "entrou ou saiu?" óbvio **42 → 3**,
data à toa **41 → 4**. ACCA 243/244. CHAOS-R3|VIOL 19.

**Avaliação:** a mudança de estratégia funcionou — um portão único fez o que duas rodadas de listas não fizeram, e com **menos**
perguntas desnecessárias, não mais.

**Achado lateral (não é do César):** os dados de demonstração de `initialize()` criam lançamentos no dia 10 do mês corrente — no dia 1º
isso é uma data **futura** (Carrefour em 10/10). Registrar para o Lote B.

**Decisão nova para o usuário:** "me pagaram 14 … no açougue domingo" — "domingo" é nome da loja ou dia? (hoje: grava no domingo).

**Próximo:** 7d — fluxo de conversa.

---

## Item 2 · Lote A — etapa 7d (andamento) · 2026-10-01

A 1ª execução da 7d caiu por limite de uso esperando a suíte completa. Ao retomar: `test/cesar_gate_a_7d_test.dart` **não compilava** —
o set constante `_notAPlaceAnswer` (local_nlp_engine.dart) tinha `'nao'` duplicado (erro de avaliação de constante que o
`flutter analyze` não acusa; só aparece ao compilar). Corrigi (1 linha) e apaguei 6 sondas `probe7d*`. Resultado: 7d 184/184.
Relançado o `cesar-fixer` para fechar: suíte completa, IDs sem teste, medição.

**Lição:** `flutter analyze` não basta como checagem de compilação — incluir `flutter test` de ao menos um arquivo que importe o motor
antes de declarar "0 erros".

---

## Item 2 · Lote A — etapa 7d (fluxo de conversa) · 2026-10-01 · ✅ concluída

**Feito (`cesar-fixer`, 2 execuções + 1 correção minha de compilação):** `lib/ai/pending_reply_check.dart` — checagem única
"resposta × assunto novo" (`PendingReplyCheck.classify` → `none | command | question | nonEvent | newEntry`), chamada pelo motor
(`startsNewTransaction`: rascunho sem valor/pagamento/categoria/data, conta recorrente, lote) e pelo `CesarAssistant` ("o que você quer
mudar?", sugestão "é esse?", escolha entre vários). Estados de edição não aceitam mais qualquer mensagem como mudança; "na verdade o X
foi N" resolve pelo nome; palavra de categoria sem título correspondente exige confirmação; 2+ sugestões + "sim" → "qual deles?".
203 testes em `test/cesar_gate_a_7d_test.dart`.

**Conferido por mim:** aceite r2 **253/254** (contaminado — o corretor viu essas frases; vale só como regressão); sem sondas soltas.
Relatado: suíte **1704/1704**, analyze 0 erros; ACCA 243/244; r3 219/267; r2 276/279; CHAOS-R3|VIOL **18** (era 19); falsos positivos
do caos sem subir (split 0, entrou-ou-saiu 3, data 4); tipo trocado 1 → 0.

**Decisões novas para o usuário:** (1) "paguei a lanchonete… ⏎ tomei um café de 9": o café é o valor da lanchonete ou outro
lançamento? (hoje completa a lanchonete); (2) "muda a gasolina de segunda pra 47" com só o Posto Shell na segunda: editar direto
(hoje) ou confirmar mostrando o item?

**Fica para o Lote B:** ACC-B-017 (dízimo vira transferência), ACC-B-019, CHAOS-B-027/028 (P2/P3).

**Próximo:** revalidação final 5''/6'' com baterias **inteiramente novas** (aceite r3 + caos r3 do lote A). Se aprovar → etapas 8–10.

---

## Item 2 · Lote A — etapa 5'' (revalidação final, aceite r3) · 2026-10-01 · ❌ REPROVADO

**Feito:** `cesar-tester` → `test/_qa/acceptance_lote_a_r3_probe_test.dart` (272 casos; 335 turnos com Jaccard < 0,6 contra **todo**
`test/**` e `docs/qa/*.md`; datas só relativas; `SimC` conferido contra o `_sendMessage` atual). **Critério mais rígido:** pergunta
desnecessária conta como falha (P2). Achados em `docs/qa/findings-aceite-lote-a-r3.md` (salvo por mim). Placar conferido.

| Eixo | r1 (antes de 7a) | r2 (após 7b) | r3 (após 7c+7d) | r3 sem contar P2 |
|---|---|---|---|---|
| 1 direção | 77% | 75,6% | 75,0% | **95,5%** |
| 2 multi/valores | 82% | 75,0% | **90,9%** | 95,5% |
| 3 hipóteses | 78% | 90,2% | 78,3% | 84,8% |
| 4 datas | 76% | 82,9% | **93,2%** | 95,5% |
| 5 pendências | 89,5% | 92,7% | 87,2% | 89,4% |
| 6 nome × data | 86% | 92,9% | 80,9% | 85,1% |
| **Total / P0** | 81,1% / 17 | 84,6% / 14 | **84,2% / 13** | ~91% / 13 |

**Leitura honesta da tendência:**
- Há progresso real: direção, valores e datas generalizaram (≥ 95% no critério antigo); eixo 6 continua com **0 P0** (nada
  editado/apagado errado); nenhuma exceção, nenhum dado perdido, desfazer exato.
- Mas o nº de P0 em frases inéditas está **estável em ~13–17 por rodada**: cada bateria nova explora um canto novo da língua
  ("seria loucura gastar…", "ia gastar… mas fiquei em casa", "trasantontem", "dois cafés 9 e um pão de queijo 6"). É a cauda longa
  de um motor de regras — cada rodada fecha uma classe e a próxima bateria encontra outra.
- Os P0 restantes são, quase todos, **intenção/não-evento sem marcador** e **direção sem verbo** — exatamente onde regras são mais fracas.

**Decisão a levar ao usuário (antes de mais rodadas):** o critério "≥ 90% por eixo e 0 P0 em frases inéditas e adversariais" pode
exigir muitas rodadas a mais. Opções a apresentar: (A) seguir iterando (7e, 7f…); (B) manter 0 P0 como meta mas acrescentar uma rede
estrutural — quando o César não tem certeza **alta** (sem verbo financeiro claro, intenção possível, frase interrogativa), ele mostra
o lançamento e pede "confirma?" antes de gravar; (C) aceitar o lote A com os P0 restantes registrados como conhecidos e seguir para o Lote B.

**Próximo:** aguardar caos 6'' e então apresentar a decisão.

---

## Item 2 · Lote A — etapa 6'' (revalidação final, caos r3) · 2026-10-01 · ❌ REPROVADO (0 regressão)

**Feito:** `cesar-chaos` → `test/_qa/chaos_lote_a_r3_test.dart` (fuzz 32 × 250 = 8.031 turnos; 603 "desfaz"; gate, `PendingReplyCheck`
e assistente com relógio injetado em 8 datas-limite). Achados em `docs/qa/findings-caos-lote-a-r3.md` (salvo por mim).

**Bom (forte):** 0 regressão em todas as baterias anteriores; `EntrySafetyGate` sob relógio injetado **deixou passar 0**; falsos
positivos quase zerados (split 0/252, "entrou ou saiu?" 0/279, fato tratado como plano 0/672); nenhum estado pendente sobreviveu a frase
nova (0/138); 0 exceção, 0 perda de dados, desfazer exato.

**Ruim:** 9 P0 novos, concentrados em: intenção/obrigação sem marcador que o **2º turno completa** ("tenho que pagar…" ⏎ "no pix");
não-evento ("deu erro", "foi recusada") completado ou aplicado como edição; "na verdade o 7 Belo foi 15" (título numérico) e "na verdade o
X…" com X inexistente; caminhos que **não passam pelo gate** (empréstimo `isReminder`; "deu 52 o almoço e 39 a sobremesa").

**Avaliação:** mesmo diagnóstico do 5'': a arquitetura (gate + checagem de pendência) está certa e generaliza; os P0 que restam são
cauda longa de intenção/não-evento e dois caminhos fora do gate.

**Decisão pedida ao usuário:** critério de aprovação do lote A — (A) seguir iterando; (B) rede de confirmação para baixa certeza +
fechar os caminhos fora do gate; (C) aceitar com P0 conhecidos documentados.

---

## Decisões do usuário · 2026-10-01

1. **Critério do lote A → B:** rede de confirmação para baixa certeza ("confirma?" antes de gravar) + fechar os caminhos que não passam
   pelo `EntrySafetyGate` (empréstimo, "deu N o X e M o Y"…), seguido de nova revalidação.
2. **Backup → "ainda não".** Sem commit. (Risco registrado: código e testes só neste disco.)
3. **Rascunho × frase com verbo próprio e outro objeto → lançamento novo** (com aviso de que o anterior ficou de lado), mesmo na mesma
   categoria ("paguei a lanchonete" ⏎ "tomei um café de 9" = 2 coisas).
4. **Edição quando o nome dito não está no título → confirmar antes** ("muda a gasolina de segunda pra 47" com só "Posto Shell" →
   "é esse?"), inclusive o caso gasolina/posto que a 7b tratava como a mesma coisa.

Ainda sem resposta: netflix recorrente pela categoria; "fim de semana" (sábado + aviso); "açougue domingo"; as 5 do HANDOFF.

---

## Item 2 · Lote A — etapa 7e (andamento) · 2026-10-02

A 1ª execução da 7e caiu por limite de uso no meio. Estado conferido: alterou 13 arquivos (inclui `lib/ai/entry_certainty.dart`, novo)
**sem ter criado** `test/cesar_gate_a_7e_test.dart` (ordem invertida: código antes do teste). Compila; portões anteriores 917/918 — a
falha é `cesar_p0_r3_test.dart:492`, que esperava edição direta por categoria e conflita com a decisão (ii) do usuário (confirmar).
Apaguei as sondas probe7e*. Relançado o `cesar-fixer` para: escrever os testes (provando que falham com a regra desligada), revisar o
código parcial, atualizar só aquele teste antigo (pela decisão do usuário) e medir.

---

## Item 2 · Lote A — etapa 7e (critério B: rede de confirmação) · 2026-10-02 · ✅ concluída

**Feito (`cesar-fixer`, 2 execuções):** `lib/ai/entry_certainty.dart` — `EntryCertainty.read(turns)` sobre **todos** os turnos (alta: verbo de
dinheiro no passado/hábito, particípio de fato consumado, papel quem-paga-quem, entrada por substantivo, item+valor; baixa: "?", falha que
fecha a frase, dúvida sobre o evento, infinitivo/futuro sem fato, comentário). 5º check do `EntrySafetyGate`: baixa → "Vou registrar … Registro
assim? (sim/não)"; irrealidade → não grava e responde como plano/simulação. Empréstimo (`isReminder`) passou a passar pelo gate; "na verdade o X…"
exige X existente; edição com nome fora do título sempre confirma (decisão ii); frase com verbo e objeto próprios = lançamento novo (decisão i).
210 testes em `test/cesar_gate_a_7e_test.dart`; 1 teste antigo atualizado pela decisão (ii) (`cesar_p0_r3_test.dart:492`).

**Conferido por mim:** aceite r3 **229 → 265/272 (97,4%)** (contaminado — o corretor viu as frases); amostra própria com 18 frases inéditas:
**0 gravação errada**, 0 confirmação desnecessária em frases claras, planos/não-eventos não gravados. Respostas fracas (P2, Lote B): "tô devendo
70 pro joão" pede o valor dito; "paguei a fatura do cartão" pede o lugar.
Relatado: suíte **1920/1920**; analyze 0 erros; confirmação em frases claras **0/66** (teste) e **0/2.112** (sonda no fuzz); caos r3: gate × relógio
falsos positivos 8 → 0; ACCB 253, ACCA 243, r3 219, r2 276, CHAOS-R3|VIOL 17.

**Próximo:** revalidação 5'''/6''' com baterias **novas** (r4). Aprovado → etapas 8–10.
