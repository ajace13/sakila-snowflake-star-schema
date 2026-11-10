# Data dictionary — `SAKILA.DW` (Sakila star schema)

Scope: the 7 tables of schema `SAKILA.DW`. `CLASSICMODELS.DW` is not covered.
Every fact below carries a query tag, **[Q1]–[Q6]**; the exact SQL for each tag is in [Queries](#queries) at the end. All six were run read-only as `snow sql -c claude` (role CLAUDE_RO) on 2026-10-26.

Two things come from the DDL (`sql/04_dw_ddl.sql`) and not from INFORMATION_SCHEMA, and are marked **(DDL)**: the column list of each constraint and the table each foreign key points to. INFORMATION_SCHEMA names the constraints (system-generated names) but not their columns or targets.

## Summary

| Table | Role | Type | Rows [Q1] | Columns [Q4] | NOT NULL [Q4] |
|---|---|---|---:|---:|---:|
| `DIM_CUSTOMER` | dimension | Type 2 SCD | 599 | 19 | 6 |
| `DIM_DATE` | dimension | Type 0 | 9,497 | 10 | 1 |
| `DIM_FILM` | dimension | Type 2 SCD | 1,000 | 17 | 6 |
| `DIM_STAFF` | dimension | Type 1 | 2 | 8 | 3 |
| `DIM_STORE` | dimension | Type 1 | 2 | 9 | 3 |
| `FACT_PAYMENT` | fact | | 16,044 | 9 | 9 |
| `FACT_RENTAL` | fact | | 16,044 | 12 | 10 |
| **Total** | | | | **84** | |

Reconciliation [Q6]: 7 tables, 84 columns (19+10+17+8+9+9+12 = 84), 22 constraints (7 primary key + 4 unique + 11 foreign key). Live `COUNT(*)` per table [Q5] equals the metadata row count [Q1] for all 7 tables. `SUM(FACT_PAYMENT.AMOUNT)` = 67,406.56 [Q6], the revenue figure in `docs/dimensional_model.md`.

**Reading the types.** INFORMATION_SCHEMA reports Snowflake's storage type, not the keyword written in the DDL. `TINYINT`, `SMALLINT` and `INTEGER` all come back as `NUMBER(38,0)` (so integer ranges are not enforced), and `VARCHAR(n)` comes back as `TEXT` with length `n`. Types below are shown as `NUMBER(p,s)` / `VARCHAR(n)` using the precision, scale and length from [Q2].

**Keys are not enforced.** Every constraint has `ENFORCED = NO` [Q3]. Snowflake records them as metadata only, so a duplicate key or an orphan loads silently. They are checked by queries in `sql/06_dw_checks.sql`, not by the database.

**Table columns used in the tables below:** *Null?* is `IS_NULLABLE` from [Q2]; *Comment* is the column `COMMENT` from [Q2], quoted, with `—` where none is set.

---

## Dimensions

### `DIM_DATE` — Type 0, one row per calendar day
Table comment [Q1]: *"Type 0 (never changes). Grain: one row per calendar day"*. 9,497 rows [Q1] = the days 2005-01-01 .. 2030-12-31 plus the member `-1` (per the DDL comment, 9,496 days + 1). Role-played twice by `FACT_RENTAL` (rental date and return date).

| # | Column | Type | Null? | Comment [Q2] |
|--:|---|---|---|---|
| 1 | `DATE_KEY` | NUMBER(8,0) | NO | "yyyymmdd; -1 = no date (rental not yet returned)" |
| 2 | `FULL_DATE` | DATE | YES | — |
| 3 | `YEAR` | NUMBER(38,0) | YES | — |
| 4 | `QUARTER` | NUMBER(38,0) | YES | — |
| 5 | `MONTH` | NUMBER(38,0) | YES | — |
| 6 | `MONTH_NAME` | VARCHAR(3) | YES | — |
| 7 | `DAY_OF_MONTH` | NUMBER(38,0) | YES | — |
| 8 | `DAY_OF_WEEK` | NUMBER(38,0) | YES | "ISO: 1 = Monday .. 7 = Sunday" |
| 9 | `DAY_NAME` | VARCHAR(3) | YES | — |
| 10 | `IS_WEEKEND` | BOOLEAN | YES | — |

Constraints [Q3]: 1 primary key (`DATE_KEY` **(DDL)**).

### `DIM_STORE` — Type 1 (overwrite), one row per store
Table comment [Q1]: *"Type 1 (overwrite). Grain: one row per store"*. 2 rows [Q1].

| # | Column | Type | Null? | Comment [Q2] |
|--:|---|---|---|---|
| 1 | `STORE_KEY` | NUMBER(38,0), identity | NO | "surrogate key" |
| 2 | `STORE_ID` | NUMBER(38,0) | NO | "natural key (OLTP.store.store_id)" |
| 3 | `MANAGER_NAME` | VARCHAR(91) | YES | — |
| 4 | `ADDRESS` | VARCHAR(50) | YES | — |
| 5 | `DISTRICT` | VARCHAR(20) | YES | — |
| 6 | `POSTAL_CODE` | VARCHAR(10) | YES | — |
| 7 | `CITY` | VARCHAR(50) | YES | — |
| 8 | `COUNTRY` | VARCHAR(50) | YES | — |
| 9 | `ROW_HASH` | VARCHAR(32) | NO | "MD5 of the attributes, used by the MERGE to see a change" |

Identity column [Q2 `IS_IDENTITY`]: `STORE_KEY`. Constraints [Q3]: 1 primary key (`STORE_KEY`) and 1 unique (`STORE_ID`) **(DDL)**.

### `DIM_STAFF` — Type 1 (overwrite), one row per staff member
Table comment [Q1]: *"Type 1 (overwrite). Grain: one row per staff member"*. 2 rows [Q1]. Password and picture are not copied from the source (DDL comment).

| # | Column | Type | Null? | Comment [Q2] |
|--:|---|---|---|---|
| 1 | `STAFF_KEY` | NUMBER(38,0), identity | NO | "surrogate key" |
| 2 | `STAFF_ID` | NUMBER(38,0) | NO | "natural key (OLTP.staff.staff_id)" |
| 3 | `STAFF_NAME` | VARCHAR(91) | YES | — |
| 4 | `EMAIL` | VARCHAR(50) | YES | — |
| 5 | `USERNAME` | VARCHAR(16) | YES | — |
| 6 | `HOME_STORE_ID` | NUMBER(38,0) | YES | — |
| 7 | `ACTIVE` | BOOLEAN | YES | — |
| 8 | `ROW_HASH` | VARCHAR(32) | NO | "MD5 of the attributes, used by the MERGE to see a change" |

Identity column [Q2]: `STAFF_KEY`. Constraints [Q3]: 1 primary key (`STAFF_KEY`) and 1 unique (`STAFF_ID`) **(DDL)**. `HOME_STORE_ID` is the staff member's own store; `STORE_KEY` on the facts is the store holding the copy, not this.

### `DIM_CUSTOMER` — Type 2 SCD, one row per version of a customer
Table comment [Q1]: *"Type 2 SCD. Grain: one row per version of a customer (customer_id + validity interval). Tracked: every attribute, address included"*. 599 rows [Q1].

| # | Column | Type | Null? | Comment [Q2] |
|--:|---|---|---|---|
| 1 | `CUSTOMER_KEY` | NUMBER(38,0), identity | NO | "surrogate key: one per version" |
| 2 | `CUSTOMER_ID` | NUMBER(38,0) | NO | "natural key (OLTP.customer.customer_id), repeats once per version" |
| 3 | `FIRST_NAME` | VARCHAR(45) | YES | — |
| 4 | `LAST_NAME` | VARCHAR(45) | YES | — |
| 5 | `EMAIL` | VARCHAR(50) | YES | — |
| 6 | `ACTIVE` | BOOLEAN | YES | — |
| 7 | `STORE_ID` | NUMBER(38,0) | YES | — |
| 8 | `CREATE_DATE` | TIMESTAMP_NTZ(0) | YES | — |
| 9 | `ADDRESS` | VARCHAR(50) | YES | — |
| 10 | `ADDRESS2` | VARCHAR(50) | YES | — |
| 11 | `DISTRICT` | VARCHAR(20) | YES | — |
| 12 | `POSTAL_CODE` | VARCHAR(10) | YES | — |
| 13 | `PHONE` | VARCHAR(20) | YES | — |
| 14 | `CITY` | VARCHAR(50) | YES | — |
| 15 | `COUNTRY` | VARCHAR(50) | YES | — |
| 16 | `ROW_HASH` | VARCHAR(32) | NO | "MD5 of every tracked attribute above; a different hash = a new version" |
| 17 | `VALID_FROM` | TIMESTAMP_NTZ(0) | NO | "inclusive. First version starts 1900-01-01: its true start is unknown, so it covers all history" |
| 18 | `VALID_TO` | TIMESTAMP_NTZ(0) | NO | "exclusive. 9999-12-31 for the current version" |
| 19 | `IS_CURRENT` | BOOLEAN | NO | — |

Identity column [Q2]: `CUSTOMER_KEY`. Constraints [Q3]: 1 primary key (`CUSTOMER_KEY`) and 1 unique (`CUSTOMER_ID`, `VALID_FROM`) **(DDL)**. A fact picks the version with `VALID_FROM <= event time < VALID_TO`.

### `DIM_FILM` — Type 2 SCD, one row per version of a film
Table comment [Q1]: *"Type 2 SCD. Grain: one row per version of a film (film_id + validity interval). description is not copied"*. 1,000 rows [Q1].

| # | Column | Type | Null? | Comment [Q2] |
|--:|---|---|---|---|
| 1 | `FILM_KEY` | NUMBER(38,0), identity | NO | "surrogate key: one per version" |
| 2 | `FILM_ID` | NUMBER(38,0) | NO | "natural key (OLTP.film.film_id), repeats once per version" |
| 3 | `TITLE` | VARCHAR(128) | YES | — |
| 4 | `RELEASE_YEAR` | NUMBER(38,0) | YES | — |
| 5 | `LANGUAGE` | VARCHAR(20) | YES | — |
| 6 | `ORIGINAL_LANGUAGE` | VARCHAR(20) | YES | — |
| 7 | `CATEGORY` | VARCHAR(25) | YES | — |
| 8 | `RATING` | VARCHAR(5) | YES | — |
| 9 | `SPECIAL_FEATURES` | VARCHAR(54) | YES | — |
| 10 | `LENGTH` | NUMBER(38,0) | YES | — |
| 11 | `RENTAL_DURATION` | NUMBER(38,0) | YES | — |
| 12 | `RENTAL_RATE` | NUMBER(4,2) | YES | — |
| 13 | `REPLACEMENT_COST` | NUMBER(5,2) | YES | — |
| 14 | `ROW_HASH` | VARCHAR(32) | NO | "MD5 of every tracked attribute above; a different hash = a new version" |
| 15 | `VALID_FROM` | TIMESTAMP_NTZ(0) | NO | "inclusive. First version starts 1900-01-01: its true start is unknown, so it covers all history" |
| 16 | `VALID_TO` | TIMESTAMP_NTZ(0) | NO | "exclusive. 9999-12-31 for the current version" |
| 17 | `IS_CURRENT` | BOOLEAN | NO | — |

Identity column [Q2]: `FILM_KEY`. Constraints [Q3]: 1 primary key (`FILM_KEY`) and 1 unique (`FILM_ID`, `VALID_FROM`) **(DDL)**.

---

## Facts

### `FACT_RENTAL` — one row per rental
Table comment [Q1]: *"GRAIN: one row per rental (rental_id) = one copy (inventory_id) rented by one customer on one date, handled by one staff member"*. 16,044 rows [Q1]. The row is inserted at rental time; the return columns are filled in later by the same MERGE (the grain does not change).

| # | Column | Type | Null? | Comment [Q2] |
|--:|---|---|---|---|
| 1 | `RENTAL_ID` | NUMBER(38,0) | NO | "degenerate dimension: the source rental number" |
| 2 | `INVENTORY_ID` | NUMBER(38,0) | NO | "degenerate dimension: the physical copy" |
| 3 | `RENTAL_DATE_KEY` | NUMBER(8,0) | NO | — |
| 4 | `RETURN_DATE_KEY` | NUMBER(8,0) | NO | "-1 until the copy is returned" |
| 5 | `CUSTOMER_KEY` | NUMBER(38,0) | NO | "the customer VERSION valid at rental_ts" |
| 6 | `FILM_KEY` | NUMBER(38,0) | NO | "the film VERSION valid at rental_ts" |
| 7 | `STORE_KEY` | NUMBER(38,0) | NO | "store that holds the rented copy" |
| 8 | `STAFF_KEY` | NUMBER(38,0) | NO | "staff member who handled the rental" |
| 9 | `RENTAL_TS` | TIMESTAMP_NTZ(0) | NO | — |
| 10 | `RETURN_TS` | TIMESTAMP_NTZ(0) | YES | — |
| 11 | `RENTAL_COUNT` | NUMBER(1,0) | NO | "always 1: additive counter, SUM = number of rentals" |
| 12 | `DAYS_OUT` | NUMBER(38,0) | YES | "calendar-day boundaries crossed from rental to return (DATEDIFF day); NULL until returned. SUM = total days out; for an average use SUM(days_out)/COUNT(days_out), not /SUM(rental_count)" |

Measures: `RENTAL_COUNT` and `DAYS_OUT` (additive; `DAYS_OUT` is nullable, so averages use `COUNT(days_out)`). Constraints [Q3]: 1 primary key and 6 foreign keys. **(DDL)** primary key `RENTAL_ID`; foreign keys: `RENTAL_DATE_KEY` and `RETURN_DATE_KEY` → `DIM_DATE.DATE_KEY`, `CUSTOMER_KEY` → `DIM_CUSTOMER`, `FILM_KEY` → `DIM_FILM`, `STORE_KEY` → `DIM_STORE`, `STAFF_KEY` → `DIM_STAFF`.

### `FACT_PAYMENT` — one row per payment
Table comment [Q1]: *"GRAIN: one row per payment (payment_id) = one amount paid by one customer to one staff member on one date, against one rental"*. 16,044 rows [Q1].

| # | Column | Type | Null? | Comment [Q2] |
|--:|---|---|---|---|
| 1 | `PAYMENT_ID` | NUMBER(38,0) | NO | "degenerate dimension: the source payment number" |
| 2 | `RENTAL_ID` | NUMBER(38,0) | NO | "degenerate dimension: the rental this payment settles. 1:1 with FACT_RENTAL in this data (proved in 09), but do not join the two facts on it: aggregate each fact on its own and combine on shared dimensions" |
| 3 | `PAYMENT_DATE_KEY` | NUMBER(8,0) | NO | — |
| 4 | `CUSTOMER_KEY` | NUMBER(38,0) | NO | "the customer VERSION valid at payment_ts, who paid" |
| 5 | `FILM_KEY` | NUMBER(38,0) | NO | "the film VERSION valid when the rental happened (rental_ts, via the rental): the same version as FACT_RENTAL.film_key" |
| 6 | `STORE_KEY` | NUMBER(38,0) | NO | "store that holds the rented copy" |
| 7 | `STAFF_KEY` | NUMBER(38,0) | NO | "staff member who took the payment (not always the one who handled the rental)" |
| 8 | `PAYMENT_TS` | TIMESTAMP_NTZ(0) | NO | — |
| 9 | `AMOUNT` | NUMBER(5,2) | NO | "additive: SUM(amount) = revenue" |

Measure: `AMOUNT` (additive; total 67,406.56 [Q6]). Constraints [Q3]: 1 primary key and 5 foreign keys. **(DDL)** primary key `PAYMENT_ID`; foreign keys: `PAYMENT_DATE_KEY` → `DIM_DATE.DATE_KEY`, `CUSTOMER_KEY` → `DIM_CUSTOMER`, `FILM_KEY` → `DIM_FILM`, `STORE_KEY` → `DIM_STORE`, `STAFF_KEY` → `DIM_STAFF`. `RENTAL_ID` has no foreign key (it is a degenerate dimension, not joined to `FACT_RENTAL`).

---

## Constraints by table

| Table | Primary key | Unique | Foreign key | Total | Query |
|---|---:|---:|---:|---:|---|
| `DIM_CUSTOMER` | 1 | 1 | 0 | 2 | [Q3] |
| `DIM_DATE` | 1 | 0 | 0 | 1 | [Q3] |
| `DIM_FILM` | 1 | 1 | 0 | 2 | [Q3] |
| `DIM_STAFF` | 1 | 1 | 0 | 2 | [Q3] |
| `DIM_STORE` | 1 | 1 | 0 | 2 | [Q3] |
| `FACT_PAYMENT` | 1 | 0 | 5 | 6 | [Q3] |
| `FACT_RENTAL` | 1 | 0 | 6 | 7 | [Q3] |
| **Total** | **7** | **4** | **11** | **22** | [Q3], [Q6] |

All 22 have `ENFORCED = NO` [Q3].

---

## Queries

Each query is a single read-only `SELECT`, run as `snow sql -c claude -q "<query>"`.

**Q1 — tables, type, row count, table comment**
```sql
SELECT table_name, table_type, row_count, comment FROM SAKILA.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'DW' ORDER BY table_name
```
Result: 7 base tables; row counts 599 / 9,497 / 1,000 / 2 / 2 / 16,044 / 16,044 in table-name order.

**Q2 — columns (position, type, length, precision, scale, nullability, identity, comment)**
```sql
SELECT table_name, ordinal_position AS pos, column_name, data_type, character_maximum_length AS len, numeric_precision AS prec, numeric_scale AS scale, datetime_precision AS dtp, is_nullable, column_default, is_identity, comment FROM SAKILA.INFORMATION_SCHEMA.COLUMNS WHERE table_schema = 'DW' ORDER BY table_name, ordinal_position
```
Result: 84 rows. `COLUMN_DEFAULT` is NULL for every column (the identity columns are flagged by `IS_IDENTITY = YES`: `CUSTOMER_KEY`, `FILM_KEY`, `STAFF_KEY`, `STORE_KEY`).

**Q3 — constraints**
```sql
SELECT table_name, constraint_name, constraint_type, enforced FROM SAKILA.INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE table_schema = 'DW' ORDER BY table_name, constraint_type, constraint_name
```
Result: 22 rows (7 PRIMARY KEY, 4 UNIQUE, 11 FOREIGN KEY), all `ENFORCED = NO`; names are system-generated (`SYS_CONSTRAINT_<uuid>`), so they are not listed here.

**Q4 — check: columns and NOT NULL columns per table, next to the metadata row count**
```sql
SELECT t.table_name, t.row_count AS meta_rows, COUNT(c.column_name) AS n_columns, SUM(IFF(c.is_nullable='NO',1,0)) AS n_not_null FROM SAKILA.INFORMATION_SCHEMA.TABLES t JOIN SAKILA.INFORMATION_SCHEMA.COLUMNS c ON c.table_schema=t.table_schema AND c.table_name=t.table_name WHERE t.table_schema='DW' GROUP BY t.table_name, t.row_count ORDER BY t.table_name
```
Result: columns 19 / 10 / 17 / 8 / 9 / 9 / 12 and NOT NULL 6 / 1 / 6 / 3 / 3 / 9 / 10 in table-name order. The per-table column lists above have these lengths.

**Q5 — check: live row counts (does the INFORMATION_SCHEMA `ROW_COUNT` match the table?)**
```sql
SELECT 'DIM_CUSTOMER' t, COUNT(*) n FROM SAKILA.DW.DIM_CUSTOMER UNION ALL SELECT 'DIM_DATE', COUNT(*) FROM SAKILA.DW.DIM_DATE UNION ALL SELECT 'DIM_FILM', COUNT(*) FROM SAKILA.DW.DIM_FILM UNION ALL SELECT 'DIM_STAFF', COUNT(*) FROM SAKILA.DW.DIM_STAFF UNION ALL SELECT 'DIM_STORE', COUNT(*) FROM SAKILA.DW.DIM_STORE UNION ALL SELECT 'FACT_PAYMENT', COUNT(*) FROM SAKILA.DW.FACT_PAYMENT UNION ALL SELECT 'FACT_RENTAL', COUNT(*) FROM SAKILA.DW.FACT_RENTAL ORDER BY 1
```
Result: 599 / 9,497 / 1,000 / 2 / 2 / 16,044 / 16,044, identical to Q1. `ROW_COUNT` is table metadata and can lag after a load; it did not here.

**Q6 — check: totals**
```sql
SELECT (SELECT SUM(amount) FROM SAKILA.DW.FACT_PAYMENT) AS sum_amount, (SELECT COUNT(*) FROM SAKILA.INFORMATION_SCHEMA.TABLES WHERE table_schema='DW') AS n_tables, (SELECT COUNT(*) FROM SAKILA.INFORMATION_SCHEMA.COLUMNS WHERE table_schema='DW') AS n_columns, (SELECT COUNT(*) FROM SAKILA.INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE table_schema='DW') AS n_constraints
```
Result: `SUM(amount)` 67,406.56; 7 tables; 84 columns; 22 constraints.

## What this dictionary does not cover
- The business meaning of values, such as ranges or code lists, is not read from the data; only the metadata above and the DDL comments are used.
- Table and column comments are what the DDL author wrote, not something the database checks. Columns with `—` have no comment in `SAKILA.INFORMATION_SCHEMA.COLUMNS`.
- Clustering, retention, ownership and grants are not documented here.
