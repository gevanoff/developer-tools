# Shared by the builder, status reader, device scanner and settings dialog.
# Loading this file never executes a project command.

# A Gradle build is rooted at its settings file even when the repository does not
# commit the Gradle wrapper. Keep in step with android_build_install_linux/backends.py.
$script:AndroidGradleSettingsFiles = @('settings.gradle', 'settings.gradle.kts')
$script:AndroidBuildRootMarkers = @('android-build-install.json', 'project.godot', 'gradlew.bat') + $script:AndroidGradleSettingsFiles
$script:AndroidNoGradleMessage = "This Gradle project has no wrapper (gradlew.bat) and no installed Gradle was found on PATH. Add the Gradle wrapper to the repository (run 'gradle wrapper' once and commit the files), or install Gradle and add it to PATH."

function Test-AndroidBuildRootMarker {
    param([string]$Path)
    foreach ($marker in $script:AndroidBuildRootMarkers) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker) -PathType Leaf) { return $true }
    }
    return $false
}

function Test-AndroidGradleWrapper {
    param([string]$Root)
    return [bool](Test-Path -LiteralPath (Join-Path $Root 'gradlew.bat') -PathType Leaf)
}

function Get-AndroidInstalledGradle {
    # The Gradle on PATH (gradle.bat), used only when a project has no wrapper.
    $command = Get-Command 'gradle' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    return ''
}

function Get-AndroidBuildConfig {
    param([string]$Root)
    $path = Join-Path $Root 'android-build-install.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data -isnot [pscustomobject] -or $data.version -ne 1) { throw 'Expected an object with version: 1.' }
        $config = @{}
        foreach ($property in $data.PSObject.Properties) { $config[$property.Name] = $property.Value }
        if ($config.ContainsKey('windows')) {
            if ($config.windows -isnot [pscustomobject]) { throw 'windows must be an object.' }
            foreach ($property in $config.windows.PSObject.Properties) { $config[$property.Name] = $property.Value }
        }
        foreach ($key in @('backend', 'executable', 'preset', 'apk')) {
            if ($config.ContainsKey($key) -and ($config[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($config[$key]))) {
                throw "$key must be a nonempty string."
            }
        }
        if ($config.ContainsKey('arguments')) {
            if ($config.arguments -isnot [array]) { throw 'arguments must be an array of strings.' }
            foreach ($argument in $config.arguments) {
                if ($argument -isnot [string]) { throw 'arguments must be an array of strings.' }
            }
        }
        return $config
    }
    catch { throw "Invalid ${path}: $($_.Exception.Message)" }
}

function Get-AndroidProjectRoots {
    param([string]$Root, [int]$MaxDepth = 2)
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@{ Path = [IO.Path]::GetFullPath($Root); Depth = 0 })
    while ($queue.Count) {
        $node = $queue.Dequeue()
        if (Test-AndroidBuildRootMarker -Path $node.Path) { $node.Path; continue }
        if ($node.Depth -ge $MaxDepth) { continue }
        foreach ($child in Get-ChildItem -LiteralPath $node.Path -Directory -ErrorAction SilentlyContinue) {
            if ($child.Name -in @('.git', '.gradle', '.godot', '.idea', 'build', 'node_modules', 'out', '.venv', 'venv')) { continue }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $queue.Enqueue(@{ Path = $child.FullName; Depth = $node.Depth + 1 })
        }
    }
}

function Get-GodotAndroidPresets {
    param([string]$Root)
    $path = Join-Path $Root 'export_presets.cfg'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Godot needs export_presets.cfg. In Godot, open Project > Export, add an Android preset, configure the SDK/JDK and debug keystore, and install matching export templates.'
    }
    $active = $false
    $section = @{}
    foreach ($line in @((Get-Content -LiteralPath $path -Encoding UTF8)) + @('[end]')) {
        $line = $line.Trim()
        if ($line.StartsWith('[')) {
            if ($active -and $section.platform -ceq 'Android' -and $section.name) { $section.name }
            $active = $line -match '^\[preset\.\d+\]$'
            $section = @{}
        }
        elseif ($active -and $line -match '^(name|platform)\s*=(.*)$') {
            $key = $matches[1]; $value = $matches[2]
            $section[$key] = ConvertFrom-Json -InputObject $value
        }
    }
}

