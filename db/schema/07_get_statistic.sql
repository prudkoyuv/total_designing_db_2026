-- ============================================================================
-- FoodExpress / FOOD-106
-- get_statistic() — статистика по ресторанам (BR-11.8: без лишних сканов).
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
               coalesce(sum(d.total_amount), 0)::numeric       AS total_amount,
               coalesce(round(avg(d.total_amount), 2), 0)::numeric AS avg_amount
          FROM restaurant r
          LEFT JOIN delivered d ON d.restaurant_id = r.restaurant_id
         GROUP BY r.restaurant_id, r.restaurant_name
    ),
    product_stats AS (
        SELECT d.restaurant_id,
               p.product_name,
               sum(os.quantity) AS quantity,
               row_number() OVER (
                   PARTITION BY d.restaurant_id
                   ORDER BY sum(os.quantity) DESC, random()
               ) AS rn
          FROM delivered d
          JOIN order_structure os ON os.order_id = d.order_id
          JOIN product p ON p.product_id = os.product_id
         GROUP BY d.restaurant_id, p.product_id, p.product_name
    ),
    client_stats AS (
        SELECT d.restaurant_id,
               c.login,
               count(*) AS orders_count,
               row_number() OVER (
                   PARTITION BY d.restaurant_id
                   ORDER BY count(*) DESC, random()
               ) AS rn
          FROM delivered d
          JOIN client c ON c.client_id = d.client_id
         GROUP BY d.restaurant_id, c.client_id, c.login
    )
    SELECT rs.restaurant_name,
           ps.product_name,
           rs.total_amount,
           rs.avg_amount,
           cs.login
      FROM rest_stats rs
      LEFT JOIN product_stats ps
             ON ps.restaurant_id = rs.restaurant_id AND ps.rn = 1
      LEFT JOIN client_stats cs
             ON cs.restaurant_id = rs.restaurant_id AND cs.rn = 1
     ORDER BY rs.restaurant_name;
$$;
