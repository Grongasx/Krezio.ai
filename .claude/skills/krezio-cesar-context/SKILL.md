---
name: krezio-cesar-context
description: Contexto compartilhado do César (assistente de IA do Krezio.ai) — arquitetura do motor de NLP on-device, onde fica cada coisa, como testar, regras do projeto e a "estrela-guia" de fazer o César se comportar como uma LLM sem usar LLM. Leia antes de qualquer trabalho de teste, correção ou funcionalidade no César.
---

# César — contexto compartilhado

O Krezio.ai é um app Flutter de finanças pessoais. O **César** é o assistente de chat/voz.
Ele **não usa LLM**: entende frases com regras + um classificador TF-IDF/regressão logística,
**100% no aparelho** (privacidade, offline, custo zero). Isso é decisão do dono do produto —
**nunca** adicione API de LLM em nuvem, nem modelo generativo embarcado, nem dependência nova
de rede para o César.

## Estrela-guia: "comportar-se como uma LLM"

O objetivo de todo trabalho no César é que o usuário **sinta** que conversa com uma LLM:

1. **Entende linguagem livre** — gírias, erros de digitação, ordem trocada, fala transcrita
   por voz (sem pontuação, números por extenso), frases longas com contexto irrelevante.
2. **Mantém contexto** — lembra o último lançamento/assunto; entende "e ontem?", "esse",
   "o anterior", "muda pra 200", "na verdade foi no crédito".
3. **Faz tudo pelo chat** — criar, consultar, **editar**, **excluir**, desfazer, categorizar,
   criar/renomear categorias, metas, lembretes. Nada deveria exigir sair do chat.
4. **Responde perguntas** sobre os dados ("qual meu maior gasto?", "quanto sobrou?",
   "gastei mais que mês passado?") e sobre si mesmo ("o que você sabe fazer?").
5. **Nunca trava num loop** — se não entendeu, pergunta de forma específica e útil, aceita
   "cancela"/"esquece" a qualquer momento, e uma frase nova completa começa um assunto novo.
6. **Explica o que fez** — confirmações claras ("Registrei R$ 50 no Pix em Mercado"),
   mostra contas ("🧮 3 × R$ 20 = R$ 60"), diz o que assumiu quando assumiu algo.
7. **Não inventa** — nunca registra valor/tipo errado com confiança. Na dúvida, pergunta.
   Registrar errado em silêncio é o pior bug possível num app de finanças.

## Mapa do código (repo: `C:\Projects\Krezio.ai`)

| O quê | Onde |
|---|---|
| Motor de NLP (parse, merge de follow-up, correção, cancelamento) | `lib/ai/local_nlp_engine.dart` (~3000 linhas) |
| Entrada principal | `LocalFinancialNlpEngine.parse(text)` → `FinancialTransactionDraft` |
| Resposta a pergunta pendente | `mergeDrafts(pendingDraft, text)` |
| Correção pós-lançamento | `applyCorrection(lastDraft, text)` |
| Cancelar / frase nova no meio | `isCancelCommand`, `startsNewTransaction` |
| Categorias do usuário | `setCustomCategories`, `matchCustomCategory`, `category_name_matcher.dart` |
| Relatórios/perguntas (RAG local) | `lib/ai/financial_report_rag_engine.dart` |
| "Posso comprar?" | `lib/ai/affordability_analyzer.dart` |
| Metas por chat | `lib/ai/goal_parser.dart` |
| Pagamento de dívida | `lib/ai/debt_payment_parser.dart` |
| Datas relativas | `lib/ai/temporal_date_parser.dart`, `lib/backend/services/calendar_service.dart` |
| Fonte da verdade dos dados | `lib/backend/repositories/financial_repository.dart` (`ChangeNotifier`) |
| Orquestração do chat (ordem das checagens!) | `lib/frontend/features/chat/presentation/screens/chat_screen.dart` → `_sendMessage` |
| Orquestração da voz (espelha o chat) | `lib/ai/voice/voice_conversation_controller.dart` |
| Modelo treinado | `models/on_device/krezio_nlp_model.json` (dataset em `data/`, treino em `scripts/ml/training/`) |

