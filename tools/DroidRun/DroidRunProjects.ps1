# Project discovery, display names, and refresh scope for the dashboard.
# No Windows Forms, so it can be tested under PowerShell 7 on Linux. The Linux
# dashboard has the same rules in android_build_install_linux/projects.py.
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')

$script:DroidRunSkippedFolders = @('.git', '.gradle', '.godot', '.idea', 'build', 'node_modules', 'out', '.venv', 'venv')
$script:DroidRunNameLimit = 80

function Test-DroidRunBuildRoot {
    param([string]$Path)
    foreach ($marker in @('android-build-install.json', 'project.godot', 'gradlew.bat')) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker) -PathType Leaf) { return $true }
    }
    return $false
}

function Get-DroidRunChildFolders {
    param([string]$Path)
    @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notin $script:DroidRunSkippedFolders -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        } | Sort-Object Name)
}

function Test-DroidRunAndroidManifest {
    param([string]$Root, [int]$MaxDepth = 4)
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@{ Path = $Root; Depth = 0 })
    $seen = 0
    while ($queue.Count -gt 0 -and $seen -lt 600) {
        $node = $queue.Dequeue()
        $seen++
        if (Test-Path -LiteralPath (Join-Path $node.Path 'AndroidManifest.xml') -PathType Leaf) { return $true }
        if ($node.Depth -ge $MaxDepth) { continue }
        foreach ($child in Get-DroidRunChildFolders -Path $node.Path) {
            $queue.Enqueue(@{ Path = $child.FullName; Depth = $node.Depth + 1 })
        }
    }
    return $false
}

function Get-DroidRunProjectKind {
    # Returns Kind, Note (why it may not build yet), and Recommended (pre-checked).
    param([string]$Root)
    if (Test-Path -LiteralPath (Join-Path $Root 'android-build-install.json') -PathType Leaf) {
        try { $config = Get-AndroidBuildConfig -Root $Root }
        catch {
            return [pscustomobject]@{ Kind = 'Custom build'; Note = 'Its build configuration has errors; fix it in Settings.'; Recommended = $false }
        }
        $kind = switch ("$($config.backend)".ToLowerInvariant()) { 'godot' { 'Godot' } 'gradle' { 'Gradle' } default { 'Custom build' } }
        return [pscustomobject]@{ Kind = $kind; Note = ''; Recommended = $true }
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'project.godot') -PathType Leaf) {
        $presets = @()
        try { $presets = @(Get-GodotAndroidPresets -Root $Root) } catch { $presets = @() }
        if ($presets.Count -gt 0) { return [pscustomobject]@{ Kind = 'Godot'; Note = ''; Recommended = $true } }
        return [pscustomobject]@{ Kind = 'Godot'; Note = 'No Android export preset yet (Project > Export in Godot).'; Recommended = $false }
    }
    if (Test-DroidRunAndroidManifest -Root $Root) {
        return [pscustomobject]@{ Kind = 'Gradle'; Note = ''; Recommended = $true }
    }
    return [pscustomobject]@{ Kind = 'Gradle'; Note = 'No Android app module found (no AndroidManifest.xml).'; Recommended = $false }
}

