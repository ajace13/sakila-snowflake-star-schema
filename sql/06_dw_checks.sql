-- 06 Sakila star schema vs the normalized copy: reconciliation and integrity checks. Read-only SELECTs.
-- Every row ends in OK; any FAIL means the star disagrees with SAKILA.OLTP or breaks a rule Snowflake does not enforce for us.
-- Run after 05_dw_load_merge.sql (any role that can read SAKILA; names are fully qualified).

-- 1. Counts and totals: the star against the normalized copy
SELECT check_name, expected, actual, IFF(expected = actual, 'OK', 'FAIL') AS result FROM (
  SELECT 'FACT_RENTAL rows = OLTP rentals' AS check_name,      (SELECT COUNT(*) FROM SAKILA.OLTP.rental)::NUMBER(18,2) AS expected, (SELECT COUNT(*) FROM SAKILA.DW.FACT_RENTAL)::NUMBER(18,2) AS actual UNION ALL
  SELECT 'FACT_PAYMENT rows = OLTP payments',                  (SELECT COUNT(*) FROM SAKILA.OLTP.payment), (SELECT COUNT(*) FROM SAKILA.DW.FACT_PAYMENT) UNION ALL
  SELECT 'SUM(amount) = OLTP SUM(amount)',                     (SELECT SUM(amount) FROM SAKILA.OLTP.payment), (SELECT SUM(amount) FROM SAKILA.DW.FACT_PAYMENT) UNION ALL
  SELECT 'SUM(amount) = 67,406.56 (the known total)',          67406.56, (SELECT SUM(amount) FROM SAKILA.DW.FACT_PAYMENT) UNION ALL
  SELECT 'SUM(rental_count) = OLTP rentals',                   (SELECT COUNT(*) FROM SAKILA.OLTP.rental), (SELECT SUM(rental_count) FROM SAKILA.DW.FACT_RENTAL) UNION ALL
  SELECT 'SUM(days_out) = OLTP SUM(DATEDIFF day)',             (SELECT SUM(DATEDIFF('day', rental_date, return_date)) FROM SAKILA.OLTP.rental), (SELECT SUM(days_out) FROM SAKILA.DW.FACT_RENTAL) UNION ALL
  SELECT 'returned rentals (days_out not NULL)',               (SELECT COUNT(return_date) FROM SAKILA.OLTP.rental), (SELECT COUNT(days_out) FROM SAKILA.DW.FACT_RENTAL) UNION ALL
  SELECT 'rentals not returned (return_date_key = -1)',        (SELECT COUNT_IF(return_date IS NULL) FROM SAKILA.OLTP.rental), (SELECT COUNT_IF(return_date_key = -1) FROM SAKILA.DW.FACT_RENTAL) UNION ALL
  SELECT 'DIM_CUSTOMER current rows = OLTP customers',         (SELECT COUNT(*) FROM SAKILA.OLTP.customer), (SELECT COUNT_IF(is_current) FROM SAKILA.DW.DIM_CUSTOMER) UNION ALL
  SELECT 'DIM_FILM current rows = OLTP films',                 (SELECT COUNT(*) FROM SAKILA.OLTP.film), (SELECT COUNT_IF(is_current) FROM SAKILA.DW.DIM_FILM) UNION ALL
  SELECT 'DIM_STORE rows = OLTP stores',                       (SELECT COUNT(*) FROM SAKILA.OLTP.store), (SELECT COUNT(*) FROM SAKILA.DW.DIM_STORE) UNION ALL
  SELECT 'DIM_STAFF rows = OLTP staff',                        (SELECT COUNT(*) FROM SAKILA.OLTP.staff), (SELECT COUNT(*) FROM SAKILA.DW.DIM_STAFF) UNION ALL
  SELECT 'DIM_DATE rows = 9,496 days + member -1',             9497, (SELECT COUNT(*) FROM SAKILA.DW.DIM_DATE)
) ORDER BY check_name;

