unit Audio.Music.XM;

interface

uses
  System.SysUtils, Audio.Types;

function OpenXM(const Data: TBytes): IAudioSource;

implementation

uses
  System.Math, Audio.Decoder, Audio.Music.Tracker.Amiga.XM;

type
  TXMDecoder = class(TAudioMusicSource, IAudioSeekSource)
  private
    FMachine: TXM;
    FInfo: TAudioInfo;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
    function SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
  end;

constructor TXMDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FMachine := TXM.Create(Data);

  FInfo.Title := FMachine.Title;
  FInfo.FormatName := 'XM';
  FInfo.Details := Format('FastTracker II / %d channels', [FMachine.Channels]);
  FInfo.TrackCount := 1;
  FInfo.SampleRate := FMachine.SampleRate;
  FInfo.Channels := 2;
  FInfo.TrackDurations := [FMachine.FrameCount / FMachine.SampleRate];
end;

destructor TXMDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function TXMDecoder.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure TXMDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('XM track');
  FMachine.Reset;
end;

function TXMDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
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

function TXMDecoder.SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
var
  Count: Integer;
begin
  if Frame < 0 then
    raise EArgumentOutOfRangeException.Create('XM seek frame');
  FMachine.Reset;
  Result := 0;
  while Result < Frame do
  begin
    if Assigned(Cancelled) and Cancelled() then
      Break;
    Count := FMachine.Skip(Integer(Min(Frame - Result, Int64(4096))));
    if Count = 0 then
      Break;
    Inc(Result, Count);
  end;
end;

function OpenXM(const Data: TBytes): IAudioSource;
begin
  Result := TXMDecoder.Create(Data);
end;

end.

