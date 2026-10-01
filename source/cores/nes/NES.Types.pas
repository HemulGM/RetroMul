unit NES.Types;

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

type
  // Dendy uses NTSC-style CPU/APU timing with PAL-style PPU frame timing.
  TNesRegion = (NTSC, PAL, Dendy);

  TRegionOverride = (Auto, NTSC, PAL);

  TByteArray = array of UInt8;

  TPalette32 = array[0..63] of UInt32;

  TFrameBuffer = array[0..255, 0..239] of UInt32;

  // Native NES coordinates [X, Y], top-left origin; 0 = dark, 1 = lit.
  TNesZapperMask = array[0..255, 0..239] of Byte;

  PNesZapperMask = ^TNesZapperMask;

  // Synchronous on the emulation thread. Borrowed mask, valid for this call
  // only. Return True when the external photosensor detects light.
  TNesZapperLightCallback = reference to function(const Mask: TNesZapperMask): Boolean;

  ENesException = class(Exception);

implementation

end.

