/* =============================================================================
   01_schemas_and_tables.sql
   Creates the four schemas and all base tables.

   upi        -> source data (cities, accounts, transactions)
   fraud      -> detection engine (rule config, rule hits, risk scores)
   eval       -> ground-truth labels + accuracy measurement (never read by rules)
   analytics  -> reporting views used by the dashboard
   ============================================================================= */

DROP SCHEMA IF EXISTS analytics CASCADE;
DROP SCHEMA IF EXISTS eval      CASCADE;
DROP SCHEMA IF EXISTS fraud     CASCADE;
DROP SCHEMA IF EXISTS upi       CASCADE;

CREATE SCHEMA upi;
CREATE SCHEMA fraud;
CREATE SCHEMA eval;
CREATE SCHEMA analytics;

-- -----------------------------------------------------------------------------
-- Source data
-- -----------------------------------------------------------------------------
CREATE TABLE upi.cities (
    city        TEXT PRIMARY KEY,
    state       TEXT          NOT NULL,
    latitude    NUMERIC(8,5)  NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
    longitude   NUMERIC(8,5)  NOT NULL CHECK (longitude BETWEEN -180 AND 180)
);

CREATE TABLE upi.accounts (
    account_id         INTEGER   PRIMARY KEY,
    vpa                TEXT      NOT NULL UNIQUE,          -- e.g. rahul.sharma42@oksbi
    holder_name        TEXT      NOT NULL,
    bank_name          TEXT      NOT NULL,
    account_type       TEXT      NOT NULL CHECK (account_type IN ('PERSONAL', 'MERCHANT')),
    merchant_category  TEXT,
    home_city          TEXT      NOT NULL,
    created_at         TIMESTAMP NOT NULL,
    kyc_level          TEXT      NOT NULL CHECK (kyc_level IN ('MIN', 'FULL')),
    CHECK ((account_type = 'MERCHANT') = (merchant_category IS NOT NULL))
);

CREATE TABLE upi.transactions (
    txn_id             BIGINT        PRIMARY KEY,
    txn_ts             TIMESTAMP     NOT NULL,
    payer_account_id   INTEGER       NOT NULL,
    payee_account_id   INTEGER       NOT NULL,
    amount             NUMERIC(12,2) NOT NULL CHECK (amount > 0 AND amount <= 100000),
    txn_type           TEXT          NOT NULL CHECK (txn_type IN ('P2P', 'P2M')),
    channel            TEXT          NOT NULL CHECK (channel IN ('QR', 'INTENT', 'COLLECT', 'VPA_ENTRY')),
    device_id          TEXT          NOT NULL,
    txn_city           TEXT          NOT NULL,
    status             TEXT          NOT NULL CHECK (status IN ('SUCCESS', 'FAILED')),
    failure_reason     TEXT,
    CHECK (payer_account_id <> payee_account_id),
    CHECK ((status = 'FAILED') = (failure_reason IS NOT NULL))
);

-- -----------------------------------------------------------------------------
-- Ground truth (used ONLY by the eval layer)
-- -----------------------------------------------------------------------------
CREATE TABLE eval.fraud_labels (
    txn_id         BIGINT PRIMARY KEY,
    fraud_pattern  TEXT   NOT NULL
);

-- -----------------------------------------------------------------------------
-- Detection engine tables
-- -----------------------------------------------------------------------------
-- Every rule reads its thresholds from here, so analysts can tune rules
-- with an UPDATE statement instead of editing SQL code.
CREATE TABLE fraud.rule_config (
    rule_code        TEXT    PRIMARY KEY,
    rule_name        TEXT    NOT NULL,
    description      TEXT    NOT NULL,
    target_pattern   TEXT    NOT NULL,      -- which fraud typology the rule is designed for
    severity_points  INTEGER NOT NULL CHECK (severity_points BETWEEN 1 AND 100),
    params           JSONB   NOT NULL,
    is_active        BOOLEAN NOT NULL DEFAULT TRUE
);

-- Score bands -> recommended action
CREATE TABLE fraud.risk_bands (
    risk_band   TEXT    PRIMARY KEY,
    min_score   INTEGER NOT NULL,
    max_score   INTEGER NOT NULL,
    action      TEXT    NOT NULL,
    sort_order  INTEGER NOT NULL
);

-- One row per (transaction, rule) that fired. `evidence` explains WHY.
CREATE TABLE fraud.rule_hits (
    hit_id       BIGSERIAL PRIMARY KEY,
    txn_id       BIGINT    NOT NULL,
    account_id   INTEGER   NOT NULL,   -- the account under suspicion for this hit
    rule_code    TEXT      NOT NULL REFERENCES fraud.rule_config (rule_code),
    evidence     JSONB     NOT NULL,
    detected_at  TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (txn_id, rule_code)
);

-- Run log: how long each rule took and how many alerts it raised
CREATE TABLE fraud.engine_run_log (
    run_id       BIGSERIAL PRIMARY KEY,
    step         TEXT      NOT NULL,
    rows_written BIGINT,
    started_at   TIMESTAMP NOT NULL,
    finished_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
