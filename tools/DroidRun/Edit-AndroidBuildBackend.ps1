[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Project)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')
. (Join-Path $PSScriptRoot 'DroidRunTheme.ps1')
$roots = @(Get-AndroidProjectRoots -Root $Project)
if ($roots.Count -gt 1) { throw 'Select a specific build root before editing its configuration.' }
$root = if ($roots.Count -eq 1) { $roots[0] } else { [IO.Path]::GetFullPath($Project) }
$path = Join-Path $root 'android-build-install.json'
$dialog = New-Object System.Windows.Forms.Form
$dialog.Text = 'Godot / custom build - DroidRun'
$dialog.Size = New-Object System.Drawing.Size(760, 560)
$dialog.StartPosition = 'CenterParent'
$dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$dialog.Padding = New-Object System.Windows.Forms.Padding(12)
[DroidRun.Theme]::ApplyForm($dialog)
$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.RowCount = 4; $layout.ColumnCount = 1
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$hint = New-Object System.Windows.Forms.Label
$hint.AutoSize = $true
$hint.Text = "Godot is detected automatically; set its editor path or export preset here if needed.`r`nA custom build runs executable with arguments in this folder and must update apk.`r`nThis file runs commands: review it before saving. Escape backslashes in JSON paths (C:\\Tools\\flutter.bat).`r`n$path"
$hint.ForeColor = [DroidRun.Theme]::Muted
$hint.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$layout.Controls.Add($hint, 0, 0)
$editor = New-Object System.Windows.Forms.TextBox
$editor.Multiline = $true; $editor.AcceptsReturn = $true; $editor.AcceptsTab = $true
$editor.ScrollBars = 'Both'; $editor.WordWrap = $false; $editor.Dock = 'Fill'
$editor.Font = New-Object System.Drawing.Font('Consolas', 10)
$editor.AccessibleName = 'Build configuration JSON'
[DroidRun.Theme]::StyleInput($editor)
[DroidRun.Theme]::DarkScrollBars($editor)
if (Test-Path -LiteralPath $path -PathType Leaf) { $editor.Text = Get-Content -LiteralPath $path -Raw -Encoding UTF8 }
elseif (Test-Path -LiteralPath (Join-Path $root 'project.godot') -PathType Leaf) {
    $editor.Text = @'
{
  "version": 1,
  "backend": "godot",
  "apk": "build/android/app-debug.apk"
}
'@
}
else {
    $editor.Text = @'
{
  "version": 1,
  "backend": "custom",
  "executable": "flutter.bat",
  "arguments": ["build", "apk", "--debug"],
  "apk": "build/app/outputs/flutter-apk/app-debug.apk"
}
'@
}
$layout.Controls.Add($editor, 0, 1)
$errorLabel = New-Object System.Windows.Forms.Label
$errorLabel.AutoSize = $true
$errorLabel.ForeColor = [DroidRun.Theme]::ToneText('error')
$errorLabel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$layout.Controls.Add($errorLabel, 0, 2)
$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.AutoSize = $true; $buttons.Dock = 'Fill'
$buttons.FlowDirection = 'RightToLeft'
$buttons.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$save = New-DroidRunButton -Text '&Save' -Kind Primary
$save.Size = New-Object System.Drawing.Size(100, 34)
$save.Add_Click({
    try {
        $data = ConvertFrom-Json -InputObject $editor.Text
        if ($data -isnot [pscustomobject] -or $data.version -ne 1) { throw 'Expected an object with version: 1.' }
        [IO.File]::WriteAllText($path, $editor.Text, (New-Object System.Text.UTF8Encoding($false)))
        $dialog.DialogResult = 'OK'; $dialog.Close()
    }
    catch {
        # Keep the dialog and the edited text open, with the problem next to the editor.
        $errorLabel.Text = "Not saved: $($_.Exception.Message)"
        [void]$editor.Focus()
    }
})
$cancel = New-DroidRunButton -Text 'Cancel' -Kind Secondary
$cancel.Size = New-Object System.Drawing.Size(100, 34)
$cancel.DialogResult = 'Cancel'
$buttons.Controls.Add($cancel); $buttons.Controls.Add($save)
$layout.Controls.Add($buttons, 0, 3)
$dialog.Controls.Add($layout); $dialog.CancelButton = $cancel
[void]$dialog.ShowDialog()
$dialog.Dispose()
