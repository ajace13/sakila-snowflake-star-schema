#!/usr/bin/env python3
"""Sakila (MySQL 8.0 / Cloud SQL) -> CSV files ready for Snowflake COPY INTO.

Reads the SAME file that was imported into Cloud SQL (sakila-db/sakila-data.sql, Sakila v1.5), parses every
INSERT, and writes one CSV per base table plus the source row counts and control totals.
Nothing here talks to a database; it only reads the dump and writes files.

Usage:  python src/export_sakila_csv.py [path/to/sakila-data.sql] [output_dir]
Defaults: sakila-db/sakila-data.sql  and  data/csv  (relative to the repo root)

CSV conventions (must match the file format in sql/01_oltp_ddl.sql):
  - UTF-8, comma delimited, one header row, fields quoted with " only when needed
  - SQL NULL is written as \\N (bare); an empty string is an empty field
  - BOOLEAN/TINYINT(1) as 1/0 · BLOB as upper-case hex (no 0x) · GEOMETRY as WKT 'POINT(x y)' (SRID 0, planar)
  - ENUM and SET are written as the same text MySQL shows (SET = comma-separated)
"""
import csv
import hashlib
import math
import os
import re
import struct
import sys
from decimal import Decimal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "sakila-db", "sakila-data.sql")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "data", "csv")

# Column order of each base table, exactly as in sakila-schema.sql. Kind: s = pass through, bool, blob, geo.
SPEC = {
    "actor": ["actor_id", "first_name", "last_name", "last_update"],
    "address": ["address_id", "address", "address2", "district", "city_id", "postal_code", "phone", "location:geo", "last_update"],
    "category": ["category_id", "name", "last_update"],
    "city": ["city_id", "city", "country_id", "last_update"],
    "country": ["country_id", "country", "last_update"],
    "customer": ["customer_id", "store_id", "first_name", "last_name", "email", "address_id", "active:bool", "create_date", "last_update"],
    "film": ["film_id", "title", "description", "release_year", "language_id", "original_language_id", "rental_duration",
             "rental_rate", "length", "replacement_cost", "rating", "special_features", "last_update"],
    "film_actor": ["actor_id", "film_id", "last_update"],
    "film_category": ["film_id", "category_id", "last_update"],
    "inventory": ["inventory_id", "film_id", "store_id", "last_update"],
    "language": ["language_id", "name", "last_update"],
    "payment": ["payment_id", "customer_id", "staff_id", "rental_id", "amount", "payment_date", "last_update"],
    "rental": ["rental_id", "rental_date", "inventory_id", "customer_id", "return_date", "staff_id", "last_update"],
    "staff": ["staff_id", "first_name", "last_name", "address_id", "picture:blob", "email", "store_id", "active:bool",
              "username", "password", "last_update"],
    "store": ["store_id", "manager_staff_id", "address_id", "last_update"],
}
# film_text has no INSERTs in the dump: MySQL fills it from film through the ins_film trigger (film_id, title, description).
FILM_TEXT_COLS = ["film_id", "title", "description"]

ESC = {"0": "\x00", "'": "'", '"': '"', "b": "\b", "n": "\n", "r": "\r", "t": "\t", "Z": "\x1a", "\\": "\\"}
NUM = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
HEX = re.compile(r"0[xX]([0-9A-Fa-f]*)")
SKIP = re.compile(r"(?:\s+|/\*!\d+\s*|\*/)+")  # whitespace and MySQL conditional-comment markers /*!50705 ... */


class Hex(str):
    """A hex literal (0x...): bytes of a BLOB or of a GEOMETRY value."""


