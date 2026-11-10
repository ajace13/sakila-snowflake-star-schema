-- 08 Business questions: show it works, and find where it doesn't.
--   3.1  three business questions, each answered on the normalized copy (SAKILA.OLTP) and on the star (SAKILA.DW), side by side
--   3.2  exercise the history: change a customer's address and a film's rental rate, re-run the MERGE, show both versions
--   3.3  one question the star answers badly, and what to change
-- Run as SYSADMIN in ONE session, with your own connection (not the read-only agent's):  snow sql -c <your-own-connection> -f sql/08_business_questions.sql   (3.2 uses !source, a Snowflake CLI command: in Snowsight
-- paste 05_dw_load_merge.sql in place of each !source line). 3.2 happens inside a transaction that ends in ROLLBACK, so SAKILA.OLTP and
-- SAKILA.DW come out exactly as they went in.
USE ROLE SYSADMIN;
USE WAREHOUSE CLASS_WH;

-- =====================================================================================================================================
-- 3.1  QUESTION 1 — What is the revenue by month?
-- =====================================================================================================================================
SELECT 'Q1 revenue by month' AS question, COALESCE(o.month, s.month) AS month, o.revenue AS normalized_revenue, s.revenue AS star_revenue,
       IFF(o.revenue = s.revenue, 'AGREE', 'DISAGREE') AS result
FROM (SELECT TO_CHAR(payment_date, 'YYYY-MM') AS month, SUM(amount) AS revenue FROM SAKILA.OLTP.payment GROUP BY 1) o
FULL JOIN (SELECT TO_CHAR(d.full_date, 'YYYY-MM') AS month, SUM(p.amount) AS revenue
           FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_DATE d ON d.date_key = p.payment_date_key GROUP BY 1) s ON s.month = o.month
ORDER BY 2;

-- =====================================================================================================================================
-- 3.1  QUESTION 2 — Which film categories earn the most (revenue, rentals and rank)?
-- =====================================================================================================================================
SELECT 'Q2 top categories' AS question, COALESCE(o.category, s.category) AS category,
       o.revenue AS normalized_revenue, s.revenue AS star_revenue, o.rentals AS normalized_rentals, s.rentals AS star_rentals,
       o.rnk AS normalized_rank, s.rnk AS star_rank,
       IFF(o.revenue = s.revenue AND o.rentals = s.rentals AND o.rnk = s.rnk, 'AGREE', 'DISAGREE') AS result
FROM (SELECT cat.name AS category, SUM(p.amount) AS revenue, COUNT(*) AS rentals, RANK() OVER (ORDER BY SUM(p.amount) DESC) AS rnk
      FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
      JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
      JOIN SAKILA.OLTP.film_category fc ON fc.film_id = i.film_id JOIN SAKILA.OLTP.category cat ON cat.category_id = fc.category_id GROUP BY 1) o
FULL JOIN (SELECT f.category, SUM(p.amount) AS revenue, COUNT(*) AS rentals, RANK() OVER (ORDER BY SUM(p.amount) DESC) AS rnk
           FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_FILM f ON f.film_key = p.film_key GROUP BY 1) s ON s.category = o.category
ORDER BY COALESCE(o.rnk, s.rnk) LIMIT 5;

-- =====================================================================================================================================
-- 3.1  QUESTION 3 — How many customers and how much revenue does each store have?
--      "Store" has three meanings in Sakila: the customer's home store, the store of the staff member who took the payment, and the store
--      that holds the rented copy. Each is answered on both models; each pair agrees, but the three definitions do not agree with each other.
-- =====================================================================================================================================
SELECT 'Q3a customers by home store' AS question, COALESCE(o.store_id, s.store_id) AS store_id, o.customers AS normalized, s.customers AS star,
       IFF(o.customers = s.customers, 'AGREE', 'DISAGREE') AS result
FROM (SELECT store_id, COUNT(*) AS customers FROM SAKILA.OLTP.customer GROUP BY 1) o
FULL JOIN (SELECT store_id, COUNT(DISTINCT customer_id) AS customers FROM SAKILA.DW.DIM_CUSTOMER WHERE is_current GROUP BY 1) s ON s.store_id = o.store_id
ORDER BY 2;

SELECT 'Q3b revenue by store, three definitions' AS question, COALESCE(o.definition, s.definition) AS definition, COALESCE(o.store_id, s.store_id) AS store_id,
       o.revenue AS normalized_revenue, s.revenue AS star_revenue, IFF(o.revenue = s.revenue, 'AGREE', 'DISAGREE') AS result
