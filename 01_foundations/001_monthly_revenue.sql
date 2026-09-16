-- Problem: We need to calculate revenue from Complete order items grouped by their creation month
-------------------------------------------------------
-------------------------------------------------------

-- Grain: one row represents revenue per month
-------------------------------------------------------
-------------------------------------------------------

-- Expected result: order_month | total_revenue
-------------------------------------------------------
-------------------------------------------------------

-- Assumptions:
  -- 1) Revenue is calculated as the sum of sale_price for Complete order items.
  -- 2) Payment timestamp is unavailable, so created_at is used to assign revenue to a month.
-------------------------------------------------------
-------------------------------------------------------


-- Data quality note:
-- Some records contain unexpected timestamp sequences and require additional investigation.
-------------------------------------------------------
-------------------------------------------------------


-- SQL: 
SELECT
  DATE_TRUNC(DATE(created_at), MONTH) AS order_month,
  SUM(sale_price) AS total_revenue
FROM `bigquery-public-data.thelook_ecommerce.order_items`
WHERE status = 'Complete'
GROUP BY DATE_TRUNC(DATE(created_at), MONTH)
ORDER BY 1;
-------------------------------------------------------
-------------------------------------------------------

-- Validation:
-------------------------------------------------------
-------------------------------------------------------
    --1) Does total revenue after aggregation equal the source data using the same business logic?

-- Reuse the base monthly revenue logic without changing its calculation.
WITH monthly_revenue AS (
  SELECT
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month,
    SUM(sale_price) AS total_revenue
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status = 'Complete'
  GROUP BY DATE_TRUNC(DATE(created_at), MONTH)
),

-- Aggregate all monthly results into one total value to compare it with the source-level calculation.
monthly_revenue_agg AS (
  SELECT
    SUM(total_revenue) AS aggregated_revenue
  FROM monthly_revenue
),

-- Calculate revenue directly from the source table using the same business rule for comparison.
data_source AS (
  SELECT
    SUM(sale_price) AS source_revenue
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status = 'Complete'
)

-- Compare the aggregated monthly result with the direct source calculation.
SELECT 
  ROUND(a.aggregated_revenue, 2) AS aggregated_revenue,
  ROUND(d.source_revenue, 2) AS source_revenue,
  ROUND((a.aggregated_revenue - d.source_revenue), 2) AS diff
FROM monthly_revenue_agg a
CROSS JOIN data_source d;
-------------------------------------------------------
-------------------------------------------------------

    --2) Are there any months with negative revenue? 
SELECT
  DATE_TRUNC(DATE(created_at), MONTH) AS order_month,
  SUM(sale_price) AS total_revenue
FROM `bigquery-public-data.thelook_ecommerce.order_items`
WHERE status = 'Complete'
GROUP BY DATE_TRUNC(DATE(created_at), MONTH)
HAVING total_revenue < 0 -- anomaly check, not a correctness check
ORDER BY 1;
-------------------------------------------------------
-------------------------------------------------------

    --3) Are there any duplicated months in the final output?

-- Reuse the base monthly revenue logic without changing its calculation.
WITH monthly_revenue AS (
  SELECT
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month,
    SUM(sale_price) AS total_revenue
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status = 'Complete'
  GROUP BY DATE_TRUNC(DATE(created_at), MONTH)
)

-- Compare the number of distinct months with the total row count.
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT order_month) AS distinct_month_count,
  (COUNT(*) - COUNT(DISTINCT order_month)) AS diff
FROM monthly_revenue;
    
-------------------------------------------------------
-------------------------------------------------------
-- Why this approach:
-- DATE_TRUNC aligns order timestamps with the required monthly grain.
-- Only Complete order items are included according to the defined revenue rule.
-- Validation checks reconcile the monthly aggregation with the source total
-- and verify that the final dataset preserves one row per month.
-------------------------------------------------------