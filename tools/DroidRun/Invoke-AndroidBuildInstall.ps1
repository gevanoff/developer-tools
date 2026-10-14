[CmdletBinding()]
param(
    [string]$Project,
    [string]$GradleTask = 'assembleDebug',
    [string]$DeviceSerial,
    [string]$PreferredApk,
    [string]$JavaHome,
    [switch]$AutoLaunch,
    [switch]$SkipBuild,
    [switch]$SkipInstall,
    [switch]$SuppressSuccessDialog,
    [switch]$NoUi,
    [Parameter(DontShow = $true)][switch]$NoProcessExit
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')
Add-Type -AssemblyName System.Windows.Forms

function Show-Error {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host "ERROR: $Message"
    if ($NoUi) { return }
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'DroidRun',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Show-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    if ($NoUi) {
        Write-Host $Message
        return
    }
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'DroidRun',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Select-Folder {
    param([Parameter(Mandatory = $true)][string]$Description)
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = $Description
    $picker.ShowNewFolderButton = $false
    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $picker.SelectedPath
}

function Select-ItemFromList {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][scriptblock]$Label,
        [string]$NoUiMessage
    )

    if ($Items.Count -eq 1) { return $Items[0] }
    if ($NoUi) {
        if (-not $NoUiMessage) {
            $NoUiMessage = "$Prompt Configure an explicit selection before running this operation from the dashboard."
        }
        throw $NoUiMessage
    }

    Write-Host ''
    Write-Host $Prompt
    Write-Host ''
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "[$($i + 1)] $(& $Label $Items[$i])"
    }

    while ($true) {
        Write-Host ''
        $answer = Read-Host "Choose 1-$($Items.Count)"
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) {
            return $Items[$number - 1]
        }
        Write-Host 'Invalid selection.'
    }
}

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @Arguments 2>&1
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { "$_" })
    }
}

function Get-GradleRoots {
    param([string]$Root, [int]$MaxDepth = 2)
    Get-AndroidProjectRoots -Root $Root -MaxDepth $MaxDepth
}

