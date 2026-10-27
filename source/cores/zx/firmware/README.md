# Original machine ROMs

These are ZX Spectrum machine firmware images, not native code libraries.
They are embedded by `ZX.Firmware.rc` so snapshots and tapes can call the ROM.
Copyright remains with the original rights holders.

Downloaded from the [Fuse libretro ROM directory](https://github.com/libretro/fuse-libretro/tree/master/fuse/roms)
on 2026-10-22. No Fuse emulator implementation is incorporated.

| File | Role | SHA-256 |
| --- | --- | --- |
| 48.rom | 48K BASIC | d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42 |
| 128-0.rom | 128K editor | 3ba308f23b9471d13d9ba30c23030059a9ce5d4b317b85b86274b132651d1425 |
| 128-1.rom | 128K 48 BASIC | 8d93c3342321e9d1e51d60afcd7d15f6a7afd978c231b43435a7c0757c60b9a3 |

## Pentagon / Beta 128

The additional machine firmware was extracted unchanged from the hardware project
[MiSTer ZX Spectrum boot ROM](https://github.com/MiSTer-devel/ZX-Spectrum_MISTer/blob/master/releases/boot.rom)
on 2026-10-23. Its [documented ROM map](https://github.com/MiSTer-devel/ZX-Spectrum_MISTer#bootrom-structure)
identifies the original components. Copyright remains with their rights holders.
Only original machine data is embedded; no host emulator code or binary library
is incorporated. The existing 128-1.rom supplies 48 BASIC for Pentagon ROM 1.

| File | Source offset / role | SHA-256 |
| --- | --- | --- |
| pentagon-0.rom | 0x08000, Pentagon 128K editor/menu | 633343620691a592c706d18c927fd539b7069a5d0fb7011bcd3bfc94be418681 |
| trdos-5.03.rom | 0x3C000, TR-DOS 5.03 | f9ca78515a1c02f0ce2ca479032e0cad24af8dbe65e4d68a46293ea85ffd7e54 |

Downloaded bundle SHA-256: a64828d45e2e73501916e1bee7beb30f028aa4ea181a9a60720bdeef28ec2b40.

## Grey UK Spectrum +2

Downloaded unchanged on 2026-10-23 from the same
[Fuse libretro ROM directory](https://github.com/libretro/fuse-libretro/tree/master/fuse/roms).
These are original machine firmware data; no emulator code or host binary library
is incorporated. Copyright remains with the original rights holders.

| File | Role | SHA-256 |
| --- | --- | --- |
| plus2-0.rom | Grey UK +2 editor/menu, 16 KiB | 51dc881d1d3e8242972390224e7cfd8650987d9a620e086aca9dfdf6988fcbf1 |
| plus2-1.rom | Grey UK +2 48 BASIC, 16 KiB | ae6d95f1e6d16c3d1c947b77e6087952f3204b7930c6cadae3769289a1f5a1b9 |

Resource slots 6/7 are dedicated to +2; optional Pentagon service firmware keeps
slot 5. Tests hash both complete mapped ROMs and verify switching/reset/state restore.

## Black UK +2b and UK +3

Added on 2026-10-23. +3 v4.0 banks were downloaded unchanged from the
[Fuse libretro ROM directory](https://github.com/libretro/fuse-libretro/tree/master/fuse/roms).
+2b v4.1 banks were extracted unchanged from the MiSTer boot bundle above,
offsets 0x10000 / 0x14000 / 0x18000 / 0x1C000. The documented bundle SHA-256
is unchanged. These are original machine firmware data, with copyright retained
by their rights holders; no emulator implementation or host binary library is used.

| File | Resource slot / role | SHA-256 |
| --- | --- | --- |
| plus3-0.rom | 8, editor/menu | 841d54545c743a7202fb9b068534ed906a08cc657a19955ae20a8de5af8ab185 |
| plus3-1.rom | 9, syntax | 6d6ccab28f255b01c8cd89ceab9e7b60247f4610471118092f290f6c7768b7e3 |
| plus3-2.rom | 10, +3DOS | c5590212a269117657ce611acbac582e41e9db87dc78db480da2615e413b2da6 |
| plus3-3.rom | 11, 48 BASIC | 8ec5cb9fd7ec24a041800314bb5a2c99be02f7e50745194eb649ed6d9085bd1f |
| plus2b-0.rom | 12, editor/menu | 5a15b395a60f6cae87c80d560265d7f5ce3bf99f5ee8c57598d32918c106696d |
| plus2b-1.rom | 13, syntax | 32e44e9c622a8e50f1c46e88a1008df7c7583244c3d3736c9d5e406b98c8ff04 |
| plus2b-2.rom | 14, +3DOS | aa92f4e0c8ef1f324b9d565009d1f1b37079057ebc97c39a6def33209e29499e |
| plus2b-3.rom | 15, 48 BASIC | 4ded16ccbcaf8043ed9acec49556dd04e79910d2e32e4bda6e5f4dbbd8c25a09 |

## esxDOS 0.8.9 interface firmware

Downloaded on 2026-10-23 from the
[official release](https://www.esxdos.org/files/esxdos089.zip), linked by
[esxdos.org](https://www.esxdos.org/index.html). These are original Z80 firmware
data, not host binary libraries or copied emulator code. Copyright 2005–2021
Papaya Dezign; original notices are retained in the downloaded release.
ESXIDE.BIN and ESXMMC.BIN are embedded unchanged. Matching SYS/BIN card files are
not embedded; the validation card contains them from the same official archive.

| File | Source | SHA-256 |
| --- | --- | --- |
| esxide089.rom | ESXIDE.BIN, 8 KiB | 771d5f21de48a3e9969adef7708ddb9a2834ba8729c5f702e5c0bb6067ebaa57 |
| esxmmc089.rom | ESXMMC.BIN, 8 KiB | 89706de560d66432fe19ddb895e7cde49e252e932687dcb57fb92259a0259339 |

Official archive SHA-256: `d455888361cd13d455e362a4c841452b6f4568d30f9069443044affdd40de9a4`.

## PAL Timex and original Scorpion ZS-256

Timex ROMs were downloaded unchanged from the Fuse libretro ROM directory on
2026-10-23. Scorpion v2.94 was split into four 16 KiB banks from the unchanged
[scorp294.rom](https://github.com/MiSTer-devel/ZX-Spectrum_MISTer/blob/master/tools/scorp294.rom).
These are original Z80 firmware data, not host libraries. No reference emulator
implementation is copied. Copyright remains with the respective rights holders.

| File | Role | SHA-256 |
| --- | --- | --- |
| tc2048.rom | TC2048 HOME | 8375dc559f35e3584b1141ed1eb50a87c2aba85e560fc7ff5b467c0520dffaf6 |
| tc2068-0.rom | TC2068 HOME | 6338f94b2ee5000b81a64a4f055b8f1d2db6e669e52cafc11233ff63896fae13 |
| tc2068-1.rom | TC2068 EXROM | e52e861bd30c144f174a596233c6f3e5804cff170fdc50d44ba61a1683b8174c |
| scorpion-0.rom | Scorpion 128 BASIC | c7ba1b5a4895b9ffba4499a40f227f955bc147092532f95023afe3a393bba602 |
| scorpion-1.rom | Scorpion 48 BASIC | e8b8ec052e5e7283a59173326a954773583fc282ccdf1dfff1724c30fdbc86f8 |
| scorpion-2.rom | Shadow service monitor | 307410a2a0537a9942b843f21528e0d0ac6fc5c695d9e61ec22bf5f000377966 |
| scorpion-3.rom | Scorpion TR-DOS | f9ca78515a1c02f0ce2ca479032e0cad24af8dbe65e4d68a46293ea85ffd7e54 |

## Profi+ BIOS 2.1

The unchanged 64 KiB [BIOS 2.1 image](https://speccy4ever.speccy.org/rom/PB21-0C278614.ROM)
(CRC32 `0C278614`) is split into four 16 KiB banks and embedded by
`ZX.Firmware.rc` / `ZX.Firmware.RES`. No external firmware path is required.
Firmware remains Z80 program data; copyright belongs to the respective holders.

| File | Role | SHA-256 |
| --- | --- | --- |
| profi-0.rom | System/CP-M boot ROM | b7a7bc88b34f643b5f823484378f1d5f67267d6a243f28f104a48c7fcc5fa5f8 |
| profi-1.rom | TR-DOS 5.04T | 13a15cc809398a8fb1b9822658c01e72cc791e6940851bfcea869c37c914ab44 |
| profi-2.rom | 128 BASIC editor/menu | 633343620691a592c706d18c927fd539b7069a5d0fb7011bcd3bfc94be418681 |
| profi-3.rom | 48 BASIC | 110020ff7a4e350999777261000442426838cc391be93ba3146abc9477dcc05f |

## Original Byte / Byte-01 and timing/compatibility PROMs

Downloaded on 2026-10-23 from the physical-board documentation curator
[zxbyte.org](https://zxbyte.org/download.htm):
[original Byte ROMs](https://zxbyte.org/doc/byte_roms.zip) and
[original Byte-01 ROMs](https://zxbyte.org/doc/byte01_roms.zip).
Byte DD72/DD73 are concatenated in ROM address order; Byte-01 and all PROMs
are embedded unchanged. Resource slots 27..32 contain **36,352 bytes total**.
No external BIOS path is needed. Copyright remains with the original holders.
These are guest firmware/data; no foreign host binary library is linked.

| File | Role | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| byte.rom | DD72 + DD73 ROM | 16384 | c3296debe149b11bcde0cc002be3aaf0c703f6fe7cd61397f95e8764203e9fe5 |
| byte01.rom | Byte-01 ROM | 16384 | 86b70e3353c3ad738ffea3a79849a1a6bbbffb9f9d20d0176e783baa701c4cae |
| byte-dd66.rom | DD66 ROM overlay decoder | 512 | 6349d8f8dc5ebb5a785360f89e3799ae54d2ee689e3058d67f3cf2b564208eb2 |
| byte-dd71.rom | DD71 compatibility patches | 2048 | 8372406ff44a36da5064e6e4922389018df20bad6a16f2711b9cee2d886a5c82 |
| byte-dd10.rom | DD10 horizontal timing | 512 | 6f87691972aa874528eed2ab71a35778e9ce37fd072bb5d1f7b3a4e0597d9f7f |
| byte-dd11.rom | DD11 vertical timing | 512 | 38cd5dafe3bfb9587557e0f0291c84b5fb0163f8e891ba16a819853f0a733641 |

## Didaktik Gama 80K

Three unchanged EPROM dumps from the physical-board curator
[Cygnus's ROM archive](https://cygnus.speccy.cz/download_roms.php), downloaded
2026-10-23. Resources ZX_GAMA87/88/89 embed **49,152 bytes total**. No external
BIOS path is needed. Firmware is guest Z80 program data; copyright remains
with Didaktik Skalica and the respective original rights holders.

| File | Revision | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| gama-1987.rom | 1987 | 16384 | e50d6ae980e582c649ba5d72a6d7b003788cd73f7cfa9c558fa4b3ec55e7bc79 |
| gama-1988-2.rom | 1988-2 | 16384 | 23e33d177176f180efda6346b7ccc0bc4358ab47af0bcbe5bf4171fcf1848b67 |
| gama-1989.rom | 1989 | 16384 | dac528146fa9161cff21517a6f70c67829c87f1212d87850b8368784d04936f0 |

CRC32 values match the curator: `291CAFED`, `8CF33890`, `45C29401`.
The 1987 and 1988-2 dumps differ only at 38FA..38FB; 1989 retains its
original font, startup delay and BASIC bank-copy routine.

## Microdigital TK90X / TK95 original ROMs

Four unchanged 16 KiB Portuguese/Spanish EPROM images are embedded by
`ZX.Firmware.rc` / `ZX.Firmware.RES`: **65,536 bytes total**. No external BIOS
path is required. The TK90X Portuguese dump matches byte-for-byte the image
in the physical-board reconstruction project
[TK90X-PCB](https://github.com/fbelavenuto/TK90X-PCB/blob/master/Common/TK90X_ROM_Rev6_7.BIN).
All four dumps also come from the independent
[ZEsarUX ROM archive](https://github.com/chernandezba/zesarux/tree/main/src),
downloaded 2026-10-23. Images remain unpatched guest Z80 firmware data; copyright
belongs to Microdigital and the respective original holders. Reference emulator
C/C++ ROM headers are not used; some include additional language-selector patches.

| File | Bytes | CRC32 | SHA-256 |
| --- | ---: | --- | --- |
| tk90x-es.rom | 16384 | 496573a1 | dc72ac2752d60604dcbd808dd292ca792ec7cf0f8c69fb6de2902788a40fc732 |
| tk90x-pt.rom | 16384 | 3e785f6f | f3892b4140901f8289b962f5e097cf330c6997260052baac351026639012beeb |
| tk95-es.rom | 16384 | 602ba2c9 | 4aa2421e29487917bfd183012b114a3caacbf10ff46f3686c87e94ba5c492819 |
| tk95-pt.rom | 16384 | 17368e07 | c0f7c0a7b2dd838488189cda052e414cd3474f3a718c1fde0a6cef3e8e0f4776 |

## General Sound 1.05b

`gs105b.rom` is the unchanged 32 KiB guest Z80 firmware by Stinger,
with fixes by psb and Evgeny Muchkin. It is embedded as RCDATA `ZX_GS105B`
in `ZX.Firmware.RES`; no external BIOS file is required. The General Sound
project was opened by its authors in 2007. Firmware remains guest program
data, with attribution and rights retained by its authors; no host binary
library or high-level MOD player is used.

Source: [original firmware archive](https://zxgit.org/RomanRom2/GeneralSound/src/commit/d0312a7f463138b8a151944893dcd09b1ced6db6/firmware/release/gs105b.rom),
downloaded 2026-10-24. Git blob, byte count, full source pins and diagnostics
are recorded in `codex-work/zx-generalsound/references.json`.

Bytes: 32768; CRC32: `0fe97025`;
SHA-256: `9948ec9617365fb1913b0c56e00d5f6b6a36084875cca16debae270a4c6e6adf`.

## NeoGS 1.11

`neogs111.rom` is the unchanged complete 512 KiB guest flash image from
NedoPC's [official update of 2026-02-07](http://nedopc.com/gs/up260207.zip),
downloaded 2026-10-24. It is embedded as RCDATA `ZX_NEOGS111`, including the
standard SD loader, main ROM 1.11 and FPGA boot data. Runtime starts with the
standard FPGA configured and executes the loader from flash page 0. There
are no ROM patches, command traps or external host binary libraries.
Firmware remains the work of Stinger, psb, Evgeny Muchkin, Savelij and the
NeoGS authors; original copyright remains with the respective authors.
The board model follows [NedoPC's published HDL](https://github.com/tslabs/neogs/tree/a1c3bbcd2f9bd74dfd44afdb5bb1729cbe9a1367).
VS1011e MP3, AMD flash erase/program and standard NedoPC FPGA configuration
are implemented natively. Modified/persisted flash uses the original cold
bootstrap; programmed bytes are saved as `zx.neogs.flash` beside the ZX
configuration. Factory resource bytes remain unchanged. No additional DSP
binary library or external decoder firmware is required.

Bytes: 524288; CRC32: `3605f8d8`;
SHA-256: `764fc819f831f64ce736d9254af4fb6dd6fcd154d09f494f3afab92543a0cd37`.
Full source URLs and hashes: `codex-work/zx-neogs/references.json`.


## DMA Ultrasound Card

DMA USC contains no BIOS or private sample RAM. The native 8237A/8253 model
uses motherboard RAM; this package adds no firmware resource. Original DMA
Demo programs are test fixtures under `codex-work/zx-dmausc/references`, not
BIOS images embedded into the application.

## ZXM-MoonSound YRW801

`yrw801.rom` is the unchanged 2 MiB Yamaha YRW801 sample table supplied in
[Mick's original board archive](http://micklab.ru/file/zxm_moonsound/yrw801m_1993.rar).
It is embedded as RCDATA `ZX_MOON_WAVE` in `ZX.Firmware.RES`; no external ROM
path is needed. The table is audio/header data, not a host library or executable
BIOS. Yamaha and the original respective rights holders retain their copyrights.
The factory resource is unchanged by guest flash programming; modified bytes
are saved separately as `zx.moonsound.flash`. The file was downloaded
2026-10-25 from the board author's publication.

Bytes: 2097152; CRC32: `2a9d8d43`;
SHA-256: `0481e861f639fa3d6a64a75b735035a54b0875d57aaae33fdbe400146c80423f`.
Primary schematic, chip documentation, archive and test-vector hashes are
recorded in `codex-work/zx-moonsound/references.json`.

## SID (eZX/MB)

The eLeMeNt ZX/MB03+ SID application interface requires no BIOS, sample ROM
or additional firmware. This package leaves `ZX.Firmware.rc`, `ZX.Firmware.RES`
and all existing firmware images unchanged. Hood's original Z80 SID players
are regression fixtures in `codex-work/zx-sid/references`, not application
resources or host binary libraries.
