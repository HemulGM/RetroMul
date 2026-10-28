unit CPS1.Console;

interface

uses
  System.SysUtils, System.Classes, HW.M68k, HW.Z80, CPS.Cartridge, CPS.RomSets,
  CPS.Video, Core.Emulation.Types, Core.Snapshots, CPS1.Sound;

type
  TCPS1Console = class
  protected
    FCart: TCPSCartridge;
    FSound: TCPS1Sound;
    FProgram, FAudio: TBytes;
    FCPU: TM68kState;
    FBus: TM68kReadWriteCallbacks;
    FZ80: TZ80State;
    FZBus: TZ80ReadAndWriteCallbacks;
    FRAM: array[0..$FFFF] of Byte;
    FZRAM: array[0..$7FF] of Byte;
    FCommand, FFade, FBank: Byte;
    FInput: TEmulatorInput;
    FCoins: array[0..1] of Integer;
    FTime, FZTime, FFrameNumber: Int64;
    FYMAddress, FYMStatus, FYMControl: Byte;
    FYMRegs: array[0..255] of Byte;
    FTimerA, FTimerB: Int64;
    FYMBusy: Integer;
    FClock, FZClock: Integer;
    FProgramRead: TMemoryReadCallback;
    FZProgramRead: TZ80ReadCallback;
    FZHoldInterrupt: Boolean;
    FSoundEnabled: Boolean;
    FNextIRQ: Int64;
    procedure BeginScanline(Line: Integer); virtual;
    procedure TriggerRaster; virtual;
    procedure BeginAudio; virtual;
    function GetSamples: TArray<SmallInt>; virtual;
    function ReadZ(Address: Word): Byte; virtual;
    procedure WriteZ(Address: Word; Value: Byte); virtual;
    procedure AdvanceSound(Cycles: Integer); virtual;
    procedure FinishFrame; virtual;
    function Pad(const Buttons: TEmulatorButtons): Byte;
    function ExtraPad(const Buttons: TEmulatorButtons): Byte;
  public
    Video: TCPSVideo;
    DIP: array[0..2] of Byte;
    constructor Create(Cart: TCPSCartridge);
    destructor Destroy; override;
    procedure SerializeState(State: TStateArchive); virtual;
    function Battery: TBytes; virtual;
    procedure LoadBattery(const Data: TBytes); virtual;
    procedure Reset; virtual;
    procedure RunFrame;
    function ReadWord(Address: Cardinal): Word; virtual;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True); virtual;
    procedure SetInput(const Input: TEmulatorInput);
    procedure InsertCoin(Player: Integer);
    property CPU: TM68kState read FCPU;
    property SoundCPU: TZ80State read FZ80;
    property FrameNumber: Int64 read FFrameNumber;
    property Samples: TArray<SmallInt> read GetSamples;
  end;

implementation

uses
  CPS.Wiring;

function BusRead(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte): Cardinal;
begin
  Result := TCPS1Console(User).ReadWord(Address shl 1);
end;

procedure BusWrite(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte; Value: Cardinal);
begin
  TCPS1Console(User).WriteWord(Address shl 1, Word(Value and $FFFF), HighByte <> 0, LowByte <> 0);
end;

procedure IRQDone(User: Pointer);
begin
  Clown68000Interrupt(TCPS1Console(User).FCPU, 0);
end;

