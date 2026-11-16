# RetroMul music library

This directory belongs to RetroMul and contains its native Pascal music library.
RetroTune is a client application in `apps/retrotune`; its forms and application
settings stay there. Shared code must not depend on RetroTune units or app paths.

| Directory | Units and purpose |
| --- | --- |
| `common` | `Music.Binary` and `Music.Compression.LH5`: music-file helpers |
| `decoders` | `Music.Decoder` interfaces, registry and format implementations |
| `synthesis` | `Music.SoundFont` and `Music.SoundFont.Catalog`: SF2 synthesis and presets |
| `trackers` | `Music.*` tracker engines and the existing `Amiga.*` players |
| `playback` | `Music.Player` and `Music.Spectrum`: playback and analysis |
| `export` | `Music.Export.WAV`: PCM export |

RetroMul and its terminal frontend use the shared WAV/MIDI decoders for J2ME.
RetroTune uses these same units plus the game-music and tracker decoders. Hardware
and machine emulation remain in `source/hardware` and `source/cores`.

SoundFont banks, license notices and the packaging script are shared assets in
`assets/music/soundfonts`. J2ME embeds TimGM6mb from that directory; RetroTune's
Windows build prepares the standard banks beside the executable in `sf2`.

Decoder units expose public factories and perform no automatic format registration.
RetroTune explicitly registers its own formats in `RetroTune.Formats` before
creating forms. J2ME creates WAV/MIDI decoders directly, including snapshot restore,
and does not use the application format registry.

Project files reference the shared source files directly. Do not add copies or
compatibility wrappers named `RetroTune.*` to this library.
