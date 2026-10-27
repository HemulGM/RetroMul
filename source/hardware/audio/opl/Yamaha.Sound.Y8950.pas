unit Yamaha.Sound.Y8950;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PC.Sound.OPL;

type
  TY8950 = class
  private
    FFM: TOPL1;
    FR: array[0..255] of Byte;
    FRAM: TBytes;
    FAddress, FControl, FStatus, FMask, FData, FLatched, FReadDelay, FKeyboardIn, FGPIOInput: Byte;
    FKeys: array[0..7] of Byte;
    FPosition, FPhase, FPredictor, FPrevious, FLevel, FStep, FNativePhase: Integer;
    FRecordPhase: Integer;
    FAnalogInput: SmallInt;
    FOutput, FDAC: Integer;
    FPlaying, FRecording, FHighNibble: Boolean;
    FCSMPhase: Byte;
    procedure TimerOverflow(Timer: Integer);
    function StartAddress: Integer;
    function StopAddress: Integer;
    function MemoryAddress(Nibble: Integer): Integer;
    function ReadMemory(Nibble: Integer): Byte;
    procedure WriteMemory(Nibble: Integer; Value: Byte);
    procedure Decode(Nibble: Byte);
    procedure NativeTick;
    procedure RecordTick;
    procedure BeginTransfer;
    procedure DataWrite(Value: Byte);
    function DataRead: Byte;
    procedure Ready;
  public
    constructor Create(RAMSize: Integer = 32768);
    destructor Destroy; override;
    procedure Reset;
    procedure SetMusicKey(Note: Integer; Pressed: Boolean);
    procedure AdvanceClocks(Cycles: Integer);
    procedure WritePort(Port, Value: Byte);
    function ReadPort(Port: Byte): Byte;
    procedure WriteRegister(Index, Value: Byte);
    function RegisterValue(Index: Byte): Byte;
    function ReadStatus: Byte;
    function Interrupt: Boolean;
    function Sample: SmallInt;
    procedure SerializeState(State: TStateArchive);
    property KeyboardInput: Byte read FKeyboardIn write FKeyboardIn;
    property GPIOInput: Byte read FGPIOInput write FGPIOInput;
    property AddressLatch: Byte read FAddress;
    property AnalogInput: SmallInt read FAnalogInput write FAnalogInput;
    property CSMPhase: Byte read FCSMPhase;
  end;

implementation

constructor TY8950.Create(RAMSize: Integer);
begin
  inherited Create;
  if (RAMSize <> 32768) and (RAMSize <> 65536) and (RAMSize <> 131072) and (RAMSize <> 262144) then
    raise EArgumentOutOfRangeException.Create('Y8950 sample RAM size');
  SetLength(FRAM, RAMSize);
  FillChar(FRAM[0], RAMSize, $FF);
  FFM := TOPL1.Create;
  FFM.OnTimerOverflow := TimerOverflow;
  Reset;
end;

destructor TY8950.Destroy;
begin
  FFM.Free;
  inherited;
end;

procedure TY8950.Reset;
begin
  FFM.Reset;
  FillChar(FR, SizeOf(FR), 0);
  FR[$12] := 255;
  FAddress := 0;
  FControl := 0;
  FStatus := 8;
  FMask := 0;
  FData := 0;
  FLatched := 0;
  FReadDelay := 0;
  FPosition := 0;
  FPhase := 0;
  FPredictor := 0;
  FPrevious := 0;
  FLevel := 0;
  FStep := 127;
  FNativePhase := 0;
  FRecordPhase := 0;
  FOutput := 0;
  FDAC := 0;
  FCSMPhase := 0;
  FPlaying := False;
  FRecording := False;
  FHighNibble := True;
  FKeyboardIn := $FF;
  FAnalogInput := 0;
  FGPIOInput := 0;
  FillChar(FKeys, SizeOf(FKeys), 0);
end;

procedure TY8950.SetMusicKey(Note: Integer; Pressed: Boolean);
const
  Bits: array[0..5] of Byte = (0, 1, 2, 4, 5, 6);
begin
  if (Note < 0) or (Note > 48) then
    raise EArgumentOutOfRangeException.Create('MSX-AUDIO music key');
  var Row := 0;
  var Bit := 7;
  if Note > 0 then
  begin
    Row := (Note - 1) div 6;
    Bit := Bits[(Note - 1) mod 6];
  end;
  if Pressed then
    FKeys[Row] := FKeys[Row] or (1 shl Bit)
  else
    FKeys[Row] := FKeys[Row] and ($FF xor (1 shl Bit));
