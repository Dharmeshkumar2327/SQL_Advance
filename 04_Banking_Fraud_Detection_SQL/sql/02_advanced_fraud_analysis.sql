-- Banking Fraud Detection | Advanced PostgreSQL investigations
-- Run after 01_schema.sql and loading CSV files.
-- The is_fraud column is synthetic ground truth for evaluation only.
-- Do not use it as an input to the detection rules.

-- 1. Executive fraud KPI summary
SELECT COUNT(*) AS total_transactions,
       COUNT(*) FILTER (WHERE is_fraud = 1) AS known_fraud_transactions,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*),0), 2) AS fraud_rate_pct,
       ROUND(SUM(amount) FILTER (WHERE is_fraud = 1), 2) AS known_fraud_value,
       ROUND(AVG(amount), 2) AS avg_transaction_value
FROM transactions;

-- 2. High-value transactions relative to each account's own behaviour (z-score)
WITH account_stats AS (
    SELECT account_id, AVG(amount) AS avg_amt, STDDEV_POP(amount) AS sd_amt
    FROM transactions GROUP BY account_id
), scored AS (
    SELECT t.*, s.avg_amt, s.sd_amt,
           (t.amount - s.avg_amt) / NULLIF(s.sd_amt,0) AS amount_z_score
    FROM transactions t JOIN account_stats s USING (account_id)
)
SELECT transaction_id, account_id, transaction_ts, amount,
       ROUND(amount_z_score::numeric,2) AS amount_z_score
FROM scored
WHERE amount_z_score >= 3
ORDER BY amount_z_score DESC
LIMIT 100;

-- 3. Rapid transaction bursts: 5+ transactions in a rolling 10-minute window
-- PostgreSQL has no QUALIFY; use a CTE to filter a window result:
WITH burst AS (
    SELECT transaction_id, account_id, transaction_ts,
           COUNT(*) OVER (
             PARTITION BY account_id ORDER BY transaction_ts
             RANGE BETWEEN INTERVAL '10 minutes' PRECEDING AND CURRENT ROW
           ) AS txns_last_10m
    FROM transactions
)
SELECT * FROM burst WHERE txns_last_10m >= 5 ORDER BY txns_last_10m DESC;

-- 4. First transaction in a new country for each account
WITH country_history AS (
    SELECT *,
           LAG(country) OVER (PARTITION BY account_id ORDER BY transaction_ts) AS previous_country,
           ROW_NUMBER() OVER (PARTITION BY account_id, country ORDER BY transaction_ts) AS country_visit_no
    FROM transactions
)
SELECT transaction_id, account_id, transaction_ts, country, previous_country, amount
FROM country_history
WHERE country_visit_no = 1 AND country <> 'IN'
ORDER BY transaction_ts;

-- 5. Multiple small transactions (possible card testing): 8+ under INR 500 in 30 minutes
WITH small_txns AS (
    SELECT *,
           COUNT(*) OVER (
             PARTITION BY account_id
             ORDER BY transaction_ts
             RANGE BETWEEN INTERVAL '30 minutes' PRECEDING AND CURRENT ROW
           ) AS small_txn_count
    FROM transactions
    WHERE amount < 500 AND transaction_status = 'SUCCESS'
)
SELECT transaction_id, account_id, transaction_ts, amount, small_txn_count
FROM small_txns WHERE small_txn_count >= 8
ORDER BY small_txn_count DESC;

-- 6. High-risk merchant + high-risk customer combinations
SELECT t.transaction_id, c.customer_id, c.risk_segment,
       m.merchant_name, m.category, m.risk_level, t.amount, t.transaction_ts
FROM transactions t
JOIN accounts a USING (account_id)
JOIN customers c USING (customer_id)
JOIN merchants m USING (merchant_id)
WHERE c.risk_segment = 'HIGH' AND m.risk_level = 'HIGH'
ORDER BY t.amount DESC;

-- 7. Device sharing across multiple accounts
SELECT device_id, COUNT(DISTINCT account_id) AS accounts_used,
       COUNT(*) AS transaction_count, SUM(amount) AS total_value
FROM transactions
GROUP BY device_id
HAVING COUNT(DISTINCT account_id) >= 5
ORDER BY accounts_used DESC, total_value DESC;

-- 8. Daily fraud trend and 7-day rolling fraud rate (labelled evaluation)
WITH daily AS (
    SELECT transaction_ts::date AS txn_date,
           COUNT(*) AS txn_count,
           COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_count
    FROM transactions GROUP BY transaction_ts::date
)
SELECT txn_date, txn_count, fraud_count,
       ROUND(100.0 * fraud_count / NULLIF(txn_count,0),2) AS daily_fraud_pct,
       ROUND(100.0 * SUM(fraud_count) OVER (
           ORDER BY txn_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
       ) / NULLIF(SUM(txn_count) OVER (
           ORDER BY txn_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
       ),0),2) AS rolling_7d_fraud_pct
FROM daily ORDER BY txn_date;

-- 9. Rank accounts by suspicious transaction value
WITH account_risk AS (
    SELECT account_id,
           COUNT(*) FILTER (WHERE amount >= 25000 OR country <> 'IN') AS suspicious_txns,
           SUM(amount) FILTER (WHERE amount >= 25000 OR country <> 'IN') AS suspicious_value
    FROM transactions GROUP BY account_id
)
SELECT *, DENSE_RANK() OVER (ORDER BY suspicious_value DESC NULLS LAST) AS risk_rank
FROM account_risk ORDER BY risk_rank LIMIT 50;

