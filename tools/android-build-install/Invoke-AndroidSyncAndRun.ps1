[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$PreferencesPath,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$statusHelper = Join-Path $PSScriptRoot 'Get-AndroidProjectStatus.ps1'
$gitUpdater = Join-Path $PSScriptRoot 'Update-AndroidRepo.ps1'
$runner = Join-Path $PSScriptRoot 'Run-AndroidBuildInstall.ps1'
$scanner = Join-Path $PSScriptRoot 'Scan-AndroidDevice.ps1'

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([char[]]@(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ))
    }
    return $full
}

function Get-Preference {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $default = [pscustomobject]@{
        gradleTask = 'assembleDebug'
        preferredApk = ''
        javaHome = ''
        autoLaunch = $false
        deviceSerial = ''
    }

    if (-not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) { return $default }
    try { $json = Get-Content -LiteralPath $PreferencesPath -Raw | ConvertFrom-Json } catch { return $default }

    $normalized = Normalize-Path -Path $ProjectPath
    foreach ($item in @($json.projects)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-Path -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $normalized) {
            return [pscustomobject]@{
                gradleTask = if ([string]::IsNullOrWhiteSpace("$($item.gradleTask)")) { 'assembleDebug' } else { "$($item.gradleTask)" }
                preferredApk = "$($item.preferredApk)"
                javaHome = "$($item.javaHome)"
                autoLaunch = [bool]$item.autoLaunch
                deviceSerial = "$($item.deviceSerial)"
            }
        }
    }
    return $default
}

function Invoke-Child {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @(),
        [hashtable]$Parameters = @{},
        [switch]$InProcess
    )

    $previousPreference = $ErrorActionPreference
    $exitCode = 1
    try {
        $ErrorActionPreference = 'Continue'
        if ($InProcess) {
            & $File @Parameters -NoProcessExit *>&1 | ForEach-Object { Write-Host "$_" }
            $exitCode = 0
        }
        else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $File @Arguments 2>&1 |
                ForEach-Object { Write-Host "$_" }
            $exitCode = [int]$LASTEXITCODE
        }
    }
    catch {
        Write-Host "$_"
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return $exitCode
}

