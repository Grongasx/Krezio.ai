# Changelog

Todos os marcos relevantes e alterações significativas do projecto **Krezio.ai** serão documentados neste ficheiro.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/) e este projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

---

## [Unreleased]

### Added
- Plataforma iOS (`ios/`, bundle `com.krezio.ai`), com as permissões de microfone e de reconhecimento de fala.
- CI no GitHub Actions (`.github/workflows/ci.yml`): análise estática e testes de regressão em todo PR e push no `main`.
- `CONTRIBUTING.md` com o fluxo de branches, commits convencionais, versões e tags.
- `README.md` do projeto: o que é, como rodar, como testar, estrutura de pastas.
- César: portão único antes de gravar (`EntrySafetyGate`), pergunta "Registro assim?" quando a certeza é baixa
  (`EntryCertainty`), separação entre resposta e assunto novo (`PendingReplyCheck`), detecção de planos e
  não-eventos (`HypothesisDetector`), datas faladas, vários lançamentos numa frase, edição, exclusão e desfazer por conversa.
- Firebase Auth + Firestore codificados (login, cadastro, sincronização local-first), ainda sem configurar.
- Backlog do produto (`BACKLOG.md`) sincronizado com as issues e o GitHub Project.
- Extrato agrupado por dia com total do dia, filtros combináveis (período, tipo, categoria, forma de pagamento) e
  busca sem acento.
- Contas e carteiras com saldo por conta, transferência entre contas próprias e fatura do cartão de crédito
  (fechamento, vencimento e parcelas por fatura).
- Tela de contas em aberto e devedores; pagar uma conta cria a despesa.
- Orçamento com faixas verde/amarela/vermelha e "Faltam/Passou R$ X".
- César: código de cada lançamento (`#4821`), consultas a lançamentos antigos ("lembra do restaurante?"),
  vários ajustes numa frase, chips presos ao card, parcelado com dia de vencimento, quinto dia útil com sábado.
- César consultor: "onde posso economizar?", "como vou fechar o mês?", "quanto vem a luz?", assinaturas,
  simulações "e se…?", média diária real, resumo semanal e aviso de gasto fora do padrão.
- Preferências: nome do usuário e forma de pagamento mais usada como sugestão.
- Voz do sistema como alternativa à voz neural (padrão no celular) e encerramento do mãos-livres por
  "tchau César" ou silêncio.
- Perfil, tema claro/escuro/sistema, bloqueio por PIN e biometria, bloqueio automático, termos de uso,
  política de privacidade, exportação JSON/CSV, exclusão de conta, onboarding e configuração inicial.
- Testes de widget das telas principais em tela de 360 px.

### Changed
- "desfaz" depois de uma correção também esquece a memória de categoria.
- Criar uma categoria com o nome interno de uma nativa ("Supermarket") reaproveita a nativa.
- Apagar uma categoria pergunta para onde mover os lançamentos.

- `lib/` reorganizado em `ai/`, `backend/` e `frontend/` (antes `core/` e `features/`).
- Nome do app padronizado como "Krezio.ai" no iOS e na web.
- `.gitignore` passa a excluir o modelo de voz Piper (~139 MB) e os áudios temporários.

### Fixed
- Overflows de layout em celular de 360 px: barra do chat, formulário de lançamento, card do extrato e total filtrado.

## [v0.4.0] - 2026-09-03

### Added
- Telas do app: dashboard (resumo, gráfico por categoria, insight do César), extrato, orçamentos, configurações e
  navegação principal.
- Formulário de novo lançamento e card de lançamento do extrato.
- Plataforma Windows.

### Changed
- Motor de linguagem, modelos e repositório financeiro ampliados; modelo on-device retreinado.
- Configuração do Android ajustada (NDK exigido pelo `speech_to_text` e `RecognitionService` em `<queries>`).

## [v0.3.2-alpha] - 2026-08-21

### Added
- Skill de Versionamento e Gestão de Releases (`versioning-and-releases`).
- Documentação Oficial de Release (`docs/releases/v0.3.2-alpha.md`).
- Skill de Brand Guidelines e Design System (`krezio-brand`).
- Skill de Documentação de Processo de Software (`krezio-documentation`).
- Pacote e Skill do `code-review-graph` (`code-review-graph`) para análise de grafo de dependências e blast radius.
- Skill de Documentação Acadêmica para TG/TCC segundo normas ABNT (`tg-abnt-documentation`).
- Gerador de Dataset Sintético Expandido com 10.000 amostras e OOD (`scripts/ml/generate_dataset_10k.py`).
- Suíte de Benchmarking Multi-Algoritmo com Gráficos (`scripts/ml/training/benchmark_suite.py`).
- Gráficos de Benchmarking em High-Res (`docs/charts/accuracy_by_split.png`, `algorithm_comparison.png`, `confusion_matrix_intent.png`).
- Engine de PLN Financeira Comercial em Dart com Proteção Anti-Alucinação (`lib/core/ml/local_nlp_engine.dart`).
- Analisador de Incompletude de Slots, Clarificação Empática (`krezio-brand`) e Fusão de Contexto Multi-Turno (`mergeDrafts`).
- Interface de Chat Interativo em Flutter para Teste do Usuário (`lib/features/chat/presentation/screens/chat_screen.dart`).
- Suítes de Testes Adversariais (2.000 amostras) e Chat Não-Financeiro (500 amostras) com 100% de Acurácia.
- Registros de Arquitetura (`docs/architecture/adr/2026-08-21-slot-disambiguation-prompting.md`) e Atualização do Capítulo 4 do TG (`docs/tg/04_arquitetura_desenvolvimento.md`).
