unit S16.Console;

interface

uses
  System.SysUtils, System.Generics.Collections, HW.M68k, S16.RomSets,
  S16.Cartridge, S16.Video, S16.Sound, S16.I8751, Core.Emulation.Types,
  Core.Snapshots;

type
  TS16Console = class
  private
    FCart: TS16Cartridge;
    FProgram, FKey: TBytes;
    FCryptoState: Byte;
    FCryptoIRQ, FResetting: Boolean;
    FIRQSerial: Cardinal;
    FOpcodeRead: TMemoryReadCallback;
    FOpcodeCache: TDictionary<UInt64, Word>;
    FMCU: TS16I8751;
    FMCUControl: Byte;
    FMainReset, FResetPending: Boolean;
    FMainPauseUntil: Int64;
    FCPU: TM68kState;
    FBus: TM68kReadWriteCallbacks;
    FMultiply: array[0..1] of Word;
    FCompare: array[0..1, 0..15] of Word;
    FHistory: array[0..1] of Integer;
    FRAM: array[0..$1FFF] of Word;
    FMapper: array[0..$1F] of Byte;
    FPPI: array[0..3] of Byte;
    FInput: TEmulatorInput;
    FCoins: array[0..1] of Integer;
    FTime, FFrameNumber: Int64;
    function MCURead(Address: Word): Byte;
    procedure MCUWrite(Address: Word; Value: Byte);
    function MCUPortRead(Port: Byte): Byte;
    procedure MCUPortWrite(Port, Value: Byte);
    function MCUAddress(Address: Word; out Physical: Cardinal): Boolean;
    procedure SetMainReset(Asserted: Boolean);
    procedure SimulateMCU;
    function ReadMath(UnitIndex: Integer; Offset: Cardinal): Word;
    procedure WriteMath(UnitIndex: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean);
    function DecodeAddress(Address: Cardinal; out Offset: Cardinal): Integer;
    function ReadOpcode(Address: Cardinal): Word;
    function ReadIO(Offset: Cardinal): Word;
    procedure WriteIO(Offset: Cardinal; Value: Byte);
    procedure WriteMapper(Index, Value: Byte);
    function Pad(const Buttons: TEmulatorButtons): Byte;
  public
    Video: TS16Video;
    Sound: TS16Sound;
    DIP: array[0..1] of Byte; // SW1 coinage, SW2 game options.
    constructor Create(Cart: TS16Cartridge);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame;
    function ReadWord(Address: Cardinal): Word;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True);
    procedure SetInput(const Input: TEmulatorInput);
    procedure InsertCoin(Player: Integer);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
    property CPU: TM68kState read FCPU;
    property MCU: TS16I8751 read FMCU;
    property FrameNumber: Int64 read FFrameNumber;
  end;

implementation

uses
  System.Math, System.Classes, S16.Crypto;

function BusRead(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte): Cardinal;
begin
  Result := TS16Console(User).ReadWord(Address shl 1);
end;

function OpcodeRead(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte): Cardinal;
begin
  Result := TS16Console(User).ReadOpcode(Address shl 1);
end;

procedure BusWrite(User: Pointer; Address: Cardinal; HighByte, LowByte: Byte; Cycle: Cardinal; var Terminate: Byte; Value: Cardinal);
begin
  TS16Console(User).WriteWord(Address shl 1, Word(Value and $FFFF), HighByte <> 0, LowByte <> 0);
end;

procedure IRQDone(User: Pointer);
begin
  var Console := TS16Console(User);
  if Console.FCart.RomSet.Crypto = 3 then
  begin
    Console.FCryptoIRQ := True;
    Inc(Console.FIRQSerial);
  end;
  if (Console.FMCU = nil) or (Console.FCart.RomSet.Board <> 0) then
    Clown68000Interrupt(Console.FCPU, 0);
end;

