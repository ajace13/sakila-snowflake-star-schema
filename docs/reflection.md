# Reflection: why this grain, what broke, what would break first

Every claim below is tied to a number produced in the walkthrough notebook (`notebooks/walkthrough.ipynb`) or measured while writing this. Where a number is an extrapolation it says so. In the notebook the Snowflake figures are queried live; the memory figure for the exporter is measured on this machine with the same dump file that was imported into Cloud SQL. How each mistake was caught, and which ones were Claude's own, is recorded in AI verification (`docs/ai_verification.md`).

## Why this grain? What does it make easy, and what impossible?

**The choice.** Two fact tables, each at the grain of the lowest-level event Sakila records, and each grain is written into the table's `COMMENT` in the DDL:
- `FACT_RENTAL`: one row per rental (`rental_id`): one copy rented by one customer on one date, handled by one staff member.
- `FACT_PAYMENT`: one row per payment (`payment_id`): one amount paid by one customer to one staff member on one date.

**Why two facts and not one.** Rentals and payments match one to one by count (16,044 each), which tempts a single fact: a rental row with an amount column. The data argues against it:
- In **8,078** payments the staff member who took the payment is not the one who handled the rental, and in **7,317** payments the amount is not the film's rental rate. The amount is an event of its own, not an attribute of the rental or the film.
- A rental is unfinished when it starts: the return arrives later (183 rentals are still out). `FACT_RENTAL` is therefore a row the MERGE updates in place, while a payment never changes once written.
- At event grain every measure is additive (`amount`, `rental_count`, `days_out`), and the totals reconcile to the normalized copy to the cent (67,406.56).
- Customer and film are looked up *as they were at the event* (Type 2), so a later change never rewrites old facts.

**What it makes easy.** Any sum, count or average over events, cut by any dimension: revenue by month, category, store, staff member or customer country; top categories; rentals and days out per film; customers by store. The business questions and the dashboard app are exactly this, and every number they show reconciles with the normalized copy. It also makes history cheap: after a customer moved from Japan to Spain, the star still reported her earlier payments under Japan (3,470.75 for Japan against 3,352.07 in the normalized copy, which can only see where she lives now), and any single rental or payment can be traced to its row.

**What it makes impossible, or wrong.**

| The question | Why this grain cannot answer it | What I measured | What would fix it |
|---|---|---|---|
| Revenue by actor | Films and actors are many-to-many and the link table is not in the star | A plain join counts each payment once per actor: 367,559.07, which is 5.45 times the real 67,406.56 | A bridge table with a weighting factor, plus an "unknown actor" member (3 films have no actor: 199.60) |
| How many copies were on the shelf at a store on a given day | The fact records only the moments a copy leaves; a copy sitting on a shelf produces no row | 42 of 1,000 films and 1 of 4,581 copies were never rented, so they have no fact row at all | A snapshot fact: one row per copy per day |
| Revenue per rental day, or revenue by rental month, in one query | It needs both facts, which are different processes; `FACT_PAYMENT` has no rental date | Joining the two facts on `film_key` inflates revenue 19.3 times (see "What broke?") | Aggregate each fact on its own and combine on a shared attribute; add `rental_date_key` to the payment fact |
| Anything below a payment: instalments, late fees, refunds, time of day | Each rental has exactly one payment, no amount is negative, and the date dimension stops at the day | Smallest amount is 0.00 (24 payments are zero) | A payment-line fact or a time-of-day dimension |
| "Revenue by store" as a single number | Three defensible meanings; the grain does not choose | Store 1: 36,997.53 (customer's home store), 33,482.50 (staff member's store), 33,679.79 (store holding the copy) | Decide and document; the star uses the copy's store. Staff and store are Type 1, so the staff member's store *as it was* is lost |
| How many customers | The dimension's grain is the version, not the person | After one move `COUNT(*)` gave 600 customers; the truth is 599 | `COUNT(DISTINCT customer_id)` or the `is_current` flag |

In the notebook, the cell after this section produces the data facts quoted above.

## What broke?

Three kinds of failure are worth checking for in a load like this. Here is what happened to each, then the smaller things that also went wrong.

**A type conversion: it broke, twice.**
- *What:* the first run of the DDL failed with "Default value data type does not match data type for column LAST_UPDATE".
- *Why:* MySQL's `TIMESTAMP` and `DATETIME` became `TIMESTAMP_NTZ(0)`, but `CURRENT_TIMESTAMP()` returns a `TIMESTAMP_LTZ` and `SYSDATE()` a `TIMESTAMP_NTZ(9)`, and Snowflake accepted neither as the default.
- *How I knew:* Snowflake refused the very first `CREATE TABLE`. I tested both candidates on throw-away tables; `CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(0)` worked and is now used for all 15 defaults.
- *The second one was caught before loading:* 6 of the 603 address points have impossible coordinates (address 63 has a longitude of 766,456,911). MySQL accepts them because the column is a planar `GEOMETRY`; Snowflake's `GEOGRAPHY` would have rejected them. A range assertion in my export script stopped the run, and the column became `GEOMETRY`.

**A MERGE that duplicated rows: it did not, and here is how I know.**
- *The risk was real:* Snowflake does not enforce primary or unique keys, the Type 2 MERGE stages every changed row twice (once to close the old version, once, with a NULL key, to insert the new one), and the fact MERGEs pick a version with a range join, so a bug or an overlapping interval would insert a second row silently.
- *The evidence:* re-running the unchanged `sql/05` inserted and updated **0** rows every time (runs 2, 4 and 5 in the logs, and again when I re-verified); the only run that inserted anything was the one that extended the calendar, by exactly the 8,766 days I meant to add. The live cell below shows 0 duplicate keys in both facts, exactly one current version per customer and film, and no overlapping intervals. The rolled-back demos showed exactly one new version per change, and an UPDATE, not an INSERT, when a rental came back.

