unit RetroTune.Decoder.AY;

interface

implementation

uses
  System.SysUtils, System.Math, RetroTune.Decoder, RetroTune.Binary,
  ZX.AudioMachine;

type
  TAYDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FData: TBytes;
    FMachine: TZXAudioMachine;
    FInfo: TTuneInfo;
    FTracks: TArray<Integer>;
    FPosition, FEnd, FFade: Int64;
    function BE(Offset: Integer): Word;
    function Relative(Offset, Size: Integer): Integer;
    function NameAt(Offset: Integer): string;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function TAYDecoder.BE(Offset: Integer): Word;
begin
  RequireBytes(FData, Offset, 2);
  Result := Integer(FData[Offset]) * 256 + FData[Offset + 1];
end;

function TAYDecoder.Relative(Offset, Size: Integer): Integer;
begin
  var Delta: Integer := BE(Offset);
  if Delta >= 32768 then
    Dec(Delta, 65536);
  if Delta = 0 then
    raise EArgumentException.Create('Missing AY relative address');
  Result := Offset + Delta;
  RequireBytes(FData, Result, Size);
end;

function TAYDecoder.NameAt(Offset: Integer): string;
begin
  if BE(Offset) = 0 then
    Exit('');
  var Start := Relative(Offset, 1);
  var Count := 0;
  while (Start + Count < Length(FData)) and (FData[Start + Count] <> 0) and (Count < 4096) do
    Inc(Count);
  if (Start + Count >= Length(FData)) or (Count = 4096) then
    raise EArgumentException.Create('Unterminated AY text');
  Result := TextField(FData, Start, Count);
end;

constructor TAYDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Copy(Data);
  RequireBytes(FData, 0, 20);
  if TextField(FData, 0, 8) <> 'ZXAYEMUL' then
    raise EArgumentException.Create('Invalid AY signature');
  if FData[8] > 3 then
    raise EArgumentException.Create('Unsupported AY version');
  FInfo.FormatName := 'AY';
  FInfo.Artist := NameAt(12);
  FInfo.CopyrightText := NameAt(14);
  FInfo.TrackCount := Integer(FData[16]) + 1;
  FInfo.DefaultTrack := FData[17];
  if FInfo.DefaultTrack >= FInfo.TrackCount then
    raise EArgumentException.Create('Invalid AY default track');
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.Details := 'Z80 / YM2149F, Spectrum beeper / CPC, 50 Hz';
  SetLength(FTracks, FInfo.TrackCount);
  SetLength(FInfo.TrackNames, FInfo.TrackCount);
  SetLength(FInfo.TrackDurations, FInfo.TrackCount);
  var Table := Relative(18, FInfo.TrackCount * 4);
  for var I := 0 to FInfo.TrackCount - 1 do
  begin
    FInfo.TrackNames[I] := NameAt(Table + I * 4);
    FTracks[I] := Relative(Table + I * 4 + 2, 14);
    var LengthTicks := BE(FTracks[I] + 4);
    var FadeTicks := BE(FTracks[I] + 6);
    if LengthTicks = 0 then
      FInfo.TrackDurations[I] := -1
    else
      FInfo.TrackDurations[I] := (Integer(LengthTicks) + FadeTicks) / 50.0;
  end;
  FInfo.Title := FInfo.TrackNames[FInfo.DefaultTrack];
  FMachine := TZXAudioMachine.Create;
  SelectTrack(FInfo.DefaultTrack);
end;

destructor TAYDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function TAYDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TAYDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('AY track');
  for var I := 0 to 255 do
    FMachine.RAM[I] := $C9;
  for var I := 256 to $3FFF do
    FMachine.RAM[I] := $FF;
  for var I := $4000 to $FFFF do
    FMachine.RAM[I] := 0;
  var Track := FTracks[Index];
  var Points := Relative(Track + 10, 6);
  var Blocks := Relative(Track + 12, 2);
  var Init := BE(Points + 2);
  var Play := BE(Points + 4);
  var First := True;
  repeat
    var Address := BE(Blocks);
    if Address = 0 then
      Break;
    RequireBytes(FData, Blocks, 6);
    var Size := BE(Blocks + 2);
    var Source := Relative(Blocks + 4, Size);
    if Size > 65536 - Integer(Address) then
      raise EArgumentException.Create('AY block exceeds memory');
    for var I := 0 to Integer(Size) - 1 do
      FMachine.RAM[Integer(Address) + I] := FData[Source + I];
    if First and (Init = 0) then
      Init := Address;
    First := False;
    Inc(Blocks, 6);
  until False;
  if First then
    raise EArgumentException.Create('AY has no executable blocks');
  FMachine.Reset(FData[Track + 8], FData[Track + 9], BE(Points), Init, Play);
  FPosition := 0;
  FFade := Int64(BE(Track + 4)) * 882;
  if FFade = 0 then
    FEnd := -1
  else
    FEnd := FFade + Int64(BE(Track + 6)) * 882;
end;

function TAYDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while (Result < Frames) and ((FEnd < 0) or (FPosition < FEnd)) do
  begin
    var L, R: SmallInt;
    FMachine.Sample(L, R);
    var Gain: Double := 1;
    if (FEnd > FFade) and (FPosition >= FFade) then
      Gain := (FEnd - FPosition) / (FEnd - FFade);
    Samples[Result * 2] := Round(L * Gain);
    Samples[Result * 2 + 1] := Round(R * Gain);
    Inc(Result);
    Inc(FPosition);
  end;
end;

function OpenAY(const Data: TBytes): ITuneDecoder;
begin
  Result := TAYDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.ay', 'AY / ZX Spectrum / CPC', OpenAY);

end.

