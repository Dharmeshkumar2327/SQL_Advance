-- =====================================================================
-- 02_customer_analytics.sql
-- Techniques: NTILE scoring, cohort matrices, PERCENTILE_CONT,
-- LAG-based inter-purchase gaps, cumulative distributions (Pareto).
-- Analysis date (as-of) = 2026-01-01
-- =====================================================================
SET search_path TO retail;

-- ---------------------------------------------------------------------
-- Q1. RFM segmentation (Recency, Frequency, Monetary) -> named segments
-- ---------------------------------------------------------------------
WITH rfm_raw AS (
    SELECT customer_id,
           DATE '2026-01-01' - MAX(order_date)  AS recency_days,
           COUNT(*)                             AS frequency,
           SUM(gross_revenue)                   AS monetary
    FROM vw_valid_sales
    GROUP BY customer_id
),
scored AS (
    SELECT *,
           NTILE(5) OVER (ORDER BY recency_days DESC)    AS r,   -- 5 = most recent
           NTILE(5) OVER (ORDER BY frequency, monetary)  AS f,   -- tie-break on spend
           NTILE(5) OVER (ORDER BY monetary)             AS m
    FROM rfm_raw
),
segmented AS (
    SELECT *,
           CASE
               WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Champions'
               WHEN r >= 3 AND f >= 3               THEN 'Loyal'
               WHEN r >= 4 AND f <= 2               THEN 'New / Promising'
               WHEN r = 3  AND f <= 2               THEN 'Need Attention'
               WHEN r <= 2 AND f >= 4               THEN 'Cannot Lose Them'
               WHEN r <= 2 AND f >= 2               THEN 'At Risk'
               ELSE 'Hibernating'
           END AS segment
    FROM scored
)
SELECT segment,
       COUNT(*)                                             AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS pct_customers,
       ROUND(AVG(recency_days))                             AS avg_recency_days,
       ROUND(AVG(frequency), 1)                             AS avg_orders,
       ROUND(AVG(monetary))                                 AS avg_spend,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_revenue
FROM segmented
GROUP BY segment
ORDER BY pct_revenue DESC;

-- ---------------------------------------------------------------------
-- Q2. Monthly cohort retention matrix (cohort = month of first order)
--     % of each cohort that purchased again in month M+1 ... M+6
-- ---------------------------------------------------------------------
WITH firsts AS (
    SELECT customer_id, MIN(order_month) AS cohort_month
    FROM vw_valid_sales GROUP BY customer_id
),
activity AS (
    SELECT DISTINCT v.customer_id, f.cohort_month,
           (date_part('year', v.order_month) - date_part('year', f.cohort_month)) * 12
         + (date_part('month', v.order_month) - date_part('month', f.cohort_month)) AS month_no
    FROM vw_valid_sales v JOIN firsts f USING (customer_id)
),
cohort_size AS (SELECT cohort_month, COUNT(*) AS n FROM firsts GROUP BY cohort_month)
SELECT a.cohort_month,
       cs.n                                                                          AS cohort_size,
       ROUND(100.0 * COUNT(*) FILTER (WHERE month_no = 1) / cs.n, 1)                 AS m1,
       ROUND(100.0 * COUNT(*) FILTER (WHERE month_no = 2) / cs.n, 1)                 AS m2,
       ROUND(100.0 * COUNT(*) FILTER (WHERE month_no = 3) / cs.n, 1)                 AS m3,
       ROUND(100.0 * COUNT(*) FILTER (WHERE month_no = 6) / cs.n, 1)                 AS m6,
       ROUND(100.0 * COUNT(*) FILTER (WHERE month_no = 12) / cs.n, 1)                AS m12
FROM activity a
JOIN cohort_size cs USING (cohort_month)
WHERE a.cohort_month BETWEEN '2024-01-01' AND '2024-12-01'
GROUP BY a.cohort_month, cs.n
ORDER BY a.cohort_month;

