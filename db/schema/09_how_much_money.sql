-- ============================================================================
-- FoodExpress / FOOD-108
-- how_much_money — месячный отчёт по деньгам (BR-11.9).
--
-- Как устроено:
--   bounds      — первый и последний месяц с доставленными заказами;
--   months      — непрерывная серия месяцев (рекурсивный CTE, BR-11.9);
--   order_months— суммы order_amount и total_amount по месяцам;
--   pay_months  — суммы выплат курьерам по месяцам;
--   base        — LEFT JOIN месяцев с суммами: месяцы без заказов/выплат
--                 получают 0, а не выпадают из отчёта;
--   финальный SELECT считает commission, prev_commission (LAG), разницу и
--                 чистую прибыль.
--
-- Представление не хранит данные и не пересчитывает их при записи: отчёт
-- всегда строится по текущему состоянию таблиц.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

CREATE OR REPLACE VIEW how_much_money AS
WITH RECURSIVE bounds AS (
    -- Границы отчёта: только доставленные заказы (BR-10.5, BR-11.9).
    SELECT date_trunc('month', min(o.order_timestamp)) AS first_month,
           date_trunc('month', max(o.order_timestamp)) AS last_month
      FROM "order" o
     WHERE o.status = 'доставлен'
),
months AS (
    -- Рекурсивная серия: каждый следующий месяц = предыдущий + 1 month.
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
    -- Деньги по заказам: без комиссии и с комиссией.
    SELECT date_trunc('month', o.order_timestamp) AS month_start,
           sum(o.order_amount)::numeric AS sum_no_commission,
           sum(o.total_amount)::numeric AS sum_with_commission
      FROM "order" o
     WHERE o.status = 'доставлен'
     GROUP BY date_trunc('month', o.order_timestamp)
),
pay_months AS (
    -- Выплаты курьерам за месяц.
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

COMMENT ON VIEW how_much_money IS
    'FOOD-108, BR-11.9: помесячный отчёт. Серия месяцев непрерывна (рекурсивный CTE), месяцы без данных присутствуют с нулями; prev_commission считается через LAG.';
COMMENT ON COLUMN how_much_money.year_month IS
    'Месяц в формате YYYY-MM (text, контракт FOOD-108).';
COMMENT ON COLUMN how_much_money.commission IS
    'sum_with_commission - sum_no_commission: доход сервиса за месяц.';
COMMENT ON COLUMN how_much_money.prev_commission IS
    'Комиссия предыдущего месяца; NULL для первого месяца серии.';
COMMENT ON COLUMN how_much_money.commission_diff IS
    'Изменение комиссии к предыдущему месяцу; NULL для первого месяца.';
COMMENT ON COLUMN how_much_money.net_profit IS
    'commission - courier_pay: прибыль после выплат курьерам.';
