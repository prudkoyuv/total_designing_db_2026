-- ============================================================================
-- FoodExpress / FOOD-108
-- how_much_money — помесячный отчёт (BR-11.9): непрерывная серия месяцев,
-- выручка по доставленным заказам, выплаты курьерам, комиссия, её изменение
-- к прошлому месяцу (LAG) и чистая прибыль.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

CREATE OR REPLACE VIEW how_much_money AS
WITH RECURSIVE bounds AS (
    -- Месяц доставки: только доставленные заказы (BR-10.5, BR-11.9).
    SELECT date_trunc('month', min(o.delivery_timestamp)) AS first_month,
           date_trunc('month', max(o.delivery_timestamp)) AS last_month
      FROM "order" o
     WHERE o.status = 'доставлен'
),
months AS (
    -- Непрерывная серия месяцев: каждый следующий = предыдущий + 1 month.
    SELECT b.first_month AS month_start
      FROM bounds b
     WHERE b.first_month IS NOT NULL

    UNION ALL

    SELECT (m.month_start + interval '1 month')::timestamp
      FROM months m
      JOIN bounds b ON true
     WHERE m.month_start < b.last_month
),
order_months AS (
    SELECT date_trunc('month', o.delivery_timestamp) AS month_start,
           sum(o.order_amount)::numeric AS sum_no_commission,
           sum(o.total_amount)::numeric AS sum_with_commission
      FROM "order" o
     WHERE o.status = 'доставлен'
     GROUP BY date_trunc('month', o.delivery_timestamp)
),
pay_months AS (
    SELECT make_date(cp.year, cp.month, 1)::timestamp AS month_start,
           sum(cp.amount)::numeric AS courier_pay
      FROM courier_pay cp
     GROUP BY make_date(cp.year, cp.month, 1)::timestamp
),
base AS (
    -- LEFT JOIN: месяц без заказов остаётся в отчёте с нулями (BR-11.9).
    SELECT m.month_start,
           coalesce(om.sum_no_commission, 0)::numeric AS sum_no_commission,
           coalesce(om.sum_with_commission, 0)::numeric AS sum_with_commission,
           (coalesce(om.sum_with_commission, 0)
            - coalesce(om.sum_no_commission, 0))::numeric AS commission,
           coalesce(pm.courier_pay, 0)::numeric AS courier_pay
      FROM months m
      LEFT JOIN order_months om ON om.month_start = m.month_start
      LEFT JOIN pay_months pm ON pm.month_start = m.month_start
)
SELECT to_char(month_start, 'YYYY-MM') AS year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       lag(commission) OVER (ORDER BY month_start) AS prev_commission,
       (commission - lag(commission) OVER (ORDER BY month_start)) AS commission_diff,
       courier_pay,
       (commission - courier_pay) AS net_profit
  FROM base;
