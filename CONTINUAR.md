# ▶️ CONTINUAR — retomar exatamente de onde parou

> Pausado em **2026-09-29**, **2026-09-30** e de novo em **2026-09-30 (2ª vez, NO MEIO da 7b)** — a pedido do usuário. Numa sessão nova, diga só: **"leia o CONTINUAR.md e continue"**.
> Leia antes: `HANDOFF.md` → skill `krezio-cesar-context` → `PLANO_CESAR.md` (seção 2, Portão de Qualidade).

## ⏸️ Pausa · 2026-10-06 — usuário pediu para criar o BACKLOG.md

- As 2 revalidações r4 caíram 2× (limite de sessão, depois limite semanal). Ficaram no disco, **compilando mas nunca rodados**:
  `test/_qa/acceptance_lote_a_r4_probe_test.dart` (~79 KB, quase completo) e `test/_qa/chaos_lote_a_r4_test.dart` (~22 KB, parcial).
  Nenhum `.md` de achados r4 existe. Código de produção não foi tocado depois da 7e (suíte 1920/1920).
- **Para retomar:** relançar `cesar-tester` e `cesar-chaos` com os prompts "Retomar aceite r4" / "Retomar caos r4" (mesmos requisitos
  do bloco abaixo: eixos 1–7, naturalidade ≤ 5%, seeds 20261400+n), mandando ler/completar/rodar os rascunhos.

## Atualização 2026-10-02 — 7e CONCLUÍDA → revalidação r4

- 7e ✅ rede de confirmação (`entry_certainty.dart` + 5º check do gate). Suíte 1920/1920. Aceite r3 265/272 (contaminado).
- Agora: `test/_qa/acceptance_lote_a_r4_probe_test.dart` (+ `docs/qa/findings-aceite-lote-a-r4.md`, IDs ACC-D-*) e
  `test/_qa/chaos_lote_a_r4_test.dart` (+ `docs/qa/findings-caos-lote-a-r4.md`, IDs CHAOS-D-*). Aprovado → etapa 8 → 9 → 10 → Lote B.

## Atualização 2026-10-01 (tarde) — revalidação final reprovada → DECISÃO DO USUÁRIO

- 5'' ❌ aceite r3 229/272 (13 P0; critério mais rígido) → `docs/qa/findings-aceite-lote-a-r3.md` (ACC-C-*).
- 6'' ❌ caos r3 9 P0 novos, **0 regressão**, gate deixou passar 0 sob relógio → `docs/qa/findings-caos-lote-a-r3.md` (CHAOS-C-*).
- Tendência: P0 em frases inéditas estável em ~13–17/rodada (cauda longa: intenção/não-evento sem marcador; caminhos fora do gate).
- ✅ Usuário escolheu **B** (+ lançamento novo no rascunho; confirmar edição sem nome no título; sem commit). **7e em andamento**,
  testes em `test/cesar_gate_a_7e_test.dart`. Antes era: parado aguardando o usuário escolher o critério do lote A (A seguir iterando / B rede de confirmação + fechar caminhos fora do
  gate / C aceitar com P0 conhecidos). Ver último bloco do FEEDBACK. Não começar 7e sem essa resposta.

## Atualização 2026-10-01 — 7c e 7d CONCLUÍDAS

- 7c ✅ `EntrySafetyGate` (portão único antes de gravar) · 7d ✅ `PendingReplyCheck` (resposta × assunto novo). Suíte 1704/1704.
- Agora: revalidação 5''/6'' com baterias NOVAS: `test/_qa/acceptance_lote_a_r3_probe_test.dart` (+ `docs/qa/findings-aceite-lote-a-r3.md`)
  e `test/_qa/chaos_lote_a_r3_test.dart` (+ `docs/qa/findings-caos-lote-a-r3.md`). Aprovado → etapa 8 (`/code-review high` + `/simplify`),
  9 (app ao vivo), 10 (registro) → Lote B. Reprovado → 7e só com os achados novos.
- Decisões pendentes acumuladas: netflix recorrente (CHAOS-A-022); "fim de semana" (sábado + aviso); "açougue domingo" (loja ou dia);
  "tomei um café de 9" no rascunho da lanchonete; "muda a gasolina…" edita direto ou confirma; + as 5 do HANDOFF; + backup.

## Atualização 2026-09-30 (noite) — revalidação reprovada → 7c/7d

