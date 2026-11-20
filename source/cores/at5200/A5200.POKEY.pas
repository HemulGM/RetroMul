unit A5200.POKEY;

interface

uses
  System.SysUtils, A5200.POKEY.Types, A5200.Controller, Core.Snapshots;

type
  TPokeyReceive = function(out Value: Byte): Boolean of object;

  TPokeyTransmit = procedure(Value: Byte) of object;

  TA5200POKEY = class
  protected
    FPair: TPokeyPair;
    FRegs: array[0..15] of Byte;
    FPots: array[0..7] of Byte;
    FCycle, FPotCycle: Integer;
    FLastKey: Byte;
    FNTSC: Boolean;
    FSerialIn, FSerialOut, FShifter, FStatus, FInputByte: Byte;
    FTimer: array[0..3] of Integer;
    FBorrow: array[0..3] of Int64;
    FTime, FTimerReset, FClock15, FClock64: Int64;
    FTwoToneReset: Byte;
    FFrequencyWrite: Integer;
    FSerialDelay: Word;
    FOldFrequency, FPolyResetValue: Byte;
    FShiftCycles, FInputCycles, FInputBit, FPolyResetCycles: Integer;
    FReceive, FLineIn, FLineOut, FSerialPhase: Boolean;
    FSendPending: Boolean;
    FKeyDown: Boolean;
    procedure ResetTiming;
    procedure ReloadTimer(Index: Integer);
    procedure CountTimer(Index: Integer);
    function ClockTimerPulses: Byte;
    procedure ClockSerial(Pulses: Byte; Receive: TPokeyReceive; Transmit: TPokeyTransmit);
    procedure ClockTimers(Receive: TPokeyReceive = nil; Transmit: TPokeyTransmit = nil);
    procedure RaiseIRQ(Mask: Byte);
    procedure ScanKeys; virtual;
    function ReadRegister(Index: Byte): Byte;
    procedure WriteRegister(Index, Value: Byte);
    procedure RestoreTimerPhase;
    procedure SerializeTiming(State: TStateArchive);
  public
    constructor Create(NTSC: Boolean = True);
    destructor Destroy; override;
    procedure Reset; virtual;
    procedure BeginFrame;
    procedure Clock(Controller: TA5200Controller; SelectedPort: Integer);
    function Read(Index: Byte; Controller: TA5200Controller; SelectedPort: Integer; PotsEnabled: Boolean): Byte;
    procedure Write(Index, Value: Byte; Controller: TA5200Controller);
    procedure EndFrame(out Samples: TArray<SmallInt>);
    function IRQ: Boolean;
    procedure SerializeState(State: TStateArchive);
    procedure SerializeConsole(State: TStateArchive);
  end;

implementation

uses
  System.Math, A5200.POKEY.Engine;

constructor TA5200POKEY.Create(NTSC: Boolean);
begin
  inherited Create;
  FNTSC := NTSC;
  FPair := TPokeyPair.Create;
  PokeyPair_Construct(FPair);
  Reset;
end;

destructor TA5200POKEY.Destroy;
begin
  FPair.Free;
  inherited;
end;

procedure TA5200POKEY.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FPots, SizeOf(FPots), 228);
  PokeyPair_Initialize(FPair, FNTSC, False, 44100);
  FCycle := 0;
  FPotCycle := 0;
  FLastKey := $FF;
  FSerialIn := $FF;
  FSerialOut := $FF;
  FShifter := $FF;
  FStatus := $FF;
  FSendPending := False;
  FKeyDown := False;
  FShiftCycles := 0;
  ResetTiming;
  FPair.basePokey.irqst := $F7;
end;

procedure TA5200POKEY.ResetTiming;
begin
  FInputByte := $FF;
  FInputCycles := 0;
  FInputBit := -1;
  FTime := 0;
  FTimerReset := -1;
  FTwoToneReset := 0;
  FFrequencyWrite := -1;
  FClock15 := -1;
  FClock64 := -1;
  for var I := 0 to 3 do
  begin
    FTimer[I] := FRegs[I * 2];
    FBorrow[I] := -1;
  end;
  FSerialPhase := False;
  FSerialDelay := 0;
  FReceive := False;
  FLineIn := True;
  FLineOut := True;
  FPolyResetCycles := 8;
  FPolyResetValue := $FF;
