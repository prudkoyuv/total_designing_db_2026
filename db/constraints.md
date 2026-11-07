# Обоснование ограничений

Схема: `prudko_food`. Все ссылки на бизнес-правила — по `docs/company-rules.md`.

## Enum-типы

| Тип | Значения | BR |
|---|---|---|
| `restaurant_status` | `'активен'`, `'неактивен'` | BR-4.3 |
| `product_status` | `'доступно'`, `'нет_в_наличии'`, `'архив'` | BR-5.5 |
| `courier_status` | `'свободен'`, `'занят'`, `'на_доставке'`, `'уволен'` | BR-6.2 |
| `order_status` | `'создан'`, `'готовится'`, `'в_доставке'`, `'доставлен'`, `'отменён'` | BR-7.7 |
| `order_pay_status` | `'ожидает'`, `'оплачен'`, `'ошибка'` | BR-7.9 |
| `payment_status` | `'успех'`, `'ошибка'`, `'в_обработке'` | BR-8.2 |
| `payment_type` | `'карта'`, `'наличные'`, `'безнал'` | BR-8.2, BR-8.6 |
| `review_entity_type` | `'блюдо'`, `'ресторан'`, `'заказ'` | BR-9.1 |

Значения не менялись относительно BR. Реализованы через `CREATE TYPE ... AS ENUM`, как требует BR-11.5 (а не `varchar`).

---

## Ловушки

### Ловушка 1: `payment` — неполная сущность

**Какие атрибуты добавил в `payment` и почему** (BR-8.2):

```
payment_id        uuid PK, DEFAULT exts.uuid_generate_v4()  — BR-11.1
order_id          uuid NOT NULL FK -> "order"               — BR-8.1: попытка относится к заказу
payment_type      payment_type NOT NULL                     — BR-8.2: тип оплаты
amount            numeric(12,2) NOT NULL                    — BR-8.2: сумма
transaction_code  varchar(100) NOT NULL UNIQUE              — BR-8.2, BR-8.3: внешний идентификатор
payment_timestamp timestamp NOT NULL DEFAULT localtimestamp — BR-8.2, BR-11.2: дата/время попытки
status            payment_status NOT NULL DEFAULT 'в_обработке' — BR-8.2: статус попытки
```

**Где хранится тип оплаты — `payment` или `order`** (BR-8.6):

```
В payment. BR-8.6 прямо говорит, что тип относится к попытке, а не к заказу:
у одного заказа может быть несколько попыток с разными типами. Если положить
тип в order, то нельзя выразить сценарий «карта не прошла — оплатил наличными».
```

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

**Как обеспечено, что адрес доставки принадлежит клиенту:**

```
Составной FK:
    FOREIGN KEY (client_id, address_id)
        REFERENCES client_address (client_id, address_id)
        ON DELETE RESTRICT

Он гарантирует, что пара (клиент, адрес) присутствует в client_address, то есть
адрес действительно привязан именно к этому клиенту. Отдельный FK
order.address_id -> address(address_id) оставлен дополнительно: он повторяет
связь из ERD и даёт явную ссылочную целостность на address.
```

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

**Как обеспечено, что все блюда из `order.restaurant_id`:**

```
Два триггера в 04_create_triggers.sql:

1. trg_order_structure_restaurant (BEFORE INSERT OR UPDATE ON order_structure)
   сравнивает product.restaurant_id блюда с "order".restaurant_id заказа и
   выбрасывает исключение при несовпадении. Это закрывает добавление/изменение
   позиции.
2. trg_order_restaurant_update (BEFORE UPDATE OF restaurant_id ON "order")
   не даёт сменить ресторан заказа, если в нём уже есть блюда другого
   ресторана. Без него ограничение обходилось бы сменой restaurant_id у заказа.

Проверить это декларативно (CHECK/FK) нельзя: сравнение идёт через две таблицы.
```

### Ловушка 4: `review` — полиморфизм (BR-9.1)

**Как реализована валидность `review.entity_id`:**

```
Гибрид: полиморфная пара entity_type + entity_id плюс проверяющий триггер
trg_review_entity_validate (BEFORE INSERT OR UPDATE ON review).

- entity_type = 'блюдо'    -> entity_id обязан существовать в product;
- entity_type = 'ресторан' -> entity_id обязан существовать в restaurant;
- entity_type = 'заказ'    -> entity_id обязан совпадать с order_id.

FK на entity_id не ставится: целевая таблица зависит от значения entity_type,
а PostgreSQL не поддерживает полиморфные FK. Нормализация в три отдельные
таблицы (product_review, restaurant_review, order_review) усложнила бы
выборку отзывов и не дала бы выигрыша: общих атрибутов у отзывов больше, чем
различий. Поэтому выбран полиморфизм с триггером.

Что осознанно не проверяется на уровне БД: BR-9.2 в части «клиент может
оставить отзыв только на то, что он заказал». Для этого пришлось бы
соединять review с order_structure и запрещать отзыв на ресторан/заказ по
произвольному заказу; официальный тест E.3 вставляет отзыв от произвольного
клиента на произвольный заказ, поэтому полная проверка оставлена приложению.
BR-9.5 (не более одного отзыва на объект в заказе) обеспечен UNIQUE.
```

