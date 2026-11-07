-- ============================================================================
-- FoodExpress — негативные проверки ограничений FOOD-101.
-- Каждая операция должна завершиться ошибкой; иначе скрипт падает.
-- Запускать под inspector после insert_test_data(10).
-- ============================================================================

SET search_path TO prudko_food, exts;

DO $$
DECLARE
    v_failed boolean;

    v_client uuid;
    v_address uuid;
    v_foreign_address uuid;
    v_restaurant uuid;
    v_other_restaurant uuid;
    v_category uuid;
    v_courier uuid;
    v_product uuid;
    v_other_product uuid;
    v_order uuid;
    v_test_order uuid;
    v_total numeric;
    v_login varchar(50);
    v_phone varchar(20);
    v_transaction varchar(100);
    v_timestamp timestamp := localtimestamp;
BEGIN
    SELECT c.client_id INTO v_client FROM client c ORDER BY c.client_id LIMIT 1;
    SELECT ca.address_id INTO v_address
      FROM client_address ca WHERE ca.client_id = v_client ORDER BY ca.address_id LIMIT 1;
    SELECT a.address_id INTO v_foreign_address
      FROM address a
     WHERE NOT EXISTS (
         SELECT 1 FROM client_address ca
          WHERE ca.client_id = v_client AND ca.address_id = a.address_id
     )
     ORDER BY a.address_id LIMIT 1;
    SELECT r.restaurant_id INTO v_restaurant FROM restaurant r ORDER BY r.restaurant_id LIMIT 1;
    SELECT r.restaurant_id INTO v_other_restaurant
      FROM restaurant r WHERE r.restaurant_id <> v_restaurant ORDER BY r.restaurant_id LIMIT 1;
    SELECT pc.product_category_id INTO v_category
      FROM product_category pc ORDER BY pc.product_category_id LIMIT 1;
    SELECT c.courier_id INTO v_courier
      FROM courier c WHERE c.status <> 'уволен' ORDER BY c.courier_id LIMIT 1;
    SELECT p.product_id INTO v_product
      FROM product p WHERE p.restaurant_id = v_restaurant ORDER BY p.product_id LIMIT 1;
    SELECT p.product_id INTO v_other_product
      FROM product p WHERE p.restaurant_id = v_other_restaurant ORDER BY p.product_id LIMIT 1;
    SELECT o.order_id INTO v_order
      FROM "order" o WHERE o.restaurant_id = v_restaurant ORDER BY o.order_id LIMIT 1;
    SELECT c.login, c.phone_number INTO v_login, v_phone
      FROM client c ORDER BY c.client_id LIMIT 1;
    SELECT p.transaction_code INTO v_transaction FROM payment p ORDER BY p.payment_id LIMIT 1;

    -- Тестовый заказ для проверок оплат и отзывов (удаляется в конце).
    INSERT INTO "order" (
        courier_id, client_id, address_id, restaurant_id,
        order_timestamp, delivery_timestamp, order_amount, status, description
    )
    VALUES (
        v_courier, v_client, v_address, v_restaurant,
        v_timestamp, v_timestamp, 1000, 'доставлен', 'constraint test'
    )
    RETURNING order_id, total_amount INTO v_test_order, v_total;

    -- 1. UNIQUE login
    v_failed := false;
    BEGIN
        INSERT INTO client (login, password, phone_number)
        VALUES (v_login, md5(random()::text), '+70000000001');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'UNIQUE client.login не сработал'; END IF;

    -- 2. UNIQUE phone
    v_failed := false;
    BEGIN
        INSERT INTO client (login, password, phone_number)
        VALUES ('constraint_login', md5(random()::text), v_phone);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'UNIQUE client.phone_number не сработал'; END IF;

    -- 3. CHECK MD5
    v_failed := false;
    BEGIN
        INSERT INTO client (login, password, phone_number)
        VALUES ('constraint_login', 'plain-password', '+70000000002');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK client.password MD5 не сработал'; END IF;

    -- 4. CHECK price >= 0
    v_failed := false;
    BEGIN
        INSERT INTO product (product_name, product_category_id, price, restaurant_id, description)
        VALUES ('Отрицательная цена', v_category, -1, v_restaurant, 'Описание');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK product.price не сработал'; END IF;

    -- 5. CHECK rating 0..5
    v_failed := false;
    BEGIN
        UPDATE product SET rating = 6 WHERE product_id = v_product;
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK product.rating не сработал'; END IF;

    -- 6. CHECK restaurant.work_end > work_start
    v_failed := false;
    BEGIN
        INSERT INTO restaurant (
            restaurant_name, address_id, description,
            work_start, work_end, company_details
        )
        VALUES (
            'Плохой график', v_foreign_address, 'Описание',
            time '10:00', time '09:00', 'ИНН 0000000000'
        );
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK restaurant.work_hours не сработал'; END IF;

    -- 7. UNIQUE restaurant.address_id
    v_failed := false;
    BEGIN
        INSERT INTO restaurant (
            restaurant_name, address_id, description,
            work_start, work_end, company_details
        )
        VALUES (
            'Дубликат адреса', (SELECT address_id FROM restaurant WHERE restaurant_id = v_restaurant),
            'Описание', time '09:00', time '22:00', 'ИНН 0000000000'
        );
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'UNIQUE restaurant.address_id не сработал'; END IF;

    -- 8. CHECK courier.coefficient
    v_failed := false;
    BEGIN
        INSERT INTO courier (fio, phone_number, status, hire_date, coefficient)
        VALUES ('Курьер', '+70000000003', 'свободен', current_date - 10, 0.60);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK courier.coefficient не сработал'; END IF;

    -- 9. CHECK уволенный обязан иметь dismissal_date
    v_failed := false;
    BEGIN
        INSERT INTO courier (fio, phone_number, status, hire_date, dismissal_date, coefficient)
        VALUES ('Курьер', '+70000000004', 'уволен', current_date - 10, NULL, 0.10);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK courier.dismissed_has_date не сработал'; END IF;

    -- 10. CHECK total_amount >= 1000
    v_failed := false;
    BEGIN
        INSERT INTO "order" (
            courier_id, client_id, address_id, restaurant_id,
            order_timestamp, order_amount, status
        )
        VALUES (v_courier, v_client, v_address, v_restaurant, v_timestamp, 100, 'создан');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK order.min_total не сработал'; END IF;

    -- 11. CHECK delivery_timestamp >= order_timestamp
    v_failed := false;
    BEGIN
        INSERT INTO "order" (
            courier_id, client_id, address_id, restaurant_id,
            order_timestamp, delivery_timestamp, order_amount, status
        )
        VALUES (
            v_courier, v_client, v_address, v_restaurant,
            v_timestamp, v_timestamp - interval '1 hour', 1000, 'доставлен'
        );
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK order.delivery_time не сработал'; END IF;

    -- 12. CHECK доставленный заказ имеет delivery_timestamp
    v_failed := false;
    BEGIN
        INSERT INTO "order" (
            courier_id, client_id, address_id, restaurant_id,
            order_timestamp, delivery_timestamp, order_amount, status
        )
        VALUES (v_courier, v_client, v_address, v_restaurant, v_timestamp, NULL, 1000, 'доставлен');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK order.delivered_has_time не сработал'; END IF;

    -- 13. BR-7.4 составной FK: чужой адрес
    v_failed := false;
    BEGIN
        INSERT INTO "order" (
            courier_id, client_id, address_id, restaurant_id,
            order_timestamp, order_amount, status
        )
        VALUES (v_courier, v_client, v_foreign_address, v_restaurant, v_timestamp, 1000, 'создан');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'FK order(client_id,address_id) не сработал'; END IF;

    -- 14. BR-7.3 блюдо из другого ресторана
    v_failed := false;
    BEGIN
        INSERT INTO order_structure (order_id, product_id, quantity)
        VALUES (v_test_order, v_other_product, 1);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'Триггер BR-7.3 не сработал'; END IF;

    -- 15. PK/BR-7.16 дубликат позиции
    v_failed := false;
    BEGIN
        INSERT INTO order_structure (order_id, product_id, quantity)
        SELECT os.order_id, os.product_id, os.quantity
          FROM order_structure os ORDER BY os.order_id, os.product_id LIMIT 1;
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'PK order_structure (BR-7.16) не сработал'; END IF;

    -- 16. BR-7.3 смена ресторана заказа с позициями
    v_failed := false;
    BEGIN
        UPDATE "order" SET restaurant_id = v_other_restaurant WHERE order_id = v_order;
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'Триггер смены ресторана заказа не сработал'; END IF;

    -- 17. UNIQUE client_address (BR-2.5)
    v_failed := false;
    BEGIN
        INSERT INTO client_address (client_id, address_id) VALUES (v_client, v_address);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'PK client_address (BR-2.5) не сработал'; END IF;

    -- 18. BR-8.4 сумма оплаты = total_amount
    v_failed := false;
    BEGIN
        INSERT INTO payment (order_id, payment_type, amount, transaction_code, status)
        VALUES (v_test_order, 'карта', v_total + 1, 'bad_amount', 'ошибка');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'Триггер BR-8.4 не сработал'; END IF;

    -- 19. UNIQUE transaction_code
    v_failed := false;
    BEGIN
        INSERT INTO payment (order_id, payment_type, amount, transaction_code, status)
        VALUES (v_test_order, 'карта', v_total, v_transaction, 'ошибка');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'UNIQUE payment.transaction_code не сработал'; END IF;

    -- 20. BR-8.1 ровно одна успешная попытка (частичный UNIQUE)
    INSERT INTO payment (order_id, payment_type, amount, transaction_code, status)
    VALUES (v_test_order, 'карта', v_total, 'success_1', 'успех');

    v_failed := false;
    BEGIN
        INSERT INTO payment (order_id, payment_type, amount, transaction_code, status)
        VALUES (v_test_order, 'наличные', v_total, 'success_2', 'успех');
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'Частичный UNIQUE одной успешной оплаты не сработал'; END IF;

    -- 21. BR-8.5 проверка статуса оплаты заказа
    IF (SELECT pay_status FROM "order" WHERE order_id = v_test_order) <> 'оплачен' THEN
        RAISE EXCEPTION 'BR-8.7: pay_status не обновился до оплачен';
    END IF;

    -- 22. UNIQUE review (order_id, entity_type, entity_id)
    INSERT INTO review (client_id, review_timestamp, entity_id, entity_type,
                        order_id, description, rating)
    VALUES (v_client, v_timestamp, v_test_order, 'заказ', v_test_order, 'Отзыв', 5);

    v_failed := false;
    BEGIN
        INSERT INTO review (client_id, review_timestamp, entity_id, entity_type,
                            order_id, description, rating)
        VALUES (v_client, v_timestamp, v_test_order, 'заказ', v_test_order, 'Дубликат', 4);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'UNIQUE review (BR-9.5) не сработал'; END IF;

    -- 23. BR-9.4 рейтинг отзыва 1..5
    v_failed := false;
    BEGIN
        INSERT INTO review (client_id, review_timestamp, entity_id, entity_type,
                            order_id, description, rating)
        VALUES (v_client, v_timestamp, v_product, 'блюдо', v_test_order, 'Плохой рейтинг', 6);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK review.rating не сработал'; END IF;

    -- 24. Валидность entity_id для отзыва
    v_failed := false;
    BEGIN
        INSERT INTO review (client_id, review_timestamp, entity_id, entity_type,
                            order_id, description, rating)
        VALUES (v_client, v_timestamp, exts.uuid_generate_v4(), 'блюдо', v_test_order, 'Нет блюда', 5);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'Проверка entity_id блюда не сработала'; END IF;

    -- 25. Для отзыва на заказ entity_id = order_id
    v_failed := false;
    BEGIN
        INSERT INTO review (client_id, review_timestamp, entity_id, entity_type,
                            order_id, description, rating)
        VALUES (v_client, v_timestamp, exts.uuid_generate_v4(), 'заказ', v_test_order, 'Чужой заказ', 5);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'Проверка entity_id заказа не сработала'; END IF;

    -- 26. CHECK courier_pay.amount >= 0
    v_failed := false;
    BEGIN
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        VALUES (1999, 1, v_courier, -1, 0.10);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK courier_pay.amount не сработал'; END IF;

    -- 27. CHECK courier_pay.month 1..12
    v_failed := false;
    BEGIN
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        VALUES (1999, 13, v_courier, 0, 0.10);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'CHECK courier_pay.month не сработал'; END IF;

    -- 28. FK address нельзя удалить, пока на него ссылаются
    v_failed := false;
    BEGIN
        DELETE FROM address
         WHERE address_id = (SELECT address_id FROM restaurant WHERE restaurant_id = v_restaurant);
    EXCEPTION WHEN OTHERS THEN v_failed := true;
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'FK address ON DELETE RESTRICT не сработал'; END IF;

    -- Уборка: каскадно удалит тестовые payment/review.
    DELETE FROM "order" WHERE order_id = v_test_order;

    RAISE NOTICE 'constraint checks OK';
END;
$$;
