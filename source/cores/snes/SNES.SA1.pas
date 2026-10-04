unit SNES.SA1;

interface

uses
  System.SysUtils, SNES.CPU, Core.Snapshots;

type
  TSa1ReadROM = function(Address: Cardinal): Byte of object;

  TSa1State = packed record
    Registers: array[0..$5F] of Byte;
    Clock, MathStart, MathResult: UInt64;
    MathOverflow, CpuRequest, SaRequest, VarBit, ConvertCounter, OpenBus: Byte;
    DMA, ConvertActive: Boolean;
    VarAddress: Cardinal;
  end;

  TSnesSA1 = class
  private
    FRead: TSa1ReadROM;
    FCPU: TSnesCPU;
    FDirty, FNMILevel: Boolean;
    FHostMemory, FLastMemory: Byte;
    FHostFast: Boolean;
    function MemoryType(Address: Cardinal; SA: Boolean): Byte;
    procedure CPUCycle;
    procedure ControlIdle(PC: Word; Jump: Boolean);
    function CPURead(Address: Cardinal): Byte;
    procedure CPUWrite(Address: Cardinal; Value: Byte);
    procedure Idle(Clocks: Integer);
    function Vector(Address: Word): Word;
    function RomAddress(Address: Cardinal): Cardinal;
    function BwAddress(Address: Cardinal; SA: Boolean; out Bitmap: Boolean): Cardinal;
    function ReadBus(Address: Cardinal; OpenBus: Byte; SA: Boolean): Byte;
    procedure WriteBus(Address: Cardinal; Value: Byte; SA: Boolean);
    procedure WriteRegister(Address: Word; Value: Byte; SA: Boolean);
    function ReadRegister(Address: Word; OpenBus: Byte; SA: Boolean): Byte;
    procedure Interrupts;
    procedure Math;
    procedure VarIncrement;
    procedure DMA;
    function Param(Index, Count: Integer): Cardinal;
    procedure CharConvert2;
    function CharConvert1(Address: Cardinal): Byte;
  public
    State: TSa1State;
    IRAM: array[0..$7FF] of Byte;
    BWRAM: TBytes;
    constructor Create(ReadROM: TSa1ReadROM; RamSize: Integer);
    destructor Destroy; override;
    procedure Reset;
    procedure RunUntil(MasterClock: UInt64);
    function Read(Address: Cardinal; OpenBus: Byte): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    procedure HostAccess(Address: Cardinal; Fast: Boolean);
    function IRQ: Boolean;
    procedure SerializeState(Archive: TStateArchive);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    property CPU: TSnesCPU read FCPU;
    property BatteryDirty: Boolean read FDirty;
  end;

implementation

constructor TSnesSA1.Create(ReadROM: TSa1ReadROM; RamSize: Integer);
var
  ReadCallback: TSnesRead;
  WriteCallback: TSnesWrite;
  ClockCallback: TSnesClock;
  VectorCallback: TSnesVector;
  ControlCallback: TSnesControlIdle;
begin
  inherited Create;
  FRead := ReadROM;
  SetLength(BWRAM, RamSize);
  ReadCallback := Self.CPURead;
  WriteCallback := Self.CPUWrite;
  ClockCallback := Self.Idle;
  VectorCallback := Self.Vector;
  ControlCallback := Self.ControlIdle;
  FCPU := TSnesCPU.Create(ReadCallback, WriteCallback, ClockCallback, VectorCallback, ControlCallback);
  Reset;
end;

destructor TSnesSA1.Destroy;
begin
  FCPU.Free;
  inherited;
end;

procedure TSnesSA1.Reset;
begin
  State := Default(TSa1State);
  State.Registers[0] := $20;
  State.Registers[$28] := $F;
  for var J := 0 to 3 do
    State.Registers[$20 + J] := J;
  FNMILevel := False;
  FHostMemory := 0;
  FLastMemory := 1;
  FHostFast := False;
  FCPU.Reset;
end;

function TSnesSA1.MemoryType(Address: Cardinal; SA: Boolean): Byte;
begin
  var Bank := Address shr 16 and $FF;
  var Offset := Address and $FFFF;
  Result := 0;
  if (Bank and $7F) < $40 then
  begin
    if ((Offset >= $3000) and (Offset <= $3FFF)) or (SA and (Offset < $1000)) then
      Exit(3);
    if (Offset >= $2000) and (Offset <= $2FFF) then
      Exit(4);
    if (Offset >= $6000) and (Offset <= $7FFF) and (Length(BWRAM) > 0) then
      Exit(2);
    if Offset >= $8000 then
      Exit(1);
  end;

  if Bank >= $C0 then
    Exit(1);
  if (Length(BWRAM) > 0) and ((Bank in [$40..$4F]) or (SA and (Bank in [$50..$6F]))) then
    Exit(2);
