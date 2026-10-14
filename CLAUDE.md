# Regras de sessão — isolamento de logs e economia de contexto

- MODO SILENCIOSO ATIVO: Retorne apenas código funcional, diffs ou comandos de terminal. Nunca explique o código gerado a menos que explicitamente solicitado.
- INTERCEPTAÇÃO DE LOGS: Ao rodar scripts de treinamento Python, NUNCA exiba o log completo no terminal. Redirecione saídas para `training_logs.txt` (ex: `python train.py > training_logs.txt 2>&1`).
- LEITURA RESTRITA: Se um erro ocorrer durante o treino, use ferramentas de bash (`tail -n 20`, `grep`) para ler apenas as últimas linhas do erro. Nunca injete o log inteiro no contexto.

## Ferramentas de log

- `python log_compressor.py training_logs.txt` → gera `training_logs.summary.json` (sem barras tqdm e sem
  linhas duplicadas; só erros críticos, picos de gradiente e as métricas finais). Leia o `.json`, não o `.txt`.
- Status do treino: delegue ao subagente `training-monitor` ("Analise como está o treinamento").

## Projeto

- **Antes de qualquer trabalho, leia `HANDOFF.md`** (estado atual, decisões pendentes, armadilhas).
- App Flutter: esta pasta (testes: `flutter test`; histórico completo em `docs/SESSION_HANDOFF.md`).
- Treino do modelo on-device do César: `scripts/ml/training/` (scikit-learn/ONNX).
  Ex.: `python scripts/ml/training/train_nlp_model.py > training_logs.txt 2>&1`

## Repositórios e backup

- **Público** `Grongasx/Krezio.ai`: app, testes e documentos da raiz. O `.gitignore` exclui `docs/`, `data/`, `scripts/` e `.agents/`.
- **Privado** `Grongasx/Krezio.ai-private`: só `docs/`, `data/`, `scripts/` e `.agents/`, com git próprio em
  `C:\Projects\.krezio-private.git` (usa esta pasta como área de trabalho). Nunca mova essas pastas para o repositório público.
- Atualizar o backup privado: `bash scripts/backup_private.sh ["mensagem"]` (só faz commit se algo mudou). Rode ao fim de
  sessões que alterarem `docs/`, `data/` ou `scripts/`.
- Backlog no GitHub (issues + Project #8): `python scripts/github/create_backlog.py` sincroniza o `BACKLOG.md`;
  `python scripts/github/project_mothers.py --project 8` deixa no Project só os épicos de fase.
- **Decisões vão para o card:** toda tarefa que exige uma decisão ganha um comentário na issue do card
  (`gh issue comment <nº>`), com o título `### ✅ Decisão tomada …` (o que foi decidido e por quê) ou
  `### ⏳ Decisão pendente …` (as opções, para o usuário responder ali).