-- 10. Declined-to-success retry pattern within 15 minutes
WITH ordered AS (
    SELECT *,
           LEAD(transaction_status) OVER (PARTITION BY account_id ORDER BY transaction_ts) AS next_status,
           LEAD(transaction_ts) OVER (PARTITION BY account_id ORDER BY transaction_ts) AS next_ts,
           LEAD(amount) OVER (PARTITION BY account_id ORDER BY transaction_ts) AS next_amount
    FROM transactions
)
SELECT transaction_id, account_id, transaction_ts, amount,
       next_ts, next_amount
FROM ordered
WHERE transaction_status = 'DECLINED'
  AND next_status = 'SUCCESS'
  AND next_ts <= transaction_ts + INTERVAL '15 minutes';

-- 11. Merchant anomaly: amount is 3x category average
WITH category_stats AS (
    SELECT m.category, AVG(t.amount) AS category_avg
    FROM transactions t JOIN merchants m USING (merchant_id)
    GROUP BY m.category
)
SELECT t.transaction_id, m.category, t.amount, cs.category_avg,
       ROUND((t.amount / NULLIF(cs.category_avg,0))::numeric,2) AS category_multiple
FROM transactions t
JOIN merchants m USING (merchant_id)
JOIN category_stats cs USING (category)
WHERE t.amount > 3 * cs.category_avg
ORDER BY category_multiple DESC LIMIT 100;

-- 12. Confusion matrix for a simple rules-based alert score
-- Example rules: foreign country, amount > INR 25,000, or high-risk merchant.
WITH alerts AS (
    SELECT t.transaction_id, t.is_fraud,
           CASE WHEN t.country <> 'IN' THEN 1 ELSE 0 END
         + CASE WHEN t.amount > 25000 THEN 1 ELSE 0 END
         + CASE WHEN m.risk_level = 'HIGH' THEN 1 ELSE 0 END AS alert_score
    FROM transactions t JOIN merchants m USING (merchant_id)
)
SELECT
    COUNT(*) FILTER (WHERE alert_score >= 2 AND is_fraud = 1) AS true_positive,
    COUNT(*) FILTER (WHERE alert_score >= 2 AND is_fraud = 0) AS false_positive,
    COUNT(*) FILTER (WHERE alert_score < 2 AND is_fraud = 0) AS true_negative,
    COUNT(*) FILTER (WHERE alert_score < 2 AND is_fraud = 1) AS false_negative
FROM alerts;

-- 13. Precision, recall and F1 for the alert threshold
WITH alerts AS (
    SELECT t.is_fraud,
           (CASE WHEN t.country <> 'IN' THEN 1 ELSE 0 END
          + CASE WHEN t.amount > 25000 THEN 1 ELSE 0 END
          + CASE WHEN m.risk_level = 'HIGH' THEN 1 ELSE 0 END) >= 2 AS predicted_fraud
    FROM transactions t JOIN merchants m USING (merchant_id)
), metrics AS (
    SELECT COUNT(*) FILTER (WHERE predicted_fraud AND is_fraud=1) AS tp,
           COUNT(*) FILTER (WHERE predicted_fraud AND is_fraud=0) AS fp,
           COUNT(*) FILTER (WHERE NOT predicted_fraud AND is_fraud=1) AS fn
    FROM alerts
)
SELECT tp, fp, fn,
       ROUND(tp::numeric / NULLIF(tp+fp,0),4) AS precision,
       ROUND(tp::numeric / NULLIF(tp+fn,0),4) AS recall,
       ROUND(2.0*tp / NULLIF(2*tp+fp+fn,0),4) AS f1_score
FROM metrics;

-- 14. Monthly cohort: customer first transaction month and subsequent activity
WITH first_txn AS (
    SELECT a.customer_id, DATE_TRUNC('month', MIN(t.transaction_ts)) AS cohort_month
    FROM accounts a JOIN transactions t USING (account_id)
    GROUP BY a.customer_id
), activity AS (
    SELECT a.customer_id, DATE_TRUNC('month', t.transaction_ts) AS activity_month
    FROM accounts a JOIN transactions t USING (account_id)
    GROUP BY a.customer_id, DATE_TRUNC('month', t.transaction_ts)
)
SELECT f.cohort_month, x.activity_month,
       (EXTRACT(YEAR FROM x.activity_month)-EXTRACT(YEAR FROM f.cohort_month))*12
       + EXTRACT(MONTH FROM x.activity_month)-EXTRACT(MONTH FROM f.cohort_month) AS month_number,
       COUNT(DISTINCT x.customer_id) AS active_customers
FROM first_txn f JOIN activity x USING (customer_id)
GROUP BY f.cohort_month, x.activity_month
ORDER BY f.cohort_month, x.activity_month;

-- 15. Explain plan exercise: compare before/after indexing
EXPLAIN ANALYZE
SELECT * FROM transactions
WHERE account_id = 10042
  AND transaction_ts >= TIMESTAMP '2025-06-01'
  AND transaction_ts < TIMESTAMP '2025-07-01'
ORDER BY transaction_ts DESC;
