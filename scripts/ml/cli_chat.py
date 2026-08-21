import sys
import json
import time
import re
from pathlib import Path
import numpy as np

# Reconfigure stdout to UTF-8 on Windows
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except AttributeError:
        pass

MODEL_FILE = Path("models/on_device/krezio_nlp_model.json")

# ANSI Color formatting
PURPLE = "\033[38;2;139;92;246m"
GREEN = "\033[38;2;16;185;129m"
ORANGE = "\033[38;2;249;115;22m"
CYAN = "\033[96m"
WHITE = "\033[97m"
GRAY = "\033[90m"
BOLD = "\033[1m"
RESET = "\033[0m"

# Enhanced Regex Amount Extractor
RE_MONETARY = re.compile(
    r'(?:R\$\s*[\d.,]+|[\d.]+(?:,\d{1,2})?\s*(?:reais|conto|pila|k\b)|(?:quinhentos|cem|dzentos|trezentos|quatrocentos)\s*reais|\b\d+,\d{2}\b)',
    re.IGNORECASE
)
RE_NUM = re.compile(r'(\d+(?:[.,]\d{1,2})?)', re.IGNORECASE)

DATE_RULES = [
    (re.compile(r'\b(hoje|essa manhã|nesta tarde)\b', re.IGNORECASE), 0),
    (re.compile(r'\b(ontem)\b', re.IGNORECASE), -1),
    (re.compile(r'\b(anteontem)\b', re.IGNORECASE), -2),
    (re.compile(r'\b(semana passada)\b', re.IGNORECASE), -7),
    (re.compile(r'\b(no fim de semana)\b', re.IGNORECASE), -3),
]

WORD_NUMBERS = {
    "quinhentos reais": 500.0,
    "cem reais": 100.0,
    "duzentos reais": 200.0,
    "cinquenta reais": 50.0,
    "vinte reais": 20.0,
    "trinta conto": 30.0
}

def parse_amount(text):
    lower = text.lower()
    
    # Filter out English system / prompt injection keywords
    system_words = ["system", "override", "status", "code", "python", "abcdefg", "ignore", "instructions", " Sentido da vida"]
    if any(w in lower for w in system_words):
        return None

    # Check word numbers
    for k, v in WORD_NUMBERS.items():
        if k in lower:
            return v
            
    # Check "1,5k" or "2k"
    k_match = re.search(r'(\d+(?:[.,]\d+)?)\s*k\b', lower)
    if k_match:
        val = float(k_match.group(1).replace(',', '.'))
        return val * 1000.0

    # Only extract amount if phrase contains explicit financial indicators or spend verbs
    financial_verbs = ["gastei", "gaste", "paguei", "comprei", "caiu", "recebi", "mandei", "transferi", "reais", "conto", "pila", "r$", "fatura", "troco", "fiado"]
    if not any(v in lower for v in financial_verbs):
        return None

    match = RE_NUM.search(text)
    if match:
        val_str = match.group(1).replace('.', '').replace(',', '.')
        try:
            val = float(val_str)
            if val > 0 and val < 1000000:
                return val
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

