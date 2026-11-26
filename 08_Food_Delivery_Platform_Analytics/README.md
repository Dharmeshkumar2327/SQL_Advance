# Food Delivery Platform Analytics (Advanced SQL)

An end-to-end PostgreSQL analytics project for a food-delivery business. It analyzes customer behavior, restaurant performance, delivery operations, revenue, discounts, and customer retention using advanced SQL.

## Business questions
- Which cities, restaurants, and cuisines generate the most revenue?
- What is the average order value (AOV) and month-over-month revenue growth?
- Which delivery partners have the best on-time delivery performance?
- How much revenue is lost through discounts, cancellations, and refunds?
- Which customers are repeat, dormant, or high-value customers?
- Which items are frequently purchased together?

## Tech stack
- PostgreSQL 14+
- SQL (CTEs, window functions, conditional aggregation, views, indexes)
- Optional: Power BI / Tableau for visualization

## Repository structure
```text
food_delivery_platform_analytics/
├── README.md
├── .gitignore
├── sql/
│   ├── 01_schema.sql
│   ├── 02_seed_data.sql
│   ├── 03_views.sql
│   ├── 04_advanced_analysis.sql
│   └── 05_performance_tuning.sql
├── data/
│   └── data_dictionary.md
└── docs/
    └── dashboard_ideas.md
```

## Setup
1. Install PostgreSQL and create a database:
   ```sql
   CREATE DATABASE food_delivery_analytics;
   ```
2. Connect to the database and run scripts in this order:
   - `sql/01_schema.sql`
   - `sql/02_seed_data.sql`
   - `sql/03_views.sql`
   - `sql/04_advanced_analysis.sql`
   - `sql/05_performance_tuning.sql`
3. Run each query in `04_advanced_analysis.sql` individually and review the comments.

Example using `psql`:
```bash
psql -d food_delivery_analytics -f sql/01_schema.sql
psql -d food_delivery_analytics -f sql/02_seed_data.sql
psql -d food_delivery_analytics -f sql/03_views.sql
```

## Data model
- `customers` place orders.
- `restaurants` offer menu items.
- `menu_items` belong to restaurants.
- `delivery_partners` deliver orders.
- `orders` connect customers, restaurants, and delivery partners.
- `order_items` store item-level quantity and price snapshots.
- `payments` store payment outcomes.
- `reviews` store customer feedback.

See `sql/01_schema.sql` for table definitions and constraints.

## Key metrics
| Metric | Definition |
|---|---|
| Gross item sales | Sum of quantity × item price |
| Net order revenue | Item subtotal + delivery fee − discount |
| AOV | Net revenue / completed orders |
| Cancellation rate | Cancelled orders / all orders |
| On-time rate | Delivered orders delivered by promised time / delivered orders |
| Repeat customer rate | Customers with 2+ completed orders / customers with completed orders |
| Average delivery time | Average minutes from placed to delivered |

## Advanced SQL covered
- Multi-table joins and conditional aggregation
- CTEs and recursive CTE
- `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `LAG`, and rolling windows
- Cohort-style monthly retention
- Customer RFM segmentation
- Basket analysis using self-joins
- Views and materialized views
- Indexing and `EXPLAIN (ANALYZE, BUFFERS)`

## Suggested dashboard pages
1. Executive Overview: revenue, orders, AOV, cancellation rate, on-time rate.
2. Restaurant & Menu: revenue by restaurant, cuisine, and item.
3. Customer Insights: RFM segments, repeat rate, monthly cohorts.
4. Delivery Operations: delivery time, on-time rate, partner rankings.
5. Payments & Discounts: payment mix, discount impact, refund/cancellation trends.

## Notes
The included seed data is synthetic and intended for learning, portfolio demonstration, and SQL practice. It is not real customer or business data. For meaningful statistical conclusions, replace it with a larger dataset.

## Portfolio description
Built a PostgreSQL-based Food Delivery Platform Analytics solution to evaluate revenue, customer retention, restaurant performance, payment trends, and delivery efficiency. Applied advanced SQL including CTEs, window functions, cohort analysis, RFM segmentation, basket analysis, views, and query optimization.
