/* =============================================================================
   01_model_evaluation.sql
   How good is the engine? Compare alerts with the planted ground truth.

   An "alert" = a transaction whose risk score >= :alert_threshold
   (default 25 = MEDIUM band and above).

   Outputs
     eval.scored_transactions  every txn + label + score (one big fact table)
     eval.overall_metrics      precision / recall / F1 / money caught
     eval.rule_performance     per rule: alerts, precision, recall on its target
     eval.pattern_coverage     per fraud pattern: how much did ANY rule catch
     eval.threshold_curve      precision-recall trade-off for thresholds 25..100
   SQL: LEFT JOIN anti-patterns, FILTER, NULLIF safe division, generate_series
   ============================================================================= */
\echo '  evaluating against ground truth'
\if :{?alert_threshold}
\else
    \set alert_threshold 25
\endif
SELECT clock_timestamp()::timestamp AS t0 \gset

DROP TABLE IF EXISTS eval.scored_transactions;
CREATE TABLE eval.scored_transactions AS
SELECT
    t.txn_id,
    t.txn_ts,
    t.amount,
    t.status,
    l.fraud_pattern,
    (l.txn_id IS NOT NULL)                       AS is_fraud,
    COALESCE(s.risk_score, 0)                    AS risk_score,
    COALESCE(s.risk_score, 0) >= :alert_threshold AS is_alert,
    s.rule_codes
FROM upi.transactions t
LEFT JOIN eval.fraud_labels      l USING (txn_id)
LEFT JOIN fraud.txn_risk_scores  s USING (txn_id);

-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS eval.overall_metrics;
CREATE TABLE eval.overall_metrics AS
WITH cm AS (
    SELECT
        COUNT(*) FILTER (WHERE is_alert AND is_fraud)          AS tp,
        COUNT(*) FILTER (WHERE is_alert AND NOT is_fraud)      AS fp,
        COUNT(*) FILTER (WHERE NOT is_alert AND is_fraud)      AS fn,
        COUNT(*) FILTER (WHERE NOT is_alert AND NOT is_fraud)  AS tn,
        SUM(amount) FILTER (WHERE is_fraud)                    AS fraud_amount,
        SUM(amount) FILTER (WHERE is_fraud AND is_alert)       AS fraud_amount_caught,
        COUNT(*)                                               AS total_txns
    FROM eval.scored_transactions
)
SELECT
    :alert_threshold                                                AS alert_threshold,
    total_txns, tp, fp, fn, tn,
    ROUND(tp::NUMERIC / NULLIF(tp + fp, 0), 4)                      AS precision,
    ROUND(tp::NUMERIC / NULLIF(tp + fn, 0), 4)                      AS recall,
    ROUND(2.0 * tp / NULLIF(2 * tp + fp + fn, 0), 4)                AS f1_score,
    ROUND(fp::NUMERIC / NULLIF(fp + tn, 0), 6)                      AS false_positive_rate,
    ROUND(1000.0 * (tp + fp) / total_txns, 2)                       AS alerts_per_1000_txns,
    fraud_amount,
    fraud_amount_caught,
    ROUND(100.0 * fraud_amount_caught / NULLIF(fraud_amount, 0), 2) AS pct_fraud_amount_caught
FROM cm;

-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS eval.rule_performance;
CREATE TABLE eval.rule_performance AS
WITH target_totals AS (
    SELECT fraud_pattern, COUNT(*) AS target_total
    FROM eval.fraud_labels
    GROUP BY fraud_pattern
)
SELECT
    c.rule_code,
    c.rule_name,
    c.target_pattern,
    c.severity_points,
    COUNT(h.txn_id)                                                  AS alerts,
    COUNT(h.txn_id) FILTER (WHERE l.txn_id IS NOT NULL)              AS true_positives,
    COUNT(h.txn_id) FILTER (WHERE l.txn_id IS NULL)                  AS false_positives,
    ROUND(COUNT(h.txn_id) FILTER (WHERE l.txn_id IS NOT NULL)::NUMERIC
          / NULLIF(COUNT(h.txn_id), 0), 4)                           AS precision,
    COUNT(h.txn_id) FILTER (WHERE l.fraud_pattern = c.target_pattern) AS target_caught,
    tt.target_total,
    ROUND(COUNT(h.txn_id) FILTER (WHERE l.fraud_pattern = c.target_pattern)::NUMERIC
          / NULLIF(tt.target_total, 0), 4)                           AS recall_on_target
FROM fraud.rule_config c
LEFT JOIN fraud.rule_hits   h ON h.rule_code = c.rule_code
LEFT JOIN eval.fraud_labels l ON l.txn_id    = h.txn_id
LEFT JOIN target_totals    tt ON tt.fraud_pattern = c.target_pattern
WHERE c.rule_code <> 'COMBO'
GROUP BY c.rule_code, c.rule_name, c.target_pattern, c.severity_points, tt.target_total
ORDER BY c.rule_code;

-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS eval.pattern_coverage;
CREATE TABLE eval.pattern_coverage AS
SELECT
    fraud_pattern,
    COUNT(*)                                                          AS planted_txns,
    COUNT(*) FILTER (WHERE is_alert)                                  AS caught_txns,
    ROUND(COUNT(*) FILTER (WHERE is_alert)::NUMERIC / COUNT(*), 4)    AS recall,
    SUM(amount)                                                       AS planted_amount,
    SUM(amount) FILTER (WHERE is_alert)                               AS caught_amount,
    ROUND(AVG(risk_score), 1)                                         AS avg_risk_score
FROM eval.scored_transactions
WHERE is_fraud
GROUP BY fraud_pattern
ORDER BY recall DESC, fraud_pattern;

-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS eval.threshold_curve;
CREATE TABLE eval.threshold_curve AS
SELECT
    th.threshold,
    COUNT(*) FILTER (WHERE s.risk_score >= th.threshold)                           AS alerts,
    COUNT(*) FILTER (WHERE s.risk_score >= th.threshold AND s.is_fraud)            AS tp,
    ROUND(COUNT(*) FILTER (WHERE s.risk_score >= th.threshold AND s.is_fraud)::NUMERIC
          / NULLIF(COUNT(*) FILTER (WHERE s.risk_score >= th.threshold), 0), 4)    AS precision,
    ROUND(COUNT(*) FILTER (WHERE s.risk_score >= th.threshold AND s.is_fraud)::NUMERIC
          / NULLIF(COUNT(*) FILTER (WHERE s.is_fraud), 0), 4)                      AS recall
FROM generate_series(25, 100, 5) AS th (threshold)
CROSS JOIN eval.scored_transactions s
WHERE s.risk_score > 0 OR s.is_fraud           -- zero-score non-fraud rows never change the counts
GROUP BY th.threshold
ORDER BY th.threshold;

SELECT fraud.log_step('evaluation', (SELECT COUNT(*) FROM eval.scored_transactions), :'t0') AS logged \gset

\echo ''
\echo '  ---- overall metrics ----'
SELECT alert_threshold, tp, fp, fn, precision, recall, f1_score, alerts_per_1000_txns, pct_fraud_amount_caught
FROM eval.overall_metrics;
\echo '  ---- rule performance ----'
SELECT rule_code, rule_name, alerts, true_positives, precision, recall_on_target FROM eval.rule_performance;
\echo '  ---- pattern coverage ----'
SELECT fraud_pattern, planted_txns, caught_txns, recall, avg_risk_score FROM eval.pattern_coverage;
