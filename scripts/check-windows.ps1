# PowerShell 5.1+ / Windows; run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-windows.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Assert-Exit([string]$Label) {
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE)" }
}
Push-Location $root
try {
    # Match the explicit Windows workflow runtimes, rather than testing whatever
    # node/python happens to be first on PATH and reporting a misleading pass.
    $nodeVersion = (& node --version)
    Assert-Exit 'Node version probe'
    if ($nodeVersion -notmatch '^v22[.]') {
        throw "Node 22 required for Windows validation; found: $nodeVersion"
    }
    $pythonVersion = (& python --version)
    Assert-Exit 'Python version probe'
    if ($pythonVersion -notmatch '^Python 3[.]11([.]|$)') {
        throw "Python 3.11 required for Windows validation; found: $pythonVersion"
    }
    Push-Location (Join-Path $root 'tools/DroidRun')
    try {
        & ./Test-DroidRunPresentation.ps1
        Assert-Exit 'DroidRun presentation'
        & ./Test-DroidRunProjects.ps1
        Assert-Exit 'DroidRun projects'
        & ./Test-AndroidBuildBackends.ps1
        Assert-Exit 'DroidRun backends'
        & ./Test-AndroidBuildInstall.ps1
        Assert-Exit 'DroidRun install'
    } finally { Pop-Location }
    Push-Location (Join-Path $root 'tools/codex-usage-meter')
    try {
        & node --test tests/read-usage.test.mjs
        Assert-Exit 'Codex usage Node tests'
        # PR #29 adds this recovery contract. Replacing its GitHub Actions
        # workflow must not silently discard executable upgrade/retry coverage.
        $recoveryTest = Join-Path (Get-Location).Path 'tests/recovery.test.ps1'
        if (-not (Test-Path -LiteralPath $recoveryTest -PathType Leaf)) {
            throw "Required Codex meter recovery regression missing: $recoveryTest"
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recoveryTest
        Assert-Exit 'Codex meter recovery tests'
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ./CodexMeter.ps1 -SelfTest
        Assert-Exit 'Codex meter self test'
    } finally { Pop-Location }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools/google-drive-zip-merger/Test-MergeGoogleDriveZips.ps1')
    Assert-Exit 'Google Drive ZIP merger'
    & python -m unittest discover -s tools/kindle-epub-transfer -p 'test_*.py' -v
    Assert-Exit 'Kindle EPUB unit tests'
    $parseErrors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'tools/kindle-epub-transfer/Run-KindleTransfer.ps1'),
        [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    Write-Host 'Developer Tools Windows validation passed'
} finally { Pop-Location }