constructor TS16Console.Create(Cart: TS16Cartridge);
begin
  inherited Create;
  FCart := Cart;
  FProgram := Cart['maincpu'];
  FKey := Cart['maincpu:key'];
  FOpcodeCache := TDictionary<UInt64, Word>.Create;
  if Cart.RomSet.Crypto in [1, 2, 3] then
  begin
    if Length(FKey) <> $2000 then
      raise EReadError.Create('System 16 CPU requires its 8 KiB key ROM');
    FOpcodeRead := OpcodeRead;
  end;
  FBus.UserData := Self;
  FBus.ReadCallback := BusRead;
  FBus.WriteCallback := BusWrite;
  FBus.InterruptAcknowledgeCallback := IRQDone;
  Video := TS16Video.Create(Cart['tiles'], Cart['sprites'], Cart.RomSet.Board = 0, Cart.RomSet.Board);
  Sound := TS16Sound.Create(Cart['soundcpu'], Cart.RomSet.Board, Cart['soundcpu:key'], Cart['upd7751'], Cart['upd7751data'], Cart.RomSet.Crypto);
  if Cart.RomSet.MCU and (Cart.RomSet.MCUSimulation = smNone) then
  begin
    FMCU := TS16I8751.Create(Cart['mcu']);
    FMCU.ReadExternal := MCURead;
    FMCU.WriteExternal := MCUWrite;
    FMCU.ReadPort := MCUPortRead;
    FMCU.WritePort := MCUPortWrite;
  end;
  for var I := 0 to 1 do
    DIP[I] := Cart.RomSet.DIPs[I];
  Reset;
end;

destructor TS16Console.Destroy;
begin
  FMCU.Free;
  FOpcodeCache.Free;
  Sound.Free;
  Video.Free;
  inherited;
end;

procedure TS16Console.Reset;
begin
  FCPU := Default(TM68kState);
  if FCart.RomSet.Board <> 0 then
    FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FMapper, SizeOf(FMapper), 0);
  FillChar(FMultiply, SizeOf(FMultiply), 0);
  FillChar(FCompare, SizeOf(FCompare), 0);
  FillChar(FHistory, SizeOf(FHistory), 0);
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
  Sound.Reset;
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

function TS16Console.DecodeAddress(Address: Cardinal; out Offset: Cardinal): Integer;
const
  Sizes: array[0..3] of Cardinal = ($FFFF, $1FFFF, $7FFFF, $1FFFFF);
  Mirrors: array[3..7] of Cardinal = ($FFC000, $FFF800, $FE0000, $FFF000, $FFC000);
begin
  if FCart.RomSet.Board = 0 then
  begin
    Offset := Address and $3FFFF;
    if Address and $C40000 = 0 then
      Exit(0);
    Offset := Address and $7FFF;
    if Address and $470000 = $400000 then
      Exit(5);
    Offset := Address and $FFF;
    if Address and $470000 = $410000 then
      Exit(8);
    Offset := Address and $7FF;
    if Address and $C40000 = $440000 then
      Exit(4);
    Offset := Address and $FFF;
    if Address and $C40000 = $840000 then
      Exit(6);
    Offset := Address and $3FFF;
    if Address and $C60000 = $C40000 then
      Exit(7);
    if Address and $C70000 = $C70000 then
      Exit(3);
    Exit(-1);
  end;
  // Lowest region index wins if regions overlap, including reset aliases.
  for var I := 0 to 7 do
  begin
    var Mask := Sizes[FMapper[$10 + I * 2] and 3];
    var Base := (Cardinal(FMapper[$11 + I * 2]) shl 16) and not Mask;
    if (Address and not Mask) <> Base then
      Continue;
    var local := Address and Mask;
    if I >= 3 then
    begin
      var Mirror := Mirrors[I] and Mask;
      Offset := local and not Mirror;
      if I = 5 then
      begin
        // Text RAM overrides the tile RAM mapping at +$10000.
        var TextOffset := local and not ($FEF000 and Mask);
        if (TextOffset >= ($10000 and Mask)) and
          (TextOffset <= ($10000 and Mask) + Min($FFF, Mask)) then
        begin
          Offset := TextOffset - ($10000 and Mask);
          Exit(8);
        end;
        if Offset < $10000 then
          Exit(5);
      end
      else
      begin
        case I of
          3:
            if Offset < $4000 then
              Exit(3);
          4:
            if Offset < $800 then
              Exit(4);
          6:
            if Offset < $1000 then
              Exit(6);
          7:
            if Offset < $4000 then
              Exit(7);
        end;
      end;
    end
    else
    begin
      if (FCart.RomSet.Board = 5) and (I in [1, 2]) then
      begin
        Offset := local and $3FFF;
        if I = 2 then
          Offset := local and $FFFF;
        Exit(9 + I);
      end;
      var ROMSize := $20000;
      if FCart.RomSet.Board >= 3 then
        ROMSize := $40000;
      if FCart.RomSet.Board = 5 then
        ROMSize := $80000;
      if (I = 2) and (FCart.RomSet.Board >= 3) then
      begin
        Offset := local and $FFFF;
        Exit(9); // Tile bank latches, 5521/5704.
      end;
      Offset := local and (ROMSize - 1);
      var ROMBase := I * ROMSize;
      if FCart.RomSet.Board = 1 then
        ROMBase := I * $10000;
      Inc(Offset, ROMBase);
      if Offset < Cardinal(Length(FProgram)) then
        Exit(0);
    end;
  end;
  Offset := 0;
  Result := -1;
