unit NES.Mapper.ExtendedMmc3;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Mmc3, NES.Mapper.Mmc1,
  NES.Mapper.Vrc;

type
  TMapperExtendedMmc3 = class(TMapperMmc3)
  private
    FBoard: Integer;
    FResetBank: Integer;
    FStarted: Boolean;
    FRegs: array[0..63] of Integer;
    FChrExtra: TByteArray;
    FPrgExtra: array[0..$7FFF] of Byte;
    FSubmapper, FMenuDip: Integer;
    FHasBoardPrgRam, FHasBoardChrRam: Boolean;
    FGn26LegacyPrgOrder: Boolean;
    FChrFromPrg: Boolean;
    FIsTec9719, FTecHasPrgRam, FTecLegacyChrOrder, FTecLegacyPrgOrder: Boolean;
    FChrRam: array[0..$1FFF] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    FNameBanks: array[0..3] of Byte;
    procedure UpdateTxSromNameBanks;
    procedure UpdateProtection121;
    function PrgBank(Slot: Integer): Integer;
    function ChrBank(Address: UInt16): Integer;
    function ChrRamOffset(Bank: Integer): Integer;
    function TecPrgBank(Slot, Bank: Integer): Integer;
    function TecChrBank(Slot, Bank: Integer): Integer;
    function WriteTecRegister(Address: UInt16; Value: Byte): Boolean;
    function Mapper327NameOffset(Address: UInt16): Integer;
    function K3033OuterBank: Integer;
    function CoolXPrgRamOffset(Address: UInt16): Integer;
    function UsesUnbankedChrRam: Boolean;
    function K3033WideBank: Boolean;
    function K3006UsesNrom256: Boolean;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer = 0);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    procedure PowerOn; override;
    procedure ConfigureRetroadChrRam(Size: UInt64);
    procedure ConfigureTecMemory(ChrRamSize: UInt64; HasPrgRam, LegacyChrOrder, LegacyPrgOrder: Boolean);
    procedure ConfigureCoolXPrgRam(Size: UInt64);
    property HasBoardPrgRam: Boolean read FHasBoardPrgRam write FHasBoardPrgRam;
    property HasBoardChrRam: Boolean read FHasBoardChrRam write FHasBoardChrRam;
    property Gn26LegacyPrgOrder: Boolean read FGn26LegacyPrgOrder write FGn26LegacyPrgOrder;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    function NameTableOffset(Address: UInt16): UInt16; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockCpu; override;
    procedure CpuRamWrite(Address: UInt16; Value: UInt8); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperJyMultiAsic = class(TMapperMmc3)
  private
    type
      TInnerAsic = (Mmc3, Mmc1, Vrc4);
  private
    FTechline, FWorkRamFitted, FChrRamFitted, FNromMirrorSet: Boolean;
    FOuter: array[0..3] of Byte;
    FWriteIndex: Integer;
    FChrRam: array[0..$1FFF] of Byte;
    FMmc1: TMapperMmc1;
    FVrc4: TMapperVrc;
    function ActiveAsic: TInnerAsic;
    function PrgBank(Slot: Integer): Integer;
    function ChrBank(Slot: Integer): Integer;
    function SwitchChrRam: Boolean;
    function WorkRamSelected(Writing: Boolean): Boolean;
    function VrcAddress(Address: UInt16): UInt16;
    procedure ResetOuter;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure ConfigureMemory(WorkRam, ChrRam: Boolean);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure PowerOn; override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
  end;

  TMapperNt319 = class(TMapperExtendedMmc3)
  private
    FMmc1: TMapperMmc1;
    function UsesMmc1: Boolean; inline;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
  end;

implementation

uses
  System.Hash, System.SysUtils;

const
  NES_EVENT2_TOURNAMENT_CYCLES = $14 shl 25;

constructor TMapperExtendedMmc3.Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  var T9552 := NoT9552;
  if Board = MAPPER_MMC3_249 then
    T9552 := LegacyT9552;
  inherited Create(Prg, Chr, HasChrRam, MirrorMode, False, False, False, False, T9552);
  FBoard := Board;
  FSubmapper := Submapper;
  FHasBoardPrgRam := Board <> MAPPER_DG574B;
  if Board = MAPPER_RETROAD_KJ01A then
  begin
    FHasBoardPrgRam := False;
    if HasChrRam then
      ConfigureRetroadChrRam($40000);
  end;
  if Board = MAPPER_BMC_GN27 then
    FMenuDip := 2;
  if (Board = MAPPER_BMC_T227) and (Submapper = 0) and (Length(Prg) = $100000) then
  begin
    var Hash := THashSHA1.Create;
    Hash.Update(Prg[0], Length(Prg));
    if SameText(Hash.HashAsString, 'A3D86BFDCFAB8A8C59695047BA7945BB3F6FF0D3') then
      FMenuDip := 7; // 60000-in-1 menu variant.
  end;
  FHasBoardChrRam := True;
  FChrFromPrg := (Board = MAPPER_GAMES_XPLOSION) and (Length(Chr) = 0);
  if FChrFromPrg then
    FHasChrRam := False;
  FIsTec9719 := (Board = MAPPER_MMC3_126) or (Board = MAPPER_TEC9719) or (Board = MAPPER_ING022);
  FTecHasPrgRam := True;
  FStarted := False;
  if Board = MAPPER_SACHEN_9602 then
  begin
    SetLength(FChrMemory, $8000);
    FHasChrRam := True
  end;
  if Board = MAPPER_MMC3_COOLBOY then
  begin
    SetLength(FChrMemory, $40000);
    FHasChrRam := True
  end;
  if Board = MAPPER_FK23C then
  begin
    SetLength(FChrExtra, $40000);
    if HasChrRam then
      SetLength(FChrMemory, $40000)
  end;
  Reset;
end;

procedure TMapperExtendedMmc3.PowerOn;
begin
  case FBoard of
    MAPPER_BMC_830947, MAPPER_BMC_820215CA2, MAPPER_ESTIQUE:
      begin
        FStarted := False;
        FResetBank := 0;
      end;
  end;
  if (FBoard = MAPPER_BMC_NT639) or (FBoard = MAPPER_COCOMA) or (FBoard = MAPPER_N49C300) then
    FRegs[0] := 0;
  if FBoard = MAPPER_N49C300 then
    FRegs[1] := 0;
  inherited;
end;

procedure TMapperExtendedMmc3.ConfigureRetroadChrRam(Size: UInt64);
begin
  if Size = 0 then
    Exit;
  if not FHasChrRam or ((Size <> $20000) and (Size <> $40000)) then
    raise ENesException.Create('Unsupported mapper 473 CHR memory layout');
  SetLength(FChrMemory, Integer(Size));
  FHasChrRam := True;
end;

procedure TMapperExtendedMmc3.Reset;
begin
  if FStarted then
    case FBoard of
      MAPPER_BMC_830947, MAPPER_BMC_820215CA2, MAPPER_ESTIQUE:
        begin
          if FBoard <> MAPPER_ESTIQUE then
            FRegs[0] := 0;
          if FBoard = MAPPER_BMC_820215CA2 then
            FResetBank := FResetBank xor 1;
          // Console reset leaves the separate MMC3 clone's registers latched.
          FIrqPending := False;
          Exit;
        end;
    end;
  inherited;
  var OuterBank := FRegs[0];
  var InnerBank := FRegs[1];
  if FStarted and (FBoard = MAPPER_RESET_TXROM) then
    FResetBank := (FResetBank + 1) and 3;
  if FStarted and (FBoard = MAPPER_MMC3_STREET_HEROES) then
    FResetBank := FResetBank xor $FF;
  FStarted := True;
  FillChar(FRegs, SizeOf(FRegs), 0);
  if (FBoard = MAPPER_BMC_NT639) or (FBoard = MAPPER_COCOMA) or (FBoard = MAPPER_N49C300) then
    FRegs[0] := OuterBank;
  if FBoard = MAPPER_N49C300 then
    FRegs[1] := InnerBank;
  if FIsTec9719 then
  begin
    FPrgRamControl := 0;
    FMirrorMode := TMirrorMode.Vertical;
  end;
  case FBoard of
    MAPPER_YY841101C, MAPPER_FK206, MAPPER_REALTEC_MMC3, MAPPER_NC7000M:
      begin
        FPrgRamControl := 0;
        FMirrorMode := TMirrorMode.Vertical;
      end;
  end;
  case FBoard of
    MAPPER_MMC3_45, MAPPER_BMC_SFC12, MAPPER_BMC_SFC13, MAPPER_BMC_VIP19, MAPPER_GAMES_XPLOSION:
      FRegs[2] := 15;
  end;
  case FBoard of
    MAPPER_NTDEC_N625231, MAPPER_BMC_WE7HGX, MAPPER_BMC_480, MAPPER_BMC_K3101, MAPPER_BMC_ET170, MAPPER_BMC_K3054, MAPPER_BMC_5426757A, MAPPER_BMC_GA009, MAPPER_BMC_A018, MAPPER_BMC_CG008, MAPPER_BMC_K3022, MAPPER_BMC_FC53A, MAPPER_BMC_1N4148, MAPPER_SACHEN_TC032, MAPPER_COCOMA, MAPPER_BMC_N42S2, MAPPER_BMC_JY4M4, MAPPER_BMC_ET149, MAPPER_BMC_T227, MAPPER_BMC_F648, MAPPER_BMC_910610, MAPPER_BMC_FC49, MAPPER_BMC_K3044, MAPPER_BMC_4782, MAPPER_BMC_NT319, MAPPER_N49C300, MAPPER_A971210, MAPPER_NTDEC_N625836, MAPPER_BMC_830947, MAPPER_RETROAD_KJ01A, MAPPER_BMC_820215CA2, MAPPER_ESTIQUE:
      begin
        FMirrorMode := TMirrorMode.Vertical;
        FIrqRequiresCounterTransition := True; // AX5202P does not IRQ on a zero-to-zero reload.
      end;
  end;
  if FBoard = MAPPER_RETROAD_KJ01A then
    FPrgRamControl := 0;
  case FBoard of
    MAPPER_BMC_TOP_TEN, MAPPER_BMC_820315C, MAPPER_BMC_GN27, MAPPER_BMC_NS32:
      begin
        FPrgRamControl := 0;
        FMirrorMode := TMirrorMode.Vertical;
        if FBoard = MAPPER_BMC_NS32 then
        begin
          case FSubmapper of
            0:
              FRegs[0] := $C2;
            1:
              FRegs[0] := $C3;
          end;
          FRegs[1] := 1;
        end;
      end;
    MAPPER_BMC_4782:
      FRegs[0] := $40;
    MAPPER_BMC_WE7HGX:
      FRegs[1] := $F0;
    MAPPER_BMC_480:
      FRegs[1] := 3;
    MAPPER_BMC_5426757A:
      FRegs[0] := $FE;
    MAPPER_BMC_CG008:
      FRegs[0] := $0F;
    MAPPER_BMC_N42S2:
      FRegs[0] := $60;
    MAPPER_JY302, MAPPER_JY208:
      FRegs[2] := $0F;
    MAPPER_YY841155C:
      if FSubmapper = 1 then
        FRegs[0] := $80;
    MAPPER_A88S1:
      FRegs[1] := 3;
  end;
  if FBoard = MAPPER_COOLX_LITE then
  begin
    FRegs[5] := 3;
    if FSubmapper <> 0 then
    begin
      FRegs[4] := $1F or ((FSubmapper and 3) shl 6);
      FRegs[5] := $1F;
    end;
  end;
  if FBoard = MAPPER_MMC3_121 then
    FRegs[3] := $80;
  if FBoard = MAPPER_MMC3_208 then
    FRegs[5] := 3;
  if FBoard = MAPPER_MMC3_215 then
    FRegs[1] := 3;
  if FBoard = MAPPER_MMC3_198 then
  begin
    FRegs[1] := 1;
    FRegs[2] := (Length(FPrgRom) div $2000) - 2;
    FRegs[3] := FRegs[2] + 1
  end;
  if FBoard = MAPPER_MMC3_199 then
  begin
    FRegs[0] := $FE;
    FRegs[1] := $FF;
    FRegs[2] := 1;
    FRegs[3] := 3
  end;
  if FBoard = MAPPER_MMC3_219 then
    for var i := 0 to 3 do
      FRegs[8 + i] := (Length(FPrgRom) div $2000) - 4 + i;
  if FBoard = MAPPER_TAITO_TC0690 then
  begin
    FRegs[0] := 0;
    FRegs[1] := 0
  end;
  if FBoard = MAPPER_MULTIMAPPER_116 then
  begin
    for var i := 0 to 3 do
      FRegs[8 + i] := $FF;
    for var i := 4 to 7 do
      FRegs[8 + i] := i;
    FRegs[2] := 1;
    FRegs[16] := 12;
    FBankRegisters[6] := $FC;
    FBankRegisters[7] := $FD;
  end;
  if FBoard = MAPPER_FK23C then
  begin
    FRegs[8] := $FE;
    FRegs[9] := $FF;
    FRegs[10] := $FF;
    FRegs[11] := $FF;
    if (Length(FPrgRom) = $100000) and (Length(FChrMemory) = $100000) then
      FRegs[4] := $20;
  end;
  if FBoard = MAPPER_TXSROM then
    UpdateTxSromNameBanks;
end;

procedure TMapperExtendedMmc3.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if (FBoard = MAPPER_MMC3_249) and not State.Loading then
    FRegs[0] := FT9552Pattern;
  State.Field(FRegs, SizeOf(FRegs));
  if (FBoard = MAPPER_MMC3_249) and State.Loading then
  begin
    if State.Version >= T9552_STATE_VERSION then
      FT9552Pattern := FRegs[0] and 7
    else
      FT9552Pattern := FRegs[0] and 2;
    UpdateBankOffsets;
  end;
  State.Field(FChrRam, SizeOf(FChrRam));
  State.Field(FNameRam, SizeOf(FNameRam));
  State.Field(FNameBanks, SizeOf(FNameBanks));
  if State.Loading and (FBoard = MAPPER_TXSROM) then
    UpdateTxSromNameBanks;
  State.Field(FResetBank, SizeOf(FResetBank));
  State.Field(FStarted, SizeOf(FStarted));
  if Length(FChrExtra) > 0 then
    State.Field(FChrExtra[0], Length(FChrExtra));
  if FBoard = MAPPER_FK23C then
    State.Field(FPrgExtra, SizeOf(FPrgExtra));
  if FBoard = MAPPER_NES_EVENT2 then
    State.Field(FPrgExtra[0], $800);
  if FBoard = MAPPER_MMC3_CHR_RAM_195 then
    if State.Version >= 20 then
      State.Field(FPrgExtra[0], $1000)
    else if State.Loading then
      FillChar(FPrgExtra, SizeOf(FPrgExtra), 0);
end;

procedure TMapperExtendedMmc3.ConfigureTecMemory(ChrRamSize: UInt64; HasPrgRam, LegacyChrOrder, LegacyPrgOrder: Boolean);
begin
  if FHasChrRam and (ChrRamSize > 0) then
  begin
    if ChrRamSize > $40000 then
      raise ENesException.Create('Unsupported TEC9719 CHR RAM size');
    SetLength(FChrMemory, Integer(ChrRamSize));
  end;
  FTecHasPrgRam := HasPrgRam;
  FTecLegacyChrOrder := LegacyChrOrder;
  FTecLegacyPrgOrder := LegacyPrgOrder;
end;

function TMapperExtendedMmc3.TecPrgBank(Slot, Bank: Integer): Integer;
begin
  var Mode := FRegs[3] and $F;
  var OuterReg := FRegs[0];
  if (Mode and 1) <> 0 then
  begin
    Bank := FBankRegisters[6];
    if (FBankSelect and $40) <> 0 then
      Bank := $FE;
    if ((Mode and $D) = $D) and (Slot >= 2) then
      if (FBankSelect and $40) = 0 then
        Bank := $FE
      else
        Bank := FBankRegisters[6];
  end;
  if (Mode and 8) <> 0 then
    case Mode and 3 of
      0:
        Bank := (Bank and 3) or ((Bank shl 1) and not 3);
      1:
        Bank := Slot or ((Bank shl 1) and not 1);
      2:
        Bank := (Bank and 3) or (Bank shl 2);
      3:
        Bank := Slot or (Bank shl 2);
    end
  else if (Mode and 1) <> 0 then
  begin
    var CpuLines := 1 or (Mode and 2);
    Bank := (Bank and not CpuLines) or (Slot and CpuLines);
  end;

  // The PRG output uses 8 KiB bank units. A21 is normally inverted.
  var Mask := $1F;
  if (OuterReg and $40) <> 0 then
    Mask := $0F;
  var Outer := ((OuterReg shl 4) and $70) or (((OuterReg xor $20) shl 3) and $180);
  case FSubmapper of
    1:
      begin
        Outer := (Outer and $7F) or ((Outer shr 1) and $80);
        if FTecLegacyPrgOrder then
          Outer := Outer xor $80;
      end;
    2:
      Outer := (Outer and $7F) or ((FRegs[1] and 4) shl 5);
    3:
      if (OuterReg and 4) <> 0 then
      begin
        Mask := Mask and not 2;
        Outer := Outer or (((not OuterReg) shr 4) and 2);
      end;
    5:
      Outer := Outer or (FRegs[4] shl 9);
    6, 7:
      begin
        var Extra := FRegs[4];
        Outer := ((OuterReg and $10) shl 7) or ((OuterReg and 1) shl 4) or
          ((Extra and 1) shl 5) or ((Extra and $E0) shl 3);
        if FSubmapper = 6 then
          Outer := Outer or ((Extra and $18) shl 3)
        else
          Outer := Outer or ((Extra and $10) shl 2) or ((Extra and 8) shl 4);
      end;
  end;
  Result := (Bank and Mask) or (Outer and not Mask);
end;

function TMapperExtendedMmc3.TecChrBank(Slot, Bank: Integer): Integer;
begin
  var OuterReg := FRegs[0];
  var Inverted := OuterReg xor $20;
  if FTecLegacyChrOrder then
    Inverted := OuterReg;
  var Mask := (not OuterReg and $80) or $7F;
  var Outer := (OuterReg and 8) shl 4;
  if FBoard = MAPPER_MMC3_126 then
    Outer := Outer or ((Inverted and $20) shl 3) or ((OuterReg and $10) shl 5)
  else if FSubmapper = 4 then
    Outer := Outer or ((OuterReg and 2) shl 7) or ((Inverted and $20) shl 4) or
      ((OuterReg and $10) shl 6)
  else
    Outer := Outer or ((OuterReg and $10) shl 4) or ((Inverted and $20) shl 4) or
      ((OuterReg and 4) shl 8);
  if (FSubmapper = 3) and ((OuterReg and 4) <> 0) then
  begin
    Mask := Mask and not $10;
    Outer := Outer or (((not OuterReg) shr 1) and $10);
  end;
  if (FRegs[3] and $10) <> 0 then
    Bank := (FRegs[2] shl 3) or Slot;
  Result := (Outer and not Mask) or (Bank and Mask);
end;

procedure TMapperExtendedMmc3.ConfigureCoolXPrgRam(Size: UInt64);
begin
  if (Size <> 0) and (Size <> $2000) and (Size <> $4000) and (Size <> $8000) then
    raise ENesException.Create('Unsupported CoolX Lite PRG RAM size');
  FHasBoardPrgRam := Size <> 0;
  if Size > $2000 then
    SetLength(FExtraPrgRam, Integer(Size) - $2000)
  else
    SetLength(FExtraPrgRam, 0);
end;

function TMapperExtendedMmc3.CoolXPrgRamOffset(Address: UInt16): Integer;
begin
  var Size := SizeOf(FPrgRam) + Length(FExtraPrgRam);
  Result := (((FRegs[3] shr 6) shl 13) or (Address and $1FFF)) and (Size - 1);
end;

function TMapperExtendedMmc3.NameTableOffset(Address: UInt16): UInt16;
begin
  if FBoard = MAPPER_TXSROM then
    Exit((FNameBanks[(Address shr 10) and 3] shl 10) or (Address and $3FF));
  if ((FBoard = MAPPER_BMC_ET149) and ((FRegs[0] and $80) <> 0)) or
    ((FBoard = MAPPER_BMC_NS32) and (FSubmapper = 2) and ((FRegs[1] and 8) <> 0)) then
  begin
    var Slot := ((Address shr 10) and 3) xor ((FBankSelect and $80) shr 5);
    Exit(((ChrRegisterBank(Slot) and $80) shl 3) or (Address and $3FF));
  end;
  if ((FBoard = MAPPER_BMC_810305C) and (FRegs[0] = 0)) or
    ((FBoard = MAPPER_F600) and ((FRegs[0] and 7) = 1)) then
  begin
    var Slot := ((Address shr 10) and 3) xor ((FBankSelect and $80) shr 5);
    var Page := (ChrRegisterBank(Slot) shr 7) xor 1;
    Exit((Page shl 10) or (Address and $3FF));
  end;
  Result := inherited NameTableOffset(Address);
end;

