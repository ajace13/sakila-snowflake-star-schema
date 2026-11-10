"""Build the Sakila star schema locally in DuckDB from data/csv and reconcile it with the normalized tables.

This is a no-cloud companion to the Snowflake build in sql/. It loads the same 16 CSVs that were staged
into Snowflake, builds the same five dimensions and two facts (one version per row, since the sample data
has no history), and runs the core reconciliation checks from sql/06_dw_checks.sql.

Usage:
    python demo/build_star_duckdb.py              # in-memory, prints the checks
    python demo/build_star_duckdb.py sakila.duckdb  # also keeps the database file
"""
from __future__ import annotations

import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
CSV_DIR = ROOT / "data" / "csv"
TABLES = ["actor", "address", "category", "city", "country", "customer", "film", "film_actor",
          "film_category", "film_text", "inventory", "language", "payment", "rental", "staff", "store"]
# Money columns are exact decimals, as in MySQL and Snowflake, so totals reconcile to the cent.
MONEY = {"payment": {"amount": "DECIMAL(5,2)"},
         "film": {"rental_rate": "DECIMAL(4,2)", "replacement_cost": "DECIMAL(5,2)"}}


def load_oltp(con: duckdb.DuckDBPyConnection) -> None:
    con.execute("CREATE SCHEMA IF NOT EXISTS oltp")
    for t in TABLES:
        path = (CSV_DIR / f"{t}.csv").as_posix()
        types = MONEY.get(t)
        types_arg = (", types = {" + ", ".join(f"'{c}': '{d}'" for c, d in types.items()) + "}") if types else ""
        con.execute(f"""CREATE OR REPLACE TABLE oltp.{t} AS
                        SELECT * FROM read_csv('{path}', header = true, nullstr = '\\N', quote = '"',
                                               escape = '"', sample_size = -1{types_arg})""")


STAR_SQL = """
CREATE SCHEMA IF NOT EXISTS dw;

-- DIM_DATE (Type 0): one row per calendar day, plus member -1 for "no date yet"
CREATE OR REPLACE TABLE dw.dim_date AS
SELECT CAST(strftime(d, '%Y%m%d') AS INTEGER) AS date_key, CAST(d AS DATE) AS full_date,
       year(d) AS year, quarter(d) AS quarter, month(d) AS month, strftime(d, '%Y-%m') AS year_month,
       dayofweek(d) AS day_of_week, strftime(d, '%A') AS day_name
FROM range(DATE '2005-01-01', DATE '2031-01-01', INTERVAL 1 DAY) r(d)
UNION ALL SELECT -1, NULL, NULL, NULL, NULL, 'unknown', NULL, 'no date yet';

-- DIM_STORE and DIM_STAFF (Type 1)
CREATE OR REPLACE TABLE dw.dim_store AS
SELECT row_number() OVER (ORDER BY s.store_id) AS store_key, s.store_id, ci.city, co.country
FROM oltp.store s JOIN oltp.address a USING (address_id) JOIN oltp.city ci USING (city_id)
JOIN oltp.country co USING (country_id);

CREATE OR REPLACE TABLE dw.dim_staff AS
SELECT row_number() OVER (ORDER BY staff_id) AS staff_key, staff_id, first_name, last_name,
       store_id AS home_store_id, active
FROM oltp.staff;

-- DIM_CUSTOMER and DIM_FILM (Type 2): one version per row, valid for all history
CREATE OR REPLACE TABLE dw.dim_customer AS
SELECT row_number() OVER (ORDER BY c.customer_id) AS customer_key, c.customer_id, c.first_name, c.last_name,
       c.email, c.store_id, c.active, ci.city, co.country,
       TIMESTAMP '1900-01-01' AS valid_from, TIMESTAMP '9999-12-31' AS valid_to, TRUE AS is_current
FROM oltp.customer c JOIN oltp.address a USING (address_id) JOIN oltp.city ci USING (city_id)
JOIN oltp.country co USING (country_id);

CREATE OR REPLACE TABLE dw.dim_film AS
SELECT row_number() OVER (ORDER BY f.film_id) AS film_key, f.film_id, f.title, cat.name AS category,
       f.rating, f.rental_duration, f.rental_rate, f.replacement_cost, f.length, l.name AS language,
       TIMESTAMP '1900-01-01' AS valid_from, TIMESTAMP '9999-12-31' AS valid_to, TRUE AS is_current
FROM oltp.film f JOIN oltp.film_category fc USING (film_id) JOIN oltp.category cat USING (category_id)
JOIN oltp.language l ON l.language_id = f.language_id;

-- FACT_RENTAL: one row per rental
CREATE OR REPLACE TABLE dw.fact_rental AS
SELECT r.rental_id, r.inventory_id,
       CAST(strftime(r.rental_date, '%Y%m%d') AS INTEGER) AS rental_date_key,
       COALESCE(CAST(strftime(r.return_date, '%Y%m%d') AS INTEGER), -1) AS return_date_key,
       c.customer_key, f.film_key, st.store_key, sf.staff_key,
       r.rental_date AS rental_ts, r.return_date AS return_ts, 1 AS rental_count,
       date_diff('day', r.rental_date, r.return_date) AS days_out
FROM oltp.rental r
JOIN oltp.inventory i USING (inventory_id)
JOIN dw.dim_customer c ON c.customer_id = r.customer_id AND r.rental_date >= c.valid_from AND r.rental_date < c.valid_to
JOIN dw.dim_film f ON f.film_id = i.film_id AND r.rental_date >= f.valid_from AND r.rental_date < f.valid_to
JOIN dw.dim_store st ON st.store_id = i.store_id
JOIN dw.dim_staff sf ON sf.staff_id = r.staff_id;

-- FACT_PAYMENT: one row per payment; store_key = the store holding the rented copy
CREATE OR REPLACE TABLE dw.fact_payment AS
SELECT p.payment_id, p.rental_id, CAST(strftime(p.payment_date, '%Y%m%d') AS INTEGER) AS payment_date_key,
       c.customer_key, f.film_key, st.store_key, sf.staff_key, p.payment_date AS payment_ts, p.amount
FROM oltp.payment p
JOIN oltp.rental r USING (rental_id)
JOIN oltp.inventory i USING (inventory_id)
JOIN dw.dim_customer c ON c.customer_id = p.customer_id AND p.payment_date >= c.valid_from AND p.payment_date < c.valid_to
JOIN dw.dim_film f ON f.film_id = i.film_id AND r.rental_date >= f.valid_from AND r.rental_date < f.valid_to
JOIN dw.dim_store st ON st.store_id = i.store_id
JOIN dw.dim_staff sf ON sf.staff_id = p.staff_id;
"""

