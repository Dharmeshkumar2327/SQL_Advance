-- =====================================================================
-- RetailPulse Analytics  |  04_indexes.sql
-- Indexes chosen from the access patterns in /analysis.
-- See analysis/06_query_optimization.sql for before/after EXPLAIN plans.
-- =====================================================================
SET search_path TO retail;

-- Foreign keys are NOT auto-indexed in PostgreSQL -> index the join columns
CREATE INDEX IF NOT EXISTS ix_orders_customer      ON orders (customer_id);
CREATE INDEX IF NOT EXISTS ix_order_items_order    ON order_items (order_id);
CREATE INDEX IF NOT EXISTS ix_order_items_product  ON order_items (product_id);
CREATE INDEX IF NOT EXISTS ix_products_category    ON products (category_id);

-- Time-range filters on orders
CREATE INDEX IF NOT EXISTS ix_orders_ts            ON orders (order_ts);

-- Partial index: dashboards only read completed sales
CREATE INDEX IF NOT EXISTS ix_orders_valid_ts      ON orders (order_ts)
    WHERE status IN ('Delivered', 'Shipped');

-- Composite index supporting sessionisation (PARTITION BY customer ORDER BY ts)
CREATE INDEX IF NOT EXISTS ix_events_customer_ts   ON web_events (customer_id, event_ts);

-- Covering index (INCLUDE) for the as-of price lookup -> index-only scan
CREATE INDEX IF NOT EXISTS ix_price_hist_lookup    ON product_price_history (product_id, valid_from)
    INCLUDE (valid_to, price);

-- Expression index for case-insensitive email lookups
CREATE INDEX IF NOT EXISTS ix_customers_email_lower ON customers (lower(email));

ANALYZE;
