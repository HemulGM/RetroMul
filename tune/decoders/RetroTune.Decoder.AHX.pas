unit RetroTune.Decoder.AHX;

interface

implementation

uses
  System.SysUtils, RetroTune.Decoder, RetroTune.Binary, Amiga.AHX;

type
  TAHXDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FMachine: TAHX;
    FInfo: TTuneInfo;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
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

function TAHXDecoder.GetInfo: TTuneInfo;
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

function OpenAHX(const Data: TBytes): ITuneDecoder;
begin
  Result := TAHXDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.ahx', 'Amiga AHX', OpenAHX);
  TTuneDecoders.RegisterFormat('.hvl', 'HivelyTracker', OpenAHX);

end.

