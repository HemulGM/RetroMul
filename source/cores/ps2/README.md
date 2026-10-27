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
| `PS2.VU`, `PS2.VIF` | VU0/VU1 micro mode, VIF0/VIF1 command processing |
| `PS2.IPU` | IPU MPEG decoder (BDEC/IDEC/VDEC/FDEC/CSC/PACK, FIFOs on DMA channels 3/4) |
| `PS2.Kernel`, `PS2.ELF` | High-level EE kernel (threads, semaphores, interrupts, alarms, SIF DMA, syscall table) and ELF loading |
| `PS2.IOP.FileIO`, `PS2.IOP.CDVD`, `PS2.IOP.HLE` | FILEIO, CDVD and LOADFILE/IOP heap RPC servers, ISO 9660 access |
| `PS2.IOP.Pad`, `PS2.IOP.SIO2`, `PS2.IOP.MemoryCard` | DualShock 2 protocol, PADMAN/XPADMAN (pad data in libpad's areas), SIO2 for IOP pad and memory card drivers, MCSERV/XMCSERV (file-level memory cards), memory cards as flash for games' own card drivers |
| `PS2.IOP.CPU`, `PS2.IOP.Hardware` | IOP R3000A interpreter and the IOP register file (root counters, SPU2 registers and RAM, IOP DMA 4/7) |
| `PS2.IOP.Loader`, `PS2.IOP.Kernel`, `PS2.IOP.Libs` | IRX loading and linking, the high-level IOP kernel and the system libraries IOP modules import |
| `PS2.Console` | Wiring, field timing (NTSC/PAL), the run loop and snapshots |

Disc images come from `source/media/dvd/Core.DVD.Image.pas` (ISO, MDS/MDF,
DVD CHD, CD images through the CD layer). The front end lives in
`source/adapters/Core.Adapter.PS2.pas` and
`apps/retromul/settings/platform/RM.Settings.PS2.pas`.

The GS draws on the emulation thread or, by default, in band threads (one per
two logical processors, 2..8): each draws every queued primitive's rows of
its 8-row stripes, in queue order. The emulation thread counts the pixels
(GS timing), keeps each queued primitive's CLUT and waits for the threads
where a primitive reads what queued ones write (render to texture, depth over
the frame's memory, transfers, the display). The memory is the same either way.

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
