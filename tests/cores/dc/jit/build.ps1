# Builds DCJitTest for Win64 (dcc64), Win32 (dcc32: no generated code, nothing
# to test) or Linux64 (dcclinux64, linked against a Linux SDK made from WSL:
# -Sdk) into bin\<platform>: build.ps1 [-Platform Win64].
param([ValidateSet('Win64', 'Win32', 'Linux64')][string]$Platform = 'Win64', [string]$Sdk = 'D:\LinuxSDK\ubuntu-22.04')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\..\..\.."
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$compiler, $lib, $ns = switch ($Platform) {
  'Win64' { 'dcc64', 'win64', 'System;Winapi' }
  'Win32' { 'dcc32', 'win32', 'System;Winapi' }
  'Linux64' { 'dcclinux64', 'linux64', 'System;Posix;Linuxapi' }
}
$out = "$PSScriptRoot\bin\$Platform"
New-Item -ItemType Directory -Force -Path $out, "$out\dcu" | Out-Null
# The engine's sources (not the user interface's).
$sources = Get-ChildItem "$root\source" -Recurse -Directory | Where-Object { $_.FullName -notmatch '\\ui(\\|$)' } |
  ForEach-Object FullName
$paths = @($PSScriptRoot) + $sources + @("$root\source", "$studio\lib\$lib\release")
$flags = @('-B', '-Q', '-$O+', "-NS$ns", "-E$out", "-NU$out\dcu", "-NO$out\dcu")
if ($Platform -eq 'Linux64') {
  $gcc = Get-ChildItem "$Sdk\usr\lib\gcc\x86_64-linux-gnu" -Directory | Sort-Object { [int]($_.Name -replace '\D.*', '') } |
    Select-Object -Last 1
  $env:PATH = "$studio\bin;$studio\bin64;$env:PATH"
  $flags += @("--syslibroot:$Sdk", "--libpath:$studio\lib\linux64\release;$Sdk\usr\lib\x86_64-linux-gnu;$($gcc.FullName)")
}
& "$studio\bin\$compiler.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\DCJitTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
