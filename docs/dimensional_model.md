# Sakila OLTP → OLAP: the star schema in `SAKILA.DW`

Built with DDL and DML inside Snowflake from the normalized copy `SAKILA.OLTP`, which is left exactly as it was (it is only read; the scripts that change it, `sql/07` and section 3.2 of `sql/08`, roll back).

| Requirement | Where it is met |
|---|---|
| 1a. A fact table at a grain you can defend, written into the DDL as a COMMENT | `FACT_RENTAL` and `FACT_PAYMENT`; the `GRAIN:` comment on each table in `sql/04_dw_ddl.sql` |
| 1b. At least two Type 2 SCDs, with a reason | `DIM_CUSTOMER` (address history) and `DIM_FILM` (rental rate) |
| 1c. Loads written as MERGE, so a re-run does not duplicate | all seven loads in `sql/05_dw_load_merge.sql`; re-run proof below |
| 1d. The normalized copy stays in place | `SAKILA.OLTP` untouched; `sql/06` checks the star against it |

## The model
```
                      DIM_DATE (Type 0)  ◄── role-played twice by FACT_RENTAL (rental date, return date)
                           ▲
  DIM_CUSTOMER (Type 2) ◄──┼──► DIM_FILM (Type 2)
                           │
   FACT_RENTAL ────────────┤        FACT_PAYMENT
   (grain: one rental)     │        (grain: one payment)
                           ▼
        DIM_STORE (Type 1)   DIM_STAFF (Type 1)           ← both facts share all five dimensions
```
| Table | Rows | Type | Grain |
|---|---:|---|---|
| `DIM_DATE` | 9,497 | 0 | one calendar day, 2005-01-01 .. 2030-12-31, plus member -1 "no date yet" |
| `DIM_STORE` | 2 | 1 | one store |
| `DIM_STAFF` | 2 | 1 | one staff member (password and picture are not copied) |
| `DIM_CUSTOMER` | 599 | **2** | one **version** of a customer |
| `DIM_FILM` | 1,000 | **2** | one **version** of a film |
| `FACT_RENTAL` | 16,044 | | one rental: one copy rented by one customer on one date, handled by one staff member |
| `FACT_PAYMENT` | 16,044 | | one payment: one amount paid by one customer to one staff member on one date, against one rental |

## Why these grains, and why two facts
I profiled the source before choosing (`SAKILA.OLTP`):
- Rentals and payments match one to one by count (16,044 each; every rental has exactly one payment), but in **8,078 payments** the staff member who took the payment is not the one who handled the rental (the customer is always the same: 0 payments differ in customer). A payment is its own event, so it is its own fact, with its own date, its own amount and its own staff key, rather than a column on the rental.
- In **7,317 payments** the amount differs from the film's rental rate, so `amount` has to live on the payment and cannot be derived from the film.
- A rental is not finished when it starts: the copy comes back later. `FACT_RENTAL` is inserted at rental time and the same MERGE fills in `return_date_key`, `return_ts` and `days_out` afterwards. The grain does not change, only those columns do (shown in the demo).
- Additivity: `amount`, `rental_count` (always 1) and `days_out` are additive across every dimension. `days_out` is NULL for rentals not yet returned, so an average is `SUM(days_out)/COUNT(days_out)`, never divided by `SUM(rental_count)`.
- The two facts are not joined on `rental_id` (it is 1:1 here, checked, but nothing enforces it). Each fact is aggregated on its own and combined on the shared dimensions.

## The two Type 2 dimensions, and why those two
- **`DIM_CUSTOMER`**: customers move, change store and are deactivated. A rental or payment must be reported against the customer *as they were that day* (revenue by country, by store). Every attribute is tracked (address, city, country, store, active, name, e-mail, phone), so any change makes a new version.
- **`DIM_FILM`**: films are re-priced (`rental_rate`, `replacement_cost`) and change `rental_duration` or `rating`. A rental must be analysed at the terms in force that day ("revenue against list price at the time"). The source keeps only today's price, which is exactly why the history must be built here.
- **Staff and store are Type 1 on purpose**: two rows each. A reassignment or a new manager overwrites; the facts still keep *which* staff member handled each rental or took each payment. What is lost, and said so in the DDL: which store a staff member worked at before, and who managed a store before.

Mechanics: each version has `valid_from` (inclusive), `valid_to` (exclusive, 9999-12-31 while current) and `is_current`. The first version of every row starts at **1900-01-01**, because its true start is unknown, so it covers all history. A fact picks the version with `valid_from <= event time < valid_to`. Customer is resolved at the event time of the fact (rental time for a rental, payment time for a payment); film is resolved at the **rental** time in both facts, so a rental and its payment always share one film version.

