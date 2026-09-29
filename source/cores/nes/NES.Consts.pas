unit NES.Consts;

interface

uses
  NES.Types;

const
  NES_CPU_HZ = 1789773;
  NES_PAL_CPU_HZ = 1662607;
  NES_DENDY_CPU_HZ = 1773448;
  NES_WIDTH = 256;
  NES_HEIGHT = 240;
  NES_FRAME_CYCLES = 89342;
  NES_PALETTE: TPalette32 = (
    $FF666666, $FF002A88, $FF1412A7, $FF3B00A4, $FF5C007E, $FF6E0040, $FF6C0600, $FF561D00,
    $FF333500, $FF0B4800, $FF005200, $FF004F08, $FF00404D, $FF000000, $FF000000, $FF000000,
    $FFADADAD, $FF155FD9, $FF4240FF, $FF7527FE, $FFA01ACC, $FFB71E7B, $FFB53120, $FF994E00,
    $FF6B6D00, $FF388700, $FF0E9300, $FF008F32, $FF007C8D, $FF000000, $FF000000, $FF000000,
    $FFFFFEFF, $FF64B0FF, $FF9290FF, $FFC676FF, $FFF36AFF, $FFFE6ECC, $FFFE8170, $FFEA9E22,
    $FFBCBE00, $FF88D800, $FF5CE430, $FF45E082, $FF48CDDE, $FF4F4F4F, $FF000000, $FF000000,
    $FFFFFEFF, $FFC0DFFF, $FFD3D2FF, $FFE8C8FF, $FFFBC2FF, $FFFEC4EA, $FFFECCC5, $FFF7D8A5,
    $FFE4E594, $FFCFEF96, $FFBDF4AB, $FFB3F3CC, $FFB5EBF2, $FFB8B8B8, $FF000000, $FF000000
  );

function CpuFrequency(Region: TNesRegion): Integer; inline;

function FrameRate(Region: TNesRegion): Double; inline;

implementation

function CpuFrequency(Region: TNesRegion): Integer;
begin
  if Region = TNesRegion.PAL then
    Result := NES_PAL_CPU_HZ
  else if Region = TNesRegion.Dendy then
    Result := NES_DENDY_CPU_HZ
  else
    Result := NES_CPU_HZ;
end;

function FrameRate(Region: TNesRegion): Double;
begin
  if Region = TNesRegion.PAL then
    Result := NES_PAL_CPU_HZ * 16.0 / (5.0 * 312 * 341)
  else if Region = TNesRegion.Dendy then
    Result := NES_DENDY_CPU_HZ * 3.0 / (312 * 341)
  else
    Result := NES_CPU_HZ * 3.0 / (NES_FRAME_CYCLES - 0.5);
end;

end.