FROM (SELECT '1 customer home store' AS definition, c.store_id, SUM(p.amount) AS revenue FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.customer c ON c.customer_id = p.customer_id GROUP BY 2
      UNION ALL SELECT '2 store of the staff member who took the payment', st.store_id, SUM(p.amount) FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.staff st ON st.staff_id = p.staff_id GROUP BY 2
      UNION ALL SELECT '3 store holding the rented copy', i.store_id, SUM(p.amount) FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
                JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id GROUP BY 2) o
FULL JOIN (SELECT '1 customer home store' AS definition, c.store_id, SUM(p.amount) AS revenue FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key GROUP BY 2
           UNION ALL SELECT '2 store of the staff member who took the payment', sf.home_store_id, SUM(p.amount) FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_STAFF sf ON sf.staff_key = p.staff_key GROUP BY 2
           UNION ALL SELECT '3 store holding the rented copy', st.store_id, SUM(p.amount) FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_STORE st ON st.store_key = p.store_key GROUP BY 2) s
  ON s.definition = o.definition AND s.store_id = o.store_id
ORDER BY 2, 3;

-- =====================================================================================================================================
-- 3.2  EXERCISE THE HISTORY — one transaction, ends in ROLLBACK
-- =====================================================================================================================================
BEGIN;

SELECT '3.2 BEFORE the change' AS step, (SELECT COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER) AS dim_customer_rows, (SELECT COUNT(*) FROM SAKILA.DW.DIM_FILM) AS dim_film_rows;

-- Change what a Type 2 dimension must capture: customer 1 moves from Japan to Spain, film 1 goes from 0.99 to 5.99 per rental
UPDATE SAKILA.OLTP.address SET address = '1 Calle Nueva', city_id = 1
  WHERE address_id = (SELECT address_id FROM SAKILA.OLTP.customer WHERE customer_id = 1);          -- city 1 is A Coruña, Spain
UPDATE SAKILA.OLTP.film SET rental_rate = 5.99 WHERE film_id = 1;

-- Re-run the MERGE (the same 08 file as always)
!source sql/05_dw_load_merge.sql

-- The dimensions now hold BOTH versions
SELECT '3.2 DIM_CUSTOMER customer 1' AS step, customer_key, country, city, address, valid_from, valid_to, is_current FROM SAKILA.DW.DIM_CUSTOMER WHERE customer_id = 1 ORDER BY valid_from;
SELECT '3.2 DIM_FILM film 1' AS step, film_key, rental_rate, valid_from, valid_to, is_current FROM SAKILA.DW.DIM_FILM WHERE film_id = 1 ORDER BY valid_from;

-- Where the two models now DISAGREE: revenue by customer country. Only the groups that differ are shown.
SELECT '3.2 revenue by customer country: groups where the models differ' AS step, COALESCE(o.country, s.country) AS country,
       o.revenue AS normalized_revenue, s.revenue AS star_revenue, COALESCE(s.revenue, 0) - COALESCE(o.revenue, 0) AS star_minus_normalized
FROM (SELECT co.country, SUM(p.amount) AS revenue FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.customer cu ON cu.customer_id = p.customer_id
      JOIN SAKILA.OLTP.address a ON a.address_id = cu.address_id JOIN SAKILA.OLTP.city ci ON ci.city_id = a.city_id
      JOIN SAKILA.OLTP.country co ON co.country_id = ci.country_id GROUP BY 1) o
FULL JOIN (SELECT c.country, SUM(p.amount) AS revenue FROM SAKILA.DW.FACT_PAYMENT p JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key GROUP BY 1) s ON s.country = o.country
WHERE o.revenue IS DISTINCT FROM s.revenue ORDER BY 2;
-- ... while the totals still agree
SELECT '3.2 total revenue' AS step, (SELECT SUM(amount) FROM SAKILA.OLTP.payment) AS normalized_total, (SELECT SUM(amount) FROM SAKILA.DW.FACT_PAYMENT) AS star_total;

-- A trap the history creates: counting customers. COUNT(*) on a Type 2 dimension counts versions.
SELECT '3.2 how many customers?' AS step, (SELECT COUNT(*) FROM SAKILA.OLTP.customer) AS normalized,
       (SELECT COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER) AS star_count_star_WRONG,
       (SELECT COUNT(DISTINCT customer_id) FROM SAKILA.DW.DIM_CUSTOMER) AS star_count_distinct_customer_id,
       (SELECT COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER WHERE is_current) AS star_current_versions;

-- Film 1's rentals: the list price in force when each rental happened (star) vs the price today (normalized, the only one it has)
SELECT '3.2 film 1 rentals by list price' AS step, f.rental_rate AS list_price_when_rented_star, (SELECT rental_rate FROM SAKILA.OLTP.film WHERE film_id = 1) AS list_price_today_normalized,
       COUNT(*) AS rentals
