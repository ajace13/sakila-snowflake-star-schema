# Claude explains; Snowflake decides

Every item ends in a table: **claim · what Claude said · what Snowflake says · correct (Y/N)**. Claude Code put its evidence next to each claim and left the last column as `TO DECIDE`. **I then made every decision in the terminal on 2026-10-26, and Claude Code only wrote the answers into the cells** (a ticked claim is Y, an unticked one N; notes I asked for are in the cells). The same goes for the accept/reject decisions and for "where Claude was wrong or overconfident": see **Decisions** at the end.

## Who did what
| Role | Who | What it did | What it was not allowed to do |
|---|---|---|---|
| **Checker** | Claude Code, the main agent | Ran every SQL statement against Snowflake through the project's `claude` connection, recorded exactly what came back, assembled this file | Fill in Y/N, accept/reject or the "where Claude was wrong" note |
| **CLAUDE (explainer)** | Three separate subagents (#1 plan, #2 difference, #3 prediction) | Explained pasted output: operator statistics, two queries and their results, a before/after pair | Run SQL; it was given no connection details and told to use no tools |
| **Reviewer** | The project's `grain-reviewer` subagent | Read `sql/04` and `sql/01` and reviewed the fact and Type 2 DDL | Run anything (it can only read files) |
| **Headless run** | `claude -p`, started by the checker exactly as written | Tried to write `docs/data_dictionary.md` | |

Limits of the set-up, stated plainly. The explainers were *instructed* not to use tools; the harness cannot enforce that. Each reported one tool use in its usage metadata; their reports are delivered through a hand-back call, which is the likely explanation, but I cannot verify it. The explainers were shown only pasted text (queries, results, operator statistics, column names), never connection details. Every query that read query history selected neither the user nor the account columns.

**Role in effect.** The setup has Claude Code sign in as `CLAUDE_AGENT` with the read-only role `CLAUDE_RO`. Here the `claude` connection's primary role is `CLAUDE_RO`, but the agent user also holds `ACCOUNTADMIN` (granted 2026-10-21) and its secondary roles are ALL, so `ACCOUNTADMIN` and `SYSADMIN` are active in every session (`SELECT CURRENT_AVAILABLE_ROLES(), CURRENT_SECONDARY_ROLES()`). Write access was switched on at my request for the migration, model and business-question work and the `.claude/settings.json` deny list was emptied. `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` for the agent user since 2026-10-19 shows 469 statements under `CLAUDE_RO` and 209 under `SYSADMIN`; 120 of the latter changed data (77 MERGE, 16 COPY, 9 CREATE TABLE, 6 UPDATE, 3 ALTER TABLE, 3 INSERT, 2 BEGIN, 2 ROLLBACK, 1 CREATE, 1 PUT): 113 between 20:23 and 21:06 UTC on 2026-10-25 (the migration, model and business-question work) and the last 7 MERGEs at 02:28 UTC on 2026-10-26, a re-run of `sql/05` that changed nothing. The checks in this file are SELECT, SHOW and DESCRIBE statements.

Raw evidence for everything below, including the prompts, is in `evidence/ai_checks/` (one file per step, named by task: `1a_*`, `1b_*`, `2_*`, `3_*`, `4_*`, `5_*`). The prompt log is `docs/prompt_log.md`; the Claude Code tool log is kept private.

---

# 1. Explain a plan

## 1a. The slowest query behind the Streamlit app, and what the plan says

**Choosing the query.** I listed the app's own queries from `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` (30 rows kept; full list in `1a_app_queries.txt`). Ranked by *elapsed* time the top entry is a Check-expander query on the normalized copy (2,536 ms, of which 2,285 ms is compilation). Operator statistics explain *execution*, not compilation or warehouse start-up, so I ranked by **execution time**: the headline KPI query on the star is the slowest by that measure of all of them (397 ms). This choice is mine and is on your checklist.

**Where these queries ran** (added at your request after I checked query history). The KPI query I analysed (973 ms, started 17:01:28 in the account's time zone) and the Check-expander rows at 17:01 (the 2,536 ms store query, the 875 ms month query and the 843 ms category query) came from one session that started at 16:52: an OAuth session on a Linux runtime with Python 3.11, which is the Streamlit-in-Snowflake runtime (my local runs use a key-pair session and Python 3.12). In all, that session sent 27 queries, every one successful. The `bounds` query (1,641 ms) and the 1,415 ms store query at 14:19 are from my own earlier local runs of the app.

| Query (app name) | Runs on | Elapsed ms | Compile ms | Execution ms | Bytes scanned |
|---|---|---:|---:|---:|---:|
| store | normalized (Check expander) | 2,536 | 2,285 | 251 | 253,952 |
| bounds | star | 1,641 | 1,182 | 284 | 217,616 |
| store | normalized (Check expander) | 1,415 | 1,179 | 236 | 204,800 |
| **kpi** | **star (page KPIs)** | **973** | **463** | **397** | **196,624** |
| month | normalized (Check expander) | 875 | 842 | 33 | 69,632 |
| category | normalized (Check expander) | 843 | 588 | 255 | 251,920 |

The query (it ran with the date filter 20050527–20050825):
```sql
SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers,
       ROUND(AVG(p.amount), 2) AS average_payment
FROM SAKILA.DW.FACT_PAYMENT p
JOIN SAKILA.DW.DIM_CUSTOMER c ON c.customer_key = p.customer_key   -- DIM_CUSTOMER is Type 2: count customer_id, not customer_key
WHERE p.payment_date_key BETWEEN 20050527 AND 20050825
```

**Operator statistics** (`GET_QUERY_OPERATOR_STATS`, what the Query Profile shows; raw in `1a_operator_stats.txt`):

| Operator | Type | Input rows | Output rows | Time share | Other |
|---:|---|---:|---:|---:|---|
| 0 | Result | 1 | | 0.0 | |
| 1 | Aggregate | 15,543 | 1 | 0.0 | SUM, COUNT(*), COUNT(DISTINCT customer_id) |
| 2 | Join (inner, customer_key) | 16,142 | 15,543 | 0.0 | |
| 3 | Filter | 15,543 | 15,543 | 0.0 | payment_date_key between the two bounds |
| 4 | TableScan FACT_PAYMENT | | 15,543 | 0.25 (all remote disk I/O) | 131,088 bytes, 1 of 1 partition, 0% from cache, columns PAYMENT_DATE_KEY, CUSTOMER_KEY, AMOUNT |
| 5 | JoinFilter | 599 | 599 | 0.0 | |
| 6 | TableScan DIM_CUSTOMER | | 599 | 0.25 (all remote disk I/O) | 65,536 bytes, 1 of 1 partition, 0% from cache, columns CUSTOMER_KEY, CUSTOMER_ID |

**What I gave the explainer:** the query text, the query-level numbers (elapsed, compilation, execution, bytes) and this table's raw text, and nothing else. It was asked: the most expensive operator and why; what the plan does; whether the date filter does useful work; whether the join or aggregate is a problem; compilation versus execution.

**What Claude said (explainer #1, verbatim):**

> 1. No single operator is clearly the most expensive. The only non-zero time_breakdown values are the two TableScans: operator 4 (FACT_PAYMENT) and operator 6 (DIM_CUSTOMER) each show overall_percentage 0.25, all of it remote_disk_io 0.25. Every other operator shows 0.0. That is a tie on time. By bytes, the fact scan is larger: 131,088 versus 65,536. Together they equal BYTES_SCANNED, 196,624. The percentages sum to 0.5, not 100, so the text does not say what the remaining time was.
>
> 2. Operator 4 scans PAYMENT_DATE_KEY, CUSTOMER_KEY and AMOUNT from FACT_PAYMENT and outputs 15,543 rows. Operator 6 scans CUSTOMER_KEY and CUSTOMER_ID from DIM_CUSTOMER and outputs 599 rows. JoinFilter 5 passes all 599 rows. The INNER equality join on CUSTOMER_KEY takes 16,142 rows in (15,543 + 599) and outputs 15,543. The Aggregate computes SUM(AMOUNT), COUNT(*), COUNT(DISTINCT CUSTOMER_ID) and COUNT(AMOUNT), and outputs 1 row. Result then derives the average as ROUND(SUM/COUNT, 2).
>
> 3. There was no partition pruning: partitions_scanned 1 of partitions_total 1 on both tables. The Filter operator (3) has input_rows 15,543 and output_rows 15,543, so it removed nothing itself. The scan, however, already outputs 15,543 rows, which is fewer than the 16,044 table rows you gave. So the date predicate did discard 501 rows, but only at or before the scan output, as row-level filtering and not as pruning. The text does not say exactly where that happened.
>
> 4. Neither looks like a problem. The join outputs exactly as many rows as the fact side supplied (15,543). That shows no row multiplication and no unmatched payment rows. The aggregate reduces 15,543 rows to 1 and has 0.0 time. The text does NOT show memory use, spilling, join build/probe timing, the cost of COUNT(DISTINCT) separately, or whether DIM_CUSTOMER has several versions per customer_id. It also says nothing about other runs or larger data.
>
> 5. Compilation was 463 ms (about 48% of 973 ms) and execution was 397 ms (about 41%). That leaves 113 ms that the text does not attribute. Compilation is larger than execution. Execution is also tiny: one partition per table and about 197 KB scanned. Tuning the plan or data layout could therefore only act on the 397 ms, and the scans are the only measurable part of that. The text does not say why compilation was slow, so it does not support a specific fix.

**What Snowflake says** (queries and outputs in `1a_evidence.txt`):


| # | Claim | What Claude said | What Snowflake says | Correct (Y/N) |
|---|---|---|---|---|
| 1 | The most expensive operator | "No single operator is clearly the most expensive": the two TableScans tie at 0.25 each (all remote_disk_io), everything else 0.0; the fact scan is bigger in bytes | The operator statistics show exactly that: 0.25 and 0.25, all others 0.0. 131,088 + 65,536 = 196,624, which equals the query's `BYTES_SCANNED` (196,624) | **Y** |
| 2 | The percentages | "The percentages sum to 0.5, not 100, so the text does not say what the remaining time was" | The only non-zero shares are the two scans (0.25 + 0.25 = 0.5). Snowflake does not say where the other half went in these statistics | **Y** |
| 3 | Pruning | "No partition pruning: 1 of 1 on both tables" | The operator statistics say 1 of 1 for both scans, and `SYSTEM$CLUSTERING_INFORMATION` reports `total_partition_count` 1 for FACT_PAYMENT and 1 for DIM_CUSTOMER | **Y** |
| 4 | The date filter | "The Filter removed nothing itself (15,543 in, 15,543 out); the predicate discarded 501 rows at or before the scan output, as row-level filtering" | The table has 16,044 rows, 15,543 inside the range and 501 outside; the scan already outputs 15,543. Where exactly the 501 were dropped is not shown by Snowflake | **Y** |
| 5 | The join | "The join outputs exactly as many rows as the fact side supplied (15,543): no multiplication, no unmatched payments" | The same join, run alone, returns 15,543 rows for 15,543 fact rows in range | **Y** |
| 6 | What the text cannot show | "Whether DIM_CUSTOMER has several versions per customer_id" is unknown | `DIM_CUSTOMER` has 599 rows, 599 distinct `customer_id` and 599 distinct `customer_key`: one version each today | **Y** |
| 7 | Where the 973 ms went | "Compilation 463 ms (about 48%), execution 397 ms (about 41%), leaving 113 ms the text does not attribute" | Query history: `COMPILATION_TIME` 463, `EXECUTION_TIME` 397, **`QUEUED_PROVISIONING_TIME` 113**, other queue and block times 0. 463 + 397 + 113 = 973 | **Y** |
| 8 | What tuning could do | "Tuning could only act on the 397 ms, and the scans are the only measurable part; the text does not support a specific fix" | See 1b: the one change I tried did not change the plan or the bytes | **N** |

## 1b. One change, before and after

**The change (chosen by you from three options, shown to you before it ran):** drop the date filter when the range covers the whole data. The app's default view covers every payment, so the `BETWEEN 20050524 AND 20060214` should remove nothing, yet I expected it to force a scan of `PAYMENT_DATE_KEY`. Measured on the full-range KPI query, the app's default view. The two queries differ only in that `WHERE` clause (`1b_measure.sql`).

**Protocol.** `ALTER SESSION SET USE_CACHED_RESULT = FALSE` (session only; no object created) and a `QUERY_TAG` per query. One warm-up pair of queries that read all four columns, then before/after alternated three times; then a second round with the order swapped and a control of the same query six times, because in the first round "after" always ran second. Every run is in `1b_raw.txt` and `1b_raw2.txt`.

**What I gave the explainer first (#3), before measuring:** the two queries and the earlier plan statistics, no results. **What Claude predicted (verbatim):**

> 1. Yes, identical. The BETWEEN 20050524 AND 20060214 filter spans the whole data range, so all 16,044 rows pass. This assumes no NULL payment_date_key, which BETWEEN would drop. I can't confirm that from the text. The join is the same in both queries. Expected output: same revenue, 16,044 payments, at most 599 paying customers, same average.
>
> 2. BEFORE is about 196,624 bytes (range 190k-200k), matching the earlier run. AFTER should be lower because PAYMENT_DATE_KEY is no longer read. Best guess is about 160,000 (range 131,000-196,624). DIM_CUSTOMER stays at 65,536. The FACT scan should fall from 131,088 by one column's compressed size. That column is a low-cardinality integer, so I expect it to be small, about 20-45 KB. The scan sizes look chunky (65,536 for two DIM columns), so "no change" is possible. I put that at about 20%.
>
> 3. BEFORE is 600-1,100 ms, best guess 850. AFTER is 600-1,100 ms, best guess 820. I expect a difference under 50 ms, which is not larger than run-to-run noise of roughly 100-200 ms. Compilation (about 460 ms) and provisioning dominate, and the filter cost about 0 ms in the earlier plan.
>
> 4. The Filter operator should be missing from AFTER. It showed 0.0 time before. The Join, Aggregate and Result operators remain, along with both TableScans.
>
> 5. BYTES_SCANNED does not depend on cache state, so the byte prediction holds either way. Elapsed time does. A cold local cache adds remote_disk_io, which was 0.25 per scan earlier. A warm cache would cut execution time by a few hundred ms. Whichever query runs second would get warm data. That would bias the comparison unless the order is alternated. The warm-up query probably doesn't touch these tables.

**Results.** All 18 runs scanned `BYTES_SCANNED` = 239,616 (warm-up: 174,080 and 65,536). Every one of the 18 result sets was identical: revenue 67,406.56, 16,044 payments, 599 paying customers, average 4.20.

| Round | Order | Variant | Elapsed ms (3 runs) | Median | Compile ms | Execution ms |
|---|---|---|---|---:|---|---|
| 1 | before, then after | BEFORE | 202, 118, 193 | 193 | 173, 100, 171 | 29, 18, 22 |
| 1 | before, then after | AFTER | 106, 73, 91 | 91 | 89, 59, 73 | 17, 14, 18 |
| 2 | after, then before | AFTER | 90, 90, 81 | 90 | 71, 72, 64 | 19, 18, 17 |
| 2 | after, then before | BEFORE | 99, 91, 79 | 91 | 80, 74, 64 | 19, 17, 15 |
| control | BEFORE six times in a row | BEFORE | 101, 100, 98, 89, 84, 80 | 93.5 | | |

**Plans** (`GET_QUERY_OPERATOR_STATS`, one run of each; `1b_operators.txt`): identical. Result, Aggregate, Join, JoinFilter and two TableScans in both; **no Filter operator in the BEFORE plan**; FACT_PAYMENT is scanned for `CUSTOMER_KEY` and `AMOUNT` only (40,960 bytes) in both; DIM_CUSTOMER for `CUSTOMER_KEY` and `CUSTOMER_ID` (4,096 bytes). The operator-level bytes (45,056 in total) do not add up to the query-level `BYTES_SCANNED` (239,616) in these warm runs, although they did in the cold run of 1a; I do not know why and have not tried to explain it.

**What this shows.** The change made no measurable difference: same plan, same bytes, same results. The ~100 ms gap in round 1 did not survive swapping the order (round 2: 90 versus 91 ms) and the same text run six times varies by 21 ms, so it was an ordering and warm-up effect, mostly in compilation (round 1 BEFORE compile times 100–173 ms against 64–80 ms for the same text in round 2; I did not investigate the cause). Why the filter disappeared is an inference: `MIN` and `MAX` of `PAYMENT_DATE_KEY` are 20050524 and 20060214 with no NULLs, exactly the bounds of the filter, which is consistent with Snowflake proving the predicate true from the partition's metadata and removing it at compile time. I did not confirm that mechanism any further. My own recommendation ("still forces a scan of `PAYMENT_DATE_KEY`") was therefore wrong.

| # | Claim | What Claude said | What Snowflake says | Correct (Y/N) |
|---|---|---|---|---|
| 1 | Results identical | "Yes, identical" (assuming no NULL `payment_date_key`) | 18 of 18 result sets identical; `payment_date_key` has 0 NULLs | **Y** |
| 2 | Bytes before | "About 196,624 (range 190k–200k), matching the earlier run" | 239,616 in every BEFORE run (the earlier run used a narrower range) | **N** |
| 3 | Bytes after | "About 160,000 (range 131,000–196,624)", with "no change" possible at about 20% | 239,616, identical to before | **N** |
| 4 | Elapsed before and after | "600–1,100 ms for both, best guesses 850 and 820" | 73–202 ms in every run (warm warehouse, medians 91–193 ms) | **N** |
| 5 | The size of the difference | "Under 50 ms, not larger than run-to-run noise of roughly 100–200 ms" | Round 1 showed ~100 ms (193 vs 91 median) but not reproducibly; round 2 showed 1 ms; the control's spread was 21 ms | **Y** — its conclusion held (with the order controlled the gap was 1 ms, and round 1's ~100 ms vanished once the order was swapped); its noise estimate of 100–200 ms was too high, since the control varied by only 21 ms |
| 6 | The Filter operator | "Should be missing from AFTER" | Missing from both: the BEFORE plan has no Filter operator either | **Y** |
| 7 | The remaining operators | "Join, Aggregate and Result remain, along with both TableScans" | Yes, in both plans | **Y** |
| 8 | The order of runs | "Whichever query runs second would get warm data; that would bias the comparison unless the order is alternated" | The fixed-order round showed a gap that disappeared when the order was swapped | **N** |
| 9 | The warm-up | "The warm-up query probably doesn't touch these tables" | Right for a generic warm-up; mine read all four columns, so every measured run was warm | **N** |

---

# 2. Explain a difference

**The question:** *revenue by store*. It is the business question where the normalized copy and the star give different answers **today**, without any history in the data: the normalized query that comes naturally uses the customer's home store, while the star's `store_key` is a different thing. (The other candidate, revenue by customer country, only differs once a customer has moved.) Same totals, different split:

| Store | A: normalized, customer's home store | B: star, `FACT_PAYMENT.store_key` |
|---|---|---|
| 1 | 8,747 payments · 36,997.53 | 7,923 payments · 33,679.79 |
| 2 | 7,297 payments · 30,409.03 | 8,121 payments · 33,726.77 |

```sql
-- A (normalized)
SELECT c.store_id, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.OLTP.payment p
JOIN SAKILA.OLTP.customer c ON c.customer_id = p.customer_id
GROUP BY c.store_id ORDER BY c.store_id

-- B (star)
SELECT s.store_id, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.DW.FACT_PAYMENT p
JOIN SAKILA.DW.DIM_STORE s ON s.store_key = p.store_key
GROUP BY s.store_id ORDER BY s.store_id
```

**What I gave the explainer (#2):** queries A and B, their results, and the *names* of the relevant columns. Not the column comments, not the load SQL and not the deciding query. **What Claude said (verbatim):**

> 1. A and B differ because they assign each payment to a store by different keys. A uses customer.store_id, which is the customer's home store, through payment.customer_id. B uses FACT_PAYMENT.store_key, which maps to DIM_STORE.store_id. The text does not say how store_key was loaded. Likely sources are the processing staff's store (payment.staff_id to staff.store_id) or the store holding the rented inventory (rental to inventory.store_id). I can't tell which from the text.
>
> 2. Neither is wrong on this evidence. A answers "revenue by the store the paying customer is registered with". B answers "revenue by the store that took the payment", under whichever definition the load used. They are two different questions that both get called "revenue by store". The decision belongs to the business, and the star's load logic should be documented.
>
> 3. The totals are identical. Payments: 8747+7297 = 16,044 and 7923+8121 = 16,044. Revenue: 36997.53+30409.03 = 67,406.56 and 33679.79+33726.77 = 67,406.56. So no rows were lost, duplicated or filtered by either join. Only the allocation between stores differs. The fact table has the same grain and total as payment, and this is a definition difference, not a load defect.
>
> 4. This query shows each payment's store under all three definitions:
> SELECT c.store_id AS customer_store, s.store_id AS staff_store, i.store_id AS inventory_store, COUNT(*) AS payments, SUM(p.amount) AS revenue
> FROM SAKILA.OLTP.payment p
> JOIN SAKILA.OLTP.customer c ON c.customer_id = p.customer_id
> JOIN SAKILA.OLTP.staff s ON s.staff_id = p.staff_id
> LEFT JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
> LEFT JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
> GROUP BY 1,2,3 ORDER BY 1,2,3
> Check: payments must sum to 16,044 and revenue to 67,406.56. Grouping by customer_store must reproduce A. Whichever of staff_store or inventory_store reproduces B (7923 / 33679.79 and 8121 / 33726.77) is the star's definition.
>
> 5. If the star had used the customer's store, B would equal A: store 1 = 8747 / 36997.53 and store 2 = 7297 / 30409.03. In the other direction, if A had used B's definition, A would equal B: 7923 / 33679.79 and 8121 / 33726.77. Either way the totals stay at 16,044 and 67,406.56.

**The one query that decides** (run on the normalized copy: each payment's store under the star's definition, the copy's store, and under A's, the customer's home store):
```sql
SELECT i.store_id AS copy_store, c.store_id AS home_store, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM SAKILA.OLTP.payment p
JOIN SAKILA.OLTP.rental r ON r.rental_id = p.rental_id
JOIN SAKILA.OLTP.inventory i ON i.inventory_id = r.inventory_id
JOIN SAKILA.OLTP.customer c ON c.customer_id = p.customer_id
GROUP BY i.store_id, c.store_id ORDER BY i.store_id, c.store_id
```

| copy_store | home_store | payments | revenue |
|---:|---:|---:|---:|
| 1 | 1 | 4,326 | 18,548.74 |
| 1 | 2 | 3,597 | 15,131.05 |
| 2 | 1 | 4,421 | 18,448.79 |
| 2 | 2 | 3,700 | 15,277.98 |

**Result.** Summing by `copy_store` gives 7,923 / 33,679.79 for store 1 and 8,121 / 33,726.77 for store 2, **exactly B**. Summing by `home_store` gives 8,747 / 36,997.53 and 7,297 / 30,409.03, **exactly A**. The gap for store 1 (36,997.53 − 33,679.79 = 3,317.74) equals the difference of the two off-diagonal cells (18,448.79 − 15,131.05 = 3,317.74): it is made entirely of payments whose customer is registered at one store and whose copy belongs to the other. Neither query has a defect; each answers its own definition of "store". Which definition is *the* revenue of a store is a business decision. The star documents its own: `FACT_PAYMENT.STORE_KEY` has the column comment "store that holds the rented copy".

**What Snowflake says** (outputs in `2_evidence.txt`):

| # | Claim | What Claude said | What Snowflake says | Correct (Y/N) |
|---|---|---|---|---|
| 1 | What A means | "A uses customer.store_id, the customer's home store, through payment.customer_id" | True of the query as written. The star asked with `DIM_CUSTOMER.store_id` returns A's numbers exactly (8,747 / 36,997.53 and 7,297 / 30,409.03) | **Y** |
| 2 | What B means | "B uses store_key → DIM_STORE.store_id"; "the text does not say how store_key was loaded" | The column comment says "store that holds the rented copy" | **Y** |
| 3 | Where store_key might come from | "Likely the processing staff's store or the store holding the rented inventory; I can't tell which" | The inventory store: its totals equal B exactly. The staff store does not (8,054 payments, 33,482.50 for store 1) | **Y** |
| 4 | What B answers | "B answers 'revenue by the store that took the payment', under whichever definition the load used" | The store that took the payment (staff's store) gives 33,482.50 / 33,924.06, not B's 33,679.79 / 33,726.77. B is the store holding the copy | **N** |
| 5 | Which is right | "Neither is wrong; two different questions both called 'revenue by store'" | Each definition reproduces its own totals exactly (deciding query) | **Y** |
| 6 | The totals | "Identical: 16,044 payments and 67,406.56 on both" | A: 16,044 and 67,406.56; B: 16,044 and 67,406.56; `payment`: 16,044 and 67,406.56 | **Y** |
| 7 | Load defect or definition | "A definition difference, not a load defect" | Consistent: the star equals the normalized copy once both use the same definition | **Y** |
| 8 | Its deciding query | "Group by customer_store, staff_store, inventory_store; customer_store must reproduce A; whichever of staff_store or inventory_store reproduces B is the star's" | I ran it as written. By customer_store: 8,747 / 36,997.53 and 7,297 / 30,409.03. By inventory_store: 7,923 / 33,679.79. By staff_store: 8,054 / 33,482.50 | **Y** |
| 9 | If the star used the customer's store | "B would equal A (8,747 / 36,997.53 and 7,297 / 30,409.03)" | Yes: the star by `DIM_CUSTOMER.store_id` gives exactly those numbers | **Y** |
| 10 | If A used the star's definition | "A would equal B (7,923 / 33,679.79 and 8,121 / 33,726.77)" | Yes: the deciding query's copy-store totals are exactly those | **Y** |

---

# 3. Review

**What I gave the reviewer:** the path of `sql/04_dw_ddl.sql` (the two facts and the two Type 2 dimensions), the path of the normalized DDL `sql/01_oltp_ddl.sql`, and the question: grain, keys, additivity, double counting, Snowflake behaviour, ranked findings with line numbers and fixes. No hints about what to find.

**The reviewer's report, in full** (one absolute path in its first line was shortened to `<project folder>` to remove the OS user name; nothing else was changed):

<details><summary>Open the reviewer's report (verbatim)</summary>

REVIEW OF <project folder>/sql/04_dw_ddl.sql
Nothing was run. I read 07 and 01_oltp_ddl.sql. I also read 05_dw_load_merge.sql and 06_dw_checks.sql, because the load decides whether the DDL's promises hold. File:line below means 07 unless I name another file. Fixes are described as edits for me to make, not as write statements. All check queries are SELECT text.

=== FACT TABLES ===

**FACT_RENTAL (07:85-103)**

Grain: one row per rental_id. Lines 96 (PRIMARY KEY rental_id) and 103 (the grain COMMENT) set it. 08:122 merges on rental_id, and 04:164 has rental_id as the source PK.
- Every column fits the grain. The return columns (88, 93, 95) are filled in later by the MERGE (08:123-124), so this is an accumulating-snapshot row, as lines 83-84 say.
- Weak wording at line 103: "one copy rented by one customer on one date". The source's own uniqueness is (rental_date, inventory_id, customer_id) at full-timestamp precision (04:165). A customer can legitimately rent the same copy twice in one day. Read literally, that sentence would collapse two real rentals. The true grain is rental_id, not that triple.
- Keys:
  - rental_id (line 86) is a degenerate dimension. That is correct.
  - inventory_id (line 87) is labelled "degenerate", but it is the key of a copy entity that has no dimension. film_key and store_key are derived from it (08:117-120). I'd call this wording imprecise, not wrong.

Measures:
- rental_count (94): additive. It is a constant 1 (08:114), so SUM gives the number of rentals across every dimension.
- days_out (95): additive over every dimension, but only for returned rentals. It is NULL until return.
  - It is a DATEDIFF('day') calendar-boundary count (08:115), so a 23-hour rental can show 1 and a 2-hour rental can show 0. Do not compare it to film.rental_duration as an overdue test.
  - It is restated when a copy comes back, so a report run earlier will not match one run later.
  - Averages must use SUM(days_out)/COUNT(days_out). The comment at line 95 already says this.
- DIM_FILM.rental_rate and replacement_cost (72) are dimension attributes, not measures. Summing them through a fact join is wrong.

Joins in the load that could multiply rows (08:109-122). Each is a potential duplicate-key insert, because PK and UNIQUE are not enforced:
- DIM_CUSTOMER range join (08:118) and DIM_FILM range join (08:119). They multiply if any version intervals overlap.
- inventory join (08:117) and the DIM_STORE / DIM_STAFF joins on natural key (08:120-121). They multiply if the source or dimension holds duplicate keys. Both are unenforced.

Check, to run before the MERGE:
`SELECT COUNT(*) - COUNT(DISTINCT rental_id) FROM (<the 08:110-121 SELECT>);`
It must return 0 and the COUNT(*) must equal the OLTP rental count (326... see the project count for Sakila).
After the load, 09:76 does the same for the fact table and 09:104-105 check the as-of keys.

Nothing prevents a duplicate or null return_ts / return_date_key mismatch. return_date_key = -1 and return_ts IS NULL (88, 93) are two copies of one fact and nothing ties them together. Check: `SELECT COUNT(*) FROM FACT_RENTAL WHERE (return_ts IS NULL) <> (return_date_key = -1);` (09:14 covers the count only, not the row-level agreement.)

**FACT_PAYMENT (07:108-124)**

Grain: one row per payment_id. Lines 118 (PRIMARY KEY) and 124 (COMMENT) set it. The source PK is at 04:178.
- The words "against one rental" (line 124) do not hold for every source row. rental_id is NOT NULL here (110), but payment.rental_id is nullable in the source (04:174).
  - The load LEFT JOINs rental (08:137), so a payment with a NULL rental_id gets NULL film_key and store_key.
  - That aborts the whole MERGE on NOT NULL. This is loud, not silent.
  - I cannot tell from the files whether this data has such rows. My recollection is that reference Sakila has a few. I am not sure.
  - The model cannot represent a payment with no rental. Decide whether to allow a NULL or an "unknown rental" member, and document it.
- Nothing makes rental_id unique within this fact (110). The comment says it is 1:1 "in this data", checked in 09. That is a data property, not a schema guarantee. 09:78 checks it.
- Every column fits the grain. film_key is resolved from the rental time (line 113) and customer_key from the payment time (line 112), which is deliberate and documented.

Measures:
- amount (117): additive across every dimension, including time, because it is a flow of money.
  - NUMBER(5,2) allows negatives, so it silently permits refunds.
  - It does not sum with rental measures.
- There is no other measure.

Joins in the load (08:133-142) that could multiply rows:
- rental and inventory (08:137-138, source PKs unenforced).
- The customer range join (08:139) and the film range join (08:140).
- Natural-key joins to store and staff (08:141-142).

Check, to run before the MERGE:
`SELECT COUNT(*) - COUNT(DISTINCT payment_id) FROM (<the 08:134-142 SELECT>);`
It must return 0. Also check:
`SELECT COUNT(*) FROM SAKILA.OLTP.payment WHERE rental_id IS NULL;`
It must return 0, or line 110 is wrong.

Joining the two facts to each other:
- On rental_id it is 1:1 in this data (09:81), but only by observation. Any rental with two payments multiplies FACT_RENTAL measures (rental_count, days_out).
- Through a shared dimension (for example both on film_key) with no prior aggregation, it multiplies in both directions. Every rental for a film pairs with every payment for that film, so SUM(amount) and SUM(rental_count) are both inflated. This is the classic chasm trap.
- Check, for any query that joins them: `SELECT SUM(amount) FROM FACT_PAYMENT` must equal the SUM(amount) over the joined result. Compare the totals in 09:9 and 09:11 against the joined query's output.

=== DIMENSIONS ===

- **DIM_CUSTOMER (50-63)**
  - Key: surrogate customer_key (line 51); natural key customer_id repeats once per version (52).
  - Not one row per entity. It is one row per version (the table comment at 63 says so). COUNT(*) overcounts customers; use COUNT(DISTINCT customer_id).
  - SCD Type 2 is justified for address, city, country and store_id (lines 48-49).
  - It is over-tracked: names, email, phone, create_date and active all start a new version (line 63, "every attribute"). That is version bloat, but it is not a correctness defect.
- **DIM_FILM (67-79)**
  - Key: surrogate film_key (68); natural key film_id repeats (69). One row per version.
  - Type 2 is a stated choice for rental_rate, replacement_cost, rental_duration and rating (65-66). The caveat at line 66 is real: OLTP holds only today's value, so true history starts at the first load, not before.
  - `category` is a single column (70), but film_category is many-to-many in the source (04:136 PK film_id, category_id). The load joins it directly (08:90), so a film with two categories becomes two source rows and two first versions. 09:108 checks for this.
- **DIM_STORE (27-34)**
  - Key: store_key; natural key store_id, UNIQUE (33). One row per store. Type 1 by choice (25-26).
  - A manager change overwrites history. That is a documented, acceptable choice, but it restates old facts.
- **DIM_STAFF (39-46)**
  - Key: staff_key; natural key staff_id, UNIQUE (45). One row per staff member. Type 1 by choice (36-38).
  - home_store_id is overwritten on reassignment, and that is documented.
- **DIM_DATE (17-23)**
  - Key: date_key = yyyymmdd (18). One row per calendar day, plus the -1 sentinel, which is not a day. The count of 9,496 days is correct (26 years, 6 leap years).
  - Type 0; no SCD needed.
  - The -1 row has NULL in every attribute (08:20). Reports by return month or year show a blank group, not a label like "Not returned".

=== LOWER-SEVERITY DEFECTS AND RISKS ===
- Type 2 as-of time (08:9, 08:78, 08:103):
  - The new version's valid_from is the load time, not the time the change happened. Facts that occurred between the real change and the next load are attributed to the old version.
  - etl_as_of uses CURRENT_TIMESTAMP in the session time zone. Source timestamps are zone-less wall-clock values. Running the load from sessions with different zones shifts valid_from by hours.
  - Two changes within one second give a zero-width interval and a duplicate (customer_id, valid_from) (07:62, 07:78).
  - 08:4-5 invites replaying an earlier date. That can produce valid_to earlier than valid_from, and nothing rejects it.
- Row-hash NULL handling is correct. The load uses TO_JSON(ARRAY_CONSTRUCT(...)), so NULL and '' hash differently, and 09:111 tests it. I found no defect here.
- Snowflake keys:
  - PK, UNIQUE and FK are declared but not enforced; NOT NULL is. There is no CHECK constraint, so "always 1" (94) and "valid_to > valid_from" cannot be declared.
  - AUTOINCREMENT values can skip. Do not treat key order or gaps as meaningful.
  - I am not certain whether Snowflake accepts NOT NULL before AUTOINCREMENT in the column definition. The note at 07:126 suggests the file was run, so it probably does.
  - The data types SMALLINT and TINYINT are all NUMBER(38,0) in Snowflake. They constrain nothing, so there is no overflow risk from them.
- FACT_PAYMENT has no rental_date_key and no inventory_id (108-117). "Revenue by rental month" or "by copy" needs a join to FACT_RENTAL, which line 110 tells analysts not to do. The model pushes people toward the join it forbids.
- The comment at line 106-107 (8,078 of 16,044 payments differ in customer or staff from the rental) is not checkable from these files. I did not verify it.
- I did not find a defect in: the surrogate-key vs natural-key split on the four Type 1/2 dimensions, the -1 date member's presence in the FK design, or the amount and rental_count measure types.

=== FINDINGS (most important first) ===

1. **Overlapping or duplicate Type 2 versions would double-count, and nothing in the DDL stops them.**
   - Where: UNIQUE (customer_id, valid_from) at 07:62 and UNIQUE (film_id, valid_from) at 07:78 are the only guards. They are not enforced, and they do not prevent two current rows or overlapping intervals (60, 76).
   - Effect: both facts pick their version with a range LEFT JOIN (08:118-119, 08:139-140). An overlap returns two source rows for one rental_id or payment_id. The MERGE's NOT MATCHED branch inserts both silently, because the PKs at 07:96 and 07:118 are not enforced. SUM(amount) and SUM(rental_count) are then inflated.
   - Fix: make the load gate on 09 section 5 before the fact MERGE. Add a dedup guard to the fact source SELECTs, for example `QUALIFY ROW_NUMBER() OVER (PARTITION BY rental_id ORDER BY valid_from DESC) = 1`.
   - Evidence the checks exist: 09:88-99 are post-hoc and only run if someone runs them.
   - Confidence: high that nothing is enforced. I did not run anything to see whether any overlap exists today.

2. **The two facts do not share a customer key, and joining them multiplies rows.**
   - Where: FACT_RENTAL.customer_key is the version at rental_ts (07:89). FACT_PAYMENT.customer_key is the version at payment_ts (07:112). A customer who changes between rental and payment has a different customer_key in each fact.
   - Effect: a drill-across on customer_key silently drops or mismatches rows. Joining on customer_id instead multiplies each fact by the number of versions. Joining both facts to a shared dimension without aggregating each first inflates both measures (see "Joining the two facts" above).
   - Fix: aggregate each fact separately, then combine on a conformed attribute such as customer_id or country. Add rental_date_key to FACT_PAYMENT (07:108-117) so nobody needs the rental_id join.
   - Confidence: high on the mechanism. The data-level impact depends on how many customers have more than one version.

3. **`CREATE TABLE IF NOT EXISTS` makes every fix to this file a silent no-op on existing tables.**
   - Where: 07:5-7 and every CREATE in the file. The only way to apply a changed definition, per the header, is to recreate the schema. That destroys Type 2 history that OLTP no longer has.
   - Effect: editing the DDL for findings 1 and 2, or for the nullable rental_id mismatch (07:110 vs 04:174), changes nothing in Snowflake. The file and the live tables drift apart with no error.
   - Fix: add a schema-drift check, for example comparing SAKILA.INFORMATION_SCHEMA.COLUMNS against the expected columns, and plan an explicit, reviewed migration that preserves the Type 2 dimensions. I am not writing that migration.
   - Confidence: high that IF NOT EXISTS skips an existing table. I am not sure of the retention settings on this account for recovering a dropped schema.

</details>

**Its line numbers were checked** against the files (`3_ddl_lines.txt`): `07:62` and `07:78` (the `UNIQUE (…, valid_from)` lines), `07:96` and `07:118` (the fact primary keys), `07:103` and `07:124` (the grain comments), `07:110` and `07:112` (`rental_id`, `customer_key` of the payment fact), `08:118-119`, `08:122`, `08:139-140`, `08:143` (the range joins and the MERGE keys), `04:164`, `04:165`, `04:174`, `04:178` all point at what it says. The file has 127 lines, so its reference to a note at `07:126` is right (a comment, not code).

## The three findings, with evidence

| # | Finding (reviewer, short) | DDL / load lines | What Snowflake says | Accept or reject, and one reason |
|---|---|---|---|---|
| 1 | Overlapping or duplicate Type 2 versions would double-count, and nothing in the DDL stops them (the UNIQUEs are informational) | `07:62` `UNIQUE (customer_id, valid_from)`; `07:78` `UNIQUE (film_id, valid_from)`; `07:60`/`07:76` `is_current`; `07:96`, `07:118` fact PKs; the fact loads pick versions with range joins at `08:118-119` and `08:139-140` | **No problem today**: customers without exactly one current version 0, overlapping version pairs 0, duplicate (customer_id, valid_from) 0 (599 rows, 599 customers); the same three for films 0 (1,000 rows, 1,000 films); duplicate keys in `FACT_RENTAL` 0 and `FACT_PAYMENT` 0. The reviewer said it did not run anything. The checks exist in `sql/06` section 5 but only run when someone runs them | **Accept** — nothing enforces the Type 2 rules, so a bad load could double-count silently; the safeguard is only a check that runs on request |
| 2 | The two facts resolve `customer_key` at different dates, and joining them multiplies rows | `07:89` (rental: version at `rental_ts`), `07:112` (payment: version at `payment_ts`); `07:110` (`rental_id`, "do not join on it") | Mechanism confirmed, by measurement: joining the two facts on `film_key` without aggregating first gives `SUM(amount)` **1,303,261.27 against the true 67,406.56 (19.3×)** and `SUM(rental_count)` **311,350 against 16,044**. Today the customer keys never differ for the same rental (0 of 16,044) because every customer has one version; the staff keys differ in 8,078. `FACT_PAYMENT` has no `rental_date_key` or `inventory_id` (0 of its 9 columns) | **Accept** — the chasm-trap mechanism is real and measured (19.3x inflation), and FACT_PAYMENT has no rental_date_key, so analysts are pushed towards the join the DDL forbids |
| 3 | `CREATE TABLE IF NOT EXISTS` makes every later DDL edit a silent no-op on existing tables, so the file and the live tables can drift | `07:5-7` (header) and every `CREATE` in the file | **No drift today**: compared against `INFORMATION_SCHEMA`, all 7 tables match the file in column names and order, NOT NULL, column comments and table comments (0 differences; see `3_drift.txt`). The comparison needed the live comments to be refreshed with `ALTER TABLE ... COMMENT` after earlier edits, which is the drift mechanism the reviewer describes | **Accept** — IF NOT EXISTS lets the file and the live tables drift with no error; today's 0 differences needed manual ALTERs, which is exactly the mechanism the reviewer describes |

## What else the reviewer said, tested

| # | Claim | What Claude said | What Snowflake says | Correct (Y/N) |
|---|---|---|---|---|
| a | The grain wording at `07:103` ("one copy rented by one customer on one date") could collapse two real rentals | "A customer can legitimately rent the same copy twice in one day" | In this data it never happens: 0 customer/copy/day groups with more than one rental. The wording is a risk, not a present error | **Y** |
| b | `payment.rental_id` is nullable in the source but `NOT NULL` in the fact | "My recollection is that reference Sakila has a few; I am not sure" | 0 of 16,044 payments have a NULL `rental_id` (`04:174` is nullable, `07:110` is NOT NULL) | **N** |
| c | `NUMBER(5,2)` for `amount` silently permits refunds | "Allows negatives" | True of the type; in the data `MIN(amount)` is 0.00, 0 negative, 24 zero | **Y** |
| d | The comment that 8,078 payments differ from their rental in customer or staff | "Not checkable from these files; I did not verify it" | 8,078 of 16,044 differ, **all in staff**: 0 differ in customer, 0 in both | **Y** |
| e | `return_ts IS NULL` should agree with `return_date_key = -1` row by row | "Nothing ties them together" | 0 disagreeing rows of 16,044 | **Y** |
| f | `DIM_FILM.category` is one column but `film_category` is many-to-many in the source | "A film with two categories becomes two source rows" | 1,000 of 1,000 films have exactly one category (0 exceptions) | **Y** |
| g | The expected OLTP rental count | "(326… see the project count for Sakila)" | 16,044. 326 is the ClassicModels order count from `CLAUDE.md`: a slip by the reviewer | **N** |
| h | `etl_as_of` uses session-local time, not UTC | "CURRENT_TIMESTAMP in the session time zone; zone-less source timestamps" | `CURRENT_TIMESTAMP()` cast to `TIMESTAMP_NTZ` is 7 hours behind `SYSDATE()` in this session | **Y** |

Not tested (no safe way without changing data): two changes within one second giving a zero-width interval, replaying an earlier `etl_as_of`, and whether Snowflake accepts `NOT NULL` before `AUTOINCREMENT` (it must, since `sql/04` ran).

---

# 4. Document

**Command, run exactly as written** from the project folder, no flags added:
```
claude -p "Write docs/data_dictionary.md for every DW table from INFORMATION_SCHEMA; cite the query for each fact."
```

**What happened.** Exit code 0, but **no `docs/data_dictionary.md` exists**. In headless mode the file write was not permitted and cannot be approved interactively, so the run printed what it would have written and asked for permission. Its own words ("I couldn't write `docs/data_dictionary.md` or append to `docs/prompt_log.md`. Both writes were blocked because permission wasn't granted … I haven't tried another way around the block") are in `4_headless_stdout.txt`. The tool log shows it attempted a `WRITE` and ran its queries against `CLASSICMODELS.INFORMATION_SCHEMA`.

**It documented the wrong database.** This account has two schemas called `DW`: `CLASSICMODELS.DW` (5 tables, a practice star, the one `CLAUDE.md` describes) and `SAKILA.DW` (7 tables, the assignment's). "Every DW table" did not say which, and the run took the one in `CLAUDE.md`. Nothing in its output mentions Sakila.

**Its printed summary, in full:**

> I couldn't write `docs/data_dictionary.md` or append to `docs/prompt_log.md`. Both writes were blocked because permission wasn't granted, so neither file has been changed. I haven't tried another way around the block.
>
> The queries did run. This is what the dictionary would contain:
>
> - **Tables:** `DIM_CUSTOMER` (122 rows), `DIM_DATE` (1,096), `DIM_EMPLOYEE` (23), `DIM_PRODUCT` (110) and `FACT_ORDER_LINE` (2,996). That is 35 columns in all.
> - **Reconciliation:** For every table, the `INFORMATION_SCHEMA.TABLES` row count equals `COUNT(*)` and equals the distinct count at the grain. `SUM(sales_amount)` is 9,604,190.61, which matches CLAUDE.md. No row has a NULL `employee_key`, and every row has `sales_amount = quantity*price_each`.
> - **Keys:** The only constraint is a primary key on the fact, and `ENFORCED = NO`. `INFORMATION_SCHEMA` doesn't list its columns, so the doc takes `(order_number, product_key)` from `sql/02_star_schema.sql` line 43.
> - **Nullability:** Every column reports `IS_NULLABLE = YES`, including the key columns.
> - **Column comments:** There are none. Column meanings and source columns come from `sql/02_star_schema.sql`, and the doc tags each one with its line number. Table-level facts are tagged with the query that returned them.
> - **Not re-derived:** I didn't re-check the DDL-sourced facts against the OLTP tables. The doc points to `/dw-reconcile` for that.
>
> Do you want to grant write access to `docs/data_dictionary.md` and `docs/prompt_log.md`, so I can write them? I can also paste the full markdown here for you to save yourself.

**Three of its claims, checked against `INFORMATION_SCHEMA`** (there is no file, so these are claims from its printed summary; queries and outputs in `4_claim_checks.txt`):

| # | Claim | What Claude said | What Snowflake says | Correct (Y/N) |
|---|---|---|---|---|
| 1 | Tables, rows and columns | "DIM_CUSTOMER (122 rows), DIM_DATE (1,096), DIM_EMPLOYEE (23), DIM_PRODUCT (110) and FACT_ORDER_LINE (2,996). That is 35 columns in all." | `INFORMATION_SCHEMA.TABLES`: 122, 1,096, 23, 110, 2,996 rows; `COLUMNS`: 6 + 7 + 6 + 7 + 9 = 35 columns in 5 tables | **Y** — correct for the schema it chose; wrong schema |
| 2 | Nullability | "Every column reports IS_NULLABLE = YES, including the key columns" | 35 of 35 columns are `YES`, 0 are `NO` | **Y** |
| 3 | Constraints | "The only constraint is a primary key on the fact, and ENFORCED = NO" | `TABLE_CONSTRAINTS` for the schema: one row, `FACT_ORDER_LINE`, `PRIMARY KEY`, `ENFORCED` = `NO` | **Y** |

All three hold, for `CLASSICMODELS.DW`. They say nothing about `SAKILA.DW`.

**You asked for the re-run** (answered in the AI verification questions): see 4b below.

## 4b. The re-run you asked for: schema named, one write allowed

**Commands** (both in `evidence/ai_checks/4b_command.txt`). They differ from the command in the task in two ways you approved: the schema is named (`SAKILA.DW`, "ignore `CLASSICMODELS.DW`"), and write permission is granted for that one file. Attempt 1 used `--allowedTools "Write(docs/data_dictionary.md)"` and was denied again: that was **my mistake**, since this version only accepts `Edit(path)` rules for files (its stderr says so, in `4b_headless_attempt1_stderr.txt`). Attempt 2 used `--allowedTools "Edit(docs/data_dictionary.md)"` and worked.

**Result.** `docs/data_dictionary.md` now exists (239 lines): the 7 tables of `SAKILA.DW`, 84 columns, 22 constraints, each fact tagged with one of six queries (Q1–Q6) whose SQL is listed once at the end; the run's own printed summary is in `4b_headless_stdout.txt`. This time it documented the right schema. `docs/prompt_log.md` was not touched (its checksum is unchanged); the run asked for permission to log the exchange, which I did not grant, and I wrote the log entry myself. It says what it could not know: `INFORMATION_SCHEMA` gives constraint names but not their columns or targets, so those come from `sql/04` and are marked *(DDL)*; and the types shown are Snowflake's storage types.

**Three of its claims, tested against `INFORMATION_SCHEMA`** (queries and outputs in `4b_claim_checks.txt`):

| # | Claim | What Claude said | What Snowflake says | Correct (Y/N) |
|---|---|---|---|---|
| 1 | Columns and NOT NULL columns per table | "Columns 19 / 10 / 17 / 8 / 9 / 9 / 12 and NOT NULL 6 / 1 / 6 / 3 / 3 / 9 / 10; 84 in total" (Summary table, Q4) | Exactly those, per table, in table-name order: DIM_CUSTOMER 19/6, DIM_DATE 10/1, DIM_FILM 17/6, DIM_STAFF 8/3, DIM_STORE 9/3, FACT_PAYMENT 9/9, FACT_RENTAL 12/10; total 84 | **Y** |
| 2 | Constraints | "22 constraints: 7 primary key, 4 unique, 11 foreign key (FACT_RENTAL 6, FACT_PAYMENT 5), all ENFORCED = NO" (Constraints by table, Q3) | 7 / 4 / 11 = 22, all 22 `ENFORCED = NO`; FACT_RENTAL 6 foreign keys, FACT_PAYMENT 5, the dimensions 0 | **Y** |
| 3 | Identity columns and defaults | "The identity columns are CUSTOMER_KEY, FILM_KEY, STAFF_KEY, STORE_KEY; COLUMN_DEFAULT is NULL for every column" (Q2) | `IS_IDENTITY = YES` for exactly those four of 84 columns; 0 columns have a `COLUMN_DEFAULT` | **Y** |

---

# 5. Prompt log and tool log

**`docs/prompt_log.md`.** It holds every prompt in order, 27 entries from "are you connected to snowflake right now?" to the headless command: yours, the checker's to each explainer, to the reviewer, and the headless prompt, each with a one-line summary of the answer. The top states that the checks were run by Claude Code as the checker with subagents as explainers. Entries 11, 15 and 16 were not logged when sent and were reconstructed afterwards from the conversation; they are marked *added later*. Entry 17 is the AI verification task itself (the log calls it the Dashboard task); entries 24 to 27 (the resume, the Snowflake check and the AI verification questions, the dictionary re-run, my answers) were added afterwards. The log ends with "where Claude was wrong or overconfident": first listed unjudged, now holding my picks. The empty template table that headed the log has been removed.

**The Claude Code tool log (kept private).** It exists and is being written by the hook configured in `.claude/settings.json` (a `PreToolUse` hook that appends the time, the tool and the command). At the check it was 131,427 bytes and 1,188 lines, last written a minute earlier; it grew by 24 lines while the headless run and the claim checks ran, and it contains the headless run's own commands (`5_toollog.txt`).

**Identifier scan.** After the files were written, every file I created or edited was scanned for: the Snowflake account locator and the `orgname-accountname` identifier (fetched from Snowflake into memory, never printed), the connection's login name, the Snowflake host-name pattern, private-key headers and key-file references, bearer/JWT-looking strings, common API-key prefixes, `password`/`secret`/`token` assigned a value, my e-mail address, and the OS user name (in a path or on its own). Only file names and counts were printed.

| What I looked for | In my 91 files | In the tool log (after the redaction) |
|---|---:|---:|
| Snowflake account locator | 0 | 0 |
| orgname-accountname identifier | 0 | 0 |
| login name of the connection user | 0 | 0 |
| Snowflake host-name pattern | 0 | 2 |
| private-key header | 0 | 0 |
| a reference to a private-key file or variable | 0 | 6 |
| bearer / JWT-looking string | 0 | 0 |
| API-key prefixes | 0 | 2 |
| password / secret / token with a value | 0 | 0 |
| my e-mail address | 0 | 0 |
| OS user name (in a path or on its own) | 0 | 0 |

How to read it:
- **My files: 91 scanned, 0 hits in every category.** Two items were masked along the way: an absolute path in the reviewer's pasted report, and a path in a sample line of the tool-log evidence (`5_toollog.txt`).
- **Tool log, redacted at my request:** the login name (4 lines) and the OS user name (168 occurrences on 137 lines, including the scratchpad paths that contain it) were replaced with `<agent-user>` and `<user>`. The log keeps all its lines. A backup of the original is in the scratchpad, outside the project and ephemeral. The hits that remain in the log (host-name pattern, key-file reference, API-key prefix) are the text of my earlier scanner scripts, which the hook logged along with the commands; none is a credential. The hook logs every command as typed, so the OS user name will come back into the log wherever a later command contains an absolute path; I ran the final checks with relative paths so it did not.
- **Not covered by a text scan:** the two screenshots (images). I looked at `docs/images/dashboard_filtered.png` in full and `docs/images/dashboard_unfiltered.png` in an earlier, cropped version: they show the app's own text, not an identifier. `env.sh` is mine: an early preliminary scan counted matches in it without displaying anything, I should not have included it, and it is no longer scanned. The starter kit's own files (its README, CLAUDE.md, ClassicModels scripts and agent setup script, none of them in this repo) are not mine and were not scanned.

---

# Decisions — made by me, recorded by Claude Code

Made in the terminal on 2026-10-26. Tick-box answers were recorded as given. Claude Code made no decision.

**Every correct (Y/N) cell and every accept/reject: all 44 are decided** (0 open).

| Section | Cells | Y | N |
|---|---:|---:|---:|
| 1a: the plan | 8 | 7 | 1 |
| 1b: the change | 9 | 4 | 5 |
| 2: revenue by store | 10 | 9 | 1 |
| 3: reviewer asides a–h | 8 | 6 | 2 |
| 4: headless run (the first run, ClassicModels) | 3 | 3 | 0 |
| 4b: the dictionary re-run (Sakila) | 3 | 3 | 0 |
| **Y/N cells in all** | **41** | **32** | **9** |

**Accept / reject** (reasons are in the Task 3 table): finding 1 **Accept**, finding 2 **Accept**, finding 3 **Accept**.

**My notes, in the cells:** 1b claim 5 (Y, with the caveat that the conclusion held but the noise estimate was too high) and Task 4 claim 1 (Y, "correct for the schema it chose; wrong schema").

**Judgement calls that were mine: all three approved as they stand.** The KPI query as the "slowest" (397 ms execution time); revenue by store as the Task 2 question; 1b reported as "the change did nothing".

**Edits made at my request:**
- **The "customer or staff" wording fixed** in `sql/04_dw_ddl.sql` (the comment above `FACT_PAYMENT`), `docs/dimensional_model.md` (line 35) and the notebook's embedded copies of both. It now says the 8,078 payments differ in the staff member only; the customer is always the same. The tables in Snowflake are unaffected (it is a SQL comment). The old wording survives, as evidence, in this file, `docs/prompt_log.md` and `evidence/ai_checks/`.
- **A note added to 1a** saying which queries came from the Streamlit-in-Snowflake session.
- **The dictionary re-run** (section 4b): `docs/data_dictionary.md` exists.
- **The tool log redacted** (section 5).

**My candidates for "where Claude was wrong or overconfident"** (also at the end of `docs/prompt_log.md`):
1. **"Snowflake is read-only"** (entries 2 and 5): said without checking secondary roles; caught when I pushed back and `CURRENT_AVAILABLE_ROLES()` showed ACCOUNTADMIN active.
2. **"Customer or staff" and "its own customer key"** (entry 12): the dimensional model write-up built an argument on a payment having its own customer key; 0 payments differ in customer, all 8,078 differ in staff (caught in Task 3, aside d).
3. **Recommending to drop the redundant date filter** (entries 21 and 22): said it "forces a scan of `PAYMENT_DATE_KEY`"; the plans were identical, with no Filter operator and the same bytes (caught by the before/after measurement and the operator statistics).
4. **The headless run documenting the wrong DW and writing nothing** (entry 23): caught by reading its output and the tool log.
5. **Explainer #2's claim about the store** (added by me; Task 2, claim 4): it said the star's store is "the store that took the payment". Snowflake: the staff (payment-taking) store gives 33,482.50 / 33,924.06, not B's 33,679.79 / 33,726.77; B is the store holding the rented copy. It had just said it couldn't tell, then asserted an answer anyway; caught by the deciding query.

Not picked: the typo in the foreign-key check of `sql/02` (entry 8).

Nothing from the AI verification questions is still open.
