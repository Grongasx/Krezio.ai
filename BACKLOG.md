# Krezio.ai — Backlog de desenvolvimento (do zero)

> Plano completo do produto como se nada tivesse sido construído. Cada **macro** é um card; dentro dele, os **micros** (tarefas).
> Marque `[x]` ao concluir. A ordem das fases é a ordem sugerida de execução; dentro de uma fase, os cards podem andar em paralelo.
>
> **Produto:** app Flutter de finanças pessoais com o **César**, assistente de chat e voz que entende linguagem natural
> **100% no aparelho** (sem LLM, sem nuvem para IA). Dados locais com sincronização opcional via Firebase.

## Legenda das labels

| Label | Valores | Significado |
|---|---|---|
| **Pontos** | `0` a `100`, de 10 em 10 | Esforço relativo do card (complexidade + volume + risco). 10 = poucas horas · 50 = cerca de uma semana · 100 = o maior card do produto |
| **Prioridade** | 🔴 **Alta** · 🟠 **Média** · 🟡 **Baixa** · ⚪ **Muito baixa** | Alta = sem isso não há produto · Média = necessário para a 1.0 · Baixa = melhora a experiência · Muito baixa = depois da 1.0 |
| **Área** | `ML` · `Backend` · `Frontend` · `Design` · `DevOps` · `QA` · `Produto` | ML = motor de linguagem do César e voz · Backend = dados, regras, Firebase · Frontend = telas e widgets · Design = visual e UX · DevOps = build, CI, loja · QA = testes e qualidade · Produto = documentos, legal, decisões |

Cada card mostra `pontos · prioridade · áreas`; cada tarefa mostra a área responsável.

**Formato das tarefas:** `O que fazer (detalhes e exemplos concretos → critério de pronto ou regra esperada)`.
O texto depois do `→` é o que precisa ser verdade para marcar a tarefa como feita.

**Estado em 2026-10-06** (auditado no código): `[x]` = critério atendido · `— ⚠️ parcial:` = existe, mas falta o que está descrito · vazio = não existe.

---

## Fase 0 — Fundação

### 0.1 Configurar o projeto
`20 pts` · 🔴 **Alta** · `DevOps` `Produto`
- [ ] `DevOps` Criar o projeto Flutter (Android, iOS, Web, Windows; package `krezio_ai`, `minSdk` 23 → `flutter run` abre a tela inicial nas 4 plataformas) — ⚠️ parcial: sem a plataforma iOS (só Android, Web e Windows)
- [x] `DevOps` Definir a estrutura de pastas (`lib/ai` motor do César, `lib/backend` dados e serviços, `lib/frontend` telas e tema → nenhum import de `frontend` dentro de `ai`)
- [x] `DevOps` Configurar lints e análise estática (`flutter_lints` + regras do projeto em `analysis_options.yaml` → `flutter analyze` com 0 erros)
- [ ] `DevOps` Configurar o repositório git (`.gitignore` para `build/`, `.dart_tool/`, chaves e `google-services`; branch `main` protegida → nenhum segredo versionado) — ⚠️ parcial: branch main sem proteção; trabalho atual em feat/cesar-v0.5 sem commit
- [ ] `Produto` Escrever o `README.md` (o que é o app, como rodar em web e Android, como rodar os testes, onde fica cada pasta → alguém novo roda o app só lendo o README) — ⚠️ parcial: o README ainda é o modelo padrão do Flutter
- [x] `DevOps` Garantir que o projeto fique num caminho sem acento (ex.: `C:\Projects\Krezio.ai`; o Android falha em "Área de Trabalho" → `flutter build apk` funciona)

### 0.2 Definir a arquitetura
`20 pts` · 🔴 **Alta** · `Backend` `Produto`
- [x] `Backend` Escolher o gerenciamento de estado (`ChangeNotifier` num repositório central, injetado nas telas → toda tela lê os dados da mesma fonte)
- [x] `Backend` Separar as camadas (IA em Dart puro, sem Flutter; backend com modelos, repositório e serviços; frontend só com telas e widgets → a IA roda em teste sem `WidgetTester`)
- [x] `Backend` Definir a regra de onde fica a lógica (toda regra de negócio em classe Dart pura testável, nunca dentro de widget → as telas só chamam métodos)
- [ ] `Produto` Documentar as decisões de arquitetura (`docs/architecture`, com o porquê de cada escolha: sem LLM, local-first, Firebase opcional → uma página por decisão) — ⚠️ parcial: há 4 ADRs em docs/architecture/adr; faltam local-first e Firebase opcional

### 0.3 Montar a infraestrutura de qualidade
`30 pts` · 🔴 **Alta** · `DevOps` `QA` `Produto`
- [x] `QA` Configurar `flutter test` e a estrutura de `test/` (um arquivo por classe, mais `test/_qa/` para baterias que só medem → `flutter test` roda tudo verde)
- [ ] `DevOps` Configurar CI no GitHub Actions (analyze + test a cada push e PR, com cache do Flutter → PR com teste vermelho não pode ser mesclado)
- [ ] `DevOps` Definir o fluxo de branch, commit e changelog (branch por feature `feat/…`, commits convencionais, versão semântica `MAJOR.MINOR.PATCH` → toda versão tem tag)
- [ ] `Produto` Criar o `CHANGELOG.md` (formato Keep a Changelog, seções Added/Changed/Fixed por versão → toda release tem entrada) — ⚠️ parcial: CHANGELOG parado na v0.3.2-alpha

---

## Fase 1 — Base visual e navegação

