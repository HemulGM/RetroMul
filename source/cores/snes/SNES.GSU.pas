unit SNES.GSU;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TGsuReadROM = function(Address: Cardinal): Byte of object;

  TGsuFlags = packed record
    Zero, Carry, Sign, Overflow, Running, RomReadPending, Alt1, Alt2, ImmLow, ImmHigh, Prefix, IRQ: Boolean;
  end;

  TGsuPixelCache = packed record
    X, Y: Byte;
    Pixels: array[0..7] of Byte;
    ValidBits: Byte;
  end;

  TGsuState = packed record
    Cycles: UInt64;
    R: array[0..15] of Word;
    SFR: TGsuFlags;
    RegisterLatch, ProgramBank, RomBank, RamBank: Byte;
    IrqDisabled, HighSpeedMode, ClockSelect, BackupRamEnabled: Boolean;
    ScreenBase, ColorGradient, PlotBpp, ScreenHeight: Byte;
    RamAccess, RomAccess: Boolean;
    CacheBase: Word;
    PlotTransparent, PlotDither, ColorHighNibble, ColorFreezeHigh, ObjMode: Boolean;
    ColorReg, SrcReg, DestReg, RomBuffer, RomDelay, ProgramBuffer: Byte;
    RamWriteAddress: Word;
    RamWriteValue, RamDelay: Byte;
    RamAddress: Word;
    Primary, Secondary: TGsuPixelCache;
  end;

  TSnesGSU = class
  private
    FRead: TGsuReadROM;
    FWaitROM, FWaitRAM, FStopped, FR15Changed, FDirty: Boolean;
    FCache: array[0..511] of Byte;
    FValid: array[0..31] of Boolean;
    procedure Tick(Cycles: UInt64);
    procedure WaitROM;
    procedure WaitRAM;
    procedure AccessROM;
    procedure AccessRAM;
    procedure UpdateRunning;
    function BusRead(Address: Cardinal): Byte;
    procedure BusWrite(Address: Cardinal; Value: Byte);
    function ProgramRead: Byte;
    function Operand: Byte;
    function RamRead(Address: Word): Byte;
    procedure RamWrite(Address: Word; Value: Byte);
    procedure RegWrite(Reg: Byte; Value: Word);
    procedure DestWrite(Value: Word);
    procedure ClearFlags;
    procedure NZ(Value: Word);
    function Color(Value: Byte): Byte;
    function TileAddress(X, Y: Byte): Cardinal;
    procedure WritePixels(var Cache: TGsuPixelCache);
    procedure FlushPrimary(X, Y: Byte);
    procedure Plot(X, Y: Byte);
    function ReadPixel(X, Y: Byte): Byte;
  public
    State: TGsuState;
    RAM: TBytes;
    constructor Create(ReadROM: TGsuReadROM; RamSize: Integer);
    procedure Reset;
    procedure Step;
    procedure Execute(Op: Byte);
    procedure RunUntil(Target: UInt64);
    function Read(Address: Cardinal): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    function CPUReadROM(Address: Cardinal): Byte;
    function CPUReadRAM(Address: Cardinal; OpenBus: Byte): Byte;
    procedure CPUWriteRAM(Address: Cardinal; Value: Byte);
    procedure SerializeState(Archive: TStateArchive);
    procedure LoadBattery(const Data: TBytes);
    property BatteryDirty: Boolean read FDirty;
  end;

implementation

constructor TSnesGSU.Create(ReadROM: TGsuReadROM; RamSize: Integer);
begin
  inherited Create;
  FRead := ReadROM;
  SetLength(RAM, RamSize);
  Reset;
end;

procedure TSnesGSU.Reset;
begin
  State := Default(TGsuState);
  State.ProgramBuffer := 1;
  FillChar(FCache, SizeOf(FCache), 0);
  FillChar(FValid, SizeOf(FValid), 0);
  FWaitROM := False;
  FWaitRAM := False;
  FStopped := True;
  FR15Changed := False;
end;

