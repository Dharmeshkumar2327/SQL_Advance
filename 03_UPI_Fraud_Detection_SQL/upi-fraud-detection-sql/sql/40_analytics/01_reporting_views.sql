/* =============================================================================
   01_reporting_views.sql
   Business-facing views for the fraud-ops team and the dashboard.
   SQL: views over CTEs, ROLLUP-free summaries, DATE_TRUNC, EXTRACT(ISODOW),
        RANK() for leaderboards, conditional aggregation
   ============================================================================= */
\echo '  creating analytics views'

-- Headline KPIs (one row)
CREATE OR REPLACE VIEW analytics.kpi_summary AS
SELECT
    (SELECT COUNT(*)            FROM upi.transactions)                               AS total_txns,
    (SELECT SUM(amount)         FROM upi.transactions WHERE status = 'SUCCESS')      AS total_value,
    (SELECT COUNT(*)            FROM upi.accounts)                                   AS total_accounts,
    (SELECT COUNT(*)            FROM fraud.txn_risk_scores)                          AS alerted_txns,
    (SELECT SUM(amount)         FROM fraud.txn_risk_scores)                          AS alerted_value,
    (SELECT COUNT(*)            FROM fraud.txn_risk_scores WHERE risk_band = 'CRITICAL') AS critical_txns,
    (SELECT COUNT(*)            FROM fraud.account_risk_profile
                                WHERE investigation_tier LIKE 'TIER_1%')             AS tier1_accounts,
    (SELECT COUNT(*)            FROM fraud.suspected_mule_accounts)                  AS suspected_mules,
    (SELECT COUNT(DISTINCT chain_id) FROM fraud.mule_chains)                         AS mule_chains,
    (SELECT precision           FROM eval.overall_metrics)                           AS precision,
    (SELECT recall              FROM eval.overall_metrics)                           AS recall,
    (SELECT f1_score            FROM eval.overall_metrics)                           AS f1_score,
    (SELECT pct_fraud_amount_caught FROM eval.overall_metrics)                       AS pct_fraud_amount_caught;

-- Daily trend: volume vs alerts
CREATE OR REPLACE VIEW analytics.daily_alert_trend AS
SELECT
    t.txn_ts::DATE                                                AS txn_date,
    COUNT(*)                                                      AS txns,
    SUM(t.amount)                                                 AS txn_value,
    COUNT(s.txn_id)                                               AS alerts,
    COUNT(s.txn_id) FILTER (WHERE s.risk_band = 'CRITICAL')       AS critical_alerts,
    COALESCE(SUM(s.amount), 0)                                    AS alerted_value,
    ROUND(1000.0 * COUNT(s.txn_id) / COUNT(*), 2)                 AS alerts_per_1000
FROM upi.transactions t
LEFT JOIN fraud.txn_risk_scores s USING (txn_id)
GROUP BY t.txn_ts::DATE
ORDER BY txn_date;

-- When does fraud happen? day-of-week x hour heatmap
CREATE OR REPLACE VIEW analytics.hourly_risk_heatmap AS
SELECT
    EXTRACT(ISODOW FROM t.txn_ts)::INT                            AS iso_dow,      -- 1 = Monday
    TO_CHAR(t.txn_ts, 'Dy')                                       AS day_name,
    EXTRACT(HOUR FROM t.txn_ts)::INT                              AS hour_of_day,
    COUNT(*)                                                      AS txns,
    COUNT(s.txn_id)                                               AS alerts,
    ROUND(1000.0 * COUNT(s.txn_id) / COUNT(*), 2)                 AS alerts_per_1000
FROM upi.transactions t
LEFT JOIN fraud.txn_risk_scores s USING (txn_id)
GROUP BY 1, 2, 3;

-- Where? city level, with state for map/grouping
CREATE OR REPLACE VIEW analytics.city_risk AS
SELECT
    c.city,
    c.state,
    c.latitude,
    c.longitude,
    COUNT(t.txn_id)                                               AS txns,
    COUNT(s.txn_id)                                               AS alerts,
    COALESCE(SUM(s.amount), 0)                                    AS alerted_value,
    ROUND(1000.0 * COUNT(s.txn_id) / NULLIF(COUNT(t.txn_id), 0), 2) AS alerts_per_1000,
    RANK() OVER (ORDER BY COUNT(s.txn_id) DESC)                   AS alert_rank
