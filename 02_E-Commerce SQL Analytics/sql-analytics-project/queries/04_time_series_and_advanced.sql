-- 04 | TIME SERIES & ADVANCED TECHNIQUES

-- 4.1 3-month moving average of revenue
WITH monthly AS (
    SELECT strftime('%Y-%m', o.order_date) AS month,
           SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)) AS revenue
    FROM orders o JOIN order_items oi USING (order_id)
    WHERE o.status = 'completed' GROUP BY 1
)
SELECT month, ROUND(revenue, 0) AS revenue,
       ROUND(AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0) AS ma_3m
FROM monthly ORDER BY month;

-- 4.2 Year-over-year revenue by month
WITH monthly AS (
    SELECT CAST(strftime('%Y', o.order_date) AS INT) AS yr,
           strftime('%m', o.order_date) AS mon,
           SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)) AS revenue
    FROM orders o JOIN order_items oi USING (order_id)
    WHERE o.status = 'completed' GROUP BY 1, 2
)
SELECT cur.mon AS month,
       ROUND(prev.revenue, 0) AS rev_2024,
       ROUND(cur.revenue, 0)  AS rev_2025,
       ROUND(100.0 * (cur.revenue - prev.revenue) / prev.revenue, 1) AS yoy_pct
FROM monthly cur JOIN monthly prev ON prev.mon = cur.mon AND prev.yr = cur.yr - 1
WHERE cur.yr = 2025
ORDER BY cur.mon;

-- 4.3 Day-of-week demand pattern
SELECT CASE strftime('%w', order_date)
           WHEN '0' THEN 'Sun' WHEN '1' THEN 'Mon' WHEN '2' THEN 'Tue' WHEN '3' THEN 'Wed'
           WHEN '4' THEN 'Thu' WHEN '5' THEN 'Fri' ELSE 'Sat' END AS weekday,
       COUNT(*) AS orders
FROM orders WHERE status = 'completed'
GROUP BY strftime('%w', order_date)
ORDER BY strftime('%w', order_date);

-- 4.4 Days between a customer's consecutive orders (LAG)
WITH gaps AS (
    SELECT customer_id, order_date,
           julianday(order_date) - julianday(LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date)) AS gap_days
    FROM orders WHERE status = 'completed'
)
SELECT ROUND(AVG(gap_days), 1) AS avg_days_between_orders,
       COUNT(gap_days) AS repeat_orders
FROM gaps;

-- 4.5 Each customer's first order and its category (ROW_NUMBER)
WITH ranked AS (
    SELECT o.customer_id, p.category,
           ROW_NUMBER() OVER (PARTITION BY o.customer_id ORDER BY o.order_date, o.order_id, oi.order_item_id) AS rn
    FROM orders o JOIN order_items oi USING (order_id) JOIN products p USING (product_id)
    WHERE o.status = 'completed'
)
SELECT category AS first_purchase_category, COUNT(*) AS customers
FROM ranked WHERE rn = 1
GROUP BY category ORDER BY customers DESC;
