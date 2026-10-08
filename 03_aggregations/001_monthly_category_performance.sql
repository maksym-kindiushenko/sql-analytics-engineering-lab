-- Problem:
-- Build a monthly product category performance dataset that allows management
-- to compare categories by revenue, order volume, customer volume and order quality.
-------------------------------------------------------

-- Source grain:
--   products:    1 row = 1 product
--   orders:      1 row = 1 order
--   order_items: 1 row = 1 item within an order
-- Final grain:
--   1 row = 1 category per order month
--
-- Each row represents the cohort of orders created in that month
-- that contained at least one item from the category.
--
-- orders is treated as the canonical order/header entity for order-level
-- attributes such as created_at and status. order_items provides the monetary
-- value of order items through sale_price.
-- products provides category attribution.
-------------------------------------------------------

-- Metric definitions:

-- Additive metrics:
--   completed_revenue
--   completed_items
--
-- These can be summed across both months and product categories,
-- because each order item belongs to exactly one order month
-- and one product category.

-- Non-additive / conditionally additive metrics:
--   completed_orders
--   returned_orders
--   cancelled_orders
--   orders_containing_category
--
-- These are DISTINCT order counts.
-- They can be summed across months for the same category because
-- one order belongs to exactly one order_month.
-- They MUST NOT be summed across product categories because
-- one order can contain products from multiple categories.

-- Non-additive metrics:
--   completed_unique_customers
--
-- One customer can appear in multiple months and multiple categories,
-- therefore customer counts cannot be summed across either dimension.

-- Derived non-additive metrics:
--   avg_category_revenue_per_order
--   avg_category_items_per_completed_order
--   completion_rate
--   return_rate
--   cancellation_rate
--
-- These must be recalculated from their numerator and denominator,
-- not summed or averaged across rows.
--
-- avg_category_revenue_per_order is not Average Order Value (AOV).
-- It shows how much revenue the category generates on average
-- per completed order containing at least one item from that category.
--
-- A true AOV for orders containing a category would require the full
-- order value, including items from other categories.

-- Expected result:
-- order_month | product_category | completed_revenue | completed_orders |
-- completed_items | completed_unique_customers | returned_orders |
-- cancelled_orders | orders_containing_category |
-- avg_category_revenue_per_order |
-- avg_category_items_per_completed_order |
-- completion_rate | return_rate | cancellation_rate

-- Assumptions:
--   1) orders is the canonical source for order status and order creation date.
--   2) Reporting month is based on orders.created_at.
--   3) Status metrics describe the status of orders created in that month.
--      They do not represent the month when the status changed.
--   4) One order can contain products from multiple categories.
--      Therefore DISTINCT order counts are not additive across categories.
--   5) Each product belongs to one product category.
--   6) completed_unique_customers includes only customers from completed orders.
--   7) completion_rate, return_rate and cancellation_rate show the share
--      of orders containing the category that currently have the given status.
-------------------------------------------------------

-- SQL:

WITH orders AS (
  SELECT
    order_id,
    status,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
),

order_items AS (
  SELECT
    id,
    order_id,
    user_id,
    product_id,
    sale_price
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

products AS (
  SELECT
    id,
    category AS product_category
  FROM `bigquery-public-data.thelook_ecommerce.products`
)

SELECT
  o.order_month,
  p.product_category,
  ROUND(SUM(
    IF(o.status = 'Complete', oi.sale_price, 0)), 2)  AS completed_revenue,
  COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Complete')                    AS completed_orders,
  COUNT(
      oi.id
      WHERE o.status = 'Complete')                    AS completed_items,
  COUNT(
      DISTINCT oi.user_id
      WHERE o.status = 'Complete')                    AS completed_unique_customers,
  COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Returned')                    AS returned_orders,
  COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Cancelled')                   AS cancelled_orders,
  COUNT(
      DISTINCT o.order_id)                            AS orders_containing_category,
  ROUND(SUM(
    IF(o.status = 'Complete', oi.sale_price, 0)) /
    NULLIF(
      COUNT(
        DISTINCT o.order_id
        WHERE o.status = 'Complete'), 0), 2)          AS avg_category_revenue_per_order,
  ROUND(COUNT(
      oi.id
      WHERE o.status = 'Complete') /
    NULLIF(
      COUNT(
        DISTINCT o.order_id
        WHERE o.status = 'Complete'), 0), 2)          AS avg_category_items_per_completed_order,
  ROUND(COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Complete') /
    NULLIF(
      COUNT(DISTINCT o.order_id), 0), 4)              AS completion_rate,
  ROUND(COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Returned') /
    NULLIF(
      COUNT(DISTINCT o.order_id), 0), 4)              AS return_rate,
  ROUND(COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Cancelled') /
    NULLIF(
      COUNT(DISTINCT o.order_id), 0), 4)              AS cancellation_rate
FROM order_items oi
INNER JOIN orders o
  ON oi.order_id = o.order_id
INNER JOIN products p
  ON oi.product_id = p.id
GROUP BY
  o.order_month,
  p.product_category
ORDER BY
  o.order_month,
  p.product_category;


-------------------------------------------------------
-- Validation:
-------------------------------------------------------

-- 1) Final grain uniqueness
-- Check that each order_month + product_category pair appears only once.
-- Expected: unique_pairs = rows_count.

