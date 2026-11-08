# Loads the DroidRun dashboard theme and view (DroidRunUi.cs) plus the pure
# presentation rules. Dot-source after Add-Type -AssemblyName System.Windows.Forms.
. (Join-Path $PSScriptRoot 'DroidRunPresentation.ps1')

if ($null -eq ('DroidRun.DashboardView' -as [type])) {
    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'DroidRunUi.cs') -Raw) `
        -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -Language CSharp
}

function New-DroidRunButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('Primary', 'Secondary', 'Quiet')][string]$Kind = 'Secondary'
    )
    return [DroidRun.ThemedButton]::new($Text, [DroidRun.ButtonKind]$Kind)
}

function New-DroidRunChipCell {
    param([AllowEmptyString()][string]$Status, [AllowEmptyString()][string]$Prefix = '')
    return [DroidRun.ChipCell]::new((Get-DroidRunStatusTone -Status $Status), $Prefix)
}
