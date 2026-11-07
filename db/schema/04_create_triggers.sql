-- ============================================================================
-- FoodExpress / FOOD-101, FOOD-105
-- Триггеры целостности и пересчёта рейтингов.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- ---------------------------------------------------------------------------
-- BR-7.3: все блюда заказа — из ресторана заказа.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_order_structure_restaurant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_order_restaurant uuid;
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

-- ---------------------------------------------------------------------------
-- BR-7.3 при смене ресторана у заказа, в котором уже есть позиции.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_order_restaurant_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id
       AND EXISTS (
           SELECT 1
             FROM order_structure os
             JOIN product p ON p.product_id = os.product_id
            WHERE os.order_id = OLD.order_id
              AND p.restaurant_id <> NEW.restaurant_id
       )
    THEN
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
    EXECUTE FUNCTION check_order_restaurant_update();

-- ---------------------------------------------------------------------------
-- BR-9.1 / BR-9.2: полиморфная ссылка отзыва должна указывать на
-- существующую сущность. Для отзыва на заказ entity_id = order_id.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- BR-9.6 / BR-9.7: пересчёт агрегированного рейтинга блюда или ресторана.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recalc_entity_rating(p_entity_type review_entity_type,
                                                p_entity_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF p_entity_type = 'блюдо' THEN
        UPDATE product p
           SET rating = (
               SELECT round(avg(r.rating), 2)
                 FROM review r
                WHERE r.entity_type = 'блюдо'
                  AND r.entity_id = p_entity_id
           )
         WHERE p.product_id = p_entity_id;
    ELSIF p_entity_type = 'ресторан' THEN
        UPDATE restaurant r
           SET rating = (
               SELECT round(avg(rv.rating), 2)
                 FROM review rv
                WHERE rv.entity_type = 'ресторан'
                  AND rv.entity_id = p_entity_id
           )
         WHERE r.restaurant_id = p_entity_id;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION rating_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM recalc_entity_rating(OLD.entity_type, OLD.entity_id);
        RETURN OLD;
    ELSIF TG_OP = 'INSERT' THEN
        PERFORM recalc_entity_rating(NEW.entity_type, NEW.entity_id);
        RETURN NEW;
    ELSE
        -- При смене сущности пересчитываем и старую, и новую.
        IF OLD.entity_type IS DISTINCT FROM NEW.entity_type
           OR OLD.entity_id IS DISTINCT FROM NEW.entity_id THEN
            PERFORM recalc_entity_rating(OLD.entity_type, OLD.entity_id);
        END IF;
        PERFORM recalc_entity_rating(NEW.entity_type, NEW.entity_id);
        RETURN NEW;
    END IF;
END;
$$;

CREATE TRIGGER trg_rating_change
    AFTER INSERT OR UPDATE OR DELETE ON review
    FOR EACH ROW
    EXECUTE FUNCTION rating_change();

-- ---------------------------------------------------------------------------
-- BR-8.7: агрегированный статус оплаты заказа по попыткам.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refresh_order_pay_status(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_status order_pay_status;
BEGIN
    IF EXISTS (
        SELECT 1 FROM payment
         WHERE order_id = p_order_id AND status = 'успех'
    ) THEN
        v_status := 'оплачен';
    ELSIF EXISTS (
        SELECT 1 FROM payment
         WHERE order_id = p_order_id AND status = 'в_обработке'
    ) THEN
        v_status := 'ожидает';
    ELSIF EXISTS (
        SELECT 1 FROM payment
         WHERE order_id = p_order_id AND status = 'ошибка'
    ) THEN
        v_status := 'ошибка';
    ELSE
        v_status := 'ожидает';
    END IF;

    UPDATE "order"
       SET pay_status = v_status
     WHERE order_id = p_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION payment_pay_status_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM refresh_order_pay_status(OLD.order_id);
        RETURN OLD;
    ELSIF TG_OP = 'INSERT' THEN
        PERFORM refresh_order_pay_status(NEW.order_id);
        RETURN NEW;
    ELSE
        IF OLD.order_id IS DISTINCT FROM NEW.order_id THEN
            PERFORM refresh_order_pay_status(OLD.order_id);
        END IF;
        PERFORM refresh_order_pay_status(NEW.order_id);
        RETURN NEW;
    END IF;
END;
$$;

CREATE TRIGGER trg_payment_pay_status
    AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW
    EXECUTE FUNCTION payment_pay_status_change();

-- ---------------------------------------------------------------------------
-- BR-8.4: сумма попытки оплаты равна общей сумме заказа.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_payment_amount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO prudko_food, exts, public
AS $$
DECLARE
    v_total numeric(12,2);
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
