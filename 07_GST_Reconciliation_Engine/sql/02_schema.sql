/* =============================================================================
   GST Reconciliation Engine  |  02_schema.sql
   Author : Dharmesh Kumar
   Purpose: Staging tables, core model, reference data, engine output tables.
   ============================================================================= */

\echo '>> 02_schema: tables, constraints, indexes, reference data'

/* =============================================================================
   1. STAGING  (raw CSV, all TEXT)
   ============================================================================= */
CREATE TABLE stg.suppliers (
    gstin text, legal_name text, trade_name text, state_code text,
    vendor_category text, onboarding_date text
);

CREATE TABLE stg.purchase_register (
    voucher_no text, booking_date text, supplier_gstin text, supplier_name text,
    invoice_no text, invoice_date text, document_type text, place_of_supply text,
    taxable_value text, igst text, cgst text, sgst text, cess text,
    itc_claim_period text
);

CREATE TABLE stg.gstr2b (
    return_period text, supplier_gstin text, trade_name text, document_type text,
    invoice_no text, invoice_date text, place_of_supply text, taxable_value text,
    igst text, cgst text, sgst text, cess text, itc_available text,
    itc_unavailable_reason text, gstr1_filing_date text
);

CREATE TABLE stg.load_rejects (
    reject_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_table  text        NOT NULL,
    record_key    text,
    reject_reason text        NOT NULL,
    raw_record    jsonb       NOT NULL,
    rejected_at   timestamptz NOT NULL DEFAULT now()
);


/* =============================================================================
   2. REFERENCE DATA
   ============================================================================= */
CREATE TABLE gst.state_code (
    state_code char(2) PRIMARY KEY,
    state_name text    NOT NULL
);

INSERT INTO gst.state_code VALUES
 ('01','Jammu and Kashmir'),('02','Himachal Pradesh'),('03','Punjab'),('04','Chandigarh'),
 ('05','Uttarakhand'),('06','Haryana'),('07','Delhi'),('08','Rajasthan'),('09','Uttar Pradesh'),
 ('10','Bihar'),('11','Sikkim'),('12','Arunachal Pradesh'),('13','Nagaland'),('14','Manipur'),
 ('15','Mizoram'),('16','Tripura'),('17','Meghalaya'),('18','Assam'),('19','West Bengal'),
 ('20','Jharkhand'),('21','Odisha'),('22','Chhattisgarh'),('23','Madhya Pradesh'),
 ('24','Gujarat'),('26','Dadra and Nagar Haveli and Daman and Diu'),('27','Maharashtra'),
 ('29','Karnataka'),('30','Goa'),('31','Lakshadweep'),('32','Kerala'),('33','Tamil Nadu'),
 ('34','Puducherry'),('35','Andaman and Nicobar Islands'),('36','Telangana'),
 ('37','Andhra Pradesh'),('38','Ladakh'),('97','Other Territory');

-- The buyer whose books we reconcile
CREATE TABLE gst.company (
    company_id   smallint PRIMARY KEY DEFAULT 1 CHECK (company_id = 1),  -- single-row table
    legal_name   text     NOT NULL,
    gstin        char(15) NOT NULL CHECK (gst.fn_is_valid_gstin(gstin)),
    state_code   char(2)  NOT NULL REFERENCES gst.state_code,
    CHECK (left(gstin, 2) = state_code)
);

INSERT INTO gst.company (legal_name, gstin, state_code)
SELECT 'Shakti Precision Components Pvt Ltd',
       '29AAKCS4821M1Z' || gst.fn_gstin_checksum('29AAKCS4821M1Z'), '29';

-- Engine settings (tunable without touching code)
CREATE TABLE gst.recon_config (
    config_key   text PRIMARY KEY,
    config_value text NOT NULL,
    description  text NOT NULL
);

