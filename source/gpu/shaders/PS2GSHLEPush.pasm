// Per-draw PS2 HLE state. Keep the existing 56-byte push layout.
type
  TPS2HLEPush = record
    NdcScale: Single2;
    Flags, Tex, ClampU, ClampV, Texa, FogColor, AlphaTest, Blend: Cardinal;
    LodK: Single;
    TexOffset, Pixel, FBMask: Cardinal;
  end;

const
  FlagTextured: Cardinal = 1;
  FlagFog: Cardinal = 2;
  FlagTarget: Cardinal = 4;
  FlagFBA: Cardinal = 8;
  FlagAlpha1: Cardinal = 16;
  FlagBlend: Cardinal = 32;
  FlagCompactTexture: Cardinal = 512;