end;

function Signed16(Value: Word): Integer; inline;
begin
  Result := Integer(Value and $7FFF) - Integer(Value and $8000);
end;

function TS16Console.ReadMath(UnitIndex: Integer; Offset: Cardinal): Word;
begin
  var Index := Integer((Offset shr 1) and $F);
  if Offset and $3000 = 0 then
  begin
    Index := Index and 3;
    if Index < 2 then
      Exit(FMultiply[Index]);
    var Product := Int64(Signed16(FMultiply[0])) * Signed16(FMultiply[1]);
    if Index = 2 then
      Exit(Word((Product shr 16) and $FFFF));
    Exit(Word(Product and $FFFF));
  end;
  if Offset and $3000 = $1000 then
  begin
    case Index of
      0..4, 7:
        Exit(FCompare[UnitIndex, Index]);
      5:
        Exit(FCompare[UnitIndex, 1]);
      6:
        Exit(FCompare[UnitIndex, 2]);
    end;
  end;
  Result := $FFFF;
end;

procedure TS16Console.WriteMath(UnitIndex: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean);

  procedure Merge(var Dest: Word);
  begin
    if HighByte then
      Dest := (Dest and $FF) or (Value and $FF00);
    if LowByte then
      Dest := (Dest and $FF00) or (Value and $FF);
  end;

begin
  var Index := Integer((Offset shr 1) and $F);
  case Offset and $3000 of
    $0000:
      Merge(FMultiply[Index and 1]);
    $1000:
      begin
        case Index of
          0..2:
            Merge(FCompare[UnitIndex, Index]);
          4:
            begin
              FCompare[UnitIndex, 4] := 0;
              FHistory[UnitIndex] := 0;
            end;
          6:
            Merge(FCompare[UnitIndex, 2]);
          8, 12:
            Merge(FCompare[UnitIndex, 8]);
          10, 14:
            Merge(FCompare[UnitIndex, 10]);
          11, 15:
            if LowByte then
              FCompare[UnitIndex, 11] := Value and $FF;
        end;
        if Index in [0, 1, 2, 6] then
        begin
          var Lower := Min(Signed16(FCompare[UnitIndex, 0]), Signed16(FCompare[UnitIndex, 1]));
          var Upper := Max(Signed16(FCompare[UnitIndex, 0]), Signed16(FCompare[UnitIndex, 1]));
          var Operand := Signed16(FCompare[UnitIndex, 2]);
          FCompare[UnitIndex, 3] := 0;
          if Operand < Lower then
            FCompare[UnitIndex, 3] := $8000;
          if Operand > Upper then
            FCompare[UnitIndex, 3] := $4000;
          FCompare[UnitIndex, 7] := Word(EnsureRange(Operand, Lower, Upper) and $FFFF);
          if Index = 2 then
          begin
            if (FCompare[UnitIndex, 3] = 0) and (FHistory[UnitIndex] < 16) then
              FCompare[UnitIndex, 4] := FCompare[UnitIndex, 4] or Word(1 shl FHistory[UnitIndex]);
            if FHistory[UnitIndex] < 32 then
              Inc(FHistory[UnitIndex]);
          end;
        end;
      end;
    $2000:
      if LowByte then
        Video.TileBank[(Offset shr 1) and 1] := Byte(Value and 7);
  end;
