"""Sakila rentals dashboard on the star schema (SAKILA.DW).

* Every number, chart and table on the page is computed from SAKILA.DW (the star) only.
* One filter, the payment date range in the sidebar, changes every number on the page.
* The "Check" expander is the only place that touches SAKILA.OLTP: for each number it shows the SQL behind it, the same
  number computed from the normalized copy, and whether they match.

Runs in two places, with the same file:
  - Streamlit in Snowflake (Snowsight > Projects > Streamlit > + Streamlit App; pick CLASS_WH and database SAKILA):
    paste this file as app/streamlit_app.py. The active session's role must be able to read SAKILA.DW and SAKILA.OLTP.
  - Locally / Cloud Shell, with the Snowflake connector and the Snowflake CLI connection named "claude":
        streamlit run app/streamlit_app.py
    (set SNOWFLAKE_CONNECTION_NAME to use another connection)
Optional link parameters set the filter: ?start=2005-07-01&end=2005-08-31
"""
import datetime as dt
import os

import altair as alt
import pandas as pd
import streamlit as st

DW = "SAKILA.DW"
OLTP = "SAKILA.OLTP"  # used by the Check expander only

st.set_page_config(page_title="Sakila rentals: the star schema", layout="wide")


# ---------------------------------------------------------------------------------------------------------------- connection
try:  # inside Streamlit in Snowflake there is an active session
    from snowflake.snowpark.context import get_active_session

    _SESSION = get_active_session()
except Exception:  # not in Snowflake: connect with the Snowflake connector
    _SESSION = None


@st.cache_resource
def _connection():
    import snowflake.connector

    return snowflake.connector.connect(connection_name=os.environ.get("SNOWFLAKE_CONNECTION_NAME", "claude"),
                                       warehouse="CLASS_WH")


@st.cache_data(ttl=300, show_spinner=False)
def query(sql: str) -> pd.DataFrame:
    """Run one SELECT and return a DataFrame with lower-case column names and numeric columns as numbers."""
    if _SESSION is not None:
        df = _SESSION.sql(sql).to_pandas()
    else:
        cur = _connection().cursor()
        try:
            cur.execute(sql)
            df = pd.DataFrame(cur.fetchall(), columns=[c[0] for c in cur.description])
        finally:
            cur.close()
    df.columns = [c.lower() for c in df.columns]
    for c in df.columns:
        if df[c].dtype == object:
            try:
                df[c] = pd.to_numeric(df[c])
            except (ValueError, TypeError):
                pass
    return df


def same(a: pd.DataFrame, b: pd.DataFrame) -> bool:
    """Same shape, same column names, same values (money compared to the cent)."""
    if a.shape != b.shape or list(a.columns) != list(b.columns):
        return False
    for c in a.columns:
        if pd.api.types.is_numeric_dtype(a[c]) and pd.api.types.is_numeric_dtype(b[c]):
            if not ((a[c].fillna(0).astype(float) - b[c].fillna(0).astype(float)).abs() < 0.005).all():
                return False
        elif not (a[c].astype(str).values == b[c].astype(str).values).all():
            return False
    return True


def stretch(fn, obj):
    """Full-width element on old and new Streamlit versions."""
    try:
        fn(obj, width="stretch")
    except TypeError:
        fn(obj, use_container_width=True)


# ---------------------------------------------------------------------------------------------------------------- the filter
bounds = query(f"""SELECT MIN(d.full_date) AS first_day, MAX(d.full_date) AS last_day
                   FROM {DW}.FACT_PAYMENT p JOIN {DW}.DIM_DATE d ON d.date_key = p.payment_date_key""")
first_day, last_day = bounds.first_day[0], bounds.last_day[0]
first_day, last_day = pd.Timestamp(first_day).date(), pd.Timestamp(last_day).date()


def _param(name: str, default: dt.date) -> dt.date:
    try:
        return min(max(dt.date.fromisoformat(st.query_params.get(name, "")), first_day), last_day)
    except ValueError:
        return default


st.sidebar.header("Filter")
picked = st.sidebar.date_input("Payment date range", value=(_param("start", first_day), _param("end", last_day)),
                               min_value=first_day, max_value=last_day,
                               help="Changes every number, chart and table on the page.")
st.sidebar.caption(f"The data holds payments from {first_day} to {last_day}.")
if not (isinstance(picked, (tuple, list)) and len(picked) == 2):
    st.info("Pick an end date to apply the filter.")
    st.stop()