`_sendMessage` no chat decide, **nessa ordem**: cancelar rascunho pendente → correção do
último lançamento → pagamento de dívida → metas → "posso comprar" → relatórios → multi-lançamento
→ parse/merge normal. Uma capacidade nova normalmente entra como um passo nessa cadeia **e**
no `voice_conversation_controller.dart`.

## Regras de engenharia

- **Lógica nova vai em classe Dart pura e testável** em `lib/ai/` (padrão de
  `DebtPaymentParser`, `AffordabilityAnalyzer`), e o chat/voz só a chamam. Não enterre regra
  de negócio em widget — `chat_screen.dart` não tem testes.
- **Todo bug corrigido e toda funcionalidade ganham teste** em `test/` (o motor é testado
  carregando o modelo real — ver `test/nlp_engine_test.dart`, `setUpAll`).
- Siga o estilo do código ao redor: comentários explicam o *porquê*, nomes em inglês,
  textos para o usuário em português do Brasil.
- Regex em Dart: use raw strings `r'...'`. `\b` é ASCII — cuidado com palavras acentuadas.
- Não retreine o modelo nem edite o dataset sem necessidade clara; prefira regra
  determinística com teste. Se retreinar, rode a suíte inteira depois.
- Não quebre o que funciona: rode `flutter test` completo antes de declarar pronto.
  O número de testes passando está no topo de `docs/SESSION_HANDOFF.md`.
- Não faça commit, push nem mexa no Firebase (`lib/firebase_options.dart`).

## Como testar

```bash
# rodar na raiz do repositório (C:\Projects\Krezio.ai)
flutter test                        # suíte completa (~10s)
flutter test test/nlp_engine_test.dart
flutter analyze lib                 # 0 erros é obrigatório
```

**Sonda rápida** para ver o que o motor faz com frases (apague depois, não é teste permanente):

```dart
// test/_qa/probe_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

void main() {
  test('probe', () async {
    final e = LocalFinancialNlpEngine.fromJsonString(
        await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final p in ['gastei 50 no mercado', 'entrada de 500']) {
      final r = e.parse(p);
      print('$p => ${r.intent} ${r.amount} ${r.category} ${r.paymentMethod} missing=${r.missingSlots} prompt=${r.clarificationPrompt}');
    }
  });
}
```

Rode com `flutter test test/_qa/probe_test.dart 2>&1 | grep "=>"`.
Multi-turno: `e.mergeDrafts(e.parse(a), b)`, correção: `e.applyCorrection(draftSalvo, texto)`.

Teste ao vivo (opcional; o app é Flutter web desenhado em canvas — `get_page_text` não lê
nada, só screenshots): `flutter run -d web-server --web-port=8091 --web-hostname=127.0.0.1`.
Parar a tarefa em background **não** mata o `dartvm.exe` — libere a porta pelo PID
(`Get-NetTCPConnection -LocalPort 8091`).

## Onde registrar achados

Um arquivo por origem, para agentes em paralelo não sobrescreverem um ao outro:
`docs/qa/findings-conversa.md` (cesar-tester) e `docs/qa/findings-caos.md` (cesar-chaos).
Corretor e construtor leem todos (`docs/qa/findings-*.md`). Formato de cada linha:

| ID | Severidade | Entrada (frases exatas, multi-turno separado por ` ⏎ `) | Esperado | Obtido | Causa provável | Status |

- **Severidade**: `P0` registra valor/tipo/data errado em silêncio ou perde/corrompe dados;
  `P1` não entende algo comum ou trava em loop; `P2` entende mas responde mal/confuso;
  `P3` polimento.
- **Status**: `aberto` → `corrigido (teste: nome do teste)` ou `não corrigido: motivo`.
- IDs: `CONV-001…` (conversação), `CHAOS-001…` (caos), `FEAT-001…` (lacunas de funcionalidade).
- Antes de adicionar, procure duplicata na tabela.
- Se a ferramenta de escrita recusar gravar o arquivo de relatório (acontece com subagentes),
  **não perca o trabalho**: coloque o conteúdo completo do arquivo na sua resposta final,
  dentro de um bloco de código, com o caminho de destino, para quem te chamou salvar.
  O mesmo vale para atualizações de status: liste `ID → novo status` na resposta final.
