[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Invoke-GitCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Git @Arguments 2>&1
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

function Show-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    if ($NoUi) {
        Write-Host $Message
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Android Project Git Pull',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

try {
    $projectPath = [System.IO.Path]::GetFullPath($Project)
    if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
        throw "Project directory does not exist:`n$projectPath"
    }

    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    }
    if ($null -eq $gitCommand) {
        throw 'Git was not found on PATH.'
    }
    $git = $gitCommand.Source

    $rootResult = Invoke-GitCaptured -Git $git -Arguments @('-C', $projectPath, 'rev-parse', '--show-toplevel')
    if ($rootResult.ExitCode -ne 0 -or $rootResult.Output.Count -eq 0) {
        throw "The selected project is not inside a Git repository.`n`n$($rootResult.Output -join [Environment]::NewLine)"
    }
    $repoRoot = [System.IO.Path]::GetFullPath($rootResult.Output[-1].Trim())

    $status = Invoke-GitCaptured -Git $git -Arguments @('-C', $repoRoot, 'status', '--porcelain')
    if ($status.ExitCode -ne 0) {
        throw "git status failed:`n$($status.Output -join [Environment]::NewLine)"
    }
    if ($status.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace(($status.Output -join ''))) {
        $preview = @($status.Output | Select-Object -First 12)
        $suffix = if ($status.Output.Count -gt 12) { "`n...and $($status.Output.Count - 12) more change(s)." } else { '' }
        Show-Result -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message @"
No pull was performed because the working tree has local changes.

Repository:
$repoRoot

Changes:
$($preview -join [Environment]::NewLine)$suffix

Commit, stash, or discard the changes first. This tool will not merge remote work over a dirty tree automatically.
"@
        exit 2
    }

    $branchResult = Invoke-GitCaptured -Git $git -Arguments @('-C', $repoRoot, 'branch', '--show-current')
    $branch = if ($branchResult.ExitCode -eq 0 -and $branchResult.Output.Count -gt 0) { $branchResult.Output[-1].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'The repository is in detached HEAD state. No pull was performed.'
    }

    $upstreamResult = Invoke-GitCaptured -Git $git -Arguments @('-C', $repoRoot, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if ($upstreamResult.ExitCode -ne 0 -or $upstreamResult.Output.Count -eq 0) {
        throw "Branch '$branch' does not have an upstream tracking branch. No pull was performed."
    }
    $upstream = $upstreamResult.Output[-1].Trim()

    $pull = Invoke-GitCaptured -Git $git -Arguments @('-C', $repoRoot, 'pull', '--ff-only')
    $pullText = ($pull.Output -join [Environment]::NewLine).Trim()
    if ($pull.ExitCode -ne 0) {
        throw "git pull --ff-only failed.`n`nRepository: $repoRoot`nBranch: $branch -> $upstream`n`n$pullText"
    }

    if ([string]::IsNullOrWhiteSpace($pullText)) {
        $pullText = 'Pull completed with no additional output.'
    }

    Show-Result -Message @"
Repository updated successfully.

Repository:
$repoRoot

Branch:
$branch -> $upstream

$pullText
"@
    exit 0
}
catch {
    Show-Result -Icon ([System.Windows.Forms.MessageBoxIcon]::Error) -Message $_.Exception.Message
    exit 1
}