function TMapperExtendedMmc3.GetMirrorMode: TMirrorMode;
begin
  if FBoard = MAPPER_BMC_47_2 then
  begin
    if (FRegs[0] and $80) <> 0 then
      Exit(TMirrorMode.Horizontal);
    Exit(TMirrorMode.Vertical);
  end;
  if (FBoard = MAPPER_BMC_L6IN1) and ((FRegs[0] and $20) <> 0) then
  begin
    if (FRegs[0] and $10) <> 0 then
      Exit(TMirrorMode.Single1);
    Exit(TMirrorMode.Single0);
  end;
  if FBoard = MAPPER_COOLX_LITE then
  begin
    if (FRegs[3] and $C) = 4 then
    begin
      if (FBankRegisters[6] and $10) <> 0 then
        Exit(TMirrorMode.Single1);
      Exit(TMirrorMode.Single0);
    end;
    if ((FRegs[4] and $40) <> 0) and ((FRegs[6] and 2) = 0) then
    begin
      if (FRegs[6] and 1) <> 0 then
        Exit(TMirrorMode.Single1);
      Exit(TMirrorMode.Single0);
    end;
  end;
  if FIsTec9719 then
  begin
    if (FRegs[3] and $20) <> 0 then
    begin
      if (FBankRegisters[6] and $10) <> 0 then
        Exit(TMirrorMode.Single1);
      Exit(TMirrorMode.Single0);
    end;
    if (FRegs[1] and 2) <> 0 then
      case FRegs[5] and 3 of
        2:
          Exit(TMirrorMode.Single0);
        3:
          Exit(TMirrorMode.Single1);
      end;
  end;
  Result := inherited GetMirrorMode;
end;

function TMapperExtendedMmc3.PrgBank(Slot: Integer): Integer;
const
  Gn26LegacyBank: array[0..3] of Integer = (0, 3, 1, 2);