procedure TSnesGSU.UpdateRunning;
begin
  FStopped := not State.SFR.Running or FWaitRAM or FWaitROM;
end;

procedure TSnesGSU.AccessROM;
begin
  if not State.RomAccess then
  begin
    FWaitROM := True;
    FStopped := True;
  end;
end;

procedure TSnesGSU.AccessRAM;
begin
  if not State.RamAccess then
  begin
    FWaitRAM := True;
    FStopped := True;
  end;
end;

procedure TSnesGSU.Tick(Cycles: UInt64);
begin
  Inc(State.Cycles, Cycles);
  if State.RomDelay > 0 then
  begin
    if Byte(Cycles) >= State.RomDelay then
      State.RomDelay := 0
    else
      Dec(State.RomDelay, Byte(Cycles));
    if State.RomDelay = 0 then
    begin
      AccessROM;
      State.RomBuffer := BusRead((Cardinal(State.RomBank) shl 16) or State.R[14]);
      State.SFR.RomReadPending := False;
    end;
  end;
  if State.RamDelay > 0 then
  begin
    if Byte(Cycles) >= State.RamDelay then
      State.RamDelay := 0
    else
      Dec(State.RamDelay, Byte(Cycles));
    if State.RamDelay = 0 then
    begin
      AccessRAM;
      BusWrite($700000 or (Cardinal(State.RamBank) shl 16) or State.RamWriteAddress, State.RamWriteValue);
    end;
  end;
end;

procedure TSnesGSU.WaitROM;
begin
  if State.RomDelay > 0 then
    Tick(State.RomDelay);
end;

procedure TSnesGSU.WaitRAM;
begin
  if State.RamDelay > 0 then
    Tick(State.RamDelay);
end;

function TSnesGSU.BusRead(Address: Cardinal): Byte;
begin
  var Bank := Address shr 16;
  if Bank <= $3F then
    Exit(FRead(((Bank and $3F) shl 15) or (Address and $7FFF)));
  if Bank <= $5F then
    Exit(FRead(Address and $1FFFFF));
  if (Bank in [$70, $71]) and (Length(RAM) > 0) then
    Exit(RAM[(Address and $1FFFF) mod Cardinal(Length(RAM))]);
  Result := 0;
end;

procedure TSnesGSU.BusWrite(Address: Cardinal; Value: Byte);
begin
  if ((Address shr 16) in [$70, $71]) and (Length(RAM) > 0) then
  begin
    var Index := (Address and $1FFFF) mod Cardinal(Length(RAM));
    if RAM[Index] <> Value then
    begin
      RAM[Index] := Value;
      FDirty := True;
    end;
  end;
end;

function TSnesGSU.ProgramRead: Byte;
begin
  var CacheAddress := Word(State.R[15] - State.CacheBase);
  if CacheAddress < 512 then
  begin
    if not FValid[CacheAddress shr 4] then
    begin
      if State.ProgramBank <= $5F then
      begin
        WaitROM;
        AccessROM;
      end
      else
      begin
        WaitRAM;
        AccessRAM;
      end;
      var Dest := CacheAddress and $1F0;
      var Src := (Cardinal(State.ProgramBank) shl 16) + State.CacheBase + Dest;
      for var J := 0 to 15 do
        FCache[Dest + J] := BusRead(Src + Cardinal(J));
      if State.ClockSelect then
        Tick(5 * 16)
      else
        Tick(6 * 16);
      FValid[CacheAddress shr 4] := True;
    end;
    if State.ClockSelect then
      Tick(1)
    else
      Tick(2);
    Exit(FCache[CacheAddress]);
  end;
  if State.ProgramBank <= $5F then
  begin
    WaitROM;
    AccessROM;
  end
  else
  begin
    WaitRAM;
    AccessRAM;
  end;
  if State.ClockSelect then
    Tick(5)
  else
    Tick(6);
  Result := BusRead((Cardinal(State.ProgramBank) shl 16) or State.R[15]);
end;

