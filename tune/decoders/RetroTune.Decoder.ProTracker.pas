unit RetroTune.Decoder.ProTracker;

interface

implementation

uses
  System.SysUtils, RetroTune.Decoder, RetroTune.Binary, Amiga.ProTracker;

type
  TMODDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FMachine: TMOD;
    FInfo: TTuneInfo;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TMODDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FMachine := TMOD.Create(Data);
  FInfo.Title := FMachine.Title;
  FInfo.FormatName := 'MOD';
  FInfo.Details := Format('SoundTracker / ProTracker / %d sample channels', [FMachine.Channels]);
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.TrackDurations := [FMachine.FrameCount / 44100];
end;

destructor TMODDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function TMODDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TMODDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('MOD track');
  FMachine.Reset;
end;

function TMODDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
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

function OpenMOD(const Data: TBytes): ITuneDecoder;
begin
  Result := TMODDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.mod', 'Amiga SoundTracker / ProTracker MOD', OpenMOD);

end.

