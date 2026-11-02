// Per-draw state of the HLE renderer's pipelines (PSP.GE.VulkanHLE TGEHLEPush).
layout(push_constant) uniform Push {
  // 2 / width and 2 / height of the target in PSP pixels.
  vec2 ndcScale;
  // FLAG_* bits, the colour test function in bits 8-9, the source premultiply
  // in bits 12-13, the target format in bits 16-17, the scale in bits 24-27.
  uint flags;
  // Function in bits 0-2, texture alpha in bit 3, colour doubling in bit 4,
  // the level of detail in bits 5-6 (0 none, 1 from the derivatives plus the
  // bias, 2 the bias, 3 from the slope and w plus the bias), TEX_* bits, the
  // minification filter in bits 8-10, the image's highest level in 13-15,
  // TEX_TARGET's scale and format in bits 17-22; without TEX_TARGET, a scale
  // in bits 17-20 is a texture made larger (TEX_SCALED).
  uint texFunc;
  uint env;
  uint fogColor;
  // Function in bits 0-2, reference in bits 8-15, mask in bits 16-23.
  uint alphaTest;
  uint colorRef;
  uint colorMask;
  float minZ;
  float maxZ;
  // In 1/16 levels.
  float lodBias;
  vec2 texSize;
  // The 4x4 dither matrix as signed nibbles, row-major.
  uint dither0;
  uint dither1;
  uint fixA;
  float lodSlope;
  // PSPGEHLEBlend.frag: source factor in bits 0-3, destination factor in bits
  // 4-7, operation in bits 8-10, blending on in bit 11, logic operation in
  // bits 12-15 (on in bit 16), depth test function in bits 20-22 (on in bit
  // 23), stencil test function in bits 24-26 (on in bit 27).
  uint blend;
  uint fixB;
  // The pixel bits the masks keep, in the target format.
  uint keep;
  // Stencil reference in bits 0-7, mask in bits 8-15.
  uint stencil;
} pc;

const uint FLAG_TEXTURED = 1u;
const uint FLAG_FOG = 2u;
const uint FLAG_COLORTEST = 4u;
const uint FLAG_ALPHATEST = 8u;
const uint FLAG_RANGE = 16u;
const uint FLAG_CLAMPZ = 32u;
const uint FLAG_CLEAR = 64u;
const uint FLAG_DITHER = 128u;
const uint FLAG_QUANTIZE = 1024u;

const uint TEX_MAGLINEAR = 128u;
const uint TEX_CLAMPU = 2048u;
const uint TEX_CLAMPV = 4096u;
// The texture is a render target's image: its scale in bits 17-20, its format
// in bits 21-22.
const uint TEX_TARGET = 65536u;
// The scale bits: without TEX_TARGET, the image holds the GE's texels that
// many times larger along each side (texture scaling, an option).
const uint TEX_SCALED = 15u << 17;
