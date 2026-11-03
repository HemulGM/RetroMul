#version 450
// The GS HLE renderer's fragments where the shader writes the pixel, in
// primitive order (VK_EXT_fragment_shader_interlock), as the GS does: the
// alpha test with AFAIL, the destination alpha test (DATE), the blend
// (A - B) * C >> 7 + D with PABE, COLCLAMP, FBA and FBMSK bit by bit, in its
// integer arithmetic and the frame format's bits. Depth is the fixed
// function's, tested before the shader (these draws write depth only when
// nothing is discarded or left unwritten).
#extension GL_ARB_fragment_shader_interlock : require

layout(early_fragment_tests) in;
layout(pixel_interlock_ordered) in;
layout(set = 1, binding = 0, rgba8) uniform coherent image2D uTarget;

#include "PS2.GS.HLEFragment.glsl"

// A, B or D of the blend: the source, the destination or zero.
ivec3 blendInput(uint sel, ivec3 s, ivec3 d) {
  return sel == 0u ? s : (sel == 1u ? d : ivec3(0));
}

void main() {
  ivec4 c = shade();
  uint px = pc.pixel;
  uint format = (px >> 21) & 3u;
  bool writeAlpha = true;
  if ((px & (1u << 25)) != 0u && !alphaPasses(c.a)) {
    uint afail = (px >> 23) & 3u;
    // KEEP, and ZB_ONLY (these draws write no depth then): nothing.
    if (afail == 0u || afail == 2u)
      discard;
    if (afail == 3u)
      writeAlpha = false;
  }
  ivec2 p = ivec2(gl_FragCoord.xy);
  beginInvocationInterlockARB();
  ivec4 d = ivec4(round(imageLoad(uTarget, p) * 255.0));
  // The destination as the GS reads it: a 16-bit frame's channels in their
  // five bits and bit 15 as 0x80, a 24-bit one's alpha 0x80.
  ivec3 dc = d.rgb;
  int da = d.a;
  if (format == 2u) {
    dc &= ivec3(0xF8);
    da = d.a >= 128 ? 128 : 0;
  } else if (format == 1u)
    da = 128;
  bool pass = true;
  if ((px & (1u << 19)) != 0u)
    pass = (da >= 128) == ((px & (1u << 20)) != 0u);
  if (pass) {
    ivec3 r = c.rgb;
    if ((px & (1u << 16)) != 0u && ((px & (1u << 17)) == 0u || c.a >= 128)) {
      uint csel = (px >> 4) & 3u;
      int k = csel == 0u ? c.a : (csel == 1u ? da : int((px >> 8) & 255u));
      r = (((blendInput(px & 3u, c.rgb, dc) - blendInput((px >> 2) & 3u, c.rgb, dc)) * k) >> 7) +
        blendInput((px >> 6) & 3u, c.rgb, dc);
    }
    if ((px & (1u << 18)) != 0u)
      r = clamp(r, 0, 255);
    else
      r &= ivec3(255);
    int a = c.a;
    if ((px & (1u << 26)) != 0u)
      a |= 128;
    uint color = uint(r.r) | (uint(r.g) << 8) | (uint(r.b) << 16) | (uint(a & 255) << 24);
    uint old = uint(dc.r) | (uint(dc.g) << 8) | (uint(dc.b) << 16) | (uint(da) << 24);
    uint mask = pc.fbmsk;
    if (!writeAlpha)
      mask |= 0xFF000000u;
    color = (color & ~mask) | (old & mask);
    ivec4 o = ivec4(int(color & 255u), int((color >> 8) & 255u), int((color >> 16) & 255u), int(color >> 24));
    if (format == 2u) {
      o.rgb &= ivec3(0xF8);
      o.a = o.a >= 128 ? 255 : 0;
    } else if (format == 1u)
      o.a = d.a;
    imageStore(uTarget, p, vec4(o) / 255.0);
  }
  endInvocationInterlockARB();
}