begin
  var OriginalSlot := Slot;
  Result := PrgRegisterBank(Slot);
  if ((FBankSelect and $40) <> 0) and ((Slot and 1) = 0) then
    Slot := Slot xor 2;
  case FBoard of
    MAPPER_DG574B:
      begin
        var Mask := $1F shr (FRegs[2] and 1);
        Result := (FRegs[0] and $70 and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_830947:
      Result := (FRegs[0] and $F0) or (Result and $0F);
    MAPPER_RETROAD_KJ01A:
      if (FRegs[0] and $20) = 0 then
        Result := $3F
      else
      begin
        var Mask := (2 shl (FRegs[0] and 7)) - 1;
        var Outer := (FRegs[2] shl 8) or FRegs[1];
        Result := (Outer and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_820215CA2:
      if FResetBank = 0 then
        Result := ($10 or ((FRegs[0] shr 4) and 3)) * 4 + OriginalSlot
      else if (FRegs[0] and 3) = 3 then
        Result := (((FRegs[0] shl 2) and $0C) or ((FRegs[0] shr 2) and 3)) * 4 + OriginalSlot
      else
        Result := ((FRegs[0] shl 4) and $F0) or (Result and $0F);
    MAPPER_ESTIQUE:
      Result := ((FRegs[0] and 1) shl 5) or (Result and $1F);
    MAPPER_N49C300:
      case FRegs[0] of
        $00, $01:
          Result := FRegs[0] * 4 + OriginalSlot;
        $13:
          if OriginalSlot = 2 then
            Result := $08 or FRegs[1]
          else
            Result := $0C or OriginalSlot;
        $37:
          Result := $10 or (Result and $0F);
        $FF:
          Result := $20 or (Result and $1F);
      end;
    MAPPER_A971210:
      begin
        var Mode := FRegs[0];
        var Outer := FRegs[3];
        if (Mode and $80) <> 0 then
        begin
          var Bank32K := ((Mode shr 1) and 7) or ((Outer shr 2) and 8);
          Result := Bank32K * 4 + OriginalSlot;
        end
        else
        begin
          var Mask := $3F shr Ord((Outer and $20) <> 0);
          if (Mode and $20) <> 0 then
            Mask := $0F;
          Result := ((Outer and 4) shl 3) or (Result and Mask);
        end;
      end;
    MAPPER_NTDEC_N625836:
      begin
        var Value := FRegs[0];
        if (Value and 1) = 0 then
          Result := ((Value shr 1) and $60) or (Result and $1F)
        else if (Value and 2) <> 0 then
          Result := (Value shr 3) * 4 + OriginalSlot
        else
          Result := (Value shr 2) * 2 + (OriginalSlot and 1);
      end;
    MAPPER_BMC_ET149:
      begin
        var Mode := FRegs[0];
        var Mask := $1F shr Ord((Mode and 4) <> 0);
        var Outer := ((Mode and 1) shl 4) or ((Mode and 8) shl 2) or ((Mode and $60) shl 1);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_TOP_TEN:
      begin
        if FRegs[0] = 8 then
          Result := (PrgRegisterBank(OriginalSlot and 1) and not 3) or OriginalSlot;
        Result := (Result and $0F) or (FRegs[0] shl 4);
      end;
    MAPPER_BMC_T227:
      begin
        var Mode := FRegs[0];
        var Mask := $0F;
        var Outer := Mode shl 1;
        if FSubmapper = 1 then
          Outer := (Mode and $20) or ((Mode and 8) shl 1)
        else if (Mode and $20) <> 0 then
          Mask := $1F;
        if (Mode and 2) <> 0 then
        begin
          var CpuLines := 1 or ((Mode and 1) shl 1);
          Result := (PrgRegisterBank(0) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_820315C, MAPPER_BMC_K3044:
      begin
        if (FBoard = MAPPER_BMC_820315C) and ((FRegs[0] and 8) <> 0) then
          Result := (PrgRegisterBank(0) and not 3) or OriginalSlot;
        Result := (Result and $0F) or (FRegs[0] shl 4);
      end;
    MAPPER_BMC_F648:
      Result := (Result and $1F) or (FRegs[0] shl 5);
    MAPPER_BMC_NT319:
      Result := (Result and $0F) or (FResetBank shl 4);
    MAPPER_BMC_FC49, MAPPER_BMC_910610:
      begin
        var Mode := FRegs[0];
        var Mask := $0F;
        if ((FBoard = MAPPER_BMC_FC49) and ((Mode and 4) <> 0)) or
          ((FBoard = MAPPER_BMC_910610) and ((Mode and 6) = 6)) then
          Mask := $1F;
        Result := (Result and Mask) or ((Mode shl 4) and not Mask);
      end;
    MAPPER_BMC_GN27:
      begin
        var Mode := FRegs[0];
        if (Mode and 4) <> 0 then
        begin
          var CpuLines := 3 - ((Mode and $10) shr 3);
          Result := (PrgRegisterBank(0) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
        Result := (Result and $0F) or (Mode shl 4);
      end;
    MAPPER_BMC_NS32:
      begin
        var Mode := FRegs[0];
        var Outer: Integer;
        if FSubmapper = 2 then
        begin
          Outer := (Mode shl 3) and $30;
          if (FRegs[1] and 4) <> 0 then
            Result := Outer or (Mode shr 2 and 4) or ((Mode and 1) shl 3) or OriginalSlot
          else
            Result := Outer or (Result and $0F);
        end
        else if FSubmapper = 1 then
          Result := (Mode shl 4) or (Result and $0F)
        else if (Mode and 2) <> 0 then
          Result := ((Mode shr 1) and $20) or ((Mode shl 2) and $10) or (Result and $0F)
        else
        begin
          Outer := ((Mode shr 3) and 8) or (Mode and 4) or ((Mode shr 4) and 1) or ((Mode and 1) shl 1);
          Result := (Outer shl 2) or OriginalSlot;
        end;
      end;
    MAPPER_BMC_4782:
      begin
        var Mode := FRegs[0];
        if (Mode and $40) <> 0 then
          Result := ((Mode shr 2) and $1C) or ((Mode shr 6) and 2) or (OriginalSlot and 1)
        else
          Result := ((Mode shr 2) and $1C) or OriginalSlot;
      end;
    MAPPER_BMC_FC53A:
      begin
        var Mode := FRegs[0];
        var Mask := $1F shr Ord((Mode and $20) <> 0);
        var Outer := ((Mode and 8) shl 2) or ((Mode and $40) shr 2);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_1N4148:
      begin
        var Mode := FRegs[0];
        if (Mode and 4) <> 0 then
        begin
          var CpuLines := 3 - (Mode and 2);
          Result := (PrgRegisterBank(OriginalSlot and 1) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
        Result := (Result and $0F) or (Mode shl 4);
      end;
    MAPPER_SACHEN_TC032:
      Result := Result and $3F;
    MAPPER_COCOMA:
      Result := (Result and $0F) or ((FRegs[0] and 3) shl 4);
    MAPPER_BMC_N42S2:
      begin
        var Mode := FRegs[0];
        var Bank := (Mode and $1F) or ((Mode shr 1) and $20);
        if (Mode and $80) <> 0 then
          Result := (Result and $0F) or (Bank shl 2)
        else
        begin
          var CpuLines := 1 + ((Mode and $20) shr 4);
          Result := ((Bank shl 1) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
      end;
    MAPPER_BMC_JY4M4:
      begin
        var Mode := FRegs[0];
        if (Mode and $80) <> 0 then
          Result := (Result and $0F) or ((Mode and $40) shr 1) or ((FRegs[1] and 1) shl 4)
        else
        begin
          if OriginalSlot >= 2 then
            Mode := Mode or 7;
          Result := (Mode shl 1) or (OriginalSlot and 1);
        end;
      end;
    MAPPER_NTDEC_N625231:
      begin
        var Mode := FRegs[0];
        var Bank := ((Mode shr 3) and $1F) or ((Mode and 1) shl 5);
        var CpuLines := 3 - ((Mode and 4) shr 1);
        Result := ((Bank shl 1) and not CpuLines) or (OriginalSlot and CpuLines);
      end;
    MAPPER_BMC_WE7HGX:
      begin
        var Mode := FRegs[0];
        var Mask := $0F;
        var Outer := Mode shl 2;
        if FSubmapper = 1 then
          Outer := Mode shl 3
        else if (Mode and $0C) = $0C then
          Mask := 3;
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_480:
      begin
        var Mode := FRegs[0];
        var Wide := (Mode and $20) <> 0;
        case FSubmapper of
          1:
            Wide := (Mode and $1F) = $1F;
          2:
            begin
              if (Mode and $20) <> 0 then
                Result := ((Mode shl 2) or (FRegs[1] and 3)) * 4 + OriginalSlot;
              Wide := (Mode and $0E) = $0E;
            end;
        end;
        if (FSubmapper <> 2) or ((Mode and $20) = 0) then
        begin
          var Mask := $0F or (Ord(Wide) shl 4);
          Result := (Result and Mask) or ((Mode shl 4) and not Mask);
        end;
      end;
    MAPPER_BMC_K3101, MAPPER_BMC_ET170:
      begin
        var Mode := FRegs[0];
        var SizeBit := $20;
        if FBoard = MAPPER_BMC_ET170 then
          SizeBit := $10;
        var CpuLines := 1 + (Ord((Mode and SizeBit) <> 0) shl 1);
        Result := ((Mode shl 1) and not CpuLines) or (OriginalSlot and CpuLines);
      end;
    MAPPER_BMC_K3054:
      begin
        var Mode := FRegs[0];
        if (Mode and $0B) = 3 then
          Result := (PrgRegisterBank(OriginalSlot and 1) and not 1) or (OriginalSlot and 1);
        var Mask := $1F shr Ord((Mode and 2) <> 0);
        Result := (Result and Mask) or ((Mode shl 4) and not Mask);
      end;
    MAPPER_BMC_5426757A:
      if (FRegs[0] and 1) <> 0 then
        Result := (Result and $1F) or (FRegs[0] and $60)
      else
        Result := (FRegs[0] and not 3) or OriginalSlot;
    MAPPER_BMC_GA009:
      begin
        var Mode := FRegs[0];
        var Mask := $0F or (Ord(Mode = 3) shl 4);
        var Outer := ((Mode and 1) shl 5) or ((Mode and 2) shl 3);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_A018:
      begin
        var Mask := $1F shr Ord((FRegs[0] and $20) <> 0);
        Result := (Result and Mask) or (FRegs[0] and not Mask);
      end;
    MAPPER_BMC_CG008:
      begin
        var Mode := FRegs[0];
        if (Mode and $80) <> 0 then
          Result := (Result and $1F) or ((Mode and $40) shr 1)
        else
        begin
          var Bank := (Mode and $0F) or ((Mode and $40) shr 2);
          var CpuLines := 1 + ((Mode and $20) shr 4);
          Result := ((Bank shl 1) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
      end;
    MAPPER_BMC_K3022:
      begin
        var Mode := FRegs[0];
        if (Mode and $20) <> 0 then
        begin
          var Mask := $0F or (Mode and $10);
          Result := (Result and Mask) or ((Mode shl 1) and not Mask);
        end
        else
        begin
          var CpuLines := 1 + (Ord((Mode and 6) <> 0) shl 1);
          Result := ((Mode shl 1) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
      end;
    MAPPER_BMC_NT639:
      begin
        var Mode := FRegs[0];
        if (Mode and $20) <> 0 then
          Result := ((((Mode shr 1) and $1E) or ((Mode shr 4) and 4)) shl 2) or OriginalSlot
        else
          Result := (Result and $0F) or ((Mode and $40) shr 2);
      end;
    MAPPER_BMC_JY830832C:
      Result := (Result and ($1F shr Ord((FRegs[0] and $20) <> 0))) or ((FRegs[0] and $40) shr 1);
    MAPPER_NC3000M:
      begin
        var Mode := FRegs[0];
        if (Mode and 4) <> 0 then
        begin
          var CpuLines := 3 - ((Mode and 8) shr 2);
          Result := (PrgRegisterBank(OriginalSlot and 1) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
        Result := (Result and $0F) or (Mode and $10) or ((Mode and 2) shl 4);
      end;
    MAPPER_BMC_EL861121C:
      Result := (Result and $1F) or ((FRegs[0] and $20) shl 2) or ((FRegs[0] and 6) shl 4);
    MAPPER_BMC_EL860947C:
      Result := (Result and $0F) or ((FRegs[0] and $20) shl 1) or ((FRegs[0] and 6) shl 3);
    MAPPER_YY840708C:
      case FRegs[0] of
        0:
          if FRegs[2] <> 0 then
            Result := FRegs[2] or (Result and 7)
          else
            Result := FRegs[1] or (Result and 3);
        $30:
          Result := $30 or (PrgRegisterBank(OriginalSlot xor 2) and $0F);
      else
        Result := FRegs[0] or (Result and $0F);
      end;
    MAPPER_YY841155C:
      begin
        var Outer: Integer;
        var Mode := FRegs[0];
        if FSubmapper = 1 then
        begin
          Outer := (Mode and 7) or ((FRegs[1] and 1) shl 3) or ((Mode shr 2) and $10);
          Mode := Mode xor $80;
        end
        else
          Outer := (Mode and 7) or ((Mode shr 3) and 8) or ((FRegs[1] and 1) shl 4);
        if (Mode and $80) = 0 then
          Result := ((Outer shl 1) and not $0F) or (Result and $0F)
        else if (Mode and $20) <> 0 then
          Result := ((Outer shl 1) and not 3) or OriginalSlot
        else
          Result := (Outer shl 1) or (OriginalSlot and 1);
      end;
    MAPPER_F600:
      begin
        var Mask := $1F shr Ord((FRegs[0] and $20) <> 0);
        Result := (Result and Mask) or (((FRegs[0] and $38) shl 1) and not Mask);
      end;
    MAPPER_REALTEC_8210:
      begin
        var Mask := $1F shr Ord((FRegs[1] and 8) <> 0);
        var Outer := ((FRegs[0] and $30) shl 1) or ((FRegs[0] and 8) shl 4) or ((FRegs[1] and 1) shl 4);
        Result := (Result and Mask) or Outer;
      end;
    MAPPER_JY302, MAPPER_JY208:
      Result := (Result and (not FRegs[3] and $3F)) or FRegs[1] or ((FRegs[2] and $C0) shl 2);
    MAPPER_A88S1:
      begin
        var Outer := ((FRegs[1] and $40) shr 1) or ((FRegs[1] and 8) shl 1);
        if (FRegs[0] and $40) <> 0 then
        begin
          var Bank := (Outer shr 1) or (FRegs[0] and 5) or ((FRegs[0] shr 2) and 2);
          var Mask := 1 or (FRegs[0] and 2);
          Result := ((Bank shl 1) and not Mask) or (OriginalSlot and Mask);
        end
        else
        begin
          var WideBit := 2;
          if FSubmapper = 2 then
            WideBit := 1;
          var Mask := $0F or (Ord((FRegs[1] and WideBit) <> 0) shl 4);
          Result := (Result and Mask) or (Outer and not Mask);
        end;
      end;
    MAPPER_REALTEC_K6C3001A:
      Result := (Result and $0F) or (FRegs[0] shl 4);
    MAPPER_BMC_810305C:
      begin
        var Outer := FRegs[0] shl 5;
        var Mask := $1F;
        if FRegs[0] = 2 then
        begin
          Outer := Outer or ((FBankRegisters[0] shr 3) and $10);
          Mask := $F;
        end
        else if (FRegs[0] = 3) and ((FBankRegisters[0] and $80) = 0) and (OriginalSlot >= 2) then
        begin
          Outer := $70;
          Mask := $F;
          Result := FBankRegisters[OriginalSlot + 4];
        end;
        Result := Outer or (Result and Mask);
      end;
    MAPPER_COOLX_LITE:
      begin
        var Mask := ((FRegs[5] shl 1) and $3E) or 1;
        var Outer := ((FRegs[1] shl 1) and $3E) or (FRegs[2] shl 6);
        if ((FRegs[3] and $C) = 4) or ((FRegs[4] and $80) <> 0) then
          Result := (((Outer shr 2) or (FBankRegisters[6] and (Mask shr 2))) shl 2) or OriginalSlot
        else if (FRegs[3] and 8) <> 0 then
        begin
          var Inner := Integer(FBankRegisters[6]);
          if OriginalSlot >= 2 then
            Inner := $FF;
          Result := (((Outer shr 1) or (Inner and (Mask shr 1))) shl 1) or (OriginalSlot and 1);
        end
        else
          Result := Outer or (Result and Mask);
      end;
    MAPPER_BMC_ST80:
      if ((FRegs[0] and 8) <> 0) and ((Result and $10) = 0) then
        Result := $40 or (Result and $0F)
      else
        Result := ((FRegs[0] and 3) shl 4) or (Result and $0F);
    MAPPER_BMC_831031C, MAPPER_BMC_FC2940:
      begin
        if (FRegs[0] and 8) <> 0 then
        begin
          var BankMask := 3;
          if (FBoard = MAPPER_BMC_FC2940) and ((FRegs[0] and $10) = 0) then
            BankMask := 1;
          Result := (PrgRegisterBank(OriginalSlot and 1) and not BankMask) or (OriginalSlot and BankMask);
        end;
        Result := ((FRegs[0] and 3) shl 4) or (Result and $0F);
      end;
    MAPPER_BMC_10_24_C_A1:
      begin
        var Mask := $0F or ((FRegs[0] and 8) shl 1);
        Result := (((FRegs[0] and 7) shl 4) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_840415C:
      begin
        if (FRegs[0] and 4) <> 0 then
        begin
          var BankMask := 3;
          if (FSubmapper = 3) and ((FRegs[0] and $20) = 0) then
            BankMask := 1;
          var SourceSlot := OriginalSlot and 1;
          if FSubmapper = 2 then
            SourceSlot := 0;
          Result := (PrgRegisterBank(SourceSlot) and not BankMask) or (OriginalSlot and BankMask);
        end;
        var Mask := $1F shr Ord((FRegs[0] and 8) <> 0);
        Result := (((FRegs[0] and 3) shl 4) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_810431C:
      begin
        var Mask := $0F or ((FRegs[0] and 8) shl 1);
        Result := (((FRegs[0] and 7) shl 4) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_GN23:
      begin
        var Bank := FRegs[0] and $0F;
        if ((FSubmapper = 0) and ((FRegs[0] and $10) <> 0)) or
          ((FSubmapper = 1) and ((FRegs[0] and 8) <> 0)) then
          Bank := (Bank and $0E) or (OriginalSlot shr 1);
        Result := (Bank shl 1) or (OriginalSlot and 1);
      end;
    MAPPER_BMC_47_2:
      if (FRegs[0] and $20) = 0 then
        Result := ((FRegs[0] and $1F) shl 1) or (OriginalSlot and 1)
      else
      begin
        var Mask := 3;
        if (FRegs[0] and $40) <> 0 then
          Mask := $0F;
        Result := (((FRegs[0] and $3F) shl 1) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_5IN1_1993:
      Result := ((FRegs[0] and $FE) shl 1) or OriginalSlot;
    MAPPER_BMC_GN26:
      begin
        var Outer := FRegs[0] and 3;
        if FGn26LegacyPrgOrder then
          Outer := Gn26LegacyBank[Outer];
        if (FRegs[0] and 4) <> 0 then
          Result := (FBankRegisters[6] and $0C) or OriginalSlot;
        Result := (Outer shl 4) or (Result and $0F);
      end;
    MAPPER_BMC_L6IN1:
      begin
        if (FRegs[0] and $0C) = 0 then
          Result := ((FRegs[0] and 3) shl 2) or OriginalSlot;
        Result := ((FRegs[0] and $C0) shr 2) or (Result and $0F);
      end;
    MAPPER_BMC_K3097:
      begin
        var Mask := $1F shr Ord((FRegs[0] and 2) <> 0);
        if (FSubmapper = 1) and ((FRegs[0] and 3) = 3) then
          Result := (Result and not $0C) or ((FRegs[0] shr 2) and $0C);
        Result := ((FRegs[0] shl 4) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_SFC12, MAPPER_BMC_SFC13:
      begin
        if (FBoard = MAPPER_BMC_SFC13) and ((FRegs[2] and $20) <> 0) then
          Result := (PrgRegisterBank(OriginalSlot and 1) and not 3) or OriginalSlot;
        var Mask := $3F xor (FRegs[3] and $3F);
        Result := (Result and Mask) or FRegs[1] or ((FRegs[2] and $C0) shl 2);
      end;
    MAPPER_GAMES_XPLOSION:
      Result := (Result and ($3F xor (FRegs[3] and $3F))) or FRegs[1] or ((FRegs[3] and $40) shl 2);
    MAPPER_BMC_VIP19:
      begin
        var Mask := $1F xor (FRegs[3] and $1F);
        Result := (Result and Mask) or (FRegs[1] and $1F) or ((FRegs[1] and $40) shr 1) or
          ((FRegs[1] and $20) shl 1) or (FRegs[2] and $80);
      end;
    MAPPER_BMC830134_C, MAPPER_BMC830118_C:
      begin
        var Outer := FRegs[0] shr 2;
        if FBoard = MAPPER_BMC830134_C then
          Outer := FRegs[0] shr 1;
        Outer := Outer and 3;
        if Outer = 3 then
          // The MMC3 sees A14 low. PRG ROM receives A14 from the CPU.
          Result := (PrgRegisterBank(OriginalSlot and 1) and $0D) or (OriginalSlot and 2);
        Result := (Outer shl 4) or (Result and $0F);
      end;
    MAPPER_BMC820310:
      if (FRegs[0] and 8) <> 0 then
        Result := ((((FRegs[0] shr 4) and 3) or (FRegs[0] and 4)) shl 2) or OriginalSlot
      else
        Result := ((FRegs[0] and $FC) shl 2) or (Result and $0F);
    MAPPER_BMC_K3033:
      begin
        var Outer := K3033OuterBank;
        if (FRegs[0] and $20) <> 0 then
        begin
          var Shift := 4 + Ord(K3033WideBank);
          Result := (Outer shl Shift) or (Result and ((1 shl Shift) - 1));
        end
        else
        begin
          var Inner := FRegs[0] and 7;
          if (Inner and 3) <> 0 then
            Inner := (Inner and 6) or (OriginalSlot shr 1);
          Result := (Outer shl 4) or (Inner shl 1) or (OriginalSlot and 1);
        end;
      end;
    MAPPER_BMC_K3006:
      if (FRegs[0] and $20) <> 0 then
        Result := ((FRegs[0] and $18) shl 1) or (Result and $0F)
      else if K3006UsesNrom256 then
        Result := ((FRegs[0] and $1E) shl 1) or OriginalSlot
      else
        Result := ((FRegs[0] and $1F) shl 1) or (OriginalSlot and 1);
    MAPPER_BMC_BS110:
      begin
        if (FRegs[0] and $20) <> 0 then
        begin
          var SlotMask := 1 or ((FRegs[0] and 4) shr 1);
          Result := (PrgRegisterBank(OriginalSlot and 1) and not SlotMask) or (OriginalSlot and SlotMask);
        end;
        var BankMask := $1F shr Ord((FRegs[0] and 8) <> 0);
        Result := (((FRegs[0] and 3) shl 4) and not BankMask) or (Result and BankMask);
      end;
    MAPPER_00202650:
      begin
        var Outer := FRegs[0] and 7;
        if (FRegs[0] and $10) = 0 then
        begin
          // A separate menu ROM follows the PRG game chips in the image.
          Result := ($80 + $10 * Ord(FSubmapper = 1)) + OriginalSlot;
        end
        else if (FSubmapper = 1) and (Outer = 6) then
          Result := $60 or (Result and $1F)
        else if (FSubmapper = 1) and (Outer = 7) then
          Result := $80 or (Result and $0F)
        else
          Result := (Outer shl 4) or (Result and $0F);
      end;
    MAPPER_820720C:
      begin
        case FRegs[0] and $30 of
          $20:
            Result := (PrgRegisterBank(0) and $0C) or OriginalSlot;
          $30:
            if OriginalSlot < 2 then
              Result := ((FRegs[1] and 7) shl 1) or OriginalSlot
            else
              Result := $0E or (OriginalSlot and 1);
        end;
        Result := ((FRegs[0] and 7) shl 4) or (Result and $0F);
      end;
    MAPPER_DRAGON_FIGHTER:
      if OriginalSlot = 0 then
        Result := FRegs[0] and 31;
    MAPPER_TAITO_TC0690:
      case OriginalSlot of
        0, 1:
          Result := FRegs[OriginalSlot];
        2:
          Result := $FFFE;
        3:
          Result := $FFFF
      end;
    MAPPER_MULTIMAPPER_116:
      case FRegs[0] and 3 of
        0:
          case OriginalSlot of
            0, 1:
              Result := FRegs[1 + OriginalSlot];
            2:
              Result := $FFFE;
            3:
              Result := $FFFF
          end;
        1:
          if Slot >= 2 then
            Result := $FE + Slot - 2;
        2, 3:
          begin
            var Bank := FRegs[19] and 15;
            if (FRegs[16] and 8) = 0 then
              Result := ((Bank and $FE) shl 1) + OriginalSlot
            else if (FRegs[16] and 4) <> 0 then
              if OriginalSlot < 2 then
                Result := (Bank shl 1) + OriginalSlot
              else
                Result := 30 + (OriginalSlot and 1)
            else if OriginalSlot < 2 then
              Result := OriginalSlot
            else
              Result := (Bank shl 1) + (OriginalSlot and 1);
          end;
      end;
    MAPPER_FK23C:
      begin
        var Mode := FRegs[0] and 7;
        if Mode = 3 then
          Result := (FRegs[4] shl 1) + (OriginalSlot and 1)
        else if Mode = 4 then
          Result := ((FRegs[4] and $FFE) shl 1) + OriginalSlot
        else if Mode <= 2 then
          if (FRegs[3] and 2) <> 0 then
          begin
            if Slot >= 2 then
              Result := FRegs[6 + Slot];
            Result := Result or (FRegs[4] shl 1)
          end
          else
          begin
            var Mask := $3F shr Mode;
            Result := (Result and Mask) or ((FRegs[4] shl 1) and not Mask)
          end;
      end;
    MAPPER_MMC3_COOLBOY:
      begin
        var Mask := (($3F or (FRegs[1] and $40) or ((FRegs[1] and $20) shl 2)) xor ((FRegs[0] and $40) shr 2)) xor ((FRegs[1] and $80) shr 2);
        var Outer := (FRegs[0] and 7) or ((FRegs[1] and $10) shr 1) or ((FRegs[1] and 12) shl 2) or ((FRegs[0] and $30) shl 2);
        if ((FRegs[3] and $40) <> 0) and (Result >= $FE) and ((FBankSelect and $40) <> 0) and (OriginalSlot in [1, 3]) then
          Result := 0;
        if (FRegs[3] and $10) = 0 then
          Result := ((Outer shl 4) and not Mask) or (Result and Mask)
        else
        begin
          Mask := Mask and $F0;
          var Extra := FRegs[3] and 14;
          if (FRegs[1] and 2) <> 0 then
            Extra := (FRegs[3] and 12) or ((OriginalSlot and 2));
          Result := ((Outer shl 4) and not Mask) or (Result and Mask) or Extra or (OriginalSlot and 1);
        end;
      end;
    MAPPER_MMC3_14:
      if (FRegs[0] and 2) = 0 then
        case OriginalSlot of
          0, 1:
            Result := FRegs[9 + OriginalSlot];
          2:
            Result := $FFFE;
          3:
            Result := $FFFF
        end;
    MAPPER_MMC3_121:
      begin
        if ((FRegs[5] and $3F) <> 0) and (OriginalSlot > 0) then
          Result := FRegs[3 - OriginalSlot];
        Result := (Result and 31) or ((FRegs[3] and $80) shr 2);
      end;
    MAPPER_MMC3_126, MAPPER_TEC9719, MAPPER_ING022:
      Result := TecPrgBank(OriginalSlot, Result);
    MAPPER_YY841101C:
      Result := (Result and $0F) or (FRegs[0] and $F0);
    MAPPER_FK206:
      begin
        if (FRegs[2] and 2) <> 0 then
        begin
          var Bank16 := FRegs[2] shr 3;
          if (FRegs[2] and 4) <> 0 then
            Bank16 := (Bank16 and not 1) or (OriginalSlot shr 1);
          Result := Bank16 * 2 + (OriginalSlot and 1);
        end
        else
        begin
          var Mask := $3F;
          if (FRegs[1] and 2) <> 0 then
            Mask := Mask and not $20;
          if (FRegs[1] and $10) <> 0 then
            Mask := Mask and not $10;
          var Outer := ((FRegs[1] and $40) shr 2) or ((FRegs[1] and 4) shl 3);
          Result := (Result and Mask) or (Outer and not Mask);
        end;
      end;
    MAPPER_REALTEC_MMC3:
      begin
        var Mode := FRegs[1];
        if (Mode and $40) <> 0 then
        begin
          var CpuLines := 1;
          if ((FSubmapper = 2) and ((Mode and $20) <> 0)) or
            ((FSubmapper <> 2) and ((Mode and $80) <> 0) and (FSubmapper <> 3)) then
            CpuLines := 3;
          Result := (PrgRegisterBank(OriginalSlot and 1) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
        var Mask := $1F;
        if (Mode and 2) <> 0 then
          Mask := $0F;
        var Outer := ((Mode and 1) shl 4) or ((Mode and $10) shl 1);
        if (FSubmapper = 0) or (FSubmapper = 4) then
          Outer := Outer or ((Mode and $20) shl 1);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_NC7000M:
      begin
        var Mode := FRegs[0];
        if (Mode and 4) <> 0 then
        begin
          var CpuLines := 3;
          if (Mode and 8) <> 0 then
            CpuLines := 1;
          Result := (PrgRegisterBank(OriginalSlot and 1) and not CpuLines) or (OriginalSlot and CpuLines);
        end;
        var Mask := $0F;
        if ((FSubmapper and 4) <> 0) and ((Mode and 2) <> 0) then
          Mask := $1F;
        Result := (Result and Mask) or (((Mode and 3) shl 4) and not Mask);
      end;
    MAPPER_NES_EVENT2:
      Result := (Result and (((FRegs[0] and 3) shl 3) or 7)) or ((FRegs[0] and 4) shl 3);
    MAPPER_MMC3_198:
      Result := FRegs[OriginalSlot];
    MAPPER_MMC3_199:
      if OriginalSlot >= 2 then
        Result := FRegs[OriginalSlot - 2];
    MAPPER_MMC3_208:
      Result := FRegs[5] * 4 + OriginalSlot;
    MAPPER_MMC3_215:
      begin
        var Mask := 31;
        var Extra := 0;
        if (FRegs[0] and $40) <> 0 then
        begin
          Mask := 15;
          Extra := FRegs[1] and $10
        end;
        if (FRegs[0] and $80) <> 0 then
        begin
          Result := ((FRegs[1] and 3) shl 4) or (FRegs[0] and (Mask shr 1)) or (Extra shr 1);
          Result := (Result shl 1) + (OriginalSlot and 1) + Ord((FRegs[0] and $20) <> 0) * (OriginalSlot shr 1) * 2;
        end
        else
          Result := ((FRegs[1] and 3) shl 5) or (Result and Mask) or Extra;
      end;
    MAPPER_MMC3_219:
      Result := FRegs[8 + OriginalSlot];
    MAPPER_MMC3_45:
      Result := (Result and ($3F xor (FRegs[3] and $3F))) or FRegs[1];
    MAPPER_MMC3_114:
      if (FRegs[0] and $80) <> 0 then
        Result := ((FRegs[0] and 15) shl 1) + (OriginalSlot and 1);
    MAPPER_MMC3_187:
      if (FRegs[0] and $80) = 0 then
        Result := Result and $3F
      else if (FRegs[0] and $20) = 0 then
        Result := ((FRegs[0] and 31) shl 1) + (OriginalSlot and 1)
      else if (FRegs[0] and $40) <> 0 then
        Result := (FRegs[0] and $1C) + OriginalSlot
      else
        Result := ((FRegs[0] and $1E) shl 1) + OriginalSlot;
    MAPPER_MMC3_224:
      begin
        if (FBankSelect and $40) <> 0 then
          case OriginalSlot of
            0:
              Result := $3E;
            1:
              Result := FBankRegisters[6] and $3F;
            2:
              Result := FBankRegisters[7] and $3F
          end;
        Result := (Result and $3F) or (FRegs[0] shl 6);
      end;
    MAPPER_UNL158_B:
      if (FRegs[0] and $80) = 0 then
        Result := Result and 15
      else if (FRegs[0] and $20) <> 0 then
        Result := ((FRegs[0] and 6) shl 1) + OriginalSlot
      else
        Result := ((FRegs[0] and 7) shl 1) + (OriginalSlot and 1);
    MAPPER_MMC3_BMC_F15:
      begin
        var Mode := (FRegs[0] shr 3) and 1;
        Result := ((FRegs[0] and (15 xor Mode)) shl 1) + ((OriginalSlot shr 1) * Mode * 2) + (OriginalSlot and 1)
      end;
    MAPPER_BMC_HPXX:
      if (FRegs[0] and 4) <> 0 then
        if (FRegs[0] and 15) = 4 then
          Result := ((FRegs[1] and 31) shl 1) + (OriginalSlot and 1)
        else
          Result := ((FRegs[1] and $1E) shl 1) + OriginalSlot
      else if (FRegs[0] and 2) <> 0 then
        Result := (Result and 15) or ((FRegs[1] and $18) shl 1)
      else
        Result := (Result and 31) or ((FRegs[1] and $10) shl 1);
    MAPPER_MMC3_BMC411120_C:
      if (FRegs[0] and 8) <> 0 then
        Result := ((((FRegs[0] shr 4) and 3) or 12) shl 2) + OriginalSlot
      else
        Result := (Result and 15) or ((FRegs[0] and 3) shl 4);
    MAPPER_RESET_TXROM:
      Result := (Result and 15) or (FResetBank shl 4);
    MAPPER_MMC3_MALI_SB:
      Result := (Result and 3) or ((Result and 8) shr 1) or ((Result and 4) shl 1);
    MAPPER_BMC8IN1:
      if (FRegs[0] and $10) <> 0 then
        Result := (Result and 15) or ((FRegs[0] and 12) shl 2)
      else
        Result := ((FRegs[0] and 15) shl 2) + OriginalSlot;
    MAPPER_BMC_GN45:
      Result := (Result and 15) or FRegs[0];
    MAPPER_SACHEN_9602:
      if Slot < 2 then
        Result := (Result and $3F) or (FRegs[1] shl 6)
      else
        Result := Result and $3F;
    MAPPER_MMC3_37:
      case FRegs[0] of
        0..2:
          Result := Result and 7;
        3:
          Result := (Result and 7) or 8;
        4..6:
          Result := (Result and 15) or $10;
        7:
          Result := (Result and 7) or $20;
      end;
    MAPPER_MMC3_44:
      if FRegs[0] < 6 then
        Result := (Result and 15) or (FRegs[0] shl 4)
      else
        Result := (Result and 31) or (FRegs[0] shl 4);
    MAPPER_MMC3_47:
      Result := (Result and 15) or ((FRegs[0] and 1) shl 4);
    MAPPER_MMC3_49:
      if (FRegs[0] and 1) <> 0 then
        Result := (Result and 15) or ((FRegs[0] and $C0) shr 2)
      else
        Result := ((FRegs[0] shr 4) and 3) * 4 + OriginalSlot;
    MAPPER_MMC3_52:
      if (FRegs[0] and 8) <> 0 then
        Result := (Result and 15) or ((FRegs[0] and 7) shl 4)
      else
        Result := (Result and 31) or ((FRegs[0] and 6) shl 4);
    MAPPER_MMC3_115:
      if (FRegs[0] and $80) <> 0 then
        if (FRegs[0] and $20) <> 0 then
          Result := ((FRegs[0] and $E) shl 1) + OriginalSlot
        else
          Result := ((FRegs[0] and 15) shl 1) + (OriginalSlot and 1);
    MAPPER_MMC3_123:
      if (FRegs[0] and $40) <> 0 then
      begin
        var Bank := (FRegs[0] and 5) or ((FRegs[0] and 8) shr 2) or ((FRegs[0] and $20) shr 2);
        if (FRegs[0] and 2) <> 0 then
          Result := ((Bank and $FE) shl 1) + OriginalSlot
        else
          Result := (Bank shl 1) + (OriginalSlot and 1);
      end;
    MAPPER_MMC3_134:
      Result := (Result and 31) or ((FRegs[0] and 2) shl 4);
    MAPPER_MMC3_189:
      Result := ((FRegs[0] or (FRegs[0] shr 4)) and 7) * 4 + OriginalSlot;
    MAPPER_MMC3_196:
      if FRegs[0] <> 0 then
        Result := FRegs[1] * 4 + OriginalSlot;
    MAPPER_MMC3_205:
      if FRegs[0] < 2 then
        Result := (Result and 31) or (FRegs[0] shl 4)
      else
        Result := (Result and 15) or (FRegs[0] shl 4);
  end;
  // Standard MMC3 registers ignore PRG bits 6-7, but outer-bank boards apply
  // their own masks before the physical address is wrapped.
  case FBoard of
    MAPPER_MMC3_CHR_RAM_74, MAPPER_TXSROM, MAPPER_MMC3_182, MAPPER_MMC3_CHR_RAM_191, MAPPER_MMC3_CHR_RAM_192, MAPPER_MMC3_CHR_RAM_194, MAPPER_MMC3_CHR_RAM_195, MAPPER_MMC3_197, MAPPER_MMC3_238, MAPPER_MMC3_254, MAPPER_MMC3_STREET_HEROES, MAPPER_MMC3_KOF97:
      if Slot < 2 then
        Result := Result and $3F;
  end;
  if Result = $FFFE then
    Result := (Length(FPrgRom) div $2000) - 2;
  if Result = $FFFF then
    Result := (Length(FPrgRom) div $2000) - 1;
  Result := Result mod (Length(FPrgRom) div $2000);
end;

function TMapperExtendedMmc3.K3033OuterBank: Integer;
begin
  Result := ((FRegs[0] and $18) shr 3) or ((FRegs[0] and $40) shr 4);
end;

function TMapperExtendedMmc3.K3033WideBank: Boolean;
begin
  Result := (FRegs[0] and $A0) = $A0;
end;

function TMapperExtendedMmc3.K3006UsesNrom256: Boolean;
begin
  case FSubmapper of
    1:
      Result := (FRegs[0] and $04) <> 0;
    2:
      Result := (FRegs[0] and $11) <> 0;
    3:
      Result := (FRegs[0] and $18) <> 0;
    4:
      Result := (FRegs[0] and $14) <> 0;
  else
    Result := (FRegs[0] and 6) = 6;
  end;
end;

function TMapperExtendedMmc3.Mapper327NameOffset(Address: UInt16): Integer;
begin
  var Slot := (Address shr 10) and 7;
  if (FRegs[0] and 8) <> 0 then
    Slot := ChrRegisterBank(Slot xor ((FBankSelect and $80) shr 5)) shr 7
  else if FMirrorMode = TMirrorMode.Horizontal then
    Slot := Slot shr 1;
  Result := ((Slot and 1) shl 10) or (Address and $3FF);
end;

function TMapperExtendedMmc3.ChrBank(Address: UInt16): Integer;
const
  Chr2KRegisterSlots: array[0..3] of Integer = (0, 3, 4, 7);
  TopTenChrSlots: array[0..3] of Integer = (0, 1, 4, 7);
  Ns32ChrSlots: array[0..3] of Integer = (0, 1, 4, 5);
begin
  var Slot := Address shr 10;
  var Invert := (FBankSelect and $80) shr 5;
  case FBoard of
    MAPPER_DG574B:
      begin
        var Mask := $FF shr ((FRegs[2] shr 3) and 1);
        Exit((((FRegs[1] and $70) shl 3) and not Mask) or (ChrRegisterBank(Slot xor Invert) and Mask));
      end;
    MAPPER_BMC_830947:
      if (FRegs[0] and $20) <> 0 then
        Exit(((FRegs[0] shl 3) and $780) or (ChrRegisterBank(Slot xor Invert) and $7F))
      else
        Exit(((FRegs[0] shl 3) and $700) or ChrRegisterBank(Slot xor Invert));
    MAPPER_RETROAD_KJ01A:
      if (FRegs[0] and $80) = 0 then
        Exit(FRegs[3] * 8 + Slot)
      else
        Exit(ChrRegisterBank(Slot xor Invert));
    MAPPER_BMC_820215CA2:
      if FResetBank = 0 then
        Exit($200 or (ChrRegisterBank(Slot xor Invert) and $7F))
      else
        Exit(((FRegs[0] shl 7) and $180) or (ChrRegisterBank(Slot xor Invert) and $7F));
    MAPPER_ESTIQUE:
      Exit(ChrRegisterBank(Slot xor Invert));
    MAPPER_N49C300:
      case FRegs[0] of
        $00, $01, $13:
          Exit((FRegs[0] and 3) * 8 + Slot);
        $37:
          Exit($80 or (ChrRegisterBank(Slot xor Invert) and $7F));
        $FF:
          Exit($100 or (ChrRegisterBank(Slot xor Invert) and $7F));
      end;
    MAPPER_A971210:
      begin
        var Outer := FRegs[1];
        var Mask := $FF shr Ord((Outer and $80) <> 0);
        Exit(((Outer and $80) shl 1) or ((Outer and 4) shl 5) or
          (ChrRegisterBank(Slot xor Invert) and Mask));
      end;
    MAPPER_NTDEC_N625836:
      begin
        var Bank := ChrRegisterBank(Slot xor Invert);
        if (FRegs[0] and 1) <> 0 then
          Exit(Bank);
        var Mask := $FF shr Ord((FRegs[1] and 2) <> 0);
        Exit(((FRegs[1] shl 6) and not Mask) or (Bank and Mask));
      end;
    MAPPER_BMC_TOP_TEN:
      if FRegs[0] = $0F then
        Exit(((ChrRegisterBank(TopTenChrSlots[Slot shr 1] xor Invert) or $200) shl 1) or (Slot and 1));
    MAPPER_BMC_820315C:
      if (FRegs[0] and 4) <> 0 then
      begin
        var Mask := $7F or ((FRegs[0] and 2) shl 6);
        var Bank := ChrRegisterBank(Chr2KRegisterSlots[Slot shr 1] xor Invert);
        Bank := (Bank and Mask) or ((FRegs[0] shl 7) and not Mask);
        Exit((Bank shl 1) or (Slot and 1));
      end;
    MAPPER_BMC_NS32:
      if (FSubmapper <> 2) and ((FRegs[0] and $80) <> 0) then
        Exit(((ChrRegisterBank(Ns32ChrSlots[Slot shr 1] xor Invert) or $100) shl 1) or (Slot and 1));
  end;
  if (FBoard = MAPPER_BMC_CG008) or (FBoard = MAPPER_BMC_N42S2) then
    Exit(Slot);
  if (FBoard = MAPPER_BMC_480) and (FSubmapper = 2) and ((FRegs[0] and $10) <> 0) then
  begin
    var RegisterSlot := Chr2KRegisterSlots[Slot shr 1] xor ((FBankSelect and $80) shr 5);
    Exit($800 or (ChrRegisterBank(RegisterSlot) shl 1) or (Slot and 1));
  end;
  if FBoard = MAPPER_BMC_FC2940 then
  begin
    if (FRegs[0] and 4) = 0 then
      Exit(Slot);
    var RegisterSlot := Chr2KRegisterSlots[Slot shr 1] xor ((FBankSelect and $80) shr 5);
    Exit((ChrRegisterBank(RegisterSlot) shl 1) or (Slot and 1));
  end;
  if FBoard = MAPPER_BMC_47_2 then
  begin
    var PairIndex := Slot shr 1;
    var Bank := ChrRegisterBank((PairIndex and 1) or ((PairIndex and 2) shl 1));
    if (FRegs[0] and $40) <> 0 then
      Bank := Bank or $100
    else
      Bank := (Bank and $FC) or PairIndex;
    Exit((Bank shl 1) or (Slot and 1));
  end;
  if ((FBoard = MAPPER_00202650) and ((FRegs[0] and $10) = 0)) or
    ((FBoard = MAPPER_820720C) and ((FRegs[0] and 8) <> 0)) or
    ((FBoard = MAPPER_BMC_SFC12) and ((FRegs[2] and $20) <> 0)) then
    Exit(Slot);
  var RealtecChr2K := (FBoard = MAPPER_REALTEC_MMC3) and (FSubmapper = 3) and ((FRegs[1] and $20) <> 0);
  if RealtecChr2K then
    Slot := (Slot and 6) or ((Slot shr 1) and 1);
  if FBoard = MAPPER_TAITO_TC0690 then
  begin
    if Slot < 4 then
      Exit(FRegs[2 + (Slot shr 1)] * 2 + (Slot and 1))
    else
      Exit(FRegs[Slot])
  end;
  if FBoard = MAPPER_MULTIMAPPER_116 then
    case FRegs[0] and 3 of
      0:
        Exit(FRegs[8 + Slot] or ((FRegs[0] and 4) shl 6));
      2, 3:
        if (FRegs[16] and $10) <> 0 then
          Exit(FRegs[17 + (Slot shr 2)] * 4 + (Slot and 3))
        else
          Exit((FRegs[17] and $FE) * 4 + Slot);
    end;

  if (FBoard = MAPPER_MMC3_14) and ((FRegs[0] and 2) = 0) then
    Exit(FRegs[1 + Slot]);

  if FBoard = MAPPER_MMC3_165 then
  begin
    var R := FRegs[12 + (Address shr 12)];
    if Address < $1000 then
      R := R
    else
      R := 2 + R * 2;
    Result := FBankRegisters[R];
    if Result = 0 then
      Exit(-1);
    Exit((Result and $FC) + (Slot and 3));
  end;

  if FBoard = MAPPER_MMC3_219 then
    Exit(FRegs[12 + Slot]);

  if FBoard = MAPPER_MMC3_197 then
  begin
    if (FBankSelect and $80) = 0 then
      if Slot < 4 then
        Exit(Integer(FBankRegisters[0]) * 2 + Slot)
      else
        Exit(Integer(FBankRegisters[2 + ((Slot - 4) shr 1)]) * 2 + (Slot and 1))
    else if Slot < 4 then
      Exit(Integer(FBankRegisters[2]) * 2 + Slot)
    else
      Exit(Integer(FBankRegisters[0]) * 2 + (Slot and 1));
  end;

  if (FBankSelect and $80) <> 0 then
    Slot := Slot xor 4;
  Result := ChrRegisterBank(Slot);
  case FBoard of
    MAPPER_BMC_ET149:
      begin
        var Mode := FRegs[0];
        var Mask := $FF shr Ord((Mode and 2) <> 0);
        var Outer := ((Mode and 1) shl 7) or ((Mode and $70) shl 4);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_TOP_TEN:
      Result := (Result and $7F) or ((FRegs[0] and 7) shl 7);
    MAPPER_BMC_T227:
      if FSubmapper = 1 then
        Result := (Result and $7F) or ((FRegs[0] shl 3) and $180)
      else
      begin
        var Mask := $7F or ((FRegs[0] and $20) shl 2);
        Result := (Result and Mask) or ((FRegs[0] shl 4) and not Mask);
      end;
    MAPPER_BMC_820315C, MAPPER_BMC_910610:
      begin
        var Mode := FRegs[0];
        var Mask := $7F;
        if ((FBoard = MAPPER_BMC_820315C) and ((Mode and 2) <> 0)) or
          ((FBoard = MAPPER_BMC_910610) and ((Mode and 6) = 6)) then
          Mask := $FF;
        Result := (Result and Mask) or ((Mode shl 7) and not Mask);
      end;
    MAPPER_BMC_F648, MAPPER_BMC_FC49, MAPPER_BMC_K3044:
      Result := (Result and $7F) or (FRegs[0] shl 7);
    MAPPER_BMC_NT319:
      Result := (Result and $7F) or (FResetBank shl 7);
    MAPPER_BMC_GN27:
      case FRegs[0] and 3 of
        0:
          Result := Result and $7F;
        1:
          Result := (Result and $FF) or $100;
        2:
          Result := (Result and $7F) or $80;
      else
        Result := Result and $FF;
      end;
    MAPPER_BMC_NS32:
      case FSubmapper of
        0:
          Result := (Result and $FF) or ((FRegs[0] and 4) shl 6);
        1:
          Result := (Result and $FF) or ((FRegs[0] and 2) shl 7);
      else
        var Mode := FRegs[0];
        var Mask := $FF;
        if (FRegs[1] and 4) = 0 then
          Mask := $7F shr Ord((Mode and $80) <> 0);
        var Outer := ((Mode and 8) shl 5) or ((Mode and $40) shl 1) or ((Mode and $80) shr 1);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_4782:
      Result := (Result and $7F) or ((FRegs[0] and $40) shl 1);
    MAPPER_BMC_FC53A:
      begin
        var Mode := FRegs[0];
        var Mask := $7F or ((Mode and 1) shl 7);
        var Outer := ((Mode and 4) shl 6) or ((Mode and 2) shl 6);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_1N4148:
      begin
        var Mask := $FF shr Ord(FSubmapper = 1);
        Result := (Result and Mask) or ((FRegs[0] shl 7) and not Mask);
      end;
    MAPPER_COCOMA:
      Result := (Result and $7F) or ((FRegs[0] and $0C) shl 5);
    MAPPER_BMC_JY4M4:
      Result := (Result and $FF) or ((FRegs[0] and $40) shl 2);
    MAPPER_NTDEC_N625231:
      Result := (Result and $FF) or ((FRegs[0] and 2) shl 7);
    MAPPER_BMC_WE7HGX:
      begin
        var Mode := FRegs[0];
        var Mask := $7F;
        var Outer := Mode shl 5;
        if FSubmapper = 1 then
          Outer := Mode shl 6
        else if (Mode and $0C) = $0C then
          Mask := $1F;
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_480:
      begin
        var Mode := FRegs[0];
        var Wide := (Mode and $20) <> 0;
        case FSubmapper of
          1:
            Wide := (Mode and $1F) = $19;
          2:
            Wide := ((Mode and $0F) = 3) or ((Mode and $0F) = $0F);
        end;
        var Mask := $7F or (Ord(Wide) shl 7);
        Result := (Result and Mask) or ((Mode shl 7) and not Mask);
      end;
    MAPPER_BMC_K3101:
      Result := (Result and $FF) or ((FRegs[0] and $10) shl 4);
    MAPPER_BMC_ET170:
      Result := (Result and $7F) or ((FRegs[0] and $F8) shl 4);
    MAPPER_BMC_K3054:
      begin
        var Mask := $FF shr Ord((FRegs[0] and 2) <> 0);
        Result := (Result and Mask) or ((FRegs[0] shl 7) and not Mask);
      end;
    MAPPER_BMC_5426757A:
      begin
        var Mode := FRegs[0];
        var Mask := $FF shr Ord((Mode and $100) <> 0);
        Result := (Result and Mask) or ((Mode shr 1) and $100) or (Mode and $80);
      end;
    MAPPER_BMC_GA009:
      begin
        var Mode := FRegs[0];
        var Mask := $FF shr Ord(Mode <> 0);
        var Outer := ((Mode and 2) shl 7) or ((not Mode and 1) shl 7);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_A018, MAPPER_BMC_K3022:
      begin
        var Mode := FRegs[0];
        var Wide := (Mode and $20) = 0;
        var Outer := Mode shl 3;
        if FBoard = MAPPER_BMC_K3022 then
        begin
          Wide := (Mode and $10) <> 0;
          Outer := Mode shl 4;
        end;
        var Mask := $7F or (Ord(Wide) shl 7);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_BMC_NT639:
      Result := (Result and $FF) or ((FRegs[0] and $40) shl 2);
    MAPPER_BMC_JY830832C:
      Result := (Result and ($FF shr Ord((FRegs[0] and $20) <> 0))) or ((FRegs[0] and $10) shl 4);
    MAPPER_NC3000M:
      Result := (Result and $FF) or ((FRegs[0] and 1) shl 8);
    MAPPER_BMC_EL861121C, MAPPER_BMC_EL860947C:
      Result := (Result and $7F) or ((FRegs[0] and $20) shl 4) or ((FRegs[0] and 6) shl 6);
    MAPPER_F600:
      begin
        var Mask := $FF shr Ord((FRegs[0] and 4) = 0);
        Result := (Result and Mask) or (((FRegs[0] and 7) shl 7) and not Mask);
      end;
    MAPPER_REALTEC_8210:
      begin
        var Mask := $FF shr Ord((FRegs[1] and $40) <> 0);
        var Outer := ((FRegs[0] and $30) shl 4) or ((FRegs[1] and $20) shl 5) or ((FRegs[1] and $10) shl 3);
        Result := (Result and Mask) or Outer;
      end;
    MAPPER_YY840708C:
      Result := (FRegs[0] shl 3) or (Result and $7F);
    MAPPER_YY841155C:
      if FSubmapper = 1 then
        Result := ((FRegs[0] and $40) shl 2) or (Result and $FF)
      else
        Result := ((FRegs[0] and $40) shl 1) or ((FRegs[1] and 1) shl 8) or (Result and $7F);
    MAPPER_JY302, MAPPER_JY208:
      Result := (Result and ($FF shr (not FRegs[2] and $0F))) or FRegs[0] or ((FRegs[2] and $F0) shl 4);
    MAPPER_A88S1:
      begin
        var Mask := $7F or ((FRegs[1] and 2) shl 6);
        var Outer := (FRegs[1] and 4) shl 5;
        if FSubmapper = 1 then
          Outer := Outer or ((FRegs[1] and $40) shl 2)
        else
          Outer := Outer or ((FRegs[0] and $10) shl 4) or ((FRegs[1] and $80) shl 2);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_REALTEC_K6C3001A:
      Result := (Result and $7F) or (FRegs[0] shl 7);
    MAPPER_BMC_810305C:
      Result := (FRegs[0] shl 7) or (Result and $7F);
    MAPPER_COOLX_LITE:
      Result := Result and (((FRegs[4] shl 3) and $F8) or 7);
    MAPPER_BMC_ST80:
      Result := (FRegs[0] shl 7) or (((FRegs[0] xor 4) and 4) shl 4) or (Result and $7F);
    MAPPER_BMC_831031C:
      begin
        var Mask := $FF shr Ord((FRegs[0] and 4) <> 0);
        Result := (((FRegs[0] and 6) shl 6) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_10_24_C_A1:
      begin
        var Mask := $FF shr Ord((FRegs[0] and $28) <> $28);
        Result := (((FRegs[0] and 7) shl 7) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_840415C:
      begin
        var Mask := $FF shr Ord((FRegs[0] and $40) <> 0);
        Result := (((FRegs[0] and $30) shl 3) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_810431C:
      begin
        var Mask := $FF shr Ord((FRegs[0] and 8) = 0);
        Result := (((FRegs[0] and 7) shl 7) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_GN23:
      Result := ((FRegs[0] and 8) shl 4) or (Result and $7F);
    MAPPER_DRAGON_FIGHTER:
      if (Address shr 10) < 2 then
        Result := (((Result shr 1) xor FRegs[1]) shl 1) + ((Address shr 10) and 1)
      else if (Address shr 10) < 4 then
        Result := (((Result shr 1) or ((FRegs[2] and $40) shl 1)) shl 1) + ((Address shr 10) and 1)
      else
        Result := (FRegs[2] and $3F) * 4 + ((Address shr 10) - 4);
    MAPPER_MULTIMAPPER_116:
      Result := Result or ((FRegs[0] and 4) shl 6);
    MAPPER_FK23C:
      if (FRegs[0] and $40) <> 0 then
      begin
        var Mask := 0;
        if (FRegs[3] and $44) <> 0 then
          if (FRegs[0] and $10) <> 0 then
            Mask := 1
          else
            Mask := 3;
        Result := ((FRegs[2] or (FRegs[5] and Mask)) shl 3) + (Address shr 10);
      end
      else if (FRegs[3] and 2) <> 0 then
      begin
        case Slot of
          0:
            Result := FBankRegisters[0];
          1:
            Result := FRegs[10];
          2:
            Result := FBankRegisters[1];
          3:
            Result := FRegs[11]
        end;
        Result := Result or (FRegs[2] shl 3);
      end
      else
      begin
        var Mask := $FF;
        if (FRegs[0] and $10) <> 0 then
          Mask := $7F;
        Result := (Result and Mask) or ((FRegs[2] shl 3) and not Mask)
      end;
    MAPPER_MMC3_COOLBOY:
      begin
        var Mask := $FF xor (FRegs[0] and $80);
        if (FRegs[3] and $40) <> 0 then
          case Slot of
            0:
              Result := FBankRegisters[0];
            2:
              Result := FBankRegisters[1];
            1, 3:
              Result := 0
          end;
        if (FRegs[3] and $10) <> 0 then
          Result := (Result and $80 and Mask) or (((FRegs[0] and 8) shl 4) and not Mask) or ((FRegs[2] and 15) shl 3) or (Address shr 10)
        else
          Result := (Result and Mask) or (((FRegs[0] and 8) shl 4) and not Mask);
      end;
    MAPPER_MMC3_14:
      if Slot < 4 then
        Result := Result or ((FRegs[0] and 8) shl 5)
      else if Slot < 6 then
        Result := Result or ((FRegs[0] and $20) shl 3)
      else
        Result := Result or ((FRegs[0] and $80) shl 1);
    MAPPER_MMC3_121:
      if Length(FPrgRom) = Length(FChrMemory) then
        Result := Result or ((FRegs[3] and $80) shl 1)
      else if (Address shr 10) >= 4 then
        Result := Result or $100;
    MAPPER_MMC3_126, MAPPER_TEC9719, MAPPER_ING022:
      Result := TecChrBank(Address shr 10, Result);
    MAPPER_YY841101C:
      Result := (Result and $7F) or ((FRegs[0] and $F0) shl 3);
    MAPPER_FK206:
      if (FRegs[2] and 2) <> 0 then
        Result := ((FRegs[0] shr 2) shl 3) or (Address shr 10)
      else
      begin
        var Mask := $FF;
        if (FRegs[1] and $20) <> 0 then
          Mask := $7F;
        var Outer := (FRegs[1] and $80) or ((FRegs[1] and 8) shl 5);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_REALTEC_MMC3:
      begin
        var Mode := FRegs[1];
        var Mask := $FF;
        if (Mode and 4) <> 0 then
          Mask := $7F;
        var Outer := ((Mode and 1) shl 7) or ((Mode and 8) shl 5);
        if (FSubmapper = 0) or (FSubmapper = 4) then
          Outer := Outer or ((Mode and $20) shl 4);
        if RealtecChr2K then
        begin
          Mask := (Mask or $100) shr 1;
          Result := (((Result and Mask) or ((Outer shr 1) and not Mask)) shl 1) or ((Address shr 10) and 1);
        end
        else
          Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_NC7000M:
      begin
        var Mask := $7F;
        var Outer := (FRegs[0] and 1) shl 7;
        if (FSubmapper and 1) <> 0 then
          Mask := $FF;
        if (FSubmapper and 2) <> 0 then
          Outer := Outer or ((FRegs[0] and $10) shl 4)
        else
          Outer := Outer or ((FRegs[0] and 2) shl 7);
        Result := (Result and Mask) or (Outer and not Mask);
      end;
    MAPPER_NES_EVENT2:
      begin
        if (FRegs[0] and 6) <> 2 then
          Result := Result and $7F;
        Result := Result or ((FRegs[0] and 4) shl 5);
      end;
    MAPPER_MMC3_198:
      if FHasChrRam and (FBankRegisters[0] or FBankRegisters[1] or FBankRegisters[2] or FBankRegisters[3] or FBankRegisters[4] or FBankRegisters[5] = 0) then
        Result := Address shr 10;
    MAPPER_MMC3_199:
      case Address shr 10 of
        0:
          Result := FBankRegisters[0];
        1:
          Result := FRegs[2];
        2:
          Result := FBankRegisters[1];
        3:
          Result := FRegs[3]
      end;
    MAPPER_MMC3_215:
      if (FRegs[0] and $40) <> 0 then
        Result := ((FRegs[1] and 12) shl 6) or (Result and $7F) or ((FRegs[1] and $20) shl 2)
      else
        Result := ((FRegs[1] and 12) shl 6) or Result;
    MAPPER_MMC3_45:
      if not FHasChrRam then
        Result := (Result and ($FF shr (15 - (FRegs[2] and 15)))) or FRegs[0] or ((FRegs[2] and $F0) shl 4);
    MAPPER_MMC3_187:
      if (Address shr 10) >= 4 then
        Result := Result or $100;
    MAPPER_BMC_HPXX:
      if (FRegs[0] and 4) <> 0 then
      begin
        var Bank := FRegs[2] and $3F;
        case FRegs[0] and 3 of
          2:
            Bank := (Bank and $3E) or (FRegs[4] and 1);
          3:
            Bank := (Bank and $3C) or (FRegs[4] and 3);
        end;
        Result := (Bank shl 3) + (Address shr 10);
      end
      else if (FRegs[0] and 1) <> 0 then
        Result := (Result and $7F) or ((FRegs[2] and $30) shl 3)
      else
        Result := Result or ((FRegs[2] and $20) shl 3);
    MAPPER_MMC3_STREET_HEROES:
      begin
        var Bit := 0;
        case Address shr 11 of
          0:
            Bit := 3;
          1:
            Bit := 2;
          2:
            Bit := 0;
          3:
            Bit := 1
        end;
        Result := Result or (((FRegs[0] shr Bit) and 1) shl 8);
      end;
    MAPPER_MMC3_BMC411120_C:
      Result := Result or ((FRegs[0] and 3) shl 7);
    MAPPER_RESET_TXROM:
      Result := (Result and $7F) or (FResetBank shl 7);
    MAPPER_MMC3_MALI_SB:
      Result := (Result and $DD) or ((Result and $20) shr 4) or ((Result and 2) shl 4);
    MAPPER_BMC8IN1, MAPPER_BMC830118_C:
      Result := ((FRegs[0] and 12) shl 5) or (Result and $7F);
    MAPPER_BMC830134_C:
      Result := (Result and $FF) or ((FRegs[0] and 8) shl 3) or
        ((FRegs[0] and 2) shl 6) or ((FRegs[0] and 1) shl 8);
    MAPPER_BMC820310:
      Result := ((FRegs[0] and $FC) shl 5) or (Result and $7F);
    MAPPER_BMC_K3033:
      begin
        var Shift := 7 + Ord(K3033WideBank);
        Result := (K3033OuterBank shl Shift) or (Result and ((1 shl Shift) - 1));
      end;
    MAPPER_BMC_K3006:
      Result := ((FRegs[0] and $18) shl 4) or (Result and $7F);
    MAPPER_BMC_BS110:
      begin
        var Mask := $FF shr Ord((FRegs[0] and $40) <> 0);
        var Outer := (FRegs[0] and $100) or ((FRegs[0] and $10) shl 3);
        Result := (Outer and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_GN26:
      begin
        var Mask := $FF shr Ord((FRegs[0] and 2) <> 0);
        Result := (((FRegs[0] and 3) shl 7) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_K3097:
      begin
        var Mask := $FF shr Ord((FRegs[0] and 2) <> 0);
        Result := ((FRegs[0] shl 7) and not Mask) or (Result and Mask);
      end;
    MAPPER_BMC_SFC12, MAPPER_BMC_SFC13, MAPPER_BMC_VIP19:
      Result := (Result and ($FF shr (15 - (FRegs[2] and 15)))) or FRegs[0] or ((FRegs[2] and $F0) shl 4);
    MAPPER_GAMES_XPLOSION:
      Result := (Result and ($FF shr (15 - (FRegs[2] and 15)))) or FRegs[0] or
        ((FRegs[2] and $F0) shl 4) or ((FRegs[3] and $40) shl 6);
    MAPPER_BMC_GN45:
      Result := (Result and $7F) or (FRegs[0] shl 3);
    MAPPER_MMC3_37:
      if FRegs[0] >= 4 then
        Result := Result or $80;
    MAPPER_MMC3_44:
      if FRegs[0] < 6 then
        Result := (Result and $7F) or (FRegs[0] shl 7)
      else
        Result := Result or (FRegs[0] shl 7);
    MAPPER_MMC3_47:
      Result := (Result and $7F) or ((FRegs[0] and 1) shl 7);
    MAPPER_MMC3_49:
      Result := (Result and $7F) or ((FRegs[0] and $C0) shl 1);
    MAPPER_MMC3_52:
      if (FRegs[0] and $40) <> 0 then
        Result := (Result and $7F) or (((FRegs[0] and 4) or ((FRegs[0] shr 4) and 3)) shl 7)
      else
        Result := Result or (((FRegs[0] and 4) or ((FRegs[0] shr 4) and 2)) shl 7);
    MAPPER_MMC3_115:
      Result := Result or (FRegs[1] shl 8);
    MAPPER_MMC3_134:
      Result := Result or ((FRegs[0] and $20) shl 3);
    MAPPER_MMC3_205:
      begin
        if FRegs[0] >= 2 then
          Result := (Result and $7F) or $100;
        if (FRegs[0] and 1) <> 0 then
          Result := Result or $80;
      end;
    MAPPER_00202650:
      Result := ((FRegs[0] and 7) shl 7) or (Result and $7F);
    MAPPER_820720C:
      Result := ((FRegs[0] and 1) shl 8) or (Result and $FF);
  end;
end;

function TMapperExtendedMmc3.ChrRamOffset(Bank: Integer): Integer;
begin
  if (FBoard = MAPPER_SACHEN_TC032) and FHasBoardChrRam and ((FRegs[0] and 2) <> 0) then
    Exit((Bank and 3) shl 10);
  Result := -1;
  case FBoard of
    MAPPER_BMC_FC2940:
      if (FRegs[0] and 4) = 0 then
        Result := Bank * $400;
    MAPPER_BMC_10_24_C_A1:
      if FHasBoardChrRam and ((FRegs[0] and $10) <> 0) then
        Result := (Bank and 7) * $400;
    MAPPER_00202650:
      if (FRegs[0] and $10) = 0 then
        Result := Bank * $400;
    MAPPER_820720C:
      if (FRegs[0] and 8) <> 0 then
        Result := Bank * $400;
    MAPPER_BMC_SFC12:
      if (FRegs[2] and $20) <> 0 then
        Result := Bank * $400;
    MAPPER_NES_EVENT2:
      if ((FRegs[0] and 6) = 2) and ((Bank and $40) <> 0) then
        Result := (Bank and 7) * $400;
    MAPPER_MMC3_199:
      if Bank < 8 then
        Result := Bank * $400;
    MAPPER_MMC3_STREET_HEROES:
      if (FRegs[0] and $40) <> 0 then
        Result := (Bank and 7) * $400;
    MAPPER_MMC3_CHR_RAM_74:
      if (Bank >= 8) and (Bank <= 9) then
        Result := (Bank - 8) * $400;
    MAPPER_MMC3_CHR_RAM_191:
      if Bank >= $80 then
        Result := ((Bank - $80) and 1) * $400;
    MAPPER_MMC3_CHR_RAM_192:
      if (Bank >= 8) and (Bank <= 11) then
        Result := (Bank - 8) * $400;
    MAPPER_MMC3_CHR_RAM_194:
      if Bank < 2 then
        Result := Bank * $400;
    MAPPER_MMC3_CHR_RAM_195:
      if Bank < 4 then
        Result := Bank * $400;
  end;
end;

function TMapperExtendedMmc3.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
const
  Protect187: array[0..3] of Byte = ($83, $83, $42, 0);
  Protect258: array[0..7] of Byte = (0, 0, 0, 1, 2, 4, 15, 0);
begin
  if FBoard = MAPPER_MMC3_249 then
    Exit(inherited CpuRead(Address, Value));
  if (Address >= $6000) and (Address < $8000) then
    case FBoard of
      MAPPER_BMC_820215CA2:
        Exit(False);
      MAPPER_BMC_830947:
        begin
          Value := FMenuDip;
          Exit(True);
        end;
      MAPPER_RETROAD_KJ01A, MAPPER_DG574B, MAPPER_TXSROM:
        Exit(FHasBoardPrgRam and inherited CpuRead(Address, Value));
      MAPPER_ESTIQUE:
        begin
          if not FHasBoardPrgRam then
            Exit(False);
          Value := FPrgRam[Address and $1FFF];
          Exit(True);
        end;
      MAPPER_A971210, MAPPER_NTDEC_N625836:
        Exit(False);
      MAPPER_N49C300:
        case FRegs[0] of
          $13:
            begin
              var Offset := ($0E * $2000 + (Address and $1FFF)) mod Length(FPrgRom);
              Value := FPrgRom[Offset];
              Exit(True);
            end;
          $37, $FF:
            begin
              // AX5202P does not gate physical WRAM with $A001.
              Value := FPrgRam[Address and $1FFF];
              Exit(True);
            end;
        else
          Exit(False);
        end;
    end;
  if FBoard = MAPPER_YY840708C then
  begin
    if (Address >= $6000) and (Address < $8000) then
    begin
      if FRegs[0] <> $30 then
        Exit(False);
      var Bank := ($30 or (PrgRegisterBank(3) and $0B)) mod (Length(FPrgRom) div $2000);
      Value := FPrgRom[Bank * $2000 + (Address and $1FFF)];
      Exit(True);
    end;
    if (Address >= $8000) and (Address < $C000) and (FRegs[0] = 0) then
      FRegs[2] := PrgRegisterBank((Address - $8000) shr 13) and 8;
  end;
  if (Address >= $5000) and (Address < $6000) then
    case FBoard of
      MAPPER_F600:
        begin
          Value := FCpuOpenBus and $7F; // Default D7 solder pad is low.
          Exit(True);
        end;
      MAPPER_A88S1:
        begin
          Value := 0; // Default menu solder pads.
          Exit(True);
        end;
    end;
  if (FBoard = MAPPER_YY841155C) and (Address >= $6000) and (Address < $8000) and
    ((Address and 2) <> 0) then
  begin
    Value := 0; // Default menu solder pads.
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) then
    case FBoard of
      MAPPER_NTDEC_N625231, MAPPER_BMC_WE7HGX, MAPPER_BMC_480, MAPPER_BMC_K3101, MAPPER_BMC_ET170, MAPPER_BMC_K3054, MAPPER_BMC_GA009, MAPPER_BMC_1N4148, MAPPER_COCOMA, MAPPER_BMC_N42S2, MAPPER_BMC_JY4M4, MAPPER_BMC_ET149, MAPPER_BMC_TOP_TEN, MAPPER_BMC_T227, MAPPER_BMC_820315C, MAPPER_BMC_F648, MAPPER_BMC_910610, MAPPER_BMC_GN27, MAPPER_BMC_K3044, MAPPER_BMC_NS32, MAPPER_BMC_4782:
        Exit(False);
      MAPPER_BMC_5426757A, MAPPER_BMC_A018, MAPPER_BMC_CG008:
        begin
          Value := 0; // Default menu solder pads.
          Exit(True);
        end;
      MAPPER_BMC_K3022, MAPPER_BMC_FC53A, MAPPER_SACHEN_TC032, MAPPER_BMC_FC49:
        begin
          if not FHasBoardPrgRam then
            Exit(False);
          Value := FPrgRam[Address and $1FFF];
          Exit(True);
        end;
    end;
  if (Address >= $6000) and (Address < $8000) and
    ((FBoard = MAPPER_BMC_NT639) or (FBoard = MAPPER_BMC_JY830832C) or (FBoard = MAPPER_NC3000M)) then
    Exit(False);
  if (Address >= $6000) and (Address < $8000) and
    ((FBoard = MAPPER_BMC_EL861121C) or (FBoard = MAPPER_BMC_EL860947C)) then
    Exit(False);
  if (Address >= $6000) and (Address < $8000) and
    ((FBoard = MAPPER_BMC_810305C) or (FBoard = MAPPER_F600) or (FBoard = MAPPER_REALTEC_8210) or
    (FBoard = MAPPER_JY302) or (FBoard = MAPPER_JY208) or (FBoard = MAPPER_YY841155C) or
    (FBoard = MAPPER_A88S1) or (FBoard = MAPPER_REALTEC_K6C3001A)) then
  begin
    if not FHasBoardPrgRam then
      Exit(False);
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;
  if (FBoard = MAPPER_COOLX_LITE) and (Address >= $6000) and (Address < $8000) then
  begin
    if not FHasBoardPrgRam then
      Exit(False);
    var Offset := CoolXPrgRamOffset(Address);
    if Offset < $2000 then
      Value := FPrgRam[Offset]
    else
      Value := FExtraPrgRam[Offset - $2000];
    Exit(True);
  end;
  if (Address >= $5000) and (Address < $8000) and
    ((FBoard = MAPPER_FK206) or ((FBoard = MAPPER_YY841101C) and (Address >= $6000))) then
  begin
    Value := 0; // Default menu solder pads.
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) and
    ((FBoard = MAPPER_REALTEC_MMC3) or (FBoard = MAPPER_NC7000M) or (FBoard = MAPPER_820720C) or
    (((FBoard = MAPPER_00202650) or (FBoard = MAPPER_GAMES_XPLOSION)) and not FHasBoardPrgRam)) then
    Exit(False);
  if (Address >= $6000) and (Address < $8000) then
  begin
    if (FBoard = MAPPER_BMC_5IN1_1993) and ((Address and 3) = 2) and
      ((FPrgRamControl and $80) <> 0) then
    begin
      Value := FCpuOpenBus and $FE; // Default menu jumper drives D0 low.
      Exit(True);
    end;
    case FBoard of
      MAPPER_BMC830134_C, MAPPER_BMC830118_C, MAPPER_BMC820310, MAPPER_BMC_K3033, MAPPER_BMC_K3006, MAPPER_BMC_BS110, MAPPER_BMC_5IN1_1993, MAPPER_BMC_GN26, MAPPER_BMC_L6IN1, MAPPER_BMC_K3097, MAPPER_BMC_SFC12, MAPPER_BMC_SFC13, MAPPER_BMC_VIP19, MAPPER_BMC_831031C, MAPPER_BMC_GN23, MAPPER_BMC_FC2940, MAPPER_BMC_47_2:
        Exit(False);
      MAPPER_BMC_840415C, MAPPER_BMC_810431C, MAPPER_BMC_10_24_C_A1:
        if not FHasBoardPrgRam then
          Exit(False);
    end;
  end;
  if (FBoard = MAPPER_NES_EVENT2) and (Address >= $5000) and (Address < $6000) then
  begin
    if Address < $5800 then
      Value := FPrgExtra[Address and $7FF]
    else
      Value := $5C or (Ord(FRegs[2] = NES_EVENT2_TOURNAMENT_CYCLES) shl 7);
    Exit(True);
  end;

  if FIsTec9719 and (Address >= $6000) and (Address < $8000) then
  begin
    if FTecHasPrgRam then
      Value := FPrgRam[Address and $1FFF];
    Exit(FTecHasPrgRam);
  end;

  // Waixing 195 has a separate, always-enabled 4 KiB RAM at $5000.
  if (FBoard = MAPPER_MMC3_CHR_RAM_195) and (Address >= $5000) and (Address < $8000) then
  begin
    if Address < $6000 then
      Value := FPrgExtra[Address and $FFF]
    else
      Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;
  if (FBoard = MAPPER_DRAGON_FIGHTER) and (Address >= $6000) and (Address < $7000) then
  begin
    if (Address and 1) = 0 then
      if (FRegs[0] and $E0) = $C0 then
        FRegs[1] := FRegs[62]
      else
        FRegs[2] := FRegs[63];
    Value := 0;
    Exit(True);
  end;

  if (FBoard = MAPPER_FK23C) and (Address >= $4000) and (Address < $8000) then
  begin
    if (FRegs[6] and $20) <> 0 then
    begin
      var Bank := FRegs[6] and 3;
      if Address < $6000 then
        Bank := (Bank + 1) and 3;
      Value := FPrgExtra[Bank * $2000 + (Address and $1FFF)];
      Exit(True)
    end;
    if Address < $6000 then
      Exit(False);
    if (FRegs[6] and $80) = 0 then
      Exit(False);
    Value := FPrgExtra[Address and $1FFF];
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_198) and (Address >= $5000) and (Address < $8000) then
  begin
    Value := FPrgRam[Address and $FFF];
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_121) and (Address >= $5000) and (Address < $6000) then
  begin
    Value := FRegs[4];
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_208) and (Address >= $5800) and (Address < $6000) then
  begin
    Value := FRegs[Address and 3];
    Exit(True)
  end;

  if (Address >= $5000) and (Address < $6000) then
    case FBoard of
      MAPPER_MMC3_187:
        begin
          Value := Protect187[FRegs[1] and 3];
          Exit(True)
        end;
      MAPPER_UNL158_B:
        begin
          Value := FCpuOpenBus or Protect258[Address and 7];
          Exit(True)
        end;
      MAPPER_BMC_HPXX:
        begin
          Value := 0;
          Exit(True)
        end;
    end;

  if (FBoard = MAPPER_MMC3_STREET_HEROES) and (Address = $4100) then
  begin
    Value := FResetBank;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_115) and (Address >= $5000) and (Address < $6000) then
  begin
    Value := FRegs[2];
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_238) and (Address >= $4020) and (Address < $8000) then
  begin
    Value := FRegs[0];
    Exit(True)
  end;

  if Address >= $8000 then
  begin
    if (FBoard = MAPPER_BMC_K3101) and ((FRegs[0] and $80) <> 0) then
      Address := Address and $FFF0; // Default menu solder pads.
    if (FBoard = MAPPER_BMC_ET170) and ((FRegs[0] and $20) <> 0) then
      Address := Address and $FFFC;
    if (FBoard = MAPPER_BMC_1N4148) and ((FRegs[0] and 8) <> 0) then
      Address := Address and $FFFC;
    if (FBoard = MAPPER_REALTEC_MMC3) and (FSubmapper <> 4) and
      (((FSubmapper = 1) and ((FRegs[1] and $20) <> 0)) or
      ((FSubmapper <> 1) and ((FRegs[0] and 1) <> 0))) then
    begin
      Value := 0;
      Exit(True);
    end;
    if (FBoard = MAPPER_NC3000M) and ((FRegs[0] and $0C) = 8) then
    begin
      Value := 0; // Default menu solder pads.
      Exit(True);
    end;
    if (FBoard = MAPPER_NC7000M) and ((FRegs[0] and $0C) = 8) then
    begin
      // CA-004 uses both left menu straps for the 7000-in-1 menu.
      Value := 3 * Ord(FSubmapper = 3);
      Exit(True);
    end;
    if (FBoard = MAPPER_BMC_GN26) and ((FRegs[0] and 8) <> 0) then
    begin
      Value := 0; // Default menu solder pads.
      Exit(True);
    end;
    if (FBoard = MAPPER_BMC_K3006) and (FSubmapper >= 2) and ((FRegs[0] and $80) <> 0) then
      Address := Address and $FFFC; // Default menu-selection solder pads.
    if (FBoard = MAPPER_BMC_GN23) and (((FSubmapper = 0) and ((FRegs[0] and $20) <> 0)) or
      ((FSubmapper = 1) and ((FRegs[0] and $80) <> 0))) then
      Address := Address and $FFE0;
    if (FBoard = MAPPER_BMC_FC2940) and (((FSubmapper = 0) and ((FRegs[0] and $80) <> 0)) or
      ((FSubmapper = 1) and ((FRegs[0] and $20) <> 0))) then
      Address := Address and $FFFC;
    if ((FBoard = MAPPER_BMC_T227) and (FSubmapper = 0) and ((FRegs[0] and $40) <> 0)) or
      ((FBoard = MAPPER_BMC_GN27) and ((FRegs[0] and $20) <> 0)) then
      Address := (Address and $FFF0) or FMenuDip;
    if (FBoard = MAPPER_BMC_T227) and (FSubmapper = 1) and
      ((FRegs[0] and (FMenuDip shl 6)) <> 0) then
      Exit(False);
    if FIsTec9719 and ((FRegs[1] and 1) <> 0) then
      Address := Address and $FFFE; // SL0 menu strap defaults to zero.
    Value := FPrgRom[PrgBank((Address - $8000) shr 13) * $2000 + (Address and $1FFF)];
    Exit(True)
  end;

  Result := inherited CpuRead(Address, Value);
  if Result and (FBoard = MAPPER_MMC3_254) and (FRegs[0] = 0) then
    Value := Value xor FRegs[1];
end;

function TMapperExtendedMmc3.WriteTecRegister(Address: UInt16; Value: Byte): Boolean;
begin
  if Address < $8000 then
  begin
    if Address < $6000 then
      Exit(False);
    if FTecHasPrgRam then
      FPrgRam[Address and $1FFF] := Value;
    if (FPrgRamControl and $C0) = $80 then
    begin
      var Index := Address and 3;
      if Index = 2 then
      begin
        // CNROM bits B/C/D each have a lock. Bit 7 latches the lock bits.
        var Locked := (FRegs[2] shr 3) and $0E;
        if (FRegs[2] and $80) <> 0 then
          Locked := Locked or $F0;
        FRegs[2] := (FRegs[2] and Locked) or (Value and not Locked);
      end
      else if (FRegs[3] and $80) = 0 then
      begin
        if Index = 0 then
        begin
          if (FSubmapper = 5) and ((Value and $24) = $20) and ((FRegs[0] and 4) <> 0) then
            FRegs[4] := ((FRegs[4] shl 1) or ((FRegs[0] shr 1) and 1)) and $FF;
          if (FSubmapper in [6, 7]) and ((Value and 4) <> 0) and ((FRegs[0] and 4) = 0) then
            FRegs[4] := Value and $F9;
        end;
        FRegs[Index] := Value;
      end;
    end;
    Exit(True);
  end;

  if (FBoard = MAPPER_ING022) and ((Address and $E000) = $C000) then
    Exit(inherited CpuWrite(Address, Value xor $FF));
  if (FRegs[3] and 8) <> 0 then
  begin
    Address := Address or 1;
    if (FRegs[3] and 1) <> 0 then
      Address := $8001;
  end;
  if (Address and $E001) = $A000 then
    FRegs[5] := Value;
  Result := inherited CpuWrite(Address, Value);
end;

function TMapperExtendedMmc3.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
const
  Security: array[0..7] of Byte = (0, 3, 1, 5, 6, 7, 2, 4);
  Protection: array[0..3] of Byte = (0, 2, 2, 3);
  Reg215: array[0..4, 0..7] of Byte = ((0, 1, 2, 3, 4, 5, 6, 7), (0, 2, 6, 1, 7, 3, 4, 5), (0, 5, 4, 1, 7, 2, 6, 3), (0, 6, 3, 7, 5, 2, 4, 1), (0, 2, 5, 3, 6, 1, 7, 4));
  Addr215: array[0..4, 0..7] of Byte = ((0, 1, 2, 3, 4, 5, 6, 7), (3, 2, 0, 4, 1, 5, 6, 7), (0, 1, 2, 3, 4, 5, 6, 7), (5, 0, 1, 2, 3, 7, 6, 4), (3, 1, 0, 5, 2, 4, 6, 7));
begin
  if FBoard = MAPPER_MMC3_249 then
    Exit(inherited CpuWrite(Address, Value));
  case FBoard of
    MAPPER_BMC_830947, MAPPER_BMC_820215CA2:
      if (Address >= $6000) and (Address < $8000) then
      begin
        if (FBoard = MAPPER_BMC_820215CA2) and (FResetBank <> 0) then
          FRegs[0] := Address and $FF
        else
          FRegs[0] := Value;
        Exit(True);
      end;
    MAPPER_RETROAD_KJ01A:
      begin
        if (Address and $F800) = $4800 then
        begin
          case Address and 3 of
            0, 1:
              FRegs[Address and 3] := Value;
            2:
              FRegs[2] := Value and $0F;
            3:
              FRegs[3] := Value and $1F;
          end;
          Exit(True);
        end;
        if (Address >= $6000) and (Address < $8000) then
          Exit(FHasBoardPrgRam and inherited CpuWrite(Address, Value));
        if (Address >= $8000) and ((FRegs[0] and $40) <> 0) then
          Exit(True);
      end;
    MAPPER_DG574B:
      case Address of
        $5000..$5FFF:
          begin
            if (FRegs[3] and $20) = 0 then
              FRegs[Address and 3] := Value;
            Exit(True);
          end;
        $6000..$7FFF:
          Exit(FHasBoardPrgRam and inherited CpuWrite(Address, Value));
      end;
    MAPPER_ESTIQUE:
      if (Address and $F000) = $5000 then
      begin
        if (FRegs[0] and $80) = 0 then
          FRegs[0] := Value;
        Exit(True);
      end;
  end;
  if (FBoard = MAPPER_ESTIQUE) and (Address >= $6000) and (Address < $8000) then
  begin
    if FHasBoardPrgRam then
      FPrgRam[Address and $1FFF] := Value;
    Exit(FHasBoardPrgRam);
  end;
  case FBoard of
    MAPPER_N49C300:
      begin
        if ((Address and $F100) = $4100) then
        begin
          if Value in [$00, $01, $13, $37, $FF] then
            FRegs[0] := Value;
          Exit(True);
        end;
        if (Address >= $6000) and (Address < $8000) then
        begin
          if FRegs[0] in [$37, $FF] then
            FPrgRam[Address and $1FFF] := Value;
          Exit(True);
        end;
        if (FRegs[0] = $13) and (Address >= $8000) then
          case Address and $E000 of
            $8000:
              begin
                FRegs[2] := 0;
                FIrqPending := False;
              end;
            $A000:
              FRegs[2] := Value and 2;
            $E000:
              begin
                FRegs[1] := Value and 3;
                Exit(True);
              end;
          end;
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_A971210:
      begin
        if (Address >= $6000) and (Address < $8000) then
        begin
          FRegs[Address and 3] := Value;
          Exit(True);
        end;
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_NTDEC_N625836:
      begin
        if (Address and $E100) = $4100 then
        begin
          FRegs[0] := Value;
          FRegs[1] := Address and $FF;
          Exit(True);
        end;
        if (Address >= $6000) and (Address < $8000) then
          Exit(False);
        Exit(inherited CpuWrite(Address, Value));
      end;
  end;
  if (FBoard = MAPPER_BMC_4782) and ((Address and $E100) = $4100) then
  begin
    FRegs[0] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_BMC_910610) and (Address >= $8000) and ((Address and 2) <> 0) then
  begin
    FRegs[0] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_SACHEN_TC032) and ((Address and $F100) = $4100) then
  begin
    FRegs[0] := Value and 3;
    Exit(True);
  end;
  if (FBoard = MAPPER_COCOMA) and (Address >= $8000) and ((Address and $10) <> 0) then
    FRegs[0] := Address and $0F;
  if (FBoard = MAPPER_YY840708C) and ((Address and $8100) = $8100) then
  begin
    FRegs[0] := Address and $30;
    FRegs[1] := (Address shr 11) and 4;
  end;
  case FBoard of
    MAPPER_NTDEC_N625231:
      if (Address and $E100) = $4100 then
      begin
        FRegs[0] := Value;
        Exit(True);
      end;
    MAPPER_BMC_WE7HGX:
      if (FSubmapper = 0) and ((FRegs[1] and $80) = 0) and (Address >= $8000) then
      begin
        for var Index := 0 to 5 do
          FBankRegisters[Index] := (FBankRegisters[Index] and $E7) or ((Value and 3) shl 3);
        Exit(True);
      end;
    MAPPER_F600:
      if (Address >= $5000) and (Address < $6000) then
      begin
        FRegs[0] := Address and $FF;
        Exit(True);
      end;
    MAPPER_A88S1:
      if (Address >= $5000) and (Address < $6000) then
      begin
        if (FSubmapper = 2) or ((Address and $800) <> 0) then
          FRegs[Address and 1] := Value;
        Exit(True);
      end;
    MAPPER_REALTEC_K6C3001A:
      if (Address and $E100) = $4100 then
      begin
        FRegs[0] := Value;
        Exit(True);
      end;
  end;
  if (Address >= $6000) and (Address < $8000) then
    case FBoard of
      MAPPER_BMC_ET149, MAPPER_BMC_T227, MAPPER_BMC_K3044:
        begin
          FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_TOP_TEN, MAPPER_BMC_820315C, MAPPER_BMC_GN27, MAPPER_BMC_NS32:
        begin
          if (FPrgRamControl and $C0) = $80 then
          begin
            FRegs[0] := Address and $FF;
            if FBoard = MAPPER_BMC_TOP_TEN then
              FRegs[0] := FRegs[0] and $0F
            else if FBoard = MAPPER_BMC_NS32 then
            begin
              FRegs[0] := Value;
              FRegs[1] := Address and $FF;
            end;
          end;
          Exit(True);
        end;
      MAPPER_BMC_F648:
        begin
          if (FRegs[0] and 8) = 0 then
            FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_4782:
        begin
          FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_BMC_910610:
        Exit(False);
      MAPPER_BMC_FC49:
        begin
          if FHasBoardPrgRam then
            FPrgRam[Address and $1FFF] := Value;
          if (FRegs[0] and 8) = 0 then
            FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_BMC_FC53A, MAPPER_SACHEN_TC032:
        begin
          if FHasBoardPrgRam then
            FPrgRam[Address and $1FFF] := Value;
          if (FBoard = MAPPER_BMC_FC53A) and ((FRegs[0] and $80) = 0) then
            FRegs[0] := Value or $80;
          Exit(True);
        end;
      MAPPER_BMC_1N4148:
        begin
          FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_N42S2, MAPPER_BMC_JY4M4:
        begin
          FRegs[Address and 1] := Value;
          Exit(True);
        end;
      MAPPER_COCOMA:
        Exit(False);
      MAPPER_BMC_WE7HGX:
        begin
          if (FRegs[1] and $60) <> 0 then
          begin
            FRegs[0] := Address and $FF;
            FRegs[1] := Value;
          end;
          Exit(True);
        end;
      MAPPER_BMC_480:
        begin
          if (FSubmapper = 2) and ((FRegs[0] and $30) <> 0) then
          begin
            if (Address and $100) <> 0 then
              FRegs[1] := (Address shr 4) and 3
            else
              FRegs[1] := ((Value shl 1) and 2) or ((Value shr 4) and 1);
          end
          else
            FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_K3101, MAPPER_BMC_ET170, MAPPER_BMC_K3054:
        begin
          FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_5426757A:
        begin
          FRegs[0] := (Address and $FFF) xor $1C;
          Exit(True);
        end;
      MAPPER_BMC_GA009:
        begin
          FRegs[0] := Address and 3;
          Exit(True);
        end;
      MAPPER_BMC_A018, MAPPER_BMC_CG008:
        begin
          FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_BMC_K3022:
        begin
          if FHasBoardPrgRam then
            FPrgRam[Address and $1FFF] := Value;
          if (FRegs[0] and $20) = 0 then
            FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_NT639, MAPPER_BMC_JY830832C:
        begin
          FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_NC3000M:
        begin
          FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_YY840708C:
        Exit(True);
      MAPPER_BMC_EL861121C, MAPPER_BMC_EL860947C:
        begin
          if (Address < $7000) and ((FRegs[0] and $80) = 0) then
            FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_F600, MAPPER_REALTEC_8210, MAPPER_JY302, MAPPER_JY208, MAPPER_YY841155C, MAPPER_A88S1, MAPPER_REALTEC_K6C3001A:
        begin
          if FHasBoardPrgRam then
            FPrgRam[Address and $1FFF] := Value;
          if (FBoard = MAPPER_REALTEC_8210) and ((FRegs[1] and $80) = 0) then
            FRegs[(Address shr 4) and 1] := Value;
          if FBoard = MAPPER_YY841155C then
            FRegs[Address and 3] := Value;
          if ((FBoard = MAPPER_JY302) or (FBoard = MAPPER_JY208)) and ((FRegs[3] and $40) = 0) then
          begin
            FRegs[FRegs[4]] := Value;
            FRegs[4] := (FRegs[4] + 1) and 3;
          end;
          Exit(True);
        end;
    end;
  if FBoard = MAPPER_COOLX_LITE then
  begin
    case Address of
      $4FF0..$4FF5:
        begin
          if (FRegs[3] and 2) = 0 then
            FRegs[Address and 7] := Value;
          Exit(True);
        end;
      $6000..$7FFF:
        begin
          if FHasBoardPrgRam then
          begin
            var Offset := CoolXPrgRamOffset(Address);
            if Offset < $2000 then
              FPrgRam[Offset] := Value
            else
              FExtraPrgRam[Offset - $2000] := Value;
          end;
          Exit(True);
        end;
      $8000..$FFFF:
        begin
          if (FRegs[3] and $C) <> 0 then
          begin
            FBankRegisters[6] := Value;
            Exit(True);
          end;
          if (Address and $E001) = $A000 then
            FRegs[6] := Value;
        end;
    end;
  end;
  if FBoard = MAPPER_BMC_810305C then
  begin
    if (Address >= $6000) and (Address < $8000) then
    begin
      if FHasBoardPrgRam then
        FPrgRam[Address and $1FFF] := Value;
      Exit(True);
    end;
    if (Address and $8FFF) = $8080 then
    begin
      FRegs[0] := (Address shr 13) and 3;
      Exit(True);
    end;
  end;
  if (FBoard = MAPPER_BMC_ST80) and ((Address and $F120) = $F120) then
  begin
    FRegs[0] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_BMC_47_2) and (Address >= $8000) then
  begin
    if (Address and $1000) <> 0 then
    begin
      FRegs[0] := Value;
      Exit(True);
    end;
    if (Address and $E001) = $8000 then
      Value := Value and $3F;
  end;
  if (FBoard = MAPPER_GAMES_XPLOSION) and (Address >= $5000) and (Address < $8000) then
  begin
    if Address < $6000 then
    begin
      if (FRegs[3] and $80) = 0 then
      begin
        FRegs[FRegs[4]] := Value;
        FRegs[4] := (FRegs[4] + 1) and 3;
      end;
    end
    else if FHasBoardPrgRam then
      inherited CpuWrite(Address, Value);
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) then
    case FBoard of
      MAPPER_BMC830134_C, MAPPER_BMC830118_C, MAPPER_BMC820310, MAPPER_BMC_L6IN1:
        begin
          if (FPrgRamControl and $C0) = $80 then
            FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_BMC_K3033, MAPPER_BMC_K3097, MAPPER_BMC_831031C, MAPPER_BMC_GN23, MAPPER_BMC_FC2940:
        begin
          if (FPrgRamControl and $C0) = $80 then
            FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_840415C, MAPPER_BMC_810431C:
        begin
          if (FPrgRamControl and $C0) = $80 then
          begin
            if (FBoard = MAPPER_BMC_810431C) or ((FRegs[0] and $80) = 0) then
            begin
              if (FBoard = MAPPER_BMC_840415C) and (FSubmapper in [1, 3]) then
                FRegs[0] := (Value and $FB) or (Address and 4)
              else
                FRegs[0] := Value;
            end;
            if FHasBoardPrgRam then
              inherited CpuWrite(Address, Value);
          end;
          Exit(True);
        end;
      MAPPER_BMC_10_24_C_A1:
        begin
          if (FPrgRamControl and $C0) = $80 then
          begin
            if (FRegs[0] and 7) = 0 then
              FRegs[0] := Address and $FF;
            if FHasBoardPrgRam then
              inherited CpuWrite(Address, Value);
          end;
          Exit(True);
        end;
      MAPPER_BMC_47_2:
        Exit(True);
      MAPPER_BMC_5IN1_1993:
        begin
          if ((FPrgRamControl and $C0) = $80) and ((Address and 3) = 0) then
            FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_BMC_GN26:
        begin
          if (FPrgRamControl and $C0) = $80 then
            FRegs[0] := Address and $0F;
          Exit(True);
        end;
      MAPPER_BMC_SFC12, MAPPER_BMC_SFC13, MAPPER_BMC_VIP19:
        begin
          if ((FPrgRamControl and $C0) = $80) and ((FRegs[3] and $40) = 0) then
          begin
            FRegs[FRegs[4]] := Value;
            FRegs[4] := (FRegs[4] + 1) and 3;
          end;
          Exit(True);
        end;
      MAPPER_BMC_K3006:
        begin
          if ((FPrgRamControl and $C0) = $80) and ((FRegs[0] and $20) = 0) then
            FRegs[0] := Address and $FF;
          Exit(True);
        end;
      MAPPER_BMC_BS110:
        begin
          if ((FPrgRamControl and $C0) = $80) and ((FRegs[0] and $80) = 0) then
            FRegs[0] := (Address and $100) or Value;
          Exit(True);
        end;
    end;
  if (FBoard = MAPPER_00202650) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FRegs[0] and $10) = 0 then
      FRegs[0] := Value and $17;
    if FHasBoardPrgRam then
      inherited CpuWrite(Address, Value);
    Exit(True);
  end;
  if (FBoard = MAPPER_820720C) and (Address >= $6000) then
  begin
    if Address < $8000 then
    begin
      if (FPrgRamControl and $C0) = $80 then
        FRegs[0] := Address and $3F;
      Exit(True);
    end;
    FRegs[1] := Value;
    Exit(inherited CpuWrite(Address, Value));
  end;

  if FBoard = MAPPER_MMC3_CHR_RAM_195 then
  begin
    if (Address >= $5000) and (Address < $8000) then
    begin
      if Address < $6000 then
        FPrgExtra[Address and $FFF] := Value
      else
        FPrgRam[Address and $1FFF] := Value;
      Exit(True);
    end;
    // This board does not decode the MMC3 RAM protection register.
    if (Address >= $8000) and ((Address and $E001) = $A001) then
      Exit(True);
  end;
  if (FBoard = MAPPER_DRAGON_FIGHTER) and (Address >= $6000) and (Address < $8000) then
  begin
    if (Address and 1) = 0 then
      FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_TAITO_TC0690) and (Address >= $8000) then
  begin
    case Address and $E003 of
      $8000, $8001:
        FRegs[Address and 1] := Value and $3F;
      $8002, $8003:
        FRegs[Address and 3] := Value;
      $A000..$A003:
        FRegs[4 + (Address and 3)] := Value;
      $C000:
        begin
          FIrqPending := False;
          FIrqLatch := (Value xor $FF) + Ord(FSubmapper = 1)
        end;
      $C001:
        begin
          FIrqPending := False;
          FIrqCounter := 0;
          FIrqReloadPending := True
        end;
      $C002:
        FIrqEnabled := True;
      $C003:
        begin
          FIrqEnabled := False;
          FIrqPending := False
        end;
      $E000:
        begin
          FMirrorMode := TMirrorMode.Vertical;
          if (Value and $40) <> 0 then
            FMirrorMode := TMirrorMode.Horizontal
        end;
    end;
    Exit(True);
  end;

  if FBoard = MAPPER_MULTIMAPPER_116 then
  begin
    if (Address >= $4100) and (Address < $8000) then
    begin
      if (Address and $4100) = $4100 then
      begin
        FRegs[0] := Value;
        if (Address and 1) <> 0 then
        begin
          FRegs[16] := 12;
          FRegs[19] := 0;
          FRegs[20] := 0;
          FRegs[21] := 0
        end
      end;
    end
    else if Address >= $8000 then
      case FRegs[0] and 3 of
        0:
          begin
            if (Address >= $B000) and (Address <= $E003) then
            begin
              var R := 8 + (((((Address and 2) or (Address shr 10)) shr 1) + 2) and 7);
              var Shift := (Address and 1) * 4;
              FRegs[R] := (FRegs[R] and ($F0 shr Shift)) or ((Value and 15) shl Shift)
            end
            else
              case Address and $F000 of
                $8000:
                  FRegs[1] := Value;
                $A000:
                  FRegs[2] := Value;
                $9000:
                  FRegs[3] := Value
              end;
            FMirrorMode := TMirrorMode.Vertical;
            if (FRegs[3] and 1) <> 0 then
              FMirrorMode := TMirrorMode.Horizontal;
          end;
        1:
          begin
            inherited CpuWrite(Address, Value);
            Exit(True)
          end;
        2, 3:
          begin
            if (Value and $80) <> 0 then
            begin
              FRegs[16] := FRegs[16] or 12;
              FRegs[20] := 0;
              FRegs[21] := 0
            end
            else
            begin
              FRegs[20] := FRegs[20] or ((Value and 1) shl FRegs[21]);
              Inc(FRegs[21]);
              if FRegs[21] = 5 then
              begin
                FRegs[16 + ((Address shr 13) - 4)] := FRegs[20];
                FRegs[20] := 0;
                FRegs[21] := 0
              end;
            end;
            case FRegs[16] and 3 of
              0:
                FMirrorMode := TMirrorMode.Single0;
              1:
                FMirrorMode := TMirrorMode.Single1;
              2:
                FMirrorMode := TMirrorMode.Vertical;
              3:
                FMirrorMode := TMirrorMode.Horizontal
            end;
          end;
      end;
    Exit(True);
  end;

  if FBoard = MAPPER_FK23C then
  begin
    if Address < $8000 then
    begin
      // In RAM configuration mode bit 6 enables outer registers, not
      // write protection: the selected $6000 RAM bank remains writable.
      if (Address >= $6000) and ((FRegs[6] and $20) <> 0) then
      begin
        FPrgExtra[(FRegs[6] and 3) * $2000 + (Address and $1FFF)] := Value;
        Exit(True);
      end;
      if ((FRegs[6] and $40) <> 0) or ((FRegs[6] and $20) = 0) then
      begin
        if (Address < $6000) and ((Address and $5010) = $5010) then
        begin
          FRegs[Address and 3] := Value;
          case Address and 3 of
            0:
              FRegs[4] := (FRegs[4] and not $180) or ((Value and $80) shl 1) or ((Value and 8) shl 4);
            1:
              FRegs[4] := (FRegs[4] and not $7F) or (Value and $7F);
            2:
              begin
                FRegs[4] := (FRegs[4] and not $200) or ((Value and $40) shl 3);
                FRegs[5] := 0
              end;
          end;
        end
        else if Address >= $6000 then
        begin
          if (FRegs[6] and $C0) = $80 then
            FPrgExtra[Address and $1FFF] := Value
        end;
      end
      else if Address >= $4000 then
      begin
        var Bank := FRegs[6] and 3;
        if Address < $6000 then
          Bank := (Bank + 1) and 3;
        FPrgExtra[Bank * $2000 + (Address and $1FFF)] := Value
      end;
      Exit(True);
    end;
    if (FRegs[3] and $44) <> 0 then
      if (Address < $A000) or (Address >= $C000) then
        FRegs[5] := Value and 3;
    case Address and $E001 of
      $8000:
        begin
          if ((FSubmapper = 2) or (Length(FPrgRom) = $1000000)) and
            ((Value and $40) <> 0) and ((Value and 7) >= 6) then
            Value := Value xor 1;
          FBankSelect := Value;
          Exit(True)
        end;
      $8001:
        begin
          var R := FBankSelect and 7;
          if (FRegs[3] and 2) <> 0 then
            R := FBankSelect and 15;
          if R < 8 then
            FBankRegisters[R] := Value
          else if R < 12 then
            FRegs[R] := Value;
          Exit(True);
        end;
      $A000:
        begin
          FRegs[7] := Value and 3;
          var R := Value and 1;
          if (FRegs[6] and 8) <> 0 then
            R := Value and 3;
          case R of
            0:
              FMirrorMode := TMirrorMode.Vertical;
            1:
              FMirrorMode := TMirrorMode.Horizontal;
            2:
              FMirrorMode := TMirrorMode.Single0;
            3:
              FMirrorMode := TMirrorMode.Single1
          end;
          Exit(True);
        end;
      $A001:
        begin
          if (Value and $20) = 0 then
            Value := Value and $C0;
          FRegs[6] := Value
        end;
    end;
  end;

  if (FBoard = MAPPER_MMC3_COOLBOY) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FPrgRamControl and $80) <> 0 then
      inherited CpuWrite(Address, Value);
    if (FRegs[3] and $90) <> $80 then
      FRegs[Address and 3] := Value;
    Exit(True);
  end;

  if FBoard = MAPPER_MMC3_14 then
  begin
    if Address = $A131 then
      FRegs[0] := Value;
    if (FRegs[0] and 2) = 0 then
    begin
      if (Address >= $B000) and (Address < $F000) then
      begin
        var R := 1 + ((Address shr 12) - 11) * 2 + ((Address shr 1) and 1);
        var Shift := (Address and 1) * 4;
        FRegs[R] := (FRegs[R] and ($FF xor (15 shl Shift))) or ((Value and 15) shl Shift);
      end
      else
        case Address and $F003 of
          $8000:
            FRegs[9] := Value;
          $9000:
            FRegs[11] := Value;
          $A000:
            FRegs[10] := Value
        end;
      FMirrorMode := TMirrorMode.Vertical;
      if (FRegs[11] and 1) <> 0 then
        FMirrorMode := TMirrorMode.Horizontal;
      Exit(True);
    end;
  end;

  if FBoard = MAPPER_MMC3_121 then
  begin
    if (Address >= $5000) and (Address < $6000) then
    begin
      case Value and 3 of
        0, 1:
          FRegs[4] := $83;
        2:
          FRegs[4] := $42;
        3:
          FRegs[4] := 0
      end;
      if (Address and $5180) = $5180 then
        FRegs[3] := Value;
      Exit(True);
    end;
    if (Address >= $8000) and (Address < $A000) then
      if (Address and 3) = 3 then
      begin
        FRegs[5] := Value;
        UpdateProtection121;
        Address := $8000
      end
      else if (Address and 1) <> 0 then
      begin
        FRegs[6] := 0;
        for var i := 0 to 5 do
          FRegs[6] := FRegs[6] or (((Value shr i) and 1) shl (5 - i));
        if FRegs[7] = 0 then
          UpdateProtection121;
        Address := $8001;
      end
      else
        Address := $8000;
  end;

  if FIsTec9719 then
    Exit(WriteTecRegister(Address, Value));

  if (Address >= $6000) and (Address < $8000) then
    case FBoard of
      MAPPER_YY841101C:
        begin
          FRegs[0] := Value;
          Exit(True);
        end;
      MAPPER_FK206, MAPPER_REALTEC_MMC3, MAPPER_NC7000M:
        begin
          if (FPrgRamControl and $C0) = $80 then
            case FBoard of
              MAPPER_FK206:
                if (FRegs[1] and 1) = 0 then
                  FRegs[Address and 3] := Value;
              MAPPER_REALTEC_MMC3:
                if ((FRegs[1] and $80) = 0) or
                  ((FSubmapper <> 3) and ((FSubmapper <> 2) or ((Address and 1) = 0))) then
                  FRegs[Address and 1] := Value;
              MAPPER_NC7000M:
                FRegs[0] := Address and $1F;
            end;
          Exit(True);
        end;
    end;

  if (FBoard = MAPPER_NES_EVENT2) and (Address >= $5000) and (Address < $6000) then
  begin
    if Address < $5800 then
      FPrgExtra[Address and $7FF] := Value
    else
      FRegs[(Address shr 10) and 1] := Value;
    Exit(True);
  end;

  if FBoard = MAPPER_MMC3_198 then
  begin
    if (Address >= $5000) and (Address < $8000) then
    begin
      FPrgRam[Address and $FFF] := Value;
      Exit(True)
    end;
    if (Address = $8001) and ((FBankSelect and 7) >= 6) then
      if Value >= $40 then
        FRegs[(FBankSelect and 7) - 6] := Value and $4F
      else
        FRegs[(FBankSelect and 7) - 6] := Value and $3F;
  end;

  if FBoard = MAPPER_MMC3_199 then
  begin
    if (Address = $8001) and ((FBankSelect and 8) <> 0) then
    begin
      FRegs[FBankSelect and 3] := Value;
      Exit(True)
    end;
    if (Address and $E001) = $A000 then
    begin
      case Value and 3 of
        0:
          FMirrorMode := TMirrorMode.Vertical;
        1:
          FMirrorMode := TMirrorMode.Horizontal;
        2:
          FMirrorMode := TMirrorMode.Single0;
        3:
          FMirrorMode := TMirrorMode.Single1
      end;
      Exit(True)
    end;
  end;

  if FBoard = MAPPER_MMC3_208 then
  begin
    if (Address >= $5000) and (Address < $6000) then
    begin
      if Address < $5800 then
        FRegs[4] := Value
      else
      begin
        var Key := FRegs[4];
        var Lut := 0;
        if (Key and $40) = 0 then
        begin
          Lut := $59;
          if (Key and 8) <> 0 then
            Lut := Lut xor ((Key and 1) shl 4) xor ((Key and 2) shl 5) xor ((Key and $10) shr 1) xor (Key shr 7);
        end
        else if (Key and 8) = 0 then
          Lut := ((Key and 1) shl 4) or ((Key and 2) shl 5) or ((Key and $10) shr 1) or (Key shr 7);
        FRegs[Address and 3] := Value xor Lut;
      end;
      Exit(True);
    end;
    if ((Address >= $4800) and (Address < $5000)) or ((Address >= $6800) and (Address < $7000)) then
    begin
      FRegs[5] := (Value and 1) or ((Value shr 3) and 2);
      Exit(True)
    end;
  end;

  if FBoard = MAPPER_MMC3_215 then
  begin
    if (Address >= $5000) and (Address < $8000) then
    begin
      case Address of
        $5000:
          FRegs[0] := Value;
        $5001:
          FRegs[1] := Value;
        $5007:
          FRegs[2] := Value and 7
      end;
      Exit(True)
    end;
    if Address >= $8000 then
    begin
      var R := FRegs[2];
      if R > 4 then
        R := 0;
      var Decoded := Addr215[R, ((Address shr 12) and 6) or (Address and 1)];
      Address := $8000 or ((Decoded and 6) shl 12) or (Decoded and 1);
      if Decoded = 0 then
        Value := (Value and $C0) or Reg215[R, Value and 7];
    end;
  end;

  if (FBoard = MAPPER_MMC3_219) and (Address >= $8000) and (Address < $A000) then
  begin
    case Address and 3 of
      0:
        begin
          FRegs[0] := 0;
          FRegs[1] := Value
        end;
      2:
        begin
          FRegs[0] := Value;
          FRegs[1] := 0
        end;
      1:
        begin
          if (FRegs[0] >= $23) and (FRegs[0] <= $26) then
            FRegs[8 + $26 - FRegs[0]] := ((Value and $20) shr 5) or ((Value and $10) shr 3) or ((Value and 8) shr 1) or ((Value and 4) shl 1);
          case FRegs[1] of
            8, 10, 14, 18, 22, 26, 30:
              FRegs[2] := (Value shl 4) and $FF;
            9, 11, 12, 13, 15, 16, 17, 20, 21, 24, 25, 28, 29:
              begin
                var Slot: Integer;
                var Bank := Value shr 1;
                case FRegs[1] of
                  9:
                    begin
                      Slot := 0;
                      Bank := Bank and 14
                    end;
                  11:
                    begin
                      Slot := 1;
                      Bank := Bank or 1
                    end;
                  12, 13:
                    begin
                      Slot := 2;
                      Bank := Bank and 14
                    end;
                  15:
                    begin
                      Slot := 3;
                      Bank := Bank or 1
                    end;
                  16, 17:
                    begin
                      Slot := 4;
                      Bank := Bank and 15
                    end;
                  20, 21:
                    begin
                      Slot := 5;
                      Bank := Bank and 15
                    end;
                  24, 25:
                    begin
                      Slot := 6;
                      Bank := Bank and 15
                    end;
                else
                  begin
                    Slot := 7;
                    Bank := Bank and 15
                  end
                end;
                FRegs[12 + Slot] := FRegs[2] or Bank;
              end;
          end;
        end;
    end;
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_45) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FRegs[3] and $40) <> 0 then
      Exit(inherited CpuWrite(Address, Value));
    FRegs[FRegs[4]] := Value;
    FRegs[4] := (FRegs[4] + 1) and 3;
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_114) and (Address >= $5000) then
  begin
    if Address < $8000 then
    begin
      FRegs[0] := Value;
      Exit(True)
    end;
    case Address and $E001 of
      $8001:
        Exit(inherited CpuWrite($A000, Value));
      $A000:
        begin
          FRegs[1] := 1;
          Exit(inherited CpuWrite($8000, (Value and $C0) or Security[Value and 7]))
        end;
      $A001:
        begin
          FIrqLatch := Value;
          Exit(True)
        end;
      $C000:
        begin
          if FRegs[1] <> 0 then
          begin
            FRegs[1] := 0;
            inherited CpuWrite($8001, Value)
          end;
          Exit(True)
        end;
      $C001:
        begin
          FIrqReloadPending := True;
          Exit(True)
        end;
      $E000, $E001:
        ;
    else
      Exit(True);
    end;
  end;

  if FBoard = MAPPER_MMC3_187 then
  begin
    if (Address >= $5000) and (Address < $7000) then
    begin
      if (Address = $5000) or (Address = $6000) then
        FRegs[0] := Value;
      Exit(True)
    end;
    if Address = $8000 then
      FRegs[1] := 1;
    if (Address = $8001) and (FRegs[1] <> 1) then
      Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_224) and (Address >= $5000) and (Address <= $5003) then
  begin
    if Address = $5000 then
      FRegs[0] := (Value shr 2) and 1;
    Exit(True)
  end;

  if (FBoard = MAPPER_UNL158_B) and (Address >= $5000) and (Address < $6000) then
  begin
    if (Address and 7) = 0 then
      FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_BMC_F15) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FPrgRamControl and $80) <> 0 then
      FRegs[0] := Value and 15;
    Exit(True)
  end;

  if FBoard = MAPPER_BMC_HPXX then
  begin
    if (Address >= $5000) and (Address < $6000) then
    begin
      if FRegs[5] = 0 then
      begin
        FRegs[Address and 3] := Value;
        FRegs[5] := Value and $80
      end;
      Exit(True)
    end;
    if (Address >= $8000) and ((FRegs[0] and 4) <> 0) then
    begin
      FRegs[4] := Value;
      FMirrorMode := TMirrorMode.Horizontal;
      if (Value and 4) <> 0 then
        FMirrorMode := TMirrorMode.Vertical;
      Exit(True)
    end;
  end;

  if (FBoard = MAPPER_MMC3_STREET_HEROES) and (Address = $4100) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_KOF97) and (Address >= $8000) then
  begin
    Value := (Value and $D8) or ((Value and $20) shr 4) or ((Value and 4) shl 3) or ((Value and 2) shr 1) or ((Value and 1) shl 2);
    case Address of
      $9000:
        Address := $8001;
      $D000:
        Address := $C001;
      $F000:
        Address := $E001
    end;
  end;

  if (FBoard = MAPPER_MMC3_BMC411120_C) and (Address >= $6000) and (Address < $8000) then
  begin
    FRegs[0] := Address and $FF;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_MALI_SB) and (Address >= $8000) then
  begin
    var Bit := (Address shr 3) and 1;
    if Address >= $C000 then
      Bit := Bit or ((Address shr 2) and 1);
    Address := (Address and $FFFE) or Bit
  end;

  if (FBoard = MAPPER_BMC8IN1) and (Address >= $8000) and ((Address and $1000) <> 0) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_BMC_GN45) and (Address >= $6000) and (Address < $8000) then
  begin
    if FRegs[1] <> 0 then
      Exit(inherited CpuWrite(Address, Value));
    if Address < $7000 then
    begin
      FRegs[0] := Address and $30;
      FRegs[1] := Address and $80
    end
    else
      FRegs[0] := Value and $30;
    Exit(True);
  end;

  if (FBoard = MAPPER_SACHEN_9602) and (Address >= $8000) then
  begin
    if (Address and $E001) = $8000 then
      FRegs[0] := Value;
    if ((Address and $E001) = $8001) and ((FRegs[0] and 7) < 6) then
    begin
      FRegs[1] := Value shr 6;
      Value := Value and 31
    end;
  end;
  if (Address >= $6000) and (Address < $8000) and (FBoard in [MAPPER_MMC3_37,
      MAPPER_MMC3_47,
      MAPPER_MMC3_49,
      MAPPER_MMC3_52,
      MAPPER_MMC3_205]) then
  begin
    if (FBoard = MAPPER_MMC3_205) or ((FPrgRamControl and $C0) = $80) then
    begin
      case FBoard of
        MAPPER_MMC3_37:
          FRegs[0] := Value and 7;
        MAPPER_MMC3_47:
          FRegs[0] := Value and 1;
        MAPPER_MMC3_49:
          FRegs[0] := Value;
        MAPPER_MMC3_52:
          if (FRegs[0] and $80) = 0 then
            FRegs[0] := Value
          else
            Exit(inherited CpuWrite(Address, Value));
        MAPPER_MMC3_205:
          FRegs[0] := Value and 3;
      end;
    end;
    Exit(True);
  end;

  if (FBoard = MAPPER_MMC3_44) and ((Address and $E001) = $A001) then
  begin
    FRegs[0] := Value and 7;
    if FRegs[0] = 7 then
      FRegs[0] := 6
  end;
  if (FBoard = MAPPER_MMC3_115) and (Address >= $4100) and (Address < $8000) then
  begin
    if Address = $5080 then
      FRegs[2] := Value
    else if (Address and 1) <> 0 then
      FRegs[1] := Value and 1
    else
      FRegs[0] := Value;
    Exit(True);
  end;

  if FBoard = MAPPER_MMC3_123 then
  begin
    if (Address >= $5001) and (Address < $8000) and ((Address and $800) <> 0) then
    begin
      FRegs[Address and 1] := Value;
      Exit(True)
    end;
    if (Address >= $8000) and (Address < $A000) and ((Address and 1) = 0) then
      Value := (Value and $C0) or Security[Value and 7];
  end;

  if (FBoard = MAPPER_MMC3_134) and (Address = $6001) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_MMC3_189) and (Address >= $4120) and (Address < $8000) then
  begin
    FRegs[0] := Value;
    Exit(True)
  end;

  if FBoard = MAPPER_MMC3_196 then
  begin
    if (Address >= $6000) and (Address < $7000) then
    begin
      FRegs[0] := 1;
      FRegs[1] := (Value and 15) or (Value shr 4);
      Exit(True)
    end;
    if Address >= $8000 then
    begin
      var Low := ((Address shr 2) or (Address shr 3)) and 1;
      if Address < $C000 then
        Low := Low or ((Address shr 1) and 1);
      Address := (Address and $FFFE) or Low;
    end;
  end;

  if FBoard = MAPPER_MMC3_182 then
  begin
    if Address < $8000 then
      Exit(inherited CpuWrite(Address, Value));
    case Address and $E001 of
      $8001:
        Address := $A000;
      $A000:
        begin
          Address := $8000;
          Value := (Value and $F8) or Security[Value and 7]
        end;
      $C000:
        Address := $8001;
      $C001:
        begin
          inherited CpuWrite($C000, Value);
          Address := $C001
        end;
      $E000, $E001:
        ;
    else
      Exit(True);
    end;
  end;

  if (FBoard = MAPPER_MMC3_238) and (Address >= $4020) and (Address < $8000) then
  begin
    FRegs[0] := Protection[Value and 3];
    Exit(True)
  end;

  if FBoard = MAPPER_MMC3_254 then
    case Address of
      $8000:
        FRegs[0] := $FF;
      $A001:
        FRegs[1] := Value
    end;

  if FBoard = MAPPER_TXSROM then
  begin
    if (Address >= $6000) and (Address < $8000) and not FHasBoardPrgRam then
      Exit(False);
    var RegisterAddress := Address and $E001;
    if RegisterAddress = $A000 then
      Exit(True);
    Result := inherited CpuWrite(Address, Value);
    if (RegisterAddress = $8000) or (RegisterAddress = $8001) then
      UpdateTxSromNameBanks;
    Exit;
  end;

  Result := inherited CpuWrite(Address, Value);
