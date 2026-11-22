unit NES.Mapper.FlameCyclone;

interface

uses
  NES.Mapper, NES.State, NES.Types;

type
  TMapperFlameCyclone = class(TMapper)
  public
    type
      TReadDma = function(Address: Word): Byte of object;

      TWriteDma = procedure(Address: Word; Value: Byte) of object;
  private
    FPrgRom, FChrRom, FPrgRam, FChrRam, FExtraRam: TByteArray;
    FPrgNvRamSize, FChrNvRamSize: Integer;
    FHasImplicitRam: Boolean;
    FRegs: array[0..$5F] of Byte;
    FPrgOffsets: array[0..4] of Integer;
    FChrOffsets: array[0..7] of Integer;
    FExtraOffsets: array[0..5] of Integer;
    FPrgInRam: array[0..4] of Boolean;
    FChrInRam: array[0..7] of Boolean;
    FCounter: Byte;
    FDivider: SmallInt;
    FIrqEnabled, FIrqLine, FDmaActive: Boolean;
    FReadCpu, FReadPpu: TReadDma;
    FWriteCpu, FWritePpu: TWriteDma;
    function RegisterWord(Index: Integer): Word; inline;
    function ExtraAddress(Address: Word): Integer;
    function NameAddress(Address: Word): Integer;
    procedure UpdateWindows;
    procedure ExpandBank(Index, First, Shift: Integer);
    procedure Dma(Mode: Byte);
    procedure WriteRegister(Index: Integer; Value: Byte);
  public
    constructor Create(const Prg, Chr: TByteArray; PrgRamSize, ChrRamSize: Integer; PrgNvRamSize: Integer = 0; ChrNvRamSize: Integer = 0; HasImplicitRam: Boolean = False);
    procedure ConnectCpu(ReadMemory: TReadDma; WriteMemory: TWriteDma);
    procedure ConnectPpu(ReadMemory: TReadDma; WriteMemory: TWriteDma);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function NameTableOffset(Address: Word): Word; override;
    function GetMirrorMode: TMirrorMode; override;
    function AllowsPpuReadCaching: Boolean; override;
    function AllowsDirectPpuRead: Boolean; override;
    procedure ClockCpu; override;
    procedure ClockRaster(Line, Dot: Integer; Rendering: Boolean);
    function IrqPending: Boolean; override;
  end;

implementation

uses
  System.Math;

const
  NAME_PAGES: array[0..7, 0..3] of Byte = (
    (0, 1, 0, 1), (0, 0, 1, 1), (0, 0, 0, 0), (1, 1, 1, 1),
    (2, 2, 2, 2), (3, 3, 3, 3), (0, 1, 2, 3), (0, 1, 0, 1));

constructor TMapperFlameCyclone.Create(const Prg, Chr: TByteArray; PrgRamSize, ChrRamSize, PrgNvRamSize, ChrNvRamSize: Integer; HasImplicitRam: Boolean);
begin
  inherited Create;
  ValidateMemory(Prg, Chr);
  FPrgRom := Prg;
  FChrRom := Chr;
  FPrgNvRamSize := PrgNvRamSize;
  FChrNvRamSize := ChrNvRamSize;
  FHasImplicitRam := HasImplicitRam;
  if FHasImplicitRam then
  begin
    PrgRamSize := Max(PrgRamSize, $800000 - PrgNvRamSize);
    ChrRamSize := Max(ChrRamSize, $100000 - ChrNvRamSize);
  end;
  SetLength(FPrgRam, PrgNvRamSize + PrgRamSize);
  SetLength(FChrRam, ChrNvRamSize + ChrRamSize);
  SetLength(FExtraRam, $200000);
  Reset;
end;

procedure TMapperFlameCyclone.ConnectCpu(ReadMemory: TReadDma; WriteMemory: TWriteDma);
begin
  FReadCpu := ReadMemory;
  FWriteCpu := WriteMemory;
end;

procedure TMapperFlameCyclone.ConnectPpu(ReadMemory: TReadDma; WriteMemory: TWriteDma);
begin
  FReadPpu := ReadMemory;
  FWritePpu := WriteMemory;
