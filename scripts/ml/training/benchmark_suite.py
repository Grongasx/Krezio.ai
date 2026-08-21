import json
import time
import os
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier
from sklearn.naive_bayes import MultinomialNB
from sklearn.svm import LinearSVC
from sklearn.metrics import accuracy_score, precision_recall_fscore_support, confusion_matrix
from sklearn.model_selection import KFold

# Configure matplotlib style
plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
plt.rcParams['font.sans-serif'] = 'DejaVu Sans'
plt.rcParams['axes.edgecolor'] = '#8B5CF6'
plt.rcParams['axes.linewidth'] = 1.2

DATA_FILE = Path("data/dataset_10k/dataset_10k_master.jsonl")
CHARTS_DIR = Path("docs/charts")
MODEL_DIR = Path("models/on_device")

def load_data():
    samples = []
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                samples.append(json.loads(line))
    return samples

def run_split_experiment(samples, train_ratio, val_ratio, test_ratio):
    total = len(samples)
    train_end = int(total * train_ratio)
    val_end = train_end + int(total * val_ratio)
    
    train_data = samples[:train_end]
    val_data = samples[train_end:val_end] if val_ratio > 0 else []
    test_data = samples[val_end:]
    
    return train_data, val_data, test_data

def evaluate_classifier(clf, vectorizer, X_train, y_train, X_test, y_test):
    X_tr_vec = vectorizer.fit_transform(X_train)
    X_te_vec = vectorizer.transform(X_test)
    
    t0 = time.perf_counter()
    clf.fit(X_tr_vec, y_train)
    train_time = (time.perf_counter() - t0) * 1000.0
    
    t0 = time.perf_counter()
    preds = clf.predict(X_te_vec)
    inference_time = (time.perf_counter() - t0) * 1000.0 / len(X_test)
    
    acc = accuracy_score(y_test, preds)
    p, r, f1, _ = precision_recall_fscore_support(y_test, preds, average='weighted', zero_division=0)
    
    return acc, p, r, f1, inference_time, preds

def generate_charts(split_results, algo_results, conf_matrix, labels):
    CHARTS_DIR.mkdir(parents=True, exist_ok=True)
    
    # Chart 1: Accuracy by Dataset Split
    fig, ax = plt.subplots(figsize=(9, 5))
    df_splits = pd.DataFrame(split_results)
    sns.barplot(data=df_splits, x='split', y='accuracy', hue='model', palette='Purples_d', ax=ax)
    ax.set_title('Acurácia por Divisão do Dataset (Splits 90/10, 80/20, 70/15/15)', fontsize=14, fontweight='bold', pad=15)
    ax.set_xlabel('Divisão do Dataset (Treino / Teste)', fontsize=12)
    ax.set_ylabel('Acurácia (%)', fontsize=12)
    ax.set_ylim(80, 100)
    for p in ax.patches:
        height = p.get_height()
        if height > 0:
            ax.annotate(f'{height:.2f}%', (p.get_x() + p.get_width() / 2., height - 3),
                        ha='center', va='bottom', fontsize=10, color='white', fontweight='bold')
    plt.tight_layout()
    chart1_path = CHARTS_DIR / "accuracy_by_split.png"
    plt.savefig(chart1_path, dpi=300)
    plt.close()
    
    # Chart 2: Algorithm Comparison (F1-Score vs Latency)
    fig, ax1 = plt.subplots(figsize=(10, 5.5))
    df_algo = pd.DataFrame(algo_results)
    
    color = '#8B5CF6'
    ax1.set_xlabel('Algoritmo de Machine Learning', fontsize=12, fontweight='bold')
    ax1.set_ylabel('F1-Score Weighted (%)', color=color, fontsize=12, fontweight='bold')
    bars = ax1.bar(df_algo['algorithm'], df_algo['f1_score'] * 100, color='#8B5CF6', alpha=0.85, width=0.45)
    ax1.tick_params(axis='y', labelcolor=color)
    ax1.set_ylim(80, 100)
    
    for bar in bars:
        yval = bar.get_height()
        ax1.text(bar.get_x() + bar.get_width()/2.0, yval - 4, f'{yval:.2f}%', ha='center', va='bottom', color='white', fontweight='bold')
        
    ax2 = ax1.twinx()
    color = '#F97316'
    ax2.set_ylabel('Latência por Frase (ms)', color=color, fontsize=12, fontweight='bold')
    ax2.plot(df_algo['algorithm'], df_algo['latency_ms'], color=color, marker='o', linewidth=3, markersize=8)
    ax2.tick_params(axis='y', labelcolor=color)
    
    plt.title('Comparativo de Algoritmos: F1-Score vs Latência de Inferência', fontsize=14, fontweight='bold', pad=15)
    plt.tight_layout()
    chart2_path = CHARTS_DIR / "algorithm_comparison.png"
    plt.savefig(chart2_path, dpi=300)
    plt.close()
    
    # Chart 3: Confusion Matrix for Intent Classification
    fig, ax = plt.subplots(figsize=(7, 6))
    sns.heatmap(conf_matrix, annot=True, fmt='d', cmap='Purples', xticklabels=labels, yticklabels=labels, ax=ax, cbar=False)
    ax.set_title('Matriz de Confusão do Modelo Campeão (Classificação de Intenção)', fontsize=13, fontweight='bold', pad=15)
    ax.set_xlabel('Intenção Preditada pelo Modelo', fontsize=11)
    ax.set_ylabel('Intenção Real (Ground Truth)', fontsize=11)
    plt.tight_layout()
    chart3_path = CHARTS_DIR / "confusion_matrix_intent.png"
    plt.savefig(chart3_path, dpi=300)
    plt.close()
    
    print(f"SUCCESS: Generated 3 benchmark chart figures in {CHARTS_DIR}")
    return [chart1_path, chart2_path, chart3_path]

