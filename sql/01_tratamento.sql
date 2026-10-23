-- ============================================================
-- 01_tratamento.sql
-- Objetivo: transformar as tabelas RAW (espelho fiel do xlsx) em
-- tabelas STG (staging) confiáveis para cálculo de métricas,
-- SEM apagar nenhum dado problemático silenciosamente.
--
-- Estratégia adotada:
--   1) Deduplicar (linha inteira idêntica = erro de carga/export, não é
--      um segundo evento real)
--   2) Tratar nulos: coalescer os que distorceriam ranking, manter
--      como NULL os que são legítimos (ausência é informação)
--   3) Marcar (flag) cada problema estrutural/lógico em vez de excluir
--   4) Consolidar todo registro flagado numa tabela `quarentena`
--      com o motivo explícito, para auditoria
--   5) Aplicar as fontes da verdade definidas no case:
--        - time_comercial  -> vem de LEADS (time é atribuído na captação)
--        - closer          -> vem de AGENDAMENTOS (fechamento reflete quem
--                              efetivamente conduziu a reunião)
-- As tabelas RAW nunca são alteradas; tudo aqui é lido de raw_* e
-- gravado em stg_*.
-- ============================================================

DROP TABLE IF EXISTS stg_leads;
DROP TABLE IF EXISTS stg_agendamentos;
DROP TABLE IF EXISTS stg_vendas;
DROP TABLE IF EXISTS quarentena;

-- ------------------------------------------------------------
-- 1) DEDUPLICAÇÃO
-- Linhas 100% idênticas (todas as colunas iguais) são artefato de
-- carga/exportação -- não representam um segundo lead/agendamento/
-- venda real. Removidas via SELECT DISTINCT.
-- A diferença raw -> dedup de cada tabela sai na conferência final e é
-- validada nos testes contra o número de duplicatas do gerador.
-- ------------------------------------------------------------
CREATE TEMP TABLE dedup_leads AS
SELECT DISTINCT * FROM raw_leads;

CREATE TEMP TABLE dedup_agendamentos AS
SELECT DISTINCT * FROM raw_agendamentos;

CREATE TEMP TABLE dedup_vendas AS
SELECT DISTINCT * FROM raw_vendas;

-- ------------------------------------------------------------
-- 2) STG_LEADS
-- - sdr nulo -> 'nao_informado': um SDR nulo não deve sumir do
--   denominador nem virar um "buraco" no ranking; melhor um bucket
--   explícito do que distorcer a média dos demais SDRs.
-- - created_at nulo: mantido NULL (não inventamos data). O lead
--   continua contado no volume; ele só é excluído dos cálculos de
--   TEMPO (etapa 2), que é o único cálculo que a ausência de data afeta.
-- - flag_status_inconsistente: lead diz "convertido" mas não existe
--   nenhuma venda vinculada -- inconsistência de PROCESSO (CRM não
--   sincronizado), não removemos o lead, só documentamos.
-- ------------------------------------------------------------
CREATE TABLE stg_leads AS
SELECT
    l.id_lead,
    l.created_at,
    (l.created_at IS NULL)                         AS flag_sem_data_criacao,
    l.origem,
    l.time_comercial,
    COALESCE(l.sdr, 'nao_informado')                AS sdr,
    (l.sdr IS NULL)                                  AS flag_sdr_ausente,
    l.status,
    (
        l.status = 'convertido'
        AND NOT EXISTS (SELECT 1 FROM dedup_vendas v WHERE v.id_lead = l.id_lead)
    )                                                 AS flag_status_inconsistente
FROM dedup_leads l;

-- ------------------------------------------------------------
-- 3) STG_AGENDAMENTOS
-- - closer nulo: LEGÍTIMO quando compareceu=False (lead nunca chegou
--   ao closer) -- não é tratado como erro, não é coalescido.
-- - motivo_nao_compareceu nulo: LEGÍTIMO quando compareceu=True.
-- - flag_orfao: id_lead do agendamento não existe em stg_leads.
--   Não deletamos a linha (mudaria a contagem de agendamentos);
--   ela fica marcada e vai para quarentena para decisão da área de
--   dados/CRM (pode ser erro de digitação de ID, por ex.).
-- - flag_sdr_divergente_lead: o SDR do agendamento é diferente do SDR
--   que originou o lead -- indício de reatribuição não registrada.
-- - primeiro_agendamento: quando um lead tem 2+ agendamentos reais,
--   convencionamos usar o primeiro (por data) para taxas de funil,
--   conforme decisão documentada no case. Quando o único caso aparente
--   de 2+ agendamentos é o próprio registro duplicado, ele some no
--   dedup -- a coluna fica pronta para o caso real aparecer em cargas
--   futuras.
-- ------------------------------------------------------------
CREATE TABLE stg_agendamentos AS
SELECT
    a.id_agend,
    a.id_lead,
    a.data_agend,
    a.compareceu,
    a.sdr,
    a.closer,
    a.motivo_nao_compareceu,
    (NOT EXISTS (SELECT 1 FROM stg_leads l WHERE l.id_lead = a.id_lead)) AS flag_orfao,
    (
        EXISTS (SELECT 1 FROM stg_leads l WHERE l.id_lead = a.id_lead AND l.sdr <> a.sdr)
    )                                                                    AS flag_sdr_divergente_lead,
    (ROW_NUMBER() OVER (PARTITION BY a.id_lead ORDER BY a.data_agend) = 1) AS primeiro_agendamento
