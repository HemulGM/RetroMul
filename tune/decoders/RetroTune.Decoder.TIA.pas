unit RetroTune.Decoder.TIA;

interface

implementation

uses
  System.SysUtils, RetroTune.Decoder, RetroTune.Binary, RetroTune.TIATracker,
  A2600.Sound.TIA, A2600.AudioMachine;

type
  TTIADecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FTrack: TTIATrack;
    FSound: TTIASound;
    FMachine: TAtari2600Audio;
    FInfo: TTuneInfo;
    FTick, FRemaining: Integer;
  public
    constructor Create(const Data: TBytes; IsROM: Boolean);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TTIADecoder.Create(const Data: TBytes; IsROM: Boolean);
begin
  inherited Create;
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  if IsROM then
  begin
    FMachine := TAtari2600Audio.Create(Data);
    FInfo.FormatName := 'A26';
    FInfo.TrackDurations := [-1];
    FInfo.Details := 'Atari 2600, 6507 / RIOT / TIA, PAL';
  end
  else
  begin
    FTrack := CompileTIATracker(Data);
    FInfo.FormatName := 'TTT';
    FInfo.Title := FTrack.Title;
    FInfo.Artist := FTrack.Artist;
    FInfo.TrackDurations := [Length(FTrack.Frames) / Double(FTrack.Rate)];
    FInfo.Details := 'TIATracker / TIA, two voices, ' + IntToStr(FTrack.Rate) + ' Hz';
    var Clock := 1182298.0;
    if FTrack.Rate = 60 then
      Clock := 1193191.666666667;
    FSound := TTIASound.Create(Clock);
  end;
  SelectTrack(0);
end;

destructor TTIADecoder.Destroy;
begin
  FMachine.Free;
  FSound.Free;
  inherited;
end;

function TTIADecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TTIADecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('TIA track');
  FTick := 0;
  FRemaining := 0;
  if FSound <> nil then
    FSound.Reset;
  if FMachine <> nil then
    FMachine.Reset;
end;

function TTIADecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while Result < Frames do
  begin
    if FMachine <> nil then
      FMachine.Sample(Samples[Result * 2], Samples[Result * 2 + 1])
    else
    begin
      if FRemaining = 0 then
      begin
        if FTick = Length(FTrack.Frames) then
          Break;
        for var I := 0 to 5 do
          FSound.WriteRegister($15 + I, FTrack.Frames[FTick][I]);
        Inc(FTick);
        FRemaining := 44100 div FTrack.Rate;
      end;
      FSound.Sample(Samples[Result * 2], Samples[Result * 2 + 1]);
      Dec(FRemaining);
    end;
    Inc(Result);
  end;
end;

function OpenTTT(const Data: TBytes): ITuneDecoder;
begin
  Result := TTIADecoder.Create(Data, False);
end;

function OpenA26(const Data: TBytes): ITuneDecoder;
begin
  Result := TTIADecoder.Create(Data, True);
end;

initialization
  TTuneDecoders.RegisterFormat('.ttt', 'TIATracker / Atari 2600', OpenTTT);
  TTuneDecoders.RegisterFormat('.a26', 'Atari 2600 cartridge music', OpenA26);

end.

