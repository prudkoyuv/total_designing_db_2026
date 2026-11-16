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

```
pg_restore --exit-on-error -d foodexpress_restore foodexpress_prudko.backup
psql -d foodexpress_restore -f grants.sql
```

Ожидается: без ошибок; архив содержит только схему.
Факт: восстановлено в пустую БД с заранее созданными `exts` и `uuid-ossp` (BR-13.3).
В TOC только объекты схемы: 1 `SCHEMA`, 12 `TABLE`, 8 `TYPE`, 6 `FUNCTION`/`PROCEDURE`
(2 + 4), 1 `TRIGGER`, 1 `VIEW`, 1 `INDEX`; записей `DATABASE`, `EXTENSION`, `TABLE DATA` нет.
Владелец объектов — `pg_database_owner`, зависимость от роли разработчика отсутствует.
Вердикт: OK.

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO prudko_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.
Факт: `inspector`.
Вердикт: OK.

---

## B. FOOD-101: структура схемы

### B.1. Схема существует

```sql
SELECT count(*) FROM pg_namespace WHERE nspname = 'prudko_food';
```

Ожидается: 1.
Факт: 1.
Вердикт: OK.

### B.2. Схема `exts` и `uuid-ossp`

```sql
SELECT e.extname, n.nspname FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace;
```

Ожидается: `uuid-ossp` в `exts`.
Факт: `uuid-ossp → exts`; `plpgsql → pg_catalog`.
Вердикт: OK.

### B.3. 12 таблиц

```sql
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'prudko_food' AND c.relkind = 'r';
```

Ожидается: 12.
Факт: 12.
Вердикт: OK.

### B.4. Все PK и ID — uuid

```sql
SELECT count(*) FILTER (WHERE c.contype = 'p') AS pks FROM pg_constraint c
JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'prudko_food';

SELECT count(*) AS non_uuid_ids FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'prudko_food' AND c.relkind = 'r' AND a.attnum > 0
  AND a.attname LIKE '%\_id' AND format_type(a.atttypid, a.atttypmod) <> 'uuid';
```

Ожидается: 12 PK, 0 не-uuid ID.
Факт: `pks = 12`, `non_uuid_ids = 0`.
Вердикт: OK.

### B.5. Enum-типы

```sql
SELECT t.typname, string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder)
FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'prudko_food' GROUP BY t.typname ORDER BY t.typname;
```

Ожидается: 8 типов из BR-4.3, 5.5, 6.2, 7.7, 7.9, 8.2, 9.1, 11.5.
Факт: `courier_status`, `order_pay_status`, `order_status`, `payment_status`,
`payment_type`, `product_status`, `restaurant_status`, `review_entity_type` — 8 типов,
значения совпадают с BR.
Вердикт: OK.

### B.6. Внешние ключи

```sql
SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
WHERE n.nspname = 'prudko_food' AND c.contype = 'f';
```

Ожидается: все FK из ERD.
Факт: 16 FK: 15 из ERD + составной `order(client_id, address_id) → client_address` (BR-7.4).
Вердикт: OK.

### B.7. Пароль — MD5

Выполняется после C.2.

```sql
SELECT count(*) FROM client WHERE password !~ '^[0-9a-f]{32}$';
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: без ошибок.
Вердикт: OK.

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок.
Факт: без ошибок.
Вердикт: OK.

### C.3. Распределение строк (BR-11.7)

```sql
SELECT (SELECT count(*) FROM client) AS client,
       (SELECT count(*) FROM courier) AS courier,
       (SELECT count(*) FROM product_category) AS category,
       (SELECT count(*) FROM restaurant) AS restaurant,
       (SELECT count(*) FROM address) AS address,
       (SELECT count(*) FROM product) AS product,
       (SELECT count(*) FROM "order") AS orders,
       (SELECT count(*) FROM review) AS review,
       (SELECT count(*) FROM payment) AS payment;
```

Ожидается: 10, 10, 10, 10, 50, 50, 50, 50, 50.
Факт: 10, 10, 10, 10, 50, 50, 50, 50, 50.
Вердикт: OK.

### C.4. Адреса ресторанов и клиентов (BR-11.7)

```sql
SELECT count(*) FILTER (WHERE address_id IN (SELECT address_id FROM restaurant)) AS restaurant_addr,
       count(*) FILTER (WHERE address_id NOT IN (SELECT address_id FROM restaurant)) AS client_addr