### 1.1 Montar o design system
`40 pts` · 🔴 **Alta** · `Design` `Frontend`
- [x] `Design` Definir a paleta de cores (primária, superfícies, texto, sucesso para receita, erro para despesa, aviso; versões clara e escura → contraste AA em todo texto)
- [ ] `Design` Definir a tipografia e os espaçamentos (escala de 4 pt; título, subtítulo, corpo, legenda e valor monetário em destaque → nenhum tamanho fora da escala nas telas)
- [x] `Frontend` Criar o tema global `krezio_theme` (`ThemeData` claro e escuro, cores e textos vindos dos tokens → trocar o tema muda o app inteiro sem cor fixa em widget)
- [ ] `Frontend` Criar os componentes base (botão primário e secundário, campo de texto com erro, campo de valor em R$, card, chip, diálogo de confirmação → usados em todas as telas, nada duplicado)
- [x] `Design` Definir os ícones e as cores de cada categoria (mercado, transporte, moradia, lazer, saúde, educação, salário, outros… → cada categoria tem um par fixo ícone + cor)

### 1.2 Criar a navegação
`30 pts` · 🔴 **Alta** · `Frontend` `Design`
- [x] `Frontend` Criar a barra de navegação principal (Dashboard, Extrato, Orçamentos, Chat do César, Configurações → a aba ativa fica destacada e o estado de cada aba é mantido ao trocar)
- [ ] `Frontend` Criar o wrapper de navegação e as rotas (rotas nomeadas, botão voltar do Android respeitado, deep link para o chat → voltar nunca fecha o app no meio de um fluxo)
- [ ] `Design` Criar a splash screen (logo e cor da marca, sem texto pequeno → aparece enquanto os dados carregam e some em menos de 2 s)
- [ ] `Design` Criar os estados vazios, de carregamento e de erro padrão (ex.: "Nenhum lançamento ainda — fale com o César", skeleton nas listas, erro com "tentar de novo" → toda lista tem os 3 estados) — ⚠️ parcial: estados vazios em algumas telas; sem skeleton nem padrão único

---

## Fase 2 — Dados e autenticação

### 2.1 Definir os modelos de dados
`30 pts` · 🔴 **Alta** · `Backend` `QA`
- [x] `Backend` Criar o modelo de lançamento (id, valor positivo, tipo receita/despesa/transferência, categoria, forma de pagamento, data, título, parcela N/total, recorrência, dia de vencimento → valor nunca negativo nem zero)
- [x] `Backend` Criar o modelo de categoria (código, nome, ícone, cor, `isCustom`; nativas fixas + personalizadas do usuário → código único, nome sem duplicar ignorando acento e maiúscula)
- [x] `Backend` Criar o modelo de orçamento por categoria (limite mensal, gasto atual calculado → o gasto nunca é salvo à mão, sempre recalculado)
- [x] `Backend` Criar o modelo de meta de economia (nome, valor-alvo, guardado, prazo opcional, concluída → concluída quando guardado ≥ alvo)
- [x] `Backend` Criar o modelo de lembrete, conta a pagar e dívida (pessoa, valor, vencimento, pago parcial, quitada → saldo da dívida = valor − pagamentos)
- [x] `QA` Escrever a serialização JSON de todos os modelos, com testes (ida e volta `toJson`/`fromJson`, campos novos com valor padrão para dados antigos → nenhum dado salvo antes quebra ao abrir)

### 2.2 Criar a persistência local
`40 pts` · 🔴 **Alta** · `Backend` `QA`
- [x] `Backend` Criar o serviço de persistência (`shared_preferences` ou banco local; leitura e gravação de tudo em JSON → funciona offline e na web)
- [x] `Backend` Criar o repositório central (fonte única da verdade com lançamentos, categorias, orçamentos, metas, lembretes; avisa as telas a cada mudança → nenhuma tela guarda cópia própria dos dados)
- [x] `Backend` Criar uma fila de gravação sequencial (cada gravação espera a anterior terminar → limpar dados e logo depois lançar algo nunca faz os dados de demonstração voltarem)
- [x] `Backend` Carregar os dados ao abrir o app e salvar a cada mudança (carregamento antes da primeira tela, gravações agrupadas → fechar o app logo após lançar não perde o lançamento)
- [ ] `Backend` Criar "Limpar dados" e os dados de demonstração (demonstração só no primeiro uso e sempre com datas no passado → nenhum lançamento de demonstração com data futura) — ⚠️ parcial: os dados de demonstração criam lançamento com data futura (dia 10 do mês)
- [x] `QA` Testar a persistência sobrevivendo a reload e restart (lançar, recarregar, conferir; limpar, lançar, recarregar → o que está na memória é igual ao que está no disco)

### 2.3 Criar a autenticação de usuário
`50 pts` · 🔴 **Alta** · `Backend` `Frontend` `DevOps`
- [ ] `DevOps` Criar o projeto no Firebase e rodar `flutterfire configure` (plataformas web, Android e Windows → `lib/firebase_options.dart` sem `REPLACE_ME`)
- [ ] `DevOps` Ativar o login por e-mail e senha no console do Firebase (Authentication → Métodos de login → E-mail/senha → cadastro de teste funciona no console)
- [x] `Frontend` Criar a tela de login (e-mail + senha, mostrar/ocultar senha, botão desabilitado até os campos serem válidos, carregando durante o envio → erro em PT, ex.: "E-mail ou senha incorretos")
- [ ] `Frontend` Criar a tela de cadastro (nome, e-mail, senha e confirmação, aceite dos termos obrigatório → só envia com senhas iguais e termos aceitos) — ⚠️ parcial: login e cadastro na mesma tela; sem aceite de termos
- [x] `Frontend` Criar o fluxo "esqueci minha senha" (pede o e-mail e envia o link do Firebase → sempre mostra "Se o e-mail existir, enviamos um link", sem revelar se a conta existe)
- [x] `Backend` Criar a lógica de login e as validações (e-mail com formato válido, senha não vazia, códigos do Firebase traduzidos: usuário não encontrado, senha errada, muitas tentativas, sem internet → nenhuma mensagem em inglês)
- [ ] `Backend` Criar a lógica de cadastro e as validações (senha com 8+ caracteres, com letra e número; e-mail já usado → "Esse e-mail já tem conta. Quer entrar?") — ⚠️ parcial: validação de senha forte não confirmada
- [x] `Frontend` Criar o botão "Sair" e a troca de sessão (confirmação antes de sair; ao trocar de usuário, os dados do anterior somem da tela → um usuário nunca vê dados de outro)
- [x] `Backend` Criar o modo local sem conta (sem Firebase configurado, o app abre direto e guarda tudo no aparelho → nenhuma tela de login quebra o uso offline)