function TSnesGSU.Operand: Byte;
begin
  Result := State.ProgramBuffer;
  State.R[15] := (Integer(State.R[15]) + 1) and $FFFF;
  State.ProgramBuffer := ProgramRead;
end;

procedure TSnesGSU.RegWrite(Reg: Byte; Value: Word);
begin
  State.R[Reg] := Value;
  if Reg = 14 then
  begin
    State.SFR.RomReadPending := True;
    State.RomDelay := 6 - Ord(State.ClockSelect);
  end
  else if Reg = 15 then
    FR15Changed := True;
end;

procedure TSnesGSU.DestWrite(Value: Word);
begin
  RegWrite(State.DestReg, Value);
end;

procedure TSnesGSU.ClearFlags;
begin
  State.SFR.Prefix := False;
  State.SFR.Alt1 := False;
  State.SFR.Alt2 := False;
  State.SrcReg := 0;
  State.DestReg := 0;
end;

procedure TSnesGSU.NZ(Value: Word);
begin
  State.SFR.Sign := (Value and $8000) <> 0;
  State.SFR.Zero := Value = 0;
end;

function TSnesGSU.RamRead(Address: Word): Byte;
begin
  WaitRAM;
  AccessRAM;
  Result := BusRead($700000 or (Cardinal(State.RamBank) shl 16) or Address);
end;

procedure TSnesGSU.RamWrite(Address: Word; Value: Byte);
begin
  WaitRAM;
  State.RamDelay := 6 - Ord(State.ClockSelect);
  State.RamWriteAddress := Address;
  State.RamWriteValue := Value;
end;

function TSnesGSU.Color(Value: Byte): Byte;
begin
  if State.ColorHighNibble then
    Result := (State.ColorReg and $F0) or (Value shr 4)
  else if State.ColorFreezeHigh then
    Result := (State.ColorReg and $F0) or (Value and $F)
  else
    Result := Value;
end;

function TSnesGSU.TileAddress(X, Y: Byte): Cardinal;
begin
  var Mode := State.ScreenHeight;
  if State.ObjMode then
    Mode := 3;
  var Index: Integer;
  case Mode of
    0:
      Index := ((X and $F8) shl 1) + ((Y and $F8) shr 3);
    1:
      Index := ((X and $F8) shl 1) + ((X and $F8) shr 1) + ((Y and $F8) shr 3);
    2:
      Index := ((X and $F8) shl 1) + (X and $F8) + ((Y and $F8) shr 3);
  else
    Index := ((Y and $80) shl 2) + ((X and $80) shl 1) + ((Y and $78) shl 1) + ((X and $78) shr 3);
  end;
  Result := ($700000 or (Cardinal(State.ScreenBase) shl 10)) + Cardinal(Index) * (State.PlotBpp shl 3) + (Y and 7) * 2;
end;

procedure TSnesGSU.WritePixels(var Cache: TGsuPixelCache);
begin
  if Cache.ValidBits = 0 then
    Exit;
  var Address := TileAddress(Cache.X, Cache.Y);
  for var Plane := 0 to Integer(State.PlotBpp) - 1 do
  begin
    var Value: Byte := 0;
    for var X := 0 to 7 do
      Value := Value or (((Cache.Pixels[X] shr Plane) and 1) shl X);
    var Offset := ((Plane shr 1) shl 4) + (Plane and 1);
    if Cache.ValidBits <> $FF then
    begin
      Tick(6 - Ord(State.ClockSelect));
      Value := (Value and Cache.ValidBits) or (BusRead(Address + Cardinal(Offset)) and not Cache.ValidBits);
    end;
    Tick(6 - Ord(State.ClockSelect));
    AccessRAM;
    BusWrite(Address + Cardinal(Offset), Value);
  end;
  Cache.ValidBits := 0;
end;

procedure TSnesGSU.FlushPrimary(X, Y: Byte);
begin
  WritePixels(State.Secondary);
  State.Secondary := State.Primary;
  State.Primary.ValidBits := 0;
  State.Primary.X := X and $F8;
  State.Primary.Y := Y;
