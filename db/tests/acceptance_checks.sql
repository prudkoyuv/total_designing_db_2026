-- ============================================================================
-- FoodExpress — проверки приёмки (read-only, кроме помеченных мест).
-- Запуск: psql -U inspector -d <db> -f acceptance_checks.sql
-- ============================================================================

SET search_path TO prudko_food, exts;

\echo '=== 1. Распределение строк (BR-11.7) ==='
SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'order_structure', count(*) FROM order_structure
UNION ALL SELECT 'client_address', count(*) FROM client_address
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay
ORDER BY tbl;

\echo '=== 2. Целостность и бизнес-правила (все значения должны быть 0) ==='
SELECT 'empty_strings' AS check_name, count(*) AS bad
  FROM client WHERE login = '' OR password = '' OR phone_number = ''
UNION ALL SELECT 'bad_password_md5', count(*) FROM client WHERE password !~ '^[0-9a-f]{32}$'
UNION ALL SELECT 'total_lt_1000', count(*) FROM "order" WHERE total_amount < 1000
UNION ALL SELECT 'bad_commission', count(*) FROM "order" WHERE round(order_amount * 0.10, 2) <> commission
UNION ALL SELECT 'bad_total', count(*) FROM "order" WHERE round(order_amount + commission, 2) <> total_amount
UNION ALL SELECT 'bad_delivery_ts', count(*) FROM "order" WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp
UNION ALL SELECT 'delivered_no_ts', count(*) FROM "order" WHERE status = 'доставлен' AND delivery_timestamp IS NULL
UNION ALL SELECT 'address_not_owned', count(*)
  FROM "order" o
  LEFT JOIN client_address ca ON ca.client_id = o.client_id AND ca.address_id = o.address_id
 WHERE ca.client_id IS NULL
UNION ALL SELECT 'wrong_restaurant_product', count(DISTINCT os.order_id)
  FROM order_structure os
  JOIN "order" o ON o.order_id = os.order_id
  JOIN product p ON p.product_id = os.product_id
 WHERE p.restaurant_id <> o.restaurant_id
UNION ALL SELECT 'payment_amount_mismatch', count(*)
  FROM payment p JOIN "order" o ON o.order_id = p.order_id
 WHERE p.amount <> o.total_amount
UNION ALL SELECT 'orders_without_success', count(*)
  FROM "order" o
 WHERE NOT EXISTS (SELECT 1 FROM payment p WHERE p.order_id = o.order_id AND p.status = 'успех')
UNION ALL SELECT 'orders_multiple_success', count(*)
  FROM (SELECT order_id FROM payment WHERE status = 'успех' GROUP BY order_id HAVING count(*) > 1) x
UNION ALL SELECT 'ca_dupes', count(*)
  FROM (SELECT client_id, address_id FROM client_address GROUP BY 1,2 HAVING count(*) > 1) x
UNION ALL SELECT 'os_dupes', count(*)
  FROM (SELECT order_id, product_id FROM order_structure GROUP BY 1,2 HAVING count(*) > 1) x
UNION ALL SELECT 'bad_work_hours', count(*) FROM restaurant WHERE work_end <= work_start
UNION ALL SELECT 'bad_dismissal', count(*) FROM courier WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date
UNION ALL SELECT 'dismissed_no_date', count(*) FROM courier WHERE status = 'уволен' AND dismissal_date IS NULL
UNION ALL SELECT 'bad_review_rating', count(*) FROM review WHERE rating < 1 OR rating > 5
UNION ALL SELECT 'bad_product_rating', count(*) FROM product WHERE rating IS NOT NULL AND (rating < 0 OR rating > 5)
UNION ALL SELECT 'bad_restaurant_rating', count(*) FROM restaurant WHERE rating IS NOT NULL AND (rating < 0 OR rating > 5)
ORDER BY check_name;

\echo '=== 2a. Положительные проверки ==='
SELECT count(*) AS active_couriers FROM courier WHERE status <> 'уволен';