function ZRead(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TCPS1Console(User).ReadZ(Word(Address and $FFFF));
end;

procedure ZWrite(User: Pointer; Address, Value: Cardinal);
begin
  TCPS1Console(User).WriteZ(Word(Address and $FFFF), Byte(Value and $FF));
end;

function ZPortRead(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := $FF;
end;

procedure ZPortWrite(User: Pointer; Address, Value: Cardinal);
begin
end;

constructor TCPS1Console.Create(Cart: TCPSCartridge);
begin
  inherited Create;
  if not (Cart.RomSet.Generation in [TCPSGeneration.CPS1, TCPSGeneration.CPS2]) then
    raise EArgumentException.Create('CPS 68000 console requires a CPS1 or CPS2 set');

  FCart := Cart;
  FProgram := CPSProgram(Cart);
  FAudio := Cart['audiocpu'];
  FSound := TCPS1Sound.Create(Cart['oki']);
  FBus.UserData := Self;
  FBus.ReadCallback := BusRead;
  FBus.WriteCallback := BusWrite;
  FBus.InterruptAcknowledgeCallback := IRQDone;
  FZBus.UserData := Self;
  FZBus.ReadCallback := ZRead;
  FZBus.WriteCallback := ZWrite;
  FZBus.PortReadCallback := ZPortRead;
  FZBus.PortWriteCallback := ZPortWrite;
  Video := TCPSVideo.Create(CPSGraphics(Cart), Cart.RomSet.Board, Cart.RomSet.Generation = TCPSGeneration.CPS2);
  Video.SetStars(Cart['stars']);
  FClock := 10000000;
  FZClock := 3579545;
  if Cart.RomSet.Clock <> 0 then
    FClock := Cart.RomSet.Clock;
  for var i := 0 to 2 do
    DIP[i] := Cart.RomSet.DIPs[i];
  Reset;
end;

destructor TCPS1Console.Destroy;
begin
  FSound.Free;
  Video.Free;
  inherited;
end;

procedure TCPS1Console.Reset;
begin
  FSound.Reset;
  FCPU := Default(TM68kState);
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FZRAM, SizeOf(FZRAM), 0);
  FillChar(FYMRegs, SizeOf(FYMRegs), 0);
  FTime := 0;
  FZTime := 0;
  FFrameNumber := 0;
  FNextIRQ := High(Int64);
  FTimerA := 0;
  FTimerB := 0;
  FYMStatus := 0;
  FYMControl := 0;
  FYMAddress := 0;
  FYMBusy := 0;
  FCoins[0] := 0;
  FCoins[1] := 0;
  FCommand := 0;
  FFade := 0;
  FBank := 0;
  FSoundEnabled := True;
  Video.Reset;
  Z80StateInitialise(FZ80);
  Z80Reset(FZ80);
  Clown68000Reset(FCPU, FBus, FProgramRead);
end;

function TCPS1Console.Pad(const Buttons: TEmulatorButtons): Byte;
const
  Order: array[0..6] of TEmulatorButton = (TEmulatorButton.Right,
    TEmulatorButton.Left, TEmulatorButton.Down, TEmulatorButton.Up,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C);
begin
  Result := $FF;
  for var i := 0 to High(Order) do
    if Order[i] in Buttons then
      Result := Result and Byte($FF xor (1 shl i));
  if (FCart.RomSet.Inputs = 'cworld2j') or (FCart.RomSet.Inputs = 'qad') or
    (FCart.RomSet.Inputs = 'qadjr') or (FCart.RomSet.Inputs = 'qtono2j') or
    FCart.RomSet.Inputs.EndsWith('4b') or (FCart.RomSet.Inputs = 'sfzch') then
    if TEmulatorButton.X in Buttons then
      Result := Result and $7F;
end;

function TCPS1Console.ExtraPad(const Buttons: TEmulatorButtons): Byte;
begin
  Result := Pad(Buttons) or $C0;
  if TEmulatorButton.Select in Buttons then
    Result := Result and $BF;
  if TEmulatorButton.Start in Buttons then
    Result := Result and $7F;
end;

function TCPS1Console.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  if Address < Cardinal(Length(FProgram) - 1) then
    Exit((Word(FProgram[Address]) shl 8) or FProgram[Address + 1]);

  if Address >= $FF0000 then
    Exit((Word(FRAM[Address and $FFFF]) shl 8) or FRAM[(Address + 1) and $FFFF]);

  if (Address >= $900000) and (Address < $930000) then
    Exit(Video.RAM[(Address - $900000) div 2]);

  if (FCart.RomSet.Board.Input2 <> 0) and (Address = $800140 + Cardinal(FCart.RomSet.Board.Input2)) then
    if not FCart.RomSet.Inputs.StartsWith('sf2') then
      Exit(ExtraPad(FInput.Buttons3));

  if (FCart.RomSet.Board.Input3 <> 0) and (Address = $800140 + Cardinal(FCart.RomSet.Board.Input3)) then
    Exit(ExtraPad(FInput.Buttons4));

  if (Address >= $800000) and (Address <= $800006) then
    Exit((Word(Pad(FInput.Buttons2)) shl 8) or Pad(FInput.Buttons));

  if (Address >= $800018) and (Address <= $80001E) then
  begin
    var Index := Integer((Address - $800018) div 2);
    var Value: Byte := $FF;
    if Index > 0 then
      Value := DIP[Index - 1]
    else
    begin
      if FCart.RomSet.Inputs = 'sfzch' then
      begin
        if TEmulatorButton.Y in FInput.Buttons then
          Value := Value and $FE;
        if TEmulatorButton.Y in FInput.Buttons2 then
          Value := Value and $FD;
        if TEmulatorButton.Select in FInput.Buttons then
          Value := Value and $FB;
        if TEmulatorButton.Select in FInput.Buttons2 then
          Value := Value and $F7;
        if TEmulatorButton.Start in FInput.Buttons then
          Value := Value and $EF;
        if TEmulatorButton.Start in FInput.Buttons2 then
          Value := Value and $DF;
        if TEmulatorButton.Z in FInput.Buttons then
          Value := Value and $BF;
        if TEmulatorButton.Z in FInput.Buttons2 then
          Value := Value and $7F;
        Exit((Word(Value) shl 8) or $FF);
      end;

      if (FCoins[0] > 0) or (TEmulatorButton.Select in FInput.Buttons) then
        Value := Value and $FE;
      if (FCoins[1] > 0) or (TEmulatorButton.Select in FInput.Buttons2) then
        Value := Value and $FD;
      if TEmulatorButton.Start in FInput.Buttons then
        Value := Value and $EF;
      if TEmulatorButton.Start in FInput.Buttons2 then
        Value := Value and $DF;
      if TEmulatorButton.Mode in FInput.Buttons then
        Value := Value and $BF;
    end;
    Exit((Word(Value) shl 8) or $FF);
  end;

  // SF2 kick harness is on the B-board I/O register.
  if Address = $800176 then
  begin
    Result := $FFFF;
    if TEmulatorButton.X in FInput.Buttons then
      Result := Result and $FFFE;
    if TEmulatorButton.Y in FInput.Buttons then
      Result := Result and $FFFD;
    if TEmulatorButton.Z in FInput.Buttons then
      Result := Result and $FFFB;
    if TEmulatorButton.X in FInput.Buttons2 then
      Result := Result and $FEFF;
    if TEmulatorButton.Y in FInput.Buttons2 then
      Result := Result and $FDFF;
    if TEmulatorButton.Z in FInput.Buttons2 then
      Result := Result and $FBFF;
    Exit;
  end;

  if (Address >= $800140) and (Address < $800180) then
    Exit(Video.ReadB(Address - $800140));

  Result := $FFFF;
end;

procedure TCPS1Console.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);

  function Merge(Old: Word): Word;
  begin
    Result := Old;
    if HighByte then
      Result := (Result and $FF) or (Value and $FF00);
    if LowByte then
      Result := (Result and $FF00) or (Value and $FF);
  end;