end;

procedure TMapperExtendedMmc3.UpdateTxSromNameBanks;
begin
  var Invert := (FBankSelect and $80) shr 5;
  for var Slot := 0 to 3 do
    FNameBanks[Slot] := ChrRegisterBank(Slot xor Invert) shr 7;
end;

function TMapperExtendedMmc3.UsesUnbankedChrRam: Boolean;
begin
  Result := FHasBoardChrRam and
    (((FBoard = MAPPER_BMC_K3044) and ((FRegs[0] and 4) <> 0)) or
    ((FBoard = MAPPER_BMC_810305C) and (FRegs[0] = 2) and ((FBankRegisters[0] and $80) <> 0)) or
    ((FBoard = MAPPER_JY302) and ((FRegs[2] and $40) <> 0)) or
    ((FBoard = MAPPER_JY208) and ((FRegs[2] and $20) = 0)) or
    ((FBoard = MAPPER_BMC_480) and (FSubmapper = 1) and ((FRegs[0] and $20) <> 0)));
end;

function TMapperExtendedMmc3.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FBoard = MAPPER_MMC3_249 then
    Exit(inherited PpuRead(Address, Value));
  if (FBoard = MAPPER_SACHEN_TC032) and FHasBoardChrRam and (FRegs[0] = 1) and
    (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FChrRam[$1000 or (Address and $FFF)];
    Exit(True);
  end;
  if (FBoard = MAPPER_JY208) and FHasBoardChrRam and ((FRegs[2] and $40) <> 0) and
    (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FChrRam[Address and $FFF];
    Exit(True);
  end;
  if (FBoard = MAPPER_BMC_10_24_C_A1) and (FSubmapper = 1) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[Mapper327NameOffset(Address)];
    Exit(True);
  end;
  if (FBoard = MAPPER_TXSROM) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[FNameBanks[(Address shr 10) and 3] * $400 + (Address and $3FF)];
    Exit(True)
  end;

  Result := Address < $2000;
  if not Result then
    Exit;

  if UsesUnbankedChrRam then
  begin
    Value := FChrRam[Address];
    Exit(True);
  end;
  var Bank := ChrBank(Address);
  if FChrFromPrg then
  begin
    // PRG and CHR share a ROM. The PPU receives its data lines in a different order.
    var Data := FPrgRom[(Bank * $400 + (Address and $3FF)) mod Length(FPrgRom)];
    Value := ((Data and $01) shl 6) or ((Data and $02) shl 3) or (Data and $84) or
      ((Data and $18) shr 3) or ((Data and $20) shr 2) or ((Data and $40) shr 1);
    Exit(True);
  end;
  if (FBoard = MAPPER_FK23C) and (((FRegs[0] and $20) <> 0) or (((FRegs[6] and $24) = $24) and (Bank <= 7))) then
  begin
    Value := FChrExtra[(Bank * $400 + (Address and $3FF)) mod Length(FChrExtra)];
    Exit(True)
  end;

  if Bank < 0 then
  begin
    Value := FChrRam[Address and $FFF];
    Exit(True)
  end;

  var Ram := ChrRamOffset(Bank);
  if (FBoard = MAPPER_MMC3_STREET_HEROES) and ((FRegs[0] and $40) <> 0) then
    Ram := (Address shr 10) * $400;
  if Ram >= 0 then
    Value := FChrRam[Ram + (Address and $3FF)]
  else
    Value := FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)];