## The MERGE pattern (`sql/05_dw_load_merge.sql`)
- **Type 0 / Type 1** (`DIM_DATE`, `DIM_STORE`, `DIM_STAFF`): `MERGE ... WHEN MATCHED AND hash differs THEN UPDATE ... WHEN NOT MATCHED THEN INSERT`. A change is detected by `MD5(TO_JSON(ARRAY_CONSTRUCT(...)))` of the attributes, which tells NULL from an empty string (checked in `sql/06`).
- **Type 2** (`DIM_CUSTOMER`, `DIM_FILM`), one MERGE each: every source row is staged once keyed to its natural key (to close the current version if its hash changed) and a second time with a NULL key when it changed (a NULL key can never match, so it is inserted as the new version).
- **Facts**: MERGE on the source number (`rental_id`, `payment_id`). Dimension keys come from LEFT JOINs, so a failed lookup gives a NULL and the MERGE stops with an error instead of silently dropping the row. An existing row keeps its keys; only the return columns (rental) or a corrected amount (payment) can change.

## Evidence
| What | Result | Where |
|---|---|---|
| Re-run does not duplicate | Same file run again: **0 rows inserted, 0 updated in all seven MERGEs** (also after the calendar was extended and after the review fixes) | `evidence/dw_load_log_run1.txt` (first load: 731, 2, 2, 599, 1,000, 16,044, 16,044) · `run2` and `run4` (all zeros) · `run3` (calendar extended: 8,766 days inserted, the rest 0) |
| Star agrees with the normalized copy | **57 checks, all OK**: row counts, `SUM(amount)` = 67,406.56 = OLTP, `SUM(days_out)` = 79,705, revenue and rental counts by 7 groupings (category, store, country, staff, month, customer) with 0 mismatching groups | `sql/06_dw_checks.sql`, `evidence/dw_checks_log.txt` |
| Relationships | 11 foreign keys from facts to dimensions, 0 orphans; grain: 0 duplicate keys; joining the two facts on `rental_id` keeps 16,044 rows | same |
| Type 2 integrity (not enforced by Snowflake, so asserted) | one current version per key, no overlapping intervals, no gaps, first version from 1900-01-01, `is_current` agrees with `valid_to`, every fact points at a version valid at its event time: all 0 violations | same |
| Type 2 really works | See the demo | `sql/07_scd2_demo.sql`, `evidence/scd2_demo_log.txt` |

**The demo** changes the source inside one transaction, reloads with the same `sql/05`, queries, and rolls back (`DIM_CUSTOMER` 599, `DIM_FILM` 1,000, facts 16,044, OLTP film 1 rate 0.99 and the original e-mail all restored afterwards):
- Customer 1 moves from Sasebo, **Japan** to A Coruña, **Spain**: two versions, the old one closed at the reload time and the new one open from it.
- Film 1 is re-priced 0.99 → 5.99: two versions.
- Staff 1's e-mail changes: still **one** row, overwritten (Type 1, for contrast).
- Customer 1's 32 earlier payments (118.68) stay under the Japan version; the new payment (5.99) lands on the Spain version. "As it was" shows Japan 32 + Spain 1; "as it is now" would show Spain 33 (124.67). That difference is the point of Type 2.
- Film 1: 23 earlier rentals at list price 0.99, the new rental at 5.99.
- When the copy is returned 3 days later, the existing `FACT_RENTAL` row is **updated** (`days_out` = 3), not duplicated: 16,045 rows, not 16,046.

## Review by the `grain-reviewer` subagent, and what was done
It read only the DDL. Applied: (1) `film_key` was resolved at the payment time in one fact and the rental time in the other, which would diverge once a film has two versions; both now use the rental time; (2) the `days_out` column comment wrongly called an additive duration non-additive; (3) the `DIM_STAFF` comment wrongly said no history is lost; (4) Type 2 integrity and the rental-to-payment 1:1 are now asserted in `sql/06` instead of assumed. It also asked to check things the load already did right, and `sql/06` now proves them: the hash handles NULLs, `original_language` uses a LEFT JOIN, every film has exactly one category.

## Limits, stated plainly
- A new version starts at the **load time**, not at the real-world change date (the source records no effective date). A rental that falls between a real move and the next load is attached to the old version. Loading often, or replaying with a chosen `etl_as_of`, narrows this.
- A row deleted from the source is not closed in the dimension (no deletes in Sakila); closing a customer who disappears from the source would need a soft-delete flag.
- The history in a Type 2 dimension cannot be rebuilt from `OLTP`, so `sql/04` uses `CREATE ... IF NOT EXISTS` and never `CREATE OR REPLACE`; to start over, drop `SAKILA.DW` deliberately.
- Snowflake does not enforce primary, unique or foreign keys; every one of them is checked in `sql/06`.
- `AUTOINCREMENT` surrogate keys are unique, but not gap-free and not in time order (the demo's new versions got 3401 and 6201 after 599 and 1,000). Order versions by `valid_from`, never by key.
- The source has no history of its own: right now every dimension row has exactly one version, and the demo is what shows that multiple versions work.

## Run order
`sql/04_dw_ddl.sql` → `sql/05_dw_load_merge.sql` → `sql/06_dw_checks.sql` → `sql/07_scd2_demo.sql` (optional; rolls back). All as SYSADMIN.