- 5' ❌ `test/_qa/acceptance_lote_a_r2_probe_test.dart` 215/254 (eixos 1, 2, 4 < 90%; 14 casos P0) → `docs/qa/findings-aceite-lote-a-r2.md` (ACC-B-*).
- 6' ❌ `test/_qa/chaos_lote_a_r2_test.dart` 14 P0 novos, 0 regressão → `docs/qa/findings-caos-lote-a-r2.md` (CHAOS-B-*).
- **7c (em andamento):** `EntrySafetyGate` — portão único antes de gravar (direção, data, números, hipótese/intenção).
  Escopo: ACC-B-001…007, 010, 011, 012, 013, 014; CHAOS-B-001…009, 015, 017, 019; P2 de falso positivo B-021…024.
  Testes em `test/cesar_gate_a_7c_test.dart`.
- **7d (depois):** fluxo de conversa — ACC-B-008, 009, 015, 016; CHAOS-B-010…014, 016, 018, 020, 025, 026. Testes em `test/cesar_gate_a_7d_test.dart`.
- Depois: nova revalidação 5''/6'' com frases/seeds NOVAS (arquivos `_r3`), então 8–10.

## Atualização 2026-09-30 (fim do dia) — 7b CONCLUÍDA

- 7b ✅: suíte 1222/1222, analyze 0 erros, r3 220/267, r2 277/279, CHAOS-R3|VIOL 19. Sondas probe7b* apagadas.
- A seção "⚠️ Estado da 7b" abaixo é **histórica** (estado parcial já resolvido).
- **Agora:** revalidação com frases/seeds NOVAS — `cesar-tester` → `test/_qa/acceptance_lote_a_r2_probe_test.dart`
  (+ `docs/qa/findings-aceite-lote-a-r2.md`) e `cesar-chaos` → `test/_qa/chaos_lote_a_r2_test.dart`
  (+ `docs/qa/findings-caos-lote-a-r2.md`). Se aprovar (≥ 90% por eixo, 0 P0, 0 violação nova): etapa 8 → 9 → 10 → Lote B.
  Se reprovar: nova rodada do `cesar-fixer` só com os achados novos.
- Decisões pendentes novas: "no fim de semana" (hoje grava sábado + aviso) e netflix recorrente (CHAOS-A-022).

## Atualização 2026-09-30

- Etapas 5 e 6 **concluídas e reprovadas**: `docs/qa/findings-aceite-lote-a.md` (ACC-A-001…020, 198/244) e
  `docs/qa/findings-caos-lote-a.md` (CHAOS-A-001…024). Feedback em `FEEDBACK_CESAR.md`.
- **Etapa 7a CONCLUÍDA** (aceite 218/244, fato→hipótese 152→0) (`cesar-fixer`): direção do dinheiro + hipóteses — ACC-A-001/002/009/010/011/018,
  CHAOS-A-001/002/003/004/005/017/019/023. Testes novos esperados em `test/cesar_gate_a_7a_test.dart`.
