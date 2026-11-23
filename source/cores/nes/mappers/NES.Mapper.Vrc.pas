unit NES.Mapper.Vrc;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked, HW.EEPROM93Cxx;

type
  TMapperVrc = class(TMapperBanked)
  protected
    FBoard, FSubmapper, FPrescaler, FCounter, FLatch: Integer;
    FChrRegisters: array[0..7] of Integer;
    FPrg0, FPrg1, FSwap, FControl, FRamLatch: Byte;
    FPending: Boolean;
    FHybridRam: array[0..$7FF] of Byte;
    FForceRom: Boolean;
    procedure TickIrq;
  private
    FExtendedWiring, FIsVrc2Board: Boolean;
    FNativeVrc2, FNativeVrc4, FVrc2BitLatch: Boolean;
    FRegisterAddress0, FRegisterAddress1: Word;
    FA12High: Boolean;
    FOuterBank, FLastChrSlot: Byte;
    FChrRamMask, FChrRamCompare, FPrgC000: Byte;
    FNamePages: array[0..3] of Byte;
    FBoardPrgRamSize: Integer;
    procedure SyncBoardPrg;
    procedure SyncStandardPrg;
    function StandardPrgRamSelected(Address: Word): Boolean;
    procedure ResetRegisters;
    function BoardChrOffset(Address: UInt16): Integer;
    function BoardPrgRamSelected(Address: UInt16): Boolean;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ConfigureBoardPrgRam(Size: UInt64);
    procedure DisableVrc2BitLatch;
    procedure RestoreLegacyVrc2BitLatch;
    function NameTableOffset(Address: UInt16): UInt16; override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer = 0);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperVrc830768C = class(TMapperVrc)
  private
    FOuter, FDataLatch: Byte;
    FOuterWriteEnabled: Boolean;
    procedure MapPrg;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
  end;

  TMapperBmcJy104 = class(TMapperVrc)
  private
    FSaveChip: TSerialEEPROM93Cxx;
    FChrRam: TByteArray;
    FChrRamSlots, FGame: Byte;
    procedure UpdatePrg;
    procedure WriteChrBank(Address: Word; Value: Byte);
    procedure WriteSerialLines(Address: Word);
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure ConfigureMemory(PrgRamSize, ChrRamSize: UInt64);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

constructor TMapperBmcJy104.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(MAPPER_BMC_JY104, Prg, Chr, HasChrRam, MirrorMode);
  FSaveChip := TSerialEEPROM93Cxx.Create($100, 16, True, True);
  SetLength(FPrgRam, 0);
end;

destructor TMapperBmcJy104.Destroy;
begin
  FSaveChip.Free;
  inherited;
end;

procedure TMapperBmcJy104.ConfigureMemory(PrgRamSize, ChrRamSize: UInt64);
begin
  if (PrgRamSize > $2000) or (ChrRamSize > $40000) then
    raise ENesException.Create('Unsupported BMC-JY-104 RAM size');
  SetLength(FPrgRam, Integer(PrgRamSize));
  if FHasChrRam then
  begin
    if ChrRamSize <> 0 then
      SetLength(FChrMemory, Integer(ChrRamSize));
  end
  else
    SetLength(FChrRam, Integer(ChrRamSize));
end;

procedure TMapperBmcJy104.UpdatePrg;
begin
  var OuterBank := Integer(FGame) shl 4;
  Prg16(0, OuterBank or FPrg0);
  Prg16(1, OuterBank or $F);
end;

procedure TMapperBmcJy104.PowerOn;
begin
  if FSaveChip <> nil then
    FSaveChip.Reset;
  if Length(FPrgRam) <> 0 then
    FillChar(FPrgRam[0], Length(FPrgRam), 0);
  if Length(FChrRam) <> 0 then
    FillChar(FChrRam[0], Length(FChrRam), 0);
  if FHasChrRam then
    FillChar(FChrMemory[0], Length(FChrMemory), 0);
  FChrRamSlots := 0;
  Chr8(0);
  FControl := 0;
  Reset;
end;

procedure TMapperBmcJy104.Reset;
begin
  FGame := 0;
  FPrg0 := 0;
  FRamEnabled := False;
  FControl := FControl and 2;
  FCounter := 0;
  FLatch := 0;
  FPrescaler := 341;
  FPending := False;
  UpdatePrg;
end;

procedure TMapperBmcJy104.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FGame, SizeOf(FGame));
  State.Field(FChrRamSlots, SizeOf(FChrRamSlots));
  if Length(FChrRam) <> 0 then
    State.Field(FChrRam[0], Length(FChrRam));
  State.SharedFields(FSaveChip.SerializeState);
end;

function TMapperBmcJy104.GetSaveMemory: TByteArray;
begin
  Result := TByteArray(FSaveChip.Battery);
end;

procedure TMapperBmcJy104.SetSaveMemory(const Data: TByteArray);
begin
  FSaveChip.LoadBattery(TArray<Byte>(Data));
end;

function TMapperBmcJy104.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address = $5000 then
  begin
    Value := Ord(FSaveChip.Output);
    Exit(True);
  end;
  if (Address >= $6000) and (Integer(Address) - $6000 < Length(FPrgRam)) then
  begin
    Value := FPrgRam[Address - $6000];
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

procedure TMapperBmcJy104.WriteSerialLines(Address: Word);
begin
  FSaveChip.Lines((Address and 4) <> 0, (Address and 2) <> 0, (Address and 1) <> 0);
end;

procedure TMapperBmcJy104.WriteChrBank(Address: Word; Value: Byte);
begin
  var Slot := ((Address shr 12) - $B) * 2 + ((Address shr 3) and 1);
  var SlotMask := Byte(1 shl Slot);
  var Shift := ((Address shr 2) and 1) * 4;
  var MemorySize := Length(FChrMemory);
  if (FChrRamSlots and SlotMask) <> 0 then
    MemorySize := Length(FChrRam);
  var PreviousBank := ((FChrBanks[Slot] * $400) mod MemorySize) div $400;
  var Bank := (PreviousBank and ($FF xor ($F shl Shift))) or ((Value and $F) shl Shift);
  MemorySize := Length(FChrMemory);
  if (FGame = 0) and (Length(FChrRam) <> 0) then
  begin
    FChrRamSlots := FChrRamSlots or SlotMask;
    MemorySize := Length(FChrRam);
  end
  else
    FChrRamSlots := FChrRamSlots and not SlotMask;
  Chr1(Slot, ((Bank * $400) mod MemorySize) div $400);
