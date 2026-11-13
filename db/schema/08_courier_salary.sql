-- ============================================================================
-- FoodExpress / FOOD-107
-- courier_salary() — зарплата курьеров за текущий месяц (BR-10.2).
--
-- Таблица "order" читается ровно один раз: агрегат agg считает для каждого
-- курьера сразу count(доставленных) и sum(commission). Этот же агрегат
-- используется и для INSERT в courier_pay, и для UPDATE коэффициента.
--
-- coalesce(sum(...), 0) нужен потому, что sum по пустому набору — NULL,
-- а зарплата курьера без доставок должна быть 0 (FOOD-107). Для count()
-- coalesce не нужен: count(*) по LEFT JOIN возвращает 0, а не NULL.
--
-- coalesce(cp.coefficient_used, c.coefficient) обеспечивает идемпотентность:
-- при повторном вызове за тот же месяц courier.coefficient уже переключён на
-- следующий месяц, поэтому применённый коэффициент берётся из существующей
-- записи courier_pay. Повторный вызов обновляет строку, а не создаёт дубль.
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
    WITH agg AS (
        SELECT c.courier_id,
               c.status,
               c.coefficient,
               count(o.order_id)                              AS delivered_count,
               coalesce(sum(o.commission), 0)::numeric(10,2)  AS commission
          FROM courier c
          LEFT JOIN "order" o
                 ON o.courier_id = c.courier_id
                AND o.status = 'доставлен'
                AND o.order_timestamp >= v_start
                AND o.order_timestamp < v_end
         GROUP BY c.courier_id, c.status, c.coefficient
    ),
    ins AS (
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
        RETURNING 1
    )
    UPDATE courier c
       SET coefficient = CASE
               WHEN a.delivered_count <= 150 THEN 0.10
               WHEN a.delivered_count <= 250 THEN 0.20
               WHEN a.delivered_count <= 500 THEN 0.30
               ELSE 0.50
           END
      FROM agg a
     WHERE c.courier_id = a.courier_id
       AND c.status <> 'уволен';  -- BR-10.6: уволенным коэффициент не назначается
END;
$$;

COMMENT ON PROCEDURE courier_salary() IS
    'FOOD-107, BR-10.2: считает зарплату за текущий месяц и новый коэффициент. "order" читается один раз (агрегат agg), повторный вызов идемпотентен; уволенные получают выплату, но коэффициент не обновляется.';
