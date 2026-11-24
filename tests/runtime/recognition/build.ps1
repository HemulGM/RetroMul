param([string]$Out = 'D:\Work\tmp\recognition-test')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
New-Item -ItemType Directory -Force $Out, "$Out\dcu" | Out-Null
$sources = Get-ChildItem "$root\source" -Recurse -Directory |
  Where-Object { $_.FullName -notmatch '\\ui(\\|$)|\\__history' } | ForEach-Object FullName
$dependencies = @(Get-ChildItem "$root\dependencies\Delphi7z" -Recurse -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\\.git' } | ForEach-Object FullName) + @("$root\dependencies\Delphi7z")
$paths = @($PSScriptRoot) + $sources + $dependencies + @("$root\source", "$studio\lib\win64\release")
& "$studio\bin\dcc64.exe" -B -Q '-$O+' '-$Q+' '-$R+' '-NSSystem;Winapi' "-E$Out" "-NU$Out\dcu" "-U$($paths -join ';')" "$PSScriptRoot\RecognitionTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
& "$Out\RecognitionTest.exe"
if ($LASTEXITCODE -ne 0) { throw 'recognition test failed' }