-- ---------------------------------------------------------------------
-- Q3. Customer value by acquisition channel: mean vs median LTV,
--     repeat rate, and median days between orders
-- ---------------------------------------------------------------------
WITH cust AS (
    SELECT c.customer_id, c.acquisition_channel,
           COUNT(v.order_id)                    AS orders,
           COALESCE(SUM(v.gross_revenue), 0)    AS ltv
    FROM customers c
    LEFT JOIN vw_valid_sales v ON v.customer_id = c.customer_id
    GROUP BY c.customer_id, c.acquisition_channel
),
gaps AS (
    SELECT c.acquisition_channel,
           v.order_date - LAG(v.order_date) OVER (PARTITION BY v.customer_id ORDER BY v.order_ts) AS gap_days
    FROM vw_valid_sales v JOIN customers c USING (customer_id)
)
SELECT cust.acquisition_channel,
       COUNT(*)                                                           AS customers,
       ROUND(100.0 * AVG((orders > 0)::int), 1)                           AS buyer_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE orders >= 2)
                   / NULLIF(COUNT(*) FILTER (WHERE orders >= 1), 0), 1)   AS repeat_rate_pct,
       ROUND(AVG(ltv) FILTER (WHERE orders > 0))                          AS mean_ltv,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ltv) FILTER (WHERE orders > 0)::numeric) AS median_ltv,
       (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY g.gap_days)
          FROM gaps g WHERE g.acquisition_channel = cust.acquisition_channel) AS median_days_between_orders
FROM cust
GROUP BY cust.acquisition_channel
ORDER BY mean_ltv DESC;

-- ---------------------------------------------------------------------
-- Q4. Churn-risk early warning: valuable customers whose silence is
--     > 2x their own typical gap between orders (personalised threshold)
-- ---------------------------------------------------------------------
WITH ordered AS (
    SELECT customer_id, order_date, gross_revenue,
           order_date - LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_ts) AS gap
    FROM vw_valid_sales
),
profile AS (
    SELECT customer_id,
           COUNT(*)                              AS orders,
           SUM(gross_revenue)                    AS lifetime_spend,
           MAX(order_date)                       AS last_order,
           AVG(gap)                              AS avg_gap_days
    FROM ordered
    GROUP BY customer_id
    HAVING COUNT(*) >= 3
)
SELECT p.customer_id, c.full_name, c.city, e.full_name AS account_manager,
       p.orders, p.lifetime_spend,
       ROUND(p.avg_gap_days)                     AS usual_gap_days,
       DATE '2026-01-01' - p.last_order          AS days_silent,
       ROUND((DATE '2026-01-01' - p.last_order) / p.avg_gap_days, 1) AS silence_ratio
FROM profile p
JOIN customers c ON c.customer_id = p.customer_id
JOIN employees e ON e.employee_id = c.account_manager_id
WHERE DATE '2026-01-01' - p.last_order > GREATEST(2 * p.avg_gap_days, 90)
ORDER BY p.lifetime_spend DESC
LIMIT 15;

-- ---------------------------------------------------------------------
-- Q5. Pareto check: what share of revenue comes from the top X% of buyers?
-- ---------------------------------------------------------------------
WITH spend AS (
    SELECT customer_id, SUM(gross_revenue) AS revenue
    FROM vw_valid_sales GROUP BY customer_id
),
ranked AS (
    SELECT revenue,
           CUME_DIST() OVER (ORDER BY revenue DESC)                       AS customer_pctile,
           SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER () AS revenue_share
    FROM spend
)
SELECT bucket AS top_customers,
       ROUND(100 * MAX(revenue_share) FILTER (WHERE customer_pctile <= cutoff), 1) AS pct_of_revenue
FROM ranked
CROSS JOIN (VALUES ('Top 1%', 0.01), ('Top 5%', 0.05), ('Top 10%', 0.10),
                   ('Top 20%', 0.20), ('Top 50%', 0.50)) AS b(bucket, cutoff)
GROUP BY bucket, cutoff
ORDER BY cutoff;

-- ---------------------------------------------------------------------
-- Q6. Time to second purchase - how fast do new buyers come back?
-- ---------------------------------------------------------------------
WITH numbered AS (
    SELECT customer_id, order_date,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_ts) AS n
    FROM vw_valid_sales
),
pairs AS (
    SELECT f.customer_id, s.order_date - f.order_date AS days_to_second
    FROM numbered f
    LEFT JOIN numbered s ON s.customer_id = f.customer_id AND s.n = 2
    WHERE f.n = 1
)
SELECT CASE WHEN days_to_second IS NULL THEN '6. Never (so far)'
            WHEN days_to_second <= 30  THEN '1. Within 30 days'
            WHEN days_to_second <= 90  THEN '2. 31-90 days'
            WHEN days_to_second <= 180 THEN '3. 91-180 days'
            WHEN days_to_second <= 365 THEN '4. 181-365 days'
            ELSE '5. Over a year' END                        AS bucket,
       COUNT(*)                                               AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)     AS pct
FROM pairs
GROUP BY 1
ORDER BY 1;
