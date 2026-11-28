unit SegaArcade.Console;

interface

uses
  System.SysUtils, System.Generics.Collections, HW.M68k, HW.I8751,
  SegaArcade.Cartridge, SegaArcade.Video, Core.Emulation.Types, Core.Snapshots;

type
  TSegaArcadeConsole = class abstract
  protected
    FCart: TSegaArcadeCartridge;
    FProgram, FKey: TBytes;
    FCryptoState: Byte;
    FCryptoIRQ, FResetting: Boolean;
    FIRQSerial: Cardinal;
    FOpcodeRead: TMemoryReadCallback;
    FOpcodeCache: TDictionary<UInt64, Word>;
    FMCU: TI8751;
    FMCUControl: Byte;
    FMainReset, FResetPending: Boolean;
    FMainPauseUntil: Int64;
    FCPU: TM68kState;
    FBus: TM68kReadWriteCallbacks;
    FRAM: array[0..$1FFF] of Word;
    FMapper: array[0..$1F] of Byte;
    FPPI: array[0..3] of Byte;
    FInput: TEmulatorInput;
    FCoins: array[0..1] of Integer;
    FTime, FFrameNumber: Int64;
    function CreateVideo: TSegaArcadeVideo; virtual; abstract;
    procedure CreateAudio; virtual; abstract;
    procedure ResetAudio; virtual; abstract;
    procedure CommandAudio(Value: Byte); virtual; abstract;
    function ReplyAudio: Byte; virtual; abstract;
    procedure BeginAudioFrame; virtual; abstract;
    procedure EndAudioFrame; virtual; abstract;
    procedure RunAudio; virtual; abstract;
    procedure SerializeAudio(State: TStateArchive); virtual; abstract;
    function ReadAchievementSoundRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal; virtual; abstract;
    function UsesMapper: Boolean; virtual;
    function HasMCU: Boolean; virtual;
    procedure VerticalBlank; virtual;
    procedure SerializeBoardState(State: TStateArchive); virtual; abstract;
    procedure StartScanline(Line: Integer); virtual;
    procedure EndScanline(Line: Integer); virtual;
    function HasNVRAM: Boolean; virtual; abstract;
    function LineDeadline(Line: Integer): Int64; virtual; abstract;
    function ExtraRead(Region: Integer; Offset: Cardinal): Word; virtual;
    procedure ExtraWrite(Region: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean); virtual;
    procedure WriteROM(Address, Offset: Cardinal; Value: Byte); virtual;
    function MCURead(Address: Word): Byte; virtual;
    procedure MCUWrite(Address: Word; Value: Byte); virtual;
    function MCUPortRead(Port: Byte): Byte; virtual;
    procedure MCUPortWrite(Port, Value: Byte); virtual;
    procedure SetMainReset(Asserted: Boolean);
    procedure ResetMainCPU;
    function DecodeAddress(Address: Cardinal; out Offset: Cardinal): Integer; virtual; abstract;
    function ReadOpcode(Address: Cardinal): Word;
    function ReadIO(Offset: Cardinal): Word; virtual; abstract;
    procedure WriteIO(Offset: Cardinal; Value: Byte); virtual; abstract;
    procedure WriteMapper(Index, Value: Byte);
    function Pad(const Buttons: TEmulatorButtons): Byte;
  public
    Video: TSegaArcadeVideo;
    DIP: array[0..1] of Byte; // SW1 coinage, SW2 game options.
    constructor Create(Cart: TSegaArcadeCartridge); virtual;
    destructor Destroy; override;
    procedure Reset; virtual;
    procedure RunFrame;
    function ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
    function AudioSamples: TArray<SmallInt>; virtual; abstract;
    function FrameRate: Double; virtual; abstract;
    function ReadWord(Address: Cardinal): Word;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True);
    procedure SetInput(const Input: TEmulatorInput);
    procedure AddPointerMotion(DX, DY: Integer); virtual;
    procedure InsertCoin(Player: Integer);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure SerializeState(State: TStateArchive); virtual;
    property CPU: TM68kState read FCPU;
    property MCU: TI8751 read FMCU;
    property FrameNumber: Int64 read FFrameNumber;
  end;

  TSegaArcadeConsoleClass = class of TSegaArcadeConsole;

