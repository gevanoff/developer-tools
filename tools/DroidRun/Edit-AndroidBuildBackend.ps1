[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Project)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'AndroidBuildBackends.ps1')
$roots = @(Get-AndroidProjectRoots -Root $Project)
if ($roots.Count -gt 1) { throw 'Select a specific build root before editing its configuration.' }
$root = if ($roots.Count -eq 1) { $roots[0] } else { [IO.Path]::GetFullPath($Project) }
$path = Join-Path $root 'android-build-install.json'
$dialog = New-Object System.Windows.Forms.Form
$dialog.Text = 'Godot / custom build configuration'
$dialog.Size = New-Object System.Drawing.Size(760, 550)
$dialog.StartPosition = 'CenterParent'
$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.RowCount = 3; $layout.ColumnCount = 1
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$hint = New-Object System.Windows.Forms.Label
$hint.AutoSize = $true
$hint.Text = "Godot is detected automatically. Configure its editor path/preset here if needed.`r`nCustom builds run executable + arguments in this folder and must update apk.`r`nReview commands before running them. Windows executable paths use JSON escaped backslashes.`r`n$path"
$layout.Controls.Add($hint, 0, 0)
$editor = New-Object System.Windows.Forms.TextBox
$editor.Multiline = $true; $editor.AcceptsReturn = $true; $editor.AcceptsTab = $true
$editor.ScrollBars = 'Both'; $editor.WordWrap = $false; $editor.Dock = 'Fill'
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
$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.AutoSize = $true; $buttons.Dock = 'Fill'
$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.Add_Click({
    try {
        $data = ConvertFrom-Json -InputObject $editor.Text
        if ($data -isnot [pscustomobject] -or $data.version -ne 1) { throw 'Expected an object with version: 1.' }
        [IO.File]::WriteAllText($path, $editor.Text, (New-Object System.Text.UTF8Encoding($false)))
        $dialog.DialogResult = 'OK'; $dialog.Close()
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Invalid configuration') }
})
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
$buttons.Controls.Add($save); $buttons.Controls.Add($cancel)
$layout.Controls.Add($buttons, 0, 2)
$dialog.Controls.Add($layout); $dialog.CancelButton = $cancel
[void]$dialog.ShowDialog()
$dialog.Dispose()