function Get-LocalSdkPath {
    param([Parameter(Mandatory = $true)][string]$GradleRoot)

    $localProperties = Join-Path $GradleRoot 'local.properties'
    if (-not (Test-Path -LiteralPath $localProperties -PathType Leaf)) { return $null }

    foreach ($line in Get-Content -LiteralPath $localProperties) {
        if ($line -match '^\s*sdk\.dir\s*=\s*(.+)\s*$') {
            $value = $matches[1].Trim().Replace('\:', ':').Replace('\\', '\')
            return [Environment]::ExpandEnvironmentVariables($value)
        }
    }
    return $null
}

function Get-SdkRoots {
    param([string]$GradleRoot)

    $roots = @()
    if ($GradleRoot) {
        $local = Get-LocalSdkPath -GradleRoot $GradleRoot
        if ($local) { $roots += $local }
    }
    if ($env:ANDROID_SDK_ROOT) { $roots += $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { $roots += $env:ANDROID_HOME }
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
    return @($roots | Where-Object { $_ } | Select-Object -Unique)
}

function Resolve-Adb {
    param([Parameter(Mandatory = $true)][string]$GradleRoot)

    foreach ($root in @(Get-SdkRoots -GradleRoot $GradleRoot)) {
        $candidate = Join-Path $root 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Resolve-ApkInspector {
    param([Parameter(Mandatory = $true)][string]$GradleRoot)

    foreach ($root in @(Get-SdkRoots -GradleRoot $GradleRoot)) {
        $buildTools = Join-Path $root 'build-tools'
        if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }

        foreach ($directory in @(Get-ChildItem -LiteralPath $buildTools -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $aapt2 = Join-Path $directory.FullName 'aapt2.exe'
            if (Test-Path -LiteralPath $aapt2 -PathType Leaf) {
                return [pscustomobject]@{ Path = $aapt2; Kind = 'aapt2' }
            }
            $aapt = Join-Path $directory.FullName 'aapt.exe'
            if (Test-Path -LiteralPath $aapt -PathType Leaf) {
                return [pscustomobject]@{ Path = $aapt; Kind = 'aapt' }
            }
        }
    }
    return $null
}

function Get-PackageId {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$Apk,
        [Parameter(Mandatory = $true)]$Inspector
    )

    if ($Inspector.Kind -eq 'aapt2') {
        $result = Invoke-NativeCaptured -FilePath $Inspector.Path -Arguments @('dump', 'packagename', $Apk.FullName)
        if ($result.ExitCode -eq 0) {
            foreach ($line in $result.Output) {
                $candidate = $line.Trim()
                if ($candidate -match '^[A-Za-z][A-Za-z0-9_.]+$') { return $candidate }
            }
        }
    }
    else {
        $result = Invoke-NativeCaptured -FilePath $Inspector.Path -Arguments @('dump', 'badging', $Apk.FullName)
        if ($result.ExitCode -eq 0) {
            foreach ($line in $result.Output) {
                if ($line -match "^package:\s+name='([^']+)'") { return $matches[1] }
            }
        }
    }
    return $null
}

function Get-ConnectedDevices {
    param([Parameter(Mandatory = $true)][string]$Adb)

    $result = Invoke-NativeCaptured -FilePath $Adb -Arguments @('devices', '-l')
    if ($result.ExitCode -ne 0) {
        throw "adb failed while listing devices:`n$($result.Output -join [Environment]::NewLine)"
    }

    $devices = @()
    foreach ($rawLine in $result.Output) {
        $line = "$rawLine".Trim()
        if ($line -match '^(\S+)\s+(device|offline|unauthorized|recovery|sideload)\b\s*(.*)$') {
            $serial = $matches[1]
            $state = $matches[2]
            $details = $matches[3]
            $model = $serial
            if ($details -match '(?:^|\s)model:([^\s]+)') { $model = $matches[1].Replace('_', ' ') }
            $devices += [pscustomobject]@{
                Serial = $serial
                State = $state
                Model = $model
                Details = $details
            }
        }
    }
    return @($devices)
}

function Resolve-Device {
    param(
        [Parameter(Mandatory = $true)][string]$Adb,
        [string]$RequestedSerial
    )

    $devices = @(Get-ConnectedDevices -Adb $Adb)
    if ($RequestedSerial) {
        $match = @($devices | Where-Object { $_.Serial -eq $RequestedSerial })
        if ($match.Count -eq 0) { throw "Device '$RequestedSerial' was not reported by adb." }
        if ($match[0].State -ne 'device') { throw "Device '$RequestedSerial' is present but its state is '$($match[0].State)'." }
        return $match[0]
    }

    $ready = @($devices | Where-Object { $_.State -eq 'device' })
    if ($ready.Count -eq 0) {
        if (@($devices | Where-Object { $_.State -eq 'unauthorized' }).Count -gt 0) {
            throw 'An Android device is connected but not authorized. Unlock it and accept the USB debugging authorization prompt, then run the tool again.'
        }
        if (@($devices | Where-Object { $_.State -eq 'offline' }).Count -gt 0) {
            throw 'An Android device is connected but adb reports it as offline. Reconnect USB or restart USB debugging, then run the tool again.'
        }
        throw 'No ready Android device was found. Connect a device with USB debugging enabled and confirm that Windows has the required USB driver.'
    }

    return Select-ItemFromList -Prompt 'Multiple Android devices are connected. Choose the install target:' -Items $ready -Label {
        param($item)
        "$($item.Model)  [$($item.Serial)]"
    } -NoUiMessage 'Multiple authorized Android devices are connected. Open Settings for this project and save a Preferred device before running Build & Install from the dashboard.'
}

function Resolve-Java {
    param([string]$OverrideJavaHome)

    if ($OverrideJavaHome) {
        $javaHomePath = [System.IO.Path]::GetFullPath($OverrideJavaHome)
        $java = Join-Path $javaHomePath 'bin\java.exe'
        if (-not (Test-Path -LiteralPath $java -PathType Leaf)) {
            throw "Configured JAVA_HOME does not contain bin\java.exe:`n$javaHomePath"
        }
        $env:JAVA_HOME = $javaHomePath
        return $java
    }

    if ($env:JAVA_HOME) {
        $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (-not (Test-Path -LiteralPath $java -PathType Leaf)) {
            throw "JAVA_HOME is set but does not contain bin\java.exe:`n$env:JAVA_HOME"
        }
        return $java
    }

    $command = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'Java was not found. Configure a per-project JDK, set JAVA_HOME, or add a compatible JDK to PATH.'
    }
    return $command.Source
}

function Get-ApkCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$GradleRoot,
        [int]$MaxModuleDepth = 2
    )

    $plan = Get-AndroidBuildPlan -Root $GradleRoot
    if ($plan.Apk) {
        if (Test-Path -LiteralPath $plan.Apk -PathType Leaf) { Get-Item -LiteralPath $plan.Apk }
        return
    }

    $skipNames = @('.git', '.gradle', '.idea', 'build', 'node_modules', 'out')
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $GradleRoot; Depth = 0 })
    $apks = @()

    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $apkRoot = Join-Path $node.Path 'build\outputs\apk'
        if (Test-Path -LiteralPath $apkRoot -PathType Container) {
            $apks += Get-ChildItem -LiteralPath $apkRoot -Filter '*.apk' -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\androidTest\\' }
        }
        if ($node.Depth -ge $MaxModuleDepth) { continue }

        foreach ($child in Get-ChildItem -LiteralPath $node.Path -Directory -ErrorAction SilentlyContinue) {
            if ($skipNames -contains $child.Name) { continue }
            $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $node.Depth + 1 })
        }
    }

    $unique = @($apks | Sort-Object FullName -Unique)
    $debug = @($unique | Where-Object { $_.FullName -match '(?i)\\debug\\' -or $_.Name -match '(?i)debug.*\.apk$' })
    if ($debug.Count -gt 0) { return @($debug | Sort-Object LastWriteTime -Descending) }
    return @($unique | Sort-Object LastWriteTime -Descending)
}

