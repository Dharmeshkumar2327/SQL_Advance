-- =====================================================================
-- 01_sales_performance.sql
-- Techniques: window functions (LAG, running SUM, moving AVG, RANK,
-- PERCENT_RANK), date spines, ROLLUP / GROUPING SETS, FILTER pivots.
-- =====================================================================
SET search_path TO retail;

-- ---------------------------------------------------------------------
-- Q1. Monthly revenue with MoM %, YoY %, YTD running total, 3-month MA
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT order_month, SUM(gross_revenue) AS revenue, COUNT(*) AS orders
    FROM vw_valid_sales
    GROUP BY order_month
)
SELECT order_month,
       orders,
       revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER w) / LAG(revenue) OVER w, 1)          AS mom_growth_pct,
       ROUND(100.0 * (revenue - LAG(revenue, 12) OVER w) / LAG(revenue, 12) OVER w, 1)  AS yoy_growth_pct,
       SUM(revenue) OVER (PARTITION BY date_part('year', order_month) ORDER BY order_month) AS ytd_revenue,
       ROUND(AVG(revenue) OVER (w ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)         AS moving_avg_3m
FROM monthly
WINDOW w AS (ORDER BY order_month)
ORDER BY order_month;

-- ---------------------------------------------------------------------
-- Q2. Daily revenue on a complete date spine (days with zero sales are
--     kept) + 7-day rolling average. Shows the "Diwali" window, 2025.
-- ---------------------------------------------------------------------
WITH spine AS (
    SELECT d::date AS day
    FROM generate_series(DATE '2025-10-01', DATE '2025-11-30', INTERVAL '1 day') d
),
daily AS (
    SELECT order_date, SUM(gross_revenue) AS revenue
    FROM vw_valid_sales
    WHERE order_date BETWEEN '2025-10-01' AND '2025-11-30'
    GROUP BY order_date
)
SELECT s.day,
       to_char(s.day, 'Dy')                     AS weekday,
       COALESCE(d.revenue, 0)                   AS revenue,
       ROUND(AVG(COALESCE(d.revenue, 0)) OVER (ORDER BY s.day ROWS 6 PRECEDING), 0) AS rolling_7d_avg
FROM spine s
LEFT JOIN daily d ON d.order_date = s.day
ORDER BY s.day;

-- ---------------------------------------------------------------------
-- Q3. Revenue by parent category > sub-category with subtotals (ROLLUP)
--     GROUPING() tells a real NULL apart from a subtotal row.
-- ---------------------------------------------------------------------
WITH total AS (SELECT SUM(gross_revenue) AS t FROM vw_valid_sales)
SELECT CASE WHEN GROUPING(pc.category_name) = 1 THEN '** GRAND TOTAL **'
            ELSE pc.category_name END                         AS parent_category,
       CASE WHEN GROUPING(pc.category_name) = 1 THEN ''
            WHEN GROUPING(c.category_name)  = 1 THEN '-- subtotal --'
            ELSE c.category_name END                          AS sub_category,
       SUM(i.line_revenue)                                    AS revenue,
       ROUND(100.0 * SUM(i.line_revenue) / MAX(total.t), 2)   AS pct_of_total
FROM orders o
JOIN order_items i ON i.order_id = o.order_id
JOIN products p    ON p.product_id = i.product_id
JOIN categories c  ON c.category_id = p.category_id
JOIN categories pc ON pc.category_id = c.parent_category_id
CROSS JOIN total
WHERE o.status IN ('Delivered', 'Shipped')
GROUP BY ROLLUP (pc.category_name, c.category_name)   -- = GROUPING SETS ((pc,c), (pc), ())
ORDER BY GROUPING(pc.category_name), pc.category_name, GROUPING(c.category_name) DESC, revenue DESC;

-- ---------------------------------------------------------------------
-- Q4. Pivot: revenue (in lakh INR) by region x year using FILTER
-- ---------------------------------------------------------------------
SELECT c.region,
       ROUND(SUM(v.gross_revenue) FILTER (WHERE date_part('year', v.order_date) = 2023) / 1e5, 1) AS "2023_lakh",
       ROUND(SUM(v.gross_revenue) FILTER (WHERE date_part('year', v.order_date) = 2024) / 1e5, 1) AS "2024_lakh",
       ROUND(SUM(v.gross_revenue) FILTER (WHERE date_part('year', v.order_date) = 2025) / 1e5, 1) AS "2025_lakh",
       ROUND(100.0 * (SUM(v.gross_revenue) FILTER (WHERE date_part('year', v.order_date) = 2025)
                    / NULLIF(SUM(v.gross_revenue) FILTER (WHERE date_part('year', v.order_date) = 2024), 0) - 1), 1)
                                                                   AS growth_25_vs_24_pct
FROM vw_valid_sales v
JOIN customers c ON c.customer_id = v.customer_id
GROUP BY c.region
ORDER BY "2025_lakh" DESC;

-- ---------------------------------------------------------------------
-- Q5. Festive-season uplift: avg daily revenue during Diwali window
--     (10 Oct - 19 Nov) vs rest of year
-- ---------------------------------------------------------------------
WITH tagged AS (
    SELECT date_part('year', order_date)::int AS yr,
           order_date,
           gross_revenue,
           (to_char(order_date, 'MMDD') BETWEEN '1010' AND '1119') AS is_festive
    FROM vw_valid_sales
)
SELECT yr,
       ROUND(SUM(gross_revenue) FILTER (WHERE is_festive)     / 41, 0)  AS festive_avg_daily,
       ROUND(SUM(gross_revenue) FILTER (WHERE NOT is_festive) / (CASE WHEN yr % 4 = 0 THEN 366 ELSE 365 END - 41), 0)
                                                                     AS normal_avg_daily,
       ROUND(  (SUM(gross_revenue) FILTER (WHERE is_festive) / 41)
             / (SUM(gross_revenue) FILTER (WHERE NOT is_festive) / (CASE WHEN yr % 4 = 0 THEN 366 ELSE 365 END - 41)), 2)
                                                                     AS uplift_x
FROM tagged
GROUP BY yr
ORDER BY yr;

-- ---------------------------------------------------------------------
-- Q6. Account-manager leaderboard 2025: rank inside region, percentile
--     across company, share of regional revenue
-- ---------------------------------------------------------------------
WITH am_rev AS (
    SELECT e.employee_id, e.full_name, e.region,
           SUM(v.gross_revenue)            AS revenue,
           COUNT(DISTINCT v.customer_id)   AS active_customers
    FROM vw_valid_sales v
    JOIN customers c ON c.customer_id = v.customer_id
    JOIN employees e ON e.employee_id = c.account_manager_id
    WHERE v.order_date >= '2025-01-01'
    GROUP BY e.employee_id, e.full_name, e.region
)
SELECT region, full_name, active_customers, revenue,
       RANK() OVER (PARTITION BY region ORDER BY revenue DESC)                     AS rank_in_region,
       ROUND(100.0 * revenue / SUM(revenue) OVER (PARTITION BY region), 1)        AS pct_of_region,
       ROUND(PERCENT_RANK() OVER (ORDER BY revenue)::numeric, 2)                    AS company_percentile
FROM am_rev
ORDER BY region, rank_in_region;
