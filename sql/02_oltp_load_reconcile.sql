-- 02 Sakila into Snowflake: COPY INTO the 16 tables, then reconcile against the source.
-- Run after sql/01_oltp_ddl.sql AND after the 16 CSVs are in @SAKILA.OLTP.SAKILA_STAGE (docs/migration.md, step 3).
-- Run as YOU (SYSADMIN). Every COPY aborts on the first bad row (ON_ERROR = ABORT_STATEMENT): a load either completes or says why not.
-- Do not run the COPY block twice on the same tables: Snowflake does not enforce keys, so a second load of different file names would duplicate rows.
-- To start over, re-run 04 (CREATE OR REPLACE) and then this file.
-- Source numbers below come from data/source_counts.csv and data/source_control_totals.csv (written by export_sakila_csv.py).

USE ROLE SYSADMIN;
USE WAREHOUSE CLASS_WH;
USE SCHEMA SAKILA.OLTP;

LIST @sakila_stage;   -- 16 files: <table>.csv or <table>.csv.gz

-- Load. PATTERN is anchored so that actor.csv does not also match film_actor.csv.
COPY INTO country       FROM @sakila_stage PATTERN = '(.*/)?country[.]csv([.]gz)?'       FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO city          FROM @sakila_stage PATTERN = '(.*/)?city[.]csv([.]gz)?'          FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
-- address: the WKT text in column 8 is turned into a GEOMETRY while loading
COPY INTO address FROM (SELECT $1, $2, $3, $4, $5, $6, $7, TO_GEOMETRY($8), $9 FROM @sakila_stage)
                                       PATTERN = '(.*/)?address[.]csv([.]gz)?'                                 FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO category      FROM @sakila_stage PATTERN = '(.*/)?category[.]csv([.]gz)?'      FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO language      FROM @sakila_stage PATTERN = '(.*/)?language[.]csv([.]gz)?'      FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO actor         FROM @sakila_stage PATTERN = '(.*/)?actor[.]csv([.]gz)?'         FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO staff         FROM @sakila_stage PATTERN = '(.*/)?staff[.]csv([.]gz)?'         FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO store         FROM @sakila_stage PATTERN = '(.*/)?store[.]csv([.]gz)?'         FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO customer      FROM @sakila_stage PATTERN = '(.*/)?customer[.]csv([.]gz)?'      FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO film          FROM @sakila_stage PATTERN = '(.*/)?film[.]csv([.]gz)?'          FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO film_actor    FROM @sakila_stage PATTERN = '(.*/)?film_actor[.]csv([.]gz)?'    FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO film_category FROM @sakila_stage PATTERN = '(.*/)?film_category[.]csv([.]gz)?' FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO film_text     FROM @sakila_stage PATTERN = '(.*/)?film_text[.]csv([.]gz)?'     FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO inventory     FROM @sakila_stage PATTERN = '(.*/)?inventory[.]csv([.]gz)?'     FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO rental        FROM @sakila_stage PATTERN = '(.*/)?rental[.]csv([.]gz)?'        FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;
COPY INTO payment       FROM @sakila_stage PATTERN = '(.*/)?payment[.]csv([.]gz)?'       FILE_FORMAT = (FORMAT_NAME = sakila_csv) ON_ERROR = ABORT_STATEMENT;