begin
  Address := Address and $FFFFFE;
  if Address >= $FF0000 then
  begin
    if HighByte then
      FRAM[Address and $FFFF] := Byte(Value shr 8);
    if LowByte then
      FRAM[(Address + 1) and $FFFF] := Byte(Value and $FF);
  end
  else if (Address >= $900000) and (Address < $930000) then
    Video.RAM[(Address - $900000) div 2] := Merge(Video.RAM[(Address - $900000) div 2])
  else if (Address >= $800100) and (Address < $800140) then
  begin
    var Index := (Address - $800100) div 2;
    Video.A[Index] := Merge(Video.A[Index]);
    if Index = 5 then
      Video.PaletteDMA;
  end
  else if (Address >= $800140) and (Address < $800180) then
    Video.B[(Address - $800140) div 2] := Merge(Video.B[(Address - $800140) div 2])
  else if (Address >= $800180) and (Address < $800188) then
  begin
    if LowByte then
      FCommand := Byte(Value and $FF)
    else if HighByte then
      FCommand := Byte(Value shr 8);
  end
  else if (Address >= $800188) and (Address < $800190) and LowByte then
    FFade := Byte(Value and $FF);
end;

function TCPS1Console.ReadZ(Address: Word): Byte;
begin
  if Address < $8000 then
    Exit(FAudio[Address]);

  if Address < $C000 then
  begin
    var Index := $10000 + Integer(FBank and 1) * $4000 + (Address and $3FFF);
    if Index < Length(FAudio) then
      Exit(FAudio[Index]);
    Exit($FF);
  end;

  if (Address >= $D000) and (Address < $D800) then
    Exit(FZRAM[Address and $7FF]);

  case Address of
    $F001:
      begin
        Result := FYMStatus;
        if FYMBusy > 0 then
          Result := Result or $80;
        Exit;
      end;
    $F002:
      Exit(FSound.OKIStatus);
    $F008:
      Exit(FCommand);
    $F00A:
      Exit(FFade);
  end;
  Result := $FF;
