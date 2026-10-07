# Shared by the builder, status reader, device scanner and settings dialog.
# Loading this file never executes a project command.
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
        $found = $false
        foreach ($marker in @('android-build-install.json', 'project.godot', 'gradlew.bat')) {
            if (Test-Path -LiteralPath (Join-Path $node.Path $marker) -PathType Leaf) { $found = $true; break }
        }
        if ($found) { $node.Path; continue }
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
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'gradlew.bat') -PathType Leaf)) {
            throw 'No Gradle wrapper. Configure backend: custom in android-build-install.json.'
        }
        return [pscustomobject]@{ Root = $Root; Backend = $backend; Executable = ''; Arguments = @(); Apk = $null }
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
        return [pscustomobject]@{ Executable = (Join-Path $Plan.Root 'gradlew.bat'); Arguments = @($GradleTask, '--stacktrace') }
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
