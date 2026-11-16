-- ============================================================================
-- FoodExpress / FOOD-105
-- rating_change(): пересчёт product.rating / restaurant.rating (BR-9.6, BR-9.7).
--
-- Алгоритм:
--   INSERT — пересчитать рейтинг новой сущности;
--   UPDATE — при смене entity_type/entity_id пересчитать старую сущность,
--            затем всегда пересчитать новую (в том числе при смене rating);
--   DELETE — пересчитать сущность удалённого отзыва;
--   entity_type = 'заказ' — агрегата нет, ничего не делать;
--   нет отзывов — avg() возвращает NULL, поэтому rating становится NULL.
-- Рекурсии нет: триггер обновляет product/restaurant, а не review.
--
-- Остальные проверки BR-7.3, BR-8.4, BR-8.7, BR-9.1 выполняет бэкенд;
-- см. db/constraints.md, раздел «Граница с приложением».
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- BR-9.6, BR-9.7: пересчёт product.rating / restaurant.rating по отзывам.
CREATE OR REPLACE FUNCTION rating_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    -- DELETE: отзыв удалён, пересчитываем рейтинг его сущности.
    IF TG_OP = 'DELETE' THEN
        IF OLD.entity_type = 'блюдо' THEN
            UPDATE product p
               SET rating = (
                   SELECT round(avg(r.rating), 2)
                     FROM review r
                    WHERE r.entity_type = 'блюдо'
                      AND r.entity_id = OLD.entity_id
               )
             WHERE p.product_id = OLD.entity_id;
        ELSIF OLD.entity_type = 'ресторан' THEN
            UPDATE restaurant rs
               SET rating = (
                   SELECT round(avg(r.rating), 2)
                     FROM review r
                    WHERE r.entity_type = 'ресторан'
                      AND r.entity_id = OLD.entity_id
               )
             WHERE rs.restaurant_id = OLD.entity_id;
        END IF;
        RETURN OLD;
    END IF;

    -- Отзыв переехал на другую сущность: пересчитываем и старую.
    IF TG_OP = 'UPDATE'
       AND (OLD.entity_type IS DISTINCT FROM NEW.entity_type
            OR OLD.entity_id IS DISTINCT FROM NEW.entity_id)
    THEN
        IF OLD.entity_type = 'блюдо' THEN
            UPDATE product p
               SET rating = (
                   SELECT round(avg(r.rating), 2)
                     FROM review r
                    WHERE r.entity_type = 'блюдо'
                      AND r.entity_id = OLD.entity_id
               )
             WHERE p.product_id = OLD.entity_id;
        ELSIF OLD.entity_type = 'ресторан' THEN
            UPDATE restaurant rs
               SET rating = (
                   SELECT round(avg(r.rating), 2)
                     FROM review r
                    WHERE r.entity_type = 'ресторан'
                      AND r.entity_id = OLD.entity_id
               )
             WHERE rs.restaurant_id = OLD.entity_id;
        END IF;
    END IF;

    -- INSERT или UPDATE: пересчитываем рейтинг новой сущности отзыва.
    IF NEW.entity_type = 'блюдо' THEN
        UPDATE product p
           SET rating = (
               SELECT round(avg(r.rating), 2)
                 FROM review r
                WHERE r.entity_type = 'блюдо'
                  AND r.entity_id = NEW.entity_id
           )
         WHERE p.product_id = NEW.entity_id;
    ELSIF NEW.entity_type = 'ресторан' THEN
        UPDATE restaurant rs
           SET rating = (
               SELECT round(avg(r.rating), 2)
                 FROM review r
                WHERE r.entity_type = 'ресторан'
                  AND r.entity_id = NEW.entity_id
           )
         WHERE rs.restaurant_id = NEW.entity_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rating_change
    AFTER INSERT OR UPDATE OR DELETE ON review
    FOR EACH ROW
    EXECUTE FUNCTION rating_change();
