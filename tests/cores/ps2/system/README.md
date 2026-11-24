# PS2 system tests (Win64)

```powershell
.\build.ps1
.\build.ps1 -Checked -Out D:\Work\tmp\ps2-system-checked
```

The script runs the existing clock/snapshot/VIF/DMAC/IOP integration suite
and `PS2GIFDirectTest`. The latter compares bulk DIRECT/DIRECTHL against the
existing word-feed reference, using `PS2VIFRuns` only in the test process.

It covers split words/quads, private VIF staging, PACKED/odd REGLIST/IMAGE
streams, 65536-quad commands, ring wrap, changing time/MXCSR, zero/four GS
bands, synchronous fallback, capture mode, unsafe aliases and interleaved
PATH1. SIGNAL/FINISH guest IRQ time/state and callback thread are checked;
complete VIF state is compared after each feed piece. Owned consumer runs
retain the original busy timeline at entry boundaries and keep IRQ writes
synchronous. No production measurement switch or counter is required.
These are current-model correctness tests, not a game
performance benchmark or new hardware reference.

`PS2VIFReadbackTest` checks reverse VIF1 DMA against an independently packed
GS local-to-host stream in all 13 pixel formats. It covers partial transfers,
empty reads without zero-filling RAM, RAM invalidation and DMA bus time,
snapshot read-cursor restoration, buffered data after VRAM changes, and
pending draws with zero/four bands and asynchronous GS drawing. It also
includes the two 256x256 PSMCT32 readbacks used to preserve FFX textures.
Empty DMA retries, including at address zero, must not invalidate RAM pages.

`PS2GIFImageRunTest` compares IMAGE runs with per-quadword feeds in all 13
formats, including 24-bit carries, HWREG prefixes, partial/ignored tails,
ring wrap, PATH3 burst times and aliases of local memory and object state.

`PS2GIFOwnedRunTest` compares complete GS/GIF/VRAM and raw busy timelines
against the existing diagnostic per-quadword consumer. It covers PATH1 and
PATH2, IMAGE data, SIGNAL/FINISH IRQ state/time/thread, mixed rounding modes,
last-vertex pending pixels and counter-wrap fallback.