end;

function TY8950.StartAddress: Integer;
begin
  Result := (Integer(FR[9]) or (Integer(FR[10]) shl 8)) shl 3;
end;

function TY8950.StopAddress: Integer;
begin
  Result := ((Integer(FR[11]) or (Integer(FR[12]) shl 8)) shl 3) or 7;
end;

function TY8950.MemoryAddress(Nibble: Integer): Integer;
begin
  Result := (Nibble shr 1) and $3FFFF;
  if FR[8] and 2 <> 0 then
    Result := Result and $FFFF;
end;

function TY8950.ReadMemory(Nibble: Integer): Byte;
begin
  var A := MemoryAddress(Nibble);
  Result := 0;
  if (FR[8] and 1 = 0) and (A < Length(FRAM)) then
    Result := FRAM[A];
end;

procedure TY8950.WriteMemory(Nibble: Integer; Value: Byte);
begin
  var A := MemoryAddress(Nibble);
  if (FR[8] and 1 = 0) and (A < Length(FRAM)) then
    FRAM[A] := Value;
end;

procedure TY8950.Ready;
begin
  if not (FPlaying or FRecording) or (FControl and $A0 = $20) then
    FStatus := FStatus or 8;
end;

procedure TY8950.BeginTransfer;
begin
  FPosition := StartAddress;
  FPredictor := 0;
  FPrevious := 0;
  FLevel := 0;
  FStep := 127;
  FOutput := 0;
  FPhase := 65536 - (Integer(FR[$10]) or (Integer(FR[$11]) shl 8));
  FReadDelay := 2;
  FRecordPhase := 0;
  FHighNibble := True;
  // External-memory modes start at START. CPU modes wait for the first
  // ADPCM data write (synthesis) or dummy read (analysis), per Yamaha's manual.
  FPlaying := (FControl and $E0 = $A0);
  FRecording := (FControl and $E0 = $E0);
  if FControl and $20 = 0 then
    FPosition := 0;
  FStatus := FStatus and $FE;
  if FControl and $80 <> 0 then
    FStatus := FStatus or 1;
  Ready;
end;

procedure TY8950.Decode(Nibble: Byte);
const
  Adjust: array[0..7] of Integer = (57, 57, 57, 57, 77, 102, 128, 153);
begin
  // Native Delta-T predictor, also used by RetroMul's YM2610 ADPCM-B.
  var Delta := (2 * Integer(Nibble and 7) + 1) * FStep div 8;
  if Nibble and 8 <> 0 then
    Delta := -Delta;
  var Before := FPredictor;
  FPredictor := EnsureRange(FPredictor + Delta, -32768, 32767);
  FStep := EnsureRange(FStep * Adjust[Nibble and 7] div 64, 127, 24576);
  FPrevious := FLevel;
  FLevel := (Before + FPredictor) div 2;
end;

procedure TY8950.NativeTick;
begin
  case FCSMPhase of
    1:
      begin
        FFM.SetCSMKey(True);
        FCSMPhase := 2;
      end;
    2:
      begin
        FFM.SetCSMKey(False);
        FCSMPhase := 0;
      end;
  end;
  FFM.ClockNative;
  if not FPlaying then
    Exit;
  var Delta := Integer(FR[$10]) or (Integer(FR[$11]) shl 8);
  Inc(FPhase, Delta);
  if FPhase >= 65536 then
  begin
    Dec(FPhase, 65536);
    if FPosition and 1 = 0 then
    begin
      if FControl and $20 <> 0 then
        FLatched := ReadMemory(FPosition)
      else
      begin
        FLatched := FData;
        FStatus := FStatus or 8;
      end;
      Decode(FLatched shr 4);
    end
    else
      Decode(FLatched and 15);
    Inc(FPosition);
    if FControl and $20 = 0 then
      FPosition := FPosition and $7FFFF;
    if (FControl and $20 <> 0) and (FPosition > StopAddress) then
    begin
      FStatus := FStatus or $10;
      if FControl and $10 <> 0 then
      begin
        FPosition := StartAddress;
        FPredictor := 0;
        FPrevious := 0;
        FLevel := 0;
        FStep := 127;
        FPhase := 65536 - Delta;
      end
      else
      begin
        FPlaying := False;
        FControl := 0;
        FStatus := FStatus and $FE;
      end;
    end;
  end;
  FOutput := FPrevious + Integer(Int64(FLevel - FPrevious) * FPhase div 65536);
end;

