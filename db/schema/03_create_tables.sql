-- ============================================================================
-- FoodExpress / FOOD-101
-- Физическая схема: 12 таблиц ERD, приведённых к 3НФ.
--
-- Отличия от концептуальной схемы (docs/erd.md) — только нормализация:
--   * restaurant.company_details разложен на inn / ogrn / bank_account;
--   * courier.fio разложен на last_name / first_name / middle_name.
-- Концептуальная схема допускает такую детализацию на логическом уровне
-- (docs/erd.md, раздел «Что это за документ»).
--
-- Все ID — uuid, генерируются через exts.uuid_generate_v4() (BR-11.1).
-- Служебных последовательностей нет: ID и уникальные строки генерируются
-- без счётчиков (см. 05_insert_test_data.sql).
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- ---------------------------------------------------------------------------
-- Клиенты (BR-2.*)
-- ---------------------------------------------------------------------------
CREATE TABLE client (
    client_id    uuid          NOT NULL DEFAULT exts.uuid_generate_v4(),
    login        varchar(50)   NOT NULL,
    password     varchar(32)   NOT NULL,
    phone_number varchar(20)   NOT NULL,
    CONSTRAINT pk_client PRIMARY KEY (client_id),
    CONSTRAINT uq_client_login UNIQUE (login),
    CONSTRAINT uq_client_phone UNIQUE (phone_number),
    CONSTRAINT chk_client_login_not_empty CHECK (length(trim(login)) > 0),
    CONSTRAINT chk_client_password_md5 CHECK (password ~ '^[0-9a-f]{32}$'),
    CONSTRAINT chk_client_phone_not_empty CHECK (length(trim(phone_number)) > 0)
);

COMMENT ON TABLE client IS
    'Клиент сервиса. ФИО не хранится (BR-2.6): идентификация по логину и телефону.';
COMMENT ON COLUMN client.password IS
    'MD5-хэш пароля, ровно 32 hex-символа (BR-2.3). Открытый пароль не хранится.';
COMMENT ON COLUMN client.phone_number IS
    'Телефон в формате +7XXXXXXXXXX, уникален (BR-2.2).';

-- ---------------------------------------------------------------------------
-- Адреса (BR-3.*). Адрес не удаляется вместе с клиентом/рестораном (BR-3.5):
-- на него ссылаются история заказов и client_address.
-- ---------------------------------------------------------------------------
CREATE TABLE address (
    address_id       uuid        NOT NULL DEFAULT exts.uuid_generate_v4(),
    street           varchar(100) NOT NULL,
    house_number     varchar(20)  NOT NULL,
    apartment_office varchar(20),
    CONSTRAINT pk_address PRIMARY KEY (address_id),
    CONSTRAINT uq_address_full UNIQUE NULLS NOT DISTINCT (street, house_number, apartment_office),
    CONSTRAINT chk_address_street_not_empty CHECK (length(trim(street)) > 0),
    CONSTRAINT chk_address_house_not_empty CHECK (length(trim(house_number)) > 0),
    CONSTRAINT chk_address_apartment_not_empty CHECK (apartment_office IS NULL OR length(trim(apartment_office)) > 0)
);

COMMENT ON TABLE address IS
    'Физический адрес: улица, дом, квартира/офис. Один адрес может использоваться несколькими клиентами (BR-3.4).';
COMMENT ON COLUMN address.apartment_office IS
    'Квартира или офис; NULL допустим для частных домов и отдельных входов (BR-3.2, BR-11.3).';
COMMENT ON CONSTRAINT uq_address_full ON address IS
    'NULLS NOT DISTINCT: два адреса без квартиры с одинаковой улицей и домом считаются дублем (BR-3.1).';

-- ---------------------------------------------------------------------------
-- M:N клиент — адрес (BR-2.4, BR-2.5)
-- ---------------------------------------------------------------------------
CREATE TABLE client_address (
    client_id  uuid NOT NULL,
    address_id uuid NOT NULL,
    CONSTRAINT pk_client_address PRIMARY KEY (client_id, address_id),
    CONSTRAINT fk_client_address_client FOREIGN KEY (client_id)
        REFERENCES client (client_id) ON DELETE CASCADE,
    CONSTRAINT fk_client_address_address FOREIGN KEY (address_id)
        REFERENCES address (address_id) ON DELETE RESTRICT
);

COMMENT ON TABLE client_address IS
    'M:N: у клиента несколько адресов, один адрес может быть у разных клиентов (BR-2.4). Пара уникальна (BR-2.5).';

