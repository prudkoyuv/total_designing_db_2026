-- ============================================================================
-- FoodExpress / FOOD-109
-- Создание учётной записи аудитора inspector и выдача ей прав.
--
-- Принципы:
--   * если роль уже существует, мы её НЕ изменяем: ни пароль, ни атрибуты,
--     ни search_path. Это чужая учётная запись, и менять её без запроса
--     нельзя;
--   * CREATE ROLE по умолчанию создаёт NOSUPERUSER NOCREATEDB NOCREATEROLE,
--     поэтому явно выставлять эти атрибуты не нужно;
--   * права выдаются только на существующие объекты схемы. Права «на
--     будущие объекты» (ALTER DEFAULT PRIVILEGES) не нужны: в BR и FOOD-109
--     такого требования нет, а выдача доступа к ещё не созданным данным —
--     лишний риск;
--   * USAGE на information_schema и pg_catalog по умолчанию есть у PUBLIC,
--     поэтому отдельные GRANT не выдаются. То, что права не отозваны,
--     проверяется в db/tests.md (G.3, G.4).
--
-- Скрипт идемпотентен: его можно запускать повторно после восстановления
-- бэкапа или пересоздания объектов.
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
        RAISE NOTICE 'Роль inspector создана';
    ELSE
        RAISE NOTICE 'Роль inspector уже существует: пароль и атрибуты не изменяются';
    END IF;
END;
$$;

-- FOOD-109: ALL PRIVILEGES на схему приложения (USAGE + CREATE).
GRANT ALL PRIVILEGES ON SCHEMA prudko_food TO inspector;

-- FOOD-109: доступ ко всем таблицам и представлениям схемы.
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA prudko_food TO inspector;

-- FOOD-109: вызов всех функций и процедур (ALL ROUTINES покрывает и то, и другое).
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA prudko_food TO inspector;

-- FOOD-109: exts нужен для exts.uuid_generate_v4() (BR-11.1, BR-13.3).
GRANT USAGE ON SCHEMA exts TO inspector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA exts TO inspector;
