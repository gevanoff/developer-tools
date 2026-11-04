$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\Recovery.ps1')
foreach($expected in @(30,60,120,120)) {
 $before=[DateTime]::UtcNow
 Register-RefreshFailure
 $delay=($script:nextRefresh-$before).TotalSeconds
 if($delay -lt $expected -or $delay -gt ($expected+2)){throw "Unexpected retry delay: $delay"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('codex meter recovery '+[guid]::NewGuid())
$old=Join-Path $root 'old version'
$new=Join-Path $root 'new version'
try {
 [void](New-Item -ItemType Directory -Path $old,$new)
 $oldExe=Join-Path $old 'codex.exe';$newExe=Join-Path $new 'codex.exe'
 [IO.File]::WriteAllText($oldExe,'old')
 (Get-Item -LiteralPath $oldExe).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(-5)
 if((Find-DesktopCodex $root) -ne $oldExe){throw 'Initial executable not found'}
 [IO.File]::WriteAllText($newExe,'new')
 if((Find-DesktopCodex $root) -ne $newExe){throw 'Updated executable not selected'}
 Remove-Item -LiteralPath $oldExe,$newExe
 if($null -ne (Find-DesktopCodex $root)){throw 'Missing executables should return null'}
} finally {
 Remove-Item -LiteralPath $oldExe,$newExe -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $old,$new,$root -ErrorAction SilentlyContinue
}
'PASS: retry delays and desktop executable discovery'
