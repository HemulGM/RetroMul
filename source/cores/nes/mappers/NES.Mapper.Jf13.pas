unit NES.Mapper.Jf13;

interface

uses
  System.SysUtils, NES.Types, NES.State, NES.Mapper, NES.Mapper.ExtendedDiscrete,
  Core.Storage, HW.Sound.UPD7756, NES.Audio.Recordings;

type
  TMapperJf13 = class(TMapperExtendedDiscrete)
  private
    type
      TSpeechState = packed record
        Control, Track, RateSelect, History: Byte;
        ResetTicks, Phase, Position, Level, Slope: Integer;
        Output: SmallInt;
        Playing: Boolean;
      end;
  private
    FUm5100: Boolean;
    FChip: TUpd7756;
    FSpeechRom: TBytes;
    FRecorded: TNesSpeechRecordings;
    FSpeech: TSpeechState;
    FCpuHz, FResetTicks: Integer;
    FHasAudio: Boolean;
    procedure StopSpeech;
    procedure StartSpeech;
    procedure ClockUm5100;
    procedure ClockRecorded;
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; const SpeechRom: TBytes);
    destructor Destroy; override;
    procedure LoadRecordings(const Storage: IStorage; const RomName: string);
    procedure Reset; override;
    procedure SetRegion(Region: TNesRegion); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
    procedure SerializeState(State: TNesStateArchive); override;
  end;

implementation

uses
  System.Classes, System.Math, NES.Consts, Core.Snapshots;

const
  UmTrackBytes = $800;
  UmTrackBits = UmTrackBytes * 8;

constructor TMapperJf13.Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; const SpeechRom: TBytes);
begin
  FUm5100 := Submapper = 1;
  if Length(SpeechRom) <> 0 then
    if FUm5100 then
      FSpeechRom := SpeechRom
    else
      FChip := TUpd7756.Create(SpeechRom);
  FHasAudio := Length(SpeechRom) <> 0;
  SetRegion(TNesRegion.NTSC);
  inherited Create(MAPPER_JALECO_JF13, Prg, Chr, HasChrRam, MirrorMode, Submapper);
end;

destructor TMapperJf13.Destroy;
begin
  FChip.Free;
  inherited;
end;

procedure TMapperJf13.LoadRecordings(const Storage: IStorage; const RomName: string);
begin
  if FUm5100 or (FChip <> nil) then
    Exit;
  FHasAudio := LoadSpeechRecordings(Storage, RomName, 'moepro', 16, FRecorded) or FHasAudio;
end;

procedure TMapperJf13.StopSpeech;
begin
  FSpeech.Playing := False;
  FSpeech.Output := 0;
  if FChip <> nil then
    FChip.Reset;
end;

procedure TMapperJf13.StartSpeech;
begin
  if not FHasAudio then
    Exit;
  if FChip <> nil then
  begin
    FChip.Start(FSpeech.Control and 15);
    Exit;
  end;
  if FSpeech.Playing and not FUm5100 then
    Exit;
  FSpeech.Track := FSpeech.Control and 15;
  FSpeech.Position := 0;
  FSpeech.Phase := 0;
  FSpeech.History := 2;
  FSpeech.Level := 0;
  FSpeech.Slope := 64;
  FSpeech.Output := 0;
  FSpeech.Playing := FUm5100 or (Length(FRecorded[FSpeech.Track].Samples) <> 0);
end;

procedure TMapperJf13.Reset;
begin
  inherited;
  Prg32(0);
  Chr8(0);
  FRamEnabled := False;
  FSpeech := Default(TSpeechState);
  FSpeech.Control := $30;
  StopSpeech;
end;

procedure TMapperJf13.SetRegion(Region: TNesRegion);
begin
  FCpuHz := CpuFrequency(Region);
  // The reset input of the uPD7756 needs at least 19 microseconds low.
  FResetTicks := (FCpuHz * Int64(19) + 999999) div 1000000;
end;

function TMapperJf13.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if Result then
    Value := FPrgRom[PrgOffset(Address)];
end;

function TMapperJf13.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if not FUm5100 then
    Address := Address and $7FFF;
  case Address shr 12 of
    5:
      if FUm5100 then
      begin
        FSpeech.RateSelect := Value;
        Exit(True);
      end;
    6:
      Exit(inherited CpuWrite(Address, Value));
    7:
      begin
        FSpeech.Control := Value;
        if (Value and $20) <> 0 then
          FSpeech.ResetTicks := 0;
        if ((Value and $10) = 0) and (FUm5100 or ((Value and $20) <> 0)) then
          StartSpeech;
        Exit(True);
      end;
  end;
  Result := False;
