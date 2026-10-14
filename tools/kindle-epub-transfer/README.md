# Kindle EPUB Transfer

Windows 11 utility for copying purchased Kindle books into an isolated Calibre
library, converting readable imports to EPUB, and keeping a per-book result manifest.
Original Kindle files are read only. KFX companion files remain together.

## Requirements and setup

- Python 3.11+ and Calibre (default `C:/Program Files/Calibre2`).
- A dedicated Calibre configuration directory with the necessary import plugins
  installed and configured. This utility does not install plugins, extract keys,
  modify firmware, or change the normal Calibre library/profile.
- For encrypted Kindle books, a compatible and configured DeDRM plugin. Modern
  KFX support varies by the file's DRM revision; a device model is not a guarantee.
- [KFX Input](https://www.mobileread.com/forums/showthread.php?t=291290) for KFX.
  Follow its current instructions and the linked
  [DeDRM project](https://github.com/Satsuoni/DeDRM_tools). Pin and inspect downloaded
  plugins before installing. They execute code inside Calibre.

Set `CALIBRE_CONFIG_DIRECTORY` to your dedicated profile before running
`calibre-customize -a <plugin.zip>`. Configure the Kindle serial locally in that
profile's `plugins/dedrm.json` (`serials` list). Never commit that profile or books.
The converter sets the profile environment only for its child processes.

Copy `settings.example.json` to ignored `settings.local.json`, change the source,
state and profile paths, then double-click `Convert-KindleBooks.bat`. State must be
outside the source tree. A full run may need several times the source book size.
Keep state somewhere persistent and private: it contains original snapshots,
working Calibre libraries, EPUBs, logs, and the manifest.

## Commands

```powershell
python .\kindle_transfer.py scan --source D:/documents
python .\kindle_transfer.py convert --source D:/documents --state C:/Books/Transfer --calibre-config C:/Books/CalibreProfile
# First-book test or a targeted retry:
python .\kindle_transfer.py convert --source D:/documents --state C:/Books/Transfer --calibre-config C:/Books/CalibreProfile --match "Auberon" --limit 1
# Separate action: copy verified outputs to an existing local Drive sync folder.
python .\kindle_transfer.py publish --state C:/Books/Transfer --destination "G:/My Drive/Books"
```

`Run-KindleTransfer.ps1 -Action scan|convert|publish` uses the local settings file.
The double-click launcher converts locally; it does not silently upload books.

For unattended cloud sync, configure Google Drive for desktop and set `destination`
to the actual local Books folder. Run `publish` after conversion. A successful copy
means a local file exists; it does not prove Drive has finished uploading or that
the reader has downloaded it. A connected Drive tool can alternatively upload the
`ready` entries in `manifest.json` and record remote IDs in a separate local receipt.
The ChatGPT Drive connection is not an OAuth credential available to this script.

## Behavior and validation boundaries

- Recursively identifies primary books, ignoring files inside `.sdr` bundles and
  built-in guides/dictionaries/personal messages. Conversion matches filenames.
- Copies each book with its `.sdr` directory and any `.azw6` companion into a fresh
  job directory. Checks source and snapshot hashes to detect incomplete copies.
- Imports through Calibre before conversion, so configured import plugins run.
  A `.kfx-zip` import is treated as failure, not as a readable book.
- When an AZW3 conversion contains image placeholders and has one AZW6 companion,
  restores JPEG-XR page images only if the container's embed map and every EPUB
  placeholder match exactly. Uses Calibre's image codec, preserves dimensions,
  and encodes JPEG at quality 95. Unknown mappings fail rather than guessing.
- Verifies ZIP CRCs, EPUB mimetype, package/manifest resources, nonempty reading
  order, spine XML, image references, unresolved placeholders, and absence of
  content encryption. Font obfuscation is allowed.
  This is structural validation, not full EPUBCheck or proof of visual fidelity.
  Missing illustrations already absent from the source cannot be detected reliably.
- Output names include a content hash. Repeated identical copies are skipped;
  existing different files are never overwritten. Verified unchanged conversions
  are skipped. A changed source produces a separate version.
- `manifest.json` records ready/failed entries and SHA-256 checksums. A failed retry
  is not eligible for publication; old local outputs are preserved for inspection.
- Individual failures do not prevent remaining books from being attempted. Any
  conversion failure returns exit code 1. Nothing deletes source books or Drive files.
- One conversion run per state folder. A crash can leave `run.lock`; remove it only
  after confirming the recorded process is no longer running. Each Calibre command
  has a ten-minute timeout. Close other Calibre CLI writers if they hold its lock.
- Logs redact configured Kindle serials; logs and state can still contain book
  titles and identifiers. They should remain private.
- Folder publication uses an atomic, non-overwriting Windows rename. The sync
  destination must support ordinary same-directory file renames.

## Tests

```powershell
python -m unittest discover -s tools/kindle-epub-transfer -p "test_*.py" -v
```

Tests cover corrupted/encrypted EPUBs, missing content, companion grouping,
path traversal, AZW6 index matching, duplicate publication and collision preservation. Qualify the
installed plugin/device combination with a real purchased book before a batch.
