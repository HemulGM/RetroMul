# ZX Spectrum

Native Delphi core using RetroMul's MD.Z80 CPU and ZX.Sound.YM2149 AY model.
No external emulator binary is linked.

## Supported hardware and media

- Sinclair PAL 16K/48K/128K, grey UK +2, black UK +2b, UK +3, Pentagon 128K/512K/1024K, Timex TC2048/TC2068, Scorpion ZS-256, Profi+ 512K/1024K, Byte/Byte-01, Didaktik Gama 1987/1988/1989 and Microdigital TK90X/TK95 profiles with their own ROMs and memory controllers.
- 256×192 ULA display, attributes, BRIGHT/FLASH and border (320×240 output).
- PAL clocks: 3.5 MHz / 69888 T states and 3.5469 MHz / 70908 T states.
- 40-key matrix, Kempston, beeper/MIC, 128K AY sound and stereo 44100 Hz PCM.
- SNA 48K/128K and Z80 v1/v2/v3 snapshots, including ED-ED compressed memory, Pentagon mode 9, +2 mode 12 and the 16K/+2 hardware-modifier flag.
- Standard and Extended DSK on +3 drive A through the existing native 765/DSK components; original +3DOS firmware, writable overlays and in-flight snapshots.
- TRD/SCL disks through a native Beta 128 / WD1793 controller and original TR-DOS 5.03 ROM.
- TAP and TZX playback through EAR at original tape speed, with automatic `LOAD ""` entry.

Place games in `zxspectrum/` under the ROM root (`zx/` and `spectrum/` are aliases).
ZIP/7z containing a supported image are accepted. A ZIP release with equivalent
TRD/SCL plus a reference SNA prefers TRD, then SCL. Multiple ZIP images of the same preferred kind
remain ambiguous. TRD/SCL auto-select Pentagon 128K; select Pentagon in the machine
setting for compatible tapes or SNA files without model metadata. Z80 mode 9 and
SNA's TR-DOS-active flag select Pentagon automatically. 128K/Pentagon tapes boot
48 BASIC while retaining banking and AY.

## Machine profiles

`ZX.Machine` defines the supported models and their RAM, paging, sound and PAL
timing descriptors. The console, worker and frontend pass `TZXMachineConfig`;
legacy boolean overloads remain available to existing callers. The existing
`Hardware/TapeModel` key and its 48k/128k/pentagon/pentagon512/pentagon1024 values
are preserved, with new `16k` and `plus2` values. Unknown configuration IDs retain
the previous 48K fallback. `plus2b` and `plus3` add the ASIC machines; `tc2048`, `tc2068` and `scorpion` add native Timex and Scorpion; `profi512` and `profi` add Profi+ 512K/1024K; `byte` / `byte01` add Byte and Byte-01; `gama87` / `gama88` / `gama` add Didaktik Gama; `tk90x` / `tk95` add Microdigital; the UI exposes twenty-one profiles.

16K installs RAM only at 4000..7FFF, ignores upper-memory writes and returns FF
on upper-memory reads. This is an explicit digital open-bus approximation, not
certification of analog bus behaviour for every board. The original Sinclair ROM
detects physical RAM ending at 7FFF and runs its normal tape loader without traps.

128K and grey +2 share the 128K paging/timing controller but select separate UK
editor and BASIC ROM pairs. +2b/+3 use their separate ASIC memory controller and four-ROM sets.
RS232/keypad devices remain outside the implementation.

Tapes use the selected profile and 128K-family tapes start in that model's own
48 BASIC ROM. SNA lacks a 16K/+2 model tag: a selected 16K is retained for a 48K
container (its saved return address must be in installed RAM). A 128K SNA
retains any selected motherboard with compatible 128K paging, including expanded
Pentagon/Scorpion/Profi profiles. Other SNA files use automatic 48K/128K/Pentagon selection. Z80 v2/v3 hardware metadata selects its exact model;
mode 12 identifies +2, and byte 37 bit 7 maps 48K to 16K or Sinclair 128K to +2.
16K Z80 files may contain only page 8 or include padded upper-memory pages.
Ambiguous Z80 v1 and 48K SNA files retain selected 16K or Timex profiles, otherwise select 48K. Timex snapshots of Spectrum programs need the appropriate HOME emulator cartridge. Explicit Pentagon
selection retains the existing snapshot override. TRD/SCL still auto-select
Pentagon 128 unless an expanded Pentagon, Scorpion or Profi profile was selected.

Native state version 27 stores a validated machine identifier, attached device state,
DMA USC bus continuation, MoonSound/FM/PCM/flash and eZX/MB SID state; earlier native state
versions are rejected. Restoring a state selects the matching embedded ROM pair.
Reset retains the current machine profile; frontend reset reloads the original
media using its configured profile.

The complete 68-item checklist, including planned features and explicit limits,
is in [the support registry](../../../codex-work/zx-package1/SUPPORT.md).
Package validation: [VALIDATION.md](../../../codex-work/zx-package1/VALIDATION.md).

## Microdigital TK90X / TK95 and configuration presets

Select `tk90x` or `tk95` for the original 48K Microdigital MC16845 family.
Four Portuguese/Spanish 16 KiB ROM images are embedded unchanged (64 KiB).
The ROM-language option also selects the Brazilian D7 clamp versus export-board
floating D7 policy. Standard 60 Hz timing uses a 14.302444 MHz master / 4,
228 T per line and 262 lines; the 50 Hz pin setting uses 312 lines at the same
clock. Frame rates are derived from those counters, rather than rounded to
50/60. Display RAM remains 4000..7FFF with contention; 7FFD is not a pager.

Native keyboard reads have driven keyboard bits and independently inverted EAR,
with no beeper-latch feedback into that input. Unused D5/D7 follow the digital
video bus where appropriate. MC16845 FLASH uses a 32-frame half-cycle, and the
Ferranti refresh/snow corruption path is not applied to this ULA. Memory and
I/O contention have a separate MC16845 timing path. These are T-state-level
presets derived from circuit/reconstruction evidence, not pin-perfect hardware
certification; analog bus hold and board phase variations remain approximate.

The factory joystick uses Interface 2 keys 67890. TK presets select that mapping;
manual configurations can choose the existing keyboard/Kempston alternatives.
Both models and languages load tapes through their original ROMs. Autoload waits
100 extra frames for startup. Explicit 48K SNA/Z80 imports retain TK model,
timing and ROM language; native v19 states preserve those options and running
hardware state. TRD/SCL retain the existing automatic Pentagon selection policy.
Early Ferranti TK90X boards, earlier/custom ROM revisions, printer, light pen,
native Beta 48 adapters and electrical PAL-M/PAL-N color encoding are outside
this MC16845 package's scope.

The settings page starts with **37 ready presets** and a Custom entry. They cover
all 21 machine profiles, TK frequency/language variants, Atarin on Pentagon 128K,
Turbo Sound, Turbo Sound FM, Next-DAC, General Sound 128K/512K, NeoGS 512K/2M/4M, ULAplus and esxDOS configurations. Selecting a preset replaces the
machine, interface, sound, input and media preferences in the draft; master
volume, rendering/shaders and button bindings are retained. Optional BIOS paths
are reset to embedded firmware. A selected CF/SD image is retained for CF/SD
presets; other presets detach it. Apply saves; Cancel discards the draft.

Manual hardware changes select Custom. A persistent, scrollable notification
panel reports all known conflicts before Apply, including Pentagon 1024SL EFF7
versus CF/SD, Scorpion shadow ROM versus esxDOS, ATA/Covox B3 and Timex/SAA1099 FF.
The UI and runtime adapter use the same hardware reader/validation rules.
Advisories explain ignored attachments, missing CF/SD media and the older Gama
esxDOS autoboot limitation. Invalid configurations cannot be saved. Notifications
remain visible across ZX categories and are hidden on other cores.

Validation and sources: [TK/presets report](../../../codex-work/zx-tk/VALIDATION.md).

## Didaktik Gama 80K

Select `gama87`, `gama88` or `gama` (1989). All three original 16 KiB ROMs
are embedded unchanged: **48 KiB total**, with no external BIOS path. Profiles
retain the 48K PAL Ferranti timing, keyboard, ULA contention and beeper.

The lower 16 KiB RAM at 4000..7FFF is shared; PC0 of the on-board NMOS 8255
selects one of two independent 32 KiB RAM banks at 8000..FFFF. The PPI's
A/B/C/control registers normally use 1F/3F/5F/7F. Only A7 selects the device;
A5/A6 choose a register. A0..A4 and the high byte are ignored, so even aliases
also write the ULA and combine its keyboard read with the PPI on the data bus.
The implementation includes mode/direction words, separate output latches,
BSR, reset and strobed-mode status with disconnected external handshake pins.
PC0 follows its physical function, including input mode and group B INTR.