---

## CHECK-ограничения

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| `client` | `login` | `length(trim(login)) > 0` | BR-2.1, BR-11.3 | BR-2.1 требует логин; пустая строка — не логин, BR-11.3 запрещает пустые значения. |
| `client` | `password` | `password ~ '^[0-9a-f]{32}$'` | BR-2.3 | BR-2.3 требует хранить MD5; ровно 32 hex-символа — это и есть MD5. |
| `client` | `phone_number` | `length(trim(phone_number)) > 0` | BR-2.1, BR-11.3 | Телефон обязателен по BR-2.1, пустая строка недопустима по BR-11.3. |
| `address` | `street` | `length(trim(street)) > 0` | BR-3.1, BR-11.3 | Адрес описывается улицей (BR-3.1); пустая улица бессмысленна и запрещена BR-11.3. |
| `address` | `house_number` | `length(trim(house_number)) > 0` | BR-3.1, BR-11.3 | Номер дома — часть адреса по BR-3.1; пустое значение запрещено BR-11.3. |
| `address` | `apartment_office` | `IS NULL OR length(trim(...)) > 0` | BR-3.2, BR-11.3 | Квартира/офис может отсутствовать (BR-3.2), но если указана — не пустая (BR-11.3). |
| `restaurant` | `restaurant_name` | `length(trim(...)) > 0` | BR-4.1, BR-11.3 | Название входит в обязательные атрибуты ресторана (BR-4.1). |
| `restaurant` | `description` | `length(trim(...)) > 0` | BR-4.1, BR-11.3 | Описание входит в обязательные атрибуты ресторана (BR-4.1). |
| `restaurant` | `company_details` | `length(trim(...)) > 0` | BR-4.1, BR-4.5 | Реквизиты обязательны (BR-4.1) и не могут быть пустыми (BR-4.5, BR-11.3). |
| `restaurant` | `work_end` | `work_end > work_start` | BR-4.4 | BR-4.4: время закрытия позже времени открытия. |
| `restaurant` | `rating` | `IS NULL OR rating BETWEEN 0 AND 5` | BR-4.2, BR-9.7 | BR-4.2 задаёт диапазон 0..5; NULL допустим, пока нет отзывов (BR-9.7). |
| `courier` | `fio` | `length(trim(fio)) > 0` | BR-6.1, BR-11.3 | ФИО — обязательный атрибут курьера (BR-6.1). |
| `courier` | `phone_number` | `length(trim(...)) > 0` | BR-6.1, BR-11.3 | Телефон — обязательный атрибут курьера (BR-6.1). |
| `courier` | `coefficient` | `coefficient BETWEEN 0.10 AND 0.50` | BR-6.4 | BR-6.4 задаёт диапазон коэффициента 0.1..0.5 включительно. |
| `courier` | `dismissal_date` | `IS NULL OR dismissal_date >= hire_date` | BR-6.3 | Увольнение не может быть раньше найма (BR-6.3). |
| `courier` | `status` + `dismissal_date` | `status <> 'уволен' OR dismissal_date IS NOT NULL` | BR-6.3 | BR-6.3: уволенный курьер обязан иметь дату увольнения. |
| `courier_pay` | `month` | `month BETWEEN 1 AND 12` | BR-10.1, BR-10.3 | Выплата месячная (BR-10.1), месяц — календарный 1..12; одна запись на месяц (BR-10.3). |
| `courier_pay` | `amount` | `amount >= 0` | BR-10.4 | BR-10.4: сумма зарплаты неотрицательна. |
| `courier_pay` | `coefficient_used` | `BETWEEN 0.10 AND 0.50` | BR-6.4, BR-10.2 | Применённый коэффициент — тот же коэффициент курьера, ограниченный BR-6.4. |
| `product_category` | `product_category_name` | `length(trim(...)) > 0` | BR-5.7, BR-11.3 | Категория — справочник с названием (BR-5.7); пустое название недопустимо. |
| `product` | `product_name` | `length(trim(...)) > 0` | BR-5.2, BR-11.3 | Название входит в обязательные атрибуты блюда (BR-5.2). |
| `product` | `description` | `length(trim(...)) > 0` | BR-5.2, BR-11.3 | Описание входит в обязательные атрибуты блюда (BR-5.2). |
| `product` | `price` | `price >= 0` | BR-5.3 | BR-5.3: цена блюда неотрицательна. |
| `product` | `rating` | `IS NULL OR rating BETWEEN 0 AND 5` | BR-5.4, BR-9.7 | BR-5.4 задаёт диапазон 0..5; NULL допустим, пока нет отзывов (BR-9.7). |
| `order` | `order_amount` | `order_amount >= 0` | BR-5.3, BR-7.10 | Сумма без комиссии складывается из неотрицательных цен блюд (BR-5.3, BR-7.10). |
| `order` | `total_amount` | `total_amount >= 1000` | BR-7.11 | BR-7.11: общая сумма заказа не менее 1000 ₽. В шаблоне `templates/constraints.md` пример ссылается на BR-7.9, но в актуальных BR минимальная сумма — BR-7.11 (BR-7.9 — статус оплаты). |
| `order` | `delivery_timestamp` | `IS NULL OR delivery_timestamp >= order_timestamp` | BR-7.13 | BR-7.13: время окончания доставки не раньше времени создания. |
| `order` | `status` + `delivery_timestamp` | `status <> 'доставлен' OR delivery_timestamp IS NOT NULL` | BR-7.12 | BR-7.12: при статусе «доставлен» время окончания доставки заполняется. |
| `order` | `description` | `IS NULL OR length(trim(...)) > 0` | BR-11.3 | Свободный комментарий из ERD; если он есть, пустая строка недопустима (BR-11.3). |
| `order_structure` | `quantity` | `quantity > 0` | BR-7.15 | BR-7.15: количество — положительное число. |
| `payment` | `amount` | `amount >= 0` | BR-8.2, BR-8.4 | Сумма попытки неотрицательна и равна сумме заказа (BR-8.4). |
| `payment` | `transaction_code` | `length(trim(...)) > 0` | BR-8.3, BR-11.3 | Внешний идентификатор транзакции обязателен (BR-8.3), пустым быть не может. |
| `review` | `description` | `length(trim(...)) > 0` | BR-9.3, BR-11.3 | Текст отзыва обязателен (BR-9.3); пустой текст недопустим. |
| `review` | `rating` | `rating BETWEEN 1 AND 5` | BR-9.4 | BR-9.4: рейтинг отзыва от 1 до 5. |

