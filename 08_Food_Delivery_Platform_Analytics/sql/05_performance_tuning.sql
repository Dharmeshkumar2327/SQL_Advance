-- 05_performance_tuning.sql
-- Create indexes that support common joins, filters, and time-based reporting.
CREATE INDEX IF NOT EXISTS idx_orders_placed_at ON orders(order_placed_at);
CREATE INDEX IF NOT EXISTS idx_orders_customer_date ON orders(customer_id, order_placed_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_restaurant_status ON orders(restaurant_id, order_status);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_item ON order_items(item_id);
CREATE INDEX IF NOT EXISTS idx_payments_status_method ON payments(payment_status, payment_method);

-- Compare the plan before and after adding indexes:
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, COUNT(*)
FROM orders
WHERE order_placed_at >= TIMESTAMP '2025-01-01'
  AND order_placed_at <  TIMESTAMP '2025-05-01'
GROUP BY customer_id;

-- Materialized view for a frequently used monthly KPI report.
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_restaurant_revenue;
CREATE MATERIALIZED VIEW mv_monthly_restaurant_revenue AS
SELECT DATE_TRUNC('month',v.order_placed_at)::DATE AS month,
       r.restaurant_id, r.restaurant_name,
       COUNT(*) AS completed_orders,
       SUM(v.net_order_value) AS revenue
FROM v_order_financials v JOIN restaurants r USING (restaurant_id)
WHERE v.order_status='delivered'
GROUP BY 1,2,3;

CREATE INDEX IF NOT EXISTS idx_mv_monthly_restaurant
ON mv_monthly_restaurant_revenue(month, restaurant_id);

-- Refresh after new data is loaded:
-- REFRESH MATERIALIZED VIEW mv_monthly_restaurant_revenue;
