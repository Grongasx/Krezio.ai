# ADR-001: Machine Learning On-Device para Reconhecimento de Frases Financeiras

- **Status:** Accepted
- **Data:** 2026-08-21
- **Autores:** Equipe Krezio.ai

---

## Contexto e Problema
O aplicativo **Krezio.ai** necessita interpretar frases em linguagem natural em Português Brasileiro (ex: *"Gastei 45 reais no mercado no pix ontem"*) e transformá-las instantaneamente em lançamentos financeiros estruturados. Como o app lida com dados financeiros sensíveis, o envio dessas frases para APIs externas em nuvem acarreta custos recorrentes, latência e potenciais preocupações com privacidade de dados.

## Decisão
Implementar uma **Engine de Machine Learning On-Device** executada 100% no celular do usuário via Dart/Flutter utilizando um modelo quantizado portátil (`krezio_nlp_model.json`).

### Componentes da Solução:
1. **Dataset Sintético em Português Brasileiro (`scripts/ml/generate_dataset.py`):** 4.000 amostras sintéticas com gírias (*Pix, boleto, vaquinha, conto, pila*), numerais e datas relativas.
2. **Pipeline de Treinamento TF-IDF + Regressão Logística Multiclasse:** Modelo para classificação de Intenção (*Expense, Income, Transfer, Query*), Categoria (*Supermarket, Transport, Health, Leisure, Housing, etc.*) e Meio de Pagamento.
3. **Engine Local em Dart (`lib/core/ml/local_nlp_engine.dart`):** Inferência sem dependências binárias externas C++, rodando em **< 3 milissegundos**.

---

## Consequências
- **Positivas:**
  - 🔒 **Privacidade 100% Garantida:** Nenhum dado financeiro do usuário sai do aparelho.
  - ⚡ **Latência Ultra-Baixa:** Inferência local realizada em ~2,0ms.
  - 🌐 **Funcionamento Offline:** Funciona perfeitamente sem qualquer conexão de internet.
  - 📦 **Tamanho Reduzido:** Modelo portátil com apenas 1,4 MB.
- **Riscos/Mitigações:**
  - Casos com gírias regionais extremamente raras serão continuamente adicionados ao gerador sintético para re-treinamento incremental.
