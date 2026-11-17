# Обоснование ограничений

Схема: `prudko_food`. Ссылки — на `docs/company-rules.md`.

## Enum-типы

| Тип | Значения | BR |
|---|---|---|
| `restaurant_status` | `активен`, `неактивен` | BR-4.3 |
| `product_status` | `доступно`, `нет_в_наличии`, `архив` | BR-5.5 |
| `courier_status` | `свободен`, `занят`, `на_доставке`, `уволен` | BR-6.2 |
| `order_status` | `создан`, `готовится`, `в_доставке`, `доставлен`, `отменён` | BR-7.7 |
| `order_pay_status` | `ожидает`, `оплачен`, `ошибка` | BR-7.9 |
| `payment_status` | `успех`, `ошибка`, `в_обработке` | BR-8.2 |
| `payment_type` | `карта`, `наличные`, `безнал` | BR-8.2 |
| `review_entity_type` | `блюдо`, `ресторан`, `заказ` | BR-9.1 |

Enum вместо `varchar` — BR-11.5.

---

## Ловушки

### 1. `payment` — неполная сущность

Добавлены атрибуты BR-8.2: `payment_type`, `amount`, `transaction_code`,
`payment_timestamp`, `status`. Тип оплаты хранится в `payment`, потому что
BR-8.6 разрешает разные типы у попыток одного заказа. `transaction_code`
уникален (BR-8.3); данных карт нет (BR-8.5).

BR-8.1 («ровно одна успешная попытка») в БД выражен частичным уникальным
индексом `uq_payment_success_per_order (order_id) WHERE status = 'успех'`:
он запрещает две успешные попытки. Наличие успешной попытки и
`order.pay_status` ведёт бэкенд (BR-8.7); см. «Спорные места».

### 2. `order.address_id` — принадлежность клиенту (BR-7.4)

Составной FK `(client_id, address_id) → client_address (client_id, address_id)`
не даёт указать в заказе адрес, не привязанный к клиенту. Отдельный FK
`address_id → address` реализует связь `ADDRESS — ORDER` из ERD.

### 3. `order_structure` — один ресторан в заказе (BR-7.3)

BR-7.3 межтабличный: `CHECK` не читает другие таблицы, а FK не связывает
`order.restaurant_id` с `product.restaurant_id`. Проверку выполняет бэкенд,
который собирает заказ из меню одного ресторана. В БД остаются PK
`(order_id, product_id)` (BR-7.16) и FK на заказ и блюдо (BR-7.14).

### 4. `review` — полиморфизм (BR-9.1)

`entity_type` + `entity_id` — полиморфная ссылка, поэтому FK на цель
невозможен. Существование цели, `entity_id = order_id` для `'заказ'`,
принадлежность отзыва клиенту заказа и наличие объекта в заказе (BR-9.2)
проверяет бэкенд. В БД остаётся `UNIQUE (order_id, entity_type, entity_id)`
(BR-9.5), запрещающий дубли в рамках заказа.

---

## CHECK-ограничения

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| `restaurant` | `work_start`, `work_end` | `work_end > work_start` | BR-4.4 | закрытие позже открытия |
| `restaurant` | `rating` | `NULL` или `0..5` | BR-4.2 | диапазон рейтинга ресторана |
| `courier` | `coefficient` | `0.10..0.50` | BR-6.4 | диапазон коэффициента |
| `courier` | `dismissal_date` | `NULL` или `>= hire_date` | BR-6.3 | нельзя уволить до найма |
| `courier` | `status`, `dismissal_date` | `status <> 'уволен' OR dismissal_date IS NOT NULL` | BR-6.3 | уволенный обязан иметь дату |
| `courier_pay` | `month` | `1..12` | BR-10.2, BR-10.3 | календарный месяц выплаты |
| `courier_pay` | `amount` | `>= 0` | BR-10.4 | зарплата неотрицательна |
| `courier_pay` | `coefficient_used` | `0.10..0.50` | BR-6.4, BR-10.2 | применённый коэффициент |
| `product` | `price` | `>= 0` | BR-5.3 | цена неотрицательна |
| `product` | `rating` | `NULL` или `0..5` | BR-5.4 | диапазон рейтинга блюда |
| `order` | `total_amount` | `>= 1000` | BR-7.11, BR-1.8 | минимальная сумма заказа |
| `order` | `delivery_timestamp` | `>= order_timestamp` | BR-7.13 | доставка не раньше создания |
| `order` | `status`, `delivery_timestamp` | `status <> 'доставлен' OR delivery_timestamp IS NOT NULL` | BR-7.12 | у доставленного есть время |
| `order_structure` | `quantity` | `> 0` | BR-7.15 | количество положительно |
| `review` | `rating` | `1..5` | BR-9.4 | диапазон оценки |

