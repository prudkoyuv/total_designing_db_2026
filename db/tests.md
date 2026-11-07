# Протокол самопроверки

Все проверки выполнены реально, под ролью `inspector`, на PostgreSQL 18.4.
Основная база — `foodexpress_dev`; протокол восстановления дополнительно
прогнан на чистой базе `foodexpress_restore`.

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | `PostgreSQL 18.4 (Debian 18.4-1.pgdg12+1) on x86_64-pc-linux-gnu` |
| Дата проверки | 2026-11-07 |
| Схема | `prudko_food` |
| Роль-аудитор | `inspector` |

Все проверки — под `inspector`, если не указано иное.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Ожидается: без ошибок.

Факт: чистая БД `foodexpress_restore` создана, в ней заранее созданы `exts` и
`uuid-ossp` (BR-13.3), затем выполнено:

```
pg_restore --no-owner --no-privileges --exit-on-error -d foodexpress_restore foodexpress_prudko.backup
psql -d foodexpress_restore -f grants.sql
```

Оба шага завершились без ошибок. Бэкап содержит только схему `prudko_food`
(12 таблиц, 8 enum-типов, 16 FK, функции, процедуры, представление, данные);
`exts`, роль `inspector` и сама база в бэкап не входят — они создаются
`grants.sql` / подготовлены заранее.

Вердикт: OK.

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO prudko_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.

Факт:

| current_user | current_schema | search_path |
|---|---|---|
| `inspector` | `prudko_food` | `prudko_food, exts` |

Вердикт: OK.

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```

Ожидается: `prudko_food`.

Факт: `prudko_food`.

Вердикт: OK.

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```

Ожидается: `uuid-ossp`, схема `exts`.

Факт: `uuid-ossp`, схема `exts`. Расширение не пересоздавалось (BR-13.3).

Вердикт: OK.

### B.3. Все 12 исходных таблиц + N после нормализации

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'prudko_food'
ORDER BY table_name;
```

Ожидается: `address`, `client`, `client_address`, `courier`, `courier_pay`,
`order`, `order_structure`, `payment`, `product`, `product_category`,
`restaurant`, `review` (12 + N штук).

Факт: все 12 таблиц присутствуют; нормализация не потребовала новых таблиц
(N = 0). `information_schema.tables` возвращает 13 строк, потому что включает
представление `how_much_money`. `pg_catalog.pg_tables` возвращает 12 —
только таблицы.

Вердикт: OK.

### B.4. Все PK — `uuid`

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'prudko_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';
```

Ожидается: пусто.

Факт: `non_uuid_ids = 0`.

Вердикт: OK.

### B.5. Enum-типы

```sql
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'prudko_food'
GROUP BY t.typname
ORDER BY t.typname;
```

Ожидается: 8 типов со значениями из `constraints.md`.

Факт: 8 типов:

| Тип | Значения |
|---|---|
| `courier_status` | `свободен, занят, на_доставке, уволен` |
| `order_pay_status` | `ожидает, оплачен, ошибка` |
| `order_status` | `создан, готовится, в_доставке, доставлен, отменён` |
| `payment_status` | `успех, ошибка, в_обработке` |
| `payment_type` | `карта, наличные, безнал` |
| `product_status` | `доступно, нет_в_наличии, архив` |
| `restaurant_status` | `активен, неактивен` |
| `review_entity_type` | `блюдо, ресторан, заказ` |

Вердикт: OK.

### B.6. FK-ограничения

```sql
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'prudko_food'::regnamespace
ORDER BY tbl, conname;
```

Ожидается: не менее 15 FK, все из `erd.md`.

Факт: 16 FK. Дополнительно к 15 связям ERD добавлен составной FK
`fk_order_client_address (client_id, address_id) → client_address` для BR-7.4.

Вердикт: OK.

### B.7. Пароль — MD5

```sql
SELECT length(password) AS len, password FROM client LIMIT 5;
```

Ожидается: `len = 32`, hex-строка.

Факт: у всех проверенных строк `len = 32`, например
`62adc345...`, `0515008c...`, `d16e2ca1...`; `bad_password_md5 = 0`.

