-- ============================================================================
-- FoodExpress / FOOD-101, FOOD-105
-- Триггеры целостности и пересчёта рейтингов.
--
-- Каждая функция снабжена шапкой: назначение, BR, алгоритм и причина, по
-- которой проверку нельзя выразить декларативно (CHECK/FK). Те же описания
-- продублированы в COMMENT ON ..., чтобы их было видно в pgAdmin и \df+.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

-- ---------------------------------------------------------------------------
-- BR-7.3: все блюда заказа — из ресторана заказа.
--
-- Алгоритм:
--   1. По NEW.order_id читаем restaurant_id заказа.
--   2. По NEW.product_id читаем restaurant_id блюда.
--   3. Если они различаются — исключение, строка не вставляется/не меняется.
--
-- Декларативно нельзя: сравнение идёт через две таблицы (order и product),
-- а CHECK в PostgreSQL не может обращаться к другим таблицам.
-- ---------------------------------------------------------------------------
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

COMMENT ON FUNCTION check_order_structure_restaurant() IS
    'BR-7.3: не даёт добавить в заказ блюдо из другого ресторана. BEFORE INSERT/UPDATE ON order_structure.';

CREATE TRIGGER trg_order_structure_restaurant
    BEFORE INSERT OR UPDATE ON order_structure
    FOR EACH ROW
    EXECUTE FUNCTION check_order_structure_restaurant();

COMMENT ON TRIGGER trg_order_structure_restaurant ON order_structure IS
    'BR-7.3: все позиции заказа принадлежат ресторану заказа.';

-- ---------------------------------------------------------------------------
-- BR-7.3 при смене ресторана у заказа, в котором уже есть позиции.
--
-- Алгоритм:
--   1. Если restaurant_id не изменился — выходим.
--   2. Иначе ищем хотя бы одну позицию заказа, чьё блюдо принадлежит другому
--      ресторану.
--   3. Если такая есть — исключение.
--
-- Без этого триггера BR-7.3 обходился бы сменой restaurant_id у заказа.
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

COMMENT ON FUNCTION check_order_restaurant_update() IS
    'BR-7.3: запрещает менять ресторан заказа, если в нём уже есть блюда другого ресторана. BEFORE UPDATE OF restaurant_id ON "order".';

CREATE TRIGGER trg_order_restaurant_update
    BEFORE UPDATE OF restaurant_id ON "order"
    FOR EACH ROW
    EXECUTE FUNCTION check_order_restaurant_update();

COMMENT ON TRIGGER trg_order_restaurant_update ON "order" IS
    'BR-7.3: смена ресторана не должна нарушать состав уже добавленных позиций.';

-- ---------------------------------------------------------------------------
-- BR-9.1 / BR-9.2: полиморфная ссылка отзыва должна указывать на
-- существующую сущность. Для отзыва на заказ entity_id = order_id.
--
-- Алгоритм:
--   'блюдо'    -> entity_id существует в product;
--   'ресторан' -> entity_id существует в restaurant;
--   'заказ'    -> entity_id совпадает с order_id (сам заказ уже гарантирован FK).
--
-- Декларативно нельзя: целевая таблица зависит от значения entity_type,
-- а полиморфных FK PostgreSQL не поддерживает.
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

COMMENT ON FUNCTION validate_review_entity() IS
    'BR-9.1: проверяет, что полиморфная ссылка review.entity_id указывает на существующую сущность нужного типа. BEFORE INSERT/UPDATE ON review.';

CREATE TRIGGER trg_review_entity_validate
    BEFORE INSERT OR UPDATE ON review
    FOR EACH ROW
    EXECUTE FUNCTION validate_review_entity();

COMMENT ON TRIGGER trg_review_entity_validate ON review IS
    'BR-9.1: валидация полиморфной ссылки отзыва.';

-- ---------------------------------------------------------------------------
-- BR-9.6 / BR-9.7: пересчёт агрегированного рейтинга блюда или ресторана.
--
-- Алгоритм:
--   DELETE -> пересчитываем сущность из OLD;
--   UPDATE со сменой entity_type/entity_id -> пересчитываем и OLD, и NEW;
--   INSERT и обычный UPDATE -> пересчитываем NEW.
--   Для entity_type = 'заказ' не делаем ничего: у заказа агрегата нет.
--
-- Пересчёт — один UPDATE с подзапросом AVG по review. Если отзывов больше
-- нет, AVG возвращает NULL, и rating становится NULL (BR-9.7).
--
-- Рекурсии нет: триггер висит на review, а UPDATE идёт в product/restaurant.
-- ---------------------------------------------------------------------------
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

    -- UPDATE, при котором отзыв переехал на другую сущность:
    -- старую сущность тоже нужно пересчитать.
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

COMMENT ON FUNCTION rating_change() IS
    'BR-9.6, BR-9.7: после INSERT/UPDATE/DELETE отзыва пересчитывает product.rating или restaurant.rating как AVG(review.rating); для entity_type = ''заказ'' ничего не делает. AFTER INSERT/UPDATE/DELETE ON review.';

CREATE TRIGGER trg_rating_change
    AFTER INSERT OR UPDATE OR DELETE ON review
    FOR EACH ROW
    EXECUTE FUNCTION rating_change();

COMMENT ON TRIGGER trg_rating_change ON review IS
    'BR-9.6, BR-9.7: поддержка агрегированных рейтингов блюда и ресторана.';

-- ---------------------------------------------------------------------------
-- BR-8.7: агрегированный статус оплаты заказа по попыткам.
--
-- Алгоритм (порядок важен):
--   1. Есть успешная попытка            -> 'оплачен';
--   2. успешных нет, есть в_обработке   -> 'ожидает';
--   3. успешных нет, все попытки ошибки -> 'ошибка';
--   4. попыток нет                      -> 'ожидает'.
--
-- Декларативно нельзя: значение зависит от агрегата по другой таблице.
-- Пересчёт встроен в триггерную функцию: отдельного хелпера нет.
-- ---------------------------------------------------------------------------
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

COMMENT ON FUNCTION payment_pay_status_change() IS
    'BR-8.7: после любого изменения payment пересчитывает "order".pay_status по попыткам: успех -> оплачен, в_обработке -> ожидает, только ошибки -> ошибка, попыток нет -> ожидает. AFTER INSERT/UPDATE/DELETE ON payment.';

CREATE TRIGGER trg_payment_pay_status
    AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW
    EXECUTE FUNCTION payment_pay_status_change();

COMMENT ON TRIGGER trg_payment_pay_status ON payment IS
    'BR-8.7: поддержка агрегированного статуса оплаты заказа.';

-- ---------------------------------------------------------------------------
-- BR-8.4: сумма попытки оплаты равна общей сумме заказа.
--
-- Алгоритм:
--   1. Читаем "order".total_amount по NEW.order_id.
--   2. Если заказа нет — исключение.
--   3. Если NEW.amount <> total_amount — исключение.
--
-- Декларативно нельзя: CHECK не может прочитать значение из другой таблицы.
-- ---------------------------------------------------------------------------
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

COMMENT ON FUNCTION check_payment_amount() IS
    'BR-8.4: запрещает попытку оплаты на сумму, отличную от "order".total_amount. BEFORE INSERT/UPDATE ON payment.';

CREATE TRIGGER trg_payment_amount_check
    BEFORE INSERT OR UPDATE ON payment
    FOR EACH ROW
    EXECUTE FUNCTION check_payment_amount();

COMMENT ON TRIGGER trg_payment_amount_check ON payment IS
    'BR-8.4: сумма попытки оплаты равна общей сумме заказа.';