implementation

uses
  System.Classes, HW.SegaCrypto;

function BusRead(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte): Cardinal;
begin
  Result := TSegaArcadeConsole(User).ReadWord(Address shl 1);
end;

function OpcodeRead(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte): Cardinal;
begin
  Result := TSegaArcadeConsole(User).ReadOpcode(Address shl 1);
end;

procedure BusWrite(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte; Value: Cardinal);
begin
  TSegaArcadeConsole(User).WriteWord(Address shl 1, Word(Value and $FFFF), HighByte <> 0, LowByte <> 0);
end;

procedure IRQDone(User: Pointer);
begin
  var Console := TSegaArcadeConsole(User);
  if Console.FCart.RomSet.Crypto = 3 then
  begin
    Console.FCryptoIRQ := True;
    Inc(Console.FIRQSerial);
  end;
  if (Console.FMCU = nil) or (Console.UsesMapper) then
    Clown68000Interrupt(Console.FCPU, 0);
end;

constructor TSegaArcadeConsole.Create(Cart: TSegaArcadeCartridge);
begin
  inherited Create;
  FCart := Cart;
  FProgram := Cart['maincpu'];
  FKey := Cart['maincpu:key'];
  FOpcodeCache := TDictionary<UInt64, Word>.Create;
  if Cart.RomSet.Crypto in [1, 2, 3] then
  begin
    if Length(FKey) <> $2000 then
      raise EReadError.Create('The FD1089/FD1094 CPU requires its 8 KiB key ROM');
    FOpcodeRead := OpcodeRead;
  end;
  FBus.UserData := Self;
  FBus.ReadCallback := BusRead;
  FBus.WriteCallback := BusWrite;
  FBus.InterruptAcknowledgeCallback := IRQDone;
  Video := CreateVideo;
  CreateAudio;
  if HasMCU then
  begin
    FMCU := TI8751.Create(Cart['mcu']);
    FMCU.ReadExternal := MCURead;
    FMCU.WriteExternal := MCUWrite;
    FMCU.ReadPort := MCUPortRead;
    FMCU.WritePort := MCUPortWrite;
  end;
  for var I := 0 to 1 do
    DIP[I] := Cart.RomSet.DIPs[I];
  Reset;
end;

destructor TSegaArcadeConsole.Destroy;
begin
  FMCU.Free;
  FOpcodeCache.Free;
  Video.Free;
  inherited;
end;

procedure TSegaArcadeConsole.StartScanline(Line: Integer);
begin
end;

procedure TSegaArcadeConsole.EndScanline(Line: Integer);
begin
end;

function TSegaArcadeConsole.ExtraRead(Region: Integer; Offset: Cardinal): Word;
begin
  Result := $FFFF;
end;

procedure TSegaArcadeConsole.ExtraWrite(Region: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
end;

procedure TSegaArcadeConsole.WriteROM(Address, Offset: Cardinal; Value: Byte);
begin
end;

procedure TSegaArcadeConsole.Reset;
begin
  FCPU := Default(TM68kState);
  if not HasNVRAM then
    FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FMapper, SizeOf(FMapper), 0);
  FillChar(FPPI, SizeOf(FPPI), 0);
  FillChar(FCoins, SizeOf(FCoins), 0);
  FMainReset := False;
  FResetPending := False;
  FMainPauseUntil := 0;
  FMCUControl := 0;
  if FMCU <> nil then
    FMCU.Reset;
  FTime := 0;
  FFrameNumber := 0;
  Video.Reset;
  ResetAudio;
  ResetMainCPU;
end;

procedure TSegaArcadeConsole.ResetMainCPU;
begin
  FCryptoState := 0;
  FCryptoIRQ := False;
  FIRQSerial := 0;
  FOpcodeCache.Clear;
  FResetting := True;
  try
    Clown68000Reset(FCPU, FBus, FOpcodeRead);
  finally
    FResetting := False;
  end;
end;

