unit RetroTune.Decoder.PT3;

interface

implementation

uses
  System.SysUtils, RetroTune.Decoder, RetroTune.Binary, RetroTune.PT3.Engine,
  ZX.Sound.YM2149;

type
  TPT3Decoder = class(TInterfacedObject, ITuneDecoder)
  private
    FEngine: TPT3Engine;
    FChips: array[0..2] of TYM2149F;
    FInfo: TTuneInfo;
    FTotalTicks, FTick, FRemaining: Integer;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TPT3Decoder.Create(const Data: TBytes);
begin
  inherited Create;
  try
    FEngine := TPT3Engine.Create(Data);
    // Scan tracker state only: PCM rendering is not needed for the exact length.
    repeat
      FEngine.Tick;
      if FEngine.Looped then
        Break;
      Inc(FTotalTicks);
      if FTotalTicks >= 90000 then
        raise EArgumentException.Create('PT3 exceeds the 30 minute limit');
    until False;
  except
    on E: ERangeError do
      raise EArgumentException.Create('Truncated or invalid PT3 data');
  end;
  for var Chip := 0 to FEngine.ChipCount - 1 do
    FChips[Chip] := TYM2149F.Create;
  var Header := FEngine.Header;
  FInfo.Title := TextField(Header, 30, 32);
  FInfo.Artist := TextField(Header, 66, 32);
  FInfo.FormatName := 'PT3';
  FInfo.TrackCount := 1;
  FInfo.DefaultTrack := 0;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.TrackDurations := [FTotalTicks / 50];
  FInfo.Details := Format('YM2149F, %d chip(s), 1.7734 MHz, 50 Hz, ABC stereo', [FEngine.ChipCount]);
  SelectTrack(0);
end;

destructor TPT3Decoder.Destroy;
begin
  for var Chip := 0 to 2 do
    FChips[Chip].Free;
  FEngine.Free;
  inherited;
end;

function TPT3Decoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TPT3Decoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('PT3 track');
  FEngine.Reset;
  for var Chip := 0 to FEngine.ChipCount - 1 do
    FChips[Chip].Reset;
  FTick := 0;
  FRemaining := 0;
end;

function TPT3Decoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while Result < Frames do
  begin
    if FRemaining = 0 then
    begin
      if FTick >= FTotalTicks then
        Break;
      FEngine.Tick;
      Inc(FTick);
      FRemaining := 882;
      for var Chip := 0 to FEngine.ChipCount - 1 do
      begin
        var Regs := FEngine.Registers(Chip);
        for var Reg := 0 to 12 do
          FChips[Chip].WriteRegister(Reg, Regs[Reg]);
        // $FF means no envelope restart; writing the same shape retriggers it.
        if Regs[13] <> $FF then
          FChips[Chip].WriteRegister(13, Regs[13]);
      end;
    end;
    var Left, Right: Integer;
    Left := 0;
    Right := 0;
    for var Chip := 0 to FEngine.ChipCount - 1 do
    begin
      var L, R: SmallInt;
      FChips[Chip].Sample(L, R);
      Inc(Left, L);
      Inc(Right, R);
    end;
    Samples[Result * 2] := Left div FEngine.ChipCount;
    Samples[Result * 2 + 1] := Right div FEngine.ChipCount;
    Inc(Result);
    Dec(FRemaining);
  end;
end;

function CreatePT3(const Data: TBytes): ITuneDecoder;
begin
  Result := TPT3Decoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.pt3', 'Pro Tracker 3 / TurboSound', CreatePT3);

end.