end;

function TS16Console.Pad(const Buttons: TEmulatorButtons): Byte;
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

function TS16Console.ReadIO(Offset: Cardinal): Word;

  function QuartetPad(const Buttons: TEmulatorButtons; Coin: Boolean): Byte;
  const
    Order: array[0..5] of TEmulatorButton = (TEmulatorButton.Down,
      TEmulatorButton.Up, TEmulatorButton.Right, TEmulatorButton.Left,
      TEmulatorButton.B, TEmulatorButton.A);
  begin
    Result := $FF;
    for var I := 0 to 5 do
      if Order[I] in Buttons then
        Result := Result and Byte($FF xor (1 shl I));
    if Coin or (TEmulatorButton.Select in Buttons) then
      Result := Result and $BF;
    if TEmulatorButton.Mode in Buttons then
      Result := Result and $7F;
  end;

begin
  if (FCart.RomSet.Inputs = 'quartet') and (Offset and $3000 = $1000) then
    case (Offset shr 1) and 3 of
      0:
        Exit(QuartetPad(FInput.Buttons, FCoins[0] > 0));
      1:
        Exit(QuartetPad(FInput.Buttons2, FCoins[1] > 0));
      2:
        Exit(QuartetPad(FInput.Buttons3, False));
      3:
        Exit(QuartetPad(FInput.Buttons4, False));
    end;
  case Offset and $3000 of
    $0000:
      if FCart.RomSet.Board = 0 then
        Exit(FPPI[(Offset shr 1) and 3]);
    $1000:
      case (Offset shr 1) and 3 of
        0:
          begin
            Result := $FF;
            if (FCoins[0] > 0) or (TEmulatorButton.Select in FInput.Buttons) then
              Result := Result and $FE;
            if (FCoins[1] > 0) or (TEmulatorButton.Select in FInput.Buttons2) then
              Result := Result and $FD;
            if TEmulatorButton.Mode in FInput.Buttons then
              Result := Result and $FB;
            if TEmulatorButton.Start in FInput.Buttons then
              Result := Result and $EF;
            if TEmulatorButton.Start in FInput.Buttons2 then
              Result := Result and $DF;
            Exit;
          end;
        1:
          Exit(Pad(FInput.Buttons));
        2:
          Exit($FF);
        3:
          Exit(Pad(FInput.Buttons2));
      end;
    $2000:
      begin
        var Index := Integer((Offset shr 1) and 1);
        if FCart.RomSet.Board <> 0 then
          Index := Index xor 1;
        Exit(DIP[Index]);
      end;
  end;
  Result := $FFFF;
end;

procedure TS16Console.WriteIO(Offset: Cardinal; Value: Byte);
begin
  if Offset and $3000 <> 0 then
    Exit;
  if FCart.RomSet.Board = 0 then
  begin
    var Port := (Offset shr 1) and 3;
    FPPI[Port] := Value;
    case Port of
      0:
        Sound.Command(Value);
      1:
        begin
          Video.DisplayEnabled := Value and $10 <> 0;
          Video.Flip := Value and $80 <> 0;
          if FMCU <> nil then
            FMCU.SetIRQ(1, Value and $40 = 0);
        end;
      2:
        begin
          Video.RowScroll := Value and 2 = 0;
          Video.ColumnScroll := Value and 4 = 0;
        end;
    end;
  end
  else
  begin
    Video.DisplayEnabled := Value and $20 <> 0;
    Video.Flip := Value and $40 <> 0;
  end;
end;

procedure TS16Console.SetMainReset(Asserted: Boolean);
begin
  if Asserted and not FMainReset then
    FResetPending := True;
  FMainReset := Asserted;
end;

function TS16Console.MCUPortRead(Port: Byte): Byte;
begin
  Result := $FF;
  if (FCart.RomSet.Board <> 0) and (Port = 1) then
    Result := Byte(ReadIO($1000) and $FF);
end;