end;

function TMapperBmcJy104.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  case Address of
    $6000..$7FFF:
      if Integer(Address) - $6000 < Length(FPrgRam) then
        FPrgRam[Address - $6000] := Value
      else
        Result := False;
    $9000..$9FFF:
      Exit(True);
    $A000..$AFFF:
      begin
        FPrg0 := Value and $0F;
        UpdatePrg;
      end;
    $B000..$EFFF:
      if (Address and $0FF3) = $0400 then
        WriteChrBank(Address, Value)
      else
        Result := False;
    $F400:
      FLatch := (FLatch and $F0) or (Value and $F);
    $F404:
      FLatch := (FLatch and $0F) or ((Value and $F) shl 4);
    $F408:
      begin
        FControl := Value and 7;
        FPending := False;
        if (FControl and 2) <> 0 then
        begin
          FCounter := FLatch;
          FPrescaler := 341;
        end;
      end;
    $FFE0..$FFE8:
      begin
        if Address = $FFE0 then
        begin
          FGame := (Value shr 6) and 1;
          UpdatePrg;
        end;
        WriteSerialLines(Address);
      end;
  else
    Result := Address >= $8000;
    if Result and ((Address and $800) <> 0) then
      WriteSerialLines(Address);
  end;
end;

function TMapperBmcJy104.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if not Result then
    Exit;
  var Slot := Address shr 10;
  if (FChrRamSlots and (1 shl Slot)) <> 0 then
    Value := FChrRam[(FChrBanks[Slot] * $400 + (Address and $3FF)) mod Length(FChrRam)]
  else
    Value := FChrMemory[ChrOffset(Address)];
end;

function TMapperBmcJy104.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := PpuRead(Address, Value);
end;

function TMapperBmcJy104.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);
  var Slot := Address shr 10;
  if (FChrRamSlots and (1 shl Slot)) <> 0 then
  begin
    FChrRam[(FChrBanks[Slot] * $400 + (Address and $3FF)) mod Length(FChrRam)] := Value;
    Exit(True);
  end;
  Result := inherited PpuWrite(Address, Value);
end;

constructor TMapperVrc830768C.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(MAPPER_VRC2_VRC4_27, Prg, Chr, HasChrRam, MirrorMode);
end;

procedure TMapperVrc830768C.Reset;
begin
  inherited;
  FOuter := 0;
  FDataLatch := 0;
  FOuterWriteEnabled := False;
  FRamEnabled := False;
  MapPrg;
end;

procedure TMapperVrc830768C.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FOuter, SizeOf(FOuter));
  State.Field(FDataLatch, SizeOf(FDataLatch));
  State.Field(FOuterWriteEnabled, SizeOf(FOuterWriteEnabled));
end;

procedure TMapperVrc830768C.MapPrg;
begin
  var Base := (FOuter and 7) shl 3;
  if (FOuter and 8) <> 0 then
    Prg32(((FOuter and 6) shl 2) or (FDataLatch and 7))
  else
  begin
    var Mask := 7 or ((FOuter and 4) shl 1);
    Prg16(0, (Base and not Mask) or (FPrg0 and Mask));
    Prg16(1, (Base and not Mask) or Mask);
  end;
end;

function TMapperVrc830768C.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $6000 then
    Exit(False);
  if Address < $8000 then
  begin
    if FOuterWriteEnabled then
    begin
      FOuter := Address and $0F;
      MapPrg;
    end;
    Exit(True);
  end;

  var RegisterAddress := (Address and $F000) or ((Address shr 2) and 3);
  if RegisterAddress = $9002 then
    FOuterWriteEnabled := (Value and 1) <> 0;
  FDataLatch := Value;
  inherited CpuWrite(RegisterAddress, Value);
  MapPrg;
  Chr8(0);
  Result := True;
end;

function TMapperVrc830768C.GetMirrorMode: TMirrorMode;
begin
  if (FOuter and 8) = 0 then
    Exit(inherited GetMirrorMode);
  if (FDataLatch and $10) <> 0 then
    Result := TMirrorMode.Single1
  else
    Result := TMirrorMode.Single0;
end;

procedure TMapperVrc.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoard, SizeOf(FBoard));
  State.Field(FPrescaler, SizeOf(FPrescaler));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FPrg0, SizeOf(FPrg0));
  State.Field(FPrg1, SizeOf(FPrg1));
  State.Field(FSwap, SizeOf(FSwap));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FRamLatch, SizeOf(FRamLatch));
  State.Field(FPending, SizeOf(FPending));
  if FBoard = MAPPER_VRC_J2020 then
    State.Field(FA12High, SizeOf(FA12High));
  if FExtendedWiring then
  begin
    State.Field(FOuterBank, SizeOf(FOuterBank));
    State.Field(FLastChrSlot, SizeOf(FLastChrSlot));
  end;
  if FBoard = MAPPER_SUBOR_SANGOKUSHI then
  begin
    State.Field(FPrgC000, SizeOf(FPrgC000));
    State.Field(FNamePages, SizeOf(FNamePages));
  end;
  if FBoard = MAPPER_VRC_FS306 then
  begin
    State.Field(FHybridRam, SizeOf(FHybridRam));
    State.Field(FChrRamMask, SizeOf(FChrRamMask));
    State.Field(FChrRamCompare, SizeOf(FChrRamCompare));
    State.Field(FPrgC000, SizeOf(FPrgC000));
    State.Field(FNamePages, SizeOf(FNamePages));
  end;
  if FBoard = MAPPER_VRC4_253 then
  begin
    State.Field(FHybridRam, SizeOf(FHybridRam));
    State.Field(FForceRom, SizeOf(FForceRom))
  end;
  if State.Loading and FNativeVrc2 then
  begin
    // Legacy generic VRC states could contain modes that this chip lacks.
    FControl := 0;
    FSwap := 0;
    FPending := False;
    FRamEnabled := True;
    if FMirror = TMirrorMode.Single0 then
      Mirror(0)
    else if FMirror = TMirrorMode.Single1 then
      Mirror(1);
    for var Slot := 0 to 7 do
      if FChrRegisters[Slot] > $FF then
      begin
        FChrRegisters[Slot] := FChrRegisters[Slot] and $FF;
        Chr1(Slot, FChrRegisters[Slot] shr Ord(FBoard = MAPPER_VRC2A));
      end;
    SyncStandardPrg;
  end;
