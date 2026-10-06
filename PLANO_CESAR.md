# Plano de implementação — César v0.5 ("consultor que conversa")

> Documento vivo. Cada item só é iniciado depois que o anterior passar **inteiro** pelo
> Portão de Qualidade (seção 2). Atualize a coluna **Status** e o **Diário** ao fim de cada etapa.
> Contexto obrigatório antes de começar: `HANDOFF.md` + skill `krezio-cesar-context`.

## 0. Pré-requisitos (antes do Item 1)

| # | Tarefa | Quem | Status |
|---|---|---|---|
| 0.1 | Backup: commit + push das ~75 alterações pendentes (e decidir se `docs/` e `.claude/` entram no git) | Usuário autoriza → Claude executa | ⏳ |
| 0.2 | Linha de base: `flutter test` (anotar nº de testes) + `flutter analyze lib` (0 erros) | Claude | ✅ 768/768 (após corrigir teste dependente de data), 0 erros |
| 0.3 | Responder as 5 decisões pendentes do `HANDOFF.md` (academia 3×100, "oitenta e sete e cinquenta", transferência p/ poupança, "Supermarket", salário duplicado) | Usuário | ⏳ |
| 0.4 | Criar branch de trabalho `feat/cesar-v0.5` | Claude | ✅ |

## 1. Itens, em ordem de execução

| # | Item | Por que nesta posição | Status |
|---|---|---|---|
| 1 | **Rodada 3 de medição** — frases inéditas (conversa + caos) | Mede onde o César erra *hoje*; as baterias r1/r2 estão saturadas. Os achados alimentam o Item 2. | ✅ 210/267; 7 P0 |
| 2 | **Pendências P2 + achados da Rodada 3** | Barato, corrige erros conhecidos antes de construir em cima. | 🔶 Lote A implementado; portão em andamento (⏸️) |
| 3 | **Simulações "e se…?"** | Maior salto de "parece uma LLM"; reaproveita `FinancialQaEngine` e `AffordabilityAnalyzer`. | ⏳ |
| 4 | **César consultor** (onde economizar, projeção do mês, assinaturas esquecidas) | Depende das médias/projeções do Item 3. | ⏳ |
| 5 | **César proativo** (resumo semanal, gasto fora do padrão) | Reaproveita os cálculos do Item 4. | ⏳ |
| 6 | **Voz no celular** (TTS nativo do Android como alternativa ao servidor do PC) | Independente da lógica; por último para não misturar mudanças de plataforma com mudanças de NLP. | ⏳ |

### Item 1 — Rodada 3 de medição
- **Skills/agentes:** `krezio-conversation-test` (`cesar-tester`) + `krezio-chaos-test` (`cesar-chaos`), em paralelo.
- **Entregas:** `test/_qa/conversation_r3_probe_test.dart` (≥250 frases **inéditas**, sem reutilizar r1/r2/holdout),
  `test/_qa/chaos_r3_*_test.dart`, `docs/qa/findings-conversa-r3.md`, `docs/qa/findings-caos-r3.md`.
- **Cobertura mínima:** gírias, fala transcrita (sem pontuação, números por extenso), multi-turno, edição/exclusão
  por referência, perguntas, comentários sem intenção de lançar, frases das features dos Itens 3–5 (para já registrar
  a linha de base delas como `FEAT-xxx`).
- **Pronto quando:** baterias rodam, taxa de acerto registrada no Diário, achados classificados P0–P3 sem duplicatas.

### Item 2 — Pendências P2 + achados da Rodada 3
- **Skill/agente:** `krezio-fix-issues` (`cesar-fixer`), P0 → P1 → P2.
- **Escopo fixo (do HANDOFF):**
  1. "esquece esse último" → oferecer apagar o último lançamento (com confirmação "sim").
  2. "qual a média que eu gasto por dia?" → média real (gasto do período ÷ dias decorridos), não o orçamento diário.
  3. Comentário sem valor ("o mercado tá caro demais") → só conversar, sem abrir rascunho.
  4. "apaguei as luzes… 20 na padaria" → título/categoria vêm do trecho com valor, não de palavra solta.
  5. (Fica fora: duas abas no web sobrescrevendo — limitação de arquitetura, resolve-se com o Firebase.)