FROM SAKILA.DW.FACT_RENTAL r JOIN SAKILA.DW.DIM_FILM f ON f.film_key = r.film_key WHERE f.film_id = 1 GROUP BY 2 ORDER BY 2;

ROLLBACK;

SELECT '3.2 AFTER the rollback' AS step, (SELECT COUNT(*) FROM SAKILA.DW.DIM_CUSTOMER) AS dim_customer_rows, (SELECT COUNT(*) FROM SAKILA.DW.DIM_FILM) AS dim_film_rows,
       (SELECT rental_rate FROM SAKILA.OLTP.film WHERE film_id = 1) AS oltp_film1_rate,
       (SELECT address FROM SAKILA.OLTP.address WHERE address_id = (SELECT address_id FROM SAKILA.OLTP.customer WHERE customer_id = 1)) AS oltp_customer1_address;

-- =====================================================================================================================================
-- 3.3  A QUESTION THE STAR ANSWERS BADLY — "Which actors generate the most revenue?"
--      The star has no actor in it: film_actor, the many-to-many between films and actors, was left out. The normalized copy can answer, but
--      the obvious query is wrong, and the obvious fix is wrong too.
-- =====================================================================================================================================
-- (a) The star cannot see actors at all: no column in SAKILA.DW mentions one
SELECT '3.3a columns in SAKILA.DW that mention an actor' AS step, COUNT(*) AS columns_found
FROM SAKILA.INFORMATION_SCHEMA.COLUMNS WHERE table_schema = 'DW' AND (column_name ILIKE '%actor%' OR table_name ILIKE '%actor%');

-- (b) On the normalized copy, the obvious join counts each payment once per actor in the film: the "total" is several times the real revenue
SELECT '3.3b naive join on film_actor' AS step, SUM(rev) AS sum_of_actor_revenues, (SELECT SUM(amount) FROM SAKILA.OLTP.payment) AS true_total_revenue,
       ROUND(SUM(rev) / (SELECT SUM(amount) FROM SAKILA.OLTP.payment), 2) AS overcount_factor
FROM (SELECT fa.actor_id, SUM(p.amount) AS rev FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
      JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id JOIN SAKILA.OLTP.film_actor fa ON fa.film_id = i.film_id GROUP BY 1);

-- (c) The fix I would build: an actor dimension and a film-actor bridge with a WEIGHTING FACTOR = 1 / (actors in the film), plus an
--     "unknown actor" member for the films that have none (3 of the 1,000), so that the allocated revenue adds back up to the real total.
--     Shown here as a query on the normalized copy, not built, to prove the design reconciles.
WITH weights AS (
  SELECT f.film_id, fa.actor_id, 1 / COUNT(*) OVER (PARTITION BY f.film_id) AS weighting_factor
  FROM SAKILA.OLTP.film f JOIN SAKILA.OLTP.film_actor fa ON fa.film_id = f.film_id
  UNION ALL
  SELECT f.film_id, -1, 1 FROM SAKILA.OLTP.film f WHERE NOT EXISTS (SELECT 1 FROM SAKILA.OLTP.film_actor fa WHERE fa.film_id = f.film_id)       -- actor -1 = unknown
), alloc AS (
  SELECT w.actor_id, SUM(p.amount * w.weighting_factor) AS revenue
  FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
  JOIN weights w ON w.film_id = i.film_id GROUP BY 1
)
SELECT '3.3c weighted allocation' AS step, ROUND(SUM(revenue), 2) AS allocated_total, (SELECT SUM(amount) FROM SAKILA.OLTP.payment) AS true_total_revenue,
       IFF(ROUND(SUM(revenue), 2) = (SELECT SUM(amount) FROM SAKILA.OLTP.payment), 'RECONCILES', 'DIFF') AS result,
       ROUND(SUM(IFF(actor_id = -1, revenue, 0)), 2) AS revenue_of_films_with_no_actor
FROM alloc;

-- (d) ... and the answer it then gives: the top actors by allocated revenue (every actor's share sums to the real total with the rest)
WITH weights AS (
  SELECT f.film_id, fa.actor_id, 1 / COUNT(*) OVER (PARTITION BY f.film_id) AS weighting_factor
  FROM SAKILA.OLTP.film f JOIN SAKILA.OLTP.film_actor fa ON fa.film_id = f.film_id
)
SELECT '3.3d top 5 actors by allocated revenue' AS step, a.first_name || ' ' || a.last_name AS actor, ROUND(SUM(p.amount * w.weighting_factor), 2) AS allocated_revenue
FROM SAKILA.OLTP.payment p JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
JOIN weights w ON w.film_id = i.film_id JOIN SAKILA.OLTP.actor a ON a.actor_id = w.actor_id
GROUP BY 2 ORDER BY 3 DESC LIMIT 5;