procedure TS16Console.MCUPortWrite(Port, Value: Byte);
begin
  if Port <> 1 then
    Exit;
  if FCart.RomSet.Board <> 0 then
  begin
    // Compatibility scheduling window used by MAME's 16B driver as well.
    // The precise P1 bus arbitration circuit is not documented.
    FMainPauseUntil := FTime + 20000;
    Exit;
  end;
  FMCUControl := Value;
  SetMainReset(Value and $40 <> 0);
  Clown68000Interrupt(FCPU, (not Value) and 7);
  if FMainReset then
    Video.DisplayEnabled := True;
end;

function TS16Console.MCUAddress(Address: Word; out Physical: Cardinal): Boolean;
begin
  Result := True;
  case (FMCUControl shr 3) and 7 of
    0:
      if (Address >= $4000) and (Address < $8000) then
        Physical := $C70001 xor (Address and $3FFF)
      else if (Address >= $8000) and (Address < $C000) then
        Physical := $C40001 xor (Address and $3FFF)
      else
        Exit(False);
    1:
      if Address < $8000 then
        Physical := $400001 xor (Address and $7FFF)
      else if Address < $9000 then
        Physical := $410001 xor (Address and $FFF)
      else
        Exit(False);
    3:
      Physical := $840001 xor Address;
  else
    Result := False;
  end;
end;

function TS16Console.MCURead(Address: Word): Byte;
var
  Physical: Cardinal;
begin
  if FCart.RomSet.Board <> 0 then
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
        Exit(Sound.Reply);
    end;
    Exit($FF);
  end;
  if (FMCUControl shr 3) and 7 in [5, 6, 7] then
    Exit(FProgram[(((FMCUControl shr 3) and 7) - 5) * $10000 + (Address xor 1)]);
  if not MCUAddress(Address, Physical) then
    Exit($FF);
  var Data := ReadWord(Physical);
  if Physical and 1 = 0 then
    Result := Byte(Data shr 8)
  else
    Result := Byte(Data and $FF);
end;

procedure TS16Console.MCUWrite(Address: Word; Value: Byte);
var
  Physical: Cardinal;
begin
  if FCart.RomSet.Board <> 0 then
  begin
    if Address and $FF < $20 then
      WriteMapper(Byte(Address and $1F), Value);
    Exit;
  end;
  if not MCUAddress(Address, Physical) then
    Exit;
  if Physical and 1 = 0 then
    WriteWord(Physical, Word(Value) shl 8, True, False)
  else
    WriteWord(Physical, Value, False, True);
end;

procedure TS16Console.WriteMapper(Index, Value: Byte);
begin
  FMapper[Index] := Value;
  case Index of
    2:
      SetMainReset(Value and 3 = 3);
    3:
      Sound.Command(Value);
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

function TS16Console.ReadOpcode(Address: Cardinal): Word;
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

function TS16Console.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  var Offset: Cardinal;
  case DecodeAddress(Address, Offset) of
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
    9:
      Exit($FFFF);
    10:
      Exit(ReadMath(0, Offset));
    11:
      Exit(ReadMath(1, (Offset and $1F) or $1000));
  end;
  Result := $FFFF;
  if FCart.RomSet.Board <> 0 then
    case (Address shr 1) and $1F of
      0, 1:
        Result := $FF00 or FMapper[(Address shr 1) and 1];
      2:
        if FMainReset then
          Result := $FF00
        else
          Result := $FF0F;
      3:
        Result := $FF00 or Sound.Reply;
    end;
end;

procedure TS16Console.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);

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
  case DecodeAddress(Address, Offset) of
    0:
      Exit;
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
    10:
      begin
        WriteMath(0, Offset, Value, HighByte, LowByte);
        Exit;
      end;
    11:
      begin
        WriteMath(1, (Offset and $1F) or $1000, Value, HighByte, LowByte);
        Exit;
      end;
    9:
      begin
        if LowByte and (Offset < 4) then
          Video.TileBank[Offset shr 1] := Byte(Value and 7);
        Exit;
      end;
  end;
  if LowByte and (FCart.RomSet.Board <> 0) then
    WriteMapper(Byte((Address shr 1) and $1F), Byte(Value and $FF));
end;

