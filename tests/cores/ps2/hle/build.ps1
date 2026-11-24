param([string]$Out = 'D:\Work\tmp\ps2-hle-tests', [switch]$Checked)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
New-Item -ItemType Directory -Force $Out, "$Out\dcu" | Out-Null
. "$PSScriptRoot\..\shader-resources.ps1"
Build-PS2ShaderResources $root $Out $studio
$dirs = @($Out, $PSScriptRoot, "$root\apps\retromul", "$root\source")
[xml]$project = Get-Content "$root\apps\retromul\RetroMul.dproj" -Raw
foreach ($node in $project.SelectNodes("//*[local-name()='DCC_UnitSearchPath']")) {
  foreach ($item in $node.InnerText.Split(';')) {
    if ($item -and $item -notmatch '\$\(') {
      $dirs += [IO.Path]::GetFullPath((Join-Path "$root\apps\retromul" $item))
    }
  }
}
$dirs += @(Get-ChildItem "$root\source", "$root\apps\retromul", "$root\dependencies\FMXInput", "$root\dependencies\Delphi7z" -Recurse -Directory |
  Where-Object { $_.FullName -notmatch '\\(\.git|__history|examples|Win64|Win32|Android|Android64|OSX64|OSXARM64|Linux64)(\\|$)' } |
  ForEach-Object FullName)
$dirs += @("$root\dependencies\FMXInput", "$root\dependencies\Delphi7z", "$studio\source\fmx", "$studio\lib\win64\release")
$paths = ($dirs | Select-Object -Unique) -join ';'
foreach ($name in 'PS2HLEScaleTest', 'PS2HLESpriteCoverageTest', 'PS2HLESubpixelTriangleTest', 'PS2HLEDepthRowTest', 'PS2HLETextureScaleTest', 'PS2HLECoherenceTest', 'PS2HLEDynamicTextureTest', 'PS2HLEConfigTest',
  'PS2HLEChangedRowsTest', 'VulkanHLEEqualBytesTest', 'PS2HLEColorUploadTest', 'PS2HLEDepthUploadTest') {
  $flags = @('-B', '-Q', '-$O+', '-NSSystem;Winapi;System.Win;Vcl;FMX',
    ('-U"' + $paths + '"'), ('-I"' + $paths + '"'), ('-R"' + $paths + '"'),
    ('-E"' + $Out + '"'), ('-NU"' + $Out + '\dcu"'))
  if ($Checked) { $flags += @('-DPS2_CHECKED', '-$Q+', '-$R+') }
  $flags += '"' + $PSScriptRoot + '\' + $name + '.dpr"'
  [IO.File]::WriteAllLines("$Out\compile.rsp", $flags, [Text.Encoding]::ASCII)
  & "$studio\bin\dcc64.exe" "@$Out\compile.rsp"
  if ($LASTEXITCODE -ne 0) { throw "$name build failed" }
  if ($name -eq 'PS2HLEConfigTest') {
    & "$Out\$name.exe" "$Out\configuration"
  } elseif ($name -in 'PS2HLEColorUploadTest', 'PS2HLEDepthUploadTest') {
    & "$Out\$name.exe" -all-scales
  } else {
    & "$Out\$name.exe"
  }
  if ($LASTEXITCODE -ne 0) { throw "$name failed" }
}
