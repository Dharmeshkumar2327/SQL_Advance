-- Banking Fraud Detection | PostgreSQL schema
DROP TABLE IF EXISTS transactions CASCADE;
DROP TABLE IF EXISTS accounts CASCADE;
DROP TABLE IF EXISTS merchants CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE TABLE customers (
    customer_id BIGINT PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    age SMALLINT CHECK (age BETWEEN 18 AND 100),
    city VARCHAR(50),
    risk_segment VARCHAR(10) CHECK (risk_segment IN ('LOW','MEDIUM','HIGH')),
    created_at DATE
);

CREATE TABLE accounts (
    account_id BIGINT PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
    account_type VARCHAR(20),
    account_status VARCHAR(10),
    opened_at DATE,
    available_balance NUMERIC(14,2) CHECK (available_balance >= 0)
);

CREATE TABLE merchants (
    merchant_id BIGINT PRIMARY KEY,
    merchant_name VARCHAR(100),
    category VARCHAR(30),
    country CHAR(2),
    risk_level VARCHAR(10)
);

CREATE TABLE transactions (
    transaction_id BIGINT PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES accounts(account_id),
    merchant_id BIGINT NOT NULL REFERENCES merchants(merchant_id),
    transaction_ts TIMESTAMP NOT NULL,
    amount NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    currency CHAR(3) DEFAULT 'INR',
    channel VARCHAR(15),
    country CHAR(2),
    device_id VARCHAR(30),
    transaction_status VARCHAR(10),
    is_fraud SMALLINT DEFAULT 0 CHECK (is_fraud IN (0,1))
);

-- Indexes to support common fraud investigations
CREATE INDEX idx_txn_account_ts ON transactions(account_id, transaction_ts DESC);
CREATE INDEX idx_txn_ts ON transactions(transaction_ts);
CREATE INDEX idx_txn_amount ON transactions(amount DESC);
CREATE INDEX idx_txn_country ON transactions(country);
CREATE INDEX idx_txn_device_ts ON transactions(device_id, transaction_ts DESC);
CREATE INDEX idx_accounts_customer ON accounts(customer_id);
