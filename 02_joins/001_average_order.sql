-- Problem: Calculate Average Order Value (AOV) per month for completed orders.
-------------------------------------------------------

-- Source grain:
--   orders:      1 row = 1 order
--   order_items: 1 row = 1 item within an order
-- Final grain:
--   1 row = 1 order month
--
-- orders is treated as the canonical order/header entity for order-level
-- attributes such as created_at and status. order_items provides the monetary
-- value of each order through sale_price.
-------------------------------------------------------

-- Expected result: order_month | average_order_value
-------------------------------------------------------

-- Assumptions:
--   1) Only orders with orders.status = 'Complete' are included.
--   2) The reporting month is based on orders.created_at.
--      order_items.created_at is not used because items from the same order
--      can have different timestamps and can span different months.
--   3) Order value is the sum of sale_price across all items in the order.
--   4) A payment/completion timestamp is unavailable, so created_at is used
--      as the canonical order date for monthly reporting.
-------------------------------------------------------


-- Main SQL
-- First reduce order_items to order grain, then calculate the average order
-- value by the canonical order month from orders.
WITH completed_orders AS (
  SELECT
    order_id,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status = 'Complete'
),

order_values AS (
  SELECT
    order_id,
    SUM(sale_price) AS order_value
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY order_id
)

SELECT
  o.order_month,
  ROUND(AVG(ov.order_value), 2) AS average_order_value
FROM completed_orders AS o
INNER JOIN order_values AS ov
  ON ov.order_id = o.order_id
GROUP BY o.order_month
ORDER BY o.order_month;


-------------------------------------------------------
-- Validation
-------------------------------------------------------

-- A. Source structure and data-quality checks

-- 1) Validate the grain of orders.
-- Expected: duplicate_order_rows = 0.
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT order_id) AS distinct_order_count,
  COUNT(*) - COUNT(DISTINCT order_id) AS duplicate_order_rows
FROM `bigquery-public-data.thelook_ecommerce.orders`;


-- 2a) Validate the Complete-order population from orders -> order_items.
-- Expected: 0 rows.
SELECT
  o.order_id
FROM `bigquery-public-data.thelook_ecommerce.orders` AS o
WHERE o.status = 'Complete'
  AND NOT EXISTS (
    SELECT 1
    FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
    WHERE oi.order_id = o.order_id
      AND oi.status = 'Complete'
  );


-- 2b) Validate the Complete-order population from order_items -> orders.
-- Expected: 0 rows.
SELECT DISTINCT
  oi.order_id
FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
WHERE oi.status = 'Complete'
  AND NOT EXISTS (
    SELECT 1
    FROM `bigquery-public-data.thelook_ecommerce.orders` AS o
    WHERE o.order_id = oi.order_id
      AND o.status = 'Complete'
  );


-- 3) Check whether sale_price contains NULL values.
-- Expected: null_sale_price_rows = 0.
SELECT
  COUNT(*) AS row_count,
  COUNTIF(sale_price IS NULL) AS null_sale_price_rows
FROM `bigquery-public-data.thelook_ecommerce.order_items`;


-- 4) Check status consistency within order_items.
-- One order should not contain items with different statuses.
-- Expected: 0 rows.
SELECT
  order_id,
  COUNT(DISTINCT status) AS status_count
FROM `bigquery-public-data.thelook_ecommerce.order_items`
GROUP BY order_id
HAVING COUNT(DISTINCT status) > 1;


-- 5) Explore timestamp consistency within order_items.
-- Rows returned here show that items from the same order may have different
-- created_at timestamps. This is not necessarily an error by itself.
SELECT
  order_id,
  COUNT(DISTINCT created_at) AS created_at_count
FROM `bigquery-public-data.thelook_ecommerce.order_items`
GROUP BY order_id
HAVING COUNT(DISTINCT created_at) > 1;


-- 6) Check whether items from the same order can span multiple months.
-- Rows returned here justify using orders.created_at as the canonical month.
SELECT
  order_id,
  COUNT(DISTINCT DATE_TRUNC(DATE(created_at), MONTH)) AS month_count
FROM `bigquery-public-data.thelook_ecommerce.order_items`
GROUP BY order_id
HAVING COUNT(DISTINCT DATE_TRUNC(DATE(created_at), MONTH)) > 1;


-- B. Calculation and reconciliation checks

-- 7) Validate raw JOIN cardinality and check for fanout or row loss.
-- Expected: row_diff = 0.
WITH source_rows AS (
  SELECT
    COUNT(*) AS source_row_count
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

joined_rows AS (
  SELECT
    COUNT(*) AS joined_row_count
  FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
  INNER JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
    ON o.order_id = oi.order_id
)

SELECT
  s.source_row_count,
  j.joined_row_count,
  j.joined_row_count - s.source_row_count AS row_diff
FROM source_rows AS s
CROSS JOIN joined_rows AS j;


-- 8) Reconcile the completed-order population between the monthly result
-- and both source tables.
-- Expected: all three counts are equal and both differences are 0.
WITH completed_orders AS (
  SELECT
    order_id,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status = 'Complete'
),

