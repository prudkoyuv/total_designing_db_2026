-- ============================================================================
-- FoodExpress — функциональные проверки FOOD-104 и FOOD-105.
-- Запускать после insert_test_data(10). Скрипт создаёт и удаляет тестовые
-- объекты; в конце данные возвращаются к исходному состоянию.
-- ============================================================================

SET search_path TO prudko_food, exts;

DO $$
DECLARE
    v_before int;
    v_after int;
    v_product uuid;
    v_restaurant uuid;
    v_restaurant_sel uuid;
    v_category uuid;
    v_category_sel uuid;
    v_orders uuid[];
    v_orders2 uuid[];
    v_client uuid;
    v_rating numeric;
    v_failed boolean;
    i int;
BEGIN
    -- ------------------------------------------------------------------
    -- FOOD-104: успешное добавление
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_before FROM product;

    SELECT restaurant_id INTO v_restaurant_sel
      FROM restaurant ORDER BY restaurant_id LIMIT 1;
    SELECT product_category_id INTO v_category_sel
      FROM product_category ORDER BY product_category_id LIMIT 1;

    CALL add_product(
        p_restaurant_id       => v_restaurant_sel,
        p_product_category_id => v_category_sel,
        p_name                => 'Тестовое блюдо',
        p_price               => 250,
        p_description         => 'Описание тестового блюда',
        p_status              => 'доступно',
        p_rating              => 4.5,
        p_photo_url           => 'https://cdn.foodexpress.ru/img/test.jpg'
    );

    SELECT count(*) INTO v_after FROM product;
    IF v_after <> v_before + 1 THEN
        RAISE EXCEPTION 'add_product: ожидалось % строк, получено %', v_before + 1, v_after;
    END IF;
    RAISE NOTICE 'add_product success: % -> %', v_before, v_after;

    SELECT product_id, restaurant_id, product_category_id
      INTO v_product, v_restaurant, v_category
      FROM product
     WHERE product_name = 'Тестовое блюдо'
     ORDER BY product_id
     LIMIT 1;

    -- ------------------------------------------------------------------
    -- FOOD-104: внятные ошибки
    -- ------------------------------------------------------------------
    v_failed := false;
    BEGIN
        CALL add_product(
            p_restaurant_id       => '00000000-0000-0000-0000-000000000000'::uuid,
            p_product_category_id => v_category,
            p_name                => 'Плохое блюдо',
            p_price               => 100,
            p_description         => 'Описание'
        );
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        RAISE NOTICE 'add_product несуществующий ресторан: %', SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'add_product не упал на несуществующем ресторане';
    END IF;

    v_failed := false;
    BEGIN
        CALL add_product(
            p_restaurant_id       => v_restaurant,
            p_product_category_id => '00000000-0000-0000-0000-000000000000'::uuid,
            p_name                => 'Плохое блюдо',
            p_price               => 100,
            p_description         => 'Описание'
        );
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        RAISE NOTICE 'add_product несуществующая категория: %', SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'add_product не упал на несуществующей категории';
    END IF;

    v_failed := false;
    BEGIN
        CALL add_product(
            p_restaurant_id       => v_restaurant,
            p_product_category_id => v_category,
            p_name                => 'Плохое блюдо',
            p_price               => -1,
            p_description         => 'Описание'
        );
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        RAISE NOTICE 'add_product отрицательная цена: %', SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'add_product не упал на отрицательной цене';
    END IF;

    -- ------------------------------------------------------------------
    -- FOOD-105: INSERT 3,4,5 -> 4.00
    -- ------------------------------------------------------------------
    SELECT array_agg(order_id) INTO v_orders
      FROM (
          SELECT o.order_id
            FROM "order" o
           WHERE o.restaurant_id = v_restaurant
           ORDER BY o.order_id
           LIMIT 3
      ) x;

    IF coalesce(array_length(v_orders, 1), 0) < 3 THEN
        RAISE EXCEPTION 'Недостаточно заказов для проверки рейтинга';
    END IF;

    FOR i IN 1..3 LOOP
        SELECT client_id INTO v_client FROM "order" WHERE order_id = v_orders[i];
        INSERT INTO review (
            review_id, client_id, review_timestamp, entity_id, entity_type,
            order_id, description, photo_url, rating
        )
        VALUES (
            exts.uuid_generate_v4(), v_client, localtimestamp, v_product, 'блюдо',
            v_orders[i], 'Проверка рейтинга', NULL, (2 + i)::numeric(2,1)
        );
    END LOOP;

    SELECT rating INTO v_rating FROM product WHERE product_id = v_product;
    IF v_rating <> 4.00 THEN
        RAISE EXCEPTION 'rating после 3,4,5 = %, ожидалось 4.00', v_rating;
    END IF;
    RAISE NOTICE 'rating insert 3,4,5 = %', v_rating;

    -- ------------------------------------------------------------------
    -- FOOD-105: DELETE одного -> 4.50
    -- ------------------------------------------------------------------
    DELETE FROM review
     WHERE entity_type = 'блюдо' AND entity_id = v_product AND rating = 3;

    SELECT rating INTO v_rating FROM product WHERE product_id = v_product;
    IF v_rating <> 4.50 THEN
        RAISE EXCEPTION 'rating после удаления 3 = %, ожидалось 4.50', v_rating;
    END IF;
    RAISE NOTICE 'rating after delete one = %', v_rating;

    -- ------------------------------------------------------------------
    -- FOOD-105: DELETE всех -> NULL
    -- ------------------------------------------------------------------
    DELETE FROM review WHERE entity_type = 'блюдо' AND entity_id = v_product;

    SELECT rating INTO v_rating FROM product WHERE product_id = v_product;
    IF v_rating IS NOT NULL THEN
        RAISE EXCEPTION 'rating после удаления всех = %, ожидалось NULL', v_rating;
    END IF;
    RAISE NOTICE 'rating after delete all = NULL';

    -- ------------------------------------------------------------------
    -- FOOD-105: UPDATE rating и UPDATE entity_type/entity_id
    -- Берём заказы без отзыва на ресторан, чтобы смена entity_type
    -- не нарушила UNIQUE (order_id, entity_type, entity_id) из BR-9.5.
    -- ------------------------------------------------------------------
    SELECT array_agg(order_id) INTO v_orders2
      FROM (
          SELECT o.order_id
            FROM "order" o
           WHERE o.restaurant_id = v_restaurant
             AND NOT EXISTS (
                 SELECT 1 FROM review r
                  WHERE r.order_id = o.order_id AND r.entity_type = 'ресторан'
             )
           ORDER BY o.order_id
           LIMIT 2
      ) x;

    IF coalesce(array_length(v_orders2, 1), 0) < 2 THEN
        RAISE EXCEPTION 'Недостаточно заказов без отзыва на ресторан';
    END IF;

    INSERT INTO review (
        review_id, client_id, review_timestamp, entity_id, entity_type,
        order_id, description, photo_url, rating
    )
    SELECT exts.uuid_generate_v4(), o.client_id, localtimestamp, v_product, 'блюдо',
           o.order_id, 'Проверка UPDATE', NULL, 2
      FROM "order" o
     WHERE o.order_id = v_orders2[1];

    INSERT INTO review (
        review_id, client_id, review_timestamp, entity_id, entity_type,
        order_id, description, photo_url, rating
    )
    SELECT exts.uuid_generate_v4(), o.client_id, localtimestamp, v_product, 'блюдо',
           o.order_id, 'Проверка UPDATE', NULL, 4
      FROM "order" o
     WHERE o.order_id = v_orders2[2];

    SELECT rating INTO v_rating FROM product WHERE product_id = v_product;
    IF v_rating <> 3.00 THEN
        RAISE EXCEPTION 'rating после 2,4 = %, ожидалось 3.00', v_rating;
    END IF;
    RAISE NOTICE 'rating insert 2,4 = %', v_rating;

    UPDATE review
       SET rating = 5
     WHERE entity_type = 'блюдо' AND entity_id = v_product
       AND order_id = v_orders2[1];

    SELECT rating INTO v_rating FROM product WHERE product_id = v_product;
    IF v_rating <> 4.50 THEN
        RAISE EXCEPTION 'rating после UPDATE 2->5 = %, ожидалось 4.50', v_rating;
    END IF;
    RAISE NOTICE 'rating after UPDATE 2->5 = %', v_rating;

    UPDATE review
       SET entity_type = 'ресторан', entity_id = v_restaurant
     WHERE entity_type = 'блюдо' AND entity_id = v_product
       AND order_id = v_orders2[1];

    SELECT rating INTO v_rating FROM product WHERE product_id = v_product;
    IF v_rating <> 4.00 THEN
        RAISE EXCEPTION 'rating после смены entity_type = %, ожидалось 4.00', v_rating;
    END IF;
    RAISE NOTICE 'rating after UPDATE entity_type = %', v_rating;

    DELETE FROM review
     WHERE order_id IN (v_orders2[1], v_orders2[2])
       AND entity_type IN ('блюдо', 'ресторан')
       AND entity_id IN (v_product, v_restaurant);

    SELECT rating INTO v_rating FROM product WHERE product_id = v_product;
    IF v_rating IS NOT NULL THEN
        RAISE EXCEPTION 'rating после очистки = %, ожидалось NULL', v_rating;
    END IF;

    -- Удаляем тестовое блюдо.
    DELETE FROM product WHERE product_id = v_product;
    RAISE NOTICE 'functional checks OK';
END;
$$;
