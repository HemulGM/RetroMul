param([string]$Out = 'D:\Work\tmp\ps2-lod-test')
# Every positive Single through System.Math.Log2, both host roundings (about a minute).
$ErrorActionPreference = 'Stop'
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
New-Item -ItemType Directory -Force $Out, "$Out\dcu" | Out-Null
& "$studio\bin\dcc64.exe" -B -Q '-$O+' '-NSSystem;Winapi' "-E$Out" "-NU$Out\dcu" "-U$studio\lib\win64\release" "$PSScriptRoot\PS2LodMonotoneTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
& "$Out\PS2LodMonotoneTest.exe"
if ($LASTEXITCODE -ne 0) { throw 'Log2 is not monotone' }