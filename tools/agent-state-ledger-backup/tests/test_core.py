import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from ledger_backup.core import (
    BackupError,
    canonical_bytes,
    export_snapshot,
    retention_plan,
    sha256_bytes,
    verify_local_snapshot,
)


class FakeAirtable:
    base_id = "appTEST"

    def discover_tables(self):
        return [
            {
                "id": "tblB",
                "name": "Beta",
                "primaryFieldId": "fldB",
                "fields": [{"id": "fldB", "name": "Name", "type": "singleLineText"}],
            },
            {
                "id": "tblA",
                "name": "Alpha / unsafe",
                "primaryFieldId": "fldA",
                "fields": [{"id": "fldA", "name": "Name", "type": "singleLineText"}],
            },
        ]

    def list_records(self, table_id):
        if table_id == "tblA":
            return [
                {
                    "id": "rec2",
                    "createdTime": "2026-01-01T00:00:00.000Z",
                    "fields": {"fldA": "two"},
                },
                {
                    "id": "rec1",
                    "createdTime": "2026-01-01T00:00:00.000Z",
                    "fields": {"fldA": "one"},
                },
            ]
        return [
            {
                "id": "rec3",
                "createdTime": "2026-01-01T00:00:00.000Z",
                "fields": {"fldB": "three"},
            }
        ]


class CoreTests(unittest.TestCase):
    def test_canonical_serialization_is_stable(self):
        a = canonical_bytes({"b": 2, "a": [3, 1]})
        b = canonical_bytes({"a": [3, 1], "b": 2})
        self.assertEqual(a, b)
        self.assertEqual(sha256_bytes(a), sha256_bytes(b))

    def test_export_and_verify(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "snapshot"
            manifest = export_snapshot(
                FakeAirtable(),
                root,
                "2026-01-01T00:00:00+00:00",
            )
            verified = verify_local_snapshot(root)
            self.assertEqual(manifest["aggregate_sha256"], verified["aggregate_sha256"])
            self.assertEqual(manifest["table_count"], 2)
            self.assertEqual(manifest["record_count"], 3)
            self.assertTrue((root / "tables" / "Alpha-unsafe--tblA.json").exists())
            alpha = json.loads(
                (root / "tables" / "Alpha-unsafe--tblA.json").read_text()
            )
            self.assertEqual([r["id"] for r in alpha["records"]], ["rec1", "rec2"])

    def test_verify_detects_corruption(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "snapshot"
            export_snapshot(FakeAirtable(), root, "x")
            table = next((root / "tables").iterdir())
            table.write_text(table.read_text() + "corrupt")
            with self.assertRaises(BackupError):
                verify_local_snapshot(root)

    def test_retention_keeps_daily_weekly_monthly_and_latest(self):
        names = [
            "ledger-20261008T120000Z",
            "ledger-20261007T120000Z",
            "ledger-20260901T120000Z",
            "ledger-20260831T120000Z",
            "ledger-20260701T120000Z",
            "not-managed",
        ]
        folders = [{"id": f"id{i}", "name": name} for i, name in enumerate(names)]
        delete = retention_plan(
            folders,
            datetime(2026, 10, 8, 12, 0, tzinfo=timezone.utc),
        )
        self.assertNotIn("id0", delete)
        self.assertNotIn("id1", delete)
        self.assertNotIn("id4", delete)
        self.assertNotIn("id5", delete)


if __name__ == "__main__":
    unittest.main()
