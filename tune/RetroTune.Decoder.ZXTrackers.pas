unit RetroTune.Decoder.ZXTrackers;

interface

implementation

uses
  System.SysUtils, System.Math, RetroTune.Decoder, RetroTune.Binary,
  RetroTune.ZXTracker.Engine, ZX.Sound.YM2149;

type
  TZXTrackerDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FEngine: TZXTrackerEngine;
    FChip: TYM2149F;
    FInfo: TTuneInfo;
    FTotalTicks, FTick, FRemaining: Integer;
  public
    constructor Create(const Data: TBytes; const FormatName: string);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TZXTrackerDecoder.Create(const Data: TBytes; const FormatName: string);
begin
  inherited Create;
  try
    var Kind: TZXTrackerKind;
    var Module := NormalizeZXTracker(Data, FormatName, Kind);
    FEngine := TZXTrackerEngine.Create(Module, Kind);
    repeat
      FEngine.Tick;
      if FEngine.Looped then
        Break;
      Inc(FTotalTicks);
      if FTotalTicks >= 90000 then
        raise EArgumentException.Create('ZX tracker exceeds 30 minutes or has no valid song end');
    until False;
    if FTotalTicks = 0 then
      raise EArgumentException.Create('ZX tracker has an empty position list');
    FInfo.FormatName := FormatName;
    if FormatName = 'S' then
      FInfo.FormatName := 'ST1';
    case Kind of
      tkSTC:
        FInfo.Title := TextField(Module, 7, 18);
      tkGTR:
        FInfo.Title := TextField(Module, 7, 32);
      tkPT1:
        FInfo.Title := TextField(Module, 69, 30);
      tkPT2:
        FInfo.Title := TextField(Module, 101, 30);
      tkPSM:
        FInfo.Title := TextField(Module, 8, Module[0] + Integer(Module[1]) * 256 - 8);
      tkASC:
        begin
          var Start := 9 + Integer(Module[8]);
          if (Start + 63 <= Length(Module)) and (TextField(Module, Start, 18) = 'ASM COMPILATION OF') then
          begin
            FInfo.Title := TextField(Module, Start + 19, 20);
            FInfo.Artist := TextField(Module, Start + 43, 20);
          end;
        end;
      tkFTC:
        FInfo.Title := TextField(Module, 8, 42);
      tkPSC:
        begin
          FInfo.Title := TextField(Module, 25, 20);
          FInfo.Artist := TextField(Module, 49, 20);
        end;
    end;
  except
    on E: ERangeError do
      raise EArgumentException.Create('Truncated or invalid ZX tracker module');
  end;
  FInfo.TrackCount := 1;
  FInfo.DefaultTrack := 0;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.TrackDurations := [FTotalTicks / 50.0];
  FInfo.Details := 'YM2149F, 1.7734 MHz, 50 Hz, ABC stereo';
  FChip := TYM2149F.Create;
  SelectTrack(0);
end;

destructor TZXTrackerDecoder.Destroy;
begin
  FEngine.Free;
  FChip.Free;
  inherited;
end;

function TZXTrackerDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TZXTrackerDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('ZX tracker track');
  FEngine.Reset;
  FChip.Reset;
  FTick := 0;
  FRemaining := 0;
end;

function TZXTrackerDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
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
      var Registers := FEngine.Registers;
      for var Reg := 0 to 12 do
        FChip.WriteRegister(Reg, Registers[Reg]);
      if Registers[13] <> $FF then
        FChip.WriteRegister(13, Registers[13]);
      for var Channel := 0 to 2 do
        if FEngine.ToneRestart(Channel) then
          FChip.RetriggerTone(Channel);
    end;
    FChip.Sample(Samples[Result * 2], Samples[Result * 2 + 1]);
    Inc(Result);
    Dec(FRemaining);
  end;
end;

function OpenAS0(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'AS0');
end;

function OpenASC(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'ASC');
end;

function OpenFTC(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'FTC');
end;

function OpenGTR(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'GTR');
end;

function OpenPSC(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'PSC');
end;

function OpenPSM(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'PSM');
end;

function OpenPT1(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'PT1');
end;

function OpenPT2(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'PT2');
end;

function OpenSQT(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'SQT');
end;

function OpenST1(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'ST1');
end;

function OpenST3(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'ST3');
end;

function OpenSTC(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'STC');
end;

function OpenSTP(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'STP');
end;

function OpenS(const Data: TBytes): ITuneDecoder;
begin
  Result := TZXTrackerDecoder.Create(Data, 'S');
end;

initialization
  TTuneDecoders.RegisterFormat('.as0', 'ASC Sound Master 0', OpenAS0);
  TTuneDecoders.RegisterFormat('.asc', 'ASC Sound Master', OpenASC);
  TTuneDecoders.RegisterFormat('.ftc', 'Fast Tracker', OpenFTC);
  TTuneDecoders.RegisterFormat('.gtr', 'Global Tracker', OpenGTR);
  TTuneDecoders.RegisterFormat('.psc', 'Pro Sound Creator', OpenPSC);
  TTuneDecoders.RegisterFormat('.psm', 'Pro Sound Maker', OpenPSM);
  TTuneDecoders.RegisterFormat('.pt1', 'Pro Tracker 1', OpenPT1);
  TTuneDecoders.RegisterFormat('.pt2', 'Pro Tracker 2', OpenPT2);
  TTuneDecoders.RegisterFormat('.sqt', 'SQ-Tracker', OpenSQT);
  TTuneDecoders.RegisterFormat('.st1', 'Sound Tracker editor', OpenST1);
  TTuneDecoders.RegisterFormat('.st3', 'Sound Tracker 3 compilation', OpenST3);
  TTuneDecoders.RegisterFormat('.stc', 'Sound Tracker', OpenSTC);
  TTuneDecoders.RegisterFormat('.stp', 'Sound Tracker Pro', OpenSTP);
  TTuneDecoders.RegisterFormat('.s', 'Sound Tracker editor', OpenS);

end.

