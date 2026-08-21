import json
import random
import os
from pathlib import Path

random.seed(42)

CATEGORIES = [
    "supermarket", "transport", "health", "leisure",
    "housing", "education", "salary", "investment",
    "income_other", "expense_other", "unknown"
]

PAYMENT_METHODS = ["pix", "credit_card", "debit_card", "cash", "bank_slip", "unknown"]

NAMES = [
    "Joao", "Maria", "Lucas", "Ana", "Pedro", "Carla", "Matheus", "Beatriz",
    "Gabriel", "Julia", "Thiago", "Fernanda", "Rodrigo", "Camila", "Felipe", "Larissa"
]

DESCRIPTIONS = {
    "supermarket": [
        "compras do mês", "feira no hortifruti", "itens de limpeza", "arroz feijão e carne",
        "pão leite e café", "supermercado atacadão", "hortifruti da esquina", "compras no carrefour",
        "verduras e legumes", "mercado de bairro"
    ],
    "transport": [
        "uber pro trabalho", "gasolina no posto shell", "estacionamento rotativo",
        "recarga do bilhete único", "pedágio da rodovia", "táxi pro aeroporto",
        "manutenção da moto", "troca de óleo do carro", "passagem de ônibus"
    ],
    "health": [
        "remédios na farmácia", "consulta com cardiologista", "exames de sangue no laboratório",
        "dentista limpeza", "vitamina C e dipirona", "mensalidade do plano de saúde",
        "sessão de fisioterapia", "óculos de grau na ótica"
    ],
    "leisure": [
        "lanche no iFood", "cinema no shopping", "cerveja no bar com os amigos",
        "ingressos do show", "jogos na Steam", "jantar no restaurante japonês",
        "pizza no domingo", "assinatura da Netflix", "viagem na praia"
    ],
    "housing": [
        "conta de luz da Enel", "conta de água da Sabesp", "fatura da internet fibra",
        "aluguel do apartamento", "taxa de condomínio", "gás de cozinha",
        "reforma da torneira", "compra de lâmpadas LED"
    ],
    "education": [
        "mensalidade da faculdade", "curso de inglês online", "livro de arquitetura de software",
        "inscrição no bootcamp", "material escolar", "curso de Flutter na Udemy"
    ],
    "expense_other": [
        "presente de aniversário", "conserto da tela do celular", "corte de cabelo no salão",
        "roupa nova na loja", "ração do cachorro no petshop", "presente de casamento"
    ]
}

OOD_SENTENCES = [
    "Que horas são agora?", "Como está o tempo em São Paulo hoje?", "Qual é a capital da França?",
    "Me conte uma piada engraçada", "Quem ganhou o jogo de futebol ontem?", "Como fazer bolo de chocolate?",
    "Qual é a velocidade da luz?", "Abra o aplicativo de música", "Qual o sentido da vida?",
    "Me ajuda com o dever de casa de história", "Onde fica o banheiro mais próximo?",
    "Qual é a previsão do tempo para amanhã?", "Tire uma foto", "Ligue para a minha mãe",
    "Quem descobriu o Brasil?", "Tocar música de rock", "Quantos dias tem um ano bissexto?",
    "Qual a fórmula da água?", "Traduzir obrigado para inglês", "Como vai você?"
]

DATES_PT = [
    ("hoje", 0), ("ontem", -1), ("anteontem", -2), ("essa manhã", 0),
    ("nesta tarde", 0), ("semana passada", -7), ("no fim de semana", -3), ("", 0)
]

METHOD_PHRASES = {
    "pix": ["no pix", "via pix", "pelo pix", "transferência pix"],
    "credit_card": ["no cartão de crédito", "no crédito", "no cartão", "parcelado no crédito em 3x"],
    "debit_card": ["no débito", "no cartão de débito", "passou no débito"],
    "cash": ["em dinheiro", "em espécie", "no dinheiro vivo", "nas notas"],
    "bank_slip": ["no boleto", "via boleto bancário", "paguei o boleto"]
}

def generate_amount():
    val = round(random.uniform(5.0, 3500.0), 2)
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
    method_key = random.choice(PAYMENT_METHODS[:5])
    method_str = random.choice(METHOD_PHRASES[method_key])
    date_str, date_offset = random.choice(DATES_PT)

    verbs = ["Gastei", "Comprei", "Paguei", "Passei", "Lançar gasto de", "Tive uma despesa de"]
    verb = random.choice(verbs)

    templates = [
        f"{verb} {amount_str} com {desc} {method_str} {date_str}".strip(),
        f"{verb} {desc} por {amount_str} {method_str}".strip(),
        f"{desc} deu {amount_str} {date_str} {method_str}".strip(),
        f"{verb} {amount_str} no {desc}".strip(),
        f"Gasto de {amount_str} em {desc} {date_str}".strip()
    ]

    phrase = " ".join(random.choice(templates).split())

    return {
        "text": phrase,
        "intent": "expense",
        "amount": amount,
        "category": cat,
        "payment_method": method_key,
        "date_offset_days": date_offset,
        "description": desc
    }

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
            f"Recebi {amount_str} de dividendos das ações",
            f"Resgatei {amount_str} da caixinha de investimentos",
            f"Lucro de {amount_str} no tesouro direto"
        ]
    else:
        desc = f"transferência recebida de {name}"
        phrases = [
            f"Recebi {amount_str} no pix do {name} {date_str}",
            f"Entrou {amount_str} de reembolso {date_str}",
            f"Recebi {amount_str} por um freela de desenvolvimento {date_str}",
            f"Pix recebido de {amount_str} da {name}"
        ]

    phrase = " ".join(random.choice(phrases).split())

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

    phrase = " ".join(random.choice(phrases).split())

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
        "Mostre meus gastos com lazer",
        "Resumo de despesas da semana passada"
    ]
    phrase = random.choice(phrases)
    return {
        "text": phrase,
        "intent": "query",
        "amount": None,
        "category": "unknown",
        "payment_method": "unknown",
        "date_offset_days": 0,
        "description": "consulta financeira"
    }

def generate_ood():
    phrase = random.choice(OOD_SENTENCES)
    return {
        "text": phrase,
        "intent": "unknown",
        "amount": None,
        "category": "unknown",
        "payment_method": "unknown",
        "date_offset_days": 0,
        "description": "fora do domínio"
    }

def main():
    dataset_dir = Path("data/dataset_10k")
    dataset_dir.mkdir(parents=True, exist_ok=True)

    total_samples = 10000
    samples = []

    for _ in range(total_samples):
        r = random.random()
        if r < 0.50:
            samples.append(generate_expense())
        elif r < 0.72:
            samples.append(generate_income())
        elif r < 0.85:
            samples.append(generate_transfer())
        elif r < 0.93:
            samples.append(generate_query())
        else:
            samples.append(generate_ood())

    random.shuffle(samples)

    # Export dataset splits
    splits = {
        "90_10": (int(0.9 * len(samples)), "train_90.jsonl", "test_10.jsonl"),
        "80_20": (int(0.8 * len(samples)), "train_80.jsonl", "test_20.jsonl"),
        "70_15_15": (int(0.7 * len(samples)), int(0.85 * len(samples)), "train_70.jsonl", "val_15.jsonl", "test_15.jsonl")
    }

    # Save master dataset file
    master_file = dataset_dir / "dataset_10k_master.jsonl"
    with open(master_file, "w", encoding="utf-8") as f:
        for s in samples:
            f.write(json.dumps(s, ensure_ascii=False) + "\n")
    print(f"SUCCESS: Generated {len(samples)} samples in master file {master_file}")

if __name__ == "__main__":
    main()
