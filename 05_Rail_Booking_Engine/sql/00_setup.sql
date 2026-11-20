-- =============================================================================
-- 00_setup.sql
-- Fresh schema + extensions. Safe to re-run: drops and recreates schema `rail`.
-- =============================================================================
\set ON_ERROR_STOP on

SET client_min_messages = warning;
DROP SCHEMA IF EXISTS rail CASCADE;
CREATE SCHEMA rail;

-- btree_gist lets a GiST index mix plain equality columns (journey_id, seat_id)
-- with range overlap (seg_range &&). This powers the no-double-booking
-- EXCLUDE constraint in 01_schema.sql.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- All business times are IST
DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'Asia/Kolkata');
END $$;
SET timezone = 'Asia/Kolkata';

COMMENT ON SCHEMA rail IS
  'Indian Railways style reservation engine: inventory, segment-wise seat allocation, RAC/WL queues, cancellation & refunds, chart preparation.';
