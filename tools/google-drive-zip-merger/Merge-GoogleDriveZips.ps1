[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination,
    [Parameter(DontShow = $true)][switch]$UiSmokeTest
)

# One window: choose the folder of Google Drive ZIP files and a destination, check
# what will happen, merge with progress, then optionally delete the original ZIPs.
# Exit code: 0 after a completed merge or when closed without merging; 1 when a
# merge failed or was stopped.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'ZipMergeEngine.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()

$appTitle = 'Google Drive ZIP Merger'
$warnColor = [System.Drawing.Color]::FromArgb(138, 80, 0)      # 6.1:1 on the window colour
$errorColor = [System.Drawing.Color]::FromArgb(176, 0, 32)     # 6.9:1
$okColor = [System.Drawing.Color]::FromArgb(0, 110, 50)        # 6.0:1
if ([System.Windows.Forms.SystemInformation]::HighContrast) {
    $warnColor = $errorColor = $okColor = [System.Drawing.SystemColors]::WindowText
}

$session = [pscustomobject]@{
    SourceInfo = $null
    Plan = $null
    State = $null
    PowerShell = $null
    Handle = $null
    Phase = 'Setup'      # Setup, Running, Completed, Stopped, Failed
    ExitCode = 0
    Deleted = $false
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $appTitle
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object System.Drawing.Size(720, 540)
$form.MinimumSize = New-Object System.Drawing.Size(600, 520)
$form.BackColor = [System.Drawing.SystemColors]::Window
$form.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 16)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 3
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
$form.Controls.Add($layout)

function Add-Row {
    param([System.Windows.Forms.Control]$Control, [int]$Column = 0, [int]$Span = 3, [string]$Size = 'AutoSize', [float]$Percent = 0)
    $row = $layout.RowCount
    $layout.RowCount++
    $style = if ($Size -eq 'Percent') { New-Object System.Windows.Forms.RowStyle('Percent', $Percent) } else { New-Object System.Windows.Forms.RowStyle('AutoSize') }
    [void]$layout.RowStyles.Add($style)
    $layout.Controls.Add($Control, $Column, $row)
    $layout.SetColumnSpan($Control, $Span)
    return $row
}

function New-Text {
    param([string]$Text, [float]$Size = 9, [System.Drawing.FontStyle]$Style = 'Regular')
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(660, 0)
    $label.UseMnemonic = $false
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
    $label.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    return $label
}

$title = New-Text $appTitle 14 'Bold'
[void](Add-Row $title)
$subtitle = New-Text 'Google Drive splits large folder downloads into several ZIP files. This extracts all of them into one folder, keeping their folder structure.'
$subtitle.ForeColor = [System.Drawing.SystemColors]::GrayText
$subtitle.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
[void](Add-Row $subtitle)

function Add-FolderRow {
    param([string]$Label, [string]$Placeholder)
    $caption = New-Text $Label 9 'Bold'
    $caption.Anchor = 'Left'
    $caption.Margin = New-Object System.Windows.Forms.Padding(0, 6, 12, 6)
    $row = Add-Row $caption 0 1
    $box = New-Object System.Windows.Forms.TextBox
    $box.Dock = 'Fill'
    $box.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
    $box.AccessibleName = $Label
    $layout.Controls.Add($box, 1, $row)
    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse...'
    $browse.AutoSize = $true
    $browse.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    $layout.Controls.Add($browse, 2, $row)
    $note = New-Text $Placeholder
    $note.ForeColor = [System.Drawing.SystemColors]::GrayText
    $note.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    [void](Add-Row $note 1 2)
    return [pscustomobject]@{ Box = $box; Browse = $browse; Note = $note }
}

$sourceRow = Add-FolderRow '1. ZIP folder' 'Choose the folder that contains the downloaded ZIP files.'
$destinationRow = Add-FolderRow '2. Destination' 'Choose where the merged files should go. It can be a new or an existing folder.'

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Dock = 'Fill'
$progressBar.Height = 18
$progressBar.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
$progressBar.Visible = $false
[void](Add-Row $progressBar)
$progressText = New-Text ''
$progressText.Visible = $false
[void](Add-Row $progressText)

