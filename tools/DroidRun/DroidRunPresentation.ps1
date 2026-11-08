# Pure display logic for the DroidRun dashboard: palette, status tones, and the
# Sync & Run preview. No Windows Forms or native calls, so it can be tested on any
# PowerShell. The Linux dashboard has the same rules in presentation.py/theme.py.

$script:DroidRunPalette = [ordered]@{
    Bg          = '#0E1726'
    Surface     = '#142238'
    Raised      = '#1B2C46'
    Select      = '#22395C'
    Border      = '#2A3D5C'
    Console     = '#0A111D'
    Text        = '#E8EEF6'
    Muted       = '#9FB0C8'
    Disabled    = '#7D8DA6'
    Lime        = '#B8F526'
    LimeHover   = '#CCFF4D'
    LimePressed = '#A3DB1F'
    LimeMuted   = '#3C4A2A'
    OnLime      = '#142238'
    ok          = '#5EE0A0'
    action      = '#7CC4FF'
    warn        = '#FFC857'
    error       = '#FF8A80'
    neutral     = '#9FB0C8'
}
$script:DroidRunChipAlpha = 0.16

function Get-DroidRunPalette { return $script:DroidRunPalette }

function Get-DroidRunMixedColor {
    # Blend two #RRGGBB colours; used for opaque chip backgrounds drawn against Surface.
    param([string]$Foreground, [string]$Background, [double]$Alpha)
    $parts = foreach ($offset in 1, 3, 5) {
        $f = [Convert]::ToInt32($Foreground.Substring($offset, 2), 16)
        $b = [Convert]::ToInt32($Background.Substring($offset, 2), 16)
        '{0:X2}' -f [int][Math]::Round($f * $Alpha + $b * (1 - $Alpha), [MidpointRounding]::AwayFromZero)
    }
    return '#' + ($parts -join '')
}

function Get-DroidRunChipColors {
    param([string]$Tone)
    if ($Tone -notin @('ok', 'action', 'warn', 'error', 'neutral')) {
        $Tone = 'neutral'
    }
    $text = $script:DroidRunPalette[$Tone]
    return [pscustomobject]@{
        Text = $text
        Background = Get-DroidRunMixedColor -Foreground $text -Background $script:DroidRunPalette.Surface -Alpha $script:DroidRunChipAlpha
    }
}

function Get-DroidRunStatusTone {
    # What a Git, Local Build, or Device status means for the next Sync & Run:
    # ok = nothing to do, action = Sync & Run will act, warn = needs a decision,
    # error = failed or unsafe, neutral = informational or not yet known.
    param([AllowNull()][AllowEmptyString()][string]$Status)

    $text = "$Status".Trim()
    switch -Exact ($text) {
        { $_ -in @('Current', 'Fresh', 'Same') } { return 'ok' }
        { $_ -in @('Stale', 'No APK', 'Different', 'Not installed') } { return 'action' }
        { $_ -in @('Dirty', 'Detached', 'No upstream', 'Ambiguous', 'Preferred missing', 'Preferred invalid',
                   'No Gradle', 'No project', 'Configuration needed', 'No device', 'Choose device', 'Preferred absent') } { return 'warn' }
        { $_ -in @('Fetch failed', 'Git error', 'Git unavailable', 'Missing', 'Failed', 'Timed out') } { return 'error' }
    }
    if ($text -match '^Behind \d+$') { return 'action' }
    if ($text -match '^Diverged ') { return 'error' }
    return 'neutral'
}