Дополнительно BR-8.4 (сумма оплаты равна `order.total_amount`) и BR-8.7
(агрегированный `order.pay_status` по попыткам) реализованы триггерами
`trg_payment_amount_check` и `trg_payment_pay_status`: это межтабличные
зависимости, для них CHECK недостаточно.

---

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `client` | `login` | BR-2.2 | BR-2.2: логин уникален. |
| `client` | `phone_number` | BR-2.2 | BR-2.2: телефон уникален. |
| `address` | `(street, house_number, apartment_office)` `NULLS NOT DISTINCT` | BR-3.1, BR-3.4, BR-3.5 | Один физический адрес должен быть одной строкой, чтобы разные клиенты могли использовать его совместно (BR-3.4), а история заказов не терялась (BR-3.5). `NULLS NOT DISTINCT` не даёт завести два одинаковых адреса без квартиры. |
| `client_address` | `(client_id, address_id)` (PK) | BR-2.5 | BR-2.5: один и тот же адрес нельзя привязать к клиенту дважды. |
| `restaurant` | `address_id` | BR-3.3, BR-3.4 | BR-3.3: два ресторана не могут делить один адрес; BR-3.4: адрес ресторана используется только одним рестораном. |
| `order_structure` | `(order_id, product_id)` (PK) | BR-7.16 | BR-7.16: одно блюдо не может встречаться в заказе дважды. |
| `payment` | `transaction_code` | BR-8.3 | BR-8.3: идентификатор финансовой транзакции уникален. |
| `payment` | `(order_id) WHERE status = 'успех'` (частичный UNIQUE INDEX) | BR-8.1 | BR-8.1: успешная попытка у заказа ровно одна. Частичный индекс ограничивает только успешные строки, не мешая нескольким неудачным попыткам. |
| `review` | `(order_id, entity_type, entity_id)` | BR-9.5 | BR-9.5: в рамках заказа — не более одного отзыва на каждый объект. |
| `courier_pay` | `(year, month, courier_id)` (PK) | BR-10.3 | BR-10.3: за один месяц у курьера ровно одна запись. |

---

