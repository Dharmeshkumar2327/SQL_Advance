/* =============================================================================
   GST Reconciliation Engine  |  01_functions.sql
   Author : Dharmesh Kumar
   Purpose: Domain functions. All are IMMUTABLE so they can back generated
            columns and expression indexes.
   ============================================================================= */

\echo '>> 01_functions: GSTIN validation, invoice normalisation, GST calendar'

/* -----------------------------------------------------------------------------
   GSTIN checksum (15th character)
   GSTIN = 2-digit state code + 10-char PAN + entity no. + 'Z' + checksum.
   The checksum is a Luhn mod-36 over the first 14 characters: odd positions
   weight 1, even positions weight 2, each product folded as (p/36 + p%36).
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION gst.fn_gstin_checksum(p_gstin text)
RETURNS char(1)
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    WITH digits AS (
        SELECT i,
               strpos('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                      substr(upper(p_gstin), i, 1)) - 1                AS code_point
        FROM generate_series(1, 14) AS i
    ), weighted AS (
        SELECT code_point * CASE WHEN i % 2 = 0 THEN 2 ELSE 1 END       AS prod
        FROM digits
    )
    SELECT substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                  ((36 - (sum(prod / 36 + prod % 36) % 36)) % 36)::int + 1, 1)
    FROM weighted;
$$;

COMMENT ON FUNCTION gst.fn_gstin_checksum(text) IS
'Computes the GSTIN check character (Luhn mod-36) from the first 14 characters.';


CREATE OR REPLACE FUNCTION gst.fn_is_valid_gstin(p_gstin text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT coalesce(
             p_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
             AND gst.fn_gstin_checksum(p_gstin) = right(p_gstin, 1),
           false);
$$;

COMMENT ON FUNCTION gst.fn_is_valid_gstin(text) IS
'TRUE when the GSTIN has the right structure AND a correct checksum.';


/* -----------------------------------------------------------------------------
   Invoice-number normalisation
   Suppliers print 'INV/25-26/0012'; accountants type 'inv-25-26-12'.
     1. upper-case
     2. every run of non-alphanumerics becomes one separator
     3. strip leading zeros of every digit run   (0012 -> 12)
     4. drop the separators
   Both examples become 'INV252612'.
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION gst.fn_normalize_invoice_no(p_invoice_no text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT replace(
             regexp_replace(
               regexp_replace(upper(btrim(p_invoice_no)), '[^A-Z0-9]+', ' ', 'g'),
               '(^|[^0-9])0+([0-9])', '\1\2', 'g'),
             ' ', '');
$$;

COMMENT ON FUNCTION gst.fn_normalize_invoice_no(text) IS
'Canonical invoice key: upper-case, separators removed, leading zeros stripped.';


/* -----------------------------------------------------------------------------
   GST calendar helpers
   ----------------------------------------------------------------------------- */
-- Indian financial year label, e.g. 2025-07-14 -> '2025-26'
CREATE OR REPLACE FUNCTION gst.fn_financial_year(p_date date)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT CASE WHEN extract(month FROM p_date) >= 4
                THEN extract(year FROM p_date)::int
                ELSE extract(year FROM p_date)::int - 1 END::text
           || '-' ||
           lpad((((CASE WHEN extract(month FROM p_date) >= 4
                        THEN extract(year FROM p_date)::int
                        ELSE extract(year FROM p_date)::int - 1 END) + 1) % 100)::text, 2, '0');
$$;

CREATE OR REPLACE FUNCTION gst.fn_fy_start(p_fy text)
RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT make_date(left(p_fy, 4)::int, 4, 1); $$;

CREATE OR REPLACE FUNCTION gst.fn_fy_end(p_fy text)
RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT make_date(left(p_fy, 4)::int + 1, 3, 31); $$;

-- Return period label 'YYYY-MM'
CREATE OR REPLACE FUNCTION gst.fn_return_period(p_date date)
RETURNS char(7)
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT to_char(p_date, 'YYYY-MM'); $$;

-- GSTR-1 (monthly) due date: 11th of the month after the return period
CREATE OR REPLACE FUNCTION gst.fn_gstr1_due_date(p_period text)
RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT (make_date(left(p_period, 4)::int, right(p_period, 2)::int, 1)
              + interval '1 month' + interval '10 days')::date; $$;

/* Section 16(4) CGST Act: ITC on an invoice must be availed by 30 November
   following the end of the financial year (or the annual-return date, if
   earlier). We model the 30-November outer limit. */
CREATE OR REPLACE FUNCTION gst.fn_itc_claim_deadline(p_invoice_date date)
RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT make_date(left(gst.fn_financial_year(p_invoice_date), 4)::int + 1, 11, 30); $$;

-- Signed multiplier: credit notes reduce ITC
CREATE OR REPLACE FUNCTION gst.fn_doc_sign(p_doc_class text)
RETURNS int
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT CASE WHEN p_doc_class = 'CRN' THEN -1 ELSE 1 END; $$;