-- ---------------------------------------------------------------------------
-- Рестораны (BR-4.*). Реквизиты разложены на атомарные атрибуты (1НФ):
-- ИНН, ОГРН и расчётный счёт — разные по смыслу и формату значения.
-- ---------------------------------------------------------------------------
CREATE TABLE restaurant (
    restaurant_id   uuid              NOT NULL DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(100)      NOT NULL,
    address_id      uuid              NOT NULL,
    description     text              NOT NULL,
    work_start      time              NOT NULL,
    work_end        time              NOT NULL,
    inn             varchar(12)       NOT NULL,
    ogrn            varchar(15)       NOT NULL,
    bank_account    varchar(20)       NOT NULL,
    rating          numeric(3,2),
    status          restaurant_status NOT NULL DEFAULT 'активен',
    CONSTRAINT pk_restaurant PRIMARY KEY (restaurant_id),
    CONSTRAINT uq_restaurant_address UNIQUE (address_id),
    CONSTRAINT fk_restaurant_address FOREIGN KEY (address_id)
        REFERENCES address (address_id) ON DELETE RESTRICT,
    CONSTRAINT chk_restaurant_name_not_empty CHECK (length(trim(restaurant_name)) > 0),
    CONSTRAINT chk_restaurant_description_not_empty CHECK (length(trim(description)) > 0),
    CONSTRAINT chk_restaurant_inn CHECK (inn ~ '^[0-9]{10}([0-9]{2})?$'),
    CONSTRAINT chk_restaurant_ogrn CHECK (ogrn ~ '^[0-9]{13}([0-9]{2})?$'),
    CONSTRAINT chk_restaurant_bank_account CHECK (bank_account ~ '^[0-9]{20}$'),
    CONSTRAINT chk_restaurant_work_hours CHECK (work_end > work_start),
    CONSTRAINT chk_restaurant_rating CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5))
);

COMMENT ON TABLE restaurant IS
    'Ресторан-партнёр. Один адрес у ресторана, адрес не делится с другим рестораном (BR-3.3).';
COMMENT ON COLUMN restaurant.inn IS
    'ИНН: 10 цифр у юрлица, 12 у ИП (BR-4.5). Отдельный атомарный атрибут вместо текста реквизитов.';
COMMENT ON COLUMN restaurant.ogrn IS
    'ОГРН: 13 цифр у юрлица, 15 у ИП (BR-4.5).';
COMMENT ON COLUMN restaurant.bank_account IS
    'Расчётный счёт: ровно 20 цифр (BR-4.5).';
COMMENT ON COLUMN restaurant.rating IS
    'Среднее по отзывам на ресторан; NULL, пока отзывов нет (BR-9.6, BR-9.7).';

-- ---------------------------------------------------------------------------
-- Курьеры (BR-6.*). ФИО разложено на атомарные атрибуты (1НФ):
-- фамилия, имя и отчество — независимые части.
-- ---------------------------------------------------------------------------
CREATE TABLE courier (
    courier_id     uuid           NOT NULL DEFAULT exts.uuid_generate_v4(),
    last_name      varchar(50)    NOT NULL,
    first_name     varchar(50)    NOT NULL,
    middle_name    varchar(50)    NOT NULL,
    phone_number   varchar(20)    NOT NULL,
    status         courier_status NOT NULL DEFAULT 'свободен',
    hire_date      date           NOT NULL,
    dismissal_date date,
    coefficient    numeric(3,2)   NOT NULL DEFAULT 0.10,
    CONSTRAINT pk_courier PRIMARY KEY (courier_id),
    CONSTRAINT chk_courier_last_name_not_empty CHECK (length(trim(last_name)) > 0),
    CONSTRAINT chk_courier_first_name_not_empty CHECK (length(trim(first_name)) > 0),
    CONSTRAINT chk_courier_middle_name_not_empty CHECK (length(trim(middle_name)) > 0),
    CONSTRAINT chk_courier_phone_not_empty CHECK (length(trim(phone_number)) > 0),
    CONSTRAINT chk_courier_coefficient CHECK (coefficient >= 0.10 AND coefficient <= 0.50),
    CONSTRAINT chk_courier_dismissal_date CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date),
    CONSTRAINT chk_courier_dismissed_has_date CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL)
);

COMMENT ON TABLE courier IS
    'Курьер сервиса. Коэффициент — доля от комиссий доставленных заказов (BR-6.4, BR-10.2).';
