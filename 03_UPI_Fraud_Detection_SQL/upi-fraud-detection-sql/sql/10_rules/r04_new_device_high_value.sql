/* =============================================================================
   R04 - NEW DEVICE + HIGH VALUE
   Pattern : SIM swap / phone takeover. An established customer suddenly pays
             a very large amount from a device never seen on their account.
   Logic   : ROW_NUMBER() per (account, device) finds the first use of a device.
             A running AVG over all *previous* payments (frame ends at
             1 PRECEDING, so the current payment does not pollute its own
             baseline) gives the customer's normal spend.
   SQL     : ROW_NUMBER, ROWS frame excluding current row, GREATEST
   ============================================================================= */
\echo '  R04 new device + high value'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R04';

WITH history AS (
    SELECT
        t.txn_id,
        t.payer_account_id,
        t.device_id,
        t.amount,
        ROW_NUMBER() OVER (PARTITION BY t.payer_account_id, t.device_id
                           ORDER BY t.txn_ts, t.txn_id)                  AS device_use_no,
        COUNT(*)     OVER prior                                          AS prior_txns,
        AVG(t.amount) OVER prior                                         AS prior_avg_amount
    FROM upi.transactions t
    WHERE t.status = 'SUCCESS'
    WINDOW prior AS (PARTITION BY t.payer_account_id ORDER BY t.txn_ts, t.txn_id
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
)
INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT
    txn_id,
    payer_account_id,
    'R04',
    jsonb_build_object(
        'device_id',         device_id,
        'amount',            amount,
        'prior_avg_amount',  ROUND(prior_avg_amount, 2),
        'x_times_normal',    ROUND(amount / NULLIF(prior_avg_amount, 0), 1),
        'prior_txns',        prior_txns
    )
FROM history
WHERE device_use_no = 1
  AND prior_txns >= fraud.param('R04', 'min_history_txns')
  AND amount >= GREATEST(fraud.param('R04', 'min_amount'),
                         fraud.param('R04', 'avg_multiplier') * prior_avg_amount)
  AND fraud.is_active('R04');

SELECT fraud.log_step('R04', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R04'), :'t0') AS logged \gset