end;

procedure TCPS1Console.WriteZ(Address: Word; Value: Byte);
begin
  if (Address >= $D000) and (Address < $D800) then
    FZRAM[Address and $7FF] := Value;
  case Address of
    $F000:
      FYMAddress := Value;
    $F001:
      begin
        FYMRegs[FYMAddress] := Value;
        FSound.WriteYM(FYMAddress, Value);
        FYMBusy := 32;
        if FYMAddress = $14 then
        begin
          if Value and $10 <> 0 then
            FYMStatus := FYMStatus and $FE;
          if Value and $20 <> 0 then
            FYMStatus := FYMStatus and $FD;
          if (Value and 1 <> 0) and (FYMControl and 1 = 0) then
            FTimerA := 0;
          if (Value and 2 <> 0) and (FYMControl and 2 = 0) then
            FTimerB := 0;
          FYMControl := Value;
        end;
      end;
    $F002:
      FSound.WriteOKI(Value);
    $F004:
      FBank := Value;
    $F006:
      FSound.SetPin7(Value and 1 <> 0);
  end;
end;

procedure TCPS1Console.AdvanceSound(Cycles: Integer);
begin
  if FYMBusy > Cycles then
    Dec(FYMBusy, Cycles)
  else
    FYMBusy := 0;
  FSound.Advance(Cycles);
  var PeriodA := (1024 - (Integer(FYMRegs[$10]) * 4 + (FYMRegs[$11] and 3))) * 64;
  var PeriodB := (256 - Integer(FYMRegs[$12])) * 1024;
  if FYMControl and 1 <> 0 then
  begin
    Inc(FTimerA, Cycles);
    if FTimerA >= PeriodA then
    begin
      FTimerA := FTimerA mod PeriodA;
      if FYMControl and 4 <> 0 then
        FYMStatus := FYMStatus or 1;
      if FYMControl and $80 <> 0 then
        FSound.CSM;
    end;
  end;
  if FYMControl and 2 <> 0 then
  begin
    Inc(FTimerB, Cycles);
    if FTimerB >= PeriodB then
    begin
      FTimerB := FTimerB mod PeriodB;
      if FYMControl and 8 <> 0 then
        FYMStatus := FYMStatus or 2;
    end;
  end;
  Z80Interrupt(FZ80, Ord(FYMStatus <> 0));
