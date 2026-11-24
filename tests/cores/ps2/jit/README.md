# PS2 VU JIT tests

Run the differential, directed MIN/MAX and branch-stall suites:

```powershell
.\build.ps1
.\build.ps1 -Checked -Out D:\Work\tmp\ps2-vujit-checked
.\build.ps1 -Defines PS2_FORCE_SSE2 -Out D:\Work\tmp\ps2-vujit-sse2
```

`PS2VUSelectTest` compares raw-bit `PS2FloatKey` MIN/MAX selection against
the model and native integer-SIMD register kernels. It covers edge/random
values, rounding modes, FTZ/DAZ and unchanged MXCSR. Microprograms cover
vector/component/I forms, masks, overlapping writes, run budgets and unsafe
buffer aliases. Each exact opcode is repeated past the JIT heat threshold;
existing vector-operation counters verify that the new emitter is exercised.

The interpreter and unsafe-alias path stay scalar. Native availability uses
the existing AVX2 gate; forced SSE2 checks the scalar fallback. These are
current-model differential tests, not independent hardware-accuracy or
whole-emulator performance measurements.

`PS2VUBranchStallTest` checks that an interlocked FMAC stall makes the
preceding integer result visible to a conditional branch, while an unstalled
adjacent branch still reads the old value. It covers all six conditional
branches, both equality operand positions, three integer writers, one to three
stall cycles, disjoint fields, loop timing and split run budgets. Interpreter,
native scheduled, model and general JIT paths are exercised past compilation
heat thresholds. Expected outcomes are directed pipeline checks rather than
comparisons with another emulator.
