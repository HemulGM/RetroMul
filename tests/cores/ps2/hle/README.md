# PS2 HLE enhancement tests

Requires a Vulkan graphics device supporting the PS2 HLE renderer.

```powershell
.\build.ps1
.\build.ps1 -Checked -Out D:\Work\tmp\ps2-hle-checked
```

- `PS2HLEScaleTest`: 1/2/3/4/6/8x, direct and GS-worker rendering. A diagonal
  has distinct subpixels within a native pixel, so stretching 1x cannot pass.
  The serialized GS layout remains independent of the chosen host resolution.
- `PS2HLESpriteCoverageTest`: fullscreen clears, fractional and reversed
  sprites, clipped scissors at 1/2/3/4/6/8x, direct and worker rendering.
  Every covered native pixel must have all its subpixels painted; no stale
  bright border may survive a black fullscreen clear.
- `PS2HLESubpixelTriangleTest`: vertical, horizontal and tiny quads made of
  triangles with empty native sample bounds, including reversed winding,
  at 1/2/3/4/6/8x in direct and worker rendering. Scaled samples must not be
  discarded by native-resolution bounds.
- `PS2HLEDepthRowTest`: depth upload rows against the original scalar
  conversion, four formats and host rounding modes, D32/D24, VRAM wrap,
  row bounds, exhaustive 16-bit values, 32-bit exponent boundaries, aliased
  read/write ordering and unmasked precision-exception write ordering.
- `PS2HLETextureScaleTest`: xBRZ, Hybrid and Bicubic GPU output against the
  shared CPU scaler, factors 2..6, equal/unequal render scales, unchanged guest
  texture memory. Sampling fixtures avoid ambiguous nearest-filter FP32 ties.
- `PS2HLECoherenceTest`: colour/depth formats, native resolves, CPU writes,
  PMODE dual-circuit mixing, callback metadata and renderer transitions.
- `PS2HLEDynamicTextureTest`: frequently changing source data becomes native,
  without stale images, for every filter and direct/worker rendering.
- `PS2HLEConfigTest`: defaults, clamps, filter names and INI round trips;
  screen Scale/Filter keys remain separate. Writes only its supplied directory.
- `PS2HLEChangedRowsTest`: the changed page-row bands a target reload takes,
  against per-band expectations, run limits, VRAM wrap and forced depth bands.
- `VulkanHLEEqualBytesTest`: the AVX2 memory comparison against `CompareMem`,
  all alignments and tails, guard-page ranges and an unchanged MXCSR.
- `PS2HLEColorUploadTest`, `PS2HLEDepthUploadTest`: target colour (every frame
  format) and 24/16-bit depth loaded on the GPU then resolved to the same GS
  memory at 1..8x in four host rounding modes, including exhaustive 16-bit
  values and VRAM wrap. `-require-gpu` fails unless the GPU path ran (D24
  depth devices keep the CPU path).

These are HLE enhancement/coherence checks, not a bit-exact hardware or FPS
claim. At 1x with texture scaling off, the legacy GS rendering path is retained.
No game data, external emulator or reference capture is a test dependency.
