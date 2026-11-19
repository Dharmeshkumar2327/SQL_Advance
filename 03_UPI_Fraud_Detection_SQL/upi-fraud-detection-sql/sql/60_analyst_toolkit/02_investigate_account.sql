/* =============================================================================
   02_investigate_account.sql  -  one-page case file for an investigator.

   Usage (pick an account from analytics.top_risky_accounts):
       psql -d upi_fraud -v account_id=50012 -f sql/60_analyst_toolkit/02_investigate_account.sql
   ============================================================================= */
\set ON_ERROR_STOP on
\if :{?account_id}
\else
    SELECT account_id AS account_id FROM analytics.top_risky_accounts WHERE risk_rank = 1 LIMIT 1 \gset
    \echo 'no -v account_id given, using the #1 risky account:' :account_id
\endif

\echo ''
\echo '==== 1. PROFILE ===='
SELECT a.account_id, a.vpa, a.holder_name, a.account_type, a.home_city, a.kyc_level, a.created_at,
       p.account_risk_score, p.investigation_tier, p.is_suspected_mule,
       ARRAY_TO_STRING(p.rules, ', ') AS rules_fired
FROM upi.accounts a
LEFT JOIN fraud.account_risk_profile p USING (account_id)
WHERE a.account_id = :account_id;

\echo '==== 2. ALERTS WITH EVIDENCE ===='
SELECT h.txn_id, t.txn_ts, t.amount, h.rule_code, c.rule_name, h.evidence
FROM fraud.rule_hits h
JOIN upi.transactions t USING (txn_id)
JOIN fraud.rule_config c USING (rule_code)
WHERE h.account_id = :account_id
ORDER BY t.txn_ts
LIMIT 50;

\echo '==== 3. MONEY IN vs MONEY OUT (per day) ===='
SELECT d::DATE AS day,
       COALESCE(SUM(amount) FILTER (WHERE payee_account_id = :account_id), 0) AS money_in,
       COALESCE(SUM(amount) FILTER (WHERE payer_account_id = :account_id), 0) AS money_out,
       COUNT(DISTINCT payer_account_id) FILTER (WHERE payee_account_id = :account_id) AS distinct_senders
FROM upi.transactions,
     LATERAL (SELECT txn_ts::DATE) AS x(d)
WHERE status = 'SUCCESS'
  AND (payer_account_id = :account_id OR payee_account_id = :account_id)
GROUP BY d
ORDER BY d;

\echo '==== 4. TOP COUNTERPARTIES ===='
WITH flows AS (
    SELECT CASE WHEN payer_account_id = :account_id THEN payee_account_id ELSE payer_account_id END AS counterparty,
           CASE WHEN payer_account_id = :account_id THEN 'SENT_TO' ELSE 'RECEIVED_FROM' END     AS direction,
           amount
    FROM upi.transactions
    WHERE status = 'SUCCESS'
      AND (payer_account_id = :account_id OR payee_account_id = :account_id)
)
SELECT f.direction, f.counterparty, a.vpa, a.account_type,
       COUNT(*) AS txns, SUM(f.amount) AS total,
       (p.account_id IS NOT NULL) AS counterparty_flagged
FROM flows f
JOIN upi.accounts a ON a.account_id = f.counterparty
LEFT JOIN fraud.account_risk_profile p ON p.account_id = f.counterparty
GROUP BY f.direction, f.counterparty, a.vpa, a.account_type, p.account_id
ORDER BY total DESC
LIMIT 15;

\echo '==== 5. MULE CHAINS THIS ACCOUNT APPEARS IN ===='
SELECT chain_id, hop_no, txn_ts, payer_vpa, payee_vpa, amount, pct_amount_retained
FROM analytics.mule_network_edges
WHERE chain_id IN (SELECT chain_id FROM fraud.mule_chains
                   WHERE payer_account_id = :account_id OR payee_account_id = :account_id)
ORDER BY chain_id, hop_no;
