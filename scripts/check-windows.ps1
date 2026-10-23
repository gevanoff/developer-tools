# PowerShell 5.1+ / Windows; run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-windows.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Assert-Exit([string]$Label) {
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE)" }
}
Push-Location $root
try {
    Push-Location (Join-Path $root 'tools/DroidRun')
    try {
        & ./Test-AndroidBuildBackends.ps1
        Assert-Exit 'DroidRun backends'
        & ./Test-AndroidBuildInstall.ps1
        Assert-Exit 'DroidRun install'
    } finally { Pop-Location }
    Push-Location (Join-Path $root 'tools/codex-usage-meter')
    try {
        & node --test tests/read-usage.test.mjs
        Assert-Exit 'Codex usage Node tests'
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ./CodexMeter.ps1 -SelfTest
        Assert-Exit 'Codex meter self test'
    } finally { Pop-Location }
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
