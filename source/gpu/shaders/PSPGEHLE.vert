#version 450
// The HLE renderer's vertices come transformed, lit and clipped by the GE
// engine: positions in PSP pixels of the target, raw depth (0..65535 when in
// range), colours, texture coordinates already times 1/w, fog. Everything is
// interpolated linearly on the screen, as the GE does; the fragment shader
// divides the coordinates by their q.

#include "PSPGEHLEPush.glsl"

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec4 aColor;
layout(location = 2) in vec4 aSecondary;
layout(location = 3) in vec4 aSTQW;
layout(location = 4) in float aFog;
layout(location = 5) in vec4 aBox;

layout(location = 0) noperspective out vec4 vColor;
layout(location = 1) noperspective out vec3 vSecondary;
layout(location = 2) noperspective out vec4 vSTQW;
layout(location = 3) noperspective out float vFog;
layout(location = 4) noperspective out float vZ;
layout(location = 5) flat out vec4 vBox;

void main() {
  // The fragment shader writes the depth: nothing is clipped by it here.
  gl_Position = vec4(aPos.x * pc.ndcScale.x - 1.0, aPos.y * pc.ndcScale.y - 1.0, 0.5, 1.0);
  gl_PointSize = float((pc.flags >> 24) & 15u);
  vColor = aColor;
  vSecondary = aSecondary.rgb;
  vSTQW = aSTQW;
  vFog = aFog;
  vZ = aPos.z;
  vBox = aBox;
}
