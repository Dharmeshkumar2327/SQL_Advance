/* =============================================================================
   GST Reconciliation Engine  |  00_setup.sql
   Author : Dharmesh Kumar
   Purpose: Clean slate - schemas and extensions.
   Target : PostgreSQL 16+
   ============================================================================= */

\echo '>> 00_setup: creating schemas and extensions'

SET client_min_messages = warning;   -- hide 'does not exist, skipping' noise

DROP SCHEMA IF EXISTS qa  CASCADE;
DROP SCHEMA IF EXISTS gst CASCADE;
DROP SCHEMA IF EXISTS stg CASCADE;

CREATE SCHEMA stg;   -- raw landing zone (everything is TEXT, nothing is trusted)
CREATE SCHEMA gst;   -- validated core model, matching engine, reports
CREATE SCHEMA qa;    -- ground truth + automated tests

COMMENT ON SCHEMA stg IS 'Raw CSV landing tables. All columns TEXT.';
COMMENT ON SCHEMA gst IS 'Core GST reconciliation model, engine and reporting views.';
COMMENT ON SCHEMA qa  IS 'Ground-truth labels and test harness.';

-- pg_trgm      : trigram similarity for fuzzy invoice-number matching
-- fuzzystrmatch: levenshtein edit distance for typo detection
CREATE EXTENSION IF NOT EXISTS pg_trgm       WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch WITH SCHEMA public;
