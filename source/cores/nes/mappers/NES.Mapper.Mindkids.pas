unit NES.Mapper.Mindkids;

interface

uses
  NES.Mapper, NES.State, NES.Types;

type
  TMapperMindkids = class(TMapper)
  private
    const
      SectorSize = $20000;
  private
    FPrg: NES.Types.TByteArray;
    FChr: NES.Types.TByteArray;
    FFlashSectors: TArray<NES.Types.TByteArray>;
    FWorkRam: array[0..$1FFF] of Byte;
    FRegs: array[0..7] of Byte;
    FPrgOffsets: array[0..3] of Integer;
    FChrOffsets: array[0..7] of Integer;
    FNamePages: array[0..3] of Integer;
    FInner: TMapper;
    FRegion: TNesRegion;
    FSubmapper, FMode, FNonVolatileSize, FFlashStep: Integer;
    FLatch: Byte;
    FHasWorkRam, FFlashId: Boolean;
    FMirror: TMirrorMode;
    function Locked: Boolean; inline;
    function PrgOffset(Address: Word): Integer; inline;
    function ReadPrg(Offset: Integer): Byte; inline;
    procedure EditFlashSector(Index: Integer; Erase: Boolean);
    procedure WriteFlash(Offset: Integer; Value: Byte);
    procedure ApplyMode;
    procedure SyncBanks;
    procedure TransferWorkRam(ToInner: Boolean);
    procedure SerializeFlash(State: TNesStateArchive);
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; Submapper: Integer);
    destructor Destroy; override;
    procedure ConfigureMemory(PrgRamSize, PrgNvRamSize, ChrRamSize: UInt64);
    procedure Reset; override;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    function NameTableOffset(Address: Word): Word; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: Word; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: NES.Types.TByteArray; override;
    procedure SetSaveMemory(const Data: NES.Types.TByteArray); override;
  end;

implementation

uses
  System.SysUtils, NES.Mapper.Banked, NES.Mapper.Mmc1, NES.Mapper.Mmc3,
  NES.Mapper.MmcLatch, NES.Mapper.Vrc, NES.Mapper.VrcAudio, NES.Mapper.Sunsoft,
  NES.Mapper.ExtendedIrq, NES.Mapper.Discrete;

const
  ModeUnrom = $00;
  ModeMmc3 = $01;
  ModeBnrom = $02;
  ModeCnrom = $03;
  ModeAnrom = $04;
  ModeSlrom = $05;
  ModeSnrom = $06;
  ModeSurom = $07;
  ModeGnrom = $08;
  ModePnrom = $09;
  ModeHkrom = $0A;
  ModeBandai = $0B;
  ModeTlsrom = $0E;
  Mode189 = $0F;
  ModeVrc6A = $10;
  ModeVrc6B = $11;
  ModeVrc2 = $12;
  ModeVrc3 = $13;
  ModeVrc4B = $15;
  ModeVrc4E = $18;
  ModeVrc4A = $19;
  ModeVrc1 = $1A;
  ModeFme7 = $1E;
  ModeH3001 = $1F;
  ModesMmc1 =[ ModeSlrom,  ModeSnrom,  ModeSurom];
  ModesMmc3 =[ ModeMmc3,  ModeHkrom,  ModeTlsrom,  Mode189];
  ModesVrc6 =[ ModeVrc6A,  ModeVrc6B];
  ModesDiscrete =[ ModeUnrom,  ModeBnrom,  ModeCnrom,  ModeAnrom,  ModeGnrom,  ModeBandai];

type
  TBankedView = class(TMapperBanked);

  TMmc3View = class(TMapperMmc3);

  TMmc1View = class(TMapperMmc1);

  TVrcAudioView = class(TMapperVrcAudio);

  TSunsoftView = class(TMapperSunsoft);