# Each check: name, SQL returning one value on the star, SQL returning the same value on the normalized copy.
CHECKS = [
    ("rentals", "SELECT COUNT(*) FROM dw.fact_rental", "SELECT COUNT(*) FROM oltp.rental"),
    ("payments", "SELECT COUNT(*) FROM dw.fact_payment", "SELECT COUNT(*) FROM oltp.payment"),
    ("customers", "SELECT COUNT(DISTINCT customer_id) FROM dw.dim_customer", "SELECT COUNT(*) FROM oltp.customer"),
    ("films", "SELECT COUNT(DISTINCT film_id) FROM dw.dim_film", "SELECT COUNT(*) FROM oltp.film"),
    ("revenue", "SELECT ROUND(SUM(amount), 2) FROM dw.fact_payment", "SELECT ROUND(SUM(amount), 2) FROM oltp.payment"),
    ("days out", "SELECT SUM(days_out) FROM dw.fact_rental",
     "SELECT SUM(date_diff('day', rental_date, return_date)) FROM oltp.rental"),
    ("revenue by month (groups that differ)",
     """SELECT COUNT(*) FROM (
          SELECT d.year_month AS k, ROUND(SUM(p.amount), 2) AS v FROM dw.fact_payment p
          JOIN dw.dim_date d ON d.date_key = p.payment_date_key GROUP BY 1) s
        FULL JOIN (SELECT strftime(payment_date, '%Y-%m') AS k, ROUND(SUM(amount), 2) AS v
                   FROM oltp.payment GROUP BY 1) o USING (k)
        WHERE s.v IS DISTINCT FROM o.v""", "SELECT 0"),
    ("revenue by category (groups that differ)",
     """SELECT COUNT(*) FROM (
          SELECT f.category AS k, ROUND(SUM(p.amount), 2) AS v FROM dw.fact_payment p
          JOIN dw.dim_film f USING (film_key) GROUP BY 1) s
        FULL JOIN (SELECT cat.name AS k, ROUND(SUM(p.amount), 2) AS v FROM oltp.payment p
                   JOIN oltp.rental r USING (rental_id) JOIN oltp.inventory i USING (inventory_id)
                   JOIN oltp.film_category fc USING (film_id) JOIN oltp.category cat USING (category_id)
                   GROUP BY 1) o USING (k)
        WHERE s.v IS DISTINCT FROM o.v""", "SELECT 0"),
    ("revenue by store holding the copy (groups that differ)",
     """SELECT COUNT(*) FROM (
          SELECT st.store_id AS k, ROUND(SUM(p.amount), 2) AS v FROM dw.fact_payment p
          JOIN dw.dim_store st USING (store_key) GROUP BY 1) s
        FULL JOIN (SELECT i.store_id AS k, ROUND(SUM(p.amount), 2) AS v FROM oltp.payment p
                   JOIN oltp.rental r USING (rental_id) JOIN oltp.inventory i USING (inventory_id)
                   GROUP BY 1) o USING (k)
        WHERE s.v IS DISTINCT FROM o.v""", "SELECT 0"),
    ("duplicate fact keys", """SELECT (SELECT COUNT(*) - COUNT(DISTINCT rental_id) FROM dw.fact_rental)
                                     + (SELECT COUNT(*) - COUNT(DISTINCT payment_id) FROM dw.fact_payment)""", "SELECT 0"),
]


def build(db_path: str = ":memory:") -> duckdb.DuckDBPyConnection:
    con = duckdb.connect(db_path)
    load_oltp(con)
    con.execute(STAR_SQL)
    return con


def run_checks(con: duckdb.DuckDBPyConnection) -> list[tuple[str, object, object, bool]]:
    results = []
    for name, star_sql, oltp_sql in CHECKS:
        star = con.execute(star_sql).fetchone()[0]
        oltp = con.execute(oltp_sql).fetchone()[0]
        results.append((name, star, oltp, star == oltp))
    return results


def main() -> int:
    con = build(sys.argv[1] if len(sys.argv) > 1 else ":memory:")
    results = run_checks(con)
    width = max(len(r[0]) for r in results)
    print(f"{'check':<{width}}  {'star':>12}  {'normalized':>12}  result")
    for name, star, oltp, ok in results:
        print(f"{name:<{width}}  {star!s:>12}  {oltp!s:>12}  {'MATCH' if ok else 'DIFF'}")
    failed = [r for r in results if not r[3]]
    print(f"\n{len(results) - len(failed)} of {len(results)} checks match")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
