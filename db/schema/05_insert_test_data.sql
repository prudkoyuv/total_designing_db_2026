-- ============================================================================
-- FoodExpress / FOOD-102, FOOD-103
-- Генератор и очистка тестовых данных.
--
-- Распределение строк — BR-11.7: value строк для client, courier,
-- product_category, restaurant; value * 5 для address, product, order,
-- review, payment. Адреса: value под рестораны, value * 4 под клиентов.
-- courier_pay — 6 месяцев на каждого курьера, но не позже месяца
-- увольнения (BR-10.6, BR-10.7).
--
-- Связи хранятся в массивах ID, а не в temp-таблицах: генератор не создаёт
-- объектов в схеме и не делает ORDER BY random() LIMIT 1 в цикле
-- (samples/all_examples.sql, раздел 7). Строки собираются из букв алфавита;
-- счётчиков, префиксов и повторяющихся шаблонов в бизнес-значениях нет.
--
-- Отзывы создаются только по доставленным заказам (BR-9.2): по 3 отзыва на
-- разные блюда заказа + отзыв о ресторане + отзыв о заказе (BR-9.5).
--
-- BR-8.1 («ровно одна успешная попытка») и BR-8.7 (статусы «ошибка»,
-- «ожидает») несовместимы при фиксированном BR-11.7 количестве payment =
-- value * 5: на каждый заказ приходится ровно одна попытка. В БД
-- запрещено больше одной успешной попытки, а pay_status вычисляется по
-- фактическому статусу этой попытки. Противоречие зафиксировано в
-- db/constraints.md.
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
    v_alphabet constant text := 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя';

    n int := value;
    i int;
    j int;

    v_uuid uuid;
    v_client_ids uuid[] := ARRAY[]::uuid[];
    v_client_addresses uuid[] := ARRAY[]::uuid[];
    v_all_courier_ids uuid[] := ARRAY[]::uuid[];
    v_active_courier_ids uuid[] := ARRAY[]::uuid[];
    v_category_ids uuid[] := ARRAY[]::uuid[];
    v_restaurant_ids uuid[] := ARRAY[]::uuid[];
    v_product_ids uuid[] := ARRAY[]::uuid[];
    v_product_prices numeric[] := ARRAY[]::numeric[];
    v_item_ids uuid[] := ARRAY[]::uuid[];
    v_item_qty numeric[] := ARRAY[]::numeric[];

    v_client_ord int;
    v_restaurant_ord int;
    v_pidx int;
    v_start int;
    v_item_count int;

    v_status order_status;
    v_pay_status order_pay_status;
    v_payment_status payment_status;
    v_rest_status restaurant_status;
    v_prod_status product_status;
    v_courier_status courier_status;
    v_entity_type review_entity_type;
    v_entity_id uuid;

    v_login varchar(50);
    v_phone varchar(20);
    v_text text;

    v_open time;
    v_close time;
    v_hire date;
    v_dismissal date;

    v_price numeric;
    v_qty numeric;
    v_amount numeric;
    v_total numeric;
    v_order_ts timestamp;
    v_delivery_ts timestamp;
    v_review_ts timestamp;
    v_month_start timestamp;
    v_month_end timestamp;
    v_month_offset int;
    v_rating numeric;