Controller 1 uses the factory PPI A Kempston adapter when Kempston is enabled.
The existing second-joystick option connects controller 2 to PPI B (port 63)
on Gama, rather than Interface 2 keys. Configuring a port as output exposes its
output latch rather than joystick contacts. Printer, plotter and parallel-mouse
backends are not attached; /STB and /ACK remain high, with no fabricated
acknowledgements or input bytes.

Original ROMs perform their own initialization and bank-copy routines. Tape
autoload waits an additional 50 frames for the 1989 ROM to enter BASIC. The
1989 firmware's BASIC `OUT 127` routine works with RAMTOP/stack above 8000;
no host copy trap or ROM patch is used. Earlier ROMs retain their original
bank-switch behavior; programs should lower RAMTOP before switching banks.

Explicit Gama selection survives 48K SNA/Z80 import, initializing PPI mode 92
and base bank 0. Those formats do not describe the hidden 32K bank; 128K
imports are rejected for explicit Gama profiles. Native v19 states preserve
both banks, ROM revision, PPI control/latches and pending output/INTE state.
TRD/SCL continue to select Pentagon through the existing media policy.

Both divIDE and divMMC boot original esxDOS 0.8.9 with the 1989 ROM, including
FAT file APIs and BASIC LOAD/SAVE. The 1987/1988 ROMs reinitialize PC0 after the
esxDOS autoboot hook and lose its autoboot BASIC program; their NMI/browser
entry is tested, but autoboot is not supported. Choose Gama 1989 for that
combination. The original ROMs and PPI reset behavior are preserved.

Sources, firmware hashes and validation:
[Didaktik Gama report](../../../codex-work/zx-gama/VALIDATION.md).

## Byte / Byte-01 with KVU.04

Select `byte` for the original 48K Byte and its compatibility switch, or
`byte01` for the 128K Byte-01. These machines retain a 3.5 MHz CPU and 69888-T
frame, but use their own PROM-controlled video RAM arbitration, 33-T interrupt
and 25-frame FLASH phase. Original Byte ROMs and DD66/DD71 compatibility PROMs
are embedded; the switch takes effect after a Kempston decoder read enables
the hardware overlay. Native Byte-01 uses its separate embedded ROM.

Byte-01 F0 controls eight physical RAM banks: video RAM 0..3 and main RAM 4..7,
including all-RAM, alternative 32K main bank, low-window overlay/write protection
and NMI inhibit. Adapter DD13 supplies the UPRTRDOS rising-edge / 3Dxx
opcode latch, selecting BASIC RAM6 or DOS RAM7 until an opcode fetch above
3FFF releases it. Spectrum 7FFD paging and AY are absent. Spectrum video is
expanded to a stable 640x480 surface; native port 05 provides 512x192 monochrome
output with a global colour attribute and interleaved 4000/6000 bitmap bytes.
Optional Timex modes and ULAplus remain available in compatible video mode.

The extended keyboard includes native Cyrillic/language keys and editing chords.
EAR polarity is inverted on both machines. Three native VI53/8253 channels run
at the board's 3.5 MHz clock, with a separate live volume setting. Counter state,
partial LSB/MSB writes and output phases survive native state restore.

`.kdi` selects Byte-01 and accepts raw 80-cylinder, two-head images with five
1024-byte sectors numbered 1..5. These are distinct from Profi PRO's boot-sector
ID 9. Native KVU ports 08/28/48/68 and system port 09 reuse the WD1793 engine.
Original ROM boots the original CP/M disk without traps; automatic loading
chooses menu item 1 (CP/M). Turn Auto-load off to use the original menu manually.
Original TR-DOS 5.04 also boots from the system KDI; after replacing it with
a working TRD in the controller, the original RAM TR-DOS command loop reads its directory using CAT.
It borrows the Spectrum line editor, so CAT is entered with extended mode
and SYMBOL SHIFT + 9. This native variant uses KVU ports rather than legacy Beta ports.
Dirty KDI overlays, state and reset retain their native geometry. CF/SD must
be disconnected for native KDI boot; esxDOS card boot is independently tested
on both Byte profiles and both interfaces.

Tape autoload uses each machine's own ROM. Explicit Byte selection is retained
for 48K SNA/Z80 imports; 128K Spectrum snapshots are rejected because their
paging does not describe Byte-01. Native states preserve all Byte-01 RAM.
KVU serial/parallel/network devices, Byte-A ROM adapters, nonstandard timing
PROM revisions and protected/flux disk formats are outside this package.
Host disk replacement controls are not provided; KVU working-disk transfers
are exercised through the core controller. Timing and analogue audio levels
are not physical-board certification.

Implementation, firmware hashes and regression results:
[Byte validation](../../../codex-work/zx-byte/VALIDATION.md).

## Profi+ 512K / 1024K

Select `profi512` or `profi` for the original 3.5 MHz Profi+ architecture.
The four original BIOS 2.1 banks (64 KiB total) are built into the executable.
Native 7FFD/DFFD paging addresses 32 or 64 banks; absent A19 mirrors on 512K.
DFFD supports moving the paged window to 4000 (SCO), RAM0 over ROM / lock bypass
(NORM), RAM6 at 8000 when SCR and the second-screen bit are both set, and CP/M
peripheral decoding. Native AY and Beta/WD1793 are reused; no display RAM or
I/O contention is inserted. Frame geometry is 224 T/line, 69888 T/frame with a
28-T interrupt; the video phase is an independently cross-checked emulator
preset, not a measurement-based certification of all board revisions.

DFFD bit 7 selects DS80: 512x240, bitmap banks 4/6 and attribute banks 56/58
(24/26 on 512K). Address halves alternate across each row. Every eight pixels
have independent ink and paper brightness; attribute bit 7 does not flash.
The original 16-of-256 palette uses inverted A8..A15 in GGGRRRBB order and the
previous FE latch for its index; writes require DS80+CPM+BLOCK. Output stays
640x576 across mode changes; DS80 doubles vertically, Spectrum mode doubles
in both dimensions. Fetch latches and mid-frame state are preserved. Optional
ULAplus and compatible Timex modes still apply in Spectrum mode.

Open `.pro` to choose Profi 1024K, retaining an explicit Profi 512K choice.
Raw PRO images support 80 cylinders, one or two heads, five 1024-byte sectors;
track 0 side 0 has sector IDs 1,2,3,4,9, with ID 9 containing the boot loader.
Other tracks use IDs 1..5. Original firmware starts the system from disk;
no CP/M calls or boot code are patched. Real SP-DOS loads BIOS/BDOS, console
and startup programs from the author-provided ReadFile.pro image. Native
WD1793 handles sector reads/writes, size-code 3, protection, dirty overlays,
in-flight state and remount after reset. TRD/SCL retain the selected Profi.
Native CP/M media require divIDE/divMMC disabled; esxDOS card boot is separately
verified in Spectrum mode on both Profi memory sizes and both interfaces.

SNA/Z80 Spectrum imports retain the explicit Profi selection; these formats
do not describe its full MMU, DS80 palette or all 64 RAM banks. Use native
states for full restoration. CPU turbo, Profi IDE, RTC, serial/parallel devices,
8255 peripherals and FDI/UDI/flux/protected media are not included. Mechanical
disk timing and palette DAC transfer characteristics remain approximations.

Validation and original references: [Profi report](../../../codex-work/zx-profi/VALIDATION.md).

## Timex TC2048 / TC2068 and Scorpion ZS-256

Select `tc2048` or `tc2068` for the PAL machines at 3.5 MHz, 224 T/line,
69888 T/frame. SCLD display modes are always available, with a stable 640x480
surface, full low-byte FE/F4/FF port decoding and their own raster phase.
Both original ROMs boot BASIC and load TAP through real EAR pulses.
TC2048 has 48 KiB RAM and its 16 KiB ROM. TC2068 adds the original HOME/EXROM
firmware, HSR F4 (eight 8 KiB windows), FF bit 7 DOCK/EXROM selection, and AY
address/data ports F5/F6. EXROM mirrors its 8 KiB throughout the bank. AY register
14 reads active-low joystick pins: A8 selects controller 1, A9 controller 2;
both selected sockets are ANDed. This native joystick wiring is independent
of optional Spectrum keyboard/Kempston mapping.

