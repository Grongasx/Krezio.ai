# Fluxo de trabalho

## Branches

- `main` é a versão estável e protegida: não aceita force-push nem exclusão, e o CI precisa passar.
- Todo trabalho acontece numa branch a partir do `main`, com prefixo pelo tipo:
  - `feat/…` funcionalidade nova (`feat/fatura-cartao`)
  - `fix/…` correção (`fix/data-futura-demo`)
  - `chore/…` infraestrutura, configuração, documentação (`chore/fase-0`)
- A branch volta ao `main` por **Pull Request**, que referencia a issue do card (`Closes #24`).

## Commits

[Commits convencionais](https://www.conventionalcommits.org/pt-br/), em português, no imperativo:

```
tipo(escopo): descrição curta

Corpo opcional explicando o porquê.
```

Tipos: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`. Escopos comuns: `cesar`, `backend`, `frontend`, `voz`, `backlog`.

Exemplos: `feat(cesar): perguntar "Registro assim?" com baixa certeza` · `fix(backend): dados de demonstração sem data futura`.

## Versões

- [Versionamento semântico](https://semver.org/lang/pt-BR/): `MAJOR.MINOR.PATCH`, com sufixo `-alpha` antes da 1.0.
- Toda versão publicada ganha:
  1. a versão no `pubspec.yaml` (`version: 0.5.0+5`);
  2. uma entrada no [CHANGELOG.md](CHANGELOG.md) (formato Keep a Changelog);
  3. uma tag anotada no commit do `main`: `git tag -a v0.5.0-alpha -m "v0.5.0-alpha" && git push origin v0.5.0-alpha`.
- Durante o desenvolvimento, as mudanças vão para a seção `[Unreleased]` do CHANGELOG.

## O que o CI verifica

O [CI](.github/workflows/ci.yml) roda em todo PR e em todo push no `main`:

1. `flutter analyze lib`: falha com erro (avisos e infos antigos ainda não bloqueiam).
2. `flutter test test/*_test.dart`: todos os testes de regressão (~2 min).

As baterias de medição em `test/_qa/` não rodam no CI. Elas só imprimem placares; rode-as localmente quando mexer no César.

## Antes de abrir o PR

- [ ] `flutter analyze lib` sem erros
- [ ] `flutter test test/*_test.dart` verde
- [ ] Lógica nova numa classe Dart pura, com teste
- [ ] Entrada no `[Unreleased]` do CHANGELOG, se a mudança for visível para o usuário
- [ ] Caixinhas do card atualizadas no `BACKLOG.md` (e `python scripts/github/create_backlog.py` para levar ao GitHub)
