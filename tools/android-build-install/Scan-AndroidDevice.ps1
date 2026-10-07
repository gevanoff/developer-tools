[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Project,
    [string]$DeviceSerial,
    [string]$PreferredApk,
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')
. (Join-Path $PSScriptRoot 'AndroidFileHash.ps1')

# Windows PowerShell 5.1 can bind a single null/empty placeholder to a
# ValueFromRemainingArguments array even when the caller supplied no trailing
# arguments. Remove only those binder placeholders before validating the
# defensive legacy call shape below.
$remainingTokens = @($RemainingArguments | Where-Object {
    $null -ne $_ -and -not [string]::IsNullOrEmpty([string]$_)
})

# Array splatting into another PowerShell script treats strings such as
# '-Project' as positional values rather than reparsing them as named
# parameters. Recover that malformed call shape defensively so a bad internal
# handoff cannot turn a parameter name into a project path.
if ($Project.Count -eq 1 -and $Project[0] -eq '-Project' -and $DeviceSerial) {
    $legacyArguments = @('-Project', $DeviceSerial)
    if ($PreferredApk) { $legacyArguments += $PreferredApk }
    $legacyArguments += $remainingTokens

    $Project = @()
    $DeviceSerial = $null
    $PreferredApk = $null
    $RemainingArguments = @()

    for ($i = 0; $i -lt $legacyArguments.Count; $i++) {
        $token = [string]$legacyArguments[$i]
        switch ($token) {
            '-Project' {
                if (($i + 1) -ge $legacyArguments.Count) { throw 'Internal scanner call supplied -Project without a value.' }
                $i++
                $Project += [string]$legacyArguments[$i]
            }
            '-DeviceSerial' {
                if (($i + 1) -ge $legacyArguments.Count) { throw 'Internal scanner call supplied -DeviceSerial without a value.' }
                $i++
                $DeviceSerial = [string]$legacyArguments[$i]
            }
            '-PreferredApk' {
                if (($i + 1) -ge $legacyArguments.Count) { throw 'Internal scanner call supplied -PreferredApk without a value.' }
                $i++
                $PreferredApk = [string]$legacyArguments[$i]
            }
            default {
                throw "Unexpected internal scanner argument: $token"
            }
        }
    }
}
elseif ($remainingTokens.Count -gt 0) {
    throw "Unexpected positional scanner argument(s): $($remainingTokens -join ' ')"
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
    param([string]$GradleRoot)

    foreach ($root in @(Get-SdkRoots -GradleRoot $GradleRoot)) {
        $candidate = Join-Path $root 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Resolve-ApkInspector {
    param([string]$GradleRoot)

    foreach ($root in @(Get-SdkRoots -GradleRoot $GradleRoot)) {
        $buildTools = Join-Path $root 'build-tools'
        if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }

        $directories = @(Get-ChildItem -LiteralPath $buildTools -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($directory in $directories) {
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

function Resolve-DeviceSerial {
    param(
        [Parameter(Mandatory = $true)][string]$Adb,
        [string]$RequestedSerial
    )

    $devices = Invoke-NativeCaptured -FilePath $Adb -Arguments @('devices', '-l')
    if ($devices.ExitCode -ne 0) {
        throw "adb failed while listing devices: $($devices.Output -join ' ')"
    }

    $ready = @()
    foreach ($line in $devices.Output) {
        if ($line -match '^(\S+)\s+device\b') {
            $ready += $matches[1]
        }
    }

    if ($RequestedSerial) {
        if ($ready -notcontains $RequestedSerial) {
            throw "Device '$RequestedSerial' is not connected and authorized."
        }
        return $RequestedSerial
    }

    if ($ready.Count -eq 0) {
        throw 'No authorized Android device was found.'
    }
    if ($ready.Count -gt 1) {
        throw 'Multiple authorized Android devices are connected. Choose and remember a preferred device in project settings, disconnect extras, or run the scanner with -DeviceSerial.'
    }

    return $ready[0]
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
            $queue.Enqueue([pscustomobject]@{
                Path = $child.FullName
                Depth = $node.Depth + 1
            })
        }
    }

    $unique = @($apks | Sort-Object FullName -Unique)
    $debug = @($unique | Where-Object {
        $_.FullName -match '(?i)\\debug\\' -or $_.Name -match '(?i)debug.*\.apk$'
    })

    if ($debug.Count -gt 0) { return @($debug | Sort-Object LastWriteTime -Descending) }
    return @($unique | Sort-Object LastWriteTime -Descending)
}

function Resolve-LocalApk {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$GradleRoot,
        [string]$Preferred
    )

    Assert-AndroidBackendApkPreference -Plan (Get-AndroidBuildPlan -Root $GradleRoot) -ProjectRoot $ProjectRoot -Preferred $Preferred
    $candidates = @(Get-ApkCandidates -GradleRoot $GradleRoot)
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ Apk = $null; Detail = 'No local APK has been built.' }
    }

    if ($Preferred) {
        try {
            $preferredPath = if ([System.IO.Path]::IsPathRooted($Preferred)) {
                [System.IO.Path]::GetFullPath($Preferred)
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Preferred))
            }
            $match = @($candidates | Where-Object { $_.FullName -ieq $preferredPath })
            if ($match.Count -eq 1) {
                return [pscustomobject]@{ Apk = $match[0]; Detail = 'Using configured preferred APK.' }
            }
            return [pscustomobject]@{ Apk = $null; Detail = "Configured preferred APK is not present: $Preferred" }
        }
        catch {
            return [pscustomobject]@{ Apk = $null; Detail = "Configured preferred APK path is invalid: $Preferred" }
        }
    }

    if ($candidates.Count -eq 1) {
        return [pscustomobject]@{ Apk = $candidates[0]; Detail = '' }
    }

    $conventional = @($candidates | Where-Object {
        $_.FullName -match '(?i)\\app\\build\\outputs\\apk\\debug\\app-debug\.apk$'
    })
    if ($conventional.Count -eq 1) {
        return [pscustomobject]@{ Apk = $conventional[0]; Detail = 'Using conventional app-debug.apk.' }
    }

    return [pscustomobject]@{
        Apk = $null
        Detail = "Multiple local APKs are present ($($candidates.Count)); exact target is ambiguous."
    }
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

