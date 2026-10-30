-- =====================================================================
-- RetailPulse Analytics  |  02_seed_data.sql
-- Generates a realistic, reproducible synthetic dataset (2023-2025)
-- entirely in SQL using generate_series + seeded random().
-- ~5k customers, ~120 products, ~25k orders, ~60k order lines,
-- ~200k clickstream events. Runs in a few seconds.
-- =====================================================================
SET search_path TO retail;
SELECT setseed(0.42);   -- same data on every run

-- ---------- Categories (2-level hierarchy) ---------------------------
INSERT INTO categories (category_name, parent_category_id) VALUES
 ('Electronics', NULL), ('Fashion', NULL), ('Home & Kitchen', NULL),
 ('Books & Stationery', NULL), ('Beauty', NULL);

INSERT INTO categories (category_name, parent_category_id)
SELECT c.child, p.category_id
FROM (VALUES
  ('Mobiles','Electronics'), ('Laptops','Electronics'), ('Audio','Electronics'), ('Accessories','Electronics'),
  ('Menswear','Fashion'), ('Womenswear','Fashion'), ('Footwear','Fashion'),
  ('Appliances','Home & Kitchen'), ('Cookware','Home & Kitchen'), ('Decor','Home & Kitchen'),
  ('Books','Books & Stationery'), ('Stationery','Books & Stationery'),
  ('Skincare','Beauty'), ('Haircare','Beauty')
) AS c(child, parent)
JOIN categories p ON p.category_name = c.parent;

-- ---------- Products --------------------------------------------------
WITH leaf AS (
    SELECT c.category_id, c.category_name,
           r.min_price, r.max_price, r.margin
    FROM categories c
    JOIN (VALUES
      ('Mobiles', 8000, 70000, 0.18), ('Laptops', 30000, 120000, 0.15),
      ('Audio', 800, 15000, 0.35),    ('Accessories', 200, 3000, 0.50),
      ('Menswear', 400, 4000, 0.55),  ('Womenswear', 500, 6000, 0.55),
      ('Footwear', 700, 8000, 0.45),  ('Appliances', 1500, 45000, 0.25),
      ('Cookware', 300, 5000, 0.40),  ('Decor', 250, 6000, 0.60),
      ('Books', 150, 1200, 0.30),     ('Stationery', 50, 800, 0.50),
      ('Skincare', 200, 2500, 0.60),  ('Haircare', 150, 1800, 0.55)
    ) AS r(name, min_price, max_price, margin) ON r.name = c.category_name
),
brands AS (SELECT ARRAY['Nova','Aura','Vertex','Lumo','Orbit','Kiara','Tara','Zenith','Sutra','Indus'] AS b),
gen AS (
    SELECT l.*, g.n,
           ROUND((l.min_price + random() * (l.max_price - l.min_price))::numeric, -1) AS price
    FROM leaf l CROSS JOIN generate_series(1, 9) AS g(n)        -- 14 leaves x 9 = 126 products
)
INSERT INTO products (product_name, category_id, unit_cost, list_price, launch_date, is_active)
SELECT (SELECT b[1 + ((gen.n + gen.category_id) % 10)] FROM brands) || ' ' || gen.category_name || ' ' ||
       chr(64 + gen.n) || (100 + (random() * 899)::int),
       gen.category_id,
       ROUND(gen.price * (1 - gen.margin), 2),
       gen.price,
       DATE '2022-01-01' + (random() * 900)::int,                   -- some launch mid-2024
       random() > 0.05
FROM gen;

-- ---------- Price history (SCD Type 2) ---------------------------------
-- Even-numbered products got a ~9% price rise on 2024-06-01 (treatment
-- group); odd-numbered products kept one price (control group).
INSERT INTO product_price_history (product_id, price, valid_from, valid_to)
SELECT product_id, ROUND(list_price * 0.92, 2), launch_date, DATE '2024-06-01'
FROM products WHERE launch_date < DATE '2024-06-01' AND product_id % 2 = 0
UNION ALL
SELECT product_id, list_price,
       CASE WHEN product_id % 2 = 0 THEN GREATEST(launch_date, DATE '2024-06-01') ELSE launch_date END,
       NULL
FROM products;

