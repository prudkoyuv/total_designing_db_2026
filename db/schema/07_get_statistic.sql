-- ============================================================================
-- FoodExpress / FOOD-106
-- get_statistic() — по каждому ресторану: сумма и средний чек доставленных
-- заказов, лучшее блюдо, лучший клиент. "order" читается один раз (BR-11.8).
-- random() используется только для разрешения ничьих по FOOD-106, а не для
-- ранжирования. DISTINCT ON выбран вместо row_number(): одна сортировка на
-- группу, без окна и повторного прохода по строкам.
-- Контракт колонок — BR-13.2.
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
        -- sum(quantity), при равенстве — случайную (FOOD-106).
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
        -- при равенстве — случайный. row_number() здесь не нужен.
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