function Resolve-Apk {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Candidates,
        [string]$Preferred,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$GradleRoot
    )

    if ($Preferred) {
        $preferredPath = if ([System.IO.Path]::IsPathRooted($Preferred)) {
            [System.IO.Path]::GetFullPath($Preferred)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Preferred))
        }

        $matches = @($Candidates | Where-Object { $_.FullName -ieq $preferredPath })
        if ($matches.Count -eq 1) {
            Write-Host "Preferred APK:  $preferredPath"
            return $matches[0]
        }

        if ($NoUi) {
            throw "The configured preferred APK was not produced by this build: $preferredPath`nOpen Settings for this project and select an existing Preferred APK before running Build & Install from the dashboard."
        }

        Write-Warning "Configured preferred APK was not produced by this build: $preferredPath"
        Write-Warning 'Falling back to normal APK selection.'
    }

    return Select-ItemFromList -Prompt 'Multiple APKs were found. Choose the one to install:' -Items $Candidates -Label {
        param($item)
        $relative = $item.FullName.Substring($GradleRoot.Length).TrimStart('\')
        $sizeMb = [Math]::Round($item.Length / 1MB, 1)
        "$relative  ($sizeMb MB)"
    } -NoUiMessage 'Multiple APKs were produced and no unique preferred APK could be selected. Open Settings for this project and save the intended Preferred APK before running Build & Install from the dashboard.'
}

function Resolve-DeterministicApk {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Candidates,
        [string]$Preferred,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    if ($Preferred) {
        try {
            $preferredPath = if ([System.IO.Path]::IsPathRooted($Preferred)) {
                [System.IO.Path]::GetFullPath($Preferred)
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Preferred))
            }
            $preferredMatch = @($Candidates | Where-Object { $_.FullName -ieq $preferredPath })
            if ($preferredMatch.Count -eq 1) { return $preferredMatch[0] }
        }
        catch { }
    }

    if ($Candidates.Count -eq 1) { return $Candidates[0] }

    $conventional = @($Candidates | Where-Object {
        $_.FullName -match '(?i)\\app\\build\\outputs\\apk\\debug\\app-debug\.apk$'
    })
    if ($conventional.Count -eq 1) { return $conventional[0] }

    return $null
}

if (-not $Project) {
    if ($NoUi) { throw 'A project path is required when running without interactive UI.' }
    $Project = Select-Folder -Description 'Choose an Android project or repository folder'
    if (-not $Project) {
        Write-Host 'Cancelled.'
        if ($NoProcessExit) { return }
        exit 0
    }
}