procedure TY8950.RecordTick;
begin
  if not FRecording then
    Exit;
  var Difference := Integer(FAnalogInput) - FPredictor;
  var N := Min(7, Abs(Difference) * 4 div FStep);
  if Difference < 0 then
    N := N or 8;
  Decode(N);
  if FHighNibble then
    FLatched := N shl 4
  else
  begin
    FLatched := FLatched or N;
    FData := FLatched;
    FStatus := FStatus or 8;
    if FControl and $20 <> 0 then
      WriteMemory(FPosition and not 1, FLatched);
  end;
  FHighNibble := not FHighNibble;
  Inc(FPosition);
  if FControl and $20 = 0 then
    FPosition := FPosition and $7FFFF;
  if (FControl and $20 <> 0) and (FPosition > StopAddress) then
  begin
    FStatus := FStatus or $10;
    FStatus := FStatus and $FE;
    FRecording := False;
    FControl := 0;
  end;
end;

procedure TY8950.AdvanceClocks(Cycles: Integer);
begin
  if Cycles < 0 then
    raise EArgumentOutOfRangeException.Create('Y8950 clocks');
  var Left := Cycles;
  while Left > 0 do
  begin
    var N := Min(Left, 72 - FNativePhase);
    Dec(Left, N);
    Inc(FNativePhase, N);
    FFM.AdvanceClocks(N);
    if FNativePhase = 72 then
    begin
      FNativePhase := 0;
      NativeTick;
    end;
  end;
  if FRecording then
  begin
    var Prescale := Integer(FR[$0D]) or (Integer(FR[$0E]) shl 8);
    if Prescale < 1 then
      Prescale := 1;
    Inc(FRecordPhase, Cycles);
    while FRecording and (FRecordPhase >= Prescale) do
    begin
      Dec(FRecordPhase, Prescale);
      RecordTick;
    end;
  end;
end;

procedure TY8950.TimerOverflow(Timer: Integer);
begin
  // Yamaha: Timer 1 keys all 18 operators, independently of IRQ masking.
  if (Timer = 0) and (FR[8] and $80 <> 0) then
    FCSMPhase := 1;
end;

procedure TY8950.DataWrite(Value: Byte);
begin
  FData := Value;
  case FControl and $E0 of
    $60:
      begin
        if FReadDelay > 0 then
        begin
          FPosition := StartAddress;
          FReadDelay := 0;
        end;
        if FPosition <= StopAddress then
        begin
          WriteMemory(FPosition, Value);
          Inc(FPosition, 2);
          FStatus := FStatus or 8;
          if FPosition > StopAddress then
          begin
            FStatus := FStatus or $10;
            FPosition := StartAddress;
          end;
        end;
      end;
    $80:
      begin
        FStatus := FStatus and $F7;
        FPlaying := True;
      end;
  end;
end;

function TY8950.DataRead: Byte;
begin
  Result := 0;
  if FControl and $E0 = $20 then
  begin
    if FReadDelay > 0 then
    begin
      Dec(FReadDelay);
      FPosition := StartAddress;
      Exit(FData);
    end;
    if FPosition > StopAddress then
    begin
      FStatus := FStatus or $10;
      Exit;
    end;
    Result := ReadMemory(FPosition);
    Inc(FPosition, 2);
    FStatus := FStatus or 8;
  end
  else if FControl and $E0 = $C0 then
  begin
    if not FRecording then
    begin
      FRecording := True;
      FRecordPhase := 0;
    end;
    Result := FData;
    FStatus := FStatus and $F7;
  end;
end;

procedure TY8950.WriteRegister(Index, Value: Byte);
begin
  if Index = 4 then
  begin
    FFM.WriteRegister(4, Value);
    if Value and $80 <> 0 then
      FStatus := FStatus and 1
    else
    begin
      FR[4] := Value;
      FMask := (not Value) and $78;
      FStatus := FStatus and (FMask or 1);
    end;
    Ready;
    Exit;
  end;
  if Index = $16 then
    Value := Value and $C0;
  if Index = $17 then
    Value := Value and 7;
  if (Index = 8) and (Value and $80 = 0) then
  begin
    FCSMPhase := 0;
    FFM.SetCSMKey(False);
  end;
  FR[Index] := Value;
  case Index of
    7:
      begin
        FControl := Value;
        if Value and 1 <> 0 then
        begin
          FControl := 0;
          FPlaying := False;
          FRecording := False;
          FStatus := FStatus and $FE;
          FOutput := 0;
          Ready;
        end
        else
          BeginTransfer;
      end;
    $0F:
      DataWrite(Value);
    $15:
      if FR[8] and 4 <> 0 then
      begin
        var V := Integer(Value);
        if V >= 128 then
          Dec(V, 256);
        FDAC := EnsureRange(((V * 256 + FR[$16]) * 4) div (1 shl (7 - FR[$17])), -32768, 32767);
      end;
  end;
  // Reuse the native OPL1 operators, rhythm, envelopes and timers. ADPCM,
  // keyboard, DAC and GPIO registers belong to the Y8950 wrapper.
  if (Index in [1, 2, 3, 8]) or (Index >= $20) then
    FFM.WriteRegister(Index, Value);
