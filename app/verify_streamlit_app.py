"""Dashboard verification, headless (Streamlit's AppTest, no browser): runs app/streamlit_app.py unfiltered and filtered, records every SQL
statement it sends to Snowflake, and asserts: no exception, the filter changes every KPI, all 7 comparisons in the Check expander match,
and only the Check expander's queries touch SAKILA.OLTP.
Run:  ~/venv-streamlit/bin/python app/verify_streamlit_app.py | tee evidence/dashboard_verify_log.txt"""
import datetime as dt
import os

import snowflake.connector.cursor as cursor_module
from streamlit.testing.v1 import AppTest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sent = []
_execute = cursor_module.SnowflakeCursor.execute


def recording_execute(self, command, *args, **kwargs):
    sent.append(" ".join(command.split()))
    return _execute(self, command, *args, **kwargs)


cursor_module.SnowflakeCursor.execute = recording_execute


def kpis(at):
    return {m.label: m.value for m in at.metric}


def report(at, label):
    comparisons = [s.value for s in at.success if "comparisons match" in s.value]
    print(f"{label}\n  KPIs: {kpis(at)}\n  Check expander: {comparisons[0] if comparisons else 'NO MATCH MESSAGE'}")
    assert not at.exception, [e.value for e in at.exception]
    assert not at.error, [e.value for e in at.error]
    assert comparisons and comparisons[0].startswith("All 7 comparisons match"), comparisons


at = AppTest.from_file(os.path.join(ROOT, "app/streamlit_app.py"), default_timeout=240).run()
report(at, "UNFILTERED (full date range)")
unfiltered = kpis(at)
n_after_first = len(sent)

at.sidebar.date_input[0].set_value((dt.date(2005, 6, 1), dt.date(2005, 7, 15))).run()
report(at, "FILTERED (payments 2005-06-01 to 2005-07-15)")
filtered = kpis(at)
assert all(unfiltered[k] != filtered[k] for k in unfiltered), "every KPI must change with the filter"
print("  the filter changed all four KPIs:", [k for k in unfiltered])

# which SQL touched which schema, over both runs
oltp = [s for s in sent if "SAKILA.OLTP" in s]
star_only = [s for s in sent if "SAKILA.OLTP" not in s and "SAKILA.DW" in s]
other = [s for s in sent if "SAKILA.OLTP" not in s and "SAKILA.DW" not in s]
print(f"\nstatements sent to Snowflake: {len(sent)} (both runs)")
print(f"  read SAKILA.DW only (what the page shows): {len(star_only)}")
print(f"  read SAKILA.OLTP (the Check expander only): {len(oltp)}")
print(f"  neither: {len(other)}")
assert not other
# each OLTP query is a Check-expander query: it is never the only query behind a number on the page
page_numbers = {"revenue", "payments", "paying_customers", "average_payment"}
assert all(" AS revenue" in s or " AS payments" in s or "average_payment" in s for s in oltp)
assert len(oltp) == 8, len(oltp)  # four checks x two date ranges
assert len(star_only) == 1 + 8   # the date bounds once + four page queries x two date ranges
print("\nOK: the page reads only the star; only the Check expander reads the normalized copy; all comparisons match.")
