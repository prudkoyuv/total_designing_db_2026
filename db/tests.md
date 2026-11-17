# Протокол для самопроверки

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | `PostgreSQL 18.4 (Debian 18.4-1.pgdg12+1) on x86_64-pc-linux-gnu` |
| Дата проверки | 2026-11-16 |
| Схема | `prudko_food` |
| Роль-аудитор | `inspector` |

Все проверки — под `inspector`, если не указано иное.

---

## A. Подготовка

### A.1. Восстановление бэкапа

```bash
pg_restore --exit-on-error -d foodexpress_restore foodexpress_prudko.backup
psql -d foodexpress_restore -f grants.sql
```

Ожидается: без ошибок; архив содержит только схему.
Факт: восстановлено в пустую БД с заранее созданными `exts` и `uuid-ossp`
(BR-13.3); строк 0. TOC: 1 `SCHEMA`, 8 `TYPE`, 6 `FUNCTION`/`PROCEDURE`,
12 `TABLE`, 1 `VIEW`, 12 PK, 5 UNIQUE, 1 пользовательский `INDEX`,
1 `TRIGGER`, 16 FK; записей `TABLE DATA`, `EXTENSION`, `SEQUENCE` нет.
Владелец — `pg_database_owner`. Повторный `grants.sql` пароль не меняет.
Вердикт: OK.

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO prudko_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.
Факт: `inspector`. Проверки идут через `SET ROLE`, поэтому пароль уже
существующей роли не важен: `grants.sql` его не меняет (см. `constraints.md`).
Вердикт: OK.

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '%_food';
```

Ожидается: `prudko_food`. Факт: `prudko_food`. Вердикт: OK.

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace FROM pg_extension WHERE extname = 'uuid-ossp';
```

Ожидается: `uuid-ossp`, `exts`. Факт: `uuid-ossp`, `exts`. Вердикт: OK.

### B.3. Все 12 таблиц

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'prudko_food' ORDER BY 1;
```

Ожидается: 12 таблиц ERD. Факт: 12 (`address`, `client`, `client_address`,
`courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`,
`product_category`, `restaurant`, `review`). Вердикт: OK.

### B.4. Все ID — `uuid`

```sql
SELECT table_name, column_name, data_type FROM information_schema.columns
WHERE table_schema = 'prudko_food' AND column_name LIKE '%_id' AND data_type <> 'uuid';
```

Ожидается: пусто. Факт: пусто. Вердикт: OK.

### B.5. Enum-типы

```sql
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder)
FROM pg_type t JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'prudko_food' GROUP BY t.typname ORDER BY 1;
```

Ожидается: 8 типов из `constraints.md`. Факт: 8. Вердикт: OK.

### B.6. FK-ограничения

```sql
SELECT count(*) FROM pg_constraint
WHERE contype = 'f' AND connamespace = 'prudko_food'::regnamespace;
```

Ожидается: все FK из ERD. Факт: 16. Вердикт: OK.

### B.7. Пароль — MD5

```sql
SELECT length(password), password ~ '^[0-9a-f]{32}$' FROM client LIMIT 5;
```

Ожидается: `32`, `true`. Факт: `32`, `true`. Вердикт: OK.

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок. Факт: без ошибок. Вердикт: OK.

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок. Факт: без ошибок. Вердикт: OK.

### C.3. Распределение строк (BR-11.7)

```sql
SELECT 'client', count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment;
```

Ожидается: 10, 10, 10, 10, 50, 50, 50, 50, 50.
Факт: 10, 10, 10, 10, 50, 50, 50, 50, 50. Вердикт: OK.

### C.4. Адреса ресторанов и клиентов (BR-11.7)

```sql
SELECT count(*) FROM restaurant
UNION ALL SELECT count(*) FROM address;
```

Ожидается: 10 адресов ресторанов, 50 всего → 40 клиентских.
Факт: 10 и 50. Вердикт: OK.

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = ''
UNION ALL SELECT count(*) FROM address WHERE street = '' OR house_number = ''
UNION ALL SELECT count(*) FROM restaurant WHERE restaurant_name = '' OR description = ''
UNION ALL SELECT count(*) FROM courier WHERE last_name = '' OR first_name = '' OR middle_name = ''
UNION ALL SELECT count(*) FROM product WHERE product_name = '' OR description = ''
UNION ALL SELECT count(*) FROM "order" WHERE description = ''
UNION ALL SELECT count(*) FROM review WHERE description = '';
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) FROM "order"
WHERE client_id IS NULL OR restaurant_id IS NULL OR courier_id IS NULL
   OR address_id IS NULL OR order_amount IS NULL OR total_amount IS NULL;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status <> 'уволен';
```

