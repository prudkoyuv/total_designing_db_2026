-- ============================================================================
-- FoodExpress / FOOD-107
-- courier_salary() — зарплата курьеров за текущий месяц (BR-10.2).
-- Повторный вызов за тот же месяц обновляет запись, а не создаёт дубликат.
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
    INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
    SELECT v_year,
           v_month,
           c.courier_id,
           round(coalesce(agg.commission, 0)
                 * coalesce(cp.coefficient_used, c.coefficient), 2),
           coalesce(cp.coefficient_used, c.coefficient)
      FROM courier c
      LEFT JOIN (
          SELECT o.courier_id,
                 sum(o.commission) AS commission
            FROM "order" o
           WHERE o.status = 'доставлен'
             AND o.order_timestamp >= v_start
             AND o.order_timestamp < v_end
           GROUP BY o.courier_id
      ) agg ON agg.courier_id = c.courier_id
      LEFT JOIN courier_pay cp
             ON cp.year = v_year
            AND cp.month = v_month
            AND cp.courier_id = c.courier_id
    ON CONFLICT (year, month, courier_id) DO UPDATE
       SET amount = EXCLUDED.amount,
           coefficient_used = EXCLUDED.coefficient_used;

    -- Новый коэффициент действует со следующего месяца.
    -- Уволенным коэффициент не назначается (BR-10.6).
    UPDATE courier c
       SET coefficient = CASE
               WHEN coalesce(agg.delivered_count, 0) <= 150 THEN 0.10
               WHEN coalesce(agg.delivered_count, 0) <= 250 THEN 0.20
               WHEN coalesce(agg.delivered_count, 0) <= 500 THEN 0.30
               ELSE 0.50
           END
      FROM (
          SELECT c2.courier_id,
                 count(o.order_id) AS delivered_count
            FROM courier c2
            LEFT JOIN "order" o
                   ON o.courier_id = c2.courier_id
                  AND o.status = 'доставлен'
                  AND o.order_timestamp >= v_start
                  AND o.order_timestamp < v_end
           GROUP BY c2.courier_id
      ) agg
     WHERE c.courier_id = agg.courier_id
       AND c.status <> 'уволен';
END;
$$;
