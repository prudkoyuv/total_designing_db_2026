-- ============================================================================
-- FoodExpress / FOOD-101
-- Физическая схема: 12 таблиц ERD в 3НФ. Все ID — uuid (BR-11.1).
-- Атрибуты payment дополнены по BR-8.2; restaurant.company_details и
-- courier.FIO разложены на атомарные столбцы (BR-4.5, BR-6.1).
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- Клиенты (BR-2.*)
CREATE TABLE client (
    client_id    uuid          NOT NULL DEFAULT exts.uuid_generate_v4(),
    login        varchar(50)   NOT NULL,
    password     varchar(32)   NOT NULL,
    phone_number varchar(20)   NOT NULL,
    CONSTRAINT pk_client PRIMARY KEY (client_id),
    CONSTRAINT uq_client_login UNIQUE (login),
    CONSTRAINT uq_client_phone UNIQUE (phone_number)
);

-- Адреса (BR-3.*)
CREATE TABLE address (
    address_id       uuid        NOT NULL DEFAULT exts.uuid_generate_v4(),
    street           varchar(100) NOT NULL,
    house_number     varchar(20)  NOT NULL,
    apartment_office varchar(20),
    CONSTRAINT pk_address PRIMARY KEY (address_id)
);

-- M:N клиент — адрес (BR-2.4, BR-2.5)
CREATE TABLE client_address (
    client_id  uuid NOT NULL,
    address_id uuid NOT NULL,
    CONSTRAINT pk_client_address PRIMARY KEY (client_id, address_id),
    CONSTRAINT fk_client_address_client FOREIGN KEY (client_id)
        REFERENCES client (client_id) ON DELETE CASCADE,
    CONSTRAINT fk_client_address_address FOREIGN KEY (address_id)
        REFERENCES address (address_id) ON DELETE RESTRICT
);

-- Рестораны (BR-4.*)
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
    CONSTRAINT chk_restaurant_work_hours CHECK (work_end > work_start),
    CONSTRAINT chk_restaurant_rating CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5))
);

-- Курьеры (BR-6.*)
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
    CONSTRAINT chk_courier_coefficient CHECK (coefficient >= 0.10 AND coefficient <= 0.50),
    CONSTRAINT chk_courier_dismissal_date CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date),
    CONSTRAINT chk_courier_dismissed_has_date CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL)
);

-- Ежемесячные выплаты курьерам (BR-10.*)
CREATE TABLE courier_pay (
    year             int          NOT NULL,
    month            int          NOT NULL,
    courier_id       uuid         NOT NULL,
    amount           numeric(8,2)  NOT NULL,
    coefficient_used numeric(3,2)  NOT NULL,
    CONSTRAINT pk_courier_pay PRIMARY KEY (year, month, courier_id),
    CONSTRAINT fk_courier_pay_courier FOREIGN KEY (courier_id)
        REFERENCES courier (courier_id) ON DELETE RESTRICT,
    CONSTRAINT chk_courier_pay_month CHECK (month BETWEEN 1 AND 12),
    CONSTRAINT chk_courier_pay_amount CHECK (amount >= 0),
    CONSTRAINT chk_courier_pay_coefficient CHECK (coefficient_used >= 0.10 AND coefficient_used <= 0.50)
);

-- Справочник категорий блюд (BR-5.7)
CREATE TABLE product_category (
    product_category_id   uuid         NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(100) NOT NULL,
    CONSTRAINT pk_product_category PRIMARY KEY (product_category_id)
);

-- Блюда (BR-5.*)
CREATE TABLE product (
    product_id          uuid           NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_name        varchar(100)   NOT NULL,
    product_category_id uuid           NOT NULL,
    price               numeric(6,2)   NOT NULL,
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
    CONSTRAINT chk_product_price CHECK (price >= 0),
    CONSTRAINT chk_product_rating CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5))
);

-- Заказы (BR-7.*). order — зарезервированное слово, поэтому "order".
CREATE TABLE "order" (
    order_id           uuid              NOT NULL DEFAULT exts.uuid_generate_v4(),
    courier_id         uuid              NOT NULL,
    client_id          uuid              NOT NULL,
    address_id         uuid              NOT NULL,
    restaurant_id      uuid              NOT NULL,
    order_timestamp    timestamp         NOT NULL DEFAULT localtimestamp,
    delivery_timestamp timestamp,
    order_amount       numeric(8,2)      NOT NULL,
    commission         numeric(7,2)      NOT NULL GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED,
    total_amount       numeric(8,2)      NOT NULL GENERATED ALWAYS AS (round(order_amount + round(order_amount * 0.10, 2), 2)) STORED,
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
    -- BR-7.4: адрес доставки обязан быть одним из адресов клиента.
    CONSTRAINT fk_order_client_address FOREIGN KEY (client_id, address_id)
        REFERENCES client_address (client_id, address_id) ON DELETE RESTRICT,
    CONSTRAINT chk_order_min_total CHECK (total_amount >= 1000),
    CONSTRAINT chk_order_delivery_time CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    CONSTRAINT chk_order_delivered_has_time CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL)
);

-- Состав заказа (BR-7.14 — BR-7.16)
CREATE TABLE order_structure (
    order_id   uuid          NOT NULL,
    product_id uuid          NOT NULL,
    quantity   numeric(4,3)  NOT NULL,
    CONSTRAINT pk_order_structure PRIMARY KEY (order_id, product_id),
    CONSTRAINT fk_order_structure_order FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE,
    CONSTRAINT fk_order_structure_product FOREIGN KEY (product_id)
        REFERENCES product (product_id) ON DELETE RESTRICT,
    CONSTRAINT chk_order_structure_quantity CHECK (quantity > 0)
);

-- Попытки оплаты (BR-8.*)
CREATE TABLE payment (
    payment_id        uuid           NOT NULL DEFAULT exts.uuid_generate_v4(),
    order_id          uuid           NOT NULL,
    payment_type      payment_type   NOT NULL,
    amount            numeric(8,2)   NOT NULL,
    transaction_code  varchar(100)   NOT NULL,
    payment_timestamp timestamp      NOT NULL DEFAULT localtimestamp,
    status            payment_status NOT NULL DEFAULT 'в_обработке',
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT uq_payment_transaction UNIQUE (transaction_code),
    CONSTRAINT fk_payment_order FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE
);

-- BR-8.1: не больше одной успешной попытки на заказ.
CREATE UNIQUE INDEX uq_payment_success_per_order
    ON payment (order_id)
    WHERE status = 'успех';

-- Отзывы (BR-9.*). Полиморфная ссылка entity_type + entity_id.
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
    CONSTRAINT chk_review_rating CHECK (rating >= 1 AND rating <= 5)
);
