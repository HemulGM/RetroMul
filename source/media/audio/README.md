# RetroMul audio library

This is RetroMul's shared native Pascal audio library. RetroTune is a client in
`apps/retrotune`. Shared modules never import that application or its forms.

| Location | Responsibility |
| --- | --- |
| `Audio.Types` | PCM source/format, optional metadata/tracks/seeking, packet audio contracts |
| `Audio.Decoder` | Source helpers, optional track adapter, resolver contract, render bounds |
| `Audio.Registry` | Independently owned format registries and companion-file loaders |
| `codecs/{aac,atrac3,atrac3plus,mp3}` | Low-level compressed audio decoding |
| `formats/{wav,midi}` | WAV files and Standard MIDI/RMID parsing |
| `music/formats` | Machine music and tracker format adapters |
| `music/dumps` | VGM/GYM/XGM, OPL and AY register logs |
| `music/containers` | TurboSound/MTC/Vortex text and TR-DOS music extraction |
| `music/trackers` | Tracker interpretation and rendering engines |
| `synthesis/soundfont` | SoundFont synthesis and standard-bank catalog |
| `processing` | Transforms and spectrum/stereo analysis |
| `common` | Audio binary fields and codec bitstream helpers |
| `export` | Streaming WAV writing and cancellable export jobs |
| `../common/Media.Types` | Shared media packets, track descriptions and timestamps |
| `../../runtime/audio/Core.Audio.Player` | Playback thread and PCM device ownership |
| `../archive/Core.Compression.LH5` | Standalone LH5 decompression |

Hardware chips remain in `source/hardware/audio`; machine audio adapters remain
in `source/cores`. The packet APIs of AAC/ATRAC/MP3 are preserved; no decoder
algorithm changes are required by this layout.

## PCM and optional capabilities

`IAudioSource` exposes only `GetFormat` and `Render`. PCM is signed 16-bit,
interleaved, and counts are frames. Render returns zero at EOF. Source methods
belong to one worker at a time; read metadata before transferring ownership.

`IAudioMetadata`, `IAudioTracks` and `IAudioSeekSource` are optional. A WAV source
supports metadata and seeking without pretending to have selectable music tracks.
`GetAudioInfo` supplies single-stream defaults when optional metadata is absent.
`TAudioMusicSource` adapts existing track-based music implementations to PCM.

The player and exporter accept plain PCM sources, including fresh forward-only
sources. A forward-only source cannot be replayed or repositioned after use:
the player reports that capability limit instead of silently reusing its cursor.
Export resets track/seek sources; forward-only input is consumed as supplied.

## Application composition

`TAudioRegistry.Create` creates an empty independent registry. There is no shared
global format list or decoder self-registration. Populate an `IAudioRegistry`
before publishing it to workers; registrations must not change while it is used.
Different applications/instances can register different extensions independently.

`RetroTune.Formats.CreateRetroTuneFormats` constructs the application's complete
set. `RegisterRetroTuneFormats` explicitly initializes its application-owned
instance before forms are created. J2ME creates WAV/MIDI directly, including
Nokia WAV playback and snapshot restoration; it needs no registry.

Container factories take `IAudioResolver` and retain it when deferred track
selection needs it. Nested opens use the supplied resolver and preserve the
bounded recursion guard. Factories do not capture registry instances, avoiding
reference cycles. `TAudioWavExport` also retains its caller-supplied resolver.

SoundFont banks and their preparation script are in `assets/music/soundfonts`.
PSP snapshots retain the previous serialized name of `TInverseMDCT`; the Pascal
unit name changed, but that existing snapshot identifier did not.
