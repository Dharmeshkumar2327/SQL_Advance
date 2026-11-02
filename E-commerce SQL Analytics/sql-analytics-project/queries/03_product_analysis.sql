-- 03 | PRODUCT ANALYSIS

-- 3.1 Top 10 products by profit
SELECT p.name, p.category,
       SUM(oi.quantity) AS units,
       ROUND(SUM(oi.quantity * (oi.unit_price * (1 - o.discount_pct/100.0) - p.cost)), 0) AS profit
FROM order_items oi
JOIN orders o USING (order_id)
JOIN products p USING (product_id)
WHERE o.status = 'completed'
GROUP BY p.product_id
ORDER BY profit DESC
LIMIT 10;

-- 3.2 Pareto / ABC analysis: which products drive 80% of revenue?
WITH rev AS (
    SELECT p.name,
           SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)) AS revenue
    FROM order_items oi JOIN orders o USING (order_id) JOIN products p USING (product_id)
    WHERE o.status = 'completed'
    GROUP BY p.product_id
),
cum AS (
    SELECT name, revenue,
           100.0 * SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER () AS cum_pct
    FROM rev
)
SELECT name, ROUND(revenue, 0) AS revenue, ROUND(cum_pct, 1) AS cum_pct,
       CASE WHEN cum_pct <= 80 THEN 'A' WHEN cum_pct <= 95 THEN 'B' ELSE 'C' END AS abc_class
FROM cum
ORDER BY revenue DESC;

-- 3.3 Return rate by category
SELECT p.category,
       COUNT(DISTINCT o.order_id) AS orders,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.status = 'returned' THEN o.order_id END)
             / COUNT(DISTINCT o.order_id), 1) AS return_rate_pct
FROM orders o JOIN order_items oi USING (order_id) JOIN products p USING (product_id)
GROUP BY p.category
ORDER BY return_rate_pct DESC;

-- 3.4 Market basket: products most often bought together (self-join)
SELECT a.name AS product_a, b.name AS product_b, COUNT(*) AS times_together
FROM order_items x
JOIN order_items y ON x.order_id = y.order_id AND x.product_id < y.product_id
JOIN products a ON a.product_id = x.product_id
JOIN products b ON b.product_id = y.product_id
GROUP BY x.product_id, y.product_id
ORDER BY times_together DESC
LIMIT 10;