Ожидается: `>= 1`. Факт: 8. Вердикт: OK.

### C.8. `courier_pay` по заказам месяца (BR-10.2)

```sql
SELECT count(*) FROM courier_pay cp
WHERE cp.amount <> round(coalesce((
    SELECT sum(o.commission) FROM "order" o
    WHERE o.courier_id = cp.courier_id AND o.status = 'доставлен'
      AND extract(year FROM o.order_timestamp) = cp.year
      AND extract(month FROM o.order_timestamp) = cp.month
), 0) * cp.coefficient_used, 2);
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### C.9. Повторный вызов

```sql
BEGIN;
CALL insert_test_data(10);
SELECT (SELECT count(*) FROM client) AS clients,
       (SELECT count(*) FROM "order") AS orders,
       (SELECT count(*) FROM payment) AS payments,
       (SELECT count(*) FROM review) AS reviews;
ROLLBACK;
```

Ожидается: без ошибок; в транзакции данные добавляются, после `ROLLBACK`
состояние прежнее.
Факт: 20 клиентов, 100 заказов, 100 платежей, 100 отзывов; после `ROLLBACK` —
10/50/50/50.
Вердикт: OK.

### C.10. `photo_url` — настоящий URL (BR-5.6, BR-9.3)

```sql
SELECT count(*) FROM product
WHERE photo_url IS NOT NULL AND photo_url !~ '^https://'
UNION ALL
SELECT count(*) FROM review
WHERE photo_url IS NOT NULL AND photo_url !~ '^https://';
```

Ожидается: 0, 0. Факт: 0, 0. Вердикт: OK.

---

## D. Проверки бизнес-правил на сгенерированных данных

### D.1. Нет orphans

```sql
SELECT count(*) FROM order_structure os LEFT JOIN "order" o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT count(*) FROM order_structure os LEFT JOIN product p USING (product_id) WHERE p.product_id IS NULL
UNION ALL SELECT count(*) FROM payment pm LEFT JOIN "order" o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT count(*) FROM review r LEFT JOIN "order" o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT count(*) FROM courier_pay cp LEFT JOIN courier c USING (courier_id) WHERE c.courier_id IS NULL;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.2. Минимальная сумма заказа (BR-1.8)

```sql
SELECT count(*) FROM "order" WHERE total_amount < 1000;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM "order" WHERE commission <> round(order_amount * 0.10, 2);
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.4. `total_amount = order_amount + commission`

```sql
SELECT count(*) FROM "order" WHERE total_amount <> order_amount + commission;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.5. Доставка не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
WHERE NOT EXISTS (SELECT 1 FROM client_address ca
                  WHERE ca.client_id = o.client_id AND ca.address_id = o.address_id);
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.7. Блюда из одного ресторана (BR-7.3)

```sql
SELECT count(*) FROM order_structure os
JOIN "order" o USING (order_id) JOIN product p USING (product_id)
WHERE p.restaurant_id <> o.restaurant_id;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.8. Успешные оплаты (BR-8.1, BR-8.7)

```sql
SELECT order_id, count(*) FROM payment WHERE status = 'успех'
GROUP BY order_id HAVING count(*) != 1;
```

Ожидается: пусто — успешных попыток не больше одной на заказ.
Факт: пусто. У части заказов ноль успешных попыток: единственная попытка
завершилась `'ошибка'` или `'в_обработке'` (BR-8.7). Это противоречие BR-8.1
и BR-8.7 при фиксированном BR-11.7 (`payment = value * 5`) разобрано в
`constraints.md`. Вердикт: OK.

### D.9. Сумма оплаты = `total_amount` (BR-8.4)

```sql
SELECT count(*) FROM payment p JOIN "order" o USING (order_id)
WHERE p.amount <> o.total_amount;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.10. Нет дубликатов `client_address` (BR-2.5)

```sql
SELECT count(*) FROM (SELECT 1 FROM client_address
GROUP BY client_id, address_id HAVING count(*) > 1) x;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.11. Нет дубликатов `order_structure` (BR-7.16)

```sql
SELECT count(*) FROM (SELECT 1 FROM order_structure
GROUP BY order_id, product_id HAVING count(*) > 1) x;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM courier WHERE dismissal_date < hire_date;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### D.14. Рейтинг соответствует отзывам (BR-9.6)

```sql
SELECT count(*) FROM product p
WHERE p.rating IS DISTINCT FROM (SELECT round(avg(r.rating), 2) FROM review r
    WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id)
UNION ALL
SELECT count(*) FROM restaurant s
WHERE s.rating IS DISTINCT FROM (SELECT round(avg(r.rating), 2) FROM review r
    WHERE r.entity_type = 'ресторан' AND r.entity_id = s.restaurant_id);
```

