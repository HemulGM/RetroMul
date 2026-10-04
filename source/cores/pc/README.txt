PC audio cores for the future RetroMul PC emulator

PC.Sound.OPL2: YM3812 / AdLib, 9 two-operator channels, mono.
PC.Sound.OPL3: YMF262 / Sound Blaster, 18 channels, 6 optional four-operator
pairs, 8 waveforms, stereo, rhythm, vibrato and tremolo. Reset starts in
OPL2 compatibility mode. Register $105 enables OPL3 mode.

These units belong to RetroMul. RetroTune uses them for YM3812/YMF262 VGM
and VGZ logs, including two instances of either chip. There is no complete
PC emulator here yet; this directory reserves its future location.

API

Create(Clock, SampleRate): source clock in Hz and output PCM sample rate.
Reset: resets synthesis, register latches, timers and resampling state.
WriteRegister: immediate write to a register ($000..$1FF).
WritePort / ReadPort: address/data ports, using offsets 0..3.
ReadStatus: timer flags/IRQ summary and the OPL2 identification bits.
GenerateNative: produces one native stereo PCM16 frame and advances timers
by Clock/72 (OPL2) or Clock/288 (OPL3) sample time.
Sample / Render: filtered PCM16 at the configured output rate.
AdvanceClocks: advances ONLY timers; do not also call this for clock time
already advanced by GenerateNative/Sample/Render.

Low-level OPL3_Generate4Ch exposes all four output buses. The high-level
stereo API uses buses A/B. Internal chip records contain direct references
to slots/channels; do not copy their memory to clone or save chip state.
Methods are intended for one emulation/playback thread per instance.

Arithmetic

Range and overflow checks remain enabled. Fixed-width chip values are
masked explicitly using wider intermediates. PCM uses bounded signed
conversion. There is no pointer indexing, pointer increment or address
arithmetic. Direct references between chip components are not moved.

Limits

This is a synthesis core with basic timer/status emulation, not a complete
AdLib/Sound Blaster device. CSM key triggering, physical bus delays/IRQ
callbacks, snapshots, Sound Blaster DSP/PCM, Y8950 ADPCM and the nonstandard
Nuked stereo extension are not implemented. YM3526 is not registered as a
supported VGM chip. VGM files requiring other chips are rejected explicitly.

Origin and license

PC.OPL.Nuked.pas is a Delphi translation of Nuked-OPL3 version 1.8 by
Nuke.YKT, copyright 2013-2020, LGPL-2.1-or-later. Its separate license is
included in LICENSE.Nuked-OPL3; the project's MIT license does not replace it.
Source: https://github.com/nukeykt/Nuked-OPL3
Reference commit: 765ec962e473aeb767e4cba74ffdc8f588ffbfe8
opl3.c SHA256: 59eb873fdb6d52bc7977a0fcbb97c1bae03dd71cc88e3acddbcc01b7121bfe03
opl3.h SHA256: a84266b8d71a4929f15f573afbe407fd24310b77757d855835dacabf68763679

Verification tools, C reference and logs are under codex-work.
OPLCoreTests compares 150000 native frames / 600000 output samples against
the C reference in Win32 and Win64 with range/overflow checks enabled.
The sequence covers banks, waveforms, rhythm, four-operator pairs, switching
compatibility modes and buffered writes. Format tests cover VGM/VGZ stereo,
dual chips, reset, gzip and EOF. The production code needs no C compiler,
external DLL, Python or reference test data.