function Get-DroidRunSyncPreview {
    # Predict the Sync & Run path from cached dashboard status. Mirrors
    # Invoke-AndroidSyncAndRun.ps1: device first, then Git, then a deterministic
    # APK, rebuild unless Fresh, install unless Same, launch per settings.
    param(
        [AllowEmptyString()][string]$GitStatus,
        [AllowEmptyString()][string]$BuildStatus,
        [AllowEmptyString()][string]$DeviceStatus,
        [bool]$AutoLaunch
    )

    $git = "$GitStatus".Trim(); $build = "$BuildStatus".Trim(); $device = "$DeviceStatus".Trim()
    $stop = {
        param([string]$Headline, [string]$Fix)
        [pscustomobject]@{ Ready = $false; Headline = "Sync & Run will stop: $Headline"; Steps = @(); Fix = $Fix }
    }

    if ($git -in @('', 'Checking...', 'Queued') -or $build -in @('', 'Checking...', 'Queued')) {
        return [pscustomobject]@{ Ready = $false; Headline = 'Status not checked yet.'; Steps = @(); Fix = 'Refresh Status to see what Sync & Run will do.' }
    }

    if ($git -eq 'Unknown') {
        # The dashboard writes Unknown only when its own status check failed or timed out.
        return [pscustomobject]@{ Ready = $false; Headline = 'Status could not be checked.'; Steps = @(); Fix = 'Hover the row for details, then Refresh Status.' }
    }

    switch ($device) {
        'No device' { return & $stop 'no authorised device is connected.' 'Connect and unlock the device, and accept the USB debugging prompt.' }
        'Choose device' { return & $stop 'several devices are connected.' 'Open Settings, click Detect, and save the preferred device.' }
        'Preferred absent' { return & $stop 'the remembered device is not connected.' 'Connect it, or change the preferred device in Settings.' }
    }

    $gitFix = 'Resolve it in Git, or use Build & Install to build the current files.'
    if ($git -eq 'Dirty') { return & $stop 'the working tree has local changes.' $gitFix }
    if ($git -like 'Diverged*') { return & $stop 'the branch has diverged from its upstream.' $gitFix }
    if ($git -eq 'Detached') { return & $stop 'the repository is on a detached HEAD.' $gitFix }
    if ($git -eq 'No upstream') { return & $stop 'the branch has no upstream.' $gitFix }
    if ($git -in @('Fetch failed', 'Git error', 'Git unavailable', 'Missing')) {
        return & $stop "Git status is '$git'." 'Hover the row for details, fix the problem, and refresh.'
    }

    if ($build -in @('Ambiguous', 'Preferred missing', 'Preferred invalid')) {
        return & $stop "there is no single APK to install ('$build')." 'Open Settings and set a Preferred APK.'
    }
    if ($build -in @('No Gradle', 'No project', 'Unknown')) {
        return & $stop "the build is not set up ('$build')." 'Check the project folder, or configure a Godot / custom build in Settings.'
    }

    $steps = New-Object System.Collections.Generic.List[string]
    if ($git -match '^Behind (\d+)$') {
        $count = [int]$matches[1]
        $steps.Add($(if ($count -eq 1) { 'Pull 1 commit' } else { "Pull $count commits" }))
    }
    if ($build -ne 'Fresh') { $steps.Add('Build') }
    if ($device -eq 'Same') {
        # A pull or rebuild changes the APK, so the cached comparison no longer holds.
        $steps.Add($(if ($steps.Count -gt 0) { 'Install if changed' } else { 'Skip install (same APK)' }))
    }
    else {
        $steps.Add('Install')
    }
    $steps.Add($(if ($AutoLaunch) { 'Launch' } else { 'No launch' }))

    return [pscustomobject]@{
        Ready = $true
        # U+2192 (rightwards arrow) is built at run time so this file stays ASCII for PowerShell 5.1.
        Headline = 'Sync & Run will: ' + ($steps -join " $([char]0x2192) ") + '.'
        Steps = $steps.ToArray()
        Fix = ''
    }
}

function Get-DroidRunContrastRatio {
    param([string]$First, [string]$Second)
    $luminance = {
        param([string]$Hex)
        $total = 0.0
        $weights = @(0.2126, 0.7152, 0.0722)
        for ($index = 0; $index -lt 3; $index++) {
            $channel = [Convert]::ToInt32($Hex.Substring(1 + 2 * $index, 2), 16) / 255.0
            $linear = if ($channel -le 0.03928) { $channel / 12.92 } else { [Math]::Pow(($channel + 0.055) / 1.055, 2.4) }
            $total += $weights[$index] * $linear
        }
        $total
    }
    $a = & $luminance $First
    $b = & $luminance $Second
    return ([Math]::Max($a, $b) + 0.05) / ([Math]::Min($a, $b) + 0.05)
}
