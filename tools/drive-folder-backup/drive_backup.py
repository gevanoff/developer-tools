"""Windows Tk desktop UI for safe, incremental rclone copies to Google Drive."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import os
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import uuid

from backup_core import (
    BackupError, canonical_source, copy_command, destination, discover_drive_remotes,
    load_settings, resolve_rclone, save_settings, state_directory, validate_root,
)


class BackupWindow:
    def __init__(self, window: tk.Tk):
        self.window = window
        self.config_path = state_directory() / "settings.json"
        self.settings = load_settings(self.config_path)
        self.rclone = resolve_rclone()
        self.remotes: list[str] = []
        self.events: queue.Queue[tuple[str, object]] = queue.Queue(maxsize=2500)
        self.dropped_lines = 0
        self.stop_requested = threading.Event()
        self.worker: threading.Thread | None = None
        self.process: subprocess.Popen | None = None
        self.close_requested = False

        window.title("Drive Folder Backup")
        window.geometry("780x590")
        window.minsize(580, 430)
        window.columnconfigure(0, weight=1)
        window.rowconfigure(1, weight=1)
        window.protocol("WM_DELETE_WINDOW", self.close)

        top = ttk.Frame(window, padding=12)
        top.grid(row=0, column=0, sticky="ew")
        top.columnconfigure(1, weight=1)
        ttk.Label(top, text="Google Drive remote").grid(row=0, column=0, sticky="w")
        self.remote_var = tk.StringVar(value=self.settings["remote"])
        self.remote_combo = ttk.Combobox(top, textvariable=self.remote_var, state="readonly")
        self.remote_combo.grid(row=0, column=1, sticky="ew", padx=8)
        self.remote_combo.bind("<<ComboboxSelected>>", lambda _: self.update_preview())
        self.refresh_btn = ttk.Button(top, text="Refresh", command=self.refresh_remotes)
        self.refresh_btn.grid(row=0, column=2)
        self.config_btn = ttk.Button(top, text="Configure...", command=self.configure)
        self.config_btn.grid(row=0, column=3, padx=(8, 0))
        ttk.Label(top, text="Destination folder").grid(row=1, column=0, sticky="w", pady=(8, 0))
        self.root_var = tk.StringVar(value=self.settings["root"])
        self.root_entry = ttk.Entry(top, textvariable=self.root_var)
        self.root_entry.grid(row=1, column=1, columnspan=3, sticky="ew", padx=(8, 0), pady=(8, 0))
        self.root_var.trace_add("write", lambda *_: self.update_preview())

        body = ttk.LabelFrame(window, text="Folders to back up", padding=10)
        body.grid(row=1, column=0, sticky="nsew", padx=12)
        body.columnconfigure(0, weight=1)
        body.rowconfigure(0, weight=1)
        self.sources = tk.Listbox(body, exportselection=False, selectmode=tk.EXTENDED)
        self.sources.grid(row=0, column=0, sticky="nsew")
        self.sources.bind("<<ListboxSelect>>", lambda _: self.update_preview())
        scrollbar = ttk.Scrollbar(body, orient="vertical", command=self.sources.yview)
        scrollbar.grid(row=0, column=1, sticky="ns")
        self.sources.configure(yscrollcommand=scrollbar.set)
        for item in self.settings["sources"]:
            self.sources.insert(tk.END, item)
        actions = ttk.Frame(body)
        actions.grid(row=1, column=0, columnspan=2, sticky="w", pady=(8, 0))
        self.add_btn = ttk.Button(actions, text="Add Folder...", command=self.add_folder)
        self.add_btn.pack(side="left")
        self.remove_btn = ttk.Button(actions, text="Remove Selected", command=self.remove_selected)
        self.remove_btn.pack(side="left", padx=8)
        self.preview_var = tk.StringVar(value="Select a folder to see its destination.")
        ttk.Label(body, textvariable=self.preview_var, wraplength=700).grid(
            row=2, column=0, columnspan=2, sticky="w", pady=(8, 0))

        footer = ttk.Frame(window, padding=12)
        footer.grid(row=2, column=0, sticky="ew")
        self.preview_btn = ttk.Button(footer, text="Preview (no changes)", command=lambda: self.start(True))
        self.preview_btn.pack(side="left")
        self.backup_btn = ttk.Button(footer, text="Back Up Now", command=lambda: self.start(False))
        self.backup_btn.pack(side="left", padx=8)
        self.cancel_btn = ttk.Button(footer, text="Cancel", command=self.cancel, state="disabled")
        self.cancel_btn.pack(side="left")
        self.status_var = tk.StringVar(value="Ready")
        ttk.Label(footer, textvariable=self.status_var).pack(side="right")

        output = ttk.LabelFrame(window, text="Operation log", padding=8)
        output.grid(row=3, column=0, sticky="nsew", padx=12, pady=(0, 12))
        window.rowconfigure(3, weight=1)
        output.columnconfigure(0, weight=1)
        output.rowconfigure(0, weight=1)
        self.log = tk.Text(output, height=10, wrap="word", state="disabled")
        self.log.grid(row=0, column=0, sticky="nsew")
        log_scroll = ttk.Scrollbar(output, command=self.log.yview)
        log_scroll.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=log_scroll.set)
        self.refresh_remotes()
        self.window.after(100, self.poll)

    def append_log(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", text.rstrip("\r\n") + "\n")
        if int(self.log.index("end-1c").split(".")[0]) > 1800:
            self.log.delete("1.0", "500.0")
        self.log.see("end")
        self.log.configure(state="disabled")

    def persist(self) -> None:
        self.settings["sources"] = list(self.sources.get(0, tk.END))
        self.settings["remote"] = self.remote_var.get()
        self.settings["root"] = self.root_var.get()
        save_settings(self.config_path, self.settings)

    def add_folder(self) -> None:
        path = filedialog.askdirectory(parent=self.window, mustexist=True)
        if not path:
            return
        path = canonical_source(path)
        if path in self.sources.get(0, tk.END):
            return
        self.sources.insert(tk.END, path)
        try:
            self.persist()
        except OSError as exc:
            messagebox.showerror("Settings not saved", str(exc), parent=self.window)
        self.update_preview()

    def remove_selected(self) -> None:
        for index in reversed(self.sources.curselection()):
            self.sources.delete(index)
        try:
            self.persist()
        except OSError as exc:
            messagebox.showerror("Settings not saved", str(exc), parent=self.window)
        self.update_preview()

    def refresh_remotes(self) -> None:
        try:
            self.remotes = discover_drive_remotes(self.rclone)
        except BackupError as exc:
            self.remotes = []
            self.append_log(str(exc))
        self.remote_combo["values"] = self.remotes
        if not self.remote_var.get() and len(self.remotes) == 1:
            self.remote_var.set(self.remotes[0])
        self.update_preview()

    def configure(self) -> None:
        try:
            flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
            subprocess.Popen([self.rclone, "config"], creationflags=flags)
            self.append_log("Finish the rclone configuration, then click Refresh.")
        except OSError as exc:
            messagebox.showerror("Cannot open rclone", str(exc), parent=self.window)

    def update_preview(self) -> None:
        indices = self.sources.curselection()
        if not indices:
            self.preview_var.set("Each folder gets a stable, distinct destination; no remote deletions.")
            return
        try:
            self.preview_var.set(destination(self.remote_var.get(), self.root_var.get(),
                                             self.settings["computer"], self.sources.get(indices[0])))
        except BackupError:
            self.preview_var.set("Choose a Drive remote and a valid destination folder.")

    def set_running(self, busy: bool) -> None:
        state = "disabled" if busy else "normal"
        for button in (self.add_btn, self.remove_btn, self.config_btn, self.refresh_btn,
                       self.preview_btn, self.backup_btn):
            button.configure(state=state)
        self.remote_combo.configure(state="disabled" if busy else "readonly")
        self.root_entry.configure(state=state)
        self.cancel_btn.configure(state="normal" if busy else "disabled")

    def start(self, dry_run: bool) -> None:
        if self.worker is not None:
            return
        folders = list(self.sources.get(0, tk.END))
        try:
            if not folders:
                raise BackupError("Add at least one folder.")
            if self.remote_var.get() not in self.remotes:
                raise BackupError("Choose a configured Google Drive remote and click Refresh if needed.")
            validate_root(self.root_var.get())
            self.persist()
        except (BackupError, OSError) as exc:
            messagebox.showerror("Cannot start", str(exc), parent=self.window)
            return
        self.stop_requested.clear()
        self.dropped_lines = 0
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        log_path = state_directory() / "logs" / f"{stamp}-{uuid.uuid4().hex[:8]}.log"
        self.set_running(True)
        self.status_var.set("Previewing..." if dry_run else "Backing up...")
        self.append_log(f"{'PREVIEW' if dry_run else 'BACKUP'} | log: {log_path}")
        self.worker = threading.Thread(
            target=self.run_backup,
            args=(folders, self.remote_var.get(), self.root_var.get(),
                  self.settings["computer"], dry_run, log_path), daemon=True,
        )
        self.worker.start()

    def run_backup(self, folders: list[str], remote: str, root: str, computer: str,
                   dry_run: bool, log_path: Path) -> None:
        failures = 0
        completed = 0
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("w", encoding="utf-8") as log:
                for index, folder in enumerate(folders, start=1):
                    if self.stop_requested.is_set():
                        break
                    def emit(line: str) -> None:
                        log.write(line.rstrip("\r\n") + "\n")
                        log.flush()
                        try:
                            self.events.put_nowait(("log", line))
                        except queue.Full:
                            self.dropped_lines += 1
                    emit(f"[{index}/{len(folders)}] {folder}")
                    if not Path(folder).is_dir():
                        failures += 1
                        emit("ERROR: Source no longer exists or is not a directory; skipped.")
                        continue
                    target = destination(remote, root, computer, folder)
                    emit(f"Target: {target}")
                    argv = copy_command(self.rclone, folder, target, dry_run)
                    try:
                        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
                        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                                   stdin=subprocess.DEVNULL, text=True, encoding="utf-8",
                                                   errors="replace", bufsize=1, creationflags=flags)
                        self.process = process
                        if self.stop_requested.is_set():
                            process.terminate()
                        assert process.stdout is not None
                        for line in process.stdout:
                            emit(line)
                        rc = process.wait()
                        if rc:
                            failures += 1
                            emit(f"ERROR: rclone exited {rc} for {folder}")
                        else:
                            completed += 1
                    except OSError as exc:
                        failures += 1
                        emit(f"ERROR: Could not start rclone: {exc}")
                    finally:
                        self.process = None
                state = "Cancelled" if self.stop_requested.is_set() else (
                    "Failed" if failures else ("Preview complete" if dry_run else "Backup complete"))
                emit(f"{state}: {completed} successful, {failures} failed; {len(folders)} selected.")
                if self.dropped_lines:
                    note = f"{self.dropped_lines} lines omitted from the live display; full log: {log_path}"
                    log.write(note + "\n")
                    self.events.put(("log", note))
            self.events.put(("done", state))
        except Exception as exc:
            self.events.put(("log", f"ERROR: {type(exc).__name__}: {exc}"))
            self.events.put(("done", "Failed"))

    def cancel(self) -> None:
        self.stop_requested.set()
        self.status_var.set("Cancelling...")
        proc = self.process
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass

    def poll(self) -> None:
        try:
            for _ in range(150):
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self.append_log(str(payload))
                elif kind == "done":
                    self.worker = None
                    self.status_var.set(str(payload))
                    self.set_running(False)
                    if self.close_requested:
                        self.window.destroy()
                        return
        except queue.Empty:
            pass
        self.window.after(100, self.poll)

    def close(self) -> None:
        if self.worker is None:
            self.window.destroy()
        elif messagebox.askyesno("Cancel backup?", "Stop the active transfer and close?", parent=self.window):
            self.close_requested = True
            self.cancel()


def main() -> int:
    root = tk.Tk()
    try:
        BackupWindow(root)
    except BackupError as exc:
        messagebox.showerror("Drive Folder Backup", str(exc), parent=root)
        root.destroy()
        return 1
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
