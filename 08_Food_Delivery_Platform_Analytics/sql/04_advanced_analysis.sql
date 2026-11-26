-- 04_advanced_analysis.sql
-- Run queries individually. All queries use PostgreSQL syntax.

-- Q1. Monthly revenue, completed orders, AOV, and month-over-month growth.
WITH monthly AS (
  SELECT DATE_TRUNC('month', order_placed_at)::DATE AS month,
         SUM(net_order_value) FILTER (WHERE order_status='delivered') AS revenue,
         COUNT(*) FILTER (WHERE order_status='delivered') AS orders
  FROM v_order_financials GROUP BY 1
)
SELECT month, revenue, orders,
       ROUND(revenue / NULLIF(orders,0),2) AS aov,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / NULLIF(LAG(revenue) OVER (ORDER BY month),0),2) AS revenue_mom_pct
FROM monthly ORDER BY month;

-- Q2. Top 3 restaurants by revenue in each city.
WITH restaurant_revenue AS (
  SELECT r.city, r.restaurant_name, SUM(v.net_order_value) AS revenue
  FROM v_order_financials v JOIN restaurants r USING (restaurant_id)
  WHERE v.order_status='delivered'
  GROUP BY r.city, r.restaurant_name
)
SELECT * FROM (
  SELECT *, DENSE_RANK() OVER (PARTITION BY city ORDER BY revenue DESC) AS city_rank
  FROM restaurant_revenue
) ranked WHERE city_rank <= 3;

-- Q3. Customer lifetime value and completed order count.
SELECT c.customer_id, c.customer_name,
       COUNT(*) FILTER (WHERE v.order_status='delivered') AS completed_orders,
       ROUND(SUM(v.net_order_value) FILTER (WHERE v.order_status='delivered'),2) AS lifetime_value
FROM customers c LEFT JOIN v_order_financials v USING (customer_id)
GROUP BY c.customer_id, c.customer_name
ORDER BY lifetime_value DESC NULLS LAST;

-- Q4. RFM segmentation (recency in days, frequency, monetary value).
WITH customer_rfm AS (
  SELECT customer_id,
         CURRENT_DATE - MAX(order_placed_at::DATE) AS recency_days,
         COUNT(*) AS frequency,
         SUM(net_order_value) AS monetary
  FROM v_order_financials WHERE order_status='delivered'
  GROUP BY customer_id
),
scored AS (
  SELECT *,
    NTILE(4) OVER (ORDER BY recency_days DESC) AS recency_score,
    NTILE(4) OVER (ORDER BY frequency) AS frequency_score,
    NTILE(4) OVER (ORDER BY monetary) AS monetary_score
  FROM customer_rfm
)
SELECT *, CASE
  WHEN recency_score >= 3 AND frequency_score >= 3 AND monetary_score >= 3 THEN 'Champions'
  WHEN frequency_score >= 3 AND monetary_score >= 3 THEN 'Loyal Customers'
  WHEN recency_score <= 2 THEN 'At Risk'
  ELSE 'Potential / Regular'
END AS customer_segment
FROM scored ORDER BY monetary DESC;

-- Q5. Repeat customer rate.
WITH customer_counts AS (
  SELECT customer_id, COUNT(*) AS completed_orders
  FROM v_order_financials WHERE order_status='delivered'
  GROUP BY customer_id
)
SELECT COUNT(*) FILTER (WHERE completed_orders >= 2) AS repeat_customers,
       COUNT(*) AS ordering_customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE completed_orders >= 2)
             / NULLIF(COUNT(*),0),2) AS repeat_customer_pct
FROM customer_counts;

-- Q6. Delivery partner on-time rate and average delivery minutes.
SELECT dp.partner_name, COUNT(*) AS delivered_orders,
       ROUND(AVG(v.delivery_minutes),1) AS avg_delivery_minutes,
       ROUND(100.0 * COUNT(*) FILTER (WHERE v.is_on_time)
             / NULLIF(COUNT(*),0),2) AS on_time_pct
FROM v_delivery_performance v JOIN delivery_partners dp USING (partner_id)
GROUP BY dp.partner_name ORDER BY on_time_pct DESC;

