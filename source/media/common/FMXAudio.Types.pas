unit FMXAudio.Types;

interface

uses
  System.SysUtils, Core.Bitstream;

const
  PLAYER_TIME_BASE = 1000000; // All public timestamps are signed microseconds.

type
  EPlayerError = Core.Bitstream.EBitstreamError;

  EPlayerFormat = Core.Bitstream.EBitstreamFormat;

  EPlayerUnsupported = class(EPlayerError);

  TPlayerState = (Closed, Ready, Playing, Paused, Ended, Failed);

  TTrackKind = (Unknown, Video, Audio);

  TMediaPacket = record
    TrackIndex: Integer;
    Data: TBytes;
    DTS, PTS, Duration: Int64;
    SourcePTS: Int64;
    SourceDuration: Int64;
    HasEdit, BeginsEdit: Boolean;
    EditStart, EditEnd, MediaTime: Int64;
    EditTimeScale: Cardinal;
    SourceTimeScale: Cardinal; // Exact audio trimming without microsecond rounding.
    KeyFrame: Boolean;
  end;

  TTrackInfo = record
    ID: Cardinal;
    Kind: TTrackKind;
    Codec: string;
    TimeScale: Cardinal;
    Duration: Int64;
    StartTime: Int64;
    Width, Height, SampleRate, Channels: Integer;
    CodecConfig: TBytes;
  end;

  TAudioFrame = record
    PTS: Int64;
    SamplePosition: Int64;
    SampleRate, Channels, Frames: Integer;
    Samples: TArray<SmallInt>; // Interleaved PCM16, Frames * Channels entries.
  end;

  IAudioDecoder = interface
    ['{DCBA7AFE-6C96-4A9B-85B5-F789C2623A01}']
    procedure Configure(const Track: TTrackInfo);
    procedure Send(const Packet: TMediaPacket);
    function Receive(out Frame: TAudioFrame): Boolean;
    procedure Flush;
    procedure Reset;
  end;

  IAudioOutput = interface
    ['{6135850B-1B1B-40BD-8B52-FA57A3EBD5D4}']
    procedure Open(SampleRate, Channels: Integer);
    procedure Write(const Frame: TAudioFrame);
    procedure Clear;
    function BufferedFrames: Integer;
    function PlayedFrames(out Frames: Int64): Boolean;
  end;

  // Submit a final partial block before starting playback or draining EOF.
  IAudioOutputDrain = interface
    ['{EC75D394-B27E-483D-9C11-2604240E467B}']
    procedure Flush;
  end;

  // Optional output control: fill a prepared PCM queue before starting playback.
  IAudioOutputPlaybackControl = interface
    ['{AFC5BEB8-8FB7-46E8-A088-781EA58BA707}']
    function SetPaused(Value: Boolean): Boolean;
  end;

  // Stateful audio extensions can depend on headers and predictors from older
  // packets, independently of the video keyframe selected by the demuxer.
  IAudioSeekHistory = interface
    ['{A089721B-18D6-42E1-B599-56F12D3F125A}']
    function RequiresFullPreroll: Boolean;
  end;

function RescaleTime(Value: Int64; SourceScale, DestScale: Cardinal): Int64;

implementation

function RescaleTime(Value: Int64; SourceScale, DestScale: Cardinal): Int64;
var
  Magnitude, Whole, Remainder, Fraction, Limit, Scaled: UInt64;
begin
  if SourceScale = 0 then
    raise EPlayerFormat.Create('Zero media timescale');
  if DestScale = 0 then
    Exit(0);
  Magnitude := UInt64(Value);
  Limit := High(Int64);
  if Value < 0 then
  begin
    Magnitude := UInt64(-(Value + 1)) + 1;
    Inc(Limit);
  end;
  Whole := Magnitude div SourceScale;
  Remainder := Magnitude mod SourceScale;
  Fraction := (Remainder * UInt64(DestScale)) div SourceScale;
  if Whole > Limit div DestScale then
    raise EPlayerFormat.Create('Media timestamp overflow');
  Scaled := Whole * DestScale;
  if Fraction > Limit - Scaled then
    raise EPlayerFormat.Create('Media timestamp overflow');
  Inc(Scaled, Fraction);
  if Value >= 0 then
    Result := Int64(Scaled)
  else if Scaled = UInt64(High(Int64)) + 1 then
    Result := Low(Int64)
  else
    Result := -Int64(Scaled);
end;

end.
