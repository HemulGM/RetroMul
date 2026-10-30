param([string]$Out = 'D:\Work\tmp\ps2-vufloat-test', [switch]$Checked, [switch]$ForceSSE2)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
New-Item -ItemType Directory -Force $Out, "$Out\dcu" | Out-Null
$sources = Get-ChildItem "$root\source" -Recurse -Directory |
  Where-Object { $_.FullName -notmatch '\\ui(\\|$)' } | ForEach-Object FullName
$paths = @($PSScriptRoot) + $sources + @("$root\source", "$studio\lib\win64\release")
$flags = @('-B', '-Q', '-$O+', '-NSSystem;Winapi', "-E$Out", "-NU$Out\dcu")
$defines = @()
if ($Checked) { $defines += 'PS2_CHECKED'; $flags += @('-$Q+', '-$R+') }
if ($ForceSSE2) { $defines += 'PS2_FORCE_SSE2' }
if ($defines.Count -gt 0) { $flags += "-D$($defines -join ';')" }
& "$studio\bin\dcc64.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\VUFloatTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
& "$Out\VUFloatTest.exe"
if ($LASTEXITCODE -ne 0) { throw 'four-field float test failed' }
