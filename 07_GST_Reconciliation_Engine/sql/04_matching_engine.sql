/* =============================================================================
   GST Reconciliation Engine  |  04_matching_engine.sql
   Author : Dharmesh Kumar
   Purpose: Multi-pass reconciliation of the purchase register (books) against
            GSTR-2B for one financial year.

   PASS 0  DUPLICATE   - same supplier + normalised invoice booked twice
   PASS 1  EXACT KEY   - GSTIN + normalised invoice no. + document class,
                         then classified by amount / tax head / date / period
   PASS 2  FUZZY INVNO - same GSTIN, invoice no. within edit distance,
                         amount within tolerance, date within window
   PASS 3  GSTIN FIX   - same invoice no. + amount, GSTIN within edit distance
   PASS 4  LEFTOVERS   - MISSING_IN_2B / MISSING_IN_BOOKS / CREDIT_NOTE_NOT_BOOKED
   POST    ELIGIBILITY - matched pairs where 2B says ITC unavailable
   VALUE   ITC IMPACT  - diffs, ITC at risk / unclaimed / to reverse

   Every pass pairs records ONE-TO-ONE using "mutual best match": a pair is
   accepted only when each side ranks the other as its best candidate.
   Unique partial indexes on gst.recon_result enforce this physically.

   Usage:  CALL gst.run_reconciliation('2025-26', 'monthly close');
   ============================================================================= */

\echo '>> 04_matching_engine: creating gst.run_reconciliation()'