-- 2. The same numbers cut by every kind of dimension: groups compared, groups where the star and OLTP disagree (must be 0)
SELECT check_name, groups_compared, mismatching_groups, IFF(mismatching_groups = 0, 'OK', 'FAIL') AS result FROM (
  SELECT 'revenue by film category' AS check_name, COUNT(*) AS groups_compared, COUNT_IF(dw.v IS DISTINCT FROM o.v) AS mismatching_groups FROM
    (SELECT f.category AS g, SUM(p.amount) AS v FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_FILM f ON f.film_key = p.film_key GROUP BY 1) dw
    FULL JOIN (SELECT cat.name AS g, SUM(p.amount) AS v FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
               JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id JOIN SAKILA.OLTP.film_category fc ON fc.film_id = i.film_id
               JOIN SAKILA.OLTP.category cat ON cat.category_id = fc.category_id GROUP BY 1) o ON o.g = dw.g
  UNION ALL
  SELECT 'revenue by store', COUNT(*), COUNT_IF(dw.v IS DISTINCT FROM o.v) FROM
    (SELECT s.store_id AS g, SUM(p.amount) AS v FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_STORE s ON s.store_key = p.store_key GROUP BY 1) dw
    FULL JOIN (SELECT i.store_id AS g, SUM(p.amount) AS v FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
               JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id GROUP BY 1) o ON o.g = dw.g
  UNION ALL
  SELECT 'revenue by customer country', COUNT(*), COUNT_IF(dw.v IS DISTINCT FROM o.v) FROM
    (SELECT c.country AS g, SUM(p.amount) AS v FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key GROUP BY 1) dw
    FULL JOIN (SELECT co.country AS g, SUM(p.amount) AS v FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.customer cu ON cu.customer_id = p.customer_id
               JOIN SAKILA.OLTP.address a ON a.address_id = cu.address_id JOIN SAKILA.OLTP.city ci ON ci.city_id = a.city_id
               JOIN SAKILA.OLTP.country co ON co.country_id = ci.country_id GROUP BY 1) o ON o.g = dw.g
  UNION ALL
  SELECT 'revenue by staff member', COUNT(*), COUNT_IF(dw.v IS DISTINCT FROM o.v) FROM
    (SELECT s.staff_id AS g, SUM(p.amount) AS v FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_STAFF s ON s.staff_key = p.staff_key GROUP BY 1) dw
    FULL JOIN (SELECT staff_id AS g, SUM(amount) AS v FROM SAKILA.OLTP.payment GROUP BY 1) o ON o.g = dw.g
  UNION ALL
  SELECT 'revenue by year-month', COUNT(*), COUNT_IF(dw.v IS DISTINCT FROM o.v) FROM
    (SELECT d.year * 100 + d.month AS g, SUM(p.amount) AS v FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_DATE d ON d.date_key = p.payment_date_key GROUP BY 1) dw
    FULL JOIN (SELECT YEAR(payment_date) * 100 + MONTH(payment_date) AS g, SUM(amount) AS v FROM SAKILA.OLTP.payment GROUP BY 1) o ON o.g = dw.g
  UNION ALL
  SELECT 'rentals by film category', COUNT(*), COUNT_IF(dw.v IS DISTINCT FROM o.v) FROM
    (SELECT f.category AS g, SUM(r.rental_count) AS v FROM SAKILA.DW.FACT_RENTAL r JOIN SAKILA.DW.DIM_FILM f ON f.film_key = r.film_key GROUP BY 1) dw
    FULL JOIN (SELECT cat.name AS g, COUNT(*) AS v FROM SAKILA.OLTP.rental r JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
               JOIN SAKILA.OLTP.film_category fc ON fc.film_id = i.film_id JOIN SAKILA.OLTP.category cat ON cat.category_id = fc.category_id GROUP BY 1) o ON o.g = dw.g
  UNION ALL
  SELECT 'rentals by customer', COUNT(*), COUNT_IF(dw.v IS DISTINCT FROM o.v) FROM
    (SELECT c.customer_id AS g, SUM(r.rental_count) AS v FROM SAKILA.DW.FACT_RENTAL r JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = r.customer_key GROUP BY 1) dw
    FULL JOIN (SELECT customer_id AS g, COUNT(*) AS v FROM SAKILA.OLTP.rental GROUP BY 1) o ON o.g = dw.g
);

