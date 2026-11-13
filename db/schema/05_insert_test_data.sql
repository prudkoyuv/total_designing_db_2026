-- ============================================================================
-- FoodExpress / FOOD-102, FOOD-103
-- Генератор и очистка тестовых данных.
--
-- Принципы генерации:
--   * строки — по паттернам samples/all_examples.sql §2: repeat(substring(...))
--     или md5, длина всегда от 1 до N (индекс считается как 1 + floor(...),
--     поэтому 0 невозможен);
--   * уникальные строки (login, phone, transaction_code) генерируются
--     случайно и при коллизии генерируются заново — без счётчиков;
--   * enum-значения берутся из enum_range() и распределяются так, чтобы
--     встречались все значения типа;
--   * ID-массивы (samples §7) используются, чтобы не делать SELECT в цикле;
--   * генератор не вызывает бизнес-процедуры/функции схемы (samples §10):
--     courier_pay, рейтинги и связи пишутся напрямую.
--
-- Распределение строк — BR-11.7:
--   value      : client, courier, product_category, restaurant;
--   value * 5  : address (value ресторанных + value*4 клиентских),
--                product, order, review, payment;
--   client_address — по 4 адреса на клиента;
--   courier_pay   — 6 месяцев на каждого курьера.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- ---------------------------------------------------------------------------
-- FOOD-103. Полная очистка тестовых данных.
-- TRUNCATE ... CASCADE сам разрешает порядок по FK. Типы, функции,
-- триггеры и представления не затрагиваются; последовательностей в схеме нет.
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
END;
$$;

COMMENT ON PROCEDURE erase_test_data() IS
    'FOOD-103: очищает все 12 таблиц. TRUNCATE ... CASCADE, без сброса последовательностей (их нет).';

-- ---------------------------------------------------------------------------
-- FOOD-102. insert_test_data(value)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE insert_test_data(value int)
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    n int := value;

    i int;
    j int;
    m int;
    k int;
    tmp int;

    v_uuid uuid;
    v_text text;
    v_login varchar(50);
    v_phone varchar(20);
    v_street varchar(100);
    v_house varchar(20);
    v_apartment varchar(20);
    v_open time;
    v_close time;
    v_hire date;
    v_dismissal date;
    v_status courier_status;

    v_price numeric(7,2);
    v_qty numeric[] := ARRAY[]::numeric[];
    v_line numeric(10,2);
    v_order_amount numeric(10,2);
    v_total numeric(10,2);
    v_idx int[];
    v_count int;

    v_order_ts timestamp;
    v_month_start timestamp;
    v_month_end timestamp;
    v_delivery_ts timestamp;
    v_review_ts timestamp;
    v_order_status order_status;

    v_entity_type review_entity_type;
    v_entity_id uuid;
    v_rating numeric(2,1);

    v_client_idx int;
    v_rest_idx int;
    v_courier_idx int;
    v_product_position int;

    v_coef numeric(3,2);
    v_cnt bigint;
    v_sum numeric(10,2);
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
    v_product_statuses    product_status[]    := enum_range(NULL::product_status);
    v_courier_statuses    courier_status[]    := enum_range(NULL::courier_status);
    v_order_statuses      order_status[]      := enum_range(NULL::order_status);
    v_payment_types       payment_type[]      := enum_range(NULL::payment_type);
    v_entity_types        review_entity_type[] := enum_range(NULL::review_entity_type);