constructor TMapperMindkids.Create(const Prg, Chr: NES.Types.TByteArray; Submapper: Integer);
begin
  inherited Create;
  ValidateMemory(Prg, Chr);
  if (Submapper < 0) or (Submapper > 4) or (Length(Chr) <> 0) then
    raise ENesException.Create('Unsupported Mindkids FPGA cartridge layout');
  FPrg := Prg;
  FSubmapper := Submapper;
  SetLength(FChr, $2000);
  SetLength(FFlashSectors, (Length(FPrg) + SectorSize - 1) div SectorSize);
  Reset;
end;

destructor TMapperMindkids.Destroy;
begin
  FInner.Free;
  inherited;
end;

procedure TMapperMindkids.ConfigureMemory(PrgRamSize, PrgNvRamSize, ChrRamSize: UInt64);
begin
  if (PrgRamSize > $2000) or (PrgNvRamSize > $2000) or
    (PrgRamSize + PrgNvRamSize > $2000) or (ChrRamSize > $40000) then
    raise ENesException.Create('Unsupported Mindkids FPGA RAM layout');
  FHasWorkRam := (PrgRamSize + PrgNvRamSize) <> 0;
  FNonVolatileSize := Integer(PrgNvRamSize);
  if ChrRamSize <> 0 then
    SetLength(FChr, Integer(ChrRamSize));
  SyncBanks;
end;

function TMapperMindkids.Locked: Boolean;
begin
  Result := (FRegs[0] and $80) <> 0;
end;

procedure TMapperMindkids.ApplyMode;
begin
  FreeAndNil(FInner);
  FMode := FRegs[0] and $1F;
  if not Locked then
    Exit;

  case FSubmapper of
    0:
      case FMode of
        1:
          FMode := ModeSnrom;
        4:
          FMode := ModeMmc3;
        6:
          FMode := ModeVrc4A;
        7:
          FMode := ModeVrc2;
        8:
          FMode := ModeVrc4E;
        9:
          FMode := ModeVrc6A;
        10:
          FMode := ModeVrc4B;
        11:
          FMode := ModeVrc6B;
        12:
          FMode := ModeVrc3;
      end;
    2:
      if FMode in [9, 13] then
        FMode := ModeMmc3;
    3:
      if FMode = 1 then
        FMode := ModeH3001;
    4:
      case FMode of
        2:
          FMode := ModeFme7;
        3:
          FMode := ModeVrc4E;
        6:
          FMode := ModeVrc3;
      end;
  end;

  if FMode in ModesDiscrete then
    Exit;

  // Child controllers decode writes and IRQs. Their banks are taken modulo
  // 256 so that negative fixed-bank numbers preserve all eight output bits.
  var ControllerPrg: NES.Types.TByteArray;
  SetLength(ControllerPrg, $200000);
  case FMode of
    ModeMmc3, ModeHkrom, ModeTlsrom, Mode189:
      FInner := TMapperMmc3.Create(ControllerPrg, nil, False, FMirror, FMode = ModeHkrom);
    ModeSlrom, ModeSnrom, ModeSurom:
      FInner := TMapperMmc1.Create(ControllerPrg, nil, False, FMirror);
    ModePnrom:
      FInner := TMapperMmcLatch.Create(False, ControllerPrg, nil, False, FMirror);
    ModeVrc6A:
      FInner := TMapperVrcAudio.Create(MAPPER_VRC6A, ControllerPrg, nil, True, FMirror);
    ModeVrc6B:
      FInner := TMapperVrcAudio.Create(MAPPER_VRC6B, ControllerPrg, nil, True, FMirror);
    ModeVrc2:
      FInner := TMapperVrc.Create(MAPPER_VRC2A, ControllerPrg, nil, False, FMirror);
    ModeVrc4A:
      FInner := TMapperVrc.Create(MAPPER_VRC4A_VRC4C, ControllerPrg, nil, False, FMirror);
    ModeVrc4E:
      FInner := TMapperVrc.Create(MAPPER_VRC2B_VRC4E, ControllerPrg, nil, False, FMirror);
    ModeVrc4B:
      FInner := TMapperVrc.Create(MAPPER_VRC2C_VRC4B, ControllerPrg, nil, False, FMirror);
    ModeVrc1:
      FInner := TMapperDiscrete.Create(MAPPER_VRC1, ControllerPrg, nil, False, FMirror);
    ModeVrc3:
      FInner := TMapperDiscrete.Create(MAPPER_VRC3, ControllerPrg, nil, False, FMirror);
    ModeH3001:
      FInner := TMapperExtendedIrq.Create(MAPPER_IREM_H3001, ControllerPrg, nil, False, FMirror);
    ModeFme7:
      FInner := TMapperSunsoft.Create(MAPPER_FME7, ControllerPrg, nil, False, FMirror);
  end;
  if FInner <> nil then
  begin
    FInner.SetRegion(FRegion);
    TransferWorkRam(True);
  end;