Ожидается: 0. Факт: 0. Вердикт: OK.

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

```sql
SELECT count(*) FROM product;  -- before

-- CALL не принимает подзапросы в аргументах, поэтому значения
-- выбираются в DO-блоке.
DO $$
DECLARE
    v_restaurant uuid;
    v_category   uuid;
BEGIN
    SELECT restaurant_id INTO v_restaurant FROM restaurant LIMIT 1;
    SELECT product_category_id INTO v_category FROM product_category LIMIT 1;
    CALL add_product(v_restaurant, v_category, 'Тестовое блюдо', 250, 'Описание');
END $$;

SELECT count(*) FROM product;  -- after
```

Ожидается: `after = before + 1`.
Факт: 50 → 51. Вердикт: OK.

### E.2. `add_product` — несуществующий ресторан

```sql
DO $$
DECLARE
    v_category uuid;
BEGIN
    SELECT product_category_id INTO v_category FROM product_category LIMIT 1;
    CALL add_product('00000000-0000-0000-0000-000000000000', v_category,
                     'Плохое блюдо', 100, 'Описание');
END $$;
```

Ожидается: ошибка FK.
Факт: `fk_product_restaurant`, `Key (restaurant_id)=... is not present`.
Вердикт: OK.

### E.3. `rating_change` — вставка отзывов

```sql
-- Выбрать заказ, блюдо и клиента
SELECT p.product_id, p.rating
FROM product p
WHERE p.product_id = (SELECT entity_id FROM review
                      WHERE entity_type = 'блюдо'
                      ORDER BY entity_id LIMIT 1);

-- Вставить отзыв на это блюдо
INSERT INTO review (review_id, client_id, review_timestamp, entity_id, entity_type, order_id, description, rating)
VALUES (
    exts.uuid_generate_v4(),
    (SELECT client_id FROM client LIMIT 1),
    localtimestamp,
    (SELECT entity_id FROM review WHERE entity_type = 'блюдо' ORDER BY entity_id LIMIT 1),
    'блюдо',
    (SELECT order_id FROM "order" LIMIT 1),
    'Тестовый отзыв',
    5
)
RETURNING review_id;

SELECT rating FROM product
WHERE product_id = (SELECT entity_id FROM review WHERE entity_type = 'блюдо' ORDER BY entity_id LIMIT 1);
```

Ожидается: `rating` пересчитан.
Факт: `3.40 → 4.20`. Вердикт: OK.

### E.4. `rating_change` — удаление отзывов

```sql
-- Удалить отзыв из E.3
DELETE FROM review
WHERE review_id = (SELECT review_id FROM review WHERE description = 'Тестовый отзыв');

SELECT rating FROM product
WHERE product_id = (SELECT entity_id FROM review WHERE entity_type = 'блюдо' ORDER BY entity_id LIMIT 1);
```

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.
Факт: `3.40` (вернулся к прежнему). Вердикт: OK.

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic();
```

Ожидается: колонки `restaurant_name`, `best_product_name`, `total_amount`,
`avg_amount`, `best_user`; по строке на ресторан; `best_user` не NULL.
Факт: 10 строк, 10 ресторанов, NULL нет. Вердикт: OK.

### E.6. `courier_salary()`

```sql
CALL courier_salary();
SELECT year, month, amount, coefficient_used FROM courier_pay
ORDER BY year DESC, month DESC LIMIT 5;
```

Ожидается: коэффициент пересчитан для работающих; у уволенных — 0.10;
у работающих `courier_pay` содержит текущий месяц, после увольнения строк нет.
Факт: у работающих по 6 месяцев, у уволенных — по месяц увольнения
включительно; строк после увольнения нет. Вердикт: OK.

### E.7. `courier_salary()` — повторный вызов

```sql
CALL courier_salary();
```

Ожидается: идемпотентно, без дублей.
Факт: `courier_pay` не изменился (число строк и суммы те же), коэффициенты те же. Вердикт: OK.

---

## F. Представление `how_much_money`

### F.1. Колонки

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema = 'prudko_food' AND table_name = 'how_much_money'
ORDER BY ordinal_position;
```

Ожидается: `year_month`, `sum_no_commission`, `sum_with_commission`,
`commission`, `prev_commission`, `commission_diff`, `courier_pay`,
`net_profit`.
Факт: совпадает. Вердикт: OK.

### F.2. Непрерывная серия месяцев

```sql
SELECT * FROM how_much_money ORDER BY year_month;
```

Ожидается: от первого доставленного до последнего, без пропусков.
Факт: 6 месяцев подряд (2026-06 … 2026-11). Вердикт: OK.