end;

procedure TSnesSA1.HostAccess(Address: Cardinal; Fast: Boolean);
begin
  FHostMemory := MemoryType(Address, False);
  FHostFast := Fast;
end;

procedure TSnesSA1.CPUCycle;
begin
  Inc(State.Clock);
  if FLastMemory = 2 then
  begin
    Inc(State.Clock);
    if FHostMemory = 2 then
      Inc(State.Clock, 2);
  end
  else if (FLastMemory = FHostMemory) and (FLastMemory <> 4) then
  begin
    Inc(State.Clock);
    if (FLastMemory = 3) and FHostFast then
      Inc(State.Clock);
  end;
end;

procedure TSnesSA1.ControlIdle(PC: Word; Jump: Boolean);
begin
  if MemoryType(PC, True) <> 1 then
    Exit;

  if Jump then
  begin
    Inc(State.Clock);
    if FHostMemory = 1 then
      Inc(State.Clock);
  end
  else if (PC and 1) <> 0 then
    Inc(State.Clock);
end;

function TSnesSA1.Param(Index, Count: Integer): Cardinal;
begin
  Result := 0;
  for var J := 0 to Count - 1 do
    Result := Result or (Cardinal(State.Registers[Index + J]) shl (J * 8));
end;

procedure TSnesSA1.Idle(Clocks: Integer);
begin
  Inc(State.Clock);
end;

function TSnesSA1.Vector(Address: Word): Word;
begin
  case Address of
    $FFFC:
      Exit(Param(3, 2));
    $FFEA:
      Exit(Param(5, 2));
    $FFEE:
      Exit(Param(7, 2));
  end;

  Result := CPURead(Address);
  Result := Result or (Word(CPURead(Word(Address + 1))) shl 8);
end;

function TSnesSA1.RomAddress(Address: Cardinal): Cardinal;
begin
  var Bank := Address shr 16;
  var Group: Integer;
  if Bank >= $C0 then
    Exit((Cardinal(State.Registers[$20 + ((Bank - $C0) shr 4)] and 7) shl 20) or (Address and $FFFFF));

  Group := (Bank shr 5) and 1;
  if Bank >= $80 then
    Inc(Group, 2);
  var Base := Cardinal(Group) shl 20;
  var B := State.Registers[$20 + Group];
  if (B and $80) <> 0 then
    Base := Cardinal(B and 7) shl 20;
  Result := Base or ((Bank and $1F) shl 15) or (Address and $7FFF);
end;

function TSnesSA1.BwAddress(Address: Cardinal; SA: Boolean; out Bitmap: Boolean): Cardinal;
begin
  var Bank := Address shr 16;
  Bitmap := False;
  if SA and (Bank in [$60..$6F]) then
  begin
    Bitmap := True;
    Exit(Address - $600000);
  end;

  if (Bank in [$40..$5F]) then
    Exit(Address and $1FFFFF);

  if SA then
  begin
    Bitmap := (State.Registers[$25] and $80) <> 0;
    Result := Cardinal(State.Registers[$25] and $7F) * $2000;
  end
  else
    Result := Cardinal(State.Registers[$24] and $1F) * $2000;
  Result := Result or (Address and $1FFF);
end;