BR-8.4 (сумма попытки равна `order.total_amount`) и BR-8.7 (`order.pay_status`
по попыткам) — межтабличные проверки бэкенда, см. «Граница с приложением».

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `client` | `login` | BR-2.2 | логин уникален |
| `client` | `phone_number` | BR-2.2 | телефон уникален |
| `restaurant` | `address_id` | BR-3.3 | у ресторана свой адрес |
| `payment` | `transaction_code` | BR-8.3 | внешний код транзакции уникален |
| `review` | `order_id`, `entity_type`, `entity_id` | BR-9.5 | один отзыв на объект в заказе |
| `client_address` | PK `(client_id, address_id)` | BR-2.5 | адрес не дублируется у клиента |
| `order_structure` | PK `(order_id, product_id)` | BR-7.16 | блюдо не дублируется в заказе |
| `courier_pay` | PK `(year, month, courier_id)` | BR-10.3 | одна выплата за месяц |
| `payment` | `(order_id) WHERE status = 'успех'` | BR-8.1 | не больше одной успешной попытки |

## FK-ограничения

| Таблица | Столбцы | → Таблица | BR | Обоснование |
|---|---|---|---|---|
| `client_address` | `client_id` | `client` | BR-2.4 | адрес принадлежит клиенту |
| `client_address` | `address_id` | `address` | BR-2.4 | адрес существует |
| `restaurant` | `address_id` | `address` | BR-3.3, BR-3.5 | адрес ресторана; `RESTRICT` сохраняет историю |
| `product` | `product_category_id` | `product_category` | BR-5.1, BR-5.7 | ровно одна категория |
| `product` | `restaurant_id` | `restaurant` | BR-5.1 | ровно один ресторан |
| `courier_pay` | `courier_id` | `courier` | BR-10.2 | выплата принадлежит курьеру |
| `order` | `courier_id` | `courier` | BR-7.5 | доставку выполняет курьер |
| `order` | `client_id` | `client` | BR-7.2 | заказ принадлежит клиенту |
| `order` | `restaurant_id` | `restaurant` | BR-7.2 | заказ относится к ресторану |
| `order` | `address_id` | `address` | BR-7.4 | адрес доставки существует |
| `order` | `client_id`, `address_id` | `client_address` | BR-7.4 | адрес — один из адресов клиента |
| `order_structure` | `order_id` | `order` | BR-7.14 | позиция принадлежит заказу |
| `order_structure` | `product_id` | `product` | BR-7.14 | позиция ссылается на блюдо |
| `payment` | `order_id` | `order` | BR-8.2 | попытка относится к заказу |
| `review` | `client_id` | `client` | BR-9.1, BR-9.2 | автор отзыва |
| `review` | `order_id` | `order` | BR-9.2 | отзыв привязан к заказу |

`ON DELETE CASCADE` — только у `client_address.client_id`, `order_structure`,
`payment` и `review` (дочерние строки заказа). Остальные FK — `RESTRICT`:
история заказов и адреса не удаляются (BR-3.5, BR-1.6).

## NOT NULL (только бизнес-обязательные)

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `order` | `order_amount`, `commission`, `total_amount` | BR-7.10 | три суммы заказа обязательны |
| `client` | `login`, `password`, `phone_number` | BR-2.1 | регистрация по этим полям |
| `courier` | `last_name`, `first_name`, `middle_name` | BR-6.1 | ФИО курьера |
| `product` | `product_name`, `price`, `description` | BR-5.2 | атрибуты блюда |
| `restaurant` | `inn`, `ogrn`, `bank_account` | BR-4.5 | реквизиты ресторана |
| `review` | `description`, `rating` | BR-9.3, BR-9.4 | текст и оценка отзыва |

Остальные `NOT NULL` — PK/FK и обязательные атрибуты ERD по BR-11.3.

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| `address` | `apartment_office` | BR-3.2 | у частного дома/входа квартиры нет |
| `order` | `delivery_timestamp` | BR-7.12 | заполняется при статусе `'доставлен'` |
| `courier` | `dismissal_date` | BR-6.3 | у работающего даты увольнения нет |
| `product` | `photo_url` | BR-5.6 | фотография необязательна |
| `review` | `photo_url` | BR-9.3 | фотография необязательна |
| `restaurant` | `rating` | BR-9.7 | нет отзывов — нет среднего |
| `product` | `rating` | BR-9.7 | нет отзывов — нет среднего |

## DEFAULT и GENERATED