\echo '=== 3. Осиротевшие FK ==='
SELECT 'order_structure -> order' AS fk, count(*) AS orphans
  FROM order_structure os LEFT JOIN "order" o ON os.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'order_structure -> product', count(*)
  FROM order_structure os LEFT JOIN product p ON os.product_id = p.product_id WHERE p.product_id IS NULL
UNION ALL SELECT 'payment -> order', count(*)
  FROM payment pmt LEFT JOIN "order" o ON pmt.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'review -> order', count(*)
  FROM review r LEFT JOIN "order" o ON r.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'courier_pay -> courier', count(*)
  FROM courier_pay cp LEFT JOIN courier c ON cp.courier_id = c.courier_id WHERE c.courier_id IS NULL
UNION ALL SELECT 'client_address -> client', count(*)
  FROM client_address ca LEFT JOIN client c ON ca.client_id = c.client_id WHERE c.client_id IS NULL
UNION ALL SELECT 'client_address -> address', count(*)
  FROM client_address ca LEFT JOIN address a ON ca.address_id = a.address_id WHERE a.address_id IS NULL;

\echo '=== 4. courier_pay: amount = coefficient_used * sum(commission) ==='
SELECT count(*) AS rows_total,
       count(*) FILTER (WHERE cp.amount = round(coalesce(x.commission, 0) * cp.coefficient_used, 2)) AS rows_ok
  FROM courier_pay cp
  LEFT JOIN (
      SELECT o.courier_id,
             extract(year FROM o.order_timestamp)::int AS y,
             extract(month FROM o.order_timestamp)::int AS m,
             sum(o.commission) AS commission
        FROM "order" o
       WHERE o.status = 'доставлен'
       GROUP BY o.courier_id, extract(year FROM o.order_timestamp), extract(month FROM o.order_timestamp)
  ) x ON x.courier_id = cp.courier_id AND x.y = cp.year AND x.m = cp.month;

\echo '=== 5. Рейтинги соответствуют отзывам ==='
SELECT count(*) AS product_rating_mismatch
  FROM product p
 WHERE p.rating IS DISTINCT FROM (
       SELECT round(avg(r.rating), 2) FROM review r
        WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id
 );
SELECT count(*) AS restaurant_rating_mismatch
  FROM restaurant r
 WHERE r.rating IS DISTINCT FROM (
       SELECT round(avg(rv.rating), 2) FROM review rv
        WHERE rv.entity_type = 'ресторан' AND rv.entity_id = r.restaurant_id
 );

\echo '=== 6. Месяцы и отчёт how_much_money ==='
SELECT count(*) AS months,
       min(year_month) AS first_month,
       max(year_month) AS last_month
  FROM how_much_money;

SELECT count(*) AS formula_mismatch
  FROM how_much_money
 WHERE commission <> sum_with_commission - sum_no_commission
    OR net_profit <> commission - courier_pay
    OR (prev_commission IS NOT NULL AND commission_diff <> commission - prev_commission)
    OR (prev_commission IS NULL AND commission_diff IS NOT NULL);

\echo '=== 7. get_statistic: строки и null-ы ==='
SELECT count(*) AS rows,
       count(*) FILTER (WHERE best_product_name IS NULL) AS null_best_product,
       count(*) FILTER (WHERE best_user IS NULL) AS null_best_user,
       count(*) FILTER (WHERE total_amount < avg_amount) AS total_lt_avg
  FROM get_statistic();

\echo '=== 8. Коэффициенты после генерации ==='
SELECT c.status, c.coefficient, count(*) AS couriers
  FROM courier c
 GROUP BY c.status, c.coefficient
 ORDER BY c.status, c.coefficient;

\echo '=== 9. 6 месяцев courier_pay у каждого курьера ==='
SELECT count(*) AS couriers_without_6_months
  FROM (
      SELECT courier_id, count(*) AS cnt FROM courier_pay GROUP BY courier_id
  ) x
 WHERE cnt <> 6;
