// Generated from RM.BitmapShaders.hlsl by GenerateNativeShaders.ps1.
#include <metal_stdlib>
using namespace metal;
struct ProjectedVertex { float4 position [[position]]; float2 textureCoord; };
float4 samplePixelMetal(float2 uv, float2 size, texture2d<float> Input, sampler InputSampler)
{
    // Explicit texel centers preserve emulator pixels regardless of the FMX sampler.
    uv = (floor(uv * size) + 0.5) / size;
    // Quantization makes implicit derivatives discontinuous. Fix the LOD to
    // avoid derivative-dependent mip selection at texel/triangle boundaries.
    return Input.sample(InputSampler, clamp(uv, 0.5 / size,
        1.0 - 0.5 / size), level(0));
}

#define samplePixel(uv) samplePixelMetal(uv, SourceSize.xy, Input, InputSampler)
fragment float4 fragmentShader(const ProjectedVertex in [[stage_in]],
    constant float4 &SourceSize [[buffer(0)]],
    constant float4 &OutputSize [[buffer(1)]],
    constant float4 &Controls [[buffer(2)]],
    constant float4 &ModeState [[buffer(3)]],
    constant float4 &LCDControls [[buffer(4)]],
    constant float4 &ColorControls [[buffer(5)]],
    texture2d<float> Input [[texture(0)]], sampler InputSampler [[sampler(0)]],
    texture2d<float> Target [[texture(1)]], sampler TargetSampler [[sampler(1)]])
{
    // Raster pixel centers are identical on both triangles of the FMX quad.
    float2 uv = in.position.xy / OutputSize.xy;
    if (ModeState.x > 2.5)
    {
        float4 pixel = samplePixel(uv);
        if (ModeState.x < 3.5)
        {
            if (ModeState.y > 0.5 && ModeState.y < 1.5)
            {
                float2 center = (floor(uv * SourceSize.xy) + 0.5) / SourceSize.xy;
                float4 history = Target.sample(TargetSampler, center, level(0));
                return mix(pixel, history, ModeState.z);
            }
            float2 visible = saturate(OutputSize.xy / SourceSize.xy - 1.0);
            float2 phase = fract(uv * SourceSize.xy + 0.5) - 0.5;
            float2 grid = 0.5 + 0.5 * cos(6.28318530718 * phase);
            float shade = 1.0 - LCDControls.x * 0.6 *
                max(grid.x * visible.x, grid.y * visible.y);
            return float4(pixel.rgb * shade, pixel.a);
        }
        // FMX stores premultiplied alpha: correct straight color, then premultiply.
        float3 color = pixel.a > 0 ? saturate(pixel.rgb / pixel.a) : float3(0, 0, 0);
        float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = mix(float3(luminance), color, ColorControls.y);
        color *= float3(1.0 + 0.2 * ColorControls.z, 1.0, 1.0 - 0.2 * ColorControls.z);
        color = pow(saturate(color), float3(1.0 / ColorControls.x));
        return float4(color * pixel.a, pixel.a);
    }
    float2 p = uv * 2.0 - 1.0;
    float2 warped = p;
    if (ModeState.x > 1.5)
        warped = p * (1.0 + Controls.y * p.yx * p.yx);
    float2 coord = warped * 0.5 + 0.5;
    float inside = step(0.0, coord.x) * step(coord.x, 1.0)
        * step(0.0, coord.y) * step(coord.y, 1.0);
    float4 color = samplePixel(coord);

    if (ModeState.x > 1.5)
    {
        // Small horizontal phosphor spread; no previous-frame history or latency.
        float3 neighbors = samplePixel(coord - float2(1.0 / SourceSize.x, 0)).rgb
            + samplePixel(coord + float2(1.0 / SourceSize.x, 0)).rgb;
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
        float3 mask = float3(phase < 0.5 ? 1.0 : 0.0, abs(phase - 1.0) < 0.5 ? 1.0 : 0.0, phase > 1.5 ? 1.0 : 0.0);
        color.rgb *= mix(float3(1, 1, 1), 0.72 + mask * 0.28, Controls.z);
        float vignette = saturate(1.0 - 0.18 * dot(p * p, p * p));
        color.rgb *= vignette;
    }
    // Outside the curved screen is opaque black; inside retains premultiplied alpha.
    return float4(color.rgb * inside, mix(1.0, color.a, inside));
}
