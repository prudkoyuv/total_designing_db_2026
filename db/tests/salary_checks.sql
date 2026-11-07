-- ============================================================================
-- FoodExpress — проверки FOOD-107 (courier_salary).
-- ============================================================================

SET search_path TO prudko_food, exts;

DO $$
DECLARE
    v_year int := extract(year FROM localtimestamp)::int;
    v_month int := extract(month FROM localtimestamp)::int;
    v_count_before int;
    v_count_after int;
    v_bad_amounts int;
    v_dismissed_id uuid;
    v_dismissed_before numeric;
    v_dismissed_after numeric;
    v_pay_hash_1 text;
    v_pay_hash_2 text;
    v_coef_hash_1 text;
    v_coef_hash_2 text;
    v_zero_pay_couriers int;
BEGIN
    SELECT count(*) INTO v_count_before
      FROM courier_pay
     WHERE year = v_year AND month = v_month;

    SELECT courier_id, coefficient
      INTO v_dismissed_id, v_dismissed_before
      FROM courier
     WHERE status = 'уволен'
     ORDER BY courier_id
     LIMIT 1;

    CALL courier_salary();

    SELECT count(*) INTO v_count_after
      FROM courier_pay
     WHERE year = v_year AND month = v_month;

    IF v_count_after <> v_count_before THEN
        RAISE EXCEPTION 'courier_salary: строк за месяц % вместо %', v_count_after, v_count_before;
    END IF;

    SELECT count(*) INTO v_bad_amounts
      FROM courier_pay cp
      LEFT JOIN (
          SELECT o.courier_id, sum(o.commission) AS commission
            FROM "order" o
           WHERE o.status = 'доставлен'
             AND o.order_timestamp >= date_trunc('month', localtimestamp)
             AND o.order_timestamp < date_trunc('month', localtimestamp) + interval '1 month'
           GROUP BY o.courier_id
      ) x ON x.courier_id = cp.courier_id
     WHERE cp.year = v_year AND cp.month = v_month
       AND cp.amount <> round(coalesce(x.commission, 0) * cp.coefficient_used, 2);

    IF v_bad_amounts <> 0 THEN
        RAISE EXCEPTION 'courier_salary: % неверных amount', v_bad_amounts;
    END IF;

    SELECT coefficient INTO v_dismissed_after
      FROM courier WHERE courier_id = v_dismissed_id;
    IF v_dismissed_after <> v_dismissed_before THEN
        RAISE EXCEPTION 'courier_salary изменил коэффициент уволенного: % -> %',
            v_dismissed_before, v_dismissed_after;
    END IF;

    SELECT count(*) INTO v_zero_pay_couriers
      FROM courier_pay cp
     WHERE cp.year = v_year AND cp.month = v_month
       AND cp.amount = 0;

    SELECT md5(string_agg(courier_id::text || ':' || amount::text || ':' || coefficient_used::text,
                          ',' ORDER BY courier_id))
      INTO v_pay_hash_1
      FROM courier_pay
     WHERE year = v_year AND month = v_month;

    SELECT md5(string_agg(courier_id::text || ':' || coefficient::text, ',' ORDER BY courier_id))
      INTO v_coef_hash_1
      FROM courier;

    CALL courier_salary();

    SELECT md5(string_agg(courier_id::text || ':' || amount::text || ':' || coefficient_used::text,
                          ',' ORDER BY courier_id))
      INTO v_pay_hash_2
      FROM courier_pay
     WHERE year = v_year AND month = v_month;

    SELECT md5(string_agg(courier_id::text || ':' || coefficient::text, ',' ORDER BY courier_id))
      INTO v_coef_hash_2
      FROM courier;

    IF v_pay_hash_1 <> v_pay_hash_2 THEN
        RAISE EXCEPTION 'courier_salary не идемпотентна по суммам';
    END IF;

    IF v_coef_hash_1 <> v_coef_hash_2 THEN
        RAISE EXCEPTION 'courier_salary не идемпотентна по коэффициентам';
    END IF;

    RAISE NOTICE 'courier_salary OK: rows=%, zero_pay_couriers=%, dismissed coefficient=%',
        v_count_after, v_zero_pay_couriers, v_dismissed_after;
END;
$$;
