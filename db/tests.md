# Протокол самопроверки

Все проверки выполнены реально, под ролью `inspector`, на PostgreSQL 18.4.
Основная база — `foodexpress_v2`; протокол восстановления отдельно прогнан на
чистой базе `foodexpress_restore`, собранной из итогового бэкапа.

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | `PostgreSQL 18.4 (Debian 18.4-1.pgdg12+1) on x86_64-pc-linux-gnu` |
| Дата проверки | 2026-11-13 |
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
(12 таблиц, 8 enum-типов, 16 FK, функции, процедуры, представление и данные);
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

Факт: все 12 таблиц присутствуют. Нормализация не потребовала новых таблиц
(N = 0): составные атрибуты разложены на столбцы внутри существующих таблиц
(`restaurant.inn/ogrn/bank_account`, `courier.last_name/first_name/middle_name`).
`information_schema.tables` возвращает 13 строк, потому что включает
представление `how_much_money`; `pg_catalog.pg_tables` возвращает 12.

Последовательностей в схеме нет (`information_schema.sequences` — 0 строк).

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
SELECT length(password) AS len, count(*) FROM client GROUP BY 1;
```

Ожидается: `len = 32`, hex-строка.

Факт: все 10 клиентов имеют `length = 32`; `bad_password_md5 = 0` в
`acceptance_checks.sql`.

Вердикт: OK.

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.

Факт: `CALL` выполнен, все 12 таблиц пусты. Сбрасывать последовательности не
нужно: их в схеме нет.

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

`client_address` и `courier_pay` — необходимое количество для связности:
у каждого клиента 4 адреса (10 × 4 = 40), у каждого курьера 6 месяцев выплат
(10 × 6 = 60). Число позиций `order_structure` зависит от случайного
количества блюд в заказе (1–5 на заказ).

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

Факт: `empty_strings = 0`; `acceptance_checks.sql` проверяет обязательные
строковые поля `client` и подтверждает отсутствие пустых значений.

Вердикт: OK.

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) FROM "order" WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL
  OR description IS NULL;
```

Ожидается: 0.

Факт: `null_required = 0`.

Вердикт: OK.

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

Ожидается: `>= 1`.

Факт: `active_couriers = 7` в каноническом прогоне (в других прогонах — 6–8;
правило выполняется всегда, потому что первые четыре курьера получают все
четыре статуса, включая `'уволен'`).

Вердикт: OK.

### C.8. Все enum-значения встречаются

```sql
SELECT status, count(*) FROM courier GROUP BY 1;
SELECT status, count(*) FROM "order" GROUP BY 1;
SELECT status, count(*) FROM payment GROUP BY 1;
SELECT pay_status, count(*) FROM "order" GROUP BY 1;
```

Ожидается: все значения каждого типа присутствуют.

Факт (канонический прогон):

| Тип | Распределение |
|---|---|
| `courier.status` | `свободен 3`, `занят 3`, `на_доставке 1`, `уволен 3` |
| `order.status` | все 5 значений (около 70 % — `доставлен`) |
| `payment.status` | `успех 20`, `ошибка 20`, `в_обработке 10` |
| `order.pay_status` | `оплачен 20`, `ошибка 10`, `ожидает 20` |

Все три статуса оплаты заказа достижимы: у части заказов нет успешной попытки
(см. D.8).

Вердикт: OK.

### C.9. `courier_pay` консистентен с правилами (BR-10.2)

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
(`couriers_without_6_months = 0`), месяцы июнь–ноябрь 2026.

Вердикт: OK.

### C.10. Повторный вызов не ломает

```sql
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;
```

Ожидается: без ошибок, данные добавляются.

Факт: после 10 повторных вызовов без очистки — `client = 110`, `order = 550`,
`payment = 550`, `review = 550`, `courier_pay = 660`, ошибок нет. Генератор
аддитивен: каждый вызов добавляет `value` клиентов/курьеров/категорий/
ресторанов и `value * 5` адресов/блюд/заказов/отзывов/платежей. Уникальность
логинов, телефонов и кодов транзакций обеспечивается случайной генерацией с
повтором при коллизии (без последовательностей и счётчиков). После проверки
выполнены `erase_test_data()` и `insert_test_data(10)` — данные возвращены к
каноническому виду.

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

Факт: 0 (`total_lt_1000`). Дополнительно `min(order_amount) = 1018.80`, то есть
порог 1000 соблюдён и по сумме без комиссии.

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

### D.8. Успешная оплата и статусы BR-8.7

```sql
SELECT order_id, count(*) AS cnt
FROM payment WHERE status = 'успех'
GROUP BY order_id HAVING count(*) > 1;
```

Ожидается: пусто (двух успешных попыток быть не может).

