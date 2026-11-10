# Sakila from Cloud SQL (MySQL 8.0) into Snowflake (SAKILA.OLTP)

## Status — complete
| Step | State |
|---|---|
| Source read, CSVs written, source counts and control totals computed | Done (`evidence/export_log.txt`) |
| `sql/01_oltp_ddl.sql`: 16 tables, 22 foreign keys, file format, stage | Done in Snowflake (first run failed on the timestamp default; fixed, see 2c) |
| 16 CSVs uploaded to `@SAKILA.OLTP.SAKILA_STAGE` | Done (`snow stage copy`, role SYSADMIN) |
| `sql/02_oltp_load_reconcile.sql`: 16 `COPY INTO`, all with 0 errors | Done (`evidence/load_log.txt`) |
| Reconciliation: counts, 16 control totals, picture MD5, duplicate keys, 22 foreign keys | All MATCH / 0 |
| Source numbers confirmed on the live Cloud SQL instance (step 0 below) | **Not done**: needs the root password, which the agent never handles. Until you run it, the source column is the dump that was imported into Cloud SQL |

`evidence/load_log.txt` ends with the output of the foreign-key and type-conversion checks. The first run of `sql/02` stopped on the foreign-key check because of a typo in its last line (`store.manager_staff_id` was compared with a column `store` does not have). That line is fixed in `sql/02_oltp_load_reconcile.sql`, and the checks were re-run from the fixed file; the error shows in the log between the two runs.

## 2a. Migration code and commands
| File | What it does |
|---|---|
| `src/export_sakila_csv.py` | Parses every INSERT in `sakila-data.sql` (the file that was imported into Cloud SQL), writes 16 CSVs to `data/csv/`, and writes `data/source_counts.csv` and `data/source_control_totals.csv` |
| `sql/01_oltp_ddl.sql` | Database `SAKILA`, schema `OLTP`, the 16 tables with their keys and foreign keys, file format, stage |
| `sql/02_oltp_load_reconcile.sql` | 16 `COPY INTO` statements, then the checks: counts, control totals, key uniqueness, 22 foreign keys |
| `sql/03_read_only_grants.sql` | SELECT-only grants so `CLAUDE_RO` can read `SAKILA` |
| `sql/00_source_counts_mysql.sql` | The same counts and controls as MySQL SELECTs, to run on the live Cloud SQL instance |

Run in this order:
```bash
# 0. (optional, confirms the source at the source) from Cloud SQL — asks for the root password; nothing is stored
cd <cloud-sql-project-folder> && source env.sh && gcloud sql connect "$INSTANCE" --user=root --quiet < sql/00_source_counts_mysql.sql

# 1. already run — regenerates the CSVs and counts from the dump
python3 -I src/export_sakila_csv.py | tee evidence/export_log.txt
```
2. Snowsight → new worksheet → paste `sql/01_oltp_ddl.sql` → **Run All** (role SYSADMIN, as you).
3. Upload the 16 CSVs to the stage. Use **your own** connection, not `claude` (read-only):
   ```bash
   snow stage copy "data/csv/*.csv" @SAKILA.OLTP.SAKILA_STAGE --connection <your-own-connection> --overwrite
   ```
   or in Snowsight: Data → Databases → SAKILA → OLTP → Stages → SAKILA_STAGE → **+ Files**, select all 16 files.
4. New worksheet → paste `sql/02_oltp_load_reconcile.sql` → **Run All**. Every check must say `MATCH` or `0`.
5. (Only if the agent is back on the read-only role) Worksheet as ACCOUNTADMIN → paste `sql/03_read_only_grants.sql` → Run All, so `CLAUDE_RO` can read `SAKILA`.

Step 2 was run by you in Snowsight; steps 3 and 4 were run by the agent through the `claude` connection with `--role SYSADMIN`.

## 2b. Row counts, table by table
Source = Sakila v1.5 as loaded into Cloud SQL, counted from the dump. These agree with the counts recorded from the live instance in the Cloud SQL project (film 1,000 · actor 200 · customer 599 · rental 16,044 · payment 16,044 · SUM(amount) 67,406.56). Step 0 repeats them on Cloud SQL itself.

| Table | Source rows | Snowflake rows | Result |
|---|---:|---:|---|
| actor | 200 | 200 | MATCH |
| address | 603 | 603 | MATCH |
| category | 16 | 16 | MATCH |
| city | 600 | 600 | MATCH |
| country | 109 | 109 | MATCH |
| customer | 599 | 599 | MATCH |
| film | 1,000 | 1,000 | MATCH |
| film_actor | 5,462 | 5,462 | MATCH |
| film_category | 1,000 | 1,000 | MATCH |
| film_text | 1,000 | 1,000 | MATCH |
| inventory | 4,581 | 4,581 | MATCH |
| language | 6 | 6 | MATCH |
| payment | 16,044 | 16,044 | MATCH |
| rental | 16,044 | 16,044 | MATCH |
| staff | 2 | 2 | MATCH |
| store | 2 | 2 | MATCH |
| **16 tables** | **47,268** | **47,268** | **MATCH** |

