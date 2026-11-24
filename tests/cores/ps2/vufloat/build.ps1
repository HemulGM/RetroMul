param([string]$Out = 'D:\Work\tmp\ps2-vufloat-test', [switch]$Checked, [switch]$ForceSSE2, [switch]$ConversionsOnly)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
New-Item -ItemType Directory -Force $Out, "$Out\dcu" | Out-Null
. "$PSScriptRoot\..\shader-resources.ps1"
Build-PS2ShaderResources $root $Out $studio
$sources = Get-ChildItem "$root\source" -Recurse -Directory |
  Where-Object { $_.FullName -notmatch '\\ui(\\|$)' } | ForEach-Object FullName
$dependencies = @(Get-ChildItem "$root\dependencies\Delphi7z" -Recurse -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\\.git' } | ForEach-Object FullName) + @("$root\dependencies\Delphi7z")
$paths = @($PSScriptRoot) + $sources + $dependencies + @("$root\source", "$studio\lib\win64\release")
$paths += @("$root\dependencies\PasToSPIRV\source")
$flags = @('-B', '-Q', '-$O+', '-NSSystem;Winapi', "-E$Out", "-NU$Out\dcu", "-R$Out")
$defines = @()
if ($Checked) { $defines += 'PS2_CHECKED'; $flags += @('-$Q+', '-$R+') }
if ($ForceSSE2) { $defines += 'PS2_FORCE_SSE2' }
if ($defines.Count -gt 0) { $flags += "-D$($defines -join ';')" }
& "$studio\bin\dcc64.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\VUFloatTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$testArgs = @()
if ($ConversionsOnly) { $testArgs += '-conversionsonly' }
& "$Out\VUFloatTest.exe" @testArgs
if ($LASTEXITCODE -ne 0) { throw 'four-field float test failed' }