Факт: пусто; `orders_multiple_success = 0`. При этом
`orders_without_success = 30` — это не ошибка: BR-8.7 допускает заказы с
ошибкой или попыткой в обработке, у которых успешной попытки ещё нет. Если
требовать успех у каждого заказа, статусы `'ошибка'` и `'ожидает'` становятся
недостижимыми (противоречие BR-8.1 и BR-8.7 разобрано в `constraints.md`,
п. 11.6). Официальный шаблон D.8 группирует только заказы с успешными
попытками и такого требования не содержит.

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

### D.15. Заказы не раньше найма курьера

```sql
SELECT count(*) FROM "order" o
JOIN courier c ON c.courier_id = o.courier_id
WHERE o.order_timestamp::date < c.hire_date;
```

Ожидается: 0.

Факт: 0. `hire_date` генерируется на 176–179 дней назад, а заказы — не старше
начала шестимесячного окна выплат.

Вердикт: OK.

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

Ожидается: `after = before + 1`.

Факт: `add_product success: 50 -> 51`; созданное блюдо затем удалено.

Вердикт: OK.

### E.2. `add_product` — падает на некорректных данных

Ожидается: ошибка с внятным сообщением.

Факт: проверены четыре случая:

| Случай | Сообщение |
|---|---|
| несуществующий ресторан | `Нельзя добавить блюдо: ресторан <uuid> или категория <uuid> не существуют (FK)` |
| несуществующая категория | то же сообщение (FK) |
| отрицательная цена | `Нельзя добавить блюдо: нарушено ограничение схемы (23514): ... chk_product_price` |
| `NULL` в описании | `Нельзя добавить блюдо: обязательное поле не заполнено (...)` |

Все ошибки пойманы ограничениями схемы; в процедуре нет ни одного `IF` с
предпроверками.

Вердикт: OK.

### E.3. `rating_change` — пересчитывает рейтинг

Ожидается: `rating` пересчитан.

Факт: после вставки трёх отзывов с оценками 3, 4, 5 —
`rating insert 3,4,5 = 4.00`.

Вердикт: OK.

### E.4. `rating_change` — удаление и изменение отзыва

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.

Факт: после удаления отзыва с оценкой 3 — `rating after delete one = 4.50`;
после удаления всех отзывов — `rating after delete all = NULL`. Также
проверены `UPDATE rating 2 → 5` (результат `4.50`) и смена
`entity_type`/`entity_id` (старый и новый объект пересчитаны, результат
`4.00`). Логика находится в теле `rating_change`, отдельного хелпера нет.

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
`total_lt_avg = 0`. Имена в строке случайные (генератор строит их по паттернам
samples §2), поэтому конкретные значения не приводятся.

Вердикт: OK.

### E.6. `courier_salary()`

Ожидается:

- `courier.coefficient` пересчитан для работающих (по BR-10.2).
- У уволенных — не изменился.
- `courier_pay` содержит запись за текущий месяц.

Факт: запись за текущий месяц есть у всех 10 курьеров
(`current_month_rows = 10`). Суммы совпадают с формулой
`coefficient_used × sum(commission)` (60/60 строк `courier_pay`). При малом
числе доставок коэффициент остаётся 0.10 у всех статусов — это корректно по
шкале BR-10.2 (0–150 доставок → 0.1). Отдельно в транзакции с `ROLLBACK`
уволенному выставлен коэффициент 0.30: после вызова `courier_salary()` он
остался 0.30, то есть BR-10.6 соблюдается.

Вердикт: OK.

### E.7. `courier_salary()` — повторный вызов

Ожидается: количество строк не изменилось, суммы и коэффициенты те же.

Факт: после двух вызовов подряд `changed_after_salary = 0`, число строк за
текущий месяц — 10. Реализовано через `INSERT ... ON CONFLICT (year, month,
courier_id) DO UPDATE`; `coalesce(cp.coefficient_used, c.coefficient)`
обеспечивает идемпотентность (см. `constraints.md`, п. 10.9).

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

Факт: `months = 6`, `first_month = 2026-06`, `last_month = 2026-11`; месяцы
идут непрерывно: `2026-06, 2026-07, 2026-08, 2026-09, 2026-10, 2026-11`.
Генератор создаёт заказы и выплаты в одном и том же шестимесячном окне,
поэтому каждый месяц отчёта имеет и заказы, и `courier_pay`.

Вердикт: OK.

### F.3. Месяцы без заказов присутствуют (BR-11.9)

Ожидается: если в какие-то месяцы заказов не было — они есть в результате.

Факт: проверено отдельно в транзакции с `ROLLBACK`: при удалении всех
доставленных заказов за `2026-09` строка `2026-09` осталась в представлении:

| year_month | sum_no_commission | sum_with_commission | commission | courier_pay | net_profit |
|---|---:|---:|---:|---:|---:|
| 2026-09 | 0 | 0 | 0 | 270.83 | -270.83 |

Непрерывная серия строится рекурсивным CTE `bounds`/`months`, а `base`
использует `LEFT JOIN`, поэтому месяц не выпадает.