end;

procedure TMapperJf13.ClockUm5100;
begin
  Inc(FSpeech.Phase);
  var Period := 88;
  if (FSpeech.RateSelect and $80) <> 0 then
    Period := 176;
  if FSpeech.Phase < Period then
    Exit;
  FSpeech.Phase := 0;
  if FSpeech.Position = UmTrackBits then
  begin
    StopSpeech;
    Exit;
  end;

  var Data := FSpeechRom[FSpeech.Track * UmTrackBytes + (FSpeech.Position shr 3)];
  var Bit := (Data shr (7 - (FSpeech.Position and 7))) and 1;
  Inc(FSpeech.Position);
  FSpeech.History := ((FSpeech.History shl 1) or Bit) and 7;
  // CVSD uses a larger step for runs of matching bits. The analog
  // integrator leakage, envelope and output filter are approximated.
  if (FSpeech.History = 0) or (FSpeech.History = 7) then
    Inc(FSpeech.Slope, (16384 - FSpeech.Slope + 15) div 16)
  else
    FSpeech.Slope := Max(64, FSpeech.Slope * 253 div 256);
  FSpeech.Level := EnsureRange(FSpeech.Level * 255 div 256 +
    (2 * Bit - 1) * FSpeech.Slope, -32768, 32767);
  FSpeech.Output := SmallInt(FSpeech.Output + (FSpeech.Level - FSpeech.Output) div 4);
end;

procedure TMapperJf13.ClockRecorded;
begin
  Inc(FSpeech.Phase, FRecorded[FSpeech.Track].Rate);
  if FSpeech.Phase < FCpuHz then
    Exit;
  Dec(FSpeech.Phase, FCpuHz);
  if FSpeech.Position >= Length(FRecorded[FSpeech.Track].Samples) then
  begin
    StopSpeech;
    Exit;
  end;
  FSpeech.Output := FRecorded[FSpeech.Track].Samples[FSpeech.Position];
  Inc(FSpeech.Position);
end;

procedure TMapperJf13.ClockCpu;
begin
  if not FHasAudio then
    Exit;
  if FUm5100 then
  begin
    if FSpeech.Playing then
      ClockUm5100;
    Exit;
  end;
  if (FSpeech.Control and $20) = 0 then
  begin
    if FSpeech.ResetTicks = FResetTicks then
      Exit;
    Inc(FSpeech.ResetTicks);
    if FSpeech.ResetTicks = FResetTicks then
    begin
      StopSpeech;
      Exit;
    end;
  end;
  if FChip <> nil then
    FChip.Clock(FCpuHz)
  else if FSpeech.Playing then
    ClockRecorded;
  if (FSpeech.Control and $30) = $20 then
    if ((FChip <> nil) and not FChip.Playing) or ((FChip = nil) and not FSpeech.Playing) then
      StartSpeech;
end;

function TMapperJf13.ExpansionAudio: Double;
begin
  if FChip <> nil then
    Exit(FChip.Output * (1.0 / 131072.0));
  Result := FSpeech.Output * (1.0 / 131072.0);
end;

procedure TMapperJf13.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version < 38 then
  begin
    if State.Loading then
    begin
      FSpeech := Default(TSpeechState);
      FSpeech.Control := $30;
      StopSpeech;
    end;
    Exit;
  end;
  State.Field(FSpeech, SizeOf(FSpeech));
  if State.Loading then
  begin
    if (FSpeech.Track > 15) or (FSpeech.History > 7) or
      (Cardinal(FSpeech.ResetTicks) > Cardinal(FResetTicks)) or
      (Cardinal(FSpeech.Phase) >= Cardinal(FCpuHz)) or (Cardinal(FSpeech.Position) > 960000) or
      (FSpeech.Level < -32768) or (FSpeech.Level > 32767) or (Cardinal(FSpeech.Slope) > 16384) then
      raise EReadError.Create('Invalid Jaleco JF-13 speech state');
    if not FHasAudio or (FSpeech.Playing and not FUm5100 and
      ((Length(FRecorded[FSpeech.Track].Samples) = 0) or
      (FSpeech.Position > Length(FRecorded[FSpeech.Track].Samples)))) then
      StopSpeech;
    if FSpeech.Playing and FUm5100 and (FSpeech.Position > UmTrackBits) then
      raise EReadError.Create('Invalid UM5100 sample position');
  end;
  if FChip <> nil then
    State.SharedFields(
      procedure(Archive: TStateArchive)
      begin
        FChip.SerializeState(Archive, FCpuHz);
      end);
end;

end.

