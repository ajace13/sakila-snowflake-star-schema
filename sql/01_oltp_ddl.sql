-- 01 Sakila (MySQL 8.0 on Cloud SQL) into Snowflake, schema SAKILA.OLTP: DDL, file format, stage.
-- Run the whole worksheet in Snowsight (Run All) as YOU (SYSADMIN), not as the agent. Then upload the CSVs (docs/migration.md, step 3)
-- and run sql/02_oltp_load_reconcile.sql. Same 16 base tables and the same relationships as sakila-schema.sql; the 7 views, 6 routines and
-- 5 triggers of the source are not migrated (the analytics only need the tables).
-- Type choices are explained in docs/migration.md; the short version is in the column COMMENTs below.

USE ROLE SYSADMIN;
CREATE WAREHOUSE IF NOT EXISTS CLASS_WH WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE CLASS_WH;
CREATE DATABASE IF NOT EXISTS SAKILA;
CREATE SCHEMA IF NOT EXISTS SAKILA.OLTP;
USE SCHEMA SAKILA.OLTP;

-- DDL, in dependency order. Snowflake records PRIMARY KEY / UNIQUE / FOREIGN KEY but does NOT enforce them (NOT NULL is enforced).
-- Dropped on purpose: AUTO_INCREMENT (ids are loaded as they are), secondary indexes, FULLTEXT/SPATIAL keys, ON UPDATE CURRENT_TIMESTAMP,
-- ON DELETE / ON UPDATE actions, UNSIGNED (every Snowflake integer type is NUMBER(38,0)).

CREATE OR REPLACE TABLE country (
  country_id SMALLINT NOT NULL,
  country VARCHAR(50) NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (country_id)
);
CREATE OR REPLACE TABLE city (
  city_id SMALLINT NOT NULL,
  city VARCHAR(50) NOT NULL,
  country_id SMALLINT NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (city_id),
  FOREIGN KEY (country_id) REFERENCES country(country_id)
);
CREATE OR REPLACE TABLE address (
  address_id SMALLINT NOT NULL,
  address VARCHAR(50) NOT NULL,
  address2 VARCHAR(50),
  district VARCHAR(20) NOT NULL,
  city_id SMALLINT NOT NULL,
  postal_code VARCHAR(10),
  phone VARCHAR(20) NOT NULL,
  location GEOMETRY NOT NULL COMMENT 'MySQL GEOMETRY, SRID 0 (planar). GEOMETRY not GEOGRAPHY: 6 source points lie outside lon/lat range',
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (address_id),
  FOREIGN KEY (city_id) REFERENCES city(city_id)
);
CREATE OR REPLACE TABLE category (
  category_id TINYINT NOT NULL,
  name VARCHAR(25) NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (category_id)
);
CREATE OR REPLACE TABLE language (
  language_id TINYINT NOT NULL,
  name CHAR(20) NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (language_id)
);
CREATE OR REPLACE TABLE actor (
  actor_id SMALLINT NOT NULL,
  first_name VARCHAR(45) NOT NULL,
  last_name VARCHAR(45) NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (actor_id)
);
-- staff and store point at each other (staff.store_id <-> store.manager_staff_id): staff first, its store FK added after store exists.
CREATE OR REPLACE TABLE staff (
  staff_id TINYINT NOT NULL,
  first_name VARCHAR(45) NOT NULL,
  last_name VARCHAR(45) NOT NULL,
  address_id SMALLINT NOT NULL,
  picture BINARY COMMENT 'MySQL BLOB; loaded from hex',
  email VARCHAR(50),
  store_id TINYINT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE COMMENT 'MySQL BOOLEAN = TINYINT(1); 1/0 become TRUE/FALSE',
  username VARCHAR(16) NOT NULL,
  password VARCHAR(40),
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (staff_id),
  FOREIGN KEY (address_id) REFERENCES address(address_id)
);
CREATE OR REPLACE TABLE store (
  store_id TINYINT NOT NULL,
  manager_staff_id TINYINT NOT NULL,
  address_id SMALLINT NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (store_id),
  UNIQUE (manager_staff_id),
  FOREIGN KEY (manager_staff_id) REFERENCES staff(staff_id),
  FOREIGN KEY (address_id) REFERENCES address(address_id)
);
ALTER TABLE staff ADD FOREIGN KEY (store_id) REFERENCES store(store_id);

