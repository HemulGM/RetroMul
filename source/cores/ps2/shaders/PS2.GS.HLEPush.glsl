// Per-draw state of the GS HLE renderer's pipelines (PS2.GS.VulkanHLE
// TPS2HLEPush).
layout(push_constant) uniform Push {
  // 2 / width and 2 / height of the target in GS pixels.
  vec2 ndcScale;
  // FLAG_* bits.
  uint flags;
  // TFX in bits 0-1, TCC in bit 2, WMS in bits 3-4, WMT in bits 5-6, MMAG
  // linear in bit 7, MMIN in bits 8-10, the highest level in bits 11-13, LCM
  // in bit 14, L in bits 15-16, the LOD in use in bit 17, TEX_TARGET's
  // format in bits 19-20 (0 32-bit, 1 24-bit, 2 16-bit), AEM in bit 21,
  // log2 of the width in bits 24-27 and of the height in bits 28-31.
  uint tex;
  // MINU | MAXU << 16 and MINV | MAXV << 16.
  uint clampU;
  uint clampV;
  // TA0 | TA1 << 8.
  uint texa;
  // FOGCOL as R | G << 8 | B << 16.
  uint fogColor;
  // AREF in bits 0-7, ATST in bits 8-10, the alpha test's use in bits 12-13
  // (0 none, 1 drawing the pixels that pass, 2 those that fail).
  uint alphaTest;
  // The blend's source weight in bits 0-2 and destination weight in bits 3-5
  // (0 none, 1 one, 2 c, 3 1 - c, 4 1 + c, each applied here when its bit
  // 17 / 18 is set), c from the source alpha (bits 6-7 0) or FIX (2), FIX in
  // bits 8-15, PABE in bit 16.
  uint blend;
  // K of the LOD.
  float lodK;
  // A target texture's texels start there in its image: x | y << 16.
  uint texOffset;
  // PS2.GS.HLEBlend.frag: ALPHA's A, B, C, D in bits 0-7 (two each), FIX in
  // bits 8-15, blending on in bit 16, PABE in bit 17, COLCLAMP in bit 18,
  // DATE in bit 19, DATM in bit 20, the frame format in bits 21-22 (0 32-bit,
  // 1 24-bit, 2 16-bit), AFAIL in bits 23-24, the alpha test on in bit 25,
  // FBA in bit 26.
  uint pixel;
  // FBMSK: the frame bits kept (32-bit layout).
  uint fbmsk;
} pc;

const uint FLAG_TEXTURED = 1u;
const uint FLAG_FOG = 2u;
const uint FLAG_TARGET = 4u;
const uint FLAG_FBA = 8u;
// A 16-bit target keeps alpha bit 7 alone, as 0 or 255.
const uint FLAG_ALPHA1 = 16u;
const uint FLAG_BLEND = 32u;
