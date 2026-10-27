// Generated from RM.BitmapShaders.hlsl by GenerateNativeShaders.ps1.
// FMX uses underscore-prefixed GLSL uniform names. Fragment highp is required.
#ifdef GL_ES
precision highp float;
precision highp int;
#endif
varying vec4 TEX0;
uniform sampler2D _Input;
uniform sampler2D _Target;
uniform vec4 _SourceSize;
uniform vec4 _OutputSize;
uniform vec4 _Controls;
uniform vec4 _ModeState;
uniform vec4 _LCDControls;
uniform vec4 _ColorControls;
#define SourceSize _SourceSize
#define OutputSize _OutputSize
#define Controls _Controls
#define ModeState _ModeState
#define LCDControls _LCDControls
#define ColorControls _ColorControls
float saturate(float x) { return clamp(x, 0.0, 1.0); }
vec2 saturate(vec2 x) { return clamp(x, 0.0, 1.0); }
vec3 saturate(vec3 x) { return clamp(x, 0.0, 1.0); }
vec4 samplePixel(vec2 uv)
{
    // Explicit texel centers preserve emulator pixels regardless of the FMX sampler.
    uv = (floor(uv * SourceSize.xy) + 0.5) / SourceSize.xy;
    // Quantization makes implicit derivatives discontinuous. Fix the LOD to
    // avoid derivative-dependent mip selection at texel/triangle boundaries.
    return texture2D(_Input, clamp(uv, 0.5 / SourceSize.xy,
        1.0 - 0.5 / SourceSize.xy), -1000.0);
}

vec4 bitmapEffect()
{
    // Raster pixel centers are identical on both triangles of the FMX quad.
    vec2 uv = (floor(TEX0.xy * OutputSize.xy) + 0.5) / OutputSize.xy;
    if (ModeState.x > 2.5)
    {
        vec4 pixel = samplePixel(uv);
        if (ModeState.x < 3.5)
        {
            if (ModeState.y > 0.5 && ModeState.y < 1.5)
            {
                vec2 center = (floor(uv * SourceSize.xy) + 0.5) / SourceSize.xy;
                vec4 history = texture2D(_Target, center, -1000.0);
                return mix(pixel, history, ModeState.z);
            }
            vec2 visible = saturate(OutputSize.xy / SourceSize.xy - 1.0);
            vec2 phase = fract(uv * SourceSize.xy + 0.5) - 0.5;
            vec2 grid = 0.5 + 0.5 * cos(6.28318530718 * phase);
            float shade = 1.0 - LCDControls.x * 0.6 *
                max(grid.x * visible.x, grid.y * visible.y);
            return vec4(pixel.rgb * shade, pixel.a);
        }
        // FMX stores premultiplied alpha: correct straight color, then premultiply.
        vec3 color = pixel.a > 0.0 ? saturate(pixel.rgb / pixel.a) : vec3(0, 0, 0);
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        color = mix(vec3(luminance), color, ColorControls.y);
        color *= vec3(1.0 + 0.2 * ColorControls.z, 1.0, 1.0 - 0.2 * ColorControls.z);
        color = pow(saturate(color), vec3(1.0 / ColorControls.x));
        return vec4(color * pixel.a, pixel.a);
    }
    vec2 p = uv * 2.0 - 1.0;
    vec2 warped = p;
    if (ModeState.x > 1.5)
        warped = p * (1.0 + Controls.y * p.yx * p.yx);
    vec2 coord = warped * 0.5 + 0.5;
    float inside = step(0.0, coord.x) * step(coord.x, 1.0)
        * step(0.0, coord.y) * step(coord.y, 1.0);
    vec4 color = samplePixel(coord);

    if (ModeState.x > 1.5)
    {
        // Small horizontal phosphor spread; no previous-frame history or latency.
        vec3 neighbors = samplePixel(coord - vec2(1.0 / SourceSize.x, 0)).rgb
            + samplePixel(coord + vec2(1.0 / SourceSize.x, 0)).rgb;
        color.rgb = mix(color.rgb, (color.rgb * 2.0 + neighbors) * 0.25, Controls.w);
    }

    // Fade at <= 1 output pixel per source row to suppress undersampling/moiré.
    float visibility = saturate(OutputSize.y / SourceSize.y - 1.0);
    // Keep the trigonometric argument in [-pi, pi] for stable GPU precision.
    float rowPhase = fract(coord.y * SourceSize.y + 0.5) - 0.5;
    float wave = 0.5 + 0.5 * cos(6.28318530718 * rowPhase);
    color.rgb *= 1.0 - Controls.x * visibility * wave;

    if (ModeState.x > 1.5)
    {
        // RGB aperture grille is tied to physical output pixels, not source pixels.
        float column = floor(uv.x * OutputSize.x);
        float phase = column - 3.0 * floor(column / 3.0);
        vec3 mask = vec3(phase < 0.5 ? 1.0 : 0.0, abs(phase - 1.0) < 0.5 ? 1.0 : 0.0, phase > 1.5 ? 1.0 : 0.0);
        color.rgb *= mix(vec3(1, 1, 1), 0.72 + mask * 0.28, Controls.z);
        float vignette = saturate(1.0 - 0.18 * dot(p * p, p * p));
        color.rgb *= vignette;
    }
    // Outside the curved screen is opaque black; inside retains premultiplied alpha.
    return vec4(color.rgb * inside, mix(1.0, color.a, inside));
}

void main() { gl_FragColor = bitmapEffect(); }
