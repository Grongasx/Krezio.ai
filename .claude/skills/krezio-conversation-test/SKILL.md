---
name: krezio-conversation-test
description: Testa o César como um usuário real conversando com uma LLM — gera centenas de frases variadas (formais, gírias, erros, fala transcrita, multi-turno, perguntas, edição/exclusão por chat), roda no motor real e registra cada falha em docs/qa/findings-conversa.md. Use para "testar o César", "procurar problemas na IA", "QA do chat".
---

# Teste de conversação do César

Leia primeiro `.claude/skills/krezio-cesar-context/SKILL.md`.

Você é o QA. **Não corrige código** — só encontra, reproduz e registra. O entregável é
`docs/qa/findings-conversa.md` com achados reproduzíveis e priorizados.

## Método

1. **Monte uma bateria** em `test/_qa/conversation_probe_test.dart` (use o padrão de sonda da
   skill de contexto). Para cada cenário, imprima `entrada => intent amount category payment
   missing isComplete prompt`, e para multi-turno encadeie `parse` → `mergeDrafts` /
   `applyCorrection`. Escreva o **resultado esperado** ao lado de cada caso e faça o próprio
   teste comparar e imprimir só as divergências — assim a saída é a lista de bugs.

2. **Cubra as personas** (pelo menos 15 frases por eixo; varie valores, datas, formas de pagamento):
   - **Formal**: "Efetuei um pagamento de R$ 1.250,90 referente ao aluguel via boleto."
   - **Coloquial/gíria**: "torrei 50 conto no bar", "caiu o salário", "passei 30 no débito".
   - **Voz transcrita** (sem pontuação, número por extenso, "vírgula"): "gastei cinquenta e
     dois reais e noventa centavos no mercado no pix", "paguei mil e duzentos de aluguel".
   - **Digitação ruim**: "gasteu 40 no mercadp no pics", "recebie 300", tudo em CAIXA ALTA.
   - **Frase longa com ruído**: "hoje foi corrido, saí cedo e acabei almoçando fora, deu 45 no crédito".
   - **Todos os tipos**: despesa, receita, transferência, parcelado, assinatura, conta com
     vencimento, empréstimo a receber, pagamento de dívida, meta, "posso comprar", diárias,
     quantidade × preço, dia útil.
   - **Perguntas (Q&A)**: "quanto gastei esse mês?", "qual meu maior gasto?", "quanto gastei
     com uber?", "quanto sobrou?", "tenho conta vencendo?", "quem me deve?", "o que você faz?",
     "gastei mais que mês passado?". Use `FinancialReportRagEngine` com um
     `FinancialRepository()` (já vem com dados de demonstração).
   - **Edição/exclusão/desfazer por chat**: "apaga o último", "exclui o uber de ontem",
     "muda o valor pra 80", "na verdade foi 45", "troca pra débito", "desfaz", "esse era
     lazer", "renomeia a categoria pets para animais". Registre como `FEAT-` o que o
     César ainda **não sabe fazer** — isso alimenta o construtor de funcionalidades.
   - **Contexto/multi-turno**: responder só "pix", só "200", só "mercado"; mudar de assunto no
     meio; "e ontem?" depois de uma pergunta; duas correções seguidas.

3. **Classifique** pela severidade da skill de contexto. Seja rigoroso com `P0`: qualquer
   caso em que o César registraria algo errado sem perguntar.

4. **Registre** em `docs/qa/findings-conversa.md` (crie com o cabeçalho da tabela se não existir;
   não duplique achados). Uma linha por problema distinto — agrupe variações da mesma causa
   numa linha só, listando 2–3 frases de exemplo.

5. **Relate** no final: total de casos rodados, % que passou por eixo, top 10 achados por
   severidade. Deixe `test/_qa/conversation_probe_test.dart` no lugar (o corretor reutiliza),
   mas garanta que ele **não falha** a suíte: imprima divergências, não use `expect`.

## Não faça

- Não altere nada em `lib/`.
- Não registre como bug um comportamento que é decisão documentada em `docs/SESSION_HANDOFF.md`
  (ex.: "3 bolos por 25 reais" = total, de propósito).
- Não invente saída: todo "Obtido" na tabela tem que ter vindo de execução real.
