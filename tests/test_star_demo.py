"""The local DuckDB star must reconcile with the normalized tables, to the cent."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_star_duckdb", ROOT / "demo" / "build_star_duckdb.py")
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)

con = demo.build()


def test_every_check_matches():
    failed = [r for r in demo.run_checks(con) if not r[3]]
    assert failed == []


def test_known_totals():
    assert float(con.execute("SELECT SUM(amount) FROM dw.fact_payment").fetchone()[0]) == 67406.56
    assert con.execute("SELECT COUNT(*) FROM dw.fact_rental").fetchone()[0] == 16044
    by_store = dict(con.execute("""SELECT st.store_id, ROUND(SUM(p.amount), 2) FROM dw.fact_payment p
                                   JOIN dw.dim_store st USING (store_key) GROUP BY 1""").fetchall())
    assert {k: float(v) for k, v in by_store.items()} == {1: 33679.79, 2: 33726.77}


def test_type2_customer_count_uses_customer_id():
    versions, people = con.execute(
        "SELECT COUNT(*), COUNT(DISTINCT customer_id) FROM dw.dim_customer").fetchone()
    assert people == 599 and versions >= people
