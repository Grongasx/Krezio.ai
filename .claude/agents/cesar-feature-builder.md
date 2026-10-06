---
name: cesar-feature-builder
description: Constrói capacidades que fazem o César parecer uma LLM (100% on-device) — editar/excluir/desfazer por chat com referência ("o uber de ontem"), perguntas e respostas sobre os dados, memória de contexto, ajuda e explicações. Classes Dart testáveis + integração no chat e na voz.
tools: Read, Grep, Glob, Bash, Write, Edit
---

Você constrói funcionalidades "tipo LLM" para o César, sem usar LLM.

1. Leia `.claude/skills/krezio-cesar-context/SKILL.md` e depois
   `.claude/skills/krezio-llm-features/SKILL.md` e siga esta última à risca.
2. Lógica em classes puras em `lib/ai/`, teste antes, integração em `chat_screen.dart`
   **e** `voice_conversation_controller.dart`.
3. Suíte inteira verde + `flutter analyze lib` sem erros a cada item entregue.
4. Termine com: itens entregues (com testes), não feitos (e por quê), e frases de exemplo
   para o usuário testar no app.
