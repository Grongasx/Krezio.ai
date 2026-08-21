import json
import os
import re
import numpy as np
from pathlib import Path
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.metrics import classification_report, accuracy_score
import skl2onnx
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import StringTensorType
import onnxruntime as ort

DATA_DIR = Path("data/dataset")
MODEL_DIR = Path("models/on_device")

def load_data(split_name):
    file_path = DATA_DIR / f"{split_name}.jsonl"
    data = []
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                data.append(json.loads(line))
    return data

def train_and_eval_pipeline(X_train, y_train, X_val, y_val, task_name):
    print(f"\n--- Training {task_name} Classifier ---")
    pipeline = Pipeline([
        ('tfidf', TfidfVectorizer(ngram_range=(1, 2), min_df=2, lower_case=True)),
        ('clf', LogisticRegression(max_iter=1000, C=5.0))
    ])
    
    pipeline.fit(X_train, y_train)
    
    preds = pipeline.predict(X_val)
    acc = accuracy_score(y_val, preds)
    print(f"Validation Accuracy for {task_name}: {acc * 100:.2f}%")
    print(classification_report(y_val, preds, zero_division=0))
    
    return pipeline

def export_pipeline_to_onnx(pipeline, filename):
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    initial_type = [('string_input', StringTensorType([None, 1]))]
    onx = convert_sklearn(pipeline, initial_types=initial_type, target_opset=12)
    
    out_path = MODEL_DIR / filename
    with open(out_path, "wb") as f:
        f.write(onx.SerializeToString())
    
    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"Exported ONNX model to {out_path} ({size_mb:.3f} MB)")
    return out_path

def verify_onnx_inference(onnx_file, sample_texts):
    sess = ort.InferenceSession(str(onnx_file))
    input_name = sess.get_inputs()[0].name
    label_name = sess.get_outputs()[0].name
    
    input_data = np.array([[t] for t in sample_texts], dtype=object)
    results = sess.run([label_name], {input_name: input_data})
    
    print(f"\nONNX Inference Verification for {onnx_file.name}:")
    for text, pred in zip(sample_texts, results[0]):
        print(f"  Phrase: '{text}' -> Predicted: {pred}")

def main():
    train_data = load_data("train")
    val_data = load_data("val")
    test_data = load_data("test")

    X_train = [d["text"] for d in train_data]
    X_val = [d["text"] for d in val_data]
    X_test = [d["text"] for d in test_data]

    # Task 1: Intent
    y_intent_train = [d["intent"] for d in train_data]
    y_intent_val = [d["intent"] for d in val_data]
    y_intent_test = [d["intent"] for d in test_data]
    
    intent_pipeline = train_and_eval_pipeline(X_train, y_intent_train, X_val, y_intent_val, "Intent")
    intent_onnx = export_pipeline_to_onnx(intent_pipeline, "krezio_nlp_intent.onnx")

    # Task 2: Category
    y_cat_train = [d["category"] for d in train_data]
    y_cat_val = [d["category"] for d in val_data]
    
    cat_pipeline = train_and_eval_pipeline(X_train, y_cat_train, X_val, y_cat_val, "Category")
    cat_onnx = export_pipeline_to_onnx(cat_pipeline, "krezio_nlp_category.onnx")

    # Task 3: Payment Method
    y_pay_train = [d["payment_method"] for d in train_data]
    y_pay_val = [d["payment_method"] for d in val_data]
    
    pay_pipeline = train_and_eval_pipeline(X_train, y_pay_train, X_val, y_pay_val, "Payment Method")
    pay_onnx = export_pipeline_to_onnx(pay_pipeline, "krezio_nlp_payment.onnx")

    # Verify ONNX Runtime Local Inference
    samples = [
        "Gastei 45 reais no mercado com arroz e feijão no pix ontem",
        "Caiu meu salário de 3500 reais na conta",
        "Mandei 50 conto no pix pro Lucas anteontem",
        "Quanto eu gastei com transporte este mês?"
    ]
    verify_onnx_inference(intent_onnx, samples)
    verify_onnx_inference(cat_onnx, samples)
    verify_onnx_inference(pay_onnx, samples)

if __name__ == "__main__":
    main()