### 2.4 Sincronizar com a nuvem
`70 pts` · 🟠 **Média** · `Backend` `DevOps` `QA`
- [ ] `DevOps` Criar o banco Firestore (região `southamerica-east1`, modo produção → custo e latência de região Brasil)
- [ ] `Backend` Escrever as regras de segurança (ler e gravar só `users/{uid}` quando `request.auth.uid == uid` → teste no emulador: outro usuário recebe "permissão negada") — ⚠️ parcial: regras escritas no handoff, ainda não publicadas
- [x] `Backend` Ativar a persistência offline do Firestore (`persistenceEnabled: true` → sem internet o app continua funcionando e envia ao reconectar)
- [x] `Backend` Criar o serviço de sincronização (local-first: grava local na hora e envia à nuvem com debounce de 2 s → a tela nunca espera a rede)
- [x] `Backend` Aplicar o snapshot que vem da nuvem no repositório (ao logar em outro aparelho, baixa tudo e substitui o local → os dois aparelhos mostram o mesmo saldo)
- [ ] `Backend` Tratar duas abas ou dois aparelhos editando ao mesmo tempo (merge por lançamento com data de atualização, não o documento inteiro → uma edição não apaga a outra)
- [ ] `QA` Testar a sincronização com mocks (offline → online, conflito entre aparelhos, logout no meio do envio → nenhum lançamento perdido ou duplicado)

---

## Fase 3 — Finanças (núcleo sem IA)

### 3.1 Lançamentos
`60 pts` · 🔴 **Alta** · `Frontend` `Backend`
- [x] `Frontend` Criar o formulário de novo lançamento (seletor despesa/receita/transferência, valor com teclado numérico e máscara R$, título → não salva sem valor e tipo)
- [x] `Frontend` Criar a escolha de categoria, forma de pagamento e data (categorias filtradas pelo tipo, Pix como padrão, data padrão hoje com atalho "ontem" → receita não mostra categoria de despesa)
- [x] `Backend` Criar o parcelamento no crédito (ex.: R$ 1.200 em 10x gera 10 lançamentos de R$ 120, um por mês, "Parcela 3/10" → a soma das parcelas é igual ao total, com o arredondamento na última)
- [x] `Backend` Criar as assinaturas e recorrências (dia de vencimento, sem prazo ou com data de fim, ex.: Netflix todo dia 12 → a próxima ocorrência aparece nas contas a vencer)
- [ ] `Frontend` Criar a edição de lançamento (abre o formulário preenchido; editar uma parcela pergunta "só esta ou todas as seguintes?" → o saldo é recalculado na hora) — ⚠️ parcial: editar parcela não pergunta "só esta ou todas"
- [x] `Frontend` Criar a exclusão com confirmação ("Apagar Mercado de R$ 50,00?" e "Desfazer" por alguns segundos depois → nada é apagado sem confirmação)
- [x] `Backend` Recalcular o saldo e os totais a cada mudança (saldo = receitas − despesas; transferência entre contas próprias não altera o total → saldo sempre igual à soma dos lançamentos)

### 3.2 Categorias
`30 pts` · 🔴 **Alta** · `Backend` `Frontend` `Design`
- [x] `Backend` Criar as categorias nativas (despesa: mercado, alimentação, transporte, moradia e contas, lazer, saúde, educação, pets, outros; receita: salário, freela, outras receitas → não podem ser apagadas)
- [x] `Frontend` Criar categorias personalizadas (nome livre, ex.: "Academia", "Presentes"; nome igual a uma existente é recusado → "Essa categoria já existe")
- [ ] `Backend` Renomear e excluir categorias (ao excluir, perguntar para qual categoria mover os lançamentos → nenhum lançamento fica sem categoria) — ⚠️ parcial: excluir categoria não pergunta para onde mover os lançamentos
- [x] `Design` Gerar ícone e cor automáticos para categorias personalizadas (paleta determinística pelo nome → o mesmo nome sempre gera o mesmo ícone e cor)

### 3.3 Formas de pagamento e contas
`70 pts` · 🟠 **Média** · `Backend` `Frontend`
- [x] `Backend` Cadastrar as formas de pagamento (Pix, débito, crédito, dinheiro, boleto, TED → crédito sempre pergunta à vista ou parcelado)
- [ ] `Backend` Criar múltiplas contas ou carteiras (ex.: Nubank, Itaú, Carteira; cada lançamento pertence a uma conta → saldo por conta + saldo total)
- [ ] `Frontend` Criar a tela de contas e carteiras (lista com saldo de cada uma, criar, renomear, arquivar → conta arquivada some da escolha mas mantém o histórico)
- [ ] `Backend` Criar a fatura de cartão de crédito com ciclo (dia de fechamento e de vencimento; compra depois do fechamento vai para a próxima fatura → total da fatura e data de pagamento corretos)
- [ ] `Backend` Tratar transferência entre contas próprias (ex.: da conta para a poupança → sai de uma e entra na outra; o saldo total não muda)