COMMENT ON COLUMN courier.middle_name IS
    'Отчество — часть ФИО, обязательна по BR-6.1 и BR-11.3.';
COMMENT ON COLUMN courier.coefficient IS
    'Коэффициент, действующий в текущем месяце (установлен в прошлом месяце), от 0.10 до 0.50 (BR-6.4).';
COMMENT ON COLUMN courier.dismissal_date IS
    'Дата увольнения; NULL у работающего курьера (BR-6.3, BR-11.3).';

-- ---------------------------------------------------------------------------
-- Ежемесячные выплаты курьерам (BR-10.*)
-- ---------------------------------------------------------------------------
CREATE TABLE courier_pay (
    year             int          NOT NULL,
    month            int          NOT NULL,
    courier_id       uuid         NOT NULL,
    amount           numeric(10,2) NOT NULL,
    coefficient_used numeric(3,2) NOT NULL,
    CONSTRAINT pk_courier_pay PRIMARY KEY (year, month, courier_id),
    CONSTRAINT fk_courier_pay_courier FOREIGN KEY (courier_id)
        REFERENCES courier (courier_id) ON DELETE RESTRICT,
    CONSTRAINT chk_courier_pay_month CHECK (month BETWEEN 1 AND 12),
    CONSTRAINT chk_courier_pay_amount CHECK (amount >= 0),
    CONSTRAINT chk_courier_pay_coefficient CHECK (coefficient_used >= 0.10 AND coefficient_used <= 0.50)
);

COMMENT ON TABLE courier_pay IS
    'Выплата курьеру за календарный месяц; одна запись на пару (курьер, месяц) (BR-10.3).';
COMMENT ON COLUMN courier_pay.amount IS
    'Зарплата = coefficient_used × сумма комиссий доставленных заказов месяца (BR-10.2).';
COMMENT ON COLUMN courier_pay.coefficient_used IS
    'Коэффициент, действовавший в этом месяце; фиксируется, чтобы пересчёт не зависел от будущих изменений (BR-10.2).';

-- ---------------------------------------------------------------------------
-- Справочник категорий блюд (BR-5.7)
-- ---------------------------------------------------------------------------
CREATE TABLE product_category (
    product_category_id   uuid         NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(100) NOT NULL,
    CONSTRAINT pk_product_category PRIMARY KEY (product_category_id),
    CONSTRAINT chk_product_category_name_not_empty CHECK (length(trim(product_category_name)) > 0)
);

COMMENT ON TABLE product_category IS
    'Справочник категорий блюд (BR-5.7).';

-- ---------------------------------------------------------------------------
-- Блюда (BR-5.*)
-- ---------------------------------------------------------------------------
CREATE TABLE product (
    product_id          uuid           NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_name        varchar(100)   NOT NULL,
    product_category_id uuid           NOT NULL,
    price               numeric(7,2)   NOT NULL,
    restaurant_id       uuid           NOT NULL,
    photo_url           text,
    rating              numeric(3,2),
    status              product_status NOT NULL DEFAULT 'доступно',
    description         text           NOT NULL,
    CONSTRAINT pk_product PRIMARY KEY (product_id),
    CONSTRAINT fk_product_category FOREIGN KEY (product_category_id)
        REFERENCES product_category (product_category_id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_restaurant FOREIGN KEY (restaurant_id)
        REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT,
    CONSTRAINT chk_product_name_not_empty CHECK (length(trim(product_name)) > 0),
    CONSTRAINT chk_product_description_not_empty CHECK (length(trim(description)) > 0),
    CONSTRAINT chk_product_price CHECK (price >= 0),
    CONSTRAINT chk_product_rating CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5))
);

COMMENT ON TABLE product IS
    'Блюдо меню: ровно один ресторан и одна категория (BR-5.1).';
COMMENT ON COLUMN product.price IS
    'Цена в рублях, numeric(7,2): до 99 999.99 ₽. Обоснование разрядности — в constraints.md.';
COMMENT ON COLUMN product.photo_url IS
    'Ссылка на фотографию; NULL допустим (BR-5.6, BR-11.3).';
COMMENT ON COLUMN product.rating IS
    'Среднее по отзывам на блюдо; NULL, пока отзывов нет (BR-9.6, BR-9.7).';

