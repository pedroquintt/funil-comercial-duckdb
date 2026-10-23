"""Gera o dataset fictício do case (leads, agendamentos, vendas).

Uso:
    python3 gerador/gerar_dados.py

Escreve dados/leads.csv, dados/agendamentos.csv e dados/vendas.csv.
Tudo é sintético (semente fixa), mas com os mesmos tipos de defeito que
aparecem num export real de CRM: linhas duplicadas, nulos, órfãos e
inconsistências lógicas entre as três tabelas. A lista de defeitos
plantados fica em DEFEITOS, para os testes conferirem que o tratamento
encontrou cada um.
"""
from __future__ import annotations

import csv
import random
from datetime import datetime, timedelta
from pathlib import Path

SEED = 42
RAIZ = Path(__file__).resolve().parent.parent
DADOS = RAIZ / "dados"

TIMES = ["atlas", "orion"]
SDRS = {"atlas": ["bruna_reis", "caio_moura"], "orion": ["diego_prado", "elisa_torres"]}
CLOSERS = {"atlas": ["fabio_nunes", "giovana_lima"], "orion": ["heitor_dias", "isabela_rocha"]}
ORIGENS = ["google", "meta", "indicacao", "organico"]
PESO_ORIGEM = [0.38, 0.40, 0.10, 0.12]
MOTIVOS = ["sem_resposta", "remarcou", "desistiu", "conflito_agenda"]

# Padrões de negócio plantados (o que a análise deve encontrar):
# - meta traz volume, mas o lead agenda e some (no-show alto);
# - o time orion confirma menos a reunião: mais "remarcou" no no-show;
# - um closer do atlas fecha bem abaixo dos colegas.
TAXA_AGENDA = {"google": 0.58, "meta": 0.47, "indicacao": 0.72, "organico": 0.55}
TAXA_SHOW = {"google": 0.74, "meta": 0.52, "indicacao": 0.86, "organico": 0.70}
AJUSTE_SHOW_TIME = {"atlas": 0.06, "orion": -0.08}
TAXA_FECHA = {"fabio_nunes": 0.44, "giovana_lima": 0.24, "heitor_dias": 0.42, "isabela_rocha": 0.40}

N_LEADS = 400
DEFEITOS = {
    "leads_duplicados": 6,
    "agendamentos_duplicados": 2,
    "vendas_duplicadas": 3,
    "leads_sem_data": 4,
    "leads_sem_sdr": 3,
    "agendamento_orfao": 1,
    "venda_orfa": 1,
    "venda_sem_agendamento": 1,
    "venda_lead_nao_compareceu": 1,
    "lead_convertido_sem_venda": 1,
    "venda_lead_perdido": 1,
    "venda_time_divergente": 1,
    "venda_closer_divergente": 1,
    "agendamento_sdr_divergente": 1,
}


