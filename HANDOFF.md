# Krezio.ai — Handoff para nova sessão (atualizado 2026-09-29)

> Leia isto antes de qualquer trabalho. É o resumo do estado atual. O histórico completo,
> sessão por sessão, está em `docs/SESSION_HANDOFF.md` (longo; consulte só o que precisar).
>
> **Backlog completo do produto (macro → micro, do zero):** `BACKLOG.md`.
>
> **⏸️ Trabalho PAUSADO no meio de um plano.** Para retomar exatamente de onde parou, leia
> **`CONTINUAR.md`** (passo a passo). Plano: `PLANO_CESAR.md`. Feedback por etapa: `FEEDBACK_CESAR.md`.

## O projeto em 5 linhas

- App **Flutter** de finanças pessoais com um assistente de chat/voz chamado **César**.
- O César **não usa LLM**: entende frases com regras + classificador TF-IDF, **100% no
  aparelho**. Decisão do dono do produto: continuar sem LLM, mas **se comportar como uma**
  (linguagem livre, contexto, editar/excluir/desfazer e perguntar pelo chat).
- Tentativa de SLM/LiteRT (torch + ai-edge-torch) foi **abandonada e desfeita** a pedido do
  usuário. Não recrie sem pedido explícito.
- Firebase (Auth + Firestore) está **codificado mas não configurado**: `lib/firebase_options.dart`
  ainda tem `REPLACE_ME`, e o app roda em modo local sem login. Falta o usuário rodar
  `flutterfire configure` (passo a passo em `docs/SESSION_HANDOFF.md`, seção Firebase).
- Dono: desenvolve sozinho; fala português; prefere respostas diretas.

## Onde fica e como rodar

- **Local único do projeto:** `C:\Projects\Krezio.ai` (estrutura plana: `pubspec.yaml` na raiz).
  Foi movido do OneDrive em 2026-09-25 porque o Android (`impellerc`, `aapt`) **falha em
  caminhos com acento** ("Área de Trabalho"). **Nunca volte para um caminho com acento.**
- Cópias antigas: `C:\Krezio.ai` (versão de agosto, sem git) e uma pasta vazia em
  `OneDrive\...\Projetos Pessoais\Krezio.ai` — ambas **obsoletas**, o usuário vai apagá-las.
- Comandos (na raiz):
  ```
  flutter test              # 984/984 no último check (30/09, ~11 min; nº varia ±2 com a data)
  flutter analyze lib       # 0 erros (≈113 infos/warnings antigos, ignorar)
  flutter run               # celular Android conectado por USB
  flutter build apk --debug # build/app/outputs/flutter-apk/app-debug.apk
  ```
- **Celular do usuário: Xiaomi Redmi Note 11 (2201117TG).** Para instalar via `flutter run`,
  em Opções do desenvolvedor: "Instalar via USB" (exige conta Mi) e tocar "Instalar" no aviso
  do celular. Erro `INSTALL_FAILED_USER_RESTRICTED` = esse aviso foi recusado/expirou.
- Android já ajustado: `ndkVersion = "28.2.13676358"` (exigido pelo `speech_to_text`) e o
  `AndroidManifest.xml` declara `android.speech.RecognitionService` em `<queries>` (sem isso o
  microfone fica indisponível no Android 11+).
- **Voz do César (TTS) não funciona no celular:** vem de um servidor Python no PC
  (`scripts/synthesize_cesar_onnx.py --server`, porta 8088) e o app procura `127.0.0.1`.
  O chat por texto e o reconhecimento de fala funcionam. Não foi liberado cleartext HTTP.

## Estrutura de `lib/` (separada em 2026-09-25)

- `lib/ai/` — motor de NLP, `CesarAssistant`, perguntas, parsers; `lib/ai/voice/` — voz (TTS/ONNX,
  controlador de conversa, player de áudio). Não depende do front-end.
- `lib/backend/` — `models/`, `repositories/`, `services/` (persistência, auth, sync na nuvem,
  calendário), `config/`.