end;

function TMapperExtendedMmc3.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FBoard = MAPPER_MMC3_249 then
    Exit(inherited PpuWrite(Address, Value));
  if (FBoard = MAPPER_SACHEN_TC032) and FHasBoardChrRam and (FRegs[0] = 1) and
    (Address >= $2000) and (Address < $3F00) then
  begin
    FChrRam[$1000 or (Address and $FFF)] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_JY208) and FHasBoardChrRam and ((FRegs[2] and $40) <> 0) and
    (Address >= $2000) and (Address < $3F00) then
  begin
    FChrRam[Address and $FFF] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_BMC_10_24_C_A1) and (FSubmapper = 1) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[Mapper327NameOffset(Address)] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_TXSROM) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[FNameBanks[(Address shr 10) and 3] * $400 + (Address and $3FF)] := Value;
    Exit(True)
  end;

  if Address >= $2000 then
    Exit(False);

  if UsesUnbankedChrRam then
  begin
    FChrRam[Address] := Value;
    Exit(True);
  end;
  if (FBoard = MAPPER_COOLX_LITE) and ((FRegs[3] and 1) <> 0) and FHasChrRam then
    Exit(True);
  var Bank := ChrBank(Address);
  if (FBoard = MAPPER_FK23C) and (((FRegs[0] and $20) <> 0) or (((FRegs[6] and $24) = $24) and (Bank <= 7))) then
  begin
    FChrExtra[(Bank * $400 + (Address and $3FF)) mod Length(FChrExtra)] := Value;
    Exit(True)
  end;

  if Bank < 0 then
  begin
    FChrRam[Address and $FFF] := Value;
    Exit(True)
  end;

  var Ram := ChrRamOffset(Bank);
  if (FBoard = MAPPER_MMC3_STREET_HEROES) and ((FRegs[0] and $40) <> 0) then
    Ram := (Address shr 10) * $400;
  if Ram >= 0 then
  begin
    FChrRam[Ram + (Address and $3FF)] := Value;
    Exit(True)
  end;

  Result := FHasChrRam;
  if Result then
    FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)] := Value;
