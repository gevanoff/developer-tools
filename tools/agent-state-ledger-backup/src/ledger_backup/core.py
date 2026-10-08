from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import requests


class BackupError(RuntimeError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip()).strip("-")
    return value or "table"


@dataclass(frozen=True)
class TableSnapshot:
    table_id: str
    table_name: str
    record_count: int
    sha256: str
    filename: str


class AirtableClient:
    def __init__(self, token: str, base_id: str, session: requests.Session | None = None):
        self.token = token
        self.base_id = base_id
        self.session = session or requests.Session()
        self.headers = {"Authorization": f"Bearer {token}"}

    def _get(self, url: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        response = self.session.get(url, headers=self.headers, params=params, timeout=60)
        if response.status_code >= 400:
            raise BackupError(f"Airtable GET failed {response.status_code}: {response.text[:500]}")
        return response.json()

    def _patch(self, url: str, payload: dict[str, Any]) -> dict[str, Any]:
        response = self.session.patch(
            url,
            headers={**self.headers, "Content-Type": "application/json"},
            json=payload,
            timeout=60,
        )
        if response.status_code >= 400:
            raise BackupError(f"Airtable PATCH failed {response.status_code}: {response.text[:500]}")
        return response.json()

    def discover_tables(self) -> list[dict[str, Any]]:
        payload = self._get(f"https://api.airtable.com/v0/meta/bases/{self.base_id}/tables")
        tables = payload.get("tables", [])
        if not tables:
            raise BackupError("Airtable metadata returned no tables")
        return sorted(tables, key=lambda table: table["id"])

    def list_records(self, table_id: str) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        offset: str | None = None
        while True:
            params: dict[str, Any] = {"pageSize": 100, "returnFieldsByFieldId": "true"}
            if offset:
                params["offset"] = offset
            payload = self._get(f"https://api.airtable.com/v0/{self.base_id}/{table_id}", params=params)
            records.extend(payload.get("records", []))
            offset = payload.get("offset")
            if not offset:
                break
        records.sort(key=lambda record: record["id"])
        return records

    def find_record_by_field(self, table_id_or_name: str, field_name: str, value: str) -> dict[str, Any] | None:
        offset: str | None = None
        while True:
            params: dict[str, Any] = {"pageSize": 100, "returnFieldsByFieldId": "false"}
            if offset:
                params["offset"] = offset
            payload = self._get(f"https://api.airtable.com/v0/{self.base_id}/{table_id_or_name}", params=params)
            for record in payload.get("records", []):
                if record.get("fields", {}).get(field_name) == value:
                    return record
            offset = payload.get("offset")
            if not offset:
                return None

    def update_record(self, table_id_or_name: str, record_id: str, fields: dict[str, Any]) -> dict[str, Any]:
        return self._patch(
            f"https://api.airtable.com/v0/{self.base_id}/{table_id_or_name}/{record_id}",
            {"fields": fields, "typecast": False},
        )


class DriveClient:
    def __init__(self, service):
        self.service = service

    @classmethod
    def from_environment(cls) -> "DriveClient":
        from google.oauth2 import service_account
        from google.oauth2.credentials import Credentials
        from googleapiclient.discovery import build

        scopes = ["https://www.googleapis.com/auth/drive"]
        sa_file = os.getenv("GOOGLE_SERVICE_ACCOUNT_FILE")
        sa_json = os.getenv("GOOGLE_SERVICE_ACCOUNT_JSON")
        oauth_json = os.getenv("GOOGLE_AUTHORIZED_USER_JSON")
        if sa_file:
            creds = service_account.Credentials.from_service_account_file(sa_file, scopes=scopes)
        elif sa_json:
            creds = service_account.Credentials.from_service_account_info(json.loads(sa_json), scopes=scopes)
        elif oauth_json:
            creds = Credentials.from_authorized_user_info(json.loads(oauth_json), scopes=scopes)
        else:
            raise BackupError(
                "Google credentials missing: set GOOGLE_SERVICE_ACCOUNT_FILE, "
                "GOOGLE_SERVICE_ACCOUNT_JSON, or GOOGLE_AUTHORIZED_USER_JSON"
            )
        return cls(build("drive", "v3", credentials=creds, cache_discovery=False))

    def create_folder(self, name: str, parent_id: str) -> str:
        result = self.service.files().create(
            body={"name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parent_id]},
            fields="id,name,parents",
        ).execute()
        return result["id"]

    def upload_file(self, path: Path, parent_id: str) -> str:
        from googleapiclient.http import MediaFileUpload

        result = self.service.files().create(
            body={"name": path.name, "parents": [parent_id]},
            media_body=MediaFileUpload(str(path), mimetype="application/json", resumable=False),
            fields="id,name,size,md5Checksum,parents",
        ).execute()
        return result["id"]

    def download_bytes(self, file_id: str) -> bytes:
        return self.service.files().get_media(fileId=file_id).execute()

    def rename(self, file_id: str, name: str) -> None:
        self.service.files().update(fileId=file_id, body={"name": name}, fields="id,name").execute()

    def metadata(self, file_id: str) -> dict[str, Any]:
        return self.service.files().get(
            fileId=file_id,
            fields="id,name,parents,trashed",
        ).execute()

    def delete(self, file_id: str) -> None:
        self.service.files().delete(fileId=file_id).execute()

    def list_snapshot_folders(self, parent_id: str) -> list[dict[str, Any]]:
        query = (
            f"'{parent_id}' in parents and trashed=false and "
            "mimeType='application/vnd.google-apps.folder'"
        )
        files: list[dict[str, Any]] = []
        page_token: str | None = None
        while True:
            response = self.service.files().list(
                q=query,
                fields="nextPageToken,files(id,name,createdTime)",
                pageToken=page_token,
                pageSize=1000,
            ).execute()
            files.extend(response.get("files", []))
            page_token = response.get("nextPageToken")
            if not page_token:
                return files


class HealthReporter:
    def __init__(self, airtable: AirtableClient):
        self.airtable = airtable
        self.table = os.getenv("LEDGER_HEALTH_TABLE", "State")
        self.key_field = os.getenv("LEDGER_HEALTH_KEY_FIELD", "Key")
        self.key_value = os.getenv("LEDGER_HEALTH_KEY_VALUE", "BACKUP_HEALTH")
        self.data_field = os.getenv("LEDGER_HEALTH_DATA_FIELD", "State Data")

    def _load(self) -> tuple[str, dict[str, Any]]:
        record = self.airtable.find_record_by_field(self.table, self.key_field, self.key_value)
        if not record:
            raise BackupError(f"Could not find {self.table}.{self.key_field}={self.key_value}")
        raw = record.get("fields", {}).get(self.data_field, "{}") or "{}"
        try:
            state = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise BackupError(f"Health record contains invalid JSON: {exc}") from exc
        return record["id"], state

    def _write_verified(self, record_id: str, state: dict[str, Any]) -> None:
        serialized = json.dumps(state, ensure_ascii=False, sort_keys=True, indent=2)
        self.airtable.update_record(self.table, record_id, {self.data_field: serialized})
        readback = self.airtable.find_record_by_field(self.table, self.key_field, self.key_value)
        if not readback:
            raise BackupError("Health readback failed: record disappeared")
        actual = readback.get("fields", {}).get(self.data_field, "")
        if actual != serialized:
            raise BackupError("Health readback mismatch")

    def mark_attempt(self, captured_at: str) -> None:
        record_id, state = self._load()
        backup = state.setdefault("backup_system", {})
        backup["last_attempt"] = {"captured_at": captured_at, "status": "IN_PROGRESS"}
        self._write_verified(record_id, state)

    def mark_success(self, payload: dict[str, Any]) -> None:
        record_id, state = self._load()
        backup = state.setdefault("backup_system", {})
        backup["last_attempt"] = {"captured_at": payload["captured_at"], "status": "PASS"}
        backup["last_success"] = payload
        backup["last_failure"] = None
        backup["transport"] = {
            "mode": "deterministic JSON files uploaded to Google Drive",
            "rule": "Airtable values are serialized as opaque data and never executed.",
            "sequence": (
                "discover -> export -> hash -> upload staging -> Drive readback/hash -> "
                "manifest -> rename staging -> health readback -> retention"
            ),
            "orchestration_guard": (
                "last_success is updated only after every uploaded object verifies by Drive readback"
            ),
        }
        self._write_verified(record_id, state)

    def mark_failure(self, captured_at: str, stage: str, error: str) -> None:
        record_id, state = self._load()
        backup = state.setdefault("backup_system", {})
        failure = {
            "captured_at": captured_at,
            "failed_at": datetime.now(timezone.utc).isoformat(),
            "stage": stage,
            "error": error[:2000],
        }
        backup["last_attempt"] = {"captured_at": captured_at, "status": "FAIL"}
        backup["last_failure"] = failure
        self._write_verified(record_id, state)


def export_snapshot(airtable: AirtableClient, directory: Path, captured_at: str) -> dict[str, Any]:
    directory.mkdir(parents=True, exist_ok=False)
    table_dir = directory / "tables"
    table_dir.mkdir()
    tables = airtable.discover_tables()
    snapshots: list[TableSnapshot] = []
    total_records = 0
    for table in tables:
        records = sorted(airtable.list_records(table["id"]), key=lambda record: record["id"])
        payload = {
            "schema_version": 1,
            "captured_at": captured_at,
            "table": table,
            "records": records,
        }
        data = canonical_bytes(payload)
        filename = f"{safe_name(table['name'])}--{table['id']}.json"
        (table_dir / filename).write_bytes(data)
        digest = sha256_bytes(data)
        snapshots.append(
            TableSnapshot(table["id"], table["name"], len(records), digest, f"tables/{filename}")
        )
        total_records += len(records)

    aggregate_material = (
        "\n".join(
            f"{item.table_id}:{item.sha256}"
            for item in sorted(snapshots, key=lambda item: item.table_id)
        )
        + "\n"
    )
    aggregate_sha256 = sha256_bytes(aggregate_material.encode("utf-8"))
    manifest = {
        "schema_version": 1,
        "captured_at": captured_at,
        "base_id": airtable.base_id,
        "table_count": len(snapshots),
        "record_count": total_records,
        "hash_algorithm": "SHA-256",
        "aggregate_rule": "SHA256(LF-joined sorted table_id:table_sha256 lines, including final LF)",
        "aggregate_sha256": aggregate_sha256,
        "tables": [item.__dict__ for item in snapshots],
    }
    (directory / "manifest.json").write_bytes(canonical_bytes(manifest))
    return manifest


def verify_local_snapshot(directory: Path) -> dict[str, Any]:
    manifest = json.loads((directory / "manifest.json").read_text("utf-8"))
    lines: list[str] = []
    count = 0
    for table in manifest["tables"]:
        data = (directory / table["filename"]).read_bytes()
        digest = sha256_bytes(data)
        if digest != table["sha256"]:
            raise BackupError(f"Local checksum mismatch: {table['filename']}")
        payload = json.loads(data)
        if payload["table"]["id"] != table["table_id"]:
            raise BackupError(f"Local identity mismatch: {table['filename']}")
        if len(payload["records"]) != table["record_count"]:
            raise BackupError(f"Local record count mismatch: {table['filename']}")
        count += len(payload["records"])
        lines.append(f"{table['table_id']}:{digest}")
    aggregate = sha256_bytes(("\n".join(sorted(lines)) + "\n").encode("utf-8"))
    if aggregate != manifest["aggregate_sha256"]:
        raise BackupError("Local aggregate checksum mismatch")
    if count != manifest["record_count"]:
        raise BackupError("Local aggregate record count mismatch")
    return manifest


def upload_verified_snapshot(
    drive: DriveClient,
    directory: Path,
    root_folder_id: str,
    final_name: str,
) -> tuple[str, dict[str, str]]:
    staging_name = f".partial-{final_name}"
    folder_id = drive.create_folder(staging_name, root_folder_id)
    uploaded: dict[str, str] = {}
    try:
        manifest = json.loads((directory / "manifest.json").read_text("utf-8"))
        for table in manifest["tables"]:
            path = directory / table["filename"]
            file_id = drive.upload_file(path, folder_id)
            readback = drive.download_bytes(file_id)
            if sha256_bytes(readback) != table["sha256"]:
                raise BackupError(f"Drive readback checksum mismatch: {path.name}")
            uploaded[table["filename"]] = file_id
        manifest_path = directory / "manifest.json"
        manifest_id = drive.upload_file(manifest_path, folder_id)
        if sha256_bytes(drive.download_bytes(manifest_id)) != sha256_bytes(manifest_path.read_bytes()):
            raise BackupError("Drive manifest readback checksum mismatch")
        uploaded["manifest.json"] = manifest_id
        drive.rename(folder_id, final_name)
        folder = drive.metadata(folder_id)
        if folder.get("name") != final_name or root_folder_id not in folder.get("parents", []):
            raise BackupError("Drive snapshot folder rename/parent readback mismatch")
        return folder_id, uploaded
    except Exception:
        # Keep the partial folder for diagnosis; its name makes it ineligible for retention pruning.
        raise


def _parse_snapshot_name(name: str) -> datetime | None:
    match = re.fullmatch(r"ledger-(\d{8}T\d{6}Z)", name)
    if not match:
        return None
    return datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


def retention_plan(folders: Iterable[dict[str, Any]], now: datetime) -> list[str]:
    parsed: list[tuple[datetime, str]] = []
    for folder in folders:
        dt = _parse_snapshot_name(folder.get("name", ""))
        if dt:
            parsed.append((dt, folder["id"]))
    parsed.sort(reverse=True)
    keep: set[str] = set()
    seen_weeks: set[tuple[int, int]] = set()
    seen_months: set[tuple[int, int]] = set()
    for dt, file_id in parsed:
        age_days = (now - dt).total_seconds() / 86400
        if age_days <= 30:
            keep.add(file_id)
        elif age_days <= 84:
            year, week, _ = dt.isocalendar()
            key = (year, week)
            if key not in seen_weeks:
                seen_weeks.add(key)
                keep.add(file_id)
        else:
            key = (dt.year, dt.month)
            if key not in seen_months:
                seen_months.add(key)
                keep.add(file_id)
    if parsed:
        keep.add(parsed[0][1])
    return [file_id for _dt, file_id in parsed if file_id not in keep]


def run_backup() -> dict[str, Any]:
    token = os.environ["AIRTABLE_TOKEN"]
    base_id = os.environ["AIRTABLE_BASE_ID"]
    root_folder = os.environ["GOOGLE_DRIVE_BACKUP_FOLDER_ID"]
    airtable = AirtableClient(token, base_id)
    drive = DriveClient.from_environment()
    health = HealthReporter(airtable)
    captured = datetime.now(timezone.utc)
    captured_at = captured.isoformat()
    name = "ledger-" + captured.strftime("%Y%m%dT%H%M%SZ")
    stage = "health_attempt"
    try:
        health.mark_attempt(captured_at)
        stage = "export"
        with tempfile.TemporaryDirectory(prefix="ledger-backup-") as tmp:
            directory = Path(tmp) / name
            manifest = export_snapshot(airtable, directory, captured_at)
            stage = "local_verify"
            verify_local_snapshot(directory)
            stage = "drive_upload_verify"
            folder_id, uploaded = upload_verified_snapshot(drive, directory, root_folder, name)
        stage = "health_success"
        success = {
            "captured_at": captured_at,
            "verified_at": datetime.now(timezone.utc).isoformat(),
            "snapshot_folder_id": folder_id,
            "table_count": manifest["table_count"],
            "record_count": manifest["record_count"],
            "aggregate_sha256": manifest["aggregate_sha256"],
            "verification_status": "PASS",
            "manifest_file_id": uploaded["manifest.json"],
        }
        health.mark_success(success)
        stage = "retention"
        for file_id in retention_plan(
            drive.list_snapshot_folders(root_folder),
            datetime.now(timezone.utc),
        ):
            drive.delete(file_id)
        return success
    except Exception as exc:
        try:
            health.mark_failure(captured_at, stage, f"{type(exc).__name__}: {exc}")
        except Exception as health_exc:
            raise BackupError(
                f"backup failed at {stage}: {exc}; additionally failed to persist health: {health_exc}"
            ) from exc
        raise
