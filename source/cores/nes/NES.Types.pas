unit NES.Types;

interface

uses
  System.SysUtils, System.UITypes;

{$SCOPEDENUMS ON}

const
  ROM_SYSTEM_NES = 'nes';
  ROM_CORE_ID_NES = 'NES';

type
  // Dendy uses NTSC-style CPU/APU timing with PAL-style PPU frame timing.
  TNesRegion = (NTSC, PAL, Dendy);

  TRegionOverride = (Auto, NTSC, PAL, Dendy);

  TMmc3IrqRevision = (Auto, SharpBC, SharpA, NecBC, NecA);

  TByteArray = array of UInt8;

  TPalette32 = array[0..63] of UInt32;

  // Native PPU coordinates [X, Y]. Pixels within a column are contiguous.
  TFrameBuffer = array[0..255, 0..239] of UInt32;

  TVt389TileRow = array[0..31] of Byte;

  // Native NES coordinates [X, Y], top-left origin; 0 = dark, 1 = lit.
  TNesZapperMask = array[0..255, 0..239] of Byte;

  PNesZapperMask = ^TNesZapperMask;

  // Synchronous on the emulation thread. Borrowed mask, valid for this call
  // only. Return True when the external photosensor detects light.
  TNesZapperLightCallback = reference to function(const Mask: TNesZapperMask): Boolean;

  ENesException = class(Exception);

procedure CopyNesFrameRows(const Frame: TFrameBuffer; var Pixels: TArray<TAlphaColor>; Left, Top, Width, Height: Integer);

implementation

procedure CopyNesFrameRows(const Frame: TFrameBuffer; var Pixels: TArray<TAlphaColor>; Left, Top, Width, Height: Integer);
begin
  SetLength(Pixels, Width * Height);
  for var Y := 0 to Height - 1 do
  begin
    var Row := Y * Width;
    for var X := 0 to Width - 1 do
      Pixels[Row + X] := TAlphaColor(Frame[X + Left, Y + Top] or $FF000000);
  end;
end;

end.