end;

procedure TSnesGSU.Plot(X, Y: Byte);
begin
  var C := State.ColorReg;
  if State.ColorFreezeHigh then
    C := C and $F;
  var Mask: Byte := 3;
  if State.PlotBpp = 8 then
    Mask := $FF
  else if State.PlotBpp = 4 then
    Mask := $F;
  if not State.PlotTransparent and ((C and Mask) = 0) then
    Exit;
  C := State.ColorReg;
  if State.PlotDither and (State.PlotBpp <> 8) then
  begin
    if ((X xor Y) and 1) <> 0 then
      C := C shr 4;
    C := C and $F;
  end;
  if (State.Primary.X <> (X and $F8)) or (State.Primary.Y <> Y) then
    FlushPrimary(X, Y);
  var Offset := (X and 7) xor 7;
  State.Primary.Pixels[Offset] := C;
  State.Primary.ValidBits := State.Primary.ValidBits or (1 shl Offset);
  if State.Primary.ValidBits = $FF then
    FlushPrimary(X, Y);
end;

function TSnesGSU.ReadPixel(X, Y: Byte): Byte;
begin
  WritePixels(State.Secondary);
  WritePixels(State.Primary);
  var Address := TileAddress(X, Y);
  X := (X and 7) xor 7;
  Result := 0;
  for var J := 0 to Integer(State.PlotBpp) - 1 do
  begin
    Result := Result or (((BusRead(Address + Cardinal((J shr 1) shl 4) + Cardinal(J and 1)) shr X) and 1) shl J);
    Tick(6 - Ord(State.ClockSelect));
  end;
end;

procedure TSnesGSU.Step;
begin
  var Op := State.ProgramBuffer;
  State.ProgramBuffer := ProgramRead;
  Execute(Op);
  if not FR15Changed then
    State.R[15] := (Integer(State.R[15]) + 1) and $FFFF
  else
    FR15Changed := False;
end;

