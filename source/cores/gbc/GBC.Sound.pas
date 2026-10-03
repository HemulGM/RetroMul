unit GBC.Sound;

interface

uses
  GB.Sound;

const
  GB_AUDIO_SAMPLE_RATE = GB.Sound.GB_AUDIO_SAMPLE_RATE;
  GB_AUDIO_OVERSAMPLE = GB.Sound.GB_AUDIO_OVERSAMPLE;
  GB_AUDIO_INTERNAL_RATE = GB.Sound.GB_AUDIO_INTERNAL_RATE;
  GB_AUDIO_CHANNELS = GB.Sound.GB_AUDIO_CHANNELS;
  GB_AUDIO_BLOCK_SAMPLES = GB.Sound.GB_AUDIO_BLOCK_SAMPLES;
  GB_AUDIO_BLOCK_COUNT = GB.Sound.GB_AUDIO_BLOCK_COUNT;

type
  TIntegerArray = GB.Sound.TIntegerArray;

  TEnvelope = GB.Sound.TEnvelope;

  TBaseChannel = GB.Sound.TBaseChannel;

  TSquareWaveChannel = GB.Sound.TSquareWaveChannel;

  TWaveChannel = GB.Sound.TWaveChannel;

  TNoiseChannel = GB.Sound.TNoiseChannel;

  TGBSound = GB.Sound.TGBSound;

implementation

end.