Вердикт: OK.

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.

Факт: `CALL` выполнен, все 12 таблиц пусты, последовательности сброшены.

Вердикт: OK.

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок.

Факт: `CALL` выполнен без ошибок.

Вердикт: OK.

### C.3. Распределение строк (BR-11.7)

```sql
SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
-- ... и остальные таблицы
ORDER BY tbl;
```

Ожидается: 10, 10, 10, 10, 50, 50, 50, 50, 50.

Факт (канонический прогон `insert_test_data(10)`):

| Таблица | Строк |
|---|---:|
| `client` | 10 |
| `courier` | 10 |
| `product_category` | 10 |
| `restaurant` | 10 |
| `address` | 50 |
| `product` | 50 |
| `order` | 50 |
| `review` | 50 |
| `payment` | 50 |
| `client_address` | 40 |
| `order_structure` | 147 |
| `courier_pay` | 60 |

`order_structure` и `courier_pay` — «необходимое количество для связности»:
у каждого клиента 4 адреса (10 × 4 = 40), у каждого курьера 6 месяцев выплат
(10 × 6 = 60), число позиций зависит от случайного количества блюд в заказе.

Вердикт: OK.

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

```sql
SELECT 'restaurant addresses' AS cat, count(*) FROM restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'total addresses', count(*) FROM address;
```

Ожидается: 10 ресторанных адресов, 50 всего → 40 клиентских.

Факт: `restaurant addresses = 10`, `total addresses = 50`, клиентских — 40
(`client_address` = 40).

Вердикт: OK.

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '';
```

Ожидается: 0.

Факт: `empty_strings = 0`; проверка в `acceptance_checks.sql` покрывает
`client` и подтверждает отсутствие пустых обязательных строк.

Вердикт: OK.

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) FROM "order" WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
```

Ожидается: 0.

Факт: `null_required = 0`.

Вердикт: OK.

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

Ожидается: `>= 1`.

Факт: `active_couriers = 10` в каноническом прогоне (в других прогонах — 7–8;
правило выполняется всегда).

Вердикт: OK.

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

```sql
SELECT cp.year, cp.month, cp.courier_id, cp.amount, cp.coefficient_used,
       round(coalesce((
           SELECT sum(o.commission)
           FROM "order" o
           WHERE o.courier_id = cp.courier_id
             AND o.status = 'доставлен'
             AND extract(year  from o.order_timestamp) = cp.year
             AND extract(month from o.order_timestamp) = cp.month
       ), 0) * cp.coefficient_used, 2) AS expected_amount
FROM courier_pay cp;
```

Ожидается: `amount = expected_amount` в каждой строке.

Факт: `rows_total = 60`, `rows_ok = 60`. У каждого курьера ровно 6 месяцев
(`couriers_without_6_months = 0`).

Вердикт: OK.

### C.9. Повторный вызов не ломает

```sql
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;
```

Ожидается: без ошибок, данные добавляются или заменяются (по решению студента,
задокументированному в `constraints.md`).

Факт: после 10 повторных вызовов без очистки — `client = 110`,
`order = 550`, ошибок нет. Генератор аддитивен: каждый вызов добавляет
`value` клиентов/курьеров/категорий/ресторанов и `value * 5`
адресов/блюд/заказов/отзывов/платежей. Уникальность логинов, телефонов и
названий обеспечивается последовательностями, поэтому повторный вызов не
конфликтует с предыдущим. После проверки выполнены `erase_test_data()` и
`insert_test_data(10)` — данные возвращены к каноническому виду.

Вердикт: OK.

---

## D. Проверки бизнес-правил на сгенерированных данных

### D.1. Все FK валидны (нет orphans)

Ожидается: все 0.

Факт: все 7 проверенных связей — 0 orphans:
`order_structure → order`, `order_structure → product`, `payment → order`,
`review → order`, `courier_pay → courier`, `client_address → client`,
`client_address → address`.

Вердикт: OK.

### D.2. Минимальная сумма заказа (BR-7.11)