-- Q7. Cancellation rate by restaurant.
SELECT r.restaurant_name, COUNT(*) AS total_orders,
       COUNT(*) FILTER (WHERE o.order_status='cancelled') AS cancelled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.order_status='cancelled')
             / NULLIF(COUNT(*),0),2) AS cancellation_pct
FROM orders o JOIN restaurants r USING (restaurant_id)
GROUP BY r.restaurant_name ORDER BY cancellation_pct DESC;

-- Q8. Payment method mix and successful payment value.
SELECT payment_method, COUNT(*) AS payment_attempts,
       COUNT(*) FILTER (WHERE payment_status='success') AS successful_payments,
       SUM(amount) FILTER (WHERE payment_status='success') AS successful_amount
FROM payments GROUP BY payment_method ORDER BY successful_amount DESC NULLS LAST;

-- Q9. Best-selling menu items by quantity.
SELECT mi.item_name, r.restaurant_name, SUM(oi.quantity) AS units_sold,
       SUM(oi.quantity * oi.unit_price) AS gross_sales
FROM order_items oi JOIN menu_items mi USING (item_id)
JOIN restaurants r USING (restaurant_id)
JOIN orders o USING (order_id)
WHERE o.order_status='delivered'
GROUP BY mi.item_name, r.restaurant_name
ORDER BY units_sold DESC, gross_sales DESC;

-- Q10. Top 3 items within each restaurant using ROW_NUMBER.
WITH item_sales AS (
  SELECT mi.restaurant_id, oi.item_id, SUM(oi.quantity) AS units
  FROM order_items oi
  JOIN orders o USING (order_id)
  JOIN menu_items mi USING (item_id)
  WHERE o.order_status='delivered'
  GROUP BY mi.restaurant_id, oi.item_id
)
SELECT restaurant_name, item_name, units, item_rank
FROM (
  SELECT r.restaurant_name, mi.item_name, s.units,
         ROW_NUMBER() OVER (PARTITION BY r.restaurant_id ORDER BY s.units DESC) AS item_rank
  FROM item_sales s JOIN restaurants r USING (restaurant_id)
  JOIN menu_items mi USING (item_id)
) x WHERE item_rank <= 3;

-- Q11. Customers who ordered in consecutive calendar months.
WITH active_months AS (
  SELECT DISTINCT customer_id, DATE_TRUNC('month',order_placed_at)::DATE AS month
  FROM orders WHERE order_status='delivered'
)
SELECT a.customer_id, c.customer_name, a.month AS first_month, b.month AS next_month
FROM active_months a JOIN active_months b
  ON b.customer_id=a.customer_id AND b.month=a.month + INTERVAL '1 month'
JOIN customers c USING (customer_id)
ORDER BY a.customer_id, a.month;

-- Q12. Monthly customer cohort retention.
WITH first_order AS (
  SELECT customer_id, DATE_TRUNC('month',MIN(order_placed_at))::DATE AS cohort_month
  FROM orders WHERE order_status='delivered' GROUP BY customer_id
),
activity AS (
  SELECT DISTINCT customer_id, DATE_TRUNC('month',order_placed_at)::DATE AS activity_month
  FROM orders WHERE order_status='delivered'
),
cohorts AS (
  SELECT f.cohort_month,
         ((EXTRACT(YEAR FROM a.activity_month)-EXTRACT(YEAR FROM f.cohort_month))*12
          + EXTRACT(MONTH FROM a.activity_month)-EXTRACT(MONTH FROM f.cohort_month))::INT AS month_number,
         COUNT(DISTINCT a.customer_id) AS active_customers
  FROM first_order f JOIN activity a USING (customer_id)
  GROUP BY f.cohort_month, month_number
)
SELECT cohort_month, month_number, active_customers,
       ROUND(100.0*active_customers /
         FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY month_number),2)
         AS retention_pct
FROM cohorts ORDER BY cohort_month, month_number;

-- Q13. Frequently purchased item pairs (basket analysis).
SELECT a.item_id AS item_a, ia.item_name AS item_a_name,
       b.item_id AS item_b, ib.item_name AS item_b_name,
       COUNT(DISTINCT a.order_id) AS orders_together
