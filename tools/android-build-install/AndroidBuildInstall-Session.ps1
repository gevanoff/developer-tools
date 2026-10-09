[CmdletBinding()]
param(
    [string]$Project,
    [Parameter(DontShow = $true)][switch]$UiSmokeTest,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestOperation,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestOperationSuccess,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestCancellation,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestStatusRefresh,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestInheritedOutput
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'WindowsTaskbarIdentity.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()
$isUiSmokeTest = $UiSmokeTest -or $UiSmokeTestOperation -or $UiSmokeTestOperationSuccess -or
    $UiSmokeTestCancellation -or $UiSmokeTestStatusRefresh -or $UiSmokeTestInheritedOutput
$appUserModelId = Get-AndroidBuildInstallAppId
$taskbarIdentityAvailable = $null -ne ('WindowsTools.TaskbarIdentity' -as [type])
if ($taskbarIdentityAvailable) {
    try { [WindowsTools.TaskbarIdentity]::SetCurrentProcessAppId($appUserModelId) }
    catch { $taskbarIdentityAvailable = $false }
}

if ($null -eq ('WindowsTools.BufferedProcessRunner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace WindowsTools
{
    public sealed class BufferedProcessRunner : IDisposable
    {
        private readonly ConcurrentQueue<string> output = new ConcurrentQueue<string>();
        private Process process;
        private bool cancellationRequested;

        public bool CancellationRequested { get { return cancellationRequested; } }

        public int ProcessId
        {
            get { return process == null ? 0 : process.Id; }
        }

        public bool IsRunning
        {
            get
            {
                if (process == null) { return false; }
                try { return !process.HasExited; }
                catch { return false; }
            }
        }

        public void Start(string fileName, string arguments, string workingDirectory)
        {
            if (process != null) { throw new InvalidOperationException("The process runner has already been used."); }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = fileName;
            startInfo.Arguments = arguments;
            startInfo.WorkingDirectory = workingDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            process = new Process();
            process.StartInfo = startInfo;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
            {
                if (args.Data != null) { output.Enqueue(args.Data); }
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
            {
                if (args.Data != null) { output.Enqueue(args.Data); }
            };

            if (!process.Start()) { throw new InvalidOperationException("The operation process could not be started."); }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }

        public bool TryDequeue(out string line)
        {
            return output.TryDequeue(out line);
        }

        public int Finish()
        {
            if (process == null) { throw new InvalidOperationException("No operation process has been started."); }
            if (IsRunning) { throw new InvalidOperationException("The operation process is still running."); }

            int exitCode = process.ExitCode;
            // A persistent descendant such as a Gradle daemon can inherit the
            // redirected handles after the immediate operation process exits.
            // Give final callbacks a bounded interval, then close our readers
            // instead of waiting indefinitely for descendant-owned handles.
            System.Threading.Thread.Sleep(100);
            try { process.CancelOutputRead(); }
            catch { }
            try { process.CancelErrorRead(); }
            catch { }
            return exitCode;
        }

        public void Cancel()
        {
            if (process == null || !IsRunning) { return; }
            cancellationRequested = true;
            output.Enqueue("Cancellation requested. Stopping the operation process tree...");

            try
            {
                ProcessStartInfo stopInfo = new ProcessStartInfo();
                stopInfo.FileName = "taskkill.exe";
                stopInfo.Arguments = "/PID " + process.Id + " /T /F";
                stopInfo.UseShellExecute = false;
                stopInfo.CreateNoWindow = true;
                stopInfo.WindowStyle = ProcessWindowStyle.Hidden;
                using (Process stopper = Process.Start(stopInfo)) { }
            }
            catch
            {
                try { process.Kill(); }
                catch { }
            }
        }

        public void Dispose()
        {
            if (process == null) { return; }
            try
            {
                if (!process.HasExited) { Cancel(); }
                else { process.Close(); }
            }
            catch { }
            process = null;
        }
    }
}
'@
}

$stateRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WindowsTools\android-build-install'
} else {
    Join-Path $env:TEMP 'WindowsTools\android-build-install'
}
$logRoot = Join-Path $stateRoot 'logs'
$projectsPath = Join-Path $stateRoot 'projects.json'
$preferencesPath = Join-Path $stateRoot 'project-preferences.json'
$runner = Join-Path $PSScriptRoot 'Run-AndroidBuildInstall.ps1'
$settingsEditor = Join-Path $PSScriptRoot 'Edit-AndroidProjectPreferences.ps1'
$gitUpdater = Join-Path $PSScriptRoot 'Update-AndroidRepo.ps1'
$statusHelper = Join-Path $PSScriptRoot 'Get-AndroidProjectStatus.ps1'
$syncRunner = Join-Path $PSScriptRoot 'Invoke-AndroidSyncAndRun.ps1'
$appIconPath = Join-Path $PSScriptRoot 'assets\droidrun.ico'
$taskbarRelaunchCommand = "`"$(Join-Path $PSHOME 'powershell.exe')`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
$taskbarIconResource = "$appIconPath,0"
$appIcon = $null
if (Test-Path -LiteralPath $appIconPath -PathType Leaf) {
    try { $appIcon = New-Object System.Drawing.Icon($appIconPath) } catch { $appIcon = $null }
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function ConvertTo-ProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }

        if ($character -eq [char]34) {
            if ($backslashes -gt 0) { [void]$builder.Append([char]92, ($backslashes * 2)) }
            [void]$builder.Append([char]92)
            [void]$builder.Append([char]34)
        }
        else {
            if ($backslashes -gt 0) { [void]$builder.Append([char]92, $backslashes) }
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }

    if ($backslashes -gt 0) { [void]$builder.Append([char]92, ($backslashes * 2)) }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Join-ProcessArguments {
    param([string[]]$Arguments = @())
    return (@($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join ' ')
}

function Normalize-ProjectPath {
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

function Get-SavedProjects {
    if (-not (Test-Path -LiteralPath $projectsPath -PathType Leaf)) { return @() }
    try { $config = Get-Content -LiteralPath $projectsPath -Raw | ConvertFrom-Json } catch { return @() }

    $result = @()
    foreach ($item in @($config.projects)) {
        if ([string]::IsNullOrWhiteSpace("$item")) { continue }
        try { $path = Normalize-ProjectPath -Path "$item" } catch { continue }
        if ((Test-Path -LiteralPath $path -PathType Container) -and $result -notcontains $path) {
            $result += $path
        }
    }
    return @($result)
}

function Save-SavedProjects {
    param([string[]]$Projects = @())

    $unique = @()
    foreach ($item in @($Projects)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $path = Normalize-ProjectPath -Path $item
        if ($unique -notcontains $path) { $unique += $path }
    }

    [pscustomobject]@{ projects = @($unique) } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $projectsPath -Encoding UTF8
}

function Remember-Project {
    param([Parameter(Mandatory = $true)][string]$Path)

    $path = Normalize-ProjectPath -Path $Path
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $path }
    $others = @(Get-SavedProjects | Where-Object { $_ -ne $path })
    Save-SavedProjects -Projects (@($path) + $others)
    return $path
}

function Browse-ForProject {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Choose an Android repository or project folder'
    $picker.ShowNewFolderButton = $false
    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $picker.SelectedPath
}

function Get-ProjectPreference {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $default = [pscustomobject]@{
        gradleTask = 'assembleDebug'
        preferredApk = ''
        javaHome = ''
        autoLaunch = $false
        deviceSerial = ''
    }

    if (-not (Test-Path -LiteralPath $preferencesPath -PathType Leaf)) { return $default }
    try { $json = Get-Content -LiteralPath $preferencesPath -Raw | ConvertFrom-Json } catch { return $default }

    $normalized = Normalize-ProjectPath -Path $ProjectPath
    foreach ($item in @($json.projects)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace("$($item.path)")) { continue }
        try { $candidate = Normalize-ProjectPath -Path "$($item.path)" } catch { continue }
        if ($candidate -ieq $normalized) {
            return [pscustomobject]@{
                gradleTask = if ([string]::IsNullOrWhiteSpace("$($item.gradleTask)")) { 'assembleDebug' } else { "$($item.gradleTask)" }
                preferredApk = "$($item.preferredApk)"
                javaHome = "$($item.javaHome)"
                autoLaunch = [bool]$item.autoLaunch
                deviceSerial = "$($item.deviceSerial)"
            }
        }
    }
    return $default
}

function Get-LogSummary {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $projectPath = ''
    $exitCode = $null
    try {
        foreach ($line in Get-Content -LiteralPath $File.FullName) {
            if ($line -like 'Selected project argument:*') {
                $projectPath = $line.Substring('Selected project argument:'.Length).Trim()
            }
            elseif ($line -like 'Exit code:*') {
                $raw = $line.Substring('Exit code:'.Length).Trim()
                $parsed = 0
                if ([int]::TryParse($raw, [ref]$parsed)) { $exitCode = $parsed }
            }
        }
    }
    catch { }

    return [pscustomobject]@{
        Time = $File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Status = if ($null -eq $exitCode) { 'Incomplete' } elseif ($exitCode -eq 0) { 'Success' } else { 'Failed' }
        Project = if ($projectPath) { Split-Path -Leaf $projectPath } else { '(unknown)' }
        Path = $File.FullName
    }
}

function Show-Reports {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'DroidRun - Reports'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($null -ne $appIcon) { $form.Icon = $appIcon }
    $form.StartPosition = if ($null -ne $Owner) {
        [System.Windows.Forms.FormStartPosition]::CenterParent
    } else {
        [System.Windows.Forms.FormStartPosition]::CenterScreen
    }
    $form.ClientSize = New-Object System.Drawing.Size(880, 440)
    $form.MinimumSize = New-Object System.Drawing.Size(640, 400)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Recent build/install reports:'
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($label)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 46)
    $list.Size = New-Object System.Drawing.Size(848, 326)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right
    [void]$list.Columns.Add('Run', 155)
    [void]$list.Columns.Add('Result', 85)
    [void]$list.Columns.Add('Project', 180)
    [void]$list.Columns.Add('Report file', 400)
    $form.Controls.Add($list)

    foreach ($file in @(Get-ChildItem -LiteralPath $logRoot -Filter 'android-build-install-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $summary = Get-LogSummary -File $file
        $item = New-Object System.Windows.Forms.ListViewItem($summary.Time)
        [void]$item.SubItems.Add($summary.Status)
        [void]$item.SubItems.Add($summary.Project)
        [void]$item.SubItems.Add((Split-Path -Leaf $summary.Path))
        $item.Tag = $summary.Path
        [void]$list.Items.Add($item)
    }

    $open = New-Object System.Windows.Forms.Button
    $open.Text = 'Open Report'
    $open.Size = New-Object System.Drawing.Size(120, 32)
    $open.Location = New-Object System.Drawing.Point(16, 392)
    $open.Enabled = $false
    $open.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($open)

    $folder = New-Object System.Windows.Forms.Button
    $folder.Text = 'Open Reports Folder'
    $folder.Size = New-Object System.Drawing.Size(150, 32)
    $folder.Location = New-Object System.Drawing.Point(146, 392)
    $folder.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($folder)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Size = New-Object System.Drawing.Size(100, 32)
    $close.Location = New-Object System.Drawing.Point(764, 392)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($close)
    $form.CancelButton = $close

    $list.Add_SelectedIndexChanged({ $open.Enabled = ($list.SelectedItems.Count -eq 1) })
    $list.Add_Resize({
        $fixedWidth = 155 + 85 + 180
        $list.Columns[3].Width = [Math]::Max(150, $list.ClientSize.Width - $fixedWidth - 8)
    })
    $openReport = {
        if ($list.SelectedItems.Count -ne 1) { return }
        $path = [string]$list.SelectedItems[0].Tag
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Start-Process notepad.exe -ArgumentList "`"$path`""
        }
    }
    $open.Add_Click($openReport)
    $list.Add_DoubleClick($openReport)
    $folder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$logRoot`"" })

    if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
    if ($null -ne $Owner) { [void]$form.ShowDialog($Owner) }
    else { [void]$form.ShowDialog() }
}

function Get-StatusResults {
    param(
        [string[]]$Projects,
        [switch]$FetchRemote
    )

    if (-not (Test-Path -LiteralPath $statusHelper -PathType Leaf)) {
        throw "Status helper was not found:`n$statusHelper"
    }

    $splat = @{
        Project = @($Projects)
        PreferencesPath = $preferencesPath
    }
    if ($FetchRemote) { $splat.FetchRemote = $true }
    return @(& $statusHelper @splat)
}