- `lib/frontend/` — `features/` (telas e widgets) e `theme/`.
- `lib/main.dart` e `lib/firebase_options.dart` ficam na raiz (exigência do Flutter/FlutterFire).
- **Acoplamento conhecido:** os 4 modelos em `backend/models/` importam `frontend/theme/` (cor e
  ícone de categoria vivem no modelo). Para limpar, mova esse mapeamento para o front-end.
- Caminhos `lib/core/...` e `lib/features/...` em `docs/SESSION_HANDOFF.md` e `docs/qa/` são
  históricos: `core/ml` → `ai`, `core/services/voice_*` → `ai/voice`, demais `core/*` → `backend/*`,
  `core/theme` → `frontend/theme`, `features` → `frontend/features`.

## Arquitetura do César (o essencial)

- Motor: `lib/ai/local_nlp_engine.dart` (`parse`, `mergeDrafts`, `applyCorrection`).
- **`lib/ai/cesar_assistant.dart`** concentra comandos (`handleCommand`: editar, excluir
  com confirmação, desfazer, categorias, metas) e perguntas (`handleQuestion`). Chat
  (`lib/frontend/features/chat/.../chat_screen.dart::_sendMessage`) e voz
  (`lib/ai/voice/voice_conversation_controller.dart`) usam as **mesmas** classes.
- Classes puras em `lib/ai/`: `financial_qa_engine` (perguntas = medida × filtro ×
  período), `transaction_reference_resolver` ("o uber de ontem"), `reference_edit_parser`
  (edição sem verbo: "o açougue foi 95"), `money_direction` (receita × despesa por quem paga
  quem), `keyword_typo_corrector` (só "escorregão de dedo"), `pt_number_words` (extenso),
  `chat_action_history` (desfazer, até 20 ações), `hypothesis_detector` ("se eu comprar…" não
  registra — novo em 29/09), `SpokenDayParser` em `temporal_date_parser` (datas faladas, usado pelo
  motor ao lançar **e** pelo resolvedor), entre outras.
- Dados: `lib/backend/repositories/financial_repository.dart` (`ChangeNotifier`, local-first com
  `shared_preferences`; gravações agrupadas por `_persistQueued`).
- Regras de produto fixas: excluir **sempre** pede "sim"; crédito sem parcelas pergunta
  "parcelado ou à vista?"; assinatura sem dia pergunta o dia (e assume "sem prazo" avisando);
  frase sem categoria conhecida pergunta a categoria uma vez; na dúvida o César **pergunta**,
  nunca registra errado em silêncio.

## Qualidade: como medir (e a armadilha)

- Baterias que só imprimem (não falham a suíte), em `test/_qa/`:
  - `conversation_probe_test.dart` — 217/217 (**saturada**, não mede mais nada).
  - `conversation_r2_probe_test.dart` — 279/279 (frases inéditas da rodada 2; **também saturada**).
  - `holdout_probe_test.dart` — 30 frases de conferência independente (~2/3 corretas).
  - **`conversation_r3_probe_test.dart`** — rodada 3, 267 frases inéditas + 20 do eixo "futuro".
    **É a medida atual**: 210/267 antes do lote A → **216/267** depois; futuro 0/20.
    (r2 caiu para 278/279 de propósito: "joga fora a feira de segunda" agora diz "não achei" — ver CONTINUAR.)
  - caos: `chaos_*`, `chaos_r2_*` (0 violações) e **`chaos_r3_{fuzz,reference,persistence}_test.dart`**
    (suporte em `chaos_r3_support.dart`): 38 violações → 19 depois do lote A (todas do lote B).
- **Armadilha comprovada:** corrigir frase a frase leva a 100% na bateria e ~70% em frases
  novas. Toda correção precisa de **regra estrutural** + 5 a 8 frases novas nos testes
  permanentes. Nunca altere uma bateria para ela passar.
- Rodada 3 já feita (29/09). Achados: `docs/qa/findings-conversa-r3.md` e `findings-caos-r3.md`.

## Agentes e skills (em `.claude/`)

- Skills: `krezio-cesar-context` (leia primeiro), `krezio-conversation-test`,
  `krezio-chaos-test`, `krezio-fix-issues` (tem a seção "Contra overfitting"),
  `krezio-llm-features`.