-- 3. Relationships: facts to dimensions. Snowflake does not enforce foreign keys, so count the orphans (must be 0 in every line)
SELECT fk, orphans, IFF(orphans = 0, 'OK', 'FAIL') AS result FROM (
  SELECT 'FACT_RENTAL.rental_date_key -> DIM_DATE' AS fk, COUNT(*) AS orphans FROM SAKILA.DW.FACT_RENTAL f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_DATE d WHERE d.date_key = f.rental_date_key) UNION ALL
  SELECT 'FACT_RENTAL.return_date_key -> DIM_DATE', COUNT(*) FROM SAKILA.DW.FACT_RENTAL f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_DATE d WHERE d.date_key = f.return_date_key) UNION ALL
  SELECT 'FACT_RENTAL.customer_key -> DIM_CUSTOMER', COUNT(*) FROM SAKILA.DW.FACT_RENTAL f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_CUSTOMER d WHERE d.customer_key = f.customer_key) UNION ALL
  SELECT 'FACT_RENTAL.film_key -> DIM_FILM', COUNT(*) FROM SAKILA.DW.FACT_RENTAL f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_FILM d WHERE d.film_key = f.film_key) UNION ALL
  SELECT 'FACT_RENTAL.store_key -> DIM_STORE', COUNT(*) FROM SAKILA.DW.FACT_RENTAL f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_STORE d WHERE d.store_key = f.store_key) UNION ALL
  SELECT 'FACT_RENTAL.staff_key -> DIM_STAFF', COUNT(*) FROM SAKILA.DW.FACT_RENTAL f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_STAFF d WHERE d.staff_key = f.staff_key) UNION ALL
  SELECT 'FACT_PAYMENT.payment_date_key -> DIM_DATE', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_DATE d WHERE d.date_key = f.payment_date_key) UNION ALL
  SELECT 'FACT_PAYMENT.customer_key -> DIM_CUSTOMER', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_CUSTOMER d WHERE d.customer_key = f.customer_key) UNION ALL
  SELECT 'FACT_PAYMENT.film_key -> DIM_FILM', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_FILM d WHERE d.film_key = f.film_key) UNION ALL
  SELECT 'FACT_PAYMENT.store_key -> DIM_STORE', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_STORE d WHERE d.store_key = f.store_key) UNION ALL
  SELECT 'FACT_PAYMENT.staff_key -> DIM_STAFF', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.DIM_STAFF d WHERE d.staff_key = f.staff_key)
);

