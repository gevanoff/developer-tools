function Find-DesktopCodex([string]$Root) {
 if(!$Root -or !(Test-Path -LiteralPath $Root -PathType Container)){return $null}
 $candidate=Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
  ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'codex.exe') -ErrorAction SilentlyContinue } |
  Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
 if($candidate){return $candidate.FullName}
 return $null
}

function Register-RefreshFailure {
 $script:failures++
 $seconds=if($script:failures -eq 1){30}elseif($script:failures -eq 2){60}else{120}
 $script:nextRefresh=[DateTime]::UtcNow.AddSeconds($seconds)
}
