-- =====================================================================
-- 03_product_analytics.sql
-- Techniques: cumulative windows (ABC), self-joins (market basket with
-- support / confidence / lift), LATERAL top-N, anti-joins, SCD2 analysis.
-- =====================================================================
SET search_path TO retail;

-- ---------------------------------------------------------------------
-- Q1. ABC inventory classification by cumulative revenue share
--     A = top 80% of revenue, B = next 15%, C = last 5%
-- ---------------------------------------------------------------------
WITH prod_rev AS (
    SELECT i.product_id, SUM(i.line_revenue) AS revenue
    FROM order_items i JOIN orders o USING (order_id)
    WHERE o.status IN ('Delivered', 'Shipped')
    GROUP BY i.product_id
),
cum AS (
    SELECT product_id, revenue,
           SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)
         / SUM(revenue) OVER ()                                     AS cum_share
    FROM prod_rev
),
classed AS (
    SELECT *, CASE WHEN cum_share <= 0.80 THEN 'A'
                   WHEN cum_share <= 0.95 THEN 'B' ELSE 'C' END    AS abc_class
    FROM cum
)
SELECT abc_class,
       COUNT(*)                                              AS products,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct_of_catalogue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1) AS pct_of_revenue
FROM classed
GROUP BY abc_class
ORDER BY abc_class;

-- ---------------------------------------------------------------------
-- Q2. Market-basket analysis at sub-category level
--     support    = P(A and B)
--     confidence = P(B | A)
--     lift       = confidence / P(B)   (>1 means bought together more than chance)
-- ---------------------------------------------------------------------
WITH basket AS (            -- distinct sub-categories per valid order
    SELECT DISTINCT i.order_id, c.category_name AS item
    FROM order_items i
    JOIN orders o     ON o.order_id = i.order_id AND o.status IN ('Delivered','Shipped')
    JOIN products p   ON p.product_id = i.product_id
    JOIN categories c ON c.category_id = p.category_id
),
n AS (SELECT COUNT(DISTINCT order_id)::numeric AS total FROM basket),
item_freq AS (SELECT item, COUNT(*) AS cnt FROM basket GROUP BY item),
pairs AS (
    SELECT a.item AS item_a, b.item AS item_b, COUNT(*) AS together
    FROM basket a
    JOIN basket b ON a.order_id = b.order_id AND a.item < b.item     -- each pair once
    GROUP BY a.item, b.item
)
SELECT p.item_a, p.item_b, p.together,
       ROUND(100 * p.together / n.total, 2)                         AS support_pct,
       ROUND(100.0 * p.together / fa.cnt, 1)                        AS confidence_a_to_b_pct,
       ROUND((p.together / n.total) / ((fa.cnt / n.total) * (fb.cnt / n.total)), 2) AS lift
FROM pairs p
CROSS JOIN n
JOIN item_freq fa ON fa.item = p.item_a
JOIN item_freq fb ON fb.item = p.item_b
WHERE p.together >= 30                                              -- minimum support
ORDER BY lift DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- Q3. Top 3 products in every sub-category (LATERAL "top-N per group")
-- ---------------------------------------------------------------------
SELECT c.category_name, t.rn, t.product_name, t.units, t.revenue
FROM categories c
CROSS JOIN LATERAL (
    SELECT ROW_NUMBER() OVER (ORDER BY SUM(i.line_revenue) DESC) AS rn,
           p.product_name, SUM(i.quantity) AS units, SUM(i.line_revenue) AS revenue
    FROM products p
    JOIN order_items i ON i.product_id = p.product_id
    JOIN orders o      ON o.order_id = i.order_id AND o.status IN ('Delivered','Shipped')
    WHERE p.category_id = c.category_id
    GROUP BY p.product_id, p.product_name
    ORDER BY revenue DESC
    LIMIT 3
) t
WHERE c.parent_category_id IS NOT NULL
ORDER BY c.category_name, t.rn;

