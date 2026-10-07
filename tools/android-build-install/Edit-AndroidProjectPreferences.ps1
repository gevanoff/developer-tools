[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$PreferencesPath,
    [Parameter(DontShow = $true)][switch]$UiSmokeTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'WindowsTaskbarIdentity.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [WindowsTools.TaskbarIdentity]::SetCurrentProcessAppId((Get-AndroidBuildInstallAppId)) }
catch { Write-Verbose "Could not set the settings-window taskbar identity: $($_.Exception.Message)" }

$appIconPath = Join-Path $PSScriptRoot 'assets\android-build-install.ico'
$appIcon = $null
if (Test-Path -LiteralPath $appIconPath -PathType Leaf) {
    try { $appIcon = New-Object System.Drawing.Icon($appIconPath) } catch { $appIcon = $null }
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

function Get-AllPreferences {
    if (-not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) { return @() }
    try { $json = Get-Content -LiteralPath $PreferencesPath -Raw | ConvertFrom-Json } catch { return @() }
    return @($json.projects)
}

function Get-Preference {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $normalized = Normalize-Path -Path $ProjectPath
    foreach ($item in @(Get-AllPreferences)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-Path -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $normalized) {
            return [pscustomobject]@{
                path = $normalized
                gradleTask = if ([string]::IsNullOrWhiteSpace("$($item.gradleTask)")) { 'assembleDebug' } else { "$($item.gradleTask)" }
                preferredApk = "$($item.preferredApk)"
                javaHome = "$($item.javaHome)"
                autoLaunch = [bool]$item.autoLaunch
                deviceSerial = "$($item.deviceSerial)"
            }
        }
    }

    return [pscustomobject]@{
        path = $normalized
        gradleTask = 'assembleDebug'
        preferredApk = ''
        javaHome = ''
        autoLaunch = $false
        deviceSerial = ''
    }
}

function Save-Preference {
    param([Parameter(Mandatory = $true)]$Preference)

    $projectPath = Normalize-Path -Path $Preference.path
    $items = @()
    foreach ($item in @(Get-AllPreferences)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-Path -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $projectPath) { continue }
        $items += [pscustomobject]@{
            path = $candidate
            gradleTask = if ([string]::IsNullOrWhiteSpace("$($item.gradleTask)")) { 'assembleDebug' } else { "$($item.gradleTask)" }
            preferredApk = "$($item.preferredApk)"
            javaHome = "$($item.javaHome)"
            autoLaunch = [bool]$item.autoLaunch
            deviceSerial = "$($item.deviceSerial)"
        }
    }

    $items = @([pscustomobject]@{
        path = $projectPath
        gradleTask = $Preference.gradleTask
        preferredApk = $Preference.preferredApk
        javaHome = $Preference.javaHome
        autoLaunch = [bool]$Preference.autoLaunch
        deviceSerial = $Preference.deviceSerial
    }) + $items

    $parent = Split-Path -Parent $PreferencesPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [pscustomobject]@{ projects = @($items) } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $PreferencesPath -Encoding UTF8
}

function Make-RelativeIfInsideProject {
    param(
        [Parameter(Mandatory = $true)][string]$SelectedPath,
        [Parameter(Mandatory = $true)][string]$ProjectPath
    )

    $selected = [System.IO.Path]::GetFullPath($SelectedPath)
    $root = (Normalize-Path -Path $ProjectPath) + [System.IO.Path]::DirectorySeparatorChar
    if ($selected.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $selected.Substring($root.Length)
    }
    return $selected
}

function Get-GradleRoots {
    param([string]$Root, [int]$MaxDepth = 2)
    Get-AndroidProjectRoots -Root $Root -MaxDepth $MaxDepth
}

