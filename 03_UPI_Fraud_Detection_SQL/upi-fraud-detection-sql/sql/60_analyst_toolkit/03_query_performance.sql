/* =============================================================================
   03_query_performance.sql  -  proving the indexes matter.

   Runs the core lookup used by R06 (distinct payers into an account in the
   last 24 h) with and without the (payee_account_id, txn_ts) index and prints
   both EXPLAIN ANALYZE plans. Everything happens inside a transaction that is
   rolled back, so the real index is never lost.

       psql -d upi_fraud -f sql/60_analyst_toolkit/03_query_performance.sql
   ============================================================================= */
\set ON_ERROR_STOP on
SELECT payee_account_id AS demo_payee, MAX(txn_ts) AS demo_ts
FROM upi.transactions t JOIN fraud.rule_hits h USING (txn_id)
WHERE h.rule_code = 'R06'
GROUP BY payee_account_id ORDER BY COUNT(*) DESC LIMIT 1 \gset

\echo ''
\echo '---- WITH index idx_txn_payee_ts ----'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT COUNT(DISTINCT payer_account_id)
FROM upi.transactions
WHERE payee_account_id = :demo_payee
  AND status = 'SUCCESS'
  AND txn_ts >  :'demo_ts'::TIMESTAMP - INTERVAL '24 hours'
  AND txn_ts <= :'demo_ts'::TIMESTAMP;

BEGIN;
DROP INDEX upi.idx_txn_payee_ts;

\echo ''
\echo '---- WITHOUT the index (inside a rolled-back transaction) ----'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT COUNT(DISTINCT payer_account_id)
FROM upi.transactions
WHERE payee_account_id = :demo_payee
  AND status = 'SUCCESS'
  AND txn_ts >  :'demo_ts'::TIMESTAMP - INTERVAL '24 hours'
  AND txn_ts <= :'demo_ts'::TIMESTAMP;

ROLLBACK;
\echo ''
\echo 'index restored (transaction rolled back)'