def export_champion(samples):
    X = [d["text"] for d in samples]
    y_intent = [d["intent"] for d in samples]
    y_cat = [d["category"] for d in samples]
    y_pay = [d["payment_method"] for d in samples]
    
    vec = TfidfVectorizer(ngram_range=(1, 2), min_df=2, lowercase=True)
    X_vec = vec.fit_transform(X)
    
    # Train champion models
    clf_intent = LogisticRegression(max_iter=1000, C=5.0)
    clf_intent.fit(X_vec, y_intent)
    
    clf_cat = LogisticRegression(max_iter=1000, C=5.0)
    clf_cat.fit(X_vec, y_cat)
    
    clf_pay = LogisticRegression(max_iter=1000, C=5.0)
    clf_pay.fit(X_vec, y_pay)
    
    combined = {
        "meta": {
            "version": "2.0.0-commercial",
            "samples_count": len(samples),
            "language": "pt-BR",
            "confidence_threshold": 0.55,
            "ngram_range": list(vec.ngram_range),
            "vocab_size": len(vec.vocabulary_)
        },
        "vocabulary": vec.vocabulary_,
        "idf": vec.idf_.tolist(),
        "models": {
            "intent": {
                "classes": list(clf_intent.classes_),
                "intercept": clf_intent.intercept_.tolist(),
                "coef": clf_intent.coef_.tolist()
            },
            "category": {
                "classes": list(clf_cat.classes_),
                "intercept": clf_cat.intercept_.tolist(),
                "coef": clf_cat.coef_.tolist()
            },
            "payment_method": {
                "classes": list(clf_pay.classes_),
                "intercept": clf_pay.intercept_.tolist(),
                "coef": clf_pay.coef_.tolist()
            }
        }
    }
    
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    out_file = MODEL_DIR / "krezio_nlp_model.json"
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(combined, f, ensure_ascii=False, indent=2)
        
    print(f"SUCCESS: Champion model exported to {out_file} ({out_file.stat().st_size / 1024.0:.1f} KB)")

def main():
    samples = load_data()
    print(f"Loaded {len(samples)} samples for benchmark suite.")
    
    # 1. Dataset Split Experiments
    split_results = []
    for train_r, val_r, test_r, label in [(0.9, 0.0, 0.1, "90/10"), (0.8, 0.0, 0.2, "80/20"), (0.7, 0.15, 0.15, "70/15/15")]:
        tr_data, _, te_data = run_split_experiment(samples, train_r, val_r, test_r)
        
        X_tr = [d["text"] for d in tr_data]
        y_tr = [d["intent"] for d in tr_data]
        X_te = [d["text"] for d in te_data]
        y_te = [d["intent"] for d in te_data]
        
        vec = TfidfVectorizer(ngram_range=(1, 2), min_df=2, lowercase=True)
        clf = LogisticRegression(max_iter=1000, C=5.0)
        
        acc, _, _, _, _, _ = evaluate_classifier(clf, vec, X_tr, y_tr, X_te, y_te)
        split_results.append({"split": label, "model": "Logistic Regression", "accuracy": acc * 100})
        
    # 2. Algorithm Comparison Benchmark
    tr_data, _, te_data = run_split_experiment(samples, 0.8, 0.0, 0.2)
    X_tr = [d["text"] for d in tr_data]
    y_tr = [d["intent"] for d in tr_data]
    X_te = [d["text"] for d in te_data]
    y_te = [d["intent"] for d in te_data]
    
    algorithms = [
        ("Logistic Regression", LogisticRegression(max_iter=1000, C=5.0)),
        ("Random Forest", RandomForestClassifier(n_estimators=100, random_state=42, n_jobs=-1)),
        ("Naive Bayes", MultinomialNB()),
        ("Linear SVM", LinearSVC(C=1.0, max_iter=2000))
    ]
    
    algo_results = []
    champion_preds = None
    champion_name = "Logistic Regression"
    
    for name, clf in algorithms:
        vec = TfidfVectorizer(ngram_range=(1, 2), min_df=2, lowercase=True)
        acc, p, r, f1, lat, preds = evaluate_classifier(clf, vec, X_tr, y_tr, X_te, y_te)
        algo_results.append({
            "algorithm": name,
            "accuracy": acc * 100,
            "f1_score": f1,
            "latency_ms": lat
        })
        if name == champion_name:
            champion_preds = preds
            
    # Confusion Matrix for Champion Model
    labels = sorted(list(set(y_te)))
    cm = confusion_matrix(y_te, champion_preds, labels=labels)
    
    # Generate visual chart artifacts
    generate_charts(split_results, algo_results, cm, labels)
    
    # Export final champion model
    export_champion(samples)

if __name__ == "__main__":
    main()
