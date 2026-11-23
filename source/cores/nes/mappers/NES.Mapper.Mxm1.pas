unit NES.Mapper.Mxm1;

interface

uses
  NES.Mapper, NES.State, NES.Types;

type
  TMapperMxm1 = class(TMapper)
  private
    type
      TMemory = (Unmapped, ProgramRom, Graphics, WorkRam);

      TWindow = packed record
        Memory: TMemory;
        Offset: Integer;
      end;

      TRegisters = packed record
        PrgBank: array[0..4] of Word;
        PrgFlags: array[0..4] of Byte;
        ChrBank: array[0..15] of Word;
        ChrFlags: array[0..15] of Byte;
        NameBank, DescriptorBank: array[0..3] of Word;
        NameFlags, DescriptorFlags, MetatileTable: array[0..3] of Byte;
        PrgSelect, PrgMode, ChrSelect, ChrMode, NameSelect, NameMode, DescriptorSelect, DescriptorMode: Byte;
        AlternateFlags, CopySource, CopyDestination, ReadLatch, StreamPosition: Byte;
        PlaneMode, PlaneSelect, ReadInhibit, MetatileControl, MetatileStride, MetatileFrame: Byte;
        ScrollY, Vertical, ManualScroll, RemapControl, RemapPage: Byte;
        WriteBank, AlternateBank, CopyFrom, CopyTo: Word;
        RemapCursor: Integer;
        AlternateEnabled, ScrollUpdated: Boolean;
        IrqEnabled, IrqMatched, PreviousIrqMatch, IrqLine, InFrame, FrameStart: Boolean;
        Scanline, IrqTarget, IrqOffset, IrqPhase: Byte;
        LastFetch, NameReads, DescriptorCell: Word;
        RepeatedFetches, DescriptorTable, TileRow: Byte;
        MetatileLow, MetatileHigh, MetatilePalette: Byte;
        Remap: array[0..$3FF] of Byte;
      end;
  private
    FPrg, FChr, FRam: TByteArray;
    FState: TRegisters;
    FPrgWindow: array[0..4] of TWindow;
    FChrWindow: array[0..15] of TWindow;
    FNameWindow: array[0..3] of TWindow;
    procedure UpdatePrgWindow(Slot: Integer);
    function ReadBacking(Memory: TMemory; Offset: Integer; Fallback: Byte): Byte;
    function ReadMappedPpu(Address: Word; out Value: Byte): Boolean;
    function ReadStateByte: Byte;
    function ReadCpuPort(Address: Word; out Value: Byte; SideEffects: Boolean): Boolean;
    procedure CopyBlocks(Count: Byte);
    procedure ObserveFetch(Address: Word; IsName: Boolean);
    procedure PrepareMetatile(Address: Word; Row: Byte);
    function DescriptorByte(Offset: Integer): Byte;
    function DescriptorAttribute(Row: Byte): Byte;
    function DescriptorPattern(Address: Word): Byte;
  public
    constructor Create(const Prg, Chr: TByteArray; WorkRamSize: Integer);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuPeek(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function Fetch(var Address: Word; Dot: Integer; out Value: Byte): Boolean;
    procedure CpuIoWrite(Address: Word; Value: Byte); override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
  end;

implementation

const
  RAM_FLAG = $80;
  GRAPHICS_APERTURE = $40;

procedure WriteByte(var Bank: Word; HighByte: Boolean; Value: Byte); inline;
begin
  if HighByte then
    Bank := (Bank and $FF) or (Word(Value) shl 8)
  else
    Bank := (Bank and $FF00) or Value;
end;

function Mapping(Memory: TMapperMxm1.TMemory; Offset: Integer): TMapperMxm1.TWindow; inline;
begin
  Result.Memory := Memory;
  Result.Offset := Offset;
end;

function GraphicsSource(Flags: Byte): TMapperMxm1.TMemory; inline;
begin
  if (Flags and RAM_FLAG) <> 0 then
    Result := TMapperMxm1.TMemory.WorkRam
  else
    Result := TMapperMxm1.TMemory.Graphics;
end;

constructor TMapperMxm1.Create(const Prg, Chr: TByteArray; WorkRamSize: Integer);
begin
  inherited Create;
  ValidateMemory(Prg, Chr);
  if (Length(Chr) = 0) or (WorkRamSize <> $100000) then
    raise ENesException.Create('Invalid MXM-1 memory layout');
  FPrg := Prg;
  FChr := Chr;
  SetLength(FRam, WorkRamSize);
  Reset;
end;

procedure TMapperMxm1.Reset;
begin
  FState := Default(TRegisters);
  FState.PrgFlags[0] := RAM_FLAG;
  FState.PrgBank[2] := 1;
  FState.PrgBank[3] := 2;
  FState.PrgBank[4] := $FFFF;
  FState.MetatileStride := 8;
  for var Slot := 0 to High(FPrgWindow) do
    UpdatePrgWindow(Slot);
  for var Slot := 0 to High(FChrWindow) do
    FChrWindow[Slot] := Mapping(TMemory.Graphics, ($100 + Slot) * $200);
  FChrWindow[10].Offset := 3 * $200;
  FillChar(FNameWindow, SizeOf(FNameWindow), 0);
end;

procedure TMapperMxm1.UpdatePrgWindow(Slot: Integer);
begin
  var Bank := FState.PrgBank[Slot];
  var Flags := FState.PrgFlags[Slot];
  if (Slot = 3) and FState.AlternateEnabled then
  begin
    Bank := FState.AlternateBank;
    Flags := FState.AlternateFlags;
  end;

  var Memory := TMemory.ProgramRom;
  var Size := Length(FPrg);
  if (Flags and RAM_FLAG) <> 0 then
  begin
    Memory := TMemory.WorkRam;
    Size := Length(FRam);
  end
  else if (Flags and GRAPHICS_APERTURE) <> 0 then
  begin
    Memory := TMemory.Graphics;
    Size := Length(FChr);
  end;

  var WindowCount := Size div $2000;
  if (Flags and GRAPHICS_APERTURE) <> 0 then
  begin
    if Bank < WindowCount then
      FPrgWindow[Slot] := Mapping(Memory, Integer(Bank) * $2000);
    Exit;
  end;
  if Bank >= $8000 then
    FPrgWindow[Slot] := Mapping(Memory, Integer((Cardinal(Bank) or $FFFF0000) mod Cardinal(WindowCount)) * $2000)
  else
    FPrgWindow[Slot] := Mapping(Memory, (Bank mod WindowCount) * $2000);
end;

function TMapperMxm1.ReadBacking(Memory: TMemory; Offset: Integer; Fallback: Byte): Byte;
begin
  case Memory of
    TMemory.ProgramRom:
      Result := FPrg[Offset mod Length(FPrg)];
    TMemory.Graphics:
      Result := FChr[Offset mod Length(FChr)];
    TMemory.WorkRam:
      Result := FRam[Offset mod Length(FRam)];
  else
    Result := Fallback;
  end;
end;

function TMapperMxm1.ReadStateByte: Byte;
begin
  case FState.StreamPosition of
    0:
      Result := FState.PrgMode;
    1:
      Result := FState.PrgSelect;
    2:
      Result := Hi(FState.PrgBank[0]);
    3:
      Result := Lo(FState.PrgBank[0]);
    $32:
      Result := FState.DescriptorSelect;
    $33:
      Result := Hi(FState.DescriptorBank[0]);
    $34:
      Result := Lo(FState.DescriptorBank[0]);
    $50:
      Result := FState.PlaneMode and 1;
    $51:
      Result := (FState.PlaneMode shr 1) and 1;
    $52:
      Result := FState.PlaneSelect and 1;
    $53:
      Result := FState.PlaneSelect and 2;
  else
    Result := $FF;
  end;
end;

function TMapperMxm1.ReadCpuPort(Address: Word; out Value: Byte; SideEffects: Boolean): Boolean;
const
  Identity: array[0..5] of Byte = ($9F, 0, $17, $14, $17, $14);
begin
  if Address >= $6000 then
  begin
    if SideEffects and ((Address = $FFFA) or (Address = $FFFB)) then
    begin
      FState.InFrame := False;
      FState.LastFetch := 0;
      FState.RepeatedFetches := 0;
      FState.Scanline := 0;
      FState.IrqMatched := False;
      FState.IrqLine := False;
    end;
    var Slot := (Address - $6000) shr 13;
    var Window := FPrgWindow[Slot];
    if (Slot = 3) and FState.AlternateEnabled then
    begin
      var Memory := TMemory.ProgramRom;
      if (FState.AlternateFlags and RAM_FLAG) <> 0 then
        Memory := TMemory.WorkRam;
      Window := Mapping(Memory, Integer(FState.AlternateBank) * $2000);
    end;
    Value := ReadBacking(Window.Memory, Window.Offset + (Address and $1FFF), FCpuOpenBus);
    if (FState.PrgFlags[Slot] and GRAPHICS_APERTURE) <> 0 then
    begin
      if SideEffects then
        FState.ReadLatch := Value;
      Value := 0;
    end;
    Exit(True);
  end;

  case Address of
    $5000..$5005:
      Value := Identity[Address - $5000];
    $5006:
      begin
        Value := ReadStateByte;
        if SideEffects then
          FState.StreamPosition := (Integer(FState.StreamPosition) + 1) and $FF;
      end;
    $5007:
      Value := FState.StreamPosition;
    $5010..$501B:
      begin
        var Index := Address - $5010;
        var Slot := Index div 3;
        case Index mod 3 of
          0:
            Value := Slot or FState.PrgFlags[Slot];
          1:
            Value := Hi(FState.PrgBank[Slot]);
        else
          Value := Lo(FState.PrgBank[Slot]);
        end;
      end;
    $501C:
      Value := FState.PrgSelect or FState.PrgFlags[FState.PrgSelect];
    $5033:
      begin
        Value := FState.IrqPhase;
        if SideEffects then
        begin
          FState.IrqMatched := False;
          FState.IrqLine := False;
        end;
      end;
    $50B0:
      Value := FState.ReadLatch;
    $50E0:
      begin
        Value := FState.RemapControl;
        if SideEffects then
          FState.RemapCursor := 0;
      end;
    $5116:
      Value := FState.Scanline;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperMxm1.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := ReadCpuPort(Address, Value, True);
end;

function TMapperMxm1.CpuPeek(Address: Word; out Value: Byte): Boolean;
begin
  Result := ReadCpuPort(Address, Value, False);
end;

procedure TMapperMxm1.CopyBlocks(Count: Byte);
begin
  if Count = 0 then
    Exit;
  var Source: TByteArray;
  case FState.CopySource of
    1, 3:
      Source := FRam;
    2:
      Source := FChr;
  else
    Source := FPrg;
  end;
  var FromOffset := Integer(FState.CopyFrom) * $2000;
  var ToOffset := Integer(FState.CopyTo) * $2000;
  var Size := Integer(Count) * $2000;
  if (FromOffset + Size > Length(Source)) or (ToOffset + Size > Length(FRam)) then
    Exit;

  // The copier advances in ascending order, including across overlapping work RAM.
  if (FState.CopySource in [1, 3]) and (ToOffset > FromOffset) and (ToOffset < FromOffset + Size) then
    for var Index := 0 to Size - 1 do
      FRam[ToOffset + Index] := FRam[FromOffset + Index]
  else
    Move(Source[FromOffset], FRam[ToOffset], Size);
end;

function TMapperMxm1.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if Address >= $6000 then
  begin
    var Window := FPrgWindow[(Address - $6000) shr 13];
    if Window.Memory = TMemory.WorkRam then
      FRam[(Window.Offset + (Address and $1FFF)) mod Length(FRam)] := Value;
    Exit(True);
  end;

  case Address of
    $5007:
      FState.StreamPosition := Value;
    $5010:
      FState.PrgMode := Value and 3;
    $5011:
      begin
        FState.PrgSelect := Value and 3;
        FState.PrgFlags[FState.PrgSelect] := Value and $F8;
      end;
    $5012, $5013:
      begin
        var Slot := FState.PrgSelect;
        WriteByte(FState.PrgBank[Slot], Address = $5012, Value);
        if (Slot <> 3) or not FState.AlternateEnabled then
          UpdatePrgWindow(Slot);
      end;
    $5014:
      begin
        var Enabled := Odd(Value);
        if FState.AlternateEnabled <> Enabled then
        begin
          FState.AlternateEnabled := Enabled;
          UpdatePrgWindow(3);
        end;
      end;
    $5015:
      FState.AlternateFlags := Value and RAM_FLAG;
    $5016, $5017:
      begin
        WriteByte(FState.AlternateBank, Address = $5016, Value);
        if FState.AlternateEnabled then
          UpdatePrgWindow(3);
      end;
    $5020:
      FState.ChrMode := Value and 3;
    $5021:
      begin
        FState.ChrSelect := Value and $0F;
        FState.ChrFlags[FState.ChrSelect] := Value and RAM_FLAG;
      end;
    $5022, $5023:
      begin
        var Slot := FState.ChrSelect;
        WriteByte(FState.ChrBank[Slot], Address = $5022, Value);
        FChrWindow[Slot] := Mapping(GraphicsSource(FState.ChrFlags[Slot]), FState.ChrBank[Slot] * $200);
      end;
    $5030:
      FState.IrqEnabled := Odd(Value);
    $5031:
      FState.IrqTarget := Value;
    $5032:
      FState.IrqOffset := Value;
    $5040:
      FState.DescriptorMode := Value and $83;
    $5041:
      begin
        FState.DescriptorSelect := Value and 3;
        FState.DescriptorFlags[FState.DescriptorSelect] := Value and $C0;
      end;
    $5042, $5043:
      WriteByte(FState.DescriptorBank[FState.DescriptorSelect], Address = $5042, Value);
    $504E:
      FState.ManualScroll := Value;
    $504F:
      FState.Vertical := Value;
    $5050:
      begin
        FState.NameMode := Value and $83;
        if (Value and $80) = 0 then
          FillChar(FNameWindow, SizeOf(FNameWindow), 0);
      end;
    $5051:
      begin
        FState.NameSelect := Value and 3;
        FState.NameFlags[FState.NameSelect] := Value and RAM_FLAG;
      end;
    $5052, $5053:
      begin
        var Slot := FState.NameSelect;
        WriteByte(FState.NameBank[Slot], Address = $5052, Value);
        if (FState.NameMode and $80) <> 0 then
          FNameWindow[Slot] := Mapping(GraphicsSource(FState.NameFlags[Slot]), FState.NameBank[Slot] * $400);
      end;
    $5080:
      FState.PlaneMode := Value and 3;
    $5081:
      FState.PlaneSelect := Value and 3;
    $5082:
      FState.ReadInhibit := Value;
    $5092, $5093:
      WriteByte(FState.WriteBank, Address = $5092, Value);
    $50C1:
      FState.CopySource := Value and 3;
    $50C2:
      FState.CopyDestination := Value and 3;
    $50C3, $50C4:
      WriteByte(FState.CopyFrom, Address = $50C4, Value);
    $50C5, $50C6:
      WriteByte(FState.CopyTo, Address = $50C6, Value);
    $50C7:
      CopyBlocks(Value);
    $50D0:
      FState.MetatileControl := Value and 1;
    $50D1..$50D4:
      FState.MetatileTable[Address - $50D1] := Value;
    $50D5:
      FState.MetatileStride := 8 shl (Value and 3);
    $50D6:
      FState.MetatileFrame := Value;
    $50E0:
      FState.RemapControl := Value and 1;
    $50E1:
      if FState.RemapCursor < Length(FState.Remap) then
      begin
        FState.Remap[FState.RemapCursor] := Value;
        Inc(FState.RemapCursor);
      end;
    $50E2:
      FState.RemapPage := Value and 3;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperMxm1.GetMirrorMode: TMirrorMode;
begin
  Result := TMirrorMode.FourScreen;
end;

function TMapperMxm1.ReadMappedPpu(Address: Word; out Value: Byte): Boolean;
begin
  if Address < $2000 then
  begin
    var Window := FChrWindow[Address shr 9];
    Value := ReadBacking(Window.Memory, Window.Offset + (Address and $1FF), Lo(Address));
    Exit(True);
  end;

  var Window := FNameWindow[(Address shr 10) and 3];
  Result := Window.Memory <> TMemory.Unmapped;
  if Result then
    Value := ReadBacking(Window.Memory, Window.Offset + (Address and $3FF), Lo(Address));
end;

function TMapperMxm1.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if FState.ReadInhibit <> 0 then
  begin
    Value := 0;
    Exit(True);
  end;
  Result := ReadMappedPpu(Address, Value);
end;

function TMapperMxm1.PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean;
begin
  Result := ReadMappedPpu(Address, Value);
end;

function TMapperMxm1.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if (FState.NameMode and $80) <> 0 then
  begin
    var Offset := (Cardinal(FState.WriteBank) shl 16) or Address;
    if Offset < Cardinal(Length(FRam)) then
      FRam[Offset] := Value;
    Exit(True);
  end;
  if Address >= $2000 then
    Exit(False);
  var Window := FChrWindow[Address shr 9];
  if Window.Memory = TMemory.WorkRam then
    FRam[(Window.Offset + (Address and $1FF)) mod Length(FRam)] := Value;
  Result := True;
end;

procedure TMapperMxm1.ObserveFetch(Address: Word; IsName: Boolean);
begin
  if IsName then
  begin
    FState.NameReads := (Integer(FState.NameReads) + 1) and $FFFF;
    if not FState.InFrame and FState.FrameStart then
    begin
      FState.FrameStart := False;
      FState.InFrame := True;
    end;
  end;
  if (Address < $2000) or (Address >= $3000) or (Address <> FState.LastFetch) then
    FState.RepeatedFetches := 0
  else
  begin
    if FState.RepeatedFetches < 3 then
      Inc(FState.RepeatedFetches);
    if FState.RepeatedFetches = 2 then
    begin
      FState.NameReads := 0;
      if not FState.InFrame and not FState.FrameStart then
      begin
        FState.FrameStart := True;
        FState.Scanline := 0;
      end
      else
      begin
        FState.Scanline := (Integer(FState.Scanline) + 1) and $FF;
        if FState.Scanline = FState.IrqTarget then
        begin
          FState.IrqMatched := True;
          FState.IrqLine := FState.IrqEnabled;
        end;
      end;
    end;
  end;
  FState.LastFetch := Address;
  if IsName and (FState.NameReads = 33) then
    FState.Vertical := (Integer(FState.Vertical) + 1) and $FF;
  if (FState.ManualScroll = 0) and FState.ScrollUpdated then
  begin
    FState.ScrollUpdated := False;
    FState.Vertical := FState.ScrollY;
  end;
end;

procedure TMapperMxm1.PrepareMetatile(Address: Word; Row: Byte);
begin
  var Selector := FState.MetatileTable[(Address shr 10) and 3];
  var Base: Integer;
  case Selector of
    0, 1:
      Base := $B8000 + Integer(Selector) * $4000;
    2..8:
      Base := $E4000 + Integer(Selector - 2) * $4000;
  else
    Base := $BA800;
  end;
  var Cell := ((Address and $3E0) shl 3) or ((Row and 7) shl 5) or (Address and $1F);
  Inc(Base, Cell * 2);
  var Id := (Word(FRam[Base]) shl 8) or FRam[Base + 1];
  if (Id and $C000) = $C000 then
  begin
    var Animation := $C0000 + 2 * (Integer(Id and $3FFF) * FState.MetatileStride + FState.MetatileFrame);
    Id := (Word(ReadBacking(TMemory.WorkRam, Animation, 0)) shl 8) or
      ReadBacking(TMemory.WorkRam, Animation + 1, 0);
  end;
  var SecondSet := (FState.PlaneMode and FState.PlaneSelect and 1) <> 0;
  Base := $80000 + Integer(Id) * 4 + 2 * Ord(SecondSet);
  FState.MetatileLow := ReadBacking(TMemory.WorkRam, Base, 0);
  FState.MetatileHigh := ReadBacking(TMemory.WorkRam, Base + 1, 0);
  var Palette := ReadBacking(TMemory.WorkRam, $B0000 + (Id shr 1), 0);
  var Shift := 6 - 4 * Ord(Odd(Id)) - 2 * Ord(SecondSet);
  FState.MetatilePalette := ((Palette shr Shift) and 3) * $55;
end;

function TMapperMxm1.DescriptorByte(Offset: Integer): Byte;
begin
  Result := ReadBacking(GraphicsSource(FState.DescriptorFlags[FState.DescriptorTable]), Offset, 0);
end;

function TMapperMxm1.DescriptorAttribute(Row: Byte): Byte;
begin
  var Offset := FState.DescriptorBank[FState.DescriptorTable] * $800 + FState.DescriptorCell * 2;
  var Shift := 6;
  case FState.DescriptorMode and 3 of
    1:
      Inc(Offset, FState.TileRow * $800);
    2:
      begin
        Inc(Offset, $800 + ((Row and 7) shr 2));
        Shift := 6 - 2 * (Row and 3);
      end;
  end;
  if ((FState.DescriptorMode and 3) < 2) and ((FState.PlaneMode and FState.PlaneSelect and 1) <> 0) then
    Shift := 4;
  Result := ((DescriptorByte(Offset) shr Shift) and 3) * $55;
end;

function TMapperMxm1.DescriptorPattern(Address: Word): Byte;
begin
  var Table := FState.DescriptorTable;
  var Offset := FState.DescriptorBank[Table] * $800 + FState.DescriptorCell * 2;
  var PatternBank := ((DescriptorByte(Offset) and $0F) shl 8) or DescriptorByte(Offset + 1);
  if (FState.PlaneMode and 1) <> 0 then
    PatternBank := PatternBank * 2 + (FState.PlaneSelect and 1);
  if FState.RemapControl <> 0 then
    Address := (Address and $FFF8) or FState.TileRow;
  var Memory := TMemory.Graphics;
  if (FState.DescriptorFlags[Table] and $40) <> 0 then
    Memory := TMemory.WorkRam;
  Result := ReadBacking(Memory, PatternBank * $1000 + (Address and $FFF), 0);
end;

function TMapperMxm1.Fetch(var Address: Word; Dot: Integer; out Value: Byte): Boolean;
begin
  var IsName := (Address >= $2000) and (Address < $3000) and ((Address and $3FF) < $3C0);
  var IsDummyAttribute := IsName and (Dot >= 260) and (Dot <= 316) and ((Dot and 7) = 4);
  if IsDummyAttribute then
    Address := $23C0 or (Address and $C00) or ((Address shr 4) and $38) or ((Address shr 2) and 7);
  IsName := IsName and not IsDummyAttribute;
  ObserveFetch(Address, IsName);
  if FState.ReadInhibit <> 0 then
  begin
    Value := 0;
    Exit(True);
  end;

  var Row := FState.Vertical;
  var Mapped := Address;
  if FState.RemapControl <> 0 then
  begin
    Row := FState.Remap[FState.RemapPage * $100 + Row];
    Mapped := (Address and $FC1F) or ((Row shr 3) shl 5);
  end;

  var Phase := (Dot - 1) and 7;
  if ((FState.NameReads + 2) mod 42 < 33) and ((Dot < 257) or ((Dot >= 322) and (Dot <= 336))) then
  begin
    if FState.MetatileControl <> 0 then
    begin
      case Phase of
        1:
          begin
            PrepareMetatile(Mapped, Row);
            Value := 0;
          end;
        3:
          Value := FState.MetatilePalette;
        5:
          Value := FState.MetatileLow;
      else
        Value := FState.MetatileHigh;
      end;
      Exit(True);
    end;
    if (FState.DescriptorMode and $80) <> 0 then
      case Phase of
        1:
          begin
            FState.DescriptorTable := (Mapped shr 10) and 3;
            FState.DescriptorCell := Mapped and $3FF;
            FState.TileRow := Row and 7;
            Address := Mapped;
            Exit(ReadMappedPpu(Address, Value));
          end;
        3:
          begin
            if (FState.DescriptorMode and 3) = 3 then
              Value := DescriptorPattern(Address)
            else
              Value := DescriptorAttribute(Row);
            Exit(True);
          end;
        5, 7:
          begin
            Value := DescriptorPattern(Address);
            Exit(True);
          end;
      end;
  end;

  if not IsName and ((FState.PlaneMode and 2) <> 0) then
  begin
    Mapped := Address;
    if ((FState.PlaneSelect and 2) <> 0) and (Address < $2000) then
    begin
      var Slot := Address shr 9;
      Value := ReadBacking(GraphicsSource(FState.ChrFlags[Slot]),
        FState.ChrBank[Slot] * $200 + $1000 + (Address and $1FF), 0);
      Exit(True);
    end;
  end;
  Address := Mapped;
  Result := ReadMappedPpu(Address, Value);
end;

procedure TMapperMxm1.CpuIoWrite(Address: Word; Value: Byte);
begin
  if (Address and $2007) = $2005 then
  begin
    FState.ScrollY := Value;
    FState.ScrollUpdated := True;
  end;
end;

procedure TMapperMxm1.ClockCpu;
begin
  FState.IrqPhase := (Integer(FState.IrqPhase) + 1) and $0F;
  if FState.IrqMatched and not FState.PreviousIrqMatch then
    FState.IrqPhase := 3;
  FState.PreviousIrqMatch := FState.IrqMatched;
  if FState.ReadInhibit <> 0 then
    Dec(FState.ReadInhibit);
end;

function TMapperMxm1.IrqPending: Boolean;
begin
  Result := FState.IrqLine;
end;

procedure TMapperMxm1.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FState, SizeOf(FState));
  State.Field(FPrgWindow, SizeOf(FPrgWindow));
  State.Field(FChrWindow, SizeOf(FChrWindow));
  State.Field(FNameWindow, SizeOf(FNameWindow));
  State.Field(FRam[0], Length(FRam));
  if State.Loading and ((FState.PrgSelect > 3) or (FState.ChrSelect > 15) or
    (FState.NameSelect > 3) or (FState.DescriptorSelect > 3) or (FState.DescriptorTable > 3) or
    (FState.RemapPage > 3) or (FState.RemapCursor < 0) or (FState.RemapCursor > Length(FState.Remap))) then
    raise ENesException.Create('Invalid MXM-1 snapshot');
end;

end.

