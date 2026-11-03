// The HLE renderer's fragments: the GE's texture sampling and function,
// secondary colour, fog, colour and alpha tests and depth range test, in its
// integer arithmetic. Included by PSPGEHLE.frag, where blending, logic
// operations, depth and stencil are the fixed function's and the colour
// attachment's alpha (the PSP's stencil channel) is written only in clear
// mode, and by PSPGEHLEBlend.frag (SHADER_BLEND), where the shader blends.

#include "PSPGEHLEPush.glsl"

layout(location = 0) noperspective in vec4 vColor;
layout(location = 1) noperspective in vec3 vSecondary;
layout(location = 2) noperspective in vec4 vSTQW;
layout(location = 3) noperspective in float vFog;
layout(location = 4) noperspective in float vZ;
// The coordinates the samples keep within (sprites above 1x; none where a
// low is above its high).
layout(location = 5) flat in vec4 vBox;

#ifdef SHADER_BLEND
// The target's colour, read and written in primitive order; its depth and
// stencil, only read.
layout(pixel_interlock_ordered) in;
layout(set = 1, binding = 0, rgba8) uniform coherent image2D uTarget;
layout(set = 1, binding = 1) uniform sampler2D uDepth;
layout(set = 1, binding = 2) uniform usampler2D uStencil;
#else
layout(location = 0) out vec4 oColor;
#endif

layout(set = 0, binding = 0) uniform sampler2D uTexture;

int clamp255(int v) {
  return clamp(v, 0, 255);
}

// a * (255 - t) + b * t over 256, rounded up, doubled before the shift.
int texLerp(int a, int b, int t, int dbl) {
  return clamp255(((a * (255 - t) + b * t + 255) * dbl) >> 8);
}

// A colour times a texture colour: the colour counts as (c + 1) / 256.
int texMul(int c, int t, int dbl) {
  return clamp255(((c + 1) * t * dbl) >> 8);
}

ivec3 unpackRGB(uint c) {
  return ivec3(int(c & 255u), int((c >> 8) & 255u), int((c >> 16) & 255u));
}

bool testFunc(uint func, int a, int b) {
  switch (func) {
    case 0u: return false;
    case 2u: return a == b;
    case 3u: return a != b;
    case 4u: return a < b;
    case 5u: return a <= b;
    case 6u: return a > b;
    case 7u: return a >= b;
  }
  return true;
}

// By the image's own pixels: above 1x the PSP's 4x4 pattern over its pixels
// would show as a coarse checkerboard.
int ditherAt() {
  uvec2 p = uvec2(gl_FragCoord.xy);
  uint i = (p.y & 3u) * 4u + (p.x & 3u);
  uint word = i < 8u ? pc.dither0 : pc.dither1;
  int n = int((word >> ((i & 7u) * 4u)) & 15u);
  return n >= 8 ? n - 16 : n;
}

// The colour as the target format keeps it, expanded back to 8 bits.
ivec3 quantize(ivec3 c, uint format) {
  if (format == 0u) {
    ivec3 q = c >> ivec3(3, 2, 3);
    return ivec3((q.r << 3) | (q.r >> 2), (q.g << 2) | (q.g >> 4), (q.b << 3) | (q.b >> 2));
  }
  if (format == 1u) {
    ivec3 q = c >> 3;
    return (q << 3) | (q >> 2);
  }
  if (format == 2u)
    return (c >> 4) * 17;
  return c;
}

// Texture sampling as the GE does it: coordinates in texels, wrapped or
// clamped per level, nearest texels by floor, bilinear with 4-bit weights,
// the level of detail in 1/16 levels from a log2 of 4 mantissa bits.
// A texture that is a render target's image (TEX_TARGET) holds the PSP's
// texels at the target's scale, a scaled one (TEX_SCALED) the GE's at its
// own; their sizes need not be powers of two.
int wrapCoord(int v, int size, bool clampIt) {
  if (clampIt)
    return clamp(v, 0, size - 1);
  if ((pc.texFunc & (TEX_TARGET | TEX_SCALED)) != 0u)
    return v - size * int(floor(float(v) / float(size)));
  return v & (size - 1);
}

ivec4 texel(ivec2 p, int level) {
  if ((pc.texFunc & TEX_TARGET) == 0u)
    return ivec4(round(texelFetch(uTexture, p, level) * 255.0));
  // Texels past the target's rows read its last row; the colour is the one
  // the target format keeps, the alpha its stencil (565 is opaque).
  ivec4 t = ivec4(round(texelFetch(uTexture, min(p, textureSize(uTexture, 0) - 1), 0) * 255.0));
  uint format = (pc.texFunc >> 21) & 3u;
  t.rgb = quantize(t.rgb, format);
  if (format == 0u)
    t.a = 255;
  return t;
}

