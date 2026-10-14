# Krezio.ai

App de finanças pessoais em Flutter com o **César**, um assistente de chat e voz que entende o que você fala
("gastei 50 no mercado no pix", "quanto gastei com lazer esse mês?", "apaga o uber de ontem").

O César **não usa LLM nem nuvem**: entende português por regras e por um classificador TF-IDF treinado no próprio projeto,
rodando **100% no aparelho**. Os dados ficam no celular; a sincronização com o Firebase é opcional.

> Status: em desenvolvimento (v0.5). Backlog e progresso em [BACKLOG.md](BACKLOG.md) e no
> [GitHub Project](https://github.com/users/Grongasx/projects/8).

## O que já funciona

- Lançamentos de despesa, receita e transferência, com parcelamento e recorrência
- Dashboard, extrato com busca, orçamentos por categoria, metas de economia, lembretes e dívidas
- Chat com o César: lançar, editar, excluir e desfazer por conversa; perguntas sobre os dados; "posso comprar isso?"
- Segurança da IA: na dúvida o César pergunta ("Registro assim?") em vez de gravar errado; planos e hipóteses não são gravados
- Voz: reconhecimento de fala e resposta falada (voz neural Piper via servidor local)

## Como rodar

Pré-requisitos: [Flutter](https://docs.flutter.dev/get-started/install) 3.38 ou mais novo (Dart 3).

```bash
flutter pub get
flutter run -d chrome          # web
flutter run                    # celular Android conectado por USB
flutter build apk --debug      # gera build/app/outputs/flutter-apk/app-debug.apk
```

> No Windows, mantenha o projeto num caminho **sem acento** (ex.: `C:\Projects\Krezio.ai`).
> O build do Android falha em pastas como "Área de Trabalho".

**Firebase (opcional):** sem configurar, o app roda em modo local, sem login. Para ativar login e sincronização,
rode `flutterfire configure` na raiz. Isso gera `lib/firebase_options.dart` (hoje com `REPLACE_ME`).
Depois, ative "E-mail/senha" no Authentication e crie o Firestore.

**Voz do César (opcional):** a voz neural vem de um servidor Python local na porta 8088, com o modelo Piper
`pt_BR-faber-medium`. O modelo (~139 MB) não fica no git; baixe-o com `python scripts/download_voice_model.py`
(salva em `models/voice/`; o script fica no repositório privado de trabalho). Sem o servidor, o chat por texto
e o reconhecimento de fala continuam funcionando.

## Como testar

```bash
flutter analyze lib            # análise estática (0 erros)
flutter test                   # suíte completa, incluindo as baterias de QA (~15 min)
flutter test test/*_test.dart  # só os testes de regressão, sem as baterias de test/_qa (o que o CI roda)
```

- `test/*_test.dart` — testes de regressão (falham quando algo quebra).
- `test/_qa/` — baterias de medição: centenas de frases inéditas e teste do caos (fuzz com invariantes). Elas **só
  imprimem** o placar, por exemplo `flutter test test/_qa/conversation_r3_probe_test.dart 2>&1 | grep R3TOTAL`.

## Estrutura

```
lib/
  ai/          motor do César em Dart puro, sem Flutter (parsers, portão de segurança, perguntas, comandos)
  ai/voice/    voz: síntese, player de áudio e controlador de conversa
  backend/     modelos, repositório central (fonte única da verdade), persistência, Firebase
  frontend/    telas, widgets e tema
models/on_device/   modelo TF-IDF + regressão logística exportado em JSON
test/               testes de regressão; test/_qa/ = baterias de medição
```

Regra da arquitetura: toda lógica nova vai numa classe Dart pura e testável em `lib/ai` ou `lib/backend`. As telas só
chamam essas classes.

## Fluxo de trabalho

Veja [CONTRIBUTING.md](CONTRIBUTING.md): branches, commits, versões e o que o CI verifica.
