-- ============================================================================
-- FoodExpress — проверки FOOD-106 и FOOD-108 (read-only).
-- ============================================================================

SET search_path TO prudko_food, exts;

\echo '=== F.1. Колонки how_much_money ==='
SELECT column_name, data_type
  FROM information_schema.columns
 WHERE table_schema = 'prudko_food'
   AND table_name = 'how_much_money'
 ORDER BY ordinal_position;

\echo '=== F.2. Содержимое how_much_money ==='
SELECT * FROM how_much_money ORDER BY year_month;

\echo '=== F.3. Суммы и формулы ==='
SELECT count(*) AS months,
       count(*) FILTER (WHERE commission <> sum_with_commission - sum_no_commission) AS bad_commission,
       count(*) FILTER (WHERE net_profit <> commission - courier_pay) AS bad_net_profit,
       count(*) FILTER (WHERE prev_commission IS NOT NULL
                         AND commission_diff <> commission - prev_commission) AS bad_diff,
       count(*) FILTER (WHERE prev_commission IS NULL AND commission_diff IS NOT NULL) AS first_month_diff
  FROM how_much_money;

\echo '=== E.5. get_statistic ==='
SELECT * FROM get_statistic() ORDER BY restaurant_name;

\echo '=== H.3. EXPLAIN ANALYZE get_statistic ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM get_statistic();
