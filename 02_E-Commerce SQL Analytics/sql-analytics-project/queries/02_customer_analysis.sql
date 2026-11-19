-- 02 | CUSTOMER ANALYSIS

-- 2.1 RFM segmentation (Recency, Frequency, Monetary) using NTILE
WITH cust AS (
    SELECT o.customer_id,
           CAST(julianday('2025-12-31') - julianday(MAX(o.order_date)) AS INT) AS recency_days,
           COUNT(DISTINCT o.order_id) AS frequency,
           SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)) AS monetary
    FROM orders o JOIN order_items oi USING (order_id)
    WHERE o.status = 'completed'
    GROUP BY o.customer_id
),
scored AS (
    SELECT *,
           NTILE(4) OVER (ORDER BY recency_days DESC) AS r,   -- 4 = most recent
           NTILE(4) OVER (ORDER BY frequency)         AS f,
           NTILE(4) OVER (ORDER BY monetary)          AS m
    FROM cust
)
SELECT CASE
           WHEN r >= 3 AND f >= 3 AND m >= 3 THEN 'Champions'
           WHEN r >= 3 AND f >= 2             THEN 'Loyal'
           WHEN r >= 3                        THEN 'New / Promising'
           WHEN r <= 2 AND f >= 3             THEN 'At Risk'
           ELSE 'Hibernating'
       END AS segment,
       COUNT(*) AS customers,
       ROUND(AVG(monetary), 0) AS avg_spend
FROM scored
GROUP BY segment
ORDER BY avg_spend DESC;

-- 2.2 Repeat purchase rate
WITH counts AS (
    SELECT customer_id, COUNT(*) AS n
    FROM orders WHERE status = 'completed'
    GROUP BY customer_id
)
SELECT COUNT(*) AS buyers,
       SUM(n > 1) AS repeat_buyers,
       ROUND(100.0 * SUM(n > 1) / COUNT(*), 1) AS repeat_rate_pct
FROM counts;

-- 2.3 Monthly cohort retention (signup month -> months since signup)
WITH cohort AS (
    SELECT customer_id, strftime('%Y-%m', signup_date) AS cohort_month FROM customers
),
activity AS (
    SELECT DISTINCT o.customer_id, strftime('%Y-%m', o.order_date) AS active_month
    FROM orders o WHERE o.status = 'completed'
),
joined AS (
    SELECT c.cohort_month,
           (CAST(substr(a.active_month,1,4) AS INT) - CAST(substr(c.cohort_month,1,4) AS INT)) * 12
         + (CAST(substr(a.active_month,6,2) AS INT) - CAST(substr(c.cohort_month,6,2) AS INT)) AS month_n,
           a.customer_id
    FROM cohort c JOIN activity a USING (customer_id)
),
sizes AS (SELECT cohort_month, COUNT(*) AS size FROM cohort GROUP BY 1)
SELECT j.cohort_month, s.size,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN month_n = 0 THEN customer_id END) / s.size, 0) AS m0,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN month_n = 1 THEN customer_id END) / s.size, 0) AS m1,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN month_n = 2 THEN customer_id END) / s.size, 0) AS m2,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN month_n = 3 THEN customer_id END) / s.size, 0) AS m3
FROM joined j JOIN sizes s USING (cohort_month)
WHERE j.cohort_month <= '2025-06'
GROUP BY j.cohort_month
ORDER BY j.cohort_month;

-- 2.4 Lifetime value by acquisition channel
SELECT c.channel,
       COUNT(DISTINCT c.customer_id) AS customers,
       ROUND(COALESCE(SUM(oi.quantity * oi.unit_price * (1 - o.discount_pct/100.0)), 0)
             / COUNT(DISTINCT c.customer_id), 0) AS avg_ltv
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id AND o.status = 'completed'
LEFT JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY c.channel
ORDER BY avg_ltv DESC;
