function Build-PS2ShaderResources([string]$Root, [string]$Out, [string]$Studio) {
  Push-Location "$Root\source\gpu\shaders"
  try {
    & "$Studio\bin\cgrc.exe" "-fo$Out\PS2GS.Pascal.res" 'PS2GS.Pascal.rc'
    if ($LASTEXITCODE -ne 0) { throw 'PS2 Pascal shader resource build failed' }
  } finally {
    Pop-Location
  }
}
