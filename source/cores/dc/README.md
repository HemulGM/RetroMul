# SEGA Dreamcast (experimental)

This native Delphi core models the Dreamcast console: the SH-4 CPU, Holly
(system bus, interrupts and DMA), the PowerVR2 tile accelerator and renderer,
the GD-ROM drive, the AICA sound processor with its ARM7DI, and the Maple bus
with controllers, Visual Memory units and jump packs.

Open a `.gdi`, `.cdi`, `.chd`, `.cue`, `.iso`, `.mds` or `.nrg` image, an
`.m3u` playlist of them, or a homebrew `.elf` program, from the `dc` folder of
the library. `.gdi` and `.cdi` are always Dreamcast discs; `.cue`, `.iso`,
`.chd`, `.mds` and `.nrg` are recognised by the `SEGA SEGAKATANA` hardware
identifier in their boot track; Redump cue sheets of GD-ROMs (with the
high-density area comment) place that area at LBA 45000. A playlist in the
`dc` folder, or one that lists
`.gdi`/`.cdi` images, opens here. The library shows a GDI, CUE or playlist
once, without its track files or discs. Archives are not supported for disc
images.

## Disc change

The core implements the frontend's disc control (as the PlayStation core
does): the discs of a playlist, or the started image plus any opened later,
can be changed or ejected while running. A change opens the drive lid, keeps it
open for a second of machine time and closes it on the new disc; RAM, VMUs and
the system flash stay. Games notice the lid through the drive status and check
the new disc with the boot ROM's check-disc call, which reads its IP.BIN
header. Snapshots taken with the lid open resume the change.

## Boot

No firmware is required. The built-in high-level boot loads IP.BIN and the
boot program from the disc (descrambling it on CD media) and provides the
system calls programs use: system information, ROM font, flash ROM, GD-ROM
and the menu call. In Dreamcast settings:

- `Built-in (high-level)` always uses it.
- `Automatic` also loads `dc_boot.bin` (and `dc_flash.bin`) when found in
  settings, beside the image or in the `dc` ROM folder; the high-level boot
  then returns the boot ROM's font glyphs. Without it the font area holds the
  12x24 ISO 8859-1 glyphs drawn from the public domain Hershey Simplex
  strokes; full-width (Japanese) glyphs stay blank.
- `Boot ROM file` starts the console from `dc_boot.bin`: the startup
  animation, then the disc (or the system menu without one). Programs then use
  the boot ROM's own system calls, which drive the GD-ROM drive by ATA packet
  commands. The drive answers the security commands (70h/71h) with a media
  check result built from the disc, in the obfuscated form the boot ROM
  decodes: GD-ROM, or MIL-CD for CD media. Soul Calibur (self-booting CD) does
  not find its VMU in this mode; it does with the high-level boot.

Windows CE games (`0WINCEOS.BIN` boot file) run with the high-level boot. On
GD-ROM their boot file starts with a sector listing the parts to load (marked
by bit 0 of the IP.BIN peripherals); the boot loads them as the boot ROM does,
leaving that sector at 8CE01000 and the GD-ROM DMA registers where the last
part ends, which the IP.BIN bootstrap checks. The kernel enables the MMU, calls
the GD-ROM system call entry 8C0010F0 directly and is served its PIO transfers
from the drive interrupt. Images whose data track holds the GD-ROM file system
with IP.BIN as a file (some single-track `.mds` rips) boot from that file.

The system flash (region, language, broadcast standard and saved settings) is
generated for the selected region unless a 128 KiB flash file is given, and is
saved per console as `saves/dc/dc_flash.bin`. At power-on the time in its
system configuration is set to the clock's, so the boot ROM does not ask for
the date (it does when the clock is behind that time or 30 days ahead).

## Controls and peripherals

Each of the four ports holds a controller with a VMU, a controller alone, a
keyboard, a mouse, a light gun, or nothing; `Automatic` connects controllers to
all ports and a VMU to port A. A keyboard takes the host keys (US layout, or
Japanese on Japanese consoles); the mouse follows the host mouse; the light
gun aims with the mouse pointer over the picture and fires with its left
button (right: B, middle: Start), its position latched in SPG_TRIGGER_POS when
the program puts the Maple bus in light gun mode.
The analog stick uses host axes or four bindable directions; the L and R
triggers are the logical Select and Mode buttons and report analog travel from
host triggers. A jump pack occupies port A's second slot when rumble is on.
VMU contents are saved as `saves/dc/vmu_A1.bin` and so on. The VMU screen,
when switched on in Dreamcast settings (it is off by default), is drawn by the
frontend in a chosen corner of the game display; it is not part of frames,
screenshots or frame hashes.

## Implementation notes

- SH-4: block interpreter with code-page invalidation, linked blocks and
  table-dispatched operations; FPU, exceptions, store queues, OCRAM, address
  translation (UTLB, with translated 4 KiB pages cached until the TLB
  changes), INTC, TMU, DMAC, SCIF, BSC and RTC. High-level system calls reach
  the caller's memory through the MMU and let the CPU take TLB misses, then
  run again. SingleStepTests/sh4 pass
  except TRAPA (treated as a no-op by the test generator) and two double NaN
  payload cases.
- PowerVR2: the tile accelerator decodes display lists into contexts; the
  software renderer draws opaque, punch-through and translucent lists
  (per-pixel sorting), modifier volumes, fog, textures (twiddled, strided, VQ,
  palettes, mipmaps, bilinear filtering, bump maps) on worker threads,
  overlapped with the emulated CPU. Results do not depend on the thread count.
- Wait loops (a short loop that only polls memory, possibly counting down a
  timeout) are recognised after two identical iterations and run ahead to the
  next scheduler event with exactly the state the iterations would leave, with
  or without address translation.
- AICA: the shared sound generator and DSP (also used by the DSF player) with
  the ARM7DI, timers, shared interrupt registers and the RTC; CD-DA enters
  through the EXT inputs (DSP EXTS0/1, EFSDL/EFPAN slots 16 and 17).
  arm7wrestler DC passes.
- Snapshots contain the full machine, decoded TA contexts and VMU contents.

Not implemented: the modem and broadband adapter, and NAOMI/Atomiswave.

## References

Marcus Comstedt's Dreamcast pages (Maple, VMU, GD-ROM, IP.BIN, system calls,
scrambling), the Hitachi SH-4 software manual, SingleStepTests/sh4 (MIT),
KallistiOS examples and headers as usage references, ATA/ATAPI-4 for the
packet protocol, the notes on the GD-ROM security commands in MAME's GD-ROM
drive (BSD-3-Clause, format description only), public PowerVR2/Holly/AICA
register descriptions, the
240p Test Suite and arm7wrestler DC as test programs, and the Hershey fonts
(public domain). Code from GPL emulators was not used.