CREATE OR REPLACE TABLE customer (
  customer_id SMALLINT NOT NULL,
  store_id TINYINT NOT NULL,
  first_name VARCHAR(45) NOT NULL,
  last_name VARCHAR(45) NOT NULL,
  email VARCHAR(50),
  address_id SMALLINT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE COMMENT 'MySQL BOOLEAN = TINYINT(1); 1/0 become TRUE/FALSE',
  create_date TIMESTAMP_NTZ(0) NOT NULL COMMENT 'MySQL DATETIME: no time zone, kept as the same wall-clock value',
  last_update TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (customer_id),
  FOREIGN KEY (address_id) REFERENCES address(address_id),
  FOREIGN KEY (store_id) REFERENCES store(store_id)
);
CREATE OR REPLACE TABLE film (
  film_id SMALLINT NOT NULL,
  title VARCHAR(128) NOT NULL,
  description VARCHAR,
  release_year SMALLINT COMMENT 'MySQL YEAR: no YEAR type in Snowflake, kept as a 4-digit number',
  language_id TINYINT NOT NULL,
  original_language_id TINYINT,
  rental_duration TINYINT NOT NULL DEFAULT 3,
  rental_rate NUMBER(4,2) NOT NULL DEFAULT 4.99,
  length SMALLINT,
  replacement_cost NUMBER(5,2) NOT NULL DEFAULT 19.99,
  rating VARCHAR(5) DEFAULT 'G' COMMENT 'MySQL ENUM(G,PG,PG-13,R,NC-17): text label, validity no longer enforced',
  special_features VARCHAR(54) COMMENT 'MySQL SET(Trailers,Commentaries,Deleted Scenes,Behind the Scenes): the same comma-separated text',
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (film_id),
  FOREIGN KEY (language_id) REFERENCES language(language_id),
  FOREIGN KEY (original_language_id) REFERENCES language(language_id)
);
CREATE OR REPLACE TABLE film_actor (
  actor_id SMALLINT NOT NULL,
  film_id SMALLINT NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (actor_id, film_id),
  FOREIGN KEY (actor_id) REFERENCES actor(actor_id),
  FOREIGN KEY (film_id) REFERENCES film(film_id)
);
CREATE OR REPLACE TABLE film_category (
  film_id SMALLINT NOT NULL,
  category_id TINYINT NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (film_id, category_id),
  FOREIGN KEY (film_id) REFERENCES film(film_id),
  FOREIGN KEY (category_id) REFERENCES category(category_id)
);
-- film_text had no INSERTs in the dump: MySQL filled it from film through the ins_film trigger. Snowflake has no triggers, so it is loaded as a copy.
CREATE OR REPLACE TABLE film_text (
  film_id SMALLINT NOT NULL,
  title VARCHAR(255) NOT NULL,
  description VARCHAR,
  PRIMARY KEY (film_id)
);
CREATE OR REPLACE TABLE inventory (
  inventory_id INTEGER NOT NULL,
  film_id SMALLINT NOT NULL,
  store_id TINYINT NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (inventory_id),
  FOREIGN KEY (store_id) REFERENCES store(store_id),
  FOREIGN KEY (film_id) REFERENCES film(film_id)
);
CREATE OR REPLACE TABLE rental (
  rental_id INTEGER NOT NULL,
  rental_date TIMESTAMP_NTZ(0) NOT NULL COMMENT 'MySQL DATETIME: no time zone, kept as the same wall-clock value',
  inventory_id INTEGER NOT NULL,
  customer_id SMALLINT NOT NULL,
  return_date TIMESTAMP_NTZ(0) COMMENT 'MySQL DATETIME: no time zone, kept as the same wall-clock value',
  staff_id TINYINT NOT NULL,
  last_update TIMESTAMP_NTZ(0) NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (rental_id),
  UNIQUE (rental_date, inventory_id, customer_id),
  FOREIGN KEY (staff_id) REFERENCES staff(staff_id),
  FOREIGN KEY (inventory_id) REFERENCES inventory(inventory_id),
  FOREIGN KEY (customer_id) REFERENCES customer(customer_id)
);
CREATE OR REPLACE TABLE payment (
  payment_id SMALLINT NOT NULL,
  customer_id SMALLINT NOT NULL,
  staff_id TINYINT NOT NULL,
  rental_id INTEGER,
  amount NUMBER(5,2) NOT NULL,
  payment_date TIMESTAMP_NTZ(0) NOT NULL COMMENT 'MySQL DATETIME: no time zone, kept as the same wall-clock value',
  last_update TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0),
  PRIMARY KEY (payment_id),
  FOREIGN KEY (rental_id) REFERENCES rental(rental_id),
  FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
  FOREIGN KEY (staff_id) REFERENCES staff(staff_id)
);

-- File format and stage for the CSVs written by src/export_sakila_csv.py:
-- NULL is the bare marker \N, an empty field is an empty string, BLOBs arrive as hex, timestamps as 'YYYY-MM-DD HH:MM:SS'.
CREATE OR REPLACE FILE FORMAT sakila_csv
  TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' ENCODING = 'UTF8'
  NULL_IF = ('\\N') EMPTY_FIELD_AS_NULL = FALSE ESCAPE_UNENCLOSED_FIELD = NONE
  BINARY_FORMAT = HEX TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
CREATE STAGE IF NOT EXISTS sakila_stage FILE_FORMAT = sakila_csv COMMENT = 'Sakila CSVs from export_sakila_csv.py';

-- ===== Checks — before the upload =====
SELECT COUNT(*) AS base_tables FROM SAKILA.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'OLTP' AND table_type = 'BASE TABLE';   -- 16
SHOW IMPORTED KEYS IN SCHEMA SAKILA.OLTP;                                                                                          -- 22 foreign keys (the source has 22)
SELECT COUNT(*) AS fk_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));                                                                -- 22
