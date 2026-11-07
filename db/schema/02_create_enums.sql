-- ============================================================================
-- FoodExpress / FOOD-101
-- 8 enum-типов из BR-11.5 и BR-4.3, 5.5, 6.2, 7.7, 7.9, 8.2, 9.1.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

CREATE TYPE restaurant_status AS ENUM (
    'активен',
    'неактивен'
);

CREATE TYPE product_status AS ENUM (
    'доступно',
    'нет_в_наличии',
    'архив'
);

CREATE TYPE courier_status AS ENUM (
    'свободен',
    'занят',
    'на_доставке',
    'уволен'
);

CREATE TYPE order_status AS ENUM (
    'создан',
    'готовится',
    'в_доставке',
    'доставлен',
    'отменён'
);

CREATE TYPE order_pay_status AS ENUM (
    'ожидает',
    'оплачен',
    'ошибка'
);

CREATE TYPE payment_status AS ENUM (
    'успех',
    'ошибка',
    'в_обработке'
);

CREATE TYPE payment_type AS ENUM (
    'карта',
    'наличные',
    'безнал'
);

CREATE TYPE review_entity_type AS ENUM (
    'блюдо',
    'ресторан',
    'заказ'
);
