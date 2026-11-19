/* =============================================================================
   R01 - VELOCITY BURST
   Pattern : account takeover - fraudster drains the account with many quick
             payments before the customer notices.
   Logic   : rolling COUNT/SUM over a time-based window frame
             (RANGE BETWEEN <n> minutes PRECEDING AND CURRENT ROW).
             When the window crosses the thresholds we flag EVERY transaction
             inside that burst, not just the one that tipped it over.
   SQL     : window functions with RANGE + INTERVAL frames, self-join on range
   ============================================================================= */
\echo '  R01 velocity burst'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R01';

WITH rolling AS (
    SELECT
        t.txn_id,
        t.payer_account_id,
        t.txn_ts,
        COUNT(*)      OVER w AS txns_in_window,
        SUM(t.amount) OVER w AS amount_in_window
    FROM upi.transactions t
    WHERE t.status = 'SUCCESS'
    WINDOW w AS (
        PARTITION BY t.payer_account_id
        ORDER BY t.txn_ts
        RANGE BETWEEN make_interval(mins => fraud.param('R01', 'window_minutes')::INT) PRECEDING
                  AND CURRENT ROW
    )
),
triggers AS (                      -- moments where the window breached the thresholds
    SELECT payer_account_id, txn_ts AS trigger_ts, txns_in_window, amount_in_window
    FROM rolling
    WHERE txns_in_window   >= fraud.param('R01', 'min_txns')
      AND amount_in_window >= fraud.param('R01', 'min_total_amount')
),
burst_members AS (                 -- every txn that belongs to a breaching window
    SELECT DISTINCT ON (t.txn_id)
        t.txn_id, t.payer_account_id, tr.trigger_ts, tr.txns_in_window, tr.amount_in_window
    FROM triggers tr
    JOIN upi.transactions t
      ON  t.payer_account_id = tr.payer_account_id
      AND t.status = 'SUCCESS'
      AND t.txn_ts BETWEEN tr.trigger_ts - make_interval(mins => fraud.param('R01', 'window_minutes')::INT)
                       AND tr.trigger_ts
    ORDER BY t.txn_id, tr.txns_in_window DESC
)
INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT
    txn_id,
    payer_account_id,
    'R01',
    jsonb_build_object(
        'txns_in_window',   txns_in_window,
        'amount_in_window', amount_in_window,
        'window_minutes',   fraud.param('R01', 'window_minutes'),
        'burst_peak_at',    trigger_ts
    )
FROM burst_members
WHERE fraud.is_active('R01');

SELECT fraud.log_step('R01', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R01'), :'t0') AS logged \gset
