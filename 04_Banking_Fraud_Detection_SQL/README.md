# Banking Fraud Detection Using SQL

An end-to-end **advanced PostgreSQL portfolio project** for investigating suspicious banking transactions with CTEs, window functions, statistical outlier detection, risk scoring, cohort analysis, indexing, and query-plan analysis.

> **Important:** All included records are synthetically generated for learning and demonstration. `is_fraud` is a planted evaluation label, not real bank data and not a production fraud decision.

## Project highlights
- 10,000 synthetic transactions, 500 customers, 500 accounts, and 60 merchants.
- Four CSV datasets with reproducible, fictional records.
- Relational schema with primary keys, foreign keys, checks, and indexes.
- 15 advanced SQL investigations, including:
  - Account-level amount z-scores
  - Rolling transaction velocity and small-payment bursts
  - First-seen foreign-country activity
  - Shared device investigation
  - High-risk customer / merchant combinations
  - Decline-to-success retry patterns
  - Merchant category outliers
  - Rules-based alert score with precision, recall, and F1
  - Daily rolling fraud trends and customer cohorts
  - `EXPLAIN ANALYZE` performance exercise

## Tech stack
- PostgreSQL 14+
- SQL (CTEs, window functions, aggregates, FILTER, intervals)
- CSV for source data

## Repository structure
```text
banking-fraud-detection-sql/
├── data/
│   ├── customers.csv
│   ├── accounts.csv
│   ├── merchants.csv
│   └── transactions.csv
├── sql/
│   ├── 01_schema.sql
│   ├── 02_advanced_fraud_analysis.sql
│   └── 03_load_data.psql
├── reports/
├── .gitignore
└── README.md
```

## Setup

### 1. Create a database
```bash
createdb fraud_db
```
Or create a database named `fraud_db` in pgAdmin.

### 2. Create tables
From the repository root:
```bash
psql -d fraud_db -f sql/01_schema.sql
```

### 3. Load CSV data
Run from the repository root using `psql`:
```bash
psql -d fraud_db -f sql/03_load_data.psql
```
If your local PostgreSQL client cannot access the relative paths, open `psql -d fraud_db` and run the four `\copy` commands in `sql/03_load_data.psql` from the project root. In pgAdmin, use **Import/Export Data** for each CSV and select CSV, header on.

### 4. Run the analysis
Open `sql/02_advanced_fraud_analysis.sql` in pgAdmin Query Tool or run:
```bash
psql -d fraud_db -f sql/02_advanced_fraud_analysis.sql
```
The script contains multiple independent queries; run them individually if you want to inspect each result set.

## Suggested investigation workflow
1. Establish baseline transaction volume and known-fraud rate.
2. Find unusually large transactions relative to each account's historical behaviour.
3. Investigate velocity bursts and repeated small payments.
4. Review new-country activity and shared devices.
5. Combine customer and merchant risk attributes into explainable alerts.
6. Evaluate the alert rule against the synthetic label using precision, recall, and F1.
7. Inspect query plans and compare performance before and after indexes.

## Data dictionary

| Table | Grain | Key fields |
|---|---|---|
| customers | One row per customer | `customer_id`, `risk_segment`, `city` |
| accounts | One row per account | `account_id`, `customer_id`, `available_balance` |
| merchants | One row per merchant | `merchant_id`, `category`, `risk_level` |
| transactions | One row per transaction | `transaction_id`, `account_id`, `amount`, `transaction_ts`, `country`, `device_id`, `is_fraud` |

## Advanced concepts demonstrated
`JOIN`, `GROUP BY`, `HAVING`, `CASE`, aggregate `FILTER`, CTEs, window frames, `LAG`, `LEAD`, `ROW_NUMBER`, `DENSE_RANK`, `STDDEV_POP`, rolling metrics, date/time arithmetic, cohort analysis, indexes, `ANALYZE`, and `EXPLAIN ANALYZE`.

## Limitations and responsible use
- The data is fictional and the fraud labels/patterns are deliberately injected.
- The alert rules are examples, not validated production controls.
- A foreign transaction, high amount, or shared device is not proof of fraud.
- Production systems need privacy controls, secure access, robust monitoring, model validation, human review, and drift testing.
- Salary, identity, or other sensitive customer information is not included.

## Author
**Dharmesh Kumar**  
GitHub: https://github.com/Dharmeshkumar2327

## License
MIT