function Get-AndroidBuildPlan {
    param([string]$Root)
    $config = Get-AndroidBuildConfig -Root $Root
    $backend = if ($config.backend) { $config.backend } else { 'auto' }
    if ($backend -ceq 'auto') {
        $backend = if (Test-Path -LiteralPath (Join-Path $Root 'project.godot') -PathType Leaf) { 'godot' } else { 'gradle' }
    }
    if ($backend -ceq 'gradle') {
        if (Test-AndroidGradleWrapper -Root $Root) {
            return [pscustomobject]@{ Root = $Root; Backend = $backend; Executable = ''; Arguments = @(); Apk = $null }
        }
        $hasSettings = $false
        foreach ($name in $script:AndroidGradleSettingsFiles) {
            if (Test-Path -LiteralPath (Join-Path $Root $name) -PathType Leaf) { $hasSettings = $true }
        }
        if (-not $hasSettings) {
            throw 'No Gradle wrapper or settings.gradle(.kts) in the build root. Select the Gradle project folder, or configure backend: custom in android-build-install.json.'
        }
        $gradle = Get-AndroidInstalledGradle
        if (-not $gradle) { throw $script:AndroidNoGradleMessage }
        return [pscustomobject]@{ Root = $Root; Backend = $backend; Executable = $gradle; Arguments = @(); Apk = $null }
    }
    if ($backend -cnotin @('godot', 'custom')) { throw "Unsupported backend: $backend. Use auto, gradle, godot or custom." }
    $output = $config.apk
    if (-not $output -and $backend -ceq 'godot') { $output = 'build/android/app-debug.apk' }
    if (-not $output -or [IO.Path]::GetExtension($output) -ine '.apk') {
        throw 'Set apk to an exact .apk output path (AAB and split APK sets cannot be installed).'
    }
    $apk = if ([IO.Path]::IsPathRooted($output)) { [IO.Path]::GetFullPath($output) } else { [IO.Path]::GetFullPath((Join-Path $Root $output)) }
    $executable = [string]$config.executable
    $arguments = @($config.arguments | ForEach-Object { $_ })
    if ($backend -ceq 'custom') {
        if (-not $executable) { throw 'Custom builds require executable and apk in android-build-install.json.' }
    }
    else {
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'project.godot') -PathType Leaf)) { throw 'Godot backend requires project.godot in the build root.' }
        $presets = @(Get-GodotAndroidPresets -Root $Root)
        $preset = $config.preset
        if ($preset) {
            if (@($presets | Where-Object { $_ -ceq $preset }).Count -ne 1) { throw "Expected one Android export preset named '$preset'." }
        }
        elseif ($presets.Count -eq 1) { $preset = $presets[0] }
        else { throw 'Expected one Android export preset; set preset in android-build-install.json to select one.' }
        $arguments = @('--headless', '--path', $Root, '--export-debug', $preset, $apk)
    }
    return [pscustomobject]@{ Root = $Root; Backend = $backend; Executable = $executable; Arguments = $arguments; Apk = $apk }
}

function Resolve-AndroidBuildCommand {
    param($Plan, [string]$GradleTask)
    if ($Plan.Backend -eq 'gradle') {
        # No wrapper: the installed Gradle that Get-AndroidBuildPlan chose.
        $gradle = if ($Plan.Executable) { $Plan.Executable } else { Join-Path $Plan.Root 'gradlew.bat' }
        return [pscustomobject]@{ Executable = $gradle; Arguments = @($GradleTask, '--stacktrace') }
    }
    $executable = $Plan.Executable
    if (-not $executable) {
        foreach ($name in @('godot4.exe', 'godot.exe', 'godot')) {
            $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
            if ($command) { $executable = $command.Source; break }
        }
    }
    elseif ($executable.Contains('/') -or $executable.Contains('\') -or (Test-Path -LiteralPath (Join-Path $Plan.Root $executable) -PathType Leaf)) {
        if (-not [IO.Path]::IsPathRooted($executable)) { $executable = Join-Path $Plan.Root $executable }
        $executable = [IO.Path]::GetFullPath($executable)
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { $executable = '' }
    }
    else {
        $command = Get-Command $executable -CommandType Application -ErrorAction SilentlyContinue
        $executable = if ($command) { $command.Source } else { '' }
    }
    if (-not $executable) { throw 'Build executable not found. Configure executable in android-build-install.json; Godot needs the Godot 4 editor binary (prefer the console executable on Windows).' }
    if ([IO.Path]::GetExtension($executable) -ieq '.ps1') { throw 'Use powershell.exe as executable and pass the .ps1 script in arguments so its exit status is explicit.' }
    return [pscustomobject]@{ Executable = $executable; Arguments = @($Plan.Arguments) }
}

function Assert-AndroidBackendApkPreference {
    param($Plan, [string]$ProjectRoot, [string]$Preferred)
    if ($Plan.Apk -and $Preferred) {
        $path = if ([IO.Path]::IsPathRooted($Preferred)) { [IO.Path]::GetFullPath($Preferred) } else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $Preferred)) }
        if ($path -ine $Plan.Apk) { throw 'Preferred APK conflicts with the backend output. Clear Preferred APK or match the configured apk.' }
    }
}