try {
    $Project = [System.IO.Path]::GetFullPath($Project)
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        throw "The project path is not a directory:`n$Project"
    }

    if ([string]::IsNullOrWhiteSpace($GradleTask)) { $GradleTask = 'assembleDebug' }

    $gradleRoots = @(Get-GradleRoots -Root $Project)
    if ($gradleRoots.Count -eq 0) {
        throw "No supported project was found. Select a Godot/Gradle folder or configure android-build-install.json for a custom build.`n`nSelected directory:`n$Project"
    }
    $gradleRoot = Select-ItemFromList -Prompt 'Multiple build projects were found. Choose the Android project to build:' -Items $gradleRoots -Label { param($item) $item } `
        -NoUiMessage 'Multiple build roots were found. Add and select the specific Android project folder containing the intended build configuration, rather than its parent repository, before running Build & Install from the dashboard.'
    $plan = Get-AndroidBuildPlan -Root $gradleRoot
    Assert-AndroidBackendApkPreference -Plan $plan -ProjectRoot $Project -Preferred $PreferredApk

    $needsDevice = (-not $SkipInstall) -or $AutoLaunch
    $adb = $null
    $device = $null
    if ($needsDevice) {
        $adb = Resolve-Adb -GradleRoot $gradleRoot
        if (-not $adb) {
            throw 'adb.exe could not be found. Install Android SDK Platform-Tools or configure the Android SDK path.'
        }
        $device = Resolve-Device -Adb $adb -RequestedSerial $DeviceSerial
        $env:ANDROID_SERIAL = $device.Serial
    }

    $java = '(not needed)'
    if (-not $SkipBuild -and ($plan.Backend -eq 'gradle' -or $JavaHome)) {
        $java = Resolve-Java -OverrideJavaHome $JavaHome
    }

    Write-Host ''
    Write-Host 'DroidRun'
    Write-Host '========================='
    Write-Host ''
    Write-Host "Selected folder: $Project"
    Write-Host "Build root:      $gradleRoot"
    Write-Host "Build backend:   $($plan.Backend)"
    Write-Host "Gradle task:     $GradleTask"
    Write-Host "Java:            $java"
    Write-Host "Build:           $(if ($SkipBuild) { 'skip' } else { 'run' })"
    Write-Host "Install:         $(if ($SkipInstall) { 'skip' } else { 'run' })"
    if ($needsDevice) {
        Write-Host "adb:             $adb"
        Write-Host "Device:          $($device.Model) [$($device.Serial)]"
    }
    Write-Host "Auto-launch:     $([bool]$AutoLaunch)"
    if ($PreferredApk) { Write-Host "APK preference:  $PreferredApk" }
    Write-Host ''

    if (-not $SkipBuild) {
        $buildCommand = Resolve-AndroidBuildCommand -Plan $plan -GradleTask $GradleTask
        $previousOutput = $null
        if ($plan.Apk) {
            if (Test-Path -LiteralPath $plan.Apk -PathType Leaf) {
                $old = Get-Item -LiteralPath $plan.Apk
                $previousOutput = @($old.LastWriteTimeUtc.Ticks, $old.Length)
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $plan.Apk)) | Out-Null
        }
        Push-Location $gradleRoot
        try {
            Write-Host "Running: $($buildCommand.Executable) $($buildCommand.Arguments -join ' ')"
            Write-Host ''
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $buildArguments = @($buildCommand.Arguments)
                & $buildCommand.Executable @buildArguments
                $gradleExitCode = [int]$LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
        }
        finally {
            Pop-Location
        }

        if ($gradleExitCode -ne 0) {
            throw "$($plan.Backend) failed with exit code $gradleExitCode. The APK was not installed."
        }
    }
    else {
        Write-Host 'Skipping build and reusing existing APK output.'
    }

    if (-not $SkipBuild -and $plan.Apk) {
        if (-not (Test-Path -LiteralPath $plan.Apk -PathType Leaf)) { throw 'Build did not produce the configured APK; refusing to install old output.' }
        $current = Get-Item -LiteralPath $plan.Apk
        if ($current.Length -eq 0 -or ($null -ne $previousOutput -and $current.LastWriteTimeUtc.Ticks -eq $previousOutput[0] -and $current.Length -eq $previousOutput[1])) {
            throw 'Build did not update the configured APK; refusing to install old output.'
        }
    }

    $apkCandidates = @(Get-ApkCandidates -GradleRoot $gradleRoot)
    if ($apkCandidates.Count -eq 0) {
        throw "No APK was found at the expected build output."
    }

    # A pure build-only stage does not need to choose an APK. This is important
    # for Sync & Run: a project may legitimately produce multiple APKs, and the
    # later status/scan stage can apply its deterministic preferred/conventional
    # APK policy without prompting during the build itself.
    $needsSelectedApk = (-not $SkipInstall) -or $AutoLaunch
    $apk = $null
    if ($needsSelectedApk) {
        $apk = Resolve-Apk -Candidates $apkCandidates -Preferred $PreferredApk -ProjectRoot $Project -GradleRoot $gradleRoot
    }

    # A successful Gradle invocation validates an unchanged UP-TO-DATE APK as
    # well as a newly written one. Mark only the deterministically selected
    # output at build completion so the conservative freshness check does not
    # request the same successful build forever. This changes file metadata,
    # not APK bytes or signatures.
    if (-not $SkipBuild) {
        $validatedApk = if ($null -ne $apk) {
            $apk
        } else {
            Resolve-DeterministicApk -Candidates $apkCandidates -Preferred $PreferredApk -ProjectRoot $Project
        }

        if ($null -ne $validatedApk) {
            $validatedAt = [DateTime]::UtcNow
            $validatedApk.LastWriteTimeUtc = $validatedAt
            Write-Host "Build freshness: validated $($validatedApk.FullName) at $($validatedAt.ToString('o'))"
        }
        else {
            Write-Warning 'Build freshness was not recorded because no deterministic APK target could be identified.'
        }
    }

    $installSummary = 'Install skipped.'
    if (-not $SkipInstall) {
        Write-Host ''
        Write-Host "Installing: $($apk.FullName)"
        Write-Host ''
        $install = Invoke-NativeCaptured -FilePath $adb -Arguments @('-s', $device.Serial, 'install', '-r', $apk.FullName)
        foreach ($line in $install.Output) { Write-Host $line }

        if ($install.ExitCode -ne 0) {
            $combined = $install.Output -join [Environment]::NewLine
            if ($combined -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
                throw "Android rejected the update because the installed app has a different signing key. The tool will not uninstall it automatically because uninstalling would remove its app data."
            }
            throw "adb install failed with exit code $($install.ExitCode).`n`n$combined"
        }
        $installSummary = 'APK installed with adb install -r.'
    }
    else {
        Write-Host 'Skipping APK installation.'
    }

    $launchSummary = 'Auto-launch disabled.'
    if ($AutoLaunch) {
        $inspector = Resolve-ApkInspector -GradleRoot $gradleRoot
        $packageId = if ($inspector) { Get-PackageId -Apk $apk -Inspector $inspector } else { $null }

        if (-not $packageId) {
            $launchSummary = 'The package ID could not be determined for auto-launch.'
            Write-Warning $launchSummary
        }
        else {
            Write-Host ''
            Write-Host "Launching package: $packageId"
            $launch = Invoke-NativeCaptured -FilePath $adb -Arguments @(
                '-s', $device.Serial,
                'shell', 'monkey',
                '-p', $packageId,
                '-c', 'android.intent.category.LAUNCHER',
                '1'
            )
            foreach ($line in $launch.Output) { Write-Host $line }

            $launchText = $launch.Output -join [Environment]::NewLine
            if ($launch.ExitCode -eq 0 -and $launchText -notmatch '(?i)No activities found') {
                $launchSummary = "Launched $packageId."
            }
            else {
                $launchSummary = "Auto-launch failed for $packageId."
                Write-Warning $launchSummary
            }
        }
    }

    $buildSummary = if ($SkipBuild) { 'Build skipped; existing APK reused.' } else { "$($plan.Backend) build completed successfully." }
    $deviceSummary = if ($null -ne $device) { "Device: $($device.Model) [$($device.Serial)]" } else { 'Device: not required for this stage.' }
    $apkSummary = if ($null -ne $apk) { $apk.Name } else { "($($apkCandidates.Count) APK output(s) available)" }
    $successMessage = @"
Android operation completed successfully.

$buildSummary
$installSummary
$launchSummary
$deviceSummary
APK: $apkSummary
Gradle task: $GradleTask
"@

    Write-Host ''
    Write-Host 'Success.'
    if (-not $SuppressSuccessDialog) { Show-Info $successMessage }
    if ($NoProcessExit) { return }
    exit 0
}
catch {
    Show-Error $_.Exception.Message
    if ($NoProcessExit) { throw }
    exit 1
}
