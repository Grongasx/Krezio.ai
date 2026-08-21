import json
import random
import os
from pathlib import Path

# Seed for reproducibility
random.seed(42)

CATEGORIES = [
    "supermarket", "transport", "health", "leisure",
    "housing", "education", "salary", "investment",
    "income_other", "expense_other"
]

PAYMENT_METHODS = ["pix", "credit_card", "debit_card", "cash", "bank_slip"]

NAMES = ["Joao", "Maria", "Lucas", "Ana", "Pedro", "Carla", "Matheus", "Beatriz", "Gabriel", "Julia"]

DESCRIPTIONS = {
    "supermarket": ["compras do mês", "feira hortifruti", "itens de limpeza", "arroz e feijão", "pão e leite", "supermercado"],
    "transport": ["uber pro trabalho", "gasolina do carro", "estacionamento no shopping", "recarga do bilhete único", "pedágio"],
    "health": ["remédios na farmácia", "consulta médica", "exames de sangue", "dentista", "vitamina C"],
    "leisure": ["lanche no iFood", "cinema no sábado", "cerveja no bar com os amigos", "ingressos do show", "jogos na Steam"],
    "housing": ["conta de luz", "conta de água", "fatura da internet", "aluguel do apartamento", "taxa de condomínio"],
    "education": ["mensalidade da faculdade", "curso de inglês", "livro didático de programação", "inscrição no workshop"],
    "expense_other": ["presente de aniversário", "conserto do celular", "corte de cabelo", "roupa nova"]
}

DATES_PT = [
    ("hoje", 0),
    ("ontem", -1),
    ("anteontem", -2),
    ("essa manhã", 0),
    ("nesta tarde", 0),
    ("semana passada", -7),
    ("no fim de semana", -3),
    ("", 0)
]

METHOD_PHRASES = {
    "pix": ["no pix", "via pix", "pelo pix", "transferência pix"],
    "credit_card": ["no cartão de crédito", "no crédito", "no cartão", "parcelado no crédito"],
    "debit_card": ["no débito", "no cartão de débito", "passou no débito"],
    "cash": ["em dinheiro", "em espécie", "no dinheiro vivo", "nas notas"],
    "bank_slip": ["no boleto", "via boleto bancário", "paguei o boleto"]
}

def generate_amount():
    vals = [12.50, 25.00, 45.90, 89.00, 120.00, 250.00, 499.90, 1200.00, 3500.00, 15.00, 8.50, 65.00, 150.00]
    val = random.choice(vals)
    if random.random() > 0.5:
        val = round(random.uniform(5.0, 2500.0), 2)
    return val

def format_amount_str(amount):
    style = random.choice(["num_dot", "num_comma", "reais_suffix", "conto_slang", "pila_slang"])
    int_part = int(amount)
    dec_part = int(round((amount - int_part) * 100))

    if style == "num_dot":
        return f"{amount:.2f}"
    elif style == "num_comma":
        return f"{int_part},{dec_part:02d}"
    elif style == "reais_suffix":
        return f"{int_part} reais" if dec_part == 0 else f"{int_part} reais e {dec_part} centavos"
    elif style == "conto_slang":
        return f"{int_part} conto"
    else:
        return f"{int_part} pila"

def generate_expense():
    cat = random.choice(["supermarket", "transport", "health", "leisure", "housing", "education", "expense_other"])
    desc = random.choice(DESCRIPTIONS[cat])
    amount = generate_amount()
    amount_str = format_amount_str(amount)
    method_key = random.choice(PAYMENT_METHODS)
    method_str = random.choice(METHOD_PHRASES[method_key])
    date_str, date_offset = random.choice(DATES_PT)

    verbs = ["Gastei", "Comprei", "Paguei", "Passei", "Lançar gasto de"]
    verb = random.choice(verbs)

    templates = [
        f"{verb} {amount_str} com {desc} {method_str} {date_str}".strip(),
        f"{verb} {desc} por {amount_str} {method_str}".strip(),
        f"{desc} deu {amount_str} {date_str} {method_str}".strip(),
        f"{verb} {amount_str} no {desc}".strip(),
        f"Gasto de {amount_str} em {desc} {date_str}".strip()
    ]

    phrase = random.choice(templates)
    # clean extra spaces
    phrase = " ".join(phrase.split())

    data = {
        "text": phrase,
        "intent": "expense",
        "amount": amount,
        "category": cat,
        "payment_method": method_key,
        "date_offset_days": date_offset,
        "description": desc
    }
    return data

