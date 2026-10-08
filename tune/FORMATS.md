# Interface language

RetroTune includes English and Russian translations in its `TLang` component. At startup, Russian system locales select Russian; English and other locales select English. English is also used if the system locale service is unavailable. The translations are embedded in the application and do not require external language files. File names, track titles, and artist metadata retain their original text.

# Active-file information

The “i” button opens a dynamically created window with static file information. Values use `TEdit` fields with `ReadOnly=True` and the borderless `editstyle_clear_sized` style, so they can be selected and copied. Information is grouped into cards with WinUI 3 headings and spacing; rows inside each group are separated by `TPanel` dividers with height 1 and the `panelstyle_divider` style. The window shows the name, full path, and size of the snapshot of the open file, every `TTuneInfo` field, track names and durations, and additional decoder metadata. Opening another file replaces its contents. Unknown duration is explicitly indicated.

The “Formats” button opens a separate reference of every registered extension and format name, sorted by extension. It is available without loading a file and uses the same appearance, `ReadOnly` fields, and 40-pixel rows as the information window. The list comes from the application's decoder registry. Both reference windows use smooth scrolling.

# WAV playback

The `.wav` extension is included in the common registry and open dialog. Supported formats are RIFF/WAVE PCM 8/16/24/32-bit and IEEE Float 32/64-bit, mono and stereo, including WAVE_FORMAT_EXTENSIBLE with PCM or Float subformats. The original sample rate is retained, and data is converted to PCM16 for the existing player. Reset, seeking, and end-of-file termination are supported.

The decoder handles arbitrary chunk order, odd sizes, and RIFF alignment; it validates sizes, sample rate, bit depth, byte rate, and block alignment. All LIST/INFO text fields are extracted; INAM/IART/ICOP also populate the title, artist, and copyright. Original PCM parameters and RIFF chunk sizes are available in the information window. Compressed subformats, multichannel audio, RF64/RIFX, and multiple data chunks are unsupported. WAV input may be up to 512 MiB; other formats retain the 16 MiB limit.

`WavDecoderTests` uses 19 independently generated Python PCM/Float fixtures and checks exact samples, INFO, extensible headers, EOF, re-export, 63 malformed inputs, and playback/seeking of a file larger than 16 MiB. `InfoFormTests` checks that all values are read-only and that the window refreshes. These checks are included in `codex-work/tools/CheckWavExport.ps1` for Win32/Win64.

# WAV export

The “Export WAV…” button saves the selected track of any supported file from its beginning. It uses a separate decoder and a snapshot of the open file; the player's position, selected track, and volume do not change. WAV contains the original PCM16 at the source sample rate and channel count, without applying player volume.

Before saving, the maximum duration in seconds is requested. The default is the known track length, or 180 seconds for files of unknown length. EOF finishes export before the requested duration. For files with multiple tracks, the track number is appended to the suggested WAV filename.

Export runs in the background, displays progress, and can be stopped with “Cancel export”. After completion, cancellation, or failure, the panel can be hidden with “×”; this button is unavailable during export. Closing the application cancels and joins the thread. The destination is replaced only after recording and updating the RIFF header have finished; errors and cancellation preserve an existing destination. Limits: a positive duration of up to 86400 seconds and a RIFF size of up to 4 GiB. Open/save dialogs and the duration prompt target desktop platforms.

Checks: `codex-work/tools/CheckWavExport.ps1` builds RetroTune and runs WAV and form checks on Win32/Win64 with range/overflow checking. Coverage includes PCM, headers, EOF, duration limits, track selection, independence from player state, cancellation, failures, and destination preservation; real fixtures cover 47 extensions. `codex-work/tools/VerifyWavExport.py` reads results with Python's independent standard WAV parser. Results and form images are in `codex-work/build/wav-export`.

# Vortex, TurboSound, and TurboFM

RetroTune registers `.txt` (Vortex Tracker), `.ts` (TurboSound), `.tf0`, `.tfe`, `.tfc`, `.tfd`, and `.mtc`.

