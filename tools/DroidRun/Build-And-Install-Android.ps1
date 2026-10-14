[CmdletBinding()]
param(
    [string]$Project,
    [string]$GradleTask = 'assembleDebug',
    [string]$DeviceSerial,
    [string]$PreferredApk,
    [string]$JavaHome,
    [switch]$AutoLaunch
)

$implementation = Join-Path $PSScriptRoot 'Invoke-AndroidBuildInstall.ps1'
if (-not (Test-Path -LiteralPath $implementation -PathType Leaf)) {
    Write-Error "Android build implementation was not found: $implementation"
    exit 1
}

$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $implementation
)

if ($Project) { $arguments += @('-Project', $Project) }
if ($GradleTask) { $arguments += @('-GradleTask', $GradleTask) }
if ($DeviceSerial) { $arguments += @('-DeviceSerial', $DeviceSerial) }
if ($PreferredApk) { $arguments += @('-PreferredApk', $PreferredApk) }
if ($JavaHome) { $arguments += @('-JavaHome', $JavaHome) }
if ($AutoLaunch) { $arguments += '-AutoLaunch' }

$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & powershell.exe @arguments
    $exitCode = [int]$LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousPreference
}

exit $exitCode