function TSnesSA1.ReadBus(Address: Cardinal; OpenBus: Byte; SA: Boolean): Byte;
begin
  Address := Address and $FFFFFF;
  var Bank := Address shr 16;
  var Offset := Address and $FFFF;
  if ((Bank and $7F) < $40) then
  begin
    if ((Offset >= $3000) and (Offset <= $3FFF)) or (SA and (Offset < $1000)) then
    begin
      if (Offset and $800) <> 0 then
        Exit(0);
      Exit(IRAM[Offset and $7FF]);
    end;

    if (Offset >= $2200) and (Offset <= $23FF) then
      Exit(ReadRegister(Offset, OpenBus, SA));
  end;
  if (Bank in [$40..$4F]) or (SA and (Bank in [$50..$6F])) or (((Bank and $7F) < $40) and (Offset >= $6000) and (Offset < $8000)) then
  begin
    if Length(BWRAM) = 0 then
      Exit(OpenBus);

    var Bitmap: Boolean;
    var A := BwAddress(Address, SA, Bitmap);
    if not SA and State.ConvertActive then
      Exit(CharConvert1(Address));

    var Shift, Mask: Cardinal;
    Shift := 0;
    Mask := $FF;
    if Bitmap then
      if (State.Registers[$3F] and $80) <> 0 then
      begin
        Shift := (A and 3) * 2;
        A := A shr 2;
        Mask := 3;
      end
      else
      begin
        Shift := (A and 1) * 4;
        A := A shr 1;
        Mask := $F;
      end;
    Exit((BWRAM[A mod Cardinal(Length(BWRAM))] shr Shift) and Mask);
  end;
  if (Bank >= $C0) or (((Bank and $7F) < $40) and (Offset >= $8000)) then
  begin
    if (Bank = 0) and not SA then
    begin
      if ((Offset = $FFEA) or (Offset = $FFEB)) and ((State.Registers[9] and $10) <> 0) then
        Exit(State.Registers[$C + (Offset and 1)]);
      if ((Offset = $FFEE) or (Offset = $FFEF)) and ((State.Registers[9] and $40) <> 0) then
        Exit(State.Registers[$E + (Offset and 1)]);
    end;
    Exit(FRead(RomAddress(Address)));
  end;
  Result := OpenBus;
end;

procedure TSnesSA1.WriteBus(Address: Cardinal; Value: Byte; SA: Boolean);
begin
  Address := Address and $FFFFFF;
  var Bank := Address shr 16;
  var Offset := Address and $FFFF;
  if (Bank and $7F) < $40 then
  begin
    if ((Offset >= $3000) and (Offset <= $3FFF)) or (SA and (Offset < $1000)) then
    begin
      var Protect := State.Registers[$29 + Ord(SA)];
      if ((Offset and $800) = 0) and ((Protect and (1 shl ((Offset shr 8) and 7))) <> 0) then
      begin
        IRAM[Offset and $7FF] := Value;
        if Length(BWRAM) = 0 then
          FDirty := True;
      end;
      Exit;
    end;

    if (Offset >= $2200) and (Offset <= $23FF) then
    begin
      WriteRegister(Offset, Value, SA);
      Exit;
    end;
  end;
  if (Bank in [$40..$4F]) or (SA and (Bank in [$50..$6F])) or (((Bank and $7F) < $40) and (Offset >= $6000) and (Offset < $8000)) then
  begin
    if Length(BWRAM) = 0 then
      Exit;

    var Bitmap: Boolean;
    var A := BwAddress(Address, SA, Bitmap);
    var Shift, Mask: Cardinal;
    Shift := 0;
    Mask := $FF;
    if Bitmap then
      if (State.Registers[$3F] and $80) <> 0 then
      begin
        Shift := (A and 3) * 2;
        A := A shr 2;
        Mask := 3;
      end
      else
      begin
        Shift := (A and 1) * 4;
        A := A shr 1;
        Mask := $F;
      end;
    A := A mod Cardinal(Length(BWRAM));
    var Area := State.Registers[$28] and $F;
    if Area > 10 then
      Area := 10;
    if ((State.Registers[$26] or State.Registers[$27]) and $80) = 0 then
      if (A and $3FFFF) < Cardinal(256 shl Area) then
        Exit;

    Value := (BWRAM[A] and not (Mask shl Shift)) or ((Value and Mask) shl Shift);
    if BWRAM[A] <> Value then
    begin
      BWRAM[A] := Value;
      FDirty := True;
    end;
  end;
end;

function TSnesSA1.CPURead(Address: Cardinal): Byte;
begin
  CPUCycle;
  Result := ReadBus(Address, State.OpenBus, True);
  var Kind := MemoryType(Address, True);
  if Kind <> 0 then
  begin
    FLastMemory := Kind;
    State.OpenBus := Result;
  end;
end;

procedure TSnesSA1.CPUWrite(Address: Cardinal; Value: Byte);
begin
  CPUCycle;
  WriteBus(Address, Value, True);
  var Kind := MemoryType(Address, True);
  if Kind <> 0 then
  begin
    FLastMemory := Kind;
    State.OpenBus := Value;
  end;