- Agentes: `cesar-tester` e `cesar-chaos` (podem rodar em paralelo; só escrevem em
  `test/_qa/` e `docs/qa/`), depois `cesar-fixer`, depois `cesar-feature-builder` — **um de
  cada vez**, porque mexem nos mesmos arquivos. `training-monitor` resume logs de treino.
- Subagentes às vezes não conseguem gravar `docs/qa/*.md`: nesse caso devolvem o conteúdo na
  resposta e a sessão principal salva.
- Achados e status: `docs/qa/findings-conversa.md`, `findings-caos.md`,
  `findings-conversa-r2.md`, `findings-caos-r2.md`, **`findings-conversa-r3.md`, `findings-caos-r3.md`**.

## Em aberto

**Decisões pendentes do usuário (não mude sem perguntar):**
1. "paguei 3 meses de academia de 100" registra R$ 300 (3 × 100) — ou 100 é o total?
2. "oitenta e sete e cinquenta" = R$ 87,50 (logo "cinquenta e trinta" = R$ 50,30) — aceitável?
3. Transferência entre contas próprias (ex.: poupança) deve reduzir o saldo? (hoje reduz)
4. Categoria "Supermarket" vira personalizada (`supermarket_2`) em vez de sobrescrever a nativa — ok?
5. "recebi 4700 de salário" com salário já lançado no mês: perguntar se é correção? (hoje registra)

**Em andamento (plano v0.5):** Item 2, lote A. Portão: etapas 5 e 6 reprovaram (listas fechadas não generalizavam);
etapa 7a (direção do dinheiro + hipóteses) **concluída** — aceite 218/244; etapa **7b (valores, datas, rascunho, resolvedor) ficou PELA METADE** — `test/cesar_gate_a_7b_test.dart` tem 28 falhas
esperadas (suíte vermelha de propósito até terminar); detalhes e prompt em `CONTINUAR.md`. Novos: `MoneyDirection.unclear` (César pergunta "entrou ou saiu?"),
`HypothesisDetector` reescrito, `CesarAssistant.hypothesisReply`. Baterias de portão: `test/_qa/acceptance_lote_a_probe_test.dart`,
`test/_qa/chaos_lote_a_test.dart`; achados `docs/qa/findings-aceite-lote-a.md`, `findings-caos-lote-a.md`.
Decisão nova pendente: "gastei 25 na netflix" vira recorrente só pela categoria (CHAOS-A-022) — desenho ou bug?

**Pendências conhecidas (P2):** "esquece esse último" não oferece apagar; "qual a média que eu
gasto por dia?" responde o orçamento diário, não a média; "quanto sobra se eu pagar o aluguel?"
ignora a hipótese; "apaguei as luzes… 20 na padaria" salva título "Luz"; um comentário ("o
mercado tá caro demais") abre rascunho pedindo valor em vez de só conversar; duas abas no web
sobrescrevem uma à outra (limitação de arquitetura).

**Git e backup (importante):** branch atual **`feat/cesar-v0.5`** (criada em 29/09, sem commits próprios);
último commit `62ab336 v0.4.0`; **~75+ alterações sem commit** (inclui o lote A)
(todo o trabalho do César desde então). Remoto: `github.com/Grongasx/Krezio.ai`. O projeto
**não tem mais backup do OneDrive**. Além disso o `.gitignore` exclui `docs/`, `data/`,
`scripts/` e `.agents/` — o histórico em `docs/` e os relatórios de QA **não estão em lugar
nenhum além deste disco**. Sugira ao usuário um commit + push (e decidir se `docs/` e
`.claude/` entram no git). Não faça commit sem ele pedir.

## Regras desta pasta

- `CLAUDE.md` está em **modo silencioso**: responda com código, diffs ou comandos; não explique
  código sem pedido. Logs de treino Python vão para `training_logs.txt` e são lidos com
  `tail`/`grep` ou `python log_compressor.py training_logs.txt` (gera um `.summary.json`).
- Treino do modelo on-device: `scripts/ml/training/` (scikit-learn/ONNX, gera
  `models/on_device/krezio_nlp_model.json`). Prefira regra determinística com teste a retreinar.