procedure TSnesGSU.Execute(Op: Byte);
begin
  var Reg := Op and $F;
  var Src := State.R[State.SrcReg];
  var V: Word;
  var A: Cardinal;
  var Take: Boolean := True;
  case Op of
    0:
      begin
        if not State.IrqDisabled then
          State.SFR.IRQ := True;
        State.ProgramBuffer := 1;
        State.SFR.Running := False;
        ClearFlags;
        UpdateRunning;
      end;
    1:
      ClearFlags;
    2:
      begin
        if State.CacheBase <> (State.R[15] and $FFF0) then
        begin
          State.CacheBase := State.R[15] and $FFF0;
          FillChar(FValid, SizeOf(FValid), 0);
        end;
        ClearFlags;
      end;
    3, 4, $96, $97:
      begin
        case Op of
          3:
            begin
              V := Src shr 1;
              State.SFR.Carry := (Src and 1) <> 0;
            end;
          4:
            begin
              V := ((Src shl 1) or Ord(State.SFR.Carry)) and $FFFF;
              State.SFR.Carry := (Src and $8000) <> 0;
            end;
          $96:
            begin
              V := (Src shr 1) or (Src and $8000);
              if State.SFR.Alt1 then
                V := (Integer(V) + ((Integer(Src) + 1) shr 16)) and $FFFF;
              State.SFR.Carry := (Src and 1) <> 0;
            end;
        else
          begin
            V := (Src shr 1) or (Ord(State.SFR.Carry) shl 15);
            State.SFR.Carry := (Src and 1) <> 0;
          end;
        end;
        DestWrite(V);
        NZ(V);
        ClearFlags;
      end;
    5..$F:
      begin
        case Op of
          6:
            Take := State.SFR.Sign = State.SFR.Overflow;
          7:
            Take := State.SFR.Sign <> State.SFR.Overflow;
          8:
            Take := not State.SFR.Zero;
          9:
            Take := State.SFR.Zero;
          $A:
            Take := not State.SFR.Sign;
          $B:
            Take := State.SFR.Sign;
          $C:
            Take := not State.SFR.Carry;
          $D:
            Take := State.SFR.Carry;
          $E:
            Take := not State.SFR.Overflow;
          $F:
            Take := State.SFR.Overflow;
        end;
        var Offset := ShortInt(Operand);
        if Take then
          RegWrite(15, Word(Integer(State.R[15]) + Offset));
      end;
    $10..$1F:
      if State.SFR.Prefix then
      begin
        RegWrite(Reg, Src);
        ClearFlags;
      end
      else
        State.DestReg := Reg;
    $20..$2F:
      begin
        State.SrcReg := Reg;
        State.DestReg := Reg;
        State.SFR.Prefix := True;
      end;
    $30..$3B, $90:
      begin
        if Op <> $90 then
          State.RamAddress := State.R[Reg];
        RamWrite(State.RamAddress, Byte(Src));
        if (Op = $90) or not State.SFR.Alt1 then
          RamWrite(State.RamAddress xor 1, Byte(Src shr 8));
        ClearFlags;
      end;
    $3C:
      begin
        State.R[12] := (Integer(State.R[12]) - 1) and $FFFF;
        NZ(State.R[12]);
        if not State.SFR.Zero then
          RegWrite(15, State.R[13]);
        ClearFlags;
      end;
    $3D..$3F:
      begin
        State.SFR.Prefix := False;
        if Op <> $3E then
          State.SFR.Alt1 := True;
        if Op <> $3D then
          State.SFR.Alt2 := True;
      end;
    $40..$4B:
      begin
        State.RamAddress := State.R[Reg];
        V := RamRead(State.RamAddress);
        if not State.SFR.Alt1 then
          V := V or (Word(RamRead(State.RamAddress xor 1)) shl 8);
        DestWrite(V);
        ClearFlags;
      end;
    $4C:
      begin
        if State.SFR.Alt1 then
        begin
          V := ReadPixel(Byte(State.R[1]), Byte(State.R[2]));
          NZ(V);
          DestWrite(V);
        end
        else
        begin
          Plot(Byte(State.R[1]), Byte(State.R[2]));
          State.R[1] := (Integer(State.R[1]) + 1) and $FFFF;
        end;
        ClearFlags;
      end;
    $4D:
      begin
        V := (Src shr 8) or ((Src and $FF) shl 8);
        DestWrite(V);
        NZ(V);
        ClearFlags;
      end;
    $4E:
      begin
        if State.SFR.Alt1 then
        begin
          State.PlotTransparent := (Src and 1) <> 0;
          State.PlotDither := (Src and 2) <> 0;
          State.ColorHighNibble := (Src and 4) <> 0;
          State.ColorFreezeHigh := (Src and 8) <> 0;
          State.ObjMode := (Src and $10) <> 0;
        end
        else
          State.ColorReg := Color(Byte(Src));
        ClearFlags;
      end;
    $4F:
      begin
        V := not Src;
        DestWrite(V);
        NZ(V);
        ClearFlags;
      end;
    $50..$5F:
      begin
        V := State.R[Reg];
        if State.SFR.Alt2 then
          V := Reg;
        A := Cardinal(Src) + V;
        if State.SFR.Alt1 then
          Inc(A, Ord(State.SFR.Carry));
        State.SFR.Carry := (A and $10000) <> 0;
        State.SFR.Overflow := (not (Src xor V) and (V xor A) and $8000) <> 0;
        NZ(Word(A));
        DestWrite(Word(A));
        ClearFlags;
      end;
    $60..$6F:
      begin
        V := State.R[Reg];
        if State.SFR.Alt2 and not State.SFR.Alt1 then
          V := Reg;
        var ResultValue := Integer(Src) - V;
        if not State.SFR.Alt2 and State.SFR.Alt1 then
          Dec(ResultValue, Ord(not State.SFR.Carry));
        State.SFR.Carry := ResultValue >= 0;
        State.SFR.Overflow := ((Src xor V) and (Src xor ResultValue) and $8000) <> 0;
        NZ(Word(ResultValue));
        if not State.SFR.Alt2 or not State.SFR.Alt1 then
          DestWrite(Word(ResultValue));
        ClearFlags;
      end;
    $70:
      begin
        V := (State.R[7] and $FF00) or (State.R[8] shr 8);
        DestWrite(V);
        State.SFR.Carry := (V and $E0E0) <> 0;
        State.SFR.Overflow := (V and $C0C0) <> 0;
        State.SFR.Sign := (V and $8080) <> 0;
        State.SFR.Zero := (V and $F0F0) <> 0;
        ClearFlags;
      end;
    $71..$7F, $C1..$CF:
      begin
        V := State.R[Reg];
        if State.SFR.Alt2 then
          V := Reg;
        if Op < $80 then
        begin
          if State.SFR.Alt1 then
            V := Src and not V
          else
            V := Src and V;
        end
        else if State.SFR.Alt1 then
          V := Src xor V
        else
          V := Src or V;
        DestWrite(V);
        NZ(V);
        ClearFlags;
      end;
    $80..$8F:
      begin
        V := State.R[Reg];
        if State.SFR.Alt2 then
          V := Reg;
        if State.SFR.Alt1 then
          V := Byte(Src) * Byte(V)
        else
          V := Word(Integer(ShortInt(Src)) * Integer(ShortInt(V)));
        DestWrite(V);
        NZ(V);
        ClearFlags;
        Tick(2 - Ord(State.HighSpeedMode));
      end;
    $91..$94:
      begin
        State.R[11] := (Integer(State.R[15]) + Reg) and $FFFF;
        ClearFlags;
      end;
    $95:
      begin
        V := Word(SmallInt(ShortInt(Src)));
        DestWrite(V);
        NZ(V);
        ClearFlags;
      end;
    $98..$9D:
      begin
        if State.SFR.Alt1 then
        begin
          State.ProgramBank := State.R[Reg] and $7F;
          RegWrite(15, Src);
          State.CacheBase := State.R[15] and $FFF0;
          FillChar(FValid, SizeOf(FValid), 0);
        end
        else
          RegWrite(15, State.R[Reg]);
        ClearFlags;
      end;
    $9E, $C0:
      begin
        if Op = $9E then
          V := Byte(Src)
        else
          V := Src shr 8;
        DestWrite(V);
        State.SFR.Zero := V = 0;
        State.SFR.Sign := (V and $80) <> 0;
        ClearFlags;
      end;
    $9F:
      begin
        A := Cardinal(Integer(SmallInt(Src)) * Integer(SmallInt(State.R[6])));
        if State.SFR.Alt1 then
          State.R[4] := Word(A);
        V := A shr 16;
        DestWrite(V);
        State.SFR.Carry := (A and $8000) <> 0;
        NZ(V);
        ClearFlags;
        var Delay := 7;
        if State.HighSpeedMode then
          Delay := 3;
        if not State.ClockSelect then
          Delay := Delay * 2;
        Tick(Delay);
      end;
    $A0..$AF, $F0..$FF:
      begin
        var L := Operand;
        if Op < $B0 then
          A := Cardinal(L) shl 1
        else
          A := L or (Cardinal(Operand) shl 8);
        if State.SFR.Alt1 then
        begin
          State.RamAddress := Word(A);
          V := RamRead(Word(A));
          V := V or (Word(RamRead(Word(A) xor 1)) shl 8);
          RegWrite(Reg, V);
        end
        else if State.SFR.Alt2 then
        begin
          State.RamAddress := Word(A);
          RamWrite(Word(A), Byte(State.R[Reg]));
          RamWrite(Word(A) xor 1, Byte(State.R[Reg] shr 8));
        end
        else if Op < $B0 then
          RegWrite(Reg, Word(SmallInt(ShortInt(L))))
        else
          RegWrite(Reg, Word(A));
        ClearFlags;
      end;
    $B0..$BF:
      if State.SFR.Prefix then
      begin
        V := State.R[Reg];
        DestWrite(V);
        State.SFR.Overflow := (V and $80) <> 0;
        NZ(V);
        ClearFlags;
      end
      else
        State.SrcReg := Reg;
    $D0..$DE, $E0..$EE:
      begin
        if Op < $E0 then
          RegWrite(Reg, (Integer(State.R[Reg]) + 1) and $FFFF)
        else
          RegWrite(Reg, (Integer(State.R[Reg]) - 1) and $FFFF);
        NZ(State.R[Reg]);
        ClearFlags;
      end;
    $DF:
      begin
        if not State.SFR.Alt2 then
        begin
          WaitROM;
          State.ColorReg := Color(State.RomBuffer);
        end
        else if not State.SFR.Alt1 then
        begin
          WaitRAM;
          State.RamBank := Src and 1;
        end
        else
        begin
          WaitROM;
          State.RomBank := Src and $7F;
        end;
        ClearFlags;
      end;
    $EF:
      begin
        WaitROM;
        if State.SFR.Alt2 and State.SFR.Alt1 then
          V := Word(SmallInt(ShortInt(State.RomBuffer)))
        else if State.SFR.Alt2 then
          V := (Src and $FF00) or State.RomBuffer
        else if State.SFR.Alt1 then
          V := (Src and $FF) or (Word(State.RomBuffer) shl 8)
        else
          V := State.RomBuffer;
        DestWrite(V);
        ClearFlags;
      end;
  end;
