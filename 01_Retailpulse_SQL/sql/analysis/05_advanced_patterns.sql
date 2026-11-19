-- =====================================================================
-- 05_advanced_patterns.sql
-- Techniques: recursive CTEs (org chart + roll-up, category paths),
-- statistical anomaly detection with window frames, as-of joins,
-- ordered-set aggregates, JSON output, data-quality assertions.
-- =====================================================================
SET search_path TO retail;

-- ---------------------------------------------------------------------
-- Q1. Recursive org chart with level, reporting path, and the 2025
--     revenue of each manager's ENTIRE sub-tree (not just direct reports)
-- ---------------------------------------------------------------------
WITH RECURSIVE org AS (
    SELECT employee_id, full_name, job_title, manager_id,
           1 AS lvl,
           full_name::text AS path,
           ARRAY[employee_id] AS chain
    FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.employee_id, e.full_name, e.job_title, e.manager_id,
           o.lvl + 1,
           o.path || ' > ' || e.full_name,
           o.chain || e.employee_id
    FROM employees e
    JOIN org o ON e.manager_id = o.employee_id
),
am_revenue AS (                                  -- revenue owned by each account manager
    SELECT c.account_manager_id AS employee_id, SUM(v.gross_revenue) AS revenue
    FROM vw_valid_sales v JOIN customers c USING (customer_id)
    WHERE v.order_date >= '2025-01-01'
    GROUP BY c.account_manager_id
)
SELECT repeat('    ', o.lvl - 1) || o.full_name               AS employee,
       o.job_title,
       o.lvl,
       ROUND(SUM(ar.revenue) / 1e5, 1)                        AS subtree_revenue_lakh,
       COUNT(ar.employee_id)                                  AS account_mgrs_below
FROM org o
JOIN org d       ON o.employee_id = ANY (d.chain)            -- d is o itself or any descendant
LEFT JOIN am_revenue ar ON ar.employee_id = d.employee_id
GROUP BY o.employee_id, o.full_name, o.job_title, o.lvl, o.path
ORDER BY o.path;

-- ---------------------------------------------------------------------
-- Q2. Recursive category breadcrumb (works for any tree depth)
-- ---------------------------------------------------------------------
WITH RECURSIVE tree AS (
    SELECT category_id, category_name, parent_category_id,
           category_name::text AS breadcrumb, 0 AS depth
    FROM categories WHERE parent_category_id IS NULL
    UNION ALL
    SELECT c.category_id, c.category_name, c.parent_category_id,
           t.breadcrumb || ' / ' || c.category_name, t.depth + 1
    FROM categories c JOIN tree t ON c.parent_category_id = t.category_id
)
SELECT t.breadcrumb, t.depth, COUNT(p.product_id) AS products
FROM tree t
LEFT JOIN products p ON p.category_id = t.category_id
GROUP BY t.breadcrumb, t.depth
ORDER BY t.breadcrumb;

-- ---------------------------------------------------------------------
-- Q3. Anomaly detection: days whose revenue is > 2.5 standard deviations
--     from the trailing 28-day mean (excludes the current day from baseline)
-- ---------------------------------------------------------------------
WITH spine AS (
    SELECT d::date AS day FROM generate_series(DATE '2024-01-01', DATE '2025-12-31', INTERVAL '1 day') d
),
daily AS (
    SELECT s.day, COALESCE(SUM(v.gross_revenue), 0) AS revenue
    FROM spine s LEFT JOIN vw_valid_sales v ON v.order_date = s.day
    GROUP BY s.day
),
stats AS (
    SELECT day, revenue,
           AVG(revenue)        OVER w AS mean_28d,
           STDDEV_SAMP(revenue) OVER w AS sd_28d
    FROM daily
    WINDOW w AS (ORDER BY day ROWS BETWEEN 28 PRECEDING AND 1 PRECEDING)
)
SELECT day, to_char(day, 'Dy') AS dow, revenue,
       ROUND(mean_28d)                               AS baseline,
       ROUND((revenue - mean_28d) / NULLIF(sd_28d, 0), 2) AS z_score,
       CASE WHEN revenue > mean_28d THEN 'Spike' ELSE 'Drop' END AS type
FROM stats
WHERE ABS((revenue - mean_28d) / NULLIF(sd_28d, 0)) > 2.5
ORDER BY ABS((revenue - mean_28d) / NULLIF(sd_28d, 0)) DESC
LIMIT 12;

-- ---------------------------------------------------------------------
-- Q4. As-of join: for every order line, what was the list price on the
--     order date (from SCD2 history) and was the customer charged it?
-- ---------------------------------------------------------------------
SELECT COUNT(*)                                                  AS lines_checked,
       COUNT(*) FILTER (WHERE i.unit_price = ph.price)           AS charged_correct_price,
       COUNT(*) FILTER (WHERE i.unit_price <> ph.price)          AS price_mismatches,
       COUNT(*) FILTER (WHERE ph.price IS NULL)                  AS no_price_on_date
