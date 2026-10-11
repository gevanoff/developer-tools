# Codex Usage Meter

A small floating Windows panel for your signed-in Codex allowance. Collapse it into the system tray and bring it back with a click.

## Requirements

- Windows 11 and Windows PowerShell 5.1 (included with Windows).
- Node.js 22 or later on `PATH`; no npm packages are required.
- A current native `codex.exe` on `PATH`, signed in with your ChatGPT account. The Codex desktop installation on the development machine provides this executable. An npm `codex.cmd` shim alone is not sufficient; use the actual Windows executable with `-CodexPath` if necessary.

This tool requires the Codex app-server `account/rateLimits/read` interface. It is independent of the desktop UI but depends on your installed Codex version and its sign-in. API-key-only authentication does not provide a ChatGPT subscription allowance.

## Run

1. Download or clone this repository and keep this tool's files together.
2. Confirm `node --version` and `codex.exe --version` work in PowerShell, and sign in to Codex normally.
3. Double-click **Launch.vbs**. If Windows Script Host is unavailable, run:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexMeter.ps1
```

For an executable outside `PATH`:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexMeter.ps1 -CodexPath "C:\path with spaces\codex.exe"
```

The execution-policy option applies to this process only. No administrator access, installation, scheduled AI task, or startup registration is required. If downloaded files are blocked, inspect them and use Windows file Properties > Unblock where available; organizational policy can still prevent running scripts.

## Controls and readings

The remaining bar, top window accent, and tray icon share a status color: green above 50%, yellow above 25% through 50%, orange above 10% through 25%, and red at 10% or less. Blocked included usage is red; stale or unavailable data is gray. Percentages and status text remain visible so color is not the only signal.

Right-click the panel or tray icon and select **Panel size**: **Mini** (300x225), **Compact** (310x285), **Standard** (330x350), or **Large** (430x420), measured in client pixels before Windows scaling. Each preset adjusts type sizes and spacing. Mini hides the bottom buttons; refresh, restore, and quit remain available in the context menu. The panel starts in Standard; the selection is not persisted. The colored accent is inside the window; Windows continues to draw the native title bar.

- Drag the title bar to move the panel.
- **To tray** or **X** hides it; left-click the tray icon to restore it. Windows may place the icon in the hidden-icons menu.
- Right-click the icon for **Show allowance**, **Refresh now**, **Always on top**, or **Quit**.
- **Dashboard** opens the official account usage page.
- A second normal launch exits to avoid duplicate polling. Restore the existing panel from the tray.

The panel shows the remaining percentage, countdown to each reported automatic reset, available reset count, and last successful refresh. When two allowance windows apply, the headline uses the lower remaining percentage. Available resets are separate from the scheduled automatic reset; the meter never consumes one.

It refreshes every five minutes even while hidden. Failed updates retain the previous reading with a stale warning. Missing values are shown as unknown rather than zero. An expired countdown waits for a server refresh instead of assuming that your allowance has reset. A server-reported block is displayed even if a percentage remains positive.

## Usage cost and privacy

Refreshes initialize a local Codex app-server and call only `account/rateLimits/read`. They do not start a thread or model turn, make inference requests, purchase credits, or consume resets. There is no AI usage from the meter's polling code; it still uses ordinary network and computer resources. Building or asking an AI to operate the meter is separate from its own refreshes.

The existing Codex installation manages credentials and its normal local state. This tool does not read or copy token files. It does not save usage history or account IDs and does not send data to a third-party server. The reader discards backend diagnostic text rather than writing it to logs, allowlists the numeric window fields it returns, and rejects oversized or unsafe responses. Use trusted Node.js and Codex installations and keep their PATH entries under your control; the reader executes those local programs with your user permissions.

The [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server) describes the underlying interface. It may change with Codex updates. If an older app-server rejects the newer read options with an invalid-request or invalid-params error, the reader retries once with null parameters. Versions supporting the read method can still show allowance while missing reset details appear as “Not reported.” Versions without that method report usage as unavailable. This is a community utility, not an official OpenAI product.

## Validation

No account, credentials, npm install, or model calls are needed for offline tests:

```powershell
node --test tests/read-usage.test.mjs
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexMeter.ps1 -SelfTest
```

Tests exercise the real stdio transport with a fake child process, paths containing spaces, missing executable, timeouts, early exit, malformed/error responses, legacy-option fallback, bounded output, numeric validation, nested account-data filtering, multiple windows, unknown values, stale/blocked status, expired countdowns, and collapse/restore. The Windows CI workflow runs these tests.

Optional authenticated check (one read; opens and then closes the test panel):

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexMeter.ps1 -LiveTest
```

This prints displayed readings to the console and does not save them. Offline UI tests can optionally save a simulated preview with `-PreviewPath`; do not publish screenshots containing private data. Tests do not establish compatibility with every Windows display scaling setting or future Codex release.