end;

procedure TSnesGSU.RunUntil(Target: UInt64);
begin
  while not FStopped and (State.Cycles < Target) do
    Step;
  if State.Cycles < Target then
    Tick(Target - State.Cycles);
end;

function TSnesGSU.Read(Address: Cardinal): Byte;
begin
  Address := Address and $33FF;
  if Address < $3020 then
    Exit(Byte(State.R[(Address shr 1) and 15] shr ((Address and 1) * 8)));
  case Address of
    $3030:
      Exit((Ord(State.SFR.Zero) shl 1) or (Ord(State.SFR.Carry) shl 2) or (Ord(State.SFR.Sign) shl 3) or
        (Ord(State.SFR.Overflow) shl 4) or (Ord(State.SFR.Running) shl 5) or (Ord(State.SFR.RomReadPending) shl 6));
    $3031:
      begin
        Result := Ord(State.SFR.Alt1) or (Ord(State.SFR.Alt2) shl 1) or (Ord(State.SFR.ImmLow) shl 2) or
          (Ord(State.SFR.ImmHigh) shl 3) or (Ord(State.SFR.Prefix) shl 4) or (Ord(State.SFR.IRQ) shl 7);
        State.SFR.IRQ := False;
        Exit;
      end;
    $3034:
      Exit(State.ProgramBank);
    $3036:
      Exit(State.RomBank);
    $303B:
      Exit(4);
    $303C:
      Exit(State.RamBank);
    $303E:
      Exit(Byte(State.CacheBase));
    $303F:
      Exit(State.CacheBase shr 8);
  end;
  if (Address >= $3100) and (Address <= $32FF) then
    Exit(FCache[(State.CacheBase + Address - $3100) and $1FF]);
  Result := 0;