# ----- Gradle download-cache recovery -----------------------------------------------
# A Gradle daemon or a reused configuration-cache entry can still point at library files
# that have since disappeared from %USERPROFILE%\.gradle\caches (cache cleanup,
# antivirus, a disk cleaner). The build then fails in seconds with FileNotFoundException
# for those paths. DroidRun retries such a build once with fresh dependency resolution.
# It never deletes anything in the Gradle cache. Keep in step with backends.py.

# Only Gradle's own cache layout under GRADLE_USER_HOME counts: caches\modules-2\files-2.1
# (downloads), caches\transforms-N, caches\jars-N, and version folders such as
# caches\8.9\transforms. A project folder that happens to be called "caches" must never
# match, because the repair message tells the user to delete what it names.
$script:GradleCachePattern = '[\\/]caches[\\/](?:modules-\d+[\\/]files-\d+\.\d+|transforms-\d+|jars-\d+|\d+\.\d+(?:\.\d+)?(?:-[^\\/]+)?[\\/](?:transforms|kotlin-dsl|groovy-dsl|generated-gradle-jars|scripts|scripts-remapped))[\\/]'

function Get-GradleMissingCacheFiles {
    # Paths under a Gradle caches folder that the build reported as missing, in order.
    param([string[]]$Lines)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ("$line" -notmatch '(?:FileNotFoundException|NoSuchFileException):\s*(.+?)\s*$') { continue }
        $path = ($matches[1] -replace '\s*\((?:The system cannot find the (?:path|file) specified|No such file or directory)\)?\.?$', '').Trim()
        if ($path -match $script:GradleCachePattern -and -not $found.Contains($path)) { $found.Add($path) }
    }
    return $found.ToArray()
}

function Get-GradleRecoveryArguments {
    # Extra arguments for the single retry after a missing-cache-file failure. Only
    # builds that used the configuration cache get --no-configuration-cache; it is what
    # replays the stale file list without re-checking it.
    param([string[]]$Lines)
    $arguments = @('--refresh-dependencies')
    if ((@($Lines) -join "`n") -match '(?i)configuration cache') { $arguments = @('--no-configuration-cache') + $arguments }
    return $arguments
}

function Get-GradleCacheEntries {
    # Folders to clear by hand, all inside Gradle's caches folder: group\artifact\version
    # for a downloaded module, or the single transform or JAR cache entry (the folder
    # directly under transforms-N, jars-N or <version>\transforms) that held the file.
    param([string[]]$Paths)
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($path in $Paths) {
        if ($path -notmatch $script:GradleCachePattern) { continue }
        $parts = @($path -split '[\\/]')
        $separator = if ($path.Contains('\')) { '\' } else { '/' }
        $caches = -1
        for ($i = 0; $i -lt $parts.Count; $i++) { if ($parts[$i] -ieq 'caches') { $caches = $i } }
        $kind = $parts[$caches + 1]
        $filesIndex = -1
        for ($i = $caches; $i -lt $parts.Count; $i++) { if ($parts[$i] -ieq 'files-2.1') { $filesIndex = $i; break } }
        $end = if ($kind -like 'modules-*' -and $filesIndex -ge 0) { $filesIndex + 4 }
            elseif ($kind -like 'transforms-*' -or $kind -like 'jars-*') { $caches + 3 }
            else { $caches + 4 }
        if ($end -ge $parts.Count) { $end = $parts.Count - 1 }
        $entry = $parts[0..($end - 1)] -join $separator
        if ($entry -and -not $entries.Contains($entry)) { $entries.Add($entry) }
    }
    return $entries.ToArray()
}

function Get-GradleCacheRepairMessage {
    param([string[]]$Paths)
    $entries = @(Get-GradleCacheEntries -Paths $Paths)
    $shown = @($entries | Select-Object -First 8 | ForEach-Object { "  $_" }) -join "`n"
    $more = if ($entries.Count -gt 8) { "`n  ...and $($entries.Count - 8) more" } else { '' }
    return "Gradle's download cache is still missing files after a fresh retry. Close Android Studio and other Gradle builds, delete these cache folders (Gradle downloads them again), and run DroidRun again:`n$shown$more"
}
