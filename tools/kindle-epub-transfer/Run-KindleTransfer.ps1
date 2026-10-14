param(
    [ValidateSet('scan', 'convert', 'publish')][string]$Action = 'convert',
    [string]$Config = (Join-Path $PSScriptRoot 'settings.local.json')
)
$ErrorActionPreference = 'Stop'
try {
    $settings = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
    $python = (Get-Command python -ErrorAction Stop).Source
    $arguments = @((Join-Path $PSScriptRoot 'kindle_transfer.py'), $Action)
    if ($Action -eq 'scan') {
        $arguments += @('--source', $settings.source)
    } elseif ($Action -eq 'convert') {
        $arguments += @('--source', $settings.source, '--state', $settings.state,
            '--calibre-config', $settings.calibre_config)
    } else {
        if (-not $settings.destination) { throw 'Set destination to your local Google Drive sync folder before publishing.' }
        $arguments += @('--state', $settings.state, '--destination', $settings.destination)
    }
    & $python @arguments
    exit $LASTEXITCODE
} catch {
    Write-Error $_
    exit 1
}
