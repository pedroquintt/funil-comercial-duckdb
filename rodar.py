"""Roda a pipeline inteira: gera os dados, executa o SQL e salva as saídas.

Uso:
    python3 rodar.py             # tudo
    python3 rodar.py --sem-graficos

Etapas:
    1. gerador/gerar_dados.py  -> dados/*.csv
    2. sql/00..03              -> funil.duckdb (raw -> stg -> métricas -> gargalos)
    3. outputs/*.csv e outputs/*.png
"""
from __future__ import annotations

import sys
from pathlib import Path

import duckdb

RAIZ = Path(__file__).resolve().parent
sys.path.insert(0, str(RAIZ / "gerador"))
import gerar_dados  # noqa: E402

SCRIPTS = ["00_carga.sql", "01_tratamento.sql", "02_metricas_funil.sql", "03_gargalos.sql"]
TABELAS_SAIDA = [
    "quarentena", "metricas_geral", "metricas_por_time", "metricas_por_origem", "tempos_medios",
    "gargalo_sdr", "gargalo_closer", "gargalo_origem_comparecimento",
    "gargalo_motivos_nao_comparecimento", "gargalo_perda_por_etapa",
]


def executar(caminho_db: Path = RAIZ / "funil.duckdb") -> duckdb.DuckDBPyConnection:
    gerar_dados.salvar(gerar_dados.gerar())
    caminho_db.unlink(missing_ok=True)
    con = duckdb.connect(str(caminho_db))
    # O SQL lê 'dados/...' com caminho relativo, como no case original.
    con.execute(f"SET file_search_path = '{RAIZ}'")
    for script in SCRIPTS:
        con.execute((RAIZ / "sql" / script).read_text(encoding="utf-8"))
    return con


def exportar(con: duckdb.DuckDBPyConnection) -> None:
    saida = RAIZ / "outputs"
    saida.mkdir(exist_ok=True)
    for tabela in TABELAS_SAIDA:
        con.execute(f"COPY {tabela} TO '{saida / tabela}.csv' (HEADER)")


def graficos(con: duckdb.DuckDBPyConnection) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    saida = RAIZ / "outputs"
    cinza, azul, laranja = "#9aa5b1", "#2f6db5", "#d9822b"
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False})

    # 1) Funil por time, em volume absoluto.
    df = con.execute("SELECT * FROM metricas_por_time ORDER BY time_comercial").df()
    etapas = ["vol_leads", "vol_agendamentos", "vol_comparecimentos", "vol_vendas"]
    rotulos = ["Leads", "Agendados", "Compareceram", "Vendas"]
    fig, ax = plt.subplots(figsize=(7.5, 4))
    largura = 0.38
    for i, (cor, linha) in enumerate(zip([azul, laranja], df.itertuples())):
        valores = [getattr(linha, e) for e in etapas]
        xs = [x + (i - 0.5) * largura for x in range(len(etapas))]
        barras = ax.bar(xs, valores, largura, color=cor, label=linha.time_comercial)
        ax.bar_label(barras, padding=2, fontsize=9)
    ax.set_xticks(range(len(etapas)), rotulos)
    ax.set_title("Funil por time comercial")
    ax.legend(frameon=False)
    fig.tight_layout()
    fig.savefig(saida / "funil_por_time.png", dpi=150)
    plt.close(fig)

    # 2) Não comparecimento por origem: onde o lead agenda e some.
    df = con.execute("SELECT * FROM gargalo_origem_comparecimento ORDER BY taxa_nao_comparecimento").df()
    fig, ax = plt.subplots(figsize=(7.5, 3.2))
    cores = [laranja if o == df.origem.iloc[-1] else cinza for o in df.origem]
    barras = ax.barh(df.origem, df.taxa_nao_comparecimento * 100, color=cores)
    ax.bar_label(barras, labels=[f"{v:.0%} de {n}" for v, n in zip(df.taxa_nao_comparecimento, df.vol_agendados)], padding=3, fontsize=9)
    ax.set_xlabel("% dos agendados que não compareceram")
    ax.set_title("Não comparecimento por origem do lead")
    fig.tight_layout()
    fig.savefig(saida / "no_show_por_origem.png", dpi=150)
    plt.close(fig)

    # 3) Taxa de fechamento por closer.
    df = con.execute("SELECT * FROM gargalo_closer ORDER BY taxa_fechamento").df()
    fig, ax = plt.subplots(figsize=(7.5, 3.2))
    cores = [laranja if v == df.taxa_fechamento.min() else azul for v in df.taxa_fechamento]
    barras = ax.barh(df.closer, df.taxa_fechamento * 100, color=cores)
    ax.bar_label(barras, labels=[f"{v:.0%} ({s}/{r})" for v, s, r in zip(df.taxa_fechamento, df.vol_vendas, df.reunioes_recebidas)], padding=3, fontsize=9)
    ax.set_xlabel("% das reuniões que viraram venda")
    ax.set_title("Taxa de fechamento por closer")
    fig.tight_layout()
    fig.savefig(saida / "fechamento_por_closer.png", dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    conexao = executar()
    exportar(conexao)
    if "--sem-graficos" not in sys.argv:
        graficos(conexao)
    print(conexao.execute("SELECT * FROM metricas_geral").df().to_string(index=False))
    print(conexao.execute("SELECT * FROM metricas_por_time").df().to_string(index=False))
    conexao.close()