end;

constructor TMapperVrc.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  FNativeVrc2 := (Board = MAPPER_VRC2A) or ((Submapper = 3) and
    ((Board = MAPPER_VRC2B_VRC4E) or (Board = MAPPER_VRC2C_VRC4B)));
  FNativeVrc4 := ((Submapper = 1) or (Submapper = 2)) and
    ((Board = MAPPER_VRC4A_VRC4C) or (Board = MAPPER_VRC2B_VRC4E) or (Board = MAPPER_VRC2C_VRC4B));
  FVrc2BitLatch := (Board = MAPPER_VRC2B_VRC4E) and (Submapper = 3);

  var UseLowAddressLines := Submapper <> 2;
  var UseHighAddressLines := (Submapper = 2) or not (FNativeVrc2 or FNativeVrc4);
  case Board of
    MAPPER_VRC4A_VRC4C:
      begin
        FRegisterAddress0 := Ord(UseLowAddressLines) * 2 + Ord(UseHighAddressLines) * $40;
        FRegisterAddress1 := Ord(UseLowAddressLines) * 4 + Ord(UseHighAddressLines) * $80;
      end;
    MAPPER_VRC2A:
      begin
        FRegisterAddress0 := 2;
        FRegisterAddress1 := 1;
      end;
    MAPPER_VRC2B_VRC4E:
      begin
        FRegisterAddress0 := Ord(UseLowAddressLines) + Ord(UseHighAddressLines) * 4;
        FRegisterAddress1 := Ord(UseLowAddressLines) * 2 + Ord(UseHighAddressLines) * 8;
      end;
    MAPPER_VRC2C_VRC4B:
      begin
        FRegisterAddress0 := Ord(UseLowAddressLines) * 2 + Ord(UseHighAddressLines) * 8;
        FRegisterAddress1 := Ord(UseLowAddressLines) + Ord(UseHighAddressLines) * 4;
      end;
  end;
  FIsVrc2Board := (Board = MAPPER_VRC_YY841157C) or (Board = MAPPER_VRC_900218) or (Board = MAPPER_VRC_AX40G) or
    (Board = MAPPER_VRC_J2020) or (Board = MAPPER_VRC_J33C) or (Board = MAPPER_NTDEC_TH2131) or
    (Board = MAPPER_VRC_J3_C);
  FExtendedWiring := FIsVrc2Board or (Board = MAPPER_VRC_L1A16) or (Board = MAPPER_VRC_DATACH_2IN1) or
    (Board = MAPPER_VRC_830506C) or (Board = MAPPER_VRC_YY840820C) or (Board = MAPPER_VRC_KL06) or
    (Board = MAPPER_VRC_FS306) or (Board = MAPPER_VRC_9052) or (Board = MAPPER_VRC_JC011) or
    (Board = MAPPER_VRC_AD301) or (Board = MAPPER_JYV610) or (Board = MAPPER_SUBOR_SANGOKUSHI);
  PowerOn;
end;

procedure TMapperVrc.PowerOn;
begin
  if FExtendedWiring then
    ResetRegisters
  else
    inherited;
end;

procedure TMapperVrc.Reset;
begin
  if not FExtendedWiring or (FBoard = MAPPER_VRC_J2020) or (FBoard = MAPPER_VRC_JC011) then
    ResetRegisters
  else
  begin
    case FBoard of
      MAPPER_VRC_L1A16, MAPPER_VRC_KL06, MAPPER_VRC_9052, MAPPER_VRC_AD301:
        FOuterBank := 0;
      MAPPER_NTDEC_TH2131:
        begin
          FControl := 0;
          FCounter := 0;
          FLatch := 0;
        end;
      MAPPER_VRC_J3_C:
        begin
          FControl := 0;
          FCounter := 0;
          FPrescaler := 0;
          FLatch := 0;
        end;
      MAPPER_VRC_J33C:
        begin
          FControl := 0;
          FCounter := 0;
          FPrescaler := 0;
        end;
      MAPPER_VRC_830506C:
        if Length(FPrgRom) > $80000 then
          FOuterBank := FOuterBank xor 1;
      MAPPER_VRC_YY840820C:
        FOuterBank := $C0;
    end;
    FPending := False;
    SyncBoardPrg;
  end;
end;

procedure TMapperVrc.ResetRegisters;
begin
  inherited Reset;
  FillChar(FChrRegisters, SizeOf(FChrRegisters), 0);
  FPrg0 := 0;
  FPrg1 := 1;
  FSwap := 0;
  FControl := 0;
  FRamLatch := 0;
  FPrescaler := 341;
  FCounter := 0;
  FLatch := 0;
  FPending := False;
  FForceRom := False;
  FA12High := False;
  if (FBoard = MAPPER_VRC_J33C) or (FBoard = MAPPER_VRC_J3_C) then
    FPrescaler := 0;
  Prg8(0, 0);
  Prg8(1, 1);
  if FNativeVrc4 then
    FRamEnabled := False;
  if FExtendedWiring then
  begin
    FOuterBank := 0;
    FLastChrSlot := 0;
    case FBoard of
      MAPPER_VRC_YY840820C:
        FOuterBank := $C0;
      MAPPER_SUBOR_SANGOKUSHI:
        begin
          FPrgC000 := $FE;
          FNamePages[0] := 0;
          FNamePages[1] := 0;
          FNamePages[2] := 1;
          FNamePages[3] := 1;
        end;
      MAPPER_VRC_FS306:
        begin
          FChrRamMask := $FC;
          FChrRamCompare := $28;
          FPrgC000 := $FE;
          FNamePages[0] := 0;
          FNamePages[1] := 0;
          FNamePages[2] := 1;
          FNamePages[3] := 1;
        end;
    end;
    FRamEnabled := False;
    Mirror(0);
    for var Slot := 0 to 7 do
      FChrRegisters[Slot] := Slot;
    SyncBoardPrg;
  end;
end;