def generate_income():
    subtype = random.choice(["salary", "investment", "income_other"])
    amount = generate_amount()
    amount_str = format_amount_str(amount)
    date_str, date_offset = random.choice(DATES_PT)
    name = random.choice(NAMES)

    if subtype == "salary":
        desc = "pagamento de salário"
        phrases = [
            f"Caiu o salário de {amount_str} na conta {date_str}",
            f"Recebi meu pagamento de {amount_str} {date_str}",
            f"Depósito do salário de {amount_str} reais",
            f"Entrou o salário de {amount_str}"
        ]
    elif subtype == "investment":
        desc = "rendimento de investimentos"
        phrases = [
            f"Rendimento de {amount_str} nos investimentos {date_str}",
            f"Recebi {amount_str} de dividendos",
            f"Resgatei {amount_str} da caixinha de investimentos",
            f"Lucro de {amount_str} das ações"
        ]
    else:
        desc = f"transferência recebida de {name}"
        phrases = [
            f"Recebi {amount_str} no pix do {name} {date_str}",
            f"Entrou {amount_str} de reembolso {date_str}",
            f"Recebi {amount_str} por um freela {date_str}",
            f"Pix recebido de {amount_str} da {name}"
        ]

    phrase = random.choice(phrases)
    phrase = " ".join(phrase.split())

    return {
        "text": phrase,
        "intent": "income",
        "amount": amount,
        "category": subtype,
        "payment_method": "pix" if "pix" in phrase.lower() else "unknown",
        "date_offset_days": date_offset,
        "description": desc
    }

def generate_transfer():
    amount = generate_amount()
    amount_str = format_amount_str(amount)
    name = random.choice(NAMES)
    date_str, date_offset = random.choice(DATES_PT)

    phrases = [
        f"Mandei {amount_str} no pix pro {name} {date_str}",
        f"Transferi {amount_str} para a conta de investimento",
        f"Fiz um pix de {amount_str} pra {name} {date_str}",
        f"Transferência de {amount_str} realizada pro {name}"
    ]

    phrase = random.choice(phrases)
    phrase = " ".join(phrase.split())

    return {
        "text": phrase,
        "intent": "transfer",
        "amount": amount,
        "category": "expense_other",
        "payment_method": "pix",
        "date_offset_days": date_offset,
        "description": f"transferência para {name}"
    }

def generate_query():
    phrases = [
        "Quanto eu gastei com mercado este mês?",
        "Qual foi meu maior gasto essa semana?",
        "Quanto sobrou do meu salário?",
        "Como estão minhas despesas com transporte?",
        "Qual o total gasto em restaurante nos últimos 30 dias?",
        "Mostre meus gastos com lazer"
    ]
    phrase = random.choice(phrases)
    return {
        "text": phrase,
        "intent": "query",
        "amount": None,
        "category": "expense_other",
        "payment_method": "unknown",
        "date_offset_days": 0,
        "description": "consulta financeira"
    }

def main():
    dataset_dir = Path("data/dataset")
    dataset_dir.mkdir(parents=True, exist_ok=True)

    total_samples = 4000
    samples = []

    for _ in range(total_samples):
        r = random.random()
        if r < 0.55:
            samples.append(generate_expense())
        elif r < 0.80:
            samples.append(generate_income())
        elif r < 0.92:
            samples.append(generate_transfer())
        else:
            samples.append(generate_query())

    random.shuffle(samples)

    train_idx = int(0.8 * len(samples))
    val_idx = int(0.9 * len(samples))

    train_set = samples[:train_idx]
    val_set = samples[train_idx:val_idx]
    test_set = samples[val_idx:]

    for name, data_set in [("train", train_set), ("val", val_set), ("test", test_set)]:
        out_file = dataset_dir / f"{name}.jsonl"
        with open(out_file, "w", encoding="utf-8") as f:
            for item in data_set:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")
        print(f"Generated {len(data_set)} samples in {out_file}")

if __name__ == "__main__":
    main()
