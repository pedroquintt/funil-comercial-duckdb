-- ============================================================
-- Objetivo: carregar os 3 arquivos exportados do CRM (csv, sem
-- qualquer transformação de conteúdo) em tabelas RAW no DuckDB.
-- Sem deduplicação, correção ou tratamento aqui. Tratamento
-- deixei isolado em 01_tratamento.sql para manter rastreabilidade.
-- A conferência de contagens sai no SELECT final.
-- ============================================================

DROP TABLE IF EXISTS raw_leads;
DROP TABLE IF EXISTS raw_agendamentos;
DROP TABLE IF EXISTS raw_vendas;

CREATE TABLE raw_leads AS
SELECT * FROM read_csv_auto('dados/leads.csv', header=True);

CREATE TABLE raw_agendamentos AS
SELECT * FROM read_csv_auto('dados/agendamentos.csv', header=True);

CREATE TABLE raw_vendas AS
SELECT * FROM read_csv_auto('dados/vendas.csv', header=True);

SELECT 'raw_leads' AS tabela, COUNT(*) AS linhas FROM raw_leads
UNION ALL
SELECT 'raw_agendamentos', COUNT(*) FROM raw_agendamentos
UNION ALL
SELECT 'raw_vendas', COUNT(*) FROM raw_vendas;
