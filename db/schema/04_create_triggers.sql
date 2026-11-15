-- ============================================================================
-- FoodExpress / FOOD-101, FOOD-105
-- Триггеры целостности (BR-7.3, BR-8.4, BR-8.7, BR-9.1) и рейтингов (BR-9.6, BR-9.7).
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- BR-7.3: блюдо в позиции заказа должно быть из ресторана заказа.
CREATE OR REPLACE FUNCTION check_order_structure_restaurant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_order_restaurant   uuid;
    v_product_restaurant uuid;
BEGIN
    SELECT o.restaurant_id
      INTO v_order_restaurant
      FROM "order" o
     WHERE o.order_id = NEW.order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заказ % не существует', NEW.order_id;
    END IF;

    SELECT p.restaurant_id
      INTO v_product_restaurant
      FROM product p
     WHERE p.product_id = NEW.product_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Блюдо % не существует', NEW.product_id;
    END IF;

    IF v_order_restaurant <> v_product_restaurant THEN
        RAISE EXCEPTION
            'Блюдо % принадлежит ресторану %, а заказ % — ресторану %',
            NEW.product_id, v_product_restaurant, NEW.order_id, v_order_restaurant;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_order_structure_restaurant
    BEFORE INSERT OR UPDATE ON order_structure
    FOR EACH ROW
    EXECUTE FUNCTION check_order_structure_restaurant();

-- BR-7.3: смена ресторана заказа не должна отрывать уже добавленные позиции.
CREATE OR REPLACE FUNCTION check_order_restaurant_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM order_structure os
          JOIN product p ON p.product_id = os.product_id
         WHERE os.order_id = OLD.order_id
           AND p.restaurant_id <> NEW.restaurant_id
    ) THEN
        RAISE EXCEPTION
            'Нельзя сменить ресторан заказа %: в нём есть блюда другого ресторана',
            OLD.order_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_order_restaurant_update
    BEFORE UPDATE OF restaurant_id ON "order"
    FOR EACH ROW
    WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
    EXECUTE FUNCTION check_order_restaurant_update();

-- BR-7.3: блюдо, уже входящее в заказы, нельзя перенести в другой ресторан.
CREATE OR REPLACE FUNCTION check_product_restaurant_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM order_structure os WHERE os.product_id = OLD.product_id
    ) THEN
        RAISE EXCEPTION
            'Нельзя сменить ресторан блюда %: оно входит в заказы',
            OLD.product_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_product_restaurant_update
    BEFORE UPDATE OF restaurant_id ON product
    FOR EACH ROW
    WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
    EXECUTE FUNCTION check_product_restaurant_update();

-- BR-9.1: полиморфная ссылка отзыва должна указывать на существующую сущность.
CREATE OR REPLACE FUNCTION validate_review_entity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF NEW.entity_type = 'блюдо' THEN
        IF NOT EXISTS (SELECT 1 FROM product WHERE product_id = NEW.entity_id) THEN
            RAISE EXCEPTION 'Отзыв ссылается на несуществующее блюдо %', NEW.entity_id;
        END IF;
    ELSIF NEW.entity_type = 'ресторан' THEN
        IF NOT EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id = NEW.entity_id) THEN
            RAISE EXCEPTION 'Отзыв ссылается на несуществующий ресторан %', NEW.entity_id;
        END IF;
    ELSIF NEW.entity_type = 'заказ' THEN
        IF NEW.entity_id IS DISTINCT FROM NEW.order_id THEN
            RAISE EXCEPTION
                'Для отзыва на заказ entity_id (%) должен совпадать с order_id (%)',
                NEW.entity_id, NEW.order_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_review_entity_validate
    BEFORE INSERT OR UPDATE ON review
    FOR EACH ROW
    EXECUTE FUNCTION validate_review_entity();

-- BR-9.1: нельзя удалить блюдо или ресторан, на которые есть отзывы.
CREATE OR REPLACE FUNCTION check_review_entity_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_entity_type review_entity_type;
    v_entity_id   uuid;
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        v_entity_type := 'блюдо';
        v_entity_id   := OLD.product_id;
    ELSE
        v_entity_type := 'ресторан';
        v_entity_id   := OLD.restaurant_id;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM review r
         WHERE r.entity_type = v_entity_type
           AND r.entity_id = v_entity_id
    ) THEN
        RAISE EXCEPTION
            'Нельзя удалить % %: на него есть отзывы', TG_TABLE_NAME, v_entity_id;
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_product_review_delete
    BEFORE DELETE ON product
    FOR EACH ROW
    EXECUTE FUNCTION check_review_entity_delete();

CREATE TRIGGER trg_restaurant_review_delete
    BEFORE DELETE ON restaurant
    FOR EACH ROW
    EXECUTE FUNCTION check_review_entity_delete();

-- BR-9.6, BR-9.7: пересчёт product.rating / restaurant.rating по отзывам.
CREATE OR REPLACE FUNCTION rating_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
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

-- BR-8.7: order.pay_status пересчитывается по попыткам оплаты.
CREATE OR REPLACE FUNCTION payment_pay_status_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_order_ids uuid[];
    v_order_id  uuid;
    v_status    order_pay_status;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_order_ids := ARRAY[OLD.order_id];
    ELSIF TG_OP = 'INSERT' THEN
        v_order_ids := ARRAY[NEW.order_id];
    ELSIF OLD.order_id IS DISTINCT FROM NEW.order_id THEN
        v_order_ids := ARRAY[OLD.order_id, NEW.order_id];
    ELSE
        v_order_ids := ARRAY[NEW.order_id];
    END IF;

    FOREACH v_order_id IN ARRAY v_order_ids LOOP
        SELECT CASE
                   WHEN bool_or(status = 'успех') THEN 'оплачен'::order_pay_status
                   WHEN bool_or(status = 'в_обработке') THEN 'ожидает'::order_pay_status
                   WHEN bool_or(status = 'ошибка') THEN 'ошибка'::order_pay_status
                   ELSE 'ожидает'::order_pay_status
               END
          INTO v_status
          FROM payment
         WHERE order_id = v_order_id;

        UPDATE "order"
           SET pay_status = v_status
         WHERE order_id = v_order_id;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_pay_status
    AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW
    EXECUTE FUNCTION payment_pay_status_change();

-- BR-8.4: сумма попытки оплаты равна order.total_amount.
CREATE OR REPLACE FUNCTION check_payment_amount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_total numeric(10,2);
BEGIN
    SELECT o.total_amount
      INTO v_total
      FROM "order" o
     WHERE o.order_id = NEW.order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заказ % не существует', NEW.order_id;
    END IF;

    IF NEW.amount <> v_total THEN
        RAISE EXCEPTION
            'Сумма оплаты % не равна общей сумме заказа % (заказ %)',
            NEW.amount, v_total, NEW.order_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_amount_check
    BEFORE INSERT OR UPDATE ON payment
    FOR EACH ROW
    EXECUTE FUNCTION check_payment_amount();