procedure TMapperVrc.ConfigureBoardPrgRam(Size: UInt64);
begin
  if (Size <> 0) and (Size <> $800) and (Size <> $1000) and (Size <> $2000) then
    raise ENesException.Create('Unsupported VRC board PRG RAM size');
  FBoardPrgRamSize := Integer(Size);
end;

function TMapperVrc.BoardPrgRamSelected(Address: UInt16): Boolean;
begin
  Result := (Address >= $6000) and
    ((FBoardPrgRamSize = $2000) or (FRamEnabled and (Address < $7000)));
end;

procedure TMapperVrc.SyncBoardPrg;
begin
  var Mask := $1F;
  var Outer := 0;
  case FBoard of
    MAPPER_VRC_J2020:
      begin
        if (FSubmapper <> 0) and ((FOuterBank and 2) = 0) then
          Mask := $0F;
        Outer := (Integer(FOuterBank) shl 4) and not Mask;
      end;
    MAPPER_VRC_9052:
      begin
        Mask := $0F;
        Outer := Integer(FOuterBank) shl 4;
      end;
    MAPPER_VRC_JC011:
      begin
        var Mode := FOuterBank;
        if (Mode and $20) = 0 then
        begin
          if (FSubmapper = 2) or ((FSubmapper = 0) and ((Mode and 6) <> 0)) or
            ((FSubmapper = 1) and ((Mode and 6) = 6)) then
            Prg32(Mode shr 1)
          else
          begin
            Prg16(0, Mode);
            Prg16(1, Mode);
          end;
          Exit;
        end;
        Mask := $0F or (Mode and $10);
        Outer := (Integer(Mode) shl 1) and not Mask;
      end;
    MAPPER_VRC_830506C:
      begin
        Mask := $0F;
        if FOuterBank = 0 then
          Outer := (FChrRegisters[FLastChrSlot] and $180) shr 3
        else
          Outer := $40;
      end;
    MAPPER_VRC_YY840820C:
      begin
        if (FOuterBank and $80) <> 0 then
        begin
          Prg32(((FOuterBank shr 5) and 6) or ((FChrRegisters[FLastChrSlot] shr 2) and 1));
          Exit;
        end;
        Mask := $0F;
      end;
    MAPPER_VRC_KL06:
      begin
        if FSubmapper <> 2 then
          Mask := $0F;
        Outer := (Integer(FOuterBank) shl 4) and not Mask;
        if (FOuterBank and 4) <> 0 then
        begin
          var Base := Outer or (FPrg0 and Mask);
          var MirrorBit := 2;
          if FSubmapper = 0 then
            MirrorBit := 1;
          if (FOuterBank and (MirrorBit shl 1)) <> 0 then
          begin
            Prg16(0, Base shr 1);
            Prg16(1, Base shr 1);
          end
          else
            Prg32(Base shr 2);
          Exit;
        end;
      end;
    MAPPER_VRC_AD301:
      begin
        var WideBit := 4 shr Ord(FSubmapper = 1);
        Mask := $0F or ($10 * Ord((FOuterBank and WideBit) <> 0));
        Outer := (FOuterBank shl 4) and not Mask;
      end;
    MAPPER_VRC_L1A16, MAPPER_VRC_YY841157C:
      begin
        Mask := $0F;
        Outer := Integer(FOuterBank) shl 4;
      end;
    MAPPER_VRC_DATACH_2IN1:
      Outer := (FChrRegisters[FLastChrSlot] and 8) shl 2;
  end;
  Prg8(FSwap, Outer or (FPrg0 and Mask));
  Prg8(1, Outer or (FPrg1 and Mask));
  Prg8(2 - FSwap, Outer or ($FE and Mask));
  Prg8(3, Outer or Mask);
  if (FBoard = MAPPER_VRC_FS306) or (FBoard = MAPPER_SUBOR_SANGOKUSHI) then
    Prg8(2, FPrgC000 and $1F);
end;

function TMapperVrc.NameTableOffset(Address: UInt16): UInt16;
begin
  if (FBoard = MAPPER_VRC_FS306) or (FBoard = MAPPER_SUBOR_SANGOKUSHI) then
    Exit((FNamePages[(Address shr 10) and 3] shl 10) or (Address and $3FF));
  if (FBoard = MAPPER_JYV610) and (FOuterBank <> 0) and ((Address and $0C00) = $0C00) then
    Exit($400 or (Address and $3FF));
  if FBoard = MAPPER_VRC_AX40G then
  begin
    var Page := (FChrRegisters[(Address shr 11) and 1] shr 7) and 1;
    Exit((Page shl 10) or (Address and $3FF));
  end;
  Result := inherited NameTableOffset(Address);
end;

procedure TMapperVrc.DisableVrc2BitLatch;
begin
  FVrc2BitLatch := False;
end;

procedure TMapperVrc.RestoreLegacyVrc2BitLatch;
begin
  if FVrc2BitLatch and (FBoardPrgRamSize = 0) then
    FRamLatch := FPrgRam[0] and 1;
end;

function TMapperVrc.StandardPrgRamSelected(Address: Word): Boolean;
begin
  Result := FRamEnabled and (FBoardPrgRamSize <> 0) and
    ((Address < $7000) or (FBoardPrgRamSize = $2000));
end;