end;

procedure TCPS1Console.RunFrame;
begin
  BeginAudio;
  for var Line := 0 to 261 do
  begin
    var Target := ((FFrameNumber * 262 + Line + 1) * Int64(FClock) * 512) div 8000000;
    BeginScanline(Line);
    while FTime < Target do
    begin
      if FTime >= FNextIRQ then
        TriggerRaster;
      Inc(FTime, Clown68000DoCycles(FCPU, FBus, 1, -1, FProgramRead));
      if FCPU.Halted <> 0 then
        raise EInvalidOpException.CreateFmt('CPS1 68000 halted at %.6x', [FCPU.ProgramCounter]);
    end;

    var ZTarget := Target * FZClock div FClock;
    if not FSoundEnabled then
    begin
      AdvanceSound(ZTarget - FZTime);
      FZTime := ZTarget;
    end;
    while FZTime < ZTarget do
    begin
      var Cycles := Z80DoInstruction(FZ80, FZBus, FZProgramRead, FZHoldInterrupt);
      if Cycles = 0 then
        raise EInvalidOpException.Create('CPS1 Z80 made no progress');

      AdvanceSound(Cycles);
      Inc(FZTime, Cycles);
    end;
  end;
  FinishFrame;
  Inc(FFrameNumber);
  for var i := 0 to 1 do
    if FCoins[i] > 0 then
      Dec(FCoins[i]);
end;

procedure TCPS1Console.FinishFrame;
begin
  FSound.EndFrame;
  Video.Render;
  Video.LatchObjects;
end;

procedure TCPS1Console.BeginAudio;
begin
  FSound.BeginFrame;
end;

procedure TCPS1Console.BeginScanline(Line: Integer);
begin
  if Line = 240 then
    Clown68000Interrupt(FCPU, FCPU.PendingInterrupt or 2);
end;

procedure TCPS1Console.TriggerRaster;
begin
  FNextIRQ := High(Int64);
end;

function TCPS1Console.GetSamples: TArray<SmallInt>;
begin
  Result := FSound.Samples;
end;

procedure TCPS1Console.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

procedure TCPS1Console.InsertCoin(Player: Integer);
begin
  if (Player < 1) or (Player > 2) then
    raise EArgumentOutOfRangeException.Create('CPS coin player');

  FCoins[Player - 1] := 3;
end;

procedure TCPS1Console.SerializeState(State: TStateArchive);
begin
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FZ80, SizeOf(FZ80));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FZRAM, SizeOf(FZRAM));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FFade, SizeOf(FFade));
  State.Field(FBank, SizeOf(FBank));
  State.Field(FInput, SizeOf(FInput));
  State.Field(FCoins, SizeOf(FCoins));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FNextIRQ, SizeOf(FNextIRQ));
  State.Field(FZTime, SizeOf(FZTime));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FYMAddress, SizeOf(FYMAddress));
  State.Field(FYMStatus, SizeOf(FYMStatus));
  State.Field(FYMControl, SizeOf(FYMControl));
  State.Field(FYMRegs, SizeOf(FYMRegs));
  State.Field(FTimerA, SizeOf(FTimerA));
  State.Field(FYMBusy, SizeOf(FYMBusy));
  State.Field(FTimerB, SizeOf(FTimerB));
  State.Field(FSoundEnabled, SizeOf(FSoundEnabled));
  State.Field(DIP, SizeOf(DIP));
  Video.SerializeState(State);
  FSound.SerializeState(State);
  if (FTime < 0) or (FZTime < 0) or (FFrameNumber < 0) then
    raise EReadError.Create('Invalid CPS clock state');
end;

function TCPS1Console.Battery: TBytes;
begin
  Result := nil;
end;

procedure TCPS1Console.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> 0 then
    raise EReadError.Create('Unexpected CPS1 battery data');
end;

initialization
  HW.Z80.ConstantInitialise;

end.

