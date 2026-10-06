---
name: krezio-fix-issues
description: Corrige os problemas abertos do César listados em docs/qa/findings-*.md, por ordem de severidade — reproduz com teste que falha, corrige na causa, roda a suíte inteira e atualiza o status. Use para "consertar os achados", "corrigir os bugs da IA", depois de rodar os testes de conversação ou do caos.
---

# Corrigir achados do César

Leia primeiro `.claude/skills/krezio-cesar-context/SKILL.md`.

## Ordem de trabalho

Pegue os achados `aberto` de `docs/qa/findings-*.md`, **P0 primeiro**, depois P1, P2.
`FEAT-` não é seu — é do construtor de funcionalidades; pule.

Para cada achado:

1. **Reproduza** com um teste permanente em `test/` (no arquivo do assunto:
   `nlp_engine_test.dart`, `financial_repository_test.dart`, etc.), dentro de um `group`
   com nome descritivo em português. Rode e **veja falhar**. Se não falhar, o achado não se
   reproduz — marque `não reproduz` com a evidência e siga.
2. **Ache a causa**, não o sintoma. Frases parecidas costumam ter a mesma raiz — corrija a
   regra, não a frase. Adicione ao teste 2–3 variações da frase para provar que generalizou.
3. **Corrija** com a menor mudança que resolve a causa. Prefira regra determinística com
   comentário explicando o porquê. Se a correção for no fluxo do chat, coloque a lógica numa
   função testável do motor/repositório e faça `chat_screen.dart` **e**
   `voice_conversation_controller.dart` chamarem-na.
4. **Rode a suíte inteira** (`flutter test`) e `flutter analyze lib`. Uma correção que
   quebra outro teste não está pronta: ou ajuste a regra, ou — só se o teste antigo codificava
   o comportamento errado — atualize-o explicando no relatório.
5. **Atualize a linha** no `docs/qa/findings-*.md` de origem: `corrigido (teste: <nome do teste>)`.

Quando um achado exigir decisão de produto (ambiguidade real, ex.: "2 pizzas de 40" é total
ou unitário?), **não decida sozinho**: marque `decisão pendente: <pergunta objetiva>` e siga.

## Contra overfitting (lição da rodada 2)

Na rodada 1 a bateria chegou a 217/217, mas com frases inéditas o César acertou só 72%:
o que foi corrigido frase a frase ("Efetuei um pagamento") não generalizou ("Comunico o
pagamento da taxa…" continuou virando receita). Por isso:

- **Antes de marcar `corrigido`, escreva de 5 a 8 frases novas** que o achado não listava:
  outros verbos, ordem, registro formal e coloquial, regionalismo. Coloque-as no teste de
  regressão. Se a correção só passa nas frases do relatório, ela é um `if` disfarçado:
  volte e ache a regra.
- Prefira **regras estruturais** a listas de palavras: "tem verbo de lançamento + valor ⇒
  não é comando", "cita um lançamento existente e muda um campo ⇒ edição", "pedaço de
  multi-lançamento sem verbo próprio não é lançamento". Uma lista de palavras só é aceitável
  para vocabulário de verdade (nomes de lojas, categorias).
- Quando existir uma bateria de generalização (`test/_qa/*_r2_*`), rode-a antes e depois e
  reporte os dois placares. **Nunca** altere essa bateria para passar.

## No final

- `flutter test` inteiro verde e `flutter analyze lib` sem erros — cole a última linha de cada.
- Apague sondas que você criou (`test/_qa/*probe*`) se já viraram testes permanentes; mantenha
  o resto de `test/_qa/` funcionando (sem falhar).
- Atualize a contagem de testes em `docs/SESSION_HANDOFF.md` e acrescente uma seção curta
  da sessão com os arquivos/funções alterados.
- Relate: achados corrigidos (ID → teste), não corrigidos (ID → motivo), decisões pendentes.

## Não faça

- Não "corrija" desligando o teste, relaxando o `expect` ou tratando a frase exata com `if`.
- Não retreine o modelo para tapar um caso isolado.
- Não mude comportamento documentado como decisão em `docs/SESSION_HANDOFF.md` sem registrar como decisão pendente.
