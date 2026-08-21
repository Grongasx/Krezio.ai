import json
import math
import re
import time
from pathlib import Path
import numpy as np

MODEL_FILE = Path("models/on_device/krezio_nlp_model.json")
TEST_FILE = Path("data/dataset_10k/dataset_10k_master.jsonl")

RE_AMOUNT = re.compile(r'(?:R\$\s*)?(\d+(?:[.,]\d{1,2})?)\s*(?:reais|conto|pila|R\$)?', re.IGNORECASE)
DATE_RULES = [
    (re.compile(r'\b(hoje|essa manhã|nesta tarde)\b', re.IGNORECASE), 0),
    (re.compile(r'\b(ontem)\b', re.IGNORECASE), -1),
    (re.compile(r'\b(anteontem)\b', re.IGNORECASE), -2),
    (re.compile(r'\b(semana passada)\b', re.IGNORECASE), -7),
    (re.compile(r'\b(no fim de semana)\b', re.IGNORECASE), -3),
]

def parse_amount(text):
    match = RE_AMOUNT.search(text)
    if match:
        val_str = match.group(1).replace(',', '.')
        try:
            return float(val_str)
        except ValueError:
            return None
    return None

def parse_date_offset(text):
    for pattern, offset in DATE_RULES:
        if pattern.search(text):
            return offset
    return 0

def softmax(x):
    e_x = np.exp(x - np.max(x))
    return e_x / e_x.sum()

