unit Video.AVC.Types;

interface

uses System.SysUtils, System.Types, Core.Bitstream;

const
  PlayerTimeBase = 1000000; // All public timestamps are signed microseconds.

type
  EPlayerError = Core.Bitstream.EBitstreamError;
  EPlayerFormat = Core.Bitstream.EBitstreamFormat;
  EPlayerUnsupported = class(EPlayerError);
  TPlayerState = (Closed, Ready, Playing, Paused, Ended, Failed);
  TTrackKind = (Unknown, Video, Audio);
  TDecoderKind = (Software, Hardware);
  TPixelFormat = (YUV420P, BGRA8, NV12);
  TColorMatrix = (BT601, BT709);

  TMediaPacket = record
    TrackIndex: Integer;
    Data: TBytes;
    DTS, PTS, Duration: Int64;
    SourcePTS: Int64;
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

  // A future backend owns and releases its native texture through this interface.
  // The core never assumes that a GPU frame has CPU-accessible pixels.
  IVideoSurface = interface
    ['{261DD1EE-7C03-49BF-8A50-94ECA0743EA2}']
    function GetSize: TSize;
    function GetPixelFormat: TPixelFormat;
    function GetBackendID: string;
  end;

  TVideoFrame = record
    Width, Height: Integer;
    PTS, Duration: Int64;
    Format: TPixelFormat;
    Matrix: TColorMatrix;
    FullRange: Boolean;
    Planes: array[0..2] of TBytes;
    Strides: array[0..2] of Integer;
    Surface: IVideoSurface;
    function IsHardware: Boolean;
  end;

  TAudioFrame = record
    PTS: Int64;
    SamplePosition: Int64;
    SampleRate, Channels, Frames: Integer;
    Samples: TArray<SmallInt>; // Interleaved PCM16, Frames * Channels entries.
  end;

  IVideoDecoder = interface
    ['{1C13BD89-D061-4BF2-9FA9-C39B9438D49A}']
    procedure Configure(const Track: TTrackInfo);
    procedure Send(const Packet: TMediaPacket);
    function Receive(out Frame: TVideoFrame): Boolean;
    procedure Flush; // Drain delayed frames at end of input.
    procedure Reset; // Discard references/output before a keyframe seek.
    function Kind: TDecoderKind;
  end;

  // Optional decoder scheduling hook. Reference reconstruction stays intact;
  // a software decoder may omit late pictures that cannot affect later frames.
  IVideoPresentationDeadline = interface
    ['{4FB18825-57D2-4F8A-8ACB-310382C9F0F6}']
    procedure SetMinimumPresentationTime(Time:Int64);
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

  // Stateful audio extensions can depend on headers and predictors from older
  // packets, independently of the video keyframe selected by the demuxer.
  IAudioSeekHistory = interface
    ['{A089721B-18D6-42E1-B599-56F12D3F125A}']
    function RequiresFullPreroll:Boolean;
  end;

function RescaleTime(Value: Int64; SourceScale, DestScale: Cardinal): Int64;

implementation

function RescaleTime(Value: Int64; SourceScale, DestScale: Cardinal): Int64;
var Whole, Remainder: Int64;
begin
  if SourceScale = 0 then raise EPlayerFormat.Create('Zero media timescale');
  if DestScale = 0 then Exit(0);
  Whole := Value div SourceScale;
  Remainder := Value mod SourceScale;
  if (Whole > High(Int64) div DestScale) or (Whole < Low(Int64) div DestScale) then
    raise EPlayerFormat.Create('Media timestamp overflow');
  Result := Whole * DestScale + Remainder * Int64(DestScale) div SourceScale;
end;

function TVideoFrame.IsHardware: Boolean;
begin
  Result := Surface <> nil;
end;

end.
