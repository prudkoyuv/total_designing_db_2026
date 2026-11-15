-- ============================================================================
-- FoodExpress / FOOD-101
-- Схема приложения. exts с uuid-ossp создаётся окружением и не пересоздаётся
-- (BR-13.3); для локального стенда: CREATE SCHEMA IF NOT EXISTS exts;
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA exts;
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS prudko_food;

SET search_path TO prudko_food, exts, public;
