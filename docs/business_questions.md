# Show it works, and find where it doesn't

All queries are in `sql/08_business_questions.sql`; the saved run is `evidence/business_questions_log.txt`. "Normalized" = `SAKILA.OLTP`, "star" = `SAKILA.DW`.

## 3.1 Three business questions, answered on both models

| # | Question | Result | Detail |
|---|---|---|---|
| Q1 | Revenue by month | **Agree** in all 5 months | 2005-05 4,823.44 · 2005-06 9,629.89 · 2005-07 28,368.91 · 2005-08 24,070.14 · 2006-02 514.18 (sum 67,406.56). Only these five months have payments in this data. |
| Q2 | Which film categories earn the most? | **Agree** on revenue, rentals and rank | Sports 5,314.21 (1,179 rentals) · Sci-Fi 4,756.98 (1,101) · Animation 4,656.30 (1,166) · Drama 4,587.39 (1,060) · Comedy 4,383.58 (941). All 16 categories agree (`sql/06`). |
| Q3 | How many customers, and how much revenue, does each store have? | Customers **agree**; revenue agrees *within* each definition of "store" but **the three definitions disagree with each other** | see below |

**Where they do not agree, and which is right.**

*Q3 — "store" means three things in Sakila.* Each definition gives the same answer on both models, but different answers from each other:

| Definition of store | Store 1 | Store 2 |
|---|---:|---:|
| 1. the customer's home store | 36,997.53 | 30,409.03 |
| 2. the store of the staff member who took the payment | 33,482.50 | 33,924.06 |
| 3. the store holding the rented copy (what `FACT_PAYMENT.store_key` means) | 33,679.79 | 33,726.77 |

Store 1's revenue moves by 3,515.03 (about 10%) depending on the definition. None of them is wrong; they answer different questions: (1) is loyalty, (2) is who is doing the selling, (3) is how the physical stock earns, which is what I would call a store's revenue. The star can answer all three because customer, staff and store are all dimensions; the danger is a report that says "revenue by store" without saying which. In the star, `store_key` is definition 3, and the dimension column name says so (`store_id` on `DIM_STORE`, `home_store_id` on `DIM_STAFF`, `store_id` on `DIM_CUSTOMER`).

*After history exists (3.2 below)* the two models disagree for real on "revenue by customer country": after customer 1 moves from Japan to Spain, the normalized copy says Japan 3,352.07 and Spain 725.26, the star says Japan 3,470.75 and Spain 606.58. The difference is exactly 118.68, customer 1's 32 earlier payments. **Both are right, for different questions.** The normalized copy answers "where do customers live now" and has no way to answer anything else, because it overwrote the old address. The star answers "where was the customer when they paid", which is what a historical revenue report means. The totals agree to the cent (67,406.56 on both). A Type 1 star would silently give the normalized answer and rewrite last year's report. The trap the history creates is counting: `COUNT(*)` on `DIM_CUSTOMER` returns **600** (versions), where the normalized copy says 599; the right counts are `COUNT(DISTINCT customer_id)` or `WHERE is_current` (599).

## 3.2 Exercise the history
Run inside one transaction that ends in `ROLLBACK` (so `SAKILA.OLTP` and the star come out unchanged: 599 customers, 1,000 films, film 1 back at 0.99, customer 1 back at 1913 Hanoi Way):
1. Customer 1's address is changed to a street in A Coruña, Spain, and film 1's rental rate from 0.99 to 5.99, in `SAKILA.OLTP`.
2. The same `sql/05_dw_load_merge.sql` is run again.
3. **`DIM_CUSTOMER` holds both versions of customer 1**: key 1, Japan, Sasebo, valid 1900-01-01 to the reload time, `is_current` false; key 7801, Spain, A Coruña, valid from the reload time, `is_current` true. **`DIM_FILM` holds both versions of film 1**: key 1 at 0.99 (closed) and key 12501 at 5.99 (current). Film 1's 23 earlier rentals stay at the 0.99 list price in the star; the normalized copy can only say 5.99. (Keys 7801 and 12501 differ from the 3401 and 6201 in `evidence/scd2_demo_log.txt`: each demo run takes fresh numbers from the identity sequence and a rollback does not give them back.)

The earlier rental/payment facts did not move: they keep the version they happened under. `sql/07_scd2_demo.sql` goes further (a new rental and payment after the change land on the new versions; a return updates the existing rental row).

## 3.3 A question the model answers badly: "Which actors generate the most revenue?"
The star cannot answer it at all: `film_actor`, the many-to-many between films and actors, was left out, and no column in `SAKILA.DW` mentions an actor (0 found). The normalized copy can, but two obvious attempts are wrong:
- **Join payments to `film_actor` and sum:** every payment is counted once per actor in the film. The actors' revenues add up to **367,559.07, 5.45 times the real 67,406.56**.
- **Split each payment equally between the film's actors (1 / number of actors):** better, but it adds up to 67,206.96, **199.60 short**, because 3 of the 1,000 films have no actor and their revenue has nowhere to go.

**What I would change:** add `DIM_ACTOR` and a bridge table `BRIDGE_FILM_ACTOR (film_id, actor_key, weighting_factor)` with `weighting_factor = 1 / (actors in the film)`, plus an "unknown actor" member for the films with none, loaded by MERGE like the other dimensions. Revenue by actor is then `SUM(amount * weighting_factor)`, and it reconciles: allocated total **67,406.56 = real total**, of which 199.60 sits under "unknown actor". `sql/08` (3.3c, run on the normalized copy) proves the design reconciles before anything is built. Top five by allocated revenue: Susan Davis 609.77, Gina Degeneres 607.22, Jada Ryder 546.99, Walter Torn 542.03, Angela Hudson 531.29.

Two honest caveats about the fix: the equal split is an assumption (the data has no billing or screen-time), so "revenue per actor" is an allocation and not a measurement; and every report on the bridge must go through the weighting factor, because without it the 5.45× overcount comes straight back. For "how many distinct films did this actor appear in", the bridge is used without weights.