def parse_inserts(text):
    """Yield (table, [row tuples]) for every INSERT INTO <t> VALUES (...),(...); statement."""
    for m in re.finditer(r"INSERT INTO `?(\w+)`? VALUES\s*", text):
        table, i, rows = m.group(1), m.end(), []
        while True:
            i = SKIP.match(text, i).end() if SKIP.match(text, i) else i
            assert text[i] == "(", f"{table}: expected ( at {i}: {text[i:i+40]!r}"
            i += 1
            row = []
            while True:
                i = SKIP.match(text, i).end() if SKIP.match(text, i) else i
                c = text[i]
                if c == "'":
                    i += 1
                    buf = []
                    while True:
                        c = text[i]
                        if c == "\\":
                            buf.append(ESC.get(text[i + 1], "\\" + text[i + 1]))
                            i += 2
                        elif c == "'":
                            if text[i + 1:i + 2] == "'":
                                buf.append("'")
                                i += 2
                            else:
                                i += 1
                                break
                        else:
                            buf.append(c)
                            i += 1
                    row.append("".join(buf))
                elif text.startswith("NULL", i):
                    row.append(None)
                    i += 4
                elif HEX.match(text, i):
                    h = HEX.match(text, i)
                    row.append(Hex(h.group(1).upper()))
                    i = h.end()
                else:
                    num = NUM.match(text, i)
                    assert num, f"{table}: cannot parse value at {i}: {text[i:i+40]!r}"
                    row.append(num.group(0))
                    i = num.end()
                i = SKIP.match(text, i).end() if SKIP.match(text, i) else i
                c = text[i]
                if c == ",":
                    i += 1
                    # a comma that closes a conditional comment, e.g. /*!50705 0x...,*/ , is followed by a value
                    continue
                if c == ")":
                    i += 1
                    break
                raise AssertionError(f"{table}: unexpected {c!r} at {i}: {text[i-40:i+40]!r}")
            rows.append(tuple(row))
            i = SKIP.match(text, i).end() if SKIP.match(text, i) else i
            if text[i] == ",":
                i += 1
                continue
            assert text[i] == ";", f"{table}: expected ; or , at {i}: {text[i:i+40]!r}"
            break
        yield table, rows


def point_xy(hexstr):
    """MySQL internal geometry = 4-byte SRID + WKB. Return (x, y); fail loudly on anything but a 2D POINT with SRID 0."""
    b = bytes.fromhex(hexstr)
    assert len(b) == 25 and b[4] == 1, "location is not a little-endian 2D POINT"
    srid, wkb_type = struct.unpack("<I", b[:4])[0], struct.unpack("<I", b[5:9])[0]
    x, y = struct.unpack("<dd", b[9:25])
    assert srid == 0 and wkb_type == 1 and math.isfinite(x) and math.isfinite(y), "location is not a finite POINT, SRID 0"
    return x, y


def point_wkt(hexstr):
    x, y = point_xy(hexstr)
    return f"POINT({x!r} {y!r})"  # repr() keeps every digit of the double


def convert(value, kind):
    if value is None:
        return "\\N"
    if kind == "geo":
        assert isinstance(value, Hex), "location should be a hex literal"
        return point_wkt(value)
    if kind == "blob":
        assert isinstance(value, Hex), "picture should be a hex literal"
        return str(value)
    if kind == "bool":
        assert value in ("0", "1"), f"unexpected boolean value {value!r}"
    return value