end;

procedure TSnesSA1.Interrupts;
begin
  FCPU.State.IRQ := ((State.SaRequest and State.Registers[$A] and $80) <> 0) or ((State.SaRequest and State.Registers[$A] and $20) <> 0);
  var NMI := (State.SaRequest and State.Registers[$A] and $10) <> 0;
  if NMI and not FNMILevel then
    FCPU.State.NMI := True;
  FNMILevel := NMI;
end;

function TSnesSA1.IRQ: Boolean;
begin
  Result := (State.CpuRequest and State.Registers[1] and $A0) <> 0;
end;

procedure TSnesSA1.VarIncrement;
begin
  var Count := State.Registers[$58] and $F;
  if State.Registers[$58] = 0 then
    Count := 16;
  Inc(State.VarBit, Count);
  Inc(State.VarAddress, State.VarBit shr 3);
  State.VarBit := State.VarBit and 7;
end;

procedure TSnesSA1.Math;
begin
  if State.MathStart = 0 then
    Exit;

  var Mode := State.Registers[$50] and 3;
  var Delay := 5;
  if (Mode and 2) <> 0 then
    Delay := 6;
  if State.Clock - State.MathStart < UInt64(Delay) then
    Exit;

  State.MathStart := 0;
  var A := SmallInt(Param($51, 2));
  var B := Word(Param($53, 2));
  if (Mode and 2) <> 0 then
  begin
    var V := UInt64((Int64(State.MathResult) + Int64(A) * SmallInt(B)) and $1FFFFFFFFFF);
    State.MathOverflow := (V shr 33) and $80;
    State.MathResult := V and $FFFFFFFFFF;
  end
  else if Mode = 0 then
    State.MathResult := Cardinal(Integer(A) * Integer(SmallInt(B)))
  else
  begin
    State.MathResult := 0;
    if B <> 0 then
    begin
      var R := Word(Integer(A) mod Integer(B));
      if A < 0 then
        R := (Integer(R) + B) and $FFFF;
      var Q := Word((Integer(A) - Integer(R)) div Integer(B));
      State.MathResult := (Cardinal(R) shl 16) or Q;
    end;
    State.Registers[$51] := 0;
    State.Registers[$52] := 0;
  end;
  State.Registers[$53] := 0;
  State.Registers[$54] := 0;
end;

procedure TSnesSA1.DMA;
begin
  var Size := Param($38, 2);
  var Src := Param($32, 3);
  var Dest := Param($35, 3);
  var Control := State.Registers[$30];
  if Size > 0 then
  begin
    var SourceDevice := Control and 3;
    var ToBW := (Control and 4) <> 0;
    var Valid := ((SourceDevice = 0) or ((SourceDevice = 1) and not ToBW) or ((SourceDevice = 2) and ToBW));
    if Valid then
    begin
      var Delay := 2;
      if (SourceDevice = 0) and not ToBW then
      begin
        Delay := 1;
        if FHostMemory in [1, 3] then
          Inc(Delay);
        if FHostMemory = 3 then
          Inc(Delay);
      end
      else if (SourceDevice = 0) and ToBW then
      begin
        if FHostMemory = 2 then
          Inc(Delay, 2);
      end
      else
      begin
        if FHostMemory in [2, 3] then
          Inc(Delay);
        if FHostMemory = 2 then
          Inc(Delay);
      end;
      var V: Byte := 0;
      case SourceDevice of
        0:
          begin
            V := ReadBus(Src, State.OpenBus, True);
            var Kind := MemoryType(Src, True);
            if Kind <> 0 then
            begin
              FLastMemory := Kind;
              State.OpenBus := V;
            end;
          end;
        1:
          if Length(BWRAM) > 0 then
            V := BWRAM[Src mod Cardinal(Length(BWRAM))];
        2:
          V := IRAM[Src and $7FF];
      end;
      if not ToBW then
        IRAM[Dest and $7FF] := V
      else if Length(BWRAM) > 0 then
      begin
        BWRAM[Dest mod Cardinal(Length(BWRAM))] := V;
        FDirty := True;
      end;
      Inc(State.Clock, Delay);
    end;
    Inc(Src);
    Inc(Dest);
    Dec(Size);
    for var J := 0 to 2 do
    begin
      State.Registers[$32 + J] := Byte(Src shr (J * 8));
      State.Registers[$35 + J] := Byte(Dest shr (J * 8));
    end;
    State.Registers[$38] := Byte(Size);
    State.Registers[$39] := Byte(Size shr 8);
  end;
  if Size = 0 then
  begin
    State.DMA := False;
    State.SaRequest := State.SaRequest or $20;
    Interrupts;
  end;
