unit PC.Sound.OPL;

interface

uses
  System.SysUtils, PC.OPL.Nuked, Core.AudioFilter;

type
  // Common AdLib / Sound Blaster synthesis backend. Instances own their state;
  // the internal pointer graph must never be copied as a plain record.
  TOPLSound = class
  private
    FChip: TOplChip;
    FOPL3, FOPL1: Boolean;
    FClock, FSampleRate, FDivider: Integer;
    FAddress: array[0..1] of Word;
    FRegisters: array[0..511] of Byte;
    FTimerValue: array[0..1] of Byte;
    FTimerRunning, FTimerMasked: array[0..1] of Boolean;
    FTimerCycles: array[0..1] of UInt64;
    FStatus: Byte;
    FPhase: Double;
    FFiltered: array[0..1] of Double;
    FFilter: array[0..1] of TPCMLowPass;
    procedure UpdateWaveforms;
  protected
    constructor CreateChip(IsOPL3: Boolean; Clock, SampleRate: Integer; IsOPL1: Boolean = False);
  public
    procedure Reset;
    procedure WriteRegister(RegisterID: Word; Value: Byte);
    procedure WritePort(Port: Byte; Value: Byte);
    function ReadPort(Port: Byte): Byte;
    function ReadStatus: Byte;
    procedure AdvanceClocks(Cycles: Cardinal);
    procedure GenerateNative(out Left, Right: SmallInt);
    procedure Sample(out Left, Right: SmallInt);
    procedure Render(var PCM: array of SmallInt; Frames: Integer);
    property Clock: Integer read FClock;
    property SampleRate: Integer read FSampleRate;
    property IsOPL3: Boolean read FOPL3;
  end;

  // YM3526: OPL synthesis with sine waveform only.
  TOPL1 = class(TOPLSound)
  public
    constructor Create(Clock: Integer = 3579545; SampleRate: Integer = 44100);
  end;

implementation

uses
  System.Math;

constructor TOPL1.Create(Clock, SampleRate: Integer);
begin
  CreateChip(False, Clock, SampleRate, True);
end;

constructor TOPLSound.CreateChip(IsOPL3: Boolean; Clock, SampleRate: Integer; IsOPL1: Boolean);
begin
  inherited Create;
  if (Clock < 1000000) or (Clock > 32000000) then
    raise EArgumentOutOfRangeException.Create('Invalid OPL clock');
  if (SampleRate < 8000) or (SampleRate > 192000) then
    raise EArgumentOutOfRangeException.Create('Invalid OPL sample rate');
  FOPL3 := IsOPL3;
  FOPL1 := IsOPL1;
  FClock := Clock;
  FSampleRate := SampleRate;
  if IsOPL3 then
    FDivider := 288
  else
    FDivider := 72;
  for var J := 0 to 1 do
    FFilter[J].Configure(Clock / FDivider, Min(14000, SampleRate * 0.4));
  Reset;
end;

procedure TOPLSound.Reset;
begin
  OPL3_Reset(@FChip, FSampleRate);
  FillChar(FAddress, SizeOf(FAddress), 0);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FTimerValue, SizeOf(FTimerValue), 0);
  FillChar(FTimerRunning, SizeOf(FTimerRunning), 0);
  FillChar(FTimerMasked, SizeOf(FTimerMasked), 0);
  FillChar(FTimerCycles, SizeOf(FTimerCycles), 0);
  FStatus := 0;
  FPhase := 0;
  for var J := 0 to 1 do
  begin
    FFiltered[J] := 0;
    FFilter[J].Reset;
  end;
end;

procedure TOPLSound.UpdateWaveforms;
begin
  for var J := $E0 to $F5 do
    if (FRegisters[1] and $20) <> 0 then
      OPL3_WriteReg(@FChip, J, FRegisters[J] and 3)
    else
      OPL3_WriteReg(@FChip, J, 0);
end;