end;

procedure TA5200POKEY.BeginFrame;
begin
  PokeyPair_StartFrame(FPair);
  FCycle := 0;
end;

const
  SerialByteCycles = 932;

procedure TA5200POKEY.ScanKeys;
begin
end;

procedure TA5200POKEY.ReloadTimer(Index: Integer);
begin
  if FFrequencyWrite = Index then
    FTimer[Index] := FOldFrequency
  else
    FTimer[Index] := FRegs[Index * 2];
end;

procedure TA5200POKEY.CountTimer(Index: Integer);
begin
  // The counter underflows immediately. Its borrow reaches the output
  // and the linked channel three cycles later.
  if FTimer[Index] = 0 then
    FBorrow[Index] := FTime + 3;
  FTimer[Index] := (FTimer[Index] - 1) and $FF;
end;

function TA5200POKEY.ClockTimerPulses: Byte;
begin
  Result := 0;
  var Slow := False;
  if FClock15 = FTime then
  begin
    Slow := FRegs[8] and 1 <> 0;
    Inc(FClock15, 114);
    ScanKeys;
  end;
  if FClock64 = FTime then
  begin
    Slow := Slow or (FRegs[8] and 1 = 0);
    Inc(FClock64, 28);
  end;
  var AsyncHold := (FRegs[15] and $10 <> 0) and (FInputBit < 0);
  var Resync := FTwoToneReset and 1 <> 0;
  FTwoToneReset := FTwoToneReset shr 1;
  if Resync then
  begin
    FBorrow[0] := -1;
    FBorrow[1] := -1;
  end;
  for var Pair := 0 to 1 do
  begin
    var Lo := Pair * 2;
    var Hi := Lo + 1;
    if (Pair = 1) and AsyncHold then
    begin
      ReloadTimer(Lo);
      ReloadTimer(Hi);
      FBorrow[Lo] := -1;
      FBorrow[Hi] := -1;
      Continue;
    end;
    var Linked := FRegs[8] and ($10 shr Pair) <> 0;
    var Fast := FRegs[8] and ($40 shr Pair) <> 0;
    // A borrow already in the propagation stages survives a timer reset.
    if (FTimerReset < FTime) and ((Pair <> 0) or not Resync) then
    begin
      if Fast or Slow then
        CountTimer(Lo);
      if Slow and not Linked then
        CountTimer(Hi);
    end;
    if FBorrow[Lo] = FTime then
    begin
      FBorrow[Lo] := -1;
      Result := Result or (1 shl Lo);
      if Linked then
      begin
        if FTimerReset < FTime then
          CountTimer(Hi);
      end
      else if FTime - 3 >= FTimerReset then
        ReloadTimer(Lo);
    end;
    if FBorrow[Hi] = FTime then
    begin
      FBorrow[Hi] := -1;
      Result := Result or (1 shl Hi);
      if FTime - 3 >= FTimerReset then
      begin
        ReloadTimer(Hi);
        if Linked then
          ReloadTimer(Lo);
      end;
    end;
    if (FTimerReset = FTime) or ((Pair = 0) and Resync) then
    begin
      ReloadTimer(Lo);
      ReloadTimer(Hi);
    end;
  end;
  if (FRegs[15] and 8 <> 0) and ((Result and 2 <> 0) or
    ((Result and 1 <> 0) and (FRegs[15] and $80 = 0) and FLineOut)) then
    FTwoToneReset := FTwoToneReset or 2;
end;