function Show-DeviceScan {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $projects = @(Get-SavedProjects)
    if ($projects.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show($Owner, 'Add at least one Android project before scanning the device.', 'Android Device Scan') | Out-Null
        return
    }

    try { $results = @(Get-StatusResults -Projects $projects) }
    catch {
        [System.Windows.Forms.MessageBox]::Show($Owner, $_.Exception.Message, 'Android Device Scan') | Out-Null
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'DroidRun - Device Scan'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($null -ne $appIcon) { $form.Icon = $appIcon }
    $form.StartPosition = if ($null -ne $Owner) {
        [System.Windows.Forms.FormStartPosition]::CenterParent
    } else {
        [System.Windows.Forms.FormStartPosition]::CenterScreen
    }
    $form.ClientSize = New-Object System.Drawing.Size(1120, 500)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 440)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Each project uses its remembered device when configured. Same/Different is an exact SHA-256 APK comparison.'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 48)
    $list.Size = New-Object System.Drawing.Size(1088, 378)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right
    [void]$list.Columns.Add('Project', 180)
    [void]$list.Columns.Add('Device', 190)
    [void]$list.Columns.Add('Status', 130)
    [void]$list.Columns.Add('Detail', 560)
    $form.Controls.Add($list)
    $list.Add_Resize({
        $fixedWidth = 180 + 190 + 130
        $list.Columns[3].Width = [Math]::Max(180, $list.ClientSize.Width - $fixedWidth - 8)
    })

    foreach ($result in $results) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$result.Project)
        [void]$item.SubItems.Add([string]$result.Device)
        [void]$item.SubItems.Add([string]$result.DeviceStatus)
        [void]$item.SubItems.Add([string]$result.DeviceDetail)
        [void]$list.Items.Add($item)
    }

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Size = New-Object System.Drawing.Size(100, 32)
    $close.Location = New-Object System.Drawing.Point(1004, 450)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($close)
    $form.CancelButton = $close
    if ($null -ne $Owner) { [void]$form.ShowDialog($Owner) }
    else { [void]$form.ShowDialog() }
}