### 3.4 Extrato e histórico
`40 pts` · 🔴 **Alta** · `Frontend` `Design`
- [ ] `Frontend` Criar a tela de extrato agrupada por dia (cabeçalho "Hoje", "Ontem", "Seg, 28/09" com o total do dia; rolagem infinita → mil lançamentos rolam sem travar)
- [ ] `Frontend` Criar filtros (período: este mês, mês passado, personalizado; categoria; tipo; forma de pagamento → os filtros se combinam e mostram o total filtrado)
- [ ] `Frontend` Criar a busca por texto (busca no título e na categoria, ignorando acento e maiúscula: "acougue" acha "Açougue" → resultado enquanto digita) — ⚠️ parcial: busca existe, mas sem ignorar acento
- [x] `Frontend` Editar e excluir pelo extrato (toque abre a edição, arrastar para o lado apaga com confirmação → o chat do César fica sabendo da mudança)
- [x] `Design` Criar o card de lançamento (ícone e cor da categoria, título, forma de pagamento, valor verde para receita e vermelho para despesa, "3/10" em parcelas → legível em tela pequena)

### 3.5 Dashboard
`50 pts` · 🔴 **Alta** · `Frontend` `Design` `Backend`
- [x] `Design` Criar os cards de resumo (saldo atual, entradas e saídas do mês, com seta de variação → valores em R$ formatados, ex.: R$ 1.948,40)
- [x] `Frontend` Criar o gráfico de gastos por categoria (donut com as 5 maiores + "outras", toque mostra o valor → soma do gráfico igual às saídas do mês)
- [x] `Backend` Criar o comparativo com o mês anterior (ex.: "Você gastou 12% a menos que em agosto" → comparar o mesmo intervalo de dias)
- [x] `Frontend` Mostrar as próximas contas a vencer (próximos 7 dias, com o valor e "vence amanhã" em destaque → toque leva ao lembrete)
- [x] `Frontend` Criar o card de insight do César (uma frase útil por dia, ex.: "Lazer já passou de 80% do orçamento" → toque abre o chat com a pergunta)

### 3.6 Orçamentos
`40 pts` · 🟠 **Média** · `Backend` `Frontend`
- [x] `Backend` Criar um orçamento mensal por categoria (ex.: Lazer R$ 400; reinicia todo dia 1º → só despesas do mês corrente contam)
- [ ] `Frontend` Mostrar o progresso (barra gasto × limite: verde até 79%, amarelo de 80% a 99%, vermelho a partir de 100% → mostra "faltam R$ 80" ou "passou R$ 30") — ⚠️ parcial: barra de progresso sem as faixas de cor 80%/100%
- [x] `Frontend` Criar a tela de orçamentos (lista por categoria, criar, editar e remover limite → total orçado × total gasto no topo)
- [x] `Backend` Recalcular os orçamentos a cada lançamento (inclusive edição, exclusão e desfazer → o progresso nunca fica desatualizado)

### 3.7 Metas de economia
`40 pts` · 🟠 **Média** · `Backend` `Frontend`
- [x] `Backend` Criar uma meta (nome, valor-alvo, prazo opcional, ex.: "Viagem, R$ 3.000 até dezembro" → prazo no passado é recusado)
- [x] `Backend` Criar aportes e retiradas (retirada maior que o guardado é recusada → guardado nunca fica negativo)
- [x] `Frontend` Mostrar o progresso e o "quanto guardar por mês" (ex.: faltam R$ 1.800 em 3 meses → "Guarde R$ 600 por mês")
- [x] `Backend` Marcar a meta como concluída (quando guardado ≥ alvo, com comemoração na tela → desfazer o último aporte volta a meta para não concluída)

### 3.8 Lembretes, contas a pagar e dívidas
`50 pts` · 🟠 **Média** · `Backend` `Frontend`
- [x] `Backend` Criar lembretes de contas a pagar (descrição, valor opcional, vencimento, recorrente ou não, ex.: "Luz todo dia 10" → marcar como paga cria o lançamento)
- [x] `Backend` Criar as dívidas (emprestei para alguém, me emprestaram, com pessoa e valor → "quem me deve" e "a quem devo" separados)
- [x] `Backend` Registrar o pagamento parcial de dívida (ex.: o João me devia 100 e pagou 70 → falta R$ 30; com o restante pago, a dívida é quitada)
- [ ] `Frontend` Criar a lista de devedores e de contas em aberto (ordenada por vencimento, atrasadas em vermelho → toque permite registrar o pagamento) — ⚠️ parcial: devedores e contas em aberto só pelo chat e dashboard, sem tela própria

### 3.9 Alertas
`30 pts` · 🟠 **Média** · `Backend` `Frontend` `Produto`
- [x] `Backend` Alertar quando o orçamento estiver perto do limite ou estourado (avisar aos 80% e aos 100% → cada aviso aparece uma vez por categoria por mês)
- [x] `Backend` Alertar sobre boleto vencendo em até 3 dias (ex.: "A conta de luz de R$ 180 vence amanhã" → some quando a conta é marcada como paga)
- [x] `Backend` Alertar sobre dívida atrasada (ex.: "O João está 5 dias atrasado nos R$ 30" → só para dívidas com data combinada)
- [x] `Frontend` Mostrar um banner de alertas no dashboard (no máximo 2 por vez, com "dispensar" → alerta dispensado não volta)
- [ ] `Produto` Decidir entre alertas só no app e notificação push do sistema (comparar esforço, permissões e suporte na web → decisão registrada em `docs/architecture`) — ⚠️ parcial: decisão tomada (alertas no app), registrada só no handoff

---

## Fase 4 — César: motor de linguagem (on-device)

### 4.1 Dataset e modelo
`80 pts` · 🔴 **Alta** · `ML`
- [x] `ML` Gerar um dataset sintético de frases em português (despesa, receita, transferência, pergunta, comando; 10 mil frases balanceadas por intenção → nenhuma intenção com menos de 10% das frases)
- [x] `ML` Incluir gírias, erros de digitação, fala transcrita e regionalismos ("torrei 50", "pila", "gastei cinquenta conto", "paguie", "oxente", sem pontuação → pelo menos 20% das frases com ruído)
- [x] `ML` Treinar o classificador TF-IDF + regressão logística (intenção, categoria e pagamento, com split treino/validação/teste e frases fora da distribuição → acurácia de intenção ≥ 95% no teste)
- [x] `ML` Criar o benchmark com gráficos (acurácia por split, comparação de algoritmos, matriz de confusão, em `docs/charts` → o benchmark roda com um comando)
- [x] `ML` Exportar o modelo para JSON e carregá-lo no app (vocabulário, IDF e pesos em `models/on_device` → o app carrega em menos de 1 s e prevê sem rede)
- [x] `ML` Criar o script de retreino reprodutível, com log isolado (seed fixa, log em `training_logs.txt` com resumo compacto → mesmo dataset gera o mesmo modelo)