FROM dedup_agendamentos a;

-- ------------------------------------------------------------
-- 4) STG_VENDAS
-- Fontes da verdade aplicadas aqui (com o valor original preservado
-- para auditoria, nunca sobrescrito silenciosamente):
--   - time_comercial_final  <- LEADS (lead é atribuído ao time na captação)
--   - closer_final          <- AGENDAMENTOS (primeiro agendamento do lead;
--                               é quem de fato conduziu a reunião)
-- Flags:
--   - flag_orfao: id_lead da venda não existe em stg_leads
--   - flag_sem_agendamento: id_lead da venda não tem nenhum agendamento
--   - flag_lead_nao_compareceu: o agendamento vinculado tem compareceu=False
--     (venda sem reunião confirmada -- quebra a lógica do funil)
--   - flag_lead_status_perdido: o lead da venda está com status='perdido'
--   - flag_time_divergente / flag_closer_divergente: valor da tabela
--     de origem diferente da fonte da verdade
-- Cada flag tem um caso plantado no dataset fictício; os testes
-- (tests/test_pipeline.py) conferem que a quarentena pega todos.
-- ------------------------------------------------------------
CREATE TABLE stg_vendas AS
SELECT
    v.id_venda,
    v.id_lead,
    v.data_venda,
    v.valor,
    v.closer                                          AS closer_original,
    pa.closer                                          AS closer_final,
    v.time_comercial                                   AS time_comercial_original,
    l.time_comercial                                   AS time_comercial_final,
    (NOT EXISTS (SELECT 1 FROM stg_leads sl WHERE sl.id_lead = v.id_lead))            AS flag_orfao,
    (NOT EXISTS (SELECT 1 FROM stg_agendamentos ag WHERE ag.id_lead = v.id_lead))     AS flag_sem_agendamento,
    (pa.compareceu = False)                                                          AS flag_lead_nao_compareceu,
    (l.status = 'perdido')                                                           AS flag_lead_status_perdido,
    (l.time_comercial IS NOT NULL AND v.time_comercial <> l.time_comercial)           AS flag_time_divergente,
    (pa.closer IS NOT NULL AND v.closer <> pa.closer)                                 AS flag_closer_divergente
FROM dedup_vendas v
LEFT JOIN stg_leads l
       ON l.id_lead = v.id_lead
LEFT JOIN stg_agendamentos pa
       ON pa.id_lead = v.id_lead
      AND pa.primeiro_agendamento = TRUE;

-- ------------------------------------------------------------
-- 5) QUARENTENA
-- Todo registro que acendeu qualquer flag de qualidade cai aqui,
-- com a tabela de origem, o(s) id(s) e o motivo em texto. Nada é
-- excluído das tabelas stg_* por causa disso -- quarentena é um
-- log de auditoria para a equipe de dados revisar/corrigir na
-- origem (CRM), não uma lixeira.
-- ------------------------------------------------------------
CREATE TABLE quarentena AS
SELECT 'leads' AS tabela_origem, id_lead AS chave, 'status=convertido sem venda registrada (CRM desatualizado?)' AS motivo
FROM stg_leads WHERE flag_status_inconsistente
UNION ALL
SELECT 'agendamentos', id_agend, 'id_lead não existe em leads (órfão)'
FROM stg_agendamentos WHERE flag_orfao
UNION ALL
SELECT 'agendamentos', id_agend, 'sdr do agendamento diverge do sdr do lead'
FROM stg_agendamentos WHERE flag_sdr_divergente_lead
UNION ALL
SELECT 'vendas', id_venda, 'id_lead não existe em leads (órfã)'
FROM stg_vendas WHERE flag_orfao
UNION ALL
SELECT 'vendas', id_venda, 'lead sem nenhum agendamento registrado (quebra a lógica do funil)'
FROM stg_vendas WHERE flag_sem_agendamento AND NOT flag_orfao
UNION ALL
SELECT 'vendas', id_venda, 'lead vinculado não compareceu à reunião (compareceu=False)'
FROM stg_vendas WHERE flag_lead_nao_compareceu
UNION ALL
SELECT 'vendas', id_venda, 'lead vinculado está com status=perdido'
FROM stg_vendas WHERE flag_lead_status_perdido
UNION ALL
SELECT 'vendas', id_venda, 'time_comercial da venda diverge do time do lead'
FROM stg_vendas WHERE flag_time_divergente
UNION ALL
SELECT 'vendas', id_venda, 'closer da venda diverge do closer do agendamento'
FROM stg_vendas WHERE flag_closer_divergente;

-- Conferência final
SELECT 'stg_leads' AS tabela, COUNT(*) AS linhas FROM stg_leads
UNION ALL SELECT 'stg_agendamentos', COUNT(*) FROM stg_agendamentos
UNION ALL SELECT 'stg_vendas', COUNT(*) FROM stg_vendas
UNION ALL SELECT 'quarentena', COUNT(*) FROM quarentena;
