#version 450
// The GS HLE renderer's fragments where the fixed function blends: its
// source side weighed here, the destination weight out as the second
// source's alpha (dual-source blending). Depth is the fixed function's.

layout(location = 0, index = 0) out vec4 oColor;
layout(location = 0, index = 1) out vec4 oFactor;

#include "PS2.GS.HLEFragment.glsl"

void main() {
  ivec4 c = shade();
  uint test = (pc.alphaTest >> 12) & 3u;
  if (test != 0u && alphaPasses(c.a) != (test == 1u))
    discard;
  int a = c.a;
  if ((pc.flags & FLAG_FBA) != 0u)
    a |= 128;
  if ((pc.flags & FLAG_ALPHA1) != 0u)
    a = a >= 128 ? 255 : 0;
  vec3 rgb = vec3(c.rgb) / 255.0;
  float factor = 0.0;
  if ((pc.flags & FLAG_BLEND) != 0u) {
    float k = (pc.blend & (2u << 6)) != 0u ? float((pc.blend >> 8) & 255u) / 128.0 : float(c.a) / 128.0;
    if ((pc.blend & (1u << 17)) != 0u)
      rgb *= weight(pc.blend & 7u, k);
    if ((pc.blend & (1u << 18)) != 0u)
      factor = weight((pc.blend >> 3) & 7u, k);
    // PABE: a source alpha below 0x80 is written unblended.
    if ((pc.blend & (1u << 16)) != 0u && c.a < 128) {
      rgb = vec3(c.rgb) / 255.0;
      factor = 0.0;
    }
  }
  oColor = vec4(rgb, float(a) / 255.0);
  oFactor = vec4(factor);
}