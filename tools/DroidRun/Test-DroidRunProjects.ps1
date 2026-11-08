[CmdletBinding()]
param()

# Checks project discovery, display names, and refresh scope. Needs no device or
# Windows Forms, so it also runs under PowerShell 7 on Linux.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DroidRunProjects.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $failures.Add($Message) }
}
function New-TestFile {
    param([string]$Path, [string]$Text = '')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

$sep = [IO.Path]::DirectorySeparatorChar
$root = Join-Path ([IO.Path]::GetTempPath()) ("DroidRun projects test $([Guid]::NewGuid().ToString('N'))")
try {
    $repo = Join-Path $root 'my repo'
    New-TestFile (Join-Path $repo 'android app\gradlew.bat'.Replace('\', $sep))
    New-TestFile (Join-Path $repo 'android app\app\src\main\AndroidManifest.xml'.Replace('\', $sep))
    New-TestFile (Join-Path $repo 'games\space\project.godot'.Replace('\', $sep))
    New-TestFile (Join-Path $repo 'games\space\export_presets.cfg'.Replace('\', $sep)) "[preset.0]`nname=`"Android`"`nplatform=`"Android`""
    New-TestFile (Join-Path $repo 'tools\flutter\android-build-install.json'.Replace('\', $sep)) '{"version": 1, "backend": "custom", "executable": "flutter", "apk": "a.apk"}'
    New-TestFile (Join-Path $repo 'server\gradlew.bat'.Replace('\', $sep))
    New-TestFile (Join-Path $repo 'node_modules\x\gradlew.bat'.Replace('\', $sep))
    New-TestFile (Join-Path $repo 'a\b\c\d\e\gradlew.bat'.Replace('\', $sep))

    $found = Find-DroidRunProjects -Folder $repo
    $byRelative = @{}
    foreach ($candidate in $found.Candidates) { $byRelative[$candidate.Relative] = $candidate }
    $expected = @('android app', "games${sep}space", "tools${sep}flutter", 'server')
    Assert-True ($found.Candidates.Count -eq 4) "Expected 4 candidates, found: $(@($found.Candidates.Relative) -join ', ')"
    foreach ($name in $expected) { Assert-True $byRelative.ContainsKey($name) "Missing candidate '$name'." }
    Assert-True ($byRelative['android app'].Kind -eq 'Gradle' -and $byRelative['android app'].Recommended) 'Android Gradle project was not recommended.'
    Assert-True ($byRelative["games${sep}space"].Kind -eq 'Godot' -and $byRelative["games${sep}space"].Recommended) 'Godot project with an Android preset was not recommended.'
    Assert-True ($byRelative["tools${sep}flutter"].Kind -eq 'Custom build') 'Custom build kind was not detected.'
    Assert-True (-not $byRelative['server'].Recommended -and $byRelative['server'].Note -like '*AndroidManifest*') 'A Gradle project without Android was recommended.'
    Assert-True (-not $found.Truncated) 'A small search was reported as truncated.'

    $self = Find-DroidRunProjects -Folder (Join-Path $repo 'games')
    Assert-True ($self.Candidates.Count -eq 1 -and $self.Candidates[0].Relative -eq 'space') 'A nested project was not found from its parent.'

    $module = Join-Path $repo 'android app\app\src'.Replace('\', $sep)
    $enclosing = Find-DroidRunProjects -Folder $module
    Assert-True ($enclosing.Candidates.Count -eq 1 -and $enclosing.Candidates[0].Outside -and
        $enclosing.Candidates[0].Path -eq (Join-Path $repo 'android app')) 'A module folder did not offer its enclosing project.'

    $godotOnly = Join-Path $root 'bare godot'
    New-TestFile (Join-Path $godotOnly 'project.godot')
    New-TestFile (Join-Path $godotOnly 'android\gradlew.bat'.Replace('\', $sep))
    $bare = Find-DroidRunProjects -Folder $godotOnly
    Assert-True ($bare.Candidates.Count -eq 1 -and $bare.Candidates[0].Relative -eq '.') 'A Godot project did not own its Gradle subtree.'
    Assert-True (-not $bare.Candidates[0].Recommended -and $bare.Candidates[0].Note -like '*export preset*') 'A Godot project without an Android preset was recommended.'

    $many = Join-Path $root 'many'
    for ($index = 0; $index -lt 30; $index++) { New-Item -ItemType Directory -Path (Join-Path $many ("folder {0:00}" -f $index)) -Force | Out-Null }
    Assert-True (Find-DroidRunProjects -Folder $many -FolderLimit 10).Truncated 'The folder limit did not stop the search.'

    $namesPath = Join-Path $root 'state\project-names.json'
    $project = Join-Path $root 'chess app'
    Assert-True ((Get-DroidRunProjectName -Path $project -NamesPath $namesPath) -eq 'chess app') 'Default name is not the folder name.'
    $shown = Set-DroidRunProjectName -Path $project -Name "  Chatturanga `n (phone)  " -NamesPath $namesPath
    Assert-True ($shown -eq 'Chatturanga (phone)') "Name was not cleaned: '$shown'"
    Assert-True ((Get-DroidRunProjectName -Path $project.ToUpperInvariant() -NamesPath $namesPath) -eq 'Chatturanga (phone)') 'Names are not matched case-insensitively.'
    Assert-True ((Set-DroidRunProjectName -Path $project -Name '' -NamesPath $namesPath) -eq 'chess app') 'Clearing a name did not restore the folder name.'
    Assert-True ((Get-DroidRunProjectNames -NamesPath $namesPath).Count -eq 0) 'Clearing a name left an override.'
    [void](Set-DroidRunProjectName -Path $project -Name 'chess app' -NamesPath $namesPath)
    Assert-True ((Get-DroidRunProjectNames -NamesPath $namesPath).Count -eq 0) 'The folder name was stored as an override.'
    Assert-True ((Set-DroidRunProjectName -Path $project -Name ('x' * 200) -NamesPath $namesPath).Length -eq 80) 'Long names were not capped.'
    Set-Content -LiteralPath $namesPath -Value '[1, 2]'
    Assert-True ((Get-DroidRunProjectName -Path $project -NamesPath $namesPath) -eq 'chess app') 'A corrupt names file was not ignored.'

    $all = @('C:\a', 'C:\b', 'C:\c')
    Assert-True ((@(Get-DroidRunRefreshTargets -Projects $all -Selected @()) -join '|') -eq ($all -join '|')) 'No selection did not refresh every project.'
    Assert-True ((@(Get-DroidRunRefreshTargets -Projects $all -Selected @('c:\C', 'C:\a')) -join '|') -eq 'C:\a|C:\c') 'Selected projects were not refreshed in list order.'
    Assert-True ((@(Get-DroidRunRefreshTargets -Projects $all -Selected @('C:\gone')) -join '|') -eq ($all -join '|')) 'A stale selection did not fall back to every project.'
    Assert-True ((@(Get-DroidRunRefreshTargets -Projects @('C:\only') -Selected @('C:\only'))).Count -eq 1) 'A single selected project was not kept as an array.'
    # The dashboard indexes the checked projects, so a single project must stay a path, not a string of characters.
    [string[]]$one = @(Get-DroidRunProjectsToCheck -Projects $all -Only @('c:\B'))
    Assert-True ($one.Count -eq 1 -and $one[0] -eq 'C:\b') "One project to check became '$($one[0])'."
    [string[]]$single = @(Get-DroidRunProjectsToCheck -Projects @('C:\only project') -Only @())
    Assert-True ($single[0] -eq 'C:\only project') "The only saved project became '$($single[0])'."
    Assert-True ((@(Get-DroidRunProjectsToCheck -Projects $all -Only @()) -join '|') -eq ($all -join '|')) 'An empty Only did not check every project.'
    Assert-True (@(Get-DroidRunProjectsToCheck -Projects $all -Only @('C:\gone')).Count -eq 0) 'An Only list matching nothing checked projects.'
    Assert-True ((Get-DroidRunRefreshLabel 0) -eq 'Re&fresh All') 'Refresh label for no selection is wrong.'
    Assert-True ((Get-DroidRunRefreshLabel 1) -eq 'Re&fresh Selected') 'Refresh label for one selection is wrong.'
    Assert-True ((Get-DroidRunRefreshLabel 3) -eq 'Re&fresh 3 Selected') 'Refresh label for several selections is wrong.'
}
finally {
    if ((Split-Path -Leaf $root) -like 'DroidRun projects test *' -and (Test-Path -LiteralPath $root)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}
Write-Host 'PASS: project discovery (kinds, notes, nesting, enclosing project, limits), display names, and refresh scope.'
