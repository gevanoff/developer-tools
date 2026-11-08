# Planning, extraction, and cleanup for the Google Drive ZIP merger.
# No Windows Forms: the window in Merge-GoogleDriveZips.ps1 runs these functions
# on a background runspace, and Test-MergeGoogleDriveZips.ps1 runs them directly.

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ZipMergeFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return $full
}

function Format-ZipMergeSize {
    param([double]$Bytes)
    $units = @('bytes', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    while ($Bytes -ge 1024 -and $index -lt $units.Count - 1) { $Bytes /= 1024; $index++ }
    if ($index -eq 0) { return "$([int]$Bytes) bytes" }
    return ('{0:0.#} {1}' -f $Bytes, $units[$index])
}

function Get-ZipMergeSource {
    # The ZIP files directly inside Source, in filename order, with their entry counts.
    param([Parameter(Mandatory = $true)][string]$Source)

    $Source = Get-ZipMergeFullPath -Path $Source
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "The ZIP folder does not exist: $Source" }

    $zips = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Filter '*.zip' -File | Sort-Object Name)) {
        $entries = 0
        $bytes = [long]0
        $archive = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
        try {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                $entries++
                $bytes += $entry.Length
            }
        }
        finally { $archive.Dispose() }
        $zips.Add([pscustomobject]@{ Name = $file.Name; FullName = $file.FullName; Length = $file.Length; Entries = $entries; Bytes = $bytes })
    }

    return [pscustomobject]@{
        Source = $Source
        Zips = $zips.ToArray()
        ZipBytes = [long](($zips | Measure-Object -Property Length -Sum).Sum)
        Entries = [int](($zips | Measure-Object -Property Entries -Sum).Sum)
        Bytes = [long](($zips | Measure-Object -Property Bytes -Sum).Sum)
    }
}

function Get-ZipMergeTargetPath {
    # Where an entry lands, or $null when the archive path would escape the destination.
    param([string]$Destination, [string]$EntryPath)
    $prefix = $Destination.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $relative = $EntryPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
    try { $target = [System.IO.Path]::GetFullPath((Join-Path $Destination $relative)) }
    catch { return $null }
    if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $target
}

function Get-ZipMergePlan {
    # Checks every entry before anything is written: unsafe paths stop the merge up
    # front, and files that already exist (or repeat across ZIPs) are counted.
    param(
        [Parameter(Mandatory = $true)]$SourceInfo,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $Destination = Get-ZipMergeFullPath -Path $Destination
    if (Test-Path -LiteralPath $Destination -PathType Leaf) { throw "The destination is a file, not a folder: $Destination" }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $existing = 0
    $repeated = 0
    $unsafe = New-Object System.Collections.Generic.List[string]
    foreach ($zip in $SourceInfo.Zips) {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
        try {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                $target = Get-ZipMergeTargetPath -Destination $Destination -EntryPath $entry.FullName
                if ($null -eq $target) {
                    if ($unsafe.Count -lt 20) { $unsafe.Add("$($zip.Name): $($entry.FullName)") }
                    continue
                }
                if (-not $seen.Add($target)) { $repeated++ }
                elseif ([System.IO.File]::Exists($target)) { $existing++ }
            }
        }
        finally { $archive.Dispose() }
    }

    return [pscustomobject]@{
        Source = $SourceInfo.Source
        Destination = $Destination
        DestinationExists = (Test-Path -LiteralPath $Destination -PathType Container)
        Zips = $SourceInfo.Zips
        Entries = $SourceInfo.Entries
        Bytes = $SourceInfo.Bytes
        ZipBytes = $SourceInfo.ZipBytes
        Existing = $existing
        Repeated = $repeated
        Unsafe = $unsafe.ToArray()
    }
}

function New-ZipMergeState {
    # Shared between the window and the extraction runspace.
    $state = [hashtable]::Synchronized(@{})
    $state.Cancel = $false
    $state.ZipIndex = 0
    $state.ZipName = ''
    $state.Files = 0
    $state.Bytes = [long]0
    $state.Replaced = 0
    $state.Finished = $false
    $state.Outcome = ''      # Completed, Stopped, or Failed
    $state.Error = ''
    $state.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    return $state
}

function Invoke-ZipMerge {
    # Extracts every ZIP in the plan into the destination. Existing files are
    # replaced (and logged). Setting State.Cancel stops after the current file.
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    try {
        if ($Plan.Unsafe.Count -gt 0) { throw "Unsafe path in archive $($Plan.Unsafe[0])" }
        New-Item -ItemType Directory -Path $Plan.Destination -Force | Out-Null
        $index = 0
        foreach ($zip in $Plan.Zips) {
            $index++
            $State.ZipIndex = $index
            $State.ZipName = $zip.Name
            $State.Log.Enqueue("[$index/$($Plan.Zips.Count)] $($zip.Name)")
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
            try {
                foreach ($entry in $archive.Entries) {
                    if ($State.Cancel) {
                        $State.Outcome = 'Stopped'
                        $State.Log.Enqueue('Stopped before the next file. The original ZIP files have not been deleted.')
                        return
                    }
                    if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                    $target = Get-ZipMergeTargetPath -Destination $Plan.Destination -EntryPath $entry.FullName
                    if ($null -eq $target) { throw "Unsafe path in archive '$($zip.Name)': $($entry.FullName)" }
                    $directory = Split-Path -Parent $target
                    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
                    if ([System.IO.File]::Exists($target)) {
                        $State.Replaced++
                        $State.Log.Enqueue("    Replaced: $($entry.FullName)")
                    }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                    $State.Files++
                    $State.Bytes += $entry.Length
                }
            }
            finally { $archive.Dispose() }
        }
        $State.Outcome = 'Completed'
        $State.Log.Enqueue("Done: $($State.Files) files extracted from $($Plan.Zips.Count) ZIP files; $($State.Replaced) existing files replaced.")
    }
    catch {
        $State.Outcome = 'Failed'
        $State.Error = $_.Exception.Message
        $State.Log.Enqueue("Stopped by an error: $($_.Exception.Message)")
        $State.Log.Enqueue('The original ZIP files have not been deleted.')
    }
    finally {
        $State.Finished = $true
    }
}

function Remove-ZipMergeSources {
    # Deletes the source ZIPs, only after a completed merge. Returns the number deleted.
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$State
    )
    if ($State.Outcome -ne 'Completed') { throw 'The original ZIP files are deleted only after every ZIP was extracted.' }
    $deleted = 0
    foreach ($zip in $Plan.Zips) {
        if (Test-Path -LiteralPath $zip.FullName -PathType Leaf) {
            Remove-Item -LiteralPath $zip.FullName
            $deleted++
        }
    }
    return $deleted
}