INSERT INTO gst.recon_config VALUES
 ('load_financial_year',     '2025-26',    'Financial year accepted by the loader; other dates are rejected'),
 ('amount_tolerance',       '10',         'Max rupee difference (taxable and tax) still treated as a match'),
 ('fuzzy_max_edit_distance', '2',          'Max Levenshtein distance between normalised invoice numbers'),
 ('fuzzy_min_similarity',    '0.00',       'Min trigram similarity gate. Kept at 0: trigrams score short IDs poorly (SB327 vs SB237 = 0.20), so similarity is used for ranking only'),
 ('fuzzy_date_window_days',  '3',          'Max invoice-date gap for a fuzzy match'),
 ('gstin_max_edit_distance', '2',          'Max Levenshtein distance for GSTIN-typo correction'),
 ('as_of_date',              '2026-11-24', 'Reporting date for ageing and Section 16(4) countdown');

-- Every status the engine can emit, with business meaning and next action
CREATE TABLE gst.status_catalog (
    match_status       text     PRIMARY KEY,
    status_group       text     NOT NULL CHECK (status_group IN ('MATCHED','TIMING','MISMATCH','MISSING','COMPLIANCE')),
    severity           smallint NOT NULL CHECK (severity BETWEEN 0 AND 3),  -- 0 ok .. 3 critical
    description        text     NOT NULL,
    recommended_action text     NOT NULL
);

INSERT INTO gst.status_catalog VALUES
 ('MATCHED',                  'MATCHED',    0, 'Books and GSTR-2B agree on every field.',
                                                 'None. ITC fully supported.'),
 ('MATCHED_TOLERANCE',        'MATCHED',    0, 'Agrees within the configured rupee tolerance (rounding).',
                                                 'None. Optionally align the paisa difference in books.'),
 ('MATCHED_DATE_DIFF',        'MATCHED',    1, 'Same invoice, but invoice date differs between books and 2B.',
                                                 'Correct the invoice date in the purchase register.'),
 ('MATCHED_FUZZY_INVNO',      'MATCHED',    1, 'Matched on a near-identical invoice number (data-entry typo).',
                                                 'Correct the invoice number in books to match the supplier copy.'),
 ('MATCHED_GSTIN_CORRECTION', 'MATCHED',    2, 'Books carry a mistyped supplier GSTIN; matched on invoice + amount.',
                                                 'Fix the GSTIN in the vendor master and the voucher.'),
 ('MATCHED_CROSS_PERIOD',     'TIMING',     1, 'Supplier reported the invoice in a later return period.',
                                                 'Claim ITC in the period it appears in 2B; track the timing difference.'),
 ('MISMATCH_VALUE',           'MISMATCH',   2, 'Invoice found but taxable value / tax differs beyond tolerance.',
                                                 'Ask supplier to amend GSTR-1, or obtain a credit/debit note.'),
 ('MISMATCH_TAX_HEAD',        'MISMATCH',   3, 'Total tax agrees but IGST vs CGST+SGST is wrong (place of supply).',
                                                 'Supplier must amend GSTR-1 with the correct place of supply.'),
 ('MISSING_IN_2B',            'MISSING',    3, 'Claimed in books, absent from GSTR-2B. ITC is not available (Sec 16(2)(aa)).',
                                                 'Follow up with supplier to file GSTR-1; defer or reverse the ITC.'),
 ('MISSING_IN_BOOKS',         'MISSING',    1, 'In GSTR-2B but never booked. Unclaimed ITC opportunity.',
                                                 'Verify the purchase, book it and claim the ITC before the Sec 16(4) deadline.'),
 ('CREDIT_NOTE_NOT_BOOKED',   'MISSING',    2, 'Supplier issued a credit note that is not recorded in books.',
                                                 'Book the credit note and reverse the corresponding ITC.'),
 ('DUPLICATE_IN_BOOKS',       'COMPLIANCE', 3, 'Same supplier invoice booked more than once; ITC claimed twice.',
                                                 'Cancel the duplicate voucher and reverse the excess ITC.'),
 ('ITC_INELIGIBLE',           'COMPLIANCE', 3, 'Invoice present in 2B but marked ITC-unavailable.',
                                                 'Do not claim; reverse if already claimed.');