function TSegaArcadeConsole.Pad(const Buttons: TEmulatorButtons): Byte;
const
  Order: array[0..7] of TEmulatorButton = (TEmulatorButton.C, TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.X, TEmulatorButton.Down,
    TEmulatorButton.Up, TEmulatorButton.Right, TEmulatorButton.Left);
begin
  Result := $FF;
  for var I := 0 to 7 do
    if Order[I] in Buttons then
      Result := Result and Byte($FF xor (1 shl I));
end;

procedure TSegaArcadeConsole.SetMainReset(Asserted: Boolean);
begin
  if Asserted and not FMainReset then
    FResetPending := True;
  FMainReset := Asserted;
end;

function TSegaArcadeConsole.UsesMapper: Boolean;
begin
  Result := True;
end;

function TSegaArcadeConsole.HasMCU: Boolean;
begin
  Result := FCart.RomSet.MCU;
end;

procedure TSegaArcadeConsole.VerticalBlank;
begin
  if FMCU = nil then
    Clown68000Interrupt(FCPU, 4)
  else
    FMCU.SetIRQ(0, True);
end;

function TSegaArcadeConsole.MCURead(Address: Word): Byte;
begin
  case Address and $FF of
    0, 1:
      Exit(FMapper[Address and 1]);
    2:
      if FMainReset then
        Exit(0)
      else
        Exit($0F);
    3:
      Exit(ReplyAudio);
  end;
  Result := $FF;
end;

procedure TSegaArcadeConsole.MCUWrite(Address: Word; Value: Byte);
begin
  if Address and $FF < $20 then
    WriteMapper(Byte(Address and $1F), Value);
end;

function TSegaArcadeConsole.MCUPortRead(Port: Byte): Byte;
begin
  Result := $FF;
end;

procedure TSegaArcadeConsole.MCUPortWrite(Port, Value: Byte);
begin
end;

procedure TSegaArcadeConsole.WriteMapper(Index, Value: Byte);
begin
  FMapper[Index] := Value;
  case Index of
    2:
      SetMainReset(Value and 3 = 3);
    3:
      CommandAudio(Value);
    4:
      if Value and 7 <> 7 then
        Clown68000Interrupt(FCPU, (not Value) and 7);
    5:
      case Value of
        1:
          WriteWord((Cardinal(FMapper[$A]) shl 17) or (Cardinal(FMapper[$B]) shl 9) or
            (Cardinal(FMapper[$C]) shl 1), (Word(FMapper[0]) shl 8) or FMapper[1]);
        2:
          begin
            var Data := ReadWord((Cardinal(FMapper[7]) shl 17) or
              (Cardinal(FMapper[8]) shl 9) or (Cardinal(FMapper[9]) shl 1));
            FMapper[0] := Byte(Data shr 8);
            FMapper[1] := Byte(Data and $FF);
          end;
      end;
  end;
end;

function TSegaArcadeConsole.ReadOpcode(Address: Cardinal): Word;
begin
  var Offset: Cardinal;
  if DecodeAddress(Address and $FFFFFE, Offset) <> 0 then
    Exit(ReadWord(Address));
  var State := FCryptoState;
  if FCryptoIRQ then
    State := FKey[0];
  var CacheKey := (UInt64(State) shl 48) or (UInt64(Address and $FFFFFF) shl 24) or Offset;
  if FResetting then
    CacheKey := CacheKey or (UInt64(1) shl 63);
  if FOpcodeCache.TryGetValue(CacheKey, Result) then
    Exit;
  var Value := (Word(FProgram[Offset]) shl 8) or FProgram[Offset + 1];
  case FCart.RomSet.Crypto of
    1, 2:
      Result := FD1089(Address, Value, FKey, True, FCart.RomSet.Crypto = 2);
    3:
      Result := FD1094(Address shr 1, Value, FKey, State, FResetting and (Address < 8));
  else
    Result := Value;
  end;
  FOpcodeCache.Add(CacheKey, Result);
end;

