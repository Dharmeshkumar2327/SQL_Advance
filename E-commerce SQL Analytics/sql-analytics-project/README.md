# E-commerce SQL Analytics Project

A hands-on SQL portfolio project: explore a small online store's data and answer real business questions.
Runs on **SQLite** (no install beyond Python); queries use standard SQL and port easily to PostgreSQL/MySQL
(swap `strftime`/`julianday` for `DATE_TRUNC`/date arithmetic).

## Quick start
```bash
python generate_data.py                      # builds ecommerce.db (600 customers, 40 products, ~1,500 orders)
python run_query.py queries/01_business_kpis.sql
# or interactively:  sqlite3 ecommerce.db
```
Optional: open `ecommerce.db` in DB Browser for SQLite, DBeaver, or VS Code's SQLite extension.

## Data model
```
customers (customer_id PK, name, email, city, channel, signup_date)
orders    (order_id PK, customer_id FK, order_date, status, discount_pct)
order_items (order_item_id PK, order_id FK, product_id FK, quantity, unit_price)
products  (product_id PK, name, category, price, cost)
```
Revenue = `quantity * unit_price * (1 - discount_pct/100)`, **completed orders only**.

## What's inside
| File | Business question | SQL skills |
|---|---|---|
| `queries/01_business_kpis.sql` | How is the business doing? Which categories are most profitable? | Aggregates, CTEs, `LAG`, window percentages |
| `queries/02_customer_analysis.sql` | Who are our best customers? Do they come back? Which channel is best? | RFM with `NTILE`, cohort retention, LEFT JOINs, `CASE` |
| `queries/03_product_analysis.sql` | What sells, what drives profit, what's bought together? | Pareto via cumulative window sums, self-joins |
| `queries/04_time_series_and_advanced.sql` | Trends, seasonality, repeat cadence | Moving averages, YoY, `ROW_NUMBER`, `PARTITION BY` |

## Notes on the data
- Data is synthetic (seeded, reproducible). Business starts near zero in Jan 2024, so early-2024 growth
  and YoY percentages look extreme. In real analysis, call this out or filter to mature periods.
- Cohort retention is sparse because customers buy on random dates; real data would show clearer decay curves.

## Extension ideas
1. Add a `visualize.py` (pandas + matplotlib) to chart the monthly revenue and cohort heatmap.
2. Write a one-page findings memo: 3 insights + 3 recommendations.
3. Add `CREATE VIEW v_order_revenue` to remove the repeated revenue formula.
4. Find the data quality issues you'd check first (duplicate emails, orders without items, negative margins).
5. Port the queries to PostgreSQL and compare execution plans with `EXPLAIN`.