WITH monthly_order_created_cohort AS (
  WITH orders AS (
    SELECT
      order_id,
      status,
      DATE_TRUNC(DATE(created_at), MONTH) AS order_month
    FROM `bigquery-public-data.thelook_ecommerce.orders`
  ),

  order_items AS (
    SELECT
      id,
      order_id,
      user_id,
      product_id,
      sale_price
    FROM `bigquery-public-data.thelook_ecommerce.order_items`
  ),

  products AS (
    SELECT
      id,
      category AS product_category
    FROM `bigquery-public-data.thelook_ecommerce.products`
  )

  SELECT
    o.order_month,
    p.product_category
  FROM order_items oi
  INNER JOIN orders o
    ON oi.order_id = o.order_id
  INNER JOIN products p
    ON oi.product_id = p.id
  GROUP BY
    o.order_month,
    p.product_category
)

SELECT
  (
    SELECT COUNT(*)
    FROM (
      SELECT DISTINCT
        order_month,
        product_category
      FROM monthly_order_created_cohort
    )
  ) AS unique_pairs,
  COUNT(*) AS rows_count
FROM monthly_order_created_cohort;


-------------------------------------------------------

-- 2) Completed revenue reconciliation
-- Check that total completed revenue after aggregation matches
-- completed revenue calculated from the source data.
-- Expected: diff = 0.

WITH orders AS (
  SELECT
    order_id,
    status,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
),

order_items AS (
  SELECT
    id,
    order_id,
    user_id,
    product_id,
    sale_price
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

products AS (
  SELECT
    id,
    category AS product_category
  FROM `bigquery-public-data.thelook_ecommerce.products`
),

monthly_order_created_cohort AS (
  SELECT
    o.order_month,
    p.product_category,
    SUM(
      IF(o.status = 'Complete', oi.sale_price, 0)) AS completed_revenue
  FROM order_items oi
  INNER JOIN orders o
    ON oi.order_id = o.order_id
  INNER JOIN products p
    ON oi.product_id = p.id
  GROUP BY
    o.order_month,
    p.product_category
),

source_revenue AS (
  SELECT
    SUM(oi.sale_price) AS source_revenue_value
  FROM order_items oi
  INNER JOIN orders o
    ON oi.order_id = o.order_id
  WHERE o.status = 'Complete'
),

cohort_revenue AS (
  SELECT
    SUM(completed_revenue) AS cohort_revenue_value
  FROM monthly_order_created_cohort
)

SELECT
  ROUND(sr.source_revenue_value, 2) AS source_revenue_value,
  ROUND(cr.cohort_revenue_value, 2) AS cohort_revenue_value,
  ROUND(sr.source_revenue_value - cr.cohort_revenue_value, 2) AS diff
FROM source_revenue sr
CROSS JOIN cohort_revenue cr;


-------------------------------------------------------

-- 3) Completed items reconciliation
-- Check that category aggregation does not lose or duplicate completed items.
-- Expected: diff = 0.

WITH orders AS (
  SELECT
    order_id,
    status,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
),

order_items AS (
  SELECT
    id,
    order_id,
    user_id,
    product_id,
    sale_price
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

products AS (
  SELECT
    id,
    category AS product_category
  FROM `bigquery-public-data.thelook_ecommerce.products`
),

monthly_order_created_cohort AS (
  SELECT
    o.order_month,
    p.product_category,
    COUNT(
      oi.id
      WHERE o.status = 'Complete') AS completed_items
  FROM order_items oi
  INNER JOIN orders o
    ON oi.order_id = o.order_id
  INNER JOIN products p
    ON oi.product_id = p.id
  GROUP BY
    o.order_month,
    p.product_category
),

cohort_items_agg AS (
  SELECT
    SUM(completed_items) AS completed_items_cohort
  FROM monthly_order_created_cohort
),

source_completed_items AS (
  SELECT
    COUNT(oi.id) AS completed_items_source
  FROM order_items oi
  INNER JOIN orders o
    ON o.order_id = oi.order_id
  WHERE o.status = 'Complete'
)

SELECT
  completed_items_cohort,
  completed_items_source,
  completed_items_source - completed_items_cohort AS diff
FROM cohort_items_agg
CROSS JOIN source_completed_items;


-------------------------------------------------------

-- 4) Source key uniqueness
-- Check that source primary keys are unique and not NULL.
-- Expected: duplicate_keys = 0 and null_keys = 0.

