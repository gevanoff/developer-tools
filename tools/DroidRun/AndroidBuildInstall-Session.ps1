[CmdletBinding()]
param(
    [string]$Project,
    [Parameter(DontShow = $true)][switch]$UiSmokeTest,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestOperation,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestOperationSuccess,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestCancellation,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestStatusRefresh,
    [Parameter(DontShow = $true)][switch]$UiSmokeTestInheritedOutput,
    [Parameter(DontShow = $true)][string]$UiSmokeTestApkPath,
    [Parameter(DontShow = $true)][string]$UiSmokeTestPreviewPath,
    [Parameter(DontShow = $true)][string]$UiSmokeTestRefreshOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'WindowsTaskbarIdentity.ps1')
. (Join-Path $PSScriptRoot 'DroidRunTheme.ps1')
. (Join-Path $PSScriptRoot 'DroidRunProjects.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()
$isUiSmokeTest = $UiSmokeTest -or $UiSmokeTestOperation -or $UiSmokeTestOperationSuccess -or
    $UiSmokeTestCancellation -or $UiSmokeTestStatusRefresh -or $UiSmokeTestInheritedOutput -or $UiSmokeTestApkPath
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
$namesPath = Join-Path $stateRoot 'project-names.json'
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
    param([System.Windows.Forms.IWin32Window]$Owner)
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $picker.Description = 'Choose a repository or project folder. DroidRun lists the Android projects it finds inside.'
        $picker.ShowNewFolderButton = $false
        $result = if ($null -ne $Owner) { $picker.ShowDialog($Owner) } else { $picker.ShowDialog() }
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $picker.SelectedPath
    }
    finally { $picker.Dispose() }
}

function Select-ProjectsToAdd {
    # Lists the projects found in Folder and returns the paths the user chose to add.
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [System.Windows.Forms.IWin32Window]$Owner,
        [string[]]$Existing = @()
    )

    $previousCursor = [System.Windows.Forms.Cursor]::Current
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try { $found = Find-DroidRunProjects -Folder $Folder }
    finally { [System.Windows.Forms.Cursor]::Current = $previousCursor }
    $candidates = @($found.Candidates)
    $isExisting = { param($path) @($Existing | Where-Object { $_ -ieq $path }).Count -gt 0 }

    if ($candidates.Count -eq 0) {
        $answer = [System.Windows.Forms.MessageBox]::Show($Owner,
            "No Android projects were found in $($found.Root).`n`nDroidRun looks up to 4 folders deep for gradlew.bat, project.godot, or android-build-install.json. Add this folder anyway? You can set up a custom build for it later in Settings.",
            'No projects found', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { return $found.Root }
        return
    }

    $only = $candidates[0]
    if ($candidates.Count -eq 1 -and $only.Relative -eq '.' -and $only.Recommended -and -not (& $isExisting $only.Path)) {
        return $only.Path  # The chosen folder is the project; nothing to choose.
    }

    $newCount = @($candidates | Where-Object { -not (& $isExisting $_.Path) }).Count
    $intro = if ($only.Outside) {
        'There are no projects beneath this folder, but it is inside this project. Add it instead?'
    } elseif ($newCount -eq 0) {
        "All $($candidates.Count) projects found here are already in DroidRun."
    } else {
        $plural = if ($candidates.Count -eq 1) { '' } else { 's' }
        "Found $($candidates.Count) project$plural. Choose the ones to add. Unchecked ones may not build yet; the reason is shown under each."
    }
    if ($found.Truncated) {
        $intro += ' The search stopped early because this folder is very large; choose a folder closer to the projects to see everything.'
    }

    $dot = "  $([char]0x00B7)  "
    $items = foreach ($candidate in $candidates) {
        $added = & $isExisting $candidate.Path
        $location = if ($candidate.Relative -eq '.') { 'this folder' } else { $candidate.Relative }
        $detail = "$($candidate.Kind)$dot$location"
        if ($added) { $detail += "${dot}already in DroidRun" }
        $note = if ($added) { '' } else { [string]$candidate.Note }
        [DroidRun.PickerItem]::new([string]$candidate.Path, (Split-Path -Leaf $candidate.Path), $detail, $note,
            [bool]($candidate.Recommended -and -not $added), [bool](-not $added))
    }
    $rootName = Split-Path -Leaf $found.Root
    if (-not $rootName) { $rootName = $found.Root }
    $picker = [DroidRun.ProjectPickerDialog]::new("Add projects from $rootName", $found.Root, $intro, [DroidRun.PickerItem[]]@($items))
    try {
        if ($null -ne $appIcon) { $picker.Dialog.Icon = $appIcon }
        $result = if ($null -ne $Owner) { $picker.Dialog.ShowDialog($Owner) } else { $picker.Dialog.ShowDialog() }
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
        # Callers wrap the result in @() so one path stays an array.
        return $picker.ChosenPaths
    }
    finally { $picker.Dialog.Dispose() }
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
        Project = if ($projectPath) { Get-DroidRunProjectName -Path $projectPath -Names $script:reportNames -NamesPath $namesPath } else { '(unknown)' }
        Path = $File.FullName
    }
}

