-- 04 Sakila OLTP → OLAP: the dimensional model in schema SAKILA.DW (DDL).
-- Two facts, five dimensions, two of them Type 2 (DIM_CUSTOMER, DIM_FILM). The loads are in 05_dw_load_merge.sql, all MERGE.
-- Run as SYSADMIN. SAKILA.OLTP is only read, never changed.
--
-- IMPORTANT: every CREATE here is IF NOT EXISTS, on purpose. A Type 2 dimension holds history that SAKILA.OLTP no longer has
-- (OLTP keeps only the current row), so CREATE OR REPLACE would destroy something no load can rebuild. To start over, drop the schema
-- deliberately:  DROP SCHEMA SAKILA.DW;  and run 07 then 08 again.
USE ROLE SYSADMIN;
USE WAREHOUSE CLASS_WH;
CREATE SCHEMA IF NOT EXISTS SAKILA.DW;
USE SCHEMA SAKILA.DW;

-- ===== Dimensions =====

-- Date: one row per calendar day, 2005-01-01 .. 2030-12-31 (9,496 days; the data runs 2005-05-24 .. 2006-02-14) plus the member -1.
-- Role-playing: FACT_RENTAL uses it twice (rental date, return date). Member -1 = "no date yet" (a rental not returned).
CREATE TABLE IF NOT EXISTS DIM_DATE (
  date_key NUMBER(8,0) NOT NULL COMMENT 'yyyymmdd; -1 = no date (rental not yet returned)',
  full_date DATE,
  year SMALLINT, quarter TINYINT, month TINYINT, month_name VARCHAR(3), day_of_month TINYINT,
  day_of_week TINYINT COMMENT 'ISO: 1 = Monday .. 7 = Sunday', day_name VARCHAR(3), is_weekend BOOLEAN,
  PRIMARY KEY (date_key)
) COMMENT = 'Type 0 (never changes). Grain: one row per calendar day';

-- Store: Type 1 — two stores; an address correction should simply overwrite. A change of manager overwrites too (who managed the store
-- earlier is not kept).
CREATE TABLE IF NOT EXISTS DIM_STORE (
  store_key NUMBER(38,0) NOT NULL AUTOINCREMENT START 1 INCREMENT 1 COMMENT 'surrogate key',
  store_id TINYINT NOT NULL COMMENT 'natural key (OLTP.store.store_id)',
  manager_name VARCHAR(91), address VARCHAR(50), district VARCHAR(20), postal_code VARCHAR(10), city VARCHAR(50), country VARCHAR(50),
  row_hash VARCHAR(32) NOT NULL COMMENT 'MD5 of the attributes, used by the MERGE to see a change',
  PRIMARY KEY (store_key),
  UNIQUE (store_id)
) COMMENT = 'Type 1 (overwrite). Grain: one row per store';