-- ---------- Employees (4-level org chart) ------------------------------
INSERT INTO employees (full_name, job_title, manager_id, hire_date, region) VALUES
 ('Ananya Rao',     'CEO',               NULL, '2018-04-01', 'All'),
 ('Vikram Mehta',   'VP Sales',          1,    '2019-01-15', 'All'),
 ('Sneha Iyer',     'VP Customer Success',1,   '2019-06-10', 'All'),
 ('Rohit Sharma',   'Regional Manager',  2,    '2020-02-01', 'North'),
 ('Lakshmi Nair',   'Regional Manager',  2,    '2020-03-12', 'South'),
 ('Arjun Patel',    'Regional Manager',  3,    '2020-07-20', 'West'),
 ('Priya Das',      'Regional Manager',  3,    '2021-01-05', 'East');

INSERT INTO employees (full_name, job_title, manager_id, hire_date, region)
SELECT f.first || ' ' || l.last, 'Account Manager', rm.employee_id,
       DATE '2021-01-01' + (random() * 900)::int, rm.region
FROM employees rm
CROSS JOIN LATERAL (SELECT (ARRAY['Karan','Meera','Aditya','Divya','Rahul','Pooja','Siddharth','Neha','Varun','Kavya','Manish','Ishita'])[1 + ((rm.employee_id * 3 + g) % 12)] AS first, g
                    FROM generate_series(1, 3) g) f
CROSS JOIN LATERAL (SELECT (ARRAY['Gupta','Reddy','Singh','Menon','Joshi','Kulkarni','Bose','Verma'])[1 + ((rm.employee_id + f.g * 5) % 8)] AS last) l
WHERE rm.job_title = 'Regional Manager';

-- ---------- Customers ---------------------------------------------------
WITH cities(city, state, region, w) AS (VALUES
  ('Bengaluru','Karnataka','South',14), ('Chennai','Tamil Nadu','South',8), ('Hyderabad','Telangana','South',9),
  ('Kochi','Kerala','South',4),         ('Mumbai','Maharashtra','West',13), ('Pune','Maharashtra','West',7),
  ('Ahmedabad','Gujarat','West',5),     ('Delhi','Delhi','North',14),       ('Jaipur','Rajasthan','North',4),
  ('Lucknow','Uttar Pradesh','North',4),('Chandigarh','Punjab','North',3),  ('Kolkata','West Bengal','East',8),
  ('Patna','Bihar','East',3),           ('Bhubaneswar','Odisha','East',2),  ('Guwahati','Assam','East',2)
),
weighted AS (       -- expand by weight so random pick follows population share
  SELECT c.city, c.state, c.region, row_number() OVER () AS rn
  FROM cities c CROSS JOIN LATERAL generate_series(1, c.w)
),
fn AS (SELECT ARRAY['Aarav','Vivaan','Aditya','Ishaan','Reyansh','Ananya','Diya','Saanvi','Aadhya','Myra',
                    'Rohan','Kabir','Arnav','Priya','Riya','Nikhil','Tanvi','Harsh','Sanya','Yash'] AS a),
ln AS (SELECT ARRAY['Sharma','Verma','Iyer','Nair','Reddy','Patel','Shah','Das','Ghosh','Singh',
                    'Kumar','Mishra','Pillai','Rao','Jain','Chopra'] AS a),
base AS (
  SELECT g AS n,
         1 + floor(random() * (SELECT count(*) FROM weighted))::int AS city_rn,
         -- power(<1) skews signups toward later dates => steady business growth
         DATE '2023-01-01' + floor(power(random(), 0.75) * 1080)::int AS signup,
         random() AS r_channel
  FROM generate_series(1, 5000) g
)
INSERT INTO customers (full_name, email, city, state, region, signup_date, acquisition_channel, account_manager_id)
SELECT fn.a[1 + (b.n * 7) % 20] || ' ' || ln.a[1 + (b.n * 11) % 16],
       lower(fn.a[1 + (b.n * 7) % 20]) || '.' || lower(ln.a[1 + (b.n * 11) % 16]) || b.n || '@example.in',
       w.city, w.state, w.region, b.signup,
       CASE WHEN b.r_channel < 0.35 THEN 'Organic' WHEN b.r_channel < 0.60 THEN 'Paid Search'
            WHEN b.r_channel < 0.80 THEN 'Social'  WHEN b.r_channel < 0.92 THEN 'Referral' ELSE 'Email' END,
       (SELECT e.employee_id FROM employees e
         WHERE e.job_title = 'Account Manager' AND e.region = w.region
         ORDER BY (e.employee_id * 31 + b.n) % 97 LIMIT 1)