| Таблица | Столбец | Что | BR |
|---|---|---|---|
| все суррогатные ключи | `*_id` | `DEFAULT exts.uuid_generate_v4()` | BR-11.1 |
| `order` | `order_timestamp` | `DEFAULT localtimestamp` | BR-7.1 |
| `payment` | `payment_timestamp` | `DEFAULT localtimestamp` | BR-8.2 |
| `review` | `review_timestamp` | `DEFAULT localtimestamp` | BR-9.3 |
| `restaurant` | `status` | `DEFAULT 'активен'` | BR-4.3 |
| `product` | `status` | `DEFAULT 'доступно'` | BR-5.5 |
| `courier` | `status` | `DEFAULT 'свободен'` | BR-6.2 |
| `courier` | `coefficient` | `DEFAULT 0.10` | BR-6.5 |
| `order` | `status` | `DEFAULT 'создан'` | BR-7.7 |
| `order` | `pay_status` | `DEFAULT 'ожидает'` | BR-7.9; далее заполняет бэкенд |
| `payment` | `status` | `DEFAULT 'в_обработке'` | BR-8.2 |
| `order` | `commission` | `GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED` | BR-1.4, BR-7.10 |
| `order` | `total_amount` | `GENERATED ALWAYS AS (round(order_amount + round(order_amount * 0.10, 2), 2)) STORED` | BR-7.10 |

## Нормализация (1НФ, 2НФ, 3НФ)

- **1НФ.** ФИО курьера разложено на `last_name`, `first_name`, `middle_name`
  (BR-6.1); реквизиты ресторана — на `inn`, `ogrn`, `bank_account` (BR-4.5).
  Повторяющихся групп нет: позиции — `order_structure`, адреса клиента —
  `client_address`, попытки оплаты — `payment`, отзывы — `review`.
- **2НФ.** Составные ключи есть только у `client_address`, `order_structure`
  и `courier_pay`; неключевые атрибуты зависят от полного ключа.
- **3НФ.** Транзитивных зависимостей нет. Осознанные денормализации:
  - `order.commission`, `order.total_amount` — `GENERATED`, рассинхронизация
    невозможна;
  - `order.order_amount` — снимок суммы позиций на момент заказа; меню может
    подорожать, история не должна меняться. Заполняет бэкенд;
  - `order.pay_status` — агрегат по `payment` (BR-8.7); заполняет бэкенд;
  - `payment.amount` — копия `order.total_amount` (BR-8.4); заполняет бэкенд;
  - `product.rating`, `restaurant.rating` — средние по отзывам (BR-9.6),
    поддерживает триггер `rating_change`;
  - `courier_pay.amount`, `courier_pay.coefficient_used` — исторический
    снимок выплаты (BR-10.2), не пересчитывается задним числом.

## Точность `numeric`

`numeric` выбран вместо `float`: деньги и рейтинги должны быть точными.
Ширина `order_amount` выведена из максимумов: 5 позиций (BR-7.14) ×
9 999.99 ₽ (`price`) × 9.999 (`quantity`) = 499 949.50 ₽.

| Таблица | Столбец | Тип | Почему |
|---|---|---|---|
| `product` | `price` | `numeric(6,2)` | до 9 999.99 ₽ за блюдо |
| `order_structure` | `quantity` | `numeric(4,3)` | до 9.999 порции/кг |
| `order` | `order_amount` | `numeric(8,2)` | до 999 999.99 ₽; максимум 499 949.50 ₽ по BR-7.14, BR-7.15 |
| `order` | `commission` | `numeric(7,2)` | 10% от `order_amount`, максимум 49 994.95 |
| `order` | `total_amount` | `numeric(8,2)` | `order_amount + commission`, максимум 549 944.45 |
| `payment` | `amount` | `numeric(8,2)` | равна `order.total_amount` (BR-8.4) |
| `courier_pay` | `amount` | `numeric(8,2)` | месячная выплата, до 999 999.99 |
| `product`, `restaurant` | `rating` | `numeric(3,2)` | среднее 0..5 с точностью 0.01 |
| `review` | `rating` | `numeric(2,1)` | оценка 1..5 с шагом 0.1 |
| `courier`, `courier_pay` | `coefficient`, `coefficient_used` | `numeric(3,2)` | 0.10..0.50 |

## Ключи и последовательности

Все PK — `uuid` с `DEFAULT exts.uuid_generate_v4()` (BR-11.1).
`SERIAL`, `IDENTITY` и последовательности не используются: объектов
`relkind = 'S'` в схеме нет.

## Процедуры и функции

