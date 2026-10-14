[CmdletBinding()]
param(
    [string]$ShortcutPath,
    [switch]$Remove,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'WindowsTaskbarIdentity.ps1')

$legacyShortcutPath = $null
if (-not $ShortcutPath) {
    $programsFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $ShortcutPath = Join-Path $programsFolder 'DroidRun.lnk'
    $legacyShortcutPath = Join-Path $programsFolder 'Android Build and Install.lnk'
}
$ShortcutPath = [System.IO.Path]::GetFullPath($ShortcutPath)
$sessionPath = Join-Path $PSScriptRoot 'AndroidBuildInstall-Session.ps1'
$powershellPath = Join-Path $PSHOME 'powershell.exe'

function Remove-MatchingLegacyShortcut {
    if (-not $legacyShortcutPath -or -not (Test-Path -LiteralPath $legacyShortcutPath -PathType Leaf)) { return }
    $legacyShell = New-Object -ComObject WScript.Shell
    $legacyShortcut = $null
    try {
        $legacyShortcut = $legacyShell.CreateShortcut($legacyShortcutPath)
        # The original directory no longer exists after an in-place upgrade.
        # Construct its path without resolving it, and scope it to this checkout.
        $toolsPath = Split-Path -Parent (Split-Path -Parent $sessionPath)
        $oldSessionPath = Join-Path $toolsPath 'android-build-install\AndroidBuildInstall-Session.ps1'
        $matchingArguments = @($sessionPath, $oldSessionPath) | ForEach-Object {
            "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$_`""
        }
        if ($legacyShortcut.TargetPath -ieq $powershellPath -and
            $matchingArguments -icontains $legacyShortcut.Arguments) {
            Remove-Item -LiteralPath $legacyShortcutPath -Force
        }
    }
    finally {
        if ($null -ne $legacyShortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($legacyShortcut) }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($legacyShell)
    }
}
if ([System.IO.Path]::GetExtension($ShortcutPath) -ine '.lnk') {
    throw "The shortcut path must end in .lnk: $ShortcutPath"
}

if ($Remove) {
    Remove-MatchingLegacyShortcut
    if (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
    if (-not $Quiet) {
        [System.Windows.Forms.MessageBox]::Show(
            "Removed the Start menu shortcut:`n$ShortcutPath",
            'DroidRun',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    return
}

$iconPath = Join-Path $PSScriptRoot 'assets\droidrun.ico'
foreach ($requiredPath in @($sessionPath, $iconPath, $powershellPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required launcher file was not found: $requiredPath"
    }
}

$shortcutParent = Split-Path -Parent $ShortcutPath
if (-not (Test-Path -LiteralPath $shortcutParent -PathType Container)) {
    New-Item -ItemType Directory -Path $shortcutParent -Force | Out-Null
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $null
try {
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$sessionPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Description = 'Build, install, sync, and launch saved Android projects.'
    $shortcut.WindowStyle = 1
    $shortcut.Save()
}
finally {
    if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
    if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

[WindowsTools.TaskbarIdentity]::SetShortcutAppId($ShortcutPath, (Get-AndroidBuildInstallAppId))

# Remove the old default name only after the replacement is installed, and
# only when it points to this checkout. Preserve shortcuts owned by others.
Remove-MatchingLegacyShortcut

if (-not $Quiet) {
    [System.Windows.Forms.MessageBox]::Show(
        "Installed the Start menu shortcut:`n$ShortcutPath`n`nOpen Start, search for DroidRun, then choose Pin to taskbar.",
        'DroidRun',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

Write-Output $ShortcutPath
