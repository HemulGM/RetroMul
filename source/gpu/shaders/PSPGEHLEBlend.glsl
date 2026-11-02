// The GE's pixel writes, in the shader (PSPGEHLEBlend.frag): depth and
// stencil tests against the target's (only read: the draws this serves
// write neither), then, in primitive order, the blend with the target's
// colour, dither, logic operation and masks, in the GE's integer arithmetic
// and the target format's bits. The colour's alpha (the stencil's mirror)
// stays.

// One side of the blend: the colour counts as (c + 1) / 256; doubled factors
// double the product, "one minus double" ones clamp at zero; 10 and up are
// the fixed colour.
int blendTerm(uint kind, int c, int other, int sa, int da, int fix) {
  switch (kind) {
    case 0u: return ((c + 1) * other) >> 8;
    case 1u: return ((c + 1) * (255 - other)) >> 8;
    case 2u: return ((c + 1) * sa) >> 8;
    case 3u: return ((c + 1) * (255 - sa)) >> 8;
    case 4u: return ((c + 1) * da) >> 8;
    case 5u: return ((c + 1) * (255 - da)) >> 8;
    case 6u: return (((c + 1) * sa) >> 8) * 2;
    case 7u: return ((c + 1) * max(0, 255 - 2 * sa)) >> 8;
    case 8u: return (((c + 1) * da) >> 8) * 2;
    case 9u: return ((c + 1) * max(0, 255 - 2 * da)) >> 8;
  }
  return ((c + 1) * fix) >> 8;
}

int blendChannel(int s, int d, int sa, int da, int fixA, int fixB) {
  uint op = (pc.blend >> 8) & 7u;
  if (op <= 2u) {
    int a = blendTerm(pc.blend & 15u, s, d, sa, da, fixA);
    int b = blendTerm((pc.blend >> 4) & 15u, d, s, sa, da, fixB);
    if (op == 0u)
      return a + b;
    return op == 1u ? a - b : b - a;
  }
  if (op == 3u)
    return min(s, d);
  if (op == 4u)
    return max(s, d);
  return abs(s - d);
}

// The colour's bits in the target format, and back to 8 bits.
uint encodeColor(ivec3 c, uint format) {
  uvec3 u = uvec3(c);
  if (format == 0u)
    return (u.r >> 3) | ((u.g >> 2) << 5) | ((u.b >> 3) << 11);
  if (format == 1u)
    return (u.r >> 3) | ((u.g >> 3) << 5) | ((u.b >> 3) << 10);
  if (format == 2u)
    return (u.r >> 4) | ((u.g >> 4) << 4) | ((u.b >> 4) << 8);
  return u.r | (u.g << 8) | (u.b << 16);
}

ivec3 decodeColor(uint p, uint format) {
  if (format == 0u) {
    uvec3 q = uvec3(p & 31u, (p >> 5) & 63u, (p >> 11) & 31u);
    return ivec3((q.r << 3) | (q.r >> 2), (q.g << 2) | (q.g >> 4), (q.b << 3) | (q.b >> 2));
  }
  if (format == 1u) {
    uvec3 q = uvec3(p & 31u, (p >> 5) & 31u, (p >> 10) & 31u);
    return ivec3((q << 3) | (q >> 2));
  }
  if (format == 2u)
    return ivec3(uvec3(p & 15u, (p >> 4) & 15u, (p >> 8) & 15u) * 17u);
  return ivec3(int(p & 255u), int((p >> 8) & 255u), int((p >> 16) & 255u));
}

uint logicOp(uint f, uint s, uint d) {
  switch (f) {
    case 0u: return 0u;
    case 1u: return s & d;
    case 2u: return s & ~d;
    case 3u: return s;
    case 4u: return ~s & d;
    case 5u: return d;
    case 6u: return s ^ d;
    case 7u: return s | d;
    case 8u: return ~(s | d);
    case 9u: return ~(s ^ d);
    case 10u: return ~d;
    case 11u: return s | ~d;
    case 12u: return ~s;
    case 13u: return ~s | d;
    case 14u: return ~(s & d);
  }
  return 0xFFFFFFFFu;
}

void main() {
  float zr;
  ivec4 c = shade(zr);
  ivec2 p = ivec2(gl_FragCoord.xy);
  uint format = (pc.flags >> 16) & 3u;
  if ((pc.blend & (1u << 23)) != 0u) {
    // The depth buffer holds Z / 65536.
    int old = int(round(texelFetch(uDepth, p, 0).r * 65536.0));
    if (!testFunc((pc.blend >> 20) & 7u, int(clamp(zr, 0.0, 65535.0)), old))
      discard;
  }
  if ((pc.blend & (1u << 27)) != 0u) {
    int st = int(texelFetch(uStencil, p, 0).r & 255u);
    int ref = int(pc.stencil & 255u);
    int mask = int((pc.stencil >> 8) & 255u);
    if (!testFunc((pc.blend >> 24) & 7u, ref & mask, st & mask))
      discard;
  }
  beginInvocationInterlockARB();
  vec4 dv = imageLoad(uTarget, p);
  uint oldBits = encodeColor(ivec3(round(dv.rgb * 255.0)), format);
  ivec3 d = decodeColor(oldBits, format);
  ivec3 r = c.rgb;
  if ((pc.blend & (1u << 11)) != 0u) {
    int da = format == 0u ? 0 : int(round(dv.a * 255.0));
    ivec3 fa = unpackRGB(pc.fixA);
    ivec3 fb = unpackRGB(pc.fixB);
    r = ivec3(blendChannel(c.r, d.r, c.a, da, fa.r, fb.r), blendChannel(c.g, d.g, c.a, da, fa.g, fb.g),
      blendChannel(c.b, d.b, c.a, da, fa.b, fb.b));
  }
  if ((pc.flags & FLAG_DITHER) != 0u)
    r += ditherAt();
  r = clamp(r, 0, 255);
  uint bits = encodeColor(r, format);
  if ((pc.blend & (1u << 16)) != 0u)
    bits = logicOp((pc.blend >> 12) & 15u, bits, oldBits);
  uint colorBits = encodeColor(ivec3(255), format);
  bits = ((bits & ~pc.keep) | (oldBits & pc.keep)) & colorBits;
  imageStore(uTarget, p, vec4(vec3(decodeColor(bits, format)) / 255.0, dv.a));
  endInvocationInterlockARB();
}
