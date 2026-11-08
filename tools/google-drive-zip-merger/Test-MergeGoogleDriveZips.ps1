[CmdletBinding()]
param()

# Checks the merger's planning, extraction, stop, failure, and cleanup rules in
# temporary folders whose names contain spaces. On Windows it also opens the
# window with -UiSmokeTest and runs a merge through it.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ZipMergeEngine.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $failures.Add($Message) }
}

function New-TestZip {
    param([string]$Path, [hashtable]$Entries)
    $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in ($Entries.Keys | Sort-Object)) {
            $entry = $archive.CreateEntry($name)
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try { $writer.Write($Entries[$name]) } finally { $writer.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("zip merger test $([Guid]::NewGuid().ToString('N'))")
try {
    $source = Join-Path $root 'Drive download'
    $destination = Join-Path $root 'Merged files'
    New-Item -ItemType Directory -Path $source, $destination -Force | Out-Null
    New-TestZip (Join-Path $source 'drive-download-001.zip') @{ 'Photos/a b.txt' = 'one'; 'Docs/report.txt' = 'first' }
    New-TestZip (Join-Path $source 'drive-download-002.zip') @{ 'Photos/c.txt' = 'three'; 'Docs/report.txt' = 'second' }
    Set-Content -LiteralPath (Join-Path $destination 'Photos c.txt') -Value 'unrelated'
    New-Item -ItemType Directory -Path (Join-Path $destination 'Photos') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $destination 'Photos/c.txt') -Value 'old'

    $info = Get-ZipMergeSource -Source $source
    Assert-True ($info.Zips.Count -eq 2) "Expected 2 ZIP files, found $($info.Zips.Count)."
    Assert-True ($info.Zips[0].Name -eq 'drive-download-001.zip') 'ZIP files are not in filename order.'
    Assert-True ($info.Entries -eq 4) "Expected 4 entries, found $($info.Entries)."

    $plan = Get-ZipMergePlan -SourceInfo $info -Destination $destination
    Assert-True ($plan.Existing -eq 1) "Expected 1 existing file, found $($plan.Existing)."
    Assert-True ($plan.Repeated -eq 1) "Expected 1 repeated path, found $($plan.Repeated)."
    Assert-True ($plan.Unsafe.Count -eq 0) 'Safe entries were reported as unsafe.'

    $state = New-ZipMergeState
    Invoke-ZipMerge -Plan $plan -State $state
    Assert-True ($state.Outcome -eq 'Completed') "Merge outcome was '$($state.Outcome)': $($state.Error)"
    Assert-True ($state.Files -eq 4 -and $state.Replaced -eq 2) "Expected 4 files and 2 replacements, got $($state.Files) and $($state.Replaced)."
    Assert-True ((Get-Content -LiteralPath (Join-Path $destination 'Docs/report.txt') -Raw) -eq 'second') 'A later ZIP did not replace an earlier copy.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $destination 'Photos/a b.txt') -Raw) -eq 'one') 'A path with a space was not extracted.'
    Assert-True (Test-Path -LiteralPath (Join-Path $source 'drive-download-001.zip')) 'A merge deleted a source ZIP without being asked.'

    # Cleanup is refused unless every ZIP was extracted.
    $stopped = New-ZipMergeState
    $stopped.Cancel = $true
    Invoke-ZipMerge -Plan $plan -State $stopped
    Assert-True ($stopped.Outcome -eq 'Stopped' -and $stopped.Files -eq 0) 'A stop request did not stop before the next file.'
    $refused = $false
    try { [void](Remove-ZipMergeSources -Plan $plan -State $stopped) } catch { $refused = $true }
    Assert-True $refused 'Cleanup ran after a stopped merge.'
    Assert-True (Test-Path -LiteralPath (Join-Path $source 'drive-download-002.zip')) 'A stopped merge lost a source ZIP.'

    # Unsafe archive paths are found before anything is written.
    $evilSource = Join-Path $root 'Evil download'
    $evilDestination = Join-Path $root 'Evil target'
    New-Item -ItemType Directory -Path $evilSource -Force | Out-Null
    New-TestZip (Join-Path $evilSource 'a.zip') @{ 'safe.txt' = 'x' }
    New-TestZip (Join-Path $evilSource 'b.zip') @{ '../escaped.txt' = 'x' }
    $evilPlan = Get-ZipMergePlan -SourceInfo (Get-ZipMergeSource -Source $evilSource) -Destination $evilDestination
    Assert-True ($evilPlan.Unsafe.Count -eq 1) 'An escaping archive path was not reported by the plan.'
    $evilState = New-ZipMergeState
    Invoke-ZipMerge -Plan $evilPlan -State $evilState
    Assert-True ($evilState.Outcome -eq 'Failed') 'A plan with an unsafe path was extracted.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $evilDestination 'safe.txt'))) 'Files were written before the unsafe path was rejected.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'escaped.txt'))) 'An archive path escaped the destination.'
    $refused = $false
    try { [void](Remove-ZipMergeSources -Plan $evilPlan -State $evilState) } catch { $refused = $true }
    Assert-True ($refused -and (Test-Path -LiteralPath (Join-Path $evilSource 'b.zip'))) 'Cleanup ran after a failed merge.'

    # Explicit cleanup after success deletes exactly the planned ZIPs.
    Set-Content -LiteralPath (Join-Path $source 'keep me.txt') -Value 'not a zip'
    $deleted = Remove-ZipMergeSources -Plan $plan -State $state
    Assert-True ($deleted -eq 2) "Expected 2 ZIPs deleted, got $deleted."
    Assert-True (Test-Path -LiteralPath (Join-Path $source 'keep me.txt')) 'Cleanup removed a file that was not a planned ZIP.'

    Assert-True ((Format-ZipMergeSize 1536) -eq '1.5 KB') "Size formatting is wrong: $(Format-ZipMergeSize 1536)"

    $isWindowsDesktop = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
    if ($isWindowsDesktop) {
        $uiSource = Join-Path $root 'UI download'
        $uiDestination = Join-Path $root 'UI merged'
        New-Item -ItemType Directory -Path $uiSource -Force | Out-Null
        New-TestZip (Join-Path $uiSource 'part 1.zip') @{ 'folder/one.txt' = '1' }
        New-TestZip (Join-Path $uiSource 'part 2.zip') @{ 'folder/two.txt' = '2' }
        $output = @(& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Merge-GoogleDriveZips.ps1') `
            -Source $uiSource -Destination $uiDestination -UiSmokeTest 2>&1)
        $text = $output -join [Environment]::NewLine
        Assert-True ($LASTEXITCODE -eq 0) "Window smoke test failed with exit code $LASTEXITCODE.`n$text"
        Assert-True ($text -match 'UI merge outcome: Completed') "The window did not complete a merge.`n$text"
        Assert-True (Test-Path -LiteralPath (Join-Path $uiDestination 'folder/two.txt')) 'The window did not extract files.'
        Assert-True (Test-Path -LiteralPath (Join-Path $uiSource 'part 1.zip')) 'The window deleted ZIP files without being asked.'
    }
}
finally {
    if ((Split-Path -Leaf $root) -like 'zip merger test *' -and (Test-Path -LiteralPath $root)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}
Write-Host 'PASS: ZIP order, plan counts, merge, replacement, paths with spaces, stop, unsafe paths before writing, and cleanup only after success.'
