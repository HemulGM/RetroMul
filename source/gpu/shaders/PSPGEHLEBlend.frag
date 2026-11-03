#version 450
// The HLE renderer's fragment shader that blends as the GE does (blend
// factors and rounding, dither after the blend, logic operations, bit masks),
// in primitive order through VK_EXT_fragment_shader_interlock.
#extension GL_ARB_fragment_shader_interlock : require
#define SHADER_BLEND
#include "PSPGEHLEFragment.glsl"
