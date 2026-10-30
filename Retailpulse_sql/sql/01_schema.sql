-- =====================================================================
-- RetailPulse Analytics  |  01_schema.sql
-- Normalised OLTP schema for an Indian multi-channel e-commerce store.
-- Engine: PostgreSQL 14+
-- =====================================================================

DROP SCHEMA IF EXISTS retail CASCADE;
CREATE SCHEMA retail;
SET search_path TO retail;

-- ---------- Reference / dimension tables ----------------------------

CREATE TABLE categories (
    category_id        SERIAL PRIMARY KEY,
    category_name      VARCHAR(60) NOT NULL UNIQUE,
    parent_category_id INT REFERENCES categories(category_id)   -- self-reference => hierarchy
);

CREATE TABLE products (
    product_id    SERIAL PRIMARY KEY,
    product_name  VARCHAR(120) NOT NULL,
    category_id   INT NOT NULL REFERENCES categories(category_id),
    unit_cost     NUMERIC(10,2) NOT NULL CHECK (unit_cost > 0),
    list_price    NUMERIC(10,2) NOT NULL CHECK (list_price > 0),
    launch_date   DATE NOT NULL,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT price_above_cost CHECK (list_price >= unit_cost)
);

-- Slowly Changing Dimension (Type 2) - full price history per product
CREATE TABLE product_price_history (
    price_id    SERIAL PRIMARY KEY,
    product_id  INT NOT NULL REFERENCES products(product_id),
    price       NUMERIC(10,2) NOT NULL,
    valid_from  DATE NOT NULL,
    valid_to    DATE,                                 -- NULL = current price
    CONSTRAINT valid_range CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(80) NOT NULL,
    job_title    VARCHAR(60) NOT NULL,
    manager_id   INT REFERENCES employees(employee_id),  -- org chart
    hire_date    DATE NOT NULL,
    region       VARCHAR(20) NOT NULL
);

CREATE TABLE customers (
    customer_id          SERIAL PRIMARY KEY,
    full_name            VARCHAR(80) NOT NULL,
    email                VARCHAR(120) NOT NULL UNIQUE,
    city                 VARCHAR(40) NOT NULL,
    state                VARCHAR(40) NOT NULL,
    region               VARCHAR(20) NOT NULL,
    signup_date          DATE NOT NULL,
    acquisition_channel  VARCHAR(20) NOT NULL
        CHECK (acquisition_channel IN ('Organic','Paid Search','Social','Referral','Email')),
    account_manager_id   INT REFERENCES employees(employee_id)
);

-- ---------- Transaction / fact tables -------------------------------

CREATE TABLE orders (
    order_id        SERIAL PRIMARY KEY,
    customer_id     INT NOT NULL REFERENCES customers(customer_id),
    order_ts        TIMESTAMP NOT NULL,
    status          VARCHAR(15) NOT NULL
        CHECK (status IN ('Delivered','Shipped','Cancelled','Returned')),
    sales_channel   VARCHAR(10) NOT NULL CHECK (sales_channel IN ('Web','App','Store')),
    payment_method  VARCHAR(15) NOT NULL CHECK (payment_method IN ('UPI','Card','COD','NetBanking','Wallet')),
    coupon_code     VARCHAR(15),
    shipping_fee    NUMERIC(8,2) NOT NULL DEFAULT 0
);

CREATE TABLE order_items (
    order_item_id  SERIAL PRIMARY KEY,
    order_id       INT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id     INT NOT NULL REFERENCES products(product_id),
    quantity       INT NOT NULL CHECK (quantity > 0),
    unit_price     NUMERIC(10,2) NOT NULL,          -- price actually charged
    discount_pct   NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 90),
    -- generated column: net revenue for the line
    line_revenue   NUMERIC(12,2) GENERATED ALWAYS AS
                   (ROUND(quantity * unit_price * (1 - discount_pct / 100.0), 2)) STORED
);

CREATE TABLE returns (
    return_id      SERIAL PRIMARY KEY,
    order_item_id  INT NOT NULL UNIQUE REFERENCES order_items(order_item_id),
    return_date    DATE NOT NULL,
    reason         VARCHAR(30) NOT NULL,
    refund_amount  NUMERIC(12,2) NOT NULL
);

-- Clickstream (no session id on purpose -> we sessionise it in SQL)
CREATE TABLE web_events (
    event_id     BIGSERIAL PRIMARY KEY,
    customer_id  INT NOT NULL REFERENCES customers(customer_id),
    event_ts     TIMESTAMP NOT NULL,
    event_type   VARCHAR(15) NOT NULL
        CHECK (event_type IN ('page_view','product_view','add_to_cart','checkout','purchase')),
    product_id   INT REFERENCES products(product_id),
    device       VARCHAR(10) NOT NULL
);

-- Audit table filled by triggers (see 03_views_functions.sql)
CREATE TABLE order_status_audit (
    audit_id    BIGSERIAL PRIMARY KEY,
    order_id    INT NOT NULL,
    old_status  VARCHAR(15),
    new_status  VARCHAR(15),
    changed_at  TIMESTAMP NOT NULL DEFAULT now(),
    changed_by  TEXT NOT NULL DEFAULT current_user
);

COMMENT ON TABLE retail.order_items IS 'One row per product per order; line_revenue is a stored generated column.';
COMMENT ON TABLE retail.web_events  IS 'Raw clickstream without session ids - sessionised with gaps-and-islands logic.';
