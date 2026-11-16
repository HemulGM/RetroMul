unit Audio.Music.AHX;

interface

uses
  Audio.Types, System.SysUtils, Audio.Decoder;

function OpenAHX(const Data: TBytes): IAudioSource;

implementation

uses
  Audio.Binary, Audio.Music.Tracker.Amiga.AHX;

type
  TAHXDecoder = class(TAudioMusicSource)
  private
    FMachine: TAHX;
    FInfo: TAudioInfo;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

constructor TAHXDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FMachine := TAHX.Create(Data);
  FInfo.FormatName := 'AHX';
  if FMachine.IsHVL then
    FInfo.FormatName := 'HVL';
  FInfo.TrackCount := FMachine.TrackCount;
  FInfo.Title := FMachine.Title;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.Details := Format('%s / Amiga / %d synthesized voices', [FInfo.FormatName, FMachine.ChannelCount]);
  SetLength(FInfo.TrackDurations, FInfo.TrackCount);
  for var I := 0 to FInfo.TrackCount - 1 do
    FInfo.TrackDurations[I] := FMachine.FrameCount(I) / 44100;
  FMachine.Reset(0);
end;

destructor TAHXDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function TAHXDecoder.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure TAHXDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('AHX track');
  FMachine.Reset(Index);
end;

function TAHXDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while Result < Frames do
  begin
    if not FMachine.Sample(Samples[Result * 2], Samples[Result * 2 + 1]) then
      Break;
    Inc(Result);
  end;
end;

function OpenAHX(const Data: TBytes): IAudioSource;
begin
  Result := TAHXDecoder.Create(Data);
end;

end.

