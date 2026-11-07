-- ============================================================================
-- FoodExpress / FOOD-102, FOOD-103
-- Генератор и очистка тестовых данных.
--
-- Генератор не вызывает бизнес-процедуры/функции схемы (courier_salary,
-- add_product и т.п.). Он пишет данные напрямую; триггеры целостности и
-- rating_change срабатывают штатно.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- ---------------------------------------------------------------------------
-- FOOD-103. Полная очистка тестовых данных. Типы, функции, триггеры,
-- представления и последовательности не удаляются.
-- ---------------------------------------------------------------------------
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

    -- setval, а не ALTER SEQUENCE: inspector не является владельцем
    -- последовательностей, но имеет право UPDATE (FOOD-109).
    PERFORM setval('prudko_food.seq_address_num', 1, false);
    PERFORM setval('prudko_food.seq_client_num', 1, false);
    PERFORM setval('prudko_food.seq_courier_num', 1, false);
    PERFORM setval('prudko_food.seq_category_num', 1, false);
    PERFORM setval('prudko_food.seq_restaurant_num', 1, false);
    PERFORM setval('prudko_food.seq_product_num', 1, false);
    PERFORM setval('prudko_food.seq_phone_num', 1, false);
    PERFORM setval('prudko_food.seq_payment_num', 1, false);
END;
$$;

-- ---------------------------------------------------------------------------
-- FOOD-102. insert_test_data(value)
-- Распределение строк — BR-11.7:
--   value      : client, courier, product_category, restaurant
--   value * 5  : address, product, order, review, payment
--   value      : адреса ресторанов, value * 4 : адреса клиентов
--   связи      : client_address (по 4 адреса на клиента), order_structure
--   courier_pay: 6 месяцев на каждого курьера
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE insert_test_data(value int)
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    n int := value;

    i int;
    j int;
    k int;
    m int;
    tmp int;

    v_addr_num bigint;
    v_uuid uuid;
    v_order_id uuid;
    v_entity_id uuid;

    v_street text;
    v_apartment varchar(20);
    v_open time;
    v_close time;
    v_hire date;
    v_dismissal date;
    v_status courier_status;

    v_price numeric(10,2);
    v_order_amount numeric(12,2);
    v_total_amount numeric(12,2);
    v_qty numeric[];
    v_idx int[];
    v_count int;

    v_order_ts timestamp;
    v_month_start timestamp;
    v_month_end timestamp;
    v_delivery_ts timestamp;
    v_order_status order_status;

    v_roll double precision;
    v_entity_type review_entity_type;
    v_rating numeric(2,1);

    v_client_idx int;
    v_rest_idx int;
    v_courier_idx int;
    v_product_position int;

    v_coef numeric(3,2);
    v_cnt bigint;
    v_sum numeric(12,2);
    v_year int;
    v_month int;

    v_rest_addresses uuid[] := ARRAY[]::uuid[];
    v_client_addresses uuid[] := ARRAY[]::uuid[];
    v_clients uuid[] := ARRAY[]::uuid[];
    v_couriers uuid[] := ARRAY[]::uuid[];
    v_active_couriers uuid[] := ARRAY[]::uuid[];
    v_restaurants uuid[] := ARRAY[]::uuid[];
    v_categories uuid[] := ARRAY[]::uuid[];
    v_products uuid[] := ARRAY[]::uuid[];
    v_prices numeric[] := ARRAY[]::numeric[];

    v_restaurant_statuses restaurant_status[] := enum_range(NULL::restaurant_status);
    v_product_statuses product_status[] := enum_range(NULL::product_status);
    v_courier_statuses courier_status[] := enum_range(NULL::courier_status);
    v_order_statuses order_status[] := enum_range(NULL::order_status);
    v_payment_types payment_type[] := enum_range(NULL::payment_type);

    v_streets text[] := ARRAY[
        'ул. Ленина', 'ул. Мира', 'ул. Гагарина', 'ул. Пушкина',
        'ул. Садовая', 'ул. Советская', 'ул. Центральная',
        'ул. Школьная', 'ул. Лесная', 'ул. Набережная'
    ];