end;

procedure TMapperExtendedMmc3.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if (FBoard = MAPPER_BMC_CG008) or ((FBoard = MAPPER_N49C300) and (FRegs[0] = $13)) then
    Exit;

  if (FBoard = MAPPER_MULTIMAPPER_116) and ((FRegs[0] and 3) <> 1) then
    Exit;

  if FBoard = MAPPER_MMC3_165 then
  begin
    FRegs[12] := FRegs[14];
    FRegs[13] := FRegs[15];
    case Address and $2FF8 of
      $FD0:
        FRegs[14 + (Address shr 12 and 1)] := 0;
      $FE8:
        FRegs[14 + (Address shr 12 and 1)] := 1
    end;
    Exit;
  end;

  var Pending := FIrqPending;
  var Active := (FIrqCounter <> 0) or FIrqReloadPending;
  inherited;
  if (FBoard = MAPPER_TAITO_TC0690) or (FBoard = MAPPER_FK23C) then
    if FIrqPending and not Pending then
    begin
      FIrqPending := False;
      if FBoard = MAPPER_FK23C then
        FRegs[60] := 2
      else if FSubmapper = 1 then
        FRegs[60] := 6
      else
        FRegs[60] := 22;
    end;
  if (FBoard = MAPPER_MMC3_114) and not Active then
    FIrqPending := Pending;