SELECT
  COUNT(*) AS row_count,
  COUNTIF(order_id IS NULL) AS null_keys,
  COUNT(order_id) - COUNT(DISTINCT order_id) AS duplicate_keys
FROM `bigquery-public-data.thelook_ecommerce.orders`;

SELECT
  COUNT(*) AS row_count,
  COUNTIF(id IS NULL) AS null_keys,
  COUNT(id) - COUNT(DISTINCT id) AS duplicate_keys
FROM `bigquery-public-data.thelook_ecommerce.order_items`;

SELECT
  COUNT(*) AS row_count,
  COUNTIF(id IS NULL) AS null_keys,
  COUNT(id) - COUNT(DISTINCT id) AS duplicate_keys
FROM `bigquery-public-data.thelook_ecommerce.products`;


-------------------------------------------------------

-- 5) JOIN row count validation
-- Check that joining orders and products does not lose or duplicate order items.
-- Expected: diff = 0.

WITH orders AS (
  SELECT
    order_id
  FROM `bigquery-public-data.thelook_ecommerce.orders`
),

order_items AS (
  SELECT
    id,
    order_id,
    product_id
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

products AS (
  SELECT
    id
  FROM `bigquery-public-data.thelook_ecommerce.products`
),

order_items_agg AS (
  SELECT
    COUNT(*) AS items_source
  FROM order_items
),

order_items_joined AS (
  SELECT
    COUNT(*) AS items_joined
  FROM order_items oi
  INNER JOIN orders o
    ON o.order_id = oi.order_id
  INNER JOIN products p
    ON p.id = oi.product_id
)

SELECT
  items_source,
  items_joined,
  items_source - items_joined AS diff
FROM order_items_agg
CROSS JOIN order_items_joined;


-------------------------------------------------------

-- 6) Order item status consistency
-- Check that items from the same order do not have different statuses.
-- Expected: 0 rows.

SELECT
  order_id,
  COUNT(DISTINCT status) AS item_status_count
FROM `bigquery-public-data.thelook_ecommerce.order_items`
GROUP BY order_id
HAVING COUNT(DISTINCT status) > 1;


-------------------------------------------------------

-- 6b) Order vs item status consistency
-- Check that order item status matches the status stored in orders.
-- Expected: 0 rows.

SELECT
  oi.order_id,
  o.status AS order_status,
  oi.status AS item_status,
  COUNT(*) AS item_count
FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
INNER JOIN `bigquery-public-data.thelook_ecommerce.orders` o
  ON o.order_id = oi.order_id
WHERE oi.status IS DISTINCT FROM o.status
GROUP BY
  oi.order_id,
  o.status,
  oi.status;


-------------------------------------------------------

-- 7) Missing product categories
-- Check whether any order items are linked to products without a category.
-- Expected: item_count = 0 and revenue = 0.

SELECT
  COUNT(*) AS item_count,
  COALESCE(SUM(oi.sale_price), 0) AS revenue
FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
INNER JOIN `bigquery-public-data.thelook_ecommerce.products` p
  ON oi.product_id = p.id
WHERE p.category IS NULL;


-------------------------------------------------------

-- 8) Order status coverage
-- Check that every order in each month/category cohort belongs
-- to one of the expected statuses.
-- Expected: 0 rows.

WITH orders AS (
  SELECT
    order_id,
    status,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
),

order_items AS (
  SELECT
    id,
    order_id,
    product_id
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

products AS (
  SELECT
    id,
    category AS product_category
  FROM `bigquery-public-data.thelook_ecommerce.products`
),

monthly_order_created_cohort AS (
  SELECT
    o.order_month,
    p.product_category,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Complete')     AS completed_orders,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Returned')     AS returned_orders,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Cancelled')    AS cancelled_orders,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Processing')   AS processing_orders,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Shipped')      AS shipped_orders,
    COUNT(
      DISTINCT o.order_id)             AS orders_containing_category
  FROM order_items oi
  INNER JOIN orders o
    ON oi.order_id = o.order_id
  INNER JOIN products p
    ON oi.product_id = p.id
  GROUP BY
    o.order_month,
    p.product_category
)

SELECT
  order_month,
  product_category,
  completed_orders,
  returned_orders,
  cancelled_orders,
  processing_orders,
  shipped_orders,
  orders_containing_category
FROM monthly_order_created_cohort
WHERE
    completed_orders
  + returned_orders
  + cancelled_orders
  + processing_orders
  + shipped_orders
  != orders_containing_category;