BEGIN
    IF n IS NULL OR n <= 0 THEN
        RETURN;
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Адреса: n ресторанных + 4n клиентских (BR-11.7)
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        v_addr_num := nextval('prudko_food.seq_address_num');
        v_street := v_streets[1 + ((v_addr_num - 1) % array_length(v_streets, 1))::int];

        INSERT INTO address (street, house_number, apartment_office)
        VALUES (v_street, v_addr_num::text, NULL)
        RETURNING address_id INTO v_uuid;

        v_rest_addresses := array_append(v_rest_addresses, v_uuid);
    END LOOP;

    FOR i IN 1..(n * 4) LOOP
        v_addr_num := nextval('prudko_food.seq_address_num');
        v_street := v_streets[1 + ((v_addr_num - 1) % array_length(v_streets, 1))::int];
        v_apartment := CASE
            WHEN random() < 0.25 THEN NULL
            ELSE 'кв. ' || (1 + floor(random() * 200)::int)::text
        END;

        INSERT INTO address (street, house_number, apartment_office)
        VALUES (v_street, v_addr_num::text, v_apartment)
        RETURNING address_id INTO v_uuid;

        v_client_addresses := array_append(v_client_addresses, v_uuid);
    END LOOP;

    -- -----------------------------------------------------------------
    -- 2. Клиенты и client_address (по 4 адреса каждому клиенту)
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        INSERT INTO client (login, password, phone_number)
        VALUES (
            'client_' || nextval('prudko_food.seq_client_num')::text,
            md5(random()::text),
            '+7' || lpad(nextval('prudko_food.seq_phone_num')::text, 10, '0')
        )
        RETURNING client_id INTO v_uuid;

        v_clients := array_append(v_clients, v_uuid);

        FOR j IN 1..4 LOOP
            INSERT INTO client_address (client_id, address_id)
            VALUES (v_uuid, v_client_addresses[(i - 1) * 4 + j]);
        END LOOP;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 3. Курьеры. i = 1 всегда активен (BR-6.6).
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        v_hire := current_date - (150 + (i % 29));

        IF i = 1 THEN
            v_status := 'свободен';
            v_dismissal := NULL;
        ELSIF random() < 0.25 THEN
            v_status := 'уволен';
            v_dismissal := v_hire + (10 + floor(random() * 60)::int);
            IF v_dismissal > current_date THEN
                v_dismissal := current_date;
            END IF;
        ELSE
            -- первые три значения enum_range: свободен, занят, на_доставке
            v_status := v_courier_statuses[1 + floor(random() * 3)::int];
            v_dismissal := NULL;
        END IF;

        INSERT INTO courier (fio, phone_number, status, hire_date, dismissal_date, coefficient)
        VALUES (
            'Курьер ' || nextval('prudko_food.seq_courier_num')::text,
            '+7' || lpad(nextval('prudko_food.seq_phone_num')::text, 10, '0'),
            v_status,
            v_hire,
            v_dismissal,
            0.10
        )
        RETURNING courier_id INTO v_uuid;

        v_couriers := array_append(v_couriers, v_uuid);
        IF v_status <> 'уволен' THEN
            v_active_couriers := array_append(v_active_couriers, v_uuid);
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 4. Категории блюд
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        INSERT INTO product_category (product_category_name)
        VALUES ('Категория ' || nextval('prudko_food.seq_category_num')::text)
        RETURNING product_category_id INTO v_uuid;

        v_categories := array_append(v_categories, v_uuid);
    END LOOP;

    -- -----------------------------------------------------------------
    -- 5. Рестораны. Первые n адресов — ресторанные (BR-11.7).
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        v_open := time '08:00' + make_interval(hours => floor(random() * 3)::int);
        v_close := time '21:00' + make_interval(hours => floor(random() * 3)::int);

        INSERT INTO restaurant (
            restaurant_name, address_id, description,
            work_start, work_end, company_details, rating, status
        )
        VALUES (
            'Ресторан ' || nextval('prudko_food.seq_restaurant_num')::text,
            v_rest_addresses[i],
            'Описание ресторана ' || i::text,
            v_open,
            v_close,
            'ИНН ' || substring(md5(random()::text), 1, 10)
                || ', ОГРН ' || substring(md5(random()::text), 1, 13),
            NULL,
            v_restaurant_statuses[1 + floor(random() * 2)::int]
        )
        RETURNING restaurant_id INTO v_uuid;

        v_restaurants := array_append(v_restaurants, v_uuid);
    END LOOP;

    -- -----------------------------------------------------------------
    -- 6. Блюда: ровно по 5 на ресторан (BR-11.7).
    --    Держим плоские массивы: позиции (r-1)*5+1 .. r*5.
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        FOR j IN 1..5 LOOP
            v_price := round((150 + random() * 650)::numeric, 2);

            INSERT INTO product (
                product_name, product_category_id, price, restaurant_id,
                photo_url, rating, status, description
            )
            VALUES (
                'Блюдо ' || nextval('prudko_food.seq_product_num')::text,
                v_categories[1 + floor(random() * n)::int],
                v_price,
                v_restaurants[i],
                CASE
                    WHEN random() < 0.70
                    THEN 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg'
                    ELSE NULL
                END,
                NULL,
                v_product_statuses[1 + floor(random() * 3)::int],
                'Описание блюда ' || i::text || '-' || j::text
            )
            RETURNING product_id INTO v_uuid;

            v_products := array_append(v_products, v_uuid);
            v_prices := array_append(v_prices, v_price);
        END LOOP;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 7. Заказы, состав, оплаты и отзывы (по value * 5)
    -- -----------------------------------------------------------------
    FOR i IN 1..(n * 5) LOOP
        v_rest_idx := 1 + ((i - 1) % n);
        v_client_idx := 1 + floor(random() * n)::int;
        v_courier_idx := 1 + floor(random() * array_length(v_active_couriers, 1))::int;

        -- равномерно по последним 6 месяцам; текущий месяц ограничен "сейчас"
        v_month_start := date_trunc('month', localtimestamp)
                         - make_interval(months => (i - 1) % 6);
        v_month_end := LEAST(v_month_start + interval '1 month', localtimestamp);
        v_order_ts := v_month_start + (v_month_end - v_month_start) * random();

        -- первые 6 заказов гарантируют доставку в каждом из 6 месяцев
        IF i <= 6 THEN
            v_order_status := 'доставлен';
        ELSIF random() < 0.80 THEN
            v_order_status := 'доставлен';
        ELSE
            v_order_status := CASE
                WHEN random() < 0.75 THEN v_order_statuses[1 + floor(random() * 3)::int]
                ELSE 'отменён'::order_status
            END;
        END IF;

        IF v_order_status = 'доставлен' THEN
            v_delivery_ts := LEAST(
                v_order_ts + make_interval(mins => 20 + floor(random() * 40)::int),
                localtimestamp
            );
            IF v_delivery_ts < v_order_ts THEN
                v_delivery_ts := v_order_ts;
            END IF;
        ELSE
            v_delivery_ts := NULL;
        END IF;

        -- 1..5 уникальных блюд только из ресторана заказа (BR-7.3, BR-7.16)
        v_product_position := (v_rest_idx - 1) * 5;
        v_idx := ARRAY[
            v_product_position + 1,
            v_product_position + 2,
            v_product_position + 3,
            v_product_position + 4,
            v_product_position + 5
        ];

        FOR k IN REVERSE 5..2 LOOP
            m := 1 + floor(random() * k)::int;
            tmp := v_idx[k];
            v_idx[k] := v_idx[m];
            v_idx[m] := tmp;
        END LOOP;

        v_count := 1 + floor(random() * 5)::int;
        v_qty := ARRAY[]::numeric[];
        v_order_amount := 0;

        FOR j IN 1..v_count LOOP
            v_qty[j] := CASE
                WHEN random() < 0.15 THEN 0.5
                ELSE (1 + floor(random() * 3))::numeric
            END;
            v_order_amount := v_order_amount + v_qty[j] * v_prices[v_idx[j]];
        END LOOP;

        -- BR-7.11: total_amount >= 1000, т.е. order_amount >= 909.09
        WHILE v_order_amount < 909.09 LOOP
            v_qty[1] := v_qty[1] + 1;
            v_order_amount := v_order_amount + v_prices[v_idx[1]];
        END LOOP;

        v_order_amount := round(v_order_amount, 2);

        INSERT INTO "order" (
            courier_id, client_id, address_id, restaurant_id,
            order_timestamp, delivery_timestamp, order_amount, status, description
        )
        VALUES (
            v_active_couriers[v_courier_idx],
            v_clients[v_client_idx],
            v_client_addresses[(v_client_idx - 1) * 4 + 1 + floor(random() * 4)::int],
            v_restaurants[v_rest_idx],
            v_order_ts,
            v_delivery_ts,
            v_order_amount,
            v_order_status,
            'Тестовый заказ ' || i::text
        )
        RETURNING order_id, total_amount INTO v_order_id, v_total_amount;

        FOR j IN 1..v_count LOOP
            INSERT INTO order_structure (order_id, product_id, quantity)
            VALUES (v_order_id, v_products[v_idx[j]], v_qty[j]);
        END LOOP;

        -- BR-8.1 и BR-8.4: ровно одна успешная попытка на заказ.
        INSERT INTO payment (
            order_id, payment_type, amount, transaction_code,
            payment_timestamp, status
        )
        VALUES (
            v_order_id,
            v_payment_types[1 + floor(random() * 3)::int],
            v_total_amount,
            'tx_' || nextval('prudko_food.seq_payment_num')::text
                || '_' || substring(md5(random()::text || v_order_id::text), 1, 16),
            LEAST(v_order_ts + make_interval(mins => floor(random() * 10)::int), localtimestamp),
            'успех'
        );

        -- Ровно один отзыв на заказ: до N+2 отзывов (BR-9.5), здесь 1.
        v_roll := random();
        IF v_roll < 0.45 THEN
            v_entity_type := 'блюдо';
            v_entity_id := v_products[v_idx[1 + floor(random() * v_count)::int]];
        ELSIF v_roll < 0.75 THEN
            v_entity_type := 'ресторан';
            v_entity_id := v_restaurants[v_rest_idx];
        ELSE
            v_entity_type := 'заказ';
            v_entity_id := v_order_id;
        END IF;

        v_rating := (1 + floor(random() * 5)::int)::numeric(2,1);

        INSERT INTO review (
            client_id, review_timestamp, entity_id, entity_type,
            order_id, description, photo_url, rating
        )
        VALUES (
            v_clients[v_client_idx],
            LEAST(
                v_order_ts + make_interval(hours => 1 + floor(random() * 48)::int),
                localtimestamp
            ),
            v_entity_id,
            v_entity_type,
            v_order_id,
            'Отзыв на заказ ' || i::text,
            CASE
                WHEN random() < 0.30
                THEN 'https://cdn.foodexpress.ru/reviews/' || md5(random()::text) || '.jpg'
                ELSE NULL
            END,
            v_rating
        );
    END LOOP;

    -- -----------------------------------------------------------------
    -- 8. courier_pay за 6 месяцев (BR-10.2, BR-10.7).
    --    coefficient_used каждого месяца — коэффициент, действовавший
    --    в этом месяце; после месяца считается коэффициент на следующий.
    -- -----------------------------------------------------------------
    FOR i IN 1..array_length(v_couriers, 1) LOOP
        v_uuid := v_couriers[i];
        v_coef := 0.10;

        FOR m IN REVERSE 5..0 LOOP
            v_month_start := date_trunc('month', localtimestamp) - make_interval(months => m);
            v_year := extract(year FROM v_month_start)::int;
            v_month := extract(month FROM v_month_start)::int;

            SELECT count(*), coalesce(sum(o.commission), 0)
              INTO v_cnt, v_sum
              FROM "order" o
             WHERE o.courier_id = v_uuid
               AND o.status = 'доставлен'
               AND o.order_timestamp >= v_month_start
               AND o.order_timestamp < v_month_start + interval '1 month';

            INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
            VALUES (v_year, v_month, v_uuid, round(v_sum * v_coef, 2), v_coef);

            v_coef := CASE
                WHEN v_cnt <= 150 THEN 0.10
                WHEN v_cnt <= 250 THEN 0.20
                WHEN v_cnt <= 500 THEN 0.30
                ELSE 0.50
            END;
        END LOOP;

        -- BR-10.6: уволенному коэффициент на следующий месяц не назначается.
        IF (SELECT c.status FROM courier c WHERE c.courier_id = v_uuid) <> 'уволен' THEN
            UPDATE courier SET coefficient = v_coef WHERE courier_id = v_uuid;
        END IF;
    END LOOP;
END;
$$;