$resultText = New-Text '' 10 'Bold'
$resultText.Visible = $false
$resultText.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
[void](Add-Row $resultText)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.Dock = 'Fill'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.BackColor = [System.Drawing.SystemColors]::Window
$log.AccessibleName = 'Merge log'
$log.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 8)
[void](Add-Row $log 0 3 'Percent' 100)

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.FlowDirection = 'RightToLeft'
$buttons.Dock = 'Fill'
$buttons.AutoSize = $true
$buttons.WrapContents = $false
$buttons.Margin = New-Object System.Windows.Forms.Padding(0)
[void](Add-Row $buttons)

function New-ActionButton {
    param([string]$Text)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.AutoSize = $true
    $button.MinimumSize = New-Object System.Drawing.Size(96, 32)
    $button.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    $button.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    return $button
}
$close = New-ActionButton 'Close'
$merge = New-ActionButton '&Merge'
$merge.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$stop = New-ActionButton '&Stop'
$deleteZips = New-ActionButton '&Delete Original ZIPs...'
$openDestination = New-ActionButton '&Open Destination'
$buttons.Controls.AddRange(@($close, $merge, $stop, $openDestination, $deleteZips))
$form.AcceptButton = $merge
$form.CancelButton = $close

$setNote = {
    param($Row, [string]$Text, [string]$Kind)
    $Row.Note.Text = $Text
    $Row.Note.ForeColor = switch ($Kind) {
        'error' { $errorColor }
        'warn' { $warnColor }
        'ok' { $okColor }
        default { [System.Drawing.SystemColors]::GrayText }
    }
}

$updateControls = {
    $phase = $session.Phase
    $setup = $phase -eq 'Setup'
    foreach ($control in @($sourceRow.Box, $sourceRow.Browse, $destinationRow.Box, $destinationRow.Browse)) { $control.Enabled = $setup }
    $merge.Visible = $setup
    $merge.Enabled = $setup -and $null -ne $session.Plan -and $session.Plan.Unsafe.Count -eq 0
    $stop.Visible = $phase -eq 'Running'
    $close.Visible = $phase -ne 'Running'
    $openDestination.Visible = $phase -in @('Completed', 'Stopped', 'Failed')
    $deleteZips.Visible = $phase -eq 'Completed'
    $deleteZips.Enabled = -not $session.Deleted
    $progressBar.Visible = $phase -ne 'Setup'
    $progressText.Visible = $phase -ne 'Setup'
}

$evaluate = {
    # Re-plan whenever either folder changes; nothing is written here.
    $session.Plan = $null
    $sourcePath = $sourceRow.Box.Text.Trim()
    $destinationPath = $destinationRow.Box.Text.Trim()
    $session.SourceInfo = $null

    if ($sourcePath) {
        $previousCursor = $form.Cursor
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $info = Get-ZipMergeSource -Source $sourcePath
            if ($info.Zips.Count -eq 0) {
                & $setNote $sourceRow 'No ZIP files directly in this folder. Choose the folder the ZIP files were downloaded to.' 'error'
            }
            else {
                $session.SourceInfo = $info
                $names = @($info.Zips | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', '
                if ($info.Zips.Count -gt 3) { $names += ', ...' }
                & $setNote $sourceRow ("{0} ZIP files ({1}) with {2:N0} files, {3} unpacked: {4}" -f $info.Zips.Count,
                    (Format-ZipMergeSize $info.ZipBytes), $info.Entries, (Format-ZipMergeSize $info.Bytes), $names) 'ok'
            }
        }
        catch { & $setNote $sourceRow "Can't read this folder: $($_.Exception.Message)" 'error' }
        finally { $form.Cursor = $previousCursor }
    }
    else {
        & $setNote $sourceRow 'Choose the folder that contains the downloaded ZIP files.' ''
    }

    if (-not $destinationPath) {
        & $setNote $destinationRow 'Choose where the merged files should go. It can be a new or an existing folder.' ''
    }
    elseif ($null -ne $session.SourceInfo) {
        try {
            $plan = Get-ZipMergePlan -SourceInfo $session.SourceInfo -Destination $destinationPath
            if ($plan.Unsafe.Count -gt 0) {
                & $setNote $destinationRow ("Can't merge: {0} archive path(s) would be written outside the destination, for example {1}." -f $plan.Unsafe.Count, $plan.Unsafe[0]) 'error'
            }
            elseif ($plan.Existing -gt 0) {
                & $setNote $destinationRow ("{0:N0} file(s) already exist here and will be replaced by the ZIP versions." -f $plan.Existing) 'warn'
            }
            elseif ($plan.DestinationExists) {
                & $setNote $destinationRow 'No existing files will be replaced.' 'ok'
            }
            else {
                & $setNote $destinationRow 'This folder will be created.' 'ok'
            }
            if ($plan.Repeated -gt 0 -and $plan.Unsafe.Count -eq 0) {
                $destinationRow.Note.Text += (" {0:N0} path(s) appear in more than one ZIP; the copy from the later ZIP is kept." -f $plan.Repeated)
            }
            $session.Plan = $plan
        }
        catch { & $setNote $destinationRow "Can't use this destination: $($_.Exception.Message)" 'error' }
    }
    else {
        & $setNote $destinationRow 'Choose a ZIP folder first.' ''
    }
    & $updateControls
}