function Find-DroidRunProjects {
    # Build roots at or beneath Folder (deeper than build selection, which stops at
    # two levels). A root is not searched further. When nothing is beneath, the
    # nearest enclosing root (up to four levels up) is offered instead.
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [int]$MaxDepth = 4,
        [int]$FolderLimit = 4000
    )

    $start = [IO.Path]::GetFullPath($Folder)
    if ($start.Length -gt ([IO.Path]::GetPathRoot($start)).Length) {
        $start = $start.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    $found = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@{ Path = $start; Depth = 0 })
    $visited = 0
    $truncated = $false
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $visited++
        if ($visited -gt $FolderLimit) { $truncated = $true; break }
        if (Test-DroidRunBuildRoot -Path $node.Path) { $found.Add($node.Path); continue }
        if ($node.Depth -ge $MaxDepth) { continue }
        foreach ($child in Get-DroidRunChildFolders -Path $node.Path) {
            $queue.Enqueue(@{ Path = $child.FullName; Depth = $node.Depth + 1 })
        }
    }

    $outside = $false
    if ($found.Count -eq 0) {
        $parent = Split-Path -Parent $start
        for ($level = 0; $level -lt 4 -and $parent; $level++) {
            if (Test-DroidRunBuildRoot -Path $parent) { $found.Add($parent); $outside = $true; break }
            $parent = Split-Path -Parent $parent
        }
    }

    $candidates = foreach ($root in $found) {
        $info = Get-DroidRunProjectKind -Root $root
        $relative = if ($outside) { $root }
            elseif ($root -eq $start) { '.' }
            else { $root.Substring($start.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
        [pscustomobject]@{
            Path = $root
            Relative = $relative
            Kind = $info.Kind
            Note = $info.Note
            Recommended = $info.Recommended
            Outside = $outside
        }
    }
    $sorted = @($candidates | Sort-Object { $_.Relative.ToLowerInvariant() })
    return [pscustomobject]@{ Root = $start; Candidates = $sorted; Truncated = $truncated }
}

function ConvertTo-DroidRunName {
    # Collapse whitespace, drop control characters, and cap the length.
    param([AllowNull()][AllowEmptyString()][string]$Name)
    $text = [regex]::Replace("$Name", '[\x00-\x1f\x7f]', ' ')
    $text = ([regex]::Replace($text, '\s+', ' ')).Trim()
    if ($text.Length -gt $script:DroidRunNameLimit) { $text = $text.Substring(0, $script:DroidRunNameLimit).TrimEnd() }
    return $text
}

function Get-DroidRunProjectNames {
    # Path -> display name, read from project-names.json ({ "names": { path: name } }).
    param([Parameter(Mandatory = $true)][string]$NamesPath)
    $names = @{}
    if (-not (Test-Path -LiteralPath $NamesPath -PathType Leaf)) { return $names }
    try { $json = Get-Content -LiteralPath $NamesPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $names }
    if ($null -eq $json -or $json -isnot [pscustomobject] -or $null -eq $json.names) { return $names }
    foreach ($property in $json.names.PSObject.Properties) {
        $value = ConvertTo-DroidRunName -Name "$($property.Value)"
        if ($value) { $names[$property.Name.ToLowerInvariant()] = $value }
    }
    return $names
}

function Get-DroidRunProjectName {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Names,
        [string]$NamesPath
    )
    if ($null -eq $Names) {
        if (-not $NamesPath) { return Split-Path -Leaf $Path }
        $Names = Get-DroidRunProjectNames -NamesPath $NamesPath
    }
    $key = "$Path".ToLowerInvariant()
    if ($Names.ContainsKey($key)) { return $Names[$key] }
    return Split-Path -Leaf $Path
}

function Set-DroidRunProjectName {
    # Saves a display name; an empty name or the folder name removes the override.
    # Returns the name that will be shown.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $true)][string]$NamesPath
    )
    $value = ConvertTo-DroidRunName -Name $Name
    $folderName = Split-Path -Leaf $Path
    $names = Get-DroidRunProjectNames -NamesPath $NamesPath
    $key = $Path.ToLowerInvariant()
    if (-not $value -or $value -ceq $folderName) { $names.Remove($key) } else { $names[$key] = $value }

    $ordered = [ordered]@{}
    foreach ($entry in ($names.GetEnumerator() | Sort-Object Name)) { $ordered[$entry.Name] = $entry.Value }
    $parent = Split-Path -Parent $NamesPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = "$NamesPath.tmp"
    [pscustomobject]@{ names = [pscustomobject]$ordered } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $NamesPath -Force
    if ($value) { return $value }
    return $folderName
}

function Get-DroidRunRefreshTargets {
    # Selected projects in list order; every project when nothing is selected.
    param([string[]]$Projects = @(), [string[]]$Selected = @())
    $subset = @($Projects | Where-Object { $project = $_; @($Selected | Where-Object { $_ -ieq $project }).Count -gt 0 })
    # Callers wrap the result in @() so a single project stays an array.
    if ($subset.Count -gt 0) { return $subset }
    return @($Projects)
}

function Get-DroidRunRefreshLabel {
    param([int]$SelectedCount)
    if ($SelectedCount -le 0) { return 'Re&fresh All' }
    if ($SelectedCount -eq 1) { return 'Re&fresh Selected' }
    return "Re&fresh $SelectedCount Selected"
}
