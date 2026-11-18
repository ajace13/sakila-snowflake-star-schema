# A Streamlit app on the star

Files: `app/streamlit_app.py` (the app) · `docs/images/dashboard_unfiltered.png` and `docs/images/dashboard_filtered.png` · `evidence/dashboard_verify_log.txt` (headless verification) · `app/take_screenshots.py`, `app/verify_streamlit_app.py` (how they were produced).

## What the app does
| Feature | How |
|---|---|
| Reads only from the DW schema, never the normalized copy | Every number, chart and table on the page comes from `SAKILA.DW` (`FACT_PAYMENT` with `DIM_DATE`, `DIM_FILM`, `DIM_STORE`, `DIM_CUSTOMER`). The only queries that touch `SAKILA.OLTP` are the ones inside the Check expander, and the verification log counts them: of 17 statements sent in two runs, 9 read the star only and 8 read the normalized copy, all 8 for the Check expander. |
| Three KPIs or charts that answer the business questions | Q1 *revenue by month* → line chart. Q2 *top categories* → bar chart of the top 10. Q3 *revenue by store* → table (the store holding the copy, the definition `FACT_PAYMENT.store_key` carries; the caption says so). Four KPIs on top: revenue, payments, paying customers, average payment. |
| One filter that changes every number | The payment date range in the sidebar (`st.date_input`) drives the KPIs, the line chart, the bar chart, the store table and everything in the Check expander. Unfiltered → filtered (2005-06-01 to 2005-07-15): revenue $67,406.56 → $24,103.36, payments 16,044 → 5,764, paying customers 599 → 598, average $4.20 → $4.18. |
| A "Check" expander: the SQL behind each number and the same number from the normalized copy; they must match | One block per number (KPIs, month, category, store): the star SQL, the normalized-copy SQL, both results, and MATCH or DIFF, ending in "All 7 comparisons match". Money is compared to the cent. |
| `app/streamlit_app.py` and two screenshots (unfiltered, filtered) | `app/streamlit_app.py` and the two PNGs in `screenshots/`, with the Check expander open (the filtered shot was made by typing into the real date widget). The same file also ran in Streamlit in Snowflake: `docs/images/dashboard_sis_unfiltered.png` (unfiltered) and `docs/images/dashboard_sis_filtered.png` (filtered). |
| Keep the warehouse at AUTO_SUSPEND = 60 | `CLASS_WH` is `AUTO_SUSPEND = 60` and was not changed (checked after the app was built and used). |

## Two details that matter
- **`DIM_CUSTOMER` is Type 2**, so "paying customers" is `COUNT(DISTINCT customer_id)`, never `COUNT(DISTINCT customer_key)` (that counts versions); the lesson from the business questions applied. It matches `COUNT(DISTINCT customer_id)` on the normalized copy.
- The date window is written two ways that mean the same days: `payment_date_key BETWEEN 20050601 AND 20050715` on the star, and `payment_date >= '2005-06-01' AND payment_date < '2005-07-16'` on the normalized copy (a timestamp column, so the last day runs to midnight).

## Where it runs
The same file runs in two places:
- **Locally or in Cloud Shell** (what `docs/images/dashboard_unfiltered.png` and `docs/images/dashboard_filtered.png` are from): `streamlit run app/streamlit_app.py` with the Snowflake CLI connection `claude`, through the Snowflake connector. Bind it to this machine only (`--server.address localhost`): the app has no login and queries with the agent's credentials. It used a virtual environment, `~/venv-streamlit` (Streamlit 1.66, connector 4.7.5).
- **Streamlit in Snowflake**: Snowsight → Projects → Streamlit → + Streamlit App, warehouse `CLASS_WH`, database `SAKILA`, paste the file as `app/streamlit_app.py`. It detects the active session and uses it. I ran it there (`docs/images/dashboard_sis_unfiltered.png` unfiltered, `docs/images/dashboard_sis_filtered.png` filtered to 2005-08-02 – 2005-11-14); the numbers on both screenshots were recomputed in Snowflake on the star and on the normalized copy and agree (unfiltered $67,406.56 · 16,044 payments · 599 paying customers · $4.20; filtered $21,252.85 · 5,015 · 599 · $4.24, stores 10,475.35 and 10,777.50). The role that owns the app must be able to read both `SAKILA.DW` and `SAKILA.OLTP` (the Check expander reads the latter).

## Limits
- The Check expander reads the normalized copy by design, so the app needs `SELECT` on both schemas. A role limited to `SAKILA.DW` would see the page work and the Check expander fail.
- Months without any payment (2005-09 to 2006-01 in this data) are not drawn, so the line joins August 2005 to February 2006 directly; the page says so under the chart.
- Results are cached for 5 minutes (`st.cache_data`) to keep the warehouse awake as little as possible; after changing data in Snowflake, reload the page after a few minutes or clear the cache from the menu.
