unit Media.Types;

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