### 4.2 Extração de informações (parsers)
`100 pts` · 🔴 **Alta** · `ML` `QA`
- [x] `ML` Extrair o valor (números, por extenso, "R$", "conto", "pila", milhar e decimal)
- [x] `ML` Separar o valor dos números que não são valor (unidades, endereços, idades, horas, parcelas, modelos)
- [x] `ML` Extrair a data (ontem, dia N, dd/mm, dia da semana, "há N dias", "mês passado"; futuro → perguntar)
- [x] `ML` Detectar a direção do dinheiro (entrou × saiu, por papel: "me pagaram", "me cobraram", venda, reembolso)
- [x] `ML` Extrair a categoria por palavra-chave e por contexto (marcas, objetos, serviços)
- [x] `ML` Extrair a forma de pagamento e as parcelas
- [x] `ML` Detectar recorrência ("todo mês", "vence dia N")
- [x] `ML` Criar o corretor de erros de digitação para palavras-chave
- [x] `ML` Extrair um título curto do lançamento
- [x] `QA` Testar cada parser com frases inéditas (generalização, não só as frases dos testes)

### 4.3 Segurança da IA (nunca gravar errado)
`90 pts` · 🔴 **Alta** · `ML` `QA`
- [x] `ML` Detectar hipóteses e planos ("se eu comprar…", "pretendo", "tenho que pagar") → não registrar
- [x] `ML` Detectar não-eventos ("quase gastei", "deu erro", "desisti") → não registrar
- [x] `ML` Criar o portão único antes de gravar (direção, data, números, intenção)
- [x] `ML` Criar a medida de certeza e o "Registro assim? (sim/não)" quando a certeza for baixa
- [x] `QA` Garantir zero pergunta desnecessária em frases claras (medir a taxa)

---

## Fase 5 — César: conversa

### 5.1 Interface do chat
`40 pts` · 🔴 **Alta** · `Frontend` `Design`
- [x] `Frontend` Criar a tela de chat (balões do usuário e do César, indicador "digitando…", rolagem automática para a última mensagem, campo que cresce até 4 linhas → enviar com Enter e com o botão)
- [x] `Frontend` Renderizar Markdown nas respostas (negrito, listas, títulos e tabelas simples, sem pacote pesado → a voz lê o texto sem `**` nem `###`)
- [x] `Design` Criar sugestões rápidas em chips depois de cada resposta (ex.: depois de um lançamento: "Desfazer", "Ver extrato"; depois de uma pergunta: "E no mês passado?" → no máximo 3 chips)
- [x] `Design` Criar o cartão de lançamento registrado (ícone, título, valor, categoria, pagamento, data e "Desfazer" → o cartão reflete edições feitas depois)
- [x] `Frontend` Criar a saudação com os alertas do dia (ex.: "Bom dia! A luz vence amanhã e o Lazer está em 85%" → no máximo 2 alertas, sem repetir na mesma sessão)

### 5.2 Fluxo de lançamento por conversa
`80 pts` · 🔴 **Alta** · `ML` `Backend`
- [x] `ML` Registrar uma frase completa direto ("gastei 50 no mercado no pix" → grava sem perguntar e confirma "Registrei R$ 50,00 no Pix em Mercado")
- [x] `ML` Perguntar o que falta, uma coisa por vez (valor → "Quanto foi?", categoria → "Onde foi?", pagamento → "Como pagou?", crédito → "À vista ou parcelado?" → nunca pergunta o que já foi dito)
- [x] `ML` Juntar a resposta ao rascunho pendente ("paguei o eletricista" ⏎ "180 no pix" → um lançamento só, de R$ 180, Eletricista, Pix)
- [x] `ML` Reconhecer uma frase nova no meio de um rascunho ("paguei a lanchonete" ⏎ "tomei um café de 9" → dois assuntos; avisa "Deixei de lado o lançamento anterior")
- [x] `ML` Registrar vários lançamentos numa frase ("almoço 32 e janta 48 no pix", "23 açougue, 14 padaria, tudo ontem" → um lançamento por item, com pagamento e data compartilhados)
- [x] `Backend` Aceitar "cancela" e "esquece" a qualquer momento ("cancela", "deixa pra lá", "larga mão" → descarta o pendente e diz o que não foi registrado)
- [x] `Backend` Nunca repetir a mesma pergunta 3 vezes sem oferecer saída (na 2ª vez, reformular com exemplo; na 3ª, oferecer "ou diga cancela" → nenhuma conversa presa em loop)

### 5.3 Comandos por conversa
`80 pts` · 🔴 **Alta** · `ML` `Backend`
- [x] `ML` Editar por referência ("o uber de ontem foi 45", "na verdade foi no crédito", "passa o açougue pra 92" → muda só o registro citado e diz o que mudou: "Mudei de R$ 40 para R$ 45")
- [x] `Backend` Excluir por referência, sempre pedindo "sim" ("apaga o uber de ontem" → "Vou apagar Uber (29/09, R$ 45). Confirma?"; sem "sim" nada é apagado)
- [x] `Backend` Desfazer até 20 ações, inclusive lotes inteiros ("desfaz" depois de um lançamento múltiplo desfaz a mensagem toda → passado o limite, avisa "guardo só as últimas 20 ações")
- [x] `ML` Criar o resolvedor de referência (nome × data × categoria: "a feira de segunda" quando só existe feira no sábado → "Não achei feira na segunda; tem uma no sábado, é essa?", sem mexer em nada)
- [x] `ML` Escolher entre vários candidatos ("apaga a barbearia" com duas → "Qual delas? 1) 26/09 R$ 40 2) 19/09 R$ 35"; aceita "a de sábado", "1", "a de 40" → nunca escolhe sozinho)
- [x] `Backend` Criar e renomear categorias pelo chat ("cria a categoria Pets", "renomeia Lazer para Diversão" → mesmas validações da tela de categorias)
- [x] `Backend` Criar metas e fazer aportes pelo chat ("quero juntar 3000 pra viagem até dezembro", "coloca 150 na meta da viagem" → responde o progresso atualizado)
- [x] `Backend` Criar lembretes pelo chat ("me lembra de pagar a luz dia 10" → cria o lembrete e confirma a data)