-- ---------------------------------------------------------------------------
-- Заказы (BR-7.*). Имя order зарезервировано, поэтому используется "order".
-- commission и total_amount — вычисляемые (BR-1.4, BR-7.10, BR-7.11).
-- ---------------------------------------------------------------------------
CREATE TABLE "order" (
    order_id           uuid              NOT NULL DEFAULT exts.uuid_generate_v4(),
    courier_id         uuid              NOT NULL,
    client_id          uuid              NOT NULL,
    address_id         uuid              NOT NULL,
    restaurant_id      uuid              NOT NULL,
    order_timestamp    timestamp         NOT NULL DEFAULT localtimestamp,
    delivery_timestamp timestamp,
    order_amount       numeric(10,2)     NOT NULL,
    commission         numeric(10,2)     NOT NULL GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED,
    total_amount       numeric(10,2)     NOT NULL GENERATED ALWAYS AS (round(order_amount + round(order_amount * 0.10, 2), 2)) STORED,
    status             order_status      NOT NULL DEFAULT 'создан',
    pay_status         order_pay_status  NOT NULL DEFAULT 'ожидает',
    description        text              NOT NULL,
    CONSTRAINT pk_order PRIMARY KEY (order_id),
    CONSTRAINT fk_order_courier FOREIGN KEY (courier_id)
        REFERENCES courier (courier_id) ON DELETE RESTRICT,
    CONSTRAINT fk_order_client FOREIGN KEY (client_id)
        REFERENCES client (client_id) ON DELETE RESTRICT,
    CONSTRAINT fk_order_restaurant FOREIGN KEY (restaurant_id)
        REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_order_address FOREIGN KEY (address_id)
        REFERENCES address (address_id) ON DELETE RESTRICT,
    -- BR-7.4: адрес доставки обязан быть одним из адресов этого клиента.
    CONSTRAINT fk_order_client_address FOREIGN KEY (client_id, address_id)
        REFERENCES client_address (client_id, address_id) ON DELETE RESTRICT,
    CONSTRAINT chk_order_amount_non_negative CHECK (order_amount >= 0),
    CONSTRAINT chk_order_min_total CHECK (total_amount >= 1000),
    CONSTRAINT chk_order_delivery_time CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    CONSTRAINT chk_order_delivered_has_time CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL),
    CONSTRAINT chk_order_description_not_empty CHECK (length(trim(description)) > 0)
);

COMMENT ON TABLE "order" IS
    'Заказ: клиент, ресторан, курьер, адрес доставки, суммы и статусы (BR-7.*).';
COMMENT ON COLUMN "order".order_amount IS
    'Стоимость блюд без комиссии. numeric(10,2): до 99 999 999.99 ₽.';
COMMENT ON COLUMN "order".commission IS
    'Вычисляемая комиссия 10% (BR-1.4, BR-7.10); GENERATED ALWAYS, чтобы её нельзя было рассинхронизировать.';
COMMENT ON COLUMN "order".total_amount IS
    'Вычисляемая сумма к оплате: order_amount + commission; CHECK >= 1000 (BR-7.11).';
COMMENT ON COLUMN "order".delivery_timestamp IS
    'Время окончания доставки; NULL, пока заказ не доставлен (BR-7.12, BR-11.3).';
COMMENT ON COLUMN "order".pay_status IS
    'Агрегированный статус оплаты; поддерживается триггером по payment (BR-8.7).';
COMMENT ON COLUMN "order".description IS
    'Комментарий к заказу; обязателен, так как BR-11.3 не разрешает NULL для этого поля.';

-- ---------------------------------------------------------------------------
-- Состав заказа (BR-7.14 — BR-7.16)
-- ---------------------------------------------------------------------------
CREATE TABLE order_structure (
    order_id   uuid          NOT NULL,
    product_id uuid          NOT NULL,
    quantity   numeric(6,3)  NOT NULL,
    CONSTRAINT pk_order_structure PRIMARY KEY (order_id, product_id),
    CONSTRAINT fk_order_structure_order FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE,
    CONSTRAINT fk_order_structure_product FOREIGN KEY (product_id)
        REFERENCES product (product_id) ON DELETE RESTRICT,
    CONSTRAINT chk_order_structure_quantity CHECK (quantity > 0)
);

COMMENT ON TABLE order_structure IS
    'Позиция заказа: блюдо и количество; блюдо не повторяется в заказе (BR-7.16).';
COMMENT ON COLUMN order_structure.quantity IS
    'Количество, numeric(6,3): от 0.001 до 999.999; допускается дробное (BR-7.15).';

