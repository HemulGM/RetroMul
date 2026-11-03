// The GS HLE renderer's fragments, shared by PS2.GS.HLE.frag (the fixed
// function blends) and PS2.GS.HLEBlend.frag (the shader does, in primitive
// order): texture sampling as the GS does it (wrap modes, nearest or bilinear
// with 4-bit weights, the LOD and mipmap levels, in 1/16 texels), the texture
// function, fog and the alpha test in its integer arithmetic.

#include "PS2.GS.HLEPush.glsl"

layout(location = 0) noperspective in vec4 vColor;
layout(location = 1) noperspective in vec3 vSTQ;
layout(location = 2) noperspective in vec2 vLodFog;

layout(set = 0, binding = 0) uniform sampler2D uTexture;

// A texel coordinate through the wrap mode (TPS2GSDrawer.ClampCoord).
int wrapCoord(int c, int size, uint mode, int minC, int maxC) {
  if (mode == 0u)
    return c & (size - 1);
  if (mode == 1u)
    return clamp(c, 0, size - 1);
  if (mode == 2u)
    return c < minC ? minC : (c > maxC ? maxC : c);
  return (c & minC) | maxC;
}

// A texel of a level, as the GS reads it (RGBA, 0..255).
ivec4 texel(ivec2 p, int level) {
  if ((pc.flags & FLAG_TARGET) == 0u) {
    ivec2 size = textureSize(uTexture, level);
    return ivec4(round(texelFetch(uTexture, clamp(p, ivec2(0), size - 1), level) * 255.0));
  }
  // A render target's image: its pixels as the texture format reads them.
  ivec2 size = textureSize(uTexture, 0);
  p += ivec2(int(pc.texOffset & 0xFFFFu), int(pc.texOffset >> 16));
  ivec4 t = ivec4(round(texelFetch(uTexture, clamp(p, ivec2(0), size - 1), 0) * 255.0));
  uint format = (pc.tex >> 19) & 3u;
  if (format == 0u)
    return t;
  bool aem = (pc.tex & (1u << 21)) != 0u;
  int ta0 = int(pc.texa & 255u);
  int ta1 = int((pc.texa >> 8) & 255u);
  if (format == 2u) {
    bool high = t.a >= 128;
    t.rgb &= ivec3(0xF8);
    t.a = high ? ta1 : ((aem && t.rgb == ivec3(0)) ? 0 : ta0);
  } else
    t.a = (aem && t.rgb == ivec3(0)) ? 0 : ta0;
  return t;
}

// One level's texel or bilinear mix (TPS2GSDrawer.SampleLevel); uv in 1/16
// texels of level 0.
ivec4 sampleLevel(int level, ivec2 uv, bool linear) {
  int w = max(1, (1 << int((pc.tex >> 24) & 15u)) >> level);
  int h = max(1, (1 << int(pc.tex >> 28)) >> level);
  uint wms = (pc.tex >> 3) & 3u;
  uint wmt = (pc.tex >> 5) & 3u;
  int minU = int(pc.clampU & 0x3FFu);
  int maxU = int((pc.clampU >> 16) & 0x3FFu);
  int minV = int(pc.clampV & 0x3FFu);
  int maxV = int((pc.clampV >> 16) & 0x3FFu);
  if (wms != 3u) {
    minU >>= level;
    maxU >>= level;
  }
  if (wmt != 3u) {
    minV >>= level;
    maxV >>= level;
  }
  uv >>= level;
  if (!linear)
    return texel(ivec2(wrapCoord(uv.x >> 4, w, wms, minU, maxU), wrapCoord(uv.y >> 4, h, wmt, minV, maxV)), level);
  int u0 = (uv.x - 8) >> 4;
  int v0 = (uv.y - 8) >> 4;
  int fu = (uv.x - 8) & 15;
  int fv = (uv.y - 8) & 15;
  int cu0 = wrapCoord(u0, w, wms, minU, maxU);
  int cu1 = wrapCoord(u0 + 1, w, wms, minU, maxU);
  int cv0 = wrapCoord(v0, h, wmt, minV, maxV);
  int cv1 = wrapCoord(v0 + 1, h, wmt, minV, maxV);
  ivec4 top = texel(ivec2(cu0, cv0), level) * (16 - fu) + texel(ivec2(cu1, cv0), level) * fu;
  ivec4 bottom = texel(ivec2(cu0, cv1), level) * (16 - fu) + texel(ivec2(cu1, cv1), level) * fu;
  return (top * (16 - fv) + bottom * fv) >> 8;
}

