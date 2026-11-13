Option Explicit
Dim shell, fs, script
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
script = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "drive_backup.py")
shell.Run "pyw.exe -3 " & Chr(34) & script & Chr(34), 1, False