```sql
SELECT count(*) FROM "order" WHERE total_amount < 1000;
```

Ожидается: 0.

Факт: 0 (`total_lt_1000`).

Вердикт: OK.

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM "order" WHERE round(order_amount * 0.10, 2) != commission;
```

Ожидается: 0.

Факт: 0 (`bad_commission`). `commission` — `GENERATED ALWAYS AS ... STORED`.

Вердикт: OK.

### D.4. `total_amount = order_amount + commission`

```sql
SELECT count(*) FROM "order"
WHERE round(order_amount + commission, 2) != total_amount;
```

Ожидается: 0.

Факт: 0 (`bad_total`).

Вердикт: OK.

### D.5. Дата доставки не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

Ожидается: 0.

Факт: 0 (`bad_delivery_ts`).

Вердикт: OK.

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```

Ожидается: 0.

Факт: 0 (`address_not_owned`).

Вердикт: OK.

### D.7. Все блюда в заказе из одного ресторана (BR-7.3)

```sql
SELECT count(DISTINCT os.order_id)
FROM order_structure os
JOIN "order" o ON os.order_id = o.order_id
JOIN product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;
```

Ожидается: 0.

Факт: 0 (`wrong_restaurant_product`).

Вердикт: OK.

### D.8. Ровно одна успешная оплата на заказ (BR-8.1)

```sql
SELECT order_id, count(*) AS cnt
FROM payment WHERE status = 'успех'
GROUP BY order_id HAVING count(*) != 1;
```

Ожидается: пусто.

Факт: пусто; `orders_without_success = 0`, `orders_multiple_success = 0`.

Вердикт: OK.

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

```sql
SELECT count(*) FROM payment p
JOIN "order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```

Ожидается: 0.

Факт: 0 (`payment_amount_mismatch`).

Вердикт: OK.

### D.10. Нет дубликатов в `client_address` (BR-2.5)

Ожидается: пусто.

Факт: пусто (`ca_dupes = 0`; PK `(client_id, address_id)`).

Вердикт: OK.

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

Ожидается: пусто.

Факт: пусто (`os_dupes = 0`; PK `(order_id, product_id)`).

Вердикт: OK.

### D.12. `work_end > work_start` (BR-4.4)

Ожидается: 0.

Факт: 0 (`bad_work_hours`).

Вердикт: OK.

### D.13. `dismissal_date >= hire_date` (BR-6.3)

Ожидается: 0.

Факт: 0 (`bad_dismissal`); дополнительно `dismissed_no_date = 0`.

Вердикт: OK.

### D.14. Рейтинг блюд/ресторанов соответствует отзывам (BR-9.6)

Ожидается: `rating = expected`.

Факт: `product_rating_mismatch = 0`, `restaurant_rating_mismatch = 0`.

Вердикт: OK.

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

Ожидается: `after = before + 1`.

Факт: `add_product success: 50 -> 51`; созданное блюдо затем удалено.

Вердикт: OK.

### E.2. `add_product` — падает на несуществующий ресторан

Ожидается: ошибка с внятным сообщением.

Факт: `Ресторан с id 00000000-0000-0000-0000-000000000000 не существует`.
Дополнительно проверены несуществующая категория
(`Категория с id ... не существует`) и отрицательная цена
(`Цена блюда не может быть отрицательной или NULL`).

Вердикт: OK.

### E.3. `rating_change` — пересчитывает рейтинг

Ожидается: `rating` пересчитан.

Факт: после вставки трёх отзывов с оценками 3, 4, 5 —
`rating insert 3,4,5 = 4.00`.

Вердикт: OK.

### E.4. `rating_change` — удаление отзыва

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.

Факт: после удаления отзыва с оценкой 3 —
`rating after delete one = 4.50`; после удаления всех отзывов —
`rating after delete all = NULL`. Также проверены `UPDATE rating 2 → 5`
(результат `4.50`) и смена `entity_type`/`entity_id` (старый и новый объект
пересчитаны).

