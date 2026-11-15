-- ============================================================================
-- FoodExpress / FOOD-109
-- Роль inspector: создаётся при отсутствии, пароль всегда приводится к
-- требуемому. Скрипт идемпотентен.
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector;
    END IF;
END;
$$;

ALTER ROLE inspector LOGIN PASSWORD 'NetoSQL2025';

GRANT ALL PRIVILEGES ON SCHEMA prudko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA prudko_food TO inspector;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA prudko_food TO inspector;
GRANT USAGE ON SCHEMA exts TO inspector;