function Invoke-ProjectSettings {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $settingsEditor -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Settings editor was not found:`n$settingsEditor", 'Android Project Settings') | Out-Null
        return
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $settingsEditor -Project $ProjectPath -PreferencesPath $preferencesPath
}

function Select-SavedProjectAction {
    param([string]$InitialProject)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'DroidRun'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($null -ne $appIcon) { $form.Icon = $appIcon }
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(1180, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 680)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $taskbarIdentityState = [pscustomobject]@{ Applied = $false; Error = $null }
    if ($taskbarIdentityAvailable) {
        $form.Add_HandleCreated({
            try {
                [WindowsTools.TaskbarIdentity]::SetWindowProperties(
                    $form.Handle,
                    $appUserModelId,
                    $taskbarRelaunchCommand,
                    'DroidRun',
                    $taskbarIconResource
                )
                $taskbarIdentityState.Applied = $true
            }
            catch { $taskbarIdentityState.Error = $_.Exception.Message }
        })
    }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Android project dashboard'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(16, 16)
    $form.Controls.Add($title)

    $statusTimestamp = New-Object System.Windows.Forms.Label
    $statusTimestamp.Text = 'Status not checked.'
    $statusTimestamp.AutoSize = $false
    $statusTimestamp.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $statusTimestamp.Location = New-Object System.Drawing.Point(914, 12)
    $statusTimestamp.Size = New-Object System.Drawing.Size(250, 24)
    $form.Controls.Add($statusTimestamp)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Sync & Run updates Git safely, rebuilds and installs only when needed, then launches according to project settings.'
    $hint.AutoSize = $false
    $hint.AutoEllipsis = $true
    $hint.Location = New-Object System.Drawing.Point(16, 42)
    $hint.Size = New-Object System.Drawing.Size(1148, 20)
    $form.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 72)
    $list.Size = New-Object System.Drawing.Size(1148, 370)
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    $list.ShowItemToolTips = $true
    [void]$list.Columns.Add('Project', 170)
    [void]$list.Columns.Add('Git', 280)
    [void]$list.Columns.Add('Local Build', 130)
    [void]$list.Columns.Add('Device', 130)
    [void]$list.Columns.Add('Path', 590)
    [void]$list.Columns.Add('Checked', 90)
    $list.TabIndex = 0
    $form.Controls.Add($list)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = 'Select a project to see its settings.'
    $summary.AutoSize = $false
    $summary.AutoEllipsis = $true
    $summary.Location = New-Object System.Drawing.Point(16, 454)
    $summary.Size = New-Object System.Drawing.Size(1148, 40)
    $form.Controls.Add($summary)

    $operationGroup = New-Object System.Windows.Forms.GroupBox
    $operationGroup.Text = 'Operation output'
    $operationGroup.Location = New-Object System.Drawing.Point(16, 502)
    $operationGroup.Size = New-Object System.Drawing.Size(1148, 180)
    $operationGroup.TabStop = $false
    $form.Controls.Add($operationGroup)

    $operationProgress = New-Object System.Windows.Forms.ProgressBar
    $operationProgress.Location = New-Object System.Drawing.Point(12, 24)
    $operationProgress.Size = New-Object System.Drawing.Size(150, 18)
    $operationProgress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $operationProgress.MarqueeAnimationSpeed = 30
    $operationProgress.Visible = $false
    $operationGroup.Controls.Add($operationProgress)

    $operationStatus = New-Object System.Windows.Forms.Label
    $operationStatus.Text = 'Ready.'
    $operationStatus.AutoSize = $false
    $operationStatus.AutoEllipsis = $true
    $operationStatus.Location = New-Object System.Drawing.Point(12, 23)
    $operationStatus.Size = New-Object System.Drawing.Size(860, 20)
    $operationGroup.Controls.Add($operationStatus)

    $copyOutput = New-Object System.Windows.Forms.Button
    $copyOutput.Text = '&Copy Output'
    $copyOutput.Size = New-Object System.Drawing.Size(110, 28)
    $copyOutput.Location = New-Object System.Drawing.Point(926, 18)
    $copyOutput.Enabled = $false
    $copyOutput.TabIndex = 11
    $operationGroup.Controls.Add($copyOutput)

    $cancelOperation = New-Object System.Windows.Forms.Button
    $cancelOperation.Text = '&Cancel'
    $cancelOperation.Size = New-Object System.Drawing.Size(90, 28)
    $cancelOperation.Location = New-Object System.Drawing.Point(1046, 18)
    $cancelOperation.Enabled = $false
    $cancelOperation.TabIndex = 12
    $operationGroup.Controls.Add($cancelOperation)

    $operationOutput = New-Object System.Windows.Forms.RichTextBox
    $operationOutput.Location = New-Object System.Drawing.Point(12, 52)
    $operationOutput.Size = New-Object System.Drawing.Size(1124, 116)
    $operationOutput.ReadOnly = $true
    $operationOutput.BackColor = [System.Drawing.SystemColors]::Window
    $operationOutput.Font = New-Object System.Drawing.Font('Consolas', 9)
    $operationOutput.WordWrap = $false
    $operationOutput.DetectUrls = $false
    $operationOutput.HideSelection = $false
    $operationOutput.TabIndex = 10
    $operationGroup.Controls.Add($operationOutput)

    $add = New-Object System.Windows.Forms.Button
    $add.Text = '&Add...'
    $add.Size = New-Object System.Drawing.Size(90, 32)
    $add.Location = New-Object System.Drawing.Point(16, 642)
    $add.TabIndex = 6
    $form.Controls.Add($add)

    $remove = New-Object System.Windows.Forms.Button
    $remove.Text = '&Remove'
    $remove.Size = New-Object System.Drawing.Size(90, 32)
    $remove.Location = New-Object System.Drawing.Point(112, 642)
    $remove.Enabled = $false
    $remove.TabIndex = 7
    $form.Controls.Add($remove)

    $reports = New-Object System.Windows.Forms.Button
    $reports.Text = 'Re&ports...'
    $reports.Size = New-Object System.Drawing.Size(100, 32)
    $reports.Location = New-Object System.Drawing.Point(16, 682)
    $reports.TabIndex = 8
    $form.Controls.Add($reports)

    $scan = New-Object System.Windows.Forms.Button
    $scan.Text = 'Scan &Device...'
    $scan.Size = New-Object System.Drawing.Size(115, 32)
    $scan.Location = New-Object System.Drawing.Point(122, 682)
    $scan.TabIndex = 9
    $form.Controls.Add($scan)

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'Re&fresh Status'
    $refresh.Size = New-Object System.Drawing.Size(115, 32)
    $refresh.Location = New-Object System.Drawing.Point(243, 682)
    $refresh.TabIndex = 3
    $form.Controls.Add($refresh)

    $gitPull = New-Object System.Windows.Forms.Button
    $gitPull.Text = '&Git Pull'
    $gitPull.Size = New-Object System.Drawing.Size(90, 32)
    $gitPull.Location = New-Object System.Drawing.Point(364, 682)
    $gitPull.Enabled = $false
    $gitPull.TabIndex = 4
    $form.Controls.Add($gitPull)

    $settings = New-Object System.Windows.Forms.Button
    $settings.Text = 'Se&ttings...'
    $settings.Size = New-Object System.Drawing.Size(100, 32)
    $settings.Location = New-Object System.Drawing.Point(208, 642)
    $settings.Enabled = $false
    $settings.TabIndex = 5
    $form.Controls.Add($settings)

    $sync = New-Object System.Windows.Forms.Button
    $sync.Text = '&Sync && Run'
    $sync.Size = New-Object System.Drawing.Size(130, 32)
    $sync.Location = New-Object System.Drawing.Point(1034, 642)
    $sync.Enabled = $false
    $sync.TabIndex = 1
    $form.Controls.Add($sync)

    $build = New-Object System.Windows.Forms.Button
    $build.Text = '&Build && Install'
    $build.Size = New-Object System.Drawing.Size(130, 32)
    $build.Location = New-Object System.Drawing.Point(896, 642)
    $build.Enabled = $false
    $build.TabIndex = 2
    $form.Controls.Add($build)

    $exit = New-Object System.Windows.Forms.Button
    $exit.Text = 'E&xit'
    $exit.Size = New-Object System.Drawing.Size(90, 32)
    $exit.Location = New-Object System.Drawing.Point(1074, 682)
    $exit.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $exit.TabIndex = 13
    $form.Controls.Add($exit)
    $form.CancelButton = $exit
    $form.AcceptButton = $sync

    $trayIcon = $null
    $trayMenu = $null
    $trayOpen = $null
    $trayCancel = $null
    $trayExit = $null
    if ($null -ne $appIcon) {
        $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $trayOpen = $trayMenu.Items.Add('Open Dashboard')
        $trayCancel = $trayMenu.Items.Add('Cancel Current Operation')
        $trayCancel.Enabled = $false
        [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $trayExit = $trayMenu.Items.Add('Exit')

        $trayIcon = New-Object System.Windows.Forms.NotifyIcon
        $trayIcon.Icon = $appIcon
        $trayIcon.Text = 'DroidRun'
        $trayIcon.ContextMenuStrip = $trayMenu
        $trayIcon.Visible = -not $isUiSmokeTest

        $showDashboard = {
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
            $form.Show()
            $form.Activate()
        }
        $trayIcon.Add_DoubleClick($showDashboard)
        $trayOpen.Add_Click($showDashboard)
        $trayCancel.Add_Click({
            if ($cancelOperation.Enabled) { $cancelOperation.PerformClick() }
            elseif ($refresh.Enabled -and $refresh.Text -like '*Cancel Refresh*') { $refresh.PerformClick() }
        })
        $trayExit.Add_Click({ $form.Close() })
    }

    $layoutDashboard = {
        $clientWidth = $form.ClientSize.Width
        $clientHeight = $form.ClientSize.Height
        $scale = [Math]::Max(1.0, ([double]$form.DeviceDpi / 96.0))
        $margin = [int][Math]::Round(16 * $scale)
        $gap = [int][Math]::Round(6 * $scale)
        $right = $clientWidth - $margin
        $secondButtonRow = $clientHeight - $margin - $exit.Height
        $firstButtonRow = $secondButtonRow - $gap - $sync.Height
        $operationHeight = [int][Math]::Round(180 * $scale)
        $operationTop = $firstButtonRow - $gap - $operationHeight
        $summaryHeight = [int][Math]::Round(36 * $scale)
        $summaryTop = $operationTop - $gap - $summaryHeight
        $listHeight = [Math]::Max([int][Math]::Round(220 * $scale), $summaryTop - $gap - $list.Top)

        $hint.Width = [Math]::Max(100, $clientWidth - (2 * $margin))
        $statusTimestamp.Location = New-Object System.Drawing.Point(($clientWidth - $margin - $statusTimestamp.Width), $statusTimestamp.Top)
        $list.Size = New-Object System.Drawing.Size([Math]::Max(300, $clientWidth - (2 * $margin)), $listHeight)
        $summary.Location = New-Object System.Drawing.Point($margin, ($list.Bottom + $gap))
        $summary.Size = New-Object System.Drawing.Size([Math]::Max(100, $clientWidth - (2 * $margin)), $summaryHeight)
        $operationGroup.Location = New-Object System.Drawing.Point($margin, $operationTop)
        $operationGroup.Size = New-Object System.Drawing.Size([Math]::Max(300, $clientWidth - (2 * $margin)), $operationHeight)

        $operationMargin = [int][Math]::Round(12 * $scale)
        $operationButtonTop = [int][Math]::Round(18 * $scale)
        $operationStatusTop = [int][Math]::Round(23 * $scale)
        $operationOutputTop = [int][Math]::Round(52 * $scale)
        $operationBottomSpace = [int][Math]::Round(12 * $scale)
        $cancelOperation.Location = New-Object System.Drawing.Point(
            ($operationGroup.ClientSize.Width - $operationMargin - $cancelOperation.Width),
            $operationButtonTop
        )
        $copyOutput.Location = New-Object System.Drawing.Point(($cancelOperation.Left - $gap - $copyOutput.Width), $operationButtonTop)
        $statusLeft = if ($operationProgress.Visible) { $operationProgress.Right + $gap } else { $operationMargin }
        $operationStatus.Location = New-Object System.Drawing.Point($statusLeft, $operationStatusTop)
        $operationStatus.Width = [Math]::Max(100, $copyOutput.Left - $gap - $statusLeft)
        $operationOutput.Location = New-Object System.Drawing.Point($operationMargin, $operationOutputTop)
        $operationOutput.Size = New-Object System.Drawing.Size(
            [Math]::Max(200, $operationGroup.ClientSize.Width - (2 * $operationMargin)),
            [Math]::Max(60, $operationGroup.ClientSize.Height - $operationOutputTop - $operationBottomSpace)
        )

        $add.Location = New-Object System.Drawing.Point($margin, $firstButtonRow)
        $remove.Location = New-Object System.Drawing.Point(($add.Right + $gap), $firstButtonRow)
        $settings.Location = New-Object System.Drawing.Point(($remove.Right + $gap), $firstButtonRow)
        $sync.Location = New-Object System.Drawing.Point(($right - $sync.Width), $firstButtonRow)
        $build.Location = New-Object System.Drawing.Point(($sync.Left - $gap - $build.Width), $firstButtonRow)

        $reports.Location = New-Object System.Drawing.Point($margin, $secondButtonRow)
        $scan.Location = New-Object System.Drawing.Point(($reports.Right + $gap), $secondButtonRow)
        $refresh.Location = New-Object System.Drawing.Point(($scan.Right + $gap), $secondButtonRow)
        $gitPull.Location = New-Object System.Drawing.Point(($refresh.Right + $gap), $secondButtonRow)
        $exit.Location = New-Object System.Drawing.Point(($right - $exit.Width), $secondButtonRow)

        $fixedColumnWidth = $list.Columns[0].Width + $list.Columns[1].Width +
            $list.Columns[2].Width + $list.Columns[3].Width + $list.Columns[5].Width
        $list.Columns[4].Width = [Math]::Max(180, $list.ClientSize.Width - $fixedColumnWidth - 8)
    }

    $form.Add_Resize({ & $layoutDashboard })
    & $layoutDashboard

    $selectedPath = {
        if ($list.SelectedItems.Count -ne 1) { return $null }
        return [string]$list.SelectedItems[0].Tag
    }

    $refreshSummary = {
        $path = & $selectedPath
        if (-not $path) {
            $summary.Text = 'Select a project to see its settings.'
            return
        }
        $pref = Get-ProjectPreference -ProjectPath $path
        $apkText = if ($pref.preferredApk) { $pref.preferredApk } else { '(prompt/default)' }
        $javaText = if ($pref.javaHome) { $pref.javaHome } else { '(environment default)' }
        $deviceText = if ($pref.deviceSerial) { $pref.deviceSerial } else { '(automatic)' }
        $summary.Text = "Task: $($pref.gradleTask)    APK: $apkText    JDK: $javaText    Device: $deviceText    Auto-launch: $([bool]$pref.autoLaunch)"
    }

    $dashboardState = [pscustomobject]@{
        Operation = $null
        StatusRefresh = $null
        PendingInitialProject = $null
        LastExitCode = 0
        SmokeCancelTimer = $null
    }

    $statusTimer = New-Object System.Windows.Forms.Timer
    $statusTimer.Interval = 100

    $setStatusRow = {
        param(
            [Parameter(Mandatory = $true)]$Result,
            [string]$CheckedText = (Get-Date -Format 'HH:mm:ss')
        )

        $item = $null
        foreach ($candidate in $list.Items) {
            if (([string]$candidate.Tag) -ieq ([string]$Result.ProjectPath)) {
                $item = $candidate
                break
            }
        }
        if ($null -eq $item) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$Result.Project)
            for ($index = 1; $index -lt 6; $index++) { [void]$item.SubItems.Add('') }
            $item.Tag = [string]$Result.ProjectPath
            [void]$list.Items.Add($item)
        }

        while ($item.SubItems.Count -lt 6) { [void]$item.SubItems.Add('') }
        $item.Text = [string]$Result.Project
        $gitDisplay = if ($Result.GitBranch) { "$($Result.GitBranch) | $($Result.GitStatus)" } else { [string]$Result.GitStatus }
        $item.SubItems[1].Text = $gitDisplay
        $item.SubItems[2].Text = [string]$Result.BuildStatus
        $item.SubItems[3].Text = [string]$Result.DeviceStatus
        $item.SubItems[4].Text = [string]$Result.ProjectPath
        $item.SubItems[5].Text = $CheckedText
        $item.ToolTipText = "Git: $gitDisplay`n$($Result.GitDetail)`nBuild: $($Result.BuildDetail)`nDevice: $($Result.DeviceDetail)"
    }

    $newUnknownStatus = {
        param(
            [Parameter(Mandatory = $true)][string]$ProjectPath,
            [Parameter(Mandatory = $true)][string]$Detail
        )
        return [pscustomobject]@{
            ProjectPath = $ProjectPath
            Project = Split-Path -Leaf $ProjectPath
            GitStatus = 'Unknown'
            GitDetail = $Detail
            BuildStatus = 'Unknown'
            BuildDetail = $Detail
            DeviceStatus = 'Unknown'
            DeviceDetail = $Detail
            Device = ''
        }
    }

    $cleanupStatusProcess = {
        if ($null -eq $dashboardState.StatusRefresh) { return }
        $refreshState = $dashboardState.StatusRefresh
        if ($null -ne $refreshState.CurrentRunner) {
            $refreshState.CurrentRunner.Dispose()
            $refreshState.CurrentRunner = $null
        }
        if ($refreshState.OutputPath -and (Test-Path -LiteralPath $refreshState.OutputPath -PathType Leaf)) {
            Remove-Item -LiteralPath $refreshState.OutputPath -Force -ErrorAction SilentlyContinue
        }
        $refreshState.OutputPath = $null
    }

    $finishStatusRefresh = {
        param([string]$Message)

        if ($null -eq $dashboardState.StatusRefresh) { return }
        & $cleanupStatusProcess
        $completed = $dashboardState.StatusRefresh.Completed
        $total = $dashboardState.StatusRefresh.Projects.Count
        $wasCancelled = $dashboardState.StatusRefresh.CancelRequested
        $dashboardState.StatusRefresh = $null
        $statusTimer.Stop()
        $form.Text = 'DroidRun'
        if ($null -ne $trayIcon) { $trayIcon.Text = 'DroidRun' }
        $statusTimestamp.Text = if ($Message) {
            $Message
        } else {
            "Last checked: $(Get-Date -Format 'HH:mm:ss') ($completed/$total)"
        }
        & $setOperationControls
        & $refreshSummary

        if ($UiSmokeTestStatusRefresh) {
            Write-Host "UI status smoke result: $completed/$total"
            foreach ($item in $list.Items) {
                Write-Host "UI status row: $($item.Text) | $($item.SubItems[1].Text) | $($item.SubItems[2].Text) | $($item.SubItems[3].Text)"
            }
            $form.Close()
            return
        }

        if ($wasCancelled) {
            $dashboardState.PendingInitialProject = $null
        }
        elseif ($dashboardState.PendingInitialProject) {
            $pendingProject = $dashboardState.PendingInitialProject
            $dashboardState.PendingInitialProject = $null
            & $startOperation 'Build' $pendingProject
        }
    }

    $startNextStatusProject = {
        if ($null -eq $dashboardState.StatusRefresh) { return }
        $refreshState = $dashboardState.StatusRefresh
        if ($refreshState.CancelRequested) {
            & $finishStatusRefresh 'Status refresh cancelled.'
            return
        }
        if ($refreshState.Index -ge $refreshState.Projects.Count) {
            & $finishStatusRefresh
            return
        }

        $projectPath = [string]$refreshState.Projects[$refreshState.Index]
        $outputPath = Join-Path $stateRoot ("status-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $statusHelper,
            '-Project', $projectPath,
            '-PreferencesPath', $preferencesPath,
            '-OutputJsonPath', $outputPath
        )
        if ($refreshState.FetchRemote) { $arguments += '-FetchRemote' }

        $powershellPath = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = 'powershell.exe' }
        $runnerInstance = New-Object WindowsTools.BufferedProcessRunner
        $refreshState.CurrentRunner = $runnerInstance
        $refreshState.OutputPath = $outputPath
        $refreshState.CurrentProject = $projectPath
        $refreshState.CurrentStartedAt = Get-Date
        $refreshState.TimedOut = $false
        $position = $refreshState.Index + 1
        $statusTimestamp.Text = "Checking $position/$($refreshState.Projects.Count): $(Split-Path -Leaf $projectPath)"
        $form.Text = 'DroidRun - Refreshing status...'
        if ($null -ne $trayIcon) { $trayIcon.Text = "DroidRun - Status $position/$($refreshState.Projects.Count)" }

        try {
            $runnerInstance.Start($powershellPath, (Join-ProcessArguments -Arguments $arguments), $PSScriptRoot)
            $statusTimer.Start()
        }
        catch {
            $detail = "Status process could not be started: $($_.Exception.Message)"
            & $setStatusRow -Result (& $newUnknownStatus -ProjectPath $projectPath -Detail $detail) -CheckedText 'Failed'
            & $cleanupStatusProcess
            $refreshState.Index++
            & $startNextStatusProject
        }
    }

    $statusTimer.Add_Tick({
        if ($null -eq $dashboardState.StatusRefresh) {
            $statusTimer.Stop()
            return
        }

        $refreshState = $dashboardState.StatusRefresh
        $runnerInstance = $refreshState.CurrentRunner
        if ($null -eq $runnerInstance) {
            & $startNextStatusProject
            return
        }

        if (-not $refreshState.TimedOut -and
            ((Get-Date) - $refreshState.CurrentStartedAt).TotalSeconds -ge $refreshState.TimeoutSeconds) {
            $refreshState.TimedOut = $true
            $statusTimestamp.Text = "Status timed out; stopping $(Split-Path -Leaf $refreshState.CurrentProject)..."
            $runnerInstance.Cancel()
        }

        if ($runnerInstance.IsRunning) { return }

        try { $exitCode = $runnerInstance.Finish() } catch { $exitCode = 1 }
        $diagnostics = New-Object System.Collections.Generic.List[string]
        $line = $null
        while ($runnerInstance.TryDequeue([ref]$line)) {
            if ($line) { $diagnostics.Add($line) }
            $line = $null
        }

        $projectPath = $refreshState.CurrentProject
        if ($refreshState.CancelRequested) {
            & $finishStatusRefresh 'Status refresh cancelled.'
            return
        }
        elseif ($refreshState.TimedOut) {
            $detail = "Status refresh exceeded $($refreshState.TimeoutSeconds) seconds and was cancelled."
            & $setStatusRow -Result (& $newUnknownStatus -ProjectPath $projectPath -Detail $detail) -CheckedText 'Timed out'
        }
        elseif ($exitCode -eq 0 -and (Test-Path -LiteralPath $refreshState.OutputPath -PathType Leaf)) {
            try {
                $statusResults = @(Get-Content -LiteralPath $refreshState.OutputPath -Raw | ConvertFrom-Json)
                if ($statusResults.Count -eq 0) { throw 'Status helper returned no project result.' }
                & $setStatusRow -Result $statusResults[0]
            }
            catch {
                & $setStatusRow -Result (& $newUnknownStatus -ProjectPath $projectPath -Detail $_.Exception.Message) -CheckedText 'Failed'
            }
        }
        else {
            $detail = if ($diagnostics.Count -gt 0) {
                $diagnostics -join [Environment]::NewLine
            } else {
                "Status helper failed with exit code $exitCode."
            }
            & $setStatusRow -Result (& $newUnknownStatus -ProjectPath $projectPath -Detail $detail) -CheckedText 'Failed'
        }

        $refreshState.Completed++
        & $cleanupStatusProcess
        $refreshState.Index++
        & $startNextStatusProject
    })

    $refreshRows = {
        param([bool]$FetchRemote = $true)

        if ($null -ne $dashboardState.StatusRefresh -or $null -ne $dashboardState.Operation) { return }
        $projects = @(Get-SavedProjects)
        $selectedBefore = & $selectedPath
        $cached = @{}
        foreach ($existing in $list.Items) {
            $values = @()
            foreach ($subItem in $existing.SubItems) { $values += [string]$subItem.Text }
            $cached[[string]$existing.Tag] = [pscustomobject]@{
                Values = $values
                ToolTipText = $existing.ToolTipText
            }
        }

        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            foreach ($projectPath in $projects) {
                $entry = $cached[[string]$projectPath]
                if ($null -ne $entry -and $entry.Values.Count -ge 5) {
                    $item = New-Object System.Windows.Forms.ListViewItem($entry.Values[0])
                    for ($index = 1; $index -lt 5; $index++) { [void]$item.SubItems.Add($entry.Values[$index]) }
                    [void]$item.SubItems.Add('Queued')
                    $item.ToolTipText = $entry.ToolTipText
                }
                else {
                    $item = New-Object System.Windows.Forms.ListViewItem((Split-Path -Leaf $projectPath))
                    [void]$item.SubItems.Add('Checking...')
                    [void]$item.SubItems.Add('Checking...')
                    [void]$item.SubItems.Add('Checking...')
                    [void]$item.SubItems.Add($projectPath)
                    [void]$item.SubItems.Add('Queued')
                }
                $item.Tag = $projectPath
                [void]$list.Items.Add($item)
                if ($selectedBefore -and $projectPath -ieq $selectedBefore) { $item.Selected = $true }
            }
        }
        finally { $list.EndUpdate() }

        if ($list.SelectedItems.Count -eq 0 -and $list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
        if ($projects.Count -eq 0) {
            $statusTimestamp.Text = 'No saved projects.'
            & $refreshSummary
            return
        }

        $dashboardState.StatusRefresh = [pscustomobject]@{
            Projects = $projects
            Index = 0
            Completed = 0
            FetchRemote = $FetchRemote
            CancelRequested = $false
            TimeoutSeconds = 60
            CurrentRunner = $null
            CurrentProject = $null
            CurrentStartedAt = $null
            OutputPath = $null
            TimedOut = $false
        }
        & $setOperationControls
        & $startNextStatusProject
    }

    $appendOperationOutput = {
        param([object[]]$Lines)

        $text = @($Lines | Where-Object { $null -ne $_ } | ForEach-Object { "$_" }) -join [Environment]::NewLine
        if ([string]::IsNullOrEmpty($text)) { return }
        $operationOutput.AppendText($text + [Environment]::NewLine)

        if ($operationOutput.TextLength -gt 1000000) {
            $removeLength = $operationOutput.TextLength - 800000
            $operationOutput.Select(0, $removeLength)
            $operationOutput.SelectedText = "[Earlier output trimmed from the dashboard; the detailed report remains complete.]$([Environment]::NewLine)"
        }

        $operationOutput.SelectionStart = $operationOutput.TextLength
        $operationOutput.SelectionLength = 0
        $operationOutput.ScrollToCaret()
        $copyOutput.Enabled = ($operationOutput.TextLength -gt 0)
    }

    $setOperationControls = {
        $busy = ($null -ne $dashboardState.Operation)
        $statusBusy = ($null -ne $dashboardState.StatusRefresh)
        $anyBusy = $busy -or $statusBusy
        $selected = ($list.SelectedItems.Count -eq 1)

        $list.Enabled = -not $busy
        $add.Enabled = -not $anyBusy
        $remove.Enabled = $selected -and -not $anyBusy
        $reports.Enabled = -not $busy
        $scan.Enabled = -not $anyBusy
        $refresh.Enabled = -not $busy
        $refresh.Text = if ($statusBusy) { '&Cancel Refresh' } else { 'Re&fresh Status' }
        $gitPull.Enabled = $selected -and -not $anyBusy
        $settings.Enabled = $selected -and -not $anyBusy
        $sync.Enabled = $selected -and -not $anyBusy
        $build.Enabled = $selected -and -not $anyBusy
        $cancelOperation.Enabled = $busy
        $operationProgress.Visible = $busy
        if ($null -ne $trayCancel) {
            $trayCancel.Enabled = $anyBusy
            $trayCancel.Text = if ($busy) {
                'Cancel Current Operation'
            } elseif ($statusBusy) {
                'Cancel Status Refresh'
            } else {
                'Cancel Current Operation'
            }
        }
        & $layoutDashboard
    }

    $operationTimer = New-Object System.Windows.Forms.Timer
    $operationTimer.Interval = 100

    $completeOperation = {
        if ($null -eq $dashboardState.Operation) { return }

        $operation = $dashboardState.Operation
        $lines = New-Object System.Collections.Generic.List[string]
        $line = $null
        while ($operation.Runner.TryDequeue([ref]$line)) {
            if ($null -ne $line) { $lines.Add($line) }
            $line = $null
        }
        if ($lines.Count -gt 0) { & $appendOperationOutput $lines.ToArray() }

        try { $exitCode = $operation.Runner.Finish() }
        catch {
            $exitCode = 1
            & $appendOperationOutput @("ERROR: Could not collect the operation result: $($_.Exception.Message)")
        }

        $lines.Clear()
        while ($operation.Runner.TryDequeue([ref]$line)) {
            if ($null -ne $line) { $lines.Add($line) }
            $line = $null
        }
        if ($lines.Count -gt 0) { & $appendOperationOutput $lines.ToArray() }

        $elapsed = (Get-Date) - $operation.StartedAt
        $dashboardState.LastExitCode = $exitCode
        $wasCancelled = $operation.Runner.CancellationRequested
        if ($wasCancelled) {
            $operationStatus.Text = "$($operation.DisplayName) cancelled after $([Math]::Round($elapsed.TotalSeconds, 1)) seconds."
            $operationStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            & $appendOperationOutput @('', "Cancelled. Exit code: $exitCode")
        }
        elseif ($exitCode -eq 0) {
            $operationStatus.Text = "$($operation.DisplayName) completed in $([Math]::Round($elapsed.TotalSeconds, 1)) seconds."
            $operationStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            & $appendOperationOutput @('', "Completed successfully. Exit code: $exitCode")
        }
        else {
            $operationStatus.Text = "$($operation.DisplayName) failed with exit code $exitCode after $([Math]::Round($elapsed.TotalSeconds, 1)) seconds."
            $operationStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $failureHint = if ($operation.Action -eq 'GitPull') {
                'Review the Git output above before retrying.'
            } else {
                'Use Reports to open the complete build/install log.'
            }
            & $appendOperationOutput @('', "Failed. Exit code: $exitCode", $failureHint)
        }

        $operation.Runner.Dispose()
        $dashboardState.Operation = $null
        $operationTimer.Stop()
        $form.Text = 'DroidRun'
        if ($null -ne $trayIcon -and -not $isUiSmokeTest) {
            $trayIcon.Text = 'DroidRun'
            $trayIcon.BalloonTipTitle = 'DroidRun'
            $trayIcon.BalloonTipText = $operationStatus.Text
            $trayIcon.BalloonTipIcon = if ($exitCode -eq 0) {
                [System.Windows.Forms.ToolTipIcon]::Info
            } elseif ($wasCancelled) {
                [System.Windows.Forms.ToolTipIcon]::Warning
            } else {
                [System.Windows.Forms.ToolTipIcon]::Error
            }
            $trayIcon.ShowBalloonTip(3000)
        }
        & $setOperationControls
        if ($UiSmokeTestOperation -or $UiSmokeTestOperationSuccess -or $UiSmokeTestCancellation -or $UiSmokeTestInheritedOutput) {
            Write-Host $operationOutput.Text
            Write-Host "UI operation elapsed seconds: $($elapsed.TotalSeconds)"
            Write-Host "UI operation smoke result: $exitCode"
            $form.Close()
            return
        }
        & $refreshRows $false
    }

    $operationTimer.Add_Tick({
        if ($null -eq $dashboardState.Operation) {
            $operationTimer.Stop()
            return
        }

        $operation = $dashboardState.Operation
        $lines = New-Object System.Collections.Generic.List[string]
        $line = $null
        while ($operation.Runner.TryDequeue([ref]$line)) {
            if ($null -ne $line) { $lines.Add($line) }
            $line = $null
        }
        if ($lines.Count -gt 0) { & $appendOperationOutput $lines.ToArray() }

        if (-not $operation.Runner.IsRunning) { & $completeOperation }
    })

    $startOperation = {
        param(
            [ValidateSet('Sync', 'Build', 'GitPull', 'SmokeSuccess', 'SmokeCancel', 'SmokeInheritedOutput')][string]$Action,
            [string]$ProjectPath
        )

        if ($null -ne $dashboardState.Operation -or $null -ne $dashboardState.StatusRefresh) { return }
        if (-not $ProjectPath -and $Action -notlike 'Smoke*') { $ProjectPath = & $selectedPath }
        if ($Action -eq 'SmokeSuccess') { $ProjectPath = '(UI success smoke test)' }
        if ($Action -eq 'SmokeCancel') { $ProjectPath = '(UI cancellation smoke test)' }
        if ($Action -eq 'SmokeInheritedOutput') { $ProjectPath = '(UI inherited-output smoke test)' }
        if (-not $ProjectPath) { return }

        $displayName = if ($Action -eq 'Sync') {
            'Sync & Run'
        } elseif ($Action -eq 'Build') {
            'Build & Install'
        } elseif ($Action -eq 'GitPull') {
            'Git Pull'
        } elseif ($Action -eq 'SmokeSuccess') {
            'Success smoke test'
        } elseif ($Action -eq 'SmokeInheritedOutput') {
            'Inherited-output smoke test'
        } else {
            'Cancellation smoke test'
        }
        $scriptPath = if ($Action -eq 'Sync') {
            $syncRunner
        } elseif ($Action -eq 'GitPull') {
            $gitUpdater
        } else {
            $runner
        }
        if ($Action -notlike 'Smoke*' -and -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            $operationStatus.Text = "$displayName could not start because its helper script is missing."
            $operationStatus.ForeColor = [System.Drawing.Color]::Firebrick
            & $appendOperationOutput @("Helper script was not found: $scriptPath")
            return
        }

        $arguments = if ($Action -eq 'SmokeSuccess') {
            @('-NoProfile', '-Command', 'Write-Output ''Smoke operation completed successfully.''; exit 0')
        } elseif ($Action -eq 'SmokeInheritedOutput') {
            @(
                '-NoProfile',
                '-Command',
                '$child = Start-Process powershell.exe -ArgumentList ''-NoProfile -Command "Start-Sleep -Seconds 4"'' -NoNewWindow -PassThru; Write-Output "Inherited-output child PID: $($child.Id)"; Write-Output ''Immediate parent completed.''; exit 0'
            )
        } elseif ($Action -eq 'SmokeCancel') {
            @(
                '-NoProfile',
                '-Command',
                'Write-Output ''Smoke operation started.''; Start-Sleep -Seconds 30; Write-Output ''Smoke operation completed unexpectedly.'''
            )
        } else {
            @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Project', $ProjectPath)
        }
        if ($Action -eq 'Sync') {
            $arguments += @('-PreferencesPath', $preferencesPath, '-NoUi')
        }
        elseif ($Action -eq 'Build') {
            $pref = Get-ProjectPreference -ProjectPath $ProjectPath
            $arguments += @('-GradleTask', $pref.gradleTask, '-SuppressSuccessDialog', '-NoUi')
            if ($pref.preferredApk) { $arguments += @('-PreferredApk', $pref.preferredApk) }
            if ($pref.javaHome) { $arguments += @('-JavaHome', $pref.javaHome) }
            if ($pref.deviceSerial) { $arguments += @('-DeviceSerial', $pref.deviceSerial) }
            if ($pref.autoLaunch) { $arguments += '-AutoLaunch' }
        }
        elseif ($Action -eq 'GitPull') {
            $arguments += '-NoUi'
        }

        $powershellPath = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = 'powershell.exe' }
        $processArguments = Join-ProcessArguments -Arguments $arguments
        $processRunner = New-Object WindowsTools.BufferedProcessRunner

        $operationOutput.Clear()
        $operationStatus.Text = "Starting $displayName..."
        $operationStatus.ForeColor = [System.Drawing.SystemColors]::ControlText
        & $appendOperationOutput @(
            "$displayName",
            ('=' * $displayName.Length),
            "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
            "Project: $ProjectPath",
            ''
        )

        $dashboardState.Operation = [pscustomobject]@{
            Runner = $processRunner
            Action = $Action
            DisplayName = $displayName
            ProjectPath = $ProjectPath
            StartedAt = Get-Date
        }
        & $setOperationControls

        try {
            $processRunner.Start($powershellPath, $processArguments, $PSScriptRoot)
            $operationStatus.Text = "$displayName is running..."
            $form.Text = "DroidRun - $displayName"
            if ($null -ne $trayIcon) { $trayIcon.Text = "DroidRun - $displayName" }
            $operationTimer.Start()
        }
        catch {
            $processRunner.Dispose()
            $dashboardState.Operation = $null
            $dashboardState.LastExitCode = 1
            $operationStatus.Text = "$displayName could not be started."
            $operationStatus.ForeColor = [System.Drawing.Color]::Firebrick
            & $appendOperationOutput @("ERROR: $($_.Exception.Message)")
            & $setOperationControls
        }
    }

    $list.Add_SelectedIndexChanged({
        & $setOperationControls
        & $refreshSummary
    })

    $sync.Add_Click({ & $startOperation 'Sync' })
    $build.Add_Click({ & $startOperation 'Build' })
    $list.Add_DoubleClick({ if ($list.SelectedItems.Count -eq 1) { & $startOperation 'Sync' } })

    $copyOutput.Add_Click({
        if ($operationOutput.TextLength -gt 0) {
            try { [System.Windows.Forms.Clipboard]::SetText($operationOutput.Text) } catch { }
        }
    })

    $cancelOperation.Add_Click({
        if ($null -eq $dashboardState.Operation) { return }
        $cancelOperation.Enabled = $false
        $operationStatus.Text = "Cancelling $($dashboardState.Operation.DisplayName)..."
        $operationStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $dashboardState.Operation.Runner.Cancel()
    })

    $add.Add_Click({
        $path = Browse-ForProject
        if (-not $path) { return }
        try { [void](Remember-Project -Path $path) } catch { return }
        & $refreshRows $false
    })

    $remove.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        $remaining = @(Get-SavedProjects | Where-Object { $_ -ine $path })
        Save-SavedProjects -Projects $remaining
        & $refreshRows $false
    })

    $reports.Add_Click({ Show-Reports -Owner $form })
    $scan.Add_Click({ Show-DeviceScan -Owner $form })
    $refresh.Add_Click({
        if ($null -ne $dashboardState.StatusRefresh) {
            $dashboardState.StatusRefresh.CancelRequested = $true
            $statusTimestamp.Text = 'Cancelling status refresh...'
            if ($null -ne $dashboardState.StatusRefresh.CurrentRunner) {
                $dashboardState.StatusRefresh.CurrentRunner.Cancel()
            }
            else {
                & $finishStatusRefresh 'Status refresh cancelled.'
            }
            return
        }
        & $refreshRows $true
    })
    $gitPull.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        & $startOperation 'GitPull' $path
    })
    $settings.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        Invoke-ProjectSettings -ProjectPath $path
        & $refreshRows $false
    })

    $form.Add_Shown({
        if ($UiSmokeTest -and -not $UiSmokeTestOperation -and -not $UiSmokeTestOperationSuccess -and
            -not $UiSmokeTestCancellation -and -not $UiSmokeTestStatusRefresh -and -not $UiSmokeTestInheritedOutput) {
            if ($taskbarIdentityAvailable -and -not $taskbarIdentityState.Applied) {
                throw "Taskbar identity could not be applied: $($taskbarIdentityState.Error)"
            }
            Write-Host "UI taskbar identity: $appUserModelId"
            $form.ClientSize = New-Object System.Drawing.Size(940, 700)
            & $layoutDashboard
            $form.Close()
            return
        }
        if ($UiSmokeTestOperationSuccess) {
            & $startOperation 'SmokeSuccess'
            return
        }
        elseif ($UiSmokeTestCancellation) {
            & $startOperation 'SmokeCancel'
            $dashboardState.SmokeCancelTimer = New-Object System.Windows.Forms.Timer
            $dashboardState.SmokeCancelTimer.Interval = 300
            $dashboardState.SmokeCancelTimer.Add_Tick({
                $dashboardState.SmokeCancelTimer.Stop()
                $cancelOperation.PerformClick()
            })
            $dashboardState.SmokeCancelTimer.Start()
            return
        }
        elseif ($UiSmokeTestInheritedOutput) {
            & $startOperation 'SmokeInheritedOutput'
            return
        }
        elseif ($UiSmokeTestOperation) {
            & $startOperation 'Build' $InitialProject
            return
        }

        if ($InitialProject -and -not $UiSmokeTestStatusRefresh) {
            $dashboardState.PendingInitialProject = $InitialProject
        }
        & $refreshRows $true

        if ($InitialProject) {
            foreach ($item in $list.Items) {
                if (([string]$item.Tag) -ieq $InitialProject) {
                    $item.Selected = $true
                    $item.Focused = $true
                    $item.EnsureVisible()
                    break
                }
            }
            if ($null -eq $dashboardState.StatusRefresh) {
                $dashboardState.PendingInitialProject = $null
                & $startOperation 'Build' $InitialProject
            }
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)

        if ($null -eq $dashboardState.Operation) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "$($dashboardState.Operation.DisplayName) is still running. Cancel it and exit?",
            'DroidRun',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }

        $dashboardState.LastExitCode = 1
        $dashboardState.Operation.Runner.Cancel()
    })

    $form.Add_FormClosed({
        $operationTimer.Stop()
        $operationTimer.Dispose()
        $statusTimer.Stop()
        if ($null -ne $dashboardState.StatusRefresh) {
            if ($null -ne $dashboardState.StatusRefresh.CurrentRunner) {
                $dashboardState.StatusRefresh.CurrentRunner.Dispose()
            }
            if ($dashboardState.StatusRefresh.OutputPath -and
                (Test-Path -LiteralPath $dashboardState.StatusRefresh.OutputPath -PathType Leaf)) {
                Remove-Item -LiteralPath $dashboardState.StatusRefresh.OutputPath -Force -ErrorAction SilentlyContinue
            }
            $dashboardState.StatusRefresh = $null
        }
        $statusTimer.Dispose()
        if ($null -ne $dashboardState.SmokeCancelTimer) {
            $dashboardState.SmokeCancelTimer.Stop()
            $dashboardState.SmokeCancelTimer.Dispose()
            $dashboardState.SmokeCancelTimer = $null
        }
        if ($null -ne $dashboardState.Operation) {
            $dashboardState.Operation.Runner.Dispose()
            $dashboardState.Operation = $null
        }
        if ($null -ne $trayIcon) {
            $trayIcon.Visible = $false
            $trayIcon.Dispose()
        }
        if ($null -ne $trayMenu) { $trayMenu.Dispose() }
    })

    & $setOperationControls
    [void]$form.ShowDialog()
    return [int]$dashboardState.LastExitCode
}

$initialProject = $null
if ($Project) {
    try { $initialProject = Remember-Project -Path $Project }
    catch { $initialProject = $Project }
}

$lastExitCode = Select-SavedProjectAction -InitialProject $initialProject
if ($null -ne $appIcon) { $appIcon.Dispose() }
exit $lastExitCode
