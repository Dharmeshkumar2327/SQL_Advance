/* =============================================================================
   R06 - FAN-IN COLLECT SCAM
   Pattern : a freshly opened personal account receives small payments from
             dozens of unrelated people in one day (fake collect requests,
             "job offer" / "lottery" scams).
   Logic   : Postgres does not allow COUNT(DISTINCT) as a window function, so a
             LATERAL subquery counts distinct payers in the trailing 24 h for
             each inbound payment (it uses idx_txn_payee_ts). Only young
             PERSONAL accounts are checked - a new kirana shop receiving many
             payments is normal and is deliberately excluded.
   SQL     : CROSS JOIN LATERAL, COUNT(DISTINCT), interval arithmetic
   ============================================================================= */
\echo '  R06 fan-in collect scam'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R06';

WITH inbound AS (               -- payments into young personal accounts only
    SELECT t.txn_id, t.payee_account_id, t.txn_ts, a.created_at
    FROM upi.transactions t
    JOIN upi.accounts a ON a.account_id = t.payee_account_id
    WHERE t.status = 'SUCCESS'
      AND a.account_type = 'PERSONAL'
      AND t.txn_ts - a.created_at <= make_interval(days => fraud.param('R06', 'max_account_age_days')::INT)
),
windowed AS (
    SELECT i.*, w.distinct_payers, w.inbound_amount
    FROM inbound i
    CROSS JOIN LATERAL (
        SELECT COUNT(DISTINCT t2.payer_account_id) AS distinct_payers,
               SUM(t2.amount)                      AS inbound_amount
        FROM upi.transactions t2
        WHERE t2.payee_account_id = i.payee_account_id
          AND t2.status = 'SUCCESS'
          AND t2.txn_ts >  i.txn_ts - make_interval(hours => fraud.param('R06', 'window_hours')::INT)
          AND t2.txn_ts <= i.txn_ts
    ) w
),
triggers AS (
    SELECT payee_account_id, txn_ts AS trigger_ts, distinct_payers, inbound_amount, created_at
    FROM windowed
    WHERE distinct_payers >= fraud.param('R06', 'min_distinct_payers')
),
members AS (                    -- every inbound payment inside a breaching window
    SELECT DISTINCT ON (i.txn_id)
        i.txn_id, i.payee_account_id, tr.distinct_payers, tr.inbound_amount, tr.created_at, i.txn_ts
    FROM triggers tr
    JOIN inbound i
      ON  i.payee_account_id = tr.payee_account_id
      AND i.txn_ts >  tr.trigger_ts - make_interval(hours => fraud.param('R06', 'window_hours')::INT)
      AND i.txn_ts <= tr.trigger_ts
    ORDER BY i.txn_id, tr.distinct_payers DESC
)
INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT
    txn_id,
    payee_account_id,           -- the receiving account is the suspect
    'R06',
    jsonb_build_object(
        'distinct_payers_24h',   distinct_payers,
        'inbound_amount_24h',    inbound_amount,
        'account_age_days',      EXTRACT(DAY FROM txn_ts - created_at)
    )
FROM members
WHERE fraud.is_active('R06');

SELECT fraud.log_step('R06', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R06'), :'t0') AS logged \gset