### 5.4 Perguntas sobre os dados
`70 pts` · 🟠 **Média** · `ML` `Backend` `Frontend`
- [x] `ML` Criar o motor de perguntas como medida × filtro × período ("quanto gastei com mercado mês passado?" = soma × categoria mercado × mês anterior → palavra que não é filtro não vira filtro)
- [x] `Backend` Responder gastos, receitas, saldo, maior e menor gasto, categoria principal ("qual meu maior gasto do mês?" → "Aluguel, R$ 1.400 em 05/09")
- [x] `Backend` Responder comparativos ("gastei mais que mês passado?" → "Sim, 18% a mais: R$ 2.300 contra R$ 1.950", comparando o mesmo intervalo de dias)
- [ ] `Backend` Responder "quanto posso gastar por dia" e a média diária real (orçamento diário = sobra ÷ dias restantes; média = gasto ÷ dias corridos → as duas respostas nunca se confundem) — ⚠️ parcial: "média diária real" ainda responde o orçamento diário
- [ ] `Backend` Responder contagem e "última vez que…" ("quantas vezes pedi iFood?" filtra pelo título, não pela categoria → "2 vezes, R$ 115,40") — ⚠️ parcial: contagem por comerciante ainda filtra pela categoria
- [x] `Backend` Responder contas a vencer e quem me deve ("o que vence essa semana?", "quem me deve?" → lista com valores e datas)
- [x] `ML` Manter o contexto entre perguntas ("quanto gastei no mercado?" ⏎ "e no mês passado?" ⏎ "e com lazer?" → cada pergunta herda o que não mudou)
- [x] `Frontend` Mostrar gráficos nas respostas quando pedido ("me mostra um gráfico dos gastos" → barras por categoria dentro do balão)
- [x] `ML` Responder "o que você sabe fazer?" (lista curta de capacidades com um exemplo de frase para cada uma → sempre atualizada com o que existe)

### 5.5 Consultoria
`70 pts` · 🟠 **Média** · `ML` `Backend`
- [x] `Backend` Responder "Posso comprar isso?" (pesa saldo, contas dos próximos 30 dias, metas e % da renda: "Uma TV de 2.000?" → "Dá, mas sobram R$ 300 até o salário")
- [ ] `ML` Criar simulações "e se…?" ("quanto sobra se eu pagar o aluguel?", "se eu cortar o delivery, quanto economizo?", "se eu guardar 200 por mês, quando bato a meta?", "2.000 em 10x fica quanto?" → nunca registra nada) — ⚠️ parcial: responde parcela e "posso comprar"; faltam "quanto sobra se…" e prazo de meta
- [ ] `Backend` Responder "onde posso economizar?" (as 3 categorias que mais cresceram contra a média de 3 meses, mais as recorrentes → com valores e sugestão concreta)
- [ ] `Backend` Projetar o fechamento do mês e prever contas recorrentes ("como vou fechar o mês?" = saldo − contas futuras − média diária × dias restantes; "quanto vem a luz?" = média das últimas → menos de 1 mês de dados: "ainda não tenho dados suficientes")
- [ ] `Backend` Listar assinaturas e gastos fixos ("quais assinaturas eu pago?" → lista com valor mensal e total anual)
- [ ] `Backend` Criar o resumo semanal proativo (na primeira abertura da segunda-feira: gasto da semana, categoria principal e comparação → aparece uma vez por semana)
- [ ] `Backend` Alertar sobre gasto fora do padrão (categoria com gasto semanal ≥ 2× a média das últimas 4 semanas → "para de me avisar disso" desliga o aviso)

### 5.6 Aprendizado
`30 pts` · 🟡 **Baixa** · `ML` `Backend`
- [x] `ML` Lembrar correções de categoria ("gastei 40 no mercado do zé" ⏎ "esse era lazer" → da próxima vez, "mercado do zé" já vai para Lazer)
- [ ] `Backend` Desfazer também a memória de categoria ("desfaz" depois da correção → o próximo "mercado do zé" volta para Mercado)
- [ ] `Backend` Criar as preferências do usuário (como chamar o usuário, forma de pagamento mais usada como sugestão → nunca assume a preferência sem dizer "considerei Pix")

---

## Fase 6 — Voz

### 6.1 Ouvir (fala → texto)
`30 pts` · 🟠 **Média** · `Frontend` `ML`
- [x] `Frontend` Integrar o reconhecimento de fala (`speech_to_text` em pt-BR, transcrição parcial na tela → o texto final vai para o mesmo fluxo do chat)
- [x] `Frontend` Configurar as permissões de microfone (Android: permissão e `RecognitionService` em `<queries>`; iOS: `NSMicrophoneUsageDescription` → sem permissão, explica e oferece abrir as configurações)
- [x] `Frontend` Criar o botão de falar e o feedback de escuta (segurar ou tocar para falar, onda animada enquanto ouve, para sozinho após 2 s de silêncio → nunca fica ouvindo para sempre)
- [x] `ML` Tratar números falados e frases sem pontuação ("gastei cento e vinte e cinco reais no mercado ontem" → R$ 125, Mercado, ontem)

