Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
folder = fs.GetParentFolderName(WScript.ScriptFullName)
powershell = fs.BuildPath(fs.GetSpecialFolder(1), "WindowsPowerShell\v1.0\powershell.exe")
shell.Run """" & powershell & """ -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & folder & "\CodexMeter.ps1""", 0, False