procedure TA5200POKEY.ClockSerial(Pulses: Byte; Receive: TPokeyReceive; Transmit: TPokeyTransmit);
begin
  var Mode := (FRegs[15] shr 4) and 7;
  if FInputCycles > 0 then
    Dec(FInputCycles);
  var Input: Byte;
  if Assigned(Receive) and Receive(Input) then
  begin
    FInputByte := Input;
    FInputCycles := SerialByteCycles;
    if Mode and 1 <> 0 then
    begin
      FInputBit := 0;
      FReceive := False;
    end;
  end;
  FLineIn := True;
  if FInputCycles <> 0 then
  begin
    var BitIndex := ((SerialByteCycles - FInputCycles) * 10) div SerialByteCycles;
    if BitIndex < 9 then
      FLineIn := (BitIndex > 0) and (FInputByte and (1 shl Max(0, BitIndex - 1)) <> 0);
  end;
  if FRegs[15] and 3 = 0 then
    Exit;
  if (Pulses and 8 <> 0) and (FInputBit >= 0) then
  begin
    Inc(FInputBit);
    if FInputBit = 1 then
      FReceive := True;
    if FInputBit = 19 then
    begin
      FInputBit := -1;
      FReceive := False;
      if FPair.basePokey.irqst and $20 = 0 then
        FStatus := FStatus and $DF;
      FSerialIn := FInputByte;
      RaiseIRQ($20);
    end;
  end;

  var OutputClock := 0;
  case Mode of
    2, 3, 4, 5:
      OutputClock := 8;
    6, 7:
      OutputClock := 2;
  end;
  if Pulses and OutputClock = 0 then
    Exit;
  FSerialPhase := not FSerialPhase;
  if not FSerialPhase then
    Exit;
  if FShiftCycles > 0 then
  begin
    Dec(FShiftCycles);
    if FShiftCycles = 0 then
    begin
      if Assigned(Transmit) then
        Transmit(FShifter);
    end
    else if FShiftCycles = 1 then
      FLineOut := True
    else
      FLineOut := FShifter and (1 shl (9 - FShiftCycles)) <> 0;
  end;
  if FShiftCycles = 0 then
  begin
    if FSendPending then
    begin
      FShifter := FSerialOut;
      FSendPending := False;
      FShiftCycles := 10;
      FLineOut := False;
      RaiseIRQ($10);
    end;
    if FShiftCycles = 0 then
      FPair.basePokey.irqst := FPair.basePokey.irqst and $F7
    else
      FPair.basePokey.irqst := FPair.basePokey.irqst or 8;
  end;
end;

procedure TA5200POKEY.ClockTimers(Receive: TPokeyReceive; Transmit: TPokeyTransmit);
begin
  var Pulses := ClockTimerPulses;
  RaiseIRQ((Pulses and 3) or ((Pulses and 8) shr 1));
  // The serial state machines see timer pulses after two clock stages.
  ClockSerial(FSerialDelay shr 8, Receive, Transmit);
  FSerialDelay := ((FSerialDelay and $FF) shl 8) or Pulses;
  Inc(FTime);
  Inc(FCycle);
  FFrequencyWrite := -1;
  if FPotCycle < 114 * 228 then
    Inc(FPotCycle);
  if FPolyResetCycles < 8 then
    Inc(FPolyResetCycles);
end;

function TA5200POKEY.ReadRegister(Index: Byte): Byte;
begin
  var Elapsed := FPotCycle div 114;
  if FRegs[15] and 4 <> 0 then
    Elapsed := FPotCycle;
  case Index of
    0..7:
      Result := Min(FPots[Index], Elapsed);
    8:
      begin
        Result := 0;
        for var Pot := 0 to High(FPots) do
          if Elapsed < FPots[Pot] then
            Result := Result or (1 shl Pot);
      end;
    9:
      Result := FLastKey;
    10:
      if FRegs[15] and 3 = 0 then
      begin
        var Clocks := Max(0, FPolyResetCycles);
        Result := (FPolyResetValue shr Clocks) or ($FF xor ($FF shr Clocks));
      end
      else
        Result := PokeyPair_Peek(FPair, Index, FCycle);
    13:
      Result := FSerialIn;
    14:
      Result := FPair.basePokey.irqst;
    15:
      begin
        Result := FStatus;
        if FKeyDown then
          Result := Result and $FB;
        if FReceive then
          Result := Result and $FD;
        if not FLineIn then
          Result := Result and $EF;
      end;
  else
    Result := $FF;
  end;
end;