function New-ScanResult {
    param(
        [string]$ProjectPath,
        [string]$Status,
        [string]$PackageId = '',
        [string]$LocalApk = '',
        [string]$LocalHash = '',
        [string]$InstalledHash = '',
        [string]$Detail = '',
        [string]$Device = ''
    )

    return [pscustomobject]@{
        ProjectPath = $ProjectPath
        Project = Split-Path -Leaf $ProjectPath
        Status = $Status
        PackageId = $PackageId
        LocalApk = $LocalApk
        LocalHash = $LocalHash
        InstalledHash = $InstalledHash
        Detail = $Detail
        Device = $Device
    }
}

$validProjects = @($Project | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
if ($validProjects.Count -eq 0) { throw 'No valid saved project folders were supplied.' }
if ($PreferredApk -and $validProjects.Count -gt 1) {
    throw '-PreferredApk can only be used when scanning one project.'
}

$firstGradleRoot = $null
foreach ($projectPath in $validProjects) {
    $roots = @(Get-GradleRoots -Root $projectPath)
    if ($roots.Count -gt 0) { $firstGradleRoot = $roots[0]; break }
}

$adb = Resolve-Adb -GradleRoot $firstGradleRoot
if (-not $adb) { throw 'adb.exe could not be found.' }
$serial = Resolve-DeviceSerial -Adb $adb -RequestedSerial $DeviceSerial

$tempBase = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$tempRoot = Join-Path $tempBase 'WindowsTools\android-build-install\scan'
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

foreach ($projectPath in $validProjects) {
    $gradleRoots = @(Get-GradleRoots -Root $projectPath)
    if ($gradleRoots.Count -eq 0) {
        New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -Detail 'No supported project found; configure android-build-install.json for a custom build.' -Device $serial
        continue
    }
    if ($gradleRoots.Count -gt 1) {
        New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -Detail 'Multiple build roots found; scan target is ambiguous.' -Device $serial
        continue
    }

    $gradleRoot = $gradleRoots[0]
    try { $local = Resolve-LocalApk -ProjectRoot $projectPath -GradleRoot $gradleRoot -Preferred $PreferredApk }
    catch {
        New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -Detail $_.Exception.Message -Device $serial
        continue
    }
    if ($null -eq $local.Apk) {
        $status = if ($local.Detail -like 'No local APK*') { 'No local build' } else { 'Unknown' }
        New-ScanResult -ProjectPath $projectPath -Status $status -Detail $local.Detail -Device $serial
        continue
    }

    $inspector = Resolve-ApkInspector -GradleRoot $gradleRoot
    if ($null -eq $inspector) {
        New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -LocalApk $local.Apk.FullName -Detail 'Android build-tools package inspector (aapt/aapt2) was not found.' -Device $serial
        continue
    }

    $packageId = Get-PackageId -Apk $local.Apk -Inspector $inspector
    if (-not $packageId) {
        New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -LocalApk $local.Apk.FullName -Detail 'Could not read the APK package ID.' -Device $serial
        continue
    }

    $localHash = Get-AndroidFileSha256 -LiteralPath $local.Apk.FullName
    $paths = Invoke-NativeCaptured -FilePath $adb -Arguments @('-s', $serial, 'shell', 'pm', 'path', $packageId)
    if ($paths.ExitCode -ne 0) {
        New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -PackageId $packageId -LocalApk $local.Apk.FullName -LocalHash $localHash -Detail "adb failed while querying the installed package: $($paths.Output -join ' ')" -Device $serial
        continue
    }

    $installedPaths = @($paths.Output | ForEach-Object {
        if ($_ -match '^package:(.+)$') { $matches[1].Trim() }
    } | Where-Object { $_ })

    if ($installedPaths.Count -eq 0) {
        New-ScanResult -ProjectPath $projectPath -Status 'Not installed' -PackageId $packageId -LocalApk $local.Apk.FullName -LocalHash $localHash -Detail $local.Detail -Device $serial
        continue
    }

    if ($installedPaths.Count -gt 1) {
        New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -PackageId $packageId -LocalApk $local.Apk.FullName -LocalHash $localHash -Detail "Installed package uses $($installedPaths.Count) split APKs; exact byte comparison is not supported." -Device $serial
        continue
    }

    $tempApk = Join-Path $tempRoot ("{0}.apk" -f [Guid]::NewGuid().ToString('N'))
    try {
        $pull = Invoke-NativeCaptured -FilePath $adb -Arguments @('-s', $serial, 'pull', $installedPaths[0], $tempApk)
        if ($pull.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempApk -PathType Leaf)) {
            New-ScanResult -ProjectPath $projectPath -Status 'Unknown' -PackageId $packageId -LocalApk $local.Apk.FullName -LocalHash $localHash -Detail 'Installed APK is present but could not be pulled for hashing.' -Device $serial
            continue
        }

        $installedHash = Get-AndroidFileSha256 -LiteralPath $tempApk
        $status = if ($installedHash -eq $localHash) { 'Same' } else { 'Different' }
        $detail = "Local APK: $($local.Apk.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        if ($local.Detail) { $detail = "$detail. $($local.Detail)" }

        New-ScanResult -ProjectPath $projectPath -Status $status -PackageId $packageId -LocalApk $local.Apk.FullName -LocalHash $localHash -InstalledHash $installedHash -Detail $detail -Device $serial
    }
    finally {
        Remove-Item -LiteralPath $tempApk -Force -ErrorAction SilentlyContinue
    }
}
