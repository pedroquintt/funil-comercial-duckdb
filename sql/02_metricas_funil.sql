-- ============================================================
-- 02_metricas_funil.sql
-- Objetivo: calcular as métricas do funil (captação -> agendamento
-- -> comparecimento -> venda) em nível geral e por time comercial
-- (times atlas e orion), a partir das tabelas STG (já tratadas).
--
-- Convenção de denominador usada em TODAS as taxas abaixo:
-- registros em quarentena (flag_orfao) são excluídos do numerador
-- e do denominador, porque não é possível atribuí-los a um time/lead
-- real -- entram na quarentena para auditoria, não nas métricas de
-- negócio. São poucos registros (1 agendamento e 1 venda órfãos),
-- volume irrelevante perto da base.
-- ============================================================

DROP TABLE IF EXISTS metricas_geral;
DROP TABLE IF EXISTS metricas_por_time;
DROP TABLE IF EXISTS metricas_por_origem;
DROP TABLE IF EXISTS tempos_medios;

-- ------------------------------------------------------------
-- CTEs base: cada uma já filtra os órfãos e resolve o vínculo
-- lead -> agendamento (primeiro agendamento, fonte da verdade
-- para closer) -> venda.
-- ------------------------------------------------------------
CREATE TEMP VIEW v_agend_validos AS
SELECT a.*, l.time_comercial, l.origem
FROM stg_agendamentos a
JOIN stg_leads l ON l.id_lead = a.id_lead
WHERE NOT a.flag_orfao;

CREATE TEMP VIEW v_vendas_validas AS
SELECT v.*, l.origem, l.created_at AS lead_created_at, ag.data_agend AS primeiro_agend_data
FROM stg_vendas v
JOIN stg_leads l ON l.id_lead = v.id_lead
LEFT JOIN stg_agendamentos ag ON ag.id_lead = v.id_lead AND ag.primeiro_agendamento = TRUE
WHERE NOT v.flag_orfao;

-- ------------------------------------------------------------
-- MÉTRICAS GERAIS (toda a base, sem quebra por time)
-- - vol_leads: todos os leads tratados (denominador de referência)
-- - vol_agendamentos: leads com pelo menos 1 agendamento válido
-- - vol_comparecimentos: desses, quantos compareceram (compareceu=True)
-- - vol_vendas: vendas válidas (não órfãs)
-- - taxa_agendamento = vol_agendamentos / vol_leads
-- - taxa_comparecimento = vol_comparecimentos / vol_agendamentos
-- - taxa_conversao_venda = vol_vendas / vol_comparecimentos
-- - conversao_ponta_a_ponta = vol_vendas / vol_leads
-- ------------------------------------------------------------
CREATE TABLE metricas_geral AS
WITH base AS (
    SELECT
        (SELECT COUNT(*) FROM stg_leads)                                    AS vol_leads,
        (SELECT COUNT(*) FROM v_agend_validos)                              AS vol_agendamentos,
        (SELECT COUNT(*) FROM v_agend_validos WHERE compareceu)             AS vol_comparecimentos,
        (SELECT COUNT(*) FROM v_vendas_validas)                             AS vol_vendas,
        (SELECT SUM(valor) FROM v_vendas_validas)                           AS receita_total
)
SELECT
    vol_leads,
    vol_agendamentos,
    vol_comparecimentos,
    vol_vendas,
    ROUND(vol_agendamentos::DOUBLE / vol_leads, 4)          AS taxa_agendamento,
    ROUND(vol_comparecimentos::DOUBLE / vol_agendamentos, 4) AS taxa_comparecimento,
    ROUND(vol_vendas::DOUBLE / vol_comparecimentos, 4)       AS taxa_conversao_venda,
    ROUND(vol_vendas::DOUBLE / vol_leads, 4)                 AS conversao_ponta_a_ponta,
    receita_total,
    ROUND(receita_total / vol_vendas, 2)                     AS ticket_medio
FROM base;