- **Mais:** todos os P0/P1 da Rodada 3; P2 da Rodada 3 quando a correção for estrutural.
- **Pronto quando:** Portão de Qualidade + 0 P0/P1 abertos em `findings-*-r3.md`.

### Item 3 — Simulações "e se…?"
- **Skill/agente:** `krezio-llm-features` (`cesar-feature-builder`).
- **Classe nova:** `lib/ai/what_if_simulator.dart` (pura, sem Flutter), chamada por `CesarAssistant.handleQuestion`.
- **Frases-alvo (exemplos, a bateria de aceite usa outras):**
  - "quanto sobra se eu pagar o aluguel?" (usa conta/lançamento existente pelo nome)
  - "e se eu gastar 300 no mercado, ainda fecho o mês no azul?"
  - "se eu cortar o delivery, quanto economizo por mês?" (média dos últimos 3 meses da categoria)
  - "se eu guardar 200 por mês, quando bato a meta da viagem?"
- **Regras:** nunca registra nada (é hipótese); resposta mostra a conta (🧮); quando falta dado, diz o que assumiu.
- **Pronto quando:** Portão de Qualidade.

### Item 4 — César consultor
- **Classe nova:** `lib/ai/spending_advisor.dart`.
- **Capacidades:**
  1. "onde posso economizar?" → top 3 categorias que mais cresceram vs. média de 3 meses + recorrentes.
  2. "como vou fechar o mês?" → projeção: saldo atual − contas futuras − (média diária × dias restantes).
     Também responde "quanto vai vir a conta de luz?" (média das últimas ocorrências) — resolve o 🟡 "previsão de faturas".
  3. Assinaturas esquecidas → recorrências ativas há ≥3 meses, listadas com o total anual.
- **Regras:** com menos de 1 mês de histórico, responde que ainda não tem dados suficientes (não inventa).
- **Pronto quando:** Portão de Qualidade.

### Item 5 — César proativo
- **Onde:** `financial_repository.getProactiveAlerts()` + saudação do chat.
- **Capacidades:**
  1. Resumo semanal na primeira abertura do chat na segunda-feira (ou após 7 dias sem abrir): gasto da semana,
     categoria principal, comparação com a semana anterior.
  2. Gasto fora do padrão: categoria com gasto semanal ≥ 2× a média semanal das últimas 4 semanas.
- **Regras:** cada alerta aparece uma vez (persistir "já visto"); nunca mais de 2 alertas proativos por abertura;
  "para de me avisar disso" desativa o tipo de alerta.
- **Pronto quando:** Portão de Qualidade + checagem manual de que não aparece repetido após reload.

### Item 6 — Voz no celular
- **Abordagem:** `flutter_tts` (voz nativa do sistema) como alternativa quando o servidor ONNX (`127.0.0.1:8088`)
  não responder; o servidor continua sendo o preferido quando disponível.
- **Onde:** `lib/ai/voice/voice_synthesis_service.dart` (interface + seleção de motor), sem mudar o controlador de conversa.
- **Pronto quando:** Portão de Qualidade + teste no Redmi Note 11 (o César fala uma resposta com o PC desligado do servidor).
  Este item depende do usuário para o teste no aparelho.

## 2. Portão de Qualidade (pipeline por item)

Cada item percorre as etapas **na ordem**. Qualquer falha volta para a etapa 3. Não se passa ao próximo
item com etapa pendente.

