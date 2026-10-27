# Fetches PeterLemon's N64 test ROMs (github.com/PeterLemon/N64, Unlicense) at the commit the
# manifest was made from, into -Root (only the test folders): fetch.ps1 [-Root <folder>].
param([string]$Root = "$PSScriptRoot\roms")
$ErrorActionPreference = 'Stop'
$commit = '7085543e4a19d8c539fc9e0a4d2869e788b4ed4b'
if (-not (Test-Path "$Root\.git")) {
  git clone -q --filter=blob:none --no-checkout https://github.com/PeterLemon/N64.git $Root
  if ($LASTEXITCODE -ne 0) { throw 'clone failed' }
}
git -C $Root sparse-checkout set CPUTest RSPTest CP1 RDP RDPTest
git -C $Root checkout -q $commit
if ($LASTEXITCODE -ne 0) { throw 'checkout failed' }
"$Root at $(git -C $Root rev-parse --short HEAD)"