def main():
    with open(DUMP, encoding="utf-8") as f:
        text = f.read()
    tables = {}
    for t, rows in parse_inserts(text):
        tables.setdefault(t, []).extend(rows)  # payment and rental are split over two INSERT statements

    unknown = set(tables) - set(SPEC)
    missing = set(SPEC) - set(tables)
    assert not unknown and not missing, f"tables in dump but not in SPEC: {unknown}; in SPEC but not in dump: {missing}"

    os.makedirs(OUT, exist_ok=True)
    counts = {}
    for t, cols in SPEC.items():
        names = [c.split(":")[0] for c in cols]
        kinds = [c.split(":")[1] if ":" in c else "s" for c in cols]
        rows = tables[t]
        assert all(len(r) == len(cols) for r in rows), f"{t}: a row does not have {len(cols)} fields"
        with open(os.path.join(OUT, f"{t}.csv"), "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f, lineterminator="\n")
            w.writerow(names)
            for r in rows:
                w.writerow([convert(v, k) for v, k in zip(r, kinds)])
        counts[t] = len(rows)

    # film_text: what the ins_film trigger produced in MySQL — one row per film (film_id, title, description)
    ft = [(r[0], r[1], r[2]) for r in tables["film"]]
    with open(os.path.join(OUT, "film_text.csv"), "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(FILM_TEXT_COLS)
        for r in ft:
            w.writerow([convert(v, "s") for v in r])
    counts["film_text"] = len(ft)

    # ---- control totals: a number per check that the Snowflake side must reproduce (see sql/01_oltp_ddl.sql) ----
    ix = {t: {c.split(":")[0]: i for i, c in enumerate(cols)} for t, cols in SPEC.items()}

    def col(t, c):
        return [r[ix[t][c]] for r in tables[t]]

    def dsum(t, c):
        return sum(Decimal(v) for v in col(t, c) if v is not None)

    ctl = [
        ("payment", "SUM(amount)", f"{dsum('payment', 'amount'):.2f}"),
        ("payment", "COUNT(*) WHERE rental_id IS NULL", sum(v is None for v in col("payment", "rental_id"))),
        ("rental", "COUNT(*) WHERE return_date IS NULL", sum(v is None for v in col("rental", "return_date"))),
        ("rental", "MAX(rental_id)", max(int(v) for v in col("rental", "rental_id"))),
        ("film", "SUM(length)", sum(int(v) for v in col("film", "length") if v is not None)),
        ("film", "SUM(rental_rate)", f"{dsum('film', 'rental_rate'):.2f}"),
        ("film", "SUM(replacement_cost)", f"{dsum('film', 'replacement_cost'):.2f}"),
        ("film", "COUNT(*) WHERE special_features IS NOT NULL", sum(v is not None for v in col("film", "special_features"))),
        ("film", "COUNT(*) WHERE rating = 'PG-13'", sum(v == "PG-13" for v in col("film", "rating"))),
        ("customer", "COUNT(*) WHERE active", sum(v == "1" for v in col("customer", "active"))),
        ("staff", "LENGTH(picture) WHERE staff_id = 1", len(bytes.fromhex(
            next(r[ix["staff"]["picture"]] for r in tables["staff"] if r[0] == "1")))),
        ("city", "SUM(LENGTH(city))", sum(len(v) for v in col("city", "city"))),
        ("staff", "MD5(HEX_ENCODE(picture)) WHERE staff_id = 1", hashlib.md5(
            next(r[ix["staff"]["picture"]] for r in tables["staff"] if r[0] == "1").encode()).hexdigest()),
        ("address", "COUNT(*) WHERE address2 IS NULL", sum(v is None for v in col("address", "address2"))),
        ("address", "COUNT(*) WHERE address2 = ''", sum(v == "" for v in col("address", "address2"))),
        ("address", "COUNT(*) WHERE location IS NOT NULL", sum(v is not None for v in col("address", "location"))),
        ("address", "COUNT(*) WHERE location is outside lon/lat range", sum(
            not (-180 <= x <= 180 and -90 <= y <= 90) for x, y in (point_xy(v) for v in col("address", "location")))),
    ]

    with open(os.path.join(OUT, "..", "source_counts.csv"), "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["table", "source_rows"])
        for t in sorted(counts):
            w.writerow([t, counts[t]])
    with open(os.path.join(OUT, "..", "source_control_totals.csv"), "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["table", "check", "source_value"])
        w.writerows(ctl)

    print(f"dump: {os.path.basename(DUMP)}   output: {os.path.relpath(OUT)}")
    print(f"{'table':<14}{'rows':>8}")
    for t in sorted(counts):
        print(f"{t:<14}{counts[t]:>8}")
    print(f"{'TOTAL':<14}{sum(counts.values()):>8}   ({len(counts)} base tables)")
    print("\ncontrol totals")
    for t, c, v in ctl:
        print(f"  {t:<9}{c:<56}{v}")


if __name__ == "__main__":
    main()
