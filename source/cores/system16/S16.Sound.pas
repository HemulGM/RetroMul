unit S16.Sound;

interface

uses
  System.SysUtils, HW.Z80, CPS1.Sound, S16.UPD7751, Core.Snapshots;

type
  TS16Sound = class
  private
    FROM, FKey, FOpcodes: TBytes;
    FA: Boolean;
    F7751: TS16UPD7751;
    FBoard, FClock: Integer;
    FCPU: TZ80State;
    FBus: TZ80ReadAndWriteCallbacks;
    FM: TCPS1Sound; // Existing native YM2151; no OKI ROM is attached.
    FRAM: array[0..$7FF] of Byte;
    FRegs: array[0..255] of Byte;
    FAddress, FStatus, FControl, FCommand, FReply: Byte;
    FPending: Boolean;
    FBusy, FTimerA, FTimerB, FBank, FYMFraction: Integer;
    FTime: Int64;
    FPCM: TArray<SmallInt>;
    FPCMCount, FPCMPhase, FUPDPhase, FSampleActivity: Integer;
    FUPDState, FUPDNext, FUPDClocks, FUPDDelay, FUPDRate: Integer;
    FUPDNibbles, FUPDStep, FUPDSample, FUPDData, FUPDFifo: Integer;
    FUPDValid, FUPDReset, FUPDMode: Boolean;
    procedure Advance(Cycles: Integer);
    procedure UPDStep;
    procedure Decode(Nibble: Integer);
  public
    Samples: TArray<SmallInt>;
    constructor Create(const ROM: TBytes; Board: Integer; const Key, Firmware, PCM: TBytes; Crypto: Integer = 0);
    destructor Destroy; override;
    procedure Reset;
    procedure Command(Value: Byte);
    procedure BeginFrame;
    procedure RunUntil(Target: Int64);
    procedure EndFrame;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Byte): Byte;
    procedure WritePort(Address, Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property SampleActivity: Integer read FSampleActivity;
    property Reply: Byte read FReply;
    property CPU: TZ80State read FCPU;
    property Clock: Integer read FClock;
  end;

implementation

uses
  System.Math, System.Classes, S16.Crypto;

function ReadZ(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TS16Sound(User).ReadMemory(Word(Address and $FFFF));
end;

function ReadOpcodeZ(User: Pointer; Address: Cardinal): Cardinal;
begin
  var Sound := TS16Sound(User);
  if (Address < $8000) and (Address < Cardinal(Length(Sound.FOpcodes))) then
    Result := Sound.FOpcodes[Address]
  else
    Result := Sound.ReadMemory(Word(Address and $FFFF));
end;

procedure WriteZ(User: Pointer; Address, Value: Cardinal);
begin
  TS16Sound(User).WriteMemory(Word(Address and $FFFF), Byte(Value and $FF));
end;

function ReadP(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TS16Sound(User).ReadPort(Byte(Address and $FF));
end;

procedure WriteP(User: Pointer; Address, Value: Cardinal);
begin
  TS16Sound(User).WritePort(Byte(Address and $FF), Byte(Value and $FF));
end;

constructor TS16Sound.Create(const ROM: TBytes; Board: Integer; const Key, Firmware, PCM: TBytes; Crypto: Integer);
begin
  inherited Create;
  FROM := ROM;
  FKey := Key;
  if Length(FKey) <> 0 then
  begin
    if Length(FKey) <> $2000 then
      raise EReadError.Create('System 16 Z80 requires its 8 KiB key ROM');
    FROM := Copy(ROM);
    FOpcodes := Copy(ROM);
    for var i := 0 to Min(Length(ROM), $8000) - 1 do
    begin
      FROM[i] := MC8123(i, ROM[i], FKey, False);
      FOpcodes[i] := MC8123(i, ROM[i], FKey, True);
    end;
  end;
  if Crypto = 5 then
  begin
    FROM := Copy(ROM);
    FOpcodes := Copy(ROM);
    for var i := 0 to Min(Length(ROM), $8000) - 1 do
    begin
      FROM[i] := Sega3155177(i, ROM[i], False);
      FOpcodes[i] := Sega3155177(i, ROM[i], True);
    end;
  end;
  FBoard := Board;
  if Length(Firmware) <> 0 then
    F7751 := TS16UPD7751.Create(Firmware, PCM);
  FA := Board = 0;
  FClock := 5000000;
  if FA then
    FClock := 4000000;
  FM := TCPS1Sound.Create(nil, 4000000);
  FBus.UserData := Self;
  FBus.ReadCallback := ReadZ;
  FBus.WriteCallback := WriteZ;
  FBus.PortReadCallback := ReadP;
  FBus.PortWriteCallback := WriteP;
  SetLength(FPCM, 2048);
  Reset;
end;

destructor TS16Sound.Destroy;
begin
  F7751.Free;
  FM.Free;
  inherited;
end;

procedure TS16Sound.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FRegs, SizeOf(FRegs), 0);
  Z80StateInitialise(FCPU);
  Z80Reset(FCPU);
  FM.Reset;
  if F7751 <> nil then
    F7751.Reset;
  FAddress := 0;
  FStatus := 0;
  FControl := 0;
  FCommand := 0;
  FReply := 0;
  FPending := False;
  FBusy := 0;
  FTimerA := 0;
  FTimerB := 0;
  FBank := $10000;
  FYMFraction := 0;
  FTime := 0;
  FPCMCount := 0;
  FPCMPhase := 0;
  FUPDPhase := 0;
  FUPDState := 0;
  FUPDNext := 0;
  FUPDClocks := 0;
  FUPDDelay := 0;
  FUPDRate := 1;
  FUPDNibbles := 0;
  FUPDStep := 0;
  FUPDSample := 0;
  FUPDData := 0;
  FUPDFifo := 0;
  FUPDValid := False;
  FUPDReset := True;
  FUPDMode := True;
end;

procedure TS16Sound.Command(Value: Byte);
begin
  FCommand := Value;
  FPending := True;
  if FA then
    Z80NonMaskableInterrupt(FCPU)
  else
    Z80Interrupt(FCPU, 1);
end;

function TS16Sound.ReadMemory(Address: Word): Byte;
begin
  if (Address < $8000) and (Address < Length(FROM)) then
    Exit(FROM[Address]);
  if not FA and (Address >= $8000) and (Address < $E000) then
  begin
    var Offset := FBank + Address - $8000;
    if Offset < Length(FROM) then
      Exit(FROM[Offset]);
  end;
  if Address = $E800 then
    Exit(ReadPort($C0));
  if Address >= $F800 then
    Exit(FRAM[Address and $7FF]);
  Result := $FF;
end;

procedure TS16Sound.WriteMemory(Address: Word; Value: Byte);
begin
  if Address >= $F800 then
    FRAM[Address and $7FF] := Value;
end;

function TS16Sound.ReadPort(Address: Byte): Byte;
begin
  case Address and $C0 of
    $00:
      begin
        Result := FStatus;
        if FBusy > 0 then
          Result := Result or $80;
      end;
    $80:
      Result := Ord(FUPDState = 0) shl 7;
    $C0:
      begin
        Result := FCommand;
        FPending := False;
        Z80Interrupt(FCPU, Ord(FA and (FStatus <> 0)));
      end;
  else
    Result := $FF;
  end;
end;

procedure TS16Sound.WritePort(Address, Value: Byte);
begin
  case Address and $C0 of
    $00:
      if Address and 1 = 0 then
        FAddress := Value
      else
      begin
        FRegs[FAddress] := Value;
        FM.WriteYM(FAddress, Value);
        if (FAddress = $1B) and (F7751 <> nil) then
          F7751.Control(Value shr 6);
        FBusy := 32;
        if FAddress = $14 then
        begin
          if Value and $10 <> 0 then
            FStatus := FStatus and $FE;
          if Value and $20 <> 0 then
            FStatus := FStatus and $FD;
          if (Value and 1 <> 0) and (FControl and 1 = 0) then
            FTimerA := 0;
          if (Value and 2 <> 0) and (FControl and 2 = 0) then
            FTimerB := 0;
          FControl := Value;
        end;
      end;
    $40:
      if not FA and (Length(FROM) > $10000) then
      begin
        // /MD falling starts slave playback. /RESET is applied afterwards.
        var Mode := Value and $80 = 0;
        if (FUPDState = 0) and FUPDReset and FUPDMode and not Mode then
        begin
          FUPDState := 1;
          FUPDClocks := 0;
        end;
        FUPDMode := Mode;
        if Value and $40 = 0 then
        begin
          FUPDState := 0;
          FUPDSample := 0;
          FUPDStep := 0;
        end;
        FUPDReset := Value and $40 <> 0;
        var Bank := 0;
        if FBoard in [1, 2] then
        begin
          for var i := 0 to 3 do
            if Value and (4 shl i) = 0 then
              Bank := i * $10000;
          Inc(Bank, (Value and 3) * $4000);
        end
        else
          Bank := ((Value and 8) shr 3) * $20000 + (Value and 7) * $4000;
        if FBoard = 5 then
          Bank := ((Value and 8) shr 3) * $40000 + ((Value and $10) shr 4) * $20000 + (Value and 7) * $4000;
        FBank := $10000 + Bank mod (Length(FROM) - $10000);
      end;
    $80:
      begin
        FUPDFifo := Value;
        if F7751 <> nil then
          F7751.Command(Value);
      end;
    $C0:
      FReply := Value;
  end;
end;

// NEC uPD7759 slave ADPCM state machine. Step values from NEC/MAME
// (Juergen Buchmueller and the MAME contributors, BSD-3-Clause).
procedure TS16Sound.Decode(Nibble: Integer);
const
  Steps: array[0..15, 0..7] of SmallInt = (
    (0, 0, 1, 2, 3, 5, 7, 10), (0, 1, 2, 3, 4, 6, 8, 13),
    (0, 1, 2, 4, 5, 7, 10, 15), (0, 1, 3, 4, 6, 9, 13, 19),
    (0, 2, 3, 5, 8, 11, 15, 23), (0, 2, 4, 7, 10, 14, 19, 29),
    (0, 3, 5, 8, 12, 16, 22, 33), (1, 4, 7, 10, 15, 20, 29, 43),
    (1, 4, 8, 13, 18, 25, 35, 53), (1, 6, 10, 16, 22, 31, 43, 64),
    (2, 7, 12, 19, 27, 37, 51, 76), (2, 9, 16, 24, 34, 46, 64, 96),
    (3, 11, 19, 29, 41, 57, 79, 117), (4, 13, 24, 36, 50, 69, 96, 143),
    (4, 16, 29, 44, 62, 85, 118, 175), (6, 20, 36, 54, 76, 104, 144, 214));
  Adjust: array[0..7] of ShortInt = (-1, -1, 0, 0, 1, 2, 2, 3);
begin
  var Delta := Integer(Steps[FUPDStep, Nibble and 7]);
  if Nibble and 8 <> 0 then
    Delta := -Delta;
  FUPDSample := EnsureRange(FUPDSample + Delta, -32768, 32767);
  FUPDStep := EnsureRange(FUPDStep + Adjust[Nibble and 7], 0, 15);
end;

procedure TS16Sound.UPDStep;
begin
  var Request := False;
  case FUPDState of
    0:
      begin
        FUPDClocks := 4;
        FUPDSample := 0;
      end;
    1:
      begin
        FUPDClocks := 70;
        FUPDState := 2;
      end;
    2:
      begin
        Request := True;
        FUPDClocks := 44;
        FUPDState := 3;
      end;
    3:
      begin
        Request := True;
        FUPDClocks := 28;
        FUPDState := 4;
        if FUPDFifo < $10 then
          FUPDState := 0;
      end;
    4:
      begin
        Request := True;
        FUPDClocks := 32;
        FUPDState := 5;
      end;
    5:
      begin
        Request := True;
        FUPDClocks := 44;
        FUPDState := 6;
      end;
    6:
      begin
        Request := True;
        FUPDClocks := 36;
        FUPDState := 7;
      end;
    7:
      begin
        Request := True;
        FUPDClocks := 36;
        FUPDState := 8;
        FUPDValid := False;
      end;
    8:
      begin
        Request := True;
        case FUPDFifo and $C0 of
          $00:
            begin
              FUPDClocks := 1024 * ((FUPDFifo and $3F) + 1);
              if (FUPDFifo = 0) and FUPDValid then
                FUPDState := 0;
              FUPDSample := 0;
              FUPDStep := 0;
            end;
          $40:
            begin
              FUPDRate := (FUPDFifo and $3F) + 1;
              FUPDNibbles := 256;
              FUPDClocks := 36;
              FUPDState := 10;
            end;
          $80:
            begin
              FUPDRate := (FUPDFifo and $3F) + 1;
              FUPDClocks := 36;
              FUPDState := 9;
            end;
          $C0:
            begin
              FUPDClocks := 36;
              FUPDState := 8;
            end;
        end;
        FUPDValid := FUPDValid or (FUPDFifo <> 0);
      end;
    9:
      begin
        FUPDNibbles := FUPDFifo + 1;
        Request := True;
        FUPDClocks := 36;
        FUPDState := 10;
      end;
    10:
      begin
        FUPDData := FUPDFifo;
        Decode(FUPDData shr 4);
        Request := True;
        FUPDClocks := FUPDRate * 4;
        Dec(FUPDNibbles);
        FUPDState := 11;
        if FUPDNibbles = 0 then
          FUPDState := 8;
      end;
    11:
      begin
        Decode(FUPDData and 15);
        FUPDClocks := FUPDRate * 4;
        Dec(FUPDNibbles);
        FUPDState := 10;
        if FUPDNibbles = 0 then
          FUPDState := 8;
      end;
    12:
      begin
        FUPDState := FUPDNext;
        FUPDClocks := FUPDDelay;
      end;
  end;
  if Request then
  begin
    FUPDNext := FUPDState;
    FUPDDelay := FUPDClocks - 21;
    FUPDState := 12;
    FUPDClocks := 21;
    Z80NonMaskableInterrupt(FCPU);
  end;
end;

procedure TS16Sound.Advance(Cycles: Integer);
begin
  Inc(FYMFraction, Cycles * 4000000 div 1000);
  var YMCycles := FYMFraction div (FClock div 1000);
  FYMFraction := FYMFraction mod (FClock div 1000);
  FBusy := Max(0, FBusy - YMCycles);
  FM.Advance(YMCycles);
  var PA := (1024 - (Integer(FRegs[$10]) * 4 + (FRegs[$11] and 3))) * 64;
  var PB := (256 - Integer(FRegs[$12])) * 1024;
  if FControl and 1 <> 0 then
  begin
    Inc(FTimerA, YMCycles);
    if FTimerA >= PA then
    begin
      FTimerA := FTimerA mod PA;
      if FControl and 4 <> 0 then
        FStatus := FStatus or 1;
      if FControl and $80 <> 0 then
        FM.CSM;
    end;
  end;
  if FControl and 2 <> 0 then
  begin
    Inc(FTimerB, YMCycles);
    if FTimerB >= PB then
    begin
      FTimerB := FTimerB mod PB;
      if FControl and 8 <> 0 then
        FStatus := FStatus or 2;
    end;
  end;
  // 16B routes YM IRQ only to the disconnected netlist input; mapper PBF
  // drives Z80 IRQ. 16A routes YM IRQ directly to the Z80.
  Z80Interrupt(FCPU, Ord((not FA and FPending) or (FA and (FStatus <> 0))));
  for var i := 1 to Cycles do
  begin
    if F7751 <> nil then
      F7751.Advance(1);
    if not FA then
    begin
      Inc(FUPDPhase, 640000);
      if FUPDPhase >= FClock then
      begin
        Dec(FUPDPhase, FClock);
        if FUPDState <> 0 then
        begin
          Dec(FUPDClocks);
          while (FUPDClocks <= 0) and (FUPDState <> 0) do
            UPDStep;
        end;
      end;
    end;
    Inc(FPCMPhase, 44100);
    if FPCMPhase >= FClock then
    begin
      Dec(FPCMPhase, FClock);
      if FPCMCount >= Length(FPCM) then
        SetLength(FPCM, FPCMCount + 2048);
      if F7751 <> nil then
        FPCM[FPCMCount] := SmallInt(F7751.Sample)
      else
        FPCM[FPCMCount] := SmallInt(EnsureRange(FUPDSample * 32, -32768, 32767));
      if FPCM[FPCMCount] <> 0 then
        Inc(FSampleActivity);
      Inc(FPCMCount);
    end;
  end;
end;

procedure TS16Sound.BeginFrame;
begin
  FM.BeginFrame;
  FPCMCount := 0;
  FSampleActivity := 0;
end;

procedure TS16Sound.RunUntil(Target: Int64);
begin
  while FTime < Target do
  begin
    var OpcodeRead: TZ80ReadCallback := nil;
    if Length(FOpcodes) <> 0 then
      OpcodeRead := ReadOpcodeZ;
    var Cycles := Z80DoInstruction(FCPU, FBus, OpcodeRead);
    if Cycles = 0 then
      raise EInvalidOpException.Create('System 16 Z80 made no progress');
    Advance(Cycles);
    Inc(FTime, Cycles);
  end;
end;

procedure TS16Sound.EndFrame;
begin
  FM.EndFrame;
  Samples := Copy(FM.Samples);
  for var i := 0 to Min(Length(Samples) div 2, FPCMCount) - 1 do
    for var Channel := 0 to 1 do
      Samples[i * 2 + Channel] := SmallInt(EnsureRange(Integer(Samples[i * 2 + Channel]) + FPCM[i], -32768, 32767));
end;

procedure TS16Sound.SerializeState(State: TStateArchive);
begin
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FReply, SizeOf(FReply));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FBusy, SizeOf(FBusy));
  State.Field(FTimerA, SizeOf(FTimerA));
  State.Field(FTimerB, SizeOf(FTimerB));
  State.Field(FBank, SizeOf(FBank));
  State.Field(FYMFraction, SizeOf(FYMFraction));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FPCMPhase, SizeOf(FPCMPhase));
  State.Field(FUPDPhase, SizeOf(FUPDPhase));
  State.Field(FUPDState, SizeOf(FUPDState));
  State.Field(FUPDNext, SizeOf(FUPDNext));
  State.Field(FUPDClocks, SizeOf(FUPDClocks));
  State.Field(FUPDDelay, SizeOf(FUPDDelay));
  State.Field(FUPDRate, SizeOf(FUPDRate));
  State.Field(FUPDNibbles, SizeOf(FUPDNibbles));
  State.Field(FUPDStep, SizeOf(FUPDStep));
  State.Field(FUPDSample, SizeOf(FUPDSample));
  State.Field(FUPDData, SizeOf(FUPDData));
  State.Field(FUPDFifo, SizeOf(FUPDFifo));
  State.Field(FUPDValid, SizeOf(FUPDValid));
  State.Field(FUPDReset, SizeOf(FUPDReset));
  State.Field(FUPDMode, SizeOf(FUPDMode));
  FM.SerializeState(State);
  if F7751 <> nil then
    F7751.SerializeState(State);
  if (FTime < 0) or (FUPDStep < 0) or (FUPDStep > 15) or
    (FUPDState < 0) or (FUPDState > 12) or (FBank < 0) then
    raise EReadError.Create('Invalid System 16 sound state');
end;

initialization
  HW.Z80.ConstantInitialise;

end.

