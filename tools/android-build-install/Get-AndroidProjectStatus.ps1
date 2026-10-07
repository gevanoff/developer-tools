[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Project,
    [string]$PreferencesPath,
    [switch]$FetchRemote,
    [switch]$SkipDevice,
    [string]$OutputJsonPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')
$scanner = Join-Path $PSScriptRoot 'Scan-AndroidDevice.ps1'

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
        preferredApk = ''
        deviceSerial = ''
    }

    if (-not $PreferencesPath -or -not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) {
        return $default
    }

    try { $json = Get-Content -LiteralPath $PreferencesPath -Raw | ConvertFrom-Json } catch { return $default }
    $normalized = Normalize-Path -Path $ProjectPath

    foreach ($item in @($json.projects)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-Path -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $normalized) {
            return [pscustomobject]@{
                preferredApk = "$($item.preferredApk)"
                deviceSerial = "$($item.deviceSerial)"
            }
        }
    }

    return $default
}

function Get-GradleRoots {
    param([string]$Root, [int]$MaxDepth = 2)
    Get-AndroidProjectRoots -Root $Root -MaxDepth $MaxDepth
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
        [string]$PreferredApk
    )

    Assert-AndroidBackendApkPreference -Plan (Get-AndroidBuildPlan -Root $GradleRoot) -ProjectRoot $ProjectRoot -Preferred $PreferredApk
    $candidates = @(Get-ApkCandidates -GradleRoot $GradleRoot)
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ Apk = $null; Status = 'No APK'; Detail = 'No local APK has been built.' }
    }

    if ($PreferredApk) {
        try {
            $preferredPath = if ([System.IO.Path]::IsPathRooted($PreferredApk)) {
                [System.IO.Path]::GetFullPath($PreferredApk)
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $PreferredApk))
            }
            $match = @($candidates | Where-Object { $_.FullName -ieq $preferredPath })
            if ($match.Count -eq 1) {
                return [pscustomobject]@{ Apk = $match[0]; Status = ''; Detail = 'Using configured preferred APK.' }
            }
            return [pscustomobject]@{ Apk = $null; Status = 'Preferred missing'; Detail = "Preferred APK is not present in current build outputs: $PreferredApk" }
        }
        catch {
            return [pscustomobject]@{ Apk = $null; Status = 'Preferred invalid'; Detail = "Preferred APK path is invalid: $PreferredApk" }
        }
    }

    if ($candidates.Count -eq 1) {
        return [pscustomobject]@{ Apk = $candidates[0]; Status = ''; Detail = '' }
    }

    $conventional = @($candidates | Where-Object {
        $_.FullName -match '(?i)\\app\\build\\outputs\\apk\\debug\\app-debug\.apk$'
    })
    if ($conventional.Count -eq 1) {
        return [pscustomobject]@{ Apk = $conventional[0]; Status = ''; Detail = 'Using conventional app-debug.apk.' }
    }

    return [pscustomobject]@{
        Apk = $null
        Status = 'Ambiguous'
        Detail = "Multiple local debug APKs are present ($($candidates.Count)). Configure a preferred APK."
    }
}

function Get-NewestProjectInput {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $skipNames = @('.git', '.gradle', '.idea', '.vscode', 'build', 'node_modules', 'out')
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($ProjectRoot)
    $newest = $null

    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($child in Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue) {
            if ($child.PSIsContainer) {
                if ($skipNames -notcontains $child.Name) { $queue.Enqueue($child.FullName) }
                continue
            }

            if ($null -eq $newest -or $child.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc) {
                $newest = $child
            }
        }
    }

    return $newest
}

function Get-GitBranch {
    param([string]$ProjectPath)
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command git -ErrorAction SilentlyContinue }
    if ($null -eq $command) { return '' }
    $branch = Invoke-NativeCaptured -FilePath $command.Source -Arguments @('-C', $ProjectPath, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($branch.ExitCode -eq 0 -and $branch.Output.Count -gt 0) { return $branch.Output[-1].Trim() }
    $commit = Invoke-NativeCaptured -FilePath $command.Source -Arguments @('-C', $ProjectPath, 'rev-parse', '--short', 'HEAD')
    if ($commit.ExitCode -eq 0 -and $commit.Output.Count -gt 0) { return "detached @ $($commit.Output[-1].Trim())" }
    return ''
}

