unit Audio.Music.KSS;

interface

uses
  Audio.Types, System.SysUtils, Audio.Decoder;

function OpenKSS(const Data: TBytes): IAudioSource;

implementation

uses
  Audio.Binary, MSX.AudioMachine;

type
  TKSSDecoder = class(TAudioMusicSource)
  private
    FMachine: TKSSAudio;
    FInfo: TAudioInfo;
    FFirst: Integer;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
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

function TKSSDecoder.GetInfo: TAudioInfo;
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

function OpenKSS(const Data: TBytes): IAudioSource;
begin
  Result := TKSSDecoder.Create(Data);
end;

end.

