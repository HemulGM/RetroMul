# Writes manifest.txt: for each ROM given (paths relative to -Root), its expected picture's size
# and the FNV-1a hash of its pixels (R, G, B, row by row), as N64.HardwareTest hashes the VI's
# framebuffer: manifest.ps1 -Root <roms> -Roms <relative .N64 paths>.
param([string]$Root = "$PSScriptRoot\roms", [Parameter(Mandatory)][string[]]$Roms)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System.Drawing;
public static class PictureHash {
  public static string Of(string path) {
    using (var b = new Bitmap(path)) {
      ulong h = 14695981039346656037UL;
      for (int y = 0; y < b.Height; y++)
        for (int x = 0; x < b.Width; x++) {
          var c = b.GetPixel(x, y);
          foreach (byte v in new byte[] { c.R, c.G, c.B }) { h ^= v; h *= 1099511628211UL; }
        }
      return string.Format("{0} {1} {2:X16}", b.Width, b.Height, h);
    }
  }
}
'@
$lines = foreach ($rom in $Roms | Sort-Object) {
  $full = Join-Path $Root $rom
  $dir = Split-Path $full
  $base = [IO.Path]::GetFileNameWithoutExtension($full)
  $png = Get-ChildItem $dir -Filter *.png | Sort-Object @{ e = { $_.BaseName -ne $base }; Descending = $false },
    @{ e = { $_.Length }; Descending = $true } | Select-Object -First 1
  '{0} {1}' -f $rom.Replace('\', '/'), [PictureHash]::Of($png.FullName)
}
$head = @(
  '# PeterLemon/N64 test ROMs whose pictures this core gives exactly (the VI''s framebuffer in RDRAM',
  '# after 60 VIs with no input): ROM, width, height, FNV-1a hash of the expected picture''s pixels.')
[IO.File]::WriteAllLines("$PSScriptRoot\manifest.txt", [string[]]($head + $lines))
"$($lines.Count) ROMs"
