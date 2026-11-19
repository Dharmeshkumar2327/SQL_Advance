/* =============================================================================
   02_engine_tests.sql
   Regression tests for the detection engine. If someone changes a rule and
   breaks it, the pipeline (and the GitHub Actions CI) fails here.
   ============================================================================= */
\echo '  engine tests'

DO $$
DECLARE
    n   BIGINT;
    r   RECORD;
    m   RECORD;
BEGIN
    -- E01. every active rule produced at least one hit
    FOR r IN SELECT rule_code FROM fraud.rule_config WHERE is_active LOOP
        SELECT COUNT(*) INTO n FROM fraud.rule_hits WHERE rule_code = r.rule_code;
        ASSERT n > 0, format('E01 failed: rule %s produced no hits', r.rule_code);
    END LOOP;

    -- E02. scores are within 0-100 and every score maps to exactly one band
    SELECT COUNT(*) INTO n FROM fraud.txn_risk_scores WHERE risk_score NOT BETWEEN 0 AND 100;
    ASSERT n = 0, format('E02 failed: %s scores outside 0-100', n);
    SELECT COUNT(*) INTO n FROM fraud.txn_risk_scores s
    WHERE (SELECT COUNT(*) FROM fraud.risk_bands b WHERE s.risk_score BETWEEN b.min_score AND b.max_score) <> 1;
    ASSERT n = 0, format('E02 failed: %s scores map to 0 or >1 bands', n);

    -- E03. no orphan hits
    SELECT COUNT(*) INTO n FROM fraud.rule_hits h
    LEFT JOIN upi.transactions t USING (txn_id) WHERE t.txn_id IS NULL;
    ASSERT n = 0, format('E03 failed: %s rule hits reference missing transactions', n);

    -- E04. rules only fire on successful payments (failed ones move no money)
    SELECT COUNT(*) INTO n FROM fraud.rule_hits h
    JOIN upi.transactions t USING (txn_id) WHERE t.status <> 'SUCCESS';
    ASSERT n = 0, format('E04 failed: %s hits on failed transactions', n);

    -- E05. every mule chain has at least min_chain_txns hops
    SELECT COUNT(*) INTO n FROM fraud.mule_chains
    WHERE chain_txns < fraud.param('R03', 'min_chain_txns');
    ASSERT n = 0, format('E05 failed: %s mule-chain rows shorter than minimum', n);

    -- E06. quality gates on the synthetic benchmark
    SELECT * INTO m FROM eval.overall_metrics;
    ASSERT m.recall    >= 0.80, format('E06 failed: overall recall %s < 0.80', m.recall);
    ASSERT m.precision >= 0.60, format('E06 failed: overall precision %s < 0.60', m.precision);

    -- E07. each planted pattern is caught at least 70% of the time
    FOR r IN SELECT fraud_pattern, recall FROM eval.pattern_coverage LOOP
        ASSERT r.recall >= 0.70, format('E07 failed: %s recall only %s', r.fraud_pattern, r.recall);
    END LOOP;

    RAISE NOTICE 'all engine tests passed';
END $$;

\echo '  all engine tests passed'