## FK-ограничения

| Таблица | Столбцы | → Таблица | BR | Обоснование |
|---|---|---|---|---|
| `client_address` | `client_id` | `client(client_id)` | BR-2.4 | Связь M:N должна ссылаться на существующего клиента. |
| `client_address` | `address_id` | `address(address_id)` | BR-2.4 | Связь M:N должна ссылаться на существующий адрес. |
| `restaurant` | `address_id` | `address(address_id)` | BR-3.3, BR-3.4 | У ресторана ровно один существующий адрес. |
| `product` | `product_category_id` | `product_category(product_category_id)` | BR-5.1, BR-5.7 | Блюдо принадлежит ровно одной категории из справочника. |
| `product` | `restaurant_id` | `restaurant(restaurant_id)` | BR-5.1 | Блюдо принадлежит ровно одному ресторану. |
| `courier_pay` | `courier_id` | `courier(courier_id)` | BR-10.2, BR-10.3 | Выплата относится к существующему курьеру. |
| `order` | `courier_id` | `courier(courier_id)` | BR-7.5 | Доставку выполняет существующий курьер. |
| `order` | `client_id` | `client(client_id)` | BR-7.2 | Заказ привязан к существующему клиенту. |
| `order` | `restaurant_id` | `restaurant(restaurant_id)` | BR-7.2 | Заказ привязан к существующему ресторану. |
| `order` | `address_id` | `address(address_id)` | BR-7.4 | Адрес доставки должен существовать. |
| `order` | `(client_id, address_id)` | `client_address(client_id, address_id)` | BR-7.4 | Адрес доставки — один из адресов именно этого клиента. Составной FK. |
| `order_structure` | `order_id` | `"order"(order_id)` | BR-7.14 | Позиция принадлежит существующему заказу. |
| `order_structure` | `product_id` | `product(product_id)` | BR-7.14 | Позиция ссылается на существующее блюдо. |
| `payment` | `order_id` | `"order"(order_id)` | BR-8.1 | Попытка оплаты относится к существующему заказу. |
| `review` | `client_id` | `client(client_id)` | BR-9.1 | Автор отзыва — существующий клиент. |
| `review` | `order_id` | `"order"(order_id)` | BR-9.2 | Отзыв всегда связан с конкретным заказом. |

Всего 16 FK. `ON DELETE CASCADE` стоит только у зависимых «слабых» сущностей
(`client_address` от клиента, `order_structure` и `payment` от заказа,
`review` от заказа). Остальные — `RESTRICT`, чтобы не терять историю заказов
(BR-3.5) и не оставлять финансовые документы без родителя.

---

## NOT NULL (только бизнес-обязательные)

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| `restaurant` | `work_start`, `work_end` | BR-4.4 | График работы — обязательная часть ресторана; без обоих времён нельзя проверить BR-4.4. |
| `restaurant` | `company_details` | BR-4.1, BR-4.5 | Реквизиты обязательны, даже если меняются без истории. |
| `courier` | `hire_date` | BR-6.1, BR-6.3 | Дата найма нужна, чтобы проверить, что увольнение позже найма (BR-6.3). |
| `product` | `description` | BR-5.2 | Описание перечислено среди обязательных атрибутов блюда. |
| `order` | `order_amount` | BR-7.10 | Сумма без комиссии — обязательная составляющая расчёта. |
| `order` | `order_timestamp` | BR-7.1 | У заказа обязательна дата/время создания. |
| `order_structure` | `quantity` | BR-7.14, BR-7.15 | Позиция без количества не имеет смысла; количество положительное. |
| `payment` | `transaction_code` | BR-8.2, BR-8.3 | Идентификатор транзакции — обязательный атрибут попытки оплаты. |
| `review` | `order_id` | BR-9.2 | Отзыв всегда связан с заказом; это не выводится из других FK. |
| `review` | `entity_type`, `entity_id` | BR-9.1 | Без них отзыв не привязан к объекту оценивания. |

Остальные `NOT NULL` — это PK и FK на обязательные родительские поля; их
перечисление было бы дублированием.

---

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| `address` | `apartment_office` | BR-3.2 | Квартира/офис может отсутствовать у частного дома или отдельного входа. |
| `restaurant` | `rating` | BR-9.7 | Пока нет отзывов, агрегированный рейтинг равен NULL. |
| `product` | `rating` | BR-9.7 | Пока нет отзывов, агрегированный рейтинг равен NULL. |
| `product` | `photo_url` | BR-5.6 | Фотография блюда необязательна. |
| `courier` | `dismissal_date` | BR-6.3 | У работающего курьера даты увольнения нет. |
| `order` | `delivery_timestamp` | BR-7.12 | Заполняется только при статусе «доставлен». |
| `order` | `description` | ERD (`order.description`) | Свободный комментарий к заказу; BR-7 его не требует, поэтому отсутствие комментария допустимо. |
| `review` | `photo_url` | BR-9.3 | Фотография в отзыве необязательна. |