Open `.dck` to select TC2068 and boot HOME, LROS or AROS cartridges. DCK supports
HOME (255), DOCK (0), EXROM (254), ROM and initialized/empty RAM chunks, including
multi-bank images. Invalid/truncated or duplicate bank records are rejected.
For tapes/snapshots, Settings / Video / Timex TC2068 cartridge attaches an optional
DCK at startup/reset. Spectrum software on TC2068 generally needs a Spectrum
HOME emulator cartridge. DCK data and writable cartridge RAM survive native
states. Z80 modes 14/15 import the TC model, HOME RAM, AY and HSR/DEC registers;
Z80 does not store arbitrary cartridge banks. NTSC TS2068 (mode 128), external
memory bank controllers and cartridge RAM battery sidecars are not implemented.

Select `scorpion` for the original 3.5 MHz ZS-256 with four original v2.94 ROMs.
1FFD bit 4 extends C000 paging to sixteen RAM banks; bit 0 maps RAM0 over ROM;
bit 1 selects the shadow service ROM. The 7FFD bit-5 lock leaves 1FFD writable.
Motherboard 1FFD/7FFD, AY and FDC aliases have separate decoders. The model
uses a 69888-T frame and no screen-memory/I/O contention, with even M1 alignment.
TRD/SCL retains a selected Scorpion and boots its own TR-DOS ROM; default disk
selection on other profiles remains Pentagon. Selected Scorpion also retains
legacy SNA/Z80 imports; mode 10 imports all sixteen RAM pages and v3x 1FFD.
F9 requests Magic: NMI waits for guest RAM execution, maps the shadow ROM and
runs the original monitor. Its Continue command restores guest execution.
Native states retain 1FFD and pending Magic/ROM-override latches.

Scorpion Turbo/Turbo+, GMX, SMUC and printer/serial devices are separate work.
The built-in esxDOS firmware does not boot with this shadow ROM; configuration
therefore requires divIDE/divMMC disabled on Scorpion. TC2048 esxDOS boot is
verified; TC2068 requires a compatible HOME cartridge for Spectrum ROM services.

References, fixtures, accuracy limits and regression results:
[Timex validation](../../../codex-work/zx-timex/VALIDATION.md),
[Scorpion validation](../../../codex-work/zx-scorpion/VALIDATION.md).

## +2b / +3 ASIC and disks

Select `plus2b` for the black UK v4.1 machine (without FDC) or `plus3` for UK
v4.0. Both have 128 KiB RAM, four 16 KiB ROM banks and 1FFD/7FFD paging,
including all four all-RAM maps and the paging lock. ASIC banks 4–7 are
contended; ULA I/O is not. Unattached ports return FF, refresh snow is disabled,
and EAR input does not echo the beeper output. The display starts at T14364;
contention begins at T14365 with delays 1,0,7,6,5,4,3,2.

Opening DSK auto-selects +3 and attaches drive A. With auto-load enabled the
original menu Loader is selected by a keypress; ROM and Z80 execute the disk
operations without traps. 2FFD is FDC status, 3FFD data, 1FFD bit 3 motor.
Existing native `SG1000.FDC` / `SG1000.Disk` components supply the 765 and DSK
implementation. The +3 instance uses its own host clock and missed-byte
overrun detection; the SF-7000 instance retains its previous defaults.

DSK sector writes and formatting go to the normal per-game saved overlay;
the original media file stays unchanged. Reset retains dirty sectors, and
states retain the image, motor, seek state, result phase and partial transfer.
The existing live write-protection option also applies to +3.

Z80 v3 modes 7/8 select +3; mode 13 and the +3 modifier select the compatible
+2b profile. A 55-byte extension restores 1FFD. SNA and older Z80 containers
cannot represent 1FFD and keep their existing 48K/128K selection rules.
Tapes on ASIC profiles boot their own ROM 3 and use the real EAR loader.

DSK containers are shared with SF-7000. Raw 160 KiB images, recognizable
40x1x16x256 Sega DSK geometry and explicit `sf7000`/`sg1000` paths or SF-7000
names retain Sega dispatch. Other DSK containers default to +3; ambiguous
Sega images should be placed in the Sega system folder. ZIP can select a DSK
ahead of a reference snapshot and still rejects multiple preferred images.

Drive B, hot media swapping, flux formats and protected/weak-sector accuracy
remain future work. Rotational latency and analog drive behaviour are approximate.
Printer/serial devices and +3e IDE firmware are not implemented by this package.
See [the package checks](../../../codex-work/zx-plus3/VALIDATION.md).

## divIDE / divMMC and esxDOS

Hardware settings offer `Hardware/DivType=none|divide|divmmc`, `DivRAMKB=128|512`,
an optional raw `DivImage` path and optional 8 KiB `DivFirmware` override. The
default interface is disconnected. divIDE has 32 KiB RAM; divMMC has 128/512 KiB.
The closed EEPROM jumper protects firmware from guest writes. Empty firmware
uses the original esxDOS 0.8.9 ROM for the selected interface.

Open a raw `.ide` or `.mmc` image directly to boot its interface. This overrides
the running interface without changing the saved global preference. Images must
contain 512-byte sectors; HDF headers and card images inside ZIP/7z are not
supported. Existing tape/snapshot launches can attach the image selected in
settings. Interface and source changes take effect when opening media.