end;

procedure TSnesSA1.CharConvert2;
begin
  var Format := State.Registers[$31] and 3;
  if Format > 2 then
    Format := 2;
  var Bpp := 8 shr Format;
  var Dest := (Param($35, 3) and $7FF) and not (Cardinal((Bpp shl 4) - 1));
  Inc(Dest, (State.ConvertCounter and 7) * 2 + (State.ConvertCounter and 8) * Bpp);
  var Base := $40 + (State.ConvertCounter and 1) * 8;
  for var Plane := 0 to Bpp - 1 do
  begin
    var V: Byte := 0;
    for var J := 0 to 7 do
      V := V or (((State.Registers[Base + J] shr Plane) and 1) shl (7 - J));
    IRAM[(Dest + Cardinal((Plane shr 1) shl 4) + Cardinal(Plane and 1)) and $7FF] := V;
  end;
  State.ConvertCounter := (State.ConvertCounter + 1) and $F;
end;

function TSnesSA1.CharConvert1(Address: Cardinal): Byte;
begin
  var Format := State.Registers[$31] and 3;
  if Format > 2 then
    Format := 2;
  var Bpp := 8 shr Format;
  var Mask := Cardinal(Bpp * 8 - 1);
  var Dest := Param($35, 3);
  if (Address and Mask) = 0 then
  begin
    var Width := (State.Registers[$31] shr 2) and 7;
    if Width > 5 then
      Width := 5;
    var Tiles := 1 shl Width;
    var BytesPerLine := (Tiles * 8) shr Format;
    var Source := Param($32, 3);
    var TileNumber := ((Address - Source) and (Length(BWRAM) - 1)) shr (6 - Format);
    var Src := Source + (TileNumber shr Width) * 8 * Cardinal(BytesPerLine) + (TileNumber and Cardinal(Tiles - 1)) * Cardinal(Bpp);
    for var Y := 0 to 7 do
    begin
      var Bits: UInt64 := 0;
      for var J := 0 to Bpp - 1 do
        Bits := Bits or (UInt64(BWRAM[(Src + Cardinal(J)) mod Cardinal(Length(BWRAM))]) shl (J * 8));
      Inc(Src, BytesPerLine);
      var Values: array[0..7] of Byte;
      FillChar(Values, SizeOf(Values), 0);
      for var X := 0 to 7 do
        for var Plane := 0 to Bpp - 1 do
        begin
          Values[Plane] := Values[Plane] or ((Bits and 1) shl (7 - X));
          Bits := Bits shr 1;
        end;
      for var Plane := 0 to Bpp - 1 do
        IRAM[(Dest + Cardinal(Y * 2) + Cardinal((Plane shr 1) shl 4) + Cardinal(Plane and 1)) and $7FF] := Values[Plane];
    end;
  end;
  Result := IRAM[(Dest + (Address and Mask)) and $7FF];
end;

