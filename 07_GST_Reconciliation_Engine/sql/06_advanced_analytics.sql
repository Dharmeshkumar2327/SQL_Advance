/* =============================================================================
   GST Reconciliation Engine  |  06_advanced_analytics.sql
   Author : Dharmesh Kumar
   Purpose: Audit and analytics queries on top of the reconciliation.
            Each query is self-contained; run any of them on its own.

     Q1  Month x status pivot                 (conditional aggregation / FILTER)
     Q2  ITC at risk by state, month, total   (GROUPING SETS)
     Q3  Missing voucher numbers              (gaps-and-islands)
     Q4  Benford's-law test on invoice values (fraud screening, chi-square)
     Q5  Deteriorating suppliers              (rolling 3-month window + LAG)
     Q6  Largest open item per supplier       (LATERAL join, top-N per group)
     Q7  Filing-delay distribution            (percentile_cont / ordered-set)
     Q8  Pareto: suppliers driving 80% of risk (running share)
   ============================================================================= */

\echo '>> 06_advanced_analytics'
\pset footer off


\echo ''
\echo '---- Q1. Month x status pivot (record counts) ----'
SELECT coalesce(books_period, b2b_period)                                        AS period,
       count(*) FILTER (WHERE status_group = 'MATCHED')                          AS matched,
       count(*) FILTER (WHERE status_group = 'TIMING')                           AS timing,
       count(*) FILTER (WHERE status_group = 'MISMATCH')                         AS mismatch,
       count(*) FILTER (WHERE match_status = 'MISSING_IN_2B')                    AS missing_in_2b,
       count(*) FILTER (WHERE match_status IN ('MISSING_IN_BOOKS','CREDIT_NOTE_NOT_BOOKED')) AS missing_in_books,
       count(*) FILTER (WHERE status_group = 'COMPLIANCE')                       AS compliance,
       round(100.0 * count(*) FILTER (WHERE status_group = 'MATCHED') / count(*), 1) AS match_rate_pct
  FROM gst.v_recon_detail
 GROUP BY 1
 ORDER BY 1;


\echo ''
\echo '---- Q2. ITC at risk by supplier state and quarter (GROUPING SETS) ----'
SELECT CASE WHEN grouping(st.state_name) = 1 THEN '* ALL STATES *' ELSE st.state_name END AS state,
       CASE WHEN grouping(q.fy_quarter)  = 1 THEN '* ALL *'        ELSE q.fy_quarter  END AS fy_quarter,
       count(*)                     AS open_items,
       sum(d.itc_at_risk)           AS itc_at_risk
  FROM gst.v_recon_detail d
  JOIN gst.state_code st ON st.state_code = left(d.supplier_gstin, 2)
  CROSS JOIN LATERAL (
        SELECT 'Q' || (((extract(month FROM d.invoice_date)::int + 8) % 12) / 3 + 1) AS fy_quarter
  ) q
 WHERE d.itc_at_risk > 0
 GROUP BY GROUPING SETS ((st.state_name), (q.fy_quarter), ())
 ORDER BY grouping(st.state_name), grouping(q.fy_quarter), itc_at_risk DESC;


\echo ''
\echo '---- Q3. Missing purchase-voucher numbers (gaps-and-islands) ----'
-- Voucher numbers are a controlled sequence. A gap = a deleted or never-
-- loaded voucher, which auditors always ask to explain.
WITH seq AS (
    SELECT voucher_no,
           substring(voucher_no FROM '(\d+)$')::int AS n
      FROM gst.purchase_register
    UNION ALL                                   -- rejected rows still used a number
    SELECT record_key, substring(record_key FROM '(\d+)$')::int
      FROM stg.load_rejects
     WHERE source_table = 'purchase_register'
), gaps AS (
    SELECT lag(n) OVER (ORDER BY n) + 1 AS gap_start,
           n - 1                        AS gap_end
      FROM seq
)
SELECT gap_start, gap_end, gap_end - gap_start + 1 AS missing_count,
       format('PV/25-26/%s', lpad(gap_start::text, 5, '0')) AS first_missing_voucher
  FROM gaps
 WHERE gap_end >= gap_start
 ORDER BY gap_start;


\echo ''
\echo '---- Q4. Benford''s law: first-digit distribution of invoice values ----'
-- Natural financial data follows Benford's law. Large deviations can point
-- to fabricated invoices. Chi-square critical value at 8 d.f., 5% = 15.51.
WITH digits AS (
    SELECT left(regexp_replace(taxable_value::text, '^[0.]+', ''), 1)::int AS d
      FROM gst.purchase_register
     WHERE taxable_value >= 1
), observed AS (
    SELECT d, count(*) AS obs, sum(count(*)) OVER () AS n
      FROM digits GROUP BY d
), compared AS (
    SELECT d, obs,
           round(n * log(1 + 1.0 / d), 1)                         AS expected,
           round(100.0 * obs / n, 2)                              AS observed_pct,
           round(100 * log(1 + 1.0 / d), 2)                       AS benford_pct,
           power(obs - n * log(1 + 1.0 / d), 2) / (n * log(1 + 1.0 / d)) AS chi_part
      FROM observed
)
SELECT d AS first_digit, obs AS observed, expected, observed_pct, benford_pct,
       round(sum(chi_part) OVER (), 2)                            AS chi_square,
       CASE WHEN sum(chi_part) OVER () < 15.51
            THEN 'Conforms (p > 0.05)' ELSE 'DEVIATES - investigate' END AS verdict
  FROM compared
 ORDER BY d;