function Get-GitStatus {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction SilentlyContinue }
    if ($null -eq $gitCommand) {
        return [pscustomobject]@{ Status = 'Git unavailable'; Detail = 'Git was not found on PATH.' }
    }
    $git = $gitCommand.Source

    $root = Invoke-NativeCaptured -FilePath $git -Arguments @('-C', $ProjectPath, 'rev-parse', '--show-toplevel')
    if ($root.ExitCode -ne 0 -or $root.Output.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Not Git'; Detail = 'Project is not inside a Git repository.' }
    }
    $repoRoot = $root.Output[-1].Trim()

    $working = Invoke-NativeCaptured -FilePath $git -Arguments @('-C', $repoRoot, 'status', '--porcelain')
    if ($working.ExitCode -ne 0) {
        return [pscustomobject]@{ Status = 'Git error'; Detail = ($working.Output -join ' ') }
    }
    if (-not [string]::IsNullOrWhiteSpace(($working.Output -join ''))) {
        return [pscustomobject]@{ Status = 'Dirty'; Detail = 'Working tree has local changes.' }
    }

    $branchResult = Invoke-NativeCaptured -FilePath $git -Arguments @('-C', $repoRoot, 'branch', '--show-current')
    $branch = if ($branchResult.ExitCode -eq 0 -and $branchResult.Output.Count -gt 0) { $branchResult.Output[-1].Trim() } else { '' }
    if (-not $branch) {
        return [pscustomobject]@{ Status = 'Detached'; Detail = 'Repository is in detached HEAD state.' }
    }

    $upstreamResult = Invoke-NativeCaptured -FilePath $git -Arguments @('-C', $repoRoot, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if ($upstreamResult.ExitCode -ne 0 -or $upstreamResult.Output.Count -eq 0) {
        return [pscustomobject]@{ Status = 'No upstream'; Detail = "Branch '$branch' has no upstream." }
    }
    $upstream = $upstreamResult.Output[-1].Trim()

    if ($FetchRemote) {
        $fetch = Invoke-NativeCaptured -FilePath $git -Arguments @('-C', $repoRoot, 'fetch', '--quiet')
        if ($fetch.ExitCode -ne 0) {
            return [pscustomobject]@{ Status = 'Fetch failed'; Detail = ($fetch.Output -join ' ') }
        }
    }

    $counts = Invoke-NativeCaptured -FilePath $git -Arguments @('-C', $repoRoot, 'rev-list', '--left-right', '--count', 'HEAD...@{u}')
    if ($counts.ExitCode -ne 0 -or $counts.Output.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Git error'; Detail = ($counts.Output -join ' ') }
    }

    $parts = @($counts.Output[-1].Trim() -split '\s+')
    if ($parts.Count -lt 2) {
        return [pscustomobject]@{ Status = 'Git error'; Detail = 'Could not parse ahead/behind counts.' }
    }

    $ahead = [int]$parts[0]
    $behind = [int]$parts[1]
    if ($ahead -gt 0 -and $behind -gt 0) {
        return [pscustomobject]@{ Status = "Diverged $ahead/$behind"; Detail = "$branch differs from $upstream in both directions." }
    }
    if ($behind -gt 0) {
        return [pscustomobject]@{ Status = "Behind $behind"; Detail = "$branch is behind $upstream by $behind commit(s)." }
    }
    if ($ahead -gt 0) {
        return [pscustomobject]@{ Status = "Ahead $ahead"; Detail = "$branch is ahead of $upstream by $ahead commit(s)." }
    }

    return [pscustomobject]@{ Status = 'Current'; Detail = "$branch matches $upstream." }
}

