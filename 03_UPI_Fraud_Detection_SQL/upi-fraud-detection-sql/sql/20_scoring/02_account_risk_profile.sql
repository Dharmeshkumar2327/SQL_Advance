/* =============================================================================
   02_account_risk_profile.sql
   Rolls transaction alerts up to the ACCOUNT level so investigators can work
   on people, not single payments.

   An account is "involved" in an alert if the rule named it as the suspect
   (rule_hits.account_id): the payer for most rules, the RECEIVER for mule
   chains (R03) and fan-in scams (R06).
   SQL: FILTER aggregates, DISTINCT de-duplication, CTE pipeline, CASE tiering
   ============================================================================= */
\echo '  building account risk profiles'
SELECT clock_timestamp()::timestamp AS t0 \gset

DROP TABLE IF EXISTS fraud.account_risk_profile;

CREATE TABLE fraud.account_risk_profile AS
WITH account_rules AS (
    SELECT
        account_id,
        COUNT(DISTINCT rule_code)                         AS distinct_rules,
        ARRAY_AGG(DISTINCT rule_code ORDER BY rule_code)  AS rules
    FROM fraud.rule_hits
    GROUP BY account_id
),
account_txns AS (               -- one row per (account, alerted txn) - avoids double counting
    SELECT DISTINCT account_id, txn_id FROM fraud.rule_hits
),
alerts AS (
    SELECT
        x.account_id,
        COUNT(*)                                                     AS alerted_txns,
        SUM(s.amount)                                                AS alerted_amount,
        MAX(s.risk_score)                                            AS max_txn_score,
        MAX(s.txn_ts)                                                AS last_alert_at,
        COUNT(*) FILTER (WHERE s.risk_band IN ('HIGH', 'CRITICAL'))  AS high_or_critical_txns,
        r.distinct_rules,
        r.rules
    FROM account_txns x
    JOIN fraud.txn_risk_scores s USING (txn_id)
    JOIN account_rules r USING (account_id)
    GROUP BY x.account_id, r.distinct_rules, r.rules
),
activity AS (
    SELECT payer_account_id AS account_id,
           COUNT(*)         AS total_txns_sent,
           SUM(amount)      AS total_amount_sent
    FROM upi.transactions
    WHERE status = 'SUCCESS'
    GROUP BY payer_account_id
)
SELECT
    a.account_id,
    acc.vpa,
    acc.holder_name,
    acc.account_type,
    acc.home_city,
    acc.kyc_level,
    acc.created_at,
    COALESCE(act.total_txns_sent, 0)   AS total_txns_sent,
    a.alerted_txns,
    a.alerted_amount,
    a.high_or_critical_txns,
    a.distinct_rules,
    a.rules,
    a.max_txn_score,
    a.last_alert_at,
    (m.account_id IS NOT NULL)         AS is_suspected_mule,
    LEAST(100, a.max_txn_score + 5 * (a.distinct_rules - 1)
               + CASE WHEN m.account_id IS NOT NULL THEN 20 ELSE 0 END
               + CASE WHEN acc.kyc_level = 'MIN' THEN 5 ELSE 0 END)  AS account_risk_score,
    CASE
        WHEN m.account_id IS NOT NULL OR a.max_txn_score >= 75 THEN 'TIER_1_FREEZE_AND_INVESTIGATE'
        WHEN a.max_txn_score >= 50 OR a.distinct_rules >= 2   THEN 'TIER_2_INVESTIGATE'
        ELSE                                                       'TIER_3_MONITOR'
    END                                AS investigation_tier
FROM alerts a
JOIN upi.accounts acc ON acc.account_id = a.account_id
LEFT JOIN activity act ON act.account_id = a.account_id
LEFT JOIN fraud.suspected_mule_accounts m ON m.account_id = a.account_id;

ALTER TABLE fraud.account_risk_profile ADD PRIMARY KEY (account_id);

SELECT fraud.log_step('account_risk_profile', (SELECT COUNT(*) FROM fraud.account_risk_profile), :'t0') AS logged \gset

SELECT investigation_tier, COUNT(*) AS accounts
FROM fraud.account_risk_profile
GROUP BY investigation_tier
ORDER BY investigation_tier;