function Show-Reports {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Reports - DroidRun'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($null -ne $appIcon) { $form.Icon = $appIcon }
    $form.StartPosition = if ($null -ne $Owner) {
        [System.Windows.Forms.FormStartPosition]::CenterParent
    } else {
        [System.Windows.Forms.FormStartPosition]::CenterScreen
    }
    $form.ClientSize = New-Object System.Drawing.Size(880, 460)
    $form.MinimumSize = New-Object System.Drawing.Size(640, 400)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    [DroidRun.Theme]::ApplyForm($form)

    $label = [DroidRun.Theme]::NewLabel('Build and install reports', 11, [System.Drawing.FontStyle]::Bold, [DroidRun.Theme]::Text)
    $label.SetBounds(16, 12, 600, 26)
    $form.Controls.Add($label)
    $hint = [DroidRun.Theme]::NewLabel('Newest first. Open a report to read the full Gradle and ADB output.', 9, [System.Drawing.FontStyle]::Regular, [DroidRun.Theme]::Muted)
    $hint.SetBounds(16, 38, 760, 20)
    $hint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($hint)

    $list = New-Object DroidRun.StatusListView
    $list.AccessibleName = 'Reports'
    $list.RowHeight = 30
    [void]$list.AddColumn('Run', 155, [DroidRun.CellKind]::Text)
    [void]$list.AddColumn('Result', 110, [DroidRun.CellKind]::Chip)
    [void]$list.AddColumn('Project', 180, [DroidRun.CellKind]::Text)
    [void]$list.AddColumn('Report file', 400, [DroidRun.CellKind]::Muted)
    $frame = [DroidRun.BorderHost]::new($list)
    $frame.SetBounds(16, 66, 848, 330)
    $frame.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($frame)

    $empty = [DroidRun.Theme]::NewLabel('No reports yet. A report is saved each time Build & Install, Install APK, or a Sync & Run build runs.', 10, [System.Drawing.FontStyle]::Regular, [DroidRun.Theme]::Muted)
    $empty.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $empty.BackColor = [DroidRun.Theme]::Surface
    $empty.Bounds = $frame.Bounds
    $empty.Anchor = $frame.Anchor
    $empty.Visible = $false
    $form.Controls.Add($empty)
    $empty.BringToFront()

    $script:reportNames = Get-DroidRunProjectNames -NamesPath $namesPath
    foreach ($file in @(Get-ChildItem -LiteralPath $logRoot -Filter 'android-build-install-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $summary = Get-LogSummary -File $file
        $item = New-Object System.Windows.Forms.ListViewItem($summary.Time)
        $result = $item.SubItems.Add($summary.Status)
        $resultTone = switch ($summary.Status) { 'Success' { 'ok' } 'Failed' { 'error' } default { 'warn' } }
        $result.Tag = [DroidRun.ChipCell]::new($resultTone, '')
        [void]$item.SubItems.Add($summary.Project)
        [void]$item.SubItems.Add((Split-Path -Leaf $summary.Path))
        $item.Tag = $summary.Path
        $item.ToolTipText = $summary.Path
        [void]$list.Items.Add($item)
    }
    $list.ShowItemToolTips = $true
    $empty.Visible = ($list.Items.Count -eq 0)

    $open = New-DroidRunButton -Text '&Open Report' -Kind Primary
    $open.Size = New-Object System.Drawing.Size(130, 34)
    $open.Location = New-Object System.Drawing.Point(16, 410)
    $open.Enabled = $false
    $open.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($open)

    $folder = New-DroidRunButton -Text 'Open Reports &Folder' -Kind Secondary
    $folder.Size = New-Object System.Drawing.Size(160, 34)
    $folder.Location = New-Object System.Drawing.Point(154, 410)
    $folder.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($folder)

    $close = New-DroidRunButton -Text 'Close' -Kind Secondary
    $close.Size = New-Object System.Drawing.Size(100, 34)
    $close.Location = New-Object System.Drawing.Point(764, 410)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($close)
    $form.CancelButton = $close

    $list.Add_SelectedIndexChanged({ $open.Enabled = ($list.SelectedItems.Count -eq 1) })
    $list.Add_Resize({
        $fixedWidth = 155 + 110 + 180
        $list.Columns[3].Width = [Math]::Max(150, $list.ClientSize.Width - $fixedWidth - 2)
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
    $form.Dispose()
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
    param(
        [System.Windows.Forms.IWin32Window]$Owner,
        [scriptblock]$OnProgress
    )

    $projects = @(Get-SavedProjects)
    if ($projects.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show($Owner, 'Add at least one Android project before scanning the device.', 'Device scan - DroidRun') | Out-Null
        return
    }

    # The scan runs in this process; show that the dashboard is busy rather than frozen.
    if ($OnProgress) { & $OnProgress "Scanning the device for $($projects.Count) project(s)..." }
    $previousCursor = [System.Windows.Forms.Cursor]::Current
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try { $results = @(Get-StatusResults -Projects $projects) }
    catch {
        if ($OnProgress) { & $OnProgress 'Device scan failed.' }
        [System.Windows.Forms.MessageBox]::Show($Owner, $_.Exception.Message, 'Device scan - DroidRun') | Out-Null
        return
    }
    finally { [System.Windows.Forms.Cursor]::Current = $previousCursor }
    if ($OnProgress) { & $OnProgress "Device scanned at $(Get-Date -Format 'HH:mm:ss')." }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Device scan - DroidRun'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($null -ne $appIcon) { $form.Icon = $appIcon }
    $form.StartPosition = if ($null -ne $Owner) {
        [System.Windows.Forms.FormStartPosition]::CenterParent
    } else {
        [System.Windows.Forms.FormStartPosition]::CenterScreen
    }
    $form.ClientSize = New-Object System.Drawing.Size(1120, 520)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 440)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    [DroidRun.Theme]::ApplyForm($form)

    $title = [DroidRun.Theme]::NewLabel('Device scan', 11, [System.Drawing.FontStyle]::Bold, [DroidRun.Theme]::Text)
    $title.SetBounds(16, 12, 400, 26)
    $form.Controls.Add($title)
    $hint = [DroidRun.Theme]::NewLabel('Read-only: nothing was built or installed. Each project uses its remembered device when set. Same and Different are exact SHA-256 comparisons.', 9, [System.Drawing.FontStyle]::Regular, [DroidRun.Theme]::Muted)
    $hint.SetBounds(16, 38, 1088, 20)
    $hint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($hint)

    $list = New-Object DroidRun.StatusListView
    $list.AccessibleName = 'Device scan results'
    $list.RowHeight = 44
    $list.ShowItemToolTips = $true
    [void]$list.AddColumn('Project', 220, [DroidRun.CellKind]::Project)
    [void]$list.AddColumn('Device', 190, [DroidRun.CellKind]::Text)
    [void]$list.AddColumn('Status', 150, [DroidRun.CellKind]::Chip)
    [void]$list.AddColumn('Detail', 500, [DroidRun.CellKind]::Muted)
    $frame = [DroidRun.BorderHost]::new($list)
    $frame.SetBounds(16, 66, 1088, 384)
    $frame.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Bottom -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($frame)
    $list.Add_Resize({
        $fixedWidth = 220 + 190 + 150
        $list.Columns[3].Width = [Math]::Max(180, $list.ClientSize.Width - $fixedWidth - 2)
    })

    $scanNames = Get-DroidRunProjectNames -NamesPath $namesPath
    foreach ($result in $results) {
        $item = New-Object System.Windows.Forms.ListViewItem((Get-DroidRunProjectName -Path ([string]$result.ProjectPath) -Names $scanNames))
        $item.Tag = [string]$result.ProjectPath
        [void]$item.SubItems.Add([string]$result.Device)
        $status = $item.SubItems.Add([string]$result.DeviceStatus)
        $status.Tag = New-DroidRunChipCell -Status ([string]$result.DeviceStatus)
        [void]$item.SubItems.Add([string]$result.DeviceDetail)
        $item.ToolTipText = [string]$result.DeviceDetail
        [void]$list.Items.Add($item)
    }

    $close = New-DroidRunButton -Text 'Close' -Kind Secondary
    $close.Size = New-Object System.Drawing.Size(100, 34)
    $close.Location = New-Object System.Drawing.Point(1004, 468)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($close)
    $form.CancelButton = $close
    if ($null -ne $Owner) { [void]$form.ShowDialog($Owner) }
    else { [void]$form.ShowDialog() }
    $form.Dispose()
}

function Invoke-ProjectSettings {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $settingsEditor -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Settings editor was not found:`n$settingsEditor", 'Android Project Settings') | Out-Null
        return
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $settingsEditor -Project $ProjectPath -PreferencesPath $preferencesPath `
        -DisplayName (Get-DroidRunProjectName -Path $ProjectPath -NamesPath $namesPath)
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

    $logoImage = $null
    $logoPath = Join-Path $PSScriptRoot 'assets\droidrun-icon.png'
    if (Test-Path -LiteralPath $logoPath -PathType Leaf) {
        try { $logoImage = [System.Drawing.Image]::FromFile($logoPath) } catch { $logoImage = $null }
    }

    # DroidRunUi.cs builds, themes, and lays out the controls; this script wires behaviour.
    $view = [DroidRun.DashboardView]::new($form, $logoImage)
    $statusTimestamp = $view.StatusTimestamp
    $list = $view.Projects
    $operationStatus = $view.OperationStatus
    $copyOutput = $view.CopyOutput
    $cancelOperation = $view.CancelOperation
    $operationOutput = $view.OperationOutput
    $add = $view.Add
    $remove = $view.Remove
    $reports = $view.Reports
    $scan = $view.Scan
    $refresh = $view.Refresh
    $gitPull = $view.GitPull
    $installApk = $view.InstallApk
    $settings = $view.Settings
    $rename = $view.Rename
    $sync = $view.Sync
    $build = $view.Build
    $copyOutput.Enabled = $false
    $cancelOperation.Enabled = $false
    $form.AcceptButton = $sync

    $toolTips = New-Object System.Windows.Forms.ToolTip
    $toolTips.SetToolTip($sync, 'Pull, build, and install only what is needed, then launch (Enter or double-click a project).')
    $toolTips.SetToolTip($build, 'Always build, then install and launch according to project settings.')
    $toolTips.SetToolTip($gitPull, 'git pull --ff-only. Stops on local changes or a diverged branch.')
    $toolTips.SetToolTip($installApk, 'Install an existing APK file without building or changing Git.')
    $toolTips.SetToolTip($remove, 'Forget this project. The folder and its settings are not changed.')
    $toolTips.SetToolTip($rename, 'Change the name shown in DroidRun (F2). The folder is not renamed.')
    $toolTips.SetToolTip($refresh, 'Fetch Git remotes and recheck builds and the device for the selected projects, or every project when none is selected. Esc clears the selection.')

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

    $layoutDashboard = { $view.LayoutDashboard() }
    & $layoutDashboard

    $selectedPath = {
        if ($list.SelectedItems.Count -ne 1) { return $null }
        return [string]$list.SelectedItems[0].Tag
    }

    # Selected project paths in list order (several can be selected to refresh just those).
    $selectedPaths = {
        # Callers wrap the result in @() so one path stays an array.
        foreach ($item in $list.Items) { if ($item.Selected) { [string]$item.Tag } }
    }

    $refreshSummary = {
        $path = & $selectedPath
        if (-not $path) {
            $chosen = @(& $selectedPaths)
            if ($chosen.Count -gt 1) {
                $names = Get-DroidRunProjectNames -NamesPath $namesPath
                $nameList = @($chosen | ForEach-Object { Get-DroidRunProjectName -Path $_ -Names $names }) -join ', '
                $view.SetDetails("$($chosen.Count) projects selected", $nameList,
                    'Refresh checks only these projects. Select one project to build, install, rename, or change its settings.', '', '', '')
                return
            }
            $hintText = if ($view.Projects.Items.Count -eq 0) {
                'Add a project to build, install, and run it.'
            } else {
                'Select a project to build and run it. With none selected, Refresh checks every project.'
            }
            $view.SetDetails('No project selected', '', $hintText, '', '', '')
            return
        }
        $pref = Get-ProjectPreference -ProjectPath $path
        $item = $list.SelectedItems[0]
        $preview = Get-DroidRunSyncPreview -GitStatus $item.SubItems[1].Text -BuildStatus $item.SubItems[2].Text `
            -DeviceStatus $item.SubItems[3].Text -AutoLaunch ([bool]$pref.autoLaunch)
        $marker = if ($preview.Ready) { [char]0x25B6 } else { '!' }
        $planTone = if ($preview.Ready) { 'ok' } elseif ($preview.Headline -like 'Status*') { '' } else { 'warn' }
        $dot = "  $([char]0x00B7)  "
        $apkText = if ($pref.preferredApk) { $pref.preferredApk } else { 'automatic' }
        $javaText = if ($pref.javaHome) { $pref.javaHome } else { 'from environment' }
        $deviceText = if ($pref.deviceSerial) { $pref.deviceSerial } else { 'automatic' }
        $launchText = if ($pref.autoLaunch) { 'on' } else { 'off' }
        $settingsText = (@("Task $($pref.gradleTask)", "APK $apkText", "JDK $javaText", "Device $deviceText", "Auto-launch $launchText") -join $dot)
        $view.SetDetails((Get-DroidRunProjectName -Path $path -NamesPath $namesPath), $path, "$marker  $($preview.Headline)", $planTone, $preview.Fix, $settingsText)
    }

    $dashboardState = [pscustomobject]@{
        CancelRequested = $false
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
            for ($index = 1; $index -lt 5; $index++) { [void]$item.SubItems.Add('') }
            $item.Tag = [string]$Result.ProjectPath
            [void]$list.Items.Add($item)
        }

        while ($item.SubItems.Count -lt 5) { [void]$item.SubItems.Add('') }
        $item.Text = Get-DroidRunProjectName -Path ([string]$Result.ProjectPath) -NamesPath $namesPath
        $gitDisplay = if ($Result.GitBranch) { "$($Result.GitBranch) | $($Result.GitStatus)" } else { [string]$Result.GitStatus }
        # Each status cell is drawn as a chip; the branch is shown before the Git chip.
        $item.SubItems[1].Text = [string]$Result.GitStatus
        $item.SubItems[1].Tag = New-DroidRunChipCell -Status ([string]$Result.GitStatus) -Prefix ([string]$Result.GitBranch)
        $item.SubItems[2].Text = [string]$Result.BuildStatus
        $item.SubItems[2].Tag = New-DroidRunChipCell -Status ([string]$Result.BuildStatus)
        $item.SubItems[3].Text = [string]$Result.DeviceStatus
        $item.SubItems[3].Tag = New-DroidRunChipCell -Status ([string]$Result.DeviceStatus)
        $item.SubItems[4].Text = $CheckedText
        $item.ToolTipText = "Git: $gitDisplay`n$($Result.GitDetail)`nBuild: $($Result.BuildStatus). $($Result.BuildDetail)`nDevice: $($Result.DeviceStatus). $($Result.DeviceDetail)"
        $list.Invalidate()
        if ($item.Selected) { & $refreshSummary }
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
        } elseif ($total -lt @(Get-SavedProjects).Count) {
            $scope = if ($total -eq 1) { '1 project' } else { "$total projects" }
            "Checked ${scope}: $(Get-Date -Format 'HH:mm:ss') ($completed/$total)"
        } else {
            "Last checked: $(Get-Date -Format 'HH:mm:ss') ($completed/$total)"
        }
        & $setOperationControls
        & $refreshSummary

        if ($UiSmokeTestStatusRefresh) {
            Write-Host "UI status smoke result: $completed/$total"
            foreach ($item in $list.Items) {
                Write-Host "UI status row: $($item.Text) | $($item.SubItems[1].Text) | $($item.SubItems[2].Text) | $($item.SubItems[3].Text) | $($item.SubItems[4].Text)"
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
        $statusTimestamp.Text = "Checking $position/$($refreshState.Projects.Count): $(Get-DroidRunProjectName -Path $projectPath -NamesPath $namesPath)"
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
        # Rebuilds the list from the saved projects and checks Only (or every project when
        # Only is empty). Rows that are not checked keep their previous result.
        param([bool]$FetchRemote = $true, [string[]]$Only = @())

        if ($null -ne $dashboardState.StatusRefresh -or $null -ne $dashboardState.Operation) { return }
        $projects = @(Get-SavedProjects)
        $targets = if (@($Only).Count -gt 0) {
            @($projects | Where-Object { $project = $_; @($Only | Where-Object { $_ -ieq $project }).Count -gt 0 })
        } else { $projects }
        $names = Get-DroidRunProjectNames -NamesPath $namesPath
        $selectedBefore = @(& $selectedPaths)
        $cached = @{}
        foreach ($existing in $list.Items) {
            $values = @()
            $tags = @()
            foreach ($subItem in $existing.SubItems) {
                $values += [string]$subItem.Text
                $tags += , $subItem.Tag
            }
            $cached[[string]$existing.Tag] = [pscustomobject]@{
                Values = $values
                Tags = $tags
                ToolTipText = $existing.ToolTipText
            }
        }

        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            foreach ($projectPath in $projects) {
                $entry = $cached[[string]$projectPath]
                $isTarget = @($targets | Where-Object { $_ -ieq $projectPath }).Count -gt 0
                $displayName = Get-DroidRunProjectName -Path $projectPath -Names $names
                if ($null -ne $entry -and $entry.Values.Count -ge 4) {
                    # Keep the previous result visible until this project is rechecked.
                    $item = New-Object System.Windows.Forms.ListViewItem($displayName)
                    for ($index = 1; $index -lt 4; $index++) {
                        $subItem = $item.SubItems.Add($entry.Values[$index])
                        $subItem.Tag = $entry.Tags[$index]
                    }
                    $checkedText = if ($isTarget) { 'Queued' } elseif ($entry.Values.Count -ge 5) { $entry.Values[4] } else { 'Not checked' }
                    [void]$item.SubItems.Add($checkedText)
                    $item.ToolTipText = $entry.ToolTipText
                }
                else {
                    $item = New-Object System.Windows.Forms.ListViewItem($displayName)
                    $placeholder = if ($isTarget) { 'Checking...' } else { 'Unknown' }
                    for ($index = 1; $index -lt 4; $index++) {
                        $subItem = $item.SubItems.Add($placeholder)
                        $subItem.Tag = New-DroidRunChipCell -Status $placeholder
                    }
                    [void]$item.SubItems.Add($(if ($isTarget) { 'Queued' } else { 'Not checked' }))
                }
                $item.Tag = $projectPath
                [void]$list.Items.Add($item)
                if (@($selectedBefore | Where-Object { $_ -ieq $projectPath }).Count -gt 0) { $item.Selected = $true }
            }
        }
        finally { $list.EndUpdate() }

        # Nothing is selected by default, so Refresh All means every project.
        $view.ShowEmpty($projects.Count -eq 0)
        $view.ProjectsTitle.Text = if ($projects.Count -gt 0) { "Projects ($($projects.Count))" } else { 'Projects' }
        & $refreshSummary
        if ($projects.Count -eq 0 -or $targets.Count -eq 0) {
            if ($projects.Count -eq 0) { $statusTimestamp.Text = 'No saved projects.' }
            & $refreshSummary
            & $setOperationControls
            return
        }

        $dashboardState.StatusRefresh = [pscustomobject]@{
            Projects = $targets
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
        $refresh.Text = if ($statusBusy) { '&Cancel Refresh' } else { Get-DroidRunRefreshLabel -SelectedCount $list.SelectedItems.Count }
        $gitPull.Enabled = $selected -and -not $anyBusy
        $settings.Enabled = $selected -and -not $anyBusy
        $rename.Enabled = $selected -and -not $anyBusy
        $sync.Enabled = $selected -and -not $anyBusy
        $build.Enabled = $selected -and -not $anyBusy
        $installApk.Enabled = $selected -and -not $anyBusy
        $cancelOperation.Enabled = $busy -and -not $dashboardState.CancelRequested
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

    $formatElapsed = {
        param([TimeSpan]$Span)
        if ($Span.TotalSeconds -lt 60) { return "$([Math]::Round($Span.TotalSeconds, 1)) seconds" }
        return ('{0}:{1:00}' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds)
    }

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
        $elapsedText = & $formatElapsed $elapsed
        $dashboardState.LastExitCode = $exitCode
        $wasCancelled = $operation.Runner.CancellationRequested
        if ($wasCancelled) {
            $resultMessage = "$($operation.DisplayName) cancelled after $elapsedText."
            $view.SetOperationState('cancelled', "$($operation.DisplayName) cancelled", "after $elapsedText. The process tree was stopped; the output shows which steps finished.")
            & $appendOperationOutput @('', "Cancelled. Exit code: $exitCode")
        }
        elseif ($exitCode -eq 0) {
            $resultMessage = "$($operation.DisplayName) completed in $elapsedText."
            $view.SetOperationState('success', "$($operation.DisplayName) completed", "in $elapsedText.")
            & $appendOperationOutput @('', "Completed successfully. Exit code: $exitCode")
        }
        else {
            $resultMessage = "$($operation.DisplayName) failed with exit code $exitCode after $elapsedText."
            $failureHint = if ($operation.Action -eq 'GitPull') {
                'Review the Git output above before retrying.'
            } else {
                'Use Reports to open the complete build/install log.'
            }
            $view.SetOperationState('failed', "$($operation.DisplayName) failed", "Exit code $exitCode after $elapsedText. $failureHint")
            & $appendOperationOutput @('', "Failed. Exit code: $exitCode", $failureHint)
        }
        $dashboardState.CancelRequested = $false

        $operation.Runner.Dispose()
        $dashboardState.Operation = $null
        $operationTimer.Stop()
        $form.Text = 'DroidRun'
        if ($null -ne $trayIcon -and -not $isUiSmokeTest) {
            $trayIcon.Text = 'DroidRun'
            $trayIcon.BalloonTipTitle = 'DroidRun'
            $trayIcon.BalloonTipText = $resultMessage
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
        if ($UiSmokeTestOperation -or $UiSmokeTestOperationSuccess -or $UiSmokeTestCancellation -or $UiSmokeTestInheritedOutput -or $UiSmokeTestApkPath) {
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

        if (-not $operation.Runner.IsRunning) { & $completeOperation; return }
        if (-not $dashboardState.CancelRequested) {
            $operationStatus.Text = "Running for $(& $formatElapsed ((Get-Date) - $operation.StartedAt))"
        }
    })

    $startOperation = {
        param(
            [ValidateSet('Sync', 'Build', 'InstallApk', 'GitPull', 'SmokeSuccess', 'SmokeCancel', 'SmokeInheritedOutput')][string]$Action,
            [string]$ProjectPath,
            [string]$SelectedApk
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
        } elseif ($Action -eq 'InstallApk') {
            'Install APK'
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
            $view.SetOperationState('failed', "$displayName could not start", 'Its helper script is missing from this checkout.')
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
        elseif ($Action -eq 'Build' -or $Action -eq 'InstallApk') {
            $pref = Get-ProjectPreference -ProjectPath $ProjectPath
            $arguments += @('-GradleTask', $pref.gradleTask, '-SuppressSuccessDialog', '-NoUi')
            if ($Action -eq 'InstallApk') { $arguments += @('-ApkPath', $SelectedApk) }
            elseif ($pref.preferredApk) { $arguments += @('-PreferredApk', $pref.preferredApk) }
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
        $dashboardState.CancelRequested = $false
        $view.SetOperationState('running', $displayName, 'Starting...')
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
            $operationStatus.Text = 'Running for 0.0 seconds'
            $form.Text = "DroidRun - $displayName"
            if ($null -ne $trayIcon) { $trayIcon.Text = "DroidRun - $displayName" }
            $operationTimer.Start()
        }
        catch {
            $processRunner.Dispose()
            $dashboardState.Operation = $null
            $dashboardState.LastExitCode = 1
            $view.SetOperationState('failed', "$displayName could not start", $_.Exception.Message)
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
    $installApk.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        try {
            $picker.Title = 'Choose APK to install'
            $picker.Filter = 'Android packages (*.apk)|*.apk'
            $picker.CheckFileExists = $true
            $picker.Multiselect = $false
            $picker.InitialDirectory = $path
            if ($picker.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                & $startOperation 'InstallApk' $path $picker.FileName
            }
        } finally { $picker.Dispose() }
    })
    $list.Add_DoubleClick({ if ($list.SelectedItems.Count -eq 1) { & $startOperation 'Sync' } })

    $copyOutput.Add_Click({
        if ($operationOutput.TextLength -gt 0) {
            try { [System.Windows.Forms.Clipboard]::SetText($operationOutput.Text) } catch { }
        }
    })

    $cancelOperation.Add_Click({
        if ($null -eq $dashboardState.Operation) { return }
        $cancelOperation.Enabled = $false
        $dashboardState.CancelRequested = $true
        $view.SetOperationState('cancelling', "Cancelling $($dashboardState.Operation.DisplayName)", 'Stopping the process tree...')
        $dashboardState.Operation.Runner.Cancel()
    })

    $add.Add_Click({
        $folder = Browse-ForProject -Owner $form
        if (-not $folder) { return }
        try { $chosen = @(Select-ProjectsToAdd -Folder $folder -Owner $form -Existing @(Get-SavedProjects)) }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, "Could not search $folder for projects: $($_.Exception.Message)", 'Add projects')
            return
        }
        if ($chosen.Count -eq 0) { return }
        $added = New-Object System.Collections.Generic.List[string]
        # Remember-Project puts each path first, so add in reverse to keep the listed order.
        for ($index = $chosen.Count - 1; $index -ge 0; $index--) {
            try { $added.Insert(0, (Remember-Project -Path $chosen[$index])) } catch { }
        }
        if ($added.Count -eq 0) { return }
        $list.SelectedItems.Clear()
        & $refreshRows $true $added.ToArray()
        foreach ($item in $list.Items) {
            if (@($added | Where-Object { $_ -ieq [string]$item.Tag }).Count -gt 0) { $item.Selected = $true; $item.EnsureVisible() }
        }
    })

    $renameProject = {
        $path = & $selectedPath
        if (-not $path -or $null -ne $dashboardState.Operation -or $null -ne $dashboardState.StatusRefresh) { return }
        $folderName = Split-Path -Leaf $path
        $prompt = [DroidRun.TextPromptDialog]::new('Rename project',
            "Name shown in DroidRun for $path.`nLeave it empty to use the folder name ($folderName). The folder itself is not renamed.",
            (Get-DroidRunProjectName -Path $path -NamesPath $namesPath))
        try {
            if ($null -ne $appIcon) { $prompt.Dialog.Icon = $appIcon }
            if ($prompt.Dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $shown = Set-DroidRunProjectName -Path $path -Name $prompt.Input.Text -NamesPath $namesPath
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, "The name could not be saved: $($_.Exception.Message)", 'Rename project')
            return
        }
        finally { $prompt.Dialog.Dispose() }
        foreach ($item in $list.Items) {
            if (([string]$item.Tag) -ieq $path) { $item.Text = $shown }
        }
        $list.Invalidate()
        & $refreshSummary
    }
    $rename.Add_Click($renameProject)

    $list.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F2) {
            & $renameProject
            $eventArgs.Handled = $true
        }
        elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            # Clear the selection so Refresh checks every project.
            $list.SelectedItems.Clear()
            $eventArgs.Handled = $true
        }
        elseif ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::A) {
            foreach ($item in $list.Items) { $item.Selected = $true }
            $eventArgs.Handled = $true
        }
    })

    $remove.Add_Click({
        $path = & $selectedPath
        if (-not $path) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Remove $(Get-DroidRunProjectName -Path $path -NamesPath $namesPath) from DroidRun?`n`nThe folder, its files, and its saved settings are not changed. You can add it again later.",
            'Remove project',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $remaining = @(Get-SavedProjects | Where-Object { $_ -ine $path })
        Save-SavedProjects -Projects $remaining
        & $refreshRows $false
    })

    $reports.Add_Click({ Show-Reports -Owner $form })
    $scan.Add_Click({ Show-DeviceScan -Owner $form -OnProgress { param($text) $statusTimestamp.Text = $text; $statusTimestamp.Refresh() } })
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
        # The selected projects, or every project when none is selected.
        $targets = @(Get-DroidRunRefreshTargets -Projects @(Get-SavedProjects) -Selected @(& $selectedPaths))
        & $refreshRows $true $targets
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

    # Smoke-test only: fill the dashboard with representative rows and capture it.
    $loadPreviewFixture = {
        $fixtures = @(
            @{ Name = 'chatturanga'; Branch = 'main'; Git = 'Behind 2'; Build = 'Stale'; Device = 'Different' },
            @{ Name = 'prism-break'; Branch = 'feature/camera-flip-and-a-very-long-branch-name'; Git = 'Dirty'; Build = 'Fresh'; Device = 'Same' },
            @{ Name = 'codex-fuel'; Branch = 'ui/glow-up'; Git = 'Current'; Build = 'Fresh'; Device = 'Same' },
            @{ Name = 'embrient-mic101-companion'; Branch = 'main'; Git = 'Diverged 3/1'; Build = 'Ambiguous'; Device = 'Unknown' },
            @{ Name = 'kiosk-launcher'; Branch = 'release/1.4'; Git = 'Current'; Build = 'No APK'; Device = 'Choose device' }
        )
        foreach ($fixture in $fixtures) {
            & $setStatusRow -CheckedText '14:02:11' -Result ([pscustomobject]@{
                ProjectPath = "C:\src with spaces\$($fixture.Name)"; Project = $fixture.Name; GitBranch = $fixture.Branch
                GitStatus = $fixture.Git; GitDetail = ''; BuildStatus = $fixture.Build; BuildDetail = ''
                DeviceStatus = $fixture.Device; DeviceDetail = ''; Device = ''
            })
        }
        $view.ProjectsTitle.Text = "Projects ($($fixtures.Count))"
        $view.ShowEmpty($false)
        $statusTimestamp.Text = 'Last checked: 14:02:11 (5/5)'
        $list.Items[0].Selected = $true
        & $refreshSummary
        & $appendOperationOutput @('Sync & Run', '==========', 'Git:    Behind 2', 'Build:  Stale', 'Device: Different', '', 'Completed successfully. Exit code: 0')
        $view.SetOperationState('success', 'Sync & Run completed', 'in 41.2 seconds.')
        foreach ($button in @($sync, $build, $gitPull, $installApk, $rename, $settings, $remove)) { $button.Enabled = $true }
    }

    $savePreview = {
        param([string]$Label)
        $target = $UiSmokeTestPreviewPath -replace '\.png$', "-$Label.png"
        $form.Activate()
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
        $origin = $form.PointToScreen([System.Drawing.Point]::Empty)
        $bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try { $graphics.CopyFromScreen($origin, [System.Drawing.Point]::Empty, $form.ClientSize) }
            catch { $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.ClientSize.Width, $form.ClientSize.Height))) }
            finally { $graphics.Dispose() }
            $bitmap.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
            Write-Host "UI preview saved: $target"
        }
        finally { $bitmap.Dispose() }
    }

    $form.Add_Shown({
        if ($UiSmokeTest -and -not $UiSmokeTestOperation -and -not $UiSmokeTestOperationSuccess -and
            -not $UiSmokeTestCancellation -and -not $UiSmokeTestStatusRefresh -and -not $UiSmokeTestInheritedOutput) {
            if ($taskbarIdentityAvailable -and -not $taskbarIdentityState.Applied) {
                throw "Taskbar identity could not be applied: $($taskbarIdentityState.Error)"
            }
            Write-Host "UI taskbar identity: $appUserModelId"
            & $loadPreviewFixture

            # Refresh scope follows the selection: none selected means every project.
            $list.SelectedItems.Clear()
            [System.Windows.Forms.Application]::DoEvents()
            if ($refresh.Text -ne 'Re&fresh All') { throw "Refresh label with no selection was '$($refresh.Text)'." }
            $list.Items[1].Selected = $true
            $list.Items[3].Selected = $true
            [System.Windows.Forms.Application]::DoEvents()
            if ($refresh.Text -ne 'Re&fresh 2 Selected') { throw "Refresh label with two selected was '$($refresh.Text)'." }
            if ($sync.Enabled -or $rename.Enabled) { throw 'Single-project actions stayed enabled with two projects selected.' }
            $targets = @(Get-DroidRunRefreshTargets -Projects @($list.Items | ForEach-Object { [string]$_.Tag }) -Selected @(& $selectedPaths))
            if ($targets.Count -ne 2 -or $targets[0] -ne [string]$list.Items[1].Tag) { throw 'Refresh targets did not follow the selection.' }
            $list.SelectedItems.Clear()
            $list.Items[0].Selected = $true
            [System.Windows.Forms.Application]::DoEvents()
            if ($refresh.Text -ne 'Re&fresh Selected' -or -not $rename.Enabled) { throw 'One selected project did not enable Rename and Refresh Selected.' }
            Write-Host 'UI refresh scope: All / Selected / 2 Selected'

            # The Add Projects picker and the Rename prompt build and lay out without overlap.
            $pickerItems = [DroidRun.PickerItem[]]@(
                [DroidRun.PickerItem]::new('C:\repo\phone', 'phone', 'Gradle  -  phone', '', $true, $true),
                [DroidRun.PickerItem]::new('C:\repo\server', 'server', 'Gradle  -  server', 'No Android app module found (no AndroidManifest.xml).', $false, $true),
                [DroidRun.PickerItem]::new('C:\repo\old', 'old', 'Gradle  -  old  -  already in DroidRun', '', $false, $false)
            )
            $picker = [DroidRun.ProjectPickerDialog]::new('Add projects from repo', 'C:\repo', 'Found 3 projects.', $pickerItems)
            try {
                $picker.Dialog.Show($form)
                [System.Windows.Forms.Application]::DoEvents()
                if ((@($picker.ChosenPaths) -join '|') -ne 'C:\repo\phone') { throw "Picker preselection was '$(@($picker.ChosenPaths) -join '|')'." }
                if ($picker.Add.Text -ne '&Add Project') { throw "Picker button read '$($picker.Add.Text)'." }
                $picker.SelectAll.PerformClick()
                if (@($picker.ChosenPaths).Count -ne 2) { throw 'Select all included a project that is already added.' }
                foreach ($button in @($picker.SelectAll, $picker.Clear, $picker.Cancel, $picker.Add)) {
                    if (-not $picker.Dialog.ClientRectangle.Contains($button.Bounds)) { throw "Picker button $($button.Text) is clipped." }
                }
                if ($picker.Cancel.Bounds.IntersectsWith($picker.Add.Bounds)) { throw 'Picker buttons overlap.' }
            }
            finally { $picker.Dialog.Dispose() }
            $prompt = [DroidRun.TextPromptDialog]::new('Rename project', 'Name shown in DroidRun.', 'Chess')
            try {
                $prompt.Dialog.Show($form)
                [System.Windows.Forms.Application]::DoEvents()
                if (-not $prompt.Dialog.ClientRectangle.Contains($prompt.Ok.Bounds) -or $prompt.Input.Text -ne 'Chess') { throw 'Rename prompt layout failed.' }
            }
            finally { $prompt.Dialog.Dispose() }
            Write-Host 'UI add-projects picker and rename prompt: built and laid out'
            foreach ($size in @(@(900, 680), @(1180, 760), @(1600, 900))) {
                $form.ClientSize = New-Object System.Drawing.Size($size[0], $size[1])
                & $layoutDashboard
                [System.Windows.Forms.Application]::DoEvents()
                # Every action button must sit fully inside its card and not overlap another.
                $buttons = @($sync, $build, $gitPull, $installApk, $rename, $settings, $remove, $refresh, $scan, $reports,
                    $add, $copyOutput)
                foreach ($button in $buttons) {
                    if (-not $button.Parent.ClientRectangle.Contains($button.Bounds)) {
                        throw "$($button.Text) is clipped at $($size[0])x$($size[1])."
                    }
                    foreach ($other in $buttons) {
                        if ($other -ne $button -and $other.Parent -eq $button.Parent -and $other.Bounds.IntersectsWith($button.Bounds)) {
                            throw "$($button.Text) overlaps $($other.Text) at $($size[0])x$($size[1])."
                        }
                    }
                }
                foreach ($card in @($view.Details, $view.Operation, $view.ProjectsFrame)) {
                    if (-not $form.ClientRectangle.Contains($card.Bounds)) { throw "A dashboard card is clipped at $($size[0])x$($size[1])." }
                }
                if ($view.Details.Bounds.IntersectsWith($view.Operation.Bounds) -or $view.ProjectsFrame.Bounds.IntersectsWith($view.Details.Bounds)) {
                    throw "Dashboard cards overlap at $($size[0])x$($size[1])."
                }
                if ($UiSmokeTestPreviewPath) { & $savePreview "$($size[0])x$($size[1])" }
            }
            Write-Host 'UI Install APK button: visible and unobstructed'
            Write-Host 'UI layout: buttons and cards fit at 900x680, 1180x760, and 1600x900'
            $form.Close()
            return
        }
        if ($UiSmokeTestApkPath) {
            & $startOperation 'InstallApk' $InitialProject $UiSmokeTestApkPath
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
        if ($UiSmokeTestRefreshOnly) { & $refreshRows $true @($UiSmokeTestRefreshOnly) }
        else { & $refreshRows $true }

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