/* =============================================================================
   3. CORE MODEL
   ============================================================================= */
CREATE TABLE gst.supplier (
    supplier_id     int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gstin           char(15) NOT NULL UNIQUE CHECK (gst.fn_is_valid_gstin(gstin)),
    legal_name      text NOT NULL,
    trade_name      text NOT NULL,
    state_code      char(2) NOT NULL REFERENCES gst.state_code,
    pan             char(10) GENERATED ALWAYS AS (substr(gstin, 3, 10)) STORED,
    vendor_category text NOT NULL,
    onboarding_date date NOT NULL,
    CHECK (left(gstin, 2) = state_code)
);

/* Purchase register = the buyer's books.
   Supplier GSTIN deliberately has NO foreign key and NO validity CHECK:
   real books contain typos, and the engine must still reconcile them. */
CREATE TABLE gst.purchase_register (
    pr_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_no       text     NOT NULL UNIQUE,
    booking_date     date     NOT NULL,
    supplier_gstin   char(15) NOT NULL,
    supplier_name    text     NOT NULL,
    invoice_no       text     NOT NULL,
    invoice_date     date     NOT NULL,
    doc_class        char(3)  NOT NULL CHECK (doc_class IN ('INV','CRN')),
    place_of_supply  char(2)  NOT NULL REFERENCES gst.state_code,
    taxable_value    numeric(14,2) NOT NULL CHECK (taxable_value >= 0),
    igst             numeric(14,2) NOT NULL DEFAULT 0 CHECK (igst >= 0),
    cgst             numeric(14,2) NOT NULL DEFAULT 0 CHECK (cgst >= 0),
    sgst             numeric(14,2) NOT NULL DEFAULT 0 CHECK (sgst >= 0),
    cess             numeric(14,2) NOT NULL DEFAULT 0 CHECK (cess >= 0),
    itc_claim_period char(7)  NOT NULL CHECK (itc_claim_period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
    -- derived columns
    invoice_no_norm  text          GENERATED ALWAYS AS (gst.fn_normalize_invoice_no(invoice_no)) STORED,
    total_tax        numeric(14,2) GENERATED ALWAYS AS (igst + cgst + sgst + cess) STORED,
    invoice_value    numeric(14,2) GENERATED ALWAYS AS (taxable_value + igst + cgst + sgst + cess) STORED,
    gstin_is_valid   boolean       GENERATED ALWAYS AS (gst.fn_is_valid_gstin(supplier_gstin)) STORED,
    financial_year   text          GENERATED ALWAYS AS (gst.fn_financial_year(invoice_date)) STORED,
    -- business rules
    CHECK (cgst = sgst OR abs(cgst - sgst) <= 0.01),            -- CGST and SGST always equal
    CHECK (NOT (igst > 0 AND (cgst > 0 OR sgst > 0)))           -- either IGST or CGST+SGST, never both
);

/* GSTR-2B: auto-drafted ITC statement, generated from suppliers' GSTR-1. */
CREATE TABLE gst.gstr2b (
    b2b_id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    return_period           char(7)  NOT NULL CHECK (return_period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
    supplier_gstin          char(15) NOT NULL CHECK (gst.fn_is_valid_gstin(supplier_gstin)),
    trade_name              text     NOT NULL,
    section                 text     NOT NULL CHECK (section IN ('B2B','CDNR')),
    invoice_no              text     NOT NULL,
    invoice_date            date     NOT NULL,
    place_of_supply         char(2)  NOT NULL REFERENCES gst.state_code,
    taxable_value           numeric(14,2) NOT NULL CHECK (taxable_value >= 0),
    igst                    numeric(14,2) NOT NULL DEFAULT 0,
    cgst                    numeric(14,2) NOT NULL DEFAULT 0,
    sgst                    numeric(14,2) NOT NULL DEFAULT 0,
    cess                    numeric(14,2) NOT NULL DEFAULT 0,
    itc_available           boolean  NOT NULL,
    itc_unavailable_reason  text,
    gstr1_filing_date       date     NOT NULL,
    -- derived columns
    doc_class        char(3)       GENERATED ALWAYS AS (CASE section WHEN 'CDNR' THEN 'CRN' ELSE 'INV' END) STORED,
    invoice_no_norm  text          GENERATED ALWAYS AS (gst.fn_normalize_invoice_no(invoice_no)) STORED,
    total_tax        numeric(14,2) GENERATED ALWAYS AS (igst + cgst + sgst + cess) STORED,
    invoice_value    numeric(14,2) GENERATED ALWAYS AS (taxable_value + igst + cgst + sgst + cess) STORED,
    financial_year   text          GENERATED ALWAYS AS (gst.fn_financial_year(invoice_date)) STORED,
    UNIQUE (supplier_gstin, invoice_no, return_period),
    CHECK (itc_available OR itc_unavailable_reason IS NOT NULL)
);

-- Matching indexes: exact key, then trigram for fuzzy candidate search
CREATE INDEX ix_pr_match_key   ON gst.purchase_register (supplier_gstin, invoice_no_norm);
CREATE INDEX ix_pr_fy          ON gst.purchase_register (financial_year);
CREATE INDEX ix_pr_invno_trgm  ON gst.purchase_register USING gin (invoice_no_norm gin_trgm_ops);
CREATE INDEX ix_2b_match_key   ON gst.gstr2b (supplier_gstin, invoice_no_norm);
CREATE INDEX ix_2b_fy          ON gst.gstr2b (financial_year);
CREATE INDEX ix_2b_invno_trgm  ON gst.gstr2b USING gin (invoice_no_norm gin_trgm_ops);


/* =============================================================================
   4. ENGINE OUTPUT
   ============================================================================= */
CREATE TABLE gst.recon_run (
    run_id          int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    financial_year  text        NOT NULL,
    started_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at     timestamptz,
    pr_records      int,
    b2b_records     int,
    result_rows     int,
    pass_log        jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- rows produced by each pass
    config_snapshot jsonb       NOT NULL,                       -- settings used (audit trail)
    notes           text
);

CREATE TABLE gst.recon_result (
    result_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id            int    NOT NULL REFERENCES gst.recon_run ON DELETE CASCADE,
    pr_id             bigint REFERENCES gst.purchase_register,
    b2b_id            bigint REFERENCES gst.gstr2b,
    match_pass        text   NOT NULL,
    match_status      text   NOT NULL REFERENCES gst.status_catalog,
    match_score       numeric(5,4),
    taxable_diff      numeric(14,2),      -- books minus 2B
    tax_diff          numeric(14,2),
    date_diff_days    int,
    itc_books         numeric(14,2) NOT NULL DEFAULT 0,  -- signed ITC claimed in books
    itc_2b            numeric(14,2) NOT NULL DEFAULT 0,  -- signed ITC available per 2B
    itc_at_risk       numeric(14,2) NOT NULL DEFAULT 0,  -- claimed but not supported
    itc_unclaimed     numeric(14,2) NOT NULL DEFAULT 0,  -- supported but not claimed
    itc_reversal      numeric(14,2) NOT NULL DEFAULT 0,  -- must be reversed (dupes, CNs)
    remarks           text,
    CHECK (pr_id IS NOT NULL OR b2b_id IS NOT NULL)
);

-- One-to-one guarantee: a record can be used only once per run
CREATE UNIQUE INDEX ux_result_pr  ON gst.recon_result (run_id, pr_id)  WHERE pr_id  IS NOT NULL;
CREATE UNIQUE INDEX ux_result_b2b ON gst.recon_result (run_id, b2b_id) WHERE b2b_id IS NOT NULL;
CREATE INDEX ix_result_status    ON gst.recon_result (run_id, match_status);


/* =============================================================================
   5. QA
   ============================================================================= */
CREATE TABLE qa.ground_truth (
    source          text NOT NULL CHECK (source IN ('PR','2B','REJECT')),
    record_key      text NOT NULL,
    scenario        text NOT NULL,
    expected_status text NOT NULL,
    PRIMARY KEY (source, record_key)
);
