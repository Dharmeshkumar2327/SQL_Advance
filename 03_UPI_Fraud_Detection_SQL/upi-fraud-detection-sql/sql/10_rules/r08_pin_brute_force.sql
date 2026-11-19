/* =============================================================================
   R08 - PIN BRUTE FORCE
   Pattern : 3+ "wrong PIN" failures in a few minutes, then a success.
             Someone who does not know the PIN is guessing it.
   Logic   : one pass over ALL attempts (success + failed) of each payer, with
             a conditional window aggregate:
                 COUNT(*) FILTER (WHERE status='FAILED' AND reason='WRONG_PIN')
                 OVER (... RANGE <n> minutes PRECEDING ...)
   SQL     : FILTER clause inside a window aggregate, time RANGE frame
   ============================================================================= */
\echo '  R08 PIN brute force'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R08';

WITH attempts AS (
    SELECT
        t.txn_id,
        t.payer_account_id,
        t.txn_ts,
        t.status,
        t.amount,
        t.device_id,
        COUNT(*) FILTER (WHERE t.status = 'FAILED' AND t.failure_reason = 'WRONG_PIN') OVER w
            AS wrong_pins_before,
        MIN(t.txn_ts) FILTER (WHERE t.status = 'FAILED' AND t.failure_reason = 'WRONG_PIN') OVER w
            AS first_failure_ts
    FROM upi.transactions t
    WHERE t.payer_account_id IN (       -- only accounts that ever entered a wrong PIN
        SELECT payer_account_id FROM upi.transactions
        WHERE status = 'FAILED' AND failure_reason = 'WRONG_PIN'
    )
    WINDOW w AS (
        PARTITION BY t.payer_account_id
        ORDER BY t.txn_ts
        RANGE BETWEEN make_interval(mins => fraud.param('R08', 'window_minutes')::INT) PRECEDING
                  AND CURRENT ROW
    )
)
INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT
    txn_id,
    payer_account_id,
    'R08',
    jsonb_build_object(
        'wrong_pin_attempts',  wrong_pins_before,
        'seconds_since_first', EXTRACT(EPOCH FROM txn_ts - first_failure_ts)::INT,
        'device_id',           device_id,
        'amount',              amount
    )
FROM attempts
WHERE status = 'SUCCESS'
  AND wrong_pins_before >= fraud.param('R08', 'min_failed_attempts')
  AND fraud.is_active('R08');

SELECT fraud.log_step('R08', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R08'), :'t0') AS logged \gset
