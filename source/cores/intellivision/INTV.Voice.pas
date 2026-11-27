unit INTV.Voice;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TIntvVoice = class
  private
    const
      ResidentBase = $1000;
      FIFOBase = $1800;
      FIFOSize = 64;
      OutputRate = 10000; // 3.12 MHz crystal divided by 312
  private
    type
      TRegisters = array[0..15] of Byte;

      TVoiceState = packed record
        Registers: TRegisters;
        FIFO: array[0..FIFOSize - 1] of Word;
        Delay: array[0..5, 0..1] of SmallInt;
        PC, ReturnPC, Phase: Integer;
        Page, Mode, Prefix, Command: Byte;
        FIFOHead, FIFOCount, FIFOBit, Repeats, PeriodLeft: Byte;
        Noise: Word;
        PreviousSample, CurrentSample: SmallInt;
        FIFOActive, Pending, Halted: Boolean;
      end;

      TRegisterWrite = (Replace, HighBits, AddDelta);
  private
    FState: TVoiceState;
    FROM: TBytes;
    FClock: Integer;
    FUnderflow: Boolean;
    FCoefficients: array[0..5, 0..1] of Integer;
    function ROMByte(BitAddress: Integer): Integer;
    function ReadBits(Count: Integer): Integer;
    procedure Transfer(Address: Integer);
    procedure UpdateRegister(Index, Bits, Shift: Integer; Operation: TRegisterWrite = Replace);
    procedure LoadParameters(Opcode: Integer);
    function PrepareFrame: Boolean;
    procedure DecodeCoefficients;
    function Synthesize: SmallInt;
  public
    constructor Create(const ROM: TBytes; MasterClock: Integer);
    procedure Reset;
    function ReadRegister(Address: Word): Word;
    procedure WriteRegister(Address, Value: Word);
    procedure Advance(CPUCycles: Integer);
    function Sample: SmallInt;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes, System.Math;

const
  Amplitude = 0;
  Pitch = 1;
  FirstCoefficient = 2;
  AmplitudeStep = 14;
  PitchStep = 15;
  BitAddressMask = $7FFFF;

function ReverseBits(Value, Count: Integer): Integer;
begin
  Result := 0;
  for var Bit := 1 to Count do
  begin
    Result := (Result shl 1) or (Value and 1);
    Value := Value shr 1;
  end;
end;

function FilterCoefficient(Value: Byte): Integer;
begin
  // GI's SP0250 coefficient translation curve (also used by SP0256).
  var Index := Value and $7F;
  if Value >= $80 then
    Index := (-Index) and $7F;
  case Index of
    0:
      Result := 0;
    1:
      Result := 9;
    2:
      Result := 12;
    3..37:
      Result := 25 + (Index - 3) * 8;
    38..69:
      Result := 301 + (Index - 38) * 4;
    70..97:
      Result := 427 + (Index - 70) * 2;
  else
    Result := 482 + (Index - 98);
  end;
  if Value < $80 then
    Result := -Result;
end;

function ShiftSigned(Value, Bits: Integer): Integer; inline;
begin
  // The chip truncates towards minus infinity.
  Result := ((Value + $40000000) shr Bits) - ($40000000 shr Bits);
end;

constructor TIntvVoice.Create(const ROM: TBytes; MasterClock: Integer);
begin
  inherited Create;
  if Length(ROM) <> $800 then
    raise EReadError.Create('Intellivoice SP0256-012 ROM must contain 2048 bytes');
  FROM := Copy(ROM);
  FClock := MasterClock;
  Reset;
end;

procedure TIntvVoice.Reset;
begin
  FillChar(FState, SizeOf(FState), 0);
  FState.Page := 1;
  FState.Noise := 1;
  FState.Halted := True;
  DecodeCoefficients;
end;

function TIntvVoice.ReadRegister(Address: Word): Word;
begin
  if Address = $0080 then
    Result := Ord(not FState.Pending) shl 15
  else
    Result := Ord(FState.FIFOCount = FIFOSize) shl 15;
end;

