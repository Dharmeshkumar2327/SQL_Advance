/* =============================================================================
   GST Reconciliation Engine  |  03_load.sql
   Author : Dharmesh Kumar
   Purpose: CSV -> staging -> validated core tables.
            Bad rows are never silently dropped: they land in stg.load_rejects
            with a reason and the full raw record as JSONB.
   Run from the repository root (paths are relative to it).
   ============================================================================= */

\echo '>> 03_load: loading CSVs into staging'

TRUNCATE stg.suppliers, stg.purchase_register, stg.gstr2b, stg.load_rejects;

\copy stg.suppliers         FROM 'data/suppliers.csv'         WITH (FORMAT csv, HEADER true)
\copy stg.purchase_register FROM 'data/purchase_register.csv' WITH (FORMAT csv, HEADER true)
\copy stg.gstr2b            FROM 'data/gstr2b.csv'            WITH (FORMAT csv, HEADER true)
\copy qa.ground_truth       FROM 'data/ground_truth.csv'      WITH (FORMAT csv, HEADER true)

\echo '>> 03_load: validating and promoting to core tables'

/* -----------------------------------------------------------------------------
   Suppliers (vendor master)
   ----------------------------------------------------------------------------- */
INSERT INTO gst.supplier (gstin, legal_name, trade_name, state_code, vendor_category, onboarding_date)
SELECT upper(btrim(gstin)), btrim(legal_name), btrim(trade_name), state_code,
       vendor_category, onboarding_date::date
FROM stg.suppliers;


/* -----------------------------------------------------------------------------
   Purchase register
   One statement, three steps, using data-modifying CTEs:
     classified -> reject reason per row (NULL = clean)
     rejected   -> INSERT bad rows into stg.load_rejects
     final      -> INSERT clean rows into gst.purchase_register
   pg_input_is_valid() (PostgreSQL 16) tests casts without raising errors.
   ----------------------------------------------------------------------------- */
WITH params AS (
    SELECT config_value AS fy FROM gst.recon_config WHERE config_key = 'load_financial_year'
),
classified AS (
    SELECT s.*,
           CASE
             WHEN nullif(btrim(s.voucher_no), '') IS NULL                       THEN 'MISSING_VOUCHER_NO'
             WHEN nullif(btrim(s.supplier_gstin), '') IS NULL                   THEN 'MISSING_GSTIN'
             WHEN length(btrim(s.supplier_gstin)) <> 15                         THEN 'BAD_GSTIN_LENGTH'
             WHEN nullif(btrim(s.invoice_no), '') IS NULL                       THEN 'MISSING_INVOICE_NO'
             WHEN NOT coalesce(pg_input_is_valid(s.invoice_date, 'date'), false)
               OR NOT coalesce(pg_input_is_valid(s.booking_date, 'date'), false) THEN 'BAD_DATE'
             WHEN NOT (   coalesce(pg_input_is_valid(s.taxable_value, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.igst, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.cgst, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.sgst, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.cess, 'numeric'), false))  THEN 'NON_NUMERIC_AMOUNT'
             WHEN least(s.taxable_value::numeric, s.igst::numeric, s.cgst::numeric,
                        s.sgst::numeric, s.cess::numeric) < 0                   THEN 'NEGATIVE_AMOUNT'
             WHEN s.invoice_date::date NOT BETWEEN gst.fn_fy_start(p.fy)
                                              AND gst.fn_fy_end(p.fy)          THEN 'OUTSIDE_FY'
             WHEN s.document_type NOT IN ('INV','CRN')                          THEN 'BAD_DOCUMENT_TYPE'
             WHEN s.place_of_supply NOT IN (SELECT state_code FROM gst.state_code) THEN 'BAD_PLACE_OF_SUPPLY'
           END AS reject_reason
    FROM stg.purchase_register s CROSS JOIN params p
),
rejected AS (
    INSERT INTO stg.load_rejects (source_table, record_key, reject_reason, raw_record)
    SELECT 'purchase_register', voucher_no, reject_reason,
           to_jsonb(c) - 'reject_reason'
    FROM classified c
    WHERE reject_reason IS NOT NULL
    RETURNING 1
)
INSERT INTO gst.purchase_register
      (voucher_no, booking_date, supplier_gstin, supplier_name, invoice_no, invoice_date,
       doc_class, place_of_supply, taxable_value, igst, cgst, sgst, cess, itc_claim_period)
SELECT btrim(voucher_no), booking_date::date, upper(btrim(supplier_gstin)), btrim(supplier_name),
       btrim(invoice_no), invoice_date::date, document_type, place_of_supply,
       taxable_value::numeric, igst::numeric, cgst::numeric, sgst::numeric, cess::numeric,
       itc_claim_period
FROM classified
WHERE reject_reason IS NULL;


/* -----------------------------------------------------------------------------
   GSTR-2B (same pattern; portal data is cleaner but is still validated)
   ----------------------------------------------------------------------------- */
WITH classified AS (
    SELECT s.*,
           CASE
             WHEN NOT gst.fn_is_valid_gstin(upper(btrim(s.supplier_gstin)))      THEN 'INVALID_GSTIN'
             WHEN nullif(btrim(s.invoice_no), '') IS NULL                       THEN 'MISSING_INVOICE_NO'
             WHEN NOT coalesce(pg_input_is_valid(s.invoice_date, 'date'), false)
               OR NOT coalesce(pg_input_is_valid(s.gstr1_filing_date, 'date'), false) THEN 'BAD_DATE'
             WHEN NOT (   coalesce(pg_input_is_valid(s.taxable_value, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.igst, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.cgst, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.sgst, 'numeric'), false)
                      AND coalesce(pg_input_is_valid(s.cess, 'numeric'), false))  THEN 'NON_NUMERIC_AMOUNT'
             WHEN s.document_type NOT IN ('B2B','CDNR')                         THEN 'BAD_SECTION'
             WHEN s.itc_available NOT IN ('Y','N')                              THEN 'BAD_ITC_FLAG'
           END AS reject_reason
    FROM stg.gstr2b s
),
rejected AS (
    INSERT INTO stg.load_rejects (source_table, record_key, reject_reason, raw_record)
    SELECT 'gstr2b', supplier_gstin || '|' || invoice_no || '|' || return_period,
           reject_reason, to_jsonb(c) - 'reject_reason'
    FROM classified c
    WHERE reject_reason IS NOT NULL
    RETURNING 1
)
INSERT INTO gst.gstr2b
      (return_period, supplier_gstin, trade_name, section, invoice_no, invoice_date,
       place_of_supply, taxable_value, igst, cgst, sgst, cess, itc_available,
       itc_unavailable_reason, gstr1_filing_date)
SELECT return_period, upper(btrim(supplier_gstin)), trade_name, document_type, btrim(invoice_no),
       invoice_date::date, place_of_supply, taxable_value::numeric, igst::numeric,
       cgst::numeric, sgst::numeric, cess::numeric, itc_available = 'Y',
       nullif(itc_unavailable_reason, ''), gstr1_filing_date::date
FROM classified
WHERE reject_reason IS NULL;

ANALYZE gst.supplier;
ANALYZE gst.purchase_register;
ANALYZE gst.gstr2b;

-- Load summary
SELECT 'suppliers'          AS table_name, count(*) AS rows FROM gst.supplier
UNION ALL SELECT 'purchase_register', count(*) FROM gst.purchase_register
UNION ALL SELECT 'gstr2b',            count(*) FROM gst.gstr2b
UNION ALL SELECT 'load_rejects',      count(*) FROM stg.load_rejects;
