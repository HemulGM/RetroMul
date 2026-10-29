# Atari 2600

Native Delphi core, system ID `at2600`, registry ID `A2600`. The desktop and
terminal clients register it through `RetroMul.Platforms`.

All Atari 2600 machine code lives in this directory. RetroMul and RetroTune
share the same console and hardware implementation:

| Module | Responsibility |
| --- | --- |
| `A2600.Types` | Clock rates, timing constants and shared types |
| `A2600.CPU` | 6507 interface over the existing NMOS engine; CPU state transfer |
| `A2600.Cartridge` | ROM validation, mapper detection, bank latches and cartridge RAM |
| `A2600.DPC` | Pitfall II display fetchers, polynomial and music oscillator |
| `A2600.Supercharger` | Binary tape blocks, bootstrap, RAM windows and delayed writes |
| `A2600.Controller` | Joystick/Paddle connections, knob calibration, keyboard/mouse positions and button wiring |
| `A2600.RIOT` | 6532 RAM, I/O ports, timer and its flags |
| `A2600.Palette` | NTSC/PAL color conversion |
| `A2600.TIA` | Register effects, beam timing, objects, collisions and video output |
| `A2600.State` | Machine state transfer, including RIOT timer phase |
| `A2600.Console` | Address decoding and coordination of CPU, RIOT, TIA and cartridge |
| `A2600.Emulation` | RetroMul worker, frame publication, audio device and commands |
| `A2600.AudioMachine` | RetroTune's sample-pull adapter over the shared console |
| `A2600.Paddle` | Four independent TIA input capacitors, resistance changes and VBLANK discharge |

The TIA sound generator remains in the shared hardware layer as `HW.Sound.TIA`,
following the placement of the other sound chips. The TIATracker decoder uses it
directly; cartridge music uses `A2600.AudioMachine`. The audio adapter suppresses
pixel writes and frame publication but retains the same bus, CPU, timer, mapper,
TIA register effects and collision calculations as normal emulation. It has no
separate memory map or timer implementation.

The console reuses RetroMul's NMOS CPU bus engine (`NES.CPU` with the decimal
arithmetic in `C64.CPU`) and its existing `HW.Sound.TIA`. It masks the CPU bus
to 13 bits, clocks TIA three times per CPU cycle, implements WSYNC stalls and
RIOT RAM, ports and timer, and produces stereo PCM containing the mono TIA mix.
The new video implementation renders playfield, players, missiles and ball,
including copies, sizes, reflection, vertical delay, motion and collision latches.

Cartridges: 1K/2K/4K, F8/F6/F4 with optional Superchip RAM, E0, 3F, FA,
E7, FE, UA, 0840, CV, DPC, Supercharger binary tapes, Megaboy, 32-in-1 and
CompuMate ROM/RAM. Exact repeated overdumps are normalized in memory.
3F ROMs up to 512 KiB and headerless 6 KiB Supercharger RAM images are supported.
Automatic selection uses size and board-specific bus signatures. Raw files with
identical sizes can be ambiguous; settings allow an explicit board override.
Supercharger uses an original bootstrap for 8448-byte binary tape blocks and
multiload records; sampled tape audio is not supported.
CompuMate identification straps and memory are emulated; its full keyboard and
cassette input are not yet exposed by the frontend.

Open `.a26` anywhere, or `.bin`/`.rom` within an `at2600` or `atari2600`
folder. The existing archive service handles ZIP and 7z. Archives in these
folders prefer the title matching the archive name, good dumps and NTSC versions.
An individual entry can also be extracted and opened directly to choose a variant.
The library scans `at2600`, `atari2600` and `a2600`.

Controls: arrows and Z for joystick/fire; Enter is the console RESET switch;
Shift is SELECT. Player two uses numpad 8/5/4/6 and numpad 1. The frontend
provides remapping, gamepads, virtual controls and two controller ports.
The menu Reset action performs a full core reset. Pause, resume and snapshots
run through the emulation worker. Cartridge RAM is volatile.

Each connector can instead host a pair of Paddle controllers (four knobs total).
Choose **Controls > Connected device > Paddles (pair)** for the required port.
Assign Left/Right to the first knob's X axis, Up/Down to the second knob's Y axis,
and A/B to their respective fire buttons. The default keyboard uses left/right,
up/down and Z/X for the left pair, numpad 4/6, 8/5 and 1/2 for the right pair.
Keyboard movement retains the knob position on release. Analog axes, keyboard,
the on-screen X/Y control, and optional relative mouse input are supported.
Mouse X/Y controls the two knobs; left/right mouse buttons fire.

The per-port controls page includes keyboard speed, mouse sensitivity and
per-knob inversion, minimum/maximum resistance range and center dead zone.
Range percentages refer to a 1 megohm potentiometer; reduce the maximum to 50%
for games whose useful play area covers roughly half its physical travel.
Settings and connections apply between frames, including while paused.
Paddle buttons drive SWCHA bits 7/6 (left port) and 3/2 (right port).
INPT0..3 measure independent 68 nF RC circuits with 1.8 kohm series resistance;
VBLANK bit 7 discharges them. Charging also continues across frame boundaries.

Settings expose TV standard, cartridge override, Color/B&W and difficulty A/B
for each player. TV standard and cartridge changes require reopening the game;
console switches and audio settings apply live. Automatic video selection uses
the selected image's `(PAL)` name tag, defaulting to NTSC. Output doubles the
160 horizontal pixels to 320; the fixed vertical window is 240 NTSC or 288 PAL
lines. Color conversion is an approximate analog palette.

Compatibility limits: no DPC+, 3E/3E+, ARM coprocessor or other unlisted boards;
no paddles, keyboard controllers or driving controllers.
INPT0..3 currently read as charged. TIA write propagation, HMOVE blanking and
extended-motion quirks, input trigger latching and RIOT PA7 edge interrupts are
not modeled. PAL/SECAM detection from executed scanline timing is not implemented;
SECAM colors are not implemented. This is a working initial core, not a claim of
full cartridge compatibility or transistor-level TIA accuracy.

Snapshot payload version 3 adds Paddle charge and knob state. Version 2 snapshots
remain readable; the old incomplete version 1 CPU-state layout is rejected.
Snapshots serialize the full in-flight CPU bus sequence, RIOT, TIA registers, video, mapper/RAM, and
sound oscillator/filter state. Frame buffers are copied before the worker writes
them. A frame has an absolute execution limit so malformed RSYNC loops cannot
prevent worker shutdown.

Reference: Atari's [Stella Programmer's Guide](https://www.atariage.com/2600/programming/2600_101/docs/stella.html)
and [2600 Field Service Manual](https://www.atarimania.com/2600/files/vcs_domestic_field_service_manual.pdf).
The [Stella cartridge documentation](https://stella-emu.github.io/docs/index.html)
provides independent board nomenclature. No external emulator binary is used.

Initial validation and logs: `codex-work/at2600`. Refactoring comparisons,
legacy snapshot replay and RetroTune decoder checks: `codex-work/at2600-refactor`.
Each directory contains a `REPORT.md` with its validation scope.

Regression checks and the full collection rerun live in `codex-work/atari-fixes`.
Board behavior was checked against the Stella project's hardware implementations
([cartridges](https://github.com/stella-emu/stella/tree/master/src/emucore)) and
its [programmer documentation](https://stella-emu.github.io/docs/).
The implementations here are native Delphi modules; no emulator binary is used.