procedure TIntvVoice.WriteRegister(Address, Value: Word);
begin
  if Address = $0080 then
  begin
    if not FState.Pending then
    begin
      FState.Command := Byte(Value);
      FState.Pending := True;
    end;
  end
  else if Value and $400 <> 0 then
  begin
    // The reset input on the FIFO also resets the speech sequencer.
    var Phase := FState.Phase;
    Reset;
    FState.Phase := Phase;
  end
  else if FState.FIFOCount < FIFOSize then
  begin
    FState.FIFO[(FState.FIFOHead + FState.FIFOCount) and (FIFOSize - 1)] := Value and $3FF;
    Inc(FState.FIFOCount);
  end;
end;

function TIntvVoice.ROMByte(BitAddress: Integer): Integer;
begin
  var Offset := ((BitAddress and BitAddressMask) shr 3) - ResidentBase;
  if (Offset >= 0) and (Offset < Length(FROM)) then
    Result := FROM[Offset]
  else
    Result := 0;
end;

function TIntvVoice.ReadBits(Count: Integer): Integer;
begin
  Result := 0;
  if FState.FIFOActive then
  begin
    if FState.FIFOCount * 10 - FState.FIFOBit < Count then
    begin
      FUnderflow := True;
      Exit;
    end;
    Result := FState.FIFO[FState.FIFOHead] shr FState.FIFOBit;
    Inc(FState.FIFOBit, Count);
    if FState.FIFOBit >= 10 then
    begin
      Dec(FState.FIFOBit, 10);
      FState.FIFOHead := (FState.FIFOHead + 1) and (FIFOSize - 1);
      Dec(FState.FIFOCount);
      if FState.FIFOBit > 0 then
        Result := Result or (FState.FIFO[FState.FIFOHead] shl (Count - FState.FIFOBit));
    end;
  end
  else
  begin
    Result := (ROMByte(FState.PC) or (ROMByte(FState.PC + 8) shl 8)) shr (FState.PC and 7);
    FState.PC := (FState.PC + Count) and BitAddressMask;
  end;
  Result := Result and ((1 shl Count) - 1);
end;

procedure TIntvVoice.Transfer(Address: Integer);
begin
  FState.PC := Address;
  FState.FIFOActive := Address = FIFOBase * 8;
  if FState.FIFOActive and (FState.FIFOBit <> 0) then
  begin
    FState.FIFOBit := 0;
    FState.FIFOHead := (FState.FIFOHead + 1) and (FIFOSize - 1);
    Dec(FState.FIFOCount);
  end;
end;

procedure TIntvVoice.UpdateRegister(Index, Bits, Shift: Integer; Operation: TRegisterWrite);
begin
  var Value := ReadBits(Bits);
  case Operation of
    Replace:
      FState.Registers[Index] := Value shl Shift;
    HighBits:
      FState.Registers[Index] := (FState.Registers[Index] and ((1 shl Shift) - 1)) or (Value shl Shift);
    AddDelta:
      begin
        if Value and (1 shl (Bits - 1)) <> 0 then
          Dec(Value, 1 shl Bits);
        FState.Registers[Index] := (FState.Registers[Index] + Value * (1 shl Shift)) and $FF;
      end;
  end;
end;

procedure TIntvVoice.LoadParameters(Opcode: Integer);
const
  LoadB: array[Boolean, 0..5] of Byte = ((3, 3, 3, 4, 7, 8), (6, 6, 6, 6, 8, 8));
  LoadF: array[Boolean, 0..5] of Byte = ((5, 5, 5, 6, 6, 8), (6, 6, 6, 7, 8, 8));
  DeltaB: array[Boolean, 0..5] of Byte = ((3, 3, 3, 3, 4, 5), (4, 4, 4, 4, 5, 5));
  DeltaF: array[Boolean, 0..5] of Byte = ((3, 3, 3, 4, 4, 5), (4, 4, 4, 5, 5, 5));
  DeltaBShift: array[Boolean, 0..5] of Byte = ((4, 4, 4, 3, 1, 0), (1, 1, 1, 1, 0, 0));
  DeltaFShift: array[Boolean, 0..5] of Byte = ((3, 3, 3, 2, 2, 0), (2, 2, 2, 1, 0, 0));
