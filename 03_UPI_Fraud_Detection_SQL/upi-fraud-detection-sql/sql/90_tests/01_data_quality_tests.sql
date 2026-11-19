/* =============================================================================
   01_data_quality_tests.sql
   Run BEFORE the rules. Each block raises an exception (and stops the
   pipeline, because ON_ERROR_STOP is on) if the data is not trustworthy.
   ============================================================================= */
\echo '  data quality tests'

DO $$
DECLARE n BIGINT;
BEGIN
    -- 1. data actually loaded
    SELECT COUNT(*) INTO n FROM upi.transactions;
    ASSERT n > 0, 'DQ01 failed: upi.transactions is empty';

    -- 2. no payment before the payer or payee account existed
    SELECT COUNT(*) INTO n
    FROM upi.transactions t
    JOIN upi.accounts p ON p.account_id = t.payer_account_id
    JOIN upi.accounts r ON r.account_id = t.payee_account_id
    WHERE t.txn_ts < p.created_at OR t.txn_ts < r.created_at;
    ASSERT n = 0, format('DQ02 failed: %s transactions happen before account creation', n);

    -- 3. no duplicate VPAs (also enforced by UNIQUE, kept as a documented test)
    SELECT COUNT(*) - COUNT(DISTINCT vpa) INTO n FROM upi.accounts;
    ASSERT n = 0, format('DQ03 failed: %s duplicate VPAs', n);

    -- 4. merchants never pay (in this dataset only cash-out merchants receive mule money)
    SELECT COUNT(*) INTO n
    FROM upi.transactions t
    JOIN upi.accounts a ON a.account_id = t.payer_account_id
    WHERE a.account_type = 'MERCHANT';
    ASSERT n = 0, format('DQ04 failed: %s payments sent by merchant accounts', n);

    -- 5. P2M payments must go to merchants
    SELECT COUNT(*) INTO n
    FROM upi.transactions t
    JOIN upi.accounts a ON a.account_id = t.payee_account_id
    WHERE t.txn_type = 'P2M' AND a.account_type <> 'MERCHANT';
    ASSERT n = 0, format('DQ05 failed: %s P2M payments to non-merchants', n);

    -- 6. every label points to a real transaction (FK) and labels are a small minority
    SELECT COUNT(*) INTO n FROM eval.fraud_labels;
    ASSERT n BETWEEN 1 AND (SELECT COUNT(*) * 0.05 FROM upi.transactions),
        format('DQ06 failed: unexpected number of fraud labels (%s)', n);

    RAISE NOTICE 'all data quality tests passed';
END $$;
