Neo Geo MVS core

Load named MAME ZIP sets or unencrypted NeoSD .neo images. Keep split-set
parents in the same directory. The current and legacy catalogs select ROM
wiring by set name and CRC, including older filenames with matching CRCs.
Unknown and protected variants without an implemented board are rejected
with a specific loading error; ZIP filenames alone do not guarantee support.

Implemented: Motorola 68000, Z80 with NMI sound commands, YM2610 FM/SSG and
ADPCM-A/B, planar sprites/FIX, shrink tables, animation, palette banks,
interrupts, watchdog, uPD4990 calendar, battery RAM and complete snapshots.
Protection: PRO-CT0 (Fatal Fury 2), KOF98, Metal Slug X, CMC42/50, SMA,
PCM2 and PVC for the catalogued original cartridge families. Bootleg boards:
CTHD2003/SP/SA, Garou, KOF2002/2003 derivatives, KOF10th/KF10THEP/KF2K5UNI,
SVC Bootleg/Plus/Super Plus, KOG, Lansquenet 2004, Samurai Shodown V Bootleg,
Matrimelee Bootleg, Metal Slug 3b6 and Metal Slug 5 Plus. Separate JAMMA PCB
wiring/decryption is supported for SVC, Metal Slug 5 and KOF2003. Metal Slug 5
PCB can reuse identical program chips from sibling mslug5.zip by CRC. Decrypted
clone chips can share still-encrypted parent chips; parent chains are bounded.
Jockey GP and V-Liner include persistent cartridge NVRAM. Irritating Maze
uses its own BIOS and trackball counters; mahjong controllers use a key matrix.

The host framebuffer stays black during the MVS BIOS memory tests.
The filter follows FIX-map initialization and cartridge graphics selection;
BIOS error messages and menus remain visible. CPU/VRAM/audio keep running
normally, with no startup timing shortcut or snapshot format change.

Video: 320 x 224; master clock 24 MHz; 1536 clocks x 264 lines per frame
(about 59.1856 Hz). Host audio is stereo 44100 Hz.
Default controls: arrows, Z/X/C/V = A/B/C/D, Enter = Start, 5 = Coin.
Second player: keypad 8/5/4/6, 1/2/3/Decimal, keypad 0, 6 = Coin.
Bindings are configurable in Neo Geo settings. Both ports work independently.
Irritating Maze: arrows move the trackball; Z/X operate its two buttons.
Mahjong (Bakatono, Minasan, Janshin): A-N select tiles, O = Pon, P = Chi,
Q = Kan, R = Ron, S = Reach, Enter = Start, 5 = Coin.
V-Liner: F1 = operator key, F2 = clear key, 5 = coin.

Limits: Neo Geo CD, linked cabinets/MCUs, physical analog paddle input,
and unlisted protection boards are not implemented. Paddle games use
their joystick mode. Memory card hardware is absent. The built-in BIOS runs in
MVS arcade mode, including when loading compatible AES cartridge dumps.
Neo Pong 1.0/1.1 use a permissive sprite-rendering compatibility profile:
their backgrounds exceed the physical 96-sprite line limit and otherwise
hide the foreground. Other games retain the physical limit. Sprite ROM
address lines mirror at the next power of two; unpopulated holes stay blank.
Audio is a functional synthesis implementation, not a cycle-exact analog
model. Full gameplay compatibility is not implied by a successful boot test.

The shared Z80 state has two new latches. Mega Drive snapshot format is
therefore version 5; earlier version 4 snapshots require the previous build.
Battery saves are unaffected.

Reference algorithms and attribution: LICENSE.txt. Firmware: firmware/README.txt.
Development probes and checks are under codex-work/neo-geo and codex-work/tests.
