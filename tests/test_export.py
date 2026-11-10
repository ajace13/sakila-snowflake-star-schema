"""Tests for the MySQL dump -> CSV exporter (src/export_sakila_csv.py)."""
import csv
import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DUMP = ROOT / "sakila-db" / "sakila-data.sql"

spec = importlib.util.spec_from_file_location("export_sakila_csv", ROOT / "src" / "export_sakila_csv.py")
exp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exp)


def test_parses_strings_nulls_numbers_and_escapes():
    text = "INSERT INTO `actor` VALUES (1,'O\\'BRIEN',NULL,2.5),(2,'it''s','a\\nb',-3);"
    [(table, rows)] = list(exp.parse_inserts(text))
    assert table == "actor"
    assert rows == [("1", "O'BRIEN", None, "2.5"), ("2", "it's", "a\nb", "-3")]


def test_hex_literals_and_conditional_comments():
    text = "INSERT INTO `staff` VALUES (1,/*!50705 0xABCD,*/ 'x');"
    [(_, rows)] = list(exp.parse_inserts(text))
    assert rows[0][1] == "ABCD" and isinstance(rows[0][1], exp.Hex)


def test_convert_null_bool_and_point():
    assert exp.convert(None, "s") == "\\N"
    assert exp.convert("1", "bool") == "1"
    with pytest.raises(AssertionError):
        exp.convert("2", "bool")
    # MySQL internal geometry: 4-byte SRID 0 + WKB little-endian POINT(1.5 -2.0)
    import struct
    wkb = struct.pack("<I", 0) + b"\x01" + struct.pack("<I", 1) + struct.pack("<dd", 1.5, -2.0)
    assert exp.convert(exp.Hex(wkb.hex().upper()), "geo") == "POINT(1.5 -2.0)"


@pytest.mark.skipif(not DUMP.exists(), reason="Sakila dump not downloaded (see README)")
def test_full_dump_reproduces_committed_counts(tmp_path):
    out = tmp_path / "csv"
    subprocess.run([sys.executable, str(ROOT / "src" / "export_sakila_csv.py"), str(DUMP), str(out)], check=True)
    for name in ("source_counts.csv", "source_control_totals.csv"):
        produced = list(csv.reader(open(tmp_path / name, encoding="utf-8")))
        committed = list(csv.reader(open(ROOT / "data" / name, encoding="utf-8")))
        assert produced == committed, name
    for f in sorted((ROOT / "data" / "csv").glob("*.csv")):
        assert (out / f.name).read_bytes() == f.read_bytes(), f.name
