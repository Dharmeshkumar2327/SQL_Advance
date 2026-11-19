-- =====================================================================
-- RetailPulse Analytics  |  03_views_functions.sql
-- Reusable layer: views, materialized view, functions, a stored
-- procedure with validation, and triggers (audit + business rules).
-- =====================================================================
SET search_path TO retail;

-- ---------------------------------------------------------------------
-- 1. VIEW: one row per order with revenue, cost, profit
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_order_summary AS
SELECT o.order_id,
       o.customer_id,
       o.order_ts,
       o.order_ts::date                       AS order_date,
       date_trunc('month', o.order_ts)::date  AS order_month,
       o.status, o.sales_channel, o.payment_method, o.coupon_code,
       COUNT(*)                               AS line_count,
       SUM(i.quantity)                        AS units,
       SUM(i.line_revenue)                    AS gross_revenue,
       SUM(i.quantity * p.unit_cost)          AS cogs,
       SUM(i.line_revenue) - SUM(i.quantity * p.unit_cost) AS gross_profit,
       COALESCE(SUM(r.refund_amount), 0)      AS refunded
FROM orders o
JOIN order_items i ON i.order_id = o.order_id
JOIN products p    ON p.product_id = i.product_id
LEFT JOIN returns r ON r.order_item_id = i.order_item_id
GROUP BY o.order_id;            -- PK grouping: other o.* columns are functionally dependent

-- "Recognised" revenue = completed sales only (exclude cancelled / returned)
CREATE OR REPLACE VIEW vw_valid_sales AS
SELECT * FROM vw_order_summary WHERE status IN ('Delivered', 'Shipped');

-- ---------------------------------------------------------------------
-- 2. MATERIALIZED VIEW: monthly KPI snapshot for dashboards
--    (unique index enables REFRESH ... CONCURRENTLY)
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_kpis;
CREATE MATERIALIZED VIEW mv_monthly_kpis AS
SELECT order_month,
       COUNT(*)                                   AS orders,
       COUNT(DISTINCT customer_id)                AS active_customers,
       SUM(gross_revenue)                         AS revenue,
       SUM(gross_profit)                          AS profit,
       ROUND(SUM(gross_revenue) / COUNT(*), 2)    AS aov,
       ROUND(100.0 * SUM(gross_profit) / SUM(gross_revenue), 2) AS margin_pct
FROM vw_valid_sales
GROUP BY order_month
WITH DATA;

CREATE UNIQUE INDEX ux_mv_monthly_kpis ON mv_monthly_kpis (order_month);
-- usage: REFRESH MATERIALIZED VIEW CONCURRENTLY retail.mv_monthly_kpis;

-- ---------------------------------------------------------------------
-- 3. SCALAR FUNCTION: lifetime value of a customer
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_customer_ltv(p_customer_id INT)
RETURNS NUMERIC
LANGUAGE sql STABLE
SET search_path = retail AS $$
    SELECT COALESCE(SUM(gross_revenue - refunded), 0)
    FROM vw_order_summary
    WHERE customer_id = p_customer_id AND status <> 'Cancelled';
$$;

-- ---------------------------------------------------------------------
-- 4. TABLE-VALUED FUNCTION: top-N products for any date range
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_top_products(p_start DATE, p_end DATE, p_n INT DEFAULT 10)
RETURNS TABLE (rank_no BIGINT, product_name VARCHAR, category VARCHAR,
               units BIGINT, revenue NUMERIC, revenue_share_pct NUMERIC)
LANGUAGE sql STABLE
SET search_path = retail AS $$
    WITH s AS (
        SELECT p.product_name, c.category_name,
               SUM(i.quantity) AS units, SUM(i.line_revenue) AS revenue
        FROM orders o
        JOIN order_items i ON i.order_id = o.order_id
        JOIN products p    ON p.product_id = i.product_id
        JOIN categories c  ON c.category_id = p.category_id
        WHERE o.status IN ('Delivered','Shipped')
          AND o.order_ts >= p_start AND o.order_ts < p_end + 1
        GROUP BY p.product_name, c.category_name
    )
    SELECT DENSE_RANK() OVER (ORDER BY revenue DESC),
           product_name, category_name, units, revenue,
           ROUND(100 * revenue / SUM(revenue) OVER (), 2)
    FROM s
    ORDER BY revenue DESC
    LIMIT p_n;
$$;

-- ---------------------------------------------------------------------
-- 5. STORED PROCEDURE: cancel an order with business-rule validation
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_cancel_order(p_order_id INT, p_reason TEXT DEFAULT 'Customer request')
LANGUAGE plpgsql
SET search_path = retail AS $$
DECLARE
    v_status orders.status%TYPE;
BEGIN
    SELECT status INTO v_status FROM orders WHERE order_id = p_order_id FOR UPDATE;  -- row lock

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % does not exist', p_order_id USING ERRCODE = 'no_data_found';
    ELSIF v_status IN ('Delivered', 'Returned') THEN
        RAISE EXCEPTION 'Order % is already % and cannot be cancelled', p_order_id, v_status;
    ELSIF v_status = 'Cancelled' THEN
        RAISE NOTICE 'Order % was already cancelled - nothing to do', p_order_id;
        RETURN;
    END IF;

    UPDATE orders SET status = 'Cancelled' WHERE order_id = p_order_id;   -- fires audit trigger
    RAISE NOTICE 'Order % cancelled (%).', p_order_id, p_reason;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. TRIGGERS
-- ---------------------------------------------------------------------
-- 6a. Audit every status change on orders
CREATE OR REPLACE FUNCTION trg_fn_audit_order_status()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = retail AS $$
BEGIN
    INSERT INTO order_status_audit (order_id, old_status, new_status)
    VALUES (NEW.order_id, OLD.status, NEW.status);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_order_status ON orders;
CREATE TRIGGER trg_audit_order_status
AFTER UPDATE OF status ON orders
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_audit_order_status();

-- 6b. Business rule: a refund can never exceed what the customer paid
CREATE OR REPLACE FUNCTION trg_fn_validate_refund()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = retail AS $$
DECLARE v_paid NUMERIC;
BEGIN
    SELECT line_revenue INTO v_paid FROM order_items WHERE order_item_id = NEW.order_item_id;
    IF NEW.refund_amount > v_paid THEN
        RAISE EXCEPTION 'Refund % exceeds amount paid % for order item %',
                        NEW.refund_amount, v_paid, NEW.order_item_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_refund ON returns;
CREATE TRIGGER trg_validate_refund
BEFORE INSERT OR UPDATE ON returns
FOR EACH ROW EXECUTE FUNCTION trg_fn_validate_refund();

-- ---------------------------------------------------------------------
-- Demo (wrapped in a transaction and rolled back so data stays clean)
-- ---------------------------------------------------------------------
BEGIN;
    DO $$
    DECLARE v_id INT;
    BEGIN
        SELECT min(order_id) INTO v_id FROM retail.orders WHERE status = 'Shipped';
        CALL retail.sp_cancel_order(v_id, 'Demo');   -- CALL args can't be subqueries
    END $$;
    SELECT * FROM order_status_audit;
ROLLBACK;

SELECT * FROM fn_top_products('2025-10-01', '2025-11-30', 5);
SELECT customer_id, fn_customer_ltv(customer_id) AS ltv FROM customers ORDER BY ltv DESC LIMIT 5;
