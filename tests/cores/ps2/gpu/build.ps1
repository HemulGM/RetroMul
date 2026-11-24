param([string]$Out = 'D:\Work\tmp\ps2-gpu-test', [switch]$Checked, [switch]$Hybrid, [switch]$Async)
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
if ($Checked) { $flags += @('-DPS2_CHECKED', '-$Q+', '-$R+') }
& "$studio\bin\dcc64.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\PS2GSPascalShaderTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'Pascal shader test build failed' }
& "$Out\PS2GSPascalShaderTest.exe"
if ($LASTEXITCODE -ne 0) { throw 'Pascal shader compile failed' }
& "$studio\bin\dcc64.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\PS2GSGpuTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$testArgs = @()
if ($Hybrid) { $testArgs += '-hybrid' }
if ($Async) { $testArgs += '-async' }
& "$Out\PS2GSGpuTest.exe" @testArgs
if ($LASTEXITCODE -ne 0) { throw 'GPU differential test failed' }
& "$studio\bin\dcc64.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\PS2GSUnusedDepthTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'unused-depth test build failed' }
& "$Out\PS2GSUnusedDepthTest.exe"
if ($LASTEXITCODE -ne 0) { throw 'unused-depth test failed' }