---

## DEFAULT и GENERATED

| Таблица | Столбец | Что | Обоснование |
|---|---|---|---|
| все таблицы | `*_id` | `DEFAULT exts.uuid_generate_v4()` | BR-11.1: все ID — UUID, генерируются на сервере через `exts.uuid_generate_v4()`. |
| `order` | `order_timestamp` | `DEFAULT localtimestamp` | BR-7.1, BR-11.2: время создания фиксируется в часовом поясе сервера. |
| `payment` | `payment_timestamp` | `DEFAULT localtimestamp` | BR-8.2, BR-11.2: дата/время попытки оплаты. |
| `review` | `review_timestamp` | `DEFAULT localtimestamp` | BR-9.3, BR-11.2: дата отзыва. |
| `restaurant` | `status` | `DEFAULT 'активен'` | BR-4.3: новый ресторан по умолчанию активен. |
| `product` | `status` | `DEFAULT 'доступно'` | BR-5.5: новое блюдо по умолчанию доступно. |
| `courier` | `status` | `DEFAULT 'свободен'` | BR-6.2: новый курьер свободен. |
| `courier` | `coefficient` | `DEFAULT 0.10` | BR-6.5: изначальный коэффициент нового курьера — 0.1. |
| `order` | `status` | `DEFAULT 'создан'` | BR-7.7: заказ начинается со статуса «создан». |
| `order` | `pay_status` | `DEFAULT 'ожидает'` | BR-7.9, BR-8.7: до успешной оплаты статус «ожидает». |
| `payment` | `status` | `DEFAULT 'в_обработке'` | BR-8.2: новая попытка начинается в обработке. |
| `order` | `commission` | `GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED` | BR-1.4, BR-7.10: комиссия — ровно 10% от суммы без комиссии; вычисляется БД, чтобы её нельзя было рассинхронизировать. |
| `order` | `total_amount` | `GENERATED ALWAYS AS (round(order_amount + round(order_amount * 0.10, 2), 2)) STORED` | BR-7.10: общая сумма = сумма без комиссии + комиссия. Вычисляется из тех же данных, поэтому не может разойтись. `CHECK (total_amount >= 1000)` проверяет BR-7.11 уже после вычисления. |

`quantity numeric(10,3)` — не DEFAULT, а выбор точности: BR-7.15 разрешает
дробное количество (например, 0.5 кг), поэтому целый тип не подходит.

---

## Нормализация (3НФ)

```
Все таблицы приведены к 3НФ.

1НФ: все атрибуты атомарны. Адрес разложен на street / house_number /
apartment_office, а не хранится одной строкой. Списки блюд вынесены в
order_structure, адреса клиентов — в client_address.

2НФ: во всех таблицах с составным PK (client_address, order_structure,
courier_pay) неключевые атрибуты зависят от полного PK. В client_address
неключевых атрибутов нет; в order_structure quantity зависит от пары
(order_id, product_id); в courier_pay amount и coefficient_used зависят от
года, месяца и курьера.

3НФ: транзитивных зависимостей нет. Ни один неключевой атрибут не определяет
другой неключевой атрибут.

Особые случаи:
- order.commission и order.total_amount — вычисляемые. Хранятся как
  GENERATED STORED, а не как обычные поля: это осознанная денормализация,
  чтобы не считать 10% в каждом отчёте и исключить рассогласование.
- product.rating и restaurant.rating — агрегаты по review. Это осознанная
  денормализация для быстрого чтения: рейтинг пересчитывается триггером
  rating_change при любом INSERT/UPDATE/DELETE отзыва (BR-9.6, BR-9.7).
- review.entity_type + review.entity_id — полиморфная ссылка. Она не нарушает
  3НФ (это не транзитивная зависимость, а дискриминируемая ссылка), но
  требует триггерной проверки; обоснование — в ловушке 4.
- order.pay_status — агрегированный статус по payment. Хранится в order,
  потому что BR-7.8 прямо требует атрибут у заказа; поддерживается триггером
  payment_pay_status_change (BR-8.7).
- courier.coefficient — текущий коэффициент, а courier_pay.coefficient_used —
  исторический снимок применённого коэффициента. Это не дублирование:
  BR-10.2 требует хранить применённый коэффициент в выплате, а BR-6.4 —
  текущий коэффициент у курьера.
```
