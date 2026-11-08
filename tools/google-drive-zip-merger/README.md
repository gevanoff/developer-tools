# Google Drive ZIP Merger

Google Drive splits large folder downloads into multiple ZIP archives. This utility lets you select the folder containing those ZIP files, choose the final destination, and extract all archives directly into one merged directory tree.

## Requirements

- Windows 11
- Windows PowerShell 5.1 or later
- No third-party dependencies

## Use

1. Double-click `Merge-GoogleDriveZips.bat`, or drag the folder that holds the Google Drive `.zip` files onto it.
2. **ZIP folder:** choose the folder with the ZIP files (filled in when you drag a folder). The window shows how many ZIP files it found, their size, and how many files they contain.
3. **Destination:** choose where the merged files should go. Before anything is written, the window checks every archive and tells you:
   - how many files already exist there and will be replaced;
   - how many paths appear in more than one ZIP (the later ZIP's copy is kept);
   - whether any archive path would land outside the destination, in which case **Merge** stays disabled.
4. Click **Merge**. A progress bar, the current ZIP, and file and replacement counts update as it runs; the log lists every replaced file. **Stop** finishes the current file and stops.
5. When it finishes, the result appears in the window. **Open Destination** opens the merged folder. **Delete Original ZIPs...** appears only after every ZIP was extracted, and asks before permanently deleting them.

Dragging a folder into an already-open console window is not supported; drag the folder onto the `.bat` file itself.

## Behavior

The tool:

- finds `.zip` files directly inside the source folder and processes them in filename order;
- extracts every archive directly into the selected destination, preserving the folder paths stored in the ZIPs and creating folders as needed;
- checks every archive path before writing anything and refuses archives with paths that would escape the destination;
- replaces a file that already exists at the same path, and lists each replacement in the log;
- keeps the window responsive while extracting, and can stop after the current file;
- never deletes the ZIP files unless every ZIP was extracted and you confirm;
- exits with code 0 after a completed merge (or when closed without merging) and 1 after a failed or stopped merge.

### Existing files

If a ZIP contains a path that already exists in the destination, the version being extracted replaces it. The destination check shows how many files will be replaced before you start, and the log lists them as they are replaced. Consider this when merging into a folder that already contains data.

## Files

- `Merge-GoogleDriveZips.bat` — double-click and drag-and-drop Windows launcher.
- `Merge-GoogleDriveZips.ps1` — the window: folder selection, destination check, progress, result, and cleanup.
- `ZipMergeEngine.ps1` — planning, extraction, stop, and cleanup, with no user interface.
- `Test-MergeGoogleDriveZips.ps1` — checks the engine in temporary folders with spaces in their names; on Windows it also runs a merge through the window. Run by `scripts/check-windows.ps1`.

## Command-line use

The window can be opened with either folder filled in:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
    -File .\Merge-GoogleDriveZips.ps1 `
    -Source "C:\Users\Example\Downloads\DriveDownload" `
    -Destination "D:\Drive export"
```

Merging still starts only when you click **Merge**.

## Possible future improvements

- Skip byte-identical duplicate files instead of rewriting them.
- Detect same-path files with different contents as explicit conflicts.
- Add recursive ZIP discovery when downloads are spread across subdirectories.