-- ---------------------------------------------------------------------
-- Q4. Return-rate hot-spots: sub-categories above the company average,
--     with their most common return reason (MODE)
-- ---------------------------------------------------------------------
WITH lines AS (
    SELECT c.category_name, i.order_item_id, r.reason,
           (r.return_id IS NOT NULL)::int AS returned
    FROM order_items i
    JOIN orders o     ON o.order_id = i.order_id AND o.status <> 'Cancelled'
    JOIN products p   ON p.product_id = i.product_id
    JOIN categories c ON c.category_id = p.category_id
    LEFT JOIN returns r ON r.order_item_id = i.order_item_id
),
by_cat AS (
    SELECT category_name,
           COUNT(*)                                  AS lines_sold,
           SUM(returned)                             AS lines_returned,
           ROUND(100.0 * AVG(returned), 2)           AS return_rate_pct,
           MODE() WITHIN GROUP (ORDER BY reason)     AS top_reason      -- NULLs ignored
    FROM lines GROUP BY category_name
)
SELECT *,
       ROUND(return_rate_pct - AVG(return_rate_pct) OVER (), 2) AS vs_avg_pp,
       CASE WHEN return_rate_pct > AVG(return_rate_pct) OVER () THEN 'Above avg' ELSE '' END AS flag
FROM by_cat
ORDER BY return_rate_pct DESC;

-- ---------------------------------------------------------------------
-- Q5. Did the 1-Jun-2024 price rise hurt demand? Difference-in-differences
--     Treatment = products whose price changed (2 rows in SCD2 history)
--     Control   = products whose price stayed flat
--     Compare 6 months before vs 6 months after; DiD removes overall growth.
-- ---------------------------------------------------------------------
WITH grp AS (
    SELECT p.product_id,
           CASE WHEN COUNT(h.price_id) = 2 THEN 'Treatment (price +9%)' ELSE 'Control (no change)' END AS grp
    FROM products p
    JOIN product_price_history h ON h.product_id = p.product_id
    WHERE p.launch_date < DATE '2023-12-01'              -- on sale for the whole window
    GROUP BY p.product_id
),
units AS (
    SELECT g.grp,
           COUNT(DISTINCT g.product_id) AS products,
           SUM(i.quantity) FILTER (WHERE o.order_ts >= '2023-12-01' AND o.order_ts < '2024-06-01') AS before_units,
           SUM(i.quantity) FILTER (WHERE o.order_ts >= '2024-06-01' AND o.order_ts < '2024-12-01') AS after_units
    FROM grp g
    JOIN order_items i ON i.product_id = g.product_id
    JOIN orders o      ON o.order_id = i.order_id AND o.status <> 'Cancelled'
    GROUP BY g.grp
)
SELECT grp, products, before_units, after_units,
       ROUND(100.0 * (after_units::numeric / before_units - 1), 1) AS growth_pct,
       ROUND(100.0 * (after_units::numeric / before_units - 1)
           - FIRST_VALUE(100.0 * (after_units::numeric / before_units - 1))
               OVER (ORDER BY grp), 1)                              AS diff_vs_control_pp
FROM units
ORDER BY grp;

-- ---------------------------------------------------------------------
-- Q6. Products losing momentum: Q4-2025 units vs Q4-2024 (same season,
--     so the Diwali spike doesn't distort it). Lowest YoY growth first.
-- ---------------------------------------------------------------------
WITH v AS (
    SELECT p.product_id, p.product_name, c.category_name,
           COALESCE(SUM(i.quantity) FILTER (WHERE o.order_ts >= '2025-10-01' AND o.order_ts < '2026-01-01'), 0) AS q4_2025,
           COALESCE(SUM(i.quantity) FILTER (WHERE o.order_ts >= '2024-10-01' AND o.order_ts < '2025-01-01'), 0) AS q4_2024
    FROM products p
    JOIN categories c ON c.category_id = p.category_id
    LEFT JOIN order_items i ON i.product_id = p.product_id
    LEFT JOIN orders o      ON o.order_id = i.order_id AND o.status <> 'Cancelled'
    WHERE p.is_active
    GROUP BY p.product_id, p.product_name, c.category_name
)
SELECT product_id, product_name, category_name, q4_2024, q4_2025,
       ROUND(100.0 * (q4_2025::numeric / NULLIF(q4_2024, 0) - 1), 1) AS yoy_units_pct
FROM v
WHERE q4_2024 >= 10                       -- ignore tiny-volume noise
ORDER BY yoy_units_pct
LIMIT 10;
