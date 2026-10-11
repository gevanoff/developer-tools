# Presentation helpers. No network access or account persistence.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MeterNative {
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
 [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
"@
$script:layoutName='Standard'
$script:meterIcons=@{}
$script:meterFonts=@{}
$accent=New-Object Windows.Forms.Panel
$accent.SetBounds(0,0,330,5)
$form.Controls.Add($accent)
$bar.BackColor=[Drawing.Color]::FromArgb(51,59,70)
$fill=New-Object Windows.Forms.Panel
$fill.Dock='Left'
$bar.Controls.Add($fill)
$sizeMenu=New-Object Windows.Forms.ToolStripMenuItem('Panel size')
[void]$menu.Items.Insert(3,$sizeMenu)
$form.ContextMenuStrip=$menu
$title.Text='CODEX ALLOWANCE  /  right-click for size'
function Get-MeterColor($remaining,$unavailable=$false,$blocked=$false) {
 if($unavailable -or $null -eq $remaining){return [Drawing.ColorTranslator]::FromHtml('#94A3B8')}
 if($blocked -or $remaining -le 10){return [Drawing.ColorTranslator]::FromHtml('#F87171')}
 if($remaining -le 25){return [Drawing.ColorTranslator]::FromHtml('#FB923C')}
 if($remaining -le 50){return [Drawing.ColorTranslator]::FromHtml('#FACC15')}
 return [Drawing.ColorTranslator]::FromHtml('#4ADE80')
}
function Set-MeterColor($remaining,$unavailable=$false,$blocked=$false) {
 $color=Get-MeterColor $remaining $unavailable $blocked
 $accent.BackColor=$color; $fill.BackColor=$color
 $fill.Width=if($null -eq $remaining){0}else{[int]($bar.Width*[Math]::Max(0,[Math]::Min(100,$remaining))/100)}
 $key=$color.ToArgb().ToString()
 if(!$script:meterIcons.ContainsKey($key)){
  $bitmap=New-Object Drawing.Bitmap(32,32)
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode='AntiAlias'
  $brush=New-Object Drawing.SolidBrush($color)
  $graphics.FillEllipse($brush,3,3,26,26)
  $handle=$bitmap.GetHicon()
  $borrowed=[Drawing.Icon]::FromHandle($handle)
  $script:meterIcons[$key]=$borrowed.Clone()
  $borrowed.Dispose();[void][MeterNative]::DestroyIcon($handle)
  $brush.Dispose();$graphics.Dispose();$bitmap.Dispose()
 }
 $tray.Icon=$script:meterIcons[$key];$form.Icon=$script:meterIcons[$key]
}
function Place-Control($control,$x,$y,$w,$h,$fontSize) {
 $control.SetBounds($x,$y,$w,$h)
 if($fontSize){if(!$script:meterFonts.ContainsKey($fontSize)){$script:meterFonts[$fontSize]=New-Object Drawing.Font('Segoe UI',$fontSize)};$control.Font=$script:meterFonts[$fontSize]}
}
function Sync-TitleTheme {
 # Poll from the UI timer so registry access and DWM calls stay on the UI thread.
 $light=Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue
 $dark=if([Windows.Forms.SystemInformation]::HighContrast -or $null -eq $light){0}else{[int]($light -eq 0)}
 if($script:lastTitleDark -ne $dark){
  $result=[MeterNative]::DwmSetWindowAttribute($form.Handle,20,[ref]$dark,4)
  if($result -ne 0){[void][MeterNative]::DwmSetWindowAttribute($form.Handle,19,[ref]$dark,4)}
  $script:lastTitleDark=$dark
 }
}
function Set-Layout($name) {
 $script:layoutName=$name
 $form.SuspendLayout()
 $title.Text='CODEX ALLOWANCE  /  right-click for size'
 foreach($button in @($refresh,$collapse,$dashboard)){$button.Visible=$name -in @('Standard','Large')}
 switch($name){
  'Mini' {
   $w=240;$h=205
   Place-Control $title 12 10 216 18 8
   $title.Text='CODEX / right-click for options'
   Place-Control $big 12 30 216 40 22
   Place-Control $bar 12 76 216 6 0
   Place-Control $resets 12 90 216 23 10
   Place-Control $windows 12 118 216 42 9
   Place-Control $status 12 168 216 34 8
  }
  'Compact' {
   $w=490;$h=138
   Place-Control $title 14 10 462 18 8
   Place-Control $big 14 33 172 45 26
   Place-Control $bar 14 86 164 7 0
   Place-Control $resets 200 34 276 25 11
   Place-Control $windows 200 66 276 42 9
   Place-Control $status 14 112 462 23 8
  }
  'Large' {
   $w=430;$h=420
   Place-Control $title 18 14 394 22 10
   Place-Control $big 18 48 394 60 34
   Place-Control $bar 18 116 394 9 0
   Place-Control $windows 18 141 394 95 13
   Place-Control $resets 18 240 394 34 16
   Place-Control $status 18 287 394 55 11
  }
  default {
   $w=330;$h=350
   Place-Control $title 16 12 298 20 8
   Place-Control $big 16 44 298 53 27
   Place-Control $bar 18 100 294 7 0
   Place-Control $windows 18 119 294 82 10
   Place-Control $resets 18 208 294 32 12
   Place-Control $status 18 242 294 48 9
  }
 }
 $form.ClientSize=New-Object Drawing.Size($w,$h)
 Place-Control $accent 0 0 $w 5 0
 $buttons=@($refresh,$collapse,$dashboard)
 for($i=0;$i -lt 3;$i++){Place-Control $buttons[$i] (18+$i*[int](($w-30)/3)) ($h-50) ([int](($w-48)/3)) 32 9}
 foreach($item in $sizeMenu.DropDownItems){$item.Checked=$item.Text -eq $name}
 $screen=[Windows.Forms.Screen]::FromControl($form).WorkingArea
 $form.Location=New-Object Drawing.Point(([Math]::Max($screen.Left,[Math]::Min($form.Left,$screen.Right-$form.Width))),([Math]::Max($screen.Top,[Math]::Min($form.Top,$screen.Bottom-$form.Height))))
 $form.ResumeLayout()
 Render
 Sync-TitleTheme
}
foreach($name in @('Mini','Compact','Standard','Large')){
 $item=$sizeMenu.DropDownItems.Add($name)
 $item.Add_Click({param($sender,$eventArgs) Set-Layout $sender.Text})
}