begin
  var Precision := FState.Mode and 2 <> 0;
  var Last := 4 + (FState.Mode and 1);
  if Last = 4 then
  begin
    FState.Registers[12] := 0;
    FState.Registers[13] := 0;
  end;
  if Opcode <> $F then
  begin
    var Bits := 6;
    if Opcode = 1 then
      Bits := 8;
    if Opcode in [$9, $D] then
    begin
      UpdateRegister(Amplitude, 4, 2, AddDelta);
      UpdateRegister(Pitch, 5, 0, AddDelta);
    end
    else
    begin
      UpdateRegister(Amplitude, Bits, 8 - Bits);
      if Opcode in [1, 2, 3, 4, 5, $C, $E] then
        UpdateRegister(Pitch, 8, 0);
    end;
  end;
  case Opcode of
    1:
      for var RegisterIndex := FirstCoefficient to FirstCoefficient + 2 * Last + 1 do
        UpdateRegister(RegisterIndex, 8, 0);
    2, 4, $C:
      begin
        var First := 0;
        if Opcode = 4 then
        begin
          First := 3;
          FillChar(FState.Registers[FirstCoefficient], 6, 0);
        end;
        for var Stage := First to Last do
        begin
          var BWidth := LoadB[Precision, Stage];
          var FWidth := LoadF[Precision, Stage];
          UpdateRegister(FirstCoefficient + 2 * Stage, BWidth, 8 - BWidth - Ord(Stage <= 3));
          UpdateRegister(FirstCoefficient + 2 * Stage + 1, FWidth, 8 - FWidth);
        end;
      end;
    3, 5, $A:
      begin
        var Bits := 5 + Ord(Precision);
        for var Stage := 0 to 2 do
          UpdateRegister(FirstCoefficient + 2 * Stage + 1, Bits, 8 - Bits, HighBits);
      end;
    6:
      for var Stage := 3 to Last do
      begin
        var Bits := LoadF[Precision, Stage];
        UpdateRegister(FirstCoefficient + 2 * Stage + 1, Bits, 8 - Bits, HighBits);
      end;
    9, $D:
      begin
        var First := 0;
        if Opcode = $D then
        begin
          First := 3;
          FillChar(FState.Registers[FirstCoefficient], 6, 0);
        end;
        for var Stage := First to Last do
        begin
          UpdateRegister(FirstCoefficient + 2 * Stage, DeltaB[Precision, Stage], DeltaBShift[Precision, Stage], AddDelta);
          UpdateRegister(FirstCoefficient + 2 * Stage + 1, DeltaF[Precision, Stage], DeltaFShift[Precision, Stage], AddDelta);
        end;
      end;
    $F:
      begin
        FillChar(FState.Registers, SizeOf(FState.Registers), 0);
        FState.Registers[Pitch] := 64;
      end;
  end;
  if Opcode in [2, 3] then
  begin
    UpdateRegister(AmplitudeStep, 5, 0);
    UpdateRegister(PitchStep, 5, 0);
  end
  else if Opcode = 1 then
  begin
    UpdateRegister(AmplitudeStep, 8, 0);
    UpdateRegister(PitchStep, 8, 0);
  end
  else
  begin
    FState.Registers[AmplitudeStep] := 0;
    FState.Registers[PitchStep] := 0;
  end;
end;

function TIntvVoice.PrepareFrame: Boolean;
begin
  Result := False;
  // A malformed data stream may loop without issuing a synthesis command.
  for var Instruction := 1 to 512 do
  begin
    if FState.Halted then
    begin
      if not FState.Pending then
        Exit;
      Transfer((ResidentBase + FState.Command * 2) * 8);
      FState.Halted := False;
      FState.Pending := False;
    end;

    var SavedPC := FState.PC;
    var SavedHead := FState.FIFOHead;
    var SavedBit := FState.FIFOBit;
    var SavedCount := FState.FIFOCount;
    var SavedRegisters := FState.Registers;
    FUnderflow := False;
    var Immediate := ReadBits(4);
    // The opcode is transmitted MSB-first. Numeric speech data is LSB-first.
    var Opcode := ReverseBits(ReadBits(4), 4);
    var Target := 0;
    var Repeats := 0;
    case Opcode of
      7, $B:
        Target := ((FState.Page shl 12) or (ReverseBits(Immediate, 4) shl 8) or
          ReverseBits(ReadBits(8), 8)) * 8;
      0, 8:
        ;
    else
      Repeats := FState.Prefix or Immediate;
      if Repeats <> 0 then
        LoadParameters(Opcode);
    end;

    if FUnderflow then
    begin
      FState.PC := SavedPC;
      FState.FIFOHead := SavedHead;
      FState.FIFOBit := SavedBit;
      FState.FIFOCount := SavedCount;
      FState.Registers := SavedRegisters;
      Exit;
    end;

    case Opcode of
      0:
        if Immediate <> 0 then
          FState.Page := ReverseBits(Immediate, 4)
        else
        begin
          Transfer(FState.ReturnPC);
          FState.ReturnPC := 0;
          FState.Halted := FState.PC = 0;
        end;
      7, $B:
        begin
          if Opcode = $B then
            FState.ReturnPC := ((FState.PC + 7) and not 7) and BitAddressMask;
          Transfer(Target);
        end;
      8:
        begin
          FState.Prefix := (Immediate and 3) shl 4;
          FState.Mode := (Immediate shr 3) or ((Immediate shr 1) and 2);
        end;
    else
      FState.Prefix := 0;
      if Repeats <> 0 then
      begin
        FState.Repeats := Repeats;
        DecodeCoefficients;
        FillChar(FState.Delay, SizeOf(FState.Delay), 0);
        Exit(True);
      end;
    end;
  end;