ivec4 sampleLevel(vec2 st, int level, bool linear) {
  ivec2 size = textureSize(uTexture, level);
  int scale = int((pc.texFunc >> 17) & 15u);
  if ((pc.texFunc & TEX_TARGET) != 0u) {
    st *= float(scale);
    size = ivec2(pc.texSize) * scale;
  } else if (scale > 1)
    st *= float(scale);
  bool cu = (pc.texFunc & TEX_CLAMPU) != 0u;
  bool cv = (pc.texFunc & TEX_CLAMPV) != 0u;
  if (!linear) {
    ivec2 p = ivec2(floor(st));
    return texel(ivec2(wrapCoord(p.x, size.x, cu), wrapCoord(p.y, size.y, cv)), level);
  }
  vec2 f = st - 0.5;
  vec2 f0 = floor(f);
  ivec2 p0 = ivec2(f0);
  ivec2 fr = ivec2((f - f0) * 16.0);
  int xa = wrapCoord(p0.x, size.x, cu);
  int xb = wrapCoord(p0.x + 1, size.x, cu);
  int ya = wrapCoord(p0.y, size.y, cv);
  int yb = wrapCoord(p0.y + 1, size.y, cv);
  // The rows are truncated before the column mix.
  ivec4 top = (texel(ivec2(xa, ya), level) * (16 - fr.x) + texel(ivec2(xb, ya), level) * fr.x) >> 4;
  ivec4 bottom = (texel(ivec2(xa, yb), level) * (16 - fr.x) + texel(ivec2(xb, yb), level) * fr.x) >> 4;
  return (top * (16 - fr.y) + bottom * fr.y) >> 4;
}

// The image's level 0 is the GE's; coordinates go with the level's size.
ivec4 sampleAt(vec2 st, int level, bool linear) {
  if (level > 0)
    st = st * vec2(textureSize(uTexture, level)) / vec2(textureSize(uTexture, 0));
  return sampleLevel(st, level, linear);
}

int log16(float v) {
  if (!(v > 0.0))
    return -0x10000;
  uint bits = floatBitsToUint(v);
  return (int((bits >> 23) & 255u) - 127) * 16 + int((bits >> 19) & 15u);
}

// scale: texels per pixel; w: 1/w.
ivec4 sampleTexture(vec2 st, float scale, float w) {
  uint lodMode = (pc.texFunc >> 5) & 3u;
  bool magLinear = (pc.texFunc & TEX_MAGLINEAR) != 0u;
  if (lodMode == 0u)
    return sampleLevel(st, 0, magLinear);
  int bias = int(pc.lodBias);
  int lod;
  if (lodMode == 1u)
    lod = log16(scale) + bias;
  else if (lodMode == 2u)
    lod = bias;
  else
    lod = log16(pc.lodSlope / w) + 16 + bias;
  if (lod <= 0)
    return sampleLevel(st, 0, magLinear);
  int minFilter = int((pc.texFunc >> 8) & 7u);
  int maxLevel = int((pc.texFunc >> 13) & 7u);
  bool linear = (minFilter & 1) != 0;
  if (minFilter < 4 || maxLevel == 0)
    return sampleLevel(st, 0, linear);
  lod = min(lod, maxLevel * 16);
  int level = lod >> 4;
  int frac = lod & 15;
  if (minFilter < 6) {
    if (frac >= 8)
      level++;
    return sampleAt(st, min(level, maxLevel), linear);
  }
  ivec4 c0 = sampleAt(st, level, linear);
  if (frac == 0 || level >= maxLevel)
    return c0;
  return (c0 * (16 - frac) + sampleAt(st, level + 1, linear) * frac) >> 4;
}


