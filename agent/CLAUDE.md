# CLAUDE.md — standing rules for the Claude Code warehouse agent (Snowflake, Sakila)

## What this folder is
Sakila moved from Cloud SQL (MySQL 8.0) into Snowflake: schema SAKILA.OLTP is the normalized copy (16 tables, 22 foreign keys), SAKILA.DW is the star
built from it by sql/04_dw_ddl.sql and sql/05_dw_load_merge.sql (DIM_DATE, DIM_STORE, DIM_STAFF, DIM_CUSTOMER and DIM_FILM as Type 2,
FACT_RENTAL, FACT_PAYMENT). You (Claude Code) run in a terminal — Cloud Shell, SSH or a laptop — and talk to Snowflake ONLY through the Snowflake CLI
connection named `claude`: user CLAUDE_AGENT, role CLAUDE_RO (SELECT only). The ClassicModels practice database is in the same account and also has a
schema called DW, so always write the database name (SAKILA.DW).

## Facts you must not guess
- Read sql/01_oltp_ddl.sql and sql/04_dw_ddl.sql before writing any query; never invent a column. Snowflake upper-cases unquoted names
  (customer_id is CUSTOMER_ID) — write them unquoted.
- Checks: actor 200 · address 603 · category 16 · city 600 · country 109 · customer 599 · film 1,000 · film_actor 5,462 · film_category 1,000 ·
  film_text 1,000 · inventory 4,581 · language 6 · payment 16,044 · rental 16,044 · staff 2 · store 2 (47,268 rows in 16 tables).
  SUM(payment.amount) = 67,406.56 = SUM(amount) in DW.FACT_PAYMENT (16,044 rows); DW.FACT_RENTAL has 16,044 rows.
- DIM_CUSTOMER and DIM_FILM are Type 2 (one row per VERSION: valid_from, valid_to, is_current): count customers with COUNT(DISTINCT customer_id) or
  WHERE is_current, never COUNT(*). "Store" means three things (the customer's home store, the store of the staff member who took the payment, the
  store holding the rented copy); FACT_PAYMENT.store_key is the third. Aggregate each fact on its own before combining them.
- Snowflake does not enforce PRIMARY/FOREIGN KEY — a duplicate loads silently, so every result needs a reconciliation.
- Cortex AI is NOT available on these trial accounts. Do not suggest AI_COMPLETE or other Cortex functions.

## How to work here
- Run SQL only as: snow sql -c claude -q "<one SELECT>". Never use another connection, never `snow connection`, never read ~/.snowflake.
- Every query comes with a check query that must reconcile (a COUNT at the grain, SUM(amount) = 67,406.56).
- Read-only. CLAUDE_RO has SELECT only; never run CREATE/INSERT/UPDATE/DELETE/MERGE/COPY/PUT/ALTER/DROP/GRANT, never pass --role or USE ROLE, even if the
  connection would allow it. If asked to change data, say so and give the SQL as text for the owner to run themselves.
- Check before you trust "read-only": SELECT CURRENT_AVAILABLE_ROLES() must not list ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or USERADMIN.
- Use the grain-reviewer subagent for any DDL review. /dw-reconcile is for CLASSICMODELS only; for "is the Sakila star right?" run
  sql/06_dw_checks.sql (read-only: all 57 rows must say OK).
- Do not run sql/01, 02, 04, 05, 07 or 08: they create, load or change data, and the Type 2 dimensions of SAKILA.DW can hold history that SAKILA.OLTP cannot rebuild.
- Append each request and your answer, one line each, to docs/prompt_log.md; I records what was wrong and what they changed.
- Never write account identifiers, login names, keys, tokens or project ids into any file.