function TMapperVrc.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FNativeVrc2 or FNativeVrc4) and (Address >= $6000) and (Address < $8000) then
  begin
    if StandardPrgRamSelected(Address) then
    begin
      Value := FPrgRam[Address and (FBoardPrgRamSize - 1)];
      Exit(True);
    end;
    if (Address < $7000) and ((FBoard = MAPPER_VRC2A) or FVrc2BitLatch) then
    begin
      Value := FCpuOpenBus and $FE;
      if FVrc2BitLatch then
        Value := Value or FRamLatch;
      Exit(True);
    end;
    Exit(False);
  end;
  if FExtendedWiring and (Address >= $6000) and (Address < $8000) then
  begin
    if FBoard = MAPPER_JYV610 then
    begin
      Value := FPrgRom[($1E000 or (Address and $1FFF)) mod Length(FPrgRom)];
      Exit(True);
    end;
    if (FBoard = MAPPER_VRC_FS306) or (FBoard = MAPPER_SUBOR_SANGOKUSHI) then
    begin
      Value := FPrgRam[Address and $1FFF];
      Exit(True);
    end;
    if ((FBoard = MAPPER_VRC_L1A16) or (FBoard = MAPPER_VRC_KL06) or
      (FBoard = MAPPER_VRC_J33C) or (FBoard = MAPPER_VRC_9052) or (FBoard = MAPPER_VRC_JC011) or
      (FBoard = MAPPER_VRC_AD301)) and
      BoardPrgRamSelected(Address) and (FBoardPrgRamSize <> 0) then
    begin
      Value := FPrgRam[Address and (FBoardPrgRamSize - 1)];
      Exit(True);
    end;
    if FIsVrc2Board and (Address < $7000) then
    begin
      if FBoard = MAPPER_VRC_YY841157C then
        Value := FOuterBank
      else
        Value := (FCpuOpenBus and $FE) or FRamLatch;
      Exit(True);
    end;
    Exit(False);
  end;
  if (FBoard = MAPPER_VRC2_VRC4_183) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(Integer(FRamLatch) * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  Result := inherited CpuRead(Address, Value);
end;

function TMapperVrc.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_WAIXING_252) or (FBoard = MAPPER_VRC4_253) or (FBoard = MAPPER_TF1201) or (FBoard = MAPPER_T230) then
  begin
    if Address < $8000 then
      Exit(inherited CpuWrite(Address, Value));

    var A := Address;
    if FBoard = MAPPER_T230 then
      A := (Address and $F000) or (Ord((Address and $2A) <> 0) shl 1) or Ord((Address and $15) <> 0);
    if FBoard = MAPPER_TF1201 then
      A := (Address and $F003) or ((Address and 12) shr 2);
    if (A >= $B000) and (A < $F000) then
    begin
      var Slot: Integer;
      var Shift: Integer;
      if FBoard = MAPPER_WAIXING_252 then
      begin
        Slot := (((A - $B000) shr 11) and 6) or ((A shr 3) and 1);
        Shift := A and 4
      end
      else if FBoard = MAPPER_VRC4_253 then
      begin
        Slot := ((((A and 8) or (A shr 8)) shr 3) + 2) and 7;
        Shift := A and 4
      end
      else if FBoard = MAPPER_TF1201 then
      begin
        Slot := (((A shr 11) - 6) or (A and 1)) and 7;
        Shift := (A and 2) * 2
      end
      else
      begin
        Slot := ((A shr 12) - 11) * 2 + ((A shr 1) and 1);
        Shift := (A and 1) * 4
      end;
      var Mask := 15;
      if (FBoard = MAPPER_T230) and (Shift = 4) then
        Mask := 31;
      if (FBoard = MAPPER_T230) and FHasChrRam then
        FRamLatch := (Value and 8) shl 2
      else
      begin
        FChrRegisters[Slot] := (FChrRegisters[Slot] and ($1FF xor (Mask shl Shift))) or ((Value and Mask) shl Shift);
        if (FBoard = MAPPER_VRC4_253) and (Shift = 4) then
          FChrRegisters[Slot] := (FChrRegisters[Slot] and $FF) or ((Value shr 4) shl 8);
        if (FBoard = MAPPER_VRC4_253) and (Slot = 0) then
          if (FChrRegisters[Slot] and $FF) = $C8 then
            FForceRom := False
          else if (FChrRegisters[Slot] and $FF) = $88 then
            FForceRom := True;
        Chr1(Slot, FChrRegisters[Slot]);
      end;
    end
    else if A >= $F000 then
    begin
      var R := A and 3;
      if (FBoard = MAPPER_WAIXING_252) or (FBoard = MAPPER_VRC4_253) then
        R := (A shr 2) and 3;
      if FBoard = MAPPER_TF1201 then
        case R of
          1:
            R := 2;
          2:
            R := 1
        end;
      case R of
        0:
          begin
            FLatch := (FLatch and $F0) or (Value and 15);
            if FBoard = MAPPER_VRC4_253 then
              FPending := False
          end;
        1:
          begin
            FLatch := (FLatch and 15) or ((Value and 15) shl 4);
            if FBoard = MAPPER_VRC4_253 then
              FPending := False
          end;
        2:
          begin
            FControl := Value and 7;
            FPending := False;
            if (FControl and 2) <> 0 then
            begin
              FCounter := FLatch;
              FPrescaler := 341
            end;
            if FBoard = MAPPER_VRC4_253 then
            begin
              FCounter := FLatch;
              FPrescaler := 114;
              FControl := Value and 2
            end
          end;
        3:
          begin
            FPending := False;
            FControl := (FControl and 5) or ((FControl and 1) shl 1)
          end;
      end;
    end
    else if (FBoard = MAPPER_VRC4_253) then
      case A of
        $8010:
          FPrg0 := Value;
        $A010:
          FPrg1 := Value;
        $9400:
          Mirror(Value and 3)
      end
    else if (FBoard = MAPPER_T230) then
      case A and $F002 of
        $9000:
          Mirror(Value and 3);
        $9002:
          FSwap := Value and 2;
        $A000, $A002:
          begin
            FPrg0 := (Value and 31) shl 1;
            FPrg1 := FPrg0 or 1
          end;
      end
    else
      case A and $F000 of
        $8000:
          FPrg0 := Value;
        $A000:
          FPrg1 := Value;
        $9000:
          if (FBoard = MAPPER_TF1201) and ((A and 3) = 1) then
            FSwap := Ord((Value and 3) <> 0) * 2
          else
            Mirror(Value and 1);
      end;
    Prg8(0, -2);
    Prg8(2, -2);
    Prg8(FSwap, FPrg0);
    Prg8(1, FPrg1);
    if FBoard = MAPPER_T230 then
    begin
      Prg8(2 - FSwap, 30 or FRamLatch);
      Prg8(FSwap, FPrg0 or FRamLatch)
    end;
    Exit(True);
  end;

  if Address < $8000 then
  begin
    if (FBoard = MAPPER_VRC_9052) and ((Address and $F000) = $5000) then
    begin
      FOuterBank := Address and $FF;
      SyncBoardPrg;
      Exit(True);
    end;
    if FExtendedWiring and (Address >= $6000) then
    begin
      if (FBoard = MAPPER_VRC_JC011) and (FSubmapper = 2) and (Address >= $7000) then
      begin
        FOuterBank := Address and $FF;
        SyncBoardPrg;
        Exit(True);
      end;
      if FBoard = MAPPER_VRC_AD301 then
      begin
        if BoardPrgRamSelected(Address) then
        begin
          if FBoardPrgRamSize <> 0 then
            FPrgRam[Address and (FBoardPrgRamSize - 1)] := Value;
          if (FOuterBank and 8) = 0 then
          begin
            FOuterBank := Address and $FF;
            SyncBoardPrg;
          end;
        end;
        Exit(True);
      end;
      if (FBoard = MAPPER_VRC_FS306) or (FBoard = MAPPER_SUBOR_SANGOKUSHI) then
        FPrgRam[Address and $1FFF] := Value
      else if ((FBoard = MAPPER_VRC_L1A16) or (FBoard = MAPPER_VRC_KL06)) and BoardPrgRamSelected(Address) then
      begin
        if FBoardPrgRamSize <> 0 then
          FPrgRam[Address and (FBoardPrgRamSize - 1)] := Value;
        if (FBoard = MAPPER_VRC_L1A16) and ((Address and $800) <> 0) and ((FOuterBank and 8) = 0) then
        begin
          FOuterBank := Value;
          SyncBoardPrg;
        end
        else if (FBoard = MAPPER_VRC_KL06) and ((FOuterBank and 1) = 0) then
        begin
          FOuterBank := Address and $FF;
          SyncBoardPrg;
        end;
      end
      else if (FBoard = MAPPER_VRC_J33C) or (FBoard = MAPPER_VRC_9052) or (FBoard = MAPPER_VRC_JC011) then
      begin
        if BoardPrgRamSelected(Address) and (FBoardPrgRamSize <> 0) then
          FPrgRam[Address and (FBoardPrgRamSize - 1)] := Value
        else if (FBoard = MAPPER_VRC_J33C) and (Address < $7000) then
          FRamLatch := Value and 1;
        if (FBoard = MAPPER_VRC_JC011) and (FSubmapper <> 2) and BoardPrgRamSelected(Address) and
          ((FOuterBank and 1) = 0) then
        begin
          FOuterBank := Address and $FF;
          SyncBoardPrg;
        end;
      end
      else if FIsVrc2Board and (Address < $7000) then
      begin
        FRamLatch := Value and 1;
        if FBoard = MAPPER_VRC_YY841157C then
        begin
          FOuterBank := Value;
          SyncBoardPrg;
        end;
      end;
      Exit(True);
    end;
    if (FBoard = MAPPER_VRC2_VRC4_183) and (Address >= $6000) then
    begin
      FRamLatch := Address and 15;
      Exit(True)
    end;
    if (FNativeVrc2 or FNativeVrc4) and (Address >= $6000) then
    begin
      if StandardPrgRamSelected(Address) then
        FPrgRam[Address and (FBoardPrgRamSize - 1)] := Value
      else if FVrc2BitLatch and (Address < $7000) then
        FRamLatch := Value and 1;
      Exit(True);
    end;
    Exit(inherited CpuWrite(Address, Value));
  end;

  if FBoard = MAPPER_VRC_YY840820C then
    FOuterBank := Address and $FF;
  if FBoard = MAPPER_JYV610 then
    case Address and $F800 of
      $D800, $E800:
        begin
          FOuterBank := Ord((Address and $1000) <> 0);
          Exit(True);
        end;
    end;
  if (FBoard = MAPPER_SUBOR_SANGOKUSHI) and (Address >= $B000) and ((Address and $400) <> 0) then
    Value := Value shr 4;
  var LowBits: Integer;
  if FRegisterAddress0 <> 0 then
    LowBits := Ord((Address and FRegisterAddress0) <> 0) or
      (Ord((Address and FRegisterAddress1) <> 0) shl 1)
  else if (FBoard = MAPPER_VRC_L1A16) or (FBoard = MAPPER_VRC_DATACH_2IN1) or
    (FBoard = MAPPER_VRC_900218) or (FBoard = MAPPER_VRC_J3_C) then
    LowBits := (Address shr 2) and 3
  else if FBoard = MAPPER_VRC_KL06 then
    LowBits := (Address shr (2 - Ord(FSubmapper = 2))) and 3
  else if FBoard = MAPPER_VRC_J33C then
    LowBits := ((Address shr 3) and 1) or ((Address shr 1) and 2)
  else if FBoard = MAPPER_VRC_9052 then
    LowBits := Address and 3
  else if FBoard = MAPPER_VRC_JC011 then
  begin
    LowBits := (Address shr 2) and 3;
    if (FOuterBank and $10) <> 0 then
      LowBits := ((LowBits shl 1) and 2) or (LowBits shr 1);
  end
  else if FBoard = MAPPER_VRC_AD301 then
    LowBits := Ord((Address and 5) <> 0) or (Ord((Address and $0A) <> 0) shl 1)
  else if (FBoard = MAPPER_VRC_FS306) or (FBoard = MAPPER_SUBOR_SANGOKUSHI) then
    LowBits := (Address shr 10) and 3
  else if FBoard = MAPPER_JYV610 then
    LowBits := Address and 3
  else if (FBoard = MAPPER_VRC2_VRC4_27) or FIsVrc2Board or
    (FBoard = MAPPER_VRC_830506C) or (FBoard = MAPPER_VRC_YY840820C) then
    LowBits := Address and 3
  else if FBoard = MAPPER_VRC2_VRC4_183 then
    LowBits := (Address shr 2) and 3
  else
    LowBits := ((Address or (Address shr 2)) and 1) or ((((Address shr 1) or (Address shr 3)) and 1) shl 1);
  var Page := Address shr 12;
  var PreviousSwap := FSwap;
  case Page of
    8:
      FPrg0 := Value and $1F;
    9:
      if FNativeVrc2 or FIsVrc2Board then
        Mirror(Value and 1)
      else if FNativeVrc4 or FExtendedWiring then
      begin
        if LowBits = 0 then
          Mirror(Value and 3)
        else if LowBits = 2 then
        begin
          FSwap := Value and 2;
          FRamEnabled := (Value and 1) <> 0;
        end
        else if (LowBits = 3) and ((FBoard = MAPPER_VRC_FS306) or (FBoard = MAPPER_SUBOR_SANGOKUSHI)) then
          if (Address and 4) <> 0 then
            FNamePages[Address and 3] := Value and 1
          else
            FPrgC000 := Value;
      end
      else if LowBits < 2 then
        Mirror(Value and 3)
      else
        FSwap := Value and 2;
    $A:
      FPrg1 := Value and $1F;
    $B..$E:
      begin
        var Slot := (Page - $B) * 2 + (LowBits shr 1);
        if FBoard = MAPPER_VRC_AX40G then
        begin
          if (LowBits and 1) = 0 then
            FChrRegisters[Slot] := (FChrRegisters[Slot] and $FF0) or (Value and $0F)
          else
            FChrRegisters[Slot] := (FChrRegisters[Slot] and $0F) or (Integer(Value) shl 4);
        end
        else if (LowBits and 1) = 0 then
          FChrRegisters[Slot] := (FChrRegisters[Slot] and $1F0) or (Value and $0F)
        else
          FChrRegisters[Slot] := (FChrRegisters[Slot] and $0F) or
            ((Value and ($1F shr Ord(FNativeVrc2))) shl 4);
        if FBoard = MAPPER_VRC2A then
          Chr1(Slot, FChrRegisters[Slot] shr 1)
        else
          Chr1(Slot, FChrRegisters[Slot]);
      end;
    $F:
      if FBoard = MAPPER_NTDEC_TH2131 then
        case LowBits of
          0:
            begin
              FControl := 0;
              FCounter := 0;
              FPending := False;
            end;
          1:
            FControl := 2;
          3:
            FLatch := Value shr 4;
        end
      else if FBoard = MAPPER_VRC_J2020 then
      begin
        FPending := False;
        case Address and $1C of
          $08:
            begin
              FControl := 2;
              FCounter := 0;
            end;
          $0C:
            FControl := 0;
          $18:
            FOuterBank := Value;
          $1C:
            FCounter := 0;
        end;
      end
      else if FBoard = MAPPER_VRC_J33C then
        case Address and $0C of
          0:
            begin
              FCounter := Value;
              FPrescaler := 0;
              FPending := False;
            end;
          4:
            FControl := (Value and 1) shl 1;
        end
      else if FBoard = MAPPER_VRC_J3_C then
      begin
        if (LowBits and 2) = 0 then
        begin
          FCounter := Value;
          FPending := False;
        end
        else
        begin
          FControl := (Value and 1) shl 1;
          if FControl = 0 then
          begin
            FPrescaler := 0;
            FLatch := $7F;
            FPending := False;
          end;
        end;
      end
      else if FBoard = MAPPER_VRC_900218 then
      begin
        case LowBits of
          2:
            FControl := 2;
          3:
            begin
              FControl := 0;
              FCounter := 0;
              FPending := False;
            end;
        end;
      end
      else if not (FNativeVrc2 or FIsVrc2Board) then
        case LowBits of
          0:
            FLatch := (FLatch and $F0) or (Value and $0F);
          1:
            FLatch := (FLatch and $0F) or ((Value and $0F) shl 4);
          2:
            begin
              FControl := Value and 7;
              FPending := False;
              if (FControl and 2) <> 0 then
              begin
                FCounter := FLatch;
                FPrescaler := 341;
              end;
            end;
          3:
            begin
              FPending := False;
              if FBoard <> MAPPER_VRC_830506C then
                FControl := (FControl and 5) or ((FControl and 1) shl 1);
            end;
        end;
  end;
  if FExtendedWiring then
    SyncBoardPrg
  else if (Page = 8) or (Page = $A) or (FSwap <> PreviousSwap) then
    SyncStandardPrg;
  Result := True;