end;

procedure TSnesGSU.Write(Address: Cardinal; Value: Byte);
begin
  Address := Address and $33FF;
  if State.SFR.Running and (Address <> $3030) and (Address <> $303A) then
    Exit;
  if Address < $3020 then
  begin
    if (Address and 1) = 0 then
      State.RegisterLatch := Value
    else
    begin
      var Reg := (Address shr 1) and 15;
      State.R[Reg] := (Word(Value) shl 8) or State.RegisterLatch;
      if Reg = 14 then
      begin
        State.SFR.RomReadPending := True;
        State.RomDelay := 6 - Ord(State.ClockSelect);
      end
      else if Reg = 15 then
      begin
        State.SFR.Running := True;
        UpdateRunning;
      end;
    end;
    Exit;
  end;
  case Address of
    $3030:
      begin
        var Running := State.SFR.Running;
        State.SFR.Zero := (Value and 2) <> 0;
        State.SFR.Carry := (Value and 4) <> 0;
        State.SFR.Sign := (Value and 8) <> 0;
        State.SFR.Overflow := (Value and $10) <> 0;
        State.SFR.Running := (Value and $20) <> 0;
        if Running and not State.SFR.Running then
        begin
          State.CacheBase := 0;
          FillChar(FValid, SizeOf(FValid), 0);
        end;
        UpdateRunning;
      end;
    $3033:
      State.BackupRamEnabled := (Value and 1) <> 0;
    $3034:
      begin
        State.ProgramBank := Value and $7F;
        FillChar(FValid, SizeOf(FValid), 0);
      end;
    $3037:
      begin
        State.HighSpeedMode := (Value and $20) <> 0;
        State.IrqDisabled := (Value and $80) <> 0;
      end;
    $3038:
      State.ScreenBase := Value;
    $3039:
      State.ClockSelect := (Value and 1) <> 0;
    $303A:
      begin
        State.ColorGradient := Value and 3;
        State.PlotBpp := 4;
        if (Value and 3) = 0 then
          State.PlotBpp := 2
        else if (Value and 3) = 3 then
          State.PlotBpp := 8;
        State.ScreenHeight := ((Value and 4) shr 2) or ((Value and $20) shr 4);
        State.RamAccess := (Value and 8) <> 0;
        State.RomAccess := (Value and $10) <> 0;
        if State.RamAccess then
          FWaitRAM := False;
        if State.RomAccess then
          FWaitROM := False;
        UpdateRunning;
      end;
  end;
  if (Address >= $3100) and (Address <= $32FF) then
  begin
    var Index := (State.CacheBase + Address - $3100) and $1FF;
    FCache[Index] := Value;
    if (Index and 15) = 15 then
      FValid[Index shr 4] := True;
  end;
