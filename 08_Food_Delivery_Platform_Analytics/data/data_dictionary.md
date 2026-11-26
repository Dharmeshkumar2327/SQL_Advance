# Data Dictionary

| Table | Grain | Purpose |
|---|---|---|
| customers | One row per customer | Customer profile and signup details |
| restaurants | One row per restaurant | Restaurant, city, cuisine, rating |
| menu_items | One row per menu item | Restaurant menu and list price |
| delivery_partners | One row per partner | Delivery workforce profile |
| orders | One row per order | Order lifecycle, timestamps, fees, discounts |
| order_items | One row per item in an order | Quantity and transaction-time unit price |
| payments | One row per payment attempt | Payment method, amount, status |
| reviews | One row per reviewed order | Restaurant and delivery ratings |

## Important business rules
- Only `delivered` orders count toward completed-order revenue.
- Item revenue is `quantity * unit_price`; order net value adds delivery fee and subtracts discount.
- `unit_price` is stored on `order_items` as a historical price snapshot. Do not use current menu price to recalculate historical orders.
- Delivery duration is measured from `order_placed_at` to `delivered_at`.
- On-time delivery means `delivered_at <= promised_delivery_at`.
- Seed records are synthetic examples, not production data.
