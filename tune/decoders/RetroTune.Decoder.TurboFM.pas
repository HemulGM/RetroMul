unit RetroTune.Decoder.TurboFM;

interface

implementation

uses
  System.SysUtils, RetroTune.Decoder, RetroTune.Binary, RetroTune.TFM.Stream,
  RetroTune.TFM.MusicMaker, ZX.Sound.YM2203;

type
  TTurboFMDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FStream: TTFMStream;
    FChips: array[0..1] of TYM2203;
    FInfo: TTuneInfo;
    FFrame, FRemaining: Integer;
  public
    constructor Create(const Data: TBytes; const Kind: string);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TTurboFMDecoder.Create(const Data: TBytes; const Kind: string);
begin
  inherited Create;
  if Kind = 'TFC' then
    FStream := ParseTFC(Data)
  else if Kind = 'TFD' then
    FStream := ParseTFD(Data)
  else
    FStream := ParseTFMMusicMaker(Data, Kind = 'TFE');
  if Length(FStream.Frames) = 0 then
    raise EArgumentException.Create('Empty TurboFM stream');
  FInfo.Title := FStream.Title;
  FInfo.Artist := FStream.Author;
  FInfo.FormatName := Kind;
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.TrackDurations := [Length(FStream.Frames) / FStream.Rate];
  FInfo.Details := Format('TurboFM, 2 x YM2203, 3.5 MHz, %d Hz, chip stereo', [FStream.Rate]);
  for var Chip := 0 to 1 do
    FChips[Chip] := TYM2203.Create;
  SelectTrack(0);
end;

destructor TTurboFMDecoder.Destroy;
begin
  for var Chip := 0 to 1 do
    FChips[Chip].Free;
  inherited;
end;

function TTurboFMDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TTurboFMDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('TurboFM track');
  for var Chip := 0 to 1 do
    FChips[Chip].Reset;
  FFrame := 0;
  FRemaining := 0;
end;

function TTurboFMDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while Result < Frames do
  begin
    if FRemaining = 0 then
    begin
      if FFrame = Length(FStream.Frames) then
        Break;
      for var W in FStream.Frames[FFrame] do
        FChips[W.Chip].WriteRegister(W.RegisterID, W.Value);
      Inc(FFrame);
      FRemaining := 44100 div FStream.Rate;
    end;
    Samples[Result * 2] := FChips[0].Sample;
    Samples[Result * 2 + 1] := FChips[1].Sample;
    Inc(Result);
    Dec(FRemaining);
  end;
end;

function OpenTF0(const Data: TBytes): ITuneDecoder;
begin
  Result := TTurboFMDecoder.Create(Data, 'TF0');
end;

function OpenTFE(const Data: TBytes): ITuneDecoder;
begin
  Result := TTurboFMDecoder.Create(Data, 'TFE');
end;

function OpenTFC(const Data: TBytes): ITuneDecoder;
begin
  Result := TTurboFMDecoder.Create(Data, 'TFC');
end;

function OpenTFD(const Data: TBytes): ITuneDecoder;
begin
  Result := TTurboFMDecoder.Create(Data, 'TFD');
end;

initialization
  TTuneDecoders.RegisterFormat('.tf0', 'TFM Music Maker 0.1–1.2', OpenTF0);
  TTuneDecoders.RegisterFormat('.tfe', 'TFM Music Maker 1.3+', OpenTFE);
  TTuneDecoders.RegisterFormat('.tfc', 'TurboFM Compiled', OpenTFC);
  TTuneDecoders.RegisterFormat('.tfd', 'TurboFM Dump', OpenTFD);

end.

