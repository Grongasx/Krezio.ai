# Changelog

Todos os marcos relevantes e alterações significativas do projecto **Krezio.ai** serão documentados neste ficheiro.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/) e este projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

---

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
