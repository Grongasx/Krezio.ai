---
name: tg-abnt-documentation
description: >-
  Guidelines, formatting standards, and structural runbooks for writing the Trabalho de Graduação (TG / TCC) of Krezio.ai according to ABNT standards (NBR 14724, NBR 6023, NBR 10520).
  Use whenever generating academic text, TG chapters, thesis documentation, theoretical references, methodology, or preparation material for the academic evaluation board (banca examinadora).
---

# Krezio.ai TG/TCC Academic Documentation Skill (Normas ABNT)

This skill defines the complete methodology, structural layout, formatting standards, and writing guidelines for producing the **Trabalho de Graduação (TG / TCC)** of **Krezio.ai** formatted for academic evaluation boards according to ABNT rules.

---

## 1. Normas ABNT Aplicadas

All academic writing for Krezio.ai must strictly conform to:
- **NBR 14724:** Estrutura e Apresentação de Trabalhos Acadêmicos.
- **NBR 10520:** Citações em Documentos (Sistema Autor-Data).
- **NBR 6023:** Referências Bibliográficas.
- **NBR 6028:** Resumos e Abstract.
- **NBR 6024:** Numeração Progressiva das Seções de um Documento.

---

## 2. Regras de Formatação Gráfica ABNT

| Elemento | Regra ABNT |
| :--- | :--- |
| **Margens** | Superior: 3,0 cm \| Esquerda: 3,0 cm \| Inferior: 2,0 cm \| Direita: 2,0 cm |
| **Fonte** | Arial ou Times New Roman |
| **Tamanho da Fonte** | Corpo de texto: **12pt** \| Citações longas, notas e legendas: **10pt** |
| **Espaçamento entre linhas** | Corpo de texto: **1,5** \| Citações longas, tabelas e referências: **1,0 (Simples)** |
| **Recuo de Parágrafo** | 1,25 cm (primeira linha de cada parágrafo) |
| **Citação Direta Longa (>3 linhas)** | Recuo de 4,0 cm da margem esquerda, fonte 10pt, espaçamento simples, sem aspas. |
| **Figuras e Tabelas** | Título no topo (`Figura 1 – Diagrama de Arquitetura`), Fonte na parte inferior (`Fonte: Elaborado pelo autor, 2026`). |
| **Referências (NBR 6023)** | Alinhadas à esquerda, espaçamento simples, ordenadas alfabeticamente por Sobrenome. |

---

## 3. Estrutura Padrão do Trabalho de Graduação (TG)

A documentação acadêmica do Krezio.ai fica centralizada no diretório `docs/tg/` organizada nos seguintes ficheiros:

```text
docs/tg/
├── 00_elementos_pre_textuais.md   # Capa, Folha de Rosto, Resumo, Abstract, Sumário
├── 01_introducao.md               # Contextualização, Problema, Objetivos, Justificativa
├── 02_referencial_teorico.md       # Finanças Pessoais, IA, UX/UI, Flutter, LLMs
├── 03_metodologia.md               # Metodologia de Dev, Tecnologias, Engenharia de Prompts
├── 04_arquitetura_desenvolvimento.md # Arquitetura do Krezio.ai, Diagramas, Telas, IA
├── 05_resultados_discussao.md      # Validação, Testes, Análise dos Insights
├── 06_conclusao.md                # Considerações Finais e Trabalhos Futuros
└── referencias.md                  # Referências bibliográficas completas (NBR 6023)
```

---

## 4. Roteiro dos Capítulos do TG - Krezio.ai

### Capítulo 1: Introdução
- **Contextualização:** O desafio da alfabetização e gestão financeira pessoal no Brasil.
- **Problema de Pesquisa:** Como uma aplicação mobile combinando assistente de IA empático e análise de dados pode auxiliar no controle financeiro sem gerar gatilhos de ansiedade?
- **Objetivo Geral:** Desenvolver o aplicativo Krezio.ai para gestão financeira pessoal orientada a dados.
- **Objetivos Específicos:**
  1. Definir o Design System e psicologia das cores amigáveis (ausência de vermelho sangue para gastos).
  2. Implementar assistente virtual preditivo com linguagem clara e empática.
  3. Estruturar visualização de dados via Dashboard/Insights.
- **Justificativa:** Relevância social da educação financeira e inovação tecnológica com IA generativa e preditiva.

### Capítulo 2: Referencial Teórico
- **2.1 Saúde e Educação Financeira Pessoal:** Impacto do endividamento e controle orçamentário.
- **2.2 Inteligência Artificial Generativa e Preditiva nas Finanças:** Uso de LLMs como conselheiros financeiros.
- **2.3 UX Writing e Psicologia das Cores:** Interfaces não punitivas em sistemas financeiros.
- **2.4 Tecnologias Mobile:** Framework Flutter, arquitetura reativa e consumo de APIs.

### Capítulo 3: Metodologia
- **Abordagem:** Pesquisa aplicada com desenvolvimento tecnológico experimental.
- **Metodologia de Desenvolvimento:** Desenvolvimento Ágil (Scrum/Kanban) e Design Thinking.
- **Ferramentas e Tecnologias:** Flutter/Dart, Python (`code-review-graph`), SQLite, LLM APIs.

### Capítulo 4: Arquitetura e Desenvolvimento do Krezio.ai
- **Arquitetura de Software:** Clean Architecture / Feature-First no Flutter.
- **Engenharia do Assistente IA:** Prompt Engineering, extração de métricas financeiras e geração de orientações.
- **Design System Krezio.ai:** Paleta de cores, tipografia (Space Grotesk / Plus Jakarta Sans) e suporte a Light/Dark Mode.

### Capítulo 5: Resultados e Discussão
- **Demonstração do Protótipo:** Apresentação das telas principais (Dashboard, Extrato, Assistente IA).
- **Avaliação de Usabilidade e Tom de Voz:** Testes com usuários e análise de aceitação do tom não alarmista.

### Capítulo 6: Conclusão
- Síntese dos resultados, limitações do trabalho e propostas de trabalhos futuros.

---

## 5. Diretrizes de Escrita para o Agente AI

Ao redigir qualquer trecho do TG para o usuário:
1. **Linguagem Acadêmica:** Utilizar terceira pessoa do singular ou primeira pessoa do plural (impessoal/formal), mantendo rigor científico.
2. **Citações Corretas:**
   - Citação indireta: *"Segundo Silva (2024), a inteligência artificial..."*
   - Citação direta curta: *"A gestão de finanças 'exige consistência diária' (SOUZA, 2025, p. 45)."*
   - Citação direta longa: Bloco separado com 4 cm de recuo, fonte 10pt e espaçamento simples.
3. **Formatação Markdown para ABNT:**
   - Usar marcações claras de títulos (`# 1 INTRODUÇÃO`, `## 1.1 PROBLEMA DE PESQUISA`).
   - Indicar claramente as fontes em todas as tabelas e figuras (`Fonte: Elaborado pelo autor, 2026`).
4. **Sincronização:** Manutenção da lista de referências em `docs/tg/referencias.md` para cada autor citado.