end;

procedure TMapperMindkids.TransferWorkRam(ToInner: Boolean);
begin
  if (FInner = nil) or not FHasWorkRam or (FMode in [ModeVrc2, ModeFme7]) then
    Exit;
  if FInner is TMapperBanked then
  begin
    var Ram := TBankedView(FInner).FPrgRam;
    if ToInner then
      Move(FWorkRam[0], Ram[0], SizeOf(FWorkRam))
    else
      Move(Ram[0], FWorkRam[0], SizeOf(FWorkRam));
    Exit;
  end;
  if FInner is TMapperMmc3 then
  begin
    var RamSize := SizeOf(FWorkRam);
    if FMode = ModeHkrom then
      RamSize := $400;
    if ToInner then
      Move(FWorkRam[0], TMmc3View(FInner).FPrgRam[0], RamSize)
    else
      Move(TMmc3View(FInner).FPrgRam[0], FWorkRam[0], RamSize);
    Exit;
  end;
  if ToInner then
  begin
    var Ram: NES.Types.TByteArray;
    SetLength(Ram, SizeOf(FWorkRam));
    Move(FWorkRam[0], Ram[0], Length(Ram));
    FInner.SetSaveMemory(Ram);
  end
  else
  begin
    var Ram := FInner.GetSaveMemory;
    Move(Ram[0], FWorkRam[0], Length(Ram));
  end;
end;

procedure TMapperMindkids.SyncBanks;
var
  Prg: array[0..3] of Integer;
  Chr: array[0..7] of Integer;
  PrgOuter, PrgMask, ChrOuter, ChrMask, Bank: Integer;
