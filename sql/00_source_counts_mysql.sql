-- the SOURCE side of the reconciliation: run this on Cloud SQL (MySQL 8.0), read-only SELECTs.
-- From Cloud Shell, in the Cloud SQL project folder (it asks for the root password; do not put it in a file):
--   source env.sh && gcloud sql connect "$INSTANCE" --user=root --quiet < sql/00_source_counts_mysql.sql
-- Expected: the numbers in data/source_counts.csv and data/source_control_totals.csv (computed from the dump that was imported).
USE sakila;

-- 1. Row counts, table by table (16 base tables, 47,268 rows)
SELECT 'actor' AS tbl, COUNT(*) AS source_rows FROM actor UNION ALL
SELECT 'address', COUNT(*) FROM address UNION ALL
SELECT 'category', COUNT(*) FROM category UNION ALL
SELECT 'city', COUNT(*) FROM city UNION ALL
SELECT 'country', COUNT(*) FROM country UNION ALL
SELECT 'customer', COUNT(*) FROM customer UNION ALL
SELECT 'film', COUNT(*) FROM film UNION ALL
SELECT 'film_actor', COUNT(*) FROM film_actor UNION ALL
SELECT 'film_category', COUNT(*) FROM film_category UNION ALL
SELECT 'film_text', COUNT(*) FROM film_text UNION ALL
SELECT 'inventory', COUNT(*) FROM inventory UNION ALL
SELECT 'language', COUNT(*) FROM language UNION ALL
SELECT 'payment', COUNT(*) FROM payment UNION ALL
SELECT 'rental', COUNT(*) FROM rental UNION ALL
SELECT 'staff', COUNT(*) FROM staff UNION ALL
SELECT 'store', COUNT(*) FROM store;

SELECT COUNT(*) AS base_tables FROM information_schema.tables WHERE table_schema = 'sakila' AND table_type = 'BASE TABLE';          -- 16
SELECT COUNT(*) AS foreign_keys FROM information_schema.referential_constraints WHERE constraint_schema = 'sakila';                  -- 22

-- 2. Control totals (same checks, same order as sql/02_oltp_load_reconcile.sql)
SELECT 'payment SUM(amount)' AS check_name, CAST(SUM(amount) AS CHAR) AS source_value FROM payment UNION ALL
SELECT 'payment rental_id IS NULL', CAST(SUM(rental_id IS NULL) AS CHAR) FROM payment UNION ALL
SELECT 'rental return_date IS NULL', CAST(SUM(return_date IS NULL) AS CHAR) FROM rental UNION ALL
SELECT 'rental MAX(rental_id)', CAST(MAX(rental_id) AS CHAR) FROM rental UNION ALL
SELECT 'film SUM(length)', CAST(SUM(length) AS CHAR) FROM film UNION ALL
SELECT 'film SUM(rental_rate)', CAST(SUM(rental_rate) AS CHAR) FROM film UNION ALL
SELECT 'film SUM(replacement_cost)', CAST(SUM(replacement_cost) AS CHAR) FROM film UNION ALL
SELECT 'film special_features IS NOT NULL', CAST(SUM(special_features IS NOT NULL) AS CHAR) FROM film UNION ALL
SELECT 'film rating = PG-13', CAST(SUM(rating = 'PG-13') AS CHAR) FROM film UNION ALL
SELECT 'customer active (TINYINT(1) = 1)', CAST(SUM(active = 1) AS CHAR) FROM customer UNION ALL
SELECT 'staff 1 LENGTH(picture) bytes', CAST(LENGTH(picture) AS CHAR) FROM staff WHERE staff_id = 1 UNION ALL
SELECT 'city SUM(LENGTH(city)) characters', CAST(SUM(CHAR_LENGTH(city)) AS CHAR) FROM city UNION ALL
SELECT 'staff 1 MD5(HEX(picture))', MD5(HEX(picture)) FROM staff WHERE staff_id = 1 UNION ALL
SELECT 'address address2 IS NULL', CAST(SUM(address2 IS NULL) AS CHAR) FROM address UNION ALL
SELECT 'address address2 = empty string', CAST(SUM(address2 = '') AS CHAR) FROM address UNION ALL
SELECT 'address location IS NOT NULL', CAST(SUM(location IS NOT NULL) AS CHAR) FROM address UNION ALL
SELECT 'address location outside lon/lat range', CAST(SUM(ST_X(location) NOT BETWEEN -180 AND 180 OR ST_Y(location) NOT BETWEEN -90 AND 90) AS CHAR) FROM address;
