-- ============================================================
-- 03_gargalos.sql
-- Objetivo: descer do funil geral (etapa 2) para o nível de SDR,
-- Closer e origem, para responder "ONDE exatamente" o funil perde
-- mais gente -- e não só "quanto" ele perde.
-- Reaproveita as views v_agend_validos / v_vendas_validas criadas
-- em 02_metricas_funil.sql (já excluem os registros órfãos).
-- ============================================================

DROP TABLE IF EXISTS gargalo_sdr;
DROP TABLE IF EXISTS gargalo_closer;
DROP TABLE IF EXISTS gargalo_origem_comparecimento;
DROP TABLE IF EXISTS gargalo_motivos_nao_comparecimento;
DROP TABLE IF EXISTS gargalo_perda_por_etapa;

-- ------------------------------------------------------------
-- FUNIL POR SDR
-- O SDR "dono" do lead é o de stg_leads.sdr (fonte da verdade da
-- etapa 1; nos leads sem SDR informado, o bucket 'nao_informado'
-- entra como um grupo à parte, para não sumir do total nem
-- contaminar o ranking dos SDRs reais).
-- - leads_recebidos: quantos leads o SDR recebeu
-- - taxa_agendamento: dos leads recebidos, quantos ele agendou
-- - taxa_comparecimento_dos_agendados: dos QUE ELE agendou, quantos
--   efetivamente compareceram (mede qualidade do agendamento feito
--   pelo SDR, não just volume)
-- ------------------------------------------------------------
CREATE TABLE gargalo_sdr AS
WITH leads_sdr AS (
    SELECT sdr, COUNT(*) AS leads_recebidos
    FROM stg_leads GROUP BY sdr
),
agend_sdr AS (
    SELECT l.sdr,
           COUNT(*) AS vol_agendados,
           COUNT(*) FILTER (WHERE a.compareceu) AS vol_comparecimentos
    FROM v_agend_validos a
    JOIN stg_leads l ON l.id_lead = a.id_lead
    GROUP BY l.sdr
)
SELECT
    l.sdr,
    l.leads_recebidos,
    COALESCE(a.vol_agendados, 0) AS vol_agendados,
    COALESCE(a.vol_comparecimentos, 0) AS vol_comparecimentos,
    ROUND(COALESCE(a.vol_agendados,0)::DOUBLE / l.leads_recebidos, 4) AS taxa_agendamento,
    ROUND(COALESCE(a.vol_comparecimentos,0)::DOUBLE / NULLIF(a.vol_agendados,0), 4) AS taxa_comparecimento_dos_agendados
FROM leads_sdr l
LEFT JOIN agend_sdr a ON a.sdr = l.sdr
ORDER BY l.leads_recebidos DESC;

-- ------------------------------------------------------------
-- FUNIL POR CLOSER
-- closer é sempre o de AGENDAMENTOS (fonte da verdade da etapa 1).
-- reunioes_recebidas = agendamentos com aquele closer (por
-- construção, todo agendamento com closer preenchido teve
-- compareceu=True -- validado na etapa 1: closer nulo <=> não
-- compareceu). taxa_fechamento = vendas fechadas / reuniões
-- recebidas por aquele closer.
-- ------------------------------------------------------------
CREATE TABLE gargalo_closer AS
WITH reunioes_closer AS (
    SELECT closer, COUNT(*) AS reunioes_recebidas
    FROM v_agend_validos
    WHERE closer IS NOT NULL
    GROUP BY closer
),
vendas_closer AS (
    SELECT closer_final AS closer, COUNT(*) AS vol_vendas,
           SUM(valor) AS receita_total, ROUND(AVG(valor), 2) AS ticket_medio
    FROM v_vendas_validas
    GROUP BY closer_final
)
SELECT
    r.closer,
    r.reunioes_recebidas,
    COALESCE(v.vol_vendas, 0) AS vol_vendas,
    ROUND(COALESCE(v.vol_vendas,0)::DOUBLE / r.reunioes_recebidas, 4) AS taxa_fechamento,
    COALESCE(v.receita_total, 0) AS receita_total,
    v.ticket_medio
FROM reunioes_closer r
LEFT JOIN vendas_closer v ON v.closer = r.closer
ORDER BY r.reunioes_recebidas DESC;

-- ------------------------------------------------------------
-- CRUZAMENTO ORIGEM x COMPARECIMENTO
-- Pergunta de negócio: qual canal traz lead que agenda mas depois
-- some (não aparece na reunião)? Olhamos a taxa de NÃO
-- comparecimento sobre quem foi agendado (não sobre o total de
-- leads), para isolar o problema especificamente na etapa de
-- comparecimento.
-- ------------------------------------------------------------
CREATE TABLE gargalo_origem_comparecimento AS
SELECT
    origem,
    COUNT(*) AS vol_agendados,
    COUNT(*) FILTER (WHERE compareceu) AS vol_compareceram,
    COUNT(*) FILTER (WHERE NOT compareceu) AS vol_nao_compareceram,
    ROUND(COUNT(*) FILTER (WHERE NOT compareceu)::DOUBLE / COUNT(*), 4) AS taxa_nao_comparecimento
FROM v_agend_validos
GROUP BY origem
ORDER BY taxa_nao_comparecimento DESC;

-- ------------------------------------------------------------
-- MOTIVOS DE NÃO COMPARECIMENTO por SDR e por time
-- motivo só existe quando compareceu=False (validado na etapa 1).
-- Ajuda a diferenciar causa operacional (remarcou = o SDR agenda
-- mal / sem confirmar) de causa de qualificação (sem_resposta =
-- lead frio, problema pode estar lá atrás, na origem/qualificação).
-- ------------------------------------------------------------
CREATE TABLE gargalo_motivos_nao_comparecimento AS
SELECT
    l.time_comercial,
    a.sdr,
    a.motivo_nao_compareceu,
    COUNT(*) AS ocorrencias
FROM v_agend_validos a
JOIN stg_leads l ON l.id_lead = a.id_lead
WHERE NOT a.compareceu
GROUP BY ALL
ORDER BY l.time_comercial, a.sdr, ocorrencias DESC;

-- ------------------------------------------------------------
-- MAIOR PERDA ABSOLUTA ENTRE ETAPAS (em quantidade de leads, não %)
-- Compara a perda absoluta geral e por time em cada transição do
-- funil, para responder objetivamente "onde perdemos mais gente".
-- ------------------------------------------------------------
CREATE TABLE gargalo_perda_por_etapa AS
SELECT
    time_comercial,
    vol_leads,
    vol_agendamentos,
    vol_comparecimentos,
    vol_vendas,
    (vol_leads - vol_agendamentos)               AS perda_captacao_agendamento,
    (vol_agendamentos - vol_comparecimentos)      AS perda_agendamento_comparecimento,
    (vol_comparecimentos - vol_vendas)            AS perda_comparecimento_venda
FROM metricas_por_time
UNION ALL
SELECT
    'geral',
    vol_leads, vol_agendamentos, vol_comparecimentos, vol_vendas,
    (vol_leads - vol_agendamentos),
    (vol_agendamentos - vol_comparecimentos),
    (vol_comparecimentos - vol_vendas)
FROM metricas_geral;

-- Saída de conferência
SELECT * FROM gargalo_sdr;
SELECT * FROM gargalo_closer;
SELECT * FROM gargalo_origem_comparecimento;
SELECT * FROM gargalo_motivos_nao_comparecimento;
SELECT * FROM gargalo_perda_por_etapa;
