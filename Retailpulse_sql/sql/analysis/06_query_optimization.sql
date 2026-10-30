-- =====================================================================
-- 06_query_optimization.sql
-- Shows HOW to tune queries, with EXPLAIN ANALYZE evidence:
--   1. Index vs sequential scan (and why FK columns need indexes)
--   2. Sargable predicates (don't wrap indexed columns in functions)
--   3. Correlated subquery  vs  window function  vs  DISTINCT ON
--   4. Partial + covering indexes
-- Indexes are dropped inside a transaction and the whole script is
-- rolled back, so the database is left unchanged.
-- =====================================================================
SET search_path TO retail;
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Point lookup on a foreign key: orders for one customer
-- ---------------------------------------------------------------------
DROP INDEX ix_orders_customer;
\echo '=== 1a. WITHOUT index on orders(customer_id) -> Seq Scan over every order ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT order_id, order_ts, status FROM orders WHERE customer_id = 4734;

CREATE INDEX ix_orders_customer ON orders (customer_id);
ANALYZE orders;
\echo '=== 1b. WITH index -> Bitmap/Index Scan touches only matching rows ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT order_id, order_ts, status FROM orders WHERE customer_id = 4734;

-- ---------------------------------------------------------------------
-- 2. Sargability: function on the column disables the index
-- ---------------------------------------------------------------------
\echo '=== 2a. NON-sargable: date(order_ts) = ... cannot use ix_orders_ts ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT COUNT(*) FROM orders WHERE order_ts::date = DATE '2025-11-01';

\echo '=== 2b. Sargable range rewrite -> index range scan ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT COUNT(*) FROM orders
WHERE order_ts >= TIMESTAMP '2025-11-01' AND order_ts < TIMESTAMP '2025-11-02';

-- ---------------------------------------------------------------------
-- 3. "Latest order per customer" - three ways
-- ---------------------------------------------------------------------
\echo '=== 3a. Correlated subquery (re-executed per row) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT o.customer_id, o.order_id, o.order_ts
FROM orders o
WHERE o.order_ts = (SELECT MAX(o2.order_ts) FROM orders o2 WHERE o2.customer_id = o.customer_id);

\echo '=== 3b. Window function (single pass + sort) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT customer_id, order_id, order_ts
FROM (SELECT customer_id, order_id, order_ts,
             ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_ts DESC) AS rn
      FROM orders) t
WHERE rn = 1;

\echo '=== 3c. PostgreSQL DISTINCT ON (most concise) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT DISTINCT ON (customer_id) customer_id, order_id, order_ts
FROM orders
ORDER BY customer_id, order_ts DESC;

-- ---------------------------------------------------------------------
-- 4. Covering index -> Index Only Scan (heap never touched)
-- ---------------------------------------------------------------------
DROP INDEX ix_price_hist_lookup;
\echo '=== 4a. Price lookup WITHOUT covering index ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT price FROM product_price_history
WHERE product_id = 42 AND valid_from <= DATE '2025-01-15'
ORDER BY valid_from DESC LIMIT 1;

ROLLBACK;   -- restores every dropped index

-- Index-only scans need an up-to-date visibility map (VACUUM), and VACUUM
-- cannot run inside a transaction block, so step 4b runs on its own:
SET search_path TO retail;
VACUUM ANALYZE product_price_history;
\echo '=== 4b. WITH covering index (product_id, valid_from) INCLUDE (price) -> Index Only Scan ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT price FROM product_price_history
WHERE product_id = 42 AND valid_from <= DATE '2025-01-15'
ORDER BY valid_from DESC LIMIT 1;

-- ---------------------------------------------------------------------
-- 5. Materialized view vs live aggregation
-- ---------------------------------------------------------------------
\echo '=== 5a. Live: monthly KPIs computed from raw tables ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, BUFFERS OFF)
SELECT order_month, COUNT(*), SUM(gross_revenue) FROM vw_valid_sales GROUP BY order_month;

\echo '=== 5b. Pre-computed: read from mv_monthly_kpis ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, BUFFERS OFF)
SELECT order_month, orders, revenue FROM mv_monthly_kpis;