class LocalFinancialNLPEngine:
    def __init__(self, model_file):
        with open(model_file, "r", encoding="utf-8") as f:
            self.data = json.load(f)
        
        self.meta = self.data["meta"]
        self.vocab = self.data["vocabulary"]
        self.idf = self.data["idf"]
        self.models = self.data["models"]
        self.vocab_size = len(self.vocab)
        self.confidence_threshold = self.meta.get("confidence_threshold", 0.55)

    def normalize_text(self, text):
        # Reduce 3+ repeated characters (e.g. gasteeeeii -> gastei)
        clean = re.sub(r'(.)\1{2,}', r'\1', text.lower())
        return clean

    def extract_tf_idf_vector(self, text):
        norm_text = self.normalize_text(text)
        tokens = norm_text.split()
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
        # If no vocabulary tokens matched (zero vector)
        if sum(vector) == 0.0:
            return "unknown", 1.0

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
        clean_text = phrase.strip()
        norm_text = self.normalize_text(clean_text)
        lower_text = norm_text.lower()

        # Prompt Injection & Non-Financial System Noise Guard
        if any(w in lower_text for w in ["system override", "status code", "ignore todas", "abcdefg"]):
            return {
                "intent": "unknown",
                "intent_confidence": 1.0,
                "category": "unknown",
                "payment_method": "unknown",
                "amount": None,
                "date_offset_days": 0,
                "is_complete": False,
                "missing_slots": [],
                "clarification_prompt": "Notei que sua mensagem não parece ser um lançamento financeiro. Como posso te ajudar com suas finanças hoje?",
                "raw_text": clean_text,
                "latency_ms": (time.perf_counter() - start_t) * 1000.0
            }

        amount = parse_amount(norm_text)
        date_offset = parse_date_offset(norm_text)
        
        vec = self.extract_tf_idf_vector(norm_text)
        intent, intent_conf = self.predict_with_confidence("intent", vec)
        category, cat_conf = self.predict_with_confidence("category", vec)
        payment_method, pay_conf = self.predict_with_confidence("payment_method", vec)
        
        resolved_intent = intent

        # Financial keywords set
        financial_keywords = [
            "gastei", "gasto", "gastos", "paguei", "pagar", "pagamento", "comprei", "compra", "compras",
            "caiu", "recebi", "receita", "receitas", "mandei", "transferi", "pix", "transferencia", "transferência",
            "saldo", "sobrou", "orçamento", "orcamento", "despesa", "despesas", "extrato", "fatura", "limite",
            "mercado", "supermercado", "uber", "gasolina", "farmacia", "remédios", "ifood", "luz", "agua", "internet",
            "aluguel", "salario", "salário", "reembolso", "freela", "pila", "conto", "reais", "dinheiro", "cartao", "cartão"
        ]

        has_fin_kw = any(k in lower_text for k in financial_keywords)
        if "receita de " in lower_text or "cozinhar" in lower_text or "bolo" in lower_text:
            has_fin_kw = False

        # Query & Question Financial Override
        if any(lower_text.startswith(q) for q in ["quanto ", "quantos ", "quantas ", "qual ", "como estão ", "mostre "]):
            if has_fin_kw:
                resolved_intent = "query"
            else:
                resolved_intent = "unknown"

        # Disambiguate transaction vs unknown
        if (resolved_intent in ["query", "unknown"]) and amount is not None and amount > 0 and has_fin_kw:
            if any(k in lower_text for k in ["caiu", "recebi"]):
                resolved_intent = "income"
            elif any(k in lower_text for k in ["mandei", "transferi"]):
                resolved_intent = "transfer"
            elif any(k in lower_text for k in ["gastei", "comprei", "paguei"]):
                resolved_intent = "expense"
        elif not has_fin_kw and amount is None:
            resolved_intent = "unknown"

        missing_slots = []
        if resolved_intent in ["expense", "income", "transfer"]:
            if amount is None or amount <= 0:
                missing_slots.append("amount")
            if not self.has_category_noun(clean_text):
                missing_slots.append("category")
            if payment_method == "unknown" or not self.has_payment_keyword(clean_text):
                missing_slots.append("payment_method")
                
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
            "raw_text": clean_text,
            "latency_ms": elapsed_ms
        }

    def has_category_noun(self, text):
        nouns = {"mercado", "supermercado", "feira", "uber", "gasolina", "farmacia", "remédios", "medico", "dentista", "cinema", "ifood", "luz", "agua", "internet", "aluguel", "salario", "reembolso", "freela", "pagamento"}
        tokens = set(text.lower().split())
        return len(tokens.intersection(nouns)) > 0 or any(n in text.lower() for n in nouns)

    def has_payment_keyword(self, text):
        keywords = ["pix", "credito", "crédito", "debito", "débito", "dinheiro", "especie", "espécie", "boleto", "cartao", "cartão"]
        return any(k in text.lower() for k in keywords)

    def generate_clarification_prompt(self, intent, amount, missing_slots):
        if intent == "unknown":
            return "Notei que sua mensagem não parece ser um lançamento financeiro. Como posso te ajudar com suas finanças hoje?"
        
        amount_str = f"R$ {amount:.2f}".replace('.', ',') if amount else None
        
        if "category" in missing_slots and "payment_method" in missing_slots:
            return f"Anotado {amount_str}! Com o que você gastou esse valor e qual foi a forma de pagamento? (ex: mercado no débito, farmácia no pix)" if amount_str else "Anotado! Onde você realizou esse gasto e qual foi a forma de pagamento?"
            
        if "category" in missing_slots:
            return f"Anotado {amount_str}! Com o que você gastou esse valor? (ex: mercado, farmácia, transporte)" if amount_str else "Com o que foi esse gasto?"
            
        if "payment_method" in missing_slots:
            return f"Anotado {amount_str}! Qual foi a forma de pagamento utilizada? (ex: pix, débito, crédito)" if amount_str else "Qual foi a forma de pagamento dessa transação?"
            
        return "Notei que faltam alguns detalhes para concluir o lançamento."