function Show-Summary {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    if ($NoUi) {
        Write-Host ''
        Write-Host $Message
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Android Sync & Run',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

function Assert-DeterministicBuildStatus {
    param([Parameter(Mandatory = $true)]$Status)

    if ($Status.BuildStatus -in @('Ambiguous', 'Preferred missing', 'Preferred invalid', 'No Gradle', 'No project', 'Unknown')) {
        throw "Sync & Run cannot choose a deterministic APK because local build status is '$($Status.BuildStatus)'. Open Settings and configure a preferred APK or correct the project layout. $($Status.BuildDetail)"
    }
}

try {
    $projectPath = Normalize-Path -Path $Project
    if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
        throw "Project directory does not exist:`n$projectPath"
    }

    $preference = Get-Preference -ProjectPath $projectPath
    $actions = New-Object System.Collections.Generic.List[string]

    Write-Host ''
    Write-Host 'Android Sync & Run'
    Write-Host '=================='
    Write-Host "Project: $projectPath"
    Write-Host ''

    # Check the device before building, and fetch remote refs without modifying
    # the working tree so the Git ahead/behind state is current.
    $before = @(& $statusHelper -Project @($projectPath) -PreferencesPath $PreferencesPath -FetchRemote)
    if ($before.Count -eq 0) { throw 'Could not determine project status.' }
    $status = $before[0]

    Write-Host "Git:    $($status.GitStatus)"
    Write-Host "Build:  $($status.BuildStatus)"
    Write-Host "Device: $($status.DeviceStatus)"

    if ($status.DeviceStatus -in @('No device', 'Choose device', 'Preferred absent')) {
        $instruction = if ($status.DeviceStatus -eq 'Choose device') {
            'Open Settings for this project, click Detect, and save the preferred device.'
        } elseif ($status.DeviceStatus -eq 'Preferred absent') {
            'Connect the remembered device or update the preferred device in Settings.'
        } else {
            'Connect and authorize an Android device before running Sync & Run.'
        }
        throw "Sync & Run stopped because the device state is '$($status.DeviceStatus)'. $instruction"
    }

    if ($status.GitStatus -eq 'Dirty') {
        throw 'Sync & Run stopped because the working tree has local changes. Commit, stash, or discard them before syncing.'
    }
    if ($status.GitStatus -like 'Diverged*') {
        throw 'Sync & Run stopped because the local branch and its upstream have diverged. Resolve the branch explicitly before syncing.'
    }
    if ($status.GitStatus -in @('Detached', 'No upstream', 'Fetch failed', 'Git error', 'Git unavailable')) {
        throw "Sync & Run stopped because Git status is '$($status.GitStatus)'. $($status.GitDetail)"
    }

    if ($status.GitStatus -like 'Behind *') {
        Write-Host ''
        Write-Host 'Updating repository with git pull --ff-only...'
        $gitExit = Invoke-Child -File $gitUpdater -Arguments @('-Project', $projectPath, '-NoUi')
        if ($gitExit -ne 0) { throw "Safe Git update failed with exit code $gitExit." }
        $actions.Add('Git: fast-forwarded to upstream.')

        $afterPull = @(& $statusHelper -Project @($projectPath) -PreferencesPath $PreferencesPath -SkipDevice)
        if ($afterPull.Count -gt 0) { $status = $afterPull[0] }
    }
    elseif ($status.GitStatus -eq 'Not Git') {
        $actions.Add('Git: project is not a Git repository; update skipped.')
    }
    else {
        $actions.Add("Git: $($status.GitStatus.ToLowerInvariant()).")
    }

    Assert-DeterministicBuildStatus -Status $status

    $needsBuild = $status.BuildStatus -ne 'Fresh'
    if ($needsBuild) {
        Write-Host ''
        Write-Host "Local build is '$($status.BuildStatus)'; building before device comparison..."

        $buildParameters = @{
            Project = $projectPath
            GradleTask = $preference.gradleTask
            SkipInstall = $true
            SuppressSuccessDialog = $true
        }
        if ($NoUi) { $buildParameters.NoUi = $true }
        if ($preference.preferredApk) { $buildParameters.PreferredApk = $preference.preferredApk }
        if ($preference.javaHome) { $buildParameters.JavaHome = $preference.javaHome }

        $buildExit = Invoke-Child -File $runner -Parameters $buildParameters -InProcess
        if ($buildExit -ne 0) { throw "Build stage failed with exit code $buildExit." }
        $actions.Add('Build: rebuilt local APK.')

        # Re-evaluate APK selection after the build. A project that had no APK
        # before building can produce multiple outputs; Sync & Run must not fall
        # into an interactive APK chooser in that case.
        $afterBuild = @(& $statusHelper -Project @($projectPath) -PreferencesPath $PreferencesPath -SkipDevice)
        if ($afterBuild.Count -eq 0) { throw 'Could not validate APK output after building.' }
        $status = $afterBuild[0]
        Assert-DeterministicBuildStatus -Status $status
    }
    else {
        $actions.Add('Build: existing APK is fresh; rebuild skipped.')
    }

    Write-Host ''
    Write-Host 'Comparing local APK with the attached device...'
    $scanParameters = @{
        Project = @($projectPath)
    }
    if ($preference.deviceSerial) { $scanParameters.DeviceSerial = $preference.deviceSerial }
    if ($preference.preferredApk) { $scanParameters.PreferredApk = $preference.preferredApk }

    $scan = @(& $scanner @scanParameters)
    if ($scan.Count -eq 0) { throw 'Device comparison did not return a result.' }
    $deviceStatus = [string]$scan[0].Status
    Write-Host "Device comparison: $deviceStatus"

    if ($deviceStatus -eq 'Same') {
        $actions.Add('Install: device already has the same APK; install skipped.')

        if ($preference.autoLaunch) {
            $launchParameters = @{
                Project = $projectPath
                GradleTask = $preference.gradleTask
                SkipBuild = $true
                SkipInstall = $true
                AutoLaunch = $true
                SuppressSuccessDialog = $true
            }
            if ($NoUi) { $launchParameters.NoUi = $true }
            if ($preference.preferredApk) { $launchParameters.PreferredApk = $preference.preferredApk }
            if ($preference.javaHome) { $launchParameters.JavaHome = $preference.javaHome }
            if ($preference.deviceSerial) { $launchParameters.DeviceSerial = $preference.deviceSerial }

            $launchExit = Invoke-Child -File $runner -Parameters $launchParameters -InProcess
            if ($launchExit -ne 0) { throw "Launch stage failed with exit code $launchExit." }
            $actions.Add('Launch: app launch requested.')
        }
        else {
            $actions.Add('Launch: disabled in project settings.')
        }
    }
    else {
        $installParameters = @{
            Project = $projectPath
            GradleTask = $preference.gradleTask
            SkipBuild = $true
            SuppressSuccessDialog = $true
        }
        if ($NoUi) { $installParameters.NoUi = $true }
        if ($preference.preferredApk) { $installParameters.PreferredApk = $preference.preferredApk }
        if ($preference.javaHome) { $installParameters.JavaHome = $preference.javaHome }
        if ($preference.deviceSerial) { $installParameters.DeviceSerial = $preference.deviceSerial }
        if ($preference.autoLaunch) { $installParameters.AutoLaunch = $true }

        $installExit = Invoke-Child -File $runner -Parameters $installParameters -InProcess
        if ($installExit -ne 0) { throw "Install stage failed with exit code $installExit." }
        $actions.Add("Install: completed because device state was '$deviceStatus'.")
        if ($preference.autoLaunch) { $actions.Add('Launch: app launch requested.') }
        else { $actions.Add('Launch: disabled in project settings.') }
    }

    $message = "Sync & Run completed successfully.`n`n" + ($actions -join [Environment]::NewLine)
    Show-Summary -Message $message
    exit 0
}
catch {
    Show-Summary -Icon ([System.Windows.Forms.MessageBoxIcon]::Error) -Message $_.Exception.Message
    exit 1
}