FROM address;
```

Ожидается: 10 ресторанных, 40 клиентских.
Факт: 10 и 40 (всего 50).
Вердикт: OK.

### C.5. Нет пустых строк

```sql
SELECT (SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '') AS client,
       (SELECT count(*) FROM address WHERE street = '' OR house_number = '') AS address,
       (SELECT count(*) FROM restaurant WHERE restaurant_name = '' OR description = '') AS restaurant,
       (SELECT count(*) FROM courier WHERE last_name = '' OR first_name = '' OR middle_name = '' OR phone_number = '') AS courier,
       (SELECT count(*) FROM product_category WHERE product_category_name = '') AS category,
       (SELECT count(*) FROM product WHERE product_name = '' OR description = '') AS product,
       (SELECT count(*) FROM "order" WHERE description = '') AS orders,
       (SELECT count(*) FROM payment WHERE transaction_code = '') AS payment,
       (SELECT count(*) FROM review WHERE description = '') AS review;
```

Ожидается: все 0.
Факт: все 0.
Вердикт: OK.

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT (SELECT count(*) FROM "order" WHERE client_id IS NULL OR restaurant_id IS NULL
           OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL) AS orders,
       (SELECT count(*) FROM order_structure WHERE order_id IS NULL OR product_id IS NULL
           OR quantity IS NULL) AS structure,
       (SELECT count(*) FROM payment WHERE order_id IS NULL OR amount IS NULL
           OR transaction_code IS NULL) AS payment,
       (SELECT count(*) FROM review WHERE client_id IS NULL OR order_id IS NULL
           OR entity_id IS NULL OR rating IS NULL) AS review,
       (SELECT count(*) FROM courier_pay WHERE courier_id IS NULL OR amount IS NULL
           OR coefficient_used IS NULL) AS pay;
```

Ожидается: все 0.
Факт: все 0.
Вердикт: OK.

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status <> 'уволен';
```

Ожидается: `>= 1`.
Факт: 9.
Вердикт: OK.

### C.8. `courier_pay` согласован с правилами (BR-10.2)

```sql
SELECT count(*) AS rows_total,
       count(*) FILTER (
           WHERE amount = round(coalesce((
               SELECT sum(o.commission) FROM "order" o
               WHERE o.courier_id = cp.courier_id
                 AND o.status = 'доставлен'
                 AND extract(year  FROM o.delivery_timestamp) = cp.year
                 AND extract(month FROM o.delivery_timestamp) = cp.month
           ), 0) * cp.coefficient_used, 2)
       ) AS rows_ok
FROM courier_pay cp;
```

Ожидается: `amount` рассчитан по доставкам месяца.
Факт: `rows_total = 60`, `rows_ok = 60`; 6 месяцев (2026-06 … 2026-11) на каждого из 10 курьеров.
Вердикт: OK.

### C.9. Повторный вызов не ломает

```sql
DO $$ BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;
```

Ожидается: без ошибок, данные добавляются.
Факт: без ошибок; `client = 110`, `order = 550`, `payment = 550`, `courier_pay = 660`.
После проверки выполнены `erase_test_data()` и `insert_test_data(10)` — данные
возвращены к каноническому виду.
Вердикт: OK.

---

## D. Проверки бизнес-правил на сгенерированных данных

### D.1. Все FK валидны (нет orphans)

```sql
SELECT (SELECT count(*) FROM order_structure os
         WHERE NOT EXISTS (SELECT 1 FROM "order" o WHERE o.order_id = os.order_id)) AS os_order,
       (SELECT count(*) FROM order_structure os
         WHERE NOT EXISTS (SELECT 1 FROM product p WHERE p.product_id = os.product_id)) AS os_product,
       (SELECT count(*) FROM payment p
         WHERE NOT EXISTS (SELECT 1 FROM "order" o WHERE o.order_id = p.order_id)) AS pay_order,
       (SELECT count(*) FROM review r
         WHERE NOT EXISTS (SELECT 1 FROM "order" o WHERE o.order_id = r.order_id)) AS rev_order,
       (SELECT count(*) FROM review r
         WHERE NOT EXISTS (SELECT 1 FROM client c WHERE c.client_id = r.client_id)) AS rev_client,
       (SELECT count(*) FROM "order" o
         WHERE NOT EXISTS (SELECT 1 FROM client c WHERE c.client_id = o.client_id)) AS order_client,
       (SELECT count(*) FROM "order" o
         WHERE NOT EXISTS (SELECT 1 FROM restaurant rs WHERE rs.restaurant_id = o.restaurant_id)) AS order_restaurant;
