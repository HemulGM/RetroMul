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
| `PS2.EE.CPU`, `PS2.EE.Bus` | R5900 block interpreter (MMI, COP0, FPU with the PS2 float range, COP2 macro mode) and its experimental recompiler (`PS2.EE.Jit.inc`), EE memory map, INTC |
| `PS2.Timers`, `PS2.DMAC`, `PS2.SIF` | EE timers, DMA controller (chain/interleave/MFIFO, stall control through D_STADR), SIF registers and the SIF command/RPC protocol |
| `PS2.GS`, `PS2.GS.Memory`, `PS2.GS.Raster`, `PS2.GIF` | GS registers, swizzled local memory, software rasterizer (on the emulation thread or in band threads, its front end optionally on a thread of its own), GIF paths (VU1 kicks and PATH2 optionally on a thread of their own) |
| `PS2.VU`, `PS2.VU.Float`, `PS2.VIF` | VU0/VU1 micro mode, the PS2 float product and sum for one or four fields (SSE2 on Win64, checked against the one-field routines by `tests/cores/ps2/vufloat/build.ps1`), VIF0/VIF1 command processing, interrupt-bit/STOP/force-break stalls with the FIFO held (8/16 quadwords), VU busy windows |
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
others wait. These decisions use the pages a primitive can actually touch:
its pixel rectangle and the texels its UV/STQ range reaches through the wrap
modes. Reading its own buffer counts as feedback only where the texel and
pixel rectangles meet (same layout, distinct addresses), not for sprites
whose pixels each read their own place, nor for point-sampled triangles whose
UV (or STQ of one Q) lies within (0.01, 0.99) of a texel past each vertex
(every pixel's coordinate is a convex combination of those: its own texel),
nor for 8H/4HL/4HH texels under a
24-bit frame or depth buffer (which keep the high byte). Idle band threads are
woken in batches (by queued pixels) rather than per command. Each queued primitive keeps its CLUT in a ring. The emulation
thread only waits for the bands when it reads GS memory itself (local-to-host
transfers, the display, snapshots). The memory is the same either way;
`PS2.GS.RaceCheck` (define `GS_RACECHECK`) reports GS memory words two band
threads touch in commands no barrier orders.
The timing counter counts exact covered row spans without shading a second
copy of every pixel. Software pixels rejected by depth skip texture reads;
coverage/busy counters still include them, so emulated GS timing is unchanged.
A software sprite sampling one texture level splits its texels' swizzled
addresses into per-column and per-row parts (clamped coordinates and
filter weights included), computed once per column and per row;
`tests/cores/ps2/gsdata` compares 800 random sprites (every texture format,
clamp mode, filter and LOD setting) against the general sampler. Such
sprites of 32-bit frames and textures (32/24-bit depth) are shaded a row at
a time (`SpriteRows`): the frame's and depth buffer's addresses from parts
as well, the same steps per pixel in the same order (a pixel may read what
the ones before it wrote: self-reading blur passes, drawn by one band thread
alone). The test compares 1200 such sprites, half textured from their own
frame, both ways. Local-to-local transfers take their addresses from row
and column parts too (`CopyRows`; 32-bit words moved as they are), the same
pixels in the same order; the test compares 800 of them (all format pairs,
strides, wrap, overlapping source and destination) both ways.

With `TPS2GSRaster.Async` (the front end sets it for the multithreaded and
Vulkan renderers on hosts with four or more logical processors; x64 Windows)
the GS front end runs on a thread of its own as well (`TPS2GSWorker`). The
emulation thread's raster keeps the registers, assembles primitives, counts
their pixels and transfer progress for the timing and raises SIGNAL/FINISH,
and queues every register write and IMAGE quadword in order. A second raster
on the worker thread, sharing the GS memory, replays them: CLUT loads,
transfers, routing between the GPU and the band threads, their barriers and
waits. Each vertex kick carries the emulation thread's SSE control word
(rounding, flush-to-zero, denormals-are-zero), which the worker loads before
drawing, so the arithmetic matches the emulation thread's. The worker
publishes its progress every 64 entries, after the last one queued and at
every entry while the emulation thread waits; a full queue waits for a
sixteenth of it to drain (counters handed back and forth per entry cost both
threads a cache line each time). The emulation
thread waits for the worker only when it reads GS memory (local-to-host
transfers, snapshots) or changes the renderer. The display at VBlank
(`MemoryFor`) waits only when queued work may still write its pages: the
emulation thread keeps, per page, the last queued entry that may write it
(primitive rectangles, transfer areas), and the worker publishes how many
entries have no band or GPU work left; usually the shown buffer was finished
a frame earlier and the worker goes on drawing the next one meanwhile. The
picture itself is built off the emulation thread (`TPS2GS.BuildFrame`): the
display registers are taken at VBlank, the shown pages are copied into one of
two snapshots of GS memory (by the emulation thread when they are drawn
already, else by the worker once it gets there, a read entry in its queue
that syncs the bands and GPU only where `MemoryFor` would wait), and a
composer thread (`TPS2GSComposer`) merges the circuits from the snapshot and
hands the picture to `OnFrame` (the front end shows it from there). `Frame`
waits for the last picture asked for. FFX gains 15%, Colossus 6%. Frames,
snapshots and timing are identical with and without it; diagnostics logs
(primitive, transfer, watched pixel) keep everything on the emulation thread.
`tests/cores/ps2/gsdata` and `tests/cores/ps2/gpu` (also with `-Async`) cover
the asynchronous raster against the synchronous one.

With `TPS2GIF.Threaded` as well (the front end sets it with `Async`), the
emulation thread does not run that front raster for VU1's XGKICK packets and
VIF1 DIRECT (PATH2) quadwords either: it copies them into a ring and a kick
thread (`TPS2GIFKicker`) feeds them to the GIF and the GS in order, each at the
EE time it came (the GIF's clock for the drawing timeline) and with the
emulation thread's SSE control word of that moment, while VU1 and the EE go
on. Anything else that reaches the GIF or the GS (PATH3, GIF and GS
registers, the busy time DMA and VIF ask for, VBlank, snapshots, FINISH
events, renderer changes) first waits for the kick thread to finish what it
was given (`TPS2GIF.Join`), so the GIF and the GS see the same sequence at the
same EE times. Only data that cannot reach the EE is handed over: a packet
must end with EOP inside VU memory with PATH1 between packets, no A+D write may
go to SIGNAL or FINISH, and no GS event may be pending that a register write
would raise as an interrupt (`TPS2GS.WriteInterrupts`; one already raised in
INTC changes nothing); for PATH2 the emulation thread follows the GIF tags
itself (`NextDirect`). Anything else goes the synchronous way.

## What works

- Homebrew ELFs built with ps2sdk/gsKit run (see `codex-work/tests/autotests.ps1`
  for the ps2autotests results: CPU, FPU, MMI, DMA, SPR, GS, kernel threads
  and interrupts). The IOP tests (`.irx`) start on the IOP alone
  (`TPS2Console.LoadIOPModule`). All 23 pass: the IOP CPU and the
  high-level kernel's threads, event flags, message boxes, interrupt handlers,
  variable pools and libc. The IOP interpreter finds each instruction's
  procedure through a table by opcode, reaches RAM at once in loads and
  stores, and runs a loop of its own without what only BIOS boot has
  (interrupts, address errors, BIOS fetches); `tests/cores/ps2/iopcpu`
  compares it over 3000 random programs (HLE and BIOS mode, delay slots,
  mirrors, devices, traps) with a copy of the core as it was.
- The high-level IOP kernel follows those hardware results. That covers
  thread call errors and rules, wait types, waiters released with
  KE_WAIT_DELETE or KE_RELEASE_WAIT, and message boxes as the kernel's ring of
  messages ordered by MBA_MSPRI. heaplib heaps and variable pools live in IOP
  memory with SCE heaplib's layout: 8-byte fragments, high-end allocation and
  growing heaps.
- Discs boot from `SYSTEM.CNF`; the EE kernel, SIF RPC, FILEIO, CDVD,
  LOADFILE, PADMAN and MCSERV answer the EE libraries.
- Game IOP modules load from the disc or from EE buffers, link against the
  high-level system libraries and run their threads, interrupt handlers and
  RPC servers on the emulated IOP.
- Snapshots cover the EE, GS, IOP and memory cards. Their header records
  `PS2SnapshotVersion`; snapshots from another format or disc are rejected with
  a message naming the cause, and the running console is left unchanged.
- The console clock (CDVD RPC, IOP `sceCdReadClock` and memory card times)
  starts at 2004-01-01 12:00:00 and advances with emulated time only. Runs
  and snapshots therefore repeat regardless of the host clock.
- The system language (`System/Language`) goes into the OSD configuration
  that `GetOsdConfigParam` returns. Automatic is Japanese for the Japan region
  and English elsewhere. The configuration word carries OSD version 1 and the
  non-Japanese flag. Russian is reported as consoles with extended languages
  do it: English in that word, version 2, and Russian in the second area
  (`GetOsdConfigParam2`, 128 bytes). That area also holds the region's date
  and time formats.

`tests/cores/ps2/system/build.ps1` checks the clock calendar and every clock
consumer, the OSD configuration for each language setting, exact snapshot
round-trips, the old-format and wrong-disc errors, and the recorded field
layout. A layout change must increase the version.
It also checks a VIF1 interrupt-bit stall that fills the FIFO and holds the
DMA channel until a stall cancel (also across a snapshot), the VU busy
window, and DMAC stall control with fromSPR as source and VIF1 as drain.
UNPACK and DIRECT data are taken many words at once inside a command
(`PS2VIFRuns`: whole vectors, groups of words ending with a vector for the
formats whose vectors share words outside fill mode, whole quadwords to the
GIF), also as held words are released after a stall; the test compares
both with one word at a time (DIRECT through a GIF and GS: memory, PATH2 and
VIF state), and the masked write with a model for V4-32 streams. It
also tests the card file system: directories, files across clusters, deleted
slots, free space, image round trips, raw images and earlier card files. It
also runs libmc's MCSERV calls: info, mkdir, create, write, read, list and
delete. It drives the `mc0:` ioman device the same way. It also calls IOP
system library functions: look_ctype_table, ReferModuleStatus, the dmacman
priority and enable calls, and a growing heaplib heap.

## VU busy windows

A micro program started by MSCAL/MSCALF/MSCNT, CTC2 to CMSAR1 or VCALLMS
still runs to its end at once. The VU then stays busy for the cycles the
program took, because VUs run at the EE clock. During that window VIF STAT.VEW,
VPU-STAT.VBS0/VBS1 and CPCOND2 report busy. FLUSHE, FLUSH, FLUSHA, MSCAL,
MSCALF, MSCNT and MPG wait for the window to pass, and their DMA channel
waits with them. The interpreter and the JIT count the same cycles. EE macro
instructions issued during a VU0 window do not wait yet, and FLUSH/FLUSHA do
not wait for the GIF paths yet.

## EE FPU and VU EFU results

The rules come from hardware results in ps2autotests (`cpu/ee_fpu`,
`vu/lower/efu`). Adds and multiplies truncate. DIV.S and SQRT.S round to
nearest. RSQRT.S multiplies Fs by a rounded reciprocal of a rounded root,
which reproduces every hardware vector. An overflowing MADD/MSUB product is
the result, without ACC. EFU sums and squares chain the PS2 adder and
multiplier. EFU roots and reciprocals round to nearest, and a zero divisor
gives the largest value.

The FPU's and the VUs' multiplier loses a bit in some products (the VU
manuals: 1 * X may differ from X, X * 1 not). Every product measured on a
console that we have (ps2autotests' `cpu/ee_fpu/muldiv` and
`vu/games/triace`, the list of 1 * X for X = 0.5 .. 249.5 on fobes.dev, PCSX2
issue 10519 from Monster Hunter) fits a radix-4 Booth multiplier that drops
the partial products' columns below 15 or 16: a negative digit of the
multiplier ft among its eight lowest loses what reaches the low columns.
Where fs is a power of two, that loss is the whole difference: such a
product (both operands nonzero, exponent 1..255) is one unit less than the
truncated one (`PS2MulLosesBit`, MUL/MULA/MADD/MSUB on the FPU, every VU
multiply in the interpreter and the JIT). With other multiplicands the loss
depends on how the hardware sums its partial products, which these data do
not show: those products stay truncated. `PS2MulLostBit` False (test runner:
`PS2_MULBIT=0`) turns it off.

Known gaps:
- Products whose multiplicand is not a power of two never lose the bit (the
  models that fit the data differ there; about one product in a hundred
  would).
- 9 of the 96 EFU root/reciprocal vectors differ by one unit in the last place.
- EATAN, ESIN and EEXP use host functions instead of the EFU's series.

## GS display and transfer checks

Display scanout publishes queued CPU/GPU writes once per read circuit, not
for every pixel. Two circuits sharing the same source rectangle reuse one
read within that frame while retaining independent output offsets and sizes.
Nothing is reused across frames. A provably opaque foreground covering the
whole output bypasses background reads and blending; partial coverage and
transparency retain general composition. `tests/cores/ps2/gsdata/build.ps1` checks display formats,
both circuits, offsets/wrap, zero stride and queued drawing. It also compares
dual-circuit composition against a scalar reference over alpha boundaries,
magnification, interlacing, disabled circuits and background selection, and
IMAGE uploads with scalar HWREG transfers over all storage formats, including
partial bitstreams, row/VRAM wrapping, ring reuse and serialized state.
Display rows use immutable offsets for 32/24/16-bit colour/depth layouts,
preserving the scalar conversion and VRAM wrap without wrapping large display
coordinates at 2048. Unsupported formats, negative coordinates and race
instrumentation retain scalar pixel reads.
Queued whole-quadword IMAGE uploads unpack integer formats into the transfer
ring in chunks; 24-bit streams, partial tails and unusual state retain the
scalar path. Reservation, row progression and barriers keep the same order.
Uploads with nothing queued before them (the GPU drew the rest, or the
bands are idle) write each whole quadword at once, a row at a time, instead
of pixel by pixel (24-bit streams keep the scalar path); Metal Gear Solid 2,
God of War and Ratchet & Clank gain 7-11% (MGS2's GS worker spent about a
third of its time there). Transfer rows (`WriteRow`, also the band threads' queued
uploads) go through immutable per-page offsets for every storage format, retaining
coordinate/VRAM wrapping and the bits a format leaves alone (24-bit, high
8/4-bit and nibble neighbours); the test compares 1664 rows over all formats
with scalar writes. Race-instrumented builds retain scalar writes.
The tests run without Vulkan; `-Checked` enables checked core code.

## Experimental recompilers

`Emulation/Execution=jit` selects the EE block recompiler and the VU block
recompiler for VU1 and for VU0 micro programs (each with its own code arena);
`interpreter` (the default) uses the original execution path. This is
independent of `Video/Renderer` and can change during play. VU0 macro
ADD/SUB/MUL/MADD/MSUB (broadcast, Q, I and ACC forms) are compiled once per
opcode into a buffer of their own (operands, register routines, MAC/status
flags, masked write) and called directly from the EE's generated code while
no micro program runs; the routines for the host rounding are chosen when the
EE starts running, which keeps rounding toward zero. Other macro
instructions remain interpreted. VU0's spin probes check the TPC after each
pair but run straight-line pairs (up to a branch's delay slot, an E bit or the
loop's start) in one budget, which the per-pair budget checks keep exact;
the register files are compared without CompareMem calls. A probe's turn
that touches no memory (no load, store, XGKICK or XTOP/XITOP; no E/M/D/T
bit) and comes back to the very same core state but the cycle count, with
no flag, clip, Q/P, VF result, end or XGKICK pending, makes the loop known
(`TPS2VU0.SpinKnown`): while the state, the integer unit's last write and
the loop's code words stay so, later probes only add that turn's cycles and
pairs (`SpinSkips`), and VF data the EE hands over to a loop of whole turns
in 16 pairs that reads and writes no VF register (an upper NOP and integer,
branch, flag or empty MOVE lower ops) adds the 16-pair run's and the
probe's. Ratchet & Clank's VU0 waits this way about 150000 times a field.
Once a probe has found the known loop, the next ones compare only VI and the
VF registers the EE wrote since (`TEECop2.VFWritten`, marked by LQC2 and
QMTC2) while nothing else could have changed: the core untouched
(`TPS2VUCore.Touched`: runs, starts, macro operations, resets, snapshots)
and no other control write or COP2 operation (`KnownProbe`); R&C's main
thread -5.7%.
`tests/cores/ps2/jit` runs 90000 random EE operations (VF/VI/data/code and
control writes, macro operations, VCALLMS, syncs) on programs waiting on
VI1, VF5, a data word, flags, I, R or a VF result, with and without skips.

On Win64, common multimedia instructions (parallel add/subtract with and
without saturation, compares, min/max, PEXT*/PPAC*, PCPY*, logic and the
halfword/word shifts) decode to SSE2 kernels on whole registers
(`EEMMIKernel`) for the interpreter and the recompiler alike;
`tests/cores/ps2/eemmi` runs each of them, with every shift amount and aliased
registers, against the general handlers in both, and the recompiler's
halfword, ADDI, COP1 and COP2 transfers (aligned or not, overflowing,
register 0, aliases) against their handlers.

The EE recompiler turns a decoded block into host code on its second run.
Shifts, 32/64-bit integer arithmetic and logic, set-on-less-than, HI/LO moves,
MOVZ/MOVN, branches and jumps (likely forms included), ADDI (its handler on
overflow), MFC1/MTC1, the mapped fast path of LB/LBU/LH/LHU/LW/LWU/LD/LQ/LWC1
and SB/SH/SW/SD/SQ/SWC1 (with the page write generation), LQC2/SQC2 and
QMFC2/QMTC2 while VU0 runs no micro program (`TEECop2.RunningFlag`; else
their handlers wait for it), PCPYLD/PCPYUD/PAND/POR/PXOR/PNOR and
MFHI1/MTHI1/MFLO1/MTLO1 are emitted
inline, the other multimedia instructions with whole-register kernels (below)
call them directly; every other instruction, and every access the fast path does
not take, calls its interpreter handler. After its last instruction a block
counts its time and goes on into the next block's code (learned per exit,
checked for its PC and code-page generations) only where the run loop would
run it next with nothing else to do: no deadline, interrupt, exit or code
reset due, the next block compiled and not a spin, no diagnostics hooks;
else it returns to the run loop, so cycle counts, state and frames match the
interpreter.

Polling loops (with or without the recompiler): a block, or two blocks the
first of which falls through to the second, whose turn ends with a
conditional branch back to its start and only loads (RAM and directly mapped
pages, INTC_STAT/INTC_MASK), register arithmetic and NOPs that read no
register the turn writes before writing it, computes the same each turn until
an event changes memory (devices only run at events). The run loop passes the
turns up to the next event at once: as many whole turns as would run (for two
blocks those ending before the event; the last runs as usual), with the same
cycle and instruction counts. Jak and Daxter and Ratchet & Clank spend much
of their idle time in such loops on INTC_STAT. Delay loops are passed the
same way (`SkipCountdowns`, `FindCountdown`): a block that branches back to
its start by BNE (with zero or a register it does not write) or BGTZ and
otherwise only counts down, a register by ADDIU/DADDIU -1 (before the branch
or in its delay slot) or a RAM word by LW/ADDIU -1/SW/LW, with NOPs: the
turns before the next event, but its last, take their cycles and leave the
counter (and the word, its page's write generation) as they would; FFX and
God of War spend millions of turns a minute so. `tests/cores/ps2/eemmi`
compares 4000 such loops and near misses in deadline slices with and without
it. Code is dropped with the decoded blocks,
waiting for running code to return; the arena is bounded to 64 MiB.

## VU recompiler details

A block is compiled (or a cached version of the same words reused) the
second time a run starts at its entry (`PS2VUCompileHeat`): games that upload
microcode often (Jak and Daxter) otherwise interpret millions of pairs a
minute before an entry warms up again.

The shared `HW.JIT` generator emits pipeline hazard checks, delayed flag
queues, register commits, VI arithmetic, branches, memory operations and
CLIP flag reads. Upper ADD/SUB/MUL/MADD/MSUB and cross products call the exact
four-field PS2 SIMD routines directly; uncommon operations retain interpreter
helpers. XGKICK still uses the shared packet reader with its original timing.
ITOF/FTOI0/4/12/15 use packed exact conversion helpers, and CLIP uses integer
comparisons plus the original four-cycle flag queue. Exponent-zero inputs,
finite exponent 255, saturation, masks and host conversion rounding retain
the scalar reference results.
On Win64/AVX2, compiled ADD/SUB/MUL/MADD/MSUB can pass operands and results
through volatile 128-bit registers. Each run picks the routines for the host
rounding it runs under, so no operation reads MXCSR (`HW.JIT`'s
`VectorCallAt` calls them through the core): under truncation the host result
is the PS2's; under round-to-nearest (VU1 programs started by the scheduler)
the host result is moved one unit toward zero where its exact error (FMA for
products, Fast2Sum for sums) shows it was rounded away from zero, within
exponent ranges where every intermediate is normal whatever FTZ/DAZ say;
other modes and ranges use the exact integer routines. With AVX-512 (F, DQ,
VL and the OS's ZMM state) the round-to-nearest routines instead let the
operation itself round toward zero (EVEX embedded rounding; the bytes are
written out, as the Delphi assembler drops the rounding operand), with the
same range tests and blends for the operand order. The multiply routines
look for a multiplicand with mantissa 0 in a lane and only then work out the
lanes losing the multiplier's bit (`MulLostBitLanes`). `tests/cores/ps2/vufloat`
calls the register routines of every host rounding, with and without
AVX-512, on random operands and all exponent pairs. The result stays live
through a call-free lower half until the masked commit (beside a lower half
that calls a helper it is stored first); Z/S extraction is vectorized and O/U
groups are returned directly. The four-field memory-operand kernels take the
same corrected host arithmetic under round-to-nearest. Every input and rounding mode remains exact,
using integer normalization outside the guarded common range. MADD/MSUB still
round the product and sum separately. OPMULA and OPMSUB take the same
register routines (operands shuffled to Fs.yzx and Ft.zxy, w cleared; x, y
and z written), as the memory path builds them; FFX gains 4%. Callbacks, aliased data/register/code
buffers and unsupported backends retain the memory-result path. In a
statically scheduled span on Win64, XMM6..XMM15 (kept vector registers, which
`TJitAsm.InvokeKeeping` saves for its caller) hold copies of the VF registers
and ACC read or written last, so that reading them again takes no load nor
waits for the store; memory always has the value too, and any other write to
a register drops its copy. Lower halves (MOVE, MR32, LQ, LQI, LQD, MFIR, MFP)
write VF directly, before the staged upper result commits. `PS2_VU_MEMORY_MATH` selects the old
compiled path for build-time differential checks; user options are unchanged.
Code is generated after 16 visits in blocks of up to 32 pairs (`PS2VUBlockPairs`), ending after
branch/end delay slots. Compiled successors chain through a table within one
native frame. The general path checks the budget, PC, both instruction words
and decoded metadata at every pair; callback changes cannot run a stale pair.
A scheduled span checks its words in code memory only when code memory
changed since it last found them there (it takes nothing from decoded
metadata at run time): whatever writes micro memory (VIF MPG, the EE, whose
accesses there go through the bus for it, snapshots, resets, tests) calls
`TPS2VUCore.NoteCodeWritten`, and each compiled block keeps the generation
its words were last found at.
Callback-free spans also have a statically scheduled path: it validates the
whole span, incoming dependency deadlines and pending queues before changing
guest state. Internal stalls and final register-ready times are constants.
Pipeline ready times are not saved (a load or reset clears them), so every
result already issued is ready three cycles into a span: only inputs read
earlier are checked, and only results issued in a span's last three cycles
get ready times written. The compiler simulates the MAC/status and clip
queues through the span for the incoming queues it finds when it compiles
(and for empty ones): what each slot, including stale tail slots, and the
base end up holding, and what each pair's flag reads see. Events nothing
reads (not a flag read's, the queue's at the end, or the last) only OR their
MAC flag into an accumulator (its lanes in any order: only each group's
sticky bit counts), whose sticky bits join the status before the
next one is worked out or a helper may read it. At the end the
queues are written from that when the incoming ones were so; otherwise the
events are replayed at run time as each pair would have queued them
(FinishFastFlags). FCEQ/FCAND/FCOR/FCGET/FCSET and FSEQ/FSAND/FSOR/FMEQ/
FMAND/FMOR may be in a span, which then requires the queues it was compiled
for on entry: other incoming queues met there are noted once and the span is
compiled again with a body for each; later mismatches run its first pair the
general way. Q and P land after their latency counted from the span's start
or from the DIV/SQRT/RSQRT or EFU op that last produced them (WAITQ/WAITP land
them at once), so those may be anywhere in a span. Spans have two pairs or
more. A budget within 64 pairs of its end records the span's LoopTrace
entries in one go (or takes the general path when only some would be). A
kick in progress takes its quadwords before each VU store and after the last
pair, if it cannot complete inside the span. An input still in the pipeline
on entry runs only the first pair the general way, then the successor.
Trace capture and pending branches/ends fall back to per-pair execution;
FSSET and XGKICK are boundaries. A span whose branch goes back to its own
start goes round again within its code where the entry's checks would all
pass then, as the compiler can tell: no end, the pipeline inputs its first
cycles read ready again after its last cycles' results, the queues it leaves
the ones it was compiled for (with flag reads; incoming entries all landed
otherwise). Each turn still looks at the branch, the budget and its trace
window, and a kick in progress.
Re-uploaded block versions are reused only after the entry address and every
word match (hashes alone are not trusted). The code arena is bounded to
32 MiB per VU; resetting it clears the version and successor tables too.
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
Directed conversion/CLIP cases also cover four host rounding modes, vf0,
overlapping upper/lower destinations, full/delayed CLIP queues and FCGET/FCSET.
Scheduled queue tests cross multiple compiled spans in 64-pair programs.
Random programs include flag reads, FCSET, DIV/WAITQ and EFU/WAITP ops; random
macro operations are compared compiled and interpreted in every host rounding.
The JIT build script accepts `-Defines PS2_FORCE_SSE2` for backend comparisons.
Register kernels are compared against the native backend, Pascal model and
one-field arithmetic in all rounding modes and FTZ/DAZ. Aliased hardware-buffer
tests verify that register-result generation is not used for synthetic aliases.
`tests/cores/ps2/vufloat/build.ps1 -ConversionsOnly` checks conversion and CLIP
helpers against scalar arithmetic, including aliases, unaligned values and
FTZ/DAZ; the default float suite retains the add/multiply checks too.

## Experimental Vulkan GS (Vulkan LLE)

`Video/Renderer=vulkan` (the settings' Vulkan LLE; `vulkan-lle` is read as
the same) independently selects Vulkan compute for supported
sprites and triangle pixels drawn to 32/24/16-bit frames, including all GS
direct and palettized texture formats and mipmapping, pixel for pixel as the
software renderer draws them. Its compute context is `PS2.Vulkan.Compute`
(from the Xbox branch, 3f3ce45; `RM.Vulkan.Compute` is the other cores'), with
coherent GS VRAM import. Small sprites (where triangles are not rasterized on
the GPU, below), draws reading pixels they draw (texture feedback),
overlapping surfaces and unsupported storage
formats retain the software path. If device creation or host-memory import
is unavailable, software rendering continues; `VulkanError` reports why.
The default remains multithreaded software rendering.
With band workers configured, unsupported sprites/triangles keep the ordered
software queue rather than drawing on the emulation thread. Accepted GPU
draws wait for queued CPU work, and software fallbacks for queued GPU work,
only where their pages meet (reads against writes, writes against both);
local copies first publish GPU work. A full half of the GPU draw slots is
submitted without waiting while the other half is recorded (two command
buffers). Workers, including the solo feedback drawer, never call
Vulkan. Palette loads stay on the host when no CPU work is pending.
These pages are those of the draw's rectangle and its textures' extents,
and of a transfer's or local copy's rectangle (all where it wraps), as the
software queue tracks them.
A draw whose texture pages may meet its own targets' (in broad page ranges,
or past the end of VRAM, where textures continue at its start on both
paths) is accepted only where the software footprint finds that no pixel
reads a texel another pixel of the draw writes: disjoint texel and pixel
rectangles in one buffer, a sprite or triangle reading its own pixels, or the high byte
of 24-bit words. A small one meeting queued software work joins that queue
instead, so that GPU and band threads do not wait for each other at each of
a series of such primitives between self-reading ones.

The integer shader implements alpha/depth tests, fog, blending, destination
alpha, masks, texture functions and 24-bit preservation. In 16-bit frames
(CT16/CT16S/Z16/Z16S) a pixel is half of a word: the invocation owning it
writes its own 16 bits with atomics, and expands and packs it as the host
does (5 bits per colour, alpha 128 or 0; `Color32To16`). Sprite UV/STQ
interpolation stays on the CPU with the software renderer's arithmetic;
integer coordinates are uploaded per column/row. The GPU performs exact
integer filtering and sampling, including all clamp/repeat modes and TEXA.
Each queued draw keeps a CLUT snapshot (including 16-bit palettes and CSA).
Texture swizzle tables are generated from `PS2.GS.Memory`. LOD selection and
the 4-bit inter-level weight are computed on the CPU with the same rounding
as the software path; the GPU samples the chosen levels and blends integers.
Triangle safety checks conservatively cover all potentially used levels.
Devices reporting `TVulkanCompute.ExactDouble` can perform triangle coverage
and interpolation on the GPU, per-pixel LOD included: the host's mip choice
(`PixelLod`, then `MipCode`) only changes at a few single-precision values
of Q, because `System.Math.Log2` of a Single never decreases as its argument
grows (`tests/cores/ps2/lod` checks every positive Single under both host
roundings), so a
table of those thresholds per LOD setting and rounding (made once, appended
to a dedicated buffer that the draw references by offset; when full, queued
work finishes and the tables start over) gives the shader the same choice from
the pixel's Q rounded to single precision as the host rounds it. The shader requests
explicit IEEE FP controls, emulates the host truncation mode and corrects
device division using exact residuals. It retains the reference depth
accumulator's four-decimal Currency quantization. Nonfinite/subnormal STQ,
zero Q, Q of mixed sign (any nonpositive Q with per-pixel LOD) and
unsupported layouts retain host interpolation; all-negative Q is accepted,
since the host's S/Q and T/Q arithmetic does not depend on the sign.
The edge functions of the integer coordinates (up to 36 bits) are evaluated in
64-bit integers (`shaderInt64`), as exact as in FP64 and much cheaper on GPUs
with slow FP64. Colours, fog and texture coordinates (affine, and S/T over Q
times the power-of-two texture size) are first estimated in single precision
from the FP64 weights, with an error bound of 2^-20 of the terms' magnitudes
(several times the float and double evaluations' worst error, the float
division's 2.5 ulp included); where that bound decides the integer the FP64
arithmetic would give (its rounding, truncation, ties to even), the estimate's
integer is taken, else the exact FP64 path runs. Depth stays in FP64.
For those triangles the GPU consumes the exact integer fragments for texture sampling,
tests, blending and writes. A 65536-fragment arena is split and synchronized
when full, including in the middle of one triangle.
The parameter arena holds 2048 draws (two halves, one filling while the other
runs). Compatible native triangles, and on these devices sprites of any size
(flat colour/depth, the host's per-column/row texture coordinates), are binned
into ordered clusters of up to 128 draws and 65536 entries (a draw meeting an
8x8 tile), listed per tile in draw order. One invocation owns a pixel through
the cluster and caches its colour/depth until the end. Where a tile meets 8
draws or more (`PS2GSTwoPhaseDraws`) a cluster takes two passes: first one
workgroup per entry works out coverage, depth and the source colour
(texture, texture function, fog: nothing a cluster draws is read as its
texture), then each pixel takes its entries in order for the depth test,
alpha tests, blending and writes; the serial chain per pixel then holds no
texture reads, which the GPU waited on before. Clusters of few draws per tile
take both steps in one pass.
Texture dependencies, layout changes and colour/depth aliases end clusters.
The 16 MiB tile arena can refill while preserving undispatched parameter and
CLUT snapshots. Other dispatches are ordered by compute memory barriers.
CPU transfers and palette loads wait only for overlapping GPU read/write
pages, including zero/undersized strides and wrapped VRAM. CPU drawing,
display reads, reset, snapshots and mode changes still drain pending work.
This is not a complete or consistently faster GPU renderer. It does not require
JIT. GS saves contain the same VRAM and state in either mode.

Regenerate its embedded SPIR-V with `source/cores/ps2/shaders/build.ps1`
(Vulkan SDK `glslc` required). Application builds use the checked-in include.
`tests/cores/ps2/gpu/build.ps1` compares 256 isolated draws and a dependent
256-draw sequence, with and without textures, against the CPU over all
4 MiB of VRAM. It checks batch capacity/reuse, texture feedback fallback,
render-to-texture ordering, transfers, CLUT state and live mode changes.
A third of those draws and of the following 256 triangles go to 16-bit
frames. The triangles cover winding, clipping, flat/Gouraud colours, UV/STQ
(negative Q included), textures continuing past the end of VRAM, both host
rounding modes, varying depth/fog and fragment-arena rollover.
An additional 312 cases cover all 13 texture formats, CLUT/CSA/CSM/TEXA,
all minification modes, multiple mip levels, sprites and triangles. A separate
test mutates the host CLUT while two draws are pending in the same GPU batch.
Tile tests (with clusters in two passes, in one, and as chosen) cover 256
ordered blended triangles in three clusters, mixed host
rounding, texture/layout/depth cluster breaks, 2048-slot reuse, tile-arena
refill with preserved palettes, 70000 prepared fragments, selective page
hazards and zero-stride/wrapped transfers and palettes. The `-coverageonly`
switch repeats the CPU band stress 100 times, comparing VRAM and counters.
Pass `-Hybrid` to the build script (or `-hybrid` to the test executable) to
run the renderer cases with four fallback bands. The mixed-renderer test
also checks two/four/six bands, self-reading 16-bit draws, local copies, palette
loads, host transfers, mode switching and serialized state equivalence.
It requires a Vulkan device with coherent host-memory import.

## Experimental Vulkan HLE GS

`Video/Renderer=vulkan-hle` (the settings' Vulkan HLE) draws every sprite,
triangle, line and point with Vulkan graphics pipelines in the host GPU's
arithmetic (`PS2.GS.VulkanHLE`, on the common `RM.Vulkan.HLE` base the PSP's
HLE renderer uses): fast and light on the CPU, but not pixel for pixel as the
software renderer. The raster still counts the pixels each primitive covers,
so the timing is the same. It draws on the GS worker's thread (where the host
has four logical processors; else on the emulation thread), without band
threads, and needs a device with a graphics queue and dual-source blending
(else the software renderer draws, without band threads, and `VulkanError`
says why). The display's reads go to the worker, which stores only the
targets they meet.

GS buffers are render targets (RGBA8 images; 24-bit frames keep alpha 0x80,
16-bit ones bit 15 as 0 or 255), their depth buffers the targets' depth
images. A target's rows map to GS memory a page row at a time, so targets are
whole page rows tall and their drawn rows are held a page row at a time.
Textures are decoded on the CPU (CLUT, TEXA, mipmap levels) and compared with
the GS blocks they came from (a large one that primitives read little of in
parts of whole GS pages); a drawn target read in its own format and width
is sampled from its image (a draw reading the target it draws reads a copy,
brought up to date before a primitive reads what was drawn since). The
shaders do the GS's texture addressing (wrap modes, 4-bit bilinear weights,
LOD and mipmaps), texture function, fog and alpha test in its integer
arithmetic; blending is the fixed function's with the source side weighed in
the shader and the destination weight as the second source (dual-source
blending); depth is the fixed function's (GEQUAL/GREATER over the buffer's
range, clamped). The alpha test's failing pixels (AFAIL) are a second pass of
the batch. Where the device has VK_EXT_fragment_shader_interlock, draws the
fixed function cannot do as the GS (any blend weighed by an alpha, weights
above one, wrapping colours, DATE, FBMSK masking part of a channel) are drawn
by `PS2.GS.HLEBlend.frag` instead: the alpha test with AFAIL, DATE, the blend,
PABE, COLCLAMP, FBA and FBMSK in the GS's integer arithmetic and the frame
format's bits, in primitive order (the colour as a storage image, depth tested
before the shader; such draws write depth only when they leave no pixel out,
else the fixed function's approximation stands). `PS2_HLESHADERBLEND=0` turns it
off.

The raster reports its own accesses to GS memory (transfers, CLUT loads,
local copies and reads, the display) by pages: targets newer there are stored
first, writes to pages textures or targets came from are seen. Only the
targets the display shows are read back each frame. 8H/4HL/4HH textures in a
24-bit buffer's high byte do not wait for it.

Not yet as the GS draws: without shader blending, DATE, FBMSK masking part
of a channel, destination alpha (32-bit frames weigh Ad / 255 instead of
Ad / 128), weights above one and COLCLAMP off; DATE with depth writes and an
alpha test in any case; dithering, and buffers read through another format
(texture shuffles, depth as colour, palettized views of colour) other than by
storing them and decoding GS memory. Resolution scaling is not offered yet. Shaders
are in `source/cores/ps2/shaders` (`PS2.GS.HLE.*`); `shaders/build.ps1 -Only HLE`
regenerates their includes. `PS2_GSVULKAN=hle` selects it in the test
runner, `PS2_HLEVALIDATE=1` the Khronos validation layer.
## BIOS boot (in progress)

With a BIOS image in `TPS2ConsoleConfig.BIOS` the console boots it instead
of the high-level kernels. The EE starts at its reset vector with the BIOS
in ROM and no high-level syscalls. The EE side adds the RDRAM controller
(MCH), the memory controller command register and the 1A000000h command
interface the BIOS initializes. The IOP side is `PS2.IOP.Machine`: the IOP
core with hardware exceptions and interrupts, the BIOS ROM, I_STAT/I_MASK/
I_CTRL, the DMA controller (DPCR/DICR, CDVD, SIF0/SIF1; the SPU2 and SIO2
channels stay in `PS2.IOP.Hardware`), the root counters and the SBUS
interrupt to the EE. `PS2.SIF.Bridge` holds the SIF mailbox registers and
the SIF0/SIF1 FIFOs between EE DMA channels 5/6 and IOP channels 9/10.
`PS2.CDVD.Drive` is the CDVD drive and MECHACON: N commands with spin-up,
seek and read timing, S commands with the exact result lengths, the clock
(the BIOS can set it), and the 1 KiB EEPROM. The EEPROM holds NVM words,
the model name, the i.Link ID and the configuration areas (EEGS, OSD, DVD
player). Those are 16-byte rows at 280h/300h/200h on the earlier MECHACON
and at 270h/2B0h/200h on the Dragon MECHACON of BIOS 1.70 and later (layout
from the PS2 Developer wiki). The EE reaches the drive's registers at
1F402000h as well: the browser reads the disc type there. ReadKey (N command
0Ch) returns the disc key, which carries the disc's serial in the encoding
that ps2sdk's cdvdman decodes. The IOP root counters count in whole ticks
from their last event, so a compare or overflow event handled late still
fires and keeps its rate.

With SCPH-50008 and a configured EEPROM (OSD row with the initialized bit),
the BIOS boots a game disc the way the console does: OSDSYS checks the disc,
reads its keys and runs PS2LOGO, then the game resets the IOP with its own
modules and starts (Final Fantasy X reaches its intro). A blank EEPROM gets
the first-start setup and the main menu instead; the BIOS stores the
answers in the EEPROM. Memory cards pass MagicGate authentication: the card
answers SECRMAN's steps and the MECHACON accepts them, so the browser and
the games' card drivers reach the same card files as in high-level mode.
The video standard starts from the BIOS region and follows SMODE1 (CMOD 2
NTSC, 3 PAL). An explicit language setting goes into the OSD configuration
of a console that has been set up.

The front end's BIOS setting (`Hardware/BIOSMode`) picks the mode for discs:
High-level, Automatic (a BIOS from the settings, beside the game, in the ps2
folder or in the bios folder, one of the disc's region first; high-level
otherwise) or External (a BIOS is required). The EEPROM is saved per BIOS
version as `saves/ps2/console-<ROMVER>.nvm` whenever the BIOS writes it; the
first time an `.nvm` beside the BIOS seeds it, and a `.mec` there gives the
MECHACON version. BIOS boot snapshots go to their own folder. ELF programs
always use high-level emulation. `PS2Run -bios FILE` boots a BIOS (with
`.nvm`/`.mec` files beside it).

## Limits

- The GS rasterizer is a software renderer without upscaling.
- Each memory card is kept as one file in the save folder: its 8 MB flash
  with the PS2 card file system, deflated. The high-level MCSERV works on that
  file system, and games bringing their own card driver (MCMAN over SIO2)
  work on the same pages, so both see the same saves. FILEIO's `mc0:` and
  `mc1:` (open, read, write, seek, mkdir, remove, dopen/dread, getstat) reach
  the same file system and share MCMAN's handles. Raw card images, with
  or without spare bytes (as PCSX2 keeps them), load as they are. Card files
  of earlier builds (a file tree) are converted, and the old file is kept as
  `.old`. MagicGate authentication is skipped.
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