### 6.2 Falar (texto → voz)
`60 pts` · 🟠 **Média** · `ML` `Frontend` `DevOps`
- [x] `ML` Criar a voz do César com ONNX/Piper (modelo de voz masculina em pt-BR, servidor local → primeira palavra em menos de 1 s)
- [x] `ML` Converter o texto para fala (R$ 1.948,40 → "mil novecentos e quarenta e oito reais e quarenta centavos", 29/09 → "vinte e nove de setembro", sem Markdown → nada de "asterisco" falado)
- [x] `Frontend` Criar o player de áudio em streaming (toca enquanto o resto ainda é gerado, com botão de parar → funciona no Android e na web)
- [ ] `Frontend` Usar a voz nativa do sistema como alternativa (`flutter_tts` quando o servidor ONNX não responde em 1 s → o César sempre fala, mesmo sem o servidor)
- [ ] `DevOps` Liberar a voz no celular sem depender do PC (modelo embarcado ou TTS nativo como padrão no Android → teste no Redmi Note 11 com o PC desligado)

### 6.3 Conversa por voz
`50 pts` · 🟡 **Baixa** · `ML` `Frontend`
- [x] `ML` Criar o controlador de conversa por voz com as mesmas regras do chat (mesmos rascunhos, confirmações e comandos → qualquer frase dá o mesmo resultado falada ou digitada)
- [ ] `Frontend` Criar o modo mãos-livres (depois de responder, volta a escutar; "tchau César" ou 10 s de silêncio encerram → indicador claro de que está ouvindo) — ⚠️ parcial: conversa contínua no modal de voz, sem encerramento por silêncio
- [ ] `Frontend` Permitir interromper o César enquanto ele fala (falar ou tocar para a voz parar na hora → a frase do usuário é processada normalmente)

---

## Fase 7 — Configurações, segurança e privacidade

### 7.1 Configurações e perfil
`30 pts` · 🟠 **Média** · `Frontend` `Design`
- [x] `Frontend` Criar a tela de configurações (seções Conta, Aparência, Segurança, Dados e privacidade, Sobre → cada opção com descrição curta)
- [ ] `Frontend` Criar o perfil do usuário (nome usado pelo César, foto opcional, moeda padrão R$ → o César chama o usuário pelo nome)
- [ ] `Design` Criar a troca de tema (claro, escuro, seguir o sistema → a escolha fica salva e vale ao reabrir) — ⚠️ parcial: alterna claro/escuro, sem "seguir o sistema"
- [x] `Frontend` Criar a seção "Conta" (e-mail logado, trocar senha, sair; no modo local: "Criar conta para sincronizar" → só aparece o que vale para o modo atual)

### 7.2 Segurança do app
`40 pts` · 🟠 **Média** · `Frontend` `Backend`
- [ ] `Frontend` Criar o bloqueio por PIN (4 a 6 dígitos, confirmação ao criar, 5 erros pedem espera de 30 s → o PIN é guardado com hash, nunca em texto)
- [ ] `Frontend` Criar o bloqueio por biometria (digital ou rosto com `local_auth`, PIN como alternativa → aparelho sem biometria só mostra o PIN)
- [ ] `Backend` Criar o bloqueio automático ao sair do app (bloquear depois de 1 minuto em segundo plano, configurável; ocultar o conteúdo na tela de apps recentes → nenhum valor visível na troca de apps)

### 7.3 Privacidade e LGPD
`50 pts` · 🔴 **Alta** · `Produto` `Backend` `Frontend`
- [ ] `Produto` Escrever os termos de uso (o que o app faz e não faz, sem aconselhamento financeiro profissional, responsabilidades → linguagem simples, em português)
- [ ] `Produto` Escrever a política de privacidade (o César roda no aparelho; o que vai para a nuvem só com conta; nenhum dado vendido; direitos da LGPD → link na loja e no app) — ⚠️ parcial: texto de privacidade nas Configurações; falta a política formal
- [ ] `Backend` Criar a exportação dos meus dados (JSON completo e CSV de lançamentos, compartilhável → o arquivo abre no Excel com acentos corretos)
- [ ] `Backend` Criar a exclusão de conta (confirmação digitando "EXCLUIR", apaga `users/{uid}` no Firestore e a conta no Auth → em seguida o app volta ao estado de primeiro uso)
- [ ] `Frontend` Criar as telas de aceite e de acesso aos documentos (aceite obrigatório no cadastro; termos e política sempre acessíveis em Configurações → guardar a versão aceita e a data)

### 7.4 Primeiro uso
`30 pts` · 🟡 **Baixa** · `Design` `Frontend`
- [ ] `Design` Criar o onboarding (3 telas: o que o app faz, "fale com o César como fala com um amigo" com exemplos, privacidade no aparelho → pode pular a qualquer momento)
- [ ] `Frontend` Criar a configuração inicial (renda mensal, categorias principais, primeiro orçamento sugerido → tudo opcional e editável depois)

---

## Fase 8 — Qualidade contínua

### 8.1 Testes automatizados
`90 pts` · 🔴 **Alta** · `QA`
- [x] `QA` Escrever testes unitários de todos os parsers e motores da IA (cada regra com casos positivos e controles negativos → toda classe de `lib/ai` com arquivo de teste)
- [x] `QA` Escrever os testes do repositório (persistência, saldo, orçamentos, metas, desfazer → saldo sempre igual à soma dos lançamentos depois de qualquer operação)
- [ ] `QA` Escrever os testes de widget das telas principais (login, formulário de lançamento, extrato, chat → os fluxos principais rodam sem erro de layout)
- [x] `QA` Criar a bateria de conversação (centenas de frases reais por eixo: gíria, voz, digitação, multi, perguntas, edição → a medida oficial usa sempre frases inéditas)
- [x] `QA` Criar o teste do caos (fuzz com seed, entradas hostis, fluxos interrompidos, reinício no meio, invariantes de saldo, duplicata e perda → 0 violação de invariante)
- [x] `QA` Aplicar a regra contra overfitting (toda correção é estrutural e vem com 5 a 8 frases novas; nunca alterar uma bateria para ela passar → revalidar com frases que o corretor não viu)
- [x] `QA` Criar testes com relógio injetado (virada de mês, 29/02, 31/12 às 23:59, domingo × segunda → nenhum teste quebra conforme o dia em que roda)

