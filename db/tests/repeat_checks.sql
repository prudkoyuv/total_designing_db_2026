-- ============================================================================
-- FoodExpress — проверки FOOD-102/103: очистка и повторная генерация.
-- ============================================================================

SET search_path TO prudko_food, exts;

DO $$
DECLARE
    v int;
BEGIN
    CALL erase_test_data();
    SELECT count(*) INTO v FROM client;
    IF v <> 0 THEN RAISE EXCEPTION 'erase: client=%', v; END IF;
    SELECT count(*) INTO v FROM "order";
    IF v <> 0 THEN RAISE EXCEPTION 'erase: order=%', v; END IF;
    SELECT count(*) INTO v FROM courier_pay;
    IF v <> 0 THEN RAISE EXCEPTION 'erase: courier_pay=%', v; END IF;

    -- повторная очистка не падает
    CALL erase_test_data();

    CALL insert_test_data(10);
    SELECT count(*) INTO v FROM client;
    IF v <> 10 THEN RAISE EXCEPTION 'insert 1: client=%', v; END IF;
    SELECT count(*) INTO v FROM "order";
    IF v <> 50 THEN RAISE EXCEPTION 'insert 1: order=%', v; END IF;
    SELECT count(*) INTO v FROM payment;
    IF v <> 50 THEN RAISE EXCEPTION 'insert 1: payment=%', v; END IF;
    SELECT count(*) INTO v FROM review;
    IF v <> 50 THEN RAISE EXCEPTION 'insert 1: review=%', v; END IF;

    -- повторный вызов без очистки: данные добавляются
    CALL insert_test_data(10);
    SELECT count(*) INTO v FROM client;
    IF v <> 20 THEN RAISE EXCEPTION 'insert 2: client=%', v; END IF;
    SELECT count(*) INTO v FROM "order";
    IF v <> 100 THEN RAISE EXCEPTION 'insert 2: order=%', v; END IF;
    SELECT count(*) INTO v FROM courier_pay;
    IF v <> 120 THEN RAISE EXCEPTION 'insert 2: courier_pay=%', v; END IF;

    RAISE NOTICE 'erase/insert repeat OK';
END;
$$;