end;

function TY8950.RegisterValue(Index: Byte): Byte;
begin
  Result := FR[Index];
end;

procedure TY8950.WritePort(Port, Value: Byte);
begin
  if Port and 1 = 0 then
    FAddress := Value
  else
    WriteRegister(FAddress, Value);
end;

function TY8950.ReadPort(Port: Byte): Byte;
begin
  if Port and 1 = 0 then
    Exit(ReadStatus);
  case FAddress of
    5:
      begin
        Result := FKeyboardIn;
        for var Row := 0 to 7 do
          if FR[6] and (1 shl Row) <> 0 then
            Result := Result and not FKeys[Row];
      end;
    $0F:
      Result := DataRead;
    $13:
      Result := (Int64(FOutput) * FR[$12] shr 8) and 255;
    $14:
      Result := (Int64(FOutput) * FR[$12] shr 16) and 255;
    $19:
      Result := $F0 or ((FR[$19] and FR[$18]) or (FGPIOInput and not FR[$18])) and 15;
    $1A:
      Result := (Integer(FAnalogInput) shr 8) and 255;
  else
    Result := FR[FAddress];
  end;
end;

function TY8950.ReadStatus: Byte;
begin
  Result := ((FFM.ReadStatus and $60) or FStatus) and (FMask or 1);
  if Result and FMask <> 0 then
    Result := Result or $80;
  Result := Result or 6;
end;

function TY8950.Interrupt: Boolean;
begin
  Result := ReadStatus and $80 <> 0;
end;

function TY8950.Sample: SmallInt;
begin
  var L, R: SmallInt;
  FFM.CurrentSample(L, R);
  var V := (Integer(L) + Integer(R)) div 2;
  if FPlaying and (FControl and 8 = 0) then
    Inc(V, Int64(FOutput) * FR[$12] div 256);
  Inc(V, FDAC);
  Result := EnsureRange(V, -32768, 32767);
end;

procedure TY8950.SerializeState(State: TStateArchive);
begin
  var Size := Length(FRAM);
  State.Field(Size, SizeOf(Size));
  if Size <> Length(FRAM) then
    raise EReadError.Create('Y8950 sample RAM differs');
  State.Field(FRAM[0], Size);
  State.Field(FR, SizeOf(FR));
  State.Field(FAddress, 1);
  State.Field(FControl, 1);
  State.Field(FStatus, 1);
  State.Field(FMask, 1);
  State.Field(FData, 1);
  State.Field(FLatched, 1);
  State.Field(FReadDelay, 1);
  State.Field(FKeyboardIn, 1);
  State.Field(FGPIOInput, 1);
  State.Field(FKeys, SizeOf(FKeys));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FPredictor, SizeOf(FPredictor));
  State.Field(FPrevious, SizeOf(FPrevious));
  State.Field(FLevel, SizeOf(FLevel));
  State.Field(FStep, SizeOf(FStep));
  State.Field(FNativePhase, SizeOf(FNativePhase));
  State.Field(FRecordPhase, SizeOf(FRecordPhase));
  State.Field(FAnalogInput, SizeOf(FAnalogInput));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FDAC, SizeOf(FDAC));
  State.Field(FPlaying, SizeOf(FPlaying));
  State.Field(FRecording, SizeOf(FRecording));
  State.Field(FHighNibble, SizeOf(FHighNibble));
  State.Field(FCSMPhase, 1);
  FFM.SerializeState(State);
  if State.Loading and ((FPosition < 0) or (FPosition > $80000) or (FPhase < 0) or (FPhase > 65536) or
    (FStep < 127) or (FStep > 24576) or (FNativePhase < 0) or (FNativePhase >= 72) or
    (FReadDelay > 2) or (FCSMPhase > 2) or (Abs(Int64(FPredictor)) > 32768) or (Abs(Int64(FOutput)) > 65536)) then
    raise EReadError.Create('Invalid Y8950 state');
end;

end.

