ZX Spectrum sound cores
=======================
ZX.Sound.YM2149.pas implements Yamaha YM2149F independently of CPU and memory.
This directory is reserved for a future ZX Spectrum emulator in RetroMul.
The unit is registered in RetroMul and RetroTune; no external DLL is required.

TYM2149F accepts the input clock, PCM sample rate and SEL pin level. It exposes
register/address-data access, two I/O ports with callbacks, channel panning,
native DAC levels and interleaved stereo signed 16-bit PCM. Default: 1.7734 MHz,
44100 Hz, ABC stereo. Low-pass filtering precedes PCM resampling; PCM output
also removes DC. Tone/noise periods of zero behave as period one; writing R13
always restarts the envelope, including a repeated value. Envelope resolution
is 32 levels and fixed volume uses the measured YM logarithmic DAC table.

DAC values and the tone/noise/envelope model follow Peter Sovietov's Ayumi:
https://github.com/true-grue/ayumi
MIT license is preserved in LICENSE.Ayumi. The PCM filter is RetroMul's
Core.AudioFilter, not Ayumi's FIR resampler; filtered PCM is not bit-identical
to Ayumi. Native digital channel levels are checked against Ayumi separately.

All code runs with overflow/range checks enabled. State uses bounded integers,
arrays and records; there is no pointer arithmetic or disabled overflow check.

PT3 replay lives in tune/RetroTune.PT3.Engine.pas and its PCM adapter in
tune/RetroTune.Decoder.PT3.pas. The kernel also plays YM2149 VGM/VGZ logs.