### 8.2 Processo
`20 pts` · 🟠 **Média** · `QA` `Produto`
- [x] `QA` Definir o portão de qualidade por funcionalidade (spec → teste que falha → código → suíte inteira → frases inéditas → caos → revisão → app ao vivo → só passa para a próxima com tudo verde)
- [ ] `QA` Fazer revisão de código e simplificação a cada entrega (`/code-review` e `/simplify` no diff → achados resolvidos ou justificados por escrito)
- [x] `Produto` Criar o handoff entre sessões e o feedback por etapa (`HANDOFF.md` com o estado atual, `FEEDBACK` com números de cada etapa → qualquer sessão retoma sem reler a conversa)

---

## Fase 9 — Publicação

### 9.1 Build e loja
`50 pts` · 🟠 **Média** · `DevOps` `Design` `Produto` `QA`
- [ ] `Design` Definir o ícone do app, a splash e o nome na loja (ícone adaptativo do Android em todas as densidades → legível em 48 px)
- [ ] `DevOps` Configurar a assinatura do APK/AAB (keystore fora do git, senhas em variável de ambiente, backup da keystore → perder a keystore não pode acontecer)
- [ ] `DevOps` Gerar os builds de release (AAB do Android com ofuscação; iOS se aplicável → app de release testado num aparelho real)
- [ ] `Produto` Preparar a ficha da Play Store (descrição curta e longa, 6 prints, classificação etária, formulário de segurança de dados, link da política → ficha aprovada sem pendências)
- [ ] `QA` Fazer um teste fechado com usuários reais (10 a 20 pessoas por 2 semanas, formulário de feedback → nenhum P0 aberto antes de publicar)
- [ ] `DevOps` Publicar a versão 1.0 (lançamento gradual de 10% → 50% → 100% → acompanhar crashes em cada etapa)

### 9.2 Pós-lançamento
`30 pts` · 🟡 **Baixa** · `Produto` `DevOps` `Frontend`
- [ ] `Frontend` Criar a coleta de feedback no app ("Fale com a gente" em Configurações e "isso ajudou?" nas respostas do César → feedback chega com a versão do app)
- [ ] `DevOps` Monitorar erros e crashes (Firebase Crashlytics, sem dados financeiros nos logs → alerta quando a taxa de crash passar de 1%)
- [ ] `Produto` Fazer releases versionadas com changelog (uma release a cada 2 a 4 semanas, notas "O que há de novo" na loja → todo item corresponde a uma entrada do `CHANGELOG.md`)

---

## Fase 10 — Evoluções futuras

### 10.1 Importação e integrações
`80 pts` · 🟡 **Baixa** · `Backend` `ML`
- [ ] `Backend` Importar extrato bancário (OFX e CSV dos principais bancos, com prévia antes de importar e detecção de duplicados → importar o mesmo arquivo duas vezes não duplica nada)
- [x] `ML` Ler notificações bancárias (Nubank e outros, ex.: "Compra de R$ 25,90 aprovada em IFOOD" → vira rascunho com a data da notificação, nunca gravado sem passar pelas checagens)
- [ ] `Backend` Integrar com Open Finance (conexão autorizada pelo usuário com o banco, sincronização diária → o usuário pode revogar a qualquer momento)

### 10.2 Recursos avançados
`90 pts` · ⚪ **Muito baixa** · `Backend` `Frontend` `ML`
- [ ] `Backend` Dividir uma conta entre várias pessoas ("o jantar deu 240, dividi com mais 3" → R$ 60 de gasto meu e R$ 180 a receber dos outros)
- [ ] `Backend` Suporte a várias moedas (lançamento em USD ou EUR com cotação do dia guardada → totais sempre convertidos para a moeda padrão)
- [ ] `Backend` Relatório para o Imposto de Renda (despesas dedutíveis: saúde e educação, rendimentos por fonte, por ano → PDF ou CSV por ano)
- [ ] `Frontend` Widgets na tela inicial do celular (saldo do mês e botão "falar com o César" → atualiza a cada lançamento)
- [ ] `ML` Atalhos de voz do sistema ("Ok Google, fala com o César: gastei 30 no uber" → abre o app já com a frase processada)

---

## Resumo

### Por fase
| Fase | Cards | Pontos |
|---|---|---|
| 0 — Fundação | 3 | 70 |
| 1 — Base visual e navegação | 2 | 70 |
| 2 — Dados e autenticação | 4 | 190 |
| 3 — Finanças (núcleo sem IA) | 9 | 410 |
| 4 — César: motor de linguagem | 3 | 270 |
| 5 — César: conversa | 6 | 370 |
| 6 — Voz | 3 | 140 |
| 7 — Configurações, segurança e privacidade | 4 | 150 |
| 8 — Qualidade contínua | 2 | 110 |
| 9 — Publicação | 2 | 80 |
| 10 — Evoluções futuras | 2 | 170 |
| **Total** | **40** | **2.030** |

### Por prioridade
| Prioridade | Cards | Pontos |
|---|---|---|
| 🔴 Alta | 20 | 1.050 |
| 🟠 Média | 14 | 670 |
| 🟡 Baixa | 5 | 220 |
| ⚪ Muito baixa | 1 | 90 |

### Por área (nº de tarefas)
| Área | Tarefas |
|---|---|
| `Backend` | 70 |
| `Frontend` | 46 |
| `ML` | 38 |
| `QA` | 16 |
| `DevOps` | 15 |
| `Design` | 13 |
| `Produto` | 9 |
| **Total** | **207** |