FROM order_items i
JOIN orders o ON o.order_id = i.order_id
LEFT JOIN LATERAL (
    SELECT h.price
    FROM product_price_history h
    WHERE h.product_id = i.product_id
      AND h.valid_from <= o.order_ts::date
    ORDER BY h.valid_from DESC
    LIMIT 1                                                      -- latest version on/before date
) ph ON TRUE;

-- ---------------------------------------------------------------------
-- Q5. Distribution stats by channel with ordered-set aggregates
-- ---------------------------------------------------------------------
SELECT sales_channel,
       COUNT(*)                                                             AS orders,
       ROUND(AVG(gross_revenue))                                            AS mean_aov,
       ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY gross_revenue)::numeric) AS p25,
       ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gross_revenue)::numeric) AS median,
       ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY gross_revenue)::numeric) AS p90,
       MODE() WITHIN GROUP (ORDER BY payment_method)                        AS most_used_payment,
       ROUND(100.0 * AVG((payment_method = 'COD')::int), 1)                 AS cod_share_pct
FROM vw_valid_sales
GROUP BY sales_channel
ORDER BY orders DESC;

-- ---------------------------------------------------------------------
-- Q6. Customer-360 as JSON (API / app-ready nested document)
-- ---------------------------------------------------------------------
SELECT jsonb_pretty(
    jsonb_build_object(
        'customer_id', c.customer_id,
        'name',        c.full_name,
        'city',        c.city,
        'since',       c.signup_date,
        'lifetime_value', fn_customer_ltv(c.customer_id),
        'recent_orders', (
            SELECT jsonb_agg(jsonb_build_object(
                       'order_id', v.order_id, 'date', v.order_date,
                       'status', v.status, 'amount', v.gross_revenue)
                   ORDER BY v.order_ts DESC)
            FROM (SELECT * FROM vw_order_summary s
                  WHERE s.customer_id = c.customer_id
                  ORDER BY s.order_ts DESC LIMIT 3) v
        ),
        'favourite_category', (
            SELECT cat.category_name
            FROM order_items i
            JOIN orders o       ON o.order_id = i.order_id
            JOIN products p     ON p.product_id = i.product_id
            JOIN categories cat ON cat.category_id = p.category_id
            WHERE o.customer_id = c.customer_id
            GROUP BY cat.category_name
            ORDER BY SUM(i.quantity) DESC LIMIT 1
        )
    )) AS customer_360
FROM customers c
WHERE c.customer_id = (SELECT customer_id FROM vw_valid_sales
                       GROUP BY customer_id ORDER BY COUNT(*) DESC LIMIT 1);

-- ---------------------------------------------------------------------
-- Q7. Data-quality assertions - every check should return 0 failures.
--     (Pattern used in dbt tests / pipeline health checks.)
-- ---------------------------------------------------------------------
SELECT check_name, failures, CASE WHEN failures = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 'Orders without any line items' AS check_name,
           COUNT(*) AS failures
    FROM orders o WHERE NOT EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.order_id)
    UNION ALL
    SELECT 'Order placed before customer signup',
           COUNT(*) FROM orders o JOIN customers c USING (customer_id) WHERE o.order_ts::date < c.signup_date
    UNION ALL
    SELECT 'Product sold before launch date',
           COUNT(*) FROM order_items i JOIN orders o USING (order_id) JOIN products p USING (product_id)
           WHERE o.order_ts::date < p.launch_date
    UNION ALL
    SELECT 'Return dated before its order',
           COUNT(*) FROM returns r JOIN order_items i USING (order_item_id) JOIN orders o USING (order_id)
           WHERE r.return_date < o.order_ts::date
    UNION ALL
    SELECT 'Overlapping price-history periods',
           COUNT(*) FROM product_price_history a JOIN product_price_history b
             ON a.product_id = b.product_id AND a.price_id < b.price_id
            AND daterange(a.valid_from, a.valid_to) && daterange(b.valid_from, b.valid_to)
    UNION ALL
    SELECT 'Duplicate customer emails (case-insensitive)',
           COUNT(*) - COUNT(DISTINCT lower(email)) FROM customers
    UNION ALL
    SELECT 'Returned orders with no return record',
           COUNT(*) FROM orders o WHERE o.status = 'Returned'
           AND NOT EXISTS (SELECT 1 FROM order_items i JOIN returns r USING (order_item_id) WHERE i.order_id = o.order_id)
) checks
ORDER BY result, check_name;