end;

procedure TMapperFlameCyclone.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  if FHasImplicitRam then
  begin
    FRegs[$02] := 1;
    FRegs[$09] := $80;
  end;
  FRegs[$04] := $FE;
  FRegs[$05] := $7F;
  FRegs[$06] := $FF;
  FRegs[$07] := $7F;
  for var Slot := 0 to 7 do
    FRegs[$10 + Slot * 2] := Slot;
  FRegs[$52] := $FF;
  FRegs[$53] := $FF;
  FRegs[$56] := $FF;
  FRegs[$57] := $FF;
  FCounter := 0;
  FDivider := 0;
  FIrqEnabled := False;
  FIrqLine := False;
  FDmaActive := False;
  UpdateWindows;
end;

function TMapperFlameCyclone.RegisterWord(Index: Integer): Word;
begin
  Result := FRegs[Index] or (Word(FRegs[Index + 1]) shl 8);
end;

procedure TMapperFlameCyclone.UpdateWindows;
const
  PRG_REGS: array[0..4] of Byte = (8, 0, 2, 4, 6);
  EXTRA_BASE: array[0..5] of Integer = ($1F0000, $1E0000, $1C0000, $180000, $100000, 0);
begin
  var PrgMask := RegisterWord($52);
  var PrgBase := RegisterWord($50);
  for var Slot := 0 to 4 do
  begin
    var Bank := RegisterWord(PRG_REGS[Slot]);
    FPrgInRam[Slot] := (Bank and $8000) <> 0;
    FPrgOffsets[Slot] := ((Bank and PrgMask) + PrgBase) * $2000;
  end;
  var ChrMask := RegisterWord($56);
  var ChrBase := RegisterWord($54);
  for var Slot := 0 to 7 do
  begin
    var Bank := RegisterWord($10 + Slot * 2);
    FChrInRam[Slot] := (Bank and $8000) <> 0;
    FChrOffsets[Slot] := ((Bank and ChrMask) + ChrBase) * $400;
  end;
  for var Slot := 0 to 5 do
    FExtraOffsets[Slot] := EXTRA_BASE[Slot] or (Integer(FRegs[$38 + Slot]) shl (7 + Slot));
end;

function TMapperFlameCyclone.ExtraAddress(Address: Word): Integer;
begin
  case Address of
    $4080..$40FF:
      Result := FExtraOffsets[0] + (Address and $07F);
    $4100..$41FF:
      Result := FExtraOffsets[1] + (Address and $0FF);
    $4200..$43FF:
      Result := FExtraOffsets[2] + (Address and $1FF);
    $4400..$47FF:
      Result := FExtraOffsets[3] + (Address and $3FF);
    $4800..$4FFF:
      Result := FExtraOffsets[4] + (Address and $7FF);
  else
    Result := FExtraOffsets[5] + (Address and $FFF);
  end;
end;

function TMapperFlameCyclone.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  case Address of
    $4020..$407F:
      Value := FRegs[Address - $4020];
    $4080..$5FFF:
      Value := FExtraRam[ExtraAddress(Address)];
    $6000..$FFFF:
      begin
        var Slot := (Address - $6000) shr 13;
        var Offset := FPrgOffsets[Slot] + (Address and $1FFF);
        if FPrgInRam[Slot] then
        begin
          if Length(FPrgRam) = 0 then
            Exit(False);
          Value := FPrgRam[Offset mod Length(FPrgRam)];
        end
        else
          Value := FPrgRom[Offset mod Length(FPrgRom)];
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperFlameCyclone.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  case Address of
    $4020..$407F:
      WriteRegister(Address - $4020, Value);
    $4080..$5FFF:
      FExtraRam[ExtraAddress(Address)] := Value;
    $6000..$FFFF:
      begin
        var Slot := (Address - $6000) shr 13;
        if FPrgInRam[Slot] and (Length(FPrgRam) <> 0) then
          FPrgRam[(FPrgOffsets[Slot] + (Address and $1FFF)) mod Length(FPrgRam)] := Value;
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure TMapperFlameCyclone.ExpandBank(Index, First, Shift: Integer);
begin
  var Bank := RegisterWord(Index);
  for var Slot := 0 to (1 shl Shift) - 1 do
  begin
    var Entry := ((Bank shl Shift) and $7FFF) or (Bank and $8000) or Slot;
    FRegs[First + Slot * 2] := Entry and $FF;
    FRegs[First + Slot * 2 + 1] := Entry shr 8;
  end;