begin
  PrgOuter := FRegs[1] or (Integer(FRegs[2]) shl 8);
  PrgMask := FRegs[3];
  ChrOuter := FRegs[6];
  if (FRegs[4] and 1) <> 0 then
    FMirror := TMirrorMode.Vertical
  else
    FMirror := TMirrorMode.Horizontal;
  for var Slot := 0 to 7 do
    Chr[Slot] := ChrOuter * 8 + Slot;

  if not Locked or ((FInner = nil) and not (FMode in ModesDiscrete)) then
  begin
    Prg[0] := PrgOuter;
    Prg[1] := PrgOuter + 1;
    Prg[2] := $3E - $20 * Ord(FSubmapper = 3);
    Prg[3] := Prg[2] + 1;
  end
  else if FMode in ModesDiscrete then
  begin
    case FMode of
      ModeUnrom, ModeBandai:
        begin
          Bank := FLatch;
          var FixedBank := $1F;
          if FMode = ModeBandai then
          begin
            Bank := FLatch shr 4;
            FixedBank := $FF;
            FMirror := TMirrorMode(Ord(TMirrorMode.Single0) + (FLatch shr 7));
            for var Slot := 0 to 7 do
              Chr[Slot] := (FLatch and $0F) * 8 + Slot;
          end;
          Prg[0] := ((Bank and (PrgMask shr 1)) or (PrgOuter shr 1)) * 2;
          Prg[1] := Prg[0] + 1;
          Prg[2] := ((FixedBank and (PrgMask shr 1)) or (PrgOuter shr 1)) * 2;
          Prg[3] := Prg[2] + 1;
        end;
      ModeBnrom, ModeCnrom:
        for var Slot := 0 to 3 do
        begin
          Bank := Slot;
          if FMode = ModeBnrom then
            Bank := (Integer(FLatch) shl 2) or Slot;
          Prg[Slot] := PrgOuter or (Bank and PrgMask);
        end;
    else
      Bank := FLatch;
      if FMode = ModeGnrom then
        Bank := FLatch shr 4
      else
        FMirror := TMirrorMode(Ord(TMirrorMode.Single0) + ((FLatch shr 4) and 1));
      Bank := ((Bank and (PrgMask shr 2)) or (PrgOuter shr 2)) * 4;
      for var Slot := 0 to 3 do
        Prg[Slot] := Bank + Slot;
    end;
    if FMode in [ModeCnrom, ModeGnrom] then
      for var Slot := 0 to 7 do
        Chr[Slot] := (FLatch and 3) * 8 + Slot;
  end
  else
  begin
    if FMode <> ModeVrc3 then
      FMirror := FInner.GetMirrorMode;
    if FMode in ModesMmc3 then
    begin
      var Chip := TMmc3View(FInner);
      ChrMask := $FF;
      case FMode of
        ModeMmc3, ModeHkrom:
          begin
            PrgMask := PrgMask and $3F;
            case FRegs[4] and $30 of
              $20:
                ChrMask := $7F;
              $30:
                ChrMask := $1F;
            end;
          end;
        ModeTlsrom:
          ChrMask := $7F;
      end;
      for var Slot := 0 to 3 do
        if FMode = Mode189 then
          Prg[Slot] := (((PrgOuter shr 2) or (FLatch and 3)) shl 2) + Slot
        else
          Prg[Slot] := PrgOuter or (Chip.PrgRegisterBank(Slot) and PrgMask);
      for var Slot := 0 to 7 do
      begin
        Bank := Chip.ChrRegisterBank(Slot xor ((Chip.FBankSelect shr 5) and 4));
        Chr[Slot] := ChrOuter or (Bank and ChrMask);
        if Slot < 4 then
          FNamePages[Slot] := Bank shr 7;
      end;
    end
    else if FMode in ModesMmc1 then
    begin
      var Chip := TMmc1View(FInner);
      var Selected := Chip.FPrgBank and $0F;
      if FMode = ModeSurom then
        PrgOuter := PrgOuter or ((Chip.FChrBank0 and $10) shl 1);
      for var Slot := 0 to 1 do
      begin
        case (Chip.FControl shr 2) and 3 of
          0, 1:
            Bank := (Selected and $0E) + Slot;
          2:
            Bank := Selected * Slot;
        else
          if Slot = 0 then
            Bank := Selected
          else
            Bank := $0F;
        end;
        Prg[Slot * 2] := ((PrgOuter shr 1) or (Bank and (PrgMask shr 1))) * 2;
        Prg[Slot * 2 + 1] := Prg[Slot * 2] + 1;
        if (Chip.FControl and $10) = 0 then
          Bank := (Chip.FChrBank0 and $1E) + Slot
        else if Slot = 0 then
          Bank := Chip.FChrBank0
        else
          Bank := Chip.FChrBank1;
        Bank := ((ChrOuter shr 2) or (Bank and $1F)) * 4;
        for var Page := 0 to 3 do
          Chr[Slot * 4 + Page] := Bank + Page;
      end;
    end
    else
    begin
      var Chip := TBankedView(FInner);
      if FMode = ModeVrc3 then
      begin
        PrgOuter := PrgOuter and not 1;
        PrgMask := PrgMask or 1;
      end;
      for var Slot := 0 to 3 do
        Prg[Slot] := PrgOuter or (Chip.FPrgBanks[Slot] and PrgMask);
      for var Slot := 0 to 7 do
        Chr[Slot] := Chip.FChrBanks[Slot];
      if FMode in ModesVrc6 then
        for var Slot := 0 to 3 do
          FNamePages[Slot] := TVrcAudioView(FInner).FNameBanks[Slot];
    end;
  end;

  for var Slot := 0 to 3 do
    FPrgOffsets[Slot] := (Prg[Slot] mod (Length(FPrg) div $2000)) * $2000;
  for var Slot := 0 to 7 do
    FChrOffsets[Slot] := (Chr[Slot] * $400) mod Length(FChr);