$results = @(
foreach ($projectItem in @($Project)) {
    if ([string]::IsNullOrWhiteSpace($projectItem)) { continue }
    $gitBranch = ''
    $gitStatus = $null

    try {
        $projectPath = Normalize-Path -Path $projectItem
        if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
            [pscustomobject]@{
                ProjectPath = $projectPath; Project = Split-Path -Leaf $projectPath
                GitStatus = 'Missing'; GitBranch = ''; GitDetail = 'Project directory does not exist.'
                BuildStatus = 'Unknown'; BuildDetail = ''
                DeviceStatus = 'Unknown'; DeviceDetail = ''
                Device = ''
            }
            continue
        }

        $preference = Get-Preference -ProjectPath $projectPath
        $gitBranch = Get-GitBranch -ProjectPath $projectPath
        $gitStatus = Get-GitStatus -ProjectPath $projectPath

        $gradleRoots = @(Get-GradleRoots -Root $projectPath)
        if ($gradleRoots.Count -eq 0) {
            $buildStatus = [pscustomobject]@{ Status = 'No project'; Detail = 'No supported project found; configure android-build-install.json for a custom build.'; Apk = $null }
        }
        elseif ($gradleRoots.Count -gt 1) {
            $buildStatus = [pscustomobject]@{ Status = 'Ambiguous'; Detail = 'Multiple build roots found; select the specific project folder.'; Apk = $null }
        }
        else {
            $local = Resolve-LocalApk -ProjectRoot $projectPath -GradleRoot $gradleRoots[0] -PreferredApk $preference.preferredApk
            if ($null -eq $local.Apk) {
                $buildStatus = [pscustomobject]@{ Status = $local.Status; Detail = $local.Detail; Apk = $null }
            }
            elseif ((Get-AndroidBuildPlan -Root $gradleRoots[0]).Backend -ne 'gradle') {
                $buildStatus = [pscustomobject]@{
                    Status = 'Stale'; Detail = 'Export/build required; dependency freshness is delegated to the builder.'; Apk = $local.Apk
                }
            }
            else {
                $newest = Get-NewestProjectInput -ProjectRoot $projectPath
                if ($null -ne $newest -and $newest.LastWriteTimeUtc -gt $local.Apk.LastWriteTimeUtc) {
                    $relative = $newest.FullName.Substring($projectPath.Length).TrimStart('\')
                    $buildStatus = [pscustomobject]@{
                        Status = 'Stale'
                        Detail = "Newer project file: $relative"
                        Apk = $local.Apk
                    }
                }
                else {
                    $buildStatus = [pscustomobject]@{
                        Status = 'Fresh'
                        Detail = "APK: $($local.Apk.Name) ($($local.Apk.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
                        Apk = $local.Apk
                    }
                }
            }
        }

        $deviceStatus = 'Not checked'
        $deviceDetail = ''
        $device = $preference.deviceSerial

        if (-not $SkipDevice) {
            try {
                $scanParameters = @{
                    Project = @($projectPath)
                }
                if ($preference.deviceSerial) { $scanParameters.DeviceSerial = $preference.deviceSerial }
                if ($preference.preferredApk) { $scanParameters.PreferredApk = $preference.preferredApk }

                $scan = @(& $scanner @scanParameters)
                if ($scan.Count -gt 0) {
                    $deviceStatus = [string]$scan[0].Status
                    $deviceDetail = [string]$scan[0].Detail
                    $device = [string]$scan[0].Device
                }
            }
            catch {
                $message = $_.Exception.Message
                if ($message -like 'No authorized Android device*') { $deviceStatus = 'No device' }
                elseif ($message -like 'Multiple authorized Android devices*') { $deviceStatus = 'Choose device' }
                elseif ($message -like "Device '*' is not connected and authorized*") { $deviceStatus = 'Preferred absent' }
                else { $deviceStatus = 'Unknown' }
                $deviceDetail = $message
            }
        }

        [pscustomobject]@{
            ProjectPath = $projectPath
            Project = Split-Path -Leaf $projectPath
            GitStatus = $gitStatus.Status
            GitBranch = $gitBranch
            GitDetail = $gitStatus.Detail
            BuildStatus = $buildStatus.Status
            BuildDetail = $buildStatus.Detail
            DeviceStatus = $deviceStatus
            DeviceDetail = $deviceDetail
            Device = $device
        }
    }
    catch {
        [pscustomobject]@{
            ProjectPath = "$projectItem"
            Project = Split-Path -Leaf "$projectItem"
            GitStatus = if ($null -ne $gitStatus) { $gitStatus.Status } else { 'Unknown' }
            GitBranch = $gitBranch
            GitDetail = if ($null -ne $gitStatus) { $gitStatus.Detail } else { $_.Exception.Message }
            BuildStatus = 'Unknown'; BuildDetail = $_.Exception.Message
            DeviceStatus = 'Unknown'; DeviceDetail = $_.Exception.Message
            Device = ''
        }
    }
}
)

if ($OutputJsonPath) {
    $outputParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputJsonPath))
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        throw "Status output directory does not exist: $outputParent"
    }
    $json = ConvertTo-Json -InputObject @($results) -Depth 4
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($OutputJsonPath),
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}
else {
    $results
}