end;

procedure TMapperFlameCyclone.Dma(Mode: Byte);
begin
  if (Mode > 5) or FDmaActive or not Assigned(FReadCpu) or not Assigned(FReadPpu) then
    Exit;
  var Source := Integer(RegisterWord($30));
  var Target := Integer(RegisterWord($32));
  var Value: Byte := Source and $FF;
  FDmaActive := True;
  try
    for var Index := 0 to Integer(RegisterWord($34)) - 1 do
    begin
      case Mode of
        0, 1:
          Value := FReadCpu(Word(Source));
        2, 3:
          Value := FReadPpu(Word(Source and $3FFF));
      end;
      if (Mode and 1) = 0 then
        FWriteCpu(Word(Target), Value)
      else
        FWritePpu(Word(Target and $3FFF), Value);
      Source := (Source + 1) and $FFFF;
      Target := (Target + 1) and $FFFF;
    end;
  finally
    FDmaActive := False;
  end;
end;

procedure TMapperFlameCyclone.WriteRegister(Index: Integer; Value: Byte);
begin
  FRegs[Index] := Value;
  case Index of
    $0A, $0B:
      ExpandBank($0A, $00, 1);
    $0D:
      FCounter := Value;
    $0E, $0F:
      begin
        FIrqEnabled := Index = $0F;
        FIrqLine := False;
      end;
    $20..$27:
      ExpandBank(Index and $FE, $10 + (Index and 6) * 2, 1);
    $28..$2B:
      ExpandBank(Index and $FE, $10 + (Index and 2) * 4, 2);
    $2C, $2D:
      ExpandBank($2C, $10, 3);
    $36:
      Dma(Value);
    $40..$43:
      begin
        var Product := UInt64(RegisterWord($40)) * RegisterWord($42);
        for var I := 0 to 3 do
          FRegs[$44 + I] := (Product shr (I * 8)) and $FF;
      end;
    $48, $49:
      begin
        var Number := Integer(FRegs[$48]) * $100 + FRegs[$49];
        for var I := $4A to $4E do
        begin
          FRegs[I] := Number mod 10;
          Number := Number div 10;
        end;
      end;
  end;
  case Index of
    $00..$0B, $10..$2D, $38..$3D, $50..$57:
      UpdateWindows;
  end;
end;

function TMapperFlameCyclone.NameAddress(Address: Word): Integer;
begin
  var Mode := FRegs[$2F] and 3;
  var Page := NAME_PAGES[FRegs[$2E] and 7, (Address shr 10) and 3];
  if Mode <> 3 then
    Page := Page and 1;
  Result := (Integer(Page) shl 10) + (Address and $3FF);
  case Mode of
    1:
      Inc(Result, FExtraOffsets[4]);
    2, 3:
      Inc(Result, FExtraOffsets[5]);
  end;
end;

function TMapperFlameCyclone.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if Address >= $2000 then
  begin
    if (Address >= $3F00) or ((FRegs[$2F] and 3) = 0) then
      Exit(False);
    Value := FExtraRam[NameAddress(Address)];
    Exit(True);
  end;

  var Slot := Address shr 10;
  var Offset := FChrOffsets[Slot] + (Address and $3FF);
  if FChrInRam[Slot] or (Length(FChrRom) = 0) then
  begin
    if Length(FChrRam) = 0 then
      Value := 0
    else
      Value := FChrRam[Offset mod Length(FChrRam)];
  end
  else
    Value := FChrRom[Offset mod Length(FChrRom)];
  Result := True;
end;