FROM base b
JOIN weighted w ON w.rn = b.city_rn
CROSS JOIN fn CROSS JOIN ln;

-- ---------- Orders -------------------------------------------------------
-- Number of orders per customer ~ exponential (few loyal heavy buyers),
-- plus a festive (Diwali, Oct-Nov) demand boost.
CREATE TEMP TABLE tmp_orders AS
SELECT c.customer_id,
       -- days after signup ~ exponential: activity decays over time (churn)
       c.signup_date
         + (-ln(1 - random() + g * 0) * c_life.mean_days) * INTERVAL '1 day'
         + (8 + random() * 15) * INTERVAL '1 hour' AS order_ts
FROM customers c
CROSS JOIN LATERAL (SELECT 60 + random() * 300 + c.customer_id * 0 AS mean_days,
                           floor(-ln(1 - random() + c.customer_id * 0) * 4.5)::int AS n_orders) c_life
CROSS JOIN LATERAL generate_series(1, c_life.n_orders) g
UNION ALL
SELECT c.customer_id,
       make_date(y, 10, 10) + (random() * 40) * INTERVAL '1 day' + (9 + random() * 13) * INTERVAL '1 hour'
FROM customers c
CROSS JOIN generate_series(2023, 2025) y
WHERE random() < 0.22 AND make_date(y, 10, 10) > c.signup_date;

INSERT INTO orders (customer_id, order_ts, status, sales_channel, payment_method, coupon_code, shipping_fee)
SELECT t.customer_id,
       date_trunc('second', t.order_ts),
       CASE WHEN t.order_ts > TIMESTAMP '2025-12-24' AND r1 < 0.6 THEN 'Shipped'
            WHEN r1 < 0.06 THEN 'Cancelled' WHEN r1 < 0.10 THEN 'Returned' ELSE 'Delivered' END,
       CASE WHEN r2 < 0.45 THEN 'Web' WHEN r2 < 0.85 THEN 'App' ELSE 'Store' END,
       CASE WHEN r3 < 0.45 THEN 'UPI' WHEN r3 < 0.65 THEN 'Card' WHEN r3 < 0.80 THEN 'COD'
            WHEN r3 < 0.90 THEN 'NetBanking' ELSE 'Wallet' END,
       CASE WHEN r4 < 0.08 THEN 'NEW15' WHEN r4 < 0.16 THEN 'SAVE5'
            WHEN r4 < 0.24 AND extract(month FROM t.order_ts) IN (10, 11) THEN 'FEST10' END,
       CASE WHEN r2 >= 0.85 THEN 0 ELSE 49 END
FROM (SELECT *, random() r1, random() r2, random() r3, random() r4 FROM tmp_orders
      WHERE order_ts < TIMESTAMP '2026-01-01') t
ORDER BY t.order_ts;

-- ---------- Order items (price looked up from SCD2 history = as-of join) --
INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_pct)
SELECT DISTINCT ON (x.order_id, x.product_id)
       x.order_id, x.product_id,
       CASE WHEN random() < 0.8 THEN 1 WHEN random() < 0.7 THEN 2 ELSE 3 END,
       ph.price,
       CASE x.coupon_code WHEN 'NEW15' THEN 15 WHEN 'FEST10' THEN 10 WHEN 'SAVE5' THEN 5
            ELSE CASE WHEN random() < 0.07 THEN 20 ELSE 0 END END
FROM (
    SELECT o.order_id, o.order_ts, o.coupon_code,
           -- skew product popularity: low ids within each leaf sell more
           1 + floor(power(random(), 1.6) * (SELECT count(*) FROM products))::int AS product_id
    FROM orders o
    CROSS JOIN LATERAL generate_series(1, 1 + floor(power(random() + o.order_id * 0, 2) * 4)::int)
) x
JOIN products p ON p.product_id = x.product_id AND p.launch_date <= x.order_ts::date
JOIN product_price_history ph
  ON ph.product_id = x.product_id
 AND x.order_ts::date >= ph.valid_from
 AND (ph.valid_to IS NULL OR x.order_ts::date < ph.valid_to)
ORDER BY x.order_id, x.product_id;

