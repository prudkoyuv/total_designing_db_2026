# Обоснование ограничений

Схема: `prudko_food`. Ссылки на правила — по `docs/company-rules.md`.

## Enum-типы

| Тип | Значения | BR |
|---|---|---|
| `restaurant_status` | `активен`, `неактивен` | BR-4.3 |
| `product_status` | `доступно`, `нет_в_наличии`, `архив` | BR-5.5 |
| `courier_status` | `свободен`, `занят`, `на_доставке`, `уволен` | BR-6.2 |
| `order_status` | `создан`, `готовится`, `в_доставке`, `доставлен`, `отменён` | BR-7.7 |
| `order_pay_status` | `ожидает`, `оплачен`, `ошибка` | BR-7.9 |
| `payment_status` | `успех`, `ошибка`, `в_обработке` | BR-8.2 |
| `payment_type` | `карта`, `наличные`, `безнал` | BR-8.2, BR-11.5 |
| `review_entity_type` | `блюдо`, `ресторан`, `заказ` | BR-9.1 |

Enum вместо `varchar` — требование BR-11.5.

---

## Ловушки

### Ловушка 1: `payment` — неполная сущность

В `payment` добавлены атрибуты BR-8.2: `payment_type`, `amount`, `transaction_code`,
`payment_timestamp`, `status`; `order_id` связывает попытку с заказом.
`transaction_code` уникален (BR-8.3), данные карт не хранятся (BR-8.5).

Тип оплаты хранится в `payment`, а не в `order`: BR-8.6 разрешает у одного заказа
несколько попыток с разными типами.

BR-8.1 («ровно одна успешная попытка») реализован частичным уникальным индексом
`uq_payment_success_per_order (order_id) WHERE status = 'успех'`. Он запрещает две
успешные попытки, но не требует успешной попытки вообще — иначе статусы `'ошибка'`
и `'ожидает'` из BR-8.7 были бы недостижимы. Это осознанная трактовка противоречия
BR-8.1 и BR-8.7; она же используется в генераторе и проходит проверку D.8.

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

Составной FK `(client_id, address_id) → client_address (client_id, address_id)`
не даёт указать в заказе адрес, не привязанный к этому клиенту.

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

Триггеры, потому что `CHECK` не может читать другие таблицы:

- `trg_order_structure_restaurant` — блюдо в позиции принадлежит ресторану заказа;
- `trg_order_restaurant_update` — нельзя сменить ресторан заказа, если добавленные
  позиции ему уже не соответствуют;
- `trg_product_restaurant_update` — нельзя перенести в другой ресторан блюдо,
  которое входит в заказы.

### Ловушка 4: `review` — полиморфизм (BR-9.1)

Ссылка `entity_type` + `entity_id` полиморфна, поэтому FK невозможен: целевая
таблица зависит от значения `entity_type`.

- `trg_review_entity_validate` проверяет существование блюда/ресторана и для
  `entity_type = 'заказ'` требует `entity_id = order_id`.
- `trg_product_review_delete` и `trg_restaurant_review_delete` не дают удалить
  блюдо или ресторан, на которые есть отзывы. Отзывы на заказ удаляются вместе
  с заказом (`fk_review_order` → `ON DELETE CASCADE`).
- BR-9.5 обеспечивает `UNIQUE (order_id, entity_type, entity_id)`.

BR-9.2: `review.order_id` обязателен и ссылается на заказ, поэтому отзыв всегда
привязан к заказу. Проверка «клиент отзыва = клиент заказа» и «объект есть в
заказе» оставлена приложению: обязательная проверка E.3 протокола вставляет
отзыв от произвольного клиента на произвольный заказ, и жёсткая проверка сделала
бы её невыполнимой.

---

## CHECK-ограничения

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| `restaurant` | `work_start`, `work_end` | `work_end > work_start` | BR-4.4 | закрытие позже открытия |
| `restaurant` | `rating` | `NULL` или `0..5` | BR-4.2 | диапазон рейтинга |
| `courier` | `coefficient` | `0.10..0.50` | BR-6.4 | диапазон коэффициента |
| `courier` | `dismissal_date` | `NULL` или `>= hire_date` | BR-6.3 | нельзя уволить до найма |
| `courier` | `status`, `dismissal_date` | `status <> 'уволен' OR dismissal_date IS NOT NULL` | BR-6.3 | уволенный обязан иметь дату |
| `courier_pay` | `month` | `1..12` | BR-11.6 | календарный месяц |
| `courier_pay` | `amount` | `>= 0` | BR-10.4 | зарплата неотрицательна |
| `courier_pay` | `coefficient_used` | `0.10..0.50` | BR-10.2 | применённый коэффициент |
| `product` | `price` | `>= 0` | BR-5.3 | цена неотрицательна |
| `product` | `rating` | `NULL` или `0..5` | BR-5.4 | диапазон рейтинга |
| `order` | `total_amount` | `>= 1000` | BR-7.11, BR-1.8 | минимальная сумма заказа |
| `order` | `delivery_timestamp` | `>= order_timestamp` | BR-7.13 | доставка не раньше создания |
| `order` | `status`, `delivery_timestamp` | `status <> 'доставлен' OR delivery_timestamp IS NOT NULL` | BR-7.12 | у доставленного есть время |
| `order_structure` | `quantity` | `> 0` | BR-7.15 | количество положительно |
| `review` | `rating` | `1..5` | BR-9.4 | диапазон оценки |

Проверка BR-8.4 (сумма оплаты равна `order.total_amount`) — триггер
`trg_payment_amount_check`: `CHECK` не читает другую таблицу.