- Vortex TXT is compiled to PT3 for the existing engine, including notes, samples, ornaments, envelopes, and effects. Binary PT3 limits apply: up to 85 used patterns and a module smaller than 64 KiB.
- TS plays two embedded modules simultaneously. Their types come from the standard `02TS` footer.
- TF0/TFE are unpacked and executed as TFM Music Maker; TFC/TFD contain register streams. Tempo, arpeggio, slides, portamento, vibrato, special channel-3 frequencies, operator settings, and row loops are supported.
- TurboFM uses two YM2203 chips at 3.5 MHz: the first on the left, the second on the right. `source/cores/zx/ZX.Sound.YM2203.pas` uses the existing OPN2 FM operators and YM2149 PSG core, with its own full FM-signal mixing and YM2203 dividers.
- MTC mixes tracks simultaneously, selects an available DATA representation, and uses PROP `Filename` to identify a format without a signature. Embedded data uses the common `TTuneDecoders.OpenData` registry, making registered decoders available.

Playback ends after one pass; reset and seeking use the normal player mechanism. Limits: 16 MiB input, 90000 TurboFM frames, 32 MTC streams, and nesting depth 8. Malformed data is checked before array access. Code runs with range/overflow checking and without pointer arithmetic.

Format descriptions were checked against [ZXTune](https://github.com/vitamin-caig/zxtune): `formats/chiptune/fm`, `protracker3_vortex.cpp`, `turbosound.cpp`, `multitrackcontainer.cpp`, and `module/players/tfm`. The FM core uses RetroMul's existing `MD.Sound`, without an external library.

Checks: `codex-work/tools/CheckExtendedFormats.ps1`; logs: `codex-work/build/turbofm/Win32` and `Win64`. Coverage includes all 12 examples of the seven new formats, EOF, reset, PCM independence from buffer size, seeking, malformed inputs, containers, FM/PSG frequencies, and existing PT3/YM2149 references.

# E-Tracker and digital trackers

The following formats were added:

| Format | Extensions | Playback |
| --- | --- | --- |
| E-Tracker | `.cop`, `.etc` | SAA1099, six voices with independent left/right volume |
| Spectrum TAP | `.tap` | E-Tracker extraction from tape blocks; each module is a separate track |
| Chip Tracker | `.chi` | Four sample channels, slides, sample start offsets |
| Digital Music Maker | `.dmm` | Three channels, packed 4-bit samples, vibrato, arpeggio, slides, note retrigger, volume changes, and mixins |
| Digital Studio | `.dst` | Three channels, Covox and AY sample variants, ordinary and compiled bank layouts |
| SQ Digital Tracker | `.sqd` | Four channels, memory banks, sample loops, and volume slides |
| Sample Tracker | `.str` | Three sample channels |
| Extreme Tracker | `.et1`, `.d`, `.m` | Four channels; versions 1.31 and 1.32–1.41, volume or glissando depending on version |
| ProDigiTracker | `.pdt`, `.m` | Four channels, memory banks, sample loops, and ornaments |

For `.m`, the type is detected from the contents. New extensions are automatically included in the file-open filter through the common decoder registry. Decoders return stereo PCM at 44.1 kHz and support track selection, reset, and seeking. Duration corresponds to one pass through the position list; sample loops remain active.

Shared cores were also added to RetroMul: `source/cores/zx/ZX.Sound.DAC.pas` plays samples with fractional position and interpolation; `source/cores/sam/SAM.Sound.SAA1099.pas` implements tone and noise generators, both envelopes, envelope resolution, right-channel inversion, deferred waveform changes, and hardware mixing. SAA1099 runs at 8 MHz. The `source/cores/sam` directory is also intended for a future SAM Coupé core.

The TAP decoder validates block lengths and XOR checksums. It extracts E-Tracker music and names from tape headers; executing tape programs is outside its scope. The `zx-saa-sound4.tap` fixture exposes 56 tracks, including a module variant with a shortened header.

Bank addresses are converted to checked array indices. New cores and decoders run with `{$Q+}`/`{$R+}`, without pointer arithmetic. Limits: 90000 frames per track, 256 tracks, and 1800000 total frames in a TAP file; pattern, sample, and ornament stream lengths are also bounded.

File layouts and commands were checked against primary [ZXTune](https://github.com/vitamin-caig/zxtune/tree/develop/src/formats/chiptune) implementations: `digital` and `saa/etracker.cpp`. Envelope and hardware-mixing behavior was checked against [SAASound](https://github.com/stripwax/SAASound); RetroMul's cores are implemented in Pascal and require no external library.

Checks: `codex-work/tools/CheckDigitalFormats.ps1`; logs: `codex-work/build/digital/Win32` and `Win64`. Both platforms check all 16 files (71 tracks), EOF and duration, identical PCM after reset and with different buffer sizes, seeking, 3072 malformed inputs, TAP checksums, and form loading. Separate core tests compare 2880 envelope states with an independent SAASound reference, tone frequency, stereo, DAC loops, and preservation of SAA1099 phase while muted. Both RetroTune and RetroMul build for Win32 and Win64.

# TIA, MSX, PC Engine, Amiga, Dreamcast, and TR-DOS

| Format | Extensions | Pascal implementation |
| --- | --- | --- |
| TIATracker | `.ttt` | Two TIA voices, instruments, percussion, envelopes, slides, overlay, PAL/NTSC, and tempo changes |
| Atari 2600 | `.a26` | Music ROM execution on 6507, RAM/RIOT, WSYNC, TIA; 2/4 KiB and F8/F6 8/16 KiB cartridges |
| MSX / SMS | `.kss` | KSCC/KSSX, Z80, 8/16 KiB banks, AY, SCC/SCC+, YM2413, MSX-AUDIO FM, and SN76489 with separate Game Gear outputs |
| PC Engine | `.hes` | HuC6280, MPR, RAM, timer/VBlank interrupts, six PSG channels, waveforms, noise, DDA, and LFO |
| Amiga AHX | `.ahx` | Standalone AHX THX0/THX1 engine: four voices, waveform synthesis, filters, envelopes, macro commands, and effects |
| Dreamcast | `.dsf`, `.minidsf` | PSF12, ARM7DI, 64 AICA PCM/ADPCM voices, envelopes, loops, LFO, filter, timers/FIQ, and DSP |
| TR-DOS | `.trd`, `.scl` | Disk/archive directory, tracker-module and PSID extraction; each detected music file is a track |

All engines are in `source/cores/a2600`, `msx`, `sms`, `pce`, `amiga`, and `dc`, and are registered in the main RetroMul project. External DLLs are unnecessary. AHX is a tracker format played by its own engine without running a 68000 program. New extensions are included in the RetroTune decoder registry and open dialog.

TTT and AHX finish after one pass and report duration. A26, KSCC, and HES have unknown duration: use manual stop and an export limit. KSCC without an extended header exposes 256 track numbers, although the file may contain fewer songs; KSSX uses the header's track-number bounds. DSF uses `length`/`fade` tags; without `length`, playback continues until manually stopped.

DSF/MiniDSF loads relative `_lib`, `_lib2`…`_lib32` libraries in PSF order, validates CRC32 and sizes, and rejects dependency cycles. A self-contained program snapshot is created before handing data to the player; reset and export do not reread libraries. Limits: 8 MiB RAM, depth 16, and 128 libraries. Malformed files cannot specify addresses outside RAM. MiniDSF packages should be opened by path through `ReadData`/`Open`; `OpenData` requires an already resolved snapshot.

TRD/SCL validates file bounds, sector overlaps, and the SCL checksum. Recognized formats include ASC/AS0/PT1/PT2/STC/STP/PSC/FTC/GTR/PSM/SQT, PT3 (including modules embedded in an executable), and PSID. A PT3 pair in a compiled TurboSound player remains two chips playing simultaneously. The decoder extracts music; it does not boot the disk OS or execute BASIC. Non-music, unknown, and unsupported files (such as RSID) are skipped.

Current implementation limits: KSS MSX-AUDIO implements FM without Y8950 Delta-T ADPCM; HES supports PSG without CD-ROM ADPCM. A26 targets music ROMs of the stated cartridge types and does not emulate game video/input. AICA has an approximate filter, and the ARM interpreter's clock model is simplified; DSF does not yet guarantee bit-exact hardware PCM. It executes 32-bit ARM instructions, without Thumb.

New cores, decoders, and shared data handlers use `{$Q+}`/`{$R+}` and explicit bit-width masks; they do not use `label`/`goto`, manual pointer movement, or disabled checks. Pointer arithmetic found in RetroMul snapshot PNG previews was replaced by array traversal; RGBA conversion during video-frame upload also uses a row array. Delphi sources are UTF-8 with a BOM.

Tests are in `codex-work/tests/retrotune`; run `codex-work/tools/CheckRemainingFormats.ps1`; logs are in `codex-work/build/remaining`. Coverage includes 70 TTT, 5 A26, 37 audible KSS tracks, eight tracks in each of two HES files, complete playback of two AHX files, DSF with 6681150 frames (including fade), and 116 TRD/SCL with 13629 music files. For AHX, the first 20 seconds of both modules match independent HivelyTracker output; YM2413 matches emu2413 bit-for-bit for 288000 samples. Tests include 1536 malformed/truncated inputs, independence of two decoders, 262144 HuC6280 arithmetic cases, ARM/FIQ/shifts, 20000 boundary chip/DSP states, F8/F6, and Game Gear stereo. Range/overflow checking is enabled on Win32/Win64.

Adapted-component licenses: MIT emu2413 (`msx/LICENSE.emu2413.txt`), BSD-3-Clause HivelyTracker (`amiga/LICENSE.hivelytracker.txt`), and MAME AICA/DSP (`dc/LICENSE.MAME-AICA.txt`).

# D15, MD1, SNG, and DebugAY


`.md1` is Atari Music ProTracker with one digital-sample channel. The player automatically reads an adjacent file with the same basename and `.d15` extension, falling back to `.d8`. A missing sample bank rejects the file with an explanatory error. Both parts are retained in one memory snapshot: seeking, replay, and WAV export are independent of later file changes. The Pascal core and embedded MPT routine are in `source/cores/atari/Atari.Audio.MPT.pas`, registered in RetroMul and RetroTune. MPT support is based on ASAP and distributed under GPL-2.0-or-later along with the embedded 6502 routine; the license text is adjacent.

`.d15` is a standalone MPT 4-bit sample bank rather than a complete tune. Each sample is available as a separate track. POKEY playback accounts for nibble order and the Atari vertical-blank pause. MD1 contains notes, instruments, tempo, and positions, which play together with the digital samples. Multiple song positions and module/bank relocation when overlapping the embedded player's memory are supported.

`.sng` is supported as **raw E-Tracker data for SAM Coupé** with the `ETracker` signature, similar to COP/ETC. It uses the existing Pascal E-Tracker engine and SAA1099 with six stereo channels. SNG is also used by incompatible GoatTracker, AdLib, and MIDI-sequencer formats; those files and SNG with embedded executable players are outside the supported variant.

`.debugay` is a ZXTune text dump: a header with the 14 AY register numbers, followed by one frame per line. Two hexadecimal digits mean a register write, two spaces mean no write, and `=` means an unchanged frame. The frame rate is 50 Hz, the AY clock is 1773400 Hz, and the default panning is ABC. Not writing register 13 preserves the envelope; writing it again restarts it. LF/CRLF and UTF-8 BOM are supported. The dump reproduces AY only: separate beeper or other chip audio, note structure, and instrument names are absent.

`LegacyTailTests` checks 21 Atari tracks from the ZEROSIGN pair in `test_data`, official ASAP barymag examples, and relocated-address/D8-bank variants; the first three seconds of every track are compared byte-for-byte with an independent ASAP build. D15 and ZEROSIGN.MD1 also receive full EOF checks. All 46 DebugAY files in `test_data` are compared with independently converted PSG logs; repeated envelope writes, unchanged frames, and EOF are checked separately. SNG is compared with COP through the end of the tune. Checks cover reset, PCM block splitting, instance independence, and 1280 malformed/truncated inputs. Command: `codex-work/tools/CheckLegacyTailFormats.ps1 -Platform Win32` (or Win64); first run `codex-work/tools/MakeLegacyTailGolden.py` for references after preparing ASAP in `codex-work/tools/legacy-tail-reference`.

Format descriptions: [ASAP](https://asap.sourceforge.net/formats.html), [DebugAY dumper](https://github.com/vitamin-caig/zxtune/blob/develop/src/devices/aym/dumper/debug.cpp), [SCPlayer E-Tracker detection](https://github.com/Deltafire/SCPlayer/blob/master/src/SCPlayer.cpp).

`LegacyTailLifecycleTests` separately checks actual seeking for all four formats and an independent WAV-export thread with exact PCM, MD1 loading without a bank and its explanatory error, export after deleting both source files, and permitted D15 trailing padding. All checks run with Q+/R+ on Win32 and Win64.

# IMF, DRO, HVL, XGM, and MOD


| Format | Extensions | Supported variants |
| --- | --- | --- |
| AdLib IMF | `.imf` | Type 0 and type 1 register streams, OPL2 |
| DOSBox RAW OPL | `.dro` | Versions 1.0 and 2.0, single/dual OPL2 and OPL3, including original v1 unescaped initialization writes |
| HivelyTracker | `.hvl` | HVL 0/1, 4–16 voices, stereo, dual effects, ring modulation, and instrument performance lists |
| Mega Drive XGM | `.xgm`, `.xgm2`, `.xgc` | XGM1 and XGM2, PAL/NTSC, YM2612, PSG, PCM, multiple tracks, packed XGM2, and compiled XGM2 without the file signature |
| ProTracker / SoundTracker | `.mod` | 15/31 samples, standard four-channel signatures and numeric 1–32 channel signatures, sample loops, finetune, and tracker effects |

All formats use Pascal engines and the existing audio chips, without external DLLs. They are registered in RetroTune's format list and open dialog and support reset, seeking, known duration, and WAV export. Playback stops after one traversal of the song; MOD pattern loops execute their prescribed repeats. The ProTracker core is also included in RetroMul; HVL extends the shared AHX engine.

IMF has no timer-frequency field: playback currently uses 700 Hz. Files made for 280 or 560 Hz require a future frequency selector. DRO v0 and compressed/encoded DRO v2 streams are unsupported. MOD is a family of incompatible layouts: exotic signatures such as FEST, FA06, FLT8, CD81, and OKTA and packed modules are outside this implementation. MOD playback is not claimed to be bit-exact to Amiga hardware. `.xgc` support covers compiled XGM2; XGM1 compiled driver blobs and `.xgz` are not registered here.

Format and command references: [SGDK XGM](https://github.com/Stephane-D/SGDK/blob/master/bin/xgm.txt), [SGDK XGM2](https://github.com/Stephane-D/SGDK/blob/master/bin/xgm2.txt), [libvgm DRO player](https://github.com/ValleyBell/libvgm/blob/master/player/droplayer.cpp), [HivelyTracker](https://github.com/pete-gordon/hivelytracker), and [ProTracker clone](https://github.com/8bitbubsy/pt2-clone). HivelyTracker and the ProTracker finetune table carry adjacent BSD-3-Clause license notices in `source/cores/amiga`.

Checks: `codex-work/tools/CheckNewFormats.ps1 -Platform Win32` or `Win64`, with range and overflow checking; logs are in `codex-work/build/new-formats`. Synthetic fixtures and real HVL/MOD songs cover full playback, duration, reset, independence from render-block size, actual player seeking, and independent WAV export. Tests also cover 2816 malformed/truncated inputs, OPL stream equivalence, MOD pattern-loop duration, 4/8/16-channel HVL ring modulation, and SGDK-generated single/multitrack plain and packed XGM2 files. The synthetic XGM tone matches its equivalent VGM stream and SGDK conversions byte-for-byte. `CompareHVLReference.py` compares the first 20 seconds of ten real HVL songs with an independent C HivelyTracker build; all samples match exactly. Existing AHX lifecycle checks and both application builds pass on Win32 and Win64.

# MIDI / General MIDI

RetroTune registers `.mid`, `.midi`, `.rmi` (RIFF/RMID), and `.kar` (karaoke audio). SMF 0 and 1 merge all source tracks into one song; SMF 2 exposes each source track as a separate song. The Pascal parser supports four-byte variable-length quantities, running status across delta times and meta events, simultaneous events, tempo changes, PPQN, SMPTE 24/25/30 and 29.97 drop-frame timing, title and copyright metadata, and GM/GM2/GS/XG reset messages. Track chunks bound parsing; legacy complete chunks without End-of-Track and exporter footers are accepted. Incomplete events and corrupt headers/chunk lengths are rejected.

Playback uses the shared `RetroTune.SoundFont` PCM synthesizer with the supplied GeneralUser GS bank by S. Christian Collins. Its own license and source/hash information are in `tune/soundfonts`. All three standard banks and their license notices are placed in the `sf2` directory beside the executable during builds. No platform MIDI service or external synthesis DLL is required. The default bank loads from that directory; the SoundFont button can also select an external SF2 file. The path is retained in `RetroTune.ini` in the user's home directory. Selecting another bank rebuilds the loaded MIDI from its in-memory file snapshot and restores its selected track, position and playback state; existing decoder instances retain their original immutable bank. Bank selection is disabled during WAV export.

The synthesizer handles preset/instrument global and local zones, key/velocity layers, signed PCM16 samples, fractional playback with interpolation, sample loops, root keys and tuning, amplitude and modulation envelopes, modulation/vibrato LFOs, a resonant low-pass filter, stereo panning, exclusive percussion groups, and up to 256 sample voices. MIDI notes, note-on velocity zero, program/bank selection with GM fallback, volume, expression, pan, modulation, sustain, pitch bend, RPN pitch range/tuning, and all-notes/all-sounds/reset-controller messages are supported. Reset, seeking, visualization and WAV export use the normal PCM player.

Limits: 16 MiB MIDI input, 256 source tracks, two million events per sequence, 24 hours per song, and 256 MiB SF2 input. Reported duration includes a fixed two-second release tail, after which playback/export ends. Compressed SF3, ROM samples, arbitrary SF2 modulator tables, chorus/reverb, polyphonic/channel pressure and vendor-specific GS/XG effect commands are not implemented. Karaoke lyrics are skipped. SoundFont rendering is not claimed to be bit-exact to FluidSynth or hardware.

Checks: `codex-work/tools/CheckMIDI.ps1 -Platform Win32` or `Win64`; logs are in `codex-work/build/midi`. Independent synthetic fixtures verify tempo maps, format 2, all four SMPTE modes, RMID equivalence, a known SoundFont sample frequency, sustain, stereo, full EOF, reset, PCM independence from buffer size, actual player seeking, and sample-exact WAV output. All 128 GM programs and 47 standard percussion keys produce audio. Tests also exercise 512 malformed/mutated SF2 files and more than 1100 truncated/random MIDI inputs with range/overflow checking. The repository's MIDI collection provides 6027 successful parses and initial renders, including longer prefixes for selected files; 51 corrupt or over-limit inputs are rejected safely. `VerifyMidiTimings.py` compares 6005 song lengths against independent mido output to within one PCM frame; 22 files with invalid non-audio metadata are skipped by mido. `CheckMidiForm.ps1` verifies MIDI loading, controls and form rendering for Win32/Win64.

References: [MIDI Association SMF specification](https://midi.org/standard-midi-files), [SoundFont 2.04 specification](https://www.synthfont.com/sfspec24.pdf), and [GeneralUser GS](https://github.com/mrbumpy409/GeneralUser-GS). TinySoundFont and mido are used only as independent research/test references and are not linked into RetroTune.

## Standard SoundFont selection

The SoundFont button opens a menu with three supplied banks: GeneralUser GS, TimGM6mb, and FluidR3 GM. The current choice is checked; Custom SF2 remains available. Standard bank IDs persist across launches and resolve to files in the executable's `sf2` directory, while custom banks retain their selected file path. Menu availability checks the corresponding SF2 files. Selection remains disabled during WAV export and reloads a loaded MIDI from its input snapshot while retaining its track, position and playing/paused/stopped/finished state.

FluidR3 is supplied in two lossless package parts to keep individual repository files below 100 MiB; the build restores it as `sf2/FluidR3_GM.sf2`. The application reads plain SF2 files at runtime; no SoundFont resources or packed archives are linked into the executable. Exact sources, hashes, licenses and package format are documented in `tune/soundfonts/README.md`.

`CheckStandardSoundFonts.ps1` verifies all three banks on Win32/Win64: audible and distinct PCM, the selected-bank path, sample-exact WAV export, PCM equivalence of packed and original FluidR3, and preservation of the active bank after an invalid selection. The form checks also verify the three enabled menu items, custom-file action, and a single active-bank checkmark.

## Live audio buffering

The PCM player queues about 120–140 ms of audio at standard sample rates (1024-frame blocks; queue depth derives from sample rate). This replaces the previous 46 ms reserve at 44.1 kHz, which could drain during brief scheduler or driver delays even when MIDI synthesis was faster than real time. The decoder PCM and WAV export are unchanged.

The MIDI audio audit wraps the real Windows backend and runs the FMX form with HOOKSG.MID, measuring empty queues and dropped frames under injected 75 ms delivery delays. Before the change it reproduced 10 underruns in 10 seconds. Source and logs are in `codex-work/tests/retrotune/audio-audit` and `codex-work/build/midi-crackle`.