\echo ''
\echo '---- Q5. Suppliers whose mismatch rate is getting worse ----'
-- Rolling 3-month problem rate per supplier; flag when the latest rolling
-- rate is at least 15 points above the previous one.
WITH monthly AS (
    SELECT supplier_gstin, max(supplier_name) AS supplier_name,
           date_trunc('month', invoice_date)::date AS month,
           count(*) AS records,
           count(*) FILTER (WHERE status_group IN ('MISMATCH','MISSING','COMPLIANCE')) AS problems
      FROM gst.v_recon_detail
     GROUP BY supplier_gstin, 3
), rolling AS (
    SELECT *,
           round(100.0 * sum(problems) OVER w / sum(records) OVER w, 1) AS rolling_3m_problem_pct
      FROM monthly
    WINDOW w AS (PARTITION BY supplier_gstin ORDER BY month
                 RANGE BETWEEN interval '2 months' PRECEDING AND CURRENT ROW)
), trend AS (
    SELECT *,
           lag(rolling_3m_problem_pct) OVER (PARTITION BY supplier_gstin ORDER BY month) AS prev_pct,
           row_number() OVER (PARTITION BY supplier_gstin ORDER BY month DESC)           AS recency
      FROM rolling
)
SELECT supplier_name, to_char(month, 'Mon-YYYY') AS latest_month,
       prev_pct, rolling_3m_problem_pct, rolling_3m_problem_pct - prev_pct AS change_pts
  FROM trend
 WHERE recency = 1
   AND rolling_3m_problem_pct - prev_pct >= 15
 ORDER BY change_pts DESC
 LIMIT 10;


\echo ''
\echo '---- Q6. Biggest open item for each of the 10 riskiest suppliers (LATERAL) ----'
SELECT v.supplier_name, v.grade, v.itc_at_risk AS supplier_itc_at_risk,
       top.books_invoice_no, top.invoice_date, top.match_status, top.itc_at_risk AS item_itc_at_risk
  FROM gst.v_vendor_scorecard v
  CROSS JOIN LATERAL (
        SELECT d.books_invoice_no, d.invoice_date, d.match_status, d.itc_at_risk
          FROM gst.v_recon_detail d
         WHERE d.supplier_gstin = v.supplier_gstin
           AND d.itc_at_risk > 0
         ORDER BY d.itc_at_risk DESC
         LIMIT 1
  ) top
 ORDER BY v.itc_at_risk DESC
 LIMIT 10;


\echo ''
\echo '---- Q7. GSTR-1 filing delay distribution by supplier grade ----'
SELECT v.grade,
       count(DISTINCT v.supplier_gstin)                                                  AS suppliers,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY b.gstr1_filing_date - gst.fn_gstr1_due_date(b.return_period))::numeric, 1) AS median_delay_days,
       round(percentile_cont(0.90) WITHIN GROUP (ORDER BY b.gstr1_filing_date - gst.fn_gstr1_due_date(b.return_period))::numeric, 1) AS p90_delay_days,
       max(b.gstr1_filing_date - gst.fn_gstr1_due_date(b.return_period))                 AS worst_delay_days
  FROM gst.gstr2b b
  JOIN gst.v_vendor_scorecard v USING (supplier_gstin)
 GROUP BY v.grade
 ORDER BY v.grade;


\echo ''
\echo '---- Q8. Pareto: how few suppliers cause 80% of ITC at risk ----'
WITH ranked AS (
    SELECT supplier_name, itc_at_risk,
           round(100.0 * sum(itc_at_risk) OVER (ORDER BY itc_at_risk DESC ROWS UNBOUNDED PRECEDING)
                 / sum(itc_at_risk) OVER (), 1)                     AS cumulative_pct,
           row_number() OVER (ORDER BY itc_at_risk DESC)            AS supplier_rank,
           count(*) FILTER (WHERE itc_at_risk > 0) OVER ()          AS suppliers_with_risk
      FROM gst.v_vendor_scorecard
     WHERE itc_at_risk > 0
)
SELECT supplier_rank, supplier_name, itc_at_risk, cumulative_pct,
       CASE WHEN cumulative_pct - 100.0 * itc_at_risk / sum(itc_at_risk) OVER () < 80
            THEN 'vital few' ELSE '' END                            AS pareto_band,
       suppliers_with_risk
  FROM ranked
 ORDER BY supplier_rank
 LIMIT 15;
