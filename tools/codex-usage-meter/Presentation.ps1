# Presentation helpers. No network access or account persistence.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MeterNative {
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
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
function Set-Layout($name) {
 $script:layoutName=$name
 $form.SuspendLayout()
 switch($name){
  'Mini' {$w=300;$h=225;$headline=20;$top=30;$barY=72;$detailsY=86;$detailsH=58;$resetY=150;$statusY=175;$buttonsY=0;$detailFont=8;$resetFont=10;$statusFont=8}
  'Compact' {$w=310;$h=285;$headline=23;$top=32;$barY=80;$detailsY=94;$detailsH=62;$resetY=160;$statusY=191;$buttonsY=241;$detailFont=9;$resetFont=11;$statusFont=8}
  'Large' {$w=430;$h=420;$headline=34;$top=46;$barY=113;$detailsY=135;$detailsH=95;$resetY=239;$statusY=283;$buttonsY=366;$detailFont=13;$resetFont=16;$statusFont=11}
  default {$w=330;$h=350;$headline=27;$top=44;$barY=100;$detailsY=119;$detailsH=82;$resetY=208;$statusY=242;$buttonsY=300;$detailFont=10;$resetFont=12;$statusFont=9}
 }
 $form.ClientSize=New-Object Drawing.Size($w,$h)
 Place-Control $accent 0 0 $w 5 0
 Place-Control $title 16 12 ($w-32) 20 8
 Place-Control $big 16 $top ($w-32) ($barY-$top-3) $headline
 Place-Control $bar 18 $barY ($w-36) 7 0
 Place-Control $windows 18 $detailsY ($w-36) $detailsH $detailFont
 Place-Control $resets 18 $resetY ($w-36) 32 $resetFont
 Place-Control $status 18 $statusY ($w-36) 48 $statusFont
 $buttons=@($refresh,$collapse,$dashboard)
 for($i=0;$i -lt 3;$i++){
  $buttons[$i].Visible=$name -ne 'Mini'
  Place-Control $buttons[$i] (18+$i*[int](($w-30)/3)) $buttonsY ([int](($w-48)/3)) 32 9
 }
 foreach($item in $sizeMenu.DropDownItems){$item.Checked=$item.Text -eq $name}
 $screen=[Windows.Forms.Screen]::FromControl($form).WorkingArea
 $form.Location=New-Object Drawing.Point(([Math]::Max($screen.Left,[Math]::Min($form.Left,$screen.Right-$form.Width))),([Math]::Max($screen.Top,[Math]::Min($form.Top,$screen.Bottom-$form.Height))))
 $form.ResumeLayout()
 Render
}
foreach($name in @('Mini','Compact','Standard','Large')){
 $item=$sizeMenu.DropDownItems.Add($name)
 $item.Add_Click({param($sender,$eventArgs) Set-Layout $sender.Text})
}
