"""Execute the checked-in SQL with standard-library SQLite; export R inputs."""
import csv
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def build(database=None):
    db = Path(database) if database else ROOT / "work/claims.sqlite"
    db.parent.mkdir(parents=True, exist_ok=True)
    # Disposable generated database only. Never points at a user database.
    if db.exists():
        db.unlink()
    con = sqlite3.connect(db)
    con.executescript((ROOT / "sql/01_schema.sql").read_text())
    with (ROOT / "data/public/dfw_county_crashes_2024.csv").open() as f:
        counties = [r["county"] for r in csv.DictReader(f)]
    con.executemany("INSERT INTO dfw_counties VALUES (?)", [(c,) for c in counties])
    for table in ("policies", "claims"):
        with (ROOT / f"data/synthetic/{table}.csv").open() as f:
            reader = csv.DictReader(f)
            names = reader.fieldnames
            con.executemany(
                f"INSERT INTO {table} ({','.join(names)}) VALUES ({','.join('?' for _ in names)})",
                ([row[k] for k in names] for row in reader),
            )
    con.executescript((ROOT / "sql/02_policy_fact.sql").read_text())
    queries = {
        "policy_fact.csv": "SELECT * FROM policy_fact ORDER BY policy_id",
        "group_summary.csv": (ROOT / "sql/03_group_summary.sql").read_text(),
    }
    out = ROOT / "reports/tables"
    out.mkdir(parents=True, exist_ok=True)
    for name, sql in queries.items():
        cur = con.execute(sql)
        with (out / name).open("w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(d[0] for d in cur.description)
            writer.writerows(cur)
    assert not con.execute("PRAGMA foreign_key_check").fetchall()
    con.commit()
    con.close()
    print("SQLite schema, policy fact, and grouped summaries executed successfully.")
    return db


if __name__ == "__main__":
    build()

