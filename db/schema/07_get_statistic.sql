-- ============================================================================
-- FoodExpress / FOOD-106
-- get_statistic() — статистика по ресторанам.
--
-- Оптимизация (BR-11.8):
--   * "order" читается один раз — в материализованном CTE delivered;
--   * лучший товар и лучший клиент выбираются через DISTINCT ON, а не через
--     row_number(): оконная функция нумерует все строки каждой группы, хотя
--     нужна только первая;
--   * random() стоит последним ключом сортировки и нужен только для
--     разрешения ничьих — этого прямо требует FOOD-106 («если таких
--     несколько — случайное»).
--
-- Контракт имён и типов колонок — BR-13.2, менять нельзя.
-- ============================================================================

SET search_path TO prudko_food, exts, public;

CREATE OR REPLACE FUNCTION get_statistic()
RETURNS TABLE (
    restaurant_name   varchar,
    best_product_name varchar,
    total_amount      numeric,
    avg_amount        numeric,
    best_user         varchar
)
LANGUAGE sql
SET search_path TO prudko_food, exts, public
AS $$
    WITH delivered AS MATERIALIZED (
        -- Один скан заказов: дальше используются только доставленные.
        SELECT o.order_id,
               o.restaurant_id,
               o.client_id,
               o.total_amount
          FROM "order" o
         WHERE o.status = 'доставлен'
    ),
    rest_stats AS (
        SELECT r.restaurant_id,
               r.restaurant_name,
               coalesce(sum(d.total_amount), 0)::numeric           AS total_amount,
               coalesce(round(avg(d.total_amount), 2), 0)::numeric AS avg_amount
          FROM restaurant r
          LEFT JOIN delivered d ON d.restaurant_id = r.restaurant_id
         GROUP BY r.restaurant_id, r.restaurant_name
    ),
    product_stats AS (
        -- DISTINCT ON берёт ровно одну строку на ресторан: максимальную
        -- sum(quantity), при равенстве — случайную.
        SELECT DISTINCT ON (d.restaurant_id)
               d.restaurant_id,
               p.product_name
          FROM delivered d
          JOIN order_structure os ON os.order_id = d.order_id
          JOIN product p ON p.product_id = os.product_id
         GROUP BY d.restaurant_id, p.product_id, p.product_name
         ORDER BY d.restaurant_id, sum(os.quantity) DESC, random()
    ),
    client_stats AS (
        -- Аналогично: клиент с максимальным числом доставленных заказов;
        -- при равенстве — случайный.
        SELECT DISTINCT ON (d.restaurant_id)
               d.restaurant_id,
               c.login
          FROM delivered d
          JOIN client c ON c.client_id = d.client_id
         GROUP BY d.restaurant_id, c.client_id, c.login
         ORDER BY d.restaurant_id, count(*) DESC, random()
    )
    SELECT rs.restaurant_name,
           ps.product_name,
           rs.total_amount,
           rs.avg_amount,
           cs.login
      FROM rest_stats rs
      LEFT JOIN product_stats ps ON ps.restaurant_id = rs.restaurant_id
      LEFT JOIN client_stats cs ON cs.restaurant_id = rs.restaurant_id
     ORDER BY rs.restaurant_name;
$$;

COMMENT ON FUNCTION get_statistic() IS
    'FOOD-106: по каждому ресторану — сумма и средний чек доставленных заказов, самое покупаемое блюдо и самый частый клиент. Один скан "order"; DISTINCT ON вместо оконных функций; random() только для разрешения ничьих.';