Вердикт: OK.

### F.4. Корректность сумм

Ожидается:

- `commission = sum_with_commission - sum_no_commission`.
- `commission_diff = commission - prev_commission` (NULL для первого месяца).
- `net_profit = commission - courier_pay`.

Факт: `formula_mismatch = 0`. Пример канонического прогона:

| year_month | sum_no_commission | sum_with_commission | commission | prev_commission | commission_diff | courier_pay | net_profit |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2026-06 | 11665.78 | 12832.36 | 1166.58 | NULL | NULL | 116.65 | 1049.93 |
| 2026-07 | 9370.68 | 10307.76 | 937.08 | 1166.58 | -229.50 | 93.70 | 843.38 |

Суммы зависят от случайных тестовых данных; формулы проверяются на каждом
прогоне через `acceptance_checks.sql`.

Вердикт: OK.

---

## G. Права `inspector`

### G.1. Права на схему

Ожидается: `prudko_food`, `usage = true`, `create = true`.

Факт: `prudko_food | t | t`.

Вердикт: OK.

### G.2. Права на таблицы

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).

Факт: у всех 13 объектов (12 таблиц + представление) — полный набор:
`DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE`.

Вердикт: OK.

### G.3. `information_schema` читается под `inspector`

Ожидается: 12 + N (количество таблиц).

Факт: 13 (12 таблиц + представление `how_much_money`). Отдельный `GRANT` не
выдавался: права `PUBLIC` на `information_schema` не отозваны.

Вердикт: OK.

### G.4. `pg_catalog` читается под `inspector`

Ожидается: 12 + N.

Факт: 12 (только таблицы `prudko_food`). Права `PUBLIC` на `pg_catalog` не
отозваны.

Вердикт: OK.

### G.5. Все процедуры/функции и данные доступны под `inspector`

Ожидается: без `permission denied`.

Факт: под `inspector` успешно выполнены `erase_test_data()`,
`insert_test_data(10)`, `courier_salary()`, `add_product(...)`,
`get_statistic()`, `SELECT * FROM how_much_money`, а также позитивные и
негативные проверки ограничений (`constraint_checks.sql`,
`functional_checks.sql`). Ошибок прав нет. Прав на последовательности не
требуется: последовательностей в схеме нет.

Вердикт: OK.

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. `EXPLAIN ANALYZE` — паттерн «избыточные подзапросы»

Ожидается: два SubPlan, каждый — скан `"order"`.

Факт: два `SubPlan`, в каждом `Seq Scan on "order"` с фильтром по курьеру и
статусу; `loops = 10` (по числу курьеров), `Execution Time: 0.402 ms`.

Вердикт: OK (паттерн воспроизведён).

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

Ожидается: один `Hash Right Join` / `Hash Left Join`, один скан `"order"`.

Факт: `HashAggregate` → `Hash Right Join` → один `Seq Scan on "order"` +
`Seq Scan on courier`; `Execution Time: 0.211 ms` (меньше, чем 0.402 ms в H.1).

Вердикт: OK.

### H.3. Применить к `get_statistic`

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без
оконных функций там, где хватает агрегата.

Факт: `EXPLAIN ANALYZE SELECT * FROM get_statistic();` даёт
`Function Scan on get_statistic`, `Execution Time: 6.284 ms` — внутренний план
SQL-функции снаружи не раскрывается. В теле функции (`07_get_statistic.sql`):

- `"order"` сканируется один раз в материализованном CTE `delivered`;
- лучшие блюдо и клиент выбираются через `DISTINCT ON (restaurant_id)`, а не
  через `row_number()`; узла `WindowAgg` в плане нет;
- `random()` стоит только последним ключом сортировки и разрешает ничьи
  (требование FOOD-106);
- `LATERAL` и повторных сканов одной таблицы нет.

Сравнение старого и нового варианта на одном и том же наборе (три прогона,
медиана). Столбец «строк в CTE» — сколько строк `product_stats` / `client_stats`
попадает в соединение: у `row_number` это все группы, у `DISTINCT ON` — уже по
одной на ресторан.

| Набор | `row_number`: строк в CTE | `DISTINCT ON`: строк в CTE | `row_number`, время | `DISTINCT ON`, время |
|---|---|---:|---:|---:|
| `insert_test_data(10)`, 50 заказов | 50 / 28 | 10 / 10 | 1.63 ms | 1.59 ms |
| `insert_test_data(300)`, 1500 заказов | 1408 / 1064 | 300 / 300 | 14.86 ms | 13.22 ms |

На малом объёме разница во времени в пределах шума (сортировка доминирует). На
300 ресторанах новый вариант быстрее примерно на 11 %, а главное — из CTE в
соединение приходит по одной строке на ресторан вместо всех строк группы с
последующей фильтрацией `rn = 1` (1408 → 300 и 1064 → 300). Именно это и
требовалось в BR-11.8.

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
