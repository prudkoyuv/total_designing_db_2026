-- ============================================================================
-- FoodExpress / FOOD-104
-- add_product(...) — добавляет блюдо одним INSERT.
-- Целостность обеспечивают ограничения product: NOT NULL, FK, CHECK,
-- varchar(N) и numeric(6,2). Процедура не дублирует валидацию фронтенда
-- и не переводит ошибки БД в свой текст: сообщение PostgreSQL уже содержит
-- имя ограничения и проблемный ключ.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

CREATE OR REPLACE PROCEDURE add_product(
    p_restaurant_id       uuid,
    p_product_category_id uuid,
    p_name                varchar,
    p_price               numeric,
    p_description         text,
    p_status              product_status DEFAULT 'доступно',
    p_photo_url           text DEFAULT NULL,
    p_rating              numeric DEFAULT NULL
)
LANGUAGE sql
SET search_path TO prudko_food, exts, public
AS $$
    INSERT INTO product (
        product_name,
        product_category_id,
        price,
        restaurant_id,
        photo_url,
        rating,
        status,
        description
    )
    VALUES (
        p_name,
        p_product_category_id,
        p_price,
        p_restaurant_id,
        p_photo_url,
        p_rating,
        p_status,
        p_description
    );
$$;