end;

procedure TMapperExtendedMmc3.ClockCpu;
begin
  if (FBoard = MAPPER_N49C300) and (FRegs[0] = $13) and (FRegs[2] <> 0) then
  begin
    FRegs[3] := (FRegs[3] + 1) and $0FFF;
    if FRegs[3] = 0 then
      FIrqPending := True;
  end;
  if FBoard = MAPPER_NES_EVENT2 then
    if (FRegs[0] and 8) = 0 then
      FRegs[2] := 0
    else if FRegs[2] < NES_EVENT2_TOURNAMENT_CYCLES then
      Inc(FRegs[2]);
  if FRegs[60] > 0 then
  begin
    Dec(FRegs[60]);
    if FRegs[60] = 0 then
      FIrqPending := True
  end;
end;

procedure TMapperExtendedMmc3.CpuRamWrite(Address: UInt16; Value: UInt8);
begin
  if FBoard = MAPPER_DRAGON_FIGHTER then
    case Address of
      $6A:
        FRegs[62] := Value;
      $FF:
        FRegs[63] := Value
    end;
end;

function TMapperExtendedMmc3.GetSaveMemory: NES.Types.TByteArray;
begin
  if FBoard = MAPPER_SACHEN_9602 then
    Result := Copy(FChrMemory)
  else if FBoard = MAPPER_FK23C then
  begin
    SetLength(Result, SizeOf(FPrgExtra));
    Move(FPrgExtra[0], Result[0], Length(Result))
  end
  else
    Result := inherited;