procedure TOPLSound.WriteRegister(RegisterID: Word; Value: Byte);
begin
  if RegisterID > $1FF then
    raise EArgumentOutOfRangeException.Create('Invalid OPL register');
  if not FOPL3 and (RegisterID > $FF) then
    Exit;
  // YM3526 has no waveform-select enable or waveform registers.
  if FOPL1 then
  begin
    if RegisterID = 1 then
      Value := Value and $DF;
    if (RegisterID >= $E0) and (RegisterID <= $F5) then
      Value := 0;
  end;
  FRegisters[RegisterID] := Value;
  case RegisterID of
    2, 3:
      FTimerValue[RegisterID - 2] := Value;
    4:
      begin
        if (Value and $80) <> 0 then
          FStatus := 0
        else
          for var J := 0 to 1 do
          begin
            FTimerMasked[J] := (Value and ($40 shr J)) <> 0;
            if FTimerMasked[J] then
              FStatus := FStatus and not ($40 shr J);
            var Running := (Value and (1 shl J)) <> 0;
            if Running <> FTimerRunning[J] then
              FTimerCycles[J] := 0;
            FTimerRunning[J] := Running;
          end;
      end;
  end;
  if not FOPL3 then
  begin
    if RegisterID = 1 then
      UpdateWaveforms;
    if (RegisterID >= $E0) and (RegisterID <= $F5) then
      if (FRegisters[1] and $20) = 0 then
        Value := 0
      else
        Value := Value and 3;
  end;
  OPL3_WriteReg(@FChip, RegisterID, Value);
end;

procedure TOPLSound.WritePort(Port: Byte; Value: Byte);
begin
  Port := Port and 3;
  if not FOPL3 and (Port >= 2) then
    Exit;
  if (Port and 1) = 0 then
    FAddress[Port shr 1] := Value + Word(Port shr 1) * $100
  else
    WriteRegister(FAddress[Port shr 1], Value);
end;

function TOPLSound.ReadPort(Port: Byte): Byte;
begin
  if (Port and 1) = 0 then
    Result := ReadStatus
  else
    Result := $FF;
end;

function TOPLSound.ReadStatus: Byte;
begin
  Result := FStatus;
  if (Result and $60) <> 0 then
    Result := Result or $80;
  if not FOPL3 then
    Result := Result or 6;
end;

procedure TOPLSound.AdvanceClocks(Cycles: Cardinal);
begin
  for var J := 0 to 1 do
    if FTimerRunning[J] then
    begin
      FTimerCycles[J] := FTimerCycles[J] + Cycles;
      var Period := UInt64(256 - Integer(FTimerValue[J])) * Cardinal(FDivider) * Cardinal(4 shl (J * 2));
      if FTimerCycles[J] >= Period then
      begin
        FTimerCycles[J] := FTimerCycles[J] mod Period;
        if not FTimerMasked[J] then
          FStatus := FStatus or ($40 shr J);
      end;
    end;
end;

procedure TOPLSound.GenerateNative(out Left, Right: SmallInt);
var
  PCM: array[0..1] of SmallInt;
begin
  OPL3_Generate(@FChip, PCM);
  Left := PCM[0];
  if FOPL3 then
    Right := PCM[1]
  else
    Right := Left;
  AdvanceClocks(FDivider);
end;

procedure TOPLSound.Sample(out Left, Right: SmallInt);
begin
  FPhase := FPhase + FClock / (Double(FDivider) * FSampleRate);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    var L, R: SmallInt;
    GenerateNative(L, R);
    FFiltered[0] := FFilter[0].Process(L);
    FFiltered[1] := FFilter[1].Process(R);
  end;
  Left := EnsureRange(Round(FFiltered[0]), -32768, 32767);
  Right := EnsureRange(Round(FFiltered[1]), -32768, 32767);
end;

procedure TOPLSound.Render(var PCM: array of SmallInt; Frames: Integer);
begin
  if (Frames < 0) or (Frames > Length(PCM) div 2) then
    raise EArgumentOutOfRangeException.Create('Invalid OPL render buffer');
  for var J := 0 to Frames - 1 do
    Sample(PCM[J * 2], PCM[J * 2 + 1]);
end;

end.

