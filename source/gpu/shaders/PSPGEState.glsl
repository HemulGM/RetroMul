// A TGERaster as PSP.GE.VulkanLLE packs it: 128 words per state, integers as
// their two's complement bits.
const uint ST_FBADDR = 0u;
const uint ST_FBSTRIDE = 1u;
const uint ST_FBFORMAT = 2u;
const uint ST_ZADDR = 3u;
const uint ST_ZSTRIDE = 4u;
const uint ST_SCISSORX1 = 5u;
const uint ST_SCISSORY1 = 6u;
const uint ST_SCISSORX2 = 7u;
const uint ST_SCISSORY2 = 8u;
const uint ST_BANDY1 = 9u;
const uint ST_BANDY2 = 10u;
const uint ST_FLAGS = 11u;
const uint ST_TEXFUNC = 12u;
const uint ST_ENVR = 13u;
const uint ST_ENVG = 14u;
const uint ST_ENVB = 15u;
const uint ST_FOGR = 16u;
const uint ST_FOGG = 17u;
const uint ST_FOGB = 18u;
const uint ST_COLORTESTFUNC = 19u;
const uint ST_COLORREF = 20u;
const uint ST_COLORMASK = 21u;
const uint ST_ALPHAFUNC = 22u;
const uint ST_ALPHAREF = 23u;
const uint ST_ALPHAMASK = 24u;
const uint ST_STENCILFUNC = 25u;
const uint ST_STENCILREF = 26u;
const uint ST_STENCILMASK = 27u;
const uint ST_STENCILFAIL = 28u;
const uint ST_STENCILZFAIL = 29u;
const uint ST_STENCILZPASS = 30u;
const uint ST_DEPTHFUNC = 31u;
const uint ST_MINZ = 32u;
const uint ST_MAXZ = 33u;
const uint ST_BLENDOP = 34u;
const uint ST_BLENDSRC = 35u;
const uint ST_BLENDDST = 36u;
const uint ST_FIXA = 37u;
const uint ST_FIXB = 38u;
const uint ST_LOGICFUNC = 39u;
const uint ST_MASKRGB = 40u;
const uint ST_MASKA = 41u;
const uint ST_DITHER = 42u; // 16 words
const uint ST_TEXFORMAT = 58u;
const uint ST_TEXSWIZZLE = 59u;
const uint ST_TEXLEVEL = 60u;
const uint ST_TEXCLAMPU = 61u;
const uint ST_TEXCLAMPV = 62u;
const uint ST_TEXLINEAR = 63u;
const uint ST_CLUTFORMAT = 64u;
const uint ST_CLUTSHIFT = 65u;
const uint ST_CLUTMASK = 66u;
const uint ST_CLUTOFFSET = 67u;
// Where texels come from: 0 = the VRAM buffer, 1 = a copy at TEXDATA of the
// guest bytes from TEXBASE on.
const uint ST_TEXSOURCE = 68u;
const uint ST_TEXBASE = 69u;
const uint ST_TEXDATA = 70u;
const uint ST_CLUTDATA = 71u;
const uint ST_LEVELS = 72u; // 8 x (address, width, height, buffer width)
const uint ST_KEEPMASK = 104u;
const uint ST_ZPERMUTATION = 105u;
const uint ST_VRAMSHIFT = 106u;
// Per level, where its texels come from: NO_DATA for the VRAM buffer, else
// the offset in the data buffer of a copy of the guest bytes from its address.
const uint ST_LEVELDATA = 107u; // 8 words
const uint ST_MINFILTER = 115u;
const uint ST_MAXLEVEL = 116u;
const uint ST_LEVELMODE = 117u;
const uint ST_LODBIAS = 118u;
const uint ST_SLOPE = 119u; // float bits
const uint ST_CLUTSTEP = 120u; // a CLUT per level: level L's indices + L x this
const uint NO_DATA = 0xFFFFFFFFu;

const uint SF_THROUGH = 1u << 0;
const uint SF_CLEARMODE = 1u << 1;
const uint SF_CLEARCOLOR = 1u << 2;
const uint SF_CLEARSTENCIL = 1u << 3;
const uint SF_CLEARDEPTH = 1u << 4;
const uint SF_FLAT = 1u << 5;
const uint SF_GOURAUD = 1u << 6;
const uint SF_TEXTURED = 1u << 7;
const uint SF_TEXALPHA = 1u << 8;
const uint SF_COLORDOUBLE = 1u << 9;
const uint SF_FOGENABLED = 1u << 10;
const uint SF_COLORTEST = 1u << 11;
const uint SF_ALPHATEST = 1u << 12;
const uint SF_STENCILTEST = 1u << 13;
const uint SF_DEPTHTEST = 1u << 14;
const uint SF_DEPTHWRITE = 1u << 15;
const uint SF_BLEND = 1u << 16;
const uint SF_DITHER = 1u << 17;
const uint SF_LOGICOP = 1u << 18;
const uint SF_DEPTHCLAMP = 1u << 19;
// TGETexture.NeedLod: sampled through GESampleTextureLod.
const uint SF_NEEDLOD = 1u << 20;

int stInt(uint s, uint index)
{
  return int(states[s + index]);
}

uint stUint(uint s, uint index)
{
  return states[s + index];
}

bool stFlag(uint s, uint flag)
{
  return (states[s + ST_FLAGS] & flag) != 0u;
}

int stDither(uint s, int index)
{
  return int(states[s + ST_DITHER + uint(index)]);
}

uint stLevelAddr(uint s, int level)
{
  return states[s + ST_LEVELS + uint(level) * 4u];
}

int stLevelWidth(uint s, int level)
{
  return int(states[s + ST_LEVELS + uint(level) * 4u + 1u]);
}

int stLevelHeight(uint s, int level)
{
  return int(states[s + ST_LEVELS + uint(level) * 4u + 2u]);
}

int stLevelBufWidth(uint s, int level)
{
  return int(states[s + ST_LEVELS + uint(level) * 4u + 3u]);
}
