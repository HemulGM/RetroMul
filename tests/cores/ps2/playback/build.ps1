param([string]$Out = 'D:\Work\tmp\ps2-playback-test')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
New-Item -ItemType Directory -Force $Out, "$Out\dcu" | Out-Null
$paths = @($PSScriptRoot, "$root\source\platforms\ps2", "$root\source\cores\ps2", "$root\dependencies\PCMAudio", "$studio\lib\win64\release")
& "$studio\bin\dcc64.exe" -B -Q '-$O+' '-$Q+' '-$R+' '-NSSystem;Winapi' "-E$Out" "-NU$Out\dcu" "-U$($paths -join ';')" "$PSScriptRoot\PS2PlaybackTest.dpr"
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
& "$Out\PS2PlaybackTest.exe"
if ($LASTEXITCODE -ne 0) { throw 'PS2 playback test failed' }