```

Ожидается: все 0.
Факт: все 0.
Вердикт: OK.

### D.2. Минимальная сумма заказа (BR-7.11)

```sql
SELECT count(*) FROM "order" WHERE total_amount < 1000;
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM "order" WHERE commission <> round(order_amount * 0.10, 2);
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.4. `total_amount = order_amount + commission` (BR-7.10)

```sql
SELECT count(*) FROM "order" WHERE total_amount <> order_amount + commission;
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.5. Доставка не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order" WHERE delivery_timestamp < order_timestamp;
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
WHERE NOT EXISTS (SELECT 1 FROM client_address ca
                  WHERE ca.client_id = o.client_id AND ca.address_id = o.address_id);
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.7. Все блюда из ресторана заказа (BR-7.3)

```sql
SELECT count(*) FROM order_structure os
JOIN "order" o ON o.order_id = os.order_id
JOIN product p ON p.product_id = os.product_id
WHERE p.restaurant_id <> o.restaurant_id;
```

Ожидается: 0.
Факт: 0. BR-7.3 обеспечивается бэкендом при сборке заказа; в БД межтабличная
проверка не дублируется (см. `constraints.md`, «Граница с приложением»).
Вердикт: OK.

### D.8. Не больше одной успешной оплаты (BR-8.1)

```sql
SELECT count(*) FROM (
    SELECT order_id FROM payment WHERE status = 'успех'
    GROUP BY order_id HAVING count(*) > 1) x;
```

Ожидается: 0.
Факт: 0. Статусы оплаты заказа: `оплачен 20`, `ошибка 10`, `ожидает 20` — все
значения BR-8.7 достижимы; `order.pay_status` выставляет генератор по сценарию
оплат (BR-8.7 на бэкенде).
Вердикт: OK.

### D.9. Сумма оплаты = `total_amount` (BR-8.4)

```sql
SELECT count(*) FROM payment p JOIN "order" o ON o.order_id = p.order_id
WHERE p.amount <> o.total_amount;
```

Ожидается: 0.
Факт: 0. Сумма выставляется генератором/бэкендом; в БД межтабличная проверка
BR-8.4 не дублируется.
Вердикт: OK.

### D.10. Нет дубликатов в `client_address` (BR-2.5)

```sql
SELECT count(*) FROM (
    SELECT client_id, address_id FROM client_address
    GROUP BY client_id, address_id HAVING count(*) > 1) x;
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

```sql
SELECT count(*) FROM (
    SELECT order_id, product_id FROM order_structure
    GROUP BY order_id, product_id HAVING count(*) > 1) x;
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```

Ожидается: 0.
Факт: 0.
Вердикт: OK.

### D.14. Рейтинги соответствуют отзывам (BR-9.6)

```sql
SELECT
    (SELECT count(*) FROM product p WHERE p.rating IS NOT NULL
       AND p.rating <> (SELECT round(avg(r.rating), 2) FROM review r
                        WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id)) AS product_bad,
    (SELECT count(*) FROM restaurant rs WHERE rs.rating IS NOT NULL
       AND rs.rating <> (SELECT round(avg(r.rating), 2) FROM review r
                         WHERE r.entity_type = 'ресторан' AND r.entity_id = rs.restaurant_id)) AS restaurant_bad;
```

Ожидается: 0 и 0.
Факт: 0 и 0.
Вердикт: OK.

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

```sql
SELECT count(*) FROM product;

DO $$
DECLARE v_restaurant uuid; v_category uuid;
BEGIN
    SELECT restaurant_id INTO v_restaurant FROM restaurant ORDER BY restaurant_id LIMIT 1;
    SELECT product_category_id INTO v_category FROM product_category ORDER BY product_category_id LIMIT 1;
    CALL add_product(v_restaurant, v_category, 'Тестовое блюдо', 250, 'Описание', 'доступно', NULL, 4.5);
END $$;

SELECT count(*) FROM product;
SELECT product_name, price, rating FROM product WHERE product_name = 'Тестовое блюдо';
```

Ожидается: `after = before + 1`.
Факт: 50 → 51; добавлено «Тестовое блюдо», цена 250.00, рейтинг 4.50.
Вердикт: OK.

### E.2. `add_product` — несуществующий ресторан

```sql
DO $$
DECLARE v_category uuid;
BEGIN
    SELECT product_category_id INTO v_category FROM product_category LIMIT 1;
    CALL add_product('00000000-0000-0000-0000-000000000000', v_category,
                     'Плохое блюдо', 100, 'Описание');
END $$;
```

