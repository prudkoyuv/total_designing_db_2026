-- ============================================================================
-- FoodExpress / FOOD-104
-- add_product(...) — добавляет блюдо одним INSERT.
-- Корректность обеспечивают ограничения product; блок EXCEPTION переводит
-- ошибки схемы в понятный текст.
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
        coalesce(p_status, 'доступно'),
        p_description
    );
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION
            'Нельзя добавить блюдо: ресторан % или категория % не существуют (FK)',
            p_restaurant_id, p_product_category_id;
    WHEN check_violation THEN
        RAISE EXCEPTION
            'Нельзя добавить блюдо: нарушено ограничение схемы (%): %',
            SQLSTATE, SQLERRM;
    WHEN not_null_violation THEN
        RAISE EXCEPTION
            'Нельзя добавить блюдо: обязательное поле не заполнено (%)', SQLERRM;
    WHEN string_data_right_truncation THEN
        RAISE EXCEPTION
            'Нельзя добавить блюдо: значение длиннее допустимого (%)', SQLERRM;
    WHEN numeric_value_out_of_range THEN
        RAISE EXCEPTION
            'Нельзя добавить блюдо: число вне допустимого диапазона (%)', SQLERRM;
END;
$$;
