-- ============================================================================
-- FoodExpress / FOOD-107
-- courier_salary() — зарплата курьеров за текущий месяц (BR-10.2).
-- Месяц считается по order_timestamp — так же, как в шаблонном тесте C.8.
-- "order" читается один раз: CTE agg материализуется и используется и для
-- вставки courier_pay, и для обновления коэффициента. LEFT JOIN сохраняет
-- курьеров без доставок: им положены amount = 0 и коэффициент 0.10.
-- Уволенным до текущего месяца запись не создаётся (BR-10.6).
-- Повторный вызов идемпотентен: применённый коэффициент берётся из уже
-- созданной записи courier_pay.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

CREATE OR REPLACE PROCEDURE courier_salary()
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_start timestamp := date_trunc('month', localtimestamp);
    v_end   timestamp := date_trunc('month', localtimestamp) + interval '1 month';
    v_year  int := extract(year FROM localtimestamp)::int;
    v_month int := extract(month FROM localtimestamp)::int;
BEGIN
    WITH agg AS MATERIALIZED (
        -- Один скан заказов и всех курьеров, включая тех, у кого доставок нет.
        SELECT c.courier_id,
               c.status,
               c.coefficient,
               count(o.order_id) AS delivered_orders,
               coalesce(sum(o.commission), 0) AS commission
          FROM courier c
          LEFT JOIN "order" o
                 ON o.courier_id = c.courier_id
                AND o.status = 'доставлен'
                AND o.order_timestamp >= v_start
                AND o.order_timestamp < v_end
         WHERE c.dismissal_date IS NULL OR c.dismissal_date >= v_start
         GROUP BY c.courier_id, c.status, c.coefficient
    ),
    ins AS (
        -- Повторный вызов обновляет строку, сохраняя уже применённый коэффициент.
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        SELECT v_year,
               v_month,
               a.courier_id,
               round(a.commission * coalesce(cp.coefficient_used, a.coefficient), 2),
               coalesce(cp.coefficient_used, a.coefficient)
          FROM agg a
          LEFT JOIN courier_pay cp
                 ON cp.year = v_year
                AND cp.month = v_month
                AND cp.courier_id = a.courier_id
        ON CONFLICT (year, month, courier_id) DO UPDATE
           SET amount = EXCLUDED.amount,
               coefficient_used = EXCLUDED.coefficient_used
        RETURNING courier_id
    )
    UPDATE courier c
       SET coefficient = CASE
               WHEN a.delivered_orders <= 150 THEN 0.10
               WHEN a.delivered_orders <= 250 THEN 0.20
               WHEN a.delivered_orders <= 500 THEN 0.30
               ELSE 0.50
           END
      FROM agg a
      JOIN ins i ON i.courier_id = a.courier_id
     WHERE c.courier_id = a.courier_id
       AND c.status <> 'уволен';  -- BR-10.6: уволенным коэффициент не назначается
END;
$$;
