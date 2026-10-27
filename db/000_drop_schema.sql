-- Удаляет схему РемКомСтрой вместе с таблицами, типами и данными.
-- Базу studs на helios не трогает.
--
--   psql -h pg -d studs -f db/000_drop_schema.sql

DROP SCHEMA IF EXISTS remkomstroy CASCADE;
