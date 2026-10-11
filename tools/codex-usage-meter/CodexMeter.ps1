param([switch]$SelfTest,[switch]$LiveTest,[string]$CodexPath,[string]$PreviewPath)
$ErrorActionPreference = 'Stop'
$taskkillPath = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
if($SelfTest){[Windows.Forms.Application]::SetUnhandledExceptionMode('ThrowException')}
$mutexName = if($LiveTest){'Local\CodexUsageMeter_Test'}else{'Local\CodexUsageMeter_v1'}
$mutex = New-Object Threading.Mutex($false, $mutexName)
if (!$SelfTest) {
 try { $ownsMutex=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
 if(!$ownsMutex){$mutex.Dispose();exit}
}
$script:worker = $null
$script:snapshot = $null
$script:lastError = $null
$script:nextRefresh = [DateTime]::MinValue
$script:quitting = $false
if(!$SelfTest){
 try {
  $nodePath = (Get-Command node.exe -ErrorAction Stop).Source
  if(!$CodexPath){$CodexPath = (Get-Command codex.exe -ErrorAction Stop).Source}
  if(!(Test-Path -LiteralPath $CodexPath -PathType Leaf)){throw 'Codex executable not found'}
 } catch {
  [void][Windows.Forms.MessageBox]::Show('Install Node.js and make codex.exe available on PATH, then sign in to Codex. See README.md for setup and the -CodexPath option.','Codex meter setup')
  $mutex.ReleaseMutex();$mutex.Dispose();exit 1
 }
}
$form = New-Object Windows.Forms.Form
$form.Text = 'Codex allowance'
$form.ClientSize = New-Object Drawing.Size(330,350)
$form.FormBorderStyle = 'FixedToolWindow'
$form.MaximizeBox = $false
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(([Math]::Max($area.Left,$area.Right-$form.Width-20)),([Math]::Max($area.Top,$area.Bottom-$form.Height-20)))
$form.BackColor = [Drawing.Color]::FromArgb(24,28,34)
$form.ForeColor = [Drawing.Color]::FromArgb(234,240,246)
$form.Font = New-Object Drawing.Font('Segoe UI',10)
function Label($text,$x,$y,$w,$h,$size=10) {
 $l=New-Object Windows.Forms.Label
 $l.Text=$text; $l.Location=New-Object Drawing.Point($x,$y); $l.Size=New-Object Drawing.Size($w,$h)
 $l.Font=New-Object Drawing.Font('Segoe UI',$size)
 $form.Controls.Add($l); return $l
}
$title=Label 'CODEX ALLOWANCE' 20 16 270 24 10
$big=Label 'Connecting...' 18 44 294 49 27
$bar=New-Object Windows.Forms.Panel
$bar.Location=New-Object Drawing.Point(22,100); $bar.Size=New-Object Drawing.Size(286,8)
$form.Controls.Add($bar)
$windows=Label '' 20 119 290 82 10
$resets=Label 'Available resets: --' 20 208 290 26 12
$status=Label 'Checking your account...' 20 242 290 44 9
function Button($text,$x,$width) {
 $b=New-Object Windows.Forms.Button
 $b.Text=$text; $b.Location=New-Object Drawing.Point($x,300); $b.Size=New-Object Drawing.Size($width,30)
 $b.FlatStyle='Flat'; $b.BackColor=[Drawing.Color]::FromArgb(40,47,57)
 $form.Controls.Add($b); return $b
}
$refresh=Button 'Refresh' 20 88
$collapse=Button 'To tray' 118 88
$dashboard=Button 'Dashboard' 216 94
$tray=New-Object Windows.Forms.NotifyIcon
$tray.Icon=[Drawing.SystemIcons]::Information
$tray.Text='Codex allowance - connecting'
$tray.Visible=$true
$menu=New-Object Windows.Forms.ContextMenuStrip
$show=$menu.Items.Add('Show allowance')
$trayRefresh=$menu.Items.Add('Refresh now')
$pin=$menu.Items.Add('Always on top'); $pin.Checked=$true; $pin.CheckOnClick=$true
$quit=$menu.Items.Add('Quit')
$tray.ContextMenuStrip=$menu
function Show-Panel { $form.Show(); $form.WindowState='Normal'; $form.Activate() }
$show.Add_Click({Show-Panel})
$tray.Add_MouseClick({param($s,$e) if($e.Button -eq 'Left'){Show-Panel}})
$collapse.Add_Click({$form.Hide()})
$pin.Add_Click({$form.TopMost=$pin.Checked})
$quit.Add_Click({$script:quitting=$true; $form.Close()})
$dashboard.Add_Click({Start-Process 'https://chatgpt.com/codex/settings/usage'})
$form.Add_FormClosing({param($s,$e) if(!$script:quitting -and $e.CloseReason -eq 'UserClosing'){$e.Cancel=$true; $form.Hide()}})
function Start-Refresh {
 if($script:worker){return}
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$nodePath
 $info.Arguments='"'+(Join-Path $PSScriptRoot 'read-usage.mjs')+'" "'+$codexPath+'"'
 $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
 $script:worker=New-Object Diagnostics.Process
 $script:worker.StartInfo=$info
 try { [void]$script:worker.Start() } catch {
  $script:worker.Dispose();$script:worker=$null
  $script:lastError='Cannot start usage reader. Check Node.js installation.'
  $script:nextRefresh=[DateTime]::UtcNow.AddMinutes(5)
  return
 }
 $script:outTask=$script:worker.StandardOutput.ReadToEndAsync()
 $script:errTask=$script:worker.StandardError.ReadToEndAsync()
 $script:started=[DateTime]::UtcNow
 $refresh.Enabled=$false
}
function Window-Text($w) {
 if(!$w){return $null}
 $name=if($w.windowDurationMins -eq 10080){'Weekly'}elseif($w.windowDurationMins -eq 300){'5-hour'}else{'Allowance'}
 $remaining=if($null -eq $w.usedPercent){'--'}else{[Math]::Round([Math]::Max(0,[Math]::Min(100,100-$w.usedPercent)),1)}
 $count='reset time unavailable'
 if($null -ne $w.resetsAt){
  $d=[DateTimeOffset]::FromUnixTimeSeconds([long]$w.resetsAt)-[DateTimeOffset]::UtcNow
  $count=if($d.TotalSeconds -le 0){'reset due; awaiting refresh'}else{('resets in {0}d {1}h {2}m' -f $d.Days,$d.Hours,$d.Minutes)}
 }
 if($script:layoutName -in @('Mini','Compact')){
  $short=if($null -eq $w.resetsAt){'reset unknown'}elseif($d.TotalSeconds -le 0){'reset pending'}else{('{0}d {1}h {2}m' -f $d.Days,$d.Hours,$d.Minutes)}
  return "$name $remaining% / $short"
 }
 return "$name`: $remaining% left`n$count"
}
function Render {
 if(!$script:snapshot){
  Set-MeterColor $null $true
  if($script:lastError){$big.Text='Unavailable';$status.Text=$script:lastError;$tray.Text='Codex allowance - unavailable'}
  return
 }
 $r=$script:snapshot.rateLimits
 $ws=@($r.primary,$r.secondary) | Where-Object {$null -ne $_}
 $valid=@($ws | Where-Object {$null -ne $_.usedPercent})
 if($valid.Count){
  $left=($valid | ForEach-Object {[Math]::Max(0,[Math]::Min(100,100-$_.usedPercent))} | Measure-Object -Minimum).Minimum
  $big.Text=('{0:0.#}% remaining' -f $left)
 }else{$big.Text='Not reported';$left=$null}
 $windows.Text=($ws | ForEach-Object {Window-Text $_}) -join "`n"
 $count=if($null -eq $script:snapshot.availableResets){'Not reported'}else{[string]$script:snapshot.availableResets}
 $resets.Text="Available resets: $count"
 $last=([DateTimeOffset]::Parse($script:snapshot.checkedAt)).ToLocalTime().ToString('h:mm:ss tt')
 $stale=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($script:snapshot.checkedAt)).TotalMinutes -gt 6
 Set-MeterColor $left ([bool]($script:lastError -or $stale)) ($script:snapshot.ordinaryUsageAllowed -eq $false)
 $status.Text=if($script:lastError -or $stale){"Stale - last success $last`nRefresh will retry automatically."}elseif($script:snapshot.ordinaryUsageAllowed -eq $false){"Included usage blocked. Updated $last"}else{"Updated $last  |  Refreshes every 5 min"}
 if($script:layoutName -in @('Mini','Compact')){
  if($null -ne $left){$big.Text=('{0:0.#}% left' -f $left)}
  $resets.Text="Resets available: $count"
  $stamp=([DateTimeOffset]::Parse($script:snapshot.checkedAt)).ToLocalTime().ToString('HH:mm:ss')
  $state=if($script:lastError -or $stale){'STALE; retrying'}elseif($script:snapshot.ordinaryUsageAllowed -eq $false){'Usage blocked'}else{'Auto refresh: 5 min'}
  $separator=if($script:layoutName -eq 'Mini'){"`n"}else{'  |  '}
  $status.Text="Updated $stamp$separator$state"
 }
 $tip=if($script:lastError -or $stale){'Codex: stale - open panel'}else{("Codex: {0} | Resets: {1}" -f $big.Text,$count)}
 $tray.Text=$tip.Substring(0,[Math]::Min(63,$tip.Length))
}
$refresh.Add_Click({$script:nextRefresh=[DateTime]::MinValue})
$trayRefresh.Add_Click({$script:nextRefresh=[DateTime]::MinValue})
$timer=New-Object Windows.Forms.Timer
$timer.Interval=1000
$timer.Add_Tick({
 Sync-TitleTheme
 if($script:worker -and $script:worker.HasExited -and $script:outTask.IsCompleted -and $script:errTask.IsCompleted){
  try{
   $data=$script:outTask.Result | ConvertFrom-Json
   if($data.error){throw $data.error}
   if(!$data.checkedAt -or !$data.rateLimits){throw 'Invalid response'}
   $script:snapshot=$data; $script:lastError=$null
  }catch{$script:lastError='Usage unavailable. Check Codex sign-in or connection.'}
  $script:worker.Dispose();$script:worker=$null;$refresh.Enabled=$true
  $script:nextRefresh=[DateTime]::UtcNow.AddMinutes(5)
 }
 if($script:worker -and ([DateTime]::UtcNow-$script:started).TotalSeconds -gt 35){
  if(!$script:worker.HasExited){& $taskkillPath /PID $script:worker.Id /T /F 2>$null | Out-Null}
  $script:worker.Dispose();$script:worker=$null;$refresh.Enabled=$true
  $script:lastError='Usage refresh timed out. Retry shortly.'
  $script:nextRefresh=[DateTime]::UtcNow.AddMinutes(5)
 }
 if(!$script:worker -and [DateTime]::UtcNow -ge $script:nextRefresh){Start-Refresh}
 Render
 if($LiveTest -and ($script:snapshot -or $script:lastError)){
  [Console]::WriteLine($big.Text+'; '+$resets.Text+'; '+$status.Text)
  if($script:lastError){$script:liveFailed=$true}
  $script:quitting=$true;$form.Close()
 }
})
. (Join-Path $PSScriptRoot 'Presentation.ps1')
Set-Layout 'Standard'
try {
 if($SelfTest){
  $script:snapshot=[pscustomobject]@{checkedAt=[DateTime]::UtcNow.ToString('o');availableResets=2;ordinaryUsageAllowed=$true;rateLimits=[pscustomobject]@{primary=[pscustomobject]@{usedPercent=27;windowDurationMins=10080;resetsAt=[DateTimeOffset]::UtcNow.AddDays(3).ToUnixTimeSeconds()};secondary=$null}}
  Render
  if($big.Text -ne '73% remaining' -or $resets.Text -ne 'Available resets: 2'){throw 'Rendering check failed'}
  $form.Show();$form.Hide();if($form.Visible){throw 'Collapse failed'}
  Show-Panel;if(!$form.Visible){throw 'Restore failed'}
  $script:lastError='Offline';Render;if($status.Text -notlike 'Stale*'){throw 'Stale check failed'}
  $script:lastError=$null;$script:snapshot.availableResets=$null;Render
  if($resets.Text -ne 'Available resets: Not reported'){throw 'Unknown reset check failed'}
  $script:snapshot.availableResets=2
  $script:snapshot.rateLimits.secondary=[pscustomobject]@{usedPercent=80;windowDurationMins=300;resetsAt=$null};Render
  if($big.Text -ne '20% remaining' -or $windows.Text -notlike '*5-hour*'){throw 'Multiple windows failed'}
  $script:snapshot.rateLimits.primary.usedPercent=$null
  $script:snapshot.rateLimits.secondary=$null;Render
  if($big.Text -ne 'Not reported'){throw 'Missing percentage failed'}
  $script:snapshot.rateLimits.primary.usedPercent=27
  $script:snapshot.rateLimits.primary.resetsAt=1;Render
  if($windows.Text -notlike '*awaiting refresh*'){throw 'Expired reset failed'}
  $script:snapshot.ordinaryUsageAllowed=$false;Render
  if($status.Text -notlike '*blocked*'){throw 'Blocked usage failed'}
  foreach($pair in @(@(100,'#4ADE80'),@(50,'#FACC15'),@(25,'#FB923C'),@(10,'#F87171'),@(0,'#F87171'))){
   if((Get-MeterColor $pair[0]).ToArgb() -ne ([Drawing.ColorTranslator]::FromHtml($pair[1])).ToArgb()){throw 'Color boundary failed'}
  }
  if((Get-MeterColor 90 $true).ToArgb() -ne ([Drawing.ColorTranslator]::FromHtml('#94A3B8')).ToArgb()){throw 'Stale color failed'}
  $script:snapshot.ordinaryUsageAllowed=$true
  foreach($preset in @('Mini','Compact','Standard','Large')){
   Set-Layout $preset
   foreach($control in @($big,$bar,$windows,$resets,$status)){
    if($control.Right -gt $form.ClientSize.Width -or $control.Bottom -gt $form.ClientSize.Height){throw "Clipped control in $preset"}
   }
   if($accent.BackColor.ToArgb() -ne $fill.BackColor.ToArgb() -or $null -eq $tray.Icon){throw 'Color synchronization failed'}
   if($PreviewPath){
    $preview=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($preview,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $preview.Save($PreviewPath.Replace('.png',"-$preset.png"));$preview.Dispose()
   }
  }
  if($PreviewPath){
   $bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
   $form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
   $bmp.Save($PreviewPath);$bmp.Dispose()
  }
  'PASS: allowance, resets, unknown values, stale/blocked states, multiple windows, expired reset, collapse and restore'
 }else{$timer.Start();[Windows.Forms.Application]::Run($form)}
} finally {
 $timer.Stop();$timer.Dispose();$tray.Visible=$false;$tray.Dispose()
 if($script:worker -and !$script:worker.HasExited){& $taskkillPath /PID $script:worker.Id /T /F 2>$null | Out-Null}
 $form.Dispose();if(!$SelfTest){$mutex.ReleaseMutex()};$mutex.Dispose()
 foreach($icon in $script:meterIcons.Values){$icon.Dispose()}
 foreach($font in $script:meterFonts.Values){$font.Dispose()}
}
if($script:liveFailed){exit 1}
