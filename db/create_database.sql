\set ON_ERROR_STOP on
-- Запускать через psql с подключением к служебной БД postgres.
-- Имя: psql -d postgres -v db_name=remkomstroy -f db/create_database.sql
\if :{?db_name}
\else
  \set db_name remkomstroy
\endif
CREATE DATABASE :"db_name" TEMPLATE template0 ENCODING 'UTF8';
\connect :db_name
\ir install.sql
