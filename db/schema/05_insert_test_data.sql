-- ============================================================================
-- FoodExpress / FOOD-102, FOOD-103
-- Генератор и очистка тестовых данных.
-- Распределение строк — BR-11.7: value строк для client, courier,
-- product_category, restaurant и value * 5 для address, product, order,
-- review, payment; courier_pay — 6 месяцев на каждого курьера.
--
-- Связи между шагами хранятся во временных таблицах pg_temp: это не объекты
-- схемы, они не попадают в бэкап и не требуют грантов. Текстовые значения
-- генерируются через md5, без повторяющихся букв, префиксов и счётчиков.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- FOOD-103: TRUNCATE ... CASCADE сам разрешает порядок по FK.
CREATE OR REPLACE PROCEDURE erase_test_data()
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    TRUNCATE TABLE
        review,
        payment,
        order_structure,
        "order",
        courier_pay,
        client_address,
        product,
        product_category,
        restaurant,
        courier,
        client,
        address
    CASCADE;
END;
$$;

-- FOOD-102: insert_test_data(value).
CREATE OR REPLACE PROCEDURE insert_test_data(value int)
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    n int := value;

    i int;
    j int;
    m int;

    v_uuid uuid;
    v_client_id uuid;
    v_client_ord int;
    v_address_id uuid;
    v_restaurant_id uuid;
    v_restaurant_ord int;
    v_courier_id uuid;
    v_courier_status courier_status;
    v_category_id uuid;
    v_product_id uuid;
    v_order_id uuid;

    v_status order_status;
    v_pay_status order_pay_status;
    v_rest_status restaurant_status;
    v_prod_status product_status;
    v_entity_type review_entity_type;
    v_entity_id uuid;

    v_open time;
    v_close time;
    v_hire date;
    v_dismissal date;

    v_login varchar(50);
    v_phone varchar(20);
    v_text text;
    v_inn varchar(12);
    v_ogrn varchar(15);
    v_bank varchar(20);

    v_price numeric;
    v_qty numeric;
    v_item_count int;
    v_order_amount numeric;
    v_total numeric;
    v_order_ts timestamp;
    v_delivery_ts timestamp;
    v_review_ts timestamp;
    v_month_start timestamp;
    v_month_end timestamp;
    v_month_offset int;
    v_scenario int;
    v_rating numeric;

    v_coef numeric(3,2);
    v_cnt bigint;
    v_sum numeric;
    v_year int;
    v_month int;
