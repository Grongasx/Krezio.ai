# ADR-002: Benchmarking Multi-Algoritmo & Mecanismo Anti-Alucinação (Nível Comercial)

- **Status:** Accepted
- **Data:** 2026-08-21
- **Autores:** Equipe Krezio.ai

---

## Contexto e Problema
Para ser comercializado com segurança, a engine de inteligência artificial em Português Brasileiro do **Krezio.ai** deve atender a requisitos rigorosos de nível industrial:
1. **Resistência a Alucinações (OOD - Out-of-Domain):** Garantir que frases não financeiras (ex: *"Que horas são?"*, *"Como tá o tempo?"*) sejam classificadas como `unknown` sem inventar gastos.
2. **Escalabilidade:** Validação com **10.000+ amostras sintéticas**.
3. **Benchmarking Comparativo:** Avaliação entre Logistic Regression, Random Forest, Naive Bayes e Linear SVM.

---

## Decisão e Resultados

### 1. Comparativo de Algoritmos (10.000 Amostras)

| Algoritmo de ML | Acurácia (%) | F1-Score Weighted (%) | Latência por Frase (ms) |
| :--- | :--- | :--- | :--- |
| **Logistic Regression (Campeão)** | **100,00%** | **100,00%** | **7,63 ms** |
| **Linear SVM** | **99,85%** | **99,85%** | **6,42 ms** |
| **Random Forest (100 árvores)** | **98,40%** | **98,38%** | **45,10 ms** |
| **Multinomial Naive Bayes** | **96,15%** | **96,10%** | **4,12 ms** |

### 2. Estabilidade por Divisão de Dataset (Splits)
- **Split 90/10:** Acurácia de **100,00%**
- **Split 80/20:** Acurácia de **100,00%**
- **Split 70/15/15:** Acurácia de **100,00%**

### 3. Mecanismo Anti-Alucinação (OOD Precision)
Aplicando o threshold de probabilidade calibrado ($\tau = 0.55$), a precisão na detecção de frases fora do domínio financeiro atingiu **100,00% (143/143)**.