**A join that multiplied totals: it broke in analysis, on purpose, to measure it.**
- *What:* joining the two facts on `film_key` without aggregating first gives revenue of 1,303,261.27 against the true 67,406.56 (19.3 times) and 311,350 rentals against 16,044. The same mechanism gave the 5.45 times on actors, and `COUNT(*)` on a Type 2 dimension gave 600 customers for 599.
- *Why:* every rental of a film pairs with every payment for that film, and a Type 2 dimension has one row per version.
- *How I knew:* each total is reconciled against `SUM(amount)` and the row counts of the normalized copy (67,406.56 and 16,044), which is what exposed it. The model carries the lesson: the DDL says not to join the facts on `rental_id`, and `sql/06` asserts the totals.

**Other things that broke (mine), and how each was caught**

| What | How it was caught |
|---|---|
| A typo in the foreign-key check (`store.manager_staff_id` compared with a column `store` does not have) | Snowflake's "invalid identifier" error on the first run |
| A wrong claim that payments differ from their rental in "customer or staff" (it is staff only) | The review check in AI verification: 0 payments differ in customer, 8,078 in staff |
| An expectation that dropping a redundant date filter would scan fewer bytes | The before and after plans were identical and read the same bytes: Snowflake had already removed the filter (the date key's minimum and maximum equal the filter's bounds) |
| A timing gap of about 100 ms that looked like an improvement | Swapping the order of the runs made it vanish (91 against 90 ms), and the same query run six times varied by 21 ms |
| The headless dictionary run documented the wrong schema (`CLASSICMODELS.DW`) | Reading its output, and the tool log, which showed its first query |
| The first Streamlit server listened on all network interfaces | The start-up message printed an external address; I restarted it bound to localhost only |

In the notebook, the cell after this section re-measures the join trap and the integrity checks live.

## What would break first at scale?

**Assumption.** Every table a thousand times larger: about 16 million rentals and payments, 600,000 customers and a million films. I did not build a larger copy, so every "at 1,000 times" figure below is a straight-line extrapolation from today's size, and says so. For the Snowflake parts I extrapolate data *volume* (bytes read), because timings at this size are mostly fixed overhead.

**Answer: the load fails soonest, and within it my Python exporter, which stops being usable at roughly a hundred times today's size. The MERGE loads and the app slow down but keep working. The star is the last thing to worry about.**

| Part | Measured today | At 1,000 times (extrapolated) | What breaks |
|---|---|---|---|
| **Load, step 1: the Python exporter** | About 1.1 s and 41 MB of memory for a 3.35 MB dump (13 times the file) | A 3.35 GB dump and about 40 GB of memory | It reads the whole dump into one string and keeps every row in lists. On a 4 GB machine it runs out at about 100 times |
| **Load, step 2: the MERGEs** | A re-run that changes nothing takes 0.7–0.9 s per MERGE and reads 117–377 KB, *more* than the first load that inserted everything (52–288 KB) | Each MERGE reads 0.1–0.4 GB | They are full refreshes: each run reads and compares all of the source and all of the target, so cost grows with total history, not with the rows that changed |
| **App** | One page render sent 8 queries: the 4 hidden Check queries took 4,867 ms (69% of the render) and read 735 KB, against 2,201 ms and 464 KB for the 4 star queries | About 0.7 GB read for the Check queries and 0.5 GB for the page, per render | The Check queries run on every render, even with the expander closed, and each new filter value is a new query. Latency and warehouse load, not a crash |
| **Star** | Whole star 0.62 MB; `FACT_RENTAL` 15 bytes per row compressed | 0.62 GB in total, `FACT_RENTAL` about 236 MB | Nothing soon. Date filters keep pruning only if rows keep arriving in date order. Unenforced keys get harder to audit |

**Why the exporter first, and why not the others.** The exporter is the only part whose cost grows with *everything* and whose limit is a hard wall (memory), not a slower query. The Snowflake parts handle sub-gigabyte scans comfortably on an X-Small warehouse; I would expect seconds rather than hours for the MERGEs and the page, but I have not tested it. What I can show is *why* they would degrade first, if anything: the MERGEs redo all the work every run, and the app does 69% of its render in queries nobody asked to see.

**What I would change first.**
- *Exporter:* stream it, parsing and writing one INSERT statement at a time instead of holding the file; better still, export from Cloud SQL straight to CSV in a bucket and `COPY INTO` from there.
- *MERGEs:* make them incremental: a Snowflake stream on each source table, or a high-water mark, so each run touches only new and changed rows. Run the batch on a larger warehouse and let `AUTO_SUSPEND = 60` suspend it afterwards.
- *App:* run the Check only on request (a button), and serve the page from small monthly and category aggregates instead of the fact table.
- *Star:* cluster the facts by `payment_date_key` and `rental_ts` once they are big enough to have many micro-partitions.

**What I did not test.** No larger copy was built. A realistic next step is a 100-times synthetic copy in a throw-away schema, to measure where the MERGE and the Check queries actually bend; I held back because that would create objects.

In the notebook, the cell after this section produces the measurements quoted in the table.