procedure TA5200POKEY.WriteRegister(Index, Value: Byte);
begin
  if (Index = 15) and (Value and 3 = 0) and (FRegs[15] and 3 <> 0) then
  begin
    FPolyResetValue := PokeyPair_Peek(FPair, 10, FCycle + 1);
    FPolyResetCycles := -1;
  end;
  var Previous := FRegs[Index];
  FRegs[Index] := Value;
  case Index of
    0, 2, 4, 6:
      begin
        FFrequencyWrite := Index shr 1;
        FOldFrequency := Previous;
      end;
    9:
      FTimerReset := FTime + 3;
    10:
      FStatus := FStatus or $E0;
    11:
      FPotCycle := 0;
    13:
      begin
        FSerialOut := Value;
        FSendPending := True;
      end;
    14:
      FPair.basePokey.irqst := FPair.basePokey.irqst or (not Value and $F7);
    15:
      begin
        if Value and $70 = 0 then
          FSerialPhase := False;
        if Value and 3 = 0 then
        begin
          FClock15 := -1;
          FClock64 := -1;
          FShiftCycles := 0;
          FSendPending := False;
          FReceive := False;
          FInputBit := -1;
          FKeyDown := False;
          FPair.basePokey.irqst := FPair.basePokey.irqst and $F7;
        end
        else if Previous and 3 = 0 then
        begin
          FClock15 := FTime + 80;
          FClock64 := FTime + 21;
        end;
      end;
  end;
  var Status := FPair.basePokey.irqst;
  PokeyPair_Poke(FPair, Index, Value, FCycle);
  FPair.basePokey.irqst := Status;
end;

procedure TA5200POKEY.RaiseIRQ(Mask: Byte);
begin
  FPair.basePokey.irqst := FPair.basePokey.irqst and not (Mask and FRegs[14]);
end;

procedure TA5200POKEY.Clock(Controller: TA5200Controller; SelectedPort: Integer);
begin
  ClockTimers;
  if FCycle mod 114 = 0 then
  begin
    var Key := Controller.Keyboard(SelectedPort);
    if (FRegs[15] and 2 <> 0) and (Key <> $FF) and (Key <> FLastKey) and (FRegs[14] and $40 <> 0) then
      FPair.basePokey.irqst := FPair.basePokey.irqst and $BF;
    if Controller.TopButton(SelectedPort) and (FRegs[14] and $80 <> 0) then
      FPair.basePokey.irqst := FPair.basePokey.irqst and $7F;
    FLastKey := Key;
  end;
end;

function TA5200POKEY.Read(Index: Byte; Controller: TA5200Controller; SelectedPort: Integer; PotsEnabled: Boolean): Byte;
begin
  Index := Index and 15;
  Result := $FF;
  if Index < 8 then
  begin
    var Elapsed := FPotCycle div 114;
    if FRegs[15] and 4 <> 0 then
      Elapsed := FPotCycle;
    if PotsEnabled then
      Result := Min(FPots[Index], Min(228, Elapsed))
    else
      Result := 228;
  end
  else
    case Index of
      8:
        begin
          Result := 0;
          for var i := 0 to 7 do
            if (FPotCycle div 114 < FPots[i]) then
              Result := Result or (1 shl i);
        end;
      9:
        Result := FLastKey;
      10, 13, 14:
        Result := ReadRegister(Index);
      15:
        begin
          Result := ReadRegister(Index);
          if Controller.TopButton(SelectedPort) then
            Result := Result and $F7;
          if Controller.Keyboard(SelectedPort) <> $FF then
            Result := Result and $FB;
        end;
    end;
end;

procedure TA5200POKEY.Write(Index, Value: Byte; Controller: TA5200Controller);
begin
  Index := Index and 15;
  WriteRegister(Index, Value);
  if Index = 11 then
  begin
    for var i := 0 to 7 do
      FPots[i] := Controller.Pot(i);
  end;
end;

function TA5200POKEY.IRQ: Boolean;
begin
  Result := (FPair.basePokey.irqst xor 255) and FRegs[14] <> 0;
end;

procedure TA5200POKEY.EndFrame(out Samples: TArray<SmallInt>);
begin
  var Count := PokeyPair_EndFrame(FPair, FCycle);
  var PCM: TBytes;
  SetLength(PCM, Count * 2);
  PokeyPair_Generate(FPair, PCM, 0, Count, ASAPSampleFormat_S16_L_E);
  SetLength(Samples, Count * 2);
  for var i := 0 to Count - 1 do
  begin
    var V := SmallInt(Word(PCM[i * 2]) or (Word(PCM[i * 2 + 1]) shl 8));
    Samples[i * 2] := V;
    Samples[i * 2 + 1] := V;
  end;
  for var i := 0 to 3 do
    PokeyChannel_EndFrame(FPair.basePokey.channels[i], FCycle);
