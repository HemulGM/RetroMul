# Builds N64HardwareTest for Win64 (dcc64) or Win32 (dcc32) into bin\<platform>:
# build.ps1 [-Platform Win64]. fetch.ps1 gets the ROMs; then bin\<platform>\N64HardwareTest.exe.
param([ValidateSet('Win64', 'Win32')][string]$Platform = 'Win64')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\..\..\.."
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$compiler, $lib = switch ($Platform) {
  'Win64' { 'dcc64', 'win64' }
  'Win32' { 'dcc32', 'win32' }
}
$out = "$PSScriptRoot\bin\$Platform"
New-Item -ItemType Directory -Force -Path $out, "$out\dcu" | Out-Null
# The engine's sources (not the user interface's).
$sources = Get-ChildItem "$root\source" -Recurse -Directory | Where-Object { $_.FullName -notmatch '\\ui(\\|$)' } |
  ForEach-Object FullName
$paths = @($PSScriptRoot) + $sources + @("$root\source", "$studio\lib\$lib\release")
& "$studio\bin\$compiler.exe" -B -Q '-$O+' '-NSSystem;Winapi' "-E$out" "-NU$out\dcu" "-U$($paths -join ';')" "$PSScriptRoot\N64HardwareTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