def _ts(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def gerar() -> dict[str, list[dict]]:
    rnd = random.Random(SEED)
    inicio = datetime(2025, 3, 3, 8, 0)

    leads, agends, vendas = [], [], []
    for i in range(1, N_LEADS + 1):
        time = rnd.choice(TIMES)
        origem = rnd.choices(ORIGENS, PESO_ORIGEM)[0]
        criado = inicio + timedelta(days=rnd.randint(0, 89), minutes=rnd.randint(0, 600))
        lead = {
            "id_lead": f"L{i:03d}",
            "created_at": _ts(criado),
            "origem": origem,
            "time_comercial": time,
            "sdr": rnd.choice(SDRS[time]),
            "status": "perdido",
        }
        leads.append(lead)

        if rnd.random() >= TAXA_AGENDA[origem]:
            continue
        data_agend = criado + timedelta(days=rnd.randint(1, 9), hours=rnd.randint(0, 6))
        compareceu = rnd.random() < TAXA_SHOW[origem] + AJUSTE_SHOW_TIME[time]
        closer = rnd.choice(CLOSERS[time]) if compareceu else None
        if compareceu:
            motivo = None
        elif time == "orion":
            motivo = rnd.choices(MOTIVOS, [0.30, 0.45, 0.15, 0.10])[0]
        else:
            motivo = rnd.choices(MOTIVOS, [0.45, 0.20, 0.20, 0.15])[0]
        agends.append({
            "id_agend": f"A{len(agends) + 1:03d}",
            "id_lead": lead["id_lead"],
            "data_agend": _ts(data_agend),
            "compareceu": compareceu,
            "sdr": lead["sdr"],
            "closer": closer,
            "motivo_nao_compareceu": motivo,
        })
        lead["status"] = "agendado"

        if compareceu and rnd.random() < TAXA_FECHA[closer]:
            data_venda = data_agend + timedelta(days=rnd.randint(0, 12), hours=rnd.randint(0, 5))
            vendas.append({
                "id_venda": f"V{len(vendas) + 1:03d}",
                "id_lead": lead["id_lead"],
                "data_venda": _ts(data_venda),
                "valor": rnd.choice([3990, 4990, 5990, 6990, 7990]) + rnd.choice([0, 0, 500, -500]),
                "closer": closer,
                "time_comercial": time,
            })
            lead["status"] = "convertido"

    for lead in leads:
        if lead["status"] == "agendado":
            lead["status"] = "perdido"

    _plantar_defeitos(rnd, leads, agends, vendas)
    return {"leads": leads, "agendamentos": agends, "vendas": vendas}


def _plantar_defeitos(rnd: random.Random, leads: list, agends: list, vendas: list) -> None:
    """Injeta cada defeito de DEFEITOS uma vez, em registros distintos."""
    usados: set[str] = set()

    def lead_livre(cond) -> dict:
        candidatos = [l for l in leads if cond(l) and l["id_lead"] not in usados]
        escolhido = rnd.choice(candidatos)
        usados.add(escolhido["id_lead"])
        return escolhido

    por_lead_agend = {a["id_lead"]: a for a in agends}
    por_lead_venda = {v["id_lead"]: v for v in vendas}
    sem_venda_com_show = lambda l: (a := por_lead_agend.get(l["id_lead"])) and a["compareceu"] and l["id_lead"] not in por_lead_venda
    com_venda = lambda l: l["id_lead"] in por_lead_venda
    sem_agenda = lambda l: l["id_lead"] not in por_lead_agend

    for _ in range(DEFEITOS["leads_sem_data"]):
        lead_livre(lambda l: True)["created_at"] = None
    for _ in range(DEFEITOS["leads_sem_sdr"]):
        lead_livre(sem_agenda)["sdr"] = None

    lead_livre(sem_venda_com_show)["status"] = "convertido"

    venda = por_lead_venda[lead_livre(com_venda)["id_lead"]]
    next(l for l in leads if l["id_lead"] == venda["id_lead"])["status"] = "perdido"

    venda = por_lead_venda[lead_livre(com_venda)["id_lead"]]
    venda["time_comercial"] = "orion" if venda["time_comercial"] == "atlas" else "atlas"

    venda = por_lead_venda[lead_livre(com_venda)["id_lead"]]
    outros = [c for t in CLOSERS.values() for c in t if c != venda["closer"]]
    venda["closer"] = rnd.choice(outros)

    agend = por_lead_agend[lead_livre(lambda l: l["id_lead"] in por_lead_agend and l["sdr"])["id_lead"]]
    time = next(l["time_comercial"] for l in leads if l["id_lead"] == agend["id_lead"])
    agend["sdr"] = next(s for s in SDRS[time] if s != agend["sdr"])

    # Venda de lead que nunca agendou.
    lead = lead_livre(sem_agenda)
    vendas.append({
        "id_venda": f"V{len(vendas) + 1:03d}", "id_lead": lead["id_lead"],
        "data_venda": lead["created_at"] or "2025-04-10 10:00:00", "valor": 4990,
        "closer": rnd.choice(CLOSERS[lead["time_comercial"]]), "time_comercial": lead["time_comercial"],
    })
    lead["status"] = "convertido"

    # Venda de lead que não compareceu.
    agend = por_lead_agend[lead_livre(lambda l: (a := por_lead_agend.get(l["id_lead"])) and not a["compareceu"])["id_lead"]]
    lead = next(l for l in leads if l["id_lead"] == agend["id_lead"])
    vendas.append({
        "id_venda": f"V{len(vendas) + 1:03d}", "id_lead": lead["id_lead"],
        "data_venda": agend["data_agend"], "valor": 5990,
        "closer": rnd.choice(CLOSERS[lead["time_comercial"]]), "time_comercial": lead["time_comercial"],
    })
    lead["status"] = "convertido"

    # Órfãos: id_lead que não existe em leads.
    agends.append({
        "id_agend": f"A{len(agends) + 1:03d}", "id_lead": "L999", "data_agend": "2025-05-02 14:00:00",
        "compareceu": False, "sdr": "caio_moura", "closer": None, "motivo_nao_compareceu": "sem_resposta",
    })
    vendas.append({
        "id_venda": f"V{len(vendas) + 1:03d}", "id_lead": "L998", "data_venda": "2025-05-20 16:30:00",
        "valor": 6990, "closer": "heitor_dias", "time_comercial": "orion",
    })

    # Duplicatas de linha inteira (artefato de export), embaralhadas no arquivo.
    for tabela, n in ((leads, DEFEITOS["leads_duplicados"]),
                      (agends, DEFEITOS["agendamentos_duplicados"]),
                      (vendas, DEFEITOS["vendas_duplicadas"])):
        tabela.extend(dict(r) for r in rnd.sample(tabela, n))
        rnd.shuffle(tabela)


def salvar(tabelas: dict[str, list[dict]]) -> None:
    DADOS.mkdir(exist_ok=True)
    for nome, linhas in tabelas.items():
        with open(DADOS / f"{nome}.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(linhas[0].keys()))
            w.writeheader()
            for linha in linhas:
                w.writerow({k: ("" if v is None else v) for k, v in linha.items()})


if __name__ == "__main__":
    t = gerar()
    salvar(t)
    print({k: len(v) for k, v in t.items()})
