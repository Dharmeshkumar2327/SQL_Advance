/* =============================================================================
   GST Reconciliation Engine  |  05_reports.sql
   Author : Dharmesh Kumar
   Purpose: Business-facing reporting views. All views read the LATEST run.

     v_recon_detail          one row per reconciled record, human readable
     v_recon_summary         status-wise counts and ITC impact, with total row
     v_monthly_itc_bridge    month-wise books vs 2B ITC with running gap
     v_vendor_scorecard      supplier compliance score, grade and risk rank
     v_vendor_followup       ready-to-send follow-up note per problem supplier
     v_itc_deadline_tracker  Section 16(4) countdown for unsupported ITC
     v_unclaimed_itc         ITC sitting in 2B that the books never claimed
   ============================================================================= */

\echo '>> 05_reports: creating reporting views'

/* -----------------------------------------------------------------------------
   1. Detail
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW gst.v_recon_detail AS
SELECT r.result_id,
       r.run_id,
       r.match_status,
       sc.status_group,
       sc.severity,
       r.match_pass,
       r.match_score,
       coalesce(b.supplier_gstin, p.supplier_gstin)                    AS supplier_gstin,
       coalesce(s.trade_name, b.trade_name, p.supplier_name)           AS supplier_name,
       p.voucher_no,
       p.invoice_no                                                    AS books_invoice_no,
       b.invoice_no                                                    AS b2b_invoice_no,
       coalesce(p.invoice_date, b.invoice_date)                        AS invoice_date,
       p.itc_claim_period                                              AS books_period,
       b.return_period                                                 AS b2b_period,
       coalesce(p.doc_class, b.doc_class)                              AS doc_class,
       p.taxable_value                                                 AS books_taxable,
       b.taxable_value                                                 AS b2b_taxable,
       r.taxable_diff, r.tax_diff, r.date_diff_days,
       r.itc_books, r.itc_2b, r.itc_at_risk, r.itc_unclaimed, r.itc_reversal,
       sc.recommended_action,
       r.remarks
  FROM gst.recon_result r
  JOIN gst.v_latest_run    lr ON lr.run_id = r.run_id
  JOIN gst.status_catalog  sc ON sc.match_status = r.match_status
  LEFT JOIN gst.purchase_register p ON p.pr_id  = r.pr_id
  LEFT JOIN gst.gstr2b            b ON b.b2b_id = r.b2b_id
  LEFT JOIN gst.supplier          s ON s.gstin  = coalesce(b.supplier_gstin, p.supplier_gstin);


/* -----------------------------------------------------------------------------
   2. Summary  (ROLLUP adds the grand-total row; window gives % share)
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW gst.v_recon_summary AS
WITH agg AS (
    SELECT status_group, match_status,
           grouping(status_group, match_status)           AS grp,
           count(*)                                       AS records,
           sum(itc_books)                                 AS itc_books,
           sum(itc_2b)                                    AS itc_2b,
           sum(itc_at_risk)                               AS itc_at_risk,
           sum(itc_unclaimed)                             AS itc_unclaimed,
           sum(itc_reversal)                              AS itc_reversal,
           min(severity)                                  AS severity
      FROM gst.v_recon_detail
     GROUP BY ROLLUP (status_group, match_status)
)
SELECT CASE grp WHEN 3 THEN 'TOTAL' ELSE status_group END                 AS status_group,
       CASE grp WHEN 0 THEN match_status WHEN 1 THEN '(subtotal)' ELSE '' END AS match_status,
       records,
       round(100.0 * records / max(records) FILTER (WHERE grp = 3) OVER (), 2) AS pct_records,
       itc_books, itc_2b, itc_at_risk, itc_unclaimed, itc_reversal
  FROM agg
 ORDER BY CASE grp WHEN 3 THEN 2 ELSE 1 END,
          array_position(ARRAY['MATCHED','TIMING','MISMATCH','MISSING','COMPLIANCE'], status_group),
          grp, severity, match_status;


/* -----------------------------------------------------------------------------
   3. Monthly ITC bridge
   ITC claimed in books (by claim period) vs ITC available in 2B (by return
   period), plus a running cumulative gap - the number a CFO asks for.
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW gst.v_monthly_itc_bridge AS
WITH books AS (
    SELECT p.itc_claim_period AS period,
           sum(gst.fn_doc_sign(p.doc_class) * p.total_tax) AS itc_claimed_books
      FROM gst.purchase_register p
     WHERE p.financial_year = (SELECT financial_year FROM gst.v_latest_run)
     GROUP BY 1
), twob AS (
    SELECT b.return_period AS period,
           sum(gst.fn_doc_sign(b.doc_class) * b.total_tax) FILTER (WHERE b.itc_available) AS itc_available_2b,
           sum(b.total_tax) FILTER (WHERE NOT b.itc_available)                            AS itc_blocked_2b
      FROM gst.gstr2b b
     WHERE b.financial_year = (SELECT financial_year FROM gst.v_latest_run)
     GROUP BY 1
), risk AS (
    SELECT books_period AS period,
           sum(itc_at_risk) AS itc_at_risk
      FROM gst.v_recon_detail
     WHERE books_period IS NOT NULL
     GROUP BY 1
)
SELECT period,
       coalesce(itc_claimed_books, 0)                                   AS itc_claimed_books,
       coalesce(itc_available_2b, 0)                                    AS itc_available_2b,
       coalesce(itc_blocked_2b, 0)                                      AS itc_blocked_2b,
       coalesce(itc_claimed_books, 0) - coalesce(itc_available_2b, 0)   AS monthly_gap,
       sum(coalesce(itc_claimed_books, 0) - coalesce(itc_available_2b, 0))
           OVER (ORDER BY period ROWS UNBOUNDED PRECEDING)              AS cumulative_gap,
       coalesce(itc_at_risk, 0)                                         AS itc_at_risk
  FROM books
  FULL JOIN twob USING (period)
  LEFT JOIN risk USING (period)
 ORDER BY period;


/* -----------------------------------------------------------------------------
   4. Vendor compliance scorecard
   Score (0-100) = 50% clean-match rate + 30% ITC-at-risk share + 20% filing
   punctuality. NTILE gives risk quartiles; DENSE_RANK orders by rupees at risk.
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW gst.v_vendor_scorecard AS
WITH per_vendor AS (
    SELECT d.supplier_gstin,
           max(d.supplier_name)                                                   AS supplier_name,
           count(*)                                                               AS records,
           count(*) FILTER (WHERE d.status_group = 'MATCHED' AND d.severity = 0)  AS clean_matches,
           count(*) FILTER (WHERE d.status_group IN ('MISMATCH','MISSING','COMPLIANCE')) AS problem_records,
           count(*) FILTER (WHERE d.match_status = 'MISSING_IN_2B')               AS missing_in_2b,
           count(*) FILTER (WHERE d.match_status = 'MATCHED_CROSS_PERIOD')        AS late_reported,
           sum(greatest(d.itc_books, 0))                                          AS itc_books,
           sum(d.itc_at_risk)                                                     AS itc_at_risk
      FROM gst.v_recon_detail d
     GROUP BY d.supplier_gstin
), filing AS (
    SELECT supplier_gstin,
           round(avg(gstr1_filing_date - gst.fn_gstr1_due_date(return_period)), 1)  AS avg_filing_delay_days,
           round(100.0 * avg((gstr1_filing_date <= gst.fn_gstr1_due_date(return_period))::int), 1) AS on_time_filing_pct
      FROM gst.gstr2b
     GROUP BY supplier_gstin
), scored AS (
    SELECT v.*, f.avg_filing_delay_days, f.on_time_filing_pct,
           round(100.0 * v.clean_matches / v.records, 1)                         AS clean_match_pct,
           round(100.0 * v.itc_at_risk / nullif(v.itc_books, 0), 2)              AS itc_at_risk_pct,
           round(  50 * v.clean_matches::numeric / v.records
                 + 30 * (1 - least(coalesce(v.itc_at_risk / nullif(v.itc_books, 0), 0), 1))
                 + 20 * coalesce(f.on_time_filing_pct, 0) / 100, 1)              AS compliance_score
      FROM per_vendor v
      LEFT JOIN filing f USING (supplier_gstin)
)
SELECT supplier_gstin, supplier_name, records, clean_match_pct, problem_records,
       missing_in_2b, late_reported, itc_books, itc_at_risk, itc_at_risk_pct,
       avg_filing_delay_days, on_time_filing_pct, compliance_score,
       CASE WHEN compliance_score >= 85 THEN 'A'
            WHEN compliance_score >= 70 THEN 'B'
            WHEN compliance_score >= 55 THEN 'C'
            ELSE 'D' END                                                          AS grade,
       ntile(4) OVER (ORDER BY compliance_score DESC)                             AS risk_quartile,
       dense_rank() OVER (ORDER BY itc_at_risk DESC)                              AS rank_by_itc_at_risk
  FROM scored
 ORDER BY compliance_score, itc_at_risk DESC;


/* -----------------------------------------------------------------------------
   5. Vendor follow-up: one ready-to-send note per supplier with open issues
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW gst.v_vendor_followup AS
SELECT d.supplier_gstin,
       max(d.supplier_name)                                       AS supplier_name,
       count(*)                                                   AS open_items,
       sum(d.itc_at_risk)                                         AS itc_at_risk,
       string_agg(format('%s %s dt %s (%s)',
                         CASE d.match_status WHEN 'MISSING_IN_2B' THEN 'Not in your GSTR-1:'
                                             WHEN 'MISMATCH_VALUE' THEN 'Value differs:'
                                             ELSE 'Wrong tax head:' END,
                         d.books_invoice_no, to_char(d.invoice_date, 'DD-Mon-YYYY'),
                         to_char(d.itc_at_risk, 'FM99,99,99,990.00')),
                  E'\n' ORDER BY d.invoice_date)                  AS invoice_list,
       format(E'Dear %s,\n\nOur GSTR-2B reconciliation shows %s invoice(s) where your GSTR-1 does '
              'not match our records, affecting input tax credit of Rs %s. Please file / amend '
              'GSTR-1 for the items below at the earliest.\n\n%s\n\nRegards,\nAccounts Payable',
              max(d.supplier_name), count(*),
              to_char(sum(d.itc_at_risk), 'FM99,99,99,990.00'),
              string_agg(format('- %s dated %s', d.books_invoice_no, to_char(d.invoice_date, 'DD-Mon-YYYY')),
                         E'\n' ORDER BY d.invoice_date))          AS draft_message
  FROM gst.v_recon_detail d
 WHERE d.match_status IN ('MISSING_IN_2B', 'MISMATCH_VALUE', 'MISMATCH_TAX_HEAD')
 GROUP BY d.supplier_gstin
 ORDER BY itc_at_risk DESC;


/* -----------------------------------------------------------------------------
   6. Section 16(4) deadline tracker for unsupported ITC, with ageing buckets
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW gst.v_itc_deadline_tracker AS
WITH cfg AS (
    SELECT config_value::date AS as_of FROM gst.recon_config WHERE config_key = 'as_of_date'
)
SELECT d.supplier_gstin, d.supplier_name, d.voucher_no, d.books_invoice_no,
       d.invoice_date, d.match_status, d.itc_at_risk,
       cfg.as_of - d.invoice_date                                       AS age_days,
       CASE WHEN cfg.as_of - d.invoice_date <= 90  THEN '0-90 days'
            WHEN cfg.as_of - d.invoice_date <= 180 THEN '91-180 days'
            WHEN cfg.as_of - d.invoice_date <= 365 THEN '181-365 days'
            ELSE '365+ days' END                                        AS ageing_bucket,
       gst.fn_itc_claim_deadline(d.invoice_date)                        AS sec16_4_deadline,
       gst.fn_itc_claim_deadline(d.invoice_date) - cfg.as_of            AS days_to_deadline,
       CASE WHEN gst.fn_itc_claim_deadline(d.invoice_date) < cfg.as_of  THEN 'LAPSED'
            WHEN gst.fn_itc_claim_deadline(d.invoice_date) - cfg.as_of <= 30 THEN 'URGENT'
            ELSE 'OPEN' END                                             AS deadline_status
  FROM gst.v_recon_detail d CROSS JOIN cfg
 WHERE d.itc_at_risk > 0
 ORDER BY days_to_deadline, d.itc_at_risk DESC;


/* -----------------------------------------------------------------------------
   7. Unclaimed ITC: money the company is entitled to but has not claimed
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW gst.v_unclaimed_itc AS
WITH cfg AS (
    SELECT config_value::date AS as_of FROM gst.recon_config WHERE config_key = 'as_of_date'
)
SELECT d.supplier_gstin, d.supplier_name, d.b2b_invoice_no, d.invoice_date, d.b2b_period,
       d.b2b_taxable, d.itc_unclaimed,
       gst.fn_itc_claim_deadline(d.invoice_date)               AS claim_by,
       gst.fn_itc_claim_deadline(d.invoice_date) - cfg.as_of   AS days_left,
       sum(d.itc_unclaimed) OVER (ORDER BY d.itc_unclaimed DESC
                                  ROWS UNBOUNDED PRECEDING)    AS cumulative_unclaimed
  FROM gst.v_recon_detail d CROSS JOIN cfg
 WHERE d.itc_unclaimed > 0
 ORDER BY d.itc_unclaimed DESC;


-- Headline output
\echo ''
\echo '================ RECONCILIATION SUMMARY ================'
SELECT * FROM gst.v_recon_summary;
