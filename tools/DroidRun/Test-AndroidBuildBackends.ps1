[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    $failure = ''
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match $Pattern) "Expected '$Pattern', received '$failure'."
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Android backends test ' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
        $errors = $null; $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True (@($errors).Count -eq 0) "$($file.Name): $errors"
    }
    $godot = Join-Path $testRoot 'godot project'
    [IO.Directory]::CreateDirectory((Join-Path $godot 'android/build')) | Out-Null
    Set-Content -LiteralPath (Join-Path $godot 'project.godot') -Value 'config_version=5'
    Set-Content -LiteralPath (Join-Path $godot 'android/build/gradlew.bat') -Value '@exit /b 0'
    Assert-True (@(Get-AndroidProjectRoots -Root $godot).Count -eq 1) 'Generated Gradle subtree must not become another build root.'
    Assert-Fails { Get-AndroidBuildPlan -Root $godot } 'Project > Export'
    Set-Content -LiteralPath (Join-Path $godot 'export_presets.cfg') -Value @'
[preset.0]
name="Android Debug"
platform="Android"
[preset.0.options]
gradle_build/use_gradle_build=false
[preset.1]
name="Web"
platform="Web"
'@
    $plan = Get-AndroidBuildPlan -Root $godot
    Assert-True ($plan.Backend -eq 'godot' -and $plan.Arguments[4] -ceq 'Android Debug') 'Godot Android preset selection failed.'
    Assert-Fails { Assert-AndroidBackendApkPreference -Plan $plan -ProjectRoot $godot -Preferred 'other.apk' } 'conflicts'
    Add-Content -LiteralPath (Join-Path $godot 'export_presets.cfg') -Value @'
