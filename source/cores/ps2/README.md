# PlayStation 2 core (experimental)

A native Delphi PlayStation 2 core. It boots discs and homebrew without a
BIOS: the EE kernel, the IOP kernel and the IOP system modules are high level,
while the games' own IOP modules (sound drivers, streaming) run as IOP code.
Several commercial games reach gameplay; many still stop early or draw parts
of the picture wrongly.

## Layout

| Unit | Contents |
| --- | --- |
| `PS2.Types`, `PS2.Scheduler` | Constants, 128-bit registers, checked arithmetic helpers, the event scheduler in EE cycles |
| `PS2.EE.CPU`, `PS2.EE.Bus` | R5900 block interpreter (MMI, COP0, FPU with the PS2 float range, COP2 macro mode), EE memory map, INTC |
| `PS2.Timers`, `PS2.DMAC`, `PS2.SIF` | EE timers, DMA controller (chain/interleave/MFIFO), SIF registers and the SIF command/RPC protocol |
| `PS2.GS`, `PS2.GS.Memory`, `PS2.GS.Raster`, `PS2.GIF` | GS registers, swizzled local memory, software rasterizer (on the emulation thread or in band threads), GIF paths |
| `PS2.VU`, `PS2.VU.Float`, `PS2.VIF` | VU0/VU1 micro mode, the PS2 float product and sum for one or four fields (SSE2 on Win64, checked against the one-field routines by `tests/cores/ps2/vufloat/build.ps1`), VIF0/VIF1 command processing |
| `PS2.IPU` | IPU MPEG decoder (BDEC/IDEC/VDEC/FDEC/CSC/PACK, FIFOs on DMA channels 3/4) |
| `PS2.Kernel`, `PS2.ELF` | High-level EE kernel (threads, semaphores, interrupts, alarms, SIF DMA, syscall table) and ELF loading |
| `PS2.IOP.FileIO`, `PS2.IOP.CDVD`, `PS2.IOP.HLE` | FILEIO, CDVD and LOADFILE/IOP heap RPC servers, ISO 9660 access |
| `PS2.IOP.Pad`, `PS2.IOP.SIO2`, `PS2.IOP.MemoryCard` | DualShock 2 protocol, PADMAN/XPADMAN (pad data in libpad's areas), SIO2 for IOP pad and memory card drivers, MCSERV/XMCSERV (file-level memory cards), memory cards as flash for games' own card drivers |
| `PS2.IOP.CPU`, `PS2.IOP.Hardware` | IOP R3000A interpreter and the IOP register file (root counters, SPU2 registers and RAM, IOP DMA 4/7) |
| `PS2.IOP.Loader`, `PS2.IOP.Kernel`, `PS2.IOP.Libs` | IRX loading and linking, the high-level IOP kernel and the system libraries IOP modules import |
| `PS2.Console` | Wiring, field timing (NTSC/PAL), the run loop and snapshots |

`PS2.VU.Float` selects packed integer AVX2 arithmetic on Win64 only after
checking CPUID, OSXSAVE and XCR0; otherwise it retains SSE2. Both paths keep
the PS2 guard-bit, extended exponent, signed-zero and saturation rules.
`tests/cores/ps2/vufloat/build.ps1 -ForceSSE2` explicitly tests the fallback.
The tests cover all host rounding modes, exponent pairs and in-place results.
Under host round-to-zero, guarded normal-range operations use hardware floats
after explicit PS2 operand/guard-bit sanitization. Anything that could
underflow, overflow or use the PS2-only exponent range stays on integer AVX2;
other host rounding modes do too. This is not an approximate-math option.

Disc images come from `source/media/dvd/Core.DVD.Image.pas` (ISO, MDS/MDF,
DVD CHD, CD images through the CD layer). The front end lives in
`source/platforms/ps2/Core.Platforms.PS2.Adapter.pas` and
`source/platforms/ps2/RM.Platforms.PS2.Settings.pas`. Platform registration,
snapshot policy, presentation and controller integration live alongside them
in `RM.Platforms.PS2` and `RM.Platforms.PS2.Input`.

The GS draws on the emulation thread or, by default, in band threads (one per
two logical processors, 2..8): each draws every queued primitive's rows of
its 8-row stripes, in queue order. The emulation thread counts the pixels
(GS timing) and keeps queueing: where a primitive reads what queued ones
write (render to texture, a depth buffer written through another layout),
the band threads first finish the earlier commands (a barrier in the queue);
a primitive reading its own target, host-to-local and local-to-local
transfers and CLUT loads are done by the first band thread alone while the
others wait. Each queued primitive keeps its CLUT in a ring. The emulation
thread only waits for the bands when it reads GS memory itself (local-to-host
transfers, the display, snapshots). The memory is the same either way;
`PS2.GS.RaceCheck` (define `GS_RACECHECK`) reports GS memory words two band
threads touch in commands no barrier orders.

## What works

- Homebrew ELFs built with ps2sdk/gsKit run (see `codex-work/tests/autotests.ps1`
  for the ps2autotests results: CPU, FPU, MMI, DMA, SPR, GS, kernel threads
  and interrupts).
- Discs boot from `SYSTEM.CNF`; the EE kernel, SIF RPC, FILEIO, CDVD,
  LOADFILE, PADMAN and MCSERV answer the EE libraries.
- Game IOP modules load from the disc or from EE buffers, link against the
  high-level system libraries and run their threads, interrupt handlers and
  RPC servers on the emulated IOP.
- Snapshots cover the EE, GS, IOP and memory cards.

## Experimental VU1 recompiler

`Emulation/Execution=jit` selects the VU1 block recompiler; `interpreter`
(the default) uses the original execution path. This is independent of
`Video/Renderer` and can change during play. VU0 and EE remain interpreted.

The shared `HW.JIT` generator emits pipeline hazard checks, delayed flag
queues, register commits, VI arithmetic, branches, memory operations and
CLIP flag reads. Upper ADD/SUB/MUL/MADD/MSUB and cross products call the exact
four-field PS2 SIMD routines directly; uncommon operations retain interpreter
helpers. XGKICK still uses the shared packet reader with its original timing.
Code is generated after 16 visits in blocks of up to 16 pairs, ending after
branch/end delay slots. Compiled successors chain through a table within one
native frame. The general path checks the budget, PC, both instruction words
and decoded metadata at every pair; callback changes cannot run a stale pair.
Callback-free spans also have a statically scheduled path: it validates the
whole span, incoming dependency deadlines and pending queues before changing
guest state. Internal stalls and final register-ready times are constants;
flag-queue evolution is compiled symbolically, retaining exact stale tail
slots. Short budgets, trace capture, pending kicks/branches and unusual input
latencies fall back to per-pair execution. Division, CLIP/flag operations and
XGKICK are observation boundaries, not deferred across such a span.
Re-uploaded block versions are reused only after the entry address and every
word match (hashes alone are not trusted). The code arena is bounded to
32 MiB per VU1; resetting it clears the version and successor tables too.
None of this cache is saved in snapshots. Unsupported hosts keep interpreting.
The recompiler remains experimental and off by default.

`tests/cores/ps2/jit/build.ps1` runs a Win64 differential test against the
interpreter, using both the native backend and the portable generator model.
It covers code replacement (including an interior pair rewritten during
XGKICK), partial budgets, mode changes, memory, masked/overlapping registers,
traces, delayed flags, loop/call chaining, cache exhaustion and re-uploaded
versions with deliberately colliding hashes. Both backends must match the
interpreter's state, including scheduled spans with pending Q/P and poisoned
live/unused flag queues. `-Checked` enables checked core code.

## Experimental Vulkan GS

`Video/Renderer=vulkan` independently selects Vulkan compute for supported
32/24-bit sprites and triangle pixels, including all GS direct and palettized
texture formats and mipmapping. This uses `RM.Vulkan.Compute` from the Xbox branch (3f3ce45), with
coherent GS VRAM import. Small draws, texture feedback,
overlapping surfaces and unsupported storage
formats retain the software path. If device creation or host-memory import
is unavailable, software rendering continues; `VulkanError` reports why.
The default remains multithreaded software rendering.

The integer shader implements alpha/depth tests, fog, blending, destination
alpha, masks, texture functions and 24-bit preservation. Sprite UV/STQ
interpolation stays on the CPU with the software renderer's arithmetic;
integer coordinates are uploaded per column/row. The GPU performs exact
integer filtering and sampling, including all clamp/repeat modes and TEXA.
Each queued draw keeps a CLUT snapshot (including 16-bit palettes and CSA).
Texture swizzle tables are generated from `PS2.GS.Memory`. LOD selection and
the 4-bit inter-level weight are computed on the CPU with the same rounding
as the software path; the GPU samples the chosen levels and blends integers.
Triangle safety checks conservatively cover all potentially used levels.
Triangles keep the software edge walker, clipping and attribute interpolation
on the host; the GPU consumes the exact integer fragments for texture sampling,
tests, blending and writes. A 65536-fragment arena is split and synchronized
when full, including in the middle of one triangle.
Up to 128 draw commands are recorded with
separate parameter slots and ordered by compute memory barriers. Pending
work finishes before CPU drawing, transfers, palette loads, display reads,
reset, snapshots and mode changes. This is not a complete or consistently
faster GPU renderer. It does not require
JIT. GS saves contain the same VRAM and state in either mode.

Regenerate its embedded SPIR-V with `source/cores/ps2/shaders/build.ps1`
(Vulkan SDK `glslc` required). Application builds use the checked-in include.
`tests/cores/ps2/gpu/build.ps1` compares 256 isolated draws and a dependent
256-draw sequence, with and without textures, against the CPU over all
4 MiB of VRAM. It checks batch capacity/reuse, texture feedback fallback,
render-to-texture ordering, transfers, CLUT state and live mode changes.
Another 256 triangles cover winding, clipping, flat/Gouraud colours, UV/STQ,
both host rounding modes, varying depth/fog and fragment-arena rollover.
An additional 312 cases cover all 13 texture formats, CLUT/CSA/CSM/TEXA,
all minification modes, multiple mip levels, sprites and triangles. A separate
test mutates the host CLUT while two draws are pending in the same GPU batch.
It requires a Vulkan device with coherent host-memory import.

## Limits

- No BIOS boot (OSDSYS); the GS rasterizer is a software renderer without
  upscaling.
- Memory cards are kept in one file per card in the save folder (not as raw
  `.ps2` card images). Games using the system card modules see the card at
  the file level; games bringing their own card driver (MCMAN over SIO2) see
  it as flash memory, created formatted and empty, which the same file keeps.
  The two views do not share saves. MagicGate authentication is skipped.
- HDD, network, USB and i.LINK modules are reported as loaded but do nothing.

## References and licences

- No code from other emulators. References: ps2tek (hardware, BIOS syscalls,
  SIO2, controller protocol); ps2sdk (AFL 2.0) headers and its open
  reimplementations of the IOP modules (padman, mcman, mcserv, cdvdfsv,
  cdvdstm, loadcore, loadfile, threadman, sifcmd, sio2man...) for RPC
  protocols, data layouts, result codes and relocation rules.
- `PS2.IPU` is written from ISO/IEC 13818-2 (syntax, Annex B tables, inverse
  quantisation, IDCT), ITU-R BT.601 (colour conversion), the IPU description in
  ps2tek and the way ps2sdk's libmpeg drives the unit. It is checked against
  ffmpeg (`codex-work/tests/iputest.ps1`).
- ps2autotests for testing.
- PCSX2, DobieStation and similar GPL projects were used only as
  documentation of hardware behaviour; no code was taken from them.
- No Sony SDK or firmware code is included. BIOS images are never part of the
  repository.