esxDOS also requires the matching SYS/BIN directories (and TMP for divIDE) on
the FAT card. Only the ROM is embedded. Use the system files from the official
[0.8.9 release](https://www.esxdos.org/files/esxdos089.zip). FAT is interpreted
by the original firmware running on Z80; the host supplies only raw sectors.
No RST syscall, BASIC loader or filesystem trap substitutes for firmware code.
F9 presses the interface NMI button; nested NMI while external memory is mapped
is inhibited. The original NMI.SYS browser runs from the card.

The automapper changes at refresh after entry/off-area opcode reads, with
immediate mapping at 3Dxx. CONMEM, sticky MAPRAM and the protected RAM-3 window
are preserved. Ports decode their low byte; divIDE resets its odd/even ATA
latch on other interface-register accesses. divMMC E7 selects the card and EB
models the receive latch and byte transfers. SPI reads clock an additional FF.
SDSC uses byte addresses and SDHC uses block addresses.

Sources are file-backed and immutable; only changed 512-byte sectors enter the
sparse `.div` sidecar. SHA-256 binds changes/states to the source and protects
sidecar contents. The source handle stays open; worker restarts reuse the
computed identity. Opening a large image still requires one full hash read.
Native v13 states retain mapper/RAM, ROM override, ATA word latches, SPI command,
reply/write buffers and dirty sectors. The same original source must be mounted
before loading a card state. Live protection is reapplied after state load.
Reset power-cycles interface/CPU RAM while retaining changed card sectors.

Drive/slot 0 only is connected. ATAPI/slave devices, EEPROM programming, full
SD command coverage and cycle-exact ATA/SPI timings remain future work. Source
size is limited to 128 GiB and changed sectors to 32 MiB per image/sidecar.
The legacy 1024SL EFF7 decoder conflicts with Div ports; choose Pentagon 128/512
or disable Div. Classic Pentagon disables native Beta automapping while Div is
attached; direct TRD/SCL boot therefore requires Div disabled. esxDOS virtual
TRD files belong on its card. GS-port Covox B3 conflicts with divIDE ATA and is
rejected in configuration. Native +3 FDC remains available, but its menu-loader
startup can be superseded by the selected Div firmware.

Validation: [CF/SD package report](../../../codex-work/zx-div/VALIDATION.md).

## Pentagon and TR-DOS

Pentagon uses 3.5 MHz, 224 T/line, 320 lines and 71680 T/frame (48.828125 Hz).
The active display begins at T17984; INT is 36 T long. Classic Pentagon RAM/I/O are not contended,
refresh snow is disabled and the unattached bus returns FF. The classic bit-5
paging lock is retained on the classic 128K and 512K models. Select expanded
models explicitly in settings; automatic disk selection remains classic 128K.

Pentagon 512K maps 32 banks through 7FFD bits 0–2, 6 and 7 and retains bit-5 lock.
Pentagon 1024K maps 64 banks through bits 0–2, 6, 7 and 5. EFF7 bit 2 selects
128K compatibility: set it to mask all extended bank bits and restore bit-5 lock;
clear it to enable 1024K paging again. The 1024K profile now uses the 1024SL
CPLD's EFF7 decode `(port and F008)=E000`, so probes for other devices cannot
accidentally change video or CPU speed. EFF7 remains writable while 7FFD is locked.
The fixed RAM windows and ULA screen banks remain 5/2 and 5/7.

### 1024K extended hardware

- EFF7 D4: clear for 7 MHz CPU, set for 3.5 MHz. Startup uses D4=1 for compatibility
  with tapes/older diagnostics. The 1024SL 2.2 clock selector is latched on OF7,
  including its DOS/RFSH input. WAIT is evaluated on CPU falling edges at T2/Tw:
  RAM waits for HL/OCAS, I/O uses the separate delay DFF (including interrupt
  acknowledge). The ideal digital circuit advances at 28 MHz half-periods of
  the 14 MHz master. Video, AY, tape, WD1793 and RTC retain the base clock.
  Master phase and WAIT/clock/grant DFFs survive snapshots; software frequency
  changes do not round away partial clock pulses. This models the original
  logical equations, not analog propagation delays or every Z80 pin callback.
- D0: 16C, 256x192 pixels with independent standard-palette color per pixel,
  interleaved C000/4000/E000/6000 pixel pairs and screen-bank selection. Active
  display drives BUSRQ from the CPLD's unregistered BORDO signal. Raster
  transitions occur on Z rising (master phase 2). The CPU samples BUSRQ at the
  rising edge of the last T of each machine cycle and asserts BUSACK on the
  next rising edge. It completes all Tw and refresh clocks before yielding.
  BUSACK holds address/data/control buses released; Tx clocks continue video,
  sound, disk and RTC. Release is sampled synchronously, with a final Tx before
  the CPU resumes. Separate internal machine cycles (ADD/ADC/SBC HL, branches,
  indexed address calculation, RLD/RRD, block repeats) have explicit boundaries;
  short extensions such as INC HL remain part of their preceding cycle.
  A suspended instruction can cross frames/save states. Its completed reads and
  writes are journaled so decoder continuation does not repeat side effects.
  Combining 16C with 384 mode holds BUSRQ continuously without freezing video.
- D1: VMG 512x192 monochrome, alternating +0000/+2000 bitmaps. The output is
  640x480 including border and doubled scanlines to preserve pixel aspect.
- D5: hardware multicolor, a separate attribute byte for each bitmap scanline.
- D6: full 384x304 raster with the documented non-linear bitmap/attribute map.
  No extended area is cropped to the previous 320x240 output. Frame dimensions,
  normal worker publication and snapshot previews follow the active mode.
- D3: map writable RAM bank 0 at 0000..3FFF instead of ROM.
- D7: Gluk CMOS enable. DFF7 selects a 7-bit RTC register, BFF7 reads/writes it;
  decode is `(port and F008)=D000/B000`. The MC146818/DS12887 model provides
  BCD/binary, 12/24-hour, SET/UIP, calendar/leap years, programmable weekday,
  alarm/update/periodic status and clear-on-read C. Its IRQ pin is not wired to
  Z80 INT. CMOS ticks at base bus speed, is included in snapshots, survives
  reset and is saved atomically as `zx.cmos` beside the machine config. Across
  closed sessions its clock advances by the elapsed host time. During a paused
  emulation it freezes with the other emulated devices.

The optional **Pentagon service ROM** setting accepts a 16 KiB Gluk ROM or a
64 KiB GLUK/DOS/128/48 ROM set. The latter is recommended when the firmware
requires a matching DOS version. The service ROM and its menu are genuine Z80
execution; no ROM-service traps are injected. Leave it empty for the existing
classic disk auto-boot. A blank CMOS battery has zeroed settings RAM; Gluk's
own configured/not-configured marker and menu preferences are software settings.
The test fixture initializes these explicitly, without modifying program bytes.

16C and 384x304 follow the standard SL modifications; 512x192 and hardware
multicolor are common alternative-firmware extensions. This is a defined
compatible feature set, not a claim to reproduce every 1024SL CPLD revision.

Beta 128 pages the TR-DOS ROM on M1 at 3D00..3DFF with 48 BASIC selected and
unpages it on a RAM opcode fetch. Ordinary data reads do not page the ROM.
Ports 1F/3F/5F/7F/FF expose command/status, track, sector, data and DRQ/INTRQ/system
control while the ROM is selected. The native controller implements restore,
seek/step, sector read/write and multi-sector transfers, read address, synthesized
read track, standard MFM write-track formatting, force interrupt, reset, missing
media/record errors, lost data and write protection. MFM byte slots are 112 CPU T
and rotation is 300 RPM. Four drive selects exist; the frontend mounts drive A.

TRD supports standard 40/80-cylinder, one/two-sided 16x256 layouts and shortened
images whose omitted trailing tracks are unused. SCL builds an equivalent TRD,
validating sizes and the arithmetic checksum; both existing checksum byte orders
are accepted. Original program bytes are not patched. Auto-boot uses actual ROM
menu keys and RUN, not traps or injected disk service results. Original archives
and images remain untouched. Dirty disk content is saved as a per-game .sav
overlay, restored next session, retained across reset and included in snapshots.

## Clocked hardware

The Z80 emits opcode, refresh, memory, I/O and internal bus cycles. ULA, audio,
interrupt level and EAR advance during those cycles, including inserted WAITs.
Contention uses the 6,5,4,3,2,1,0,0 sequence from T14335 (48K) / T14361 (128K),
with the model's line period and bank mapping. I/O uses all four contention
patterns; high I/O addresses C000..FFFF do not inherit paged-RAM contention.
Internal cycles retain their addresses, including IR and the BC repeat address
of OTIR/OTDR. Read-modify-write and indexed instruction cycles are ordered.

ULA fetches bitmap and attribute bytes into latches before drawing pixels.
Later CPU writes cannot change bytes already fetched. Floating bus exposes the
fetch sequence and idle slots; border changes are quantized to pixel groups.
An NMOS refresh snow approximation mixes the refresh address into the ULA fetch.
Instruction overrun into the following frame is retained rather than discarded.

Z80 v3 images restore their saved frame phase, including quarter-counter wrap;
v1/v2 images retain their format's default frame start.

Save states include hardware phase, ULA latches, partial framebuffer, audio phase
and TZX control stacks. ZX state format is version 16, including the exact machine profile, edge-timed transfer counters, BUSACK/Tx ownership and instruction continuation, master phase, WAIT/clock DFFs, video dimensions, service ROM, CMOS, expanded RAM, EFF7, tape presence, the controller and writable media; earlier
versions are rejected rather than interpreted with the new layout.

## TZX blocks

| IDs | Implementation |
| --- | --- |
| 10–15 | Standard/turbo data, tones, pulses, pure data, direct recording |
| 18 | CSW RLE and Z-RLE, native RTL zlib decompression and fractional sample timing |
| 19 | Generalized pilot/data alphabets, PRLE, packed symbols and polarity flags |
| 20–28 | Pauses/stops, groups, signed jumps, loops, calls/returns and interactive selection |
| 2A–2B | Model-dependent 48K stop and explicit signal level |
| 30–35 | Text/messages, archive/hardware/custom metadata; legacy emulation info is skipped |
| 40 | Legacy embedded SNA/Z80 snapshot, then continue tape |
| 5A | Concatenated-file glue |
| 16–17 | Legacy C64 ROM/turbo waveform encoding; this does not emulate C64 hardware |

Unknown future extension blocks are skipped using their declared length.
Length errors, invalid symbols/targets, unbounded zero-time control flow,
excessive stacks and decompression expansion are rejected. Limits are 8 MiB per
image, 100000 blocks, 64 nested loop/call frames and 16 million pulses per wave.
Loops/jumps execute at playback time; they are not flattened into repeated audio.

F7 toggles tape play/pause; F8 rewinds. The virtual pad provides TAPE and REW.
A zero-length pause stops at its current position; play resumes the next block.
For select blocks press 1–9; 0 advances pages when there are more than nine choices.
These keys also work through the screen keyboard. Tape controls work while the
emulator is paused. Message blocks with time zero wait for play/acknowledgement.

Physical Shift is CAPS SHIFT; Ctrl is SYMBOL SHIFT. Touch modifiers latch for
combinations. By default, pad directions also press QAOP, Fire presses Space, Enter presses
ENTER and Select presses 1. Kempston and keyboard mappings are supplied together.

## Compatibility limits

The target is Sinclair PAL 16K/48K/128K/grey +2 and Pentagon 128K timing with optional 512K/1024K RAM and a Zilog NMOS CPU. CPU instructions still
retire as units; this is not a transistor/pin-level model. ULA silicon variations,
refresh snow, interrupt-acknowledge pin phases and analog EAR settling are not
certified against every board. The NEC contention suite is a useful additional
comparison, not certification of a NEC CPU model.

Cache, extended 512-color palettes/FE37, CMOS DS1685 bank extensions, Interface I and Multiface
are not implemented. TRD/SCL are sector containers, so weak bits, nonstandard
sector IDs/sizes, deleted data marks and flux-level protection are not preserved.
Read-track gaps are reconstructed rather than captured from a physical disk;
mechanical/analog details are approximate. TAR archives of +3DOS files are not
executable Spectrum snapshots or tapes.

## References and verification

- [48K hardware reference](https://worldofspectrum.net/faq/reference/48kreference.htm)
- [128K hardware reference](https://worldofspectrum.net/faq/reference/128kreference.htm)
- [TZX specification 1.20](https://worldofspectrum.net/TZXformat.html)
- [Z80 snapshot format](https://worldofspectrum.net/faq/reference/z80format.htm)
- [Hardware diagnostic catalog](https://github.com/redcode/ZXSpectrum/wiki/Tests)
- DSP Emulator was consulted as a system checklist; its drivers were not ported.

`codex-work/tools/BuildZX.ps1 -Tests ZXTests,ZXAccuracyTests,ZXTapeTests,ZXFrontendTests,ZXDiskTests,ZXExpansionTests,ZXPentagonSLTests,GenesisZ80Tests`
checks the core, bus timing, tape interpreter, worker/transport, UI and shared Z80.
`BuildZXProjects.ps1` builds Debug/Release Win32/Win64 through MSBuild.
Floating Spy passes its full 48K and 128K self-tests; external Z80 Full reports
all tests passed. The disk/model update adds 575 controller/media/worker checks. ATARIN and TbMA
boot from TRD/SCL through the actual frontend worker; each matched its TRD/SCL
framebuffer at the same emulated frame. See `codex-work/zx-disk/VALIDATION.md`
for earlier captures and timing-test scope. See `codex-work/zx-expansion/VALIDATION.md`
for expanded-memory verification and the unmodified PENTTEST 9/9 result.

Expansion references: [VELESOFT hardware design](https://velesoft.speccy.cz/pentagon512_interface.htm),
[Alone Coder on EFF7 and paging](https://www.zxpress.ru/ru/ezines/born-dead/10/tehnicheskie-podrobnosti-kompyuterov-semeystva-pentagon-osobennosti-pentagon-1024-upravlenie),
and the Z80 format reference above.

Extended hardware validation, original program sources and captures:
`codex-work/pentagon-sl/VALIDATION.md`. Primary hardware reference:
[Pentagon 2.2 CPLD](https://github.com/koe1234/pentagon_2.2/tree/main/CPLD);
RTC reference: [DS12887 datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/ds12885-ds12c887a.pdf).

Turbo WAIT verification: `codex-work/pentagon-wait/VALIDATION.md`. The independent
AHDL evaluator reads the author's original CPLD equations and supplies 1440 bus
vectors, 12 interrupt vectors and 32 software clock-switch vectors. Actual paced
worker runs boot Pang 16C, ACEx1.08 in 512/384 modes and Gluk, with captured WAIT
counters and restored native snapshots. Z80 WAIT sampling reference:
[Zilog UM008011, pp. 7–13](https://www.zilog.com/docs/z80/um0080.pdf).

16C BUSRQ/BUSACK validation: `codex-work/pentagon-busack/VALIDATION.md`.
The reference uses the author's BUSRQ equation and explicitly grouped Zilog
machine-cycle stimuli; 1512 instruction vectors cover first/last display lines,
3.5/7 MHz, WAIT, refresh, internal machine cycles and HALT. Snapshot tests pause
between an input read and memory write, and between two committed writes.
Original Pang 16C and Biver 16C execute through the paced application worker.

### 1024SL memory and port data fronts

CPU callbacks now split each data transaction at its setup prefix; the same
transaction continues through WAIT and performs the actual value access at the
hardware strobe. Opcode reads use a separate latch, including ignored HALT fetches.

| Access | Sampling/commit point |
|---|---|
| M1 opcode byte | T3 rising, before refresh |
| Ordinary memory byte / IN | T3 falling after all Tw |
| CPU memory write completion | T3 falling (/WR rising) |
| DRAM storage update | CAS falling with WE low, or late WE falling while CAS is low |
| FE border/beeper register | IORQ/WR assertion at T2 rising |
| EFF7 / 7FFD | Each falling CLK while IORQ/WR are asserted, including Tw |
| AY address/data, CMOS, BetaDisk output | End of write mode at T3 falling |

The complete 1024SL CAS-low window is master phases 1..4. This fixes a previous
quarter-base-T offset of the storage write strobe. EFF7 D4 therefore affects the
clock-selector DFF during its own OUT cycle. Even FE aliases do not latch EFF7 or
7FFD; the independent AY select includes A13 as specified by the auxiliary CPLD.

`TransferCount`/`LastTransferMaster` and an optional `SetTransferObserver` expose
CPU data latches, physical RAM writes and decoded register strobes for diagnostics.
These counters survive state restore. Debug/host ReadMemory/WriteMemory/ReadPort/
WritePort methods remain immediate; CPU accesses go through the timed bus adapter.
Snapshot continuation reuses completed latched values and suppresses repeated
physical operations. Normal snapshots are taken at instruction/BUSACK boundaries.

Data-front validation and original program captures:
`codex-work/pentagon-transfer/VALIDATION.md`. Independent original-AHDL stimuli
supply 1056 instruction cases and 4144 exact data/device events, including RAM,
ROM, all-RAM, slow/turbo, 16C arbitration, device aliases and in-cycle turbo changes.

## Spectrum settings

In Video/Audio, select the machine and optional Pentagon 1024 service ROM.
The common page already provides image filtering, shader/CRT effects and master
volume; controller bindings remain in Controls.

Additional Spectrum sound options are AY-3-8912/YM2149 chip characteristics,
mono or ABC/ACB/BAC/BCA/CAB/CBA panning, and independent 0–100% PSG and beeper/MIC
volumes. Stereo labels specify left/centre/right channel order. These settings
apply live and do not attach an AY expansion to 16K/48K machines.

Peripherals provides physical keyboard input; Kempston, QAOP/Space, their legacy
combined mode or disconnected joystick; automatic tape-command/disk-boot entry;
tape playback on startup; tape speed 1x/2x/4x/8x; and disk write protection.
Auto-load and tape auto-play act on open/reset. F7 toggles tape transport and F8
rewinds. Tape acceleration runs the whole machine faster while the tape plays,
mutes host audio during acceleration, and returns to normal pacing when stopped.
CPU/video/audio/tape hardware clocks relative to each other are unchanged.

Sound, joystick, playback speed and write protection apply without reopening.
Machine and service-ROM selection take effect when opening media. Current sound
and write-protection preferences are reapplied after loading a native state;
tape transport itself is restored from the state. Native state version 23 also preserves these TK/Gama/Byte/Profi devices alongside GS/NeoGS and the shared SD state.
Defaults preserve the previous AY/ABC, full chip volumes, combined joystick,
auto-load/auto-play, normal speed and writable-disk behaviour.

The settings audit and validation are recorded in
[the settings report](../../../codex-work/zx-settings/VALIDATION.md).

## Attached video, input and sound interfaces

The machine config now carries optional ULAplus, Timex-compatible video,
Kempston mouse, NedoPC Turbo Sound, SAM-port SAA1099 and a selected DAC board.
They default to disconnected and take effect when opening media. Importing SNA
or Z80 changes the base model while retaining these explicitly attached boards.
Native states restore the attachments and registers, including partial
video output, palette/fetch latches, mouse counters, second PSG and SAA phases.
Earlier native layouts are rejected; SNA/Z80 import is retained.

ULAplus implements the standard 64-entry GRB palette and four attribute CLUTs,
palette readback and palette changes during raster output. Deprecated grayscale
and optional BF3B screen-mode mirroring are not implemented. Its palette applies
to compatible Spectrum/Timex output; Pentagon extended video retains its own
palette. Timex FF modes 0/1/2/6 provide screen 0/1, HiColor and HiRes using the
existing bus fetch latches. Bit 6 gates INT. Bit 7 selects DOCK/EXROM on the native TC profiles; the optional extension on other machines has no MMU.
The output stays 640x480 while Timex video is attached, preserving mixed modes
and the display aspect. Native Timex models enable this video hardware without
requiring the optional extension switch. BetaDisk owns its overlapping FF port while DOS is mapped.

Controller 1 can select Interface 2 keys 6–0 or 1–5. Controller 2 can independently
use keys 1–5, with its own bindings/disconnection. Physical keyboard contacts
and joystick contacts combine through the existing matrix. Cartridge ROM support
is not implied. Kempston mouse uses canonical FBDF/FFDF/FADF ports; X grows right,
Y grows up, counts wrap at 256, and buttons are active-low (right/left/middle).
Host relative input is queued once and released when focus/input is cleared.
Mouse wheel, mirrored decoder aliases and native cursor locking remain absent.

Turbo Sound supports NedoPC FF/FE chip selection and independent read/write
address latches, stereo routing and base-clock synthesis. It also provides the
external dual-PSG configuration on 48K. Turbo Sound FM is a separate, mutually exclusive board with its own preset (see below).
DAC selection offers Covox FB, Covox DD, direct GS-compatible B3, SounDrive 1.00
and SpecDrum DF. SounDrive A/B route left, C/D route right; other listed DACs are
mono. The direct B3 DAC is not General Sound CPU/firmware/handshake emulation.
Normal paging/AY aliases and BetaDisk priority are retained. DACs use ideal
linear 8-bit levels with PCM integration and the existing DC blocker; analog
board transfer functions are approximate.

The existing SAA1099 synthesizer is connected at 8 MHz with address/data ports
01FF/00FF and its complete state serialized. SAA PCM is rendered at the existing
44.1 kHz boundary; sub-sample analog write settling is not modeled. This board
and the Timex FF extension cannot be selected together. Settings validate that
port conflict. DAC/SAA gain is independent of the PSG and beeper; the AY/YM and
stereo preferences apply to both PSGs of Turbo Sound.

Validation, explicit hardware scopes and references:
[peripherals/audio report](../../../codex-work/zx-peripherals/VALIDATION.md).

## ATARIN compatibility on Pentagon 1024SL

ATARIN party and postparty use `C0FD` to select most AY registers and `BFFD`
for their data. The original 1024SL auxiliary CPLD includes A13 in AY selection,
so `C0FD` is not selected there. Subsequent `BFFD` writes then reach the old
register latch, losing voices and distorting the remaining signal. Switching
AY to YM does not change this port decode. Select **Pentagon 128K / TR-DOS**
for this demo; the 1024K profile implements 1024SL hardware.

Both 5000-frame 1024SL PCM captures match the pre-Byte core byte for byte; this
is not a regression from the Byte/Byte-01 package. The focused host/timed-CPU
port-alias tests and original-ROM traces are in
[the ATARIN report](../../../codex-work/zx-atarin/VALIDATION.md).

## Independent ROM audit and hot-path optimization

The 2026-10-23 audit adds seven independent diagnostic images (five programs)
under `H:/ROMS/zxspectrum/tests/audit-20261023`, with source archives and SHA-256
provenance. They cover snapshot registers/RAM, ROM identification, RAM patterns,
I/O timing and +2A/+3 paging. The external Timing Test's 320 I/O measurements
match the published 128K early-timing grids. Hardware findings are checked
against Fuse and original test/documentation evidence; emulator agreement alone
is not treated as hardware certification.

128K/grey +2 I/O address contention now follows the currently mapped RAM bank:
odd banks in C000..FFFF contend as well as fixed RAM at 4000..7FFF. A former
unit test incorrectly expected the old behavior; the corrected contract and
1,024 phase/bank/port combinations cover this regression.

Short immutable hardware predicates are inline, normal colors use a 16-entry
lookup, and non-ASIC memory contention no longer computes an unused bank map.
A repeated checked Win64 benchmark takes 13.5–35.2% less wall time for the
same fixed frame workloads; sampled raster/PCM/PC/T-state hashes match. This
is a scoped benchmark, not a claim of that speedup for every game/platform.
No serialized fields or native state version were changed. Production ZX,
shared Z80 and PSG sources contain no textual code includes; the merged Pascal
modules are retained. Golden data includes in working tests are separate fixtures.

Sources, detailed limits, captures, regressions and build results:
[ROM/reference audit](../../../codex-work/zx-audit-20261023/VALIDATION.md).

## Turbo Sound FM (NedoPC revision C)

`Hardware/TurboSoundFM` attaches two native YM2203 chips in place of the PSG.
The `turbosound-fm` preset selects Pentagon 128K and ACB SSG stereo. It is
independent of the existing AY-only `TurboSound` setting; enabling both is a
configuration error. TC2068 uses different AY wiring and is rejected for this board.
Other implemented profiles can attach the board through their existing Spectrum
PSG decoder, including its model-specific aliases. The board clock is twice the
motherboard AY input (3.5 / 3.5469 MHz, following the selected profile).

The implemented revision follows the NedoPC CPLD source dated 2022-05-24:
address commands F8..FF latch bit 2 (FM DAC disable), bit 1 (SSG data / status)
and bit 0 (D1 / D2). Reset selects FE: D1, SSG readback, FM disabled. Unlike
AY-only Turbo Sound's historical selector, FE selects physical D1 and FF D2.
Control writes preserve the two independent YM register addresses. FM registers
are write-only; their data reads return zero. Status returns both timer flags
and BUSY. The status mode uses the normal AY read port, not a new BFFD read port.

Both chips provide three FM and three SSG voices. The native OPN operators are
shared with RetroMul's MD synthesis engine; no external sound DLL is loaded.
Prescaler changes occur on address strobes, including writes without data.
Timer A/B flags, load/enable/reset controls, reload and BUSY advance from machine
clocks even between output samples. YM IRQ pins are not wired to the Z80 on this
board. SSG keeps the configurable channel ordering; FM DAC D1 goes left and D2
right. `AYVolume` controls SSG, `ExpansionVolume` controls FM. FM disable gates
only the DAC outputs; synthesis, SSG and timers keep running.

The audit also corrected the shared YM2203 SSG clock (it was an octave too low)
and verified that unused key-on bits 2/3 are ignored before forwarding
to the shared six-channel OPN2 engine. The existing tracker stream decoder
remains unchanged. Native state v20 stores the CPLD latch, address latches, partial
clock/BUSY phases and complete filters/operators for both chips. Earlier native
ZX states are rejected; SNA/Z80 imports remain supported and initialize D1 SSG.

Scope limits: fixed 44.1 kHz output resampling is not a pin-level YM pipeline;
CSM key pulses, timer-load/prescaler transitions at pin level, analog gain/filter tolerances,
YM3014 floating-point quantization, expansion-connector GPIO devices and external
audio inputs are not hardware-certified. No BIOS ROM or programmable logic binary
is needed: the CPLD logic is implemented natively. The original music programs
are test media, not embedded firmware.

Sources and executable checks: [Turbo Sound FM validation](../../../codex-work/zx-tsfm/VALIDATION.md).

## Next-DAC audio compatibility interface

`Hardware/DAC=nextdac` attaches the four unsigned 8-bit DAC latches from the
Next FPGA 3.02.03 as an audio-only compatibility device. `ZX.NextDAC` implements
A/B left, C/D right, master enable/reset, per-alias gates, the protected NextReg
selector reset value 24, and the DAC mirrors 2C (B), 2D (A+D), 2E (C). These
mirror reads access the disconnected Pi I2S input and return zero, not the DAC
latches. The component exposes only DAC-owned bits of NextRegs 08 and 84;
other Next CPU/video/peripheral registers remain unsupported. Port decoding
for 243B/253B is exact; legacy DAC aliases use the low byte.

`NextDACMode` selects startup aliases: 0 all, 1 SounDrive 1, 2 SounDrive 2,
3 Profi stereo, 4 Covox stereo, 5 Pentagon/ATM mono, 6 GS Covox mono,
7 SpecDrum mono, 8 NextReg mirrors only. Guest code can change the live enables through NextReg 84.
FB writes D while SounDrive 2 is enabled; otherwise the enabled Pentagon/ATM
alias writes A+D. DF writes A+D and B3 writes B+C. The full matrix is checked
against 32768 Boolean vectors extracted from the pinned FPGA source and four
upper port bytes. NextReg writes remain available when legacy alias gates are off.

`NextDACStartup` defaults to true for classic programs that do not enable the
Next DAC themselves. This is an explicit host compatibility preference: physical
Next power-on starts with NR08 bit 3 clear. Disabling the setting retains that
gate until guest code enables it. Clearing bit 3 immediately resets all sample
latches to 80; disabled writes do not queue samples for re-enabling. Opening or
resetting media reapplies the selected startup settings; native v21 preserves
both those preferences and the independent live register/latch state.

The `nextdac` preset selects Pentagon 128K with the audio interface. DAC level
uses the existing expansion volume and T-state PCM integration/DC filtering.
The selected motherboard still owns paging, AY, joystick and PPI decoding:
this device does not turn it into a Spectrum Next. F1/F9 can also hit classic
paging/AY aliases, and Gama's PPI can affect NextReg readback. Settings explain
these combinations. The GS B3 alias is rejected with divIDE; select another
startup alias profile or divMMC. ULA/video timing, Z80N opcodes, DMA, CTC,
Copper, Next memory mapping, Pi I2S, expansion-bus gates and NextReg 85 reset
policy belong to the future full Next machine. The 28 MHz FPGA pipeline and
analog board calibration are outside this DAC component's precision target.

No BIOS is required or added for the DAC. The original plain-Z80 diagnostic
snapshot is in `H:/ROMS/zxspectrum/tests/next-dac/`, with its source in
`codex-work/tests/ZXNextDACTests.dpr`. Firmware resources are unchanged.
Native v22 and earlier states are rejected; standard SNA/Z80 imports remain
supported. Validation and source pins: [Next-DAC report](../../../codex-work/zx-nextdac/VALIDATION.md).

## General Sound

`Hardware/GeneralSound=true` attaches the classic GS with a separate native
Z80 at 12 MHz, original GS 1.05b ROM (32 KiB embedded resource), RAM, periodic
37.5 kHz interrupt, four DAC latches and four six-bit volume latches. Commands,
MOD loading/conversion/playback, samples and Covox modes run in the guest ROM;
there is no host command interpreter or host MOD playback library.

`GeneralSoundRAMKB` is 128 (default; 0 is accepted for zero-initialized legacy
configuration records) or 512. The original base board maps ROM at 0000..3FFF,
fixed RAM at 4000..7FFF, and 32 KiB bank windows at 8000..FFFF. Page 0 is the
whole ROM; fixed RAM aliases page 1's upper half. GS128 has pages 1..4.
Classic GS512 has pages 1..15 and retains the documented missing 32 KiB
region: 480 KiB is addressable, including the 16 KiB work area. The original
ROM reports three or fourteen module pages, respectively. This is the classic
decoder, not the corrected NeoGS memory controller.

The host exchanges data/commands via B3/BB, with a shared data flag and a
separate command flag. The upper host address byte is ignored. Internal ports
decode A0..A3; handshake strobes on 2/3/5/A/B apply on IN and OUT. Port A uses
the inverse of page-register bit 0; port B uses volume A bit 5. Sample reads
through 6000..7FFF latch channel (address >> 8) & 3, including M1 fetches;
writes and refresh do not latch a sample. A/B feed left and C/D right.

The /5, /4 and /16 divider chain produces a 320-cycle, 50% duty INT signal.
Integer rational conversion follows the selected motherboard's base clock;
GS continues during Pentagon turbo/wait/BUSACK. Synchronization finishes
the current GS instruction and repays its cycle overshoot. Sub-instruction
host/GS ordering, asynchronous crystal startup phase, analog crossfeed,
electrical bus contention and board filter calibration are not certified.
The existing T-state PCM mixer/DC filters and expansion-volume slider mix GS.

Settings include two GS presets, enable and RAM controls, and translated
conflicts with divIDE ATA and B3 DAC aliases. divMMC and DAC profiles without
B3 can coexist. A notice explains E0B3..EFB3 writes also reaching Pentagon
1024SL EFF7; use explicit addresses such as 00B3. The motherboard's original
decoder remains active. Whole-emulator reset/open resets both CPUs and GS
RAM; physical GS boards can have independent reset wiring, which is not a
separate host control here. Native v23 preserves both CPUs, installed GS RAM,
handshake/data latches, sample/volume latches, IRQ and fractional clock/debt.
Disabled GS allocates no secondary CPU/RAM and stores no GS payload.

`GS-port Covox #B3` remains the old ideal direct DAC option. To execute GS
firmware commands and its Covox mode, enable General Sound and leave that
direct DAC option off. NeoGS is a separate board model (below). Overclocked
classic GS revisions, custom ROM overrides and analog calibration remain
separate work.

Validation, reference pins, BIOS and authored diagnostics:
[General Sound report](../../../codex-work/zx-generalsound/VALIDATION.md).

## NeoGS (PCM / MP3 / SD / DMA / flash / FPGA)

`Hardware/NeoGS=true` selects the NedoPC board independently of classic GS.
`NeoGSRAMKB` accepts 512, 2048 (default, also 0 for legacy zeroed records) and
4096 KiB. Three ready presets select these configurations. Both sound boards
share B3/BB and cannot be attached together. divIDE and B3 DAC aliases also
conflict; settings collect and translate every conflict before Apply/open.
NeoGS can coexist with divMMC and has its own SD image and sector overlay.

`ZX.NeoGS` derives from the existing GS CPU/mixer path, reusing the native
Z80. The embedded complete 512 KiB firmware 1.11 executes its original loader,
RAM test, command processor and MOD player without patches. It reports 14,
62 and 126 module pages on 512 KiB, 2 MiB and 4 MiB boards. Guest software
controls all four 16 KiB MMU windows, normal MPAG or independent EXPAG windows,
ROM/RAM selection and RAMRO. The 10/12/20/24 MHz oscillator selection uses
rational clocks. A separate 24 MHz timer has the published eight divisors;
latched interrupt enables/requests prioritize timer, SD DMA and MP3 DMA,
with FF/F7/EF vectors in IM0/IM2 (IM1 retains RST38).

Sample reads at 6000..7FFF latch four or eight channels. Eight independent
six-bit volume registers, stereo routing, four-channel panning and live INV7B
feed the existing expansion-volume, T-state mixer and DC filtering. NeoGS
internal ports decode the entire low byte, unlike classic GS's 4-bit aliases;
OUT02/IN03 have no handshake effect. Compatibility strobe A uses raw PG2 D0
and strobe B uses VOL4 D5. Host port 33 selects warm reset/NMI/LED with exact
E0-mask decode. Warm reset retains RAM and mounted SD; host reset/open clears
board RAM and restarts the ROM, preserving the mounted media overlay.

`Hardware/NeoGSImage` attaches a raw 512-byte-sector card through `ZX.SDCard`,
extracted from the existing divMMC protocol implementation. Both interfaces
use the same tested SD initialization, SDSC/SDHC, read/write/multiblock/CRC
logic and `ZX.BlockImage` immutable source plus sparse sector overlay. The
adapter retains the source hash/read lock; the worker loads/saves a separate
`.ngs` overlay atomically. Disk write protection applies to this card as well.
SPI reads return the completed byte; port 14 also starts the next FF transfer.
SPI follows the selected CPU clock; the timer follows its independent crystal.

ZX DMA reads require ROMCS in 0000..3FFF, with the documented initial dummy
read and prefetch. Writes to that region feed NeoGS even when motherboard
RAM is mapped, preserving both writes. The pointer is 22-bit with installed
RAM address-line mirroring. SD DMA receives one 512-byte block and two CRC
bytes, then requests the sound CPU memory bus for a two-clock-per-byte FIFO
burst. Its completion disables the one-shot and latches the SD interrupt.
Native v25 stores both CPUs, MMU, clocks, samples/volumes, SPI pipeline,
partially received SD/FIFO burst, DMA pointers/prefetch and mounted-card hash
and overlay. Mounted media survives a state-driven NeoGS RAM-size change.

`ZX.VS1011` implements the VS1011e MPEG Layer III profile in native Pascal.
SCI on port 15 is a timed, big-endian four-byte transaction; SDI on port 14
accepts a bounded MP3 stream. SCTRL controls XRESET, XCS and serial dividers;
port 12 reports DREQ and control-SPI READY. The decoder handles MPEG-1/2/2.5
CBR/VBR mono/stereo, bit reservoirs, volume/mute, reset, header/rate/time
registers, WRAM access and sine/SCI/memory diagnostics. Audio joins the existing
NeoGS/expansion mixer. MP3 DMA module 3 fetches 512 physical RAM bytes into its
own FIFO at two CPU clocks per byte, honors DREQ while transmitting, and
latches the EF interrupt. State v25 includes decoder overlap/filter history,
compressed/PCM buffers, serial progress and partial DMA.

`ZX.AM29F040` shares the board's existing 512 KiB flash array and implements
AMD unlock/autoselect, byte programming (only 1-to-0), sector/chip erasure,
suspend/resume, busy polling and operation timing. Configured ROM windows are
writable through the flash command protocol. CPLD ports 40..7F, 80..BF and
C0..FF provide unconfigured 32 KiB memory banking, nCONFIG/status and parallel
FPGA data with the board's bit routing. Only published standard NedoPC
bitstreams are accepted; an unknown image leaves nSTATUS low. A completed
configuration schedules the sound-CPU reset at an instruction boundary.
The original BIOS bootFPGA code performs its own CRC, unpacking and writes.

A clean built-in image retains the previous configured-FPGA fast startup.
Explicit cold reset, modified flash and persisted flash execute the original
cold bootstrap. Reset preserves programmed bytes. The worker atomically saves
completed flash writes beside the ZX configuration (`zx.neogs.flash`), separate
from SD and game saves, loads them on the next session, and preserves them
before loading a state that may remove the board. The embedded factory BIOS
is unchanged. Native snapshots contain mutable flash and pending operations;
older native v24 and earlier states are rejected. SNA/Z80 imports remain supported.

The supported profile excludes arbitrary FPGA HDL, VSDSP application/plugin
execution, MPEG layers I/II, WAV and free-format MP3. Bass/treble and analog
attenuation are approximations, not a bit-exact model of the proprietary DSP
or analog circuit. Sub-instruction WAIT/arbitration and analog calibration
remain uncertified. The registry marks the implemented standard NeoGS profile;
it does not claim a general-purpose FPGA or DSP emulator.

[NeoGS MP3/programming validation and reference pins](../../../codex-work/zx-neogs-vs-flash/VALIDATION.md).
[Earlier PCM/SD/DMA validation](../../../codex-work/zx-neogs/VALIDATION.md).


## DMA Ultrasound Card

The `dmausc` ready configuration selects Pentagon 128K with Witchcraft/Stranger
DMA USC. `Hardware/DMAUSC=true` attaches the board to Sinclair 128K/+2/+2b/+3,
Pentagon 128/512/1024, Scorpion 256 or Profi 512/1024. Unsupported motherboards
produce a live settings conflict. The board has no BIOS or private sample RAM:
its native 8237A reads/writes physical motherboard RAM. No firmware resource is needed.

`ZX.DMAUSC` supplies four sample DACs with 6-bit volumes, two native readable
8253s, bank latches, DMA requests and the board's EOP/timer IM2 interrupt vectors.
Normal audio counters run at the motherboard base clock; the two interrupt
counters run at half that clock. The controller supports masks, shared byte
pointer, count/address wrap, auto-init, fixed/rotating priorities, demand/single/
block/verify transfers and memory copy/fill. Software requests require block
mode and bypass channel masks. Contiguous block transfers omit redundant high
address cycles, and compressed timing omits S3.

Use the documented `77` ports: DMA registers `0C77..FC77`, PITs `3D77/7D77/BD77/FD77`
and `3E77/7E77/BE77/FE77`, bank latches `0777/1777/2777/3777`, volumes
`3F77/7F77/BF77/FF77`, IRQ control `F777`. Decode aliases follow the published
schematic and retain motherboard side effects; settings warn about Pentagon
EFF7 aliases. Bank latches select 64 KiB groups, independent of CPU paging,
with address-line mirroring at the selected motherboard's RAM capacity.

`DMAUSCStereo=0/1/2` selects AD-left/BC-right (default), AB-left/CD-right or mono.
All outputs use the existing expansion volume, DC filter and host PCM path.
`DMAUSCULABypass=true` (default) is an explicit compatibility option for early
players that write zero to IRQ control while still expecting frame interrupts.
Disable it to emulate the complete DD18/DD19 interrupt controller: bit 0 masks
EOP, bits 1/2 enable timer interrupts and bit 3 enables the ULA interrupt path.
For example, EOP alone supplies IM2 vector 6F, and EOP with ULA supplies EF.
The software option is not a claim that reset enables the schematic's ULA gate.

DMA owns the bus between CPU machine cycles; video, other audio and interrupt
timers continue. A long transfer can suspend an instruction across a frame.
Native state v25 preserves its continuation journal, active DMA source latch,
register byte pointer, both PITs, pending interrupts, sample latches, volumes
and mixer phases. Worker reset, presets and settings persistence retain the
installed hardware profile. A compatible 128K SNA retains the selected
motherboard rather than silently changing its timing or expanded RAM.

The acceptance scope is the standard card with fixed-high GATE/READY and no
external cascaded DMA controller or input peripheral. Four physical analog
outputs are mixed in software; analog voltage calibration, unusual DACK-polarity
programming and pin-exact CPU/BUSRQ/INT edge timing remain uncertified.
Original unmodified DMA Demo Planet/Technological players and sample data pass
alongside register/timing, full 64K bus holds, snapshots and runtime-worker tests.

[DMA USC validation and source hashes](../../../codex-work/zx-dmausc/VALIDATION.md).

## ZXM-MoonSound (Mick revision 01)

Enable `MoonSound` or choose **Pentagon 128K + ZXM-MoonSound**. The board has
a native YMF278B at 33.8688 MHz, existing RetroMul OPL3 FM and 24 PCM voices
at 44.1 kHz. PCM supports signed packed 8/12/16-bit samples, ROM/RAM headers,
fractional pitch and interpolation, looping, envelopes, rate correction,
pseudo reverb, DAMP, LFO, level interpolation and stereo pan/mix registers.
The board uses DO2; voices routed exclusively to unconnected DO1 are silent.

The complete 2 MiB YRW801 table is embedded as `ZX_MOON_WAVE`; an external
BIOS file is unnecessary. This is sample data, not guest executable firmware.
AM29F016D ID/read/program/sector and chip erase use the shared native AMD flash
controller. Guest programming persists in `zx.moonsound.flash` beside
the ZX configuration. Reset retains programmed flash and SRAM. The factory
resource is immutable. Original MoonService 0.3a identifies the flash as 01/AD.

There is 1 MiB external SRAM. Memory type 0 maps it at 200000..2FFFFF. Type 1
maps MCS6 at 380000..39FFFF and MCS7 at 3A0000..3BFFFF, preserving the wired
nineteen address lines on each 512 KiB SRAM; these windows are not a linear
remapping of the entire RAM. Flash occupies 000000..1FFFFF in either mode.

The low-byte decoder selects 7E/7F (PCM) and C4..C7 (FM); upper address bits
are ignored. IORQG inhibits motherboard aliases, including even-port ULA and
paging. The optional IRQ jumper is off by default; the board has no IM2 vector.
Enabling it together with DMA USC is rejected as an interrupt-bus conflict.
The PentEvo jumper can expose the board in TR-DOS; disk-controller I/O retains
priority. Both jumper settings have localized controls and conflict/advisory
messages. Presets and manual settings use the same validated configuration.

MoonSound state (introduced in native v26) saves PCM/FM phases, SRAM, flash commands and clock
remainders. FM pointer graphs are rebased when loading. Older native states
are rejected; native states are architecture-local. SNA/Z80 interchange formats
retain their existing behavior.

Implementation follows the author's schematics/CPLD and Yamaha documentation.
Independent YMFM vectors cover PCM format/loop/pitch at unity gain; existing
FM output matches Nuked-OPL3 goldens. Envelope/effect and analog behavior are
not certified bit-exact to a physical card. Other board revisions and CPLD/JTAG
reprogramming are outside this profile. No external host audio library is linked.

Sources, original player tests and regression results:
[MoonSound validation](../../../codex-work/zx-moonsound/VALIDATION.md).

## SID (eLeMeNt ZX / MB03+ application interface)

Enable `SID` or select **Pentagon 128K + SID 6581 (eZX/MB)** / **SID 8580**.
This attaches one chip using the existing native `C64.Sound.SID` synthesizer:
three voices, ADSR, triangle/saw/pulse/noise, sync/ring modulation, volume DAC
and model-dependent approximate filters. No SID BIOS or sample ROM is required.

The full 16-bit ports are **6C3B** (index) and **6D3B** (read/write data).
Original registers 00..1C are forwarded to the SID. Register **1F** bit 0 selects
6581/8580; bit 1 selects PAL **985248 Hz** / NTSC **1022730 Hz**; bits 2..7 read
zero. Switching preserves voices, envelopes and filter state. The clock ratio
to the motherboard is rational and independent of Spectrum video timing and
Pentagon CPU turbo. The optional multiple-chip register 20 leaves chip 0 selected;
other reserved indices are ignored/read FF and do not alias original registers.
POT inputs read FF. The index port has no claimed readback and returns FF.

Settings define startup model/clock. Reset restores them; guest changes are
saved in native states rather than written back to the startup configuration.
Audio is mono through the expansion sound volume, with existing DC filtering.
The board can coexist with AY, DAC, GS/NeoGS, DMA USC and MoonSound; it adds no
IRQ. State v27 stores all oscillator/envelope/filter/DC/sample phases and latches.
Earlier ZX native states are rejected; SNA/Z80 interchange formats are unchanged.

This package implements the documented single-chip application interface, not
the complete eZX/MB motherboard or SetUp port families 70/71/78/793B. Other SID
cards (for example xxCF) are separate interfaces. The existing synthesizer is
not certified bit-exact to physical SID analog circuits or the FPGA's internal
pipelines/combined waveforms. Original Hood Z80 music routines are exercised
without player patches; complete game/firmware boot is not implied.

See [SID validation](../../../codex-work/zx-sid/VALIDATION.md) for primary
documentation, regression hashes and reproducible tests.