[preset.2]
name="Other Android"
platform="Android"
'@
    Assert-Fails { Get-AndroidBuildPlan -Root $godot } 'set preset'
    $godotConfig = Join-Path $godot 'android-build-install.json'
    @{ version = 1; backend = 'godot'; preset = 'Android Debug' } | ConvertTo-Json | Set-Content -LiteralPath $godotConfig
    Assert-True ((Get-AndroidBuildPlan -Root $godot).Arguments[4] -ceq 'Android Debug') 'Explicit preset selection failed.'

    $custom = Join-Path $testRoot 'custom project'
    [IO.Directory]::CreateDirectory($custom) | Out-Null
    $configPath = Join-Path $custom 'android-build-install.json'
    $config = @{ version = 1; backend = 'custom'; executable = 'unused'; arguments = @('argument with spaces'); apk = 'output dir/test.apk'; windows = @{ executable = 'builder.bat' } }
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath
    $customPlan = Get-AndroidBuildPlan -Root $custom
    Assert-True ($customPlan.Executable -eq 'builder.bat') 'Windows override was ignored.'
    Assert-True ($customPlan.Arguments.Count -eq 1 -and $customPlan.Arguments[0] -eq 'argument with spaces') 'Arguments were split.'
    $config.apk = 'output.aab'
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath
    Assert-Fails { Get-AndroidBuildPlan -Root $custom } 'exact .apk'
    Set-Content -LiteralPath $configPath -Value '{broken'
    Assert-Fails { Get-AndroidBuildPlan -Root $custom } 'Invalid'
    $config.apk = 'output dir/test.apk'; $config.windows.executable = 'builder.bat'
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath

    # A Gradle project without a committed wrapper is rooted at its settings file and
    # builds with the Gradle on PATH; a committed wrapper always wins.
    $noWrapperRepo = Join-Path $testRoot 'repo without wrapper'
    $noWrapper = Join-Path $noWrapperRepo 'android'
    [IO.Directory]::CreateDirectory($noWrapper) | Out-Null
    Set-Content -LiteralPath (Join-Path $noWrapper 'settings.gradle.kts') -Value 'rootProject.name = "x"'
    $roots = @(Get-AndroidProjectRoots -Root $noWrapperRepo)
    Assert-True ($roots.Count -eq 1 -and $roots[0] -eq $noWrapper) 'settings.gradle.kts must mark a Gradle build root.'
    function Get-AndroidInstalledGradle { '' }
    Assert-Fails { Get-AndroidBuildPlan -Root $noWrapper } "no wrapper.*gradle wrapper.*install Gradle"
    function Get-AndroidInstalledGradle { 'C:\gradle 8.9\bin\gradle.bat' }
    $noWrapperCommand = Resolve-AndroidBuildCommand -Plan (Get-AndroidBuildPlan -Root $noWrapper) -GradleTask 'assembleDebug'
    Assert-True ($noWrapperCommand.Executable -eq 'C:\gradle 8.9\bin\gradle.bat') 'A project without a wrapper must use the installed Gradle.'
    Assert-True (($noWrapperCommand.Arguments -join ' ') -eq 'assembleDebug --stacktrace') 'Installed Gradle arguments changed.'
    Set-Content -LiteralPath (Join-Path $noWrapper 'gradlew.bat') -Value '@exit /b 0'
    Assert-True ((Resolve-AndroidBuildCommand -Plan (Get-AndroidBuildPlan -Root $noWrapper) -GradleTask 'x').Executable -eq (Join-Path $noWrapper 'gradlew.bat')) 'A committed wrapper must win over installed Gradle.'
    Remove-Item -Path Function:\Get-AndroidInstalledGradle
    . (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')

    # Missing Gradle cache files: recognized on both platforms, with spaces, and not
    # confused with ordinary missing project files. Keep in step with test_backends.py.
    $cacheLog = @(
        'Configuration cache entry reused.',
        'Caused by: java.io.FileNotFoundException: C:\Users\Jo Smith\.gradle\caches\modules-2\files-2.1\io.coil-kt\coil\2.7.0\a80e19\coil-2.7.0.aar (The system cannot find the path specified)',
        'Caused by: java.nio.file.NoSuchFileException: /home/a b/.gradle/caches/transforms-4/abc/x.jar',
        'java.io.FileNotFoundException: C:\project\local.properties (The system cannot find the file specified)',
        'Caused by: java.io.FileNotFoundException: C:\Users\Jo Smith\.gradle\caches\modules-2\files-2.1\io.coil-kt\coil\2.7.0\a80e19\coil-2.7.0.aar (The system cannot find the path specified)'
    )
    $missingFiles = @(Get-GradleMissingCacheFiles -Lines $cacheLog)
    Assert-True ($missingFiles.Count -eq 2) "Expected two missing cache files, found $($missingFiles.Count): $($missingFiles -join ' | ')"
    Assert-True ($missingFiles[0] -ceq 'C:\Users\Jo Smith\.gradle\caches\modules-2\files-2.1\io.coil-kt\coil\2.7.0\a80e19\coil-2.7.0.aar') "Unexpected path: $($missingFiles[0])"
    Assert-True ($missingFiles[1] -ceq '/home/a b/.gradle/caches/transforms-4/abc/x.jar') "Unexpected path: $($missingFiles[1])"
    Assert-True (@(Get-GradleMissingCacheFiles -Lines @("e: Unresolved reference 'foo'.")).Count -eq 0) 'An ordinary failure must not trigger a cache retry.'
    Assert-True ((@(Get-GradleRecoveryArguments -Lines $cacheLog) -join ' ') -ceq '--no-configuration-cache --refresh-dependencies') 'Recovery arguments changed.'
    Assert-True ((@(Get-GradleRecoveryArguments -Lines @('FileNotFoundException: x')) -join ' ') -ceq '--refresh-dependencies') 'Builds without the configuration cache must not get --no-configuration-cache.'
    foreach ($projectPath in @('/work/app/src/main/assets/caches/catalog.json', 'C:\work\assets\caches\1.2\a.json', '/work/caches/12/notes.txt', 'C:\work\caches\modules-2\notes.txt')) {
        $line = "Caused by: java.io.FileNotFoundException: $projectPath (No such file or directory)"
        Assert-True (@(Get-GradleMissingCacheFiles -Lines @($line)).Count -eq 0) "A project folder named caches was treated as Gradle's cache: $projectPath"
        Assert-True (@(Get-GradleCacheEntries -Paths @($projectPath)).Count -eq 0) "A project folder named caches was offered for deletion: $projectPath"
    }
    $transformEntries = @(Get-GradleCacheEntries -Paths @('/home/a b/.gradle/caches/transforms-4/abc123/transformed/x/jars/classes.jar', 'C:\Gradle Home\caches\8.9\transforms\def456\metadata.bin'))
    Assert-True (($transformEntries -join '|') -ceq '/home/a b/.gradle/caches/transforms-4/abc123|C:\Gradle Home\caches\8.9\transforms\def456') "Unexpected transform entries: $($transformEntries -join '|')"
    $repair = Get-GradleCacheRepairMessage -Paths @($missingFiles[0])
    Assert-True ($repair.Contains("  C:\Users\Jo Smith\.gradle\caches\modules-2\files-2.1\io.coil-kt\coil\2.7.0") -and -not $repair.Contains('a80e19')) "Repair message must name the module folder: $repair"

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $builder = Join-Path $custom 'builder.bat'
        Set-Content -LiteralPath $builder -Encoding ASCII -Value @('@echo off', 'if not "%~1"=="argument with spaces" exit /b 9', 'echo new apk>"output dir\test.apk"', 'exit /b 0')
        $invoke = Join-Path $PSScriptRoot 'Invoke-AndroidBuildInstall.ps1'
        & $invoke -Project $custom -SkipInstall -NoUi -SuppressSuccessDialog -NoProcessExit
        $apk = Join-Path $custom 'output dir/test.apk'
        Assert-True (Test-Path -LiteralPath $apk) 'Custom build did not produce output.'
        $status = @(& (Join-Path $PSScriptRoot 'Get-AndroidProjectStatus.ps1') -Project @($custom) -SkipDevice)[0]
        Assert-True ($status.BuildStatus -eq 'Stale') 'Non-Gradle freshness must be delegated to builder.'
        $before = [IO.File]::ReadAllText($apk)
        $mtime = (Get-Item -LiteralPath $apk).LastWriteTimeUtc
        Set-Content -LiteralPath $builder -Encoding ASCII -Value @('@echo off', 'exit /b 7')
        Assert-Fails { & $invoke -Project $custom -SkipInstall -NoUi -NoProcessExit } 'failed with exit code 7'
        Assert-True ([IO.File]::ReadAllText($apk) -eq $before -and (Get-Item -LiteralPath $apk).LastWriteTimeUtc -eq $mtime) 'Failed build modified old output.'
        Set-Content -LiteralPath $builder -Encoding ASCII -Value @('@echo off', 'exit /b 0')
        Assert-Fails { & $invoke -Project $custom -SkipInstall -NoUi -NoProcessExit } 'did not update'
        Remove-Item -LiteralPath $apk
        Assert-Fails { & $invoke -Project $custom -SkipInstall -NoUi -NoProcessExit } 'did not produce'

        $fakeGodot = Join-Path $godot 'fake godot.bat'
        Set-Content -LiteralPath $fakeGodot -Encoding ASCII -Value @('@echo off', 'if not "%~1"=="--headless" exit /b 8', 'if not "%~4"=="--export-debug" exit /b 8', 'if not "%~5"=="Android Debug" exit /b 8', 'echo godot apk>"%~6"', 'exit /b 0')
        @{ version = 1; backend = 'godot'; preset = 'Android Debug'; executable = $fakeGodot } | ConvertTo-Json | Set-Content -LiteralPath $godotConfig
        & $invoke -Project $godot -SkipInstall -NoUi -SuppressSuccessDialog -NoProcessExit
        Assert-True (Test-Path -LiteralPath (Join-Path $godot 'build/android/app-debug.apk')) 'Godot export did not produce expected APK.'
        $statusScript = Join-Path $PSScriptRoot 'Get-AndroidProjectStatus.ps1'
        $godotApk = Get-Item -LiteralPath (Join-Path $godot 'build/android/app-debug.apk')
        Assert-True ((& $statusScript -Project $godot -SkipDevice).BuildStatus -eq 'Fresh') 'Successful Godot export must be fresh.'
        foreach ($cache in @('.godot', '.import')) {
            [IO.Directory]::CreateDirectory((Join-Path $godot $cache)) | Out-Null
            $cacheFile = Join-Path $godot "$cache/cache.txt"
            Set-Content -LiteralPath $cacheFile -Value 'generated cache'
            (Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc = $godotApk.LastWriteTimeUtc.AddMinutes(1)
        }
        Assert-True ((& $statusScript -Project $godot -SkipDevice).BuildStatus -eq 'Fresh') 'Godot caches must not invalidate an export.'
        foreach ($inputName in @('project.godot', 'export_presets.cfg', 'android-build-install.json', 'lesson.gd', 'words.json', 'texture.png')) {
            $inputPath = Join-Path $godot $inputName
            if (-not (Test-Path -LiteralPath $inputPath)) { Set-Content -LiteralPath $inputPath -Value 'project input' }
            $inputFile = Get-Item -LiteralPath $inputPath
            $inputFile.LastWriteTimeUtc = $godotApk.LastWriteTimeUtc.AddSeconds(1)
            Assert-True ((& $statusScript -Project $godot -SkipDevice).BuildStatus -eq 'Stale') "Changed $inputName must invalidate Godot export."
            $inputFile.LastWriteTimeUtc = $godotApk.LastWriteTimeUtc.AddSeconds(-1)
        }
        Set-Content -LiteralPath $fakeGodot -Encoding ASCII -Value @('@echo off', 'exit /b 7')
        (Get-Item -LiteralPath $fakeGodot).LastWriteTimeUtc = $godotApk.LastWriteTimeUtc.AddSeconds(1)
        $godotMtime = $godotApk.LastWriteTimeUtc
        Assert-Fails { & $invoke -Project $godot -SkipInstall -NoUi -NoProcessExit } 'failed with exit code 7'
        Assert-True ((Get-Item -LiteralPath $godotApk.FullName).LastWriteTimeUtc -eq $godotMtime) 'Failed Godot build must not refresh old APK.'
        Assert-True ((& $statusScript -Project $godot -SkipDevice).BuildStatus -eq 'Stale') 'Failed Godot build must remain stale.'
        Remove-Item -LiteralPath $godotApk.FullName
        Assert-True ((& $statusScript -Project $godot -SkipDevice).BuildStatus -eq 'No APK') 'Missing Godot APK must be reported.'

        # A build that fails only because Gradle's download cache lost files is retried
        # once (stop daemons, fresh resolution); a second cache failure stops with the
        # folders to clear, and other failures are never retried.
        $retryProject = Join-Path $testRoot 'gradle retry project'
        $fakeJdk = Join-Path $testRoot 'fake jdk'
        [IO.Directory]::CreateDirectory((Join-Path $fakeJdk 'bin')) | Out-Null
        Set-Content -LiteralPath (Join-Path $fakeJdk 'bin\java.exe') -Value 'placeholder'
        [IO.Directory]::CreateDirectory((Join-Path $retryProject 'app\src\main')) | Out-Null
        Set-Content -LiteralPath (Join-Path $retryProject 'app\src\main\AndroidManifest.xml') -Value '<manifest />'
        $calls = Join-Path $retryProject 'calls.txt'
        function Set-FakeGradle([int]$Failures, [string]$FailureLine) {
            # Fails the first $Failures builds (one marker file each), then writes the APK.
            $batch = New-Object System.Collections.Generic.List[string]
            $batch.Add('@echo off')
            $batch.Add('echo %*>>"%~dp0calls.txt"')
            $batch.Add('if "%~1"=="--stop" exit /b 0')
            for ($attempt = 1; $attempt -le $Failures; $attempt++) {
                $batch.Add("if not exist ""%~dp0failure $attempt.txt"" goto fail$attempt")
            }
            $batch.Add('mkdir "%~dp0app\build\outputs\apk\debug" 2>nul')
            $batch.Add('echo apk>"%~dp0app\build\outputs\apk\debug\app-debug.apk"')
            $batch.Add('exit /b 0')
            for ($attempt = 1; $attempt -le $Failures; $attempt++) {
                $batch.Add(":fail$attempt")
                $batch.Add("echo x>""%~dp0failure $attempt.txt""")
                $batch.Add('echo Configuration cache entry reused.')
                $batch.Add("echo $FailureLine")
                $batch.Add('exit /b 1')
            }
            Set-Content -LiteralPath (Join-Path $retryProject 'gradlew.bat') -Encoding ASCII -Value $batch.ToArray()
            Get-ChildItem -LiteralPath $retryProject -Filter '*.txt' | Remove-Item
        }
        $cacheLine = 'Caused by: java.io.FileNotFoundException: C:\Users\Jo Smith\.gradle\caches\modules-2\files-2.1\io.coil-kt\coil\2.7.0\a80e19\coil-2.7.0.aar (The system cannot find the path specified)'
        Set-FakeGradle -Failures 1 -FailureLine $cacheLine
        & $invoke -Project $retryProject -SkipInstall -NoUi -SuppressSuccessDialog -NoProcessExit -JavaHome $fakeJdk
        $callLines = @(Get-Content -LiteralPath $calls | ForEach-Object { $_.Trim() })
        Assert-True (($callLines -join '|') -ceq 'assembleDebug --stacktrace|--stop|assembleDebug --stacktrace --no-configuration-cache --refresh-dependencies') "Unexpected Gradle calls: $($callLines -join '|')"
        Assert-True (Test-Path -LiteralPath (Join-Path $retryProject 'app\build\outputs\apk\debug\app-debug.apk')) 'The retried build did not produce the APK.'
        Set-FakeGradle -Failures 2 -FailureLine $cacheLine
        Remove-Item -LiteralPath (Join-Path $retryProject 'app\build') -Recurse -Force
        Assert-Fails { & $invoke -Project $retryProject -SkipInstall -NoUi -NoProcessExit -JavaHome $fakeJdk } 'still missing files'
        Assert-True (@(Get-Content -LiteralPath $calls).Count -eq 3) 'A second cache failure must not retry again.'
        Set-FakeGradle -Failures 1 -FailureLine "e: Unresolved reference 'foo'."
        Assert-Fails { & $invoke -Project $retryProject -SkipInstall -NoUi -NoProcessExit -JavaHome $fakeJdk } 'failed with exit code 1'
        Assert-True (@(Get-Content -LiteralPath $calls).Count -eq 1) 'Ordinary Gradle failures must not be retried.'
    }
    else { Write-Host 'Windows process/UI integration skipped on this OS; helper/parser checks ran.' }
    Write-Host 'PASS: Android build backends.'
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }

# Expected native-command failures above must not leak into a CI shell's exit
# status after every assertion has passed. Unhandled assertions still throw.
$global:LASTEXITCODE = 0