end;

procedure TMapperVrc.SyncStandardPrg;
begin
  Prg8(2 - FSwap, -2);
  Prg8(FSwap, FPrg0);
  Prg8(1, FPrg1);
end;

procedure TMapperVrc.TickIrq;
begin
  if FCounter = $FF then
  begin
    if FBoard = MAPPER_TF1201 then
      FCounter := 0
    else
      FCounter := FLatch;
    FPending := True;
  end
  else
    Inc(FCounter);
end;

function TMapperVrc.BoardChrOffset(Address: UInt16): Integer;
begin
  var Bank := FChrRegisters[Address shr 10];
  case FBoard of
    MAPPER_VRC_J2020:
      begin
        var Mask := $FF;
        if (FSubmapper <> 0) and ((FOuterBank and 2) = 0) then
          Mask := $7F;
        Bank := (Bank and Mask) or ((Integer(FOuterBank) shl 7) and not Mask);
      end;
    MAPPER_VRC_J33C, MAPPER_NTDEC_TH2131:
      Bank := Bank and $FF;
    MAPPER_VRC_9052:
      if FHasChrRam then
        Bank := Address shr 10
      else if (FOuterBank and 3) <> 0 then
        Bank := (Bank and $FF) or $200 or ((FOuterBank and 2) shl 7);
    MAPPER_VRC_JC011:
      begin
        var Mask := $7F or ((FOuterBank and $10) shl 3);
        Bank := (Bank and Mask) or ((Integer(FOuterBank) shl 4) and not Mask);
      end;
    MAPPER_VRC_830506C:
      if FOuterBank = 0 then
        Bank := (Bank and $7F) or (FChrRegisters[FLastChrSlot] and $180)
      else
        Bank := (Bank and $1FF) or $200;
    MAPPER_VRC_YY840820C:
      if (FOuterBank and $80) <> 0 then
      begin
        var Bank8K := $40 or ((FOuterBank shr 3) and 8) or (FChrRegisters[FLastChrSlot] and 7);
        Bank := (Bank8K shl 3) or (Address shr 10);
      end;
    MAPPER_VRC_KL06:
      Bank := ((Integer(FOuterBank) shl (7 - Ord(FSubmapper = 2))) and not $7F) or (Bank and $7F);
    MAPPER_VRC_AD301:
      begin
        var NarrowBit := 2 shr Ord(FSubmapper = 1);
        var Mask := $FF shr Ord((FOuterBank and NarrowBit) <> 0);
        var Outer := FOuterBank shl 7;
        if FSubmapper = 1 then
          Outer := ((FOuterBank and 1) shl 8) or ((FOuterBank and 2) shl 6);
        Bank := (Bank and Mask) or (Outer and not Mask);
      end;
    MAPPER_VRC_L1A16, MAPPER_VRC_YY841157C:
      Bank := (Integer(FOuterBank) shl 7) or (Bank and $7F);
    MAPPER_VRC_900218:
      Bank := Bank and $FF;
    MAPPER_VRC_DATACH_2IN1:
      Bank := Bank and 7;
  end;
  Result := (Bank * $400 + (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperVrc.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  if (Address < $2000) and ((FBoard = MAPPER_VRC_DATACH_2IN1) or
    (FBoard = MAPPER_VRC_YY840820C) or (FBoard = MAPPER_VRC_830506C)) then
  begin
    Value := FChrMemory[BoardChrOffset(Address)];
    Exit(True);
  end;
  Result := inherited PpuPeek(Address, Rendering, Value, Sprite);
end;

function TMapperVrc.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FExtendedWiring and (Address < $2000) then
  begin
    var Slot := Address shr 10;
    if (FBoard = MAPPER_VRC_FS306) and ((FChrRegisters[Slot] and FChrRamMask) = FChrRamCompare) then
    begin
      Value := FHybridRam[((FChrRegisters[Slot] and 1) shl 10) or (Address and $3FF)];
      Exit(True);
    end;
    if ((FBoard = MAPPER_VRC_DATACH_2IN1) or (FBoard = MAPPER_VRC_YY840820C) or
      ((FBoard = MAPPER_VRC_830506C) and (FOuterBank = 0))) and (FLastChrSlot <> Slot) then
    begin
      FLastChrSlot := Slot;
      SyncBoardPrg;
    end;
    Value := FChrMemory[BoardChrOffset(Address)];
    Exit(True);
  end;
  if (FBoard = MAPPER_VRC4_253) and (Address < $2000) and not FForceRom then
  begin
    var Bank := FChrRegisters[Address shr 10] and $FF;
    if (Bank = 4) or (Bank = 5) then
    begin
      Value := FHybridRam[(Bank and 1) * $400 + (Address and $3FF)];
      Exit(True)
    end;
  end;

  Result := inherited;
end;

function TMapperVrc.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
const
  ChrRamBase: array[0..7] of Byte = ($28, $00, $4C, $64, $46, $7C, $04, $FF);
begin
  if (FBoard = MAPPER_VRC_FS306) and (Address < $2000) then
  begin
    var Bank := FChrRegisters[Address shr 10];
    if (Bank and $80) <> 0 then
      if (Bank and $10) <> 0 then
      begin
        FChrRamMask := 0;
        FChrRamCompare := $FF;
      end
      else
      begin
        FChrRamMask := $FC or ((Bank shr 5) and 2);
        FChrRamCompare := ChrRamBase[((Bank shr 1) and 1) or ((Bank shr 2) and 2) or ((Bank shr 4) and 4)];
      end;
    if (Bank and FChrRamMask) = FChrRamCompare then
      FHybridRam[((Bank and 1) shl 10) or (Address and $3FF)] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_VRC4_253) and (Address < $2000) and not FForceRom then
  begin
    var Bank := FChrRegisters[Address shr 10] and $FF;
    if (Bank = 4) or (Bank = 5) then
    begin
      FHybridRam[(Bank and 1) * $400 + (Address and $3FF)] := Value;
      Exit(True)
    end;
  end;

  if FExtendedWiring and FHasChrRam and (Address < $2000) then
  begin
    FChrMemory[BoardChrOffset(Address)] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_WAIXING_252) and (Address < $2000) then
  begin
    FChrMemory[ChrOffset(Address)] := Value;
    Exit(True)
  end;

  Result := inherited;
