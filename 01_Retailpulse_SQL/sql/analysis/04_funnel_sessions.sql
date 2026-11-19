-- =====================================================================
-- 04_funnel_sessions.sql
-- Techniques: sessionisation of raw clickstream (gaps-and-islands with
-- LAG + running SUM), funnel conversion, BOOL_OR, consecutive-month
-- streaks (another gaps-and-islands variant).
-- =====================================================================
SET search_path TO retail;

-- ---------------------------------------------------------------------
-- Q0. Build sessions: a new session starts when a customer is inactive
--     for > 30 minutes. Stored as a TEMP VIEW reused by Q1-Q3.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW sessions AS
WITH flagged AS (
    SELECT e.*,
           CASE WHEN event_ts - LAG(event_ts) OVER (PARTITION BY customer_id ORDER BY event_ts)
                     <= INTERVAL '30 minutes' THEN 0 ELSE 1 END AS is_new_session
    FROM retail.web_events e
),
numbered AS (
    SELECT *,
           SUM(is_new_session) OVER (PARTITION BY customer_id ORDER BY event_ts, event_id) AS session_no
    FROM flagged
)
SELECT customer_id,
       customer_id || '-' || session_no                       AS session_id,
       MIN(event_ts)                                          AS session_start,
       MAX(event_ts)                                          AS session_end,
       MODE() WITHIN GROUP (ORDER BY device)                  AS device,
       COUNT(*)                                               AS events,
       BOOL_OR(event_type = 'product_view')                   AS viewed_product,
       BOOL_OR(event_type = 'add_to_cart')                    AS added_to_cart,
       BOOL_OR(event_type = 'checkout')                       AS reached_checkout,
       BOOL_OR(event_type = 'purchase')                       AS purchased
FROM numbered
GROUP BY customer_id, session_no;

-- ---------------------------------------------------------------------
-- Q1. Funnel by device: step-to-step and overall conversion
-- ---------------------------------------------------------------------
WITH f AS (
    SELECT device,
           COUNT(*)                                  AS sessions,
           COUNT(*) FILTER (WHERE viewed_product)    AS product_view,
           COUNT(*) FILTER (WHERE added_to_cart)     AS add_to_cart,
           COUNT(*) FILTER (WHERE reached_checkout)  AS checkout,
           COUNT(*) FILTER (WHERE purchased)         AS purchase
    FROM sessions
    GROUP BY ROLLUP (device)
)
SELECT COALESCE(device, 'ALL')                                    AS device,
       sessions,
       ROUND(100.0 * product_view / sessions, 1)                  AS "visit>view %",
       ROUND(100.0 * add_to_cart  / NULLIF(product_view, 0), 1)   AS "view>cart %",
       ROUND(100.0 * checkout     / NULLIF(add_to_cart, 0), 1)    AS "cart>checkout %",
       ROUND(100.0 * purchase     / NULLIF(checkout, 0), 1)       AS "checkout>buy %",
       ROUND(100.0 * purchase     / sessions, 2)                  AS overall_cvr_pct
FROM f
ORDER BY device = 'ALL', device;   -- keeps the ALL row at the bottom

-- ---------------------------------------------------------------------
-- Q2. Cart abandonment rate by quarter (added to cart but no purchase)
-- ---------------------------------------------------------------------
SELECT to_char(date_trunc('quarter', session_start), 'YYYY-"Q"Q')         AS quarter,
       COUNT(*) FILTER (WHERE added_to_cart)                               AS carts,
       COUNT(*) FILTER (WHERE added_to_cart AND NOT purchased)             AS abandoned,
       ROUND(100.0 * COUNT(*) FILTER (WHERE added_to_cart AND NOT purchased)
                   / NULLIF(COUNT(*) FILTER (WHERE added_to_cart), 0), 1)  AS abandonment_pct
FROM sessions
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- Q3. Session quality: bounce rate, avg duration, events per session
-- ---------------------------------------------------------------------
SELECT device,
       COUNT(*)                                                            AS sessions,
       ROUND(100.0 * AVG((events = 1)::int), 1)                            AS bounce_rate_pct,
       ROUND(AVG(events), 2)                                               AS avg_events,
       to_char(AVG(session_end - session_start) FILTER (WHERE events > 1), 'MI"m "SS"s"') AS avg_duration_multi_event,
       ROUND(100.0 * AVG(purchased::int), 2)                               AS cvr_pct
FROM sessions
GROUP BY device
ORDER BY device;

-- ---------------------------------------------------------------------
-- Q4. Longest buying streak: consecutive months with >= 1 order
--     Classic gaps-and-islands: month_index - ROW_NUMBER() is constant
--     within an unbroken run of months.
-- ---------------------------------------------------------------------
WITH months AS (
    SELECT DISTINCT customer_id,
           (date_part('year', order_month) * 12 + date_part('month', order_month))::int AS month_idx
    FROM vw_valid_sales
),
islands AS (
    SELECT customer_id, month_idx,
           month_idx - ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY month_idx) AS grp
    FROM months
),
streaks AS (
    SELECT customer_id,
           COUNT(*)                                                   AS streak_months,
           make_date(MIN(month_idx - 1) / 12, (MIN(month_idx - 1) % 12) + 1, 1) AS streak_start
    FROM islands
    GROUP BY customer_id, grp
),
best AS (
    SELECT DISTINCT ON (customer_id) *
    FROM streaks
    ORDER BY customer_id, streak_months DESC, streak_start
)
SELECT b.customer_id, c.full_name, c.city, b.streak_months, b.streak_start,
       (b.streak_start + (b.streak_months - 1) * INTERVAL '1 month')::date AS streak_end
FROM best b
JOIN customers c USING (customer_id)
ORDER BY b.streak_months DESC, b.streak_start
LIMIT 10;

-- Distribution of best streaks
WITH months AS (
    SELECT DISTINCT customer_id,
           (date_part('year', order_month) * 12 + date_part('month', order_month))::int AS m
    FROM vw_valid_sales
), runs AS (
    SELECT customer_id, COUNT(*) AS len
    FROM (SELECT customer_id, m - ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY m) AS g FROM months) t
    GROUP BY customer_id, g
)
SELECT best_streak, COUNT(*) AS customers
FROM (SELECT customer_id, MAX(len) AS best_streak FROM runs GROUP BY customer_id) x
GROUP BY best_streak
ORDER BY best_streak;
