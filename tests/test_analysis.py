"""Test the denominators and joins, including an adversarial two-claim policy."""
import csv
import sqlite3
import tempfile
import unittest
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build_sql import build


class AnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.con = sqlite3.connect(build(Path(cls.tmp.name) / "test.sqlite"))
        cls.con.execute("PRAGMA foreign_keys = ON")

    @classmethod
    def tearDownClass(cls):
        cls.con.close()
        cls.tmp.cleanup()

    def test_geography_and_integrity(self):
        counties = {x[0] for x in self.con.execute("SELECT county FROM dfw_counties")}
        expected = set("Collin Dallas Denton Ellis Hood Hunt Johnson Kaufman Parker Rockwall Tarrant Wise".split())
        self.assertEqual(counties, expected)
        self.assertEqual(self.con.execute("PRAGMA foreign_key_check").fetchall(), [])
        self.assertEqual(self.con.execute("SELECT COUNT(*) FROM policies").fetchone()[0], 30000)

    def test_totals_reconcile_without_join_inflation(self):
        fact = self.con.execute("SELECT COUNT(*),SUM(exposure_years),SUM(claim_count),SUM(total_paid_usd) FROM policy_fact").fetchone()
        raw = self.con.execute("SELECT COUNT(*),SUM(exposure_years) FROM policies").fetchone()
        claims = self.con.execute("SELECT COUNT(*),SUM(paid_amount_usd) FROM claims").fetchone()
        self.assertEqual(fact[:2], raw)
        self.assertEqual(fact[2], claims[0])
        self.assertAlmostEqual(fact[3], claims[1], places=5)
        self.assertGreater(self.con.execute("SELECT COUNT(*) FROM policy_fact WHERE claim_count=0").fetchone()[0], 0)

    def test_two_claim_policy_and_zero_claim_policy(self):
        con = sqlite3.connect(":memory:")
        con.executescript((ROOT / "sql/01_schema.sql").read_text())
        con.execute("INSERT INTO dfw_counties VALUES ('Dallas')")
        for ident, exp in [('A', .5), ('B', 1)]:
            con.execute("INSERT INTO policies VALUES (?,2024,'Dallas','40-64','Sedan','5-9',?,'collision','SYNTHETIC','train')", (ident,exp))
        con.executemany("INSERT INTO claims VALUES (?, 'A', ?, 'SYNTHETIC')", [('C1',100),('C2',200)])
        con.executescript((ROOT / "sql/02_policy_fact.sql").read_text())
        cur = con.execute((ROOT / "sql/03_group_summary.sql").read_text())
        rows = [dict(zip([x[0] for x in cur.description], r)) for r in cur]
        row = next(r for r in rows if r['dimension']=='overall')
        self.assertEqual(row['policy_years'], 1.5)
        self.assertEqual(row['claims'], 2)
        self.assertEqual(row['annual_expected_cost_usd'], 200)
        self.assertEqual(row['observed_term_cost_usd'], 150)
        self.assertEqual(row['average_paid_per_claim_usd'], 150)
        self.assertAlmostEqual(row['frequency_per_policy_year'], 2/1.5)
        con.close()

    def test_frequency_severity_identity_and_group_rollups(self):
        cur = self.con.execute((ROOT / "sql/03_group_summary.sql").read_text())
        rows = [dict(zip([x[0] for x in cur.description], r)) for r in cur]
        overall = next(r for r in rows if r['dimension']=='overall')
        for r in rows:
            if r['claims']:
                self.assertAlmostEqual(r['frequency_per_policy_year'] * r['average_paid_per_claim_usd'], r['annual_expected_cost_usd'], places=6)
        for dim in ('driver_age','vehicle_type','vehicle_age','county','driver_vehicle'):
            rr = [r for r in rows if r['dimension']==dim]
            self.assertEqual(sum(r['policy_terms'] for r in rr), overall['policy_terms'])
            self.assertEqual(sum(r['claims'] for r in rr), overall['claims'])
            self.assertAlmostEqual(sum(r['policy_years'] for r in rr), overall['policy_years'])

    def test_invalid_exposure_and_orphan_claim_fail(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.con.execute("INSERT INTO claims VALUES ('BAD', 'MISSING', 10, 'SYNTHETIC')")
        with self.assertRaises(sqlite3.IntegrityError):
            self.con.execute("UPDATE policies SET exposure_years=0 WHERE policy_id='SYN000001'")
        self.con.rollback()


if __name__ == '__main__':
    unittest.main()