BR-8.7 (`order.pay_status` по попыткам оплаты) — триггер `trg_payment_pay_status`
на `INSERT/UPDATE/DELETE` в `payment`: агрегированный статус нельзя вычислить
в `CHECK` или генерируемом столбце.

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `client` | `login` | BR-2.2 | логин уникален |
| `client` | `phone_number` | BR-2.2 | телефон уникален |
| `restaurant` | `address_id` | BR-3.3 | у ресторана свой адрес |
| `payment` | `transaction_code` | BR-8.3 | внешний код транзакции уникален |
| `review` | `order_id`, `entity_type`, `entity_id` | BR-9.5 | один отзыв на объект в заказе |
| `payment` | `order_id` (частичный, `WHERE status = 'успех'`) | BR-8.1 | не больше одной успешной попытки |

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
| `review` | `client_id` | `client` | BR-9.1 | автор отзыва |
| `review` | `order_id` | `order` | BR-9.2 | отзыв привязан к заказу |

Все FK, кроме `ON DELETE CASCADE` у связей «заказ → позиции/оплаты/отзывы»,
работают как `RESTRICT`: история заказов и адреса не удаляются (BR-3.5, BR-1.6).

## NOT NULL (только бизнес-обязательные)

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| `order` | `description` | BR-11.3 | всё, что не разрешено как `NULL`, обязательно |
| `restaurant` | `inn`, `ogrn`, `bank_account` | BR-4.5 | реквизиты входят в описание ресторана |

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| `address` | `apartment_office` | BR-3.2, BR-11.3 | у частного дома/входа квартиры нет |
| `order` | `delivery_timestamp` | BR-7.12, BR-11.3 | заполняется при статусе `'доставлен'` |
| `courier` | `dismissal_date` | BR-6.3, BR-11.3 | у работающего даты увольнения нет |
| `product` | `photo_url` | BR-5.6, BR-11.3 | фотография необязательна |
| `review` | `photo_url` | BR-9.3, BR-11.3 | фотография необязательна |
| `restaurant` | `rating` | BR-9.7 | нет отзывов — нет среднего |
| `product` | `rating` | BR-9.7 | нет отзывов — нет среднего |

## DEFAULT и GENERATED

| Таблица | Столбец | Что | Обоснование |
|---|---|---|---|
| сущности с суррогатным ключом | `*_id` | `DEFAULT exts.uuid_generate_v4()` | BR-11.1: ID — uuid на сервере |
| `order` | `order_timestamp` | `DEFAULT localtimestamp` | BR-7.1: время создания заказа |
| `payment` | `payment_timestamp` | `DEFAULT localtimestamp` | BR-8.2: время попытки оплаты |
| `review` | `review_timestamp` | `DEFAULT localtimestamp` | BR-9.3: дата отзыва |
| `restaurant` | `status` | `DEFAULT 'активен'` | BR-4.3 |
| `product` | `status` | `DEFAULT 'доступно'` | BR-5.5 |
| `courier` | `status` | `DEFAULT 'свободен'` | BR-6.2 |
| `courier` | `coefficient` | `DEFAULT 0.10` | BR-6.5: коэффициент нового курьера |
| `order` | `status` | `DEFAULT 'создан'` | BR-7.7 |
| `order` | `pay_status` | `DEFAULT 'ожидает'` | BR-7.9; далее пересчитывается триггером |
| `payment` | `status` | `DEFAULT 'в_обработке'` | BR-8.2 |
| `order` | `commission` | `GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED` | BR-1.4: 10% нельзя рассинхронизировать |
| `order` | `total_amount` | `GENERATED ALWAYS AS (order_amount + commission) STORED` | BR-7.10: сумма = стоимость + комиссия |

## Нормализация (3НФ)

Все таблицы в 3НФ: неключевые атрибуты зависят от полного первичного ключа (2НФ),
транзитивных зависимостей нет (3НФ). `restaurant.inn/ogrn/bank_account` (BR-4.5) и
`courier.last_name/first_name/middle_name` (BR-6.1) разложены на атомарные атрибуты.

Особые случаи:

- `order.commission` и `order.total_amount` — вычисляемые, `GENERATED ALWAYS`;
  вручную не хранятся (BR-1.4, BR-7.10). `order.order_amount` фиксируется при
  оформлении заказа и рассчитывается приложением по позициям.
- `product.rating` и `restaurant.rating` — агрегаты, поддерживаются триггером
  `rating_change` (BR-9.6, BR-9.7). Это осознанная денормализация ради чтения.
- `review.entity_type` + `entity_id` — полиморфизм, 3НФ не нарушает (ловушка 4).

Дополнительных индексов нет: BR-11.8 не оценивает оптимизацию индексами, остаются
индексы PK/UNIQUE и частичный `uq_payment_success_per_order` (BR-8.1).

## Спорные места требований

- **BR-8.1 vs BR-8.7.** «Ровно одна успешная попытка» и статусы `'ошибка'`/`'ожидает'`
  несовместимы. Реализовано «не больше одной», статусы достижимы.
- **BR-7.14 (1..N позиций).** Декларативно не выражается. Генератор всегда создаёт
  1–5 позиций; при ручной вставке заказ без позиций возможен. Отложенный
  constraint-триггер не добавлен — это лишний механизм вне ERD.
- **BR-9.2.** Связь отзыва с заказом обеспечена; принадлежность отзыва клиенту
  заказа и наличие объекта в заказе — на приложении (см. ловушку 4).
- **BR-13.1.** `order` не переименован, а взят в кавычки — `"order"`.
