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
    $config.apk = 'output dir/test.apk'; $config.windows.executable = './builder.bat'
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath

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
    }
    else { Write-Host 'Windows process/UI integration skipped on this OS; helper/parser checks ran.' }
    Write-Host 'PASS: Android build backends.'
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