-- 4. Grain: one row per rental, one row per payment, and what joining the two facts on rental_id would do (it is 1:1 here, but not enforced)
SELECT check_name, expected, actual, IFF(expected = actual, 'OK', 'FAIL') AS result FROM (
  SELECT 'FACT_RENTAL: rows - distinct rental_id' AS check_name, 0::NUMBER(18,2) AS expected, (COUNT(*) - COUNT(DISTINCT rental_id))::NUMBER(18,2) AS actual FROM SAKILA.DW.FACT_RENTAL UNION ALL
  SELECT 'FACT_PAYMENT: rows - distinct payment_id', 0, COUNT(*) - COUNT(DISTINCT payment_id) FROM SAKILA.DW.FACT_PAYMENT UNION ALL
  SELECT 'rentals with more than one payment', 0, COUNT(*) FROM (SELECT rental_id FROM SAKILA.DW.FACT_PAYMENT GROUP BY 1 HAVING COUNT(*) > 1) UNION ALL
  SELECT 'rentals with no payment', 0, COUNT(*) FROM SAKILA.DW.FACT_RENTAL r WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.FACT_PAYMENT p WHERE p.rental_id = r.rental_id) UNION ALL
  SELECT 'payments with no rental', 0, COUNT(*) FROM SAKILA.DW.FACT_PAYMENT p WHERE NOT EXISTS (SELECT 1 FROM SAKILA.DW.FACT_RENTAL r WHERE r.rental_id = p.rental_id) UNION ALL
  SELECT 'rows of FACT_RENTAL JOIN FACT_PAYMENT on rental_id (no multiplication)', (SELECT COUNT(*) FROM SAKILA.DW.FACT_RENTAL), COUNT(*) FROM SAKILA.DW.FACT_RENTAL r JOIN SAKILA.DW.FACT_PAYMENT p ON p.rental_id = r.rental_id UNION ALL
  SELECT 'rental and payment share one film version', 0, COUNT(*) FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.FACT_RENTAL r ON r.rental_id = p.rental_id WHERE r.film_key <> p.film_key
);

-- 5. Type 2 integrity: Snowflake enforces none of it, so prove it (every line must be 0). One current version per natural key,
--    no overlapping intervals, no gaps between versions, first version from 1900-01-01, last open until 9999-12-31, is_current agrees with valid_to.
SELECT dim, check_name, violations, IFF(violations = 0, 'OK', 'FAIL') AS result FROM (
  SELECT 'DIM_CUSTOMER' AS dim, 'natural keys without exactly one current version' AS check_name, COUNT(*) AS violations FROM (SELECT customer_id FROM SAKILA.DW.DIM_CUSTOMER GROUP BY 1 HAVING COUNT_IF(is_current) <> 1) UNION ALL
  SELECT 'DIM_CUSTOMER', 'overlapping version intervals', COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER a JOIN SAKILA.DW.DIM_CUSTOMER b ON a.customer_id = b.customer_id AND a.customer_key < b.customer_key AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to UNION ALL
  SELECT 'DIM_CUSTOMER', 'gaps: next valid_from <> this valid_to', COUNT(*) FROM (SELECT valid_to, LEAD(valid_from) OVER (PARTITION BY customer_id ORDER BY valid_from) AS nxt FROM SAKILA.DW.DIM_CUSTOMER) WHERE nxt IS NOT NULL AND nxt <> valid_to UNION ALL
  SELECT 'DIM_CUSTOMER', 'first version not from 1900-01-01', COUNT(*) FROM (SELECT customer_id, MIN(valid_from) AS f FROM SAKILA.DW.DIM_CUSTOMER GROUP BY 1) WHERE f <> '1900-01-01' UNION ALL
  SELECT 'DIM_CUSTOMER', 'current version not open to 9999-12-31, or closed version marked current', COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER WHERE is_current <> (valid_to = '9999-12-31') UNION ALL
  SELECT 'DIM_CUSTOMER', 'duplicate (customer_id, valid_from)', COUNT(*) - COUNT(DISTINCT customer_id || '|' || valid_from::STRING) FROM SAKILA.DW.DIM_CUSTOMER UNION ALL
  SELECT 'DIM_FILM', 'natural keys without exactly one current version', COUNT(*) FROM (SELECT film_id FROM SAKILA.DW.DIM_FILM GROUP BY 1 HAVING COUNT_IF(is_current) <> 1) UNION ALL
  SELECT 'DIM_FILM', 'overlapping version intervals', COUNT(*) FROM SAKILA.DW.DIM_FILM a JOIN SAKILA.DW.DIM_FILM b ON a.film_id = b.film_id AND a.film_key < b.film_key AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to UNION ALL
  SELECT 'DIM_FILM', 'gaps: next valid_from <> this valid_to', COUNT(*) FROM (SELECT valid_to, LEAD(valid_from) OVER (PARTITION BY film_id ORDER BY valid_from) AS nxt FROM SAKILA.DW.DIM_FILM) WHERE nxt IS NOT NULL AND nxt <> valid_to UNION ALL
  SELECT 'DIM_FILM', 'first version not from 1900-01-01', COUNT(*) FROM (SELECT film_id, MIN(valid_from) AS f FROM SAKILA.DW.DIM_FILM GROUP BY 1) WHERE f <> '1900-01-01' UNION ALL
  SELECT 'DIM_FILM', 'current version not open to 9999-12-31, or closed version marked current', COUNT(*) FROM SAKILA.DW.DIM_FILM WHERE is_current <> (valid_to = '9999-12-31') UNION ALL
  SELECT 'DIM_FILM', 'duplicate (film_id, valid_from)', COUNT(*) - COUNT(DISTINCT film_id || '|' || valid_from::STRING) FROM SAKILA.DW.DIM_FILM
);

