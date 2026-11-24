param([string]$Out = 'D:\Work\tmp\ps2-system-test', [switch]$Checked)
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
foreach ($project in @('PS2SystemTest', 'PS2GIFDirectTest', 'PS2VIFReadbackTest', 'PS2GIFImageRunTest', 'PS2GIFOwnedRunTest')) {
  & "$studio\bin\dcc64.exe" @flags "-U$($paths -join ';')" "$PSScriptRoot\$project.dpr"
  if ($LASTEXITCODE -ne 0) { throw "$project build failed" }
  & "$Out\$project.exe"
  if ($LASTEXITCODE -ne 0) { throw "$project test failed" }
}