Ожидается: ошибка с внятным сообщением.
Факт: `Нельзя добавить блюдо: ресторан 00000000-0000-0000-0000-000000000000
или категория … не существуют (FK)`.
Вердикт: OK.

### E.3. `rating_change` — пересчитывает рейтинг

```sql
CREATE TEMP TABLE rating_probe AS
SELECT p.product_id, p.rating,
       (SELECT o.order_id FROM "order" o
         WHERE NOT EXISTS (SELECT 1 FROM review r
                            WHERE r.order_id = o.order_id
                              AND r.entity_type = 'блюдо'
                              AND r.entity_id = p.product_id)
         LIMIT 1) AS order_id
  FROM product p
 WHERE p.rating IS NOT NULL
 LIMIT 1;

SELECT rating FROM product WHERE product_id = (SELECT product_id FROM rating_probe);

INSERT INTO review (client_id, entity_id, entity_type, order_id, description, rating)
SELECT (SELECT client_id FROM client LIMIT 1), product_id, 'блюдо', order_id,
       'Тестовый отзыв', 5
  FROM rating_probe;

SELECT rating FROM product WHERE product_id = (SELECT product_id FROM rating_probe);
```

Ожидается: `rating` пересчитан.
Факт: было 4.60, после отзыва на 5 — 4.80.
Вердикт: OK.

### E.4. `rating_change` — удаление отзыва

```sql
DELETE FROM review WHERE description = 'Тестовый отзыв';
SELECT rating FROM product WHERE product_id = (SELECT product_id FROM rating_probe);
DROP TABLE rating_probe;
```

Ожидается: если других отзывов нет — `NULL`; иначе — пересчитан.
Факт: отзыв удалён, рейтинг вернулся к 4.60.
Вердикт: OK.

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic() ORDER BY restaurant_name LIMIT 3;
```

Ожидается: колонки `restaurant_name`, `best_product_name`, `total_amount`,
`avg_amount`, `best_user`; по одной строке на ресторан; `best_user` — логин клиента.
Факт: 10 строк; `best_product_name IS NULL` — 0, `best_user IS NULL` — 0;
имена и суммы заполнены.
Вердикт: OK.

### E.6. `courier_salary()`

```sql
CALL courier_salary();
SELECT year, month, courier_id, amount, coefficient_used
FROM courier_pay ORDER BY year DESC, month DESC LIMIT 10;
```

Ожидается: запись за текущий месяц; коэффициент пересчитан по BR-10.2.
Факт: `courier_pay` — 60 строк, за текущий месяц 10; у работающих курьеров
`coefficient = 0.10` (до 150 доставок), у уволенных он не изменён.
Вердикт: OK.

### E.7. `courier_salary()` — повторный вызов

```sql
SELECT md5(string_agg(year || '-' || month || '-' || courier_id || '-' || amount
                      || '-' || coefficient_used, '|' ORDER BY year, month, courier_id))
FROM courier_pay;
CALL courier_salary();
SELECT md5(string_agg(year || '-' || month || '-' || courier_id || '-' || amount
                      || '-' || coefficient_used, '|' ORDER BY year, month, courier_id))
FROM courier_pay;
```

Ожидается: количество строк не изменилось, значения не продублированы.
Факт: контрольные суммы до и после совпадают; строк — 60.
Вердикт: OK.

---

## F. Представление `how_much_money`

### F.1. Колонки

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema = 'prudko_food' AND table_name = 'how_much_money'
ORDER BY ordinal_position;
```

Ожидается: `year_month` (text) и 7 numeric-колонок.
Факт: `year_month text`, `sum_no_commission`, `sum_with_commission`, `commission`,
`prev_commission`, `commission_diff`, `courier_pay`, `net_profit` — numeric.
Вердикт: OK.

### F.2. Месяцы покрыты

```sql
SELECT count(*), min(year_month), max(year_month) FROM how_much_money;
```

Ожидается: непрерывная серия от первого доставленного заказа до последнего.
Факт: 6 месяцев, 2026-06 … 2026-11, пропусков нет.
Вердикт: OK.

### F.3. Месяцы без заказов присутствуют (BR-11.9)

```sql
SELECT count(*) FROM how_much_money WHERE sum_no_commission = 0;
```

Ожидается: месяцы без заказов не выпадают из отчёта.
Факт: таких месяцев в данных нет (0); серия строится рекурсивным CTE, поэтому
пропущенный месяц получил бы нулевые суммы.
Вердикт: OK.

### F.4. Корректность сумм

