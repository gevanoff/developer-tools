[CmdletBinding()]
param()

# Checks the dashboard's pure display rules: status tones, the Sync & Run preview,
# and palette contrast. Needs no device, Windows Forms, or Android SDK, so it also
# runs under PowerShell 7 on Linux.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DroidRunPresentation.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ("$Actual" -cne "$Expected") { $failures.Add("$Name`n  expected: $Expected`n  actual:   $Actual") }
}

$tones = [ordered]@{
    'Current' = 'ok'; 'Fresh' = 'ok'; 'Same' = 'ok'
    'Behind 2' = 'action'; 'Stale' = 'action'; 'No APK' = 'action'; 'Different' = 'action'; 'Not installed' = 'action'
    'Dirty' = 'warn'; 'Detached' = 'warn'; 'No upstream' = 'warn'; 'Ambiguous' = 'warn'; 'Preferred missing' = 'warn'
    'No device' = 'warn'; 'Choose device' = 'warn'; 'Preferred absent' = 'warn'
    'Diverged 3/1' = 'error'; 'Fetch failed' = 'error'; 'Git error' = 'error'; 'Timed out' = 'error'; 'Failed' = 'error'
    'Ahead 1' = 'neutral'; 'Not Git' = 'neutral'; 'Unknown' = 'neutral'; 'Checking...' = 'neutral'; 'Queued' = 'neutral'
    '' = 'neutral'; 'Behindhand' = 'neutral'
}
foreach ($entry in $tones.GetEnumerator()) {
    Assert-Equal (Get-DroidRunStatusTone -Status $entry.Key) $entry.Value "tone of '$($entry.Key)'"
}

$arrow = " $([char]0x2192) "
$ready = @(
    @{ Git = 'Behind 2'; Build = 'Stale'; Device = 'Different'; Launch = $true; Steps = 'Pull 2 commits|Build|Install|Launch' },
    @{ Git = 'Behind 1'; Build = 'Fresh'; Device = 'Not installed'; Launch = $false; Steps = 'Pull 1 commit|Install|No launch' },
    @{ Git = 'Current'; Build = 'Fresh'; Device = 'Same'; Launch = $true; Steps = 'Skip install (same APK)|Launch' },
    @{ Git = 'Current'; Build = 'Stale'; Device = 'Same'; Launch = $true; Steps = 'Build|Install if changed|Launch' },
    @{ Git = 'Not Git'; Build = 'No APK'; Device = 'Not installed'; Launch = $true; Steps = 'Build|Install|Launch' },
    @{ Git = 'Ahead 3'; Build = 'Fresh'; Device = 'Unknown'; Launch = $true; Steps = 'Install|Launch' }
)
foreach ($case in $ready) {
    $preview = Get-DroidRunSyncPreview -GitStatus $case.Git -BuildStatus $case.Build -DeviceStatus $case.Device -AutoLaunch $case.Launch
    $name = "preview $($case.Git)/$($case.Build)/$($case.Device)"
    Assert-Equal $preview.Ready $true "$name ready"
    Assert-Equal ($preview.Steps -join '|') $case.Steps "$name steps"
    Assert-Equal $preview.Headline ('Sync & Run will: ' + ($case.Steps -replace '\|', $arrow) + '.') "$name headline"
}

# Each blocker matches a throw in Invoke-AndroidSyncAndRun.ps1, in the same order.
$blocked = @(
    @{ Git = 'Dirty'; Build = 'Ambiguous'; Device = 'Choose device'; Expect = 'several devices' },
    @{ Git = 'Dirty'; Build = 'Fresh'; Device = 'No device'; Expect = 'no authorised device' },
    @{ Git = 'Current'; Build = 'Fresh'; Device = 'Preferred absent'; Expect = 'remembered device' },
    @{ Git = 'Dirty'; Build = 'Ambiguous'; Device = 'Same'; Expect = 'local changes' },
    @{ Git = 'Diverged 1/2'; Build = 'Fresh'; Device = 'Same'; Expect = 'diverged' },
    @{ Git = 'Detached'; Build = 'Fresh'; Device = 'Same'; Expect = 'detached' },
    @{ Git = 'No upstream'; Build = 'Fresh'; Device = 'Same'; Expect = 'no upstream' },
    @{ Git = 'Fetch failed'; Build = 'Fresh'; Device = 'Same'; Expect = 'Fetch failed' },
    @{ Git = 'Current'; Build = 'Ambiguous'; Device = 'Same'; Expect = 'single APK' },
    @{ Git = 'Current'; Build = 'Preferred missing'; Device = 'Same'; Expect = 'single APK' },
    @{ Git = 'Current'; Build = 'No project'; Device = 'Unknown'; Expect = 'not set up' },
    @{ Git = 'Current'; Build = 'Unknown'; Device = 'Unknown'; Expect = 'not set up' }
)
foreach ($case in $blocked) {
    $preview = Get-DroidRunSyncPreview -GitStatus $case.Git -BuildStatus $case.Build -DeviceStatus $case.Device -AutoLaunch $true
    $name = "blocked $($case.Git)/$($case.Build)/$($case.Device)"
    Assert-Equal $preview.Ready $false "$name ready"
    Assert-Equal ($preview.Headline -like "Sync & Run will stop:*$($case.Expect)*") $true "$name headline '$($preview.Headline)'"
    Assert-Equal ([bool]$preview.Fix) $true "$name has a fix"
}
$failedCheck = Get-DroidRunSyncPreview -GitStatus 'Unknown' -BuildStatus 'Unknown' -DeviceStatus 'Unknown' -AutoLaunch $true
Assert-Equal $failedCheck.Headline 'Status could not be checked.' 'failed status check is not a build problem'
$pending = Get-DroidRunSyncPreview -GitStatus 'Checking...' -BuildStatus 'Checking...' -DeviceStatus 'Checking...' -AutoLaunch $true
Assert-Equal $pending.Ready $false 'pending is not a prediction'
Assert-Equal $pending.Headline 'Status not checked yet.' 'pending headline'

$palette = Get-DroidRunPalette
foreach ($surface in @('Bg', 'Surface', 'Raised', 'Select')) {
    foreach ($text in @('Text', 'Muted')) {
        $ratio = Get-DroidRunContrastRatio $palette[$text] $palette[$surface]
        Assert-Equal ($ratio -ge 4.5) $true "$text on $surface contrast $([Math]::Round($ratio, 2))"
    }
}
foreach ($tone in @('ok', 'action', 'warn', 'error', 'neutral')) {
    $chip = Get-DroidRunChipColors -Tone $tone
    $ratio = Get-DroidRunContrastRatio $chip.Text $chip.Background
    Assert-Equal ($ratio -ge 4.5) $true "$tone chip contrast $([Math]::Round($ratio, 2))"
}
Assert-Equal ((Get-DroidRunContrastRatio $palette.OnLime $palette.Lime) -ge 4.5) $true 'primary button contrast'
Assert-Equal ((Get-DroidRunContrastRatio $palette.Disabled $palette.Surface) -ge 4.5) $true 'disabled text contrast'
Assert-Equal (Get-DroidRunChipColors -Tone 'ok').Background '#204049' 'chip background matches Linux theme.mix'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}
Write-Host 'PASS: status tones, Sync & Run preview and blockers, palette contrast.'