procedure TSnesSA1.WriteRegister(Address: Word; Value: Byte; SA: Boolean);
begin
  if (Address < $2200) or (Address > $225B) then
    Exit;

  var Index := Address - $2200;
  if SA then
  begin
    if not ((Index in [9..$15, $25, $27, $2A, $30..$39, $3F..$54, $58..$5B])) then
      Exit;
  end
  else if not (Index in [0..8, $20..$24, $26, $28, $29, $31..$37]) then
    Exit;

  if Index in [$50..$54] then
    Math;
  var Previous := State.Registers[Index];
  State.Registers[Index] := Value;
  case Index of
    0:
      begin
        if ((Previous and $20) <> 0) and ((Value and $20) = 0) then
        begin
          var Clock := State.Clock;
          State.Registers[$2A] := 0;
          FCPU.Reset;
          State.Clock := Clock;
        end;
        State.SaRequest := (State.SaRequest and $20) or (Value and $90);
        Interrupts;
      end;
    1, $A:
      Interrupts;
    2:
      begin
        State.CpuRequest := State.CpuRequest and not (Value and $A0);
        Interrupts;
      end;
    9:
      begin
        State.CpuRequest := (State.CpuRequest and $20) or (Value and $80);
        Interrupts;
      end;
    $B:
      begin
        State.SaRequest := State.SaRequest and not (Value and $B0);
        Interrupts;
      end;
    $30:
      if (Value and $80) = 0 then
        State.ConvertCounter := 0;
    $31:
      if (Value and $80) <> 0 then
        State.ConvertActive := False;
    $36, $37:
      begin
        var C := State.Registers[$30];
        if (C and $80) <> 0 then
          if (C and $20) = 0 then
          begin
            if ((Index = $36) and ((C and 4) = 0)) or ((Index = $37) and ((C and 4) <> 0)) then
              State.DMA := True;
          end
          else if (Index = $36) and ((C and $10) <> 0) then
          begin
            State.ConvertActive := True;
            State.CpuRequest := State.CpuRequest or $20;
          end;
      end;
    $47, $4F:
      if (State.Registers[$30] and $B0) = $A0 then
        CharConvert2;
    $50:
      if (Value and 2) <> 0 then
        State.MathResult := 0;
    $54:
      State.MathStart := State.Clock;
    $58:
      if (Value and $80) = 0 then
        VarIncrement;
    $59..$5B:
      begin
        State.VarAddress := Param($59, 3);
        if Index = $5B then
          State.VarBit := 0;
      end;
  end;
end;

function TSnesSA1.ReadRegister(Address: Word; OpenBus: Byte; SA: Boolean): Byte;
begin
  Result := OpenBus;
  if not SA then
  begin
    if Address = $2300 then
      Result := (State.Registers[9] and $5F) or State.CpuRequest;
    Exit;
  end;

  case Address of
    $2301:
      Result := (State.Registers[0] and $F) or State.SaRequest;
    $2306..$230A:
      begin
        Math;
        Result := Byte(State.MathResult shr ((Address - $2306) * 8));
      end;
    $230B:
      begin
        Math;
        Result := State.MathOverflow;
      end;
    $230C, $230D:
      begin
        var V := Cardinal(ReadBus(State.VarAddress, 0, True)) or (Cardinal(ReadBus(State.VarAddress + 1, 0, True)) shl 8) or (Cardinal(ReadBus(State.VarAddress + 2, 0, True)) shl 16);
        Result := Byte(V shr (State.VarBit + Ord(Address = $230D) * 8));
        if (Address = $230D) and ((State.Registers[$58] and $80) <> 0) then
          VarIncrement;
      end;
  end;
end;

procedure TSnesSA1.RunUntil(MasterClock: UInt64);
begin
  var Target := MasterClock div 2;
  while State.Clock < Target do
  begin
    if (State.Registers[0] and $60) <> 0 then
    begin
      State.Clock := Target;
      Break;
    end
    else if State.DMA then
      DMA
    else
    begin
      Interrupts;
      FCPU.Step;
    end;
  end;
end;

function TSnesSA1.Read(Address: Cardinal; OpenBus: Byte): Byte;
begin
  Result := ReadBus(Address, OpenBus, False);
end;

procedure TSnesSA1.Write(Address: Cardinal; Value: Byte);
begin
  WriteBus(Address, Value, False);
end;

procedure TSnesSA1.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  Archive.Field(IRAM, SizeOf(IRAM));
  if Length(BWRAM) > 0 then
    Archive.Field(BWRAM[0], Length(BWRAM));
  FCPU.SerializeState(Archive);
  Archive.Field(FNMILevel, SizeOf(FNMILevel));
  Archive.Field(FHostMemory, SizeOf(FHostMemory));
  Archive.Field(FLastMemory, SizeOf(FLastMemory));
  Archive.Field(FHostFast, SizeOf(FHostFast));
end;

function TSnesSA1.Battery: TBytes;
begin
  if Length(BWRAM) > 0 then
    Result := Copy(BWRAM)
  else
  begin
    SetLength(Result, SizeOf(IRAM));
    Move(IRAM, Result[0], SizeOf(IRAM));
  end;
end;

procedure TSnesSA1.LoadBattery(const Data: TBytes);
begin
  var Size := Length(BWRAM);
  if Size = 0 then
    Size := SizeOf(IRAM);
  if Length(Data) <> Size then
    raise EArgumentException.Create('SA1 battery size mismatch');

  if Length(BWRAM) > 0 then
    BWRAM := Copy(Data)
  else
    Move(Data[0], IRAM, Size);
  FDirty := False;
end;

end.

