[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

$toolRoot = $PSScriptRoot
$runner = Join-Path $toolRoot 'Run-AndroidBuildInstall.ps1'
$session = Join-Path $toolRoot 'AndroidBuildInstall-Session.ps1'
$settingsEditor = Join-Path $toolRoot 'Edit-AndroidProjectPreferences.ps1'
$statusHelper = Join-Path $toolRoot 'Get-AndroidProjectStatus.ps1'
$gitUpdater = Join-Path $toolRoot 'Update-AndroidRepo.ps1'
$scanner = Join-Path $toolRoot 'Scan-AndroidDevice.ps1'
$fileHashHelper = Join-Path $toolRoot 'AndroidFileHash.ps1'
$shortcutInstaller = Join-Path $toolRoot 'Install-AndroidBuildInstallShortcut.ps1'
$taskbarIdentityHelper = Join-Path $toolRoot 'WindowsTaskbarIdentity.ps1'
$iconPng = Join-Path $toolRoot 'assets\droidrun-icon.png'
$iconPath = Join-Path $toolRoot 'assets\droidrun.ico'
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("WindowsTools Android Test {0}" -f [Guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA

try {
    foreach ($script in Get-ChildItem -LiteralPath $toolRoot -Filter '*.ps1' -File) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        Assert-True -Condition ($parseErrors.Count -eq 0) -Message "PowerShell parse errors in $($script.Name): $($parseErrors -join '; ')"
    }

    Assert-True -Condition (Test-Path -LiteralPath $iconPng -PathType Leaf) -Message 'The source application icon is missing.'
    Assert-True -Condition (Test-Path -LiteralPath $iconPath -PathType Leaf) -Message 'The Windows application/tray icon is missing.'
    . $fileHashHelper
    $hashProbe = Join-Path $testRoot 'SHA-256 probe with spaces.txt'
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Set-Content -LiteralPath $hashProbe -Value 'abc' -Encoding ASCII -NoNewline
    Assert-True -Condition ((Get-AndroidFileSha256 -LiteralPath $hashProbe) -eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') -Message 'The built-in .NET SHA-256 helper returned an incorrect hash.'
    Assert-True -Condition ((Get-Content -LiteralPath $scanner -Raw) -notmatch '\bGet-FileHash\b') -Message 'The device scanner still depends on the unavailable Get-FileHash command.'
    Add-Type -AssemblyName System.Drawing
    $sourceIcon = [System.Drawing.Bitmap]::FromFile($iconPng)
    try {
        Assert-True -Condition ($sourceIcon.GetPixel(0, 0).A -eq 0) -Message 'The source icon does not retain a transparent background.'
    }
    finally { $sourceIcon.Dispose() }

    $loadedIcon = New-Object System.Drawing.Icon($iconPath)
    try {
        Assert-True -Condition ($loadedIcon.Width -gt 0 -and $loadedIcon.Height -gt 0) -Message 'The Windows icon could not be decoded.'
        $iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
        $iconImageCount = [BitConverter]::ToUInt16($iconBytes, 4)
        Assert-True -Condition ($iconImageCount -ge 5) -Message "The Windows icon contains only $iconImageCount image sizes."
        $iconSizes = @(
            for ($iconIndex = 0; $iconIndex -lt $iconImageCount; $iconIndex++) {
                $encodedWidth = [int]$iconBytes[6 + (16 * $iconIndex)]
                if ($encodedWidth -eq 0) { 256 } else { $encodedWidth }
            }
        )
        Assert-True -Condition ($iconSizes -contains 16 -and $iconSizes -contains 32 -and $iconSizes -contains 256) -Message "The Windows icon is missing a required small or large frame: $($iconSizes -join ', ')."
    }
    finally { $loadedIcon.Dispose() }

    $projectRoot = Join-Path $testRoot 'project with spaces'
    $apkPath = Join-Path $projectRoot 'app\build\outputs\apk\debug\app-debug.apk'
    $sourcePath = Join-Path $projectRoot 'app\src\main\source.txt'
    $fakeJavaHome = Join-Path $testRoot 'fake jdk'

    New-Item -ItemType Directory -Path (Split-Path -Parent $apkPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $sourcePath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fakeJavaHome 'bin') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $projectRoot 'gradlew.bat') -Encoding ASCII -Value @('@echo off', 'exit /b 0')
    Set-Content -LiteralPath $apkPath -Encoding ASCII -Value 'fake apk payload'
    Set-Content -LiteralPath $sourcePath -Encoding ASCII -Value 'newer source input'
    Set-Content -LiteralPath (Join-Path $fakeJavaHome 'bin\java.exe') -Encoding ASCII -Value 'fake java placeholder'

    (Get-Item -LiteralPath $apkPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc = [DateTime]::UtcNow
    $env:LOCALAPPDATA = Join-Path $testRoot 'state with spaces'

    $testShortcut = Join-Path $testRoot 'Start Menu\DroidRun.lnk'
    $shortcutOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutInstaller `
        -ShortcutPath $testShortcut `
        -Quiet 2>&1)
    $shortcutExit = [int]$LASTEXITCODE
    Assert-True -Condition ($shortcutExit -eq 0) -Message "Start menu shortcut creation failed with exit code $shortcutExit.`n$($shortcutOutput -join [Environment]::NewLine)"
    Assert-True -Condition (Test-Path -LiteralPath $testShortcut -PathType Leaf) -Message 'The Start menu shortcut was not created.'
    . $taskbarIdentityHelper
    Assert-True -Condition ([WindowsTools.TaskbarIdentity]::GetShortcutAppId($testShortcut) -eq (Get-AndroidBuildInstallAppId)) -Message 'The shortcut does not have the DroidRun AppUserModelID.'
    $shortcutShell = New-Object -ComObject WScript.Shell
    $loadedShortcut = $null
    try {
        $loadedShortcut = $shortcutShell.CreateShortcut($testShortcut)
        Assert-True -Condition ($loadedShortcut.TargetPath -ieq (Join-Path $PSHOME 'powershell.exe')) -Message "The shortcut target is incorrect: $($loadedShortcut.TargetPath)"
        Assert-True -Condition ($loadedShortcut.Arguments.Contains('AndroidBuildInstall-Session.ps1')) -Message "The shortcut arguments are incorrect: $($loadedShortcut.Arguments)"
        Assert-True -Condition ($loadedShortcut.IconLocation.Contains('droidrun.ico')) -Message "The shortcut icon is incorrect: $($loadedShortcut.IconLocation)"
    }
    finally {
        if ($null -ne $loadedShortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($loadedShortcut) }
        if ($null -ne $shortcutShell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcutShell) }
    }

    $runOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
        -Project $projectRoot `
        -JavaHome $fakeJavaHome `
        -SkipInstall `
        -NoUi `
        -SuppressSuccessDialog 2>&1)
    $runExit = [int]$LASTEXITCODE
    Assert-True -Condition ($runExit -eq 0) -Message "Mock build failed with exit code $runExit.`n$($runOutput -join [Environment]::NewLine)"

    $status = @(& $statusHelper -Project @($projectRoot) -SkipDevice)[0]
    Assert-True -Condition ($status.BuildStatus -eq 'Fresh') -Message "Successful build was reported as '$($status.BuildStatus)': $($status.BuildDetail)"
    Assert-True -Condition ((Get-Item -LiteralPath $apkPath).LastWriteTimeUtc -ge (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc) -Message 'Successful build did not advance the deterministic APK freshness timestamp.'

    $missingProject = Join-Path $testRoot 'missing project'
    $failureOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gitUpdater -Project $missingProject -NoUi 2>&1)
    $failureExit = [int]$LASTEXITCODE
    Assert-True -Condition ($failureExit -ne 0) -Message 'Missing-project validation unexpectedly succeeded.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $missingProject)) -Message 'Failure-path validation created the missing project directory.'

    $ambiguousProject = Join-Path $testRoot 'ambiguous project'
    foreach ($moduleName in @('android-one', 'android-two')) {
        $moduleRoot = Join-Path $ambiguousProject $moduleName
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $moduleRoot 'gradlew.bat') -Encoding ASCII -Value @('@echo off', 'exit /b 0')
    }
    $ambiguityOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolRoot 'Invoke-AndroidBuildInstall.ps1') `
        -Project $ambiguousProject `
        -SkipBuild `
        -SkipInstall `
        -SuppressSuccessDialog `
        -NoUi 2>&1)
    $ambiguityExit = [int]$LASTEXITCODE
    $ambiguityText = $ambiguityOutput -join [Environment]::NewLine
    Assert-True -Condition ($ambiguityExit -ne 0) -Message 'A background build with ambiguous Gradle roots unexpectedly succeeded.'
    Assert-True -Condition ($ambiguityText -match 'Multiple build roots were found') -Message "The background ambiguity failure was not actionable.`n$ambiguityText"
    Assert-True -Condition ($ambiguityText -notmatch 'Choose 1-') -Message "The background ambiguity path attempted to prompt for console input.`n$ambiguityText"

    $scannerFailure = ''
    try { & $scanner -Project @($missingProject) | Out-Null } catch { $scannerFailure = $_.Exception.Message }
    Assert-True -Condition ($scannerFailure -eq 'No valid saved project folders were supplied.') -Message "Normal scanner parameter binding failed unexpectedly: $scannerFailure"

    $sessionOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $session -UiSmokeTest 2>&1)
    $sessionExit = [int]$LASTEXITCODE
    Assert-True -Condition ($sessionExit -eq 0) -Message "Dashboard UI smoke test failed with exit code $sessionExit.`n$($sessionOutput -join [Environment]::NewLine)"
    Assert-True -Condition (($sessionOutput -join [Environment]::NewLine) -match 'UI taskbar identity: WindowsTools\.AndroidBuildInstall') -Message "Dashboard taskbar identity was not applied.`n$($sessionOutput -join [Environment]::NewLine)"

    $preferencesPath = Join-Path $env:LOCALAPPDATA 'project-preferences.json'
    $settingsOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $settingsEditor `
        -Project $projectRoot `
        -PreferencesPath $preferencesPath `
        -UiSmokeTest 2>&1)
    $settingsExit = [int]$LASTEXITCODE
    Assert-True -Condition ($settingsExit -eq 0) -Message "Settings UI smoke test failed with exit code $settingsExit.`n$($settingsOutput -join [Environment]::NewLine)"

    $operationOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $session `
        -Project $missingProject `
        -UiSmokeTestOperation 2>&1)
    $operationExit = [int]$LASTEXITCODE
    Assert-True -Condition ($operationExit -ne 0) -Message 'Dashboard operation smoke test unexpectedly succeeded for a missing project.'
    Assert-True -Condition (($operationOutput -join [Environment]::NewLine) -match 'UI operation smoke result:') -Message "Dashboard operation controller did not report completion.`n$($operationOutput -join [Environment]::NewLine)"
    Assert-True -Condition (($operationOutput -join [Environment]::NewLine) -match 'The project path is not a directory') -Message "Dashboard operation output did not capture the child failure.`n$($operationOutput -join [Environment]::NewLine)"
    Assert-True -Condition (($operationOutput -join [Environment]::NewLine).Contains($missingProject)) -Message "Dashboard operation did not preserve the project path containing spaces.`n$($operationOutput -join [Environment]::NewLine)"
    Assert-True -Condition (-not (Test-Path -LiteralPath $missingProject)) -Message 'Dashboard operation failure created the missing project directory.'

    $successOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $session -UiSmokeTestOperationSuccess 2>&1)
    $successExit = [int]$LASTEXITCODE
    $successText = $successOutput -join [Environment]::NewLine
    Assert-True -Condition ($successExit -eq 0) -Message "Dashboard operation success smoke test failed with exit code $successExit.`n$successText"
    Assert-True -Condition ($successText -match 'Smoke operation completed successfully') -Message "Dashboard did not capture successful child output.`n$successText"
    Assert-True -Condition ($successText -match 'Completed successfully\. Exit code: 0') -Message "Dashboard did not report successful completion.`n$successText"

    $inheritedOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $session -UiSmokeTestInheritedOutput 2>&1)
    $inheritedExit = [int]$LASTEXITCODE
    $inheritedText = $inheritedOutput -join [Environment]::NewLine
    Assert-True -Condition ($inheritedExit -eq 0) -Message "Inherited-output completion smoke test failed with exit code $inheritedExit.`n$inheritedText"
    Assert-True -Condition ($inheritedText -match 'Immediate parent completed') -Message "Inherited-output completion did not capture the immediate process output.`n$inheritedText"
    Assert-True -Condition ($inheritedText -match 'UI operation elapsed seconds: ([0-9.,]+)') -Message "The dashboard did not report its inherited-output completion time.`n$inheritedText"
    $inheritedElapsedSeconds = [double]::Parse($matches[1], [Globalization.CultureInfo]::CurrentCulture)
    Assert-True -Condition ($inheritedElapsedSeconds -lt 2) -Message "The dashboard waited $([Math]::Round($inheritedElapsedSeconds, 1)) seconds for a descendant-owned output handle to close."

    $cancelOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $session -UiSmokeTestCancellation 2>&1)
    $cancelExit = [int]$LASTEXITCODE
    $cancelText = $cancelOutput -join [Environment]::NewLine
    Assert-True -Condition ($cancelExit -ne 0) -Message 'Dashboard cancellation smoke test unexpectedly succeeded.'
    Assert-True -Condition ($cancelText -match 'Cancellation requested') -Message "Dashboard cancellation did not reach the process runner.`n$cancelText"
    Assert-True -Condition ($cancelText -notmatch 'completed unexpectedly') -Message "Dashboard cancellation left the child operation running.`n$cancelText"

    $statusOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $session `
        -Project $projectRoot `
        -UiSmokeTestStatusRefresh 2>&1)
    $statusExit = [int]$LASTEXITCODE
    $statusText = $statusOutput -join [Environment]::NewLine
    Assert-True -Condition ($statusExit -eq 0) -Message "Dashboard status refresh smoke test failed with exit code $statusExit.`n$statusText"
    Assert-True -Condition ($statusText -match 'UI status smoke result: 1/1') -Message "Dashboard status refresh did not complete progressively.`n$statusText"
    Assert-True -Condition ($statusText -match 'UI status row:') -Message "Dashboard status refresh did not populate a project row.`n$statusText"

    Write-Host 'PASS: PowerShell parsing, taskbar identity and Start menu shortcut creation, multi-size app/tray icon loading, built-in .NET SHA-256 hashing, configured JAVA_HOME, paths with spaces, build freshness, scanner binding, non-interactive ambiguity handling, UI creation/resizing, asynchronous operation completion/cancellation, inherited-output-handle completion, progressive status refresh, and expected failure behavior.'
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -like 'WindowsTools Android Test *' -and
        (Test-Path -LiteralPath $resolvedTestRoot -PathType Container)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
