---
name: krezio-llm-features
description: Adiciona ao César capacidades que o fazem parecer uma LLM, sem usar LLM — perguntas e respostas sobre os dados, edição e exclusão de lançamentos por chat, desfazer, memória de contexto e referências ("esse", "o de ontem"), ajuda, explicações. Tudo on-device, em classes testáveis. Use para "adicionar funcionalidades de IA", "deixar o César como uma LLM", "editar/excluir pelo chat", "perguntas e respostas".
---

# Funcionalidades "tipo LLM" para o César

Leia primeiro `.claude/skills/krezio-cesar-context/SKILL.md` (especialmente a estrela-guia).

## Backlog (em ordem de valor — faça de cima para baixo)

Antes de começar, confira em `docs/qa/findings-*.md` os `FEAT-` abertos e o que já existe no
código — não refaça o que já funciona.

1. **Editar lançamento por chat, por referência** — não só o último:
   "muda o valor do mercado de ontem pra 80", "o uber de segunda foi no débito",
   "renomeia o último para Padaria", "esse era lazer". Precisa de um **resolvedor de
   referência**: dado um texto, encontra a(s) transação(ões) no repositório por descrição,
   categoria, data relativa ("ontem", "segunda", "semana passada"), valor, ou posição
   ("o último", "o penúltimo"). Se casar mais de uma, **pergunte qual** listando as opções.
2. **Excluir por chat, com confirmação**: "apaga o uber de ontem", "exclui os lançamentos de
   hoje", "remove a assinatura da netflix". Excluir é destrutivo — o César mostra o que vai
   apagar e só apaga depois de "sim"; "não"/qualquer outra coisa cancela.
3. **Desfazer**: "desfaz", "volta atrás", "não era isso" desfaz a última ação do chat
   (criação, edição ou exclusão) — guarde uma pilha curta de ações reversíveis.
4. **Perguntas e respostas sobre os dados** (além dos relatórios que já existem):
   maior/menor gasto do período, média diária, gasto por dia da semana, comparação entre
   períodos ou categorias, "quanto posso gastar por dia até o fim do mês", "quando foi a
   última vez que paguei X", "quantas vezes fui ao iFood esse mês", lista dos últimos N
   lançamentos. Respostas curtas, com número e uma frase de contexto.
5. **Memória de contexto da conversa**: seguimento de perguntas ("e em transporte?",
   "e no mês passado?", "e ontem?") reaproveitando o último filtro; pronomes ("esse",
   "ele", "o anterior") apontando para a última transação/assunto citado.
6. **Ajuda e autoconsciência**: "o que você sabe fazer?", "como eu apago um lançamento?",
   "por que você colocou isso em lazer?" (explica a regra/palavra que decidiu a categoria).
7. **Categorias por chat**: "cria a categoria Pets com limite de 200", "renomeia Pets para
   Animais", "apaga a categoria Pets" (com confirmação), "aumenta o limite de mercado pra 1500".

## Como construir cada item

1. **Projete a interface** numa classe Dart pura em `lib/ai/` (ex.:
   `transaction_reference_resolver.dart`, `chat_command_parser.dart`,
   `conversation_context.dart`, `financial_qa_engine.dart`). Entrada: texto (+ contexto/
   repositório). Saída: um objeto de resultado imutável (o que fazer, com quais alvos,
   texto de resposta, se precisa confirmação). **Sem Flutter/widgets nessas classes.**
2. **Teste primeiro**: arquivo novo em `test/` com casos felizes, variações de linguagem
   (gíria, erro de digitação, voz), ambiguidade (2+ alvos), nada encontrado, e **não
   disparar** em frases que são lançamentos normais ("apaguei a luz e gastei 50" é despesa!).
3. **Implemente** até passar.
4. **Conecte** em `chat_screen.dart::_sendMessage` **na posição certa da cadeia** (comandos
   explícitos de editar/excluir/desfazer antes do parse de lançamento; Q&A junto dos
   relatórios) e espelhe em `voice_conversation_controller.dart`. Estados de confirmação
   pendente (excluir) seguem o mesmo padrão de `_activeDraft`: a próxima mensagem responde.
5. **Suíte inteira verde** + `flutter analyze lib` sem erros, a cada item — não acumule.

## Qualidade de resposta (é isso que faz parecer LLM)

- Confirme o que entendeu com os dados concretos: "Mudei **Mercado (ontem, R$ 45,00)** para R$ 80,00."
- Quando assumir algo, diga: "Considerei o lançamento mais recente com 'uber'."
- Quando não achar: diga o que procurou e sugira: "Não achei nenhum lançamento de 'uber'
  ontem. Os últimos com 'uber' foram 14/09 e 10/09 — quer editar algum deles?"
- Varie levemente as frases de confirmação (2–3 variantes) para não soar robótico, mas de
  forma determinística nos testes (ex.: escolha por hash do texto, não `Random()`).

## No final

Atualize `docs/SESSION_HANDOFF.md` (inventário de features + contagem de testes) e relate:
itens entregues (com os testes), itens não feitos e por quê, frases de exemplo para o
usuário testar no app.

## Não faça

- Nada de LLM em nuvem, modelo generativo, nem pacote de rede.
- Não apague sem confirmação. Não edite em lote sem listar o que vai mudar.
- Não quebre os fluxos existentes (lançar, corrigir o último, cancelar, relatórios, metas, dívidas).
