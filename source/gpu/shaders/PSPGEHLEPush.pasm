// Per-draw state, with the std430 layout of TGEHLEPush.
type
  TGEHLEPush = record
    NdcScale: Single2;
    Flags, TexFunc, Env, FogColor, AlphaTest, ColorRef, ColorMask: Cardinal;
    MinZ, MaxZ, LodBias: Single;
    TexSize: Single2;
    Dither0, Dither1, FixA: Cardinal;
    LodSlope: Single;
    Blend, FixB, Keep, Stencil: Cardinal;
  end;

const
  FLAG_TEXTURED: Cardinal = 1;
  FLAG_FOG: Cardinal = 2;
  FLAG_COLORTEST: Cardinal = 4;
  FLAG_ALPHATEST: Cardinal = 8;
  FLAG_RANGE: Cardinal = 16;
  FLAG_CLAMPZ: Cardinal = 32;
  FLAG_CLEAR: Cardinal = 64;
  FLAG_DITHER: Cardinal = 128;
  FLAG_QUANTIZE: Cardinal = 1024;
  TEX_MAGLINEAR: Cardinal = 128;
  TEX_CLAMPU: Cardinal = 2048;
  TEX_CLAMPV: Cardinal = 4096;
  TEX_TARGET: Cardinal = 65536;
  TEX_SCALED: Cardinal = 15 shl 17;
