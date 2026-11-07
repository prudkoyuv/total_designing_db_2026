-- ============================================================================
-- FoodExpress — протокол проверок под учётной записью inspector (FOOD-109).
-- Запускать от имени inspector.
-- ============================================================================

SET search_path TO prudko_food, exts;

\echo '=== A.2. Кто мы ==='
SELECT current_user, current_schema, current_setting('search_path') AS search_path;

\echo '=== B.1-B.5. Схема, exts, таблицы, ID, enum-типы ==='
SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'prudko_food';
SELECT extname, extnamespace::regnamespace AS schema
  FROM pg_extension WHERE extname = 'uuid-ossp';
SELECT count(*) AS tables
  FROM information_schema.tables
 WHERE table_schema = 'prudko_food';
SELECT count(*) AS non_uuid_ids
  FROM information_schema.columns
 WHERE table_schema = 'prudko_food'
   AND column_name LIKE '%_id'
   AND data_type <> 'uuid';
SELECT count(*) AS enum_types
  FROM (
      SELECT t.typname
        FROM pg_type t
        JOIN pg_enum e ON e.enumtypid = t.oid
        JOIN pg_namespace n ON n.oid = t.typnamespace
       WHERE n.nspname = 'prudko_food'
       GROUP BY t.typname
  ) x;

\echo '=== B.6. FK-ограничения ==='
SELECT count(*) AS fk_count
  FROM pg_constraint
 WHERE contype = 'f'
   AND connamespace = 'prudko_food'::regnamespace;

\echo '=== C.1-C.3. erase + insert + распределение ==='
CALL erase_test_data();
CALL insert_test_data(10);

SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
ORDER BY tbl;

\echo '=== E.1. add_product под inspector ==='
SELECT count(*) AS before FROM product;

DO $$
DECLARE
    v_restaurant uuid;
    v_category uuid;
BEGIN
    SELECT restaurant_id INTO v_restaurant
      FROM restaurant ORDER BY restaurant_id LIMIT 1;
    SELECT product_category_id INTO v_category
      FROM product_category ORDER BY product_category_id LIMIT 1;

    CALL add_product(
        p_restaurant_id       => v_restaurant,
        p_product_category_id => v_category,
        p_name                => 'Блюдо инспектора',
        p_price               => 321,
        p_description         => 'Проверка прав inspector',
        p_status              => 'доступно',
        p_rating              => 4.0
    );
END;
$$;

SELECT count(*) AS after FROM product;
DELETE FROM product WHERE product_name = 'Блюдо инспектора';

\echo '=== E.5-E.7. get_statistic и courier_salary ==='
SELECT count(*) AS statistic_rows FROM get_statistic();
SELECT count(*) AS current_month_pay_rows
  FROM courier_pay
 WHERE year = extract(year FROM localtimestamp)
   AND month = extract(month FROM localtimestamp);
CALL courier_salary();
SELECT count(*) AS current_month_pay_rows_after
  FROM courier_pay
 WHERE year = extract(year FROM localtimestamp)
   AND month = extract(month FROM localtimestamp);

\echo '=== F. Представление how_much_money ==='
SELECT count(*) AS view_rows,
       min(year_month) AS first_month,
       max(year_month) AS last_month
  FROM how_much_money;
SELECT * FROM how_much_money ORDER BY year_month LIMIT 3;

\echo '=== G.1. Права на схему ==='
SELECT nspname AS schema_name,
       has_schema_privilege('inspector', nspname, 'USAGE')  AS usage,
       has_schema_privilege('inspector', nspname, 'CREATE') AS create
  FROM pg_namespace
 WHERE nspname = 'prudko_food';

\echo '=== G.2. Права на таблицы ==='
SELECT table_name, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privs
  FROM information_schema.role_table_grants
 WHERE grantee = 'inspector' AND table_schema = 'prudko_food'
 GROUP BY table_name
 ORDER BY table_name;

\echo '=== G.3. information_schema ==='
SELECT count(*) AS tables_in_information_schema
  FROM information_schema.tables
 WHERE table_schema = 'prudko_food';

\echo '=== G.4. pg_catalog ==='
SELECT count(*) AS tables_in_pg_catalog
  FROM pg_catalog.pg_tables
 WHERE schemaname = 'prudko_food';

\echo '=== G.5. Все вызовы ==='
SELECT count(*) AS final_statistic_rows FROM get_statistic();
SELECT count(*) AS final_orders FROM "order";