| Etapa | O quê | Ferramenta | Critério de saída |
|---|---|---|---|
| 1. Especificação | Frases-alvo + critérios de aceite escritos no Diário | — | Revisado contra a estrela-guia (skill de contexto) |
| 2. Testes primeiro | Testes que **falham** para cada critério | `flutter test <arquivo>` | Falham pelo motivo certo |
| 3. Implementação | Classe pura em `lib/ai/` + integração em `CesarAssistant` (chat **e** voz) | skill do item | Testes da etapa 2 passam |
| 4. Regressão | Suíte inteira + análise estática | `flutter test`, `flutter analyze lib` | 100% verde, 0 erros, nº de testes ≥ linha de base |
| 5. Generalização | Bateria de aceite com 30–50 frases **inéditas** escritas depois da implementação | `cesar-tester` | ≥ 90% corretas; 0 P0 |
| 6. Caos | Fuzz com seed + entradas hostis + fluxos interrompidos na feature nova | `cesar-chaos` | 0 violações de invariante (saldo, duplicata, perda) |
| 7. Correção | Achados das etapas 5–6 corrigidos com regra estrutural + 5–8 frases novas em teste permanente | `cesar-fixer` | 0 P0/P1; repetir 4–6 com frases **novas** |
| 8. Revisão de código | Bugs e simplificação no diff do item | `/code-review high`, `/simplify` | Achados resolvidos ou justificados |
| 9. Ao vivo | Rodar o app e exercitar as frases-alvo | skill `run` (web :8091 + screenshot) | Comportamento igual ao dos testes |
| 10. Registro | Atualizar `HANDOFF.md`, `findings-*`, `CHANGELOG.md`, este plano | — | Status ✅ + entrada no Diário |

**Regra contra overfitting:** nunca altere uma bateria para ela passar; nunca conserte frase a frase.
Cada correção precisa de uma regra estrutural, e a revalidação usa frases que o corretor não viu.

**Agentes:** `cesar-tester` e `cesar-chaos` podem rodar em paralelo; `cesar-fixer` e
`cesar-feature-builder` rodam **um de cada vez** (mexem nos mesmos arquivos).

## 3. Riscos

- **Conflito com o parser de lançamentos:** "se eu gastar 300…" não pode virar lançamento. Mitigação: a
  detecção de hipótese ("se eu", "e se", "caso eu") entra **antes** do parse na cadeia do `CesarAssistant`, com
  testes negativos ("se eu gastei 50 ontem, registra" deve continuar registrando).
- **Dados insuficientes** em contas novas → respostas honestas ("ainda não tenho 1 mês de dados").
- **Crescimento de `local_nlp_engine.dart` (~3000 linhas):** lógica nova vai em classes separadas.
- **Sem backup:** por isso o item 0.1 vem primeiro.

## 4. Diário

| Data | Item/etapa | Resultado |
|---|---|---|
| 2026-09-29 | Plano criado | Aprovado ("pode implementar"); 0.1 e 0.3 sem resposta → sem commit, comportamento atual mantido |
| 2026-09-29 | Item 0 | Linha de base 768/768 após corrigir teste dependente de data. Ver FEEDBACK_CESAR.md |
| 2026-09-29 | Item 1 | Conversa r3 210/267 (78,7%), futuro 0/20; caos 7.826 turnos, 4 P0. Suíte 775/775 |
| 2026-09-29 | Item 2 · Lote A | 7 P0 corrigidos; suíte 905/905; r3 216/267; caos 19 viol. Portão parado nas etapas 5–6 |
| 2026-09-29 | ⏸️ Pausa | Pedido do usuário. Retomar por CONTINUAR.md |
| 2026-09-30 | Lote A · portão 5–7a | Etapa 5 ❌ 198/244; etapa 6 ❌ 16 P0; 7a ✅ → aceite 218/244 |
| 2026-09-30 | ⏸️ Pausa | Antes da 7b (nada alterado). Retomar por CONTINUAR.md |
| 2026-09-30 | ⏸️ Pausa (meio da 7b) | 7b parcial: gate_a_7b 101✅/28❌ (TDD), testes antigos verdes, analyze 0 erros |
