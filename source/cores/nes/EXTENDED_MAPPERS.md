# Extended mapper support

The missing mapper IDs from the 899-ROM collection in `H:\ROMS\nes` are now
registered. The factory adds 39 IDs, including six board variants needed to
correct legacy headers:

| Implementation | IDs | Implemented hardware |
| --- | --- | --- |
| MMC5 | 5 | PRG ROM/RAM modes and protection, CHR modes, separate sprite/background banks, ExRAM, fill nametables, extended attributes, vertical split, scanline IRQ, multiplier |
| Discrete | 8, 13, 15, 32, 34, 70, 71, 79, 88, 99, 112, 113, 144, 152, 154, 206, 228, 232, 240, 242 | Board-specific banking/mirroring, CPROM CHR RAM, Namco 108 registers, VS CHR select, FFE IRQ |
| MMC2/MMC4 | 9, 10 | PRG banking and read-triggered CHR latches |
| MMC3 variants | 12, 91, 119, 245, 250 | Outer bank bits, register decoding, revision-A IRQ for 12, independent TQROM CHR RAM/ROM |
| Bandai | 16, 159 | FCG/LZ93D50 banking, CPU IRQ, serial X24C02/X24C01 EEPROM |
| VRC | 22, 23, 25 | Nibble-written CHR banks, address wiring, PRG swap, mirroring, VRC4 CPU/scanline IRQ |
| RAMBO-1 | 64 | Additional PRG/CHR registers, A12 and CPU/4 IRQ modes |
| Sunsoft | 68, 69 | Sunsoft-4 CHR nametables, FME-7 ROM/RAM banking and CPU IRQ |
| Cony | 83 | PRG modes, outer banks, CHR modes, scratch registers and CPU IRQ |
| JY | 90, 209 | PRG/CHR modes, 209 nametable mapping/latches, multiplier and four IRQ clock sources |
| SUBOR | 167 | Educational-computer PRG banking modes, 8 KiB CHR-RAM and H/V mirroring |

`NES.Mapper.Banked` provides bounded array-based bank access. Hardware wrap is
explicit. CPU, CPU-write, PPU-address, PPU-fetch and scanline hooks connect the
boards to the console. Unknown IDs still raise an unsupported-mapper error.
All implementation classes use the `TMapper` prefix. New units are registered
in `fmx/NESFMX.dpr` and `.dproj`.

Legacy mapper-15 headers enable a compatibility mode with writable CHR RAM
in every banking mode. Older single-game dumps such as Crazy Climber depend
on this behavior. NES 2.0 uses the board's CHR write protection in modes 0/3.
This distinction follows the documented
[mapper-15 hack compatibility requirement](https://www.nesdev.org/wiki/INES_Mapper_015).

## Legacy headers

`NES.RomMetadata` only changes the effective mapper when both the declared
legacy mapper and the SHA-1 of the complete PRG+CHR payload match. Filenames are
irrelevant, NES 2.0 headers take precedence, and source ROM files are untouched.
The original and effective mapper remain visible in the report.

| ROM identity | Declared → effective mapper |
| --- | --- |
| Faxanadu | 2 → 1 |
| Xevious (2) (VS) | 2 → 206 |
| Arkanoid 2 | 70 → 152 |
| Devilman | 88 → 154 |
| Dragon Ball Z | 16 → 159 |
| Mermaids of Atlantis | 8 → 79 |
| Pachicom | 15 → 0 |
| Quattro Sports | 71 → 232 |
| Samurai Spirits 2 | 90 → 209 |
| Videomation | 12 → 13 |
| Death Race | 11 → 144 |

Hardware behavior was cross-checked against the
[NESdev mapper reference](https://www.nesdev.org/wiki/Mapper),
[Mesen mapper implementations](https://github.com/SourMesen/Mesen2/tree/master/Core/NES/Mappers)
and cartridge identities in the
[Nestopia database](https://github.com/0ldsk00l/nestopia/blob/master/NstDatabase.xml).
Death Race uses the AGCI 50282 board (mapper 144), whose bus conflict forces D0
from ROM. Mapper 11 remains available for ordinary Color Dreams cartridges.

## Limits

- The frame test proves a repeatable non-uniform frame, not pixel accuracy
  against real hardware or successful gameplay.
- Rendering is scanline-based. MMC5 scanline IRQ uses the renderer's scanline
  notification rather than full hardware fetch/idle detection. Mid-scanline
  changes and latch-sensitive drawing are not cycle-accurate.
- MMC5 and Sunsoft 5B expansion audio are not implemented. The base NES APU
  continues to produce sound; these additional voices are absent.
- Mapper 99 implements cartridge banking, not complete VS System emulation.
  Dual CPU boards, security devices, arcade inputs and variant PPU palettes
  require separate work.
- NES 2.0 submapper-specific wiring and RAM sizes are not fully modeled.
  VRC 23/25 use legacy address-line decoding; Sunsoft-4 dual-cartridge hardware
  and some unlicensed-board variants remain outside the tested behavior.
- Bandai EEPROM persists across console reset within the same mapper instance;
  saving battery-backed contents to disk is not implemented by this emulator.
