/* =============================================================================
   R05 - STRUCTURING (SMURFING)
   Pattern : instead of one Rs 50,000 payment that would be reviewed, the
             fraudster sends five payments of Rs 9,900 on the same day.
   Logic   : filter payments inside the "just below threshold" band, GROUP BY
             payer + calendar day, keep days with HAVING COUNT(*) >= n, then
             flag every payment of those days.
   SQL     : GROUP BY / HAVING, date truncation, join back to detail rows
   ============================================================================= */
\echo '  R05 structuring'
SELECT clock_timestamp()::timestamp AS t0 \gset

DELETE FROM fraud.rule_hits WHERE rule_code = 'R05';

WITH band AS (
    SELECT t.txn_id, t.payer_account_id, t.payee_account_id, t.amount, t.txn_ts::DATE AS txn_date
    FROM upi.transactions t
    WHERE t.status = 'SUCCESS'
      AND t.amount >= fraud.param('R05', 'band_lower')
      AND t.amount <  fraud.param('R05', 'band_upper')
),
suspicious_days AS (
    SELECT
        payer_account_id,
        txn_date,
        COUNT(*)                         AS band_txns,
        COUNT(DISTINCT payee_account_id) AS distinct_payees,
        SUM(amount)                      AS band_total
    FROM band
    GROUP BY payer_account_id, txn_date
    HAVING COUNT(*) >= fraud.param('R05', 'min_txns_per_day')
)
INSERT INTO fraud.rule_hits (txn_id, account_id, rule_code, evidence)
SELECT
    b.txn_id,
    b.payer_account_id,
    'R05',
    jsonb_build_object(
        'txn_date',        d.txn_date,
        'band_txns',       d.band_txns,
        'distinct_payees', d.distinct_payees,
        'band_total',      d.band_total,
        'band',            fraud.param('R05', 'band_lower') || ' - ' || fraud.param('R05', 'band_upper')
    )
FROM band b
JOIN suspicious_days d USING (payer_account_id, txn_date)
WHERE fraud.is_active('R05');

SELECT fraud.log_step('R05', (SELECT COUNT(*) FROM fraud.rule_hits WHERE rule_code = 'R05'), :'t0') AS logged \gset