end;

procedure TMapperMindkids.Reset;
begin
  TransferWorkRam(False);
  FreeAndNil(FInner);
  FillChar(FRegs, SizeOf(FRegs), 0);
  FMode := 0;
  FLatch := 0;
  FFlashStep := 0;
  FFlashId := False;
  SyncBanks;
end;

function TMapperMindkids.PrgOffset(Address: Word): Integer;
begin
  Result := FPrgOffsets[(Address - $8000) shr 13] + (Address and $1FFF);
end;

function TMapperMindkids.ReadPrg(Offset: Integer): Byte;
begin
  var Sector := Offset div SectorSize;
  if FFlashSectors[Sector] = nil then
    Result := FPrg[Offset]
  else
    Result := FFlashSectors[Sector][Offset mod SectorSize];
end;

procedure TMapperMindkids.EditFlashSector(Index: Integer; Erase: Boolean);
begin
  var Offset := Index * SectorSize;
  var Size := Length(FPrg) - Offset;
  if Size > SectorSize then
    Size := SectorSize;
  if Erase then
  begin
    SetLength(FFlashSectors[Index], Size);
    FillChar(FFlashSectors[Index][0], Size, $FF);
  end
  else if FFlashSectors[Index] = nil then
    FFlashSectors[Index] := Copy(FPrg, Offset, Size);
end;

procedure TMapperMindkids.WriteFlash(Offset: Integer; Value: Byte);
begin
  var Command := Offset and $FFF;
  var Sector := Offset div SectorSize;
  // S29GL512S x8 AMD command sequence, with 128 KiB erase sectors.
  case FFlashStep of
    0:
      if (Command = $AAA) and (Value = $AA) then
        FFlashStep := 1
      else if Value = $F0 then
        FFlashId := False;
    1:
      FFlashStep := 2 * Ord((Command = $555) and (Value = $55));
    2:
      begin
        FFlashStep := 0;
        if Command = $AAA then
          case Value of
            $80:
              FFlashStep := 4;
            $90:
              FFlashId := True;
            $A0:
              FFlashStep := 3;
            $F0:
              FFlashId := False;
          end;
      end;
    3:
      begin
        EditFlashSector(Sector, False);
        FFlashSectors[Sector][Offset mod SectorSize] :=
          FFlashSectors[Sector][Offset mod SectorSize] and Value;
        FFlashStep := 0;
      end;
    4:
      FFlashStep := 5 * Ord((Command = $AAA) and (Value = $AA));
    5:
      FFlashStep := 6 * Ord((Command = $555) and (Value = $55));
    6:
      begin
        if (Command = $AAA) and (Value = $10) then
          for var Index := 0 to High(FFlashSectors) do
            EditFlashSector(Index, True)
        else if Value = $30 then
          EditFlashSector(Sector, True);
        FFlashStep := 0;
      end;
  end;
end;

function TMapperMindkids.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if Address >= $8000 then
  begin
    if FFlashId and not Locked then
    begin
      case Address and $1FF of
        0:
          Value := $01;
        2:
          Value := $7E;
        $1C:
          Value := $23;
        $1E:
          Value := $01;
      else
        Value := 0;
      end;
    end
    else
      Value := ReadPrg(PrgOffset(Address));
    Exit(True);
  end;

  if Address < $6000 then
    Exit(False);

  if Locked and (FMode = ModeFme7) then
  begin
    var WorkBank := TSunsoftView(FInner).FWorkBank;
    if (WorkBank and $40) = 0 then
    begin
      var Outer := FRegs[1] or (Integer(FRegs[2]) shl 8);
      var Bank := Outer or (WorkBank and $3F and FRegs[3]);
      var Offset := (Bank mod (Length(FPrg) div $2000)) * $2000 + (Address and $1FFF);
      Value := ReadPrg(Offset);
      Exit(True);
    end;
    if (WorkBank and $80) = 0 then
      Exit(False);
  end;

  if not FHasWorkRam or (Locked and (FMode in ModesDiscrete)) then
    Exit(False);
  if (FInner <> nil) and not (FMode in [ModeVrc2, ModeFme7, ModeVrc1]) then
    Exit(FInner.CpuRead(Address, Value));
  Value := FWorkRam[Address and $1FFF];
  Result := True;