end;

procedure TA5200POKEY.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FPots, SizeOf(FPots));
  State.Field(FCycle, SizeOf(FCycle));
  State.Field(FPotCycle, SizeOf(FPotCycle));
  State.Field(FLastKey, SizeOf(FLastKey));
  State.Field(FPair.sampleOffset, SizeOf(Integer));
  State.Field(FPair.readySamplesStart, SizeOf(Integer));
  State.Field(FPair.readySamplesEnd, SizeOf(Integer));
  var P := FPair.basePokey;
  State.Field(P.audctl, SizeOf(Integer));
  State.Field(P.skctl, SizeOf(Integer));
  State.Field(P.irqst, SizeOf(Integer));
  State.Field(P.init, SizeOf(Boolean));
  State.Field(P.divCycles, SizeOf(Integer));
  State.Field(P.reloadCycles1, SizeOf(Integer));
  State.Field(P.reloadCycles3, SizeOf(Integer));
  State.Field(P.polyIndex, SizeOf(Integer));
  State.Field(P.sumDACInputs, SizeOf(Integer));
  State.Field(P.sumDACOutputs, SizeOf(Integer));
  State.Field(P.iirAcc, SizeOf(Integer));
  State.Field(P.trailing, SizeOf(Integer));
  State.Field(P.deltaBuffer[0], Length(P.deltaBuffer) * SizeOf(Integer));
  for var i := 0 to 3 do
  begin
    var C := P.channels[i];
    State.Field(C.audf, SizeOf(Integer));
    State.Field(C.audc, SizeOf(Integer));
    State.Field(C.periodCycles, SizeOf(Integer));
    State.Field(C.tickCycle, SizeOf(Integer));
    State.Field(C.timerCycle, SizeOf(Integer));
    State.Field(C.mute, SizeOf(Integer));
    State.Field(C.output, SizeOf(Integer));
    State.Field(C.delta, SizeOf(Integer));
  end;
end;

procedure TA5200POKEY.RestoreTimerPhase;
begin
  ResetTiming;
  if FRegs[15] and 3 <> 0 then
  begin
    FClock15 := 79;
    FClock64 := 20;
  end;
end;

procedure TA5200POKEY.SerializeConsole(State: TStateArchive);
begin
  SerializeState(State);
  if State.Version in [1, 2] then
  begin
    if State.Loading then
    begin
      FSerialIn := $FF;
      FSerialOut := $FF;
      FShifter := $FF;
      FStatus := $FF;
      FSendPending := False;
      FShiftCycles := 0;
      FPair.basePokey.irqst := FPair.basePokey.irqst and $F7;
      RestoreTimerPhase;
    end;
    Exit;
  end;
  State.Field(FSerialIn, SizeOf(FSerialIn));
  State.Field(FSerialOut, SizeOf(FSerialOut));
  State.Field(FShifter, SizeOf(FShifter));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FSendPending, SizeOf(FSendPending));
  SerializeTiming(State);
end;

procedure TA5200POKEY.SerializeTiming(State: TStateArchive);
begin
  State.Field(FShiftCycles, SizeOf(FShiftCycles));
  State.Field(FPolyResetValue, SizeOf(FPolyResetValue));
  State.Field(FPolyResetCycles, SizeOf(FPolyResetCycles));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FBorrow, SizeOf(FBorrow));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FTimerReset, SizeOf(FTimerReset));
  State.Field(FTwoToneReset, SizeOf(FTwoToneReset));
  State.Field(FClock15, SizeOf(FClock15));
  State.Field(FClock64, SizeOf(FClock64));
  State.Field(FInputCycles, SizeOf(FInputCycles));
  State.Field(FInputBit, SizeOf(FInputBit));
  State.Field(FInputByte, SizeOf(FInputByte));
  State.Field(FReceive, SizeOf(FReceive));
  State.Field(FLineIn, SizeOf(FLineIn));
  State.Field(FLineOut, SizeOf(FLineOut));
  State.Field(FSerialPhase, SizeOf(FSerialPhase));
  State.Field(FSerialDelay, SizeOf(FSerialDelay));
end;

end.

