-- 01 | BUSINESS KPIs
-- Revenue = quantity * unit_price * (1 - discount), completed orders only.

-- 1.1 Headline numbers
SELECT
    COUNT(DISTINCT o.order_id)                                         AS orders,
    COUNT(DISTINCT o.customer_id)                                      AS active_customers,
    ROUND(SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)), 0) AS revenue,
    ROUND(SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0))
          / COUNT(DISTINCT o.order_id), 0)                             AS avg_order_value
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'completed';

-- 1.2 Monthly revenue with month-over-month growth (LAG)
WITH monthly AS (
    SELECT strftime('%Y-%m', o.order_date) AS month,
           SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)) AS revenue
    FROM orders o JOIN order_items oi USING (order_id)
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT month,
       ROUND(revenue, 0) AS revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / LAG(revenue) OVER (ORDER BY month), 1) AS mom_growth_pct
FROM monthly
ORDER BY month;

-- 1.3 Order outcome mix (completion / cancel / return rates)
SELECT status,
       COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_orders
FROM orders
GROUP BY status;

-- 1.4 Revenue and profit margin by category
SELECT p.category,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)), 0) AS revenue,
       ROUND(SUM(oi.quantity * (oi.unit_price * (1 - o.discount_pct/100.0) - p.cost)), 0) AS profit,
       ROUND(100.0 * SUM(oi.quantity * (oi.unit_price * (1 - o.discount_pct/100.0) - p.cost))
             / SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)), 1) AS margin_pct
FROM orders o
JOIN order_items oi USING (order_id)
JOIN products p USING (product_id)
WHERE o.status = 'completed'
GROUP BY p.category
ORDER BY revenue DESC;
