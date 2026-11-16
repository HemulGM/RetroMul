unit Audio.Music.HES;

interface

uses
  Audio.Types, System.SysUtils, Audio.Decoder;

function OpenHES(const Data: TBytes): IAudioSource;

implementation

uses
  Audio.Binary, PCE.AudioMachine;

type
  THESDecoder = class(TAudioMusicSource)
  private
    FMachine: THESAudio;
    FInfo: TAudioInfo;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

constructor THESDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FMachine := THESAudio.Create(Data);
  FInfo.FormatName := 'HES';
  FInfo.TrackCount := 256;
  FInfo.DefaultTrack := FMachine.DefaultTrack;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.Details := 'HuC6280 / PSG';
  SetLength(FInfo.TrackDurations, FInfo.TrackCount);
  for var I := 0 to FInfo.TrackCount - 1 do
    FInfo.TrackDurations[I] := -1;
end;

destructor THESDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function THESDecoder.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure THESDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('HES track');
  FMachine.Reset(Index);
end;

function THESDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  for var I := 0 to Frames - 1 do
    FMachine.Sample(Samples[I * 2], Samples[I * 2 + 1]);
  Result := Frames;
end;

function OpenHES(const Data: TBytes): IAudioSource;
begin
  Result := THESDecoder.Create(Data);
end;

end.

