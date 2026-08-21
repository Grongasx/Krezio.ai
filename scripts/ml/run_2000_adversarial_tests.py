import json
import time
import re
from pathlib import Path
import numpy as np

from cli_chat import LocalFinancialNLPEngine

DATA_FILE = Path("data/dataset_2k_adversarial.jsonl")
MODEL_FILE = Path("models/on_device/krezio_nlp_model.json")
REPORT_FILE = Path("docs/reports/2000_adversarial_test_report.md")

def main():
    engine = LocalFinancialNLPEngine(MODEL_FILE)
    
    samples = []
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                samples.append(json.loads(line))
                
    print(f"\n========================================================")
    print(f"  RUNNING 2,000 ADVERSARIAL STRESS TEST BENCHMARK")
    print(f"========================================================")
    
    results = []
    errors = []
    
    intent_tp = {}
    intent_fp = {}
    intent_fn = {}

    for idx, item in enumerate(samples, 1):
        phrase = item["text"]
        expected_intent = item["intent"]
        expected_cat = item["category"]
        expected_pay = item["payment_method"]
        expected_amount = item["amount"]
        
        parsed = engine.parse_phrase(phrase)
        
        pred_intent = parsed["intent"]
        pred_cat = parsed["category"]
        pred_pay = parsed["payment_method"]
        pred_amount = parsed["amount"]
        conf = parsed["intent_confidence"]
        
        intent_match = (pred_intent == expected_intent)
        cat_match = (pred_cat == expected_cat)
        pay_match = (pred_pay == expected_pay)
        amount_match = True if expected_amount is None else (pred_amount is not None and abs(pred_amount - expected_amount) < 0.05)

        # Track Intent metrics
        if expected_intent not in intent_tp: intent_tp[expected_intent] = 0
        if expected_intent not in intent_fn: intent_fn[expected_intent] = 0
        if pred_intent not in intent_fp: intent_fp[pred_intent] = 0
        if pred_intent not in intent_tp: intent_tp[pred_intent] = 0
        
        if intent_match:
            intent_tp[expected_intent] += 1
        else:
            intent_fn[expected_intent] += 1
            intent_fp[pred_intent] += 1
            errors.append({
                "sample_id": idx,
                "text": phrase,
                "type": "Intent Misclassification",
                "expected": expected_intent,
                "predicted": pred_intent,
                "confidence": conf
            })

        results.append({
            "sample_id": idx,
            "phrase": phrase,
            "expected_intent": expected_intent,
            "pred_intent": pred_intent,
            "intent_match": intent_match,
            "cat_match": cat_match,
            "pay_match": pay_match,
            "amount_match": amount_match,
            "latency_ms": parsed["latency_ms"]
        })

    # Calculate Class Precisions
    intent_precisions = {}
    for intent_class in set(list(intent_tp.keys()) + list(intent_fp.keys())):
        tp = intent_tp.get(intent_class, 0)
        fp = intent_fp.get(intent_class, 0)
        precision = (tp / (tp + fp)) * 100.0 if (tp + fp) > 0 else 0.0
        intent_precisions[intent_class] = precision

    total_samples = len(samples)
    total_intent_correct = sum(1 for r in results if r["intent_match"])
    overall_intent_acc = (total_intent_correct / total_samples) * 100.0
    avg_latency = np.mean([r["latency_ms"] for r in results])

    print(f"Total Adversarial Samples:    {total_samples}")
    print(f"Overall Intent Accuracy:       {overall_intent_acc:.2f}% ({total_intent_correct}/{total_samples})")
    print(f"Total Discrepancies/Errors:    {len(errors)}")

    # Generate Markdown Report Artifact
    REPORT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(REPORT_FILE, "w", encoding="utf-8") as f:
        f.write("# Relatório de Estresse Adversarial da IA (2.000 Amostras) - Krezio.ai\n\n")
        f.write("Este relatório apresenta a avaliação de estresse contendo 2.000 testes adversariais (gírias, erros de digitação, ambiguidades, formatações de moeda complexas e frases fora de contexto) executados na engine de IA local do **Krezio.ai**.\n\n")
        f.write("---\n\n")
        f.write("## 📈 1. Resumo Executivo de Desempenho Adversarial\n\n")
        f.write(f"- **Total de Testes Adversariais:** 2.000 amostras\n")
        f.write(f"- **Acurácia Geral de Intenção (*Intent*):** **{overall_intent_acc:.2f}%** ({total_intent_correct}/2000)\n")
        f.write(f"- **Latência Média de Inferência Local:** **{avg_latency:.2f} ms**\n")
        f.write(f"- **Total de Erros Identificados:** **{len(errors)}**\n\n")
        
        f.write("---\n\n")
        f.write("## 🎯 2. Precisão por Classe de Resposta (Intent Precision)\n\n")
        f.write("| Classe de Resposta (Intent) | Precisão Obtida (%) | Total de Ocorrências | Status |\n")
        f.write("| :--- | :--- | :--- | :--- |\n")
        for cls_name, prec in sorted(intent_precisions.items()):
            count = sum(1 for r in results if r["expected_intent"] == cls_name)
            f.write(f"| **`{cls_name}`** | **{prec:.2f}%** | {count} amostras | {'✅ Excelente' if prec >= 95 else '⚠️ Atenção'} |\n")
        
        f.write("\n---\n\n")
        f.write("## ⚠️ 3. Lista Completa de Erros Encontrados\n\n")
        if len(errors) == 0:
            f.write("🎉 **Nenhum erro de classificação foi encontrado nas 2.000 amostras adversariais!** A acurácia atingiu 100%.\n\n")
        else:
            f.write(f"Abaixo está a lista dos **{len(errors)} erros** identificados durante a execução dos 2.000 testes de estresse:\n\n")
            f.write("| ID | Frase Testada | Tipo do Erro | Esperado | Predito | Confiança |\n")
            f.write("| :--- | :--- | :--- | :--- | :--- | :--- |\n")
            for err in errors:
                f.write(f"| #{err['sample_id']} | \"{err['text']}\" | {err['type']} | `{err['expected']}` | `{err['predicted']}` | {err['confidence']*100:.1f}% |\n")

    print(f"SUCCESS: Adversarial report saved to {REPORT_FILE}")

if __name__ == "__main__":
    main()
