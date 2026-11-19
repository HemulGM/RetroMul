unit S32.Sound;

interface

uses
  System.SysUtils, HW.Z80, MD.Sound, Core.Snapshots;

type
  TS32Sound = class
  private
    type
      TChannel = record
        Address: Cardinal;
        Step, Loop: Word;
        Start, Envelope, Pan: Byte;
        Enabled: Boolean;
      end;
  private
    FROM: TBytes;
    FCPU: TZ80State;
    FBus: TZ80ReadAndWriteCallbacks;
    FFM: array[0..1] of TFM;
    FFMPhase, FPCMPhase, FOutputPhase: Int64;
    FLastFM: array[0..1, 0..1] of SmallInt;
    FLastPCM: array[0..1] of Integer;
    FWave: array[0..65535] of Byte;
    FChannels: array[0..7] of TChannel;
    FChannel, FWaveBank, FBank: Integer;
    FPCMEnabled: Boolean;
    FControl: array[0..3] of Byte;
    FPending, FDummy: Byte;
    FResetLine: Boolean;
    FTime: Int64;
    FCPUCyclesRemaining: Integer;
    FYMIRQ: Boolean;
    FSampleCount: Integer;
    FSamples: TArray<SmallInt>;
    procedure Advance(Cycles: Integer);
    procedure PCMTick;
    procedure PCMWrite(RegisterIndex: Integer; Value: Byte);
    procedure UpdateIRQ;
    procedure UpdateFMIRQ;
    procedure SetResetLine(Value: Boolean);
  public
    Shared: array[0..8191] of Byte;
    MainIRQ: Boolean;
    Samples: TArray<SmallInt>;
    constructor Create(const ROM: TBytes);
    procedure Reset;
    procedure BeginFrame;
    procedure EndFrame;
    procedure RunUntil(Target: Int64);
    procedure SignalIRQ(Which: Integer; Asserted: Boolean = True);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Byte): Byte;
    procedure WritePort(Address, Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property CPU: TZ80State read FCPU;
    property ResetLine: Boolean read FResetLine write SetResetLine;
  end;

implementation

uses
  System.Classes, System.Math;

const
  Z80_CLOCK = 8053975;

function ReadZ(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TS32Sound(User).ReadMemory(Word(Address));
end;

procedure WriteZ(User: Pointer; Address, Value: Cardinal);
begin
  TS32Sound(User).WriteMemory(Word(Address), Byte(Value));
end;

function ReadP(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TS32Sound(User).ReadPort(Byte(Address));
end;

procedure WriteP(User: Pointer; Address, Value: Cardinal);
begin
  TS32Sound(User).WritePort(Byte(Address), Byte(Value));
end;

constructor TS32Sound.Create(const ROM: TBytes);
begin
  inherited Create;
  FROM := ROM;
  FBus := Default(TZ80ReadAndWriteCallbacks);
  FBus.UserData := Self;
  FBus.ReadCallback := ReadZ;
  FBus.WriteCallback := WriteZ;
  FBus.PortReadCallback := ReadP;
  FBus.PortWriteCallback := WriteP;
  Reset;
end;

procedure TS32Sound.Reset;
begin
  Z80StateInitialise(FCPU);
  for var I := 0 to 1 do
  begin
    FFM[I] := Default(TFM);
    FMInitialise(FFM[I]);
    FFM[I].Configuration.LadderEffectDisabled := 1;
  end;
  FillChar(FChannels, SizeOf(FChannels), 0);
  // Shared is battery-backed SRAM. Class allocation supplies the initial
  // contents; CPU/board reset must retain it, like the external battery.
  FillChar(FWave, SizeOf(FWave), 0);
  FillChar(FControl, SizeOf(FControl), $FF);
  FillChar(FLastFM, SizeOf(FLastFM), 0);
  FillChar(FLastPCM, SizeOf(FLastPCM), 0);
  FTime := 0;
  FCPUCyclesRemaining := 0;
  FYMIRQ := False;
  FFMPhase := 0;
  FPCMPhase := 0;
  FOutputPhase := 0;
  FChannel := 0;
  FWaveBank := 0;
  FBank := 0;
  FPending := 0;
  FDummy := 0;
  FPCMEnabled := False;
  MainIRQ := False;
  FResetLine := True;
  FSampleCount := 0;
  Samples := nil;
end;

procedure TS32Sound.SetResetLine(Value: Boolean);
begin
  if Value and not FResetLine then
  begin
    Z80Reset(FCPU);
    FCPUCyclesRemaining := 0;
  end;
  FResetLine := Value;
end;

procedure TS32Sound.SignalIRQ(Which: Integer; Asserted: Boolean);
begin
  for var I := 0 to 2 do
    if FControl[I] = Which then
      if Asserted then
        FPending := FPending or (1 shl I)
      else
        FPending := FPending and not (1 shl I);
  UpdateIRQ;
end;

procedure TS32Sound.UpdateIRQ;
begin
  Z80Interrupt(FCPU, Ord((FPending and not FControl[3] and 7) <> 0));
end;

procedure TS32Sound.UpdateFMIRQ;
begin
  // Only YM1 is wired to the interrupt controller. Latch an assertion
  // edge, not a fresh request on every sample while its flag remains set.
  var Asserted := FFM[0].State.Status and 3 <> 0;
  if Asserted <> FYMIRQ then
  begin
    FYMIRQ := Asserted;
    SignalIRQ(0, Asserted);
  end;
end;

function TS32Sound.ReadMemory(Address: Word): Byte;
begin
  Result := $FF;
  if Address < $A000 then
  begin
    if Address < Length(FROM) then
      Result := FROM[Address];
  end
  else if Address < $C000 then
  begin
    var Index := FBank * $2000 + (Address and $1FFF);
    if Index < Length(FROM) then
      Result := FROM[Index];
  end
  else if Address >= $E000 then
    Result := Shared[Address and $1FFF]
  else if Address >= $D000 then
    Result := FWave[FWaveBank or (Address and $FFF)];
end;

procedure TS32Sound.WriteMemory(Address: Word; Value: Byte);
begin
  if Address >= $E000 then
    Shared[Address and $1FFF] := Value
  else if Address >= $D000 then
    FWave[FWaveBank or (Address and $FFF)] := Value
  else if (Address >= $C000) and ((Address and $F) <= 8) then
    PCMWrite(Address and $F, Value);
end;

function TS32Sound.ReadPort(Address: Byte): Byte;
begin
  Result := $FF;
  if Address and $E0 = $80 then
    Result := FFM[(Address shr 4) and 1].State.Status
  else if Address = $F1 then
    Result := FDummy;
end;

procedure TS32Sound.WritePort(Address, Value: Byte);
begin
  case Address and $F0 of
    $80, $90:
      begin
        var I := (Address shr 4) and 1;
        if Address and 1 = 0 then
          FMDoAddress(FFM[I], (Address shr 1) and 1, Value)
        else
        begin
          FMDoData(FFM[I], Value);
          if I = 0 then
            UpdateFMIRQ;
        end;
      end;
    $A0:
      FBank := (FBank and not $3F) or (Value and $3F);
    $B0:
      FBank := (FBank and $3F) or ((Value and 4) shl 4) or ((Value and 3) shl 7);
    $C0:
      begin
        if Address and 1 <> 0 then
          FPending := FPending and Value;
        if Address and 4 <> 0 then
          MainIRQ := True;
        UpdateIRQ;
      end;
    $D0:
      if Address and 8 = 0 then
      begin
        FControl[Address and 3] := Value;
        UpdateIRQ;
      end;
    $F0:
      if Address = $F1 then
        FDummy := Value;
  end;
end;

procedure TS32Sound.PCMWrite(RegisterIndex: Integer; Value: Byte);
begin
  // Same RF5C68 register semantics as the native Mega-CD, with arcade mirrors.
  case RegisterIndex of
    0:
      FChannels[FChannel].Envelope := Value;
    1:
      FChannels[FChannel].Pan := Value;
    2:
      FChannels[FChannel].Step := (FChannels[FChannel].Step and $FF00) or Value;
    3:
      FChannels[FChannel].Step := (FChannels[FChannel].Step and $FF) or (Word(Value) shl 8);
    4:
      FChannels[FChannel].Loop := (FChannels[FChannel].Loop and $FF00) or Value;
    5:
      FChannels[FChannel].Loop := (FChannels[FChannel].Loop and $FF) or (Word(Value) shl 8);
    6:
      begin
        FChannels[FChannel].Start := Value;
        if not FChannels[FChannel].Enabled then
          FChannels[FChannel].Address := Cardinal(Value) shl 19;
      end;
    7:
      begin
        FPCMEnabled := Value and $80 <> 0;
        if Value and $40 <> 0 then
          FChannel := Value and 7
        else
          FWaveBank := (Value and 15) shl 12;
      end;
    8:
      for var I := 0 to 7 do
      begin
        FChannels[I].Enabled := Value and (1 shl I) = 0;
        if not FChannels[I].Enabled then
          FChannels[I].Address := Cardinal(FChannels[I].Start) shl 19;
      end;
  end;
end;

procedure TS32Sound.PCMTick;
begin
  FLastPCM[0] := 0;
  FLastPCM[1] := 0;
  if not FPCMEnabled then
    Exit;
  for var I := 0 to 7 do
    if FChannels[I].Enabled then
    begin
      var C := FChannels[I];
      var V := FWave[(C.Address shr 11) and $FFFF];
      if V = $FF then
      begin
        C.Address := Cardinal(C.Loop) shl 11;
        V := FWave[C.Loop];
      end;
      if V <> $FF then
      begin
        var S := Integer(V and $7F);
        if V and $80 = 0 then
          S := -S;
        Inc(FLastPCM[0], S * C.Envelope * (C.Pan and 15) div 32);
        Inc(FLastPCM[1], S * C.Envelope * (C.Pan shr 4) div 32);
        C.Address := (C.Address + C.Step) and $7FFFFFF;
      end;
      FChannels[I] := C;
    end;
  for var I := 0 to 1 do
    FLastPCM[I] := EnsureRange(FLastPCM[I], -32768, 32767) and not 63;
end;

procedure TS32Sound.Advance(Cycles: Integer);
begin
  // FM, PCM and host samples share elapsed time but have different clocks.
  // Stop at the earliest edge: an output sample must never use a PCM/FM
  // value from later in this CPU slice. Tied edges update chips before DAC.
  while Cycles > 0 do
  begin
    var Step := Min(Int64(Cycles), 144 - FFMPhase);
    Step := Min(Step, (Int64(Z80_CLOCK) * 384 - FPCMPhase + 12499999) div 12500000);
    Step := Min(Step, (Int64(Z80_CLOCK) - FOutputPhase + 44099) div 44100);
    Dec(Cycles, Step);
    for var I := 0 to 1 do
      if FFM[I].State.BusyFlagCounter > Cardinal(Step) then
        Dec(FFM[I].State.BusyFlagCounter, Step)
      else
      begin
        FFM[I].State.BusyFlagCounter := 0;
        FFM[I].State.Status := FFM[I].State.Status and $7F;
      end;
    Inc(FFMPhase, Step);
    Inc(FPCMPhase, Step * 12500000);
    Inc(FOutputPhase, Step * 44100);
    if FFMPhase >= 144 then
    begin
      Dec(FFMPhase, 144);
      for var I := 0 to 1 do
      begin
        var Sample: array[0..1] of SmallInt;
        FillChar(Sample, SizeOf(Sample), 0);
        FMOutputSamples(FFM[I], Sample);
        FLastFM[I, 0] := Sample[0];
        FLastFM[I, 1] := Sample[1];
      end;
      UpdateFMIRQ;
    end;
    if FPCMPhase >= Int64(Z80_CLOCK) * 384 then
    begin
      Dec(FPCMPhase, Int64(Z80_CLOCK) * 384);
      PCMTick;
    end;
    if FOutputPhase >= Z80_CLOCK then
    begin
      Dec(FOutputPhase, Z80_CLOCK);
      if Length(FSamples) < FSampleCount + 2 then
        SetLength(FSamples, FSampleCount + 2048);
      for var C := 0 to 1 do
        FSamples[FSampleCount + C] := EnsureRange((Integer(FLastFM[0, C]) + FLastFM[1, C]) * 3 div 10 + FLastPCM[C] * 4 div 10, -32768, 32767);
      Inc(FSampleCount, 2);
    end;
  end;
end;

procedure TS32Sound.RunUntil(Target: Int64);
begin
  while FTime < Target do
  begin
    // The instruction engine commits at instruction start. Its remaining
    // clocks carry over between slices; peripheral/output clocks stop at
    // Target even if the instruction finishes beyond it. Bus-cycle CPU
    // micro-timing is still outside this instruction-level scheduler.
    if FCPUCyclesRemaining = 0 then
    begin
      var Vector: Byte := 0;
      for var I := 2 downto 0 do
        if FPending and not FControl[3] and (1 shl I) <> 0 then
          Vector := 2 * I;
      if ResetLine then
        FCPUCyclesRemaining := 4
      else
        FCPUCyclesRemaining := Z80DoInstruction(FCPU, FBus, nil, False, Vector);
    end;
    var Step := Integer(Min(Target - FTime, Int64(FCPUCyclesRemaining)));
    Advance(Step);
    Inc(FTime, Step);
    Dec(FCPUCyclesRemaining, Step);
  end;
end;

procedure TS32Sound.BeginFrame;
begin
  FSampleCount := 0;
end;

procedure TS32Sound.EndFrame;
begin
  Samples := Copy(FSamples, 0, FSampleCount);
end;

procedure TS32Sound.SerializeState(State: TStateArchive);
begin
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FFM, SizeOf(FFM));
  State.Field(FFMPhase, SizeOf(FFMPhase));
  State.Field(FPCMPhase, SizeOf(FPCMPhase));
  State.Field(FOutputPhase, SizeOf(FOutputPhase));
  State.Field(FLastFM, SizeOf(FLastFM));
  State.Field(FLastPCM, SizeOf(FLastPCM));
  State.Field(FWave, SizeOf(FWave));
  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FChannel, SizeOf(FChannel));
  State.Field(FWaveBank, SizeOf(FWaveBank));
  State.Field(FBank, SizeOf(FBank));
  State.Field(FPCMEnabled, SizeOf(FPCMEnabled));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FDummy, SizeOf(FDummy));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FCPUCyclesRemaining, SizeOf(FCPUCyclesRemaining));
  State.Field(FYMIRQ, SizeOf(FYMIRQ));
  State.Field(Shared, SizeOf(Shared));
  State.Field(FResetLine, SizeOf(FResetLine));
  State.Field(MainIRQ, SizeOf(MainIRQ));
  if (FChannel < 0) or (FChannel > 7) or (FWaveBank < 0) or (FWaveBank > $F000) or (FBank < 0) or (FBank > $7FF) or
    (FTime < 0) or (FCPUCyclesRemaining < 0) then
    raise EReadError.Create('Invalid System 32 sound state');
end;

end.

