\set ON_ERROR_STOP on
-- Запускать из postgres, а не из удаляемой БД. FORCE не используется.
\if :{?db_name}
\else
  \set db_name remkomstroy
\endif
DROP DATABASE IF EXISTS :"db_name";