FROM upi.cities c
LEFT JOIN upi.transactions t      ON t.txn_city = c.city
LEFT JOIN fraud.txn_risk_scores s ON s.txn_id   = t.txn_id
GROUP BY c.city, c.state, c.latitude, c.longitude;

-- How? channel and payment type
CREATE OR REPLACE VIEW analytics.channel_risk AS
SELECT
    t.channel,
    t.txn_type,
    COUNT(*)                                                      AS txns,
    COUNT(s.txn_id)                                               AS alerts,
    ROUND(1000.0 * COUNT(s.txn_id) / COUNT(*), 2)                 AS alerts_per_1000,
    ROUND(AVG(t.amount), 2)                                       AS avg_amount,
    ROUND(AVG(s.amount), 2)                                       AS avg_alerted_amount
FROM upi.transactions t
LEFT JOIN fraud.txn_risk_scores s USING (txn_id)
GROUP BY t.channel, t.txn_type;

-- Which rules fire, and how often do they agree?
CREATE OR REPLACE VIEW analytics.rule_overlap AS
SELECT
    a.rule_code   AS rule_a,
    b.rule_code   AS rule_b,
    COUNT(*)      AS shared_txns
FROM fraud.rule_hits a
JOIN fraud.rule_hits b ON b.txn_id = a.txn_id AND b.rule_code > a.rule_code
GROUP BY a.rule_code, b.rule_code;

-- Investigator leaderboard
CREATE OR REPLACE VIEW analytics.top_risky_accounts AS
SELECT
    RANK() OVER (ORDER BY account_risk_score DESC, alerted_txns DESC, account_id) AS risk_rank,
    account_id, vpa, holder_name, account_type, home_city, kyc_level, created_at,
    alerted_txns, alerted_amount, distinct_rules, ARRAY_TO_STRING(rules, ', ') AS rules,
    is_suspected_mule, account_risk_score, investigation_tier, last_alert_at
FROM fraud.account_risk_profile;

-- Money-flow edges of detected mule chains (for network / Sankey charts)
CREATE OR REPLACE VIEW analytics.mule_network_edges AS
SELECT
    m.chain_id,
    m.hop_no,
    m.txn_id,
    m.txn_ts,
    m.payer_account_id,
    p.vpa                                AS payer_vpa,
    m.payee_account_id,
    r.vpa                                AS payee_vpa,
    r.account_type                       AS payee_type,
    m.amount,
    m.chain_txns,
    m.pct_amount_retained
FROM fraud.mule_chains m
JOIN upi.accounts p ON p.account_id = m.payer_account_id
JOIN upi.accounts r ON r.account_id = m.payee_account_id;

-- Analyst work queue: HIGH + CRITICAL alerts, newest first, with readable reasons
CREATE OR REPLACE VIEW analytics.alert_queue AS
SELECT
    s.txn_id,
    s.txn_ts,
    s.risk_score,
    s.risk_band,
    s.action,
    s.amount,
    s.txn_type,
    s.channel,
    s.txn_city,
    p.vpa                                        AS payer_vpa,
    r.vpa                                        AS payee_vpa,
    ARRAY_TO_STRING(s.rule_codes, ' + ')         AS rules_fired,
    (SELECT STRING_AGG(c.rule_name, ' + ' ORDER BY c.rule_code)
     FROM fraud.rule_config c WHERE c.rule_code = ANY (s.rule_codes)) AS reasons,
    s.evidence::TEXT                             AS evidence
FROM fraud.txn_risk_scores s
JOIN upi.accounts p ON p.account_id = s.payer_account_id
JOIN upi.accounts r ON r.account_id = s.payee_account_id
WHERE s.risk_band IN ('HIGH', 'CRITICAL')
   OR s.rules_fired >= 2;