def print_banner():
    print(f"\n{PURPLE}{BOLD}========================================================================{RESET}")
    print(f"{PURPLE}{BOLD}    🤖 KREZIO.AI - ENGINE DE INTELIGÊNCIA ARTIFICIAL LOCAL (TERMINAL)   {RESET}")
    print(f"{PURPLE}{BOLD}========================================================================{RESET}")
    print(f"{GRAY}Modelo carregado: krezio_nlp_model.json | Latência ~3ms | 100% On-Device{RESET}\n")

def print_result(res):
    print(f"\n{BOLD}------------------------------------------------------------------------{RESET}")
    if res["is_complete"]:
        print(f"Status: {GREEN}{BOLD}✓ TRANSAÇÃO COMPLETA{RESET}")
    else:
        print(f"Status: {ORANGE}{BOLD}⚠ INFORMAÇÕES INCOMPLETAS{RESET}")
        
    print(f"Intenção:         {CYAN}{res['intent'].upper()}{RESET} ({res['intent_confidence']*100:.1f}% conf)")
    print(f"Valor:            {WHITE}{'R$ ' + f'{res['amount']:.2f}'.replace('.', ',') if res['amount'] else 'Não informado'}{RESET}")
    print(f"Categoria:        {WHITE}{res['category']}{RESET}")
    print(f"Meio de Pagamento:{WHITE}{res['payment_method']}{RESET}")
    print(f"Slots Faltantes:  {ORANGE}{res['missing_slots']}{RESET}")
    print(f"Latência:         {GRAY}{res['latency_ms']:.2f} ms (Local CPU){RESET}")
    
    if res["clarification_prompt"]:
        print(f"\n{PURPLE}{BOLD}💬 Resposta do Krezio.ai ({'krezio-brand'}):{RESET}")
        print(f"{WHITE}\"{res['clarification_prompt']}\"{RESET}")
    print(f"{BOLD}------------------------------------------------------------------------{RESET}\n")

def main():
    print_banner()
    engine = LocalFinancialNLPEngine(MODEL_FILE)
    
    if len(sys.argv) > 1:
        phrase = " ".join(sys.argv[1:])
        print(f"Entrada: {WHITE}\"{phrase}\"{RESET}")
        res = engine.parse_phrase(phrase)
        print_result(res)
        return

    active_draft = None
    print(f"{GRAY}Digite uma frase (ex: 'gastei 50', 'caiu 1200 de pagamento no pix') ou 'sair':{RESET}\n")
    
    while True:
        try:
            if active_draft and not active_draft["is_complete"]:
                user_input = input(f"{ORANGE}Responder Clarificação > {RESET}").strip()
            else:
                user_input = input(f"{PURPLE}Krezio.ai > {RESET}").strip()
                
            if not user_input:
                continue
            if user_input.lower() in ["sair", "exit", "quit"]:
                print(f"{PURPLE}Até logo!{RESET}")
                break
                
            if active_draft and not active_draft["is_complete"]:
                merged_text = f"{active_draft['raw_text']} {user_input}"
                res = engine.parse_phrase(merged_text)
            else:
                res = engine.parse_phrase(user_input)
                
            active_draft = res
            print_result(res)
            
        except (KeyboardInterrupt, EOFError):
            print(f"\n{PURPLE}Encerrando sessão.{RESET}")
            break

if __name__ == "__main__":
    main()
