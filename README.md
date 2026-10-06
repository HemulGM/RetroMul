# RetroMul — Delphi / FireMonkey

![screen](https://github.com/HemulGM/RetroMul/blob/main/screen/screen1.png?raw=true)

A Delphi multi-system emulator with an FMX interface for NES, Game Boy and Game Boy Color, Mega Drive (Genesis), and SNES.
The new native Delphi [SNES core] includes two controllers, audio, SRAM and save states. This initial
port supports ordinary ROM/RAM cartridges, OBC1, S-DD1, NEC DSP, ST010/ST011 and CX4 cartridges;
DSP-1/1B/2/3/4 and ST010/ST011/ST018 firmware is embedded in the program resources;
no separate firmware files are needed.
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

`IEmulationCore` is the frontend boundary for every console: it receives
logical button states (including SEGA's six action buttons and a second pad)
and produces a size-tagged, row-major FMX
frame. Platform-specific settings stay in the adapter, so a future core only
needs an adapter plus a folder under `source/cores/`. ROMs are loaded from
`TStream`; NES, Game Boy, Game Boy Color, Mega Drive and SNES are identified by
their headers, regardless of the filename extension. SMD and byte-swapped
Mega Drive dumps are normalized before loading. The caller owns the stream
and may release it immediately after construction; reset uses the loaded bytes.
All adapters support reset and save states.
Tested with Delphi 13 / compiler 37.0.

To build release archives for Win32, Win64, Linux64, Android32 and Android64 on Windows:

```powershell
.\BuildReleases.ps1
# Build selected platforms or choose a RAD Studio installation:
.\BuildReleases.ps1 -Platforms win32,win64 -BdsPath 'G:\Program Files (x86)\Embarcadero\Studio\37.0'
# Build only Android32 (RAD Studio platform name: Android):
.\BuildReleases.ps1 -Platforms android32
```

The script discovers RAD Studio, loads `rsvars.bat`, and builds
`fmx/RetroMul.dproj` with `Config=Release`. Install the corresponding platform
compilers and configure the Linux and Android SDKs in RAD Studio first.
Archives are written to `releases/RetroMul-win32.zip`, `RetroMul-win64.zip`,
`RetroMul-linux64.zip`, `RetroMul-android32.zip`, and `RetroMul-android64.zip`. Each contains only the
application: `RetroMul.exe`, `RetroMul` (with Linux execute permission), or
`RetroMul.apk`. Linux requires the FMX system libraries and ALSA.
Android uses APK packaging with the SDK debug certificate for sideloading;
the native binary is optimized Release code. RAD Studio's APK packaging mode
sets `android:debuggable=true`; this is a sideload build, not a store-signed release.
The script does not install the APK on a device. A failed build stops the script
and leaves the previous archive for that platform untouched.

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
  snes -> (gamelist.xml + *.sfc, *.smc, *.swc, *.fig)
```
Use [Skraper](https://www.skraper.net) to create gamelist.xml and parsing your rom files (select `RecalBox` as platform)

If there is no `gamelist.xml` file in the system folders, the list will load as it is, without logos and additional information.

`TStorage` implements the shared `IStorage` interface passed to each core.
It provides streams for ROMs, core configuration, battery saves, snapshots,
previews and cassettes. The selected ROM folder is persisted in `storage.ini`;
lists use filenames and sizes, include only `root/<system>/*`, and skip files
larger than 64 MiB. Headers are checked only when opening a ROM. Android
document URIs are opened directly through the document provider.
The listing size filter can be disabled with `Storage.CheckRomFileSize := False`.
Set `Storage.MaxRomFileSize` to a positive byte count to change its limit;
the default is `64 * 1024 * 1024`. These settings belong to the storage instance
and affect listing; each core still validates its ROM format when opening it.
Application data is stored under `Documents/RetroMul` (or the platform's
home directory when Documents is unavailable). Manual snapshot enumeration
returns both the state location and its optional BMP preview.

## Game

| Key | Action |
| --- | --- |
| Z / X / C | A / B / C|
| A / S / D | X / Y / Z|
| Space / Enter | Select (Mode) / Start |
| Arrows | Directions |
| Ctrl+O | "Open" another ROM |
| R | Reset console |
| P | Pause console |
| F5 | Save quick snapshot (NES, GB, GBC, Mega Drive) |
| F6 | Load quick snapshot (NES, GB, GBC, Mega Drive) |
| F8 / PNG button | Save a screenshot to `Documents/RetroMul/screenshots` |
| F11 | Fullscreen mode |

SEGA supports two independent six-button controllers. Player 1 uses the keys
above and the Android screen gamepad. Player 2 uses the numeric keypad
(with Num Lock enabled):

| Player 2 key | SEGA button |
| --- | --- |
| Numpad 8 / 5 / 4 / 6 | Up / Down / Left / Right |
| Numpad 1 / 2 / 3 | A / B / C |
| Numpad 7 / 9 / Decimal | X / Y / Z |
| Numpad 0 | Start |
| Numpad Multiply | Mode |

Both mappings can be configured in `md.ini`: `[Keys]` for player 1 and `[Keys2]`
for player 2, using the button names and numeric virtual-key codes.
The game must support two players; select its two-player mode in the game menu.
Frontends can supply both pads through `TEmulatorInput.Buttons` and `Buttons2`.
Keyboard and gamepad input are merged independently for each player.
On the screen gamepad, rolling one finger from an action button onto another
keeps the first button held and adds the button under the finger. Rolling back
releases the added button; lifting the finger or leaving the action area releases
the combination. This works for NES A/B and all six SEGA action buttons.
Mega Drive snapshots now use version 2 to preserve both controller handshakes;
older Mega Drive snapshots are rejected. GB/GBC snapshot versions are unchanged.

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

SNES settings offer a Multitap switch for each physical controller port.
Enable port 2 for five controllers, or both ports for eight; the game must support
the chosen configuration. Players 1 and 2 retain their existing bindings.
The port-2 adapter supplies players 2–5; the port-1 adapter supplies players
1, 6, 7 and 8. Assign the extra controllers and their input devices in SNES settings.
Both adapters are disabled by default. Serial reads support both data lines,
pair selection through `$4201`, adapter detection, and automatic joypad polling.
SNES snapshots use version 9 to preserve all eight controller shift registers;
older SNES snapshots are rejected. Battery saves are unaffected.

Mapper 167 Subor educational-computer ROMs automatically connect the Subor
Keyboard. The PC keyboard then supplies its 13-row matrix through `$4016/$4017`;
letters, number row, arrows, editing keys, modifiers and F1–F12 are supported.
For these ROMs Esc, R and F5/F6 are delivered to the emulated keyboard rather
than handled as application shortcuts.

Family BASIC Keyboard (HVC-007) connects automatically for NES 2.0 expansion
device `$23` and the known legacy Family BASIC v1.0, v2.0, v2.1 and v3.0 ROMs.
Its separate screen control follows the original 72-key layout and supplies
the nine-row matrix plus the empty tenth scan row through `$4016/$4017`.
Screen and host input are combined; Windows distinguishes both Shift keys.
Host Alt maps to GRPH, Caps Lock to KANA, Home to CLR HOME, Pause to STOP,
backslash to yen, equals to caret, grave to `@`, quote to colon, and the extra
ISO key to underscore. The ROM interprets shifted and kana characters.
Keyboard input takes precedence over Esc, R, P, F5/F6 and Ctrl+O shortcuts.

Famicom Data Recorder connects for NES 2.0 expansion device `$20`, alongside
Family BASIC Keyboard (`$23`), and for known legacy Wrecking Crew, Excitebike
and Mach Rider ROMs. Legacy detection uses the PRG+CHR SHA-1, excluding headers
and trailing title data; explicit NES 2.0 device metadata takes precedence.
Its standalone cassette control offers Play, Record and Stop. To save, click Record before
starting SAVE in the game, then Stop when SAVE completes. To load, click Play
before starting LOAD in the game. One cassette per game is stored as
`saves/<game>_<ROM hash>/data.tape` under the configured save root.
The cassette map shows a line where the signal changes, with gaps for constant
signal and a marker for the current position. Rewind/forward move by 5% of the
cassette length; Stop preserves the position for the next Play. Seeking is
disabled during recording. The control shows read/write activity, progress and
counts of raw signal bytes (not decoded game data).
Choose file mounts an existing `.tape` or a new empty cassette; ROM cassette
returns to the game's default `data.tape`. On Android, selected documents are
imported into the application's cassette directory; recording updates that copy.
Save as exports the current cassette to a new file without changing the mounted
file, transport or position; partial recording bytes are included. Android uses
the system document picker to save outside the application's private directory.
The core API also accepts an explicit cassette filename. Tape commands work
while paused; pausing freezes the tape, and closing/resetting a game finishes
recording. NES snapshots version 14 include tape contents, transport state and
the seek position. Version 13 tapes remain readable; older snapshots restore
an idle recorder.
