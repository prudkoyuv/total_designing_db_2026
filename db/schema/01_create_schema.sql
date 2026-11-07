-- ============================================================================
-- FoodExpress / FOOD-101
-- Схема приложения. Схема exts с uuid-ossp создаётся окружением (BR-13.3)
-- и этим скриптом НЕ пересоздаётся.
--
-- Для локального стенда exts создаётся один раз вручную:
--   CREATE SCHEMA IF NOT EXISTS exts;
--   CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA exts;
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS prudko_food;

SET search_path TO prudko_food, exts, public;
