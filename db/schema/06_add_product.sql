-- ============================================================================
-- FoodExpress / FOOD-104
-- add_product(...) — добавление блюда. product_id генерируется внутри.
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
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM restaurant WHERE restaurant_id = p_restaurant_id
    ) THEN
        RAISE EXCEPTION 'Ресторан с id % не существует', p_restaurant_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM product_category
         WHERE product_category_id = p_product_category_id
    ) THEN
        RAISE EXCEPTION 'Категория с id % не существует', p_product_category_id;
    END IF;

    IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
        RAISE EXCEPTION 'Название блюда не может быть пустым';
    END IF;

    IF length(p_name) > 100 THEN
        RAISE EXCEPTION 'Название блюда длиннее 100 символов';
    END IF;

    IF p_price IS NULL OR p_price < 0 THEN
        RAISE EXCEPTION 'Цена блюда не может быть отрицательной или NULL';
    END IF;

    IF p_description IS NULL OR length(trim(p_description)) = 0 THEN
        RAISE EXCEPTION 'Описание блюда не может быть пустым';
    END IF;

    IF p_rating IS NOT NULL AND (p_rating < 0 OR p_rating > 5) THEN
        RAISE EXCEPTION 'Рейтинг блюда должен быть в диапазоне от 0 до 5';
    END IF;

    INSERT INTO product (
        product_id,
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
        exts.uuid_generate_v4(),
        p_name,
        p_product_category_id,
        p_price,
        p_restaurant_id,
        p_photo_url,
        p_rating,
        COALESCE(p_status, 'доступно'),
        p_description
    );
END;
$$;
