unit Audio.Types;

interface

uses
  System.SysUtils, Media.Types;

type
  // Pull sources return interleaved signed PCM16. Counts are audio frames.
  TAudioFormat = record
    SampleRate, Channels: Integer;
  end;

  IAudioSource = interface
    ['{066BC72E-941B-48B6-BA9D-672F41E03E06}']
    function GetFormat: TAudioFormat;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

  TAudioMetadataField = record
    Name, Value: string;
  end;

  TAudioInfo = record
    Title, Artist, CopyrightText, FormatName, Details: string;
    TrackCount, DefaultTrack, SampleRate, Channels: Integer;
    TrackNames: TArray<string>;
    // Seconds per logical track; missing entries / negative values mean unknown.
    TrackDurations: TArray<Double>;
    Metadata: TArray<TAudioMetadataField>;
  end;

  // Metadata and track selection are optional capabilities, separate from PCM.
  IAudioMetadata = interface
    ['{EDE6E61B-DB20-4926-BC09-E98842584323}']
    function GetInfo: TAudioInfo;
  end;

  IAudioTracks = interface
    ['{2CE0438F-050D-425E-8B56-59F0FE884BCE}']
    procedure SelectTrack(Index: Integer);
  end;

  IAudioSeekSource = interface
    ['{6D281F3A-1EF3-4A47-9B57-70C5244218C2}']
    function SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
  end;

  TAudioFormatInfo = record
    Extension, Description: string;
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

implementation

end.