// The fragment's colour after the tests, as it goes to the blend (or, in
// clear mode, as it is written, with the stencil value as alpha).
ivec4 shade(out float zr) {
  uint flags = pc.flags;
  uint format = (flags >> 16) & 3u;
  // The depth as the GE rounds it; the depth test and writes see it clamped.
  zr = roundEven(vZ);
  ivec4 c = ivec4(round(clamp(vColor, 0.0, 1.0) * 255.0));

  // Where q is not positive (against 1/w) the GE takes the last texel. The
  // derivatives are taken before anything is discarded.
  float q = vSTQW.z;
  bool ok = q != 0.0 && ((q > 0.0) == (vSTQW.w > 0.0));
  vec2 st = mix(pc.texSize - 0.5, vSTQW.xy / q, bvec2(ok));
  vec2 dx = dFdxFine(st);
  vec2 dy = dFdyFine(st);
  if (vBox.x <= vBox.z)
    st.x = clamp(st.x, vBox.x, vBox.z);
  if (vBox.y <= vBox.w)
    st.y = clamp(st.y, vBox.y, vBox.w);
  ivec4 t = ivec4(0);
  if ((flags & FLAG_TEXTURED) != 0u)
    t = sampleTexture(st, max(max(abs(dx.x), abs(dy.x)), max(abs(dx.y), abs(dy.y))), vSTQW.w);

  if ((flags & FLAG_CLEAR) != 0u) {
    ivec3 rgb = c.rgb;
    if ((flags & FLAG_DITHER) != 0u)
      rgb = clamp(rgb + ditherAt(), 0, 255);
    rgb = quantize(rgb, format);
    // The stencil value in the format's precision, as 8 bits.
    int s = c.a;
    if (format == 1u)
      s = (s >> 7) * 255;
    else if (format == 2u)
      s = (s >> 4) * 17;
    else if (format == 0u)
      s = 0;
    return ivec4(rgb, s);
  }

  // The range test sees the depth clamped only with depth clamping on.
  if ((flags & FLAG_RANGE) != 0u) {
    float z = zr;
    if ((flags & FLAG_CLAMPZ) != 0u)
      z = clamp(z, 0.0, 65535.0);
    if (z < pc.minZ || z > pc.maxZ)
      discard;
  }

  if ((flags & FLAG_TEXTURED) != 0u) {
    uint func = pc.texFunc & 7u;
    bool texAlpha = (pc.texFunc & 8u) != 0u;
    int dbl = (pc.texFunc & 16u) != 0u ? 2 : 1;
    if (func == 0u) {
      c.rgb = ivec3(texMul(c.r, t.r, dbl), texMul(c.g, t.g, dbl), texMul(c.b, t.b, dbl));
      if (texAlpha)
        c.a = texMul(c.a, t.a, 1);
    } else if (func == 1u) {
      if (texAlpha)
        c.rgb = ivec3(texLerp(c.r, t.r, t.a, dbl), texLerp(c.g, t.g, t.a, dbl), texLerp(c.b, t.b, t.a, dbl));
      else
        c.rgb = clamp(t.rgb * dbl, 0, 255);
    } else if (func == 2u) {
      ivec3 env = unpackRGB(pc.env);
      c.rgb = ivec3(texLerp(c.r, env.r, t.r, dbl), texLerp(c.g, env.g, t.g, dbl), texLerp(c.b, env.b, t.b, dbl));
      if (texAlpha)
        c.a = texMul(c.a, t.a, 1);
    } else if (func == 3u) {
      c.rgb = clamp(t.rgb * dbl, 0, 255);
      if (texAlpha)
        c.a = t.a;
    } else {
      c.rgb = clamp((c.rgb + t.rgb) * dbl, 0, 255);
      if (texAlpha)
        c.a = texMul(c.a, t.a, 1);
    }
  }

  c.rgb = clamp(c.rgb + ivec3(round(clamp(vSecondary, 0.0, 1.0) * 255.0)), 0, 255);

  if ((flags & FLAG_FOG) != 0u) {
    int fi = int(clamp(vFog, 0.0, 1.0) * 255.0);
    ivec3 fog = unpackRGB(pc.fogColor);
    c.rgb = ivec3(texLerp(fog.r, c.r, fi, 1), texLerp(fog.g, c.g, fi, 1), texLerp(fog.b, c.b, fi, 1));
  }

  if ((flags & FLAG_COLORTEST) != 0u) {
    uint packed = uint(c.r) | (uint(c.g) << 8) | (uint(c.b) << 16);
    uint func = (flags >> 8) & 3u;
    bool same = (packed & pc.colorMask) == (pc.colorRef & pc.colorMask);
    if (func == 0u || (func == 2u && !same) || (func == 3u && same))
      discard;
  }

  if ((flags & FLAG_ALPHATEST) != 0u) {
    int mask = int((pc.alphaTest >> 16) & 255u);
    int ref = int((pc.alphaTest >> 8) & 255u);
    if (!testFunc(pc.alphaTest & 7u, c.a & mask, ref & mask))
      discard;
  }

#ifndef SHADER_BLEND
  // The source side of a blend the fixed function cannot weigh.
  uint premultiply = (flags >> 12) & 3u;
  if (premultiply == 1u) {
    ivec3 fix = unpackRGB(pc.fixA);
    c.rgb = ((c.rgb + 1) * fix) >> 8;
  } else if (premultiply == 2u) {
    c.rgb = clamp((((c.rgb + 1) * c.a) >> 8) * 2, 0, 255);
  } else if (premultiply == 3u) {
    c.rgb = ((c.rgb + 1) * max(0, 255 - 2 * c.a)) >> 8;
  }

  if ((flags & FLAG_DITHER) != 0u)
    c.rgb = clamp(c.rgb + ditherAt(), 0, 255);
  if ((flags & FLAG_QUANTIZE) != 0u)
    c.rgb = quantize(c.rgb, format);
#endif
  return c;
}

#ifdef SHADER_BLEND
#include "PSPGEHLEBlend.glsl"
#else
void main() {
  float zr;
  ivec4 c = shade(zr);
  // Over 65536 the depth is exact in the depth buffer's float.
  gl_FragDepth = clamp(zr, 0.0, 65535.0) * (1.0 / 65536.0);
  oColor = vec4(c) / 255.0;
}
#endif
