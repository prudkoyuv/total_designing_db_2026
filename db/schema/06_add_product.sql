-- ============================================================================
-- FoodExpress / FOOD-104
-- add_product(...) — добавление блюда.
--
-- Задача процедуры — только выполнить INSERT. Вся проверка корректности
-- данных уже описана ограничениями схемы:
--   * существование ресторана и категории — FK fk_product_restaurant /
--     fk_product_category;
--   * непустые name/description — NOT NULL + chk_product_*_not_empty;
--   * неотрицательная цена — chk_product_price;
--   * диапазон рейтинга — chk_product_rating;
--   * длина названия — тип varchar(100).
-- Поэтому дублировать эти проверки в IF-ах не нужно: СУБД сделает это
-- быстрее и не даст ограничениям разойтись с процедурой.
--
-- Блок EXCEPTION переводит стандартные ошибки ограничений в понятный текст
-- (требование FOOD-104 «падает с внятной ошибкой»). Сам INSERT при этом
-- откатывается, как и положено.
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

COMMENT ON PROCEDURE add_product(uuid, uuid, varchar, numeric, text, product_status, text, numeric) IS
    'FOOD-104: добавляет блюдо одним INSERT. Корректность обеспечивают ограничения product; исключения ограничений транслируются в понятный текст. product_id генерируется внутри.';