-- cross-sell behaviour: ~40% of phone/laptop orders also add an accessory or audio item
INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_pct)
SELECT DISTINCT ON (x.order_id) x.order_id, ap.product_id, 1, ph.price, x.discount_pct
FROM (
    SELECT i.order_id, o.order_ts, i.discount_pct, random() AS r
    FROM order_items i
    JOIN orders o     ON o.order_id = i.order_id
    JOIN products p   ON p.product_id = i.product_id
    JOIN categories c ON c.category_id = p.category_id
    WHERE c.category_name IN ('Mobiles', 'Laptops')
) x
CROSS JOIN LATERAL (
    SELECT p2.product_id FROM products p2
    JOIN categories c2 ON c2.category_id = p2.category_id
    WHERE c2.category_name IN ('Accessories', 'Audio') AND p2.launch_date <= x.order_ts::date
      AND NOT EXISTS (SELECT 1 FROM order_items e WHERE e.order_id = x.order_id AND e.product_id = p2.product_id)
    ORDER BY random() + x.r * 0 LIMIT 1
) ap
JOIN product_price_history ph
  ON ph.product_id = ap.product_id AND x.order_ts::date >= ph.valid_from
 AND (ph.valid_to IS NULL OR x.order_ts::date < ph.valid_to)
WHERE x.r < 0.40
ORDER BY x.order_id;

-- remove orders that ended up with no lines (product not launched yet)
DELETE FROM orders o WHERE NOT EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.order_id);

-- ---------- Returns -------------------------------------------------------
INSERT INTO returns (order_item_id, return_date, reason, refund_amount)
SELECT i.order_item_id,
       o.order_ts::date + (3 + random() * 17)::int,
       (ARRAY['Damaged','Wrong size','Not as described','Changed mind','Late delivery'])[1 + floor(random() * 5)::int],
       i.line_revenue
FROM order_items i JOIN orders o USING (order_id)
WHERE o.status = 'Returned';

-- ---------- Clickstream ----------------------------------------------------
-- (a) a converting session before every non-cancelled order
INSERT INTO web_events (customer_id, event_ts, event_type, product_id, device)
SELECT o.customer_id, o.order_ts - s.mins_before * INTERVAL '1 minute', s.event_type,
       CASE WHEN s.event_type IN ('product_view','add_to_cart') THEN i.product_id END,
       CASE o.sales_channel WHEN 'App' THEN 'Mobile' ELSE 'Desktop' END
FROM orders o
JOIN LATERAL (SELECT product_id FROM order_items WHERE order_id = o.order_id LIMIT 1) i ON TRUE
CROSS JOIN (VALUES (14,'page_view'), (11,'product_view'), (6,'add_to_cart'), (2,'checkout'), (0,'purchase'))
           AS s(mins_before, event_type)
WHERE o.sales_channel <> 'Store';

-- (b) non-converting sessions that drop off at different funnel stages
WITH sess AS (
  SELECT c.customer_id,
         c.signup_date + random() * (TIMESTAMP '2025-12-31 22:00' - c.signup_date) AS start_ts,
         random() AS depth,
         1 + floor(random() * (SELECT count(*) FROM products))::int AS product_id,
         CASE WHEN random() < 0.55 THEN 'Mobile' ELSE 'Desktop' END AS device
  FROM customers c
  CROSS JOIN LATERAL generate_series(1, 8 + floor(random() * 16 + c.customer_id * 0)::int)
)
INSERT INTO web_events (customer_id, event_ts, event_type, product_id, device)
SELECT s.customer_id, s.start_ts + st.offset_min * INTERVAL '1 minute', st.event_type,
       CASE WHEN st.event_type IN ('product_view','add_to_cart') THEN s.product_id END, s.device
FROM sess s
JOIN (VALUES (1,0,'page_view'), (2,3,'product_view'), (3,8,'add_to_cart'), (4,12,'checkout'))
     AS st(stage, offset_min, event_type)
  -- mobile shoppers drop off earlier than desktop shoppers
  ON st.stage <= CASE WHEN s.depth < 0.42 + CASE s.device WHEN 'Mobile' THEN 0.06 ELSE 0 END THEN 1
                      WHEN s.depth < 0.80 THEN 2
                      WHEN s.depth < 0.95 THEN 3 ELSE 4 END;

ANALYZE;

-- quick sanity check
SELECT 'customers' AS tbl, count(*) FROM customers UNION ALL
SELECT 'products', count(*) FROM products UNION ALL
SELECT 'orders', count(*) FROM orders UNION ALL
SELECT 'order_items', count(*) FROM order_items UNION ALL
SELECT 'returns', count(*) FROM returns UNION ALL
SELECT 'web_events', count(*) FROM web_events;
