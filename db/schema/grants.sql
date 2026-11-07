-- ============================================================================
-- FoodExpress / FOOD-109
-- Пользователь inspector и его права. Запускать суперпользователем после
-- восстановления бэкапа (FOOD-110).
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        EXECUTE 'CREATE ROLE inspector LOGIN PASSWORD ''NetoSQL2025''';
    ELSE
        EXECUTE 'ALTER ROLE inspector WITH LOGIN PASSWORD ''NetoSQL2025''';
    END IF;
END;
$$;

ALTER ROLE inspector NOSUPERUSER NOCREATEDB NOCREATEROLE;

-- Удобство проверки: можно вызывать объекты без ручного SET search_path.
ALTER ROLE inspector SET search_path TO prudko_food, exts, public;

-- Права на схему приложения (USAGE + CREATE = ALL PRIVILEGES).
GRANT ALL PRIVILEGES ON SCHEMA prudko_food TO inspector;

-- Таблицы, представления и последовательности.
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA prudko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA prudko_food TO inspector;
GRANT SELECT ON prudko_food.how_much_money TO inspector;

-- Функции и процедуры.
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA prudko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL PROCEDURES IN SCHEMA prudko_food TO inspector;

-- exts: uuid_generate_v4() (BR-13.3).
GRANT USAGE ON SCHEMA exts TO inspector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA exts TO inspector;

-- Явно подтверждаем системные схемы (FOOD-109).
GRANT USAGE ON SCHEMA information_schema TO inspector;
GRANT USAGE ON SCHEMA pg_catalog TO inspector;

-- Права на объекты, которые могут быть созданы позже.
ALTER DEFAULT PRIVILEGES IN SCHEMA prudko_food
    GRANT ALL PRIVILEGES ON TABLES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA prudko_food
    GRANT ALL PRIVILEGES ON SEQUENCES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA prudko_food
    GRANT ALL PRIVILEGES ON FUNCTIONS TO inspector;

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO inspector', current_database());
END;
$$;