// MMAG for a negative LOD, else MMIN on level 0 or the mipmap levels
// (TPS2GSDrawer.Texel).
ivec4 sampleTexture(ivec2 uv, float lodQ) {
  bool magLinear = (pc.tex & 128u) != 0u;
  if ((pc.tex & (1u << 17)) == 0u)
    return sampleLevel(0, uv, magLinear);
  float lod = pc.lodK;
  if ((pc.tex & (1u << 14)) == 0u)
    lod += -log2(max(abs(lodQ), 1e-30)) * float(1 << int((pc.tex >> 15) & 3u));
  if (lod < 0.0)
    return sampleLevel(0, uv, magLinear);
  int mmin = int((pc.tex >> 8) & 7u);
  int mxl = int((pc.tex >> 11) & 7u);
  bool bilinear = mmin == 1 || mmin == 4 || mmin == 5;
  if (mmin <= 1 || mxl == 0)
    return sampleLevel(0, uv, bilinear);
  if (mmin == 2 || mmin == 4)
    return sampleLevel(min(int(lod + 0.5), mxl), uv, bilinear);
  int l0 = int(lod);
  if (l0 >= mxl)
    return sampleLevel(mxl, uv, bilinear);
  int frac = int(round((lod - float(l0)) * 16.0));
  ivec4 a = sampleLevel(l0, uv, bilinear);
  if (frac <= 0)
    return a;
  return (a * (16 - frac) + sampleLevel(l0 + 1, uv, bilinear) * frac) >> 4;
}

// A blend weight (see blend in the push constants).
float weight(uint code, float c) {
  if (code == 0u)
    return 0.0;
  if (code == 1u)
    return 1.0;
  if (code == 2u)
    return c;
  if (code == 3u)
    return max(1.0 - c, 0.0);
  return 1.0 + c;
}

bool alphaPasses(int a) {
  int ref = int(pc.alphaTest & 255u);
  switch ((pc.alphaTest >> 8) & 7u) {
    case 0u: return false;
    case 1u: return true;
    case 2u: return a < ref;
    case 3u: return a <= ref;
    case 4u: return a == ref;
    case 5u: return a >= ref;
    case 6u: return a > ref;
  }
  return a != ref;
}

// The fragment's colour before the alpha test (TFX, fog).
ivec4 shade() {
  ivec4 c = clamp(ivec4(round(vColor * 255.0)), 0, 255);
  if ((pc.flags & FLAG_TEXTURED) != 0u) {
    // Coordinates as TexCoord takes them: toward zero, bounded.
    vec2 st = vSTQ.xy;
    float q = vSTQ.z;
    if (q != 1.0)
      st /= (q == 0.0 ? 1.0 : q);
    ivec2 uv = ivec2(clamp(st, vec2(-16777216.0), vec2(16777216.0)));
    ivec4 t = sampleTexture(uv, vLodFog.x);
    uint tfx = pc.tex & 3u;
    bool tcc = (pc.tex & 4u) != 0u;
    if (tfx == 0u) {
      c.rgb = (c.rgb * t.rgb) >> 7;
      if (tcc)
        c.a = (c.a * t.a) >> 7;
    } else if (tfx == 1u) {
      c.rgb = t.rgb;
      if (tcc)
        c.a = t.a;
    } else {
      c.rgb = ((c.rgb * t.rgb) >> 7) + c.a;
      if (tcc)
        c.a = tfx == 2u ? t.a + c.a : t.a;
    }
    c = min(c, ivec4(255));
  }
  if ((pc.flags & FLAG_FOG) != 0u) {
    int f = clamp(int(round(vLodFog.y)), 0, 255);
    ivec3 fog = ivec3(int(pc.fogColor & 255u), int((pc.fogColor >> 8) & 255u), int((pc.fogColor >> 16) & 255u));
    c.rgb = (c.rgb * f + fog * (255 - f)) >> 8;
  }
  return c;
}