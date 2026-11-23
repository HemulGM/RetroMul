unit GBA.Sound;

{$IF Defined(ANDROID) and Defined(CPUARM64) and not Defined(RETROMUL_GBA_NO_NATIVE_QUIET)}
{$DEFINE RETROMUL_GBA_NATIVE_QUIET}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, Core.AudioFilter;

const
  GBA_SAMPLE_RATE = 44100;

type
  // A fractional-phase sinc filter integrates DAC level changes. Its
  // 16-sample latency is fixed; frame publications never reset the tail.
  TGBABandlimitedLevel = record
  private
    FPending: array[0..31] of Double;
    FLevel: Double;
    FPosition: Integer;
  public
    procedure Reset;
    procedure AddDelta(Delta, PhaseClock: Integer);
    function NextSample: Double;
    procedure SerializeState(State: TStateArchive);
  end;

  TGBASoundChannel = record
    Enabled, LengthEnabled, EnvelopeUp, SweepEnabled, SweepNegated, EnvelopeActive: Boolean;
    Frequency, Length, Volume, EnvelopePeriod, EnvelopeClock, Timer, Position: Integer;
    SweepShadow, SweepClock: Integer;
  end;

  PGBASoundChannel = ^TGBASoundChannel;

  TGBASound = class
  private
    FRegs: array[0..47] of Byte;
    FWave: array[0..31] of Byte;
    FChannels: array[0..3] of TGBASoundChannel;
    FFIFO: array[0..1, 0..6] of Cardinal;
    FHead, FWritePos, FCount, FReadRemaining, FCurrent: array[0..1] of Integer;
    FWriteBuffer, FReadBuffer: array[0..1] of Cardinal;
    FDACClock, FDACLeft, FDACRight: Integer;
    FPendingCycles, FEventCycles: Integer; // Derived; never part of a snapshot.
    FNoise: Word;
    FSequenceClock, FSequenceStep, FSampleClock, FFrames: Integer;
    FSamples: TArray<SmallInt>;
    FDC: array[0..1] of TPCMDCBlocker;
    FResampler: array[0..1] of TGBABandlimitedLevel;
    procedure FlushPending;
    procedure Advance(Cycles: Integer);
    procedure TickEvent(Cycles: Integer);
    function Reg16(Offset: Integer): Word; inline;
    procedure Trigger(Channel: Integer);
    procedure Sequence;
    function Period(Channel: Integer): Integer;
    procedure MixDAC;
    procedure Sample;
    procedure ClearFIFO(Index: Integer);
    function SweepValue: Integer;
  public
    {$IFDEF RETROMUL_GBA_NATIVE_QUIET}
    procedure NativeQuietOffsets(out Pending, Event: Integer);
    {$ENDIF}
    constructor Create;
    procedure Reset;
    procedure BeginFrame;
    procedure Write(Offset: Integer; Value: Byte);
    procedure WriteFIFO(Offset: Integer; Value: Cardinal; Size: Integer);
    function Read(Offset: Integer): Byte;
    procedure Tick(Cycles: Integer); inline;
    function ClockFIFO(Timer: Integer): Integer;
    procedure SerializeState(State: TStateArchive);
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FFrames;
  end;

implementation
{$IFDEF RETROMUL_GBA_NATIVE_QUIET}
procedure TGBASound.NativeQuietOffsets(out Pending, Event: Integer);
begin
  Pending := Integer(NativeUInt(@FPendingCycles)-NativeUInt(Self));
  Event := Integer(NativeUInt(@FEventCycles)-NativeUInt(Self));
end;
{$ENDIF}

var
  GBAImpulse: array[0..63, 0..31] of Double;

procedure BuildGBAImpulse;
begin
  for var Phase := 0 to 63 do
  begin
    var Sum: Double := 0;
    for var Tap := 0 to 31 do
    begin
      var X: Double := Tap - 15 - Phase / 64.0;
      var H: Double := 0;
      if Abs(X) < 16 then
      begin
        H := 0.90;
        if Abs(X) > 1E-12 then
          H := Sin(Pi * 0.90 * X) / (Pi * X);
        H := H * (0.42 + 0.50 * Cos(Pi * X / 16) + 0.08 * Cos(Pi * X / 8));
      end;
      GBAImpulse[Phase, Tap] := H;
      Sum := Sum + H;
    end;

    // Preserve DC exactly for every fractional event position.
    for var Tap := 0 to 31 do
      GBAImpulse[Phase, Tap] := GBAImpulse[Phase, Tap] / Sum;
  end;
end;

procedure TGBABandlimitedLevel.Reset;
begin
  FillChar(Self, SizeOf(Self), 0);
end;

procedure TGBABandlimitedLevel.AddDelta(Delta, PhaseClock: Integer);
begin
  if Delta = 0 then
    Exit;

  var Phase := EnsureRange(Integer(Int64(PhaseClock) * 64 div 16777216), 0, 63);
  for var Tap := 0 to 31 do
  begin
    var Slot := (FPosition + Tap) and 31;
    FPending[Slot] := FPending[Slot] + Delta * GBAImpulse[Phase, Tap];
  end;
end;

function TGBABandlimitedLevel.NextSample: Double;
begin
  FLevel := FLevel + FPending[FPosition];
  FPending[FPosition] := 0;
  FPosition := (FPosition + 1) and 31;
  Result := FLevel;
end;

procedure TGBABandlimitedLevel.SerializeState(State: TStateArchive);
begin
  State.Field(FPending, SizeOf(FPending));
  State.Field(FLevel, SizeOf(FLevel));
  State.Field(FPosition, SizeOf(FPosition));
  if State.Loading then
  begin
    if (FPosition < 0) or (FPosition > 31) or IsNan(FLevel) or IsInfinite(FLevel) or (Abs(FLevel) > 1E8) then
      raise EReadError.Create('Invalid GBA audio filter state');

    for var Tap := 0 to 31 do
      if IsNan(FPending[Tap]) or IsInfinite(FPending[Tap]) or (Abs(FPending[Tap]) > 1E8) then
        raise EReadError.Create('Invalid GBA audio filter tail');
  end;
end;

constructor TGBASound.Create;
begin
  inherited;
  SetLength(FSamples, 2048);
  Reset;
end;

procedure TGBASound.Reset;
begin
  FPendingCycles := 0;
  FEventCycles := 0;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FWave, SizeOf(FWave), 0);
  FillChar(FChannels, SizeOf(FChannels), 0);
  FillChar(FFIFO, SizeOf(FFIFO), 0);
  FillChar(FHead, SizeOf(FHead), 0);
  FillChar(FCount, SizeOf(FCount), 0);
  FillChar(FCurrent, SizeOf(FCurrent), 0);
  FillChar(FWritePos, SizeOf(FWritePos), 0);
  FillChar(FReadRemaining, SizeOf(FReadRemaining), 0);
  FillChar(FWriteBuffer, SizeOf(FWriteBuffer), 0);
  FillChar(FReadBuffer, SizeOf(FReadBuffer), 0);
  FDACClock := 0;
  FDACLeft := 0;
  FDACRight := 0;
  FNoise := $7FFF;
  FSequenceClock := 0;
  FSequenceStep := 0;
  FSampleClock := 0;
  FFrames := 0;
  for var i := 0 to 1 do
  begin
    FDC[i].Configure(GBA_SAMPLE_RATE, 20);
    FDC[i].Reset;
    FResampler[i].Reset;
  end;
end;

procedure TGBASound.BeginFrame;
begin
  FlushPending;
  FFrames := 0;
end;

function TGBASound.Reg16(Offset: Integer): Word;
begin
  Result := FRegs[Offset - $60] or (Word(FRegs[Offset - $5F]) shl 8);
end;

function TGBASound.Read(Offset: Integer): Byte;
begin
  FlushPending;
  Result := 0;
  if (Offset >= $90) and (Offset < $A0) then
    Exit(FWave[(((FRegs[$10] shr 6) and 1) xor 1) * 16 + Offset - $90]);

  if (Offset < $60) or (Offset > $8F) then
    Exit;

  if Offset = $84 then
  begin
    Result := FRegs[$24] and $80;
    for var i := 0 to 3 do
      if FChannels[i].Enabled then
        Result := Result or (1 shl i);
  end
  else
    case Offset of
      $60:
        Result := FRegs[0] and $7F;
      $62, $68:
        Result := FRegs[Offset - $60] and $C0;
      $63, $69, $79, $81:
        Result := FRegs[Offset - $60];
      $65, $6D, $75, $7D:
        Result := FRegs[Offset - $60] and $40;
      $70, $73:
        Result := FRegs[Offset - $60] and $E0;
      $7C:
        Result := FRegs[$1C];
      $80:
        Result := FRegs[$20] and $77;
      $82:
        Result := FRegs[$22] and $0F;
      $83:
        Result := FRegs[$23] and $77;
      $88:
        Result := FRegs[$28] and $FE;
      $89:
        Result := FRegs[$29] and $C3;
    end;
end;

procedure TGBASound.Write(Offset: Integer; Value: Byte);
begin
  FlushPending;
  FEventCycles := 0; // A register write may change oscillator/DAC deadlines.
  if (Offset >= $A0) and (Offset < $A8) then
  begin
    WriteFIFO(Offset, Value, 1);
    Exit;
  end;

  if (Offset >= $90) and (Offset < $A0) then
  begin
    FWave[(((FRegs[$10] shr 6) and 1) xor 1) * 16 + Offset - $90] := Value;
    Exit;
  end;

  if (Offset < $60) or (Offset > $8F) then
    Exit;

  case Offset of
    $60:
      Value := Value and $7F;
    $70, $73:
      Value := Value and $E0;
    $80:
      Value := Value and $77;
    $82:
      Value := Value and $0F;
    $84:
      Value := Value and $80;
    $88:
      Value := Value and $FE;
    $89:
      Value := Value and $C3;
    $61, $66, $67, $6A, $6B, $6E, $6F, $71, $76, $77, $7A, $7B, $7E, $7F, $85..$87, $8A..$8F:
      Exit;
  end;

  if (Offset < $82) and (FRegs[$24] and $80 = 0) then
    Exit;

  var Previous := FRegs[Offset - $60];
  FRegs[Offset - $60] := Value;
  if Offset = $84 then
  begin
    if Value and $80 = 0 then
    begin
      FillChar(FChannels, SizeOf(FChannels), 0);
      // Master disable resets only PSG registers ($60..$81).
      // Direct Sound routing at SOUNDCNT_H survives power cycling.
      FillChar(FRegs, $22, 0);
      ClearFIFO(0);
      ClearFIFO(1);
      FCurrent[0] := 0;
      FCurrent[1] := 0;
    end
    else if Previous and $80 = 0 then
      FSequenceStep := 0;
    Exit;
  end;

  if Offset = $83 then
  begin
    if Value and 8 <> 0 then
    begin
      ClearFIFO(0);
    end;
    if Value and $80 <> 0 then
    begin
      ClearFIFO(1);
    end;
    FRegs[$23] := Value and $77;
  end;

  var i := -1;
  case Offset of
    $65:
      i := 0;
    $6D:
      i := 1;
    $75:
      i := 2;
    $7D:
      i := 3;
  end;

  if i >= 0 then
  begin
    if (Value and $40 <> 0) and not FChannels[i].LengthEnabled and (FSequenceStep and 1 <> 0) and (FChannels[i].Length > 0) then
    begin
      Dec(FChannels[i].Length);
      if FChannels[i].Length = 0 then
        FChannels[i].Enabled := False;
    end;
    FChannels[i].LengthEnabled := Value and $40 <> 0;
    if Value and $80 <> 0 then
      Trigger(i);
  end;

  case Offset of
    $60:
      if FChannels[0].SweepNegated and (Previous and 8 <> 0) and (Value and 8 = 0) then
        FChannels[0].Enabled := False;
    $62:
      FChannels[0].Length := 64 - (Value and 63);
    $68:
      FChannels[1].Length := 64 - (Value and 63);
    $72:
      FChannels[2].Length := 256 - Value;
    $78:
      FChannels[3].Length := 64 - (Value and 63);
    $63, $69, $79:
      begin
        if Value and $F8 = 0 then
          case Offset of
            $63:
              FChannels[0].Enabled := False;
            $69:
              FChannels[1].Enabled := False;
            $79:
              FChannels[3].Enabled := False;
          end;
      end;
    $70:
      if Value and $80 = 0 then
        FChannels[2].Enabled := False;
    $64, $65:
      FChannels[0].Frequency := Reg16($64) and $7FF;
    $6C, $6D:
      FChannels[1].Frequency := Reg16($6C) and $7FF;
    $74, $75:
      FChannels[2].Frequency := Reg16($74) and $7FF;
  end;
end;

procedure TGBASound.Trigger(Channel: Integer);
const
  Envelopes: array[0..3] of Integer = ($63, $69, $73, $79);
begin
  var C: PGBASoundChannel := @FChannels[Channel];
  C.Enabled := FRegs[$24] and $80 <> 0;
  var E := FRegs[Envelopes[Channel] - $60];
  if Channel = 2 then
    C.Enabled := C.Enabled and (FRegs[$10] and $80 <> 0)
  else
    C.Enabled := C.Enabled and (E and $F8 <> 0);
  C.Volume := E shr 4;
  C.EnvelopeUp := E and 8 <> 0;
  C.EnvelopePeriod := E and 7;
  C.EnvelopeClock := C.EnvelopePeriod;
  if C.EnvelopeClock = 0 then
    C.EnvelopeClock := 8;
  C.EnvelopeActive := True;
  if C.Length = 0 then
  begin
    if Channel = 2 then
      C.Length := 256
    else
      C.Length := 64;
    if C.LengthEnabled and (FSequenceStep and 1 <> 0) then
      Dec(C.Length);
  end;
  C.Timer := Period(Channel) + 8;
  if Channel = 2 then
    C.Position := 0;
  if Channel = 0 then
  begin
    C.SweepShadow := C.Frequency;
    C.SweepClock := (FRegs[0] shr 4) and 7;
    if C.SweepClock = 0 then
      C.SweepClock := 8;
    C.SweepEnabled := (FRegs[0] and $77 <> 0);
    C.SweepNegated := False;
    if (FRegs[0] and 7 <> 0) and (SweepValue > 2047) then
      C.Enabled := False;
  end;
  if Channel = 3 then
    FNoise := $7FFF;
end;

function TGBASound.Period(Channel: Integer): Integer;
const
  Divisors: array[0..7] of Integer = (8, 16, 32, 48, 64, 80, 96, 112);
begin
  if Channel < 2 then
    Result := (2048 - FChannels[Channel].Frequency) * 16
  else if Channel = 2 then
    Result := (2048 - FChannels[2].Frequency) * 8
  else
    Result := (Divisors[FRegs[$1C] and 7] shl (FRegs[$1C] shr 4)) * 4;
  Result := Max(4, Result);
end;

procedure TGBASound.Sequence;
begin
  if FSequenceStep and 1 = 0 then
    for var i := 0 to 3 do
      if FChannels[i].LengthEnabled and (FChannels[i].Length > 0) then
      begin
        Dec(FChannels[i].Length);
        if FChannels[i].Length = 0 then
          FChannels[i].Enabled := False;
      end;

  if FSequenceStep in [2, 6] then
  begin
    var C: PGBASoundChannel := @FChannels[0];
    Dec(C.SweepClock);
    if C.SweepClock <= 0 then
    begin
      C.SweepClock := (FRegs[0] shr 4) and 7;
      if C.SweepClock = 0 then
        C.SweepClock := 8;
      if C.SweepEnabled and (FRegs[0] and $70 <> 0) then
      begin
        var V := SweepValue;
        if V > 2047 then
          C.Enabled := False
        else if FRegs[0] and 7 <> 0 then
        begin
          C.Frequency := V;
          C.SweepShadow := V;
          if SweepValue > 2047 then
            C.Enabled := False;
        end;
      end;
    end;
  end;

  if FSequenceStep = 7 then
    for var i := 0 to 3 do
      if (i <> 2) and FChannels[i].EnvelopeActive then
      begin
        var C: PGBASoundChannel := @FChannels[i];
        Dec(C.EnvelopeClock);
        if C.EnvelopeClock <= 0 then
        begin
          C.EnvelopeClock := C.EnvelopePeriod;
          if C.EnvelopeClock = 0 then
            C.EnvelopeClock := 8;
          if C.EnvelopePeriod <> 0 then
          begin
            var V := C.Volume;
            if C.EnvelopeUp then
              Inc(V)
            else
              Dec(V);
            if (V < 0) or (V > 15) then
              C.EnvelopeActive := False
            else
              C.Volume := V;
          end;
        end;
      end;
  FSequenceStep := (FSequenceStep + 1) and 7;
end;

function TGBASound.SweepValue: Integer;
begin
  var Delta := FChannels[0].SweepShadow shr (FRegs[0] and 7);
  if FRegs[0] and 8 <> 0 then
  begin
    Delta := -Delta;
    FChannels[0].SweepNegated := True;
  end;
  Result := FChannels[0].SweepShadow + Delta;
end;

procedure TGBASound.ClearFIFO(Index: Integer);
begin
  FHead[Index] := 0;
  FWritePos[Index] := 0;
  FCount[Index] := 0;
  FReadRemaining[Index] := 0;
  FWriteBuffer[Index] := 0;
  FReadBuffer[Index] := 0;
end;

procedure TGBASound.WriteFIFO(Offset: Integer; Value: Cardinal; Size: Integer);
begin
  FlushPending;
  if FRegs[$24] and $80 = 0 then
    Exit;

  var Index := (Offset - $A0) div 4;
  var Position := Offset and 3;
  for var i := 0 to Size - 1 do
  begin
    var Shift := ((Position + i) and 3) * 8;
    FWriteBuffer[Index] := (FWriteBuffer[Index] and not (Cardinal($FF) shl Shift)) or (((Value shr (i * 8)) and $FF) shl Shift);
  end;
  if FCount[Index] = 7 then
  begin
    FCount[Index] := 0;
    FReadRemaining[Index] := 0;
  end
  else
  begin
    FFIFO[Index, FWritePos[Index]] := FWriteBuffer[Index];
    FWritePos[Index] := (FWritePos[Index] + 1) mod 7;
    Inc(FCount[Index]);
  end;
end;

function TGBASound.ClockFIFO(Timer: Integer): Integer;
begin
  FlushPending;
  Result := 0;
  if FRegs[$24] and $80 = 0 then
    Exit;

  for var i := 0 to 1 do
    if ((Reg16($82) shr (10 + i * 4)) and 1) = Timer then
    begin
      // DMA request observes the queued words before the next sample is popped.
      if FCount[i] <= 3 then
        Result := Result or (1 shl i);
      if (FCount[i] > 0) or (FReadRemaining[i] > 0) then
      begin
        if FReadRemaining[i] = 0 then
        begin
          FReadBuffer[i] := FFIFO[i, FHead[i]];
          FHead[i] := (FHead[i] + 1) mod 7;
          Dec(FCount[i]);
          FReadRemaining[i] := 4;
        end;
        FCurrent[i] := Integer(FReadBuffer[i] and $FF);
        if FCurrent[i] >= 128 then
          Dec(FCurrent[i], 256);
        FReadBuffer[i] := FReadBuffer[i] shr 8;
        Dec(FReadRemaining[i]);
      end;
    end;
end;

procedure TGBASound.MixDAC;
const
  Duty: array[0..3] of Byte = ($01, $81, $87, $7E);
