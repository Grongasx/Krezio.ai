import json
import math
import random
import re
import time
from pathlib import Path
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, accuracy_score

DATA_DIR = Path("data/dataset")
MODEL_DIR = Path("models/on_device")

def load_dataset(split_name):
    file_path = DATA_DIR / f"{split_name}.jsonl"
    data = []
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                data.append(json.loads(line))
    return data

def train_classifier(X_train, y_train, X_val, y_val, task_name):
    print(f"\n==========================================")
    print(f"  Training {task_name} Classifier")
    print(f"==========================================")
    
    vectorizer = TfidfVectorizer(ngram_range=(1, 2), min_df=2, lowercase=True)
    X_train_vec = vectorizer.fit_transform(X_train)
    X_val_vec = vectorizer.transform(X_val)

    clf = LogisticRegression(max_iter=1000, C=5.0)
    clf.fit(X_train_vec, y_train)

    val_preds = clf.predict(X_val_vec)
    acc = accuracy_score(y_val, val_preds)
    print(f"Validation Accuracy: {acc * 100:.2f}%\n")
    print(classification_report(y_val, val_preds, zero_division=0))

    # Extract model parameters for portable execution
    model_data = {
        "classes": list(clf.classes_),
        "intercept": clf.intercept_.tolist(),
        "coef": clf.coef_.tolist()
    }
    
    return vectorizer, model_data

def build_combined_model_json(vectorizer, intent_model, cat_model, pay_model):
    vocab = vectorizer.vocabulary_
    idf = vectorizer.idf_.tolist()
    ngram_range = list(vectorizer.ngram_range)

    combined = {
        "meta": {
            "version": "1.0.0",
            "language": "pt-BR",
            "ngram_range": ngram_range,
            "vocab_size": len(vocab)
        },
        "vocabulary": vocab,
        "idf": idf,
        "models": {
            "intent": intent_model,
            "category": cat_model,
            "payment_method": pay_model
        }
    }
    
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    out_file = MODEL_DIR / "krezio_nlp_model.json"
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(combined, f, ensure_ascii=False, indent=2)
    
    size_kb = out_file.stat().st_size / 1024.0
    print(f"\nSUCCESS: Exported portable model to {out_file} ({size_kb:.1f} KB)")
    return out_file

def main():
    master_file = Path("data/dataset_10k/dataset_10k_master.jsonl")
    samples = []
    with open(master_file, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                samples.append(json.loads(line))

    random.shuffle(samples)
    train_idx = int(0.85 * len(samples))
    train_data = samples[:train_idx]
    val_data = samples[train_idx:]

    X_train = [d["text"] for d in train_data]
    X_val = [d["text"] for d in val_data]

    # Shared TF-IDF Vectorizer
    vectorizer = TfidfVectorizer(ngram_range=(1, 2), min_df=2, lowercase=True)
    vectorizer.fit(X_train)

    # 1. Intent Model
    y_intent_train = [d["intent"] for d in train_data]
    y_intent_val = [d["intent"] for d in val_data]
    _, intent_model = train_classifier(X_train, y_intent_train, X_val, y_intent_val, "Intent")

    # 2. Category Model
    y_cat_train = [d["category"] for d in train_data]
    y_cat_val = [d["category"] for d in val_data]
    _, cat_model = train_classifier(X_train, y_cat_train, X_val, y_cat_val, "Category")

    # 3. Payment Method Model
    y_pay_train = [d["payment_method"] for d in train_data]
    y_pay_val = [d["payment_method"] for d in val_data]
    _, pay_model = train_classifier(X_train, y_pay_train, X_val, y_pay_val, "Payment Method")

    # Export combined model
    build_combined_model_json(vectorizer, intent_model, cat_model, pay_model)

if __name__ == "__main__":
    main()
