unit RetroTune.Decoder.KSS;

interface

implementation

uses
  System.SysUtils, RetroTune.Decoder, RetroTune.Binary, MSX.AudioMachine;

type
  TKSSDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FMachine: TKSSAudio;
    FInfo: TTuneInfo;
    FFirst: Integer;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TKSSDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FMachine := TKSSAudio.Create(Data);
  FFirst := FMachine.FirstTrack;
  FInfo.FormatName := 'KSS';
  FInfo.TrackCount := FMachine.LastTrack - FFirst + 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.Details := 'Z80 / AY / SCC / YM2413 / MSX-AUDIO / SN76489';
  SetLength(FInfo.TrackDurations, FInfo.TrackCount);
  for var I := 0 to FInfo.TrackCount - 1 do
    FInfo.TrackDurations[I] := -1;
end;

destructor TKSSDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function TKSSDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TKSSDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('KSS track');
  FMachine.Reset(FFirst + Index);
end;

function TKSSDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  for var I := 0 to Frames - 1 do
    FMachine.Sample(Samples[I * 2], Samples[I * 2 + 1]);
  Result := Frames;
end;

function OpenKSS(const Data: TBytes): ITuneDecoder;
begin
  Result := TKSSDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.kss', 'MSX / Sega Master System KSS', OpenKSS);

end.

