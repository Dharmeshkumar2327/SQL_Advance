-- 01_schema.sql
-- PostgreSQL 14+

DROP TABLE IF EXISTS reviews, payments, order_items, orders, menu_items,
    delivery_partners, restaurants, customers CASCADE;

CREATE TABLE customers (
    customer_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_name    VARCHAR(100) NOT NULL,
    email            VARCHAR(150) UNIQUE NOT NULL,
    city             VARCHAR(80) NOT NULL,
    signup_date      DATE NOT NULL,
    customer_status  VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (customer_status IN ('active','inactive'))
);

CREATE TABLE restaurants (
    restaurant_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restaurant_name  VARCHAR(120) NOT NULL,
    city             VARCHAR(80) NOT NULL,
    cuisine          VARCHAR(60) NOT NULL,
    rating           NUMERIC(2,1) CHECK (rating BETWEEN 0 AND 5),
    is_active        BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE menu_items (
    item_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restaurant_id    BIGINT NOT NULL REFERENCES restaurants(restaurant_id),
    item_name        VARCHAR(120) NOT NULL,
    category         VARCHAR(60) NOT NULL,
    list_price       NUMERIC(10,2) NOT NULL CHECK (list_price >= 0),
    is_available     BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (restaurant_id, item_name)
);

CREATE TABLE delivery_partners (
    partner_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    partner_name     VARCHAR(100) NOT NULL,
    city             VARCHAR(80) NOT NULL,
    joined_date      DATE NOT NULL,
    vehicle_type     VARCHAR(30) NOT NULL
);

CREATE TABLE orders (
    order_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id          BIGINT NOT NULL REFERENCES customers(customer_id),
    restaurant_id        BIGINT NOT NULL REFERENCES restaurants(restaurant_id),
    partner_id           BIGINT REFERENCES delivery_partners(partner_id),
    order_placed_at      TIMESTAMP NOT NULL,
    promised_delivery_at TIMESTAMP,
    delivered_at         TIMESTAMP,
    order_status         VARCHAR(20) NOT NULL
        CHECK (order_status IN ('placed','preparing','picked_up','delivered','cancelled')),
    delivery_fee         NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    discount_amount      NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    cancellation_reason  VARCHAR(150),
    CHECK (delivered_at IS NULL OR delivered_at >= order_placed_at)
);

CREATE TABLE order_items (
    order_item_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id         BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    item_id          BIGINT NOT NULL REFERENCES menu_items(item_id),
    quantity         INTEGER NOT NULL CHECK (quantity > 0),
    unit_price       NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0)
);

CREATE TABLE payments (
    payment_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id         BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    payment_method   VARCHAR(30) NOT NULL,
    payment_status   VARCHAR(20) NOT NULL
        CHECK (payment_status IN ('success','failed','refunded','pending')),
    amount           NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    paid_at          TIMESTAMP
);

CREATE TABLE reviews (
    review_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id         BIGINT NOT NULL UNIQUE REFERENCES orders(order_id) ON DELETE CASCADE,
    customer_id      BIGINT NOT NULL REFERENCES customers(customer_id),
    restaurant_rating INTEGER CHECK (restaurant_rating BETWEEN 1 AND 5),
    delivery_rating   INTEGER CHECK (delivery_rating BETWEEN 1 AND 5),
    review_text       TEXT,
    reviewed_at       TIMESTAMP NOT NULL
);