order_values AS (
  SELECT
    order_id,
    SUM(sale_price) AS order_value
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY order_id
),

monthly_population AS (
  SELECT
    o.order_month,
    COUNT(*) AS orders_count
  FROM completed_orders AS o
  INNER JOIN order_values AS ov
    ON ov.order_id = o.order_id
  GROUP BY o.order_month
),

monthly_total AS (
  SELECT
    SUM(orders_count) AS orders_in_monthly_result
  FROM monthly_population
),

orders_source AS (
  SELECT
    COUNT(*) AS complete_orders_in_orders
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status = 'Complete'
),

order_items_source AS (
  SELECT
    COUNT(DISTINCT order_id) AS complete_orders_in_order_items
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status = 'Complete'
)

SELECT
  m.orders_in_monthly_result,
  o.complete_orders_in_orders,
  oi.complete_orders_in_order_items,
  m.orders_in_monthly_result - o.complete_orders_in_orders AS diff_vs_orders,
  m.orders_in_monthly_result - oi.complete_orders_in_order_items AS diff_vs_order_items
FROM monthly_total AS m
CROSS JOIN orders_source AS o
CROSS JOIN order_items_source AS oi;


-- 9) Validate AOV using an independent calculation method.
-- Main method: first aggregate item values to order grain, then AVG(order_value).
-- Alternative method: SUM(item revenue) / COUNT(DISTINCT order_id).
-- Expected: 0 rows.
WITH completed_orders AS (
  SELECT
    order_id,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status = 'Complete'
),

order_values AS (
  SELECT
    order_id,
    SUM(sale_price) AS order_value
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY order_id
),

main_method AS (
  SELECT
    o.order_month,
    AVG(ov.order_value) AS aov
  FROM completed_orders AS o
  INNER JOIN order_values AS ov
    ON ov.order_id = o.order_id
  GROUP BY o.order_month
),

alternative_method AS (
  SELECT
    DATE_TRUNC(DATE(o.created_at), MONTH) AS order_month,
    SUM(oi.sale_price) / COUNT(DISTINCT o.order_id) AS aov
  FROM `bigquery-public-data.thelook_ecommerce.order_items` AS oi
  INNER JOIN `bigquery-public-data.thelook_ecommerce.orders` AS o
    ON o.order_id = oi.order_id
  WHERE o.status = 'Complete'
  GROUP BY DATE_TRUNC(DATE(o.created_at), MONTH)
)

SELECT
  COALESCE(m.order_month, a.order_month) AS order_month,
  ROUND(m.aov, 2) AS main_aov,
  ROUND(a.aov, 2) AS alternative_aov,
  ROUND(m.aov - a.aov, 10) AS aov_diff
FROM main_method AS m
FULL OUTER JOIN alternative_method AS a
  ON a.order_month = m.order_month
WHERE m.order_month IS NULL
   OR a.order_month IS NULL
   OR ABS(m.aov - a.aov) > 0.0000001
ORDER BY order_month;


-- 10) Validate the final grain.
-- Expected: duplicate_month_rows = 0.
WITH completed_orders AS (
  SELECT
    order_id,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status = 'Complete'
),

order_values AS (
  SELECT
    order_id,
    SUM(sale_price) AS order_value
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY order_id
),

monthly_aov AS (
  SELECT
    o.order_month,
    AVG(ov.order_value) AS average_order_value
  FROM completed_orders AS o
  INNER JOIN order_values AS ov
    ON ov.order_id = o.order_id
  GROUP BY o.order_month
)

SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT order_month) AS distinct_month_count,
  COUNT(*) - COUNT(DISTINCT order_month) AS duplicate_month_rows
FROM monthly_aov;


-- 11) Optional anomaly check for the final metric.
-- This is an anomaly check, not a correctness check.
-- Expected for this dataset: no NULL or non-positive AOV values.
WITH completed_orders AS (
  SELECT
    order_id,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status = 'Complete'
),

order_values AS (
  SELECT
    order_id,
    SUM(sale_price) AS order_value
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY order_id
),

monthly_aov AS (
  SELECT
    o.order_month,
    AVG(ov.order_value) AS average_order_value
  FROM completed_orders AS o
  INNER JOIN order_values AS ov
    ON ov.order_id = o.order_id
  GROUP BY o.order_month
)

SELECT
  order_month,
  average_order_value
FROM monthly_aov
WHERE average_order_value IS NULL
   OR average_order_value <= 0
ORDER BY order_month;


-------------------------------------------------------
-- Why this approach:
-- AOV is an order-level metric, so order_items is first aggregated from item
-- grain to order grain. orders is then used as the canonical source for
-- order-level attributes, especially status and reporting month. The final
-- aggregation calculates the average order value at monthly grain.
--
-- Validation checks confirm source grain, referential completeness, status and
-- timestamp assumptions, JOIN cardinality, completed-order population, final
-- grain, and equivalence between two independent AOV calculation methods.
-------------------------------------------------------