### F.3. Месяц без заказов (BR-11.9)

```sql
BEGIN;
DELETE FROM "order" WHERE status = 'доставлен'
  AND date_trunc('month', delivery_timestamp) = date_trunc('month', localtimestamp) - interval '4 months';
UPDATE courier_pay SET amount = 0
WHERE make_date(year, month, 1) = (date_trunc('month', localtimestamp) - interval '4 months')::date;
SELECT year_month, sum_no_commission, sum_with_commission, commission, courier_pay, net_profit
FROM how_much_money WHERE year_month = to_char(date_trunc('month', localtimestamp) - interval '4 months', 'YYYY-MM');
ROLLBACK;
```

Ожидается: месяц присутствует, все суммы нулевые.
Факт: `2026-07`: `0 / 0 / 0 / 0 / 0`. Вердикт: OK.

### F.4. Корректность сумм

```sql
SELECT count(*) FROM how_much_money
WHERE commission <> sum_with_commission - sum_no_commission
   OR commission_diff IS DISTINCT FROM commission - prev_commission
   OR net_profit <> commission - courier_pay;
```

Ожидается: 0. Факт: 0. Вердикт: OK.

---

## G. Права `inspector`

### G.1. Права на схему

```sql
SELECT has_schema_privilege('inspector', 'prudko_food', 'USAGE'),
       has_schema_privilege('inspector', 'prudko_food', 'CREATE'),
       has_schema_privilege('inspector', 'exts', 'USAGE');
```

Ожидается: `true`, `true`, `true`. Факт: `true`, `true`, `true`. Вердикт: OK.

### G.2. Права на таблицы

```sql
SELECT table_name, string_agg(privilege_type, ', ') FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'prudko_food' GROUP BY table_name;
```

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE`.
Факт: `SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER`.
Вердикт: OK.

### G.3. `information_schema` под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables WHERE table_schema = 'prudko_food';
RESET ROLE;
```

Ожидается: 12 таблиц + представление.
Факт: 13. Вердикт: OK.

### G.4. `pg_catalog` под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'prudko_food';
RESET ROLE;
```

Ожидается: 12. Факт: 12. Вердикт: OK.

### G.5. Все процедуры/функции под `inspector`

```sql
SET ROLE inspector;
SET search_path TO prudko_food, exts;
CALL erase_test_data();
CALL insert_test_data(10);
CALL courier_salary();
SELECT count(*) FROM get_statistic();
SELECT count(*) FROM how_much_money;
RESET ROLE;
```

Ожидается: без `permission denied`.
Факт: 10, 6. Вердикт: OK.

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. Подзапросы к `"order"`

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       (SELECT count(*) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен'),
       (SELECT sum(commission) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен')
FROM courier c;
```

Ожидается: два `SubPlan`, каждый сканирует `"order"`.
Факт: `Seq Scan on "order"` × 2, `loops=10`, Execution Time `0.254 ms`.
Вердикт: OK.

### H.2. Один `LEFT JOIN`

```sql
EXPLAIN ANALYZE
SELECT c.courier_id, count(o.order_id), sum(o.commission)
FROM courier c
LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
GROUP BY c.courier_id;
```

Ожидается: один `Hash Left Join`, один скан `"order"`, быстрее H.1.
Факт: `Hash Left Join`, один скан, `0.061 ms`. Вердикт: OK.

### H.3. `get_statistic()`

```sql
EXPLAIN ANALYZE SELECT * FROM get_statistic();
```

Ожидается: один `Function Scan`, без `LATERAL` и повторных подзапросов.
Факт: `Function Scan`, Execution Time `4.989 ms`. Вердикт: OK.

---

## I. Очистка и повторная генерация

### I.1. `erase_test_data` очищает всё

```sql
CALL erase_test_data();
SELECT (SELECT count(*) FROM client) + (SELECT count(*) FROM courier)
     + (SELECT count(*) FROM product_category) + (SELECT count(*) FROM restaurant)
     + (SELECT count(*) FROM address) + (SELECT count(*) FROM product)
     + (SELECT count(*) FROM "order") + (SELECT count(*) FROM review)
     + (SELECT count(*) FROM payment) + (SELECT count(*) FROM order_structure)
     + (SELECT count(*) FROM client_address) + (SELECT count(*) FROM courier_pay);
```

Ожидается: 0. Факт: 0. Вердикт: OK.

### I.2. Повторный `erase_test_data`

```sql
CALL erase_test_data();
```

Ожидается: без ошибок. Факт: без ошибок. Вердикт: OK.

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL insert_test_data(10);
SELECT count(*) FROM "order";
```

Ожидается: 50. Факт: 50. Вердикт: OK.