function TMapperFlameCyclone.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if Address >= $2000 then
  begin
    if (Address >= $3F00) or ((FRegs[$2F] and 3) = 0) then
      Exit(False);
    FExtraRam[NameAddress(Address)] := Value;
    Exit(True);
  end;
  var Slot := Address shr 10;
  if (FChrInRam[Slot] or (Length(FChrRom) = 0)) and (Length(FChrRam) <> 0) then
    FChrRam[(FChrOffsets[Slot] + (Address and $3FF)) mod Length(FChrRam)] := Value;
  Result := True;
end;

function TMapperFlameCyclone.NameTableOffset(Address: Word): Word;
begin
  Result := NameAddress(Address) and $0FFF;
end;

function TMapperFlameCyclone.GetMirrorMode: TMirrorMode;
begin
  case FRegs[$2E] and 7 of
    1:
      Result := TMirrorMode.Horizontal;
    2, 4:
      Result := TMirrorMode.Single0;
    3, 5:
      Result := TMirrorMode.Single1;
    6:
      Result := TMirrorMode.FourScreen;
  else
    Result := TMirrorMode.Vertical;
  end;
end;

function TMapperFlameCyclone.AllowsPpuReadCaching: Boolean;
begin
  // IRQ and DMA are clocked separately from the presentation reads.
  Result := True;
end;

function TMapperFlameCyclone.AllowsDirectPpuRead: Boolean;
begin
  Result := True;
end;

procedure TMapperFlameCyclone.ClockCpu;
begin
  if not FIrqEnabled then
    Exit;
  case FRegs[$0C] and 3 of
    0, 1:
      Exit;
    3:
      begin
        Dec(FDivider, 3);
        if FDivider > 0 then
          Exit;
        Inc(FDivider, 341);
      end;
  end;

  FCounter := (Integer(FCounter) - 1) and $FF;
  if FCounter = 0 then
  begin
    FCounter := FRegs[$0D];
    FIrqLine := True;
  end;
end;

procedure TMapperFlameCyclone.ClockRaster(Line, Dot: Integer; Rendering: Boolean);
begin
  if not FIrqEnabled then
    Exit;
  case FRegs[$0C] and 3 of
    0:
      if Rendering and (Line >= 0) and (Line < 240) and (Dot = 260) then
      begin
        if FCounter = 0 then
          FCounter := FRegs[$0D]
        else
          Dec(FCounter);
        if FCounter = 0 then
          FIrqLine := True;
      end;
    1:
      if (Line >= 240) or not Rendering then
      begin
        FIrqEnabled := False;
        FRegs[$0D] := 0;
        FIrqLine := False;
      end
      else if (Dot = 256) and (Line = FRegs[$0D]) then
        FIrqLine := True;
  end;
end;

function TMapperFlameCyclone.IrqPending: Boolean;
begin
  Result := FIrqLine;
end;

function TMapperFlameCyclone.GetSaveMemory: TByteArray;
begin
  SetLength(Result, FPrgNvRamSize + FChrNvRamSize);
  if FPrgNvRamSize <> 0 then
    Move(FPrgRam[0], Result[0], FPrgNvRamSize);
  if FChrNvRamSize <> 0 then
    Move(FChrRam[0], Result[FPrgNvRamSize], FChrNvRamSize);
end;

procedure TMapperFlameCyclone.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> FPrgNvRamSize + FChrNvRamSize then
    raise ENesException.Create('Invalid FlameCyclone save size');
  if FPrgNvRamSize <> 0 then
    Move(Data[0], FPrgRam[0], FPrgNvRamSize);
  if FChrNvRamSize <> 0 then
    Move(Data[FPrgNvRamSize], FChrRam[0], FChrNvRamSize);
end;

procedure TMapperFlameCyclone.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FExtraRam[0], Length(FExtraRam));
  if Length(FPrgRam) <> 0 then
    State.Field(FPrgRam[0], Length(FPrgRam));
  if Length(FChrRam) <> 0 then
    State.Field(FChrRam[0], Length(FChrRam));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FDivider, SizeOf(FDivider));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqLine, SizeOf(FIrqLine));
  if State.Loading then
  begin
    if (FDivider < 0) or (FDivider > 341) then
      raise ENesException.Create('Invalid FlameCyclone snapshot');
    UpdateWindows;
  end;
end;

end.

