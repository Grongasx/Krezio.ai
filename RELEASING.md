# Como lançar uma versão

Uma release a cada **2 a 4 semanas**. Todo item das notas "O que há de novo" corresponde a uma entrada do `CHANGELOG.md`.

## 1. Preparar

1. Mesclar no `main` os PRs da versão (CI verde).
2. Mover as entradas de `[Unreleased]` no `CHANGELOG.md` para `## [vX.Y.Z] - AAAA-MM-DD`.
3. Subir a versão no `pubspec.yaml`: `version: X.Y.Z+N` (N = código de build, sempre maior que o anterior).
4. Commit `chore(release): vX.Y.Z` e tag `vX.Y.Z` (`git tag vX.Y.Z && git push origin vX.Y.Z`).

## 2. Assinatura (Android)

A keystore **nunca** entra no git (`*.jks`, `*.keystore` e `android/key.properties` estão no `.gitignore`).

Criar uma vez (guarde a senha num gerenciador de senhas):

```bash
keytool -genkey -v -keystore ~/krezio-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias krezio
```

**Backup da keystore:** guarde uma cópia em dois lugares fora deste computador (ex.: gerenciador de senhas com anexo e um pendrive). Perder a keystore significa não conseguir mais atualizar o app na Play Store (a menos que a assinatura de apps do Google Play esteja ativada — ative-a ao criar o app no Console).

O build lê os dados de **variáveis de ambiente** (CI) ou de `android/key.properties` (local):

| Variável | `key.properties` |
|---|---|
| `KREZIO_KEYSTORE_PATH` | `storeFile` |
| `KREZIO_KEYSTORE_PASSWORD` | `storePassword` |
| `KREZIO_KEY_ALIAS` | `keyAlias` |
| `KREZIO_KEY_PASSWORD` | `keyPassword` |

Sem keystore, o build de release usa a chave de debug (serve para testar, **não** para a loja).

## 3. Gerar o build

```bash
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
```

- Saída: `build/app/outputs/bundle/release/app-release.aab`.
- `build/symbols/` traduz os erros ofuscados; guarde-o junto com a versão (não vai para o git).
- Teste o release num aparelho real antes de enviar: `flutter install --release` ou o teste interno da Play Store.

## 4. Publicar (Play Console)

1. Teste fechado: 10 a 20 pessoas por 2 semanas, com o formulário de feedback (Configurações → Fale com a gente). Nenhum P0 aberto antes de seguir.
2. Produção com lançamento gradual: **10% → 50% → 100%**, acompanhando falhas e ANRs no Play Console em cada etapa.
3. Notas "O que há de novo": copiar as entradas da versão no `CHANGELOG.md`, em linguagem simples.

A ficha da loja (textos, classificação, segurança de dados) está em `docs/store/`.