| Объект | FOOD | Что делает |
|---|---|---|
| `erase_test_data()` | FOOD-103 | `TRUNCATE ... CASCADE`; объекты схемы не трогает |
| `insert_test_data(value)` | FOOD-102 | 1n/5n по BR-11.7; массивы ID, один проход, до 6 месяцев `courier_pay` |
| `add_product(...)` | FOOD-104 | один `INSERT`; целостность — ограничения `product` |
| `rating_change()` + `trg_rating_change` | FOOD-105 | `INSERT`/`UPDATE`/`DELETE` отзыва; `avg()`; нет отзывов — `NULL`; `'заказ'` не агрегируется |
| `get_statistic()` | FOOD-106 | только `'доставлен'`; один скан `"order"`; `DISTINCT ON`, `random()` — tie-break |
| `courier_salary()` | FOOD-107 | текущий месяц по `order_timestamp`; один скан; `LEFT JOIN`; идемпотентен |
| `how_much_money` | FOOD-108 | рекурсивный CTE месяцев, `LAG`, суммы и чистая прибыль |

`insert_test_data` не вызывает `courier_salary`, `add_product` и
`rating_change`. Рейтинги при вставке отзывов пересчитывает штатный триггер —
это работа схемы, а не вызов бизнес-процедуры из генератора.

`courier_salary` не падает при нуле доставок: `LEFT JOIN` даёт `amount = 0`,
коэффициент остаётся 0.10. Уволенным до текущего месяца запись не создаётся,
коэффициент на следующий месяц не назначается (BR-10.6). Повторный вызов
обновляет запись, а не дублирует её.

## Права `inspector`

`grants.sql` создаёт роль только если её нет; пароль существующей роли не
меняется. Если роль уже была создана с другим паролем, вход `psql -U inspector`
с `NetoSQL2025` не сработает — используйте `SET ROLE inspector` от суперпользователя
или задайте пароль роли вручную. Гранты выдаются после восстановления схемы,
когда объекты уже существуют, поэтому `ALTER DEFAULT PRIVILEGES` не нужен.
`ALL PRIVILEGES` включает `TRUNCATE` (для `erase_test_data`) и `UPDATE`
(для триггера `rating_change`). `USAGE` на `exts` нужен для
`uuid_generate_v4()`.

## Граница с приложением

BR-11.4 относит уникальность и непустоту к схеме; эти ограничения в БД есть.
На бэкенд/фронтенд вынесено то, что нельзя выразить `CHECK`/FK или что
описывает процесс:

| BR | Где проверяется | Почему не в БД |
|---|---|---|
| BR-2.1, BR-2.3 | фронтенд/бэкенд | формат логина и MD5-хеширование |
| BR-1.7, BR-8.5 | схема | столбцов для данных карт просто нет |
| BR-3.1 | фронтенд | формат адреса |
| BR-4.5 | фронтенд/бэкенд | формат ИНН/ОГРН/счёта; в БД `varchar(N)` |
| BR-5.6, BR-9.3 | фронтенд/бэкенд | формат URL; в БД `text` и `NULL` |
| BR-6.6 | `insert_test_data` | правило тестовых данных |
| BR-7.3 | бэкенд | межтабличная проверка при сборке заказа |
| BR-7.6 | бэкенд | граф переходов статусов в BR не задан |
| BR-7.14 | бэкенд | «минимум одна позиция» не выражается декларативно |
| BR-8.1 | БД + бэкенд | в БД — не больше одной успешной; наличие — бэкенд |
| BR-8.4 | бэкенд/генератор | сумма попытки равна сумме заказа |
| BR-8.7 | бэкенд/генератор | `pay_status` — агрегат по попыткам |
| BR-9.1, BR-9.2 | бэкенд | полиморфная цель и авторство отзыва |

`rating_change` оставлен триггером: этого прямо требует FOOD-105.

## Спорные места требований

- **BR-8.1 vs BR-8.7.** «Ровно одна успешная попытка» и статусы `'ошибка'`/
  `'ожидает'` несовместимы: заказ с единственной неуспешной попыткой имеет
  ноль успешных. При фиксированном BR-11.7 (`payment = value * 5`) на заказ
  приходится ровно одна попытка, поэтому выбрать оба правила нельзя.
  В БД запрещено больше одной успешной; `pay_status` считается по фактической
  попытке; наличие успешной у оплаченного заказа контролирует бэкенд.
- **BR-7.14.** «Одна или несколько позиций» декларативно не выражается.
  Генератор всегда создаёт 1–5 позиций; ручной заказ без позиций возможен,
  проверка — на бэкенде.
- **BR-13.1.** `order` не переименован, а взят в кавычки — `"order"`.