$pickFolder = {
    param($Row, [string]$Description)
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $picker.Description = $Description
        $picker.ShowNewFolderButton = $true
        if ($Row.Box.Text -and (Test-Path -LiteralPath $Row.Box.Text -PathType Container)) { $picker.SelectedPath = $Row.Box.Text }
        if ($picker.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $Row.Box.Text = $picker.SelectedPath
            & $evaluate
        }
    }
    finally { $picker.Dispose() }
}
$sourceRow.Browse.Add_Click({ & $pickFolder $sourceRow 'Choose the folder that contains the Google Drive ZIP files' })
$destinationRow.Browse.Add_Click({ & $pickFolder $destinationRow 'Choose where the merged files should go' })
foreach ($box in @($sourceRow.Box, $destinationRow.Box)) { $box.Add_Leave({ & $evaluate }) }

$appendLog = {
    $line = $null
    $added = $false
    while ($null -ne $session.State -and $session.State.Log.TryDequeue([ref]$line)) {
        $log.AppendText($line + [Environment]::NewLine)
        $added = $true
    }
    if ($added) { $log.SelectionStart = $log.TextLength; $log.ScrollToCaret() }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $state = $session.State
    if ($null -eq $state) { return }
    & $appendLog
    $total = [Math]::Max([long]1, $session.Plan.Bytes)
    $progressBar.Value = [int][Math]::Min(1000, [Math]::Floor(1000.0 * $state.Bytes / $total))
    $progressText.Text = ("ZIP {0} of {1}: {2}    {3:N0} of {4:N0} files    {5:N0} replaced" -f $state.ZipIndex,
        $session.Plan.Zips.Count, $state.ZipName, $state.Files, $session.Plan.Entries, $state.Replaced)
    if (-not $state.Finished) { return }

    $timer.Stop()
    try { $session.PowerShell.EndInvoke($session.Handle) } catch { }
    $session.PowerShell.Dispose()
    & $appendLog
    $session.Phase = $state.Outcome
    $resultText.Visible = $true
    switch ($state.Outcome) {
        'Completed' {
            $session.ExitCode = 0
            $progressBar.Value = 1000
            $resultText.ForeColor = $okColor
            $resultText.Text = ("Done. {0:N0} files extracted from {1} ZIP files; {2:N0} existing files replaced. The original ZIP files are still in the ZIP folder." -f
                $state.Files, $session.Plan.Zips.Count, $state.Replaced)
        }
        'Stopped' {
            $session.ExitCode = 1
            $resultText.ForeColor = $warnColor
            $resultText.Text = ("Stopped after {0:N0} of {1:N0} files. Files already extracted stay in the destination; the original ZIP files have not been deleted." -f
                $state.Files, $session.Plan.Entries)
        }
        default {
            $session.ExitCode = 1
            $resultText.ForeColor = $errorColor
            $resultText.Text = "Extraction stopped by an error: $($state.Error) Files already extracted stay in the destination; the original ZIP files have not been deleted."
        }
    }
    $form.Text = "$appTitle - $($state.Outcome)"
    & $updateControls
    if ($UiSmokeTest) {
        Write-Host "UI merge outcome: $($state.Outcome)"
        $form.Close()
    }
})