begin
  var L := 0;
  var R := 0;
  if FRegs[$24] and $80 <> 0 then
  begin
    for var i := 0 to 3 do
      if FChannels[i].Enabled then
      begin
        var C: PGBASoundChannel := @FChannels[i];
        var V := 0;
        case i of
          0, 1:
            begin
              var D := FRegs[$02 + i * 6] shr 6;
              if Duty[D] and (1 shl (C.Position and 7)) <> 0 then
                V := C.Volume
              else
                V := 0;
            end;
          2:
            begin
              var Pos := C.Position and 31;
              var Bank := (FRegs[$10] shr 6) and 1;
              if FRegs[$10] and $20 <> 0 then
                Bank := (C.Position shr 5) and 1;
              V := FWave[Bank * 16 + Pos div 2];
              if Pos and 1 = 0 then
                V := V shr 4
              else
                V := V and 15;

              var Level := (FRegs[$13] shr 5) and 3;
              if FRegs[$13] and $80 <> 0 then
                V := V * 3 div 4
              else if Level = 0 then
                V := 0
              else
                V := V div (1 shl (Level - 1));
            end;
          3:
            if FNoise and 1 = 0 then
              V := C.Volume
            else
              V := 0;
        end;
        if FRegs[$21] and (1 shl (i + 4)) <> 0 then
          Inc(L, V);
        if FRegs[$21] and (1 shl i) <> 0 then
          Inc(R, V);
      end;
    var Ratio := FRegs[$22] and 3;
    L := (L * (((FRegs[$20] shr 4) and 7) + 1) * (1 shl Min(2, Ratio))) div 2;
    R := (R * ((FRegs[$20] and 7) + 1) * (1 shl Min(2, Ratio))) div 2;
    for var i := 0 to 1 do
    begin
      var V := FCurrent[i] * 4;
      if FRegs[$22] and (4 shl i) = 0 then
        V := V div 2;
      if Reg16($82) and (1 shl (9 + i * 4)) <> 0 then
        Inc(L, V);
      if Reg16($82) and (1 shl (8 + i * 4)) <> 0 then
        Inc(R, V);
    end;
  end;
  var Bias := Reg16($88) and $3FE;
  var Mask := not ((1 shl (FRegs[$29] shr 6)) - 1);
  FDACLeft := ((EnsureRange(Bias + L, 0, 1023) and Mask) - Bias) * 32;
  FDACRight := ((EnsureRange(Bias + R, 0, 1023) and Mask) - Bias) * 32;
end;

procedure TGBASound.Sample;
begin
  if (FFrames + 1) * 2 > Length(FSamples) then
    SetLength(FSamples, Length(FSamples) * 2);
  FSamples[FFrames * 2] := SmallInt(EnsureRange(Round(FDC[0].Process(FResampler[0].NextSample)), -32768, 32767));
  FSamples[FFrames * 2 + 1] := SmallInt(EnsureRange(Round(FDC[1].Process(FResampler[1].NextSample)), -32768, 32767));
  Inc(FFrames);
end;

procedure TGBASound.FlushPending;
begin
  // Accumulated slices contain no sequencer, oscillator, DAC or sample edge.
  // Materialize them before a register access or an event-bearing bus slice.
  // Process the latter separately to retain the original ordering when a
  // sequencer edge disables an oscillator inside that slice.
  if FPendingCycles = 0 then
    Exit;

  Inc(FSequenceClock, FPendingCycles);
  Inc(FDACClock, FPendingCycles);
  Inc(FSampleClock, FPendingCycles * GBA_SAMPLE_RATE);
  for var i := 0 to 3 do
    if FChannels[i].Enabled then
      Dec(FChannels[i].Timer, FPendingCycles);
  FPendingCycles := 0;
end;

procedure TGBASound.Tick(Cycles: Integer);
begin
  if Cycles <= 0 then
    Exit;

  if Cycles < FEventCycles then
  begin
    Inc(FPendingCycles, Cycles);
    Dec(FEventCycles, Cycles);
  end
  else
    TickEvent(Cycles);
end;

procedure TGBASound.TickEvent(Cycles: Integer);
begin
  FlushPending;
  Advance(Cycles);
  var DACPeriod := 512 shr (FRegs[$29] shr 6);
  FEventCycles := Min(DACPeriod - (FDACClock and (DACPeriod - 1)), (16777216 - FSampleClock + GBA_SAMPLE_RATE - 1) div GBA_SAMPLE_RATE);
  FEventCycles := Min(FEventCycles, 32768 - FSequenceClock);
  for var i := 0 to 3 do
    if FChannels[i].Enabled then
      FEventCycles := Min(FEventCycles, Max(1, FChannels[i].Timer));
end;