-- ---------------------------------------------------------------------------
-- Попытки оплаты (BR-8.*)
-- ---------------------------------------------------------------------------
CREATE TABLE payment (
    payment_id        uuid           NOT NULL DEFAULT exts.uuid_generate_v4(),
    order_id          uuid           NOT NULL,
    payment_type      payment_type   NOT NULL,
    amount            numeric(10,2)  NOT NULL,
    transaction_code  varchar(100)   NOT NULL,
    payment_timestamp timestamp      NOT NULL DEFAULT localtimestamp,
    status            payment_status NOT NULL DEFAULT 'в_обработке',
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT uq_payment_transaction UNIQUE (transaction_code),
    CONSTRAINT fk_payment_order FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE,
    CONSTRAINT chk_payment_amount CHECK (amount >= 0),
    CONSTRAINT chk_payment_transaction_not_empty CHECK (length(trim(transaction_code)) > 0)
);

COMMENT ON TABLE payment IS
    'Попытка оплаты заказа; тип относится к попытке, а не к заказу (BR-8.6).';
COMMENT ON COLUMN payment.transaction_code IS
    'Внешний идентификатор транзакции от платёжного провайдера; уникален (BR-8.3).';
COMMENT ON COLUMN payment.amount IS
    'Сумма попытки; равна order.total_amount (BR-8.4), проверяется триггером.';

-- BR-8.1: не больше одной успешной попытки на заказ.
CREATE UNIQUE INDEX uq_payment_success_per_order
    ON payment (order_id)
    WHERE status = 'успех';

COMMENT ON INDEX uq_payment_success_per_order IS
    'BR-8.1: у заказа не может быть двух успешных попыток оплаты.';

-- ---------------------------------------------------------------------------
-- Отзывы (BR-9.*). Полиморфная ссылка entity_type + entity_id.
-- ---------------------------------------------------------------------------
CREATE TABLE review (
    review_id        uuid               NOT NULL DEFAULT exts.uuid_generate_v4(),
    client_id        uuid               NOT NULL,
    review_timestamp timestamp          NOT NULL DEFAULT localtimestamp,
    entity_id        uuid               NOT NULL,
    entity_type      review_entity_type NOT NULL,
    order_id         uuid               NOT NULL,
    description      text               NOT NULL,
    photo_url        text,
    rating           numeric(2,1)       NOT NULL,
    CONSTRAINT pk_review PRIMARY KEY (review_id),
    CONSTRAINT uq_review_order_entity UNIQUE (order_id, entity_type, entity_id),
    CONSTRAINT fk_review_client FOREIGN KEY (client_id)
        REFERENCES client (client_id) ON DELETE RESTRICT,
    CONSTRAINT fk_review_order FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE,
    CONSTRAINT chk_review_description_not_empty CHECK (length(trim(description)) > 0),
    CONSTRAINT chk_review_rating CHECK (rating >= 1 AND rating <= 5)
);

COMMENT ON TABLE review IS
    'Отзыв клиента на блюдо, ресторан или заказ; в рамках заказа объект оценивается один раз (BR-9.5).';
COMMENT ON COLUMN review.entity_id IS
    'Полиморфная ссылка: product_id, restaurant_id или order_id в зависимости от entity_type (BR-9.1).';
COMMENT ON COLUMN review.photo_url IS
    'Фотография в отзыве; NULL допустим (BR-9.3, BR-11.3).';
COMMENT ON COLUMN review.rating IS
    'Оценка от 1 до 5 с шагом 0.1 (BR-9.4).';

-- ---------------------------------------------------------------------------
-- Индексы под JOIN/агрегаты отчётов и триггеров.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_client_address_address ON client_address (address_id);
CREATE INDEX idx_product_restaurant ON product (restaurant_id);
CREATE INDEX idx_product_category ON product (product_category_id);
CREATE INDEX idx_order_courier_status ON "order" (courier_id, status, order_timestamp);
CREATE INDEX idx_order_restaurant_status ON "order" (restaurant_id, status);
CREATE INDEX idx_order_client ON "order" (client_id);
CREATE INDEX idx_order_timestamp ON "order" (order_timestamp);
CREATE INDEX idx_order_structure_product ON order_structure (product_id);
CREATE INDEX idx_payment_order ON payment (order_id);
CREATE INDEX idx_review_entity ON review (entity_type, entity_id);
CREATE INDEX idx_review_order ON review (order_id);