$merge.Add_Click({
    & $evaluate
    $plan = $session.Plan
    if ($null -eq $plan -or $plan.Unsafe.Count -gt 0) { return }
    $session.State = New-ZipMergeState
    $session.Phase = 'Running'
    $log.Clear()
    $resultText.Visible = $false
    $progressBar.Maximum = 1000
    $progressBar.Value = 0
    $form.Text = "$appTitle - merging"
    & $updateControls

    # Extract on a background runspace so the window stays responsive and can stop it.
    $session.PowerShell = [System.Management.Automation.PowerShell]::Create()
    # The engine text is loaded as a script block, so the runspace does not depend on
    # the process execution policy.
    $engineText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ZipMergeEngine.ps1') -Raw
    [void]$session.PowerShell.AddScript({
        param($EngineText, $Plan, $State)
        . ([ScriptBlock]::Create($EngineText))
        Invoke-ZipMerge -Plan $Plan -State $State
    }.ToString()).AddArgument($engineText).AddArgument($plan).AddArgument($session.State)
    $session.Handle = $session.PowerShell.BeginInvoke()
    $timer.Start()
    $stop.Focus()
})

$stop.Add_Click({
    if ($null -ne $session.State -and -not $session.State.Finished) {
        $session.State.Cancel = $true
        $stop.Enabled = $false
        $progressText.Text = 'Stopping after the current file...'
    }
})

$openDestination.Add_Click({
    if ($session.Plan -and (Test-Path -LiteralPath $session.Plan.Destination -PathType Container)) {
        Start-Process explorer.exe -ArgumentList "`"$($session.Plan.Destination)`""
    }
})

$deleteZips.Add_Click({
    $plan = $session.Plan
    $answer = [System.Windows.Forms.MessageBox]::Show($form,
        ("Delete the {0} original ZIP files ({1}) from this folder?`n`n{2}`n`nThe merged files are not affected. The ZIP files are deleted permanently; they do not go to the Recycle Bin." -f
            $plan.Zips.Count, (Format-ZipMergeSize $plan.ZipBytes), $plan.Source),
        $appTitle, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $count = Remove-ZipMergeSources -Plan $plan -State $session.State
        $session.Deleted = $true
        $log.AppendText("Deleted $count original ZIP files.$([Environment]::NewLine)")
        $resultText.Text += " Deleted $count original ZIP files."
        $resultText.Text = $resultText.Text.Replace(' The original ZIP files are still in the ZIP folder.', '')
    }
    catch { $log.AppendText("Could not delete every ZIP file: $($_.Exception.Message)$([Environment]::NewLine)") }
    & $updateControls
})

$close.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($session.Phase -ne 'Running') { return }
    $answer = [System.Windows.Forms.MessageBox]::Show($form,
        'The merge is still running. Stop it after the current file and close?',
        $appTitle, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $eventArgs.Cancel = $true; return }
    $session.State.Cancel = $true
    # Wait for the current file so it is not left half-written.
    while (-not $session.State.Finished) { Start-Sleep -Milliseconds 100 }
    $session.ExitCode = 1
})

$form.Add_Shown({
    if ($Source) { $sourceRow.Box.Text = $Source }
    if ($Destination) { $destinationRow.Box.Text = $Destination }
    & $evaluate
    if ($UiSmokeTest) {
        if (-not $merge.Enabled) {
            Write-Host "UI merge outcome: not ready ($($sourceRow.Note.Text) / $($destinationRow.Note.Text))"
            $session.ExitCode = 1
            $form.Close()
            return
        }
        $merge.PerformClick()
    }
    elseif ($Source -and -not $Destination) { $destinationRow.Browse.Focus() }
})

# Wrap long labels to the width actually available in their table cells.
$fitLabels = {
    $width = $layout.ClientSize.Width
    $firstColumn = @($layout.GetColumnWidths())[0]
    foreach ($label in @($title, $subtitle, $progressText, $resultText)) {
        $label.MaximumSize = New-Object System.Drawing.Size([Math]::Max(200, $width - 4), 0)
    }
    foreach ($label in @($sourceRow.Note, $destinationRow.Note)) {
        $label.MaximumSize = New-Object System.Drawing.Size([Math]::Max(160, $width - $firstColumn - 4), 0)
    }
}
$form.Add_Resize($fitLabels)
$form.Add_Load($fitLabels)

& $updateControls
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
exit $session.ExitCode