-------------------------------------------------------

-- 9) Customer consistency within an order
-- Check that one order is not linked to multiple customer IDs.
-- Expected: 0 rows.

SELECT
  order_id,
  COUNT(DISTINCT user_id) AS users
FROM `bigquery-public-data.thelook_ecommerce.order_items`
GROUP BY order_id
HAVING COUNT(DISTINCT user_id) > 1;


-------------------------------------------------------

-- 10) Metric value checks
-- Check basic rules for counts, rates and averages.
-- Expected: 0 rows.

WITH orders AS (
  SELECT
    order_id,
    status,
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
),

order_items AS (
  SELECT
    id,
    order_id,
    user_id,
    product_id,
    sale_price
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

products AS (
  SELECT
    id,
    category AS product_category
  FROM `bigquery-public-data.thelook_ecommerce.products`
),

monthly_order_created_cohort AS (
  SELECT
    o.order_month,
    p.product_category,
    ROUND(SUM(
      IF(o.status = 'Complete', oi.sale_price, 0)), 2)  AS completed_revenue,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Complete')                      AS completed_orders,
    COUNT(
      oi.id
      WHERE o.status = 'Complete')                      AS completed_items,
    COUNT(
      DISTINCT oi.user_id
      WHERE o.status = 'Complete')                      AS completed_unique_customers,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Returned')                      AS returned_orders,
    COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Cancelled')                     AS cancelled_orders,
    COUNT(
      DISTINCT o.order_id)                              AS orders_containing_category,
    ROUND(SUM(
      IF(o.status = 'Complete', oi.sale_price, 0)) /
      NULLIF(
        COUNT(
          DISTINCT o.order_id
          WHERE o.status = 'Complete'), 0), 2)          AS avg_category_revenue_per_order,
    ROUND(COUNT(
      oi.id
      WHERE o.status = 'Complete') /
      NULLIF(
        COUNT(
          DISTINCT o.order_id
          WHERE o.status = 'Complete'), 0), 2)          AS avg_category_items_per_completed_order,
    ROUND(COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Complete') /
      NULLIF(
        COUNT(DISTINCT o.order_id), 0), 4)              AS completion_rate,
    ROUND(COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Returned') /
      NULLIF(
        COUNT(DISTINCT o.order_id), 0), 4)              AS return_rate,
    ROUND(COUNT(
      DISTINCT o.order_id
      WHERE o.status = 'Cancelled') /
      NULLIF(
        COUNT(DISTINCT o.order_id), 0), 4)              AS cancellation_rate
  FROM order_items oi
  INNER JOIN orders o
    ON oi.order_id = o.order_id
  INNER JOIN products p
    ON oi.product_id = p.id
  GROUP BY
    o.order_month,
    p.product_category
)

SELECT
  *
FROM monthly_order_created_cohort
WHERE
  completion_rate NOT BETWEEN 0 AND 1
  OR return_rate NOT BETWEEN 0 AND 1
  OR cancellation_rate NOT BETWEEN 0 AND 1
  OR completed_orders > orders_containing_category
  OR returned_orders > orders_containing_category
  OR cancelled_orders > orders_containing_category
  OR completed_unique_customers > completed_orders
  OR completed_items < completed_orders
  OR avg_category_revenue_per_order < 0
  OR avg_category_items_per_completed_order < 1
  OR (
    completed_orders = 0
    AND (
      avg_category_revenue_per_order IS NOT NULL
      OR avg_category_items_per_completed_order IS NOT NULL
    )
  );


-------------------------------------------------------
-- Findings:
--
-- Revenue and item counts are additive across product categories because
-- each order item belongs to one category.
--
-- DISTINCT order counts are not additive across categories because the same
-- order can contain products from several categories.
--
-- The same limitation applies to customer counts because one customer can
-- appear in several categories and months.
--
-- Some metrics can still be calculated at the month/category grain,
-- but their business meaning must be defined carefully.
--
-- avg_category_revenue_per_order is not Average Order Value.
-- It measures the average revenue contribution of a category within
-- completed orders that contain that category.
--
-- If a business question requires full order value or a true customer/order
-- metric, a different grain may be required.
-------------------------------------------------------

-- Why this approach:
--
-- The query keeps source entities at their natural grain and joins
-- order items with order-level status/date information and product category.
--
-- The final aggregation uses month + category because this is the reporting
-- grain required for category performance analysis.
--
-- Additive metrics are reconciled with source data.
-- DISTINCT counts and derived metrics are validated separately because
-- they cannot always be aggregated across categories.
--
-- Main lesson:
-- metric logic depends on grain.
-- Before calculating a metric, we need to understand what business question
-- it answers and whether the selected grain supports this calculation.
-------------------------------------------------------