// Native Pascal adaptation of MAME's tturf_i8751_sim / wb3_i8751_sim.
// Copyright Aaron Giles, BSD-3-Clause; see REFERENCE-LICENSE.txt.
// These two MCU ROMs are undumped. The VBLANK mailbox protocol has no
// private state: all pending requests and acknowledgements live in work RAM.
procedure TS16Console.SimulateMCU;
begin
  Clown68000Interrupt(FCPU, 4);
  case FCart.RomSet.MCUSimulation of
    smToughTurf:
      begin
        var Request := FRAM[$1D0 div 2];
        if Request and $FF00 <> 0 then
        begin
          WriteMapper(3, Byte(Request and $FF));
          FRAM[$1D0 div 2] := Request and $FF;
        end;
        FRAM[$1E6 div 2] := (ReadIO($1000) and $FF) shl 8;
        FRAM[$1E8 div 2] := (ReadIO($1002) and $FF) shl 8;
        FRAM[$1EA div 2] := (ReadIO($1006) and $FF) shl 8;
      end;
    smWonderBoy3:
      begin
        var Request := FRAM[$8 div 2];
        if Request and $FF <> 0 then
        begin
          WriteMapper(3, Byte(Request shr 8));
          FRAM[$8 div 2] := Request and $FF00;
        end;
      end;
  end;
end;

procedure TS16Console.RunFrame;
begin
  Sound.BeginFrame;
  for var Line := 0 to 261 do
  begin
    if Line = 224 then
    begin
      Video.Render;
      if FCart.RomSet.MCUSimulation <> smNone then
        SimulateMCU
      else if FMCU = nil then
        Clown68000Interrupt(FCPU, 4)
      else
        FMCU.SetIRQ(0, True);
    end;
    if Line = 261 then
      Video.Latch;
    if (Line = 0) and (FMCU <> nil) then
      FMCU.SetIRQ(0, False);
    var Target := ((FFrameNumber * 262 + Line + 1) * Int64(10000000) * 1600) div 25174800;
    while FTime < Target do
    begin
      if FMCU <> nil then
        while FMCU.Cycles * 15 <= FTime do
          FMCU.Step;
      if FResetPending and not FMainReset then
      begin
        Clown68000Reset(FCPU, FBus, FOpcodeRead);
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
        raise EInvalidOpException.CreateFmt('System 16 68000 halted at %.6x', [FCPU.ProgramCounter]);
      Inc(FTime, Cycles);
      Sound.RunUntil(FTime * Sound.Clock div 10000000);
    end;
  end;
  Sound.EndFrame;
  Inc(FFrameNumber);
  for var I := 0 to 1 do
    if FCoins[I] > 0 then
      Dec(FCoins[I]);
end;

procedure TS16Console.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

procedure TS16Console.InsertCoin(Player: Integer);
begin
  if not (Player in [1, 2]) then
    raise EArgumentOutOfRangeException.Create('System 16 coin player');
  FCoins[Player - 1] := 3;
end;

function TS16Console.Battery: TBytes;
begin
  Result := nil;
  if FCart.RomSet.Board <> 0 then
    Exit;
  SetLength(Result, SizeOf(FRAM));
  Move(FRAM, Result[0], SizeOf(FRAM));
end;

procedure TS16Console.LoadBattery(const Data: TBytes);
begin
  if (FCart.RomSet.Board <> 0) or (Length(Data) <> SizeOf(FRAM)) then
    raise EReadError.Create('Invalid System 16 NVRAM size');
  Move(Data[0], FRAM, SizeOf(FRAM));
end;

procedure TS16Console.SerializeState(State: TStateArchive);
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
  State.Field(FMultiply, SizeOf(FMultiply));
  State.Field(FCompare, SizeOf(FCompare));
  State.Field(FHistory, SizeOf(FHistory));
  State.Field(FMapper, SizeOf(FMapper));
  State.Field(FPPI, SizeOf(FPPI));
  State.Field(FInput, SizeOf(FInput));
  State.Field(FCoins, SizeOf(FCoins));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(DIP, SizeOf(DIP));
  Video.SerializeState(State);
  Sound.SerializeState(State);
  if (FTime < 0) or (FFrameNumber < 0) then
    raise EReadError.Create('Invalid System 16 clock state');
end;

end.