end;

procedure TIntvVoice.DecodeCoefficients;
begin
  for var Stage := 0 to 5 do
  begin
    FCoefficients[Stage, 0] := FilterCoefficient(FState.Registers[FirstCoefficient + Stage * 2]);
    FCoefficients[Stage, 1] := FilterCoefficient(FState.Registers[FirstCoefficient + Stage * 2 + 1]);
  end;
end;

function TIntvVoice.Synthesize: SmallInt;
begin
  if (FState.PeriodLeft = 0) and (FState.Repeats = 0) and not PrepareFrame then
    Exit(0);
  var NoiseBit := FState.Noise and 1;
  FState.Noise := (FState.Noise shr 1) xor ($4001 * NoiseBit);

  var Level := FState.Registers[Amplitude];
  var Excitation := (Level and $1F) shl (Level shr 5);
  var Period := FState.Registers[Pitch];
  var Output := 0;
  if Period = 0 then
    Output := Excitation * (1 - 2 * NoiseBit);
  if FState.PeriodLeft = 0 then
  begin
    Dec(FState.Repeats);
    if Period = 0 then
      FState.PeriodLeft := 64
    else
    begin
      FState.PeriodLeft := Period;
      Output := Excitation;
    end;
    FState.Registers[Amplitude] := (Level + FState.Registers[AmplitudeStep]) and $FF;
    FState.Registers[Pitch] := (Period + FState.Registers[PitchStep]) and $FF;
  end;
  Dec(FState.PeriodLeft);

  for var Stage := 0 to 5 do
  begin
    Inc(Output, ShiftSigned(FCoefficients[Stage, 0] * FState.Delay[Stage, 1], 9));
    Inc(Output, ShiftSigned(FCoefficients[Stage, 1] * FState.Delay[Stage, 0], 8));
    Output := ((Output + $8000) and $FFFF) - $8000;
    FState.Delay[Stage, 1] := FState.Delay[Stage, 0];
    FState.Delay[Stage, 0] := Output;
  end;
  Result := EnsureRange(ShiftSigned(Output, 4), -128, 127) * 256;
end;

procedure TIntvVoice.Advance(CPUCycles: Integer);
begin
  Inc(FState.Phase, CPUCycles * 4 * OutputRate);
  while FState.Phase >= FClock do
  begin
    Dec(FState.Phase, FClock);
    FState.PreviousSample := FState.CurrentSample;
    FState.CurrentSample := Synthesize;
  end;
end;

function TIntvVoice.Sample: SmallInt;
begin
  Result := FState.PreviousSample + (Int64(FState.CurrentSample - FState.PreviousSample) * FState.Phase) div FClock;
end;

procedure TIntvVoice.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  if State.Loading then
  begin
    if (Cardinal(FState.PC) > BitAddressMask) or (Cardinal(FState.ReturnPC) > BitAddressMask) or
      (Cardinal(FState.Phase) >= Cardinal(FClock)) or (FState.Page > $F) or
      (FState.Mode > 3) or (FState.Prefix and not $30 <> 0) or
      (FState.FIFOHead >= FIFOSize) or (FState.FIFOCount > FIFOSize) or
      (FState.FIFOBit > 9) or (FState.FIFOCount * 10 < FState.FIFOBit) or
      (FState.Repeats > 63) then
      raise EReadError.Create('Invalid Intellivoice snapshot');
    DecodeCoefficients;
  end;
end;

end.

