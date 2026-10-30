param([string]$Out = 'D:\Work\tmp\ps2-gpu-test', [switch]$Checked, [switch]$Hybrid)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
New-Item -ItemType Directory -Force $Out, "$Out\dcu" | Out-Null
$sources = Get-ChildItem "$root\source" -Recurse -Directory |
  Where-Object { $_.FullName -notmatch '\\ui(\\|$)' } | ForEach-Object FullName
$paths = @($PSScriptRoot) + $sources + @("$root\source", "$studio\lib\win64\release")
$flags = @('-B', '-Q', '-$O+', '-NSSystem;Winapi', "-E$Out", "-NU$Out\dcu")
if ($Checked) { $flags += @('-DPS2_CHECKED', '-$Q+', '-$R+') }
& "$studio\bin\dcc64.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\PS2GSGpuTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$testArgs = @()
if ($Hybrid) { $testArgs += '-hybrid' }
& "$Out\PS2GSGpuTest.exe" @testArgs
if ($LASTEXITCODE -ne 0) { throw 'GPU differential test failed' }
