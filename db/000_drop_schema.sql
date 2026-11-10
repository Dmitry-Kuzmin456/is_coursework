\set ON_ERROR_STOP on
-- Удаляет только схему remkomstroy и её данные в текущей БД.
-- Для Helios: psql -X -h pg -d studs -f db/000_drop_schema.sql
BEGIN;
DROP SCHEMA IF EXISTS remkomstroy CASCADE;
COMMIT;
