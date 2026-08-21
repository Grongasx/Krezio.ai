# ADR-003: Disambiguação de Slots Incompletos e Prompts de Clarificação Empáticos

- **Status:** Accepted
- **Data:** 2026-08-21
- **Autores:** Equipe Krezio.ai

---

## Contexto e Problema
Na rotina real dos usuários, é comum o envio de comandos financeiros parciais ou incompletos (ex: *"Eu gastei 50"*). Nesses cenários, os sistemas tradicionais costumam falhar com mensagens de erro frustrantes (*"Erro: parâmetro ausente"*).

Para manter o tom de voz encorajador, não punitivo e empático do **Krezio.ai** (`krezio-brand`), a engine local deve identificar quais slots críticos estão ausentes (`amount`, `category`, `payment_method`) e interagir de forma natural em múltiplos turnos para completar o registro.

---

## Decisão de Arquitetura

### 1. Analisador de Completude de Slots (`is_complete` & `missing_slots`)
A engine avalia a presença dos 3 pilares fundamentais do lançamento:
- **Valor Monetário (`amount`):** Extração numérica regex/parser.
- **Categoria / Destino (`category`):** Identificação de substantivos de categoria (*mercado, farmácia, uber, etc.*).
- **Forma de Pagamento (`payment_method`):** Detecção dos meios (*pix, débito, crédito, dinheiro, boleto*).

### 2. Gerador de Clarificação Empática (`krezio-brand`)
Se houver slots faltantes, a engine gera prompts acolhedores e contextualizados:
- Entrada: *"Eu gastei 50"*
- Resposta IA: *"Anotado R$ 50,00! Com o que você gastou esse valor e qual foi a forma de pagamento? (ex: mercado no débito, farmácia no pix)"*

### 3. Fusão de Contexto Multi-Turno (`mergeDrafts`)
Quando o usuário responde ao prompt no turno seguinte (*"no mercado no débito"*), a função `mergeDrafts` une as duas mensagens e produz o lançamento financeiro estruturado final com `is_complete: true`.

---

## Consequências
- **Positivas:**
  - 💬 **Experiência Humanizada:** Diálogo natural sem mensagens de erro ou frustração.
  - 🎯 **Precisão dos Dados:** Zero lançamentos incompletos ou categorias incorretas cadastradas por adivinhação.
  - 🔄 **Múltiplos Turnos no Dispositivo:** Processamento 100% offline no celular.