Вердикт: OK.

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic();
```

Ожидается:

- Колонки: `restaurant_name`, `best_product_name`, `total_amount`,
  `avg_amount`, `best_user`.
- По одной строке на ресторан.
- `best_user` = `client.login` (не NULL при наличии заказов).

Факт: ровно 5 колонок с указанными именами и типами; `rows = 10` (по числу
ресторанов); `null_best_product = 0`, `null_best_user = 0`;
`total_lt_avg = 0`. Пример строки:
`Ресторан 1 | Блюдо 3 | 16972.19 | 3394.44 | client_7`.

Вердикт: OK.

### E.6. `courier_salary()`

Ожидается:

- `courier.coefficient` пересчитан для работающих (по BR-10.2).
- У уволенных — не изменился.
- `courier_pay` содержит запись за текущий месяц.

Факт: `courier_salary OK: rows = 10, zero_pay_couriers = 4`. Записи за текущий
месяц есть у всех 10 курьеров; суммы совпадают с формулой
`coefficient_used × sum(commission)` (60/60 строк `courier_pay`). При
наличии уволенного курьера его коэффициент остаётся прежним (в одном из
прогонов: `dismissed coefficient = 0.10`).

Вердикт: OK.

### E.7. `courier_salary()` — повторный вызов

Ожидается: количество не изменилось (idempotency / обновление).

Факт: после второго вызова хеши сумм и коэффициентов совпали; число строк за
текущий месяц осталось `10`. Реализовано через
`ON CONFLICT (year, month, courier_id) DO UPDATE`.

Вердикт: OK.

---

## F. Представление `how_much_money`

### F.1. Колонки

Ожидается: `year_month` (text), `sum_no_commission`, `sum_with_commission`,
`commission`, `prev_commission`, `commission_diff`, `courier_pay`,
`net_profit` (numeric).

Факт: ровно 8 колонок в указанном порядке и с указанными типами.

Вердикт: OK.

### F.2. Месяцы покрыты

Ожидается: месяцы от первого доставленного заказа до последнего, без пропусков.

Факт: `months = 6`, `first_month = 2026-06`, `last_month = 2026-11`;
месяцы идут непрерывно: `2026-06, 2026-07, 2026-08, 2026-09, 2026-10, 2026-11`.

Вердикт: OK.

### F.3. Месяцы без заказов присутствуют (BR-11.9)

Ожидается: если в какие-то месяцы заказов не было — они есть в результате.

Факт: проверено отдельно в транзакции с `ROLLBACK`: при удалении всех
доставленных заказов за `2026-09` строка `2026-09` осталась в представлении:

| year_month | sum_no_commission | sum_with_commission | commission | courier_pay | net_profit |
|---|---:|---:|---:|---:|---:|
| 2026-09 | 0 | 0 | 0 | 260.49 | -260.49 |

Непрерывная серия строится рекурсивным CTE `bounds`/`months`.

Вердикт: OK.

### F.4. Корректность сумм

Ожидается:

- `commission = sum_with_commission - sum_no_commission`.
- `commission_diff = commission - prev_commission` (NULL для первого месяца).
- `net_profit = commission - courier_pay`.

Факт: `formula_mismatch = 0`; `bad_commission = 0`, `bad_net_profit = 0`,
`bad_diff = 0`, `first_month_diff = 0`. Пример:

| year_month | sum_no_commission | sum_with_commission | commission | prev_commission | commission_diff | courier_pay | net_profit |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2026-06 | 19500.49 | 21450.55 | 1950.06 | NULL | NULL | 195.01 | 1755.05 |
| 2026-07 | 16058.16 | 17663.99 | 1605.83 | 1950.06 | -344.23 | 160.59 | 1445.24 |

(суммы зависят от случайных тестовых данных; формулы проверяются на каждом
прогоне).

Вердикт: OK.

---

## G. Права `inspector`

### G.1. Права на схему

Ожидается: `prudko_food`, `usage = true`, `create = true`.

Факт: `prudko_food | t | t`.

Вердикт: OK.

### G.2. Права на таблицы

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).

Факт: у всех 13 объектов (12 таблиц + представление) —
`DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE`, то есть
полный набор (`GRANT ALL PRIVILEGES`).

Вердикт: OK.

### G.3. `information_schema` читается под `inspector`

Ожидается: 12 + N (количество таблиц).

Факт: 13 (12 таблиц + представление `how_much_money`).

Вердикт: OK.

### G.4. `pg_catalog` читается под `inspector`

Ожидается: 12 + N.

Факт: 12 (только таблицы).

Вердикт: OK.

### G.5. Все процедуры/функции работают под `inspector`

Ожидается: без `permission denied`.

Факт: под `inspector` успешно выполнены `erase_test_data()`,
`insert_test_data(10)`, `courier_salary()`, `add_product(...)`,
`get_statistic()`, `SELECT * FROM how_much_money`. Ошибок прав нет.

Вердикт: OK.

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. `EXPLAIN ANALYZE` — паттерн «избыточные подзапросы»

Ожидается: два SubPlan, каждый — скан `"order"`.

Факт: два `SubPlan`, каждый использует `Bitmap Index Scan` по
`idx_order_courier_status` и `Bitmap Heap Scan` на `"order"`;
`Execution Time: 0.436 ms`.

Вердикт: OK (паттерн воспроизведён).

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

Ожидается: один `Hash Right Join` / `Hash Left Join`, один скан `"order"`;
время меньше, чем в H.1.

Факт: `HashAggregate` → `Hash Right Join` → один `Seq Scan on "order"` +
`Seq Scan on courier`; `Execution Time: 0.214 ms` (меньше, чем 0.436 ms).

Вердикт: OK.

### H.3. Применить к `get_statistic`

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без
оконных функций там, где хватает агрегата.

Факт: `EXPLAIN ANALYZE SELECT * FROM get_statistic();` даёт один
`Function Scan on get_statistic`, `Execution Time: 0.843 ms` — внутренний
план SQL-функции снаружи не раскрывается. В теле функции (`07_get_statistic.sql`):
`"order"` сканируется один раз в CTE `delivered`, затем идут три агрегатных
CTE и LEFT JOIN. `LATERAL` нет, повторных сканов одной таблицы нет.
`row_number()` используется только для выбора top-1 в группе (лучшее блюдо и
лучший клиент), где обычной агрегации недостаточно.

Вердикт: OK.

---

## I. Очистка и повторная генерация

### I.1. `erase_test_data` очищает всё

Ожидается: все 0.

Факт: после `CALL erase_test_data()` все 12 таблиц содержат 0 строк
(проверены `client`, `courier`, `product_category`, `restaurant`, `address`,
`product`, `"order"`, `review`, `payment`, `order_structure`,
`client_address`, `courier_pay`).

Вердикт: OK.

### I.2. Повторный `erase_test_data` не падает

Ожидается: без ошибок.

Факт: повторный `CALL erase_test_data()` выполнен без ошибок
(`TRUNCATE ... CASCADE` идемпотентен).

Вердикт: OK.

### I.3. После очистки `insert_test_data` снова работает

Ожидается: 50.

Факт: `CALL insert_test_data(10)` → `count(*) FROM "order" = 50`; клиентов 10,
платежей 50, отзывов 50, `courier_pay` 60.

Вердикт: OK.

---

## Итог

| Раздел | Результат |
|---|---|
| A. Подготовка / восстановление бэкапа | OK |
| B. FOOD-101 структура | OK |
| C. FOOD-102/103 генерация и очистка | OK |
| D. Бизнес-правила на данных | OK |
| E. FOOD-104/105/106/107 | OK |
| F. FOOD-108 `how_much_money` | OK |
| G. FOOD-109 `inspector` | OK |
| H. BR-11.8 оптимизация | OK |
| I. Повторная генерация | OK |

Бэкап: `db/foodexpress_prudko.backup` (custom format, схема `prudko_food`,
`--no-owner --no-privileges`), восстановление проверено на чистой базе
`foodexpress_restore` с последующим `grants.sql` и полным прогоном проверок
под `inspector`.
