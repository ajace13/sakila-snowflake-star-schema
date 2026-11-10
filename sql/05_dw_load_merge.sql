-- 05 Sakila OLTP → OLAP: the loads of SAKILA.DW, every one a MERGE (safe to re-run).
-- Run as SYSADMIN after 04_dw_ddl.sql, in this order (dimensions first, facts last: facts look up the dimension versions).
-- Re-running changes nothing unless the source changed: each MERGE reports 0 rows inserted / 0 updated the second time.
-- SAKILA.OLTP is only read. The "as of" time that closes and opens Type 2 versions is one value for the whole run:
--   default = now; to replay a date, change the SET line (the demo in 09 does).
USE ROLE SYSADMIN;
USE WAREHOUSE CLASS_WH;
USE SCHEMA SAKILA.DW;
SET etl_as_of = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0));

-- ===== 1. DIM_DATE — Type 0: insert the days that are missing, never change one =====
-- 2005-01-01 .. 2030-12-31 = 9,496 days, plus the member -1. The data itself runs 2005-05-24 .. 2006-02-14; the calendar runs on so that
-- new facts always find their day. To extend it again, raise ROWCOUNT: the MERGE inserts only the days that are not there yet.
MERGE INTO DIM_DATE t USING (
  SELECT TO_NUMBER(TO_CHAR(d, 'YYYYMMDD')) AS date_key, d AS full_date, YEAR(d) AS year, QUARTER(d) AS quarter, MONTH(d) AS month,
         MONTHNAME(d) AS month_name, DAY(d) AS day_of_month, DAYOFWEEKISO(d) AS day_of_week, DAYNAME(d) AS day_name,
         DAYOFWEEKISO(d) >= 6 AS is_weekend
  FROM (SELECT DATEADD(day, SEQ4(), '2005-01-01'::DATE) AS d FROM TABLE(GENERATOR(ROWCOUNT => 9496)))
  UNION ALL
  SELECT -1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL        -- "no date yet": rentals not returned
) s ON t.date_key = s.date_key
WHEN NOT MATCHED THEN INSERT (date_key, full_date, year, quarter, month, month_name, day_of_month, day_of_week, day_name, is_weekend)
  VALUES (s.date_key, s.full_date, s.year, s.quarter, s.month, s.month_name, s.day_of_month, s.day_of_week, s.day_name, s.is_weekend);

-- ===== 2. DIM_STORE — Type 1: a changed store is overwritten, a new store is inserted =====
MERGE INTO DIM_STORE t USING (
  SELECT s.store_id, m.first_name || ' ' || m.last_name AS manager_name, a.address, a.district, a.postal_code, ci.city, co.country,
         MD5(TO_JSON(ARRAY_CONSTRUCT(m.first_name, m.last_name, a.address, a.district, a.postal_code, ci.city, co.country))) AS row_hash
  FROM SAKILA.OLTP.store s
  JOIN SAKILA.OLTP.staff m ON m.staff_id = s.manager_staff_id
  JOIN SAKILA.OLTP.address a ON a.address_id = s.address_id
  JOIN SAKILA.OLTP.city ci ON ci.city_id = a.city_id
  JOIN SAKILA.OLTP.country co ON co.country_id = ci.country_id
) src ON t.store_id = src.store_id
WHEN MATCHED AND t.row_hash <> src.row_hash THEN UPDATE SET
  manager_name = src.manager_name, address = src.address, district = src.district, postal_code = src.postal_code,
  city = src.city, country = src.country, row_hash = src.row_hash
WHEN NOT MATCHED THEN INSERT (store_id, manager_name, address, district, postal_code, city, country, row_hash)
  VALUES (src.store_id, src.manager_name, src.address, src.district, src.postal_code, src.city, src.country, src.row_hash);

-- ===== 3. DIM_STAFF — Type 1 (password and picture are deliberately not copied) =====
MERGE INTO DIM_STAFF t USING (
  SELECT staff_id, first_name || ' ' || last_name AS staff_name, email, username, store_id AS home_store_id, active,
         MD5(TO_JSON(ARRAY_CONSTRUCT(first_name, last_name, email, username, store_id, active))) AS row_hash
  FROM SAKILA.OLTP.staff
) src ON t.staff_id = src.staff_id
WHEN MATCHED AND t.row_hash <> src.row_hash THEN UPDATE SET
  staff_name = src.staff_name, email = src.email, username = src.username, home_store_id = src.home_store_id,
  active = src.active, row_hash = src.row_hash
