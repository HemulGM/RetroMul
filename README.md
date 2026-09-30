# RetroMul — Delphi / FireMonkey

![screen](https://github.com/HemulGM/RetroMul/blob/main/screen/screen1.png?raw=true)

A Delphi multi-system emulator with an FMX interface for NES, Game Boy and Game Boy Color, Mega Drive (Genesis).
For NES, 47 mapper numbers are supported:
NROM, MMC1–MMC5, UxROM, CNROM, AxROM, Color Dreams, GxROM, Bandai, VRC,
Sunsoft, RAMBO-1, Namco 108, JY, Subor and other boards from the proven ROM collection.
Audio output is implemented for Windows (Win32/Win64), Linux64, Android (ARM/ARM64),
macOS (Intel/Apple Silicon) and iOS.

SDL is no longer required: the window, zoom, keyboard, timer, and PNG images
are implemented using FMX tools. 44 100 Hz streaming audio, mono PCM16 output via
Windows WaveOut (`Winapi.MMSystem`), ALSA (`libasound.so.2`) on Linux,
Android AudioTrack or Apple Audio Queue (AudioToolbox):
FMX Media does not provide a queue of arbitrary PCM samples.
On Windows, third-party DLLs and runtime packages are not needed; on Linux, ALSA is needed.

CPU/PPU/APU emulation and audio sending are performed in a separate thread
`NES.Emulation'. The FMX timer displays the last finished frame:
interface delays do not stop the game and do not accumulate a queue of frames.
Input and reset commands are passed to the thread under lock, and when the ROM is changed
or the application is closed, the audio device is released in the workflow,
and the console is released after the thread ends.

MMC3 supports PRG/CHR banks, mirroring switching, PRG RAM
and IRQ protection over A12 PPU. Adventure Island 2 has been tested with the transition to the first level.
The frame is drawn line by line, so switching banks between lines is saved
in the image. MMC3B/C and several derivative boards are implemented;
MMC6 is not supported yet. A12 filtering is approximate, the accuracy to each clock cycle of the PPU
is not stated. CNROM and GxROM account for bus conflicts; AxROM uses
the conflict-free option. Old iNES headers with the caption `DiskDude!` recognized
without changing the ROM on the disk. There is no full support for NES 2.0 extensions yet.

## Assembly

Open `fmx/RetroMul.dproj` in RAD Studio with Delphi FMX support, select
Win32 or Win64 and run Build. The form `fmx/RM.Main.fmx` is available for
visual editing. Sources are grouped by responsibility:

`IEmulationCore` is the frontend boundary for every console: it receives a
logical eight-button input state and produces a size-tagged, row-major FMX
frame. Platform-specific settings stay in the adapter, so a future core only
needs an adapter plus a folder under `source/cores/`. The current frontend
selects NES for .nes, Game Boy for .gb, Game Boy Color for .gbc,
and SEGA Mega Drive (Genesis) for .smd, .bin, .gen, .md ROMs.
All three adapters support reset. GB/GBC/SEGA save states remain unsupported.
Tested with Delphi 13 / compiler 37.0.

The audio subsystem is separate from the platform API: `PCM.Audio` provides a common
facade, `PCM.Audio.Windows.MMSystem` implements output via WaveOut, `PCM.Audio.Linux.Alsa` via
ALSA, `PCM.Audio.Android.AudioTrack` via AudioTrack, and `PCM.Audio.Apple.AudioQueue` via
AudioToolbox on macOS/iOS. Unsupported platforms use `PCM.Audio.Null`:
emulation continues without sound, with the reason available through `Audio.Error`.

## Launch and management

Run the EXE and select `rom` in the dialog

### ROMs folder
```
ROMS\
  gb -> (gamelist.xml + *.gb)
  gbc -> (gamelist.xml +*.gbc)
  megadrive -> (gamelist.xml +*.gen, *.md, *.bin, *.smd)
  nes -> (gamelist.xml +*.nes)
```
Use [Skraper](https://www.skraper.net) to create gamelist.xml and parsing your rom files (select RecalBox as platform)

## Game

| Key | Action |
| --- | --- |
| Z / X | A / B |
| Space / Enter | Select / Start |
| Arrows | Directions |
| G / H | A / B of the second player |
| T / Y | Select / Start of the second player |
| W / S / A / D | Up / down / left / right of the second player |
| N / M | A / B of the third player |
| U / O | Select / Start of the third player |
| I / K / J / L | Up / Down / Left / Right of the third player |
| Num 1 / Num 3 | A / B of the fourth player |
| Num 7 / Num 9 | Select / Start the fourth player |
| Num 8 / Num 5 / Num 4 / Num 6 | Directions of the fourth player (Num Lock enabled) |
| Ctrl+O | "Open" another ROM |
|R | Reset console |
| F5 | Save PNG 256×240 to "Documents" folder |
| F6 | Save the last ~30 seconds of audio and diagnostics to "Documents" |
| Esc | Close the application |

When you lose focus, the emulation and sound continue, and the pressed buttons are reset.
The window can be scaled;
the proportions of the image are preserved. An invalid ROM does not replace the current game.
If the sound device is unavailable, the app informs you about it and runs without sound.


Four virtual NES gamepads are independently controlled from the keyboard.
By default, the NES Four Score adapter is enabled: port `$4016` transmits buttons
for players 1 and 3, port `$4017` for players 2 and 4, then each port transmits
the adapter signature. The game must support Four Score; the number of players
is selected in the game itself. The Famicom protocol for four players has not yet been implemented.
Protocol description: [NESdev](https://www.nesdev.org/wiki/Controller_detection#Four_Score).

Mapper 167 Subor educational-computer ROMs automatically connect the Subor
Keyboard. The PC keyboard then supplies its 13-row matrix through `$4016/$4017`;
letters, number row, arrows, editing keys, modifiers and F1–F12 are supported.
For these ROMs Esc, R and F5/F6 are delivered to the emulated keyboard rather
than handled as application shortcuts.