function TSegaArcadeConsole.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  var Offset: Cardinal;
  var Region := DecodeAddress(Address, Offset);
  case Region of
    0:
      begin
        Result := (Word(FProgram[Offset]) shl 8) or FProgram[Offset + 1];
        if FCart.RomSet.Crypto in [1, 2] then
          Result := FD1089(Address, Result, FKey, False, FCart.RomSet.Crypto = 2);
        Exit;
      end;
    3:
      Exit(FRAM[(Offset shr 1) and $1FFF]);
    4:
      Exit(Video.SpriteRAM[Offset shr 1]);
    5:
      Exit(Video.TileRAM[Offset shr 1]);
    6:
      Exit(Video.PaletteRAM[Offset shr 1]);
    7:
      Exit(ReadIO(Offset));
    8:
      Exit(Video.TextRAM[Offset shr 1]);
    9..15:
      Exit(ExtraRead(Region, Offset));
  end;
  Result := $FFFF;
  if UsesMapper then
    case (Address shr 1) and $1F of
      0, 1:
        Result := $FF00 or FMapper[(Address shr 1) and 1];
      2:
        if FMainReset then
          Result := $FF00
        else
          Result := $FF0F;
      3:
        Result := $FF00 or ReplyAudio;
    end;
end;

procedure TSegaArcadeConsole.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);

  procedure Merge(var Dest: Word);
  begin
    if HighByte then
      Dest := (Dest and $FF) or (Value and $FF00);
    if LowByte then
      Dest := (Dest and $FF00) or (Value and $FF);
  end;

begin
  Address := Address and $FFFFFE;
  var Offset: Cardinal;
  var Region := DecodeAddress(Address, Offset);
  case Region of
    0:
      begin
        if LowByte then
          WriteROM(Address, Offset, Byte(Value and $FF));
        Exit;
      end;
    3:
      begin
        Merge(FRAM[(Offset shr 1) and $1FFF]);
        Exit;
      end;
    4:
      begin
        Merge(Video.SpriteRAM[Offset shr 1]);
        Exit;
      end;
    5:
      begin
        Merge(Video.TileRAM[Offset shr 1]);
        Exit;
      end;
    6:
      begin
        Merge(Video.PaletteRAM[Offset shr 1]);
        Exit;
      end;
    7:
      begin
        if LowByte then
          WriteIO(Offset, Byte(Value and $FF));
        Exit;
      end;
    8:
      begin
        Merge(Video.TextRAM[Offset shr 1]);
        Exit;
      end;
    9..15:
      begin
        ExtraWrite(Region, Offset, Value, HighByte, LowByte);
        Exit;
      end;
  end;
  if LowByte and (UsesMapper) then
    WriteMapper(Byte((Address shr 1) and $1F), Byte(Value and $FF));
end;

procedure TSegaArcadeConsole.RunFrame;
begin
  BeginAudioFrame;
  for var Line := 0 to 261 do
  begin
    StartScanline(Line);
    if Line = 224 then
    begin
      Video.Render;
      VerticalBlank;
    end;
    if Line = 261 then
      Video.Latch;
    if (Line = 0) and (FMCU <> nil) then
      FMCU.SetIRQ(0, False);
    var Target := LineDeadline(Line);
    while FTime < Target do
    begin
      if FMCU <> nil then
        while FMCU.Cycles * 15 <= FTime do
          FMCU.Step;
      if FResetPending and not FMainReset then
      begin
        ResetMainCPU;
        FResetPending := False;
      end;
      var Cycles: Cardinal;
      if FMainReset or (FTime < FMainPauseUntil) then
        Cycles := 16
      else if FCart.RomSet.Crypto = 3 then
      begin
        var PC := FCPU.ProgramCounter;
        var Opcode := ReadOpcode(PC);
        var Command := -1;
        if (FCPU.Stopped = 0) and (Opcode = $0C80) and (ReadOpcode(PC + 4) = $FFFF) then
          Command := ReadOpcode(PC + 2);
        var Serial := FIRQSerial;
        Cycles := Clown68000DoCycles(FCPU, FBus, 1, -1, FOpcodeRead);
        if Command >= 0 then
          case Command and $300 of
            $000:
              FCryptoState := Byte(Command and $FF);
            $100:
              begin
                FCryptoState := Byte(Command and $FF);
                FCryptoIRQ := False;
              end;
            $200:
              FCryptoIRQ := True;
            $300:
              FCryptoIRQ := False;
          end;
        if (Opcode = $4E73) and (Serial = FIRQSerial) then
          FCryptoIRQ := False;
      end
      else
        Cycles := Clown68000DoCycles(FCPU, FBus, 32, -1, FOpcodeRead);
      if (Cycles = 0) or (FCPU.Halted <> 0) then
        raise EInvalidOpException.CreateFmt('68000 halted at %.6x', [FCPU.ProgramCounter]);
      Inc(FTime, Cycles);
      RunAudio;
    end;
    EndScanline(Line);
  end;
  EndAudioFrame;
  Inc(FFrameNumber);
  for var I := 0 to 1 do
    if FCoins[I] > 0 then
      Dec(FCoins[I]);