start, end = picked
lo, hi = int(start.strftime("%Y%m%d")), int(end.strftime("%Y%m%d"))  # DIM_DATE keys
# the same window written for the normalized copy (a timestamp column, so up to the end of the last day)
oltp_window = f"p.payment_date >= '{start.isoformat()}' AND p.payment_date < DATEADD(day, 1, '{end.isoformat()}'::DATE)"
star_window = f"p.payment_date_key BETWEEN {lo} AND {hi}"

# ---------------------------------------------------------------------------------------------------------------- the queries
# Each number has a star query (what the page shows) and a normalized-copy query (only used by the Check expander).
Q = {}
Q["kpi"] = (
    f"""SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT c.customer_id) AS paying_customers,
       ROUND(AVG(p.amount), 2) AS average_payment
FROM {DW}.FACT_PAYMENT p
JOIN {DW}.DIM_CUSTOMER c ON c.customer_key = p.customer_key   -- DIM_CUSTOMER is Type 2: count customer_id, not customer_key
WHERE {star_window}""",
    f"""SELECT SUM(p.amount) AS revenue, COUNT(*) AS payments, COUNT(DISTINCT p.customer_id) AS paying_customers,
       ROUND(AVG(p.amount), 2) AS average_payment
FROM {OLTP}.payment p
WHERE {oltp_window}""")
Q["month"] = (
    f"""SELECT TO_CHAR(d.full_date, 'YYYY-MM') AS month, SUM(p.amount) AS revenue
FROM {DW}.FACT_PAYMENT p
JOIN {DW}.DIM_DATE d ON d.date_key = p.payment_date_key
WHERE {star_window}
GROUP BY 1 ORDER BY 1""",
    f"""SELECT TO_CHAR(p.payment_date, 'YYYY-MM') AS month, SUM(p.amount) AS revenue
FROM {OLTP}.payment p
WHERE {oltp_window}
GROUP BY 1 ORDER BY 1""")
Q["category"] = (
    f"""SELECT f.category, SUM(p.amount) AS revenue
FROM {DW}.FACT_PAYMENT p
JOIN {DW}.DIM_FILM f ON f.film_key = p.film_key
WHERE {star_window}
GROUP BY 1 ORDER BY revenue DESC, category LIMIT 10""",
    f"""SELECT cat.name AS category, SUM(p.amount) AS revenue
FROM {OLTP}.payment p
JOIN {OLTP}.rental r ON r.rental_id = p.rental_id
JOIN {OLTP}.inventory i ON i.inventory_id = r.inventory_id
JOIN {OLTP}.film_category fc ON fc.film_id = i.film_id
JOIN {OLTP}.category cat ON cat.category_id = fc.category_id
WHERE {oltp_window}
GROUP BY 1 ORDER BY revenue DESC, category LIMIT 10""")
Q["store"] = (
    f"""SELECT s.store_id, s.city, s.country, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM {DW}.FACT_PAYMENT p
JOIN {DW}.DIM_STORE s ON s.store_key = p.store_key          -- the store that holds the rented copy
WHERE {star_window}
GROUP BY 1, 2, 3 ORDER BY 1""",
    f"""SELECT st.store_id, ci.city, co.country, COUNT(*) AS payments, SUM(p.amount) AS revenue
FROM {OLTP}.payment p
JOIN {OLTP}.rental r ON r.rental_id = p.rental_id
JOIN {OLTP}.inventory i ON i.inventory_id = r.inventory_id
JOIN {OLTP}.store st ON st.store_id = i.store_id
JOIN {OLTP}.address a ON a.address_id = st.address_id
JOIN {OLTP}.city ci ON ci.city_id = a.city_id
JOIN {OLTP}.country co ON co.country_id = ci.country_id
WHERE {oltp_window}
GROUP BY 1, 2, 3 ORDER BY 1""")

# ---------------------------------------------------------------------------------------------------------------- the page
st.title("Sakila rentals: what the star schema says")
st.caption(f"Payments dated **{start}** to **{end}** · every number below is read from `{DW}` · warehouse CLASS_WH")

kpi = query(Q["kpi"][0])
if kpi.payments[0] == 0:
    st.warning("No payments in this date range.")
    st.stop()
