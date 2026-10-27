// FMX filter vertex shader supplies normalized TEXCOORD0.
// Constants occupy complete 16-byte registers, matching FMX's variable binding.
Texture2D Input : register(t0);
SamplerState InputSampler : register(s0);
Texture2D Target : register(t1);
SamplerState TargetSampler : register(s1);
cbuffer Parameters : register(b0)
{
    float4 SourceSize : packoffset(c0); // xy = source pixel dimensions
    float4 OutputSize : packoffset(c1); // xy = physical output dimensions
    float4 Controls : packoffset(c2);   // scanline strength, curvature, mask, glow
    float4 ModeState : packoffset(c3); // mode: 1 scanlines, 2 CRT, 3 LCD, 4 color; y=response pass, z=history weight
    float4 LCDControls : packoffset(c4); // grid strength
    float4 ColorControls : packoffset(c5); // gamma, saturation, temperature
};

float4 samplePixel(float2 uv)
{
    // Explicit texel centers preserve emulator pixels regardless of the FMX sampler.
    uv = (floor(uv * SourceSize.xy) + 0.5) / SourceSize.xy;
    // Quantization makes implicit derivatives discontinuous. Fix the LOD to
    // avoid derivative-dependent mip selection at texel/triangle boundaries.
    return Input.SampleLevel(InputSampler, clamp(uv, 0.5 / SourceSize.xy,
        1.0 - 0.5 / SourceSize.xy), 0);
}

float4 main(float4 position : SV_Position) : SV_Target
{
    // Raster pixel centers are identical on both triangles of the FMX quad.
    float2 uv = position.xy / OutputSize.xy;
    if (ModeState.x > 2.5)
    {
        float4 pixel = samplePixel(uv);
        if (ModeState.x < 3.5)
        {
            if (ModeState.y > 0.5 && ModeState.y < 1.5)
            {
                float2 center = (floor(uv * SourceSize.xy) + 0.5) / SourceSize.xy;
                float4 history = Target.SampleLevel(TargetSampler, center, 0);
                return lerp(pixel, history, ModeState.z);
            }
            float2 visible = saturate(OutputSize.xy / SourceSize.xy - 1.0);
            float2 phase = frac(uv * SourceSize.xy + 0.5) - 0.5;
            float2 grid = 0.5 + 0.5 * cos(6.28318530718 * phase);
            float shade = 1.0 - LCDControls.x * 0.6 *
                max(grid.x * visible.x, grid.y * visible.y);
            return float4(pixel.rgb * shade, pixel.a);
        }
        // FMX stores premultiplied alpha: correct straight color, then premultiply.
        float3 color = pixel.a > 0 ? saturate(pixel.rgb / pixel.a) : float3(0, 0, 0);
        float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = lerp(luminance.xxx, color, ColorControls.y);
        color *= float3(1.0 + 0.2 * ColorControls.z, 1.0, 1.0 - 0.2 * ColorControls.z);
        color = pow(saturate(color), 1.0 / ColorControls.x);
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
        color.rgb = lerp(color.rgb, (color.rgb * 2.0 + neighbors) * 0.25, Controls.w);
    }

    // Fade at <= 1 output pixel per source row to suppress undersampling/moiré.
    float visibility = saturate(OutputSize.y / SourceSize.y - 1.0);
    // Keep the trigonometric argument in [-pi, pi] for stable GPU precision.
    float rowPhase = frac(coord.y * SourceSize.y + 0.5) - 0.5;
    float wave = 0.5 + 0.5 * cos(6.28318530718 * rowPhase);
    color.rgb *= 1.0 - Controls.x * visibility * wave;

    if (ModeState.x > 1.5)
    {
        // RGB aperture grille is tied to physical output pixels, not source pixels.
        float column = floor(uv.x * OutputSize.x);
        float phase = column - 3.0 * floor(column / 3.0);
        float3 mask = float3(phase < 0.5, abs(phase - 1.0) < 0.5, phase > 1.5);
        color.rgb *= lerp(float3(1, 1, 1), 0.72 + mask * 0.28, Controls.z);
        float vignette = saturate(1.0 - 0.18 * dot(p * p, p * p));
        color.rgb *= vignette;
    }
    // Outside the curved screen is opaque black; inside retains premultiplied alpha.
    return float4(color.rgb * inside, lerp(1.0, color.a, inside));
}