FROM order_items a JOIN order_items b
  ON a.order_id=b.order_id AND a.item_id < b.item_id
JOIN orders o ON o.order_id=a.order_id AND o.order_status='delivered'
JOIN menu_items ia ON ia.item_id=a.item_id
JOIN menu_items ib ON ib.item_id=b.item_id
GROUP BY a.item_id,ia.item_name,b.item_id,ib.item_name
ORDER BY orders_together DESC;

-- Q14. Revenue contribution percentage by cuisine.
WITH cuisine_sales AS (
  SELECT r.cuisine, SUM(v.net_order_value) AS revenue
  FROM v_order_financials v JOIN restaurants r USING (restaurant_id)
  WHERE v.order_status='delivered' GROUP BY r.cuisine
)
SELECT cuisine, revenue,
       ROUND(100.0*revenue/SUM(revenue) OVER (),2) AS revenue_share_pct
FROM cuisine_sales ORDER BY revenue DESC;

-- Q15. Customers inactive for at least 60 days from their last completed order.
SELECT c.customer_id, c.customer_name, MAX(o.order_placed_at)::DATE AS last_order_date,
       CURRENT_DATE - MAX(o.order_placed_at)::DATE AS days_since_last_order
FROM customers c JOIN orders o USING (customer_id)
WHERE o.order_status='delivered'
GROUP BY c.customer_id,c.customer_name
HAVING MAX(o.order_placed_at) < CURRENT_DATE - INTERVAL '60 days'
ORDER BY last_order_date;

-- Q16. Average ratings by restaurant.
SELECT r.restaurant_name, COUNT(rv.review_id) AS review_count,
       ROUND(AVG(rv.restaurant_rating),2) AS avg_restaurant_rating,
       ROUND(AVG(rv.delivery_rating),2) AS avg_delivery_rating
FROM restaurants r LEFT JOIN orders o USING (restaurant_id)
LEFT JOIN reviews rv USING (order_id)
GROUP BY r.restaurant_name ORDER BY avg_restaurant_rating DESC NULLS LAST;