end;

procedure TMapperVrc.ClockCpu;
begin
  if FBoard = MAPPER_VRC_J2020 then
    Exit;
  if FBoard = MAPPER_VRC_J33C then
  begin
    if (FControl and 2) = 0 then
    begin
      FPending := False;
      FPrescaler := 0;
      Exit;
    end;
    Inc(FPrescaler);
    if FPrescaler = 64 then
    begin
      FCounter := (FCounter + 1) and $FF;
      FPending := FCounter = 0;
    end
    else if FPrescaler = 112 then
      FPrescaler := 0;
    Exit;
  end;
  if (FControl and 2) = 0 then
    Exit;

  if FBoard = MAPPER_NTDEC_TH2131 then
  begin
    // The high counter is clocked on the rising edge of the low counter's bit 11.
    FCounter := (FCounter + 1) and $FFF;
    if FCounter = $800 then
      FLatch := (FLatch - 1) and $FF;
    if (FLatch = 0) and (FCounter < $800) then
      FPending := True;
    Exit;
  end;
  if FBoard = MAPPER_VRC_J3_C then
  begin
    FPrescaler := (FPrescaler + 1) and $FF;
    // After a disable, the first tick is at $80; later ticks occur on byte wrap.
    if (FPrescaler and FLatch) = 0 then
    begin
      FLatch := $FF;
      FCounter := (FCounter + 1) and $FF;
      FPending := FCounter = 0;
    end;
    Exit;
  end;
  if FBoard = MAPPER_VRC_900218 then
  begin
    FCounter := (FCounter + 1) and $7FF;
    FPending := (FCounter and $400) <> 0;
    Exit;
  end;
  if FBoard = MAPPER_VRC4_253 then
  begin
    Dec(FPrescaler);
    if FPrescaler <= 0 then
    begin
      FPrescaler := 114;
      TickIrq
    end;
    Exit
  end;

  if (FControl and 4) <> 0 then
    TickIrq
  else
  begin
    Dec(FPrescaler, 3);
    if FPrescaler <= 0 then
    begin
      Inc(FPrescaler, 341);
      TickIrq;
    end;
  end;
end;

procedure TMapperVrc.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if FBoard = MAPPER_VRC_J2020 then
  begin
    var NewHigh := (Address and $1000) <> 0;
    if FA12High and not NewHigh then
    begin
      FCounter := (FCounter + 1) and $0F;
      if (FCounter = 0) and ((FControl and 2) <> 0) then
        FPending := True;
    end;
    FA12High := NewHigh;
  end;
end;

function TMapperVrc.IrqPending: Boolean;
begin
  Result := FPending;
end;

end.