-- 6. As-of correctness: every fact points at the dimension version that was valid at its event time (must be 0), and the assumptions the loads rely on
SELECT check_name, violations, IFF(violations = 0, 'OK', 'FAIL') AS result FROM (
  SELECT 'FACT_RENTAL customer version not valid at rental_ts' AS check_name, COUNT(*) AS violations FROM SAKILA.DW.FACT_RENTAL f JOIN SAKILA.DW.DIM_CUSTOMER d ON d.customer_key = f.customer_key WHERE NOT (f.rental_ts >= d.valid_from AND f.rental_ts < d.valid_to) UNION ALL
  SELECT 'FACT_RENTAL film version not valid at rental_ts', COUNT(*) FROM SAKILA.DW.FACT_RENTAL f JOIN SAKILA.DW.DIM_FILM d ON d.film_key = f.film_key WHERE NOT (f.rental_ts >= d.valid_from AND f.rental_ts < d.valid_to) UNION ALL
  SELECT 'FACT_PAYMENT customer version not valid at payment_ts', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT f JOIN SAKILA.DW.DIM_CUSTOMER d ON d.customer_key = f.customer_key WHERE NOT (f.payment_ts >= d.valid_from AND f.payment_ts < d.valid_to) UNION ALL
  SELECT 'FACT_PAYMENT film version not valid at the rental time', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT f JOIN SAKILA.DW.FACT_RENTAL r ON r.rental_id = f.rental_id JOIN SAKILA.DW.DIM_FILM d ON d.film_key = f.film_key WHERE NOT (r.rental_ts >= d.valid_from AND r.rental_ts < d.valid_to) UNION ALL
  SELECT 'films without exactly one category (DIM_FILM would multiply)', COUNT(*) FROM (SELECT f.film_id FROM SAKILA.OLTP.film f LEFT JOIN SAKILA.OLTP.film_category fc ON fc.film_id = f.film_id GROUP BY 1 HAVING COUNT(fc.film_id) <> 1) UNION ALL
  SELECT 'dimension rows with a NULL row_hash', (SELECT COUNT_IF(row_hash IS NULL) FROM SAKILA.DW.DIM_CUSTOMER) + (SELECT COUNT_IF(row_hash IS NULL) FROM SAKILA.DW.DIM_FILM)
                                              + (SELECT COUNT_IF(row_hash IS NULL) FROM SAKILA.DW.DIM_STORE) + (SELECT COUNT_IF(row_hash IS NULL) FROM SAKILA.DW.DIM_STAFF) UNION ALL
  SELECT 'row_hash cannot tell NULL from empty string (it must)', IFF(MD5(TO_JSON(ARRAY_CONSTRUCT('a', NULL))) <> MD5(TO_JSON(ARRAY_CONSTRUCT('a', ''))), 0, 1)
);