-- Q17. Revenue by city and month with a running cumulative total.
WITH city_month AS (
  SELECT r.city, DATE_TRUNC('month',v.order_placed_at)::DATE AS month,
         SUM(v.net_order_value) AS revenue
  FROM v_order_financials v JOIN restaurants r USING (restaurant_id)
  WHERE v.order_status='delivered' GROUP BY r.city, month
)
SELECT city, month, revenue,
       SUM(revenue) OVER (PARTITION BY city ORDER BY month
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue
FROM city_month ORDER BY city,month;

-- Q18. Discount effectiveness: discount amount vs net revenue.
SELECT DATE_TRUNC('month',order_placed_at)::DATE AS month,
       SUM(discount_amount) AS discounts_given,
       SUM(net_order_value) FILTER (WHERE order_status='delivered') AS net_revenue,
       ROUND(100.0*SUM(discount_amount) /
         NULLIF(SUM(net_order_value) FILTER (WHERE order_status='delivered'),0),2)
         AS discount_to_revenue_pct
FROM v_order_financials GROUP BY 1 ORDER BY 1;

-- Q19. Orders whose payment amount does not match calculated net order value.
SELECT v.order_id, v.net_order_value, p.amount AS payment_amount,
       p.payment_status
FROM v_order_financials v JOIN payments p USING (order_id)
WHERE p.payment_status='success'
  AND ABS(v.net_order_value-p.amount) > 0.01;

-- Q20. Use a recursive CTE to generate a calendar of dates.
WITH RECURSIVE calendar(day) AS (
  SELECT DATE '2025-01-01'
  UNION ALL
  SELECT day + 1 FROM calendar WHERE day < DATE '2025-04-30'
)
SELECT day, COUNT(o.order_id) AS orders_placed
FROM calendar c LEFT JOIN orders o ON o.order_placed_at::DATE=c.day
GROUP BY day ORDER BY day;

-- Q21. Rank delivery partners by average delivery time within each city.
WITH partner_city AS (
  SELECT dp.city, dp.partner_name, AVG(v.delivery_minutes) AS avg_minutes
  FROM v_delivery_performance v JOIN delivery_partners dp USING (partner_id)
  GROUP BY dp.city,dp.partner_name
)
SELECT *, RANK() OVER (PARTITION BY city ORDER BY avg_minutes) AS speed_rank
FROM partner_city;

-- Q22. Identify peak ordering hours.
SELECT EXTRACT(HOUR FROM order_placed_at)::INT AS order_hour,
       COUNT(*) AS total_orders
FROM orders GROUP BY order_hour ORDER BY total_orders DESC;

-- Q23. Revenue per customer city (customer's city).
SELECT c.city, COUNT(DISTINCT c.customer_id) AS customers,
       SUM(v.net_order_value) AS revenue
FROM customers c JOIN v_order_financials v USING (customer_id)
WHERE v.order_status='delivered'
GROUP BY c.city ORDER BY revenue DESC;

-- Q24. Cancellation reasons.
SELECT COALESCE(cancellation_reason,'Not specified') AS reason,
       COUNT(*) AS cancelled_orders
FROM orders WHERE order_status='cancelled'
GROUP BY 1 ORDER BY 2 DESC;

-- Q25. Detect customers with above-average order frequency.
WITH frequency AS (
  SELECT customer_id, COUNT(*) AS order_count
  FROM orders WHERE order_status='delivered' GROUP BY customer_id
)
SELECT c.customer_name, f.order_count
FROM frequency f JOIN customers c USING (customer_id)
WHERE f.order_count > (SELECT AVG(order_count) FROM frequency)
ORDER BY f.order_count DESC;

-- Q26. Rolling 3-month revenue average.
WITH monthly AS (
  SELECT DATE_TRUNC('month',order_placed_at)::DATE AS month,
         SUM(net_order_value) FILTER (WHERE order_status='delivered') AS revenue
  FROM v_order_financials GROUP BY 1
)
SELECT month,revenue,
       ROUND(AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),2)
         AS rolling_3_month_avg
FROM monthly ORDER BY month;

-- Q27. Menu items priced above their restaurant category average.
SELECT r.restaurant_name,mi.item_name,mi.category,mi.list_price,
       ROUND(AVG(mi.list_price) OVER (PARTITION BY mi.restaurant_id,mi.category),2) AS category_avg
FROM menu_items mi JOIN restaurants r USING (restaurant_id)
WHERE mi.list_price > (SELECT AVG(m2.list_price) FROM menu_items m2
                       WHERE m2.restaurant_id=mi.restaurant_id AND m2.category=mi.category);

-- Q28. Delivery delay in minutes for late orders.
SELECT order_id, promised_delivery_at, delivered_at,
       ROUND(EXTRACT(EPOCH FROM (delivered_at-promised_delivery_at))/60,1) AS delay_minutes
FROM orders
WHERE order_status='delivered' AND delivered_at > promised_delivery_at
ORDER BY delay_minutes DESC;

-- Q29. Customer order sequence and time since previous order.
SELECT customer_id, order_id, order_placed_at,
       ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_placed_at) AS order_number,
       order_placed_at - LAG(order_placed_at) OVER
         (PARTITION BY customer_id ORDER BY order_placed_at) AS gap_from_previous_order
FROM orders WHERE order_status='delivered';

-- Q30. Restaurant performance scorecard.
SELECT r.restaurant_name,
       COUNT(o.order_id) AS total_orders,
       COUNT(*) FILTER (WHERE o.order_status='delivered') AS delivered_orders,
       ROUND(AVG(rv.restaurant_rating),2) AS avg_food_rating,
       ROUND(AVG(dp.delivery_minutes),1) AS avg_delivery_minutes,
       ROUND(100.0*COUNT(*) FILTER (WHERE o.order_status='delivered')
             / NULLIF(COUNT(o.order_id),0),2) AS completion_pct
FROM restaurants r LEFT JOIN orders o USING (restaurant_id)
LEFT JOIN reviews rv USING (order_id)
LEFT JOIN v_delivery_performance dp USING (order_id)
GROUP BY r.restaurant_name ORDER BY completion_pct DESC NULLS LAST;
