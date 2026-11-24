/* =============================================================================
   GST Reconciliation Engine  |  07_tests.sql
   Author : Dharmesh Kumar
   Purpose: Automated test suite. Any failure raises an EXCEPTION, so with
            ON_ERROR_STOP the build fails (CI-friendly).

     T01  GSTIN checksum accepts a real-format GSTIN, rejects a typo
     T02  Invoice normalisation treats format variants as equal
     T03  Every books record is classified exactly once
     T04  Every GSTR-2B record is classified exactly once
     T05  Control totals: ITC in results = ITC in source tables
     T06  ITC buckets are never negative
     T07  Every planted junk row was rejected for the planted reason
     T08  Engine status = planted ground truth for every labelled record
   ============================================================================= */

\echo '>> 07_tests: running test suite'

CREATE OR REPLACE FUNCTION qa.assert(p_test text, p_condition boolean, p_detail text DEFAULT '')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'TEST FAILED  %  %', p_test, p_detail;
    END IF;
    RAISE NOTICE 'PASS  %  %', p_test, p_detail;
END;
$$;

-- Scored comparison of engine output vs ground truth (kept as a view so the
-- README / dashboards can show the accuracy table)
CREATE OR REPLACE VIEW qa.v_engine_accuracy AS
WITH actual AS (
    SELECT 'PR'::text AS source, p.voucher_no AS record_key, r.match_status
      FROM gst.recon_result r
      JOIN gst.v_latest_run lr USING (run_id)
      JOIN gst.purchase_register p USING (pr_id)
    UNION ALL
    SELECT '2B', b.supplier_gstin || '|' || b.invoice_no || '|' || b.return_period, r.match_status
      FROM gst.recon_result r
      JOIN gst.v_latest_run lr USING (run_id)
      JOIN gst.gstr2b b USING (b2b_id)
)
SELECT g.expected_status,
       count(*)                                                        AS labelled_records,
       count(*) FILTER (WHERE a.match_status = g.expected_status)      AS correctly_classified,
       round(100.0 * count(*) FILTER (WHERE a.match_status = g.expected_status) / count(*), 2) AS accuracy_pct,
       string_agg(DISTINCT g.scenario, ', ')                           AS planted_scenarios
  FROM qa.ground_truth g
  LEFT JOIN actual a USING (source, record_key)
 WHERE g.source <> 'REJECT'
 GROUP BY g.expected_status
 ORDER BY labelled_records DESC;


DO $$
DECLARE
    v_run  int := (SELECT run_id FROM gst.v_latest_run);
    v_fy   text := (SELECT financial_year FROM gst.v_latest_run);
    v_n    bigint;
    v_m    bigint;
    v_a    numeric;
    v_b    numeric;
BEGIN
    -- T01 --------------------------------------------------------------------
    PERFORM qa.assert('T01a', gst.fn_is_valid_gstin('27AAPFU0939F1ZV'),
                      'known-good GSTIN 27AAPFU0939F1ZV is valid');
    PERFORM qa.assert('T01b', NOT gst.fn_is_valid_gstin('27AAPFU0939F1ZX'),
                      'same GSTIN with wrong check digit is invalid');
    PERFORM qa.assert('T01c', NOT gst.fn_is_valid_gstin('27AAPFU09391ZV'),
                      '14-character GSTIN is invalid');

    -- T02 --------------------------------------------------------------------
    PERFORM qa.assert('T02a',
        gst.fn_normalize_invoice_no('INV/25-26/0012') = gst.fn_normalize_invoice_no(' inv-25-26-12 '),
        'INV/25-26/0012 == inv-25-26-12');
    PERFORM qa.assert('T02b',
        gst.fn_normalize_invoice_no('SB000069') = gst.fn_normalize_invoice_no('sb69'),
        'SB000069 == sb69');
    PERFORM qa.assert('T02c',
        gst.fn_normalize_invoice_no('INV/12') <> gst.fn_normalize_invoice_no('INV/13'),
        'different invoices stay different');

    -- T03 --------------------------------------------------------------------
    SELECT count(*) INTO v_n FROM gst.purchase_register WHERE financial_year = v_fy;
    SELECT count(DISTINCT pr_id) INTO v_m FROM gst.recon_result WHERE run_id = v_run AND pr_id IS NOT NULL;
    PERFORM qa.assert('T03', v_n = v_m, format('%s books records, %s classified', v_n, v_m));

    -- T04 --------------------------------------------------------------------
    SELECT count(*) INTO v_n FROM gst.gstr2b WHERE financial_year = v_fy;
    SELECT count(DISTINCT b2b_id) INTO v_m FROM gst.recon_result WHERE run_id = v_run AND b2b_id IS NOT NULL;
    PERFORM qa.assert('T04', v_n = v_m, format('%s 2B records, %s classified', v_n, v_m));

    -- T05 --------------------------------------------------------------------
    SELECT sum(gst.fn_doc_sign(doc_class) * total_tax) INTO v_a
      FROM gst.purchase_register WHERE financial_year = v_fy;
    SELECT sum(itc_books) INTO v_b FROM gst.recon_result WHERE run_id = v_run;
    PERFORM qa.assert('T05a', v_a = v_b, format('books ITC control total Rs %s', v_a));

    SELECT sum(gst.fn_doc_sign(doc_class) * total_tax) INTO v_a
      FROM gst.gstr2b WHERE financial_year = v_fy AND itc_available;
    SELECT sum(itc_2b) INTO v_b FROM gst.recon_result WHERE run_id = v_run;
    PERFORM qa.assert('T05b', v_a = v_b, format('2B available ITC control total Rs %s', v_a));

    -- T06 --------------------------------------------------------------------
    SELECT count(*) INTO v_n FROM gst.recon_result
     WHERE run_id = v_run AND (itc_at_risk < 0 OR itc_unclaimed < 0 OR itc_reversal < 0);
    PERFORM qa.assert('T06', v_n = 0, 'no negative ITC buckets');

    -- T07 --------------------------------------------------------------------
    SELECT count(*) INTO v_n FROM qa.ground_truth WHERE source = 'REJECT';
    SELECT count(*) INTO v_m
      FROM qa.ground_truth g
      JOIN stg.load_rejects r ON r.record_key = g.record_key AND r.reject_reason = g.scenario
     WHERE g.source = 'REJECT';
    PERFORM qa.assert('T07', v_n = v_m AND v_n > 0,
                      format('%s of %s junk rows rejected with the expected reason', v_m, v_n));

    -- T08 --------------------------------------------------------------------
    SELECT sum(labelled_records), sum(correctly_classified) INTO v_n, v_m FROM qa.v_engine_accuracy;
    PERFORM qa.assert('T08', v_n = v_m,
                      format('%s of %s labelled records classified correctly (%s%%)',
                             v_m, v_n, round(100.0 * v_m / v_n, 2)));
END;
$$;

\echo ''
\echo '================ ENGINE ACCURACY vs GROUND TRUTH ================'
SELECT * FROM qa.v_engine_accuracy;