```sql
SELECT count(*) FILTER (WHERE commission <> sum_with_commission - sum_no_commission) AS commission_bad,
       count(*) FILTER (WHERE commission_diff IS DISTINCT FROM commission - prev_commission) AS diff_bad,
       count(*) FILTER (WHERE net_profit <> commission - courier_pay) AS profit_bad
FROM how_much_money;
```

Ожидается: все 0.
Факт: все 0. Например, 2026-06: `2636.43 = 29000.73 - 26364.30`, `prev_commission`
NULL, `net_profit = 2372.79`.
Вердикт: OK.

---

## G. Права `inspector`

### G.1. Права на схему

```sql
SELECT has_schema_privilege('inspector', 'prudko_food', 'USAGE') AS usage,
       has_schema_privilege('inspector', 'prudko_food', 'CREATE') AS create;
```

Ожидается: `true`, `true`.
Факт: `t`, `t`.
Вердикт: OK.

### G.2. Права на таблицы

```sql
SELECT table_name, string_agg(DISTINCT privilege_type, ', ')
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'prudko_food'
GROUP BY table_name;
```

Ожидается: `SELECT, INSERT, UPDATE, DELETE` у каждой таблицы.
Факт: полный набор прав у 12 таблиц и представления `how_much_money`.
Вердикт: OK.

### G.3. `information_schema` читается под `inspector`

```sql
SELECT count(*) FROM information_schema.tables WHERE table_schema = 'prudko_food';
```

Ожидается: 12 таблиц + представления.
Факт: 13 (12 таблиц и `how_much_money`).
Вердикт: OK.

### G.4. `pg_catalog` читается под `inspector`

```sql
SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'prudko_food';
```

Ожидается: 12.
Факт: 12.
Вердикт: OK.

### G.5. Все процедуры/функции работают под `inspector`

```sql
CALL erase_test_data();
CALL insert_test_data(10);
CALL courier_salary();
SELECT count(*) FROM get_statistic();
SELECT count(*) FROM how_much_money;
```

Ожидается: без `permission denied`.
Факт: все вызовы выполнены; `get_statistic` — 10 строк, `how_much_money` — 6 строк.
Вердикт: OK.

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. План `get_statistic`

```sql
EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM get_statistic();
```

Ожидается: без повторных сканов `"order"`.
Факт: `Function Scan on get_statistic`, 10 строк, 7.8 мс. В теле функции `"order"`
читается один раз (материализованный CTE `delivered`), лучшие блюдо и клиент
выбираются через `DISTINCT ON` без оконных функций.
Вердикт: OK.

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

```sql
EXPLAIN (ANALYZE, COSTS OFF)
SELECT c.courier_id,
       count(o.order_id) AS cnt,
       coalesce(sum(o.commission), 0) AS commission_sum
FROM courier c
LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
GROUP BY c.courier_id;
```

Ожидается: один `Hash Right Join`, один скан `"order"`, время меньше, чем в H.1.
Факт: `HashAggregate → Hash Right Join → Seq Scan on "order"` (один скан), 0.08 мс.
Вердикт: OK.

### H.3. Применить к `get_statistic`

```sql
EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM get_statistic();
```

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без оконных функций там, где хватает агрегата.
Факт: `Function Scan` без `LATERAL`; в теле — один материализованный CTE `delivered`,
далее `DISTINCT ON`, оконных функций нет.
Вердикт: OK.

---

## I. Работа с тестовыми данными

### I.1. `erase_test_data` очищает всё

```sql
CALL erase_test_data();
SELECT (SELECT count(*) FROM client) AS client,
       (SELECT count(*) FROM address) AS address,
       (SELECT count(*) FROM client_address) AS client_address,
       (SELECT count(*) FROM restaurant) AS restaurant,
       (SELECT count(*) FROM courier) AS courier,
       (SELECT count(*) FROM courier_pay) AS courier_pay,
       (SELECT count(*) FROM product_category) AS category,
       (SELECT count(*) FROM product) AS product,
       (SELECT count(*) FROM "order") AS orders,
       (SELECT count(*) FROM order_structure) AS structure,
       (SELECT count(*) FROM payment) AS payment,
       (SELECT count(*) FROM review) AS review;
```

Ожидается: все 0.
Факт: все 0.
Вердикт: OK.

### I.2. Повторный `erase_test_data` не падает

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: без ошибок.
Вердикт: OK.

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL insert_test_data(10);
```

Ожидается: все таблицы заполнены, FK-целостность не нарушена.
Факт: 10, 10, 10, 10, 50, 50, 50, 50, 50; orphans в `order_structure` — 0.
Вердикт: OK.