procedure TGBASound.Advance(Cycles: Integer);
begin
  if Cycles <= 0 then
    Exit;

  var Remaining := Cycles;
  while Remaining > 0 do
  begin
    var DACPeriod := 512 shr (FRegs[$29] shr 6);
    var N := Min(Remaining, DACPeriod - (FDACClock and (DACPeriod - 1)));
    N := Min(N, (16777216 - FSampleClock + GBA_SAMPLE_RATE - 1) div GBA_SAMPLE_RATE);
    Dec(Remaining, N);
    Cycles := N;
    Inc(FSequenceClock, Cycles);
    while FSequenceClock >= 32768 do
    begin
      Dec(FSequenceClock, 32768);
      if FRegs[$24] and $80 <> 0 then
        Sequence;
    end;

    for var i := 0 to 3 do
      if FChannels[i].Enabled then
      begin
        var C: PGBASoundChannel := @FChannels[i];
        Dec(C.Timer, Cycles);
        while C.Timer <= 0 do
        begin
          Inc(C.Timer, Period(i));
          C.Position := (C.Position + 1) and 63;
          if i = 3 then
          begin
            var B := (FNoise xor (FNoise shr 1)) and 1;
            FNoise := (FNoise shr 1) or (B shl 14);
            if FRegs[$1C] and 8 <> 0 then
              FNoise := (FNoise and not $40) or (B shl 6);
          end;
        end;
      end;

    var OldLeft := FDACLeft;
    var OldRight := FDACRight;
    Inc(FDACClock, Cycles);
    if FDACClock and (DACPeriod - 1) = 0 then
      MixDAC;
    if FDACClock >= 512 then
      Dec(FDACClock, 512);
    Inc(FSampleClock, Cycles * GBA_SAMPLE_RATE);
    while FSampleClock >= 16777216 do
    begin
      Dec(FSampleClock, 16777216);
      Sample;
    end;

    // Output crossings precede a DAC edge at the end of this bus slice.
    // Keep the residual fractional phase instead of clamping it to one.
    if FDACLeft <> OldLeft then
      FResampler[0].AddDelta(FDACLeft - OldLeft, FSampleClock);
    if FDACRight <> OldRight then
      FResampler[1].AddDelta(FDACRight - OldRight, FSampleClock);
  end;
end;

procedure TGBASound.SerializeState(State: TStateArchive);
begin
  if not State.Loading then
    FlushPending;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FWave, SizeOf(FWave));
  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FFIFO, SizeOf(FFIFO));
  State.Field(FHead, SizeOf(FHead));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FWritePos, SizeOf(FWritePos));
  State.Field(FReadRemaining, SizeOf(FReadRemaining));
  State.Field(FWriteBuffer, SizeOf(FWriteBuffer));
  State.Field(FReadBuffer, SizeOf(FReadBuffer));
  State.Field(FDACClock, SizeOf(FDACClock));
  State.Field(FDACLeft, SizeOf(FDACLeft));
  State.Field(FDACRight, SizeOf(FDACRight));
  State.Field(FCurrent, SizeOf(FCurrent));
  State.Field(FNoise, SizeOf(FNoise));
  State.Field(FSequenceClock, SizeOf(FSequenceClock));
  State.Field(FSequenceStep, SizeOf(FSequenceStep));
  State.Field(FSampleClock, SizeOf(FSampleClock));
  State.Field(FDC, SizeOf(FDC));
  for var i := 0 to 1 do
    FResampler[i].SerializeState(State);

  if State.Loading then
  begin
    if (FSequenceClock < 0) or (FSequenceClock >= 32768) or (FSequenceStep < 0) or (FSequenceStep > 7) or
      (FDACClock < 0) or (FDACClock >= 512) or (FSampleClock < 0) or (FSampleClock >= 16777216) then
      raise EReadError.Create('Invalid GBA sound state');

    for var i := 0 to 1 do
      if (FHead[i] < 0) or (FHead[i] > 6) or (FCount[i] < 0) or (FCount[i] > 7) or
        (FWritePos[i] < 0) or (FWritePos[i] > 6) or (FReadRemaining[i] < 0) or (FReadRemaining[i] > 4) or
        (FCurrent[i] < -128) or (FCurrent[i] > 127) then
        raise EReadError.Create('Invalid GBA FIFO');

    FFrames := 0;
    FPendingCycles := 0;
    FEventCycles := 0;
  end;
end;

initialization
  BuildGBAImpulse;

end.

