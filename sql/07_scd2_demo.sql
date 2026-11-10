-- 07 Proof that the Type 2 dimensions and the MERGE loads work: change the source, reload, show the history, ROLL BACK.
-- The source has no history of its own (every last_update is identical), so this script makes real changes inside ONE transaction, runs
-- 05_dw_load_merge.sql on them, queries the result, and ends with ROLLBACK: SAKILA.OLTP and SAKILA.DW come out exactly as they went in.
-- (The surrogate key sequences do not roll back: the next customer_key / film_key will skip a few numbers. Harmless; order versions by valid_from.)
-- Run as SYSADMIN, in ONE session, with your own connection (not the read-only agent's):   snow sql -c <your-own-connection> -f sql/07_scd2_demo.sql
-- In Snowsight, `!source` does not exist: paste the contents of 05_dw_load_merge.sql in place of each  !source  line below.
-- If anything fails halfway, the open transaction is rolled back when the session ends.
USE ROLE SYSADMIN;
USE WAREHOUSE CLASS_WH;
BEGIN;

-- ===== BEFORE: one version per customer and film =====
SELECT 'BEFORE' AS step, customer_key, customer_id, country, city, address, valid_from, valid_to, is_current FROM SAKILA.DW.DIM_CUSTOMER WHERE customer_id = 1;
SELECT 'BEFORE' AS step, film_key, film_id, rental_rate, valid_from, valid_to, is_current FROM SAKILA.DW.DIM_FILM WHERE film_id = 1;
SELECT 'BEFORE' AS step, (SELECT COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER) AS dim_customer_rows, (SELECT COUNT(*) FROM SAKILA.DW.DIM_FILM) AS dim_film_rows,
       (SELECT COUNT(*) FROM SAKILA.DW.FACT_RENTAL) AS fact_rental_rows, (SELECT COUNT(*) FROM SAKILA.DW.FACT_PAYMENT) AS fact_payment_rows;

-- ===== CHANGE 1: customer 1 moves to another country; film 1 is re-priced; staff member 1 gets a new e-mail (a Type 1 attribute) =====
UPDATE SAKILA.OLTP.address SET address = '1 Calle Nueva', city_id = 1
  WHERE address_id = (SELECT address_id FROM SAKILA.OLTP.customer WHERE customer_id = 1);          -- city 1 is A Coruña, Spain
UPDATE SAKILA.OLTP.film SET rental_rate = 5.99 WHERE film_id = 1;
UPDATE SAKILA.OLTP.staff SET email = 'mike.changed@sakilastaff.example' WHERE staff_id = 1;

-- Reload (08): the two Type 2 dimensions close the old version and open a new one; DIM_STAFF just overwrites; facts are untouched
!source sql/05_dw_load_merge.sql

-- ===== CHANGE 2: a rental and a payment that happen AFTER the changes: customer 1 rents a copy of film 1 =====
INSERT INTO SAKILA.OLTP.rental (rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
  SELECT 99999, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0), MIN(inventory_id), 1, NULL, 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0)
  FROM SAKILA.OLTP.inventory WHERE film_id = 1;
INSERT INTO SAKILA.OLTP.payment (payment_id, customer_id, staff_id, rental_id, amount, payment_date, last_update)
  VALUES (99999, 1, 1, 99999, 5.99, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0));
!source sql/05_dw_load_merge.sql

-- ===== PROOF 1: the history. Two versions each; the old one is closed at the reload time, the new one starts there =====
SELECT 'AFTER' AS step, customer_key, customer_id, country, city, address, valid_from, valid_to, is_current FROM SAKILA.DW.DIM_CUSTOMER WHERE customer_id = 1 ORDER BY valid_from;
SELECT 'AFTER' AS step, film_key, film_id, rental_rate, valid_from, valid_to, is_current FROM SAKILA.DW.DIM_FILM WHERE film_id = 1 ORDER BY valid_from;
-- Type 1 for contrast: staff 1 is still ONE row, the e-mail was overwritten
SELECT 'AFTER' AS step, staff_id, email, COUNT(*) OVER () AS dim_staff_rows FROM SAKILA.DW.DIM_STAFF WHERE staff_id = 1;

-- ===== PROOF 2: old facts keep the version they happened under; the new fact gets the new version =====
SELECT c.country AS customer_country_when_it_happened, c.is_current AS version_is_current, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key
WHERE c.customer_id = 1 GROUP BY 1, 2 ORDER BY 2;
SELECT f.rental_rate AS list_price_when_rented, f.is_current AS version_is_current, COUNT(*) AS rentals
FROM SAKILA.DW.FACT_RENTAL r JOIN SAKILA.DW.DIM_FILM f ON f.film_key = r.film_key
WHERE f.film_id = 1 GROUP BY 1, 2 ORDER BY 2;

-- ===== PROOF 3: why Type 2 — customer 1's revenue by country "as it was" vs "as it is now" (Type 1 would only have the second) =====
SELECT 'as it was (fact key)' AS view_of_history, c.country, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key WHERE c.customer_id = 1 GROUP BY 2
UNION ALL
SELECT 'as it is now (current version)', cur.country, COUNT(*), SUM(p.amount)
FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key
JOIN SAKILA.DW.DIM_CUSTOMER cur ON cur.customer_id = c.customer_id AND cur.is_current WHERE c.customer_id = 1 GROUP BY 2
ORDER BY 1, 2;

-- ===== CHANGE 3: the copy comes back 3 days later. The existing FACT_RENTAL row is UPDATED by the MERGE, not duplicated =====
UPDATE SAKILA.OLTP.rental SET return_date = DATEADD(day, 3, rental_date) WHERE rental_id = 99999;
!source sql/05_dw_load_merge.sql
SELECT 'RETURNED' AS step, rental_id, return_date_key, days_out, (SELECT COUNT(*) FROM SAKILA.DW.FACT_RENTAL) AS fact_rental_rows
FROM SAKILA.DW.FACT_RENTAL WHERE rental_id = 99999;

-- ===== PROOF 4: reloading again changes nothing (the MERGEs above print 0 inserted / 0 updated) =====
!source sql/05_dw_load_merge.sql
SELECT 'AFTER 3 RELOADS' AS step, (SELECT COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER) AS dim_customer_rows, (SELECT COUNT(*) FROM SAKILA.DW.DIM_FILM) AS dim_film_rows,
       (SELECT COUNT(*) FROM SAKILA.DW.FACT_RENTAL) AS fact_rental_rows, (SELECT COUNT(*) FROM SAKILA.DW.FACT_PAYMENT) AS fact_payment_rows;

ROLLBACK;

-- ===== AFTER THE ROLLBACK: everything is as it was =====
SELECT 'ROLLED BACK' AS step, (SELECT COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER) AS dim_customer_rows, (SELECT COUNT(*) FROM SAKILA.DW.DIM_FILM) AS dim_film_rows,
       (SELECT COUNT(*) FROM SAKILA.DW.FACT_RENTAL) AS fact_rental_rows, (SELECT COUNT(*) FROM SAKILA.DW.FACT_PAYMENT) AS fact_payment_rows,
       (SELECT COUNT(*) FROM SAKILA.OLTP.rental) AS oltp_rentals, (SELECT COUNT(*) FROM SAKILA.OLTP.payment) AS oltp_payments,
       (SELECT rental_rate FROM SAKILA.OLTP.film WHERE film_id = 1) AS oltp_film1_rate, (SELECT email FROM SAKILA.OLTP.staff WHERE staff_id = 1) AS oltp_staff1_email;