WHEN NOT MATCHED THEN INSERT (staff_id, staff_name, email, username, home_store_id, active, row_hash)
  VALUES (src.staff_id, src.staff_name, src.email, src.username, src.home_store_id, src.active, src.row_hash);

-- ===== 4. DIM_CUSTOMER — Type 2, one MERGE =====
-- Each source customer is staged once to MATCH its current row (merge_key = customer_id) and, if its hash changed, a second time
-- with merge_key NULL, which can never match and so is INSERTED as the new version. The matched row is closed in the same statement.
-- A customer not yet in the dimension is just the first case: no current row, so it is inserted (valid_from 1900-01-01).
MERGE INTO DIM_CUSTOMER t USING (
  WITH src AS (
    SELECT c.customer_id, c.first_name, c.last_name, c.email, c.active, c.store_id, c.create_date,
           a.address, a.address2, a.district, a.postal_code, a.phone, ci.city, co.country,
           MD5(TO_JSON(ARRAY_CONSTRUCT(c.first_name, c.last_name, c.email, c.active, c.store_id, c.create_date,
                                       a.address, a.address2, a.district, a.postal_code, a.phone, ci.city, co.country))) AS row_hash
    FROM SAKILA.OLTP.customer c
    JOIN SAKILA.OLTP.address a ON a.address_id = c.address_id
    JOIN SAKILA.OLTP.city ci ON ci.city_id = a.city_id
    JOIN SAKILA.OLTP.country co ON co.country_id = ci.country_id
  )
  SELECT s.customer_id AS merge_key, FALSE AS is_new_version, s.* FROM src s
  UNION ALL
  SELECT NULL, TRUE, s.* FROM src s
  JOIN DIM_CUSTOMER d ON d.customer_id = s.customer_id AND d.is_current AND d.row_hash <> s.row_hash
) u ON t.customer_id = u.merge_key AND t.is_current
WHEN MATCHED AND t.row_hash <> u.row_hash THEN UPDATE SET valid_to = $etl_as_of, is_current = FALSE
WHEN NOT MATCHED THEN INSERT (customer_id, first_name, last_name, email, active, store_id, create_date, address, address2, district,
                              postal_code, phone, city, country, row_hash, valid_from, valid_to, is_current)
  VALUES (u.customer_id, u.first_name, u.last_name, u.email, u.active, u.store_id, u.create_date, u.address, u.address2, u.district,
          u.postal_code, u.phone, u.city, u.country, u.row_hash,
          IFF(u.is_new_version, $etl_as_of, '1900-01-01'::TIMESTAMP_NTZ(0)), '9999-12-31'::TIMESTAMP_NTZ(0), TRUE);

-- ===== 5. DIM_FILM — Type 2, same pattern =====
MERGE INTO DIM_FILM t USING (
  WITH src AS (
    SELECT f.film_id, f.title, f.release_year, l.name AS language, ol.name AS original_language, cat.name AS category,
           f.rating, f.special_features, f.length, f.rental_duration, f.rental_rate, f.replacement_cost,
           MD5(TO_JSON(ARRAY_CONSTRUCT(f.title, f.release_year, l.name, ol.name, cat.name, f.rating, f.special_features, f.length,
                                       f.rental_duration, f.rental_rate, f.replacement_cost))) AS row_hash
    FROM SAKILA.OLTP.film f
    JOIN SAKILA.OLTP.language l ON l.language_id = f.language_id
    LEFT JOIN SAKILA.OLTP.language ol ON ol.language_id = f.original_language_id
    JOIN SAKILA.OLTP.film_category fc ON fc.film_id = f.film_id
    JOIN SAKILA.OLTP.category cat ON cat.category_id = fc.category_id
  )
  SELECT s.film_id AS merge_key, FALSE AS is_new_version, s.* FROM src s
  UNION ALL
  SELECT NULL, TRUE, s.* FROM src s
  JOIN DIM_FILM d ON d.film_id = s.film_id AND d.is_current AND d.row_hash <> s.row_hash
) u ON t.film_id = u.merge_key AND t.is_current
WHEN MATCHED AND t.row_hash <> u.row_hash THEN UPDATE SET valid_to = $etl_as_of, is_current = FALSE
WHEN NOT MATCHED THEN INSERT (film_id, title, release_year, language, original_language, category, rating, special_features, length,
                              rental_duration, rental_rate, replacement_cost, row_hash, valid_from, valid_to, is_current)
  VALUES (u.film_id, u.title, u.release_year, u.language, u.original_language, u.category, u.rating, u.special_features, u.length,
          u.rental_duration, u.rental_rate, u.replacement_cost, u.row_hash,
          IFF(u.is_new_version, $etl_as_of, '1900-01-01'::TIMESTAMP_NTZ(0)), '9999-12-31'::TIMESTAMP_NTZ(0), TRUE);