-- ===== Checks — every result must say MATCH / 0 =====
-- 1. Row counts, table by table: 16 tables, 47,268 rows in total
SELECT tbl, source_rows, snowflake_rows, IFF(source_rows = snowflake_rows, 'MATCH', 'DIFF') AS result FROM (
  SELECT 'actor' AS tbl,         200 AS source_rows,   (SELECT COUNT(*) FROM actor) AS snowflake_rows UNION ALL
  SELECT 'address',              603,                  (SELECT COUNT(*) FROM address) UNION ALL
  SELECT 'category',             16,                   (SELECT COUNT(*) FROM category) UNION ALL
  SELECT 'city',                 600,                  (SELECT COUNT(*) FROM city) UNION ALL
  SELECT 'country',              109,                  (SELECT COUNT(*) FROM country) UNION ALL
  SELECT 'customer',             599,                  (SELECT COUNT(*) FROM customer) UNION ALL
  SELECT 'film',                 1000,                 (SELECT COUNT(*) FROM film) UNION ALL
  SELECT 'film_actor',           5462,                 (SELECT COUNT(*) FROM film_actor) UNION ALL
  SELECT 'film_category',        1000,                 (SELECT COUNT(*) FROM film_category) UNION ALL
  SELECT 'film_text',            1000,                 (SELECT COUNT(*) FROM film_text) UNION ALL
  SELECT 'inventory',            4581,                 (SELECT COUNT(*) FROM inventory) UNION ALL
  SELECT 'language',             6,                    (SELECT COUNT(*) FROM language) UNION ALL
  SELECT 'payment',              16044,                (SELECT COUNT(*) FROM payment) UNION ALL
  SELECT 'rental',               16044,                (SELECT COUNT(*) FROM rental) UNION ALL
  SELECT 'staff',                2,                    (SELECT COUNT(*) FROM staff) UNION ALL
  SELECT 'store',                2,                    (SELECT COUNT(*) FROM store)
) ORDER BY tbl;

-- 2. Control totals: numbers that would change if a value, a NULL, a boolean, a BLOB or a point were damaged on the way
SELECT check_name, source_value, snowflake_value, IFF(source_value = snowflake_value, 'MATCH', 'DIFF') AS result FROM (
  SELECT 'payment SUM(amount)' AS check_name,                 67406.56 AS source_value,  (SELECT SUM(amount) FROM payment) AS snowflake_value UNION ALL
  SELECT 'payment rental_id IS NULL',                         0,                         (SELECT COUNT_IF(rental_id IS NULL) FROM payment) UNION ALL
  SELECT 'rental return_date IS NULL',                        183,                       (SELECT COUNT_IF(return_date IS NULL) FROM rental) UNION ALL
  SELECT 'rental MAX(rental_id)',                             16049,                     (SELECT MAX(rental_id) FROM rental) UNION ALL
  SELECT 'film SUM(length)',                                  115272,                    (SELECT SUM(length) FROM film) UNION ALL
  SELECT 'film SUM(rental_rate)',                             2980.00,                   (SELECT SUM(rental_rate) FROM film) UNION ALL
  SELECT 'film SUM(replacement_cost)',                        19984.00,                  (SELECT SUM(replacement_cost) FROM film) UNION ALL
  SELECT 'film special_features IS NOT NULL',                 1000,                      (SELECT COUNT_IF(special_features IS NOT NULL) FROM film) UNION ALL
  SELECT 'film rating = PG-13',                               223,                       (SELECT COUNT_IF(rating = 'PG-13') FROM film) UNION ALL
  SELECT 'customer active (BOOLEAN TRUE)',                    584,                       (SELECT COUNT_IF(active) FROM customer) UNION ALL
  SELECT 'staff 1 LENGTH(picture) bytes',                     36365,                     (SELECT LENGTH(picture) FROM staff WHERE staff_id = 1) UNION ALL
  SELECT 'city SUM(LENGTH(city)) characters',                 5090,                      (SELECT SUM(LENGTH(city)) FROM city) UNION ALL
  SELECT 'address address2 IS NULL',                          4,                         (SELECT COUNT_IF(address2 IS NULL) FROM address) UNION ALL
  SELECT 'address address2 = empty string',                   599,                       (SELECT COUNT_IF(address2 = '') FROM address) UNION ALL
  SELECT 'address location IS NOT NULL',                      603,                       (SELECT COUNT_IF(location IS NOT NULL) FROM address) UNION ALL
  SELECT 'address location outside lon/lat range',            6,                         (SELECT COUNT_IF(ST_X(location) NOT BETWEEN -180 AND 180 OR ST_Y(location) NOT BETWEEN -90 AND 90) FROM address)
);

