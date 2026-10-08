from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from .core import AirtableClient, export_snapshot, run_backup, verify_local_snapshot


def main() -> int:
    parser = argparse.ArgumentParser(prog="ledger-backup")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run", help="Export Airtable, upload to Drive, verify readback, update health, then prune")
    verify = sub.add_parser("verify-local", help="Verify a staged/local snapshot")
    verify.add_argument("path", type=Path)
    export = sub.add_parser("export-local", help="Export Airtable to a local directory without Drive")
    export.add_argument("path", type=Path)
    args = parser.parse_args()

    if args.command == "run":
        print(json.dumps(run_backup(), indent=2, sort_keys=True))
        return 0
    if args.command == "verify-local":
        print(json.dumps(verify_local_snapshot(args.path), indent=2, sort_keys=True))
        return 0
    if args.command == "export-local":
        airtable = AirtableClient(os.environ["AIRTABLE_TOKEN"], os.environ["AIRTABLE_BASE_ID"])
        manifest = export_snapshot(airtable, args.path, "manual-local-export")
        verify_local_snapshot(args.path)
        print(json.dumps(manifest, indent=2, sort_keys=True))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