BEGIN
    IF n IS NULL OR n <= 0 THEN
        RETURN;
    END IF;

    -- 1. Клиенты и по 4 адреса на клиента (4n адресов).
    FOR i IN 1..n LOOP
        LOOP
            v_login := left(md5(random()::text || clock_timestamp()::text), 20);
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client c WHERE c.login = v_login);
        END LOOP;

        LOOP
            v_phone := '+7' || left(translate(
                md5(random()::text || clock_timestamp()::text),
                'abcdef', '012345'), 10);
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client c WHERE c.phone_number = v_phone);
        END LOOP;

        INSERT INTO client (login, password, phone_number)
        VALUES (v_login, md5(random()::text), v_phone)
        RETURNING client_id INTO v_uuid;

        v_client_ids := array_append(v_client_ids, v_uuid);

        FOR j IN 1..4 LOOP
            v_text := (
                SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                  FROM generate_series(1, 8 + floor(random() * 12)::int)
            );

            INSERT INTO address (street, house_number, apartment_office)
            VALUES (
                v_text,
                (1 + floor(random() * 999))::int::text,
                CASE WHEN random() < 0.30 THEN NULL
                     ELSE (1 + floor(random() * 300))::int::text
                END
            )
            RETURNING address_id INTO v_uuid;

            INSERT INTO client_address (client_id, address_id)
            VALUES (v_client_ids[i], v_uuid);

            v_client_addresses := array_append(v_client_addresses, v_uuid);
        END LOOP;
    END LOOP;

    -- 2. Курьеры (n). Первые четыре статуса покрывают весь enum.
    -- Найм — перед началом шестимесячного окна, чтобы все выплаты и заказы
    -- были после найма. Уволенные получают дату увольнения (BR-6.3).
    FOR i IN 1..n LOOP
        v_courier_status := (enum_range(NULL::courier_status))[1 + ((i - 1) % 4)];
        v_hire := (date_trunc('month', localtimestamp) - interval '5 months')::date
                  - (1 + floor(random() * 12)::int);

        IF v_courier_status = 'уволен' THEN
            v_dismissal := v_hire + (30 + floor(random() * 120)::int);
            IF v_dismissal > current_date THEN
                v_dismissal := current_date;
            END IF;
        ELSE
            v_dismissal := NULL;
        END IF;

        LOOP
            v_phone := '+7' || left(translate(
                md5(random()::text || clock_timestamp()::text),
                'abcdef', '012345'), 10);
            EXIT WHEN NOT EXISTS (SELECT 1 FROM courier c WHERE c.phone_number = v_phone);
        END LOOP;

        INSERT INTO courier (
            last_name, first_name, middle_name, phone_number,
            status, hire_date, dismissal_date, coefficient
        )
        VALUES (
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 6 + floor(random() * 10)::int)),
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 6 + floor(random() * 10)::int)),
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 6 + floor(random() * 10)::int)),
            v_phone,
            v_courier_status,
            v_hire,
            v_dismissal,
            0.10
        )
        RETURNING courier_id INTO v_uuid;

        v_all_courier_ids := array_append(v_all_courier_ids, v_uuid);
        IF v_courier_status <> 'уволен' THEN
            v_active_courier_ids := array_append(v_active_courier_ids, v_uuid);
        END IF;
    END LOOP;

    -- 3. Категории блюд (n).
    FOR i IN 1..n LOOP
        INSERT INTO product_category (product_category_name)
        VALUES ((
            SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
              FROM generate_series(1, 6 + floor(random() * 12)::int)
        ))
        RETURNING product_category_id INTO v_uuid;

        v_category_ids := array_append(v_category_ids, v_uuid);
    END LOOP;

    -- 4. Рестораны и по одному адресу на ресторан (n адресов).
    FOR i IN 1..n LOOP
        v_open := time '08:00' + make_interval(hours => floor(random() * 4)::int);
        v_close := time '18:00' + make_interval(hours => floor(random() * 5)::int);
        v_rest_status := (enum_range(NULL::restaurant_status))[1 + ((i - 1) % 2)];

        INSERT INTO address (street, house_number, apartment_office)
        VALUES (
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 8 + floor(random() * 12)::int)),
            (1 + floor(random() * 999))::int::text,
            NULL
        )
        RETURNING address_id INTO v_uuid;

        INSERT INTO restaurant (
            restaurant_name, address_id, description, work_start, work_end,
            inn, ogrn, bank_account, rating, status
        )
        VALUES (
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 8 + floor(random() * 12)::int)),
            v_uuid,
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 10 + floor(random() * 20)::int)),
            v_open,
            v_close,
            left(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', '012345'), 12),
            left(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', '012345'), 15),
            left(translate(md5(random()::text || clock_timestamp()::text), 'abcdef', '012345'), 20),
            NULL,
            v_rest_status
        )
        RETURNING restaurant_id INTO v_uuid;

        v_restaurant_ids := array_append(v_restaurant_ids, v_uuid);
    END LOOP;

    -- 5. Блюда: по 5 на ресторан (5n). Цена — 350.00 … 2500.00 ₽.
    FOR i IN 1..(n * 5) LOOP
        v_restaurant_ord := 1 + (i - 1) / 5;
        v_price := round((350 + random() * 2150)::numeric, 2);
        v_prod_status := (enum_range(NULL::product_status))[1 + ((i - 1) % 3)];

        INSERT INTO product (
            product_name, product_category_id, price, restaurant_id,
            photo_url, rating, status, description
        )
        VALUES (
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 6 + floor(random() * 12)::int)),
            v_category_ids[1 + floor(random() * n)::int],
            v_price,
            v_restaurant_ids[v_restaurant_ord],
            CASE WHEN random() < 0.30 THEN NULL
                 ELSE 'https://cdn.foodexpress.ru/img/'
                      || md5(random()::text || clock_timestamp()::text) || '.jpg'
            END,
            NULL,
            v_prod_status,
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 10 + floor(random() * 20)::int))
        )
        RETURNING product_id INTO v_uuid;

        v_product_ids := array_append(v_product_ids, v_uuid);
        v_product_prices := array_append(v_product_prices, v_price);
    END LOOP;

    -- 6. Заказы, позиции, оплаты и отзывы (5n).
    FOR i IN 1..(n * 5) LOOP
        v_restaurant_ord := 1 + ((i - 1) % n);

        v_client_ord := 1 + floor(random() * n)::int;

        -- У каждого ресторана встречаются все пять статусов заказа.
        v_status := (enum_range(NULL::order_status))[
            1 + ((v_restaurant_ord - 1 + (i - 1) / n) % 5)
        ];

        -- Доставленные заказы распределены по последним 6 месяцам, чтобы
        -- how_much_money строил непрерывную серию.
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
            -- Доставка не должна переходить в следующий месяц: зарплата
            -- считается по order_timestamp, а how_much_money — по
            -- delivery_timestamp; иначе месяцы разойдутся.
            v_order_ts := greatest(
                v_month_start,
                least(v_order_ts, v_month_end - interval '2 hours')
            );
            v_delivery_ts := least(
                v_order_ts + make_interval(mins => 20 + floor(random() * 60)::int),
                localtimestamp
            );
        ELSE
            v_delivery_ts := NULL;
        END IF;

        -- Позиции: 1..5 разных блюд только из ресторана заказа (BR-7.3),
        -- количество 1..4 (BR-7.15). Сумма доводится до 909.10, чтобы
        -- total_amount с комиссией был не меньше 1000 ₽ (BR-7.11).
        v_item_count := 1 + floor(random() * 5)::int;
        IF v_status = 'доставлен' AND v_item_count < 3 THEN
            v_item_count := 3;  -- три разных блюда для отзывов (BR-9.5)
        END IF;
        v_start := 1 + floor(random() * 5)::int;
        v_item_ids := ARRAY[]::uuid[];
        v_item_qty := ARRAY[]::numeric[];
        v_amount := 0;

        FOR j IN 1..v_item_count LOOP
            v_pidx := (v_restaurant_ord - 1) * 5 + ((v_start - 1 + (j - 1)) % 5) + 1;
            v_qty := 1 + floor(random() * 4)::int;
            v_item_ids := array_append(v_item_ids, v_product_ids[v_pidx]);
            v_item_qty := array_append(v_item_qty, v_qty);
            v_amount := v_amount + v_product_prices[v_pidx] * v_qty;
        END LOOP;

        WHILE v_amount < 909.10 AND array_length(v_item_ids, 1) < 5 LOOP
            j := array_length(v_item_ids, 1) + 1;
            v_pidx := (v_restaurant_ord - 1) * 5 + ((v_start - 1 + (j - 1)) % 5) + 1;
            v_item_ids := array_append(v_item_ids, v_product_ids[v_pidx]);
            v_item_qty := array_append(v_item_qty, 1);
            v_amount := v_amount + v_product_prices[v_pidx];
        END LOOP;

        v_amount := round(v_amount, 2);
        v_total := round(v_amount + round(v_amount * 0.10, 2), 2);

        -- BR-8.7: pay_status вычисляется по статусу попытки оплаты.
        IF v_status = 'доставлен' OR (i - 1) % 3 = 0 THEN
            v_pay_status := 'оплачен';
            v_payment_status := 'успех';
        ELSIF (i - 1) % 3 = 1 THEN
            v_pay_status := 'ошибка';
            v_payment_status := 'ошибка';
        ELSE
            v_pay_status := 'ожидает';
            v_payment_status := 'в_обработке';
        END IF;

        INSERT INTO "order" (
            courier_id, client_id, address_id, restaurant_id,
            order_timestamp, delivery_timestamp, order_amount,
            status, pay_status, description
        )
        VALUES (
            v_active_courier_ids[
                1 + floor(random() * array_length(v_active_courier_ids, 1))::int
            ],
            v_client_ids[v_client_ord],
            v_client_addresses[(v_client_ord - 1) * 4 + 1 + floor(random() * 4)::int],
            v_restaurant_ids[v_restaurant_ord],
            v_order_ts,
            v_delivery_ts,
            v_amount,
            v_status,
            v_pay_status,
            (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
               FROM generate_series(1, 10 + floor(random() * 20)::int))
        )
        RETURNING order_id INTO v_uuid;

        FOR j IN 1..array_length(v_item_ids, 1) LOOP
            INSERT INTO order_structure (order_id, product_id, quantity)
            VALUES (v_uuid, v_item_ids[j], v_item_qty[j]);
        END LOOP;

        -- BR-8.4: сумма попытки равна total_amount. Одна попытка на заказ,
        -- иначе при BR-11.7 (5n платежей на 5n заказов) не остаётся места
        -- для второй попытки.
        INSERT INTO payment (
            order_id, payment_type, amount, transaction_code,
            payment_timestamp, status
        )
        VALUES (
            v_uuid,
            (enum_range(NULL::payment_type))[1 + ((i - 1) % 3)],
            v_total,
            exts.uuid_generate_v4()::text,
            least(v_order_ts + interval '5 minutes', localtimestamp),
            v_payment_status
        );

        -- BR-9.2: отзывы оставляют только по доставленным заказам.
        -- BR-9.5: 3 отзыва о разных блюдах заказа + отзыв о ресторане +
        -- отзыв о заказе = 5 отзывов на доставленный заказ (value * 5 всего).
        IF v_status = 'доставлен' THEN
            FOR j IN 1..5 LOOP
                v_entity_type := CASE
                    WHEN j <= 3 THEN 'блюдо'::review_entity_type
                    WHEN j = 4 THEN 'ресторан'::review_entity_type
                    ELSE 'заказ'::review_entity_type
                END;
                v_entity_id := CASE
                    WHEN j <= 3 THEN v_item_ids[j]
                    WHEN j = 4 THEN v_restaurant_ids[v_restaurant_ord]
                    ELSE v_uuid
                END;
                v_rating := round((1 + random() * 4)::numeric, 1);
                v_review_ts := least(
                    v_delivery_ts
                        + make_interval(hours => 1 + floor(random() * 48)::int),
                    localtimestamp
                );

                INSERT INTO review (
                    client_id, review_timestamp, entity_id, entity_type,
                    order_id, description, photo_url, rating
                )
                VALUES (
                    v_client_ids[v_client_ord],
                    v_review_ts,
                    v_entity_id,
                    v_entity_type,
                    v_uuid,
                    (SELECT string_agg(substr(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
                       FROM generate_series(1, 10 + floor(random() * 20)::int)),
                    CASE WHEN random() < 0.30 THEN NULL
                         ELSE 'https://cdn.foodexpress.ru/review/'
                              || md5(random()::text || clock_timestamp()::text) || '.jpg'
                    END,
                    v_rating
                );
            END LOOP;
        END IF;
    END LOOP;

    -- 7. courier_pay за последние 6 месяцев (BR-10.2, BR-10.7).
    -- Один проход: months × couriers × orders. Месяц заказа — по
    -- order_timestamp (как в шаблоне C.8). Коэффициент месяца — это
    -- коэффициент, назначенный в предыдущем месяце по числу доставок
    -- (для первого месяца — начальный 0.10). После генерации
    -- courier.coefficient — коэффициент на следующий месяц.
    -- Уволенным записи после месяца увольнения не создаются (BR-10.6).
    WITH months AS (
        SELECT generate_series(
            date_trunc('month', localtimestamp) - interval '5 months',
            date_trunc('month', localtimestamp),
            interval '1 month'
        ) AS m
    ),
    cells AS (
        SELECT c.courier_id,
               m.m,
               count(o.order_id) AS cnt,
               coalesce(sum(o.commission), 0) AS commission
          FROM courier c
          CROSS JOIN months m
          LEFT JOIN "order" o
                 ON o.courier_id = c.courier_id
                AND o.status = 'доставлен'
                AND o.order_timestamp >= m.m
                AND o.order_timestamp < m.m + interval '1 month'
         WHERE c.courier_id = ANY (v_all_courier_ids)
           AND (c.dismissal_date IS NULL
                OR m.m <= date_trunc('month', c.dismissal_date))
         GROUP BY c.courier_id, m.m
    ),
    ranked AS (
        SELECT cells.*,
               lag(cnt) OVER (PARTITION BY courier_id ORDER BY m) AS prev_cnt
          FROM cells
    ),
    paid AS (
        SELECT courier_id,
               m,
               commission,
               CASE
                   WHEN prev_cnt IS NULL OR prev_cnt <= 150 THEN 0.10
                   WHEN prev_cnt <= 250 THEN 0.20
                   WHEN prev_cnt <= 500 THEN 0.30
                   ELSE 0.50
               END::numeric(3,2) AS coef
          FROM ranked
    ),
    ins AS (
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        SELECT extract(year FROM m)::int,
               extract(month FROM m)::int,
               courier_id,
               round(commission * coef, 2),
               coef
          FROM paid
        RETURNING courier_id
    ),
    last_month AS (
        SELECT DISTINCT ON (courier_id) courier_id, cnt
          FROM cells
         ORDER BY courier_id, m DESC
    )
    UPDATE courier c
       SET coefficient = CASE
               WHEN lm.cnt <= 150 THEN 0.10
               WHEN lm.cnt <= 250 THEN 0.20
               WHEN lm.cnt <= 500 THEN 0.30
               ELSE 0.50
           END
      FROM last_month lm
     WHERE c.courier_id = lm.courier_id
       AND c.status <> 'уволен';  -- BR-10.6: уволенным коэффициент не назначается
END;
$$;