-- ------------------------------------------------------------
-- MÉTRICAS POR TIME COMERCIAL (times atlas e orion)
-- Mesmas fórmulas de metricas_geral, quebradas por time_comercial.
-- time_comercial sempre vem de LEADS (fonte da verdade definida na
-- Etapa 1), inclusive para as vendas (time_comercial_final).
-- ------------------------------------------------------------
CREATE TABLE metricas_por_time AS
WITH leads_t AS (
    SELECT time_comercial, COUNT(*) AS vol_leads
    FROM stg_leads GROUP BY time_comercial
),
agend_t AS (
    SELECT time_comercial, COUNT(*) AS vol_agendamentos,
           COUNT(*) FILTER (WHERE compareceu) AS vol_comparecimentos
    FROM v_agend_validos GROUP BY time_comercial
),
vendas_t AS (
    SELECT time_comercial_final AS time_comercial,
           COUNT(*) AS vol_vendas,
           SUM(valor) AS receita_total
    FROM v_vendas_validas GROUP BY time_comercial_final
)
SELECT
    l.time_comercial,
    l.vol_leads,
    a.vol_agendamentos,
    a.vol_comparecimentos,
    v.vol_vendas,
    ROUND(a.vol_agendamentos::DOUBLE / l.vol_leads, 4)           AS taxa_agendamento,
    ROUND(a.vol_comparecimentos::DOUBLE / a.vol_agendamentos, 4) AS taxa_comparecimento,
    ROUND(v.vol_vendas::DOUBLE / a.vol_comparecimentos, 4)       AS taxa_conversao_venda,
    ROUND(v.vol_vendas::DOUBLE / l.vol_leads, 4)                 AS conversao_ponta_a_ponta,
    v.receita_total,
    ROUND(v.receita_total / v.vol_vendas, 2)                     AS ticket_medio
FROM leads_t l
JOIN agend_t a USING (time_comercial)
JOIN vendas_t v USING (time_comercial)
ORDER BY l.time_comercial;

-- ------------------------------------------------------------
-- MÉTRICAS POR ORIGEM (google, meta, indicacao, organico)
-- origem é atributo do LEAD; propagamos via join para agendamentos
-- e vendas. Mesma lógica de taxas do bloco geral.
-- ------------------------------------------------------------
CREATE TABLE metricas_por_origem AS
WITH leads_o AS (
    SELECT origem, COUNT(*) AS vol_leads
    FROM stg_leads GROUP BY origem
),
agend_o AS (
    SELECT origem, COUNT(*) AS vol_agendamentos,
           COUNT(*) FILTER (WHERE compareceu) AS vol_comparecimentos
    FROM v_agend_validos GROUP BY origem
),
vendas_o AS (
    SELECT origem, COUNT(*) AS vol_vendas, SUM(valor) AS receita_total
    FROM v_vendas_validas GROUP BY origem
)
SELECT
    l.origem,
    l.vol_leads,
    COALESCE(a.vol_agendamentos, 0) AS vol_agendamentos,
    COALESCE(a.vol_comparecimentos, 0) AS vol_comparecimentos,
    COALESCE(v.vol_vendas, 0) AS vol_vendas,
    ROUND(COALESCE(a.vol_agendamentos, 0)::DOUBLE / l.vol_leads, 4) AS taxa_agendamento,
    ROUND(COALESCE(a.vol_comparecimentos,0)::DOUBLE / NULLIF(a.vol_agendamentos,0), 4) AS taxa_comparecimento,
    ROUND(COALESCE(v.vol_vendas,0)::DOUBLE / NULLIF(a.vol_comparecimentos,0), 4) AS taxa_conversao_venda,
    ROUND(COALESCE(v.vol_vendas,0)::DOUBLE / l.vol_leads, 4) AS conversao_ponta_a_ponta,
    COALESCE(v.receita_total, 0) AS receita_total
FROM leads_o l
LEFT JOIN agend_o a USING (origem)
LEFT JOIN vendas_o v USING (origem)
ORDER BY l.vol_leads DESC;

-- ------------------------------------------------------------
-- TEMPOS MÉDIOS (em dias) por etapa, geral e por time
-- - captação -> agendamento: só para leads com created_at preenchido
--   (flag_sem_data_criacao = FALSE) e com agendamento válido
-- - agendamento -> venda: primeiro agendamento do lead até a venda
-- ------------------------------------------------------------
CREATE TABLE tempos_medios AS
SELECT
    'geral' AS time_comercial,
    ROUND(AVG(DATE_DIFF('day', l.created_at, a.data_agend)) FILTER (
        WHERE NOT l.flag_sem_data_criacao
    ), 2) AS dias_medios_captacao_agendamento,
    (SELECT ROUND(AVG(DATE_DIFF('day', primeiro_agend_data, data_venda)), 2) FROM v_vendas_validas) AS dias_medios_agendamento_venda
FROM v_agend_validos a
JOIN stg_leads l ON l.id_lead = a.id_lead
UNION ALL
SELECT
    a.time_comercial,
    ROUND(AVG(DATE_DIFF('day', l.created_at, a.data_agend)) FILTER (
        WHERE NOT l.flag_sem_data_criacao
    ), 2),
    (SELECT ROUND(AVG(DATE_DIFF('day', primeiro_agend_data, data_venda)), 2)
     FROM v_vendas_validas vv WHERE vv.time_comercial_final = a.time_comercial)
FROM v_agend_validos a
JOIN stg_leads l ON l.id_lead = a.id_lead
GROUP BY a.time_comercial;

-- Saída de conferência
SELECT * FROM metricas_geral;
SELECT * FROM metricas_por_time;
SELECT * FROM metricas_por_origem;
SELECT * FROM tempos_medios;