BEGIN
    IF n IS NULL OR n <= 0 THEN
        RETURN;
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Адреса: n ресторанных + 4n клиентских (BR-11.7).
    --    Уникальность (street, house_number, apartment_office) —
    --    случайная генерация с повтором при коллизии, без счётчиков.
    -- -----------------------------------------------------------------
    FOR i IN 1..(n * 5) LOOP
        LOOP
            v_street := left(
                repeat(
                    substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                              1, 1 + floor(random() * 33)::int),
                    1 + floor(random() * 3)::int
                ), 100);
            v_house := (1 + floor(random() * 999))::int::text;
            v_apartment := CASE
                WHEN i <= n THEN NULL
                WHEN random() < 0.30 THEN NULL
                ELSE (1 + floor(random() * 300))::int::text
            END;

            EXIT WHEN NOT EXISTS (
                SELECT 1 FROM address a
                 WHERE a.street = v_street
                   AND a.house_number = v_house
                   AND a.apartment_office IS NOT DISTINCT FROM v_apartment
            );
        END LOOP;

        INSERT INTO address (street, house_number, apartment_office)
        VALUES (v_street, v_house, v_apartment)
        RETURNING address_id INTO v_uuid;

        IF i <= n THEN
            v_rest_addresses := array_append(v_rest_addresses, v_uuid);
        ELSE
            v_client_addresses := array_append(v_client_addresses, v_uuid);
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 2. Клиенты и client_address (по 4 адреса каждому клиенту).
    --    login и phone_number уникальны (BR-2.2) — повтор при коллизии.
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        LOOP
            v_login := substring(
                md5(random()::text || clock_timestamp()::text),
                1, 21 + floor(random() * 12)::int);
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client c WHERE c.login = v_login);
        END LOOP;

        LOOP
            v_phone := '+79' || lpad(
                (floor(random() * 1000000000))::bigint::text, 9, '0');
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client c WHERE c.phone_number = v_phone);
        END LOOP;

        INSERT INTO client (login, password, phone_number)
        VALUES (v_login, md5(random()::text), v_phone)
        RETURNING client_id INTO v_uuid;

        v_clients := array_append(v_clients, v_uuid);

        FOR j IN 1..4 LOOP
            INSERT INTO client_address (client_id, address_id)
            VALUES (v_uuid, v_client_addresses[(i - 1) * 4 + j]);
        END LOOP;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 3. Курьеры. Статусы берутся из enum_range(), первые четыре строки
    --    гарантированно покрывают все значения; значит, минимум один
    --    курьер активен (BR-6.6).
    --    hire_date — на несколько дней раньше начала шестимесячного окна
    --    заказов. Фиксированное "176 дней назад" не годится: в конце
    --    длинного месяца окно в 6 календарных месяцев шире 176 дней
    --    (например, 31 августа — это 184 дня от 1 марта).
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        IF i <= 4 THEN
            v_status := v_courier_statuses[i];
        ELSE
            v_status := v_courier_statuses[
                1 + floor(random() * cardinality(v_courier_statuses))::int];
        END IF;

        v_hire := (date_trunc('month', localtimestamp) - interval '5 months')::date
                  - (2 + floor(random() * 4)::int);

        IF v_status = 'уволен' THEN
            v_dismissal := v_hire + (30 + floor(random() * 90)::int);
            IF v_dismissal > current_date THEN
                v_dismissal := current_date;
            END IF;
        ELSE
            v_dismissal := NULL;
        END IF;

        INSERT INTO courier (
            last_name, first_name, middle_name, phone_number,
            status, hire_date, dismissal_date, coefficient
        )
        VALUES (
            left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                  1, 1 + floor(random() * 33)::int),
                       1 + floor(random() * 2)::int), 50),
            left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                  1, 1 + floor(random() * 33)::int),
                       1 + floor(random() * 2)::int), 50),
            left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                  1, 1 + floor(random() * 33)::int),
                       1 + floor(random() * 2)::int), 50),
            '+79' || lpad((floor(random() * 1000000000))::bigint::text, 9, '0'),
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
    -- 4. Категории блюд.
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        INSERT INTO product_category (product_category_name)
        VALUES (left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                      1, 1 + floor(random() * 33)::int),
                           1 + floor(random() * 3)::int), 100))
        RETURNING product_category_id INTO v_uuid;

        v_categories := array_append(v_categories, v_uuid);
    END LOOP;

    -- -----------------------------------------------------------------
    -- 5. Рестораны: по одному на ресторанный адрес.
    --    ИНН / ОГРН / расчётный счёт — случайные цифры нужной длины.
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        v_open := time '08:00' + make_interval(hours => floor(random() * 4)::int);
        v_close := time '18:00' + make_interval(hours => floor(random() * 5)::int);

        v_text := regexp_replace(
            md5(random()::text) || md5(random()::text) || md5(random()::text),
            '[^0-9]', '', 'g');

        INSERT INTO restaurant (
            restaurant_name, address_id, description,
            work_start, work_end, inn, ogrn, bank_account, rating, status
        )
        VALUES (
            left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                  1, 1 + floor(random() * 33)::int),
                       1 + floor(random() * 3)::int), 100),
            v_rest_addresses[i],
            left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                  1, 1 + floor(random() * 33)::int),
                       1 + floor(random() * 4)::int), 200),
            v_open,
            v_close,
            lpad(left(v_text, 10), 10, '0'),
            lpad(left(v_text, 13), 13, '0'),
            lpad(left(v_text, 20), 20, '0'),
            NULL,
            v_restaurant_statuses[
                1 + ((i - 1) % cardinality(v_restaurant_statuses))]
        )
        RETURNING restaurant_id INTO v_uuid;

        v_restaurants := array_append(v_restaurants, v_uuid);
    END LOOP;

    -- -----------------------------------------------------------------
    -- 6. Блюда: ровно по 5 на ресторан (BR-11.7).
    --    Плоский массив: позиции (r-1)*5+1 .. r*5.
    -- -----------------------------------------------------------------
    FOR i IN 1..n LOOP
        FOR j IN 1..5 LOOP
            v_price := round((150 + random() * 850)::numeric, 2);

            INSERT INTO product (
                product_name, product_category_id, price, restaurant_id,
                photo_url, rating, status, description
            )
            VALUES (
                left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                      1, 1 + floor(random() * 33)::int),
                           1 + floor(random() * 3)::int), 100),
                v_categories[1 + floor(random() * n)::int],
                v_price,
                v_restaurants[i],
                CASE
                    WHEN random() < 0.30 THEN NULL
                    ELSE 'https://cdn.foodexpress.ru/img/'
                         || md5(random()::text) || '.jpg'
                END,
                NULL,
                v_product_statuses[
                    1 + ((i - 1) * 5 + (j - 1)) % cardinality(v_product_statuses)],
                left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                      1, 1 + floor(random() * 33)::int),
                           1 + floor(random() * 4)::int), 200)
            )
            RETURNING product_id INTO v_uuid;

            v_products := array_append(v_products, v_uuid);
            v_prices := array_append(v_prices, v_price);
        END LOOP;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 7. Заказы, состав, оплаты и отзывы (по value * 5).
    -- -----------------------------------------------------------------
    FOR i IN 1..(n * 5) LOOP
        v_rest_idx := 1 + ((i - 1) % n);
        v_client_idx := 1 + floor(random() * n)::int;
        v_courier_idx := 1 + floor(random() * array_length(v_active_couriers, 1))::int;

        -- Даты: первые 6 заказов равномерно покрывают 6 календарных месяцев
        -- (текущий и пять предыдущих), остальные — случайно в этом же окне.
        -- Так все доставленные заказы попадают в периоды, за которые
        -- генератор создаёт выплаты courier_pay. Всё не позже "сейчас".
        IF i <= 6 THEN
            v_month_start := date_trunc('month', localtimestamp)
                             - make_interval(months => i - 1);
            v_month_end := least(v_month_start + interval '1 month', localtimestamp);
            v_order_ts := v_month_start + (v_month_end - v_month_start) * random();
        ELSE
            v_month_start := date_trunc('month', localtimestamp)
                             - interval '5 months';
            v_order_ts := v_month_start
                          + (localtimestamp - v_month_start) * random();
        END IF;

        -- Статусы: первые 6 заказов доставлены (чтобы отчёт покрывал
        -- 6 месяцев), следующие 5 покрывают все значения enum, остальные
        -- распределены с преобладанием 'доставлен'.
        IF i <= 6 THEN
            v_order_status := 'доставлен';
        ELSIF i <= 11 THEN
            v_order_status := v_order_statuses[i - 6];
        ELSE
            v_order_status := CASE
                WHEN random() < 0.70 THEN 'доставлен'
                WHEN random() < 0.40 THEN 'отменён'
                WHEN random() < 0.50 THEN 'создан'
                WHEN random() < 0.55 THEN 'готовится'
                ELSE 'в_доставке'
            END;
        END IF;

        IF v_order_status = 'доставлен' THEN
            v_delivery_ts := least(
                v_order_ts + make_interval(mins => 20 + floor(random() * 60)::int),
                localtimestamp);
            IF v_delivery_ts < v_order_ts THEN
                v_delivery_ts := v_order_ts;
            END IF;
        ELSE
            v_delivery_ts := NULL;
        END IF;

        -- 1..5 уникальных блюд только из ресторана заказа (BR-7.3, BR-7.16).
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

        FOR j IN 1..v_count LOOP
            v_qty[j] := CASE
                WHEN random() < 0.15 THEN 0.5
                ELSE (1 + floor(random() * 3))::numeric
            END;
        END LOOP;

        -- Сумма — точная сумма округлённых стоимостей позиций.
        v_order_amount := 0;
        FOR j IN 1..v_count LOOP
            v_order_amount := v_order_amount
                + round(v_qty[j] * v_prices[v_idx[j]], 2);
        END LOOP;

        -- Держим order_amount >= 1000, чтобы вопрос о минимальной сумме
        -- не возникал даже при чтении order_amount (BR-7.11, BR-1.8).
        IF v_order_amount < 1000 THEN
            v_qty[1] := v_qty[1]
                + ceil((1000 - v_order_amount) / v_prices[v_idx[1]]);

            v_order_amount := 0;
            FOR j IN 1..v_count LOOP
                v_order_amount := v_order_amount
                    + round(v_qty[j] * v_prices[v_idx[j]], 2);
            END LOOP;
        END IF;

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
            left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                  1, 1 + floor(random() * 33)::int),
                       1 + floor(random() * 4)::int), 200)
        )
        RETURNING order_id, total_amount INTO v_uuid, v_total;

        FOR j IN 1..v_count LOOP
            INSERT INTO order_structure (order_id, product_id, quantity)
            VALUES (v_uuid, v_products[v_idx[j]], v_qty[j]);
        END LOOP;

        -- -----------------------------------------------------------------
        -- Оплаты: ровно 5n строк на 5n заказов.
        -- Сценарий зависит от i mod 5 (в каждом блоке из 5 заказов —
        -- 2 + 1 + 1 + 1 + 0 = 5 попыток):
        --   1: ошибка, затем успех -> pay_status = 'оплачен';
        --   2: успех               -> 'оплачен';
        --   3: ошибка              -> 'ошибка';
        --   4: в_обработке         -> 'ожидает';
        --   0: попыток нет         -> 'ожидает'.
        -- У каждого заказа не больше одной успешной попытки (BR-8.1),
        -- сумма каждой попытки равна total_amount (BR-8.4).
        -- -----------------------------------------------------------------
        FOR j IN 1..CASE ((i - 1) % 5)
                            WHEN 1 THEN 2
                            WHEN 2 THEN 1
                            WHEN 3 THEN 1
                            WHEN 4 THEN 1
                            ELSE 0
                        END
        LOOP
            LOOP
                v_text := md5(random()::text || clock_timestamp()::text)
                          || substring(md5(random()::text), 1, 16);
                EXIT WHEN NOT EXISTS (
                    SELECT 1 FROM payment p WHERE p.transaction_code = v_text
                );
            END LOOP;

            INSERT INTO payment (
                order_id, payment_type, amount, transaction_code,
                payment_timestamp, status
            )
            VALUES (
                v_uuid,
                v_payment_types[1 + ((i + j - 2) % cardinality(v_payment_types))],
                v_total,
                v_text,
                least(v_order_ts
                      + make_interval(mins => 5 + j * 5 + floor(random() * 5)::int),
                      localtimestamp),
                CASE
                    WHEN (i - 1) % 5 = 1 AND j = 1 THEN 'ошибка'::payment_status
                    WHEN (i - 1) % 5 = 1 AND j = 2 THEN 'успех'::payment_status
                    WHEN (i - 1) % 5 = 2 THEN 'успех'::payment_status
                    WHEN (i - 1) % 5 = 3 THEN 'ошибка'::payment_status
                    ELSE 'в_обработке'::payment_status
                END
            );
        END LOOP;

        -- -----------------------------------------------------------------
        -- Ровно один отзыв на заказ (5n отзывов). Тип сущности циклически
        -- покрывает все три значения; блюдо выбирается из состава заказа,
        -- поэтому BR-9.2 «отзыв на то, что заказал» соблюдается, а
        -- UNIQUE (order_id, entity_type, entity_id) не нарушается.
        -- -----------------------------------------------------------------
        v_entity_type := v_entity_types[
            1 + ((i - 1) % cardinality(v_entity_types))];

        IF v_entity_type = 'блюдо' THEN
            v_entity_id := v_products[v_idx[1 + floor(random() * v_count)::int]];
        ELSIF v_entity_type = 'ресторан' THEN
            v_entity_id := v_restaurants[v_rest_idx];
        ELSE
            v_entity_id := v_uuid;  -- отзыв на заказ: entity_id = order_id
        END IF;

        v_rating := round((1 + random() * 4)::numeric, 1);

        v_review_ts := least(
            v_order_ts + make_interval(hours => 1 + floor(random() * 48)::int),
            localtimestamp);
        IF v_review_ts < v_order_ts THEN
            v_review_ts := v_order_ts;
        END IF;

        INSERT INTO review (
            client_id, review_timestamp, entity_id, entity_type,
            order_id, description, photo_url, rating
        )
        VALUES (
            v_clients[v_client_idx],
            v_review_ts,
            v_entity_id,
            v_entity_type,
            v_uuid,
            left(repeat(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                                  1, 1 + floor(random() * 33)::int),
                       1 + floor(random() * 4)::int), 200),
            CASE
                WHEN random() < 0.30 THEN NULL
                ELSE 'https://cdn.foodexpress.ru/reviews/'
                     || md5(random()::text) || '.jpg'
            END,
            v_rating
        );
    END LOOP;

    -- -----------------------------------------------------------------
    -- 8. courier_pay за последние 6 месяцев (BR-10.2, BR-10.7).
    --    coefficient_used — коэффициент, действовавший в этом месяце;
    --    новый коэффициент начинает действовать со следующего месяца.
    -- -----------------------------------------------------------------
    FOR i IN 1..array_length(v_couriers, 1) LOOP
        v_uuid := v_couriers[i];
        v_coef := 0.10;

        FOR m IN REVERSE 5..0 LOOP
            v_month_start := date_trunc('month', localtimestamp)
                             - make_interval(months => m);
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

COMMENT ON PROCEDURE insert_test_data(int) IS
    'FOOD-102: генерирует тестовые данные по BR-11.7. Строки — случайные по samples §2, все enum-значения присутствуют, оплаты разнообразны, суммы и даты согласованы, генератор не вызывает бизнес-процедуры.';