end;

function TMapperMindkids.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := CpuWriteTimed(Address, Value, High(UInt64));
end;

function TMapperMindkids.CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean;
begin
  if Address < $5000 then
    Exit(False);
  if Address < $6000 then
  begin
    if not Locked then
    begin
      var Index := Address and 7;
      if (Index = 3) and (FSubmapper <> 2) then
        Value := Value xor $FF;
      FRegs[Index] := Value;
      if Locked then
      begin
        FLatch := 0;
        ApplyMode;
      end;
      SyncBanks;
    end;
    Exit(True);
  end;

  if Address < $8000 then
  begin
    if Locked and (FMode = Mode189) and (Address < $7000) then
    begin
      FLatch := Address and 3;
      SyncBanks;
      Exit(True);
    end;
    if not FHasWorkRam or (Locked and (FMode in ModesDiscrete)) then
      Exit(False);
    if Locked and (FMode = ModeFme7) and ((TSunsoftView(FInner).FWorkBank and $C0) <> $C0) then
      Exit(True);
    if (FInner <> nil) and not (FMode in [ModeVrc2, ModeFme7, ModeVrc1]) then
      Exit(FInner.CpuWriteTimed(Address, Value, CpuCycle));
    FWorkRam[Address and $1FFF] := Value;
    Exit(True);
  end;

  if not Locked then
    WriteFlash(PrgOffset(Address), Value)
  else if FMode in ModesDiscrete then
  begin
    FLatch := Value;
    SyncBanks;
  end
  else if FInner <> nil then
  begin
    if CpuCycle = High(UInt64) then
      FInner.CpuWrite(Address, Value)
    else
      FInner.CpuWriteTimed(Address, Value, CpuCycle);
    SyncBanks;
  end;
  Result := True;
end;

function TMapperMindkids.PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean;
begin
  if Address < $2000 then
  begin
    Value := FChr[(FChrOffsets[Address shr 10] + (Address and $3FF)) mod Length(FChr)];
    Exit(True);
  end;
  Result := (FInner <> nil) and (FMode in ModesVrc6) and (Address < $3F00) and
    ((TVrcAudioView(FInner).FMode and $10) <> 0);
  if Result then
    Value := FChr[(FNamePages[(Address shr 10) and 3] * $400 + (Address and $3FF)) mod Length(FChr)];
end;

function TMapperMindkids.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  Result := PpuPeek(Address, FPpuRenderingRead, Value, FPpuSpriteFetch);
  if Result and (FInner <> nil) and (FMode = ModePnrom) and
    ((Address = $0FD8) or (Address = $0FE8) or ((Address and $FFF8) = $1FD8) or
    ((Address and $FFF8) = $1FE8)) then
  begin
    var Ignored: Byte;
    FInner.PpuRead(Address, Ignored);
    SyncBanks;
  end;
end;

function TMapperMindkids.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if Address < $2000 then
  begin
    if (FRegs[5] and 4) = 0 then
      FChr[(FChrOffsets[Address shr 10] + (Address and $3FF)) mod Length(FChr)] := Value;
    Exit(True);
  end;
  Result := (FInner <> nil) and (FMode in ModesVrc6) and (Address < $3F00) and
    ((TVrcAudioView(FInner).FMode and $10) <> 0);
  if Result and ((FRegs[5] and 4) = 0) then
    FChr[(FNamePages[(Address shr 10) and 3] * $400 + (Address and $3FF)) mod Length(FChr)] := Value;
end;

