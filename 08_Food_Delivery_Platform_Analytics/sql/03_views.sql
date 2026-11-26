-- 03_views.sql

CREATE OR REPLACE VIEW v_order_financials AS
WITH item_totals AS (
    SELECT order_id, SUM(quantity * unit_price)::NUMERIC(12,2) AS item_subtotal
    FROM order_items GROUP BY order_id
)
SELECT o.order_id, o.customer_id, o.restaurant_id, o.partner_id,
       o.order_placed_at, o.order_status,
       COALESCE(i.item_subtotal,0) AS item_subtotal,
       o.delivery_fee, o.discount_amount,
       (COALESCE(i.item_subtotal,0) + o.delivery_fee - o.discount_amount)::NUMERIC(12,2)
           AS net_order_value
FROM orders o
LEFT JOIN item_totals i USING (order_id);

CREATE OR REPLACE VIEW v_delivery_performance AS
SELECT order_id, partner_id, order_placed_at, promised_delivery_at, delivered_at,
       EXTRACT(EPOCH FROM (delivered_at - order_placed_at))/60 AS delivery_minutes,
       CASE WHEN delivered_at <= promised_delivery_at THEN TRUE ELSE FALSE END AS is_on_time
FROM orders
WHERE order_status = 'delivered' AND delivered_at IS NOT NULL;

CREATE OR REPLACE VIEW v_monthly_business_kpis AS
SELECT DATE_TRUNC('month', order_placed_at)::DATE AS order_month,
       COUNT(*) AS total_orders,
       COUNT(*) FILTER (WHERE order_status='delivered') AS completed_orders,
       COUNT(*) FILTER (WHERE order_status='cancelled') AS cancelled_orders,
       ROUND(AVG(net_order_value) FILTER (WHERE order_status='delivered'),2) AS avg_order_value,
       ROUND(SUM(net_order_value) FILTER (WHERE order_status='delivered'),2) AS net_revenue
FROM v_order_financials
GROUP BY 1;
