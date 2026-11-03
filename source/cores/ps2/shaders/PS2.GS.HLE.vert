#version 450
// The GS HLE renderer's vertices: positions in target pixels (the GS samples
// at whole pixel coordinates, the GPU at pixel centres: they come half a
// pixel on), depth as a fraction of the buffer's range, colours, texture
// coordinates in 1/16 texels (or S, T times the texture's size in 1/16
// texels with Q), the Q the LOD is taken from and fog. Everything is
// interpolated linearly on the screen, as the GS does.

#include "PS2.GS.HLEPush.glsl"

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec4 aColor;
layout(location = 2) in vec3 aSTQ;
layout(location = 3) in vec2 aLodFog;

layout(location = 0) noperspective out vec4 vColor;
layout(location = 1) noperspective out vec3 vSTQ;
layout(location = 2) noperspective out vec2 vLodFog;

void main() {
  gl_Position = vec4(aPos.x * pc.ndcScale.x - 1.0, aPos.y * pc.ndcScale.y - 1.0, aPos.z, 1.0);
  vColor = aColor;
  vSTQ = aSTQ;
  vLodFog = aLodFog;
}