Beyond counts, `sql/02_oltp_load_reconcile.sql` also checks 16 control totals (for example `SUM(payment.amount)` = 67,406.56, 584 active customers, the staff picture's MD5), that no table has duplicate keys, and that all 22 foreign keys have zero orphans.

Two things in the source worth knowing:
- `rental` has 16,044 rows but `MAX(rental_id)` is 16,049: five ids are simply absent in this release. The original requirements quoted 16,049 payments and 67,416.51 from an older Sakila release, which had five payments with a NULL `rental_id` worth 9.95 together (MySQL bug #107158; 67,406.56 + 9.95 = 67,416.51). This release has 16,044 payments, none with a NULL `rental_id`, totalling 67,406.56; nothing was changed to force a match.
- `film_text` has no INSERTs in the dump. MySQL filled it through the `ins_film` trigger, so it is loaded as a copy of `film (film_id, title, description)`: 1,000 rows.

## 2c. What the migration did to the data types
Snowflake has no UNSIGNED, ENUM, SET, YEAR or TINYINT(1), no triggers, and no `ON UPDATE CURRENT_TIMESTAMP`. Each choice below keeps the value and says what was lost.

| MySQL | Snowflake | Why, and what changed |
|---|---|---|
| `DATETIME` (create_date, rental_date, return_date, payment_date) | `TIMESTAMP_NTZ(0)` | DATETIME has no time zone, and NTZ is the type with none. The dump holds plain literals like `2005-05-25 11:30:37`, and NTZ stores exactly those. `TIMESTAMP_LTZ`/`TZ` would attach the session's time zone and could shift values. Scale 0 matches DATETIME's default. |
| `TIMESTAMP` (every `last_update`) | `TIMESTAMP_NTZ(0)` with `DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0)` (a bare `CURRENT_TIMESTAMP()` is a TIMESTAMP_LTZ and Snowflake rejects it as the default of an NTZ column) | Same reason: the exported literals are kept as they are. **Lost:** `ON UPDATE CURRENT_TIMESTAMP`, so `last_update` no longer maintains itself when a row is updated. |
| `BOOLEAN` = `TINYINT(1)` (customer.active, staff.active) | `BOOLEAN` | In MySQL this is just a 0/1 number that could hold 7 as well. The export asserts only 0 and 1 occur, and Snowflake turns them into TRUE/FALSE, which a boolean should hold and which rejects anything else. Count of active customers is 584 on both sides. **Cost:** `SUM(active)` no longer works; use `COUNT_IF(active)` or `active::INT`. The other TINYINT columns are ids and stay numbers. |
| `ENUM('G','PG','PG-13','R','NC-17')` (film.rating) | `VARCHAR(5)` | No ENUM type and no CHECK constraint in Snowflake, so the label is kept and the allowed list is not enforced. **Behaviour change:** MySQL sorts an ENUM by its position (G, PG, PG-13, R, NC-17); a VARCHAR sorts alphabetically (G, NC-17, PG, PG-13, R). Counts per rating: G 178 · PG 194 · PG-13 223 · R 195 · NC-17 210. |
| `SET(...)` (film.special_features) | `VARCHAR(54)`, comma-separated | Kept as the exact text MySQL shows, e.g. `Trailers,Deleted Scenes`; that is lossless, and 54 is the length of all four values joined. Alternatives: an `ARRAY` (harder to compare with the source), or a bridge table `film_special_feature` (the properly normalized form, but it adds a table the source does not have). Query it with `SPLIT_TO_TABLE(special_features, ',')` or `ARRAY_CONTAINS('Trailers'::VARIANT, SPLIT(special_features, ','))`. **Lost:** membership validation. 15 distinct combinations occur. |
| `YEAR` (film.release_year) | `SMALLINT` | There is no YEAR type. `DATE` would invent a month and day; `VARCHAR(4)` would lose arithmetic. All 1,000 films are 2006. **Lost:** MySQL's 1901–2155 range check. |
| `BLOB` (staff.picture) | `BINARY` | Holds the same bytes (up to 8 MB; the one picture is 36,365 bytes, the other staff row is NULL). A CSV cannot carry raw bytes, so the file holds hex and the file format sets `BINARY_FORMAT = HEX`. Checked by byte length and by an MD5 of the hex text, not just "it loaded". |

Types not on the required list but needed for the same tables:

| MySQL | Snowflake | Why, and what changed |
|---|---|---|
| `GEOMETRY SRID 0` (address.location) | `GEOMETRY` | **Not `GEOGRAPHY`, on evidence:** 6 of the 603 source points have impossible coordinates (address 63 has longitude 766,456,911). MySQL accepts them because SRID 0 is planar; `GEOGRAPHY` would reject them. `GEOMETRY` keeps all 603 exactly. The export decodes MySQL's binary into WKT `POINT(x y)` and refuses anything that is not a finite point. The 6 are checked, not cleaned. |
| `SMALLINT/TINYINT/MEDIUMINT UNSIGNED`, `INT` | `SMALLINT`, `TINYINT`, `INTEGER` | Every Snowflake integer is `NUMBER(38,0)`, so the names are only for reading and the UNSIGNED limit is gone. `AUTO_INCREMENT` is dropped too: ids load as they are, so a later insert must supply its own id. |
| `DECIMAL(4,2)`, `(5,2)` | `NUMBER(4,2)`, `NUMBER(5,2)` | Exact, same precision and scale. Totals match to the cent. |
| `VARCHAR`, `CHAR(20)`, `TEXT` | `VARCHAR(n)`, `CHAR(20)`, `VARCHAR` | Same text, UTF-8 both sides (the accents in `city` are checked by character count). `staff.password`'s case-sensitive collation matches Snowflake's default. |
| NULL vs `''` | `\N` marker vs empty field | The source keeps both: `address2` is NULL in 4 rows and `''` in 599. The file format has `EMPTY_FIELD_AS_NULL = FALSE` and `NULL_IF = ('\\N')`, and the checks count both. |

Not migrated, because only the tables were in scope: 7 views, 6 stored routines, 5 triggers, secondary indexes, the FULLTEXT index on `film_text`, and the referential actions (`ON DELETE`/`ON UPDATE`). Foreign keys are recorded in Snowflake but not enforced, which is why `sql/02` proves them with orphan counts.