c1, c2, c3, c4 = st.columns(4)
c1.metric("Revenue", f"${kpi.revenue[0]:,.2f}")
c2.metric("Payments", f"{int(kpi.payments[0]):,}")
c3.metric("Paying customers", f"{int(kpi.paying_customers[0]):,}")
c4.metric("Average payment", f"${kpi.average_payment[0]:,.2f}")

left, right = st.columns(2)
with left:
    st.subheader("Revenue by month")
    month = query(Q["month"][0])
    chart = (alt.Chart(month).mark_line(point=True)
             .encode(x=alt.X("month:N", title="Month", axis=alt.Axis(labelAngle=0)),
                     y=alt.Y("revenue:Q", title="Revenue ($)", scale=alt.Scale(zero=True)),
                     tooltip=["month", alt.Tooltip("revenue:Q", format=",.2f")])
             .properties(height=320))
    stretch(st.altair_chart, chart)
    st.caption("Months without any payment are not shown.")
with right:
    st.subheader("Top 10 film categories by revenue")
    cat = query(Q["category"][0])
    chart = (alt.Chart(cat).mark_bar()
             .encode(y=alt.Y("category:N", sort="-x", title=None), x=alt.X("revenue:Q", title="Revenue ($)"),
                     tooltip=["category", alt.Tooltip("revenue:Q", format=",.2f")])
             .properties(height=320))
    stretch(st.altair_chart, chart)

st.subheader("Revenue by store")
store = query(Q["store"][0])
store_view = store.assign(share=(store.revenue / store.revenue.sum() * 100).round(1)).rename(
    columns={"store_id": "Store", "city": "City", "country": "Country", "payments": "Payments", "revenue": "Revenue ($)", "share": "Share (%)"})
st.dataframe(store_view, hide_index=True)
st.caption("A store's revenue is the revenue of the copies it holds (`FACT_PAYMENT.store_key`). "
           "Revenue by the customer's home store or by the staff member's store would give different totals per store.")

# ---------------------------------------------------------------------------------------------------------------- the check
with st.expander("Check: the SQL behind every number, and the same number from the normalized copy", expanded=False):
    st.write("Each block shows the star query that produced the number above, the same question asked of the normalized copy "
             f"(`{OLTP}`), and whether the two agree. Nothing outside this expander reads `{OLTP}`.")
    results = []

    # --- the four KPIs: one query on each side, compared number by number
    star_kpi, oltp_kpi = query(Q["kpi"][0]), query(Q["kpi"][1])
    st.markdown("#### KPIs: revenue, payments, paying customers, average payment")
    a, b = st.columns(2)
    a.caption("Star (`SAKILA.DW`)")
    a.code(Q["kpi"][0], language="sql")
    b.caption("Normalized copy (`SAKILA.OLTP`)")
    b.code(Q["kpi"][1], language="sql")
    kpi_check = pd.DataFrame({"number": ["Revenue", "Payments", "Paying customers", "Average payment"],
                              "star": star_kpi.iloc[0].astype(float).values, "normalized": oltp_kpi.iloc[0].astype(float).values})
    kpi_check["match"] = ((kpi_check.star - kpi_check.normalized).abs() < 0.005).map({True: "MATCH", False: "DIFF"})
    st.dataframe(kpi_check, hide_index=True)
    results += list(kpi_check.match == "MATCH")

    # --- the three tables behind the charts
    for key, title in [("month", "Revenue by month"), ("category", "Top 10 film categories by revenue"), ("store", "Revenue by store")]:
        s_df, o_df = query(Q[key][0]), query(Q[key][1])
        ok = same(s_df, o_df)
        results.append(ok)
        st.markdown(f"#### {title}")
        a, b = st.columns(2)
        a.caption("Star (`SAKILA.DW`)")
        a.code(Q[key][0], language="sql")
        b.caption("Normalized copy (`SAKILA.OLTP`)")
        b.code(Q[key][1], language="sql")
        a.dataframe(s_df, hide_index=True)
        b.dataframe(o_df, hide_index=True)
        (st.success if ok else st.error)(f"{'MATCH' if ok else 'DIFF'}: {len(s_df)} rows from the star, {len(o_df)} rows from the normalized copy")

    st.markdown("---")
    if all(results):
        st.success(f"All {len(results)} comparisons match for payments dated {start} to {end}.")
    else:
        st.error(f"{results.count(False)} of {len(results)} comparisons differ: the star and the normalized copy disagree.")