function Get-LocalSdkPath {
    param([string]$GradleRoot)

    if (-not $GradleRoot) { return $null }
    $localProperties = Join-Path $GradleRoot 'local.properties'
    if (-not (Test-Path -LiteralPath $localProperties -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $localProperties) {
        if ($line -match '^\s*sdk\.dir\s*=\s*(.+)\s*$') {
            return [Environment]::ExpandEnvironmentVariables($matches[1].Trim().Replace('\:', ':').Replace('\\', '\'))
        }
    }
    return $null
}

function Resolve-Adb {
    param([string]$ProjectPath)

    $roots = @(Get-GradleRoots -Root $ProjectPath)
    $sdkRoots = @()
    if ($roots.Count -gt 0) {
        $localSdk = Get-LocalSdkPath -GradleRoot $roots[0]
        if ($localSdk) { $sdkRoots += $localSdk }
    }
    if ($env:ANDROID_SDK_ROOT) { $sdkRoots += $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { $sdkRoots += $env:ANDROID_HOME }
    if ($env:LOCALAPPDATA) { $sdkRoots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }

    foreach ($sdkRoot in @($sdkRoots | Select-Object -Unique)) {
        $candidate = Join-Path $sdkRoot 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-ConnectedDevices {
    param([Parameter(Mandatory = $true)][string]$Adb)

    $result = Invoke-NativeCaptured -FilePath $Adb -Arguments @('devices', '-l')
    if ($result.ExitCode -ne 0) { throw "adb failed while listing devices: $($result.Output -join ' ')" }

    $devices = @()
    foreach ($line in $result.Output) {
        if ($line -match '^(\S+)\s+device\b\s*(.*)$') {
            $serial = $matches[1]
            $details = $matches[2]
            $model = $serial
            if ($details -match '(?:^|\s)model:([^\s]+)') { $model = $matches[1].Replace('_', ' ') }
            $devices += [pscustomobject]@{ Serial = $serial; Model = $model }
        }
    }
    return @($devices)
}

function Select-Device {
    param(
        [Parameter(Mandatory = $true)][object[]]$Devices,
        [System.Windows.Forms.IWin32Window]$Owner
    )

    if ($Devices.Count -eq 0) { return $null }
    if ($Devices.Count -eq 1) { return $Devices[0] }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Choose Preferred Android Device'
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($null -ne $appIcon) { $dialog.Icon = $appIcon }
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 300)
    $dialog.MinimumSize = New-Object System.Drawing.Size(420, 280)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16, 16)
    $list.Size = New-Object System.Drawing.Size(488, 210)
    $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right
    foreach ($entry in $Devices) { [void]$list.Items.Add("$($entry.Model) [$($entry.Serial)]") }
    $dialog.Controls.Add($list)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Use Device'
    $ok.Size = New-Object System.Drawing.Size(110, 32)
    $ok.Location = New-Object System.Drawing.Point(286, 248)
    $ok.Enabled = $false
    $ok.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dialog.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object System.Drawing.Size(100, 32)
    $cancel.Location = New-Object System.Drawing.Point(404, 248)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    $list.Add_SelectedIndexChanged({ $ok.Enabled = ($list.SelectedIndex -ge 0) })
    $ok.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        $dialog.Tag = $Devices[$list.SelectedIndex]
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $list.Add_DoubleClick({ if ($list.SelectedIndex -ge 0) { $ok.PerformClick() } })
    $list.SelectedIndex = 0

    $result = if ($null -ne $Owner) { $dialog.ShowDialog($Owner) } else { $dialog.ShowDialog() }
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dialog.Tag
}

$projectPath = Normalize-Path -Path $Project
$preference = Get-Preference -ProjectPath $projectPath

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Android Project Settings'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
if ($null -ne $appIcon) { $form.Icon = $appIcon }
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object System.Drawing.Size(760, 390)
$form.MinimumSize = New-Object System.Drawing.Size(640, 430)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$title = New-Object System.Windows.Forms.Label
$title.Text = "Project: $projectPath"
$title.AutoSize = $false
$title.AutoEllipsis = $true
$title.Location = New-Object System.Drawing.Point(16, 16)
$title.Size = New-Object System.Drawing.Size(704, 24)
$title.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($title)

$taskLabel = New-Object System.Windows.Forms.Label
$taskLabel.Text = 'Gradle task:'
$taskLabel.AutoSize = $true
$taskLabel.Location = New-Object System.Drawing.Point(16, 58)
$form.Controls.Add($taskLabel)

$task = New-Object System.Windows.Forms.TextBox
$task.Location = New-Object System.Drawing.Point(150, 54)
$task.Size = New-Object System.Drawing.Size(570, 24)
$task.Text = $preference.gradleTask
$task.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($task)

$apkLabel = New-Object System.Windows.Forms.Label
$apkLabel.Text = 'Preferred APK:'
$apkLabel.AutoSize = $true
$apkLabel.Location = New-Object System.Drawing.Point(16, 100)
$form.Controls.Add($apkLabel)

$apk = New-Object System.Windows.Forms.TextBox
$apk.Location = New-Object System.Drawing.Point(150, 96)
$apk.Size = New-Object System.Drawing.Size(470, 24)
$apk.Text = $preference.preferredApk
$apk.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($apk)

$apkBrowse = New-Object System.Windows.Forms.Button
$apkBrowse.Text = 'Browse...'
$apkBrowse.Size = New-Object System.Drawing.Size(92, 28)
$apkBrowse.Location = New-Object System.Drawing.Point(628, 94)
$apkBrowse.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($apkBrowse)

$javaLabel = New-Object System.Windows.Forms.Label
$javaLabel.Text = 'JAVA_HOME:'
$javaLabel.AutoSize = $true
$javaLabel.Location = New-Object System.Drawing.Point(16, 142)
$form.Controls.Add($javaLabel)

$java = New-Object System.Windows.Forms.TextBox
$java.Location = New-Object System.Drawing.Point(150, 138)
$java.Size = New-Object System.Drawing.Size(470, 24)
$java.Text = $preference.javaHome
$java.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($java)

$javaBrowse = New-Object System.Windows.Forms.Button
$javaBrowse.Text = 'Browse...'
$javaBrowse.Size = New-Object System.Drawing.Size(92, 28)
$javaBrowse.Location = New-Object System.Drawing.Point(628, 136)
$javaBrowse.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($javaBrowse)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = 'Preferred device:'
$deviceLabel.AutoSize = $true
$deviceLabel.Location = New-Object System.Drawing.Point(16, 184)
$form.Controls.Add($deviceLabel)

$device = New-Object System.Windows.Forms.TextBox
$device.Location = New-Object System.Drawing.Point(150, 180)
$device.Size = New-Object System.Drawing.Size(470, 24)
$device.Text = $preference.deviceSerial
$device.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($device)

$deviceDetect = New-Object System.Windows.Forms.Button
$deviceDetect.Text = 'Detect...'
$deviceDetect.Size = New-Object System.Drawing.Size(92, 28)
$deviceDetect.Location = New-Object System.Drawing.Point(628, 178)
$deviceDetect.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($deviceDetect)

$launch = New-Object System.Windows.Forms.CheckBox
$launch.Text = 'Launch the app automatically after a successful install'
$launch.AutoSize = $true
$launch.Location = New-Object System.Drawing.Point(150, 226)
$launch.Checked = [bool]$preference.autoLaunch
$launch.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($launch)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Gradle task applies only to Gradle. Godot/custom builds use the configuration below. Detect stores the adb serial.'
$hint.AutoSize = $false
$hint.AutoEllipsis = $true
$hint.Location = New-Object System.Drawing.Point(150, 258)
$hint.Size = New-Object System.Drawing.Size(570, 36)
$hint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($hint)

$backendButton = New-Object System.Windows.Forms.Button
$backendButton.Text = 'Godot / custom build...'
$backendButton.Size = New-Object System.Drawing.Size(200, 30)
$backendButton.Location = New-Object System.Drawing.Point(150, 298)
$backendButton.Add_Click({
    try { & (Join-Path $PSScriptRoot 'Edit-AndroidBuildBackend.ps1') -Project $projectPath }
    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Build configuration') }
})
$form.Controls.Add($backendButton)

$reset = New-Object System.Windows.Forms.Button
$reset.Text = 'Reset Defaults'
$reset.Size = New-Object System.Drawing.Size(120, 32)
$reset.Location = New-Object System.Drawing.Point(16, 338)
$reset.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($reset)

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.Size = New-Object System.Drawing.Size(100, 32)
$save.Location = New-Object System.Drawing.Point(512, 338)
$save.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($save)

$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.Size = New-Object System.Drawing.Size(100, 32)
$cancel.Location = New-Object System.Drawing.Point(620, 338)
$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$cancel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($cancel)
$form.AcceptButton = $save
$form.CancelButton = $cancel

$apkBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose preferred APK'
    $dialog.Filter = 'Android packages (*.apk)|*.apk|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.InitialDirectory = $projectPath
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $apk.Text = Make-RelativeIfInsideProject -SelectedPath $dialog.FileName -ProjectPath $projectPath
    }
})

$javaBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a JDK folder containing bin\java.exe'
    $dialog.ShowNewFolderButton = $false
    if ($java.Text -and (Test-Path -LiteralPath $java.Text -PathType Container)) { $dialog.SelectedPath = $java.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $java.Text = $dialog.SelectedPath }
})