-- ===== 6. FACT_RENTAL =====
-- Customer and film are looked up AS OF the rental time (valid_from <= rental_ts < valid_to). LEFT JOINs so that a failed lookup
-- gives a NULL key and the MERGE stops ("NULL result in a non-nullable column") instead of silently dropping the rental.
-- A row that already exists keeps its keys; only the return columns can change (the copy comes back after the row was inserted).
MERGE INTO FACT_RENTAL t USING (
  SELECT r.rental_id, r.inventory_id,
         TO_NUMBER(TO_CHAR(r.rental_date, 'YYYYMMDD')) AS rental_date_key,
         IFF(r.return_date IS NULL, -1, TO_NUMBER(TO_CHAR(r.return_date, 'YYYYMMDD'))) AS return_date_key,
         c.customer_key, f.film_key, st.store_key, sf.staff_key,
         r.rental_date AS rental_ts, r.return_date AS return_ts, 1 AS rental_count,
         DATEDIFF('day', r.rental_date, r.return_date) AS days_out
  FROM SAKILA.OLTP.rental r
  JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
  LEFT JOIN DIM_CUSTOMER c ON c.customer_id = r.customer_id AND r.rental_date >= c.valid_from AND r.rental_date < c.valid_to
  LEFT JOIN DIM_FILM f ON f.film_id = i.film_id AND r.rental_date >= f.valid_from AND r.rental_date < f.valid_to
  LEFT JOIN DIM_STORE st ON st.store_id = i.store_id
  LEFT JOIN DIM_STAFF sf ON sf.staff_id = r.staff_id
) s ON t.rental_id = s.rental_id
WHEN MATCHED AND (t.return_ts IS DISTINCT FROM s.return_ts OR t.days_out IS DISTINCT FROM s.days_out) THEN UPDATE SET
  return_date_key = s.return_date_key, return_ts = s.return_ts, days_out = s.days_out
WHEN NOT MATCHED THEN INSERT (rental_id, inventory_id, rental_date_key, return_date_key, customer_key, film_key, store_key, staff_key,
                              rental_ts, return_ts, rental_count, days_out)
  VALUES (s.rental_id, s.inventory_id, s.rental_date_key, s.return_date_key, s.customer_key, s.film_key, s.store_key, s.staff_key,
          s.rental_ts, s.return_ts, s.rental_count, s.days_out);

-- ===== 7. FACT_PAYMENT =====
-- Customer as of the payment time (who paid, as they were); film as of the RENTAL time, so a rental and its payment share one film version.
-- Only a corrected amount can change an existing row.
MERGE INTO FACT_PAYMENT t USING (
  SELECT p.payment_id, p.rental_id, TO_NUMBER(TO_CHAR(p.payment_date, 'YYYYMMDD')) AS payment_date_key,
         c.customer_key, f.film_key, st.store_key, sf.staff_key, p.payment_date AS payment_ts, p.amount
  FROM SAKILA.OLTP.payment p
  LEFT JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
  LEFT JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
  LEFT JOIN DIM_CUSTOMER c ON c.customer_id = p.customer_id AND p.payment_date >= c.valid_from AND p.payment_date < c.valid_to
  LEFT JOIN DIM_FILM f ON f.film_id = i.film_id AND r.rental_date >= f.valid_from AND r.rental_date < f.valid_to
  LEFT JOIN DIM_STORE st ON st.store_id = i.store_id
  LEFT JOIN DIM_STAFF sf ON sf.staff_id = p.staff_id
) s ON t.payment_id = s.payment_id
WHEN MATCHED AND t.amount <> s.amount THEN UPDATE SET amount = s.amount
WHEN NOT MATCHED THEN INSERT (payment_id, rental_id, payment_date_key, customer_key, film_key, store_key, staff_key, payment_ts, amount)
  VALUES (s.payment_id, s.rental_id, s.payment_date_key, s.customer_key, s.film_key, s.store_key, s.staff_key, s.payment_ts, s.amount);