CREATE OR REPLACE PROCEDURE gst.run_reconciliation(
    p_fy      text DEFAULT '2025-26',
    p_notes   text DEFAULT NULL,
    INOUT p_run_id int DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tol    numeric;
    v_edit   int;
    v_sim    numeric;
    v_window int;
    v_gedit  int;
    v_rows   int;
    v_t0     timestamptz;
    v_log    jsonb := '[]'::jsonb;
    v_left_pr  int;
    v_left_2b  int;
BEGIN
    -------------------------------------------------------------------------
    -- Settings
    -------------------------------------------------------------------------
    SELECT max(config_value) FILTER (WHERE config_key = 'amount_tolerance')::numeric,
           max(config_value) FILTER (WHERE config_key = 'fuzzy_max_edit_distance')::int,
           max(config_value) FILTER (WHERE config_key = 'fuzzy_min_similarity')::numeric,
           max(config_value) FILTER (WHERE config_key = 'fuzzy_date_window_days')::int,
           max(config_value) FILTER (WHERE config_key = 'gstin_max_edit_distance')::int
      INTO v_tol, v_edit, v_sim, v_window, v_gedit
      FROM gst.recon_config;

    INSERT INTO gst.recon_run (financial_year, notes, config_snapshot)
    VALUES (p_fy, p_notes,
            (SELECT jsonb_object_agg(config_key, config_value) FROM gst.recon_config))
    RETURNING run_id INTO p_run_id;

    RAISE NOTICE 'Run % started for FY % (tolerance Rs %, edit distance %, window % days)',
                 p_run_id, p_fy, v_tol, v_edit, v_window;

    -------------------------------------------------------------------------
    -- Working sets: everything still unmatched lives here
    -------------------------------------------------------------------------
    IF to_regclass('pg_temp._pr') IS NOT NULL THEN DROP TABLE _pr; END IF;
    IF to_regclass('pg_temp._2b') IS NOT NULL THEN DROP TABLE _2b; END IF;

    CREATE TEMP TABLE _pr AS
    SELECT pr_id, voucher_no, booking_date, supplier_gstin, invoice_no, invoice_no_norm,
           invoice_date, doc_class, taxable_value, igst, total_tax, invoice_value,
           itc_claim_period, gstin_is_valid
      FROM gst.purchase_register
     WHERE financial_year = p_fy;

    CREATE TEMP TABLE _2b AS
    SELECT b2b_id, return_period, supplier_gstin, invoice_no, invoice_no_norm, invoice_date,
           doc_class, taxable_value, igst, total_tax, invoice_value
      FROM gst.gstr2b
     WHERE financial_year = p_fy;

    CREATE INDEX ON _pr (supplier_gstin, invoice_no_norm);
    CREATE INDEX ON _pr (invoice_no_norm);
    CREATE INDEX ON _2b (supplier_gstin, invoice_no_norm);
    CREATE INDEX ON _2b (invoice_no_norm);
    ANALYZE _pr;
    ANALYZE _2b;

    UPDATE gst.recon_run
       SET pr_records  = (SELECT count(*) FROM _pr),
           b2b_records = (SELECT count(*) FROM _2b)
     WHERE run_id = p_run_id;

    -------------------------------------------------------------------------
    -- PASS 0: duplicates inside the books
    -- The first booking (by booking date, then voucher) is the original;
    -- every later booking of the same supplier invoice is a duplicate.
    -------------------------------------------------------------------------
    v_t0 := clock_timestamp();

    INSERT INTO gst.recon_result (run_id, pr_id, match_pass, match_status, remarks)
    SELECT p_run_id, pr_id, 'P0_DUPLICATE', 'DUPLICATE_IN_BOOKS',
           format('Duplicate of voucher %s (invoice %s)', original_voucher, original_invoice_no)
      FROM (SELECT pr_id,
                   row_number()  OVER w AS booking_rank,
                   first_value(voucher_no) OVER w AS original_voucher,
                   first_value(invoice_no) OVER w AS original_invoice_no
              FROM _pr
            WINDOW w AS (PARTITION BY supplier_gstin, invoice_no_norm, doc_class
                         ORDER BY booking_date, voucher_no)) d
     WHERE booking_rank > 1;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    DELETE FROM _pr WHERE pr_id IN (SELECT pr_id FROM gst.recon_result WHERE run_id = p_run_id);
    v_log := v_log || jsonb_build_object('pass', 'P0_DUPLICATE', 'rows', v_rows,
                 'ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
    RAISE NOTICE '  P0 duplicates      : % rows', v_rows;

    -------------------------------------------------------------------------
    -- PASS 1: exact key  (GSTIN + normalised invoice no. + document class)
    -- Pairing is exact; the status explains HOW the pair differs.
    -------------------------------------------------------------------------
    v_t0 := clock_timestamp();

    WITH candidates AS (
        SELECT p.pr_id, b.b2b_id,
               CASE
                 WHEN abs(p.total_tax - b.total_tax) <= v_tol
                  AND (p.igst > 0) <> (b.igst > 0)                        THEN 'MISMATCH_TAX_HEAD'
                 WHEN abs(p.taxable_value - b.taxable_value) > v_tol
                   OR abs(p.total_tax - b.total_tax) > v_tol              THEN 'MISMATCH_VALUE'
                 WHEN p.itc_claim_period <> b.return_period               THEN 'MATCHED_CROSS_PERIOD'
                 WHEN p.invoice_date <> b.invoice_date                    THEN 'MATCHED_DATE_DIFF'
                 WHEN p.taxable_value <> b.taxable_value
                   OR p.total_tax <> b.total_tax                          THEN 'MATCHED_TOLERANCE'
                 ELSE 'MATCHED'
               END AS match_status,
               CASE WHEN p.itc_claim_period <> b.return_period
                    THEN format('Books period %s, 2B period %s', p.itc_claim_period, b.return_period)
               END AS remarks,
               row_number() OVER (PARTITION BY p.pr_id
                                  ORDER BY abs(p.invoice_value - b.invoice_value),
                                           abs(p.invoice_date - b.invoice_date), b.b2b_id) AS rank_for_pr,
               row_number() OVER (PARTITION BY b.b2b_id
                                  ORDER BY abs(p.invoice_value - b.invoice_value),
                                           abs(p.invoice_date - b.invoice_date), p.pr_id)  AS rank_for_2b
          FROM _pr p
          JOIN _2b b
            ON b.supplier_gstin  = p.supplier_gstin
           AND b.invoice_no_norm = p.invoice_no_norm
           AND b.doc_class       = p.doc_class
    )
    INSERT INTO gst.recon_result (run_id, pr_id, b2b_id, match_pass, match_status, match_score, remarks)
    SELECT p_run_id, pr_id, b2b_id, 'P1_EXACT_KEY', match_status, 1.0, remarks
      FROM candidates
     WHERE rank_for_pr = 1 AND rank_for_2b = 1;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    DELETE FROM _pr WHERE pr_id  IN (SELECT pr_id  FROM gst.recon_result WHERE run_id = p_run_id AND pr_id  IS NOT NULL);
    DELETE FROM _2b WHERE b2b_id IN (SELECT b2b_id FROM gst.recon_result WHERE run_id = p_run_id AND b2b_id IS NOT NULL);
    v_log := v_log || jsonb_build_object('pass', 'P1_EXACT_KEY', 'rows', v_rows,
                 'ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
    RAISE NOTICE '  P1 exact key       : % pairs', v_rows;

    -------------------------------------------------------------------------
    -- PASS 2: fuzzy invoice number (typos)
    -- Sequential invoice numbers of one supplier differ by a single digit,
    -- so edit distance alone is dangerous. A candidate must ALSO agree on
    -- value (within tolerance) and date (within window).
    -------------------------------------------------------------------------
    v_t0 := clock_timestamp();

    WITH candidates AS (
        SELECT p.pr_id, b.b2b_id, p.invoice_no AS books_inv, b.invoice_no AS b2b_inv,
               levenshtein(p.invoice_no_norm, b.invoice_no_norm)      AS edit_distance,
               similarity(p.invoice_no_norm, b.invoice_no_norm)       AS trigram_sim,
               greatest(length(p.invoice_no_norm), length(b.invoice_no_norm)) AS max_len
          FROM _pr p
          JOIN _2b b
            ON b.supplier_gstin = p.supplier_gstin
           AND b.doc_class      = p.doc_class
           AND abs(p.invoice_value - b.invoice_value) <= v_tol
           AND abs(p.invoice_date  - b.invoice_date)  <= v_window
         WHERE levenshtein(p.invoice_no_norm, b.invoice_no_norm) BETWEEN 1 AND v_edit
           AND similarity(p.invoice_no_norm, b.invoice_no_norm) >= v_sim
    ), scored AS (
        SELECT *,
               round(0.5 * (1 - edit_distance::numeric / max_len) + 0.5 * trigram_sim::numeric, 4) AS score
          FROM candidates
    ), ranked AS (
        SELECT *,
               row_number() OVER (PARTITION BY pr_id  ORDER BY score DESC, b2b_id) AS rank_for_pr,
               row_number() OVER (PARTITION BY b2b_id ORDER BY score DESC, pr_id)  AS rank_for_2b
          FROM scored
    )
    INSERT INTO gst.recon_result (run_id, pr_id, b2b_id, match_pass, match_status, match_score, remarks)
    SELECT p_run_id, pr_id, b2b_id, 'P2_FUZZY_INVNO', 'MATCHED_FUZZY_INVNO', score,
           format('Books invoice "%s" vs supplier "%s" (edit distance %s)', books_inv, b2b_inv, edit_distance)
      FROM ranked
     WHERE rank_for_pr = 1 AND rank_for_2b = 1;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    DELETE FROM _pr WHERE pr_id  IN (SELECT pr_id  FROM gst.recon_result WHERE run_id = p_run_id AND pr_id  IS NOT NULL);
    DELETE FROM _2b WHERE b2b_id IN (SELECT b2b_id FROM gst.recon_result WHERE run_id = p_run_id AND b2b_id IS NOT NULL);
    v_log := v_log || jsonb_build_object('pass', 'P2_FUZZY_INVNO', 'rows', v_rows,
                 'ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
    RAISE NOTICE '  P2 fuzzy invoice # : % pairs', v_rows;

    -------------------------------------------------------------------------
    -- PASS 3: GSTIN typo in books
    -- Same invoice + same value, GSTIN within a small edit distance.
    -------------------------------------------------------------------------
    v_t0 := clock_timestamp();

    WITH candidates AS (
        SELECT p.pr_id, b.b2b_id, p.supplier_gstin AS books_gstin, b.supplier_gstin AS b2b_gstin,
               p.gstin_is_valid,
               levenshtein(p.supplier_gstin, b.supplier_gstin) AS edit_distance
          FROM _pr p
          JOIN _2b b
            ON b.invoice_no_norm = p.invoice_no_norm
           AND b.doc_class       = p.doc_class
           AND b.supplier_gstin <> p.supplier_gstin
           AND abs(p.invoice_value - b.invoice_value) <= v_tol
         WHERE levenshtein(p.supplier_gstin, b.supplier_gstin) <= v_gedit
    ), ranked AS (
        SELECT *,
               row_number() OVER (PARTITION BY pr_id  ORDER BY edit_distance, b2b_id) AS rank_for_pr,
               row_number() OVER (PARTITION BY b2b_id ORDER BY edit_distance, pr_id)  AS rank_for_2b
          FROM candidates
    )
    INSERT INTO gst.recon_result (run_id, pr_id, b2b_id, match_pass, match_status, match_score, remarks)
    SELECT p_run_id, pr_id, b2b_id, 'P3_GSTIN_FIX', 'MATCHED_GSTIN_CORRECTION',
           round(1 - edit_distance / 15.0, 4),
           format('Books GSTIN %s (%s) should be %s', books_gstin,
                  CASE WHEN gstin_is_valid THEN 'valid checksum' ELSE 'checksum FAILS' END, b2b_gstin)
      FROM ranked
     WHERE rank_for_pr = 1 AND rank_for_2b = 1;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    DELETE FROM _pr WHERE pr_id  IN (SELECT pr_id  FROM gst.recon_result WHERE run_id = p_run_id AND pr_id  IS NOT NULL);
    DELETE FROM _2b WHERE b2b_id IN (SELECT b2b_id FROM gst.recon_result WHERE run_id = p_run_id AND b2b_id IS NOT NULL);
    v_log := v_log || jsonb_build_object('pass', 'P3_GSTIN_FIX', 'rows', v_rows,
                 'ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
    RAISE NOTICE '  P3 GSTIN correction: % pairs', v_rows;

    -------------------------------------------------------------------------
    -- PASS 4: whatever is left has no counterpart
    -------------------------------------------------------------------------
    v_t0 := clock_timestamp();

    INSERT INTO gst.recon_result (run_id, pr_id, match_pass, match_status, remarks)
    SELECT p_run_id, pr_id, 'P4_UNMATCHED', 'MISSING_IN_2B',
           CASE WHEN NOT gstin_is_valid THEN 'Supplier GSTIN in books fails checksum' END
      FROM _pr;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_left_pr := v_rows;

    INSERT INTO gst.recon_result (run_id, b2b_id, match_pass, match_status)
    SELECT p_run_id, b2b_id, 'P4_UNMATCHED',
           CASE doc_class WHEN 'CRN' THEN 'CREDIT_NOTE_NOT_BOOKED' ELSE 'MISSING_IN_BOOKS' END
      FROM _2b;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_left_2b := v_rows;

    v_log := v_log || jsonb_build_object('pass', 'P4_UNMATCHED', 'rows', v_left_pr + v_left_2b,
                 'ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
    RAISE NOTICE '  P4 unmatched       : % books-only, % 2B-only', v_left_pr, v_left_2b;

    -------------------------------------------------------------------------
    -- POST: ITC eligibility. A perfect match is still worthless if GSTR-2B
    -- flags the ITC as unavailable (e.g. place-of-supply rule, Sec 16(4)).
    -------------------------------------------------------------------------
    UPDATE gst.recon_result r
       SET match_status = 'ITC_INELIGIBLE',
           remarks      = concat_ws('; ', r.remarks,
                                    format('Paired as %s; 2B reason: %s', r.match_status, b.itc_unavailable_reason))
      FROM gst.gstr2b b
     WHERE r.run_id = p_run_id
       AND r.b2b_id = b.b2b_id
       AND r.pr_id IS NOT NULL
       AND NOT b.itc_available;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_log := v_log || jsonb_build_object('pass', 'POST_ELIGIBILITY', 'rows', v_rows);
    RAISE NOTICE '  POST ineligible ITC: % pairs re-flagged', v_rows;

    -------------------------------------------------------------------------
    -- VALUATION: one place that turns a status into rupees.
    -------------------------------------------------------------------------
    UPDATE gst.recon_result r
       SET taxable_diff   = v.taxable_diff,
           tax_diff       = v.tax_diff,
           date_diff_days = v.date_diff_days,
           itc_books      = v.itc_books,
           itc_2b         = v.itc_2b,
           itc_at_risk    = CASE
                              WHEN r.match_status IN ('MISSING_IN_2B','MISMATCH_TAX_HEAD','ITC_INELIGIBLE')
                                   THEN greatest(v.itc_books, 0)
                              WHEN r.match_status = 'MISMATCH_VALUE'
                                   THEN greatest(v.itc_books - v.itc_2b, 0)
                              ELSE 0 END,
           itc_unclaimed  = CASE
                              WHEN r.match_status = 'MISSING_IN_BOOKS' THEN greatest(v.itc_2b, 0)
                              WHEN r.match_status = 'MISMATCH_VALUE'   THEN greatest(v.itc_2b - v.itc_books, 0)
                              ELSE 0 END,
           itc_reversal   = CASE
                              WHEN r.match_status = 'DUPLICATE_IN_BOOKS'     THEN greatest(v.itc_books, 0)
                              WHEN r.match_status = 'CREDIT_NOTE_NOT_BOOKED' THEN abs(v.itc_2b)
                              ELSE 0 END
      FROM (SELECT x.result_id,
                   p.taxable_value - b.taxable_value                                   AS taxable_diff,
                   p.total_tax     - b.total_tax                                       AS tax_diff,
                   p.invoice_date  - b.invoice_date                                    AS date_diff_days,
                   coalesce(gst.fn_doc_sign(p.doc_class) * p.total_tax, 0)             AS itc_books,
                   coalesce(CASE WHEN b.itc_available
                                 THEN gst.fn_doc_sign(b.doc_class) * b.total_tax END, 0) AS itc_2b
              FROM gst.recon_result x
              LEFT JOIN gst.purchase_register p ON p.pr_id  = x.pr_id
              LEFT JOIN gst.gstr2b            b ON b.b2b_id = x.b2b_id
             WHERE x.run_id = p_run_id) v
     WHERE r.result_id = v.result_id;

    -------------------------------------------------------------------------
    -- Close the run
    -------------------------------------------------------------------------
    UPDATE gst.recon_run
       SET finished_at = clock_timestamp(),
           result_rows = (SELECT count(*) FROM gst.recon_result WHERE run_id = p_run_id),
           pass_log    = v_log
     WHERE run_id = p_run_id;

    DROP TABLE _pr;
    DROP TABLE _2b;

    RAISE NOTICE 'Run % finished.', p_run_id;
END;
$$;

COMMENT ON PROCEDURE gst.run_reconciliation(text, text, int) IS
'Multi-pass GSTR-2B vs purchase-register reconciliation. Returns the new run_id.';


-- Convenience: always point reports at the latest run
CREATE OR REPLACE VIEW gst.v_latest_run AS
SELECT * FROM gst.recon_run ORDER BY run_id DESC LIMIT 1;


\echo '>> 04_matching_engine: executing reconciliation for FY 2025-26'
CALL gst.run_reconciliation('2025-26', 'Initial full-year reconciliation');

SELECT run_id, financial_year, pr_records, b2b_records, result_rows,
       round(extract(epoch FROM finished_at - started_at)::numeric, 2) AS seconds,
       jsonb_pretty(pass_log) AS pass_log
  FROM gst.v_latest_run;