end;

procedure TSegaArcadeConsole.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

procedure TSegaArcadeConsole.AddPointerMotion(DX, DY: Integer);
begin
end;

procedure TSegaArcadeConsole.InsertCoin(Player: Integer);
begin
  if not (Player in [1, 2]) then
    raise EArgumentOutOfRangeException.Create('Arcade coin player');
  FCoins[Player - 1] := 3;
end;

function TSegaArcadeConsole.Battery: TBytes;
begin
  Result := nil;
  if not HasNVRAM then
    Exit;
  SetLength(Result, SizeOf(FRAM));
  Move(FRAM, Result[0], SizeOf(FRAM));
end;

procedure TSegaArcadeConsole.LoadBattery(const Data: TBytes);
begin
  if (not HasNVRAM) or (Length(Data) <> SizeOf(FRAM)) then
    raise EReadError.Create('Invalid arcade NVRAM size');
  Move(Data[0], FRAM, SizeOf(FRAM));
end;

procedure TSegaArcadeConsole.SerializeState(State: TStateArchive);
begin
  State.Field(FMCUControl, SizeOf(FMCUControl));
  State.Field(FMainReset, SizeOf(FMainReset));
  State.Field(FResetPending, SizeOf(FResetPending));
  State.Field(FMainPauseUntil, SizeOf(FMainPauseUntil));
  if FMCU <> nil then
    FMCU.SerializeState(State);
  State.Field(FCryptoState, SizeOf(FCryptoState));
  State.Field(FCryptoIRQ, SizeOf(FCryptoIRQ));
  State.Field(FIRQSerial, SizeOf(FIRQSerial));
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM, SizeOf(FRAM));
  SerializeBoardState(State);
  State.Field(FMapper, SizeOf(FMapper));
  State.Field(FPPI, SizeOf(FPPI));
  State.CompatibleField(FInput, SizeOf(FInput), TEmulatorInput.LegacySize, TEmulatorInput.TravelSize);
  State.Field(FCoins, SizeOf(FCoins));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(DIP, SizeOf(DIP));
  Video.SerializeState(State);
  SerializeAudio(State);
  if (FTime < 0) or (FFrameNumber < 0) then
    raise EReadError.Create('Invalid arcade clock state');
end;

function TSegaArcadeConsole.ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;

  procedure ReadBlock(Base: Cardinal; Memory: PByte; Size: Cardinal);
  begin
    if (Address < Base) or (Address - Base >= Size) or (Count = 0) then
      Exit;
    var Read := ReadAchievementMemoryBlock(Address - Base, Buffer, Count, Memory, Size);
    Inc(Address, Read);
    Inc(Buffer, Read);
    Dec(Count, Read);
    Inc(Result, Read);
  end;

begin
  Result := 0;
  if (Buffer = nil) or (Count = 0) then
    Exit;
  // FBNeo System16MemIndex, from RamStart. The 68000 buffers use host word order.
  ReadBlock($00000, @FRAM, SizeOf(FRAM));
  ReadBlock($04000, @Video.TileRAM, SizeOf(Video.TileRAM));
  ReadBlock($14000, @Video.TextRAM, SizeOf(Video.TextRAM));
  ReadBlock($15000, @Video.SpriteRAM, $800);
  ReadBlock($15800, @Video.PaletteRAM, SizeOf(Video.PaletteRAM));
  if (Address >= $16800) and (Count <> 0) then
    Inc(Result, ReadAchievementSoundRAM(Address - $16800, Buffer, Count));
end;

end.