- **Etapa 7b ⏸️ — PRÓXIMO PASSO.** O agente foi parado ainda medindo a linha de base: **nenhum arquivo mudou** depois da 7a
  (conferido: nada em lib/ ou test/ mais novo que a 7a; analyze 0 erros). Relançar o `cesar-fixer` com o prompt da
  seção "Prompt da etapa 7b" abaixo (testes em `test/cesar_gate_a_7b_test.dart`). Escopo: valores/multi (ACC-A-005/006/012/013/014, CHAOS-A-006/007/010/018), datas (ACC-A-003/004/019,
  CHAOS-A-008/009/013/014/020), rascunho (ACC-A-007/008/017, CHAOS-A-011/012/016), resolvedor (ACC-A-015/016,
  CHAOS-A-015/021), P3 (ACC-A-020, CHAOS-A-024). Princípio: regras gramaticais + redes de segurança ("pergunta em vez
  de gravar errado"), não listas.
- Depois de 7a+7b: repetir etapas 4–6 com frases **novas** (novo aceite + novo caos), então 8–10.
- Nova decisão do usuário: CHAOS-A-022 ("gastei 25 na netflix" vira recorrente pela categoria) — não mexer sem resposta.

### ⚠️ Estado da 7b no momento da última pausa (LEIA ANTES DE TUDO)

O `cesar-fixer` foi parado **no meio** da 7b (estava reescrevendo `SpokenDayParser.parse`). `lib/ai/` **não está no git**, então
**não dá para reverter** — continue a partir do que está no disco.

- Arquivos tocados pela 7b parcial: `lib/ai/local_nlp_engine.dart`, `lib/ai/temporal_date_parser.dart`,
  `test/cesar_gate_a_7b_test.dart` (novo, 494 linhas), e sondas temporárias do agente `test/_qa/probe7b_test.dart` +
  `test/_qa/probe7b.txt` (**apagar ao final da 7b**; não são baterias).
- Conferido na pausa: `flutter analyze lib` **0 erros**; testes que já existiam **verdes** (622/622 em p0_r3, gate_a_7a,
  nlp_engine, nlp_engine_r3, cesar_assistant, cesar_assistant_r3, transaction_command_parser).
- `test/cesar_gate_a_7b_test.dart`: **101 ✅ / 28 ❌** — as 28 falhas são a especificação do que falta (testes escritos antes
  da correção). Por isso a **suíte completa está VERMELHA de propósito** até a 7b terminar. Falta implementar:
  - CHAOS-A-007 — resposta com 2 números ao "quanto foi?" ("70 ou 80", "entre 100 e 120", "acho que 60, talvez 65") → perguntar qual (6 testes)
  - CHAOS-A-008 — data dita na resposta vale no merge ("70 ontem", "deu 28 na sexta", "foi 50 há 3 dias"; "depois de amanhã" → pergunta) (5)
  - CHAOS-A-012 — frase nova sem valor não responde pergunta de outro assunto ("recebi o aluguel da sala", "a maria me mandou um pix"…) (5)
  - ACC-A-017 / CHAOS-A-016 — resposta legítima completa ("99", "deu 99", "R$ 99", "saiu 110 no boleto") (4)
  - ACC-A-006 — número com unidade não é preço ("500g por 32", "350ml por 24") (2)
  - ACC-A-012 / CHAOS-A-018 / CHAOS-A-010 — valor não some perto de "mês passado" ("mês passado: a vizinha me pagou 8…") (2)
  - ACC-A-003 — "tem quatro dias" por extenso (1) · ACC-A-005 — "ontem: pedágio 9, estacionamento 15, lanche 22, tudo no pix" (1)
  - ACC-A-007/008/CHAOS-A-011 — "paguei o encanador ⏎ comprei uma lâmpada de 20…" (1) · CHAOS-A-009 — "20 ontem no bar e 30 hoje no mercado" (1)
- Parte já passando (101 testes): inclui os grupos do resolvedor (D) e boa parte de valores/datas — **não reescreva do zero**.
- Ao relançar o `cesar-fixer`, acrescente ao prompt: "A 7b foi interrompida no meio. Leia `test/cesar_gate_a_7b_test.dart`
  (a especificação) e o estado atual de `local_nlp_engine.dart` e `temporal_date_parser.dart`; rode o arquivo, faça as 28 falhas
  passarem sem quebrar o resto, confira os IDs do escopo que ainda não têm teste, e apague as sondas probe7b*."

### Números no momento da pausa (30/09)
- Suíte 984/984 (relatado pela 7a) · analyze 0 erros · testes do portão (p0_r3 + gate_a_7a) 204/204 conferidos.
- Aceite lote A 218/244 (89,3%; P0 10, todos do escopo 7b) · r3 217/267 · r2 277/279 (2× "posto de terça", depende do dia — reavaliar na 7b).
- Caos lote A (fuzz): fato→hipótese 0, hipótese salva 5, tipo trocado 31 (restos = rascunho fundido, 7b).

### Prompt da etapa 7b (`cesar-fixer`)
> Portão de qualidade, etapa 7b (correções), do Item 2 lote A do `PLANO_CESAR.md`. Leia `CONTINUAR.md`, `FEEDBACK_CESAR.md`
> (blocos das etapas 5, 6 e 7a), `.claude/skills/krezio-cesar-context/SKILL.md` e `.claude/skills/krezio-fix-issues/SKILL.md`.
> Não reverta a 7a (test/cesar_gate_a_7a_test.dart e test/cesar_p0_r3_test.dart têm de continuar verdes). Princípio: regras
> estruturais + redes de segurança ("pergunta em vez de gravar errado"), não listas. Escopo (IDs em docs/qa/findings-aceite-lote-a.md
> e findings-caos-lote-a.md):
> A) Valores/multi — ACC-A-005/006/012/013/014, CHAOS-A-006/007/010/018 (+ "o chefe pagou 120 mês passado" do CHAOS-A-004):
>    invariante num ponto único — contar valores MONETÁRIOS (excluir números com unidade, endereço/identificação, frações, datas,
>    horas, quantidades); ≥2 valores e menos lançamentos → split/pergunta; valores iguais contam; separadores "+", "/", "depois",
>    "mais", ausência de separador; resposta com 2 números ("50 ou 60") → pergunta; valor nunca some/troca perto de "dia M", "dd/mm",
>    "N dias atrás", "mês passado".
> B) Datas — ACC-A-003/004/019, CHAOS-A-008/009/013/014/020: `_parseDateOffset` sem substrings (usar SpokenDayParser com limite de
>    palavra: "totem", "Bar Fim de Semana"); marcador temporal não convertido com certeza ou data futura → perguntar; "há dois dias"
>    por extenso; "dia N do mês passado"; dd/mm só com contexto de data (não "parcela 3/10", "1/2 kg"); data da resposta aplicada no
>    merge; data dita uma vez vale para todos os itens do multi; nome próprio com palavra de data → ao menos avisar a data assumida.
> C) Rascunho — ACC-A-007/008/017, CHAOS-A-011/012/016: frase nova com verbo+objeto próprios substitui o rascunho (multi passa por
>    parseMulti); frase nova sem valor não responde pergunta de outro assunto; respostas legítimas ("50", "custou 88 no boleto",
>    "99") completam — número puro nunca é nome de app quando César perguntou o valor.
> D) Resolvedor — ACC-A-015/016, CHAOS-A-015/021 + r2 "joga fora a feira de segunda": palavra de categoria não seleciona outro
>    título quando a data filtra; com UMA sugestão, "sim/esse/pode ser" seleciona (exclusão ainda confirma); "passa o X pra N" com X
>    existente = edição; título com palavra de data casa pelo título; reavaliar r2 "posto de terça".
> E) P3 ACC-A-020, CHAOS-A-024 só se estrutural e barato. CHAOS-A-022: NÃO mexer (decisão do usuário).
> Para cada ID: teste que falha primeiro + 5–8 frases NOVAS em test/cesar_gate_a_7b_test.dart. Nunca edite test/_qa/*. Ao final:
> suíte completa, analyze 0 erros, ACCA_(AXIS|TOTAL), CHAOS-A|RESUMO, R3TOTAL (≥217), r2 e CHAOS-R3|VIOL (≤19). Atualize Status
> nos findings. Sem commit; não mexer em lib/firebase_options.dart.

**Depois da 7b:** repetir 4–6 com frases NOVAS (novo aceite `cesar-tester` + novo caos `cesar-chaos`, arquivos novos, não reutilizar
os de lote A) → etapa 8 (`/code-review high`, `/simplify`) → 9 (app ao vivo) → 10 (registro) → Lote B.

## Onde estamos (na pausa de 29/09)

```
Plano v0.5 (PLANO_CESAR.md)
 ✅ Item 0  Pré-requisitos (branch feat/cesar-v0.5, linha de base)      — 0.1 backup e 0.3 decisões: sem resposta do usuário
 ✅ Item 1  Rodada 3 de medição                                         — conversa 210/267, caos 38 violações, 7 P0
 🔶 Item 2  Correções
     🔶 Lote A — 7 P0             implementado ✅ │ Portão: 1–4 ✅ · 5 ❌ (198/244) · 6 ❌ (16 P0) · 7a ✅ (aceite 218/244) · 7a ✅ · 7b ✅ (suíte 1222) · 5' ❌ 215/254 · 6' ❌ 14 P0 · 7c ✅ (aceite r2 244/254) · 7d ✅ (suíte 1704) · 5'' ❌ 229/272 · 6'' ❌ 9 P0 (0 regressão) · decisão: B · 7e ✅ (suíte 1920) · revalidação r4 ⏸️ PAUSADA (2ª queda: limite semanal; rascunhos r4 no disco, nunca rodados) · 8–10 ⏳
     ⏳ Lote B — P1 + pendências P2 do HANDOFF
     ⏳ Lote C — P2 estruturais
 ⏳ Item 3  Simulações "e se…?"
 ⏳ Item 4  César consultor
 ⏳ Item 5  César proativo
 ⏳ Item 6  Voz no celular
```

**Estado verificado no momento da pausa**
- `flutter test` → **905/905** ✅ (o agente contou 907; varia ±2 com a data) · `flutter analyze lib` → 0 erros.
- Conversa r3 → **216/267** (era 210) · caos r3 (reference+persistence) → **19 linhas `CHAOS-R3|VIOL`** (era 38).
- Lote A — IDs corrigidos: CHAOS-R3-001…005, CONV-R3-001…003, FEAT-R3-004 (mínimo). CONV-R3-012 parcial ("ótima"→"TIM" ficou aberto).
- Testes do lote A: `test/cesar_p0_r3_test.dart` (130 casos).
- Arquivos de produção tocados no lote A: `lib/ai/local_nlp_engine.dart`, `lib/ai/money_direction.dart`,
  `lib/ai/hypothesis_detector.dart` (novo), `lib/ai/cesar_assistant.dart`, `lib/ai/temporal_date_parser.dart`
  (`SpokenDayParser`), `lib/ai/transaction_reference_resolver.dart`.
- Revisão de código parcial (etapa 8, feita por mim): `HypothesisDetector` e `_replacesValuelessDraft` lidos, sem
  defeito aparente. **Ponto de atenção:** em `_conditional`, qualquer palavra terminada em -ar/-er/-ir/-or após "se"
  conta como verbo → risco de falso positivo (títulos/nomes próprios). Os testes de caos da etapa 6 miram isso.

## O que estava rodando quando pausou

Dois agentes foram **interrompidos no meio** (parados de propósito):

| Etapa | Agente | Arquivo deixado | Situação |
|---|---|---|---|
| 5 — aceite com frases inéditas | `cesar-tester` | `test/_qa/acceptance_lote_a_probe_test.dart` (725 linhas) | Compila (0 erros). **Nunca foi rodado**; `docs/qa/findings-aceite-lote-a.md` **não existe** |
| 6 — caos focado no lote A | `cesar-chaos` | `test/_qa/chaos_lote_a_test.dart` (~52 KB) | Compila (0 erros). **Nunca foi rodado**; `docs/qa/findings-caos-lote-a.md` **não existe** |

Os arquivos podem estar incompletos em cobertura (o agente parou antes de revisar). Eles só imprimem — não quebram a suíte.

## Passo a passo para retomar

1. **Conferir o estado** (deve bater com o de cima):
   ```bash
   git branch --show-current
   flutter test --reporter compact 2>&1 | tail -1
   flutter test test/_qa/conversation_r3_probe_test.dart 2>&1 | grep -E "^R3(AXIS|TOTAL)"
   ```
2. **Retomar a etapa 5 e a 6 em paralelo** — relançar `cesar-tester` e `cesar-chaos` com os prompts abaixo.
   Eles devem **continuar** os arquivos existentes (ler, completar a cobertura pedida, rodar), não recomeçar do zero.
   Se não conseguirem gravar o `.md` de achados, salve você o conteúdo que eles devolverem.
3. **Conferir os resultados você mesmo** (rodar os dois arquivos). Critério do portão: **≥ 90% por eixo e 0 P0**
   no aceite; **0 violação de invariante nova** no caos.
4. **Etapa 7 — correções:** `cesar-fixer` nos achados ACC-A-* e CHAOS-A-* (P0 → P1), **mais** este já conhecido:
   - Depois de "Não achei 'feira' de segunda. Os mais próximos são: Feira livre em 21/09. Quer mexer em algum deles?",
     responder **"sim" / "essa" / "pode ser"** cai em "Não consegui identificar essa transação". Com **uma** sugestão só,
     "sim" deve selecioná-la e seguir o fluxo (na exclusão, ainda pedir a confirmação normal). É isso que derruba
     o caso da r2 "joga fora a feira de segunda" (278/279) — **não** altere a bateria r2.
   Depois, repetir etapas 4–6 com frases **novas** (regra contra overfitting).
5. **Etapa 8:** `/code-review high` e `/simplify` no código do lote A (lista de arquivos acima).
6. **Etapa 9:** app ao vivo (skill `run`: `flutter run -d web-server --web-port=8091 --web-hostname=127.0.0.1` +
   screenshot) exercitando: "fiz uma graninha de 400 com bico no pix", "almoço 32 e janta 48 no pix",
   "se eu comprar um celular de 2000 em 10x, quanto fica?", "gastei 50 no mercado segunda no pix",
   "muda a feira de segunda pra 90" (sem feira na segunda).
7. **Etapa 10:** fechar o lote A em `FEEDBACK_CESAR.md` (bloco "Item 2 · Lote A"), `PLANO_CESAR.md` (Diário),
   `HANDOFF.md` (contagens) — e só então começar o **Lote B**.

**Sempre:** um feedback por etapa em `FEEDBACK_CESAR.md` (pedido do usuário). Não passar ao próximo item/lote
com etapa pendente. Sem commit sem autorização.

## Prompts para relançar os agentes

**Etapa 5 — `cesar-tester`:**
> Portão de qualidade, etapa 5 (generalização), do Item 2 lote A do `PLANO_CESAR.md`. Leia `CONTINUAR.md`,
> `.claude/skills/krezio-cesar-context/SKILL.md` e `.claude/skills/krezio-conversation-test/SKILL.md`.
> Já existe um rascunho interrompido em `test/_qa/acceptance_lote_a_probe_test.dart`: leia, complete e rode.
> Objetivo: provar ou refutar que as correções do lote A (test/cesar_p0_r3_test.dart; status "corrigido" em
> docs/qa/findings-*-r3.md) GENERALIZAM, com 30–50 frases **inéditas por eixo** (não reutilize nem parafraseie
> frases de test/cesar_p0_r3_test.dart, r1/r2/r3 ou holdout). Só imprime; prefixos ACCA_FAIL / ACCA_AXIS / ACCA_TOTAL.
> Eixos: (1) receita informal + controles de despesa que parecem receita; (2) multi-lançamento + controles com 2 números
> que não são 2 lançamentos ("apartamento 302", "2 pizzas por 80", "dia 15"); (3) hipóteses que não salvam + controles
> que salvam ("se não me engano…", "se eu gastei 45 ontem registra", "caso você não saiba, paguei 30 de luz");
> (4) datas ditas ao lançar + recorrência real ("todo dia 5", "vence dia 12"); (5) rascunho sem valor + frase nova
> completa + controles de resposta legítima ("50", "deu 230", "foi 1500 no boleto"); (6) referência nome × dia da
> semana (editar/apagar; nada muda sem confirmação), incluindo "não achei X; o mais próximo é X em DD/MM" ⏎ "sim".
> Datas relativas a DateTime.now(). Meta: ≥ 90% por eixo, 0 P0. Achados em docs/qa/findings-aceite-lote-a.md
> (IDs ACC-A-001…). Não edite lib/. Resposta: comando, placar por eixo, total, P0/P1.

**Etapa 6 — `cesar-chaos`:**
> Portão de qualidade, etapa 6 (caos), do Item 2 lote A do `PLANO_CESAR.md`. Leia `CONTINUAR.md`,
> `.claude/skills/krezio-cesar-context/SKILL.md` e `.claude/skills/krezio-chaos-test/SKILL.md`.
> Já existe um rascunho interrompido em `test/_qa/chaos_lote_a_test.dart` (prefixo CHAOS-A|, usa
> test/_qa/chaos_r3_support.dart): leia, complete e rode. Foco em QUEBRAR as mudanças do lote A
> (`_replacesValuelessDraft`, `MoneyDirectionDetector._informalIncoming`, `parseMulti`/`_itemPiece`/slot `split`,
> `HypothesisDetector` — atenção a falso positivo de -ar/-er/-ir/-or após "se" —, `SpokenDayParser` ao lançar,
> "dia N" × recorrência, `_termScore`). Fuzz ≥ 20 seeds novas × 200 turnos enviesado para essas entradas (inclua
> títulos como "Padaria Segunda Via", "Pizzaria Sábado", "Bar Dia 7"); relógio injetado em 1º do mês, 29/02, 31/12,
> domingo × segunda. Invariantes do chaos_r3_support + novos: nenhuma hipótese salva; 2+ valores nunca viram 1
> lançamento em silêncio; nada com data futura sem pergunta; nenhum recorrente sem sinal de recorrência; receita
> nunca salva como despesa (e vice-versa); edição/exclusão nunca atinge outro título sem confirmação mostrando o item.
> Regressão: repita as seeds do chaos_r3_fuzz (20260929+n) e compare com a linha de base de docs/qa/findings-caos-r3.md.
> Achados em docs/qa/findings-caos-lote-a.md (IDs CHAOS-A-001…). Não edite lib/. Resposta: comando, volume,
> violações por invariante, P0/P1.

## Pendências com o usuário (perguntar de novo ao retomar)

1. **Backup:** autorizar commit + push da branch `feat/cesar-v0.5` para `github.com/Grongasx/Krezio.ai`?
   `docs/` e `.claude/` entram no git? (Hoje o projeto **não tem backup nenhum**.)
2. As **5 decisões** da seção "Em aberto" do `HANDOFF.md` — sem resposta; comportamento atual mantido.
