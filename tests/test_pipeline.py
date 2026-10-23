"""Testes da pipeline: o tratamento encontra cada defeito plantado e as
métricas fecham entre si."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ))
sys.path.insert(0, str(RAIZ / "gerador"))
import gerar_dados  # noqa: E402
import rodar  # noqa: E402


@pytest.fixture(scope="module")
def con(tmp_path_factory):
    conexao = rodar.executar(tmp_path_factory.mktemp("db") / "teste.duckdb")
    yield conexao
    conexao.close()


def um(con, sql):
    return con.execute(sql).fetchone()[0]


D = gerar_dados.DEFEITOS


@pytest.mark.parametrize("tabela,defeito", [
    ("leads", "leads_duplicados"),
    ("agendamentos", "agendamentos_duplicados"),
    ("vendas", "vendas_duplicadas"),
])
def test_dedup_remove_exatamente_as_duplicatas(con, tabela, defeito):
    raw = um(con, f"SELECT COUNT(*) FROM raw_{tabela}")
    stg = um(con, f"SELECT COUNT(*) FROM stg_{tabela}")
    assert raw - stg == D[defeito]


@pytest.mark.parametrize("tabela,chave", [
    ("stg_leads", "id_lead"), ("stg_agendamentos", "id_agend"), ("stg_vendas", "id_venda"),
])
def test_chave_unica_e_nao_nula(con, tabela, chave):
    assert um(con, f"SELECT COUNT(*) FROM {tabela} WHERE {chave} IS NULL") == 0
    assert um(con, f"SELECT COUNT(*) - COUNT(DISTINCT {chave}) FROM {tabela}") == 0


def test_nulos_legitimos_nao_sao_apagados(con):
    assert um(con, "SELECT COUNT(*) FROM stg_leads WHERE flag_sem_data_criacao") == D["leads_sem_data"]
    assert um(con, "SELECT COUNT(*) FROM stg_leads WHERE sdr = 'nao_informado'") == D["leads_sem_sdr"]
    # closer nulo <=> não compareceu
    assert um(con, "SELECT COUNT(*) FROM stg_agendamentos WHERE (closer IS NULL) <> (NOT compareceu)") == 0


@pytest.mark.parametrize("trecho,defeito", [
    ("status=convertido sem venda", "lead_convertido_sem_venda"),
    ("agendamentos|id_lead não existe", "agendamento_orfao"),
    ("vendas|id_lead não existe", "venda_orfa"),
    ("sem nenhum agendamento", "venda_sem_agendamento"),
    ("não compareceu à reunião", "venda_lead_nao_compareceu"),
    ("status=perdido", "venda_lead_perdido"),
    ("time_comercial da venda diverge", "venda_time_divergente"),
    ("closer da venda diverge", "venda_closer_divergente"),
    ("sdr do agendamento diverge", "agendamento_sdr_divergente"),
])
def test_quarentena_pega_cada_defeito_plantado(con, trecho, defeito):
    origem, _, texto = trecho.rpartition("|")
    filtro = f"AND tabela_origem = '{origem}'" if origem else ""
    achados = um(con, f"SELECT COUNT(*) FROM quarentena WHERE motivo LIKE '%{texto}%' {filtro}")
    assert achados == D[defeito]


def test_soma_dos_times_fecha_com_o_geral(con):
    for coluna in ["vol_leads", "vol_agendamentos", "vol_comparecimentos", "vol_vendas"]:
        geral = um(con, f"SELECT {coluna} FROM metricas_geral")
        por_time = um(con, f"SELECT SUM({coluna}) FROM metricas_por_time")
        assert geral == por_time, coluna


def test_taxas_entre_zero_e_um(con):
    df = con.execute("SELECT * FROM metricas_por_time").df()
    taxas = df.filter(like="taxa_").stack()
    assert taxas.between(0, 1).all()


def test_padroes_plantados_aparecem(con):
    pior_origem = um(con, "SELECT origem FROM gargalo_origem_comparecimento ORDER BY taxa_nao_comparecimento DESC LIMIT 1")
    assert pior_origem == "meta"
    pior_closer = um(con, "SELECT closer FROM gargalo_closer ORDER BY taxa_fechamento LIMIT 1")
    assert pior_closer == "giovana_lima"
    show = dict(con.execute("SELECT time_comercial, taxa_comparecimento FROM metricas_por_time").fetchall())
    assert show["atlas"] > show["orion"]