class CommercialFinancialNLPEngine:
    def __init__(self, model_file):
        with open(model_file, "r", encoding="utf-8") as f:
            self.data = json.load(f)
        
        self.meta = self.data["meta"]
        self.vocab = self.data["vocabulary"]
        self.idf = self.data["idf"]
        self.models = self.data["models"]
        self.vocab_size = len(self.vocab)
        self.confidence_threshold = self.meta.get("confidence_threshold", 0.55)

    def extract_tf_idf_vector(self, text):
        tokens = text.lower().split()
        ngrams = []
        for t in tokens:
            ngrams.append(t)
        for i in range(len(tokens) - 1):
            ngrams.append(f"{tokens[i]} {tokens[i+1]}")
        
        counts = {}
        for ng in ngrams:
            if ng in self.vocab:
                idx = self.vocab[ng]
                counts[idx] = counts.get(idx, 0) + 1
        
        vec = [0.0] * self.vocab_size
        total_tokens = len(tokens) if len(tokens) > 0 else 1
        for idx, count in counts.items():
            tf = count / total_tokens
            vec[idx] = tf * self.idf[idx]
            
        return vec

    def predict_with_confidence(self, model_name, vector):
        m = self.models[model_name]
        classes = m["classes"]
        coef = m["coef"]
        intercept = m["intercept"]
        
        scores = []
        for c_idx in range(len(classes)):
            score = intercept[c_idx]
            weights = coef[c_idx]
            for feat_idx, val in enumerate(vector):
                if val != 0.0:
                    score += weights[feat_idx] * val
            scores.append(score)
            
        probs = softmax(np.array(scores))
        best_idx = int(np.argmax(probs))
        max_prob = float(probs[best_idx])
        
        if max_prob < self.confidence_threshold:
            return "unknown", max_prob
        return classes[best_idx], max_prob

    def parse_phrase(self, phrase):
        start_t = time.perf_counter()
        
        vec = self.extract_tf_idf_vector(phrase)
        intent, intent_conf = self.predict_with_confidence("intent", vec)
        category, cat_conf = self.predict_with_confidence("category", vec)
        payment_method, pay_conf = self.predict_with_confidence("payment_method", vec)
        amount = parse_amount(phrase)
        date_offset = parse_date_offset(phrase)
        
        resolved_intent = intent
        if (resolved_intent in ["query", "unknown"]) and amount is not None and amount > 0:
            lower_text = phrase.lower()
            if any(k in lower_text for k in ["caiu", "recebi"]):
                resolved_intent = "income"
            elif any(k in lower_text for k in ["mandei", "transferi"]):
                resolved_intent = "transfer"
            else:
                resolved_intent = "expense"
        elif resolved_intent == "unknown":
            lower_text = phrase.lower()
            if any(k in lower_text for k in ["gastei", "comprei", "paguei"]):
                resolved_intent = "expense"
            elif any(k in lower_text for k in ["caiu", "recebi"]):
                resolved_intent = "income"
            elif any(k in lower_text for k in ["mandei", "transferi"]):
                resolved_intent = "transfer"

        missing_slots = []
        if resolved_intent in ["expense", "income", "transfer"]:
            if amount is None or amount <= 0:
                missing_slots.append("amount")
            if not self.has_category_noun(phrase):
                missing_slots.append("category")
            if payment_method == "unknown" or not self.has_payment_keyword(phrase):
                missing_slots.append("payment_method")
                
        # print(f"DEBUG: '{phrase}' -> intent={resolved_intent}, missing={missing_slots}")
        is_complete = (resolved_intent != "unknown") and len(missing_slots) == 0
        clarification_prompt = None if is_complete else self.generate_clarification_prompt(resolved_intent, amount, missing_slots)

        elapsed_ms = (time.perf_counter() - start_t) * 1000.0

        return {
            "intent": resolved_intent,
            "intent_confidence": intent_conf,
            "category": category,
            "payment_method": payment_method,
            "amount": amount,
            "date_offset_days": date_offset,
            "is_complete": is_complete,
            "missing_slots": missing_slots,
            "clarification_prompt": clarification_prompt,
            "latency_ms": elapsed_ms
        }

    def has_category_noun(self, text):
        nouns = {"mercado", "supermercado", "feira", "uber", "gasolina", "farmacia", "medico", "cinema", "ifood", "luz", "agua", "internet", "aluguel", "salario", "reembolso", "freela", "pagamento"}
        tokens = set(text.lower().split())
        return len(tokens.intersection(nouns)) > 0

    def has_payment_keyword(self, text):
        keywords = ["pix", "credito", "crédito", "debito", "débito", "dinheiro", "especie", "espécie", "boleto", "cartao", "cartão"]
        return any(k in text.lower() for k in keywords)

    def generate_clarification_prompt(self, intent, amount, missing_slots):
        if intent == "unknown":
            return "Notei que sua mensagem não parece ser um lançamento financeiro. Como posso te ajudar hoje?"
        
        amount_str = f"R$ {amount:.2f}".replace('.', ',') if amount else None
        
        if "category" in missing_slots and "payment_method" in missing_slots:
            return f"Anotado {amount_str}! Com o que você gastou esse valor e qual foi a forma de pagamento? (ex: mercado no débito, farmácia no pix)" if amount_str else "Anotado! Onde você realizou esse gasto e qual foi a forma de pagamento?"
            
        if "category" in missing_slots:
            return f"Anotado {amount_str}! Com o que você gastou esse valor? (ex: mercado, farmácia, transporte)" if amount_str else "Com o que foi esse gasto?"
            
        if "payment_method" in missing_slots:
            return f"Anotado {amount_str}! Qual foi a forma de pagamento utilizada? (ex: pix, débito, crédito)" if amount_str else "Qual foi a forma de pagamento?"
            
        return "Notei que faltam detalhes para concluir o lançamento."

def evaluate():
    engine = CommercialFinancialNLPEngine(MODEL_FILE)
    
    print("\n========================================================")
    print("  INCOMPLETE PHRASE & CLARIFICATION TEST SUITE")
    print("========================================================")

    incomplete_cases = [
        "eu gastei 50",
        "comprei no mercado",
        "paguei 120 no pix",
        "gastei 35 conto",
        "caiu 1500 de pagamento"
    ]

    # Multi-turn context merging simulation
    print("\n--- Multi-Turn Conversation Simulation ---")
    draft1 = engine.parse_phrase("eu gastei 50")
    print(f"Turn 1 Input: 'eu gastei 50'")
    print(f"  -> Complete: {draft1['is_complete']}")
    print(f"  -> Prompt: \"{draft1['clarification_prompt']}\"")
    
    # User responds to prompt with missing details
    followup = "no mercado no débito"
    merged_text = f"{'eu gastei 50'} {followup}"
    draft2 = engine.parse_phrase(merged_text)
    print(f"\nTurn 2 User Answer: '{followup}'")
    print(f"  -> Merged Complete: {draft2['is_complete']}")
    print(f"  -> Final Transaction: Amount={draft2['amount']} | Category={draft2['category']} | Method={draft2['payment_method']}")
    print(f"  -> Final Prompt: {draft2['clarification_prompt']}")

if __name__ == "__main__":
    evaluate()