-- 2b. The BLOB, byte for byte: MD5 of the picture as hex text must equal the one computed from the source dump
SELECT 'staff 1 MD5(HEX_ENCODE(picture))' AS check_name, '1f9645743e1ddae309c4bb38ebd6ba9c' AS source_value,
       MD5(HEX_ENCODE(picture)) AS snowflake_value, IFF(source_value = snowflake_value, 'MATCH', 'DIFF') AS result
FROM staff WHERE staff_id = 1;

-- 3. Keys are not enforced, so prove them: rows minus distinct keys must be 0 in every table
SELECT 'actor' AS tbl, COUNT(*) - COUNT(DISTINCT actor_id) AS duplicate_keys FROM actor UNION ALL
SELECT 'address', COUNT(*) - COUNT(DISTINCT address_id) FROM address UNION ALL
SELECT 'category', COUNT(*) - COUNT(DISTINCT category_id) FROM category UNION ALL
SELECT 'city', COUNT(*) - COUNT(DISTINCT city_id) FROM city UNION ALL
SELECT 'country', COUNT(*) - COUNT(DISTINCT country_id) FROM country UNION ALL
SELECT 'customer', COUNT(*) - COUNT(DISTINCT customer_id) FROM customer UNION ALL
SELECT 'film', COUNT(*) - COUNT(DISTINCT film_id) FROM film UNION ALL
SELECT 'film_actor', COUNT(*) - COUNT(DISTINCT actor_id, film_id) FROM film_actor UNION ALL
SELECT 'film_category', COUNT(*) - COUNT(DISTINCT film_id, category_id) FROM film_category UNION ALL
SELECT 'film_text', COUNT(*) - COUNT(DISTINCT film_id) FROM film_text UNION ALL
SELECT 'inventory', COUNT(*) - COUNT(DISTINCT inventory_id) FROM inventory UNION ALL
SELECT 'language', COUNT(*) - COUNT(DISTINCT language_id) FROM language UNION ALL
SELECT 'payment', COUNT(*) - COUNT(DISTINCT payment_id) FROM payment UNION ALL
SELECT 'rental', COUNT(*) - COUNT(DISTINCT rental_id) FROM rental UNION ALL
SELECT 'staff', COUNT(*) - COUNT(DISTINCT staff_id) FROM staff UNION ALL
SELECT 'store', COUNT(*) - COUNT(DISTINCT store_id) FROM store;