$deviceDetect.Add_Click({
    try {
        $adb = Resolve-Adb -ProjectPath $projectPath
        if (-not $adb) { throw 'adb.exe could not be found.' }
        $devices = @(Get-ConnectedDevices -Adb $adb)
        if ($devices.Count -eq 0) { throw 'No authorized Android device is currently connected.' }
        $selected = Select-Device -Devices $devices -Owner $form
        if ($null -ne $selected) { $device.Text = [string]$selected.Serial }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Android Project Settings') | Out-Null
    }
})

$reset.Add_Click({
    $task.Text = 'assembleDebug'
    $apk.Text = ''
    $java.Text = ''
    $device.Text = ''
    $launch.Checked = $false
})

$save.Add_Click({
    $gradleTask = $task.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($gradleTask)) { $gradleTask = 'assembleDebug' }

    $javaHome = $java.Text.Trim()
    if ($javaHome) {
        try { $javaHome = Normalize-Path -Path $javaHome } catch {
            [System.Windows.Forms.MessageBox]::Show('JAVA_HOME is not a valid path.', 'Android Project Settings') | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe') -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('The selected JAVA_HOME does not contain bin\java.exe.', 'Android Project Settings') | Out-Null
            return
        }
    }

    Save-Preference -Preference ([pscustomobject]@{
        path = $projectPath
        gradleTask = $gradleTask
        preferredApk = $apk.Text.Trim()
        javaHome = $javaHome
        autoLaunch = $launch.Checked
        deviceSerial = $device.Text.Trim()
    })

    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

$form.Add_Shown({
    if ($UiSmokeTest) {
        $form.ClientSize = New-Object System.Drawing.Size(680, 430)
        $form.Close()
    }
})

[void]$form.ShowDialog()
if ($null -ne $appIcon) { $appIcon.Dispose() }