-- Staff: Type 1 on purpose — two people. A reassignment between stores overwrites home_store_id, so the history of which store a
-- staff member worked at is NOT kept (the facts do keep WHICH staff member handled each rental or took each payment, and
-- store_key on the facts is the store holding the copy, not the staff member's store). password and picture are not copied.
CREATE TABLE IF NOT EXISTS DIM_STAFF (
  staff_key NUMBER(38,0) NOT NULL AUTOINCREMENT START 1 INCREMENT 1 COMMENT 'surrogate key',
  staff_id TINYINT NOT NULL COMMENT 'natural key (OLTP.staff.staff_id)',
  staff_name VARCHAR(91), email VARCHAR(50), username VARCHAR(16), home_store_id TINYINT, active BOOLEAN,
  row_hash VARCHAR(32) NOT NULL COMMENT 'MD5 of the attributes, used by the MERGE to see a change',
  PRIMARY KEY (staff_key),
  UNIQUE (staff_id)
) COMMENT = 'Type 1 (overwrite). Grain: one row per staff member';

-- Customer: Type 2. Why: a customer moves (address, city, country), changes store, or is deactivated, and a rental or payment
-- must be reported against the customer as they were that day (revenue by country, by store). One row per VERSION of a customer.
CREATE TABLE IF NOT EXISTS DIM_CUSTOMER (
  customer_key NUMBER(38,0) NOT NULL AUTOINCREMENT START 1 INCREMENT 1 COMMENT 'surrogate key: one per version',
  customer_id SMALLINT NOT NULL COMMENT 'natural key (OLTP.customer.customer_id), repeats once per version',
  first_name VARCHAR(45), last_name VARCHAR(45), email VARCHAR(50), active BOOLEAN, store_id TINYINT,
  create_date TIMESTAMP_NTZ(0),
  address VARCHAR(50), address2 VARCHAR(50), district VARCHAR(20), postal_code VARCHAR(10), phone VARCHAR(20),
  city VARCHAR(50), country VARCHAR(50),
  row_hash VARCHAR(32) NOT NULL COMMENT 'MD5 of every tracked attribute above; a different hash = a new version',
  valid_from TIMESTAMP_NTZ(0) NOT NULL COMMENT 'inclusive. First version starts 1900-01-01: its true start is unknown, so it covers all history',
  valid_to TIMESTAMP_NTZ(0) NOT NULL COMMENT 'exclusive. 9999-12-31 for the current version',
  is_current BOOLEAN NOT NULL,
  PRIMARY KEY (customer_key),
  UNIQUE (customer_id, valid_from)
) COMMENT = 'Type 2 SCD. Grain: one row per version of a customer (customer_id + validity interval). Tracked: every attribute, address included';

-- Film: Type 2. Why: films are re-priced (rental_rate, replacement_cost), get a different rental_duration or rating, and a rental
-- must be analysed at the terms in force the day it happened ("revenue vs list price at the time"). OLTP keeps only today's price.
CREATE TABLE IF NOT EXISTS DIM_FILM (
  film_key NUMBER(38,0) NOT NULL AUTOINCREMENT START 1 INCREMENT 1 COMMENT 'surrogate key: one per version',
  film_id SMALLINT NOT NULL COMMENT 'natural key (OLTP.film.film_id), repeats once per version',
  title VARCHAR(128), release_year SMALLINT, language VARCHAR(20), original_language VARCHAR(20), category VARCHAR(25),
  rating VARCHAR(5), special_features VARCHAR(54), length SMALLINT,
  rental_duration TINYINT, rental_rate NUMBER(4,2), replacement_cost NUMBER(5,2),
  row_hash VARCHAR(32) NOT NULL COMMENT 'MD5 of every tracked attribute above; a different hash = a new version',
  valid_from TIMESTAMP_NTZ(0) NOT NULL COMMENT 'inclusive. First version starts 1900-01-01: its true start is unknown, so it covers all history',
  valid_to TIMESTAMP_NTZ(0) NOT NULL COMMENT 'exclusive. 9999-12-31 for the current version',
  is_current BOOLEAN NOT NULL,
  PRIMARY KEY (film_key),
  UNIQUE (film_id, valid_from)
) COMMENT = 'Type 2 SCD. Grain: one row per version of a film (film_id + validity interval). description is not copied';

-- ===== Facts =====

-- Rental: the rental process. A rental starts when a copy leaves the store and is completed when it comes back, so the row is
-- inserted at rental time and its return columns are filled in later by the same MERGE (the grain does not change).
CREATE TABLE IF NOT EXISTS FACT_RENTAL (
  rental_id INTEGER NOT NULL COMMENT 'degenerate dimension: the source rental number',
  inventory_id INTEGER NOT NULL COMMENT 'degenerate dimension: the physical copy',
  rental_date_key NUMBER(8,0) NOT NULL, return_date_key NUMBER(8,0) NOT NULL COMMENT '-1 until the copy is returned',
  customer_key NUMBER(38,0) NOT NULL COMMENT 'the customer VERSION valid at rental_ts',
  film_key NUMBER(38,0) NOT NULL COMMENT 'the film VERSION valid at rental_ts',
  store_key NUMBER(38,0) NOT NULL COMMENT 'store that holds the rented copy',
  staff_key NUMBER(38,0) NOT NULL COMMENT 'staff member who handled the rental',
  rental_ts TIMESTAMP_NTZ(0) NOT NULL, return_ts TIMESTAMP_NTZ(0),
  rental_count NUMBER(1,0) NOT NULL COMMENT 'always 1: additive counter, SUM = number of rentals',
  days_out SMALLINT COMMENT 'calendar-day boundaries crossed from rental to return (DATEDIFF day); NULL until returned. SUM = total days out; for an average use SUM(days_out)/COUNT(days_out), not /SUM(rental_count)',
  PRIMARY KEY (rental_id),
  FOREIGN KEY (rental_date_key) REFERENCES DIM_DATE(date_key),
  FOREIGN KEY (return_date_key) REFERENCES DIM_DATE(date_key),
  FOREIGN KEY (customer_key) REFERENCES DIM_CUSTOMER(customer_key),
  FOREIGN KEY (film_key) REFERENCES DIM_FILM(film_key),
  FOREIGN KEY (store_key) REFERENCES DIM_STORE(store_key),
  FOREIGN KEY (staff_key) REFERENCES DIM_STAFF(staff_key)
) COMMENT = 'GRAIN: one row per rental (rental_id) = one copy (inventory_id) rented by one customer on one date, handled by one staff member';

-- Payment: the payment process, kept apart from rentals on purpose. film_key is resolved at the RENTAL time, not the payment time, so a
-- rental and its payment always point at the same film version; customer_key is resolved at the payment time (who paid, as they were). In the source, 8,078 of the 16,044 payments were taken by a
-- different staff member than the one who handled the rental they settle (the customer is always the same), so a payment is its own event, not a column of the rental.
CREATE TABLE IF NOT EXISTS FACT_PAYMENT (
  payment_id SMALLINT NOT NULL COMMENT 'degenerate dimension: the source payment number',
  rental_id INTEGER NOT NULL COMMENT 'degenerate dimension: the rental this payment settles. 1:1 with FACT_RENTAL in this data (proved in 09), but do not join the two facts on it: aggregate each fact on its own and combine on shared dimensions',
  payment_date_key NUMBER(8,0) NOT NULL,
  customer_key NUMBER(38,0) NOT NULL COMMENT 'the customer VERSION valid at payment_ts, who paid',
  film_key NUMBER(38,0) NOT NULL COMMENT 'the film VERSION valid when the rental happened (rental_ts, via the rental): the same version as FACT_RENTAL.film_key',
  store_key NUMBER(38,0) NOT NULL COMMENT 'store that holds the rented copy',
  staff_key NUMBER(38,0) NOT NULL COMMENT 'staff member who took the payment (not always the one who handled the rental)',
  payment_ts TIMESTAMP_NTZ(0) NOT NULL,
  amount NUMBER(5,2) NOT NULL COMMENT 'additive: SUM(amount) = revenue',
  PRIMARY KEY (payment_id),
  FOREIGN KEY (payment_date_key) REFERENCES DIM_DATE(date_key),
  FOREIGN KEY (customer_key) REFERENCES DIM_CUSTOMER(customer_key),
  FOREIGN KEY (film_key) REFERENCES DIM_FILM(film_key),
  FOREIGN KEY (store_key) REFERENCES DIM_STORE(store_key),
  FOREIGN KEY (staff_key) REFERENCES DIM_STAFF(staff_key)
) COMMENT = 'GRAIN: one row per payment (payment_id) = one amount paid by one customer to one staff member on one date, against one rental';

-- Check: 7 tables in DW, 4 of them with a surrogate key sequence, both facts commented with their grain
SELECT table_name, comment FROM SAKILA.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'DW' ORDER BY table_name;