-- 4. Relationships: all 22 foreign keys, orphans (child rows with no parent) must be 0 in every line
SELECT 'address.city_id -> city' AS fk, COUNT(*) AS orphans FROM address c WHERE NOT EXISTS (SELECT 1 FROM city p WHERE p.city_id = c.city_id) UNION ALL
SELECT 'city.country_id -> country', COUNT(*) FROM city c WHERE NOT EXISTS (SELECT 1 FROM country p WHERE p.country_id = c.country_id) UNION ALL
SELECT 'customer.address_id -> address', COUNT(*) FROM customer c WHERE NOT EXISTS (SELECT 1 FROM address p WHERE p.address_id = c.address_id) UNION ALL
SELECT 'customer.store_id -> store', COUNT(*) FROM customer c WHERE NOT EXISTS (SELECT 1 FROM store p WHERE p.store_id = c.store_id) UNION ALL
SELECT 'film.language_id -> language', COUNT(*) FROM film c WHERE NOT EXISTS (SELECT 1 FROM language p WHERE p.language_id = c.language_id) UNION ALL
SELECT 'film.original_language_id -> language', COUNT(*) FROM film c WHERE c.original_language_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM language p WHERE p.language_id = c.original_language_id) UNION ALL
SELECT 'film_actor.actor_id -> actor', COUNT(*) FROM film_actor c WHERE NOT EXISTS (SELECT 1 FROM actor p WHERE p.actor_id = c.actor_id) UNION ALL
SELECT 'film_actor.film_id -> film', COUNT(*) FROM film_actor c WHERE NOT EXISTS (SELECT 1 FROM film p WHERE p.film_id = c.film_id) UNION ALL
SELECT 'film_category.film_id -> film', COUNT(*) FROM film_category c WHERE NOT EXISTS (SELECT 1 FROM film p WHERE p.film_id = c.film_id) UNION ALL
SELECT 'film_category.category_id -> category', COUNT(*) FROM film_category c WHERE NOT EXISTS (SELECT 1 FROM category p WHERE p.category_id = c.category_id) UNION ALL
SELECT 'inventory.film_id -> film', COUNT(*) FROM inventory c WHERE NOT EXISTS (SELECT 1 FROM film p WHERE p.film_id = c.film_id) UNION ALL
SELECT 'inventory.store_id -> store', COUNT(*) FROM inventory c WHERE NOT EXISTS (SELECT 1 FROM store p WHERE p.store_id = c.store_id) UNION ALL
SELECT 'payment.customer_id -> customer', COUNT(*) FROM payment c WHERE NOT EXISTS (SELECT 1 FROM customer p WHERE p.customer_id = c.customer_id) UNION ALL
SELECT 'payment.staff_id -> staff', COUNT(*) FROM payment c WHERE NOT EXISTS (SELECT 1 FROM staff p WHERE p.staff_id = c.staff_id) UNION ALL
SELECT 'payment.rental_id -> rental', COUNT(*) FROM payment c WHERE c.rental_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rental p WHERE p.rental_id = c.rental_id) UNION ALL
SELECT 'rental.customer_id -> customer', COUNT(*) FROM rental c WHERE NOT EXISTS (SELECT 1 FROM customer p WHERE p.customer_id = c.customer_id) UNION ALL
SELECT 'rental.inventory_id -> inventory', COUNT(*) FROM rental c WHERE NOT EXISTS (SELECT 1 FROM inventory p WHERE p.inventory_id = c.inventory_id) UNION ALL
SELECT 'rental.staff_id -> staff', COUNT(*) FROM rental c WHERE NOT EXISTS (SELECT 1 FROM staff p WHERE p.staff_id = c.staff_id) UNION ALL
SELECT 'staff.address_id -> address', COUNT(*) FROM staff c WHERE NOT EXISTS (SELECT 1 FROM address p WHERE p.address_id = c.address_id) UNION ALL
SELECT 'staff.store_id -> store', COUNT(*) FROM staff c WHERE NOT EXISTS (SELECT 1 FROM store p WHERE p.store_id = c.store_id) UNION ALL
SELECT 'store.address_id -> address', COUNT(*) FROM store c WHERE NOT EXISTS (SELECT 1 FROM address p WHERE p.address_id = c.address_id) UNION ALL
SELECT 'store.manager_staff_id -> staff', COUNT(*) FROM store c WHERE NOT EXISTS (SELECT 1 FROM staff p WHERE p.staff_id = c.manager_staff_id);

-- 5. The type conversions at work (see docs/migration.md)
SELECT rating, COUNT(*) AS films FROM film GROUP BY rating ORDER BY rating;                                  -- G 178 · NC-17 210 · PG 194 · PG-13 223 · R 195
SELECT f.value::STRING AS special_feature, COUNT(*) AS films FROM film, LATERAL SPLIT_TO_TABLE(special_features, ',') f
GROUP BY 1 ORDER BY 1;                                                                                       -- Behind the Scenes 538 · Commentaries 539 · Deleted Scenes 503 · Trailers 535
SELECT address_id, ST_ASTEXT(location) AS location_wkt FROM address WHERE address_id IN (1, 63);              -- POINT(-112.8185647 49.6999986) · POINT(766456911 13.5639657)
