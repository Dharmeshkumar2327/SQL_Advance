/* =============================================================================
   01_txn_risk_scores.sql
   Combines all rule hits into ONE risk score per transaction.

     score = SUM(severity of every rule that fired)
           + bonus_per_extra_rule * (number_of_rules - 1)      -- rules agreeing
     capped at 100, then mapped to a band + action via fraud.risk_bands.

   Only transactions with at least one hit are stored (everything else = 0).
   SQL: aggregation with ARRAY_AGG / JSONB_OBJECT_AGG, range join to bands
   ============================================================================= */
\echo '  scoring transactions'
SELECT clock_timestamp()::timestamp AS t0 \gset

DROP TABLE IF EXISTS fraud.txn_risk_scores;

CREATE TABLE fraud.txn_risk_scores AS
WITH per_txn AS (
    SELECT
        h.txn_id,
        COUNT(*)                                            AS rules_fired,
        SUM(c.severity_points)                              AS base_points,
        ARRAY_AGG(h.rule_code ORDER BY h.rule_code)         AS rule_codes,
        JSONB_OBJECT_AGG(h.rule_code, h.evidence)           AS evidence
    FROM fraud.rule_hits h
    JOIN fraud.rule_config c USING (rule_code)
    GROUP BY h.txn_id
),
scored AS (
    SELECT
        p.*,
        LEAST(100,
              p.base_points
              + fraud.param('COMBO', 'bonus_per_extra_rule') * (p.rules_fired - 1)
        )::INT AS risk_score
    FROM per_txn p
)
SELECT
    t.txn_id,
    t.txn_ts,
    t.payer_account_id,
    t.payee_account_id,
    t.amount,
    t.txn_type,
    t.channel,
    t.txn_city,
    s.rules_fired,
    s.rule_codes,
    s.risk_score,
    b.risk_band,
    b.action,
    s.evidence
FROM scored s
JOIN upi.transactions t ON t.txn_id = s.txn_id
JOIN fraud.risk_bands b ON s.risk_score BETWEEN b.min_score AND b.max_score;

ALTER TABLE fraud.txn_risk_scores ADD PRIMARY KEY (txn_id);
CREATE INDEX ON fraud.txn_risk_scores (risk_band);

SELECT fraud.log_step('txn_risk_scores', (SELECT COUNT(*) FROM fraud.txn_risk_scores), :'t0') AS logged \gset

SELECT risk_band, action, COUNT(*) AS txns, SUM(amount) AS amount_at_risk
FROM fraud.txn_risk_scores
GROUP BY risk_band, action
ORDER BY MIN(risk_score);