end;

procedure TMapperExtendedMmc3.SetSaveMemory(const Data: NES.Types.TByteArray);
begin
  if FBoard = MAPPER_SACHEN_9602 then
  begin
    if Length(Data) <> Length(FChrMemory) then
      raise ENesException.Create('Invalid Sachen CHR save size');

    Move(Data[0], FChrMemory[0], Length(Data))
  end
  else if FBoard = MAPPER_FK23C then
  begin
    if Length(Data) <> SizeOf(FPrgExtra) then
      raise ENesException.Create('Invalid FK23C save size');

    Move(Data[0], FPrgExtra[0], Length(Data))
  end
  else
    inherited;
end;

procedure TMapperExtendedMmc3.UpdateProtection121;
begin
  case FRegs[5] and $3F of
    $20, $29, $2B, $3C, $3F:
      begin
        FRegs[7] := 1;
        FRegs[0] := FRegs[6]
      end;
    $26:
      begin
        FRegs[7] := 0;
        FRegs[0] := FRegs[6]
      end;
    $2C:
      begin
        FRegs[7] := 1;
        if FRegs[6] <> 0 then
          FRegs[0] := FRegs[6]
      end;
    $28:
      begin
        FRegs[7] := 0;
        FRegs[1] := FRegs[6]
      end;
    $2A:
      begin
        FRegs[7] := 0;
        FRegs[2] := FRegs[6]
      end;
    $2F:
      ;
  else
    FRegs[5] := 0
  end;
end;

type
  TTechlineMmc1 = class(TMapperMmc1)
  public
    function PrgBank(Slot: Integer): Integer;
    function ChrBank(Slot: Integer): Integer;
  end;

  TJyMulticartVrc4 = class(TMapperVrc)
  private
    FWorkRamEnabled: Boolean;
  public
    function PrgBank(Slot: Integer): Integer;
    function ChrBank(Slot: Integer): Integer;
    procedure Reset; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ClearIrq;
    property WorkRamEnabled: Boolean read FWorkRamEnabled;
  end;

function TTechlineMmc1.PrgBank(Slot: Integer): Integer;
begin
  var Bank := FPrgBank and $0F;
  case (FControl shr 2) and 3 of
    0, 1:
      Result := ((Bank and $0E) shl 1) + Slot;
    2:
      Result := Bank * 2 * (Slot shr 1) + (Slot and 1);
  else
    if Slot < 2 then
      Result := Bank * 2 + Slot
    else
      Result := $1E or (Slot and 1);
  end;
end;

function TTechlineMmc1.ChrBank(Slot: Integer): Integer;
begin
  if (FControl and $10) = 0 then
    Result := ((FChrBank0 and $1E) shl 2) or Slot
  else if Slot < 4 then
    Result := (FChrBank0 shl 2) or Slot
  else
    Result := (FChrBank1 shl 2) or (Slot and 3);
end;

function TJyMulticartVrc4.PrgBank(Slot: Integer): Integer;
begin
  if Slot = FSwap then
    Exit(FPrg0);
  if Slot = 1 then
    Exit(FPrg1);
  Result := $FE or (Slot and 1);
end;

function TJyMulticartVrc4.ChrBank(Slot: Integer): Integer;
begin
  Result := FChrRegisters[Slot];
end;

procedure TJyMulticartVrc4.Reset;
begin
  inherited;
  FWorkRamEnabled := False;
  for var Slot := 0 to High(FChrRegisters) do
    FChrRegisters[Slot] := Slot;
end;

function TJyMulticartVrc4.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address and $F003) = $9002 then
    FWorkRamEnabled := (Value and 1) <> 0;
  Result := inherited CpuWrite(Address, Value);
end;

procedure TJyMulticartVrc4.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FWorkRamEnabled, SizeOf(FWorkRamEnabled));
end;

procedure TJyMulticartVrc4.ClearIrq;
begin
  FPending := False;
end;

constructor TMapperJyMultiAsic.Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FTechline := Board = MAPPER_TECHLINE_XB;
  FChrRamFitted := HasChrRam;
  // The inner controllers decode writes and clock IRQs. Physical memory is
  // mapped by this board, so the controllers need only a minimal PRG window.
  var InnerPrg: NES.Types.TByteArray;
  SetLength(InnerPrg, $4000);
  if FTechline then
    FMmc1 := TTechlineMmc1.Create(InnerPrg, nil, False, MirrorMode, True);
  FVrc4 := TJyMulticartVrc4.Create(MAPPER_VRC2B_VRC4E, InnerPrg, nil, False, MirrorMode);
  PowerOn;
end;

destructor TMapperJyMultiAsic.Destroy;
begin
  FVrc4.Free;
  FMmc1.Free;
  inherited;
end;

procedure TMapperJyMultiAsic.ConfigureMemory(WorkRam, ChrRam: Boolean);
begin
  FWorkRamFitted := WorkRam;
  FChrRamFitted := FHasChrRam or ChrRam;
end;

procedure TMapperJyMultiAsic.ResetOuter;
begin
  FillChar(FOuter, SizeOf(FOuter), 0);
  if not FTechline then
    FOuter[2] := $0F;
  FWriteIndex := 0;
  FNromMirrorSet := False;
end;

procedure TMapperJyMultiAsic.PowerOn;
begin
  inherited Reset;
  FIrqRequiresCounterTransition := True;
  ResetOuter;
  if FMmc1 <> nil then
    FMmc1.PowerOn;
  FVrc4.PowerOn;
end;

procedure TMapperJyMultiAsic.Reset;
begin
  // The 556's M2-gap detector resets the outer register sequencer.
  if FTechline or (FVrc4 = nil) then
  begin
    inherited;
    if FVrc4 <> nil then
      FVrc4.PowerOn;
    if FMmc1 <> nil then
      FMmc1.PowerOn;
  end;
  ResetOuter;
end;

procedure TMapperJyMultiAsic.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FOuter, SizeOf(FOuter));
  State.Field(FWriteIndex, SizeOf(FWriteIndex));
  State.Field(FNromMirrorSet, SizeOf(FNromMirrorSet));
  if FTechline then
  begin
    State.Field(FChrRam, SizeOf(FChrRam));
    FMmc1.SerializeState(State);
  end;
  FVrc4.SerializeState(State);
end;

function TMapperJyMultiAsic.ActiveAsic: TInnerAsic;
begin
  Result := TInnerAsic.Mmc3;
  if FTechline then
  begin
    case FOuter[0] and 3 of
      2:
        Result := TInnerAsic.Mmc1;
      3:
        Result := TInnerAsic.Vrc4;
    end;
  end
  else if (FOuter[2] and $80) <> 0 then
    Result := TInnerAsic.Vrc4;
end;

function TMapperJyMultiAsic.PrgBank(Slot: Integer): Integer;
begin
  var Base, Mask: Integer;
  if FTechline then
  begin
    Base := FOuter[1] shr 1;
    Mask := $1F shr Ord((FOuter[2] and 4) <> 0);
    if (FOuter[2] and $10) <> 0 then
    begin
      case FOuter[2] and $0C of
        0:
          Exit((Base and not 3) or Slot);
        4:
          Exit((Base and not 1) or (Slot and 1));
      else
        Exit(Base);
      end;
    end;
  end
  else
  begin
    Base := FOuter[1] or ((FOuter[2] and $C0) shl 2);
    Mask := not FOuter[3] and $3F;
  end;
  var Inner: Integer;
  case ActiveAsic of
    TInnerAsic.Mmc1:
      Inner := TTechlineMmc1(FMmc1).PrgBank(Slot);
    TInnerAsic.Vrc4:
      Inner := TJyMulticartVrc4(FVrc4).PrgBank(Slot);
  else
    Inner := PrgRegisterBank(Slot);
  end;
  Result := (Base and not Mask) or (Inner and Mask);
end;

function TMapperJyMultiAsic.ChrBank(Slot: Integer): Integer;
begin
  var Base, Mask: Integer;
  if FTechline then
  begin
    Base := FOuter[0] shl 1;
    if (FOuter[2] and $40) <> 0 then
      Exit((Base and not 7) or Slot);
    if (FOuter[2] and $20) <> 0 then
      Mask := $7F
    else if (FOuter[2] and $10) <> 0 then
      Mask := $1F
    else
      Mask := $FF;
  end
  else
  begin
    Base := FOuter[0] or ((FOuter[2] and $30) shl 4) or
      ((FOuter[1] and $80) shl 3) or ((FOuter[2] and $40) shl 5);
    Mask := $FF shr (not FOuter[2] and $0F);
  end;
  var Inner: Integer;
  case ActiveAsic of
    TInnerAsic.Mmc1:
      Inner := TTechlineMmc1(FMmc1).ChrBank(Slot);
    TInnerAsic.Vrc4:
      Inner := TJyMulticartVrc4(FVrc4).ChrBank(Slot);
  else
    Inner := ChrRegisterBank(Slot xor ((FBankSelect and $80) shr 5));
  end;
  Result := (Base and not Mask) or (Inner and Mask);
end;

function TMapperJyMultiAsic.SwitchChrRam: Boolean;
begin
  Result := FTechline and ((FOuter[2] and 1) <> 0);
end;

function TMapperJyMultiAsic.WorkRamSelected(Writing: Boolean): Boolean;
begin
  if not FWorkRamFitted then
    Exit(False);
  case ActiveAsic of
    TInnerAsic.Mmc1:
      Result := True; // MMC1A has no PRG register RAM-disable bit.
      TInnerAsic.Vrc4:
      Result := TJyMulticartVrc4(FVrc4).WorkRamEnabled;
  else
    Result := (FPrgRamControl and ($80 or (Ord(Writing) shl 6))) = $80;
  end;
end;

function TMapperJyMultiAsic.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FTechline and (Address >= $5000) and (Address < $6000) then
  begin
    Value := FCpuOpenBus and $F8;
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    Result := WorkRamSelected(False);
    if Result then
      Value := FPrgRam[Address and $1FFF];
    Exit;
  end;
  if Address < $8000 then
    Exit(False);
  var Offset := PrgBank((Address - $8000) shr 13) * $2000 + (Address and $1FFF);
  if SwitchChrRam and not FHasChrRam then
  begin
    Offset := Offset mod (Length(FPrgRom) + Length(FChrMemory));
    if Offset >= Length(FPrgRom) then
    begin
      Value := FChrMemory[Offset - Length(FPrgRom)];
      Exit(True);
    end;
  end;
  Value := FPrgRom[Offset mod Length(FPrgRom)];
  Result := True;
end;

function TMapperJyMultiAsic.VrcAddress(Address: UInt16): UInt16;
begin
  var LowBits: UInt16;
  if FTechline then
  begin
    LowBits := (Address shr 2) and 3;
    // Some Techline batches use CPU A1/A2 for the 256 KiB VRC4 games.
    if (FOuter[2] and 5) = 0 then
      LowBits := (Address shr 1) and 3;
  end
  else
    LowBits := Ord((Address and 5) <> 0) or (Ord((Address and $0A) <> 0) shl 1);
  if (Address and $0800) <> 0 then
    LowBits := ((LowBits and 1) shl 1) or (LowBits shr 1);
  Result := (Address and $F000) or LowBits;
end;

function TMapperJyMultiAsic.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FTechline and (Address = $4025) then
  begin
    if (Value and 8) = 0 then
      FMirrorMode := TMirrorMode.Vertical
    else
      FMirrorMode := TMirrorMode.Horizontal;
    FNromMirrorSet := (FOuter[2] and $10) <> 0;
    Exit(True);
  end;
  if (Address >= $5000) and (Address < $6000) then
  begin
    if FTechline then
    begin
      var RegisterIndex := Address and 3;
      FOuter[RegisterIndex] := Value;
      if RegisterIndex = 0 then
      begin
        FIrqPending := False;
        TJyMulticartVrc4(FVrc4).ClearIrq;
      end;
      if RegisterIndex = 2 then
        FNromMirrorSet := False;
    end
    else if (FOuter[3] and $80) = 0 then
    begin
      FOuter[FWriteIndex] := Value;
      FWriteIndex := (FWriteIndex + 1) and 3;
    end;
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    if WorkRamSelected(True) then
      FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;
  if Address < $8000 then
    Exit(False);
  case ActiveAsic of
    TInnerAsic.Mmc1:
      Result := FMmc1.CpuWrite(Address, Value);
    TInnerAsic.Vrc4:
      Result := FVrc4.CpuWrite(VrcAddress(Address), Value);
  else
    Result := inherited CpuWrite(Address, Value);
  end;
end;

function TMapperJyMultiAsic.CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean;
begin
  if (Address >= $8000) and (ActiveAsic = TInnerAsic.Mmc1) then
    Exit(FMmc1.CpuWriteTimed(Address, Value, CpuCycle));
  Result := CpuWrite(Address, Value);
end;

function TMapperJyMultiAsic.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);
  if SwitchChrRam and FChrRamFitted then
    Value := FChrRam[Address]
  else
    Value := FChrMemory[(ChrBank(Address shr 10) * $400 + (Address and $3FF)) mod Length(FChrMemory)];
  Result := True;
end;

function TMapperJyMultiAsic.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);
  if SwitchChrRam and FChrRamFitted then
  begin
    FChrRam[Address] := Value;
    Exit(True);
  end;
  Result := FHasChrRam;
  if Result then
    FChrMemory[(ChrBank(Address shr 10) * $400 + (Address and $3FF)) mod Length(FChrMemory)] := Value;
end;

function TMapperJyMultiAsic.GetMirrorMode: TMirrorMode;
begin
  if FNromMirrorSet then
    Exit(FMirrorMode);
  case ActiveAsic of
    TInnerAsic.Mmc1:
      Result := FMmc1.GetMirrorMode;
    TInnerAsic.Vrc4:
      Result := FVrc4.GetMirrorMode;
  else
    Result := inherited;
  end;
end;

procedure TMapperJyMultiAsic.ClockCpu;
begin
  if ActiveAsic = TInnerAsic.Vrc4 then
    FVrc4.ClockCpu;
end;

procedure TMapperJyMultiAsic.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if ActiveAsic = TInnerAsic.Mmc3 then
    inherited;
end;

function TMapperJyMultiAsic.IrqPending: Boolean;
begin
  case ActiveAsic of
    TInnerAsic.Mmc1:
      Result := False;
    TInnerAsic.Vrc4:
      Result := FVrc4.IrqPending;
  else
    Result := inherited;
  end;
end;

constructor TMapperNt319.Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(MAPPER_BMC_NT319, Prg, Chr, HasChrRam, MirrorMode);
  FMmc1 := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode, True, MAPPER_BMC_NT319);
  PowerOn;
end;

destructor TMapperNt319.Destroy;
begin
  FMmc1.Free;
  inherited;
end;

function TMapperNt319.UsesMmc1: Boolean;
begin
  Result := (FResetBank and 1) = 0;
end;

procedure TMapperNt319.PowerOn;
begin
  FResetBank := 0;
  inherited Reset;
  FMmc1.PowerOn;
end;

procedure TMapperNt319.Reset;
begin
  if FMmc1 = nil then
  begin
    inherited;
    Exit;
  end;
  // The reset counter selects the next game while both ASICs retain their registers.
  FResetBank := (FResetBank + 1) and $FF;
  FIrqPending := False;
  FMmc1.SelectNt319Block(FResetBank);
end;

procedure TMapperNt319.SerializeState(State: TNesStateArchive);
begin
  inherited;
  FMmc1.SerializeState(State);
  if State.Loading then
    FMmc1.SelectNt319Block(FResetBank);
end;

function TMapperNt319.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    if not FHasBoardPrgRam then
      Exit(False);
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;
  if UsesMmc1 then
    Result := FMmc1.CpuRead(Address, Value)
  else
    Result := inherited CpuRead(Address, Value);
end;

function TMapperNt319.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    if not FHasBoardPrgRam then
      Exit(False);
    FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;
  if UsesMmc1 then
    Result := FMmc1.CpuWrite(Address, Value)
  else
    Result := inherited CpuWrite(Address, Value);
end;

function TMapperNt319.CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean;
begin
  if UsesMmc1 and (Address >= $8000) then
    Result := FMmc1.CpuWriteTimed(Address, Value, CpuCycle)
  else
    Result := CpuWrite(Address, Value);
end;

function TMapperNt319.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if UsesMmc1 then
    Result := FMmc1.PpuRead(Address, Value)
  else
    Result := inherited PpuRead(Address, Value);
end;

function TMapperNt319.GetMirrorMode: TMirrorMode;
begin
  if UsesMmc1 then
    Result := FMmc1.GetMirrorMode
  else
    Result := inherited GetMirrorMode;
end;

procedure TMapperNt319.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if not UsesMmc1 then
    inherited;
end;

function TMapperNt319.IrqPending: Boolean;
begin
  Result := not UsesMmc1 and inherited IrqPending;
end;

end.

