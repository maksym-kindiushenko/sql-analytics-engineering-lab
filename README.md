# SQL Analytics Engineering Lab

Analytics engineering exercises in **BigQuery SQL** on the public `thelook_ecommerce` dataset.
Each module answers one business question the way a production model should: define the grain first, document metric logic and assumptions, then **prove the result is correct** with validation queries against the source data.

## How each module is structured

Every SQL file follows the same template:

1. **Problem** – the business question
2. **Source and final grain** – what one row means in each table and in the result
3. **Metric definitions** – including which metrics are additive and which are not
4. **Assumptions** – canonical sources, date logic, status rules
5. **SQL** – the main query
6. **Validation** – reconciliation, grain, referential and data-quality checks, each with its expected result
7. **Findings / why this approach** – the reasoning behind the design

## Modules

| # | Module | Business question | Final grain | Key techniques | Validation queries |
|---|---|---|---|---|---|
| 01 | [Foundations](01_foundations/001_monthly_revenue.sql) | Monthly revenue from completed order items | 1 row = 1 month | `DATE_TRUNC`, aggregation, CTEs | 3: reconciliation with the source total, negative-revenue anomaly check, grain uniqueness |
| 02 | [Joins](02_joins/001_average_order.sql) | Average Order Value (AOV) per month for completed orders | 1 row = 1 month | Reducing item grain to order grain before joining, canonical header entity, avoiding join fan-out | 12: source grain, referential completeness in both directions, NULL checks, status and timestamp consistency, join cardinality, population reconciliation, an independent second AOV method, final grain, anomaly check |
| 03 | [Aggregations](03_aggregations/001_monthly_category_performance.sql) | Monthly product category performance: revenue, orders, customers, completion / return / cancellation rates | 1 row = 1 category per month | Conditional aggregation, `COUNT(DISTINCT …)`, safe division with `NULLIF`, additive vs non-additive metrics | 13: revenue and item reconciliation, primary key uniqueness, join row counts, status consistency and coverage, customer consistency, metric value rules |

## Key lessons

- **Metric logic depends on grain.** Before calculating a metric, decide what one row represents and whether that grain supports the business question.
- **Reduce to the right grain before joining.** Aggregating `order_items` to order level first prevents fan-out when joining to `orders`.
- **Not every metric can be summed.** Revenue and item counts are additive across categories; distinct order and customer counts are not, because one order can contain several categories. Rates and averages are always recalculated from their numerator and denominator.
- **Reconcile with the source.** Every aggregated result is checked against a direct calculation on the source tables.

## Dataset

[`bigquery-public-data.thelook_ecommerce`](https://console.cloud.google.com/marketplace/product/bigquery-public-data/thelook-ecommerce) – a synthetic e-commerce dataset published by Google. Tables used: `orders`, `order_items`, `products`.

## How to run

1. Open the [BigQuery console](https://console.cloud.google.com/bigquery) in any Google Cloud project (the free BigQuery sandbox is enough).
2. Paste the main query or any validation query from a module and run it. Each validation query states its expected result in a comment.

## Workflow

Each module is developed on its own feature branch (`feature/sql-foundations-01`, `feature/sql-joins-02`, `feature/sql-aggregations-03`) and merged into `main`.

## Roadmap

- **04 Window functions** – planned
- **05 Business cases** – planned
- **06 Data engineering patterns** – planned
- **dbt project** – rebuild the modules as dbt models, turning the validation queries into dbt tests and documentation

## Author

Maksym Kindiushenko – BI / analytics professional moving into analytics engineering.
