-- ============================================================================
-- FoodExpress / FOOD-109
-- Роль inspector создаётся только при отсутствии. Пароль существующей роли
-- не изменяется. Гранты выдаются после восстановления схемы, когда все
-- объекты уже существуют; ALTER DEFAULT PRIVILEGES не нужен.
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    ELSE
        RAISE NOTICE 'Роль inspector уже существует; пароль не изменяется';
    END IF;
END;
$$;

GRANT ALL PRIVILEGES ON SCHEMA prudko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA prudko_food TO inspector;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA prudko_food TO inspector;
GRANT USAGE ON SCHEMA exts TO inspector;
