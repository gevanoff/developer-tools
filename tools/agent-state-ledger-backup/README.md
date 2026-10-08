# Agent State Ledger Backup

Deterministic, independently verifiable backups of the Airtable **Agent State Ledger** to Google Drive.

## Invariants

1. Discover the Airtable schema dynamically on every run.
2. Export every table and every record using stable Airtable IDs.
3. Canonically serialize JSON and SHA-256 each table.
4. Verify the local snapshot before upload.
5. Upload into a `.partial-*` Drive folder.
6. Download every uploaded object and compare SHA-256.
7. Rename the folder into the managed snapshot namespace only after complete verification.
8. Update `BACKUP_HEALTH.last_success` only after Drive readback passes, then read the health record back and compare it byte-for-byte.
9. On failure, preserve `last_success`, write `last_failure`, and leave partial Drive folders outside retention scope.
10. Prune only after a newly verified snapshot exists.

## Configuration

Required:

```text
AIRTABLE_TOKEN=...
AIRTABLE_BASE_ID=appLMmAjdVcRt8JnS
GOOGLE_DRIVE_BACKUP_FOLDER_ID=1AklZfuXdLriut4dybxViLnlgvraYt76W
```

Choose one Google credential source:

```text
GOOGLE_SERVICE_ACCOUNT_FILE=/path/to/service-account.json
# or
GOOGLE_SERVICE_ACCOUNT_JSON={...}
# or
GOOGLE_AUTHORIZED_USER_JSON={...}
```

A service account is preferred because it limits the Google principal used by the backup. Share only the backup folder with that identity.

Health defaults match the current Ledger:

```text
LEDGER_HEALTH_TABLE=State
LEDGER_HEALTH_KEY_FIELD=Key
LEDGER_HEALTH_KEY_VALUE=BACKUP_HEALTH
LEDGER_HEALTH_DATA_FIELD=State Data
```

## Install and verify

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e .
python -m unittest discover -s tests -v
ledger-backup run
```

A successful `run` means the Airtable export, local verification, Drive upload, Drive readback verification, health update/readback, and retention pass all completed.

## Restore validation

Every snapshot is ordinary JSON. `ledger-backup verify-local <snapshot-directory>` verifies checksums and record counts without needing Airtable or Drive.

A future restore command should create a new base rather than mutating the live Ledger in place. Destructive restore is intentionally not part of `run`.
