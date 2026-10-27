unit PC.Sound.OPL;

interface

uses
  System.SysUtils, PC.OPL.Nuked, Core.AudioFilter, Core.Snapshots;

type
  TOPLTimerEvent = procedure(Timer: Integer) of object;

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
    FOnTimerOverflow: TOPLTimerEvent;
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
    procedure GenerateNative(out Left, Right: SmallInt; Timers: Boolean = True);
    procedure ClockNative;
    procedure CurrentSample(out Left, Right: SmallInt);
    procedure SetCSMKey(Enabled: Boolean);
    function RegisterValue(Index: Word): Byte;
    procedure SerializeState(State: TStateArchive);
    procedure Sample(out Left, Right: SmallInt; Timers: Boolean = True);
    procedure Render(var PCM: array of SmallInt; Frames: Integer);
    property Clock: Integer read FClock;
    property SampleRate: Integer read FSampleRate;
    property IsOPL3: Boolean read FOPL3;
    property OnTimerOverflow: TOPLTimerEvent read FOnTimerOverflow write FOnTimerOverflow;
  end;

  // YM3526: OPL synthesis with sine waveform only.
  TOPL1 = class(TOPLSound)
  public
    constructor Create(Clock: Integer = 3579545; SampleRate: Integer = 44100);
  end;

implementation

uses
  System.Math, System.Classes;

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
          for var i := 0 to 1 do
          begin
            FTimerMasked[i] := (Value and ($40 shr i)) <> 0;
            if FTimerMasked[i] then
              FStatus := FStatus and not ($40 shr i);
            var Running := (Value and (1 shl i)) <> 0;
            if Running <> FTimerRunning[i] then
              FTimerCycles[i] := 0;
            FTimerRunning[i] := Running;
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
  for var i := 0 to 1 do
    if FTimerRunning[i] then
    begin
      FTimerCycles[i] := FTimerCycles[i] + Cycles;
      var Period := UInt64(256 - Integer(FTimerValue[i])) * Cardinal(FDivider) * Cardinal(4 shl (i * 2));
      if FTimerCycles[i] >= Period then
      begin
        if Assigned(FOnTimerOverflow) then
          FOnTimerOverflow(i);
        FTimerCycles[i] := FTimerCycles[i] mod Period;
        if not FTimerMasked[i] then
          FStatus := FStatus or ($40 shr i);
      end;
    end;
end;

procedure TOPLSound.GenerateNative(out Left, Right: SmallInt; Timers: Boolean);
var
  PCM: array[0..1] of SmallInt;
begin
  OPL3_Generate(@FChip, PCM);
  Left := PCM[0];
  if FOPL3 then
    Right := PCM[1]
  else
    Right := Left;
  if Timers then
    AdvanceClocks(FDivider);
end;

procedure TOPLSound.Sample(out Left, Right: SmallInt; Timers: Boolean);
begin
  FPhase := FPhase + FClock / (Double(FDivider) * FSampleRate);
  while FPhase >= 1 do
  begin
    FPhase := FPhase - 1;
    var L, R: SmallInt;
    GenerateNative(L, R, Timers);
    FFiltered[0] := FFilter[0].Process(L);
    FFiltered[1] := FFilter[1].Process(R);
  end;
  Left := EnsureRange(Round(FFiltered[0]), -32768, 32767);
  Right := EnsureRange(Round(FFiltered[1]), -32768, 32767);
end;

procedure TOPLSound.SetCSMKey(Enabled: Boolean);
begin
  // Separate key source: releasing CSM must preserve normal and rhythm keys.
  for var I := 0 to 17 do
    if Enabled then
      FChip.slot[I].key := FChip.slot[I].key or 4
    else
      FChip.slot[I].key := FChip.slot[I].key and $FB;
end;

procedure TOPLSound.ClockNative;
begin
  var L, R: SmallInt;
  GenerateNative(L, R, False);
  FFiltered[0] := FFilter[0].Process(L);
  FFiltered[1] := FFilter[1].Process(R);
end;

procedure TOPLSound.CurrentSample(out Left, Right: SmallInt);
begin
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

function TOPLSound.RegisterValue(Index: Word): Byte;
begin
  Result := FRegisters[Index and $1FF];
end;

procedure TOPLSound.SerializeState(State: TStateArchive);
var
  Chip: TOplChip;

  procedure PointerField(var P; Loading: Boolean);
  var
    N: NativeUInt;
  begin
    Move(P, N, SizeOf(N));
    if not Loading then
    begin
      if N <> 0 then
      begin
        if (N < NativeUInt(@FChip)) or (N >= NativeUInt(@FChip) + SizeOf(FChip)) then
          raise EReadError.Create('Invalid OPL internal pointer');
        N := N - NativeUInt(@FChip) + 1;
      end;
    end
    else if N <> 0 then
    begin
      if N > SizeOf(FChip) then
        raise EReadError.Create('Invalid OPL state pointer');
      N := NativeUInt(@FChip) + N - 1;
    end;
    Move(N, P, SizeOf(N));
  end;

  procedure Pointers(Loading: Boolean);
  begin
    for var I := 0 to 17 do
    begin
      for var J := 0 to 1 do
        PointerField(Chip.channel[I].slotz[J], Loading);
      PointerField(Chip.channel[I].pair, Loading);
      PointerField(Chip.channel[I].Chip, Loading);
      for var J := 0 to 3 do
        PointerField(Chip.channel[I].&out[J], Loading);
    end;
    for var I := 0 to 35 do
    begin
      PointerField(Chip.slot[I].channel, Loading);
      PointerField(Chip.slot[I].Chip, Loading);
      PointerField(Chip.slot[I].&mod, Loading);
      PointerField(Chip.slot[I].trem, Loading);
    end;
  end;

begin
  Chip := FChip;
  if not State.Loading then
    Pointers(False);
  State.Field(Chip, SizeOf(Chip));
  if State.Loading then
  begin
    Pointers(True);
    FChip := Chip;
    if (FChip.writebuf_cur > 1023) or (FChip.writebuf_last > 1023) then
      raise EReadError.Create('Invalid OPL write buffer');
  end;
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FTimerValue, SizeOf(FTimerValue));
  State.Field(FTimerRunning, SizeOf(FTimerRunning));
  State.Field(FTimerMasked, SizeOf(FTimerMasked));
  State.Field(FTimerCycles, SizeOf(FTimerCycles));
  State.Field(FStatus, 1);
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FFiltered, SizeOf(FFiltered));
  State.Field(FFilter, SizeOf(FFilter));
end;

end.