BEGIN
    IF n IS NULL OR n <= 0 THEN
        RETURN;
    END IF;

    -- Временные таблицы создаются один раз на сессию; повторный вызов
    -- очищает их и заполняет заново.
    IF to_regclass('pg_temp.tmp_client') IS NULL THEN
        CREATE TEMP TABLE tmp_client (
            ord       int PRIMARY KEY,
            client_id uuid NOT NULL
        );
        CREATE TEMP TABLE tmp_client_address (
            client_id  uuid NOT NULL,
            address_id uuid NOT NULL,
            PRIMARY KEY (client_id, address_id)
        );
        CREATE TEMP TABLE tmp_courier (
            ord        int PRIMARY KEY,
            courier_id uuid NOT NULL,
            status     courier_status NOT NULL
        );
        CREATE TEMP TABLE tmp_category (
            ord         int PRIMARY KEY,
            category_id uuid NOT NULL
        );
        CREATE TEMP TABLE tmp_restaurant (
            ord           int PRIMARY KEY,
            restaurant_id uuid NOT NULL
        );
        CREATE TEMP TABLE tmp_product (
            ord            int PRIMARY KEY,
            product_id     uuid NOT NULL,
            restaurant_ord int NOT NULL,
            price          numeric(7,2) NOT NULL
        );
        CREATE TEMP TABLE tmp_item (
            order_id   uuid NOT NULL,
            product_id uuid NOT NULL,
            quantity   numeric(6,3) NOT NULL,
            PRIMARY KEY (order_id, product_id)
        );
    END IF;

    TRUNCATE TABLE
        tmp_client,
        tmp_client_address,
        tmp_courier,
        tmp_category,
        tmp_restaurant,
        tmp_product,
        tmp_item;

    -- 1. Клиенты и по 4 адреса на клиента (4n адресов).
    FOR i IN 1..n LOOP
        LOOP
            v_login := left(md5(random()::text || clock_timestamp()::text), 20);
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client c WHERE c.login = v_login);
        END LOOP;

        LOOP
            v_phone := substring('123456789', 1 + floor(random() * 9)::int, 1)
                       || left(translate(md5(random()::text || clock_timestamp()::text),
                                         'abcdef', '012345'), 10);
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client c WHERE c.phone_number = v_phone);
        END LOOP;

        INSERT INTO client (login, password, phone_number)
        VALUES (v_login, md5(random()::text), v_phone)
        RETURNING client_id INTO v_uuid;

        INSERT INTO pg_temp.tmp_client (ord, client_id) VALUES (i, v_uuid);

        FOR j IN 1..4 LOOP
            INSERT INTO address (street, house_number, apartment_office)
            VALUES (
                left(md5(random()::text || clock_timestamp()::text), 30),
                (1 + floor(random() * 999))::int::text,
                CASE WHEN random() < 0.30 THEN NULL
                     ELSE (1 + floor(random() * 300))::int::text
                END
            )
            RETURNING address_id INTO v_address_id;

            INSERT INTO client_address (client_id, address_id)
            VALUES (v_uuid, v_address_id);

            INSERT INTO pg_temp.tmp_client_address (client_id, address_id)
            VALUES (v_uuid, v_address_id);
        END LOOP;
    END LOOP;

    -- 2. Курьеры (n). Первые четыре статуса покрывают весь enum.
    FOR i IN 1..n LOOP
        v_courier_status := (enum_range(NULL::courier_status))[1 + ((i - 1) % 4)];
        v_hire := current_date - (30 + floor(random() * 150))::int;

        IF v_courier_status = 'уволен' THEN
            v_dismissal := v_hire + (30 + floor(random() * 90))::int;
            IF v_dismissal > current_date THEN
                v_dismissal := current_date;
            END IF;
            IF v_dismissal < v_hire THEN
                v_dismissal := v_hire;
            END IF;
        ELSE
            v_dismissal := NULL;
        END IF;

        v_phone := substring('123456789', 1 + floor(random() * 9)::int, 1)
                   || left(translate(md5(random()::text || clock_timestamp()::text),
                                     'abcdef', '012345'), 10);

        INSERT INTO courier (
            last_name, first_name, middle_name, phone_number,
            status, hire_date, dismissal_date, coefficient
        )
        VALUES (
            left(md5(random()::text || clock_timestamp()::text), 20),
            left(md5(random()::text || clock_timestamp()::text), 20),
            left(md5(random()::text || clock_timestamp()::text), 20),
            v_phone,
            v_courier_status,
            v_hire,
            v_dismissal,
            0.10
        )
        RETURNING courier_id INTO v_uuid;

        INSERT INTO pg_temp.tmp_courier (ord, courier_id, status)
        VALUES (i, v_uuid, v_courier_status);
    END LOOP;

    -- 3. Категории блюд (n).
    FOR i IN 1..n LOOP
        INSERT INTO product_category (product_category_name)
        VALUES (left(md5(random()::text || clock_timestamp()::text), 30))
        RETURNING product_category_id INTO v_uuid;

        INSERT INTO pg_temp.tmp_category (ord, category_id) VALUES (i, v_uuid);
    END LOOP;

    -- 4. Рестораны и по одному адресу на ресторан (n адресов).
    FOR i IN 1..n LOOP
        v_open := time '08:00' + make_interval(hours => floor(random() * 4)::int);
        v_close := time '18:00' + make_interval(hours => floor(random() * 5)::int);
        v_inn := left(translate(md5(random()::text || clock_timestamp()::text),
                                'abcdef', '012345'), 12);
        v_ogrn := left(translate(md5(random()::text || clock_timestamp()::text),
                                 'abcdef', '012345'), 15);
        v_bank := left(translate(md5(random()::text || clock_timestamp()::text),
                                 'abcdef', '012345'), 20);
        v_rest_status := (enum_range(NULL::restaurant_status))[1 + ((i - 1) % 2)];

        INSERT INTO address (street, house_number, apartment_office)
        VALUES (
            left(md5(random()::text || clock_timestamp()::text), 30),
            (1 + floor(random() * 999))::int::text,
            NULL
        )
        RETURNING address_id INTO v_address_id;

        INSERT INTO restaurant (
            restaurant_name, address_id, description, work_start, work_end,
            inn, ogrn, bank_account, rating, status
        )
        VALUES (
            left(md5(random()::text || clock_timestamp()::text), 30),
            v_address_id,
            left(md5(random()::text || clock_timestamp()::text), 50),
            v_open,
            v_close,
            v_inn,
            v_ogrn,
            v_bank,
            NULL,
            v_rest_status
        )
        RETURNING restaurant_id INTO v_uuid;

        INSERT INTO pg_temp.tmp_restaurant (ord, restaurant_id) VALUES (i, v_uuid);
    END LOOP;

    -- 5. Блюда: по 5 на ресторан (5n).
    FOR i IN 1..(n * 5) LOOP
        v_restaurant_ord := 1 + (i - 1) / 5;
        SELECT restaurant_id INTO v_restaurant_id
          FROM pg_temp.tmp_restaurant
         WHERE ord = v_restaurant_ord;

        SELECT category_id INTO v_category_id
          FROM pg_temp.tmp_category
         ORDER BY random()
         LIMIT 1;

        v_price := round((1000 + random() * 2000)::numeric, 2);
        v_prod_status := (enum_range(NULL::product_status))[1 + ((i - 1) % 3)];

        INSERT INTO product (
            product_name, product_category_id, price, restaurant_id,
            photo_url, rating, status, description
        )
        VALUES (
            left(md5(random()::text || clock_timestamp()::text), 30),
            v_category_id,
            v_price,
            v_restaurant_id,
            CASE WHEN random() < 0.30 THEN NULL
                 ELSE left(md5(random()::text || clock_timestamp()::text), 32) || '.jpg'
            END,
            NULL,
            v_prod_status,
            left(md5(random()::text || clock_timestamp()::text), 50)
        )
        RETURNING product_id INTO v_uuid;

        INSERT INTO pg_temp.tmp_product (ord, product_id, restaurant_ord, price)
        VALUES (i, v_uuid, v_restaurant_ord, v_price);
    END LOOP;

    -- 6. Заказы, позиции, оплаты и отзывы (5n).
    FOR i IN 1..(n * 5) LOOP
        v_restaurant_ord := 1 + ((i - 1) % n);
        SELECT restaurant_id INTO v_restaurant_id
          FROM pg_temp.tmp_restaurant
         WHERE ord = v_restaurant_ord;

        v_client_ord := 1 + floor(random() * n)::int;
        SELECT client_id INTO v_client_id
          FROM pg_temp.tmp_client
         WHERE ord = v_client_ord;

        SELECT address_id INTO v_address_id
          FROM pg_temp.tmp_client_address
         WHERE client_id = v_client_id
         ORDER BY random()
         LIMIT 1;

        SELECT courier_id INTO v_courier_id
          FROM pg_temp.tmp_courier
         WHERE status <> 'уволен'
         ORDER BY random()
         LIMIT 1;

        -- Статусы заказов распределены так, что у каждого ресторана
        -- встречаются все пять значений, включая 'доставлен'.
        v_status := (enum_range(NULL::order_status))[
            1 + ((v_restaurant_ord - 1 + (i - 1) / n) % 5)
        ];

        -- Доставленные заказы равномерно покрывают последние 6 месяцев,
        -- чтобы how_much_money строил непрерывную серию.
        IF v_status = 'доставлен' THEN
            v_month_offset := (v_restaurant_ord - 1) % 6;
        ELSE
            v_month_offset := (i - 1) % 6;
        END IF;

        v_month_start := date_trunc('month', localtimestamp)
                         - make_interval(months => v_month_offset);
        v_month_end := least(v_month_start + interval '1 month', localtimestamp);
        v_order_ts := v_month_start + (v_month_end - v_month_start) * random();

        IF v_status = 'доставлен' THEN
            v_delivery_ts := least(
                v_order_ts + make_interval(mins => 20 + floor(random() * 60)::int),
                localtimestamp
            );
            IF v_delivery_ts < v_order_ts THEN
                v_delivery_ts := v_order_ts;
            END IF;
        ELSE
            v_delivery_ts := NULL;
        END IF;

        -- Пять сценариев оплаты: 0, успех, ошибка, в обработке, ошибка+успех.
        v_scenario := (((i - 1) / n) + 2) % 5;
        v_pay_status := CASE v_scenario
            WHEN 1 THEN 'оплачен'::order_pay_status
            WHEN 2 THEN 'ошибка'::order_pay_status
            WHEN 3 THEN 'ожидает'::order_pay_status
            WHEN 4 THEN 'оплачен'::order_pay_status
            ELSE 'ожидает'::order_pay_status
        END;

        INSERT INTO "order" (
            courier_id, client_id, address_id, restaurant_id,
            order_timestamp, delivery_timestamp, order_amount,
            status, pay_status, description
        )
        VALUES (
            v_courier_id,
            v_client_id,
            v_address_id,
            v_restaurant_id,
            v_order_ts,
            v_delivery_ts,
            1000,
            v_status,
            v_pay_status,
            left(md5(random()::text || clock_timestamp()::text), 50)
        )
        RETURNING order_id INTO v_order_id;

        -- 1..5 уникальных блюд только из ресторана заказа (BR-7.3).
        v_item_count := 1 + floor(random() * 5)::int;
        FOR j IN 1..v_item_count LOOP
            SELECT p.product_id, p.price
              INTO v_product_id, v_price
              FROM pg_temp.tmp_product p
             WHERE p.restaurant_ord = v_restaurant_ord
               AND NOT EXISTS (
                   SELECT 1
                     FROM pg_temp.tmp_item it
                    WHERE it.order_id = v_order_id
                      AND it.product_id = p.product_id
               )
             ORDER BY random()
             LIMIT 1;

            v_qty := (1 + floor(random() * 4))::numeric;
            INSERT INTO pg_temp.tmp_item (order_id, product_id, quantity)
            VALUES (v_order_id, v_product_id, v_qty);

            INSERT INTO order_structure (order_id, product_id, quantity)
            VALUES (v_order_id, v_product_id, v_qty);
        END LOOP;

        SELECT sum(it.quantity * p.price)
          INTO v_order_amount
          FROM pg_temp.tmp_item it
          JOIN pg_temp.tmp_product p ON p.product_id = it.product_id
         WHERE it.order_id = v_order_id;

        UPDATE "order" SET order_amount = v_order_amount WHERE order_id = v_order_id;
        SELECT total_amount INTO v_total FROM "order" WHERE order_id = v_order_id;

        IF v_scenario IN (1, 2, 3) THEN
            LOOP
                v_text := md5(random()::text || clock_timestamp()::text);
                EXIT WHEN NOT EXISTS (SELECT 1 FROM payment p
                                       WHERE p.transaction_code = v_text);
            END LOOP;

            INSERT INTO payment (
                order_id, payment_type, amount, transaction_code,
                payment_timestamp, status
            )
            VALUES (
                v_order_id,
                (enum_range(NULL::payment_type))[1 + ((i - 1) % 3)],
                v_total,
                v_text,
                least(v_order_ts + interval '10 minutes', localtimestamp),
                CASE v_scenario
                    WHEN 1 THEN 'успех'::payment_status
                    WHEN 2 THEN 'ошибка'::payment_status
                    ELSE 'в_обработке'::payment_status
                END
            );
        ELSIF v_scenario = 4 THEN
            FOR j IN 1..2 LOOP
                LOOP
                    v_text := md5(random()::text || clock_timestamp()::text);
                    EXIT WHEN NOT EXISTS (SELECT 1 FROM payment p
                                           WHERE p.transaction_code = v_text);
                END LOOP;

                INSERT INTO payment (
                    order_id, payment_type, amount, transaction_code,
                    payment_timestamp, status
                )
                VALUES (
                    v_order_id,
                    (enum_range(NULL::payment_type))[1 + ((i + j - 2) % 3)],
                    v_total,
                    v_text,
                    least(v_order_ts + make_interval(mins => 5 + j * 5), localtimestamp),
                    CASE WHEN j = 1 THEN 'ошибка'::payment_status
                         ELSE 'успех'::payment_status
                    END
                );
            END LOOP;
        END IF;

        -- Один отзыв на заказ; тип сущности циклически покрывает все три.
        v_entity_type := (enum_range(NULL::review_entity_type))[1 + ((i - 1) % 3)];
        IF v_entity_type = 'блюдо' THEN
            SELECT product_id INTO v_entity_id
              FROM pg_temp.tmp_item
             WHERE order_id = v_order_id
             ORDER BY random()
             LIMIT 1;
        ELSIF v_entity_type = 'ресторан' THEN
            v_entity_id := v_restaurant_id;
        ELSE
            v_entity_id := v_order_id;
        END IF;

        v_rating := round((1 + random() * 4)::numeric, 1);
        v_review_ts := least(
            v_order_ts + make_interval(hours => 1 + floor(random() * 48)::int),
            localtimestamp
        );
        IF v_review_ts < v_order_ts THEN
            v_review_ts := v_order_ts;
        END IF;

        INSERT INTO review (
            client_id, review_timestamp, entity_id, entity_type,
            order_id, description, photo_url, rating
        )
        VALUES (
            v_client_id,
            v_review_ts,
            v_entity_id,
            v_entity_type,
            v_order_id,
            left(md5(random()::text || clock_timestamp()::text), 50),
            CASE WHEN random() < 0.30 THEN NULL
                 ELSE left(md5(random()::text || clock_timestamp()::text), 32) || '.jpg'
            END,
            v_rating
        );
    END LOOP;

    -- 7. courier_pay за последние 6 месяцев (BR-10.2, BR-10.7).
    FOR i IN 1..n LOOP
        SELECT courier_id, status INTO v_courier_id, v_courier_status
          FROM pg_temp.tmp_courier
         WHERE ord = i;

        v_coef := 0.10;

        FOR m IN REVERSE 5..0 LOOP
            v_month_start := date_trunc('month', localtimestamp)
                             - make_interval(months => m);
            v_year := extract(year FROM v_month_start)::int;
            v_month := extract(month FROM v_month_start)::int;

            SELECT count(*), coalesce(sum(o.commission), 0)
              INTO v_cnt, v_sum
              FROM "order" o
             WHERE o.courier_id = v_courier_id
               AND o.status = 'доставлен'
               AND o.delivery_timestamp >= v_month_start
               AND o.delivery_timestamp < v_month_start + interval '1 month';

            INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
            VALUES (v_year, v_month, v_courier_id, round(v_sum * v_coef, 2), v_coef);

            v_coef := CASE
                WHEN v_cnt <= 150 THEN 0.10
                WHEN v_cnt <= 250 THEN 0.20
                WHEN v_cnt <= 500 THEN 0.30
                ELSE 0.50
            END;
        END LOOP;

        -- BR-10.6: уволенному коэффициент на следующий месяц не назначается.
        IF v_courier_status <> 'уволен' THEN
            UPDATE courier SET coefficient = v_coef WHERE courier_id = v_courier_id;
        END IF;
    END LOOP;
END;
$$;
