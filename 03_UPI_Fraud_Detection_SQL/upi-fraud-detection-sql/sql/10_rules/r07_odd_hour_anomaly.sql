/* =============================================================================
   R07 - ODD-HOUR AMOUNT ANOMALY
   Pattern : a payment between 1am and 4am that is wildly larger than what
             this customer normally spends.
   Logic   : behavioural baseline per customer = running AVG and STDDEV of all
             previous payments. z = (amount - avg) / stddev. Flag z >= 3 at
             odd hours.
   SQL     : statistical window aggregates (STDDEV_SAMP), z-score, EXTRACT(HOUR)
   ============================================================================= */
\echo '  R07 odd-hour amount anomaly'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R07';

WITH baseline AS (
    SELECT
        t.txn_id,
        t.payer_account_id,
        t.txn_ts,
        t.amount,
        COUNT(*)              OVER prior AS prior_txns,
        AVG(t.amount)         OVER prior AS prior_avg,
        STDDEV_SAMP(t.amount) OVER prior AS prior_std
    FROM upi.transactions t
    WHERE t.status = 'SUCCESS'
    WINDOW prior AS (PARTITION BY t.payer_account_id ORDER BY t.txn_ts, t.txn_id
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),
scored AS (
    SELECT b.*, (b.amount - b.prior_avg) / NULLIF(b.prior_std, 0) AS z_score
    FROM baseline b
    WHERE EXTRACT(HOUR FROM b.txn_ts) BETWEEN fraud.param('R07', 'start_hour')
                                          AND fraud.param('R07', 'end_hour')
      AND b.prior_txns >= fraud.param('R07', 'min_history_txns')
)
INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT
    txn_id,
    payer_account_id,
    'R07',
    jsonb_build_object(
        'hour_of_day', EXTRACT(HOUR FROM txn_ts),
        'amount',      amount,
        'prior_avg',   ROUND(prior_avg, 2),
        'prior_std',   ROUND(prior_std, 2),
        'z_score',     ROUND(z_score, 2)
    )
FROM scored
WHERE z_score >= fraud.param('R07', 'z_threshold')
  AND amount  >= fraud.param('R07', 'min_amount')
  AND fraud.is_active('R07');

SELECT fraud.log_step('R07', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R07'), :'t0') AS logged \gset