function TMapperMindkids.GetMirrorMode: TMirrorMode;
begin
  Result := FMirror;
end;

function TMapperMindkids.NameTableOffset(Address: Word): Word;
begin
  if (FInner <> nil) and ((FMode = ModeTlsrom) or (FMode in ModesVrc6)) then
    Result := ((FNamePages[(Address shr 10) and 3] and 1) shl 10) or (Address and $3FF)
  else
    Result := inherited;
end;

procedure TMapperMindkids.SetRegion(Region: TNesRegion);
begin
  FRegion := Region;
  if FInner <> nil then
    FInner.SetRegion(Region);
end;

procedure TMapperMindkids.ClockCpu;
begin
  if FInner <> nil then
    FInner.ClockCpu;
end;

procedure TMapperMindkids.ClockPpuAddress(Address: Word; PpuCycle: UInt64);
begin
  if (FInner <> nil) and (FMode in ModesMmc3) then
    FInner.ClockPpuAddress(Address, PpuCycle);
end;

function TMapperMindkids.IrqPending: Boolean;
begin
  Result := (FInner <> nil) and FInner.IrqPending;
end;

function TMapperMindkids.ExpansionAudio: Double;
begin
  Result := 0;
  if (FInner <> nil) and (FMode in ModesVrc6) then
    Result := FInner.ExpansionAudio;
end;

procedure TMapperMindkids.SerializeFlash(State: TNesStateArchive);
begin
  for var Index := 0 to High(FFlashSectors) do
  begin
    var Modified := FFlashSectors[Index] <> nil;
    State.Field(Modified, SizeOf(Modified));
    if Modified then
    begin
      if State.Loading then
        EditFlashSector(Index, False);
      State.Field(FFlashSectors[Index][0], Length(FFlashSectors[Index]));
    end
    else if State.Loading then
      FFlashSectors[Index] := nil;
  end;
end;

procedure TMapperMindkids.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FFlashStep, SizeOf(FFlashStep));
  State.Field(FFlashId, SizeOf(FFlashId));
  State.Field(FWorkRam, SizeOf(FWorkRam));
  State.Field(FChr[0], Length(FChr));
  SerializeFlash(State);
  if State.Loading then
  begin
    if (FRegs[4] and 1) <> 0 then
      FMirror := TMirrorMode.Vertical
    else
      FMirror := TMirrorMode.Horizontal;
    ApplyMode;
  end;
  if FInner <> nil then
    FInner.SerializeState(State);
  if State.Loading then
    SyncBanks;
end;

function TMapperMindkids.GetSaveMemory: NES.Types.TByteArray;
begin
  TransferWorkRam(False);
  SetLength(Result, Length(FPrg) + FNonVolatileSize);
  Move(FPrg[0], Result[0], Length(FPrg));
  for var Index := 0 to High(FFlashSectors) do
    if FFlashSectors[Index] <> nil then
      Move(FFlashSectors[Index][0], Result[Index * SectorSize], Length(FFlashSectors[Index]));
  if FNonVolatileSize <> 0 then
    Move(FWorkRam[0], Result[Length(FPrg)], FNonVolatileSize);
end;

procedure TMapperMindkids.SetSaveMemory(const Data: NES.Types.TByteArray);
begin
  if Length(Data) <> Length(FPrg) + FNonVolatileSize then
    raise ENesException.Create('Invalid Mindkids FPGA save size');
  for var Index := 0 to High(FFlashSectors) do
  begin
    var Offset := Index * SectorSize;
    var Size := Length(FPrg) - Offset;
    if Size > SectorSize then
      Size := SectorSize;
    if CompareMem(@FPrg[Offset], @Data[Offset], Size) then
      FFlashSectors[Index] := nil
    else
      FFlashSectors[Index] := Copy(Data, Offset, Size);
  end;
  if FNonVolatileSize <> 0 then
  begin
    TransferWorkRam(False);
    Move(Data[Length(FPrg)], FWorkRam[0], FNonVolatileSize);
    TransferWorkRam(True);
  end;
end;

end.