end;

function TSnesGSU.CPUReadROM(Address: Cardinal): Byte;
begin
  if State.SFR.Running and State.RomAccess then
  begin
    if (Address and 1) <> 0 then
      Exit(1);
    case Address and $E of
      4:
        Exit(4);
      $A:
        Exit(8);
      $E:
        Exit($C);
    else
      Exit(0);
    end;
  end;
  var Bank := Address shr 16 and $7F;
  if Bank < $40 then
    Result := FRead((Bank shl 15) or (Address and $7FFF))
  else
    Result := FRead(Address and $1FFFFF);
end;

function TSnesGSU.CPUReadRAM(Address: Cardinal; OpenBus: Byte): Byte;
begin
  if State.SFR.Running and State.RamAccess then
    Exit(0);
  if Length(RAM) = 0 then
    Exit(OpenBus);
  Result := RAM[Address mod Cardinal(Length(RAM))];
end;

procedure TSnesGSU.CPUWriteRAM(Address: Cardinal; Value: Byte);
begin
  if not (State.SFR.Running and State.RamAccess) then
    BusWrite($700000 or (Address and $1FFFF), Value);
end;

procedure TSnesGSU.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  Archive.Field(FCache, SizeOf(FCache));
  Archive.Field(FValid, SizeOf(FValid));
  Archive.Field(FWaitROM, SizeOf(FWaitROM));
  Archive.Field(FWaitRAM, SizeOf(FWaitRAM));
  Archive.Field(FStopped, SizeOf(FStopped));
  Archive.Field(FR15Changed, SizeOf(FR15Changed));
  if Length(RAM) > 0 then
    Archive.Field(RAM[0], Length(RAM));
end;

procedure TSnesGSU.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> Length(RAM) then
    raise EArgumentException.Create('GSU battery size mismatch');
  RAM := Copy(Data);
  FDirty := False;
end;

end.

