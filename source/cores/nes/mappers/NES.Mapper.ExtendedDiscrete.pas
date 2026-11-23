unit NES.Mapper.ExtendedDiscrete;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked, HW.Sound.OPLL,
  HW.Sound.TMS5220, NES.Audio.Jaleco;

type
  TMapperExtendedDiscrete = class(TMapperBanked)
  private
    FBoard, FSubmapper: Integer;
    FRegs: array[0..31] of Integer;
    FResetBank: Integer;
    FMenuDip: Integer;
    FBoardPrgRamSize: Integer;
    FStarted, FKs7030LegacyOrder: Boolean;
    FExtraRam: array[0..$1FFF] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    function ConversionRamOffset(Address: UInt16): Integer;
    function IsYhcBoard: Boolean;
    procedure UpdateYhc;
    procedure UpdateSachen89433;
    procedure UpdateLiko;
    procedure UpdateK3071;
    procedure UpdateNamco;
    procedure UpdateMulticart428;
    procedure UpdateUxromMulticart;
    procedure UpdateLatchMulticart;
    procedure UpdateCtcMulticart;
    procedure UpdateAddressMulticart;
    procedure UpdateDiscreteMulticart;
    function MenuPrgDisconnected: Boolean;
    procedure UpdateMulticartLatches;
  protected
    procedure WriteJalecoSpeech(Address: UInt16; Value: UInt8); virtual;
  public
    constructor Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer = 0);
    procedure SetK3071Dip(Enabled: Boolean);
    procedure ConfigureBankedChrRam(Size: UInt64);
    procedure ConfigureBoardPrgRam(Size: UInt64);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure PowerOn; override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function NameTableOffset(Address: UInt16): UInt16; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
  end;

  TMapperJalecoJfSpeech = class(TMapperExtendedDiscrete)
  private
    FSpeech: TJalecoSpeech;
  protected
    procedure WriteJalecoSpeech(Address: UInt16; Value: UInt8); override;
  public
    constructor Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; const SpeechRom: TArray<Byte>);
    destructor Destroy; override;
    procedure Reset; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
    procedure SerializeState(State: TNesStateArchive); override;
    property Speech: TJalecoSpeech read FSpeech;
  end;

  TMapperGameinis = class(TMapperExtendedDiscrete)
  private
    FIrLevel, FIrEnabled, FIrPending: Boolean;
  public
    procedure SetInfraredInput(Active, FallingEdge: Boolean);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function IrqPending: Boolean; override;
  end;

  TMapper178SolderPad = class(TMapperExtendedDiscrete)
  private
    FPadIndex: Byte;
    FPadReadEnabled: Boolean;
  public
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperPeLpc = class(TMapperExtendedDiscrete)
  private
    FSpeech: TPeLpcSpeech;
    FWorkRamSize: Integer;
    function WorkRamOffset(Address: UInt16): Integer;
  public
    constructor Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
    destructor Destroy; override;
    procedure ConfigureWorkRam(Size: UInt64);
    procedure Reset; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperRcm452 = class(TMapperBanked)
  private
    FSubmapper: Integer;
    FRamSlots: Byte;
    procedure LatchDs927(Address: UInt16; Value: UInt8);
    procedure LatchDs916(Address: UInt16);
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperN46 = class(TMapperBanked)
  private
    FPrgRegisters: array[0..2] of Byte;
    FChrRegisters: array[0..3] of Byte;
    FSelected: array[0..1] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    procedure UpdatePatternBank(Slot: Integer);
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function NameTableOffset(Address: UInt16): UInt16; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperSuborLogo = class(TMapperBanked)
  private
    FControl, FNameBlock: Byte;
    procedure UpdatePatternBank;
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
  end;

  TMapperCeBasic = class(TMapperBanked)
  private
    FSubmapper: Integer;
    FMode, FTileBank: Byte;
    FShadow: array[0..$3FF] of Byte;
    function ReadPattern(Address: UInt16; out Value: UInt8): Boolean;
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperSuborKaraoke = class(TMapperBanked)
  private
    FLatch, FNametableBank: Byte;
    procedure UpdateLowerChr;
  public
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperKaraokeMicrophone = class(TMapperBanked)
  protected
    FMicrophoneLevel: Byte;
  public
    procedure SetMicrophoneLevel(Level: Byte);
  end;

  TMapperKkachiKaraoke = class(TMapperKaraokeMicrophone)
  private
    FHighPulses, FLowPulses, FAdcPhase: Byte;
    FPrgLatch: Byte;
  public
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperFamilyNoraebang = class(TMapperKaraokeMicrophone)
  private
    FOpll: TYM2413;
    FPrgLatch, FAdcShift, FAdcPreamble, FAdcOutput: Byte;
    FAdcSelected, FAdcClockHigh: Boolean;
    FNativePhase, FNativePeriod: Integer;
    FOutput: SmallInt;
    procedure UpdateBank;
    procedure ClockAdc(HighLevel: Boolean);
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

uses
  System.Hash, System.SysUtils, Core.Snapshots, NES.Consts;

constructor TMapperExtendedDiscrete.Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  if (Board = MAPPER_KAISER_KS7030) and (Length(Prg) = $20000) then
  begin
    var Hash := THashSHA1.Create;
    Hash.Update(Prg[0], Length(Prg));
    FKs7030LegacyOrder := SameText(Hash.HashAsString, '75E5A55D639F7BC5F6BDB36A02E4FB90369295EB');
  end;
  if (Board = MAPPER_BMC_9999999IN1) and (Length(Prg) = $10000) then
  begin
    var Hash := THashSHA1.Create;
    Hash.Update(Prg[0], Length(Prg));
    // The documented 9-in-1 menu uses the A4 solder pad.
    if SameText(Hash.HashAsString, '742FD29ED9CC8B78A89C283192D6E07889127926') then
      FMenuDip := $10;
  end;
  if ((Board = MAPPER_BMC_ET133A) and (Length(Prg) = $A0000)) or
    ((Board = MAPPER_BMC_KL09B) and (Length(Prg) = $40000)) then
  begin
    var Hash := THashSHA1.Create;
    Hash.Update(Prg[0], Length(Prg));
    var PrgHash := Hash.HashAsString;
    if Board = MAPPER_BMC_ET133A then
    begin
      // The 64-in-1 III and IV cartridges strap the PRG-disable jumper high.
      if SameText(PrgHash, '6DAD778BEEC3AF55994CD6CD5EFBCC017DE9DEA9') or
        SameText(PrgHash, '7AB0411369FBF87E06AC1598F96FF48EA95AB933') then
        FMenuDip := 1;
    end
    else if SameText(PrgHash, '89CF160491BCAEB78CB317D1DF833E10B10AC163') then
      FMenuDip := $0F; // Super 980-in-1 menu.
  end;
  if (Board = MAPPER_BMC_K3071) and (Submapper = 1) and (Length(Prg) < $40000) then
    raise ENesException.Create('Mapper 438.1 requires PRG ROM for a menu and a 128 KiB UNROM block');
  if Board = MAPPER_SACHEN_89433 then
  begin
    SetLength(FChrMemory, $8000);
    FHasChrRam := True;
  end;
  if Board = MAPPER_OEKA_KIDS then
  begin
    SetLength(FChrMemory, $8000);
    FHasChrRam := True
  end;
  if Board = MAPPER_EDU2000 then
    SetLength(FPrgRam, $8000);
  if Board = MAPPER_WAIXING178 then
    SetLength(FPrgRam, $8000);
  if Board = MAPPER_MALEE2 then
  begin
    if Length(Prg) < $8800 then
      raise ENesException.Create('Mapper 55 requires 32 KiB PRG and a 2 KiB extension');
    SetLength(FPrgRam, $800);
  end;
  if (Board = MAPPER_SUPER_GAMES_KING) or (Board = MAPPER_BMC_K1053) then
  begin
    SetLength(FChrMemory, $8000);
    FHasChrRam := True;
  end;
  Reset;
end;

procedure TMapperExtendedDiscrete.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if FBoard = MAPPER_BMC_K3071 then
    State.Field(FMenuDip, SizeOf(FMenuDip));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FResetBank, SizeOf(FResetBank));
  State.Field(FStarted, SizeOf(FStarted));
  State.Field(FExtraRam, SizeOf(FExtraRam));
  State.Field(FNameRam, SizeOf(FNameRam));
end;

procedure TMapperExtendedDiscrete.SetK3071Dip(Enabled: Boolean);
begin
  if (FBoard = MAPPER_BMC_K3071) and (FSubmapper = 0) then
    FMenuDip := Ord(Enabled);
end;

procedure TMapperExtendedDiscrete.ConfigureBankedChrRam(Size: UInt64);
begin
  if (Size <> $2000) and (Size <> $8000) then
    raise ENesException.Create('Unsupported banked CHR RAM size');
  SetLength(FChrMemory, Integer(Size));
end;

procedure TMapperExtendedDiscrete.ConfigureBoardPrgRam(Size: UInt64);
begin
  if (Size <> 0) and (Size <> $800) and (Size <> $1000) and (Size <> $2000) then
    raise ENesException.Create('Unsupported discrete mapper PRG RAM size');
  FBoardPrgRamSize := Integer(Size);
end;

procedure TMapperExtendedDiscrete.PowerOn;
begin
  if (FBoard = MAPPER_CTC12IN1) or (FBoard = MAPPER_KN42) or
    (FBoard = MAPPER_SA005A) or (FBoard = MAPPER_BMC891227) or (FBoard = MAPPER_MGC026) or
    (FBoard = MAPPER_RESET_NROM256) or (FBoard = MAPPER_BMC_K3017) or (FBoard = MAPPER_NTDEC_2779) or
    (FBoard = MAPPER_BMC_9999999IN1) or (FBoard = MAPPER_BMC_TH2348) or (FBoard = MAPPER_SACHEN_3014) or
    (FBoard = MAPPER_BMC_K3004) or (FBoard = MAPPER_SUPER_SOCCER_CHAMPION) or
    (FBoard = MAPPER_LUCKY_RABBIT) or (FBoard = MAPPER_PALTHENA) or
    (FBoard = MAPPER_WHIRLWIND_LH42) or (FBoard = MAPPER_KAISER_KS7021A) or
    (FBoard = MAPPER_CONTRA_PIRATE) or (FBoard = MAPPER_NTDEC_2718) or
    (FBoard = MAPPER_BMC_K3071) or (FBoard = MAPPER_KAISER_KS7009) or
    (FBoard = MAPPER_BMC_P3127_01) or IsYhcBoard then
  begin
    FStarted := False;
    FResetBank := 0;
  end;
  inherited;
end;

procedure TMapperExtendedDiscrete.Reset;
begin
  inherited;
  var RetainRegisters := (FBoard = MAPPER_KAISER7058) or (FBoard = MAPPER_MULTICART_428) or
    ((FBoard = MAPPER_YY850437C) and (FSubmapper = 3)) or
    (FBoard = MAPPER_CTC12IN1) or (FBoard = MAPPER_KN42) or
    (FBoard = MAPPER_SA005A) or (FBoard = MAPPER_BMC891227) or (FBoard = MAPPER_MGC026) or
    (FBoard = MAPPER_NTDEC_2779) or (FBoard = MAPPER_BMC_9999999IN1) or (FBoard = MAPPER_BMC_TH2348) or
    (FBoard = MAPPER_SACHEN_3014) or (FBoard = MAPPER_SUPER_SOCCER_CHAMPION) or
    (FBoard = MAPPER_LUCKY_RABBIT) or (FBoard = MAPPER_PALTHENA) or
    (FBoard = MAPPER_WHIRLWIND_LH42) or (FBoard = MAPPER_KAISER_KS7021A) or
    (FBoard = MAPPER_CONTRA_PIRATE) or (FBoard = MAPPER_NTDEC_2718) or
    (FBoard = MAPPER_KAISER_KS7009) or (FBoard = MAPPER_BMC_P3127_01) or IsYhcBoard;
  var InnerBank := FRegs[1];
  if not RetainRegisters or not FStarted then
    FillChar(FRegs, SizeOf(FRegs), 0);
  if (FBoard = MAPPER_S009) and FStarted then
    FRegs[1] := InnerBank;
  if not FStarted then
    case FBoard of
      MAPPER_WHIRLWIND_LH42, MAPPER_NTDEC_2718:
        begin
          FRegs[5] := Ord(FBoard = MAPPER_WHIRLWIND_LH42);
          FRegs[7] := 1;
        end;
      MAPPER_CONTRA_PIRATE:
        begin
          for var Index := 0 to 15 do
            FRegs[Index] := Index;
          for var Slot := 0 to 2 do
            FRegs[16 + Slot] := $FC + Slot;
        end;
    end;
  if (FBoard = MAPPER_KAISER_KS7009) and not FStarted then
  begin
    FRegs[1] := 2;
    for var Slot := 2 to 5 do
      FRegs[Slot] := Slot + 2;
    FRegs[7] := 1;
  end;
  if (FBoard = MAPPER_PALTHENA) and not FStarted then
  begin
    FRegs[1] := 8;
    // The cartridge powers up with alternating two-byte rows in CHR RAM.
    if FHasChrRam then
      for var Index := 0 to Length(FChrMemory) - 1 do
        FChrMemory[Index] := $FF * Ord((Index and 2) <> 0);
  end;
  FRamEnabled := FBoard = MAPPER_SEALIE_COMPUTING;
  if FBoard = MAPPER_LITTLECOM160 then
  begin
    Prg32(0);
    Mirror(1 xor (FSubmapper and 1));
  end;
  if FBoard = MAPPER_EDU2000 then
    FRamEnabled := True;
  if (FBoard = MAPPER_WAIXING178) or (FBoard = MAPPER_DISCRETE_246) then
    FRamEnabled := True;
  if FStarted and (FBoard = MAPPER_DISCRETE_233) then
    FResetBank := FResetBank xor 1;
  if FStarted and (FBoard = MAPPER_KN42) then
    FResetBank := FResetBank xor 1;
  if (FBoard = MAPPER_BMC_K3017) and FStarted and (Length(FPrgRom) > $80000) then
  begin
    FResetBank := FResetBank xor 1;
    FRegs[1] := InnerBank;
  end;
  if FBoard = MAPPER_BMC_09078 then
    FRegs[1] := 8;
  if FBoard = MAPPER_BMC_TX5_8IN1 then
    FRegs[1] := 1;
  if FBoard = MAPPER_NTDEC_A9778 then
    for var Index := 0 to 3 do
      FRegs[Index] := $FF;
  if FStarted and (FBoard = MAPPER_BMC_K3004) then
  begin
    FRegs[1] := InnerBank;
    FResetBank := (FResetBank + 1) and $FF;
  end;
  if FStarted and (FBoard = MAPPER_RESET_NROM256) then
    FResetBank := (FResetBank + 1) and $FF;
  if FStarted and (FBoard = MAPPER_BMC_K3071) and (FSubmapper = 1) then
    FResetBank := FResetBank xor 1;
  FStarted := True;
  case FBoard of
    MAPPER_YHC_UNROM, MAPPER_YHC_AXROM, MAPPER_YHC_MULTICART:
      begin
        FRamEnabled := False;
        UpdateYhc;
      end;
    MAPPER_SACHEN_89433:
      begin
        FRamEnabled := False;
        UpdateSachen89433;
      end;
    MAPPER_LIKO_429:
      begin
        FRamEnabled := FBoardPrgRamSize <> 0;
        FRegs[0] := 4;
        UpdateLiko;
      end;
    MAPPER_BMC_K3071:
      begin
        FRamEnabled := False;
        UpdateK3071;
      end;
    MAPPER_CONTRA_PIRATE:
      begin
        for var Slot := 0 to 2 do
          Prg8(Slot, FRegs[16 + Slot]);
        Prg8(3, -1);
        for var Slot := 0 to 7 do
          Chr1(Slot, FRegs[Slot]);
      end;
    MAPPER_SACHEN_3013:
      Prg32(0);
    MAPPER_WHIRLWIND_LH42, MAPPER_NTDEC_2718:
      begin
        FRamEnabled := FBoard = MAPPER_NTDEC_2718;
        Prg8(0, FRegs[6]);
        Prg8(1, FRegs[7]);
        Prg8(2, $E);
        Prg8(3, $F);
        Mirror(FRegs[5]);
      end;
    MAPPER_KAISER_KS7021A:
      begin
        Prg16(0, FRegs[8]);
        Prg16(1, -1);
        for var Slot := 0 to 7 do
          Chr1(Slot, FRegs[Slot]);
        Mirror(FRegs[9]);
      end;
    MAPPER_KAISER_KS7030:
      begin
        FRegs[0] := $F;
        FRegs[1] := $F;
        Mirror(1);
      end;
    MAPPER_LUCKY_RABBIT:
      begin
        Prg32(-1);
        Mirror((FRegs[0] shr 4) and 1);
      end;
    MAPPER_PALTHENA:
      begin
        Prg8(0, 12);
        Prg8(1, FRegs[0]);
        Prg8(2, 14);
        Prg8(3, 15);
        Mirror((FRegs[1] shr 3) and 1);
      end;
    MAPPER_KAISER_KS7016B:
      Prg32(2);
    MAPPER_KAISER_KS7010:
      begin
        Prg8(0, 10);
        Prg8(1, 11);
        Prg8(2, 6);
        Prg8(3, 7);
        Mirror(0);
      end;
    MAPPER_SUPER_SOCCER_CHAMPION:
      begin
        Chr8(0);
        Mirror(0);
        Prg8(1, 13);
        Prg8(2, 14);
        Prg8(3, 15);
        CpuWrite($C000, FRegs[0]);
      end;
    MAPPER_MALEE2, MAPPER_JY043:
      Prg32(0);
    MAPPER_MULTICART_380, MAPPER_NC20MB, MAPPER_F1002, MAPPER_SUPER_GAMES_KING:
      CpuWrite($8000, 0);
    MAPPER_YY850437C, MAPPER_S009, MAPPER_YS2309:
      UpdateUxromMulticart;
    MAPPER_INX_007T, MAPPER_SUBOR_045N, MAPPER_MAXIVISION_NTDEC:
      UpdateLatchMulticart;
    MAPPER_CTC09, MAPPER_CTC12IN1, MAPPER_TJ03, MAPPER_I030_0365, MAPPER_KN42, MAPPER_BMC830928C:
      UpdateCtcMulticart;
    MAPPER_BMC_631601, MAPPER_SA005A, MAPPER_BMC891227, MAPPER_FAM250, MAPPER_P3150, MAPPER_MULTICART_375, MAPPER_TELETUBBIES_420, MAPPER_MGC026, MAPPER_RESET_NROM256, MAPPER_OK043, MAPPER_BMC_09078, MAPPER_BMC_P3127_01, MAPPER_BMC_K3017, MAPPER_NEWSTAR_12IN1, MAPPER_BMC_K1053, MAPPER_BMC_SQ002, MAPPER_BMC_35BH1, MAPPER_NTDEC_2779:
      UpdateMulticartLatches;
    MAPPER_BMC_K3036, MAPPER_BMC_5069, MAPPER_CALTRON_9IN1, MAPPER_BMC_J2282, MAPPER_BMC_9999999IN1, MAPPER_BMC_TH2348, MAPPER_REALTEC_8042, MAPPER_BMC_ET89, MAPPER_BMC_VQ168, MAPPER_BMC_971107_00G, MAPPER_BMC_YH810X1, MAPPER_NTDEC_9012, MAPPER_BMC_ET120, MAPPER_KEYBYTE_COMPUTER, MAPPER_NTDEC_15IN1, MAPPER_BMC_K1079, MAPPER_BMC_0359, MAPPER_BMC_HC001, MAPPER_BMC_N80, MAPPER_SANE_TING_5IN1, MAPPER_BMC_K3069, MAPPER_BMC_CH512K, MAPPER_SACHEN_3014, MAPPER_BMC_BD23, MAPPER_BMC_5068, MAPPER_BMC_FC40, MAPPER_BMC_W03, MAPPER_BMC_J2096, MAPPER_BMC_KN20:
      UpdateAddressMulticart;
    MAPPER_BMC_T215, MAPPER_BMC_ET156, MAPPER_BMC_ET82, MAPPER_BMC_8203, MAPPER_BMC_ST32, MAPPER_BMC_FE011, MAPPER_BMC_HN02, MAPPER_BMC_K3057, MAPPER_BMC_ET81, MAPPER_BMC_810706, MAPPER_BMC_810706_LEGACY, MAPPER_BMC_810430, MAPPER_BMC_07027, MAPPER_BMC_J2054, MAPPER_BMC_K3021, MAPPER_BMC_ET133A, MAPPER_BMC_J2061, MAPPER_BMC_TX5_8IN1, MAPPER_BMC_T4IN1, MAPPER_BMC_4705, MAPPER_BMC_A23, MAPPER_BMC_63100, MAPPER_BMC_J2042, MAPPER_BMC_T124, MAPPER_BMC_K3004, MAPPER_BMC_9135, MAPPER_BMC_LB12IN1, MAPPER_BMC_68IN1, MAPPER_BMC_3945, MAPPER_BMC_J2083, MAPPER_BMC_KL09B, MAPPER_BMC_ET20, MAPPER_BMC_90IN1, MAPPER_BMC_821134, MAPPER_BMC_GC004, MAPPER_NTDEC_A9778:
      UpdateDiscreteMulticart;
    MAPPER_MULTICART_428:
      UpdateMulticart428;
    MAPPER_SEALIE_COMPUTING:
      begin
        Prg16(1, 7);
        SetLength(FChrMemory, $8000);
        FHasChrRam := True
      end;
    MAPPER_JALECO_JF17, MAPPER_SUNSOFT_89:
      ;
    MAPPER_KAISER_KS7009:
      begin
        FRamEnabled := False;
        Prg8(2, -2);
        Prg8(3, -1);
        UpdateNamco;
      end;
    MAPPER_JINGKETAI:
      begin
        FRamEnabled := True;
        Prg32(0);
      end;
    MAPPER_NAMCO_108_76, MAPPER_NAMCO_108_95:
      begin
        Prg8(0, 0);
        Prg8(1, 0);
        Prg8(2, -2);
        Prg8(3, -1);
        UpdateNamco
      end;
    MAPPER_IREM_LROG017:
      begin
        Prg32(0);
        FMirror := TMirrorMode.FourScreen
      end;
    MAPPER_KAISER7058:
      begin
        Prg32(0);
        Chr4(0, FRegs[0]);
        Chr4(1, FRegs[1])
      end;
    MAPPER_OEKA_KIDS:
      begin
        Prg32(0);
        Chr4(0, 0);
        Chr4(1, 3);
        FMirror := TMirrorMode.Single0
      end;
    MAPPER_JALECO_JF19:
      Prg16(1, 0);
    MAPPER_IREM_TAM_S1:
      begin
        Prg16(0, -1);
        Prg16(1, 0)
      end;
    MAPPER_GOLDEN_FIVE:
      Prg16(1, 15);
    MAPPER_DISCRETE_120:
      Prg32(2);
    MAPPER_LH32:
      Prg32(-1);
    MAPPER_CNROM_PROTECT:
      begin
        FRegs[0] := 1;
        Prg32(0)
      end;
    MAPPER_DAOU_INFOSYS:
      Mirror(2);
    MAPPER_SUBOR166:
      begin
        Prg16(0, 0);
        Prg16(1, 7);
        FHasChrRam := True
      end;
    MAPPER_WAIXING178:
      begin
        Prg32(0);
        Mirror(0)
      end;
    MAPPER_DISCRETE_246:
      Prg8(3, $FF);
    MAPPER_SACHEN_143:
      Prg32(0);
    MAPPER_NTDEC_TC112:
      begin
        Prg8(0, 0);
        Prg8(1, -3);
        Prg8(2, -2);
        Prg8(3, -1)
      end;
    MAPPER_DISCRETE_203, MAPPER_DISCRETE_214, MAPPER_DISCRETE_231:
      begin
        Prg16(0, 0);
        Prg16(1, 0)
      end;
    MAPPER_DISCRETE_225, MAPPER_DISCRETE_226:
      Prg32(0);
    MAPPER_DISCRETE_227, MAPPER_DISCRETE_229:
      CpuWrite($8000, 0);
    MAPPER_DISCRETE_233:
      begin
        Prg16(0, FResetBank shl 5);
        Prg16(1, (FResetBank shl 5) or 1)
      end;
    MAPPER_GS2004:
      Prg32(7);
    MAPPER_A65_AS, MAPPER_BMC11160, MAPPER_BMC190IN1, MAPPER_BMC8157:
      CpuWrite($8000, 0);
    MAPPER_KAISER7016:
      begin
        Prg32(3);
        FRegs[0] := 8
      end;
    MAPPER_LH51:
      begin
        Prg8(0, 0);
        Prg8(1, 13);
        Prg8(2, 14);
        Prg8(3, 15)
      end;
    MAPPER_KAISER7013_B:
      Mirror(0);
    MAPPER_HP898F:
      begin
        Prg16(0, 0);
        Prg16(1, 0);
        Mirror(1)
      end;
    MAPPER_RT01:
      begin
        Prg16(0, 0);
        Prg16(1, 0);
        for var i := 0 to 3 do
          Chr2(i, 0)
      end;
    MAPPER_BMC_K3046:
      Prg16(1, 7);
    MAPPER_KAISER7012:
      Prg32(1);
    MAPPER_DREAM_TECH01:
      Prg16(1, 8);
  else
    Prg32(0);
  end;
end;

procedure TMapperExtendedDiscrete.UpdateMulticartLatches;
var
  Bank: Integer;
begin
  var Latch := FRegs[0];
  var Data := FRegs[1];
  case FBoard of
    MAPPER_OK043:
      begin
        Bank := Latch and 7;
        if (Latch and 4) <> 0 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end;
        Chr8(Bank);
        Mirror((Latch shr 4) and 1);
      end;
    MAPPER_BMC_P3127_01:
      begin
        Bank := Data and $1F;
        Chr8(Bank);
        case Bank of
          $1D:
            begin
              Prg16(0, $1D);
              Prg16(1, $1D);
              Mirror(1);
            end;
          $1E, $1F:
            begin
              Prg32($0F);
              Mirror(0);
            end;
        else
          // PRG A15 is inverted for these four selections. CHR uses the raw latch.
          if Bank in [$0C..$0F] then
            Bank := Bank xor 2;
          if (Data and $40) <> 0 then
            Prg32(Bank shr 1)
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank);
          end;
          Mirror(1 xor ((Data shr 5) and 1));
        end;
      end;
    MAPPER_BMC_09078:
      begin
        Bank := Data and $0F;
        if (Data and 8) = 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank or 7);
          FMirror := FInitialMirror;
        end
        else
        begin
          if (Data and 1) = 0 then
            Prg32(Bank shr 1)
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank);
          end;
          Mirror((Data shr 4) and 1);
        end;
      end;
    MAPPER_BMC_K3017:
      if FResetBank <> 0 then
      begin
        if FSubmapper = 1 then
          Bank := (Latch shr 2) and 7
        else
          Bank := Data and 7;
        Prg16(0, $20 or Bank);
        Prg16(1, $27);
        Mirror(0);
      end
      else
      begin
        Bank := (Latch shr 2) and $1F;
        if (Latch and $81) = $81 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          if (Latch and $80) <> 0 then
            Prg16(1, Bank)
          else
            Prg16(1, 0);
        end;
        Mirror((Latch shr 1) and 1);
      end;
    MAPPER_NEWSTAR_12IN1:
      begin
        var Outer := (Latch and $30) shr 1 or (Latch and 1) shl 5;
        Bank := Outer or (Data and 7);
        if (Data and 8) = 0 then
        begin
          Prg16(0, Bank and not ((Latch shr 6) and 1));
          Prg16(1, Outer or 7);
        end
        else if (Latch and $40) <> 0 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end;
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_K1053:
      begin
        Bank := (Data and $3F) or ((Latch and $0C) shl 4);
        case Latch and 3 of
          0:
            Prg32(Bank shr 1);
          1:
            begin
              Prg16(0, Bank);
              Prg16(1, Bank or 7);
            end;
          2:
            for var Slot := 0 to 3 do
              Prg8(Slot, (Bank shl 1) or (Data shr 7));
          3:
            begin
              Prg16(0, Bank);
              Prg16(1, Bank);
            end;
        end;
        Chr8(FRegs[2] and 3);
        Mirror((Data shr 6) and 1);
      end;
    MAPPER_BMC_SQ002:
      if (Data and $20) = 0 then
      begin
        Prg32(Data and 7);
        Mirror(2 + ((Data shr 4) and 1));
      end
      else
      begin
        Bank := $10 or ((Data shl 1) and $0E) or ((Data shr 3) and 1);
        Prg16(0, Bank);
        Prg16(1, (Bank and $18) or 7);
        Mirror((Data shr 2) and 1);
      end;
    MAPPER_BMC_35BH1:
      begin
        Prg32(Data and 3);
        Chr8(Data shr 2);
      end;
    MAPPER_NTDEC_2779:
      begin
        Bank := (Latch shr 1) and 7;
        Prg16(0, Bank);
        Prg16(1, Bank);
        Chr8(Latch shr 3);
        Mirror(Latch and 1);
      end;
    MAPPER_TELETUBBIES_420:
      begin
        var Outer := ((Latch and 4) shl 3) or (Data and $18);
        Bank := Outer or (Data and 7);
        if (Data and $40) <> 0 then
          Bank := Bank and not 1;
        Prg16(0, Bank);
        if (Data and $80) = 0 then
          Prg16(1, Outer or 7)
        else
          Prg16(1, Bank or ((Data shr 6) and 1));
        Mirror((Data shr 5) and 1);
      end;
    MAPPER_MGC026:
      begin
        Prg32(Data shr 4);
        Chr8(Data and $0F);
        Mirror(Ord((Data and $20) = 0));
      end;
    MAPPER_RESET_NROM256:
      begin
        Prg32(FResetBank);
        Chr8(FResetBank);
        if FSubmapper = 0 then
          Mirror((FResetBank xor 1) and 1);
      end;
    MAPPER_BMC_631601:
      begin
        Bank := (Latch and $F) shl 3;
        Prg16(0, Bank or (Data and 7));
        Prg16(1, Bank or 7);
        Mirror((Latch shr 4) and 1);
      end;
    MAPPER_SA005A:
      begin
        Bank := Latch and $F;
        Prg16(0, Bank);
        Prg16(1, Bank);
        Chr8(Bank);
        Mirror(Ord((Latch and 8) = 0));
      end;
    MAPPER_BMC891227:
      begin
        Bank := (Latch and $18) or (Data and 7);
        case (Latch shr 5) and 3 of
          0:
            begin
              Prg16(0, Bank);
              Prg16(1, Bank);
            end;
          1:
            Prg32(Bank shr 1);
        else
          begin
            if (Latch and $20) <> 0 then
              Bank := $20 or (Data and 7);
            Prg16(0, Bank);
            Prg16(1, Bank or 7);
          end;
        end;
        if (Latch and $40) = 0 then
          Mirror((Latch shr 7) and 1)
        else
          FMirror := FInitialMirror;
      end;
    MAPPER_FAM250:
      begin
        Bank := Data and $3F;
        if FSubmapper = 1 then
          Bank := Bank or ((Latch shl 2) and $40) or ((Latch shr 5) and $80)
        else
          Bank := Bank or ((Latch shl 4) and $40);
        FRegs[2] := (Bank shl 1) or (Data shr 7);
        case Latch and 7 of
          0, 4:
            Prg32(Bank shr 1);
          1:
            begin
              Prg16(0, Bank);
              Prg16(1, Bank or 7);
            end;
          2, 6:
            for var Slot := 0 to 3 do
              Prg8(Slot, FRegs[2]);
          3, 7:
            begin
              Prg16(0, Bank);
              Prg16(1, Bank);
            end;
          5:
            Prg32((Bank shr 1) or 3);
        end;
        Mirror((Data shr 6) and 1);
      end;
    MAPPER_P3150:
      begin
        Bank := Latch and $1F;
        if FSubmapper = 0 then
          Latch := Latch or $20;
        if (Latch and $20) = 0 then
          for var Slot := 0 to 3 do
            Prg8(Slot, $40)
        else if Bank < 2 then
          Prg32(0)
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end;
        Chr8(Bank);
        Mirror((Latch shr 4) and 1);
      end;
    MAPPER_MULTICART_375:
      begin
        Bank := ((Latch shr 2) and $1F) or ((Latch shr 3) and $20) or ((Latch shr 4) and $40);
        if (Latch and $80) <> 0 then
        begin
          if (Latch and 1) <> 0 then
            Prg32(Bank shr 1)
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank);
          end;
        end
        else
        begin
          var Lower := Bank;
          if (Latch and $800) <> 0 then
            Lower := (Bank and not 7) or (Data and 7);
          if (Latch and 1) <> 0 then
            Lower := Lower and not 1;
          Prg16(0, Lower);
          if (Latch and $200) <> 0 then
            Prg16(1, Bank or 7)
          else if FSubmapper = 2 then
            Prg16(1, 0)
          else
            Prg16(1, Bank and not 7);
        end;
        Mirror((Latch shr 1) and 1);
      end;
  end;
end;

procedure TMapperExtendedDiscrete.UpdateCtcMulticart;
begin
  var Outer := FRegs[0];
  var Inner := FRegs[1];
  var Horizontal := False;
  case FBoard of
    MAPPER_CTC09:
      begin
        if (Outer and $10) <> 0 then
        begin
          var Bank := ((Outer and 7) shl 1) or ((Outer shr 3) and 1);
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Outer and 7);
        Chr8(Inner);
        Horizontal := (Outer and $20) <> 0;
      end;
    MAPPER_CTC12IN1:
      begin
        var Bank := Outer and $1F;
        case Outer shr 6 of
          0:
            begin
              Prg16(0, Bank);
              Prg16(1, Bank);
            end;
          1:
            Prg32(Bank shr 1);
        else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank or 7);
          end;
        end;
        Horizontal := (Outer and $20) <> 0;
      end;
    MAPPER_TJ03:
      begin
        var Bank := (Outer shr 8) and 7;
        Prg32(Bank);
        Chr8(Bank);
        if FSubmapper = 1 then
          Horizontal := (Outer and $800) <> 0
        else
          Horizontal := (Outer and $200) <> 0;
      end;
    MAPPER_I030_0365, MAPPER_BMC830928C:
      begin
        var Bank := Outer and 7;
        if ((FBoard = MAPPER_I030_0365) and (FSubmapper = 0) and (Bank = 0)) or
          ((FBoard = MAPPER_BMC830928C) and ((Outer and 8) <> 0)) then
          Prg32((Bank shl 2) or (Inner and 3))
        else
        begin
          Prg16(0, (Bank shl 3) or (Inner and 7));
          Prg16(1, (Bank shl 3) or 7);
        end;
        if FBoard = MAPPER_I030_0365 then
          Horizontal := (Outer and 8) <> 0
        else
          Horizontal := (Outer and $10) <> 0;
      end;
    MAPPER_KN42:
      begin
        var Bank := FResetBank shl 4;
        Prg16(0, Bank or (((Inner shl 1) or (Inner shr 4)) and $F));
        Prg16(1, Bank or $F);
        Exit;
      end;
  end;
  if Horizontal then
    FMirror := TMirrorMode.Horizontal
  else
    FMirror := TMirrorMode.Vertical;
end;

procedure TMapperExtendedDiscrete.UpdateLatchMulticart;
begin
  var InnerBank := FRegs[1];
  case FBoard of
    MAPPER_INX_007T:
      begin
        Prg32((FRegs[0] shl 3) or (InnerBank and 7));
        if (InnerBank and $10) <> 0 then
          FMirror := TMirrorMode.Single1
        else
          FMirror := TMirrorMode.Single0;
      end;
    MAPPER_SUBOR_045N:
      begin
        var Outer := (InnerBank and $80) shr 4;
        Prg16(0, Outer or (InnerBank and 7));
        Prg16(1, Outer or 7);
      end;
    MAPPER_MAXIVISION_NTDEC:
      begin
        Prg32((FRegs[0] shl 1) or (InnerBank and 1));
        Chr8((FRegs[0] shl 3) or ((InnerBank shr 4) and 7));
      end;
  end;
end;

procedure TMapperExtendedDiscrete.UpdateUxromMulticart;
begin
  var Outer := (FRegs[0] and 7) shl 3;
  var Inner := FRegs[1] and 7;
  var Fixed := 7;
  case FBoard of
    MAPPER_YY850437C:
      begin
        var MirrorBits := $60;
        if FSubmapper = 1 then
          MirrorBits := $40
        else if FSubmapper >= 2 then
          MirrorBits := $20;
        Mirror(Ord((FRegs[0] and MirrorBits) <> 0));
      end;
    MAPPER_S009:
      Mirror(Ord((FRegs[0] and $20) = 0));
    MAPPER_YS2309:
      begin
        var OuterMask := (FRegs[2] shr 1) and $38;
        Outer := (FRegs[0] shr 1) and OuterMask;
        Inner := FRegs[1] and ($3F xor OuterMask);
        Fixed := $3F xor OuterMask;
        Mirror(FRegs[1] shr 7);
      end;
  end;
  Prg16(0, Outer or Inner);
  Prg16(1, Outer or Fixed);
end;

procedure TMapperExtendedDiscrete.UpdateMulticart428;
begin
  var Bank := FRegs[1] shr 5;
  if (FRegs[1] and $10) <> 0 then
    Prg32(Bank shr 1)
  else
  begin
    Prg16(0, Bank);
    Prg16(1, Bank);
  end;
  Mirror((FRegs[1] shr 3) and 1);
  var InnerMask := FRegs[2] shr 6;
  Chr8(((FRegs[1] and 7) and not InnerMask) or (FRegs[4] and InnerMask));
end;

function TMapperExtendedDiscrete.MenuPrgDisconnected: Boolean;
begin
  Result := ((FRegs[0] and $100) = 0) and ((FRegs[0] and FMenuDip) <> 0);
end;

procedure TMapperExtendedDiscrete.UpdateAddressMulticart;
begin
  var Latch := FRegs[0];
  var Data := FRegs[1];
  case FBoard of
    MAPPER_BMC_K3036:
      begin
        var Bank := ((Latch and $80) shr 2) or (Latch and $1F);
        if (Latch and $20) <> 0 then
        begin
          Prg32(Bank shr 1);
          Mirror((Latch shr 2) and 1);
        end
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank or 7);
          if FSubmapper = 1 then
            Mirror(Ord((Latch and $18) = $10))
          else
            Mirror((Latch shr 6) and 1);
        end;
      end;
    MAPPER_BMC_5069:
      begin
        var Outer := (Latch and 7) shl 3;
        Prg16(0, Outer or (Data and 7));
        Prg16(1, Outer or 7);
        Mirror((Latch shr 5) and 1);
      end;
    MAPPER_CALTRON_9IN1:
      begin
        var Inner := FRegs[2];
        if (Data and 2) <> 0 then
        begin
          var Outer := Latch shr 2;
          Prg16(0, Outer or (Inner shr 2));
          Prg16(1, Outer or 3);
        end
        else
          Prg32(Latch shr 3);
        Chr8(((Data shr 1) and $1C) or (Inner and 3));
        Mirror(Latch and 1);
      end;
    MAPPER_BMC_J2282:
      begin
        var Bank := Latch and $1F;
        if (Latch and $40) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_9999999IN1:
      begin
        if not MenuPrgDisconnected then
          FRegs[2] := Latch;
        var MappedAddress := FRegs[2];
        if (MappedAddress and $2000) <> 0 then
          Prg32(MappedAddress shr 2)
        else
        begin
          Prg16(0, MappedAddress shr 1);
          Prg16(1, MappedAddress shr 1);
        end;
        Chr8(Data);
        Mirror(Latch and 1);
      end;
    MAPPER_BMC_TH2348:
      begin
        var Outer := (Latch and 7) shl 3;
        Prg16(0, Outer or (Data and 7));
        Prg16(1, Outer or 7);
        Mirror((Latch shr 3) and 1);
      end;
    MAPPER_REALTEC_8042:
      if (Data and $40) <> 0 then
      begin
        Prg32((Data and 7) or ((Data shr 3) and $18));
        Mirror(3 - ((Data shr 4) and 1));
      end
      else
      begin
        var Outer := (Data shr 2) and $38;
        Prg16(0, Outer or (Data and 7));
        Prg16(1, Outer or 7);
        Mirror((Data shr 4) and 1);
      end;
    MAPPER_BMC_ET89:
      begin
        var Bank := ((Latch shr 2) and $1F) or ((Latch shr 3) and $20);
        var CpuA14 := Latch and 1;
        if (Latch and $100) <> 0 then
        begin
          Prg16(0, ((Bank and not 7) or (Data and 7)) and not CpuA14);
          Prg16(1, Bank or 7);
        end
        else
        begin
          Prg16(0, Bank and not CpuA14);
          if (Latch and $80) <> 0 then
            Prg16(1, Bank or CpuA14)
          else
            Prg16(1, 0);
        end;
        Mirror((Latch shr 1) and 1);
      end;
    MAPPER_BMC_VQ168:
      begin
        var Bank := (Latch shr 5) and 7;
        if (Latch and 4) <> 0 then
          Prg32(Bank)
        else
        begin
          Prg16(0, Bank shl 1);
          Prg16(1, (Bank shl 1) or 7);
        end;
        Chr8((Latch and 3) or ((Latch shr 2) and 4) or ((Latch shr 4) and 8));
        Mirror((Latch shr 8) and 1);
      end;
    MAPPER_BMC_971107_00G:
      if (Latch and $40) <> 0 then
      begin
        Prg32((Data and 7) or ((Latch shr 3) and not 7));
        Mirror(2 + ((Data shr 4) and 1));
      end
      else
      begin
        var Outer := (Latch shr 2) and not 7;
        Prg16(0, Outer or (Data and 7));
        Prg16(1, Outer or 7);
        Mirror(1 - ((Latch shr 4) and 1));
      end;
    MAPPER_BMC_YH810X1:
      begin
        var A14 := Ord((Latch and 4) = 0);
        Prg16(0, Data and not A14);
        Prg16(1, Data or A14);
        Chr8(FRegs[2]);
        Mirror(Latch and 1);
      end;
    MAPPER_NTDEC_9012:
      begin
        var A14 := (Latch shr 6) and 1;
        var Bank := (Latch shr 7) and $1F;
        Prg16(0, Bank and not A14);
        Prg16(1, Bank or A14);
        Chr8(Latch and $1F);
        Mirror((Latch shr 5) and 1);
      end;
    MAPPER_BMC_ET120:
      begin
        var Bank := ((Latch shr 2) and $1F) or ((Latch shr 5) and $20);
        var A14 := Latch and 1;
        if (Latch and $200) <> 0 then
        begin
          Prg16(0, (Bank and not A14) or Data);
          Prg16(1, Bank or A14 or 7);
        end
        else
        begin
          Prg16(0, Bank and not A14);
          Prg16(1, Bank or A14);
        end;
        Mirror((Latch shr 1) and 1);
      end;
    MAPPER_BMC_BD23:
      begin
        Prg32(Data);
        if (Data and $20) <> 0 then
          Mirror(2 + ((Data shr 4) and 1))
        else
          Mirror((Data shr 4) and 1);
      end;
    MAPPER_BMC_5068:
      begin
        var Mask := 7 or ((Latch and 2) shl 2);
        var Outer := (Latch shl 3) and not Mask;
        Prg16(0, Outer or (Data and Mask));
        Prg16(1, Outer or Mask);
      end;
    MAPPER_BMC_FC40:
      if (Latch and $60) <> 0 then
      begin
        var Mask := 3 or ((Latch and $40) shr 4);
        Prg32(((Latch shr 2) and not Mask) or (Data and Mask));
        Mirror(2 + ((Data shr 4) and 1));
      end
      else
      begin
        Prg32(((Latch shr 2) and not 3) or (Latch and 3));
        Mirror((Data shr 4) and 1);
      end;
    MAPPER_BMC_W03:
      begin
        if (Latch and 6) = 6 then
          Prg32(Latch shr 1)
        else
        begin
          Prg16(0, Latch);
          Prg16(1, Latch);
        end;
        Chr8(Latch);
        Mirror((Latch shr 3) and 1);
      end;
    MAPPER_BMC_J2096:
      begin
        var Bank := Latch shr 4;
        if (Latch and $100) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Chr8(Latch);
        Mirror((Latch shr 9) and 1);
      end;
    MAPPER_BMC_KN20:
      begin
        Prg16(0, Latch);
        Prg16(1, Latch);
        Chr8(Latch shr 1);
      end;
    MAPPER_SACHEN_3014:
      begin
        Prg32(0);
        Chr8((Data shr 4) and 1);
      end;
    MAPPER_NTDEC_15IN1:
      begin
        if (Data and $0E) <> 0 then
        begin
          Prg16(0, -1);
          Prg16(1, Data);
        end
        else
          Prg32(Data shr 1);
        Chr8(Data);
      end;
    MAPPER_BMC_K1079:
      begin
        if (Data and $80) <> 0 then
        begin
          Prg16(0, Data);
          Prg16(1, Data);
        end
        else
          Prg32(Data shr 1);
        Mirror((Data shr 6) and 1);
      end;
    MAPPER_BMC_0359:
      begin
        var Bank := (Data and $1F) or ((Latch and 7) shl 5);
        if (Data and $20) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        case Data shr 6 of
          0:
            Mirror(2);
          1:
            Mirror(0);
          2:
            Mirror(1);
          3:
            Mirror(3);
        end;
      end;
    MAPPER_BMC_HC001:
      begin
        if (Latch and 4) <> 0 then
          Prg32(Latch)
        else
        begin
          var Bank := (Latch shl 1) or ((Latch shr 4) and 1);
          Prg16(0, Bank);
          Prg16(1, Bank);
        end;
        Chr8(Latch);
      end;
    MAPPER_BMC_N80:
      begin
        if (Data and $1F) = 2 then
          Prg32(Data shr 1)
        else
        begin
          Prg16(0, Data);
          Prg16(1, Data);
        end;
        Chr8(Data);
        case Data shr 6 of
          0:
            Mirror(2); // NameTableOffset supplies the separate fourth quadrant.
            1:
            Mirror(0);
          2:
            Mirror(1);
          3:
            Mirror(3);
        end;
      end;
    MAPPER_SANE_TING_5IN1:
      begin
        if (Latch and 8) <> 0 then
        begin
          Prg16(0, Latch);
          Prg16(1, Latch);
        end
        else
          Prg32(Latch shr 1);
        Chr8(Data);
        Mirror((Latch shr 4) and 1);
      end;
    MAPPER_BMC_K3069:
      begin
        var Bank := (Latch shr 3) and 7;
        if (Latch and $20) <> 0 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end;
        Chr8(((Latch shr 1) and 3) or ((Latch shr 2) and $0C));
        Mirror(Latch and 1);
      end;
    MAPPER_BMC_CH512K:
      begin
        var Bank := Latch shr 2;
        if (Latch and $100) = 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank or 7);
        end
        else if (Latch and 1) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Chr8(((Latch shr 5) and 7) or ((Latch shr 1) and 8));
        Mirror((Latch shr 1) and 1);
      end;
    MAPPER_KEYBYTE_COMPUTER:
      begin
        var Bank := ((Data and 1) shl 5) or ((Latch shl 1) and $1E) or ((Latch shr 5) and 1);
        if (Latch and $40) <> 0 then
        begin
          var A14 := Ord((Latch and $10) = 0);
          Prg16(0, Bank and not A14);
          Prg16(1, Bank or A14);
        end
        else
        begin
          Prg16(0, (Bank and not 7) or (FRegs[2] and 7));
          Prg16(1, Bank or 7);
        end;
        Mirror((Latch shr 7) and 1);
      end;
  end;
end;

procedure TMapperExtendedDiscrete.UpdateDiscreteMulticart;
const
  K3021Mirroring: array[0..3] of Integer = (2, 0, 1, 3);

  procedure MapMirroredPrg(Bank: Integer);
  begin
    Prg16(0, Bank);
    Prg16(1, Bank);
  end;

begin
  var Latch := FRegs[0];
  var Data := FRegs[1];
  case FBoard of
    MAPPER_NTDEC_A9778:
      begin
        Prg16(0, (Latch and 7) or (Data shl 3));
        Prg16(1, (FRegs[2] and 7) or (FRegs[3] shl 3));
      end;
    MAPPER_BMC_T215:
      begin
        var Bank := (Latch shr 2) and $1F;
        if (Latch and $200) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank or 7);
        end
        else if (Latch and 1) <> 0 then
          Prg32(Bank shr 1)
        else
          MapMirroredPrg(Bank);
        Mirror((Latch shr 1) and 1);
      end;
    MAPPER_BMC_ET156:
      begin
        var ChrLines := 1;
        if (Latch and 1) <> 0 then
        begin
          Prg32(Latch shr 5);
          ChrLines := 3;
        end
        else
          MapMirroredPrg(Latch shr 4);
        Chr8(((Latch shr 3) and not ChrLines) or ((Latch shr 2) and ChrLines));
        Mirror((Latch shr 1) and 1);
      end;
    MAPPER_BMC_ET82:
      begin
        var Bank := ((Latch shr 1) and $20) or (Latch and $1F);
        if (Latch and $20) <> 0 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank or 7);
        end;
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_8203:
      begin
        var Bank := (Latch and not $0F) or ((Latch and 1) shl 3);
        if (Latch and $20) <> 0 then
        begin
          Prg32(((Bank shr 1) and not 7) or (Data and 7));
          Mirror(2 + ((Data shr 4) and 1));
        end
        else
        begin
          var InnerMask := 7;
          if (Latch and $18) = $18 then
            InnerMask := 3;
          Prg16(0, (Bank and not InnerMask) or (Data and InnerMask));
          Prg16(1, Bank or InnerMask);
          Mirror(Ord(InnerMask = 3));
        end;
      end;
    MAPPER_BMC_ST32:
      begin
        if (Latch and $20) <> 0 then
          Prg32(Latch shr 1)
        else
          MapMirroredPrg(Latch and $1F);
        Chr8(Data and $1F);
        Mirror(1 - ((Data shr 5) and 1));
      end;
    MAPPER_BMC_FE011:
      begin
        var Bank := Latch shr 1;
        if (Latch and 1) <> 0 then
          Prg32(Bank shr 1)
        else
          MapMirroredPrg(Bank);
        Chr8(Bank);
        Mirror(1 - ((Latch shr 4) and 1));
      end;
    MAPPER_BMC_HN02:
      begin
        if (Latch and 8) <> 0 then
          MapMirroredPrg(Latch)
        else
          Prg32(Latch shr 1);
        Chr8(Latch);
        Mirror(1 - ((Latch shr 3) and 1));
      end;
    MAPPER_BMC_K3057:
      begin
        var Bank := (Latch and not 7) or (Data and 7);
        if (Latch and 2) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Latch or 7);
        end
        else if (Latch and $80) <> 0 then
          Prg32(((Latch shr 1) and not 3) or (Data and 3))
        else
          MapMirroredPrg(Bank);
        if (Latch and 4) <> 0 then
          Mirror(2 + ((Data shr 4) and 1))
        else
          Mirror(Latch and 1);
      end;
    MAPPER_BMC_ET81:
      begin
        Prg32((Latch shr 4) and 7);
        Chr8(Latch and $0F);
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_810706, MAPPER_BMC_810706_LEGACY:
      begin
        var Bank := Latch shr 1;
        // The legacy image places the 128 KiB menu chip before the game chips.
        var Offset := 8 * Ord(FBoard = MAPPER_BMC_810706_LEGACY);
        if (Latch and $20) <> 0 then
        begin
          var Outer := (Bank and 8) + Offset;
          Prg16(0, Outer + (Data and 7));
          Prg16(1, Outer + 7);
        end
        else
          MapMirroredPrg((($10 or (Bank and 7)) + Offset) mod 24);
        Mirror(Latch and 1);
      end;
    MAPPER_BMC_810430:
      begin
        if (Data and 8) <> 0 then
          Prg32(Data shr 1)
        else
          MapMirroredPrg(Data);
        Chr8(Data);
      end;
    MAPPER_BMC_07027:
      begin
        if (Latch and $0C) = $0C then
          Prg32(Latch shr 2)
        else
          MapMirroredPrg(Latch shr 1);
        Chr8(Latch);
        Mirror(1 - ((Latch shr 3) and 1));
      end;
    MAPPER_BMC_J2054:
      begin
        if FSubmapper = 1 then
          Prg32(Data)
        else
          MapMirroredPrg(Data);
        Chr8(Data);
        Mirror((Data shr 3) and 1);
      end;
    MAPPER_BMC_K3021:
      begin
        var OuterBank := Data and $18;
        Prg16(0, OuterBank or (Latch and 7));
        Prg16(1, OuterBank or 7);
        Mirror(K3021Mirroring[Data and 3]);
      end;
    MAPPER_BMC_ET133A:
      begin
        var InnerMask := $0F;
        var OuterBank := 0;
        if Length(FPrgRom) >= $80000 then
          InnerMask := $1F;
        if (Latch and $400) <> 0 then
        begin
          OuterBank := InnerMask + 1;
          InnerMask := 7;
        end;
        var Bank := OuterBank or ((Latch shr 2) and InnerMask);
        if (Latch and $80) = 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, OuterBank);
        end
        else if (Latch and 1) <> 0 then
          Prg32(Bank shr 1)
        else
          MapMirroredPrg(Bank);
        Chr8(((Latch shr 6) and not 3) or (Data and 3));
        Mirror((Latch shr 1) and 1);
      end;
    MAPPER_BMC_J2061:
      begin
        MapMirroredPrg((Latch and $FF) shr 2);
        Chr8(Latch and $FF);
      end;
    MAPPER_BMC_TX5_8IN1:
      begin
        var OuterBank := FRegs[2] shr 3;
        if (FRegs[3] and 1) = 0 then
          Prg32(((OuterBank and not 7) or Data) shr 1)
        else
        begin
          var FixedBank := (OuterBank and not 7) or 7;
          if (FRegs[2] and $20) = 0 then
          begin
            OuterBank := OuterBank and not 3;
            FixedBank := OuterBank or (Data and 4) or 3;
          end
          else
            OuterBank := OuterBank and not 7;
          Prg16(0, OuterBank or (Data and 7));
          Prg16(1, FixedBank);
        end;
        Mirror(Latch and 1);
      end;
    MAPPER_BMC_T4IN1:
      begin
        if (Latch and $80) <> 0 then
        begin
          Prg32(((Latch shr 4) and 4) or ((Latch shr 2) and 8) or (Data and 3));
          Mirror(2 + ((Data shr 4) and 1));
        end
        else
        begin
          var OuterBank := ((Latch shr 3) and 8) or ((Latch shr 1) and $10);
          Prg16(0, OuterBank or (Data and 7));
          Prg16(1, OuterBank or 7);
          Mirror((Data shr 4) and 1);
        end;
      end;
    MAPPER_BMC_4705:
      begin
        if (Latch and $10) <> 0 then
        begin
          var OuterBank := (Latch and not 1) shl 3;
          Prg16(0, OuterBank or (Data and 7));
          Prg16(1, OuterBank or 7);
        end
        else
          Prg32((Data shr 1) and 3);
        Mirror((Latch shr 5) and 1);
      end;
    MAPPER_BMC_A23, MAPPER_BMC_K3004:
      begin
        var OuterBank := FResetBank shl 3;
        if FBoard = MAPPER_BMC_A23 then
        begin
          OuterBank := Latch shl 3;
          Mirror(1 - ((Latch shr 2) and 1));
        end;
        Prg16(0, OuterBank or (Data and 7));
        Prg16(1, OuterBank or 7);
      end;
    MAPPER_BMC_63100:
      begin
        var SlotMask := (Latch shr 5) and 3;
        for var Slot := 0 to 3 do
          Prg8(Slot, (Latch and not SlotMask) or (Slot and SlotMask));
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_J2042:
      begin
        if (Latch and $10) <> 0 then
          MapMirroredPrg(Latch shl 1)
        else
          Prg32(Latch);
        Chr8((Latch shl 2) or (Data and 3));
        Mirror((Latch shr 3) and 1);
      end;
    MAPPER_BMC_T124:
      begin
        if (Latch and $0C) = $0C then
          Prg32((Latch and $FF) shr 3)
        else
          MapMirroredPrg((Latch and $FF) shr 2);
        Chr8(((Latch shr 1) and 4) or (Latch and 3));
      end;
    MAPPER_BMC_9135:
      begin
        var Bank := (Latch and $30) or ((Data and 1) shl 3);
        if (Latch and $48) = $48 then
          Prg32((Bank shr 1) or ((Latch shr 1) and 3))
        else if (Latch and 8) <> 0 then
          MapMirroredPrg(Bank or (FRegs[2] and 7))
        else
        begin
          Prg16(0, Bank or (FRegs[2] and 7));
          Prg16(1, Bank or 7);
        end;
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_LB12IN1:
      begin
        var Bank := (Latch and $34) or ((Data and 1) shl 3);
        if (Latch and 8) = 0 then
          Prg32(((Bank shr 1) and $1C) or ((Latch shr 1) and 3))
        else
        begin
          var InnerMask := 7;
          if ((Latch and $20) <> 0) and ((Data and 1) <> 0) then
            InnerMask := 3;
          Bank := Bank and not InnerMask;
          Prg16(0, Bank or (FRegs[2] and InnerMask));
          Prg16(1, Bank or InnerMask);
        end;
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_68IN1:
      begin
        if (Latch and $1000) <> 0 then
          MapMirroredPrg(Latch shr 6)
        else
          Prg32(Latch shr 7);
        Chr8(Latch);
        Mirror((Latch shr 13) and 1);
      end;
    MAPPER_BMC_3945:
      begin
        var Bank := ((Latch shr 2) and 8) or (Latch and 7);
        if (Latch and $10) <> 0 then
          Prg32(Bank shr 1)
        else
          MapMirroredPrg(Bank);
        Chr8(Bank);
        Mirror((Latch shr 3) and 1);
      end;
    MAPPER_BMC_J2083:
      begin
        if (Latch and 8) <> 0 then
        begin
          Prg16(0, Data and $0F);
          Prg16(1, $0F);
        end
        else
          Prg32(Data shr 1);
      end;
    MAPPER_BMC_KL09B:
      begin
        if (Latch and 1) <> 0 then
          MapMirroredPrg((Latch and $FF) shr 1)
        else
          Prg32((Latch and $FF) shr 2);
        Chr8((Latch and $FF) shr 1);
        Mirror(1 - ((Latch shr 4) and 1));
      end;
    MAPPER_BMC_ET20:
      begin
        var Bank := ((Data shr 1) and $40) or ((Latch and 1) shl 5) or (Data and $1F);
        if (Bank and $40) <> 0 then
          Bank := Bank xor $20;
        if (Latch and 8) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank or 7);
        end
        else if (Data and $20) <> 0 then
          MapMirroredPrg(Bank)
        else
          Prg32(Bank shr 1);
        Mirror(1 - ((Data shr 6) and 1));
      end;
    MAPPER_BMC_90IN1:
      begin
        if (Latch and $200) <> 0 then
          Prg32(Latch)
        else
          MapMirroredPrg((Latch shl 1) or ((Latch shr 8) and 1));
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_821134:
      begin
        if (Latch and $40) <> 0 then
          Prg32(Latch shr 3)
        else
          MapMirroredPrg(Latch shr 2);
        Chr8(((Latch shr 1) and $1C) or (Latch and 3));
        Mirror((Latch shr 7) and 1);
      end;
    MAPPER_BMC_GC004:
      begin
        if (Latch and $200) = 0 then
        begin
          Prg16(0, Latch shr 2);
          Prg16(1, (Latch shr 2) or 7);
        end
        else if (Latch and 1) <> 0 then
          MapMirroredPrg(Latch shr 2)
        else
          Prg32(Latch shr 3);
        Chr8(((Latch shr 5) and 3) or ((Latch shr 6) and 4));
        Mirror((Latch shr 1) and 1);
      end;
  end;
end;

function TMapperExtendedDiscrete.NameTableOffset(Address: UInt16): UInt16;
begin
  if FBoard = MAPPER_CONTRA_PIRATE then
    Exit(((FRegs[8 + ((Address shr 10) and 7)] and 1) shl 10) or (Address and $3FF));
  if (FBoard = MAPPER_BMC_N80) and ((FRegs[1] and $C0) = 0) then
    Exit((Address and $3FF) or (Ord((Address and $C00) = $C00) shl 10));
  Result := inherited NameTableOffset(Address);
end;

function TMapperExtendedDiscrete.ConversionRamOffset(Address: UInt16): Integer;
begin
  if FBoard = MAPPER_KAISER_KS7030 then
    case Address of
      $6000..$6BFF:
        Exit(Address - $6000);
      $B800..$BFFF:
        Exit($C00 + Address - $B800);
      $CC00..$D7FF:
        Exit($1400 + Address - $CC00);
    end
  else if FBoard = MAPPER_PALTHENA then
    case Address of
      $6000..$60FF, $6200..$62FF, $6400..$65FF:
        Exit($1800 + (Address and $7FF));
      $8200..$82FF:
        Exit($1200 + (Address and $FF));
      $C000..$D1FF, $DF00..$DFFF:
        Exit(Address and $1FFF);
    end;
  Result := -1;
end;

function TMapperExtendedDiscrete.IsYhcBoard: Boolean;
begin
  Result := (FBoard >= MAPPER_YHC_UNROM) and (FBoard <= MAPPER_YHC_MULTICART);
end;

procedure TMapperExtendedDiscrete.UpdateYhc;
begin
  var Outer := FRegs[0];
  var Mode := FRegs[1];
  var Inner := FRegs[2];
  var Mask := 7;
  if FBoard = MAPPER_YHC_MULTICART then
    Mask := (8 shl ((Mode shr 4) and 3)) - 1;

  if FBoard = MAPPER_YHC_AXROM then
    Prg32((Outer shl 2) + (Inner and 7))
  else if (FBoard = MAPPER_YHC_MULTICART) and ((Mode and 6) <> 0) then
    Prg32((Outer shl 2) + (Inner and (Mask shr 1)))
  else
  begin
    Prg16(0, (Outer shl 3) + (Inner and Mask));
    Prg16(1, (Outer shl 3) + Mask);
  end;
  if (FBoard = MAPPER_YHC_AXROM) or ((FBoard = MAPPER_YHC_MULTICART) and ((Mode and 2) <> 0)) then
    Mirror(2 + ((Inner shr 4) and 1))
  else
    Mirror(1 xor (Mode and 1));
  Chr8(0);
end;

function TMapperExtendedDiscrete.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if IsYhcBoard and ((Address and $F000) = $7000) then
  begin
    Value := FPrgRam[Address and $FFF];
    Exit(True);
  end;
  if (FBoard = MAPPER_SACHEN_89433) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := $60;
    Exit(True);
  end;
  if (FBoard = MAPPER_BMC_K3071) and (FSubmapper = 0) and (Address >= $8000) and
    (FMenuDip <> 0) and ((FRegs[0] and $80) <> 0) then
    Exit(False);
  if (FBoard = MAPPER_LIKO_429) and (Address >= $6000) and (Address < $8000) and (FBoardPrgRamSize <> 0) then
  begin
    Value := FPrgRam[(Address - $6000) mod FBoardPrgRamSize];
    Exit(True);
  end;
  if (FBoard = MAPPER_SACHEN_3013) and ((Address and $C000) = $8000) then
  begin
    Value := $3A;
    Exit(True);
  end;
  case FBoard of
    MAPPER_KAISER_KS7030, MAPPER_PALTHENA:
      begin
        if Address < $6000 then
          Exit(False);
        var Offset := ConversionRamOffset(Address);
        if Offset >= 0 then
        begin
          Value := FPrgRam[Offset];
          Exit(True);
        end;
        if FBoard = MAPPER_PALTHENA then
        begin
          if Address >= $8000 then
            Exit(inherited CpuRead(Address, Value));
          Offset := ($D shl 13) or (Address and $1FFF);
        end
        else
        begin
          var Bank6C00 := $C00;
          var Bank7000 := $10000;
          var BankC000 := 0;
          // The earlier dump interleaves the same switches in a different ROM layout.
          if FKs7030LegacyOrder then
          begin
            Bank6C00 := $8000;
            Bank7000 := 0;
            BankC000 := $8400;
          end;
          case Address of
            $6C00..$6FFF:
              Offset := Bank6C00 + (FRegs[1] shl 12) + (Address and $3FF);
            $7000..$7FFF:
              Offset := Bank7000 + ((FRegs[0] and 7) shl 12) + (Address and $FFF);
            $C000..$CBFF:
              Offset := BankC000 + (FRegs[1] shl 12) + (Address and $FFF);
          else
            Offset := $18000 or (Address and $7FFF);
          end;
        end;
        Value := FPrgRom[Offset mod Length(FPrgRom)];
        Exit(True);
      end;
    MAPPER_KAISER_KS7010:
      // Reads in the ranges used by the game update the bank latch.
      if ((Address >= $CAB6) and (Address <= $CAD7)) or
        ((Address and $FFFE) = $EBE2) or ((Address and $FFFE) = $EE32) or
        ((Address and $FFFE) = $FFFC) then
      begin
        FRegs[0] := (Address shr 2) and $0F;
        Chr8(FRegs[0]);
      end;
  end;
  if (Address >= $6000) and (Address < $8000) then
    case FBoard of
      MAPPER_LUCKY_RABBIT, MAPPER_KAISER_KS7016B, MAPPER_KAISER_KS7010:
        begin
          var Offset := ((FRegs[0] and $F) shl 13) or (Address and $1FFF);
          Value := FPrgRom[Offset mod Length(FPrgRom)];
          Exit(True);
        end;
      MAPPER_SUPER_SOCCER_CHAMPION:
        begin
          var Offset := ((FRegs[0] or 1) shl 13) or (Address and $1FFF);
          Value := FPrgRom[Offset mod Length(FPrgRom)];
          Exit(True);
        end;
      MAPPER_BMC_T215, MAPPER_BMC_821134:
        begin
          if FBoardPrgRamSize = 0 then
            Exit(False);
          Value := FPrgRam[Address and (FBoardPrgRamSize - 1)];
          Exit(True);
        end;
      MAPPER_BMC_ET81:
        begin
          var Bank := (8 or (FRegs[1] and 7)) mod (Length(FPrgRom) div $2000);
          Value := FPrgRom[(Bank shl 13) or (Address and $1FFF)];
          Exit(True);
        end;
    end;
  if Address >= $8000 then
    case FBoard of
      MAPPER_DISCRETE_226:
        // The three-chip CTC-65 leaves the second chip-select combination empty.
        if (Length(FPrgRom) = $180000) and ((FRegs[0] and $80) <> 0) and ((FRegs[1] and 1) = 0) then
          Exit(False);
      MAPPER_BMC_4705:
        if (FRegs[0] and $0C) <> 0 then
          Exit(False);
      MAPPER_BMC_ET133A:
        if ((FRegs[0] and $600) = $200) and (FMenuDip <> 0) then
          Exit(False);
      MAPPER_BMC_KL09B:
        if (FRegs[0] and $20) <> 0 then
          Address := (Address and $FFF0) or UInt16(FMenuDip);
    end;
  if (FBoard = MAPPER_BMC_5068) and (Address >= $8000) and
    ((FRegs[0] and $10) <> 0) and (Length(FPrgRom) > $20000) then
    Exit(False);
  if (FBoard = MAPPER_SACHEN_3014) and ((Address and $F000) = $E000) then
  begin
    inherited CpuRead(Address, Value);
    Value := (Value and $F0) or (FRegs[1] shr 4);
    Exit(True);
  end;
  if (FBoard = MAPPER_BMC_HC001) and (Address >= $8000) and ((FRegs[0] and $100) <> 0) then
    Address := Address and $FFF0; // Default menu solder pads.
  if (FBoard = MAPPER_BMC_K1079) and (Address >= $8000) and ((FRegs[0] and 3) = 3) then
  begin
    Value := FCpuOpenBus and $F8; // Default menu solder pads.
    Exit(True);
  end;
  if FBoard = MAPPER_KEYBYTE_COMPUTER then
  begin
    if (Address >= $6000) and (Address < $8000) then
    begin
      if FBoardPrgRamSize = 0 then
        Exit(False);
      Value := FPrgRam[Address and (FBoardPrgRamSize - 1)];
      Exit(True);
    end;
    if (Address >= $8000) and ((FRegs[1] and 1) <> 0) and (Length(FPrgRom) < $100000) then
      Exit(False);
  end;
  if (FBoard = MAPPER_BMC_9999999IN1) and (Address >= $C000) and MenuPrgDisconnected then
    Exit(False);
  if (FBoard = MAPPER_BMC_J2282) and (Address >= $6000) and (Address < $8000) and
    ((FRegs[0] and $800) <> 0) then
  begin
    var Bank := (((FRegs[0] and $1F) shl 1) or 3) mod (Length(FPrgRom) div $2000);
    Value := FPrgRom[Bank * $2000 + (Address and $1FFF)];
    Exit(True);
  end;
  if (FBoard = MAPPER_TELETUBBIES_420) and (Address >= $8000) and ((FRegs[0] and 1) <> 0) then
  begin
    Value := 0; // Default menu solder pads.
    Exit(True);
  end;
  if (FBoard = MAPPER_SA005A) and (Address >= $8000) then
  begin
    var SelectPins := FRegs[0] and $FF0F;
    if (SelectPins = $F008) or ((SelectPins = $F004) and (Length(FPrgRom) <= $10000)) then
    begin
      Value := 0; // Menu solder pads default to zero.
      Exit(True);
    end;
  end;
  if (FBoard = MAPPER_BMC891227) and (Address >= $8000) and
    ((FRegs[0] and $60) = $60) and (Length(FPrgRom) <= $80000) then
    Exit(False);
  if (FBoard = MAPPER_FAM250) and (Address >= $6000) and (Address < $8000) and
    ((FRegs[0] and 7) = 5) then
  begin
    var Bank := FRegs[2] mod (Length(FPrgRom) div $2000);
    Value := FPrgRom[Bank * $2000 + (Address and $1FFF)];
    Exit(True);
  end;
  if ((FBoard = MAPPER_CTC12IN1) or (FBoard = MAPPER_BMC891227)) and
    (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[$2000 + (Address and $1FFF)];
    Exit(True);
  end;
  if (FBoard = MAPPER_MALEE2) and (Address >= $6000) and (Address < $8000) then
  begin
    if Address < $7000 then
      Value := FPrgRom[$8000 + (Address and $7FF)]
    else
      Value := FPrgRam[Address and $7FF];
    Exit(True);
  end;

  if (FBoard = MAPPER_MULTICART_380) and (Address >= $8000) and
    (FSubmapper = 0) and ((FRegs[0] and $100) <> 0) then
    Address := Address and $FFF0; // All four menu solder pads are off.

  if FBoard = MAPPER_SUPER_GAMES_KING then
  begin
    if (FSubmapper = 1) and (Address >= $5000) and (Address < $6000) then
    begin
      Value := 0;
      Exit(True);
    end;
    if (Address >= $8000) and
      (((FSubmapper = 0) and ((FRegs[0] and $200) <> 0)) or
      ((FSubmapper = 2) and ((FRegs[1] and 1) <> 0))) then
      Address := Address and $FFF0;
  end;
  if (FBoard = MAPPER_YS2309) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := 0; // Menu solder pads default to zero.
    Exit(True);
  end;

  if (FBoard = MAPPER_MULTICART_428) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FCpuOpenBus and $FC; // Two menu DIP switches default to off.
    Exit(True);
  end;

  if (FBoard = MAPPER_LH32) and (Address >= $C000) and (Address < $E000) then
  begin
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;

  if (FBoard = MAPPER_LH32) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(FRegs[0] * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if ((FBoard = MAPPER_GS2004) or (FBoard = MAPPER_KAISER7016)) and (Address >= $6000) and (Address < $8000) then
  begin
    var Bank := FRegs[0];
    if FBoard = MAPPER_GS2004 then
      Bank := $20;
    Value := FPrgRom[(Bank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if ((FBoard = MAPPER_EDU2000) or (FBoard = MAPPER_WAIXING178)) and (Address >= $6000) and (Address < $8000) then
  begin
    var Bank := (FRegs[0] shr 6) and 3;
    if FBoard = MAPPER_WAIXING178 then
      Bank := FRegs[3] and 3;
    Value := FPrgRam[Bank * $2000 + (Address and $1FFF)];
    Exit(True);
  end;

  if (FBoard = MAPPER_RT01) and (((Address >= $CE80) and (Address < $CF00)) or ((Address >= $FE80) and (Address < $FF00))) then
  begin
    Value := $FF;
    Exit(True)
  end;

  if (FBoard = MAPPER_DISCRETE_120) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRom[(FRegs[0] * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (FBoard = MAPPER_SACHEN_143) and (Address >= $4100) and (Address <= $5FFF) then
  begin
    Value := ((not Address) and $3F) or $40;
    Exit(True);
  end;

  if (FBoard = MAPPER_DISCRETE_170) and ((Address = $7001) or (Address = $7777)) then
  begin
    Value := FRegs[0] or ((Address shr 8) and $7F);
    Exit(True);
  end;

  if (FBoard = MAPPER_DISCRETE_216) and (Address = $5000) then
  begin
    Value := 0;
    Exit(True);
  end;

  Result := inherited CpuRead(Address, Value);
end;

function TMapperExtendedDiscrete.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
const
  PrgPerm: array[0..3, 0..3] of Byte = ((0, 1, 2, 3), (3, 2, 1, 0), (0, 2, 1, 3), (3, 1, 2, 0));
  ChrPerm: array[0..7, 0..7] of Byte = (
    (0, 1, 2, 3, 4, 5, 6, 7),
    (0, 2, 1, 3, 4, 6, 5, 7),
    (0, 1, 4, 5, 2, 3, 6, 7),
    (0, 4, 1, 5, 2, 6, 3, 7),
    (0, 4, 2, 6, 1, 5, 3, 7),
    (0, 2, 4, 6, 1, 3, 5, 7),
    (7, 6, 5, 4, 3, 2, 1, 0),
    (7, 6, 5, 4, 3, 2, 1, 0));
var
  Bank, High: Integer;
  Bus: Byte;
begin
  Result := True;

  case FBoard of
    MAPPER_BMC_P3127_01:
      begin
        Result := (Address and $F000) = $7000;
        if Result and ((FRegs[1] and $80) = 0) then
        begin
          FRegs[1] := Value;
          UpdateMulticartLatches;
        end;
        Exit;
      end;
    MAPPER_YHC_UNROM, MAPPER_YHC_AXROM, MAPPER_YHC_MULTICART:
      begin
        case Address of
          $6000..$6FFF:
            if (FRegs[1] and $80) = 0 then
            begin
              FRegs[Address and 1] := Value;
              UpdateYhc;
            end;
          $7000..$7FFF:
            FPrgRam[Address and $FFF] := Value;
          $8000..$FFFF:
            begin
              FRegs[2] := Value;
              UpdateYhc;
            end;
        else
          Exit(False);
        end;
      end;
    MAPPER_SACHEN_89433:
      if (Address and $E100) = $4100 then
      begin
        FRegs[Address and 3] := Value;
        UpdateSachen89433;
      end
      else if Address >= $8000 then
      begin
        if (FRegs[2] and 4) <> 0 then
        begin
          FRegs[1] := Value;
          UpdateSachen89433;
        end;
      end
      else
        Exit(False);
    MAPPER_LIKO_429:
      begin
        if Address < $8000 then
        begin
          if (Address < $6000) or (FBoardPrgRamSize = 0) then
            Exit(False);
          FPrgRam[(Address - $6000) mod FBoardPrgRamSize] := Value;
          Exit(True);
        end;
        FRegs[0] := Value;
        UpdateLiko;
      end;
    MAPPER_BMC_K3071:
      begin
        if Address < $8000 then
          Exit(False);
        FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateK3071;
      end;
    MAPPER_LITTLECOM160:
      begin
        if Address < $C000 then
          Exit(False);
        FRegs[0] := Address and $1FF;
        Bank := (Address and $FF) shr 2;
        if (Address and 2) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Mirror(1 xor (Address and 1) xor (FSubmapper and 1));
        Exit(True);
      end;
    MAPPER_KAISER_KS7030, MAPPER_PALTHENA:
      begin
        var Offset := ConversionRamOffset(Address);
        if Offset >= 0 then
        begin
          FPrgRam[Offset] := Value;
          Exit;
        end;
        if FBoard = MAPPER_KAISER_KS7030 then
          case Address shr 12 of
            8:
              begin
                FRegs[0] := Address and $F;
                Mirror(FRegs[0] shr 3);
                Exit;
              end;
            9:
              begin
                FRegs[1] := Address and $F;
                Exit;
              end;
          end
        else if (Address = $4025) or ((Address and $F000) = $F000) then
        begin
          FRegs[1] := Value and 8;
          Mirror(FRegs[1] shr 3);
          Exit;
        end
        else
          case Address shr 12 of
            $A:
              begin
                FRegs[0] := Value and $F;
                Prg8(1, FRegs[0]);
                Exit;
              end;
          end;
        Exit(False);
      end;
  end;

  // Low-address register decoders are handled before the common ROM decoder.
  case FBoard of
    MAPPER_BMC_T4IN1, MAPPER_BMC_4705, MAPPER_BMC_LB12IN1:
      if (Address >= $6000) and (Address < $8000) then
      begin
        if (FBoard <> MAPPER_BMC_T4IN1) or ((FRegs[0] and $10) = 0) then
        begin
          FRegs[0] := Value;
          if FBoard = MAPPER_BMC_LB12IN1 then
            FRegs[1] := Address and 1;
          UpdateDiscreteMulticart;
        end;
        Exit;
      end;
    MAPPER_BMC_63100:
      if (Address and $E100) = $4100 then
      begin
        FRegs[0] := Value;
        UpdateDiscreteMulticart;
        Exit;
      end;
    MAPPER_BMC_J2042, MAPPER_BMC_J2083:
      if (Address and $F000) = $5000 then
      begin
        if (FBoard = MAPPER_BMC_J2083) or ((FRegs[0] and $20) = 0) then
        begin
          FRegs[0] := Value;
          UpdateDiscreteMulticart;
        end;
        Exit;
      end;
    MAPPER_BMC_T215, MAPPER_BMC_821134:
      if (Address >= $6000) and (Address < $8000) then
      begin
        if FBoardPrgRamSize = 0 then
          Exit(False);
        FPrgRam[Address and (FBoardPrgRamSize - 1)] := Value;
        Exit;
      end;
    MAPPER_BMC_ST32:
      if (Address and $C100) = $4100 then
      begin
        FRegs[(Address shr 13) and 1] := Value;
        UpdateDiscreteMulticart;
        Exit;
      end;
    MAPPER_BMC_0359:
      if (Address >= $5000) and (Address < $6000) then
      begin
        FRegs[0] := Value;
        UpdateAddressMulticart;
        Exit;
      end;
    MAPPER_BMC_YH810X1:
      if (Address and $F010) = $5010 then
      begin
        FRegs[Address and 3] := Value;
        UpdateAddressMulticart;
        Exit;
      end;
    MAPPER_KEYBYTE_COMPUTER:
      case Address of
        $5000..$5FFF:
          begin
            FRegs[(Address shr 11) and 1] := Address and $FF;
            UpdateAddressMulticart;
            Exit;
          end;
        $6000..$7FFF:
          begin
            if FBoardPrgRamSize = 0 then
              Exit(False);
            FPrgRam[Address and (FBoardPrgRamSize - 1)] := Value;
            Exit;
          end;
      end;
    MAPPER_BMC_TH2348:
      if (Address >= $5000) and (Address < $6000) then
      begin
        FRegs[0] := Address and $0F;
        UpdateAddressMulticart;
        Exit;
      end;
    MAPPER_INX_007T:
      if (Address >= $5000) and (Address < $6000) then
      begin
        FRegs[0] := Value;
        UpdateLatchMulticart;
        Exit;
      end;
    MAPPER_MAXIVISION_NTDEC:
      if (Address >= $6000) and (Address < $8000) then
      begin
        FRegs[0] := Value;
        UpdateLatchMulticart;
        Exit;
      end;
    MAPPER_S009, MAPPER_YS2309:
      if (Address >= $6000) and (Address < $8000) then
      begin
        if (FBoard = MAPPER_YS2309) and ((Address and 1) <> 0) then
          FRegs[2] := Value
        else
          FRegs[0] := Value;
        UpdateUxromMulticart;
        Exit;
      end;
    MAPPER_SUPER_GAMES_KING:
      if (FSubmapper = 2) and (Address >= $6000) and (Address < $8000) then
      begin
        FRegs[1] := Value;
        Exit;
      end;
    MAPPER_MALEE2:
      if (Address >= $7000) and (Address < $8000) then
      begin
        FPrgRam[Address and $7FF] := Value;
        Exit;
      end;
    MAPPER_MULTICART_428:
      if (Address >= $6000) and (Address < $8000) then
      begin
        FRegs[Address and 3] := Value;
        UpdateMulticart428;
        Exit;
      end;
    MAPPER_JINGKETAI:
      if (Address >= $4800) and (Address < $5000) then
      begin
        FRegs[Address and 3] := Value;
        Bank := (FRegs[2] shl 3) or (FRegs[1] and 7);
        if (FRegs[0] and 6) = 0 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          case FRegs[0] and 6 of
            2:
              Prg16(1, Bank or 7);
            4:
              Prg16(1, Bank);
            6:
              Prg16(1, Bank or 6);
          end;
        end;
        Chr8(FRegs[3]);
        Exit;
      end;
    MAPPER_WAIXING178:
      begin
        if (Address >= $6000) and (Address < $8000) then
        begin
          FPrgRam[(FRegs[3] and 3) * $2000 + (Address and $1FFF)] := Value;
          Exit
        end;

        if (Address >= $4800) and (Address <= $4FFF) then
        begin
          FRegs[Address and 3] := Value;
          Bank := (FRegs[2] shl 3) or (FRegs[1] and 7);
          if (FRegs[0] and 2) <> 0 then
          begin
            Prg16(0, Bank);
            if (FRegs[0] and 4) <> 0 then
              Prg16(1, (FRegs[2] shl 3) or 6 or (FRegs[1] and 1))
            else
              Prg16(1, (FRegs[2] shl 3) or 7)
          end
          else if (FRegs[0] and 4) <> 0 then
          begin
            Prg16(0, Bank);
            Prg16(1, Bank)
          end
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank + 1)
          end;
          Mirror(FRegs[0] and 1);
          Exit;
        end;
      end;
    MAPPER_DISCRETE_246:
      if (Address >= $6000) and (Address <= $67FF) then
      begin
        if (Address and 7) < 4 then
          Prg8(Address and 3, Value)
        else
          Chr2(Address and 3, Value);
        Exit
      end;
    MAPPER_LH32:
      if Address = $6000 then
      begin
        FRegs[0] := Value;
        Exit
      end
      else if (Address >= $C000) and (Address < $E000) then
      begin
        FPrgRam[Address and $1FFF] := Value;
        Exit
      end;
    MAPPER_KAISER7013_B:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Prg16(0, Value);
        Exit
      end;
    MAPPER_EDU2000:
      if (Address >= $6000) and (Address < $8000) then
      begin
        FPrgRam[((FRegs[0] shr 6) and 3) * $2000 + (Address and $1FFF)] := Value;
        Exit
      end;
    MAPPER_HP898F:
      if (Address and $6000) = $6000 then
      begin
        FRegs[(Address shr 2) and 1] := Value;
        Bank := (FRegs[1] shr 3) and 7;
        High := (FRegs[1] shr 4) and 4;
        Prg16(0, Bank and (not High));
        Prg16(1, Bank or High);
        Chr8(((FRegs[0] shr 4) and 7) and (not (((FRegs[0] and 1) shl 2) or (FRegs[0] and 2))));
        Mirror(1 - ((FRegs[1] shr 7) and 1));
        Exit;
      end;
    MAPPER_UNL_PCI556:
      if (Address >= $7000) and (Address < $8000) then
      begin
        Prg32(Value and 3);
        Chr8((Value shr 2) and 3);
        Exit
      end;
    MAPPER_COLOR_DREAMS_46:
      if Address >= $6000 then
      begin
        if Address < $8000 then
          FRegs[0] := Value
        else
          FRegs[1] := Value;
        Prg32(((FRegs[0] and 15) shl 1) or (FRegs[1] and 1));
        Chr8(((FRegs[0] and $F0) shr 1) or ((FRegs[1] shr 4) and 7));
        Exit;
      end;
    MAPPER_JALECO_JF13:
      if (Address >= $6000) and (Address < $8000) then
      begin
        if Address < $7000 then
        begin
          Prg32((Value shr 4) and 3);
          Chr8((Value and 3) or ((Value shr 4) and 4))
        end;
        Exit;
      end;
    MAPPER_DISCRETE_120:
      if Address = $41FF then
      begin
        FRegs[0] := Value;
        Exit
      end;
    MAPPER_DISCRETE_170:
      if (Address = $6502) or (Address = $7000) then
      begin
        FRegs[0] := (Integer(Value) shl 1) and $80;
        Exit
      end;
    MAPPER_HENGGEDIANZI179:
      if (Address >= $5000) and (Address < $6000) then
      begin
        Prg32(Value shr 1);
        Exit
      end;
    MAPPER_NTDEC_TC112:
      if (Address >= $6000) and (Address < $8000) then
      begin
        case Address and 3 of
          0:
            begin
              Chr2(0, Value shr 1);
              Chr2(1, (Value shr 1) + 1)
            end;
          1:
            Chr2(2, Value shr 1);
          2:
            Chr2(3, Value shr 1);
          3:
            Prg8(0, Value);
        end;
        Exit;
      end;
    MAPPER_DISCRETE_216:
      if Address = $5000 then
      begin
        Prg32(0);
        Chr8(0);
        Exit
      end;
    MAPPER_DREAM_TECH01:
      if Address = $5020 then
      begin
        Prg16(0, Value and 7);
        Exit
      end;
  end;

  if (FBoard = MAPPER_I030_0365) and (Address >= $5000) and (Address < $6000) then
  begin
    FRegs[0] := Value;
    UpdateCtcMulticart;
    Exit;
  end;

  if (FBoard = MAPPER_BMC_631601) and ((Address and $E100) = $4100) then
  begin
    FRegs[0] := Value;
    UpdateMulticartLatches;
    Exit;
  end;

  if (FBoard = MAPPER_P3150) and (FSubmapper = 1) and
    ((Address and $F100) = $4100) then
  begin
    FRegs[0] := Value;
    UpdateMulticartLatches;
    Exit;
  end;

  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));

  case FBoard of
    MAPPER_CONTRA_PIRATE:
      if (Address and $10) <> 0 then
      begin
        var Slot := Address and $0F;
        FRegs[Slot] := Value;
        if Slot < 8 then
          Chr1(Slot, Value);
      end
      else if Address < $E000 then
      begin
        var Slot := (Address - $8000) shr 13;
        FRegs[16 + Slot] := Value;
        Prg8(Slot, Value);
      end
      else
        Exit(False);
    MAPPER_WHIRLWIND_LH42, MAPPER_NTDEC_2718:
      begin
        if (Address and $E000) <> $8000 then
          Exit(False);
        if (Address and 1) = 0 then
          FRegs[8] := Value and 7
        else
          case FRegs[8] of
            5:
              begin
                var Bit := 0;
                if FBoard = MAPPER_NTDEC_2718 then
                  Bit := 5;
                FRegs[5] := (Value shr Bit) and 1;
                Mirror(FRegs[5]);
              end;
            6, 7:
              begin
                FRegs[FRegs[8]] := Value and $F;
                Prg8(FRegs[8] - 6, Value and $F);
              end;
          end;
      end;
    MAPPER_KAISER_KS7021A:
      case Address shr 12 of
        8:
          begin
            FRegs[8] := (Value shr 1) and 7;
            Prg16(0, FRegs[8]);
          end;
        9:
          begin
            FRegs[9] := Value and 1;
            Mirror(FRegs[9]);
          end;
        $B:
          begin
            var Slot := Address and 7;
            FRegs[Slot] := Value and $7F;
            Chr1(Slot, FRegs[Slot]);
          end;
      else
        Exit(False);
      end;
    MAPPER_KAISER_KS7016B:
      FRegs[0] := ((Address shr 2) and $F) or ((Address shr 3) and 4);
    MAPPER_LUCKY_RABBIT:
      begin
        FRegs[0] := Value and $1F;
        Mirror(FRegs[0] shr 4);
      end;
    MAPPER_SUPER_SOCCER_CHAMPION:
      begin
        if (Address and $E000) <> $C000 then
          Exit(False);
        FRegs[0] := Value and $0F;
        if (Value and 9) = 1 then
          Prg8(0, 10)
        else
          Prg8(0, Value and $0E);
      end;
    MAPPER_NTDEC_A9778:
      begin
        FRegs[(Address shr 13) and 3] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_J2061, MAPPER_BMC_T124, MAPPER_BMC_68IN1, MAPPER_BMC_3945, MAPPER_BMC_KL09B, MAPPER_BMC_90IN1, MAPPER_BMC_821134, MAPPER_BMC_GC004:
      begin
        FRegs[0] := Address;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_K3021:
      begin
        FRegs[Value shr 7] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_ET133A:
      begin
        if (FRegs[0] and $4000) = 0 then
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_TX5_8IN1:
      begin
        FRegs[(Address shr 14) and 1] := Value;
        if Address < $C000 then
        begin
          FRegs[2] := Address and $FF;
          FRegs[3] := (Address shr 8) and 1;
        end;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_T4IN1, MAPPER_BMC_4705, MAPPER_BMC_A23, MAPPER_BMC_J2042, MAPPER_BMC_K3004, MAPPER_BMC_J2083:
      begin
        if (FBoard = MAPPER_BMC_A23) and ((Address and $FFF8) = $FF08) then
          FRegs[0] := Address and 7;
        FRegs[1] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_9135, MAPPER_BMC_LB12IN1:
      begin
        if (FBoard = MAPPER_BMC_9135) and (Address < $C000) then
        begin
          FRegs[0] := Value;
          FRegs[1] := Address and 1;
        end
        else
          FRegs[2] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_ET20:
      begin
        if (FRegs[0] and 8) <> 0 then
          FRegs[1] := (FRegs[1] and not 7) or (FPrgRom[PrgOffset(Address)] and 7)
        else
        begin
          FRegs[0] := Address;
          FRegs[1] := Value;
        end;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_T215:
      begin
        if (FRegs[0] and $200) <> 0 then
          FRegs[0] := (FRegs[0] and not $1C) or (Address and $1C)
        else
          FRegs[0] := Address;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_ET156, MAPPER_BMC_FE011, MAPPER_BMC_HN02, MAPPER_BMC_07027:
      begin
        FRegs[0] := Address;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_ET82:
      begin
        if ((FRegs[0] and $20) <> 0) and ((Address and $20) = 0) then
          FRegs[0] := Address
        else
          FRegs[0] := (FRegs[0] and $C0) or (Address and not $C0);
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_8203:
      begin
        if ((FRegs[0] and $80) = 0) and ((Address and $80) <> 0) then
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_K3057:
      begin
        FRegs[Ord((FRegs[0] and $80) <> 0)] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_ET81:
      if Address >= $E000 then
      begin
        FRegs[(Address shr 12) and 1] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_810706, MAPPER_BMC_810706_LEGACY:
      begin
        if ((FRegs[1] and 8) <> 0) and ((Value and 8) = 0) then
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_810430, MAPPER_BMC_J2054:
      begin
        CpuRead(Address, Bus);
        FRegs[1] := Value and Bus;
        UpdateDiscreteMulticart;
      end;
    MAPPER_BMC_BD23:
      begin
        var Mask := 0;
        if (FRegs[1] and $20) <> 0 then
        begin
          Mask := $28;
          if (FRegs[1] and 8) = 0 then
            Mask := $2C;
        end;
        FRegs[1] := (FRegs[1] and Mask) or (Value and not Mask);
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_5068:
      begin
        if (FRegs[0] and $20) <> 0 then
          FRegs[0] := (FRegs[0] and $33) or (Address and not $33)
        else
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_FC40:
      begin
        if (FRegs[0] and $80) <> 0 then
          FRegs[0] := (FRegs[0] and not 3) or (Address and 3)
        else
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_SACHEN_3014:
      begin
        inherited CpuRead(Address, Bus);
        FRegs[1] := Value and Bus;
        UpdateAddressMulticart;
      end;
    MAPPER_NTDEC_15IN1:
      begin
        CpuRead(Address, Bus);
        var Data := Value and Bus;
        if (FRegs[1] and 8) <> 0 then
          Data := (Data and $F0) or (Bus and $0F);
        FRegs[1] := Data;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_K1079, MAPPER_BMC_N80, MAPPER_SANE_TING_5IN1:
      begin
        FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_0359:
      begin
        FRegs[1] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_VQ168, MAPPER_NTDEC_9012, MAPPER_BMC_HC001, MAPPER_BMC_K3069, MAPPER_BMC_CH512K, MAPPER_BMC_W03, MAPPER_BMC_J2096, MAPPER_BMC_KN20:
      begin
        FRegs[0] := Address;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_971107_00G:
      begin
        FRegs[Ord((Address and $E000) <> $A000)] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_ET120:
      begin
        if (FRegs[0] and $200) <> 0 then
          FRegs[1] := Value
        else
          FRegs[0] := Address;
        UpdateAddressMulticart;
      end;
    MAPPER_KEYBYTE_COMPUTER:
      begin
        FRegs[2] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_K3036, MAPPER_BMC_J2282:
      begin
        FRegs[0] := Address;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_5069:
      begin
        if ((FRegs[0] and $10) = 0) and ((Address and $10) <> 0) then
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_CALTRON_9IN1:
      begin
        case Address shr 12 of
          8:
            FRegs[0] := Address and $FF;
          9:
            FRegs[1] := Address and $FF;
        else
          FRegs[2] := Address and $0F;
        end;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_9999999IN1, MAPPER_BMC_TH2348:
      begin
        if CpuRead(Address, Bus) then
          Value := Value and Bus;
        if FBoard = MAPPER_BMC_9999999IN1 then
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_REALTEC_8042:
      begin
        if (FRegs[1] and $E0) <> 0 then
          FRegs[1] := (FRegs[1] and $E0) or (Value and $1F)
        else
          FRegs[1] := Value;
        UpdateAddressMulticart;
      end;
    MAPPER_BMC_ET89:
      begin
        if (FRegs[0] and $100) = 0 then
          FRegs[0] := Address;
        FRegs[1] := Value and 7;
        UpdateAddressMulticart;
      end;
    MAPPER_OK043, MAPPER_NTDEC_2779:
      begin
        FRegs[0] := Address and $FF;
        UpdateMulticartLatches;
      end;
    MAPPER_BMC_09078:
      if (FRegs[1] and $20) = 0 then
      begin
        FRegs[1] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_BMC_K3017:
      begin
        FRegs[0] := Address and $FF;
        FRegs[1] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_NEWSTAR_12IN1:
      begin
        if (Address and $2000) = 0 then
          FRegs[1] := Value;
        if (Address and $4000) = 0 then
          FRegs[0] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_BMC_K1053:
      begin
        if (Address and $4000) = 0 then
          FRegs[1] := Value
        else
        begin
          FRegs[0] := Address and $FF;
          FRegs[2] := Value;
        end;
        UpdateMulticartLatches;
      end;
    MAPPER_BMC_SQ002, MAPPER_BMC_35BH1:
      begin
        if FBoard = MAPPER_BMC_SQ002 then
        begin
          inherited CpuRead(Address, Bus);
          Value := Value and Bus;
        end;
        FRegs[1] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_TELETUBBIES_420:
      begin
        if (FRegs[0] and 2) <> 0 then
          FRegs[1] := (FRegs[1] and $F8) or (Value and 7)
        else
        begin
          FRegs[0] := Address and 7;
          FRegs[1] := Value;
        end;
        UpdateMulticartLatches;
      end;
    MAPPER_MGC026:
      begin
        FRegs[1] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_RESET_NROM256:
      ;
    MAPPER_BMC_631601:
      begin
        FRegs[1] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_SA005A:
      begin
        FRegs[0] := Address;
        UpdateMulticartLatches;
      end;
    MAPPER_BMC891227:
      begin
        if FRegs[2] = 0 then
        begin
          if (Address and $4000) = 0 then
          begin
            FRegs[0] := Value;
            FRegs[2] := Ord((Address and $2000) <> 0);
          end
          else
            FRegs[1] := Value;
          UpdateMulticartLatches;
        end;
      end;
    MAPPER_FAM250:
      if (Address >= $F000) or ((FSubmapper = 1) and (Address >= $E000)) then
      begin
        FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_P3150:
      ;
    MAPPER_MULTICART_375:
      begin
        if (FRegs[0] and $800) = 0 then
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateMulticartLatches;
      end;
    MAPPER_CTC09:
      begin
        if (FRegs[0] and $40) = 0 then
        begin
          FRegs[Ord((Address and $4000) = 0)] := Value;
          UpdateCtcMulticart;
        end;
      end;
    MAPPER_CTC12IN1:
      begin
        if (Address and $4000) = 0 then
          FRegs[0] := (FRegs[0] and 7) or (Value and $F8)
        else
          FRegs[0] := (FRegs[0] and $F8) or (Value and 7);
        UpdateCtcMulticart;
      end;
    MAPPER_TJ03:
      begin
        if (FSubmapper <> 1) or ((Address and $F0) = $A0) then
        begin
          FRegs[0] := Address;
          UpdateCtcMulticart;
        end;
      end;
    MAPPER_BMC830928C, MAPPER_I030_0365, MAPPER_KN42:
      begin
        if FBoard <> MAPPER_KN42 then
        begin
          inherited CpuRead(Address, Bus);
          Value := Value and Bus;
        end;
        if (FBoard = MAPPER_BMC830928C) and ((FRegs[0] and $20) = 0) then
          FRegs[0] := Address;
        FRegs[1] := Value;
        UpdateCtcMulticart;
      end;
    MAPPER_INX_007T, MAPPER_SUBOR_045N, MAPPER_MAXIVISION_NTDEC:
      begin
        if FBoard = MAPPER_MAXIVISION_NTDEC then
        begin
          inherited CpuRead(Address, Bus);
          Value := Value and Bus;
        end;
        FRegs[1] := Value;
        UpdateLatchMulticart;
      end;
    MAPPER_SEALIE_COMPUTING:
      begin
        Prg16(0, (Value shr 2) and 7);
        Chr8(Value and 3)
      end;
    MAPPER_DISCRETE_39, MAPPER_DISCRETE_241:
      Prg32(Value);
    MAPPER_NOVEL_DIAMOND_54, MAPPER_NOVEL_DIAMOND_201:
      begin
        Prg32(Address and 3);
        Chr8(Address and 7)
      end;
    MAPPER_JALECO_JF17, MAPPER_JALECO_JF19:
      begin
        // JF-17/19 clock bank latches on rising data-bit edges, after bus conflicts.
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        if ((FRegs[0] and $80) = 0) and ((Value and $80) <> 0) then
          if FBoard = MAPPER_JALECO_JF17 then
            Prg16(0, Value and 7)
          else
            Prg16(1, Value and 15);
        if ((FRegs[0] and $40) = 0) and ((Value and $40) <> 0) then
          Chr8(Value and 15);
        FRegs[0] := Value;
        WriteJalecoSpeech(Address, Value);
      end;
    MAPPER_KAISER_KS7009:
      if Address < $A000 then
      begin
        FRegs[Address and 7] := Value;
        UpdateNamco;
      end;
    MAPPER_NAMCO_108_76, MAPPER_NAMCO_108_95:
      begin
        if (Address and 1) = 0 then
          FRegs[8] := Value and 7
        else
          FRegs[FRegs[8]] := Value;
        UpdateNamco;
      end;
    MAPPER_IREM_LROG017:
      begin
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        Prg32(Value and 15);
        Chr2(0, Value shr 4)
      end;
    MAPPER_OEKA_KIDS:
      begin
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        Prg32(Value and 3);
        FRegs[0] := Value and 4;
        Chr4(0, FRegs[0] or FRegs[1]);
        Chr4(1, FRegs[0] or 3);
      end;
    MAPPER_SUNSOFT_89:
      begin
        Prg16(0, (Value shr 4) and 7);
        Chr8((Value and 7) or ((Value shr 4) and 8));
        Mirror(2 + ((Value shr 3) and 1))
      end;
    MAPPER_IREM_TAM_S1:
      begin
        Prg16(1, Value and 15);
        Mirror(1 - ((Value shr 7) and 1))
      end;
    MAPPER_GOLDEN_FIVE:
      begin
        if Address >= $C000 then
        begin
          FRegs[0] := (FRegs[0] and $F0) or (Value and 15);
          Prg16(0, FRegs[0])
        end
        else if (Address < $A000) and ((Value and 8) <> 0) then
        begin
          FRegs[0] := (FRegs[0] and 15) or ((Integer(Value) shl 4) and $70);
          Prg16(0, FRegs[0]);
          Prg16(1, ((Integer(Value) shl 4) and $70) or 15)
        end;
      end;
    MAPPER_DISCRETE_107:
      begin
        Prg32(Value shr 1);
        Chr8(Value)
      end;
    MAPPER_SACHEN_149:
      Chr8(Value shr 7);
    MAPPER_DAOU_INFOSYS:
      if (Address >= $C000) and (Address <= $C014) then
      begin
        if Address <= $C00F then
        begin
          Bank := (Address and 3) + Ord(Address >= $C008) * 4;
          if (Address and 4) <> 0 then
            FRegs[Bank + 8] := Value
          else
            FRegs[Bank] := Value;
          for var i := 0 to 7 do
            Chr1(i, (FRegs[i + 8] shl 8) or FRegs[i]);
        end
        else if Address = $C010 then
          Prg16(0, Value)
        else if Address = $C014 then
          Mirror(Value and 1);
      end;
    MAPPER_SUBOR166:
      begin
        FRegs[(Address shr 13) and 3] := Value;
        High := ((FRegs[0] xor FRegs[1]) and $10) shl 1;
        Bank := (FRegs[2] xor FRegs[3]) and 31;
        if (FRegs[1] and 8) <> 0 then
          Prg32((High or Bank) shr 1)
        else if (FRegs[1] and 4) <> 0 then
        begin
          Prg16(0, 31);
          Prg16(1, High or Bank)
        end
        else
        begin
          Prg16(0, High or Bank);
          Prg16(1, 7)
        end;
      end;
    MAPPER_KAISER7058:
      begin
        // CPU A0 selects the independent 4 KiB CHR window throughout $8000-$FFFF.
        FRegs[Address and 1] := Value;
        Chr4(Address and 1, Value)
      end;
    MAPPER_JY043:
      Chr4(Address and 1, Value and 7);
    MAPPER_YY850437C:
      begin
        var OuterWrite := (Address and $E000) = $A000;
        if FSubmapper = 3 then
          OuterWrite := Address < $C000;
        FRegs[Ord(not OuterWrite)] := Value;
        UpdateUxromMulticart;
      end;
    MAPPER_S009:
      begin
        inherited CpuRead(Address, Bus);
        FRegs[1] := (Value and Bus) and 7;
        UpdateUxromMulticart;
      end;
    MAPPER_YS2309:
      begin
        var Hold := (FRegs[2] and $80) or ((FRegs[2] shr 1) and $38);
        FRegs[1] := (FRegs[1] and Hold) or (Value and not Hold);
        UpdateUxromMulticart;
      end;
    MAPPER_NC20MB:
      begin
        FRegs[0] := Value;
        Bank := Value and $1F;
        if (Value and $20) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        Mirror((Value shr 6) and 1);
      end;
    MAPPER_F1002, MAPPER_SUPER_GAMES_KING:
      begin
        FRegs[0] := Address;
        var Nrom := (Address and $200) <> 0;
        var Mirror16 := (Address and 1) <> 0;
        Bank := ((Address shr 2) and $1F) or ((Address shr 3) and $20);
        if FBoard = MAPPER_SUPER_GAMES_KING then
        begin
          Nrom := (Address and $80) <> 0;
          Mirror16 := not Mirror16;
          Chr8(Value and 3);
        end
        else
          Bank := Bank or ((Address shr 4) and $40);
        if Nrom and not Mirror16 then
          Prg32(Bank shr 1)
        else
        begin
          Prg16(0, Bank);
          if Nrom then
            Prg16(1, Bank)
          else
            Prg16(1, Bank or 7);
        end;
        Mirror((Address shr 1) and 1);
      end;
    MAPPER_MULTICART_380:
      begin
        FRegs[0] := Address;
        Bank := (Address shr 2) and $1F;
        if (Address and $200) = 0 then
        begin
          Prg16(0, Bank);
          High := Bank or 7;
          if (FSubmapper = 1) and ((Address and $100) <> 0) then
            High := High or 8;
          Prg16(1, High);
        end
        else if (Address and 1) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank);
        end
        else
          Prg32(Bank shr 1);
        if FSubmapper = 2 then
          Mirror((Address shr 6) and 1)
        else
          Mirror((Address shr 1) and 1);
      end;
    MAPPER_MULTICART_428:
      begin
        FRegs[4] := Value;
        UpdateMulticart428;
      end;
    MAPPER_HENGGEDIANZI177:
      begin
        Prg32(Value);
        Mirror((Value shr 5) and 1)
      end;
    MAPPER_CNROM_PROTECT:
      begin
        inherited CpuRead(Address, Bus);
        Value := Value and Bus;
        if FSubmapper = 0 then
          FRegs[0] := Ord(((Value and 15) <> 0) and (Value <> $13))
        else
          FRegs[0] := Ord((Value and 3) = (FSubmapper - 4));
      end;
    MAPPER_HENGGEDIANZI179:
      Mirror(Value and 1);
    MAPPER_DISCRETE_203:
      begin
        Prg16(0, Value shr 2);
        Prg16(1, Value shr 2);
        Chr8(Value and 3)
      end;
    MAPPER_DISCRETE_214:
      begin
        Prg16(0, (Address shr 2) and 3);
        Prg16(1, (Address shr 2) and 3);
        Chr8(Address and 3)
      end;
    MAPPER_DISCRETE_216:
      begin
        Prg32(Address and 1);
        Chr8((Address shr 1) and 7)
      end;
    MAPPER_DISCRETE_225:
      begin
        High := (Address shr 8) and $40;
        Bank := ((Address shr 6) and $3F) or High;
        if (Address and $1000) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Chr8((Address and $3F) or High);
        Mirror((Address shr 13) and 1);
      end;
    MAPPER_DISCRETE_226, MAPPER_DISCRETE_233:
      begin
        FRegs[Address and 1] := Value;
        Bank := FRegs[0] and $1F;
        if FBoard = MAPPER_DISCRETE_233 then
          Bank := Bank or (FResetBank shl 5) or ((FRegs[1] and 1) shl 6)
        else if Length(FPrgRom) = $180000 then
          // Chip selects 0, 2 and 3 address the three successive ROM chunks.
          Bank := Bank or ((FRegs[1] and 1) shl (5 + ((FRegs[0] shr 7) and 1)))
        else
          Bank := Bank or ((FRegs[0] and $80) shr 2) or ((FRegs[1] and 1) shl 6);
        if (FRegs[0] and $20) <> 0 then
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end
        else
          Prg32(Bank shr 1);
        Mirror(1 - ((FRegs[0] shr 6) and 1));
      end;
    MAPPER_DISCRETE_227:
      begin
        Bank := ((Address shr 2) and $1F) or ((Address and $100) shr 3);
        if (Address and $80) <> 0 then
          if (Address and 1) <> 0 then
            Prg32(Bank shr 1)
          else
          begin
            Prg16(0, Bank);
            Prg16(1, Bank)
          end
        else
        begin
          Prg16(0, Bank and ($3F - (Address and 1)));
          if (Address and $200) <> 0 then
            Prg16(1, Bank or 7)
          else
            Prg16(1, Bank and $38);
        end;
        Mirror((Address shr 1) and 1);
      end;
    MAPPER_DISCRETE_229:
      begin
        Chr8(Address and $FF);
        if (Address and $1E) = 0 then
          Prg32(0)
        else
        begin
          Prg16(0, Address and $1F);
          Prg16(1, Address and $1F)
        end;
        Mirror((Address shr 5) and 1);
      end;
    MAPPER_DISCRETE_231:
      begin
        Bank := ((Address shr 5) and 1) or (Address and $1E);
        Prg16(0, Bank and $1E);
        Prg16(1, Bank);
        Mirror((Address shr 7) and 1)
      end;
    MAPPER_DISCRETE_244:
      if (Value and 8) <> 0 then
        Chr8(ChrPerm[(Value shr 4) and 7, Value and 7])
      else
        Prg32(PrgPerm[(Value shr 4) and 3, Value and 3]);
    MAPPER_GS2004:
      Prg32(Value and 7);
    MAPPER_A65_AS:
      begin
        if (Value and $40) <> 0 then
          Prg32((Value and $1E) shr 1)
        else
        begin
          Prg16(0, ((Value and $30) shr 1) or (Value and 7));
          Prg16(1, ((Value and $30) shr 1) or 7)
        end;
        if (Value and $80) <> 0 then
          Mirror(2 + ((Value shr 5) and 1))
        else
          Mirror((Value shr 3) and 1);
      end;
    MAPPER_BMC11160:
      begin
        Bank := (Value shr 4) and 7;
        Prg32(Bank);
        Chr8((Bank shl 2) or (Value and 3));
        Mirror(1 - (Value shr 7))
      end;
    MAPPER_BMC190IN1:
      begin
        Bank := (Value shr 2) and 7;
        Prg16(0, Bank);
        Prg16(1, Bank);
        Chr8(Bank);
        Mirror(Value and 1)
      end;
    MAPPER_BMC8157:
      begin
        Bank := ((Address shr 5) and 3) * 8 + ((Address shr 8) and 1) * 64;
        High := ((Address shr 7) and 1) or ((Address shr 8) and 2);
        var Inner := (Address shr 2) and 7;
        Prg16(0, Bank or Inner);
        if High = 0 then
          Prg16(1, Bank)
        else if High = 1 then
          Prg16(1, Bank or Inner)
        else
          Prg16(1, Bank or 7);
        Mirror((Address shr 1) and 1);
      end;
    MAPPER_KAISER7016:
      case Address and $D943 of
        $D943:
          if (Address and $30) = $30 then
            FRegs[0] := 11
          else
            FRegs[0] := (Address shr 2) and 15;
        $D903:
          if (Address and $30) = $30 then
            FRegs[0] := 8 or ((Address shr 2) and 3)
          else
            FRegs[0] := 11;
      end;
    MAPPER_LH51:
      case Address and $E000 of
        $8000:
          Prg8(0, Value and 15);
        $E000:
          Mirror((Value shr 3) and 1)
      end;
    MAPPER_KAISER7013_B:
      Mirror(Value and 1);
    MAPPER_EDU2000:
      begin
        FRegs[0] := Value;
        Prg32(Value and 31)
      end;
    MAPPER_BMC_K3046:
      begin
        Prg16(0, Value and $3F);
        Prg16(1, (Value and $38) or 7)
      end;
    MAPPER_KAISER7012:
      case Address of
        $E0A0:
          Prg32(0);
        $EE36:
          Prg32(1)
      end;
  else
    Exit(False);
  end;
end;

procedure TMapperExtendedDiscrete.UpdateSachen89433;
begin
  if (FRegs[2] and 1) <> 0 then
  begin
    Prg16(0, (FRegs[0] shr 1) and $3F);
    Prg16(1, (FRegs[0] shr 1) and $3F);
  end
  else
    Prg32((FRegs[0] shr 2) and $1F);
  Chr8(FRegs[1] and 3);
  Mirror((FRegs[2] shr 4) and 1);
end;

procedure TMapperExtendedDiscrete.UpdateLiko;
begin
  var Latch := FRegs[0];
  Prg32(Latch shr 2);
  if FSubmapper = 2 then
    Chr8((Latch and 3) or (4 * Ord((Latch and $0C) = $0C)))
  else
    Chr8(Latch);
  if FSubmapper = 1 then
    Mirror(2 + (Latch shr 7));
end;

procedure TMapperExtendedDiscrete.UpdateK3071;
begin
  var MenuMask := $7FFF;
  if FSubmapper = 1 then
    MenuMask := (Length(FPrgRom) - $20001) shr 14;

  if FResetBank <> 0 then
  begin
    var UnromBase := MenuMask + 1;
    Prg16(0, UnromBase or (FRegs[1] and 7));
    Prg16(1, UnromBase or 7);
    Mirror(0);
    Exit;
  end;

  if (FRegs[0] and 1) <> 0 then
    Prg32((FRegs[0] shr 2) and (MenuMask shr 1))
  else
  begin
    var Bank := (FRegs[0] shr 1) and MenuMask;
    Prg16(0, Bank);
    Prg16(1, Bank);
  end;
  Chr8(FRegs[1] shr 1);
  Mirror(FRegs[1] and 1);
end;

procedure TMapperExtendedDiscrete.UpdateNamco;
begin
  var PrgMask := $3F;
  if FBoard = MAPPER_KAISER_KS7009 then
    PrgMask := $0F;
  Prg8(0, FRegs[6] and PrgMask);
  Prg8(1, FRegs[7] and PrgMask);
  if FBoard = MAPPER_NAMCO_108_76 then
    for var i := 0 to 3 do
      Chr2(i, FRegs[i + 2] and $3F)
  else
  begin
    Chr2(0, (FRegs[0] and $3F) shr 1);
    Chr2(1, (FRegs[1] and $3F) shr 1);
    for var i := 4 to 7 do
      Chr1(i, FRegs[i - 2] and $3F);
  end;
end;

function TMapperExtendedDiscrete.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_BMC_K3071) and (FResetBank <> 0) and (Address < $2000) then
  begin
    Value := FExtraRam[Address];
    Exit(True);
  end;
  if (FBoard = MAPPER_BMC_ET133A) and (Address < $2000) and ((FRegs[0] and $400) = 0) then
  begin
    Value := FExtraRam[Address];
    Exit(True);
  end;

  if (FBoard = MAPPER_NAMCO_108_95) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[((FRegs[(Address shr 11) and 1] shr 5) and 1) * $400 + (Address and $3FF)];
    Exit(True)
  end;

  if (FBoard = MAPPER_IREM_LROG017) and (Address >= $800) and (Address < $2000) then
  begin
    Value := FExtraRam[Address - $800];
    Exit(True)
  end;

  if (FBoard = MAPPER_CNROM_PROTECT) and (FRegs[0] = 0) and (Address < $2000) then
  begin
    Value := 1;
    Exit(True)
  end;

  Result := inherited PpuRead(Address, Value);
end;

function TMapperExtendedDiscrete.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $2000 then
    case FBoard of
      MAPPER_BMC_K3071:
        if FResetBank <> 0 then
        begin
          FExtraRam[Address] := Value;
          Exit(True);
        end;
      MAPPER_SACHEN_89433:
        // Mighty Bomb Jack relies on retaining pattern data in horizontal mode.
        if (FRegs[2] and $10) <> 0 then
          Exit(True);
    end;
  if (FBoard = MAPPER_MULTICART_380) and (Address < $2000) and
    ((FRegs[0] and $80) <> 0) then
    Exit(True);

  if Address < $2000 then
    case FBoard of
      MAPPER_LITTLECOM160:
        if (FSubmapper = 1) and ((FRegs[0] and $100) <> 0) then
          Exit(True);
      MAPPER_BMC_ET133A:
        begin
          if (FRegs[0] and $400) = 0 then
            FExtraRam[Address] := Value;
          Exit(True);
        end;
      MAPPER_BMC_T215:
        if (FRegs[0] and $80) <> 0 then
          Exit(True);
      MAPPER_BMC_K3036, MAPPER_BMC_ET82:
        if (FRegs[0] and $20) <> 0 then
          Exit(True);
      MAPPER_BMC_J2282:
        if (FRegs[0] and $400) = 0 then
          Exit(True);
      MAPPER_BMC_ET89:
        if (FRegs[0] and $80) <> 0 then
          Exit(True);
      MAPPER_BMC_K1053:
        if ((FRegs[0] and 3) = 0) or ((FRegs[0] and 3) = 3) then
          Exit(True);
      MAPPER_BMC_K3017:
        if (FResetBank = 0) and ((FRegs[0] and $80) <> 0) then
          Exit(True);
      MAPPER_FAM250:
        if (FRegs[0] and 8) <> 0 then
          Exit(True);
      MAPPER_MULTICART_375:
        if (FRegs[0] and $80) <> 0 then
          Exit(True);
      MAPPER_BMC891227:
        if (FRegs[0] and $40) = 0 then
          Exit(True);
      MAPPER_CTC12IN1:
        if (FRegs[0] and $80) = 0 then
          Exit(True);
      MAPPER_NC20MB:
        if (FRegs[0] and $80) = 0 then
          Exit(True);
      MAPPER_F1002:
        if (FRegs[0] and $800) <> 0 then
          Exit(True);
      MAPPER_SUPER_GAMES_KING:
        if (FSubmapper = 0) and ((FRegs[0] and $80) <> 0) then
          Exit(True);
    end;

  if (FBoard = MAPPER_NAMCO_108_95) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[((FRegs[(Address shr 11) and 1] shr 5) and 1) * $400 + (Address and $3FF)] := Value;
    Exit(True)
  end;

  if (FBoard = MAPPER_IREM_LROG017) and (Address >= $800) and (Address < $2000) then
  begin
    FExtraRam[Address - $800] := Value;
    Exit(True)
  end;

  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperGameinis.Reset;
begin
  inherited;
  FIrEnabled := True;
  FIrPending := False;
end;

procedure TMapperGameinis.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version >= 35 then
  begin
    State.Field(FIrEnabled, SizeOf(FIrEnabled));
    State.Field(FIrPending, SizeOf(FIrPending));
  end
  else if State.Loading then
  begin
    FIrEnabled := True;
    FIrPending := False;
  end;
end;

procedure TMapperExtendedDiscrete.WriteJalecoSpeech(Address: UInt16; Value: UInt8);
begin
end;

constructor TMapperJalecoJfSpeech.Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; const SpeechRom: TArray<Byte>);
begin
  FSpeech := TJalecoSpeech.Create(SpeechRom);
  inherited Create(Board, Prg, Chr, HasChrRam, MirrorMode, Submapper);
end;

destructor TMapperJalecoJfSpeech.Destroy;
begin
  FSpeech.Free;
  inherited;
end;

procedure TMapperJalecoJfSpeech.Reset;
begin
  inherited;
  FSpeech.Reset(False);
end;

procedure TMapperJalecoJfSpeech.SetRegion(Region: TNesRegion);
begin
  FSpeech.SetRegion(Region);
end;

procedure TMapperJalecoJfSpeech.WriteJalecoSpeech(Address: UInt16; Value: UInt8);
begin
  FSpeech.WritePins(Address and 31, (Value and $20) <> 0, (Value and $10) = 0);
end;

procedure TMapperJalecoJfSpeech.ClockCpu;
begin
  FSpeech.Clock;
end;

function TMapperJalecoJfSpeech.ExpansionAudio: Double;
begin
  Result := FSpeech.Output;
end;

procedure TMapperJalecoJfSpeech.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version >= 39 then
    FSpeech.SerializeState(State)
  else if State.Loading then
    FSpeech.Reset((FRegs[0] and $20) <> 0);
end;

procedure TMapperGameinis.SetInfraredInput(Active, FallingEdge: Boolean);
begin
  FIrLevel := Active;
  // The cartridge's edge detector responds when exposure to the IR LED ends.
  if FallingEdge and FIrEnabled then
    FIrPending := True;
end;

function TMapperGameinis.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := (Address >= $5000) and (Address < $6000);
  if Result then
    Value := (FCpuOpenBus and $FE) or Byte(Ord(FIrLevel));
end;

function TMapperGameinis.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $5000) and (Address < $8000) then
    Exit(CpuPeek(Address, Value));

  Result := inherited CpuRead(Address, Value);
end;

function TMapperGameinis.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    FIrEnabled := (Value and $80) <> 0;
    if not FIrEnabled then
      FIrPending := False;
    Exit(True);
  end;

  Result := inherited CpuWrite(Address, Value);
end;

function TMapperGameinis.IrqPending: Boolean;
begin
  Result := FIrPending;
end;

procedure TMapper178SolderPad.PowerOn;
begin
  FStarted := False;
  FPadIndex := 0;
  inherited;
end;

procedure TMapper178SolderPad.Reset;
begin
  // A console reset is the host control for selecting the next pair of pads.
  if FStarted then
    FPadIndex := (FPadIndex + 1) and 3;
  inherited;
  FPadReadEnabled := False;
end;

procedure TMapper178SolderPad.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version >= 36 then
  begin
    State.Field(FPadIndex, SizeOf(FPadIndex));
    State.Field(FPadReadEnabled, SizeOf(FPadReadEnabled));
  end
  else if State.Loading then
  begin
    FPadIndex := 0;
    FPadReadEnabled := False;
  end;
end;

function TMapper178SolderPad.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address >= $8000;
  if Result then
  begin
    // The pads replace PRG address lines A0 and A1 in readout mode.
    if FPadReadEnabled then
      Address := (Address and $FFFC) or (FPadIndex and 3);
    Value := FPrgRom[PrgOffset(Address)];
  end;
end;

function TMapper178SolderPad.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    FPadReadEnabled := (Value and 1) <> 0;
    Exit(True);
  end;
  Result := inherited CpuWrite(Address, Value);
end;

constructor TMapperPeLpc.Create(Board: Integer; const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  FSpeech := TPeLpcSpeech.Create;
  inherited Create(Board, Prg, Chr, HasChrRam, MirrorMode, Submapper);
  FWorkRamSize := Length(FPrgRam);
end;

destructor TMapperPeLpc.Destroy;
begin
  FSpeech.Free;
  inherited;
end;

procedure TMapperPeLpc.ConfigureWorkRam(Size: UInt64);
begin
  if (Size > UInt64(Length(FPrgRam))) or ((Size <> 0) and ((Size and (Size - 1)) <> 0)) then
    raise ENesException.Create('Unsupported PE-LPC cartridge RAM size');
  FWorkRamSize := Integer(Size);
end;

function TMapperPeLpc.WorkRamOffset(Address: UInt16): Integer;
begin
  var Bank := 0;
  if FBoard = MAPPER_WAIXING178 then
    Bank := FRegs[3] and 3;
  Result := ((Bank shl 13) or (Address and $1FFF)) and (FWorkRamSize - 1);
end;

procedure TMapperPeLpc.Reset;
begin
  inherited;
  FSpeech.Reset;
end;

procedure TMapperPeLpc.SetRegion(Region: TNesRegion);
begin
  FSpeech.SetCpuFrequency(CpuFrequency(Region));
end;

procedure TMapperPeLpc.ClockCpu;
begin
  FSpeech.Clock;
end;

function TMapperPeLpc.ExpansionAudio: Double;
begin
  Result := FSpeech.Output;
end;

procedure TMapperPeLpc.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version >= 37 then
    State.SharedFields(FSpeech.SerializeState)
  else if State.Loading then
    FSpeech.Reset;
end;

function TMapperPeLpc.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := (Address and $F000) = $5000;
  if Result then
    Value := (FCpuOpenBus and $BF) or (Ord(FSpeech.Ready) shl 6);
end;

function TMapperPeLpc.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $8000 then
  begin
    Value := FPrgRom[PrgOffset(Address)];
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    Result := FWorkRamSize <> 0;
    if Result then
      Value := FPrgRam[WorkRamOffset(Address)];
    Exit;
  end;
  Result := CpuPeek(Address, Value);
end;

function TMapperPeLpc.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address shr 12 of
    5:
      begin
        case Value and $50 of
          0:
            FSpeech.Reset;
          $50:
            FSpeech.WriteNibble(Value);
        end;
        Exit(True);
      end;
    6, 7:
      begin
        Result := FWorkRamSize <> 0;
        if Result then
          FPrgRam[WorkRamOffset(Address)] := Value;
        Exit;
      end;
  end;
  Result := inherited CpuWrite(Address, Value);
end;

constructor TMapperRcm452.Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FSubmapper := Submapper;
  FHasChrRam := True;
  Reset;
end;

procedure TMapperRcm452.Reset;
begin
  inherited;
  FRamEnabled := False;
  if FSubmapper = 1 then
    LatchDs916(0)
  else
    LatchDs927(0, 0);
end;

procedure TMapperRcm452.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRamSlots, SizeOf(FRamSlots));
end;

procedure TMapperRcm452.LatchDs927(Address: UInt16; Value: UInt8);
begin
  var RamSlot := (Value shr 4) and 3;
  FRamSlots := 1 shl RamSlot;
  if (Value and 2) <> 0 then
  begin
    for var Slot := 0 to 3 do
      Prg8(Slot, (Address shr 1) and $FF);
    FRamSlots := FRamSlots or (1 shl (RamSlot xor 2));
  end
  else if (Value and 8) <> 0 then
  begin
    var Bank := (Address shr 1) and $FE;
    Prg8(0, Bank);
    Prg8(1, Bank or 1);
    Prg8(2, Bank or 2);
    Prg8(3, Bank or 3 or (Value and 4) or (8 * Ord((Value and $44) = $44)));
  end
  else
  begin
    Prg16(0, (Address shr 2) and $7F);
    Prg16(1, 0);
  end;
  Mirror(Value and 1);
end;

procedure TMapperRcm452.LatchDs916(Address: UInt16);
begin
  var Bank := Address shr 1;
  var RamSlot := (Address shr 9) and 3;
  FRamSlots := 1 shl RamSlot;
  case Address and $F000 of
    $A000:
      begin
        Prg16(0, Bank);
        Prg8(2, 0);
      end;
    $C000:
      begin
        Prg16(0, Bank);
        Prg16(1, Bank or 1);
      end;
    $D000:
      begin
        for var Slot := 0 to 3 do
          Prg8(Slot, Address);
        FRamSlots := FRamSlots or (1 shl (RamSlot xor 2));
      end;
    $E000:
      begin
        Prg16(0, Bank);
        if (Address and $100) <> 0 then
          Prg16(1, Bank or 7)
        else
          Prg16(1, 0);
      end;
  else
    FRamSlots := 0;
    Prg16(0, Bank);
    Prg16(1, 0);
  end;
  Mirror((Address shr 11) and 1);
end;

function TMapperRcm452.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $8000) and ((FRamSlots and (1 shl ((Address - $8000) shr 13))) <> 0) then
  begin
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperRcm452.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(False);
  if (FRamSlots and (1 shl ((Address - $8000) shr 13))) <> 0 then
    FPrgRam[Address and $1FFF] := Value
  else if FSubmapper = 1 then
  begin
    if Address >= $A000 then
      LatchDs916(Address);
  end
  else if Address < $E000 then
    LatchDs927(Address, Value);
  Result := True;
end;

procedure TMapperExtendedDiscrete.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if FBoard <> MAPPER_OEKA_KIDS then
    Exit;

  if ((FRegs[2] and $3000) <> $2000) and ((Address and $3000) = $2000) then
  begin
    FRegs[1] := (Address shr 8) and 3;
    Chr4(0, FRegs[0] or FRegs[1]);
    Chr4(1, FRegs[0] or 3)
  end;
  FRegs[2] := Address;
end;

constructor TMapperN46.Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  PowerOn;
end;

procedure TMapperN46.PowerOn;
begin
  FillChar(FPrgRegisters, SizeOf(FPrgRegisters), 0);
  FillChar(FChrRegisters, SizeOf(FChrRegisters), 0);
  FillChar(FSelected, SizeOf(FSelected), 1);
  Reset;
end;

procedure TMapperN46.Reset;
begin
  inherited;
  // This mapper routes CIRAM itself so a latch can change only after the read.
  FillChar(FNameRam, SizeOf(FNameRam), 0);
  FRamEnabled := False;
  for var Slot := 0 to High(FPrgRegisters) do
    Prg8(Slot, FPrgRegisters[Slot]);
  Prg8(3, -1);
  UpdatePatternBank(0);
  UpdatePatternBank(1);
end;

procedure TMapperN46.UpdatePatternBank(Slot: Integer);
begin
  Chr4(Slot, FChrRegisters[Slot * 2 + FSelected[Slot]] and $1F);
end;

function TMapperN46.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(False);
  if Address < $E000 then
  begin
    var Slot := (Address - $8000) shr 13;
    FPrgRegisters[Slot] := Value and $0F;
    Prg8(Slot, FPrgRegisters[Slot]);
  end
  else
  begin
    var RegisterIndex := (Address shr 10) and 3;
    FChrRegisters[RegisterIndex] := Value;
    UpdatePatternBank(RegisterIndex shr 1);
  end;
  Result := True;
end;

function TMapperN46.NameTableOffset(Address: UInt16): UInt16;
begin
  var Slot := (Address shr 12) and 1;
  var Page := (Address shr 10) and 3;
  var Arrangement := FChrRegisters[Slot * 2 + FSelected[Slot]] shr 6;
  case Arrangement of
    0:
      Page := Ord(Page = 3);
    1:
      Page := Page shr 1;
    2:
      Page := Page and 1;
    3:
      Page := 1;
  end;
  Result := UInt16((Page shl 10) or (Address and $3FF));
end;

function TMapperN46.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[NameTableOffset(Address)];
    Exit(True);
  end;
  Result := inherited PpuRead(Address, Value);
end;

function TMapperN46.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  // Complete the read using the old bank. The new latch also changes CIRAM routing.
  Result := PpuPeek(Address, False, Value, False);
  var Tile := Address and $0FF0;
  if Result and ((Tile = $0FD0) or (Tile = $0FE0)) then
  begin
    var Slot := (Address shr 12) and 1;
    FSelected[Slot] := Ord(Tile = $0FE0);
    UpdatePatternBank(Slot);
  end;
end;

function TMapperN46.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[NameTableOffset(Address)] := Value;
    Exit(True);
  end;
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperN46.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgRegisters, SizeOf(FPrgRegisters));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FNameRam, SizeOf(FNameRam));
end;

constructor TMapperSuborLogo.Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  SetLength(FChrMemory, $8000);
  FHasChrRam := True;
  Reset;
end;

procedure TMapperSuborLogo.UpdatePatternBank;
begin
  if ((FControl and 2) <> 0) and (((FControl and 1) = 0) or (FNameBlock <> 3)) then
    Chr4(1, FNameBlock + 2)
  else
    Chr4(1, 1);
end;

procedure TMapperSuborLogo.Reset;
begin
  inherited;
  Prg32(0);
  FControl := 0;
  FNameBlock := 0;
end;

function TMapperSuborLogo.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));
  FControl := Value and 3;
  UpdatePatternBank;
  Result := True;
end;

function TMapperSuborLogo.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3000) and ((Address and $FF) = 0) then
  begin
    FNameBlock := (Address shr 8) and 3;
    UpdatePatternBank;
  end;
  Result := inherited PpuRead(Address, Value);
end;

function TMapperSuborLogo.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := inherited PpuRead(Address, Value);
end;

procedure TMapperSuborLogo.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FControl, SizeOf(FControl));
  State.Field(FNameBlock, SizeOf(FNameBlock));
end;

constructor TMapperCeBasic.Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FSubmapper := Submapper;
  Reset;
end;

procedure TMapperCeBasic.Reset;
begin
  inherited;
  FMode := 1;
  FTileBank := 0;
  FillChar(FShadow, SizeOf(FShadow), 0);
  Prg32(FMode);
  Mirror(0);
end;

function TMapperCeBasic.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));
  FMode := FMode xor 1;
  Prg32(FMode);
  Result := True;
end;

function TMapperCeBasic.ReadPattern(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $2000 then
    Exit(False);

  var Offset: Integer;
  if FSubmapper = 1 then
  begin
    if (FMode = 0) or ((FTileBank and $C0) = 0) then
      Exit(inherited PpuRead(Address, Value));
    if (FTileBank and ($80 shr Ord((Address and 8) <> 0))) = 0 then
    begin
      Value := 0;
      Exit(True);
    end;
    Offset := ((FTileBank and $1F) shl 12) or (Address and $0FF0) or
      ((FTileBank and $20) shr 2) or (Address and 7);
  end
  else
  begin
    var TileBase := ((Address and $0FF0) shr 1) or (Address and 7);
    if FMode = 0 then
      Offset := ((Address and 8) shl 13) or TileBase
    else
      Offset := ((FTileBank and $3F) shl 11) or TileBase;
  end;
  Value := FChrMemory[Offset mod Length(FChrMemory)];
  Result := True;
end;

function TMapperCeBasic.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) and ((Address and $3FF) < $3C0) then
    FTileBank := FShadow[Address and $3FF];
  Result := ReadPattern(Address, Value);
end;

function TMapperCeBasic.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := ReadPattern(Address, Value);
end;

function TMapperCeBasic.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  // The cartridge shadow RAM receives the same write as the right CIRAM page.
  if (Address >= $2000) and (Address < $3F00) and ((Address and $400) <> 0) then
    FShadow[Address and $3FF] := Value;
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperCeBasic.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FMode, SizeOf(FMode));
  State.Field(FTileBank, SizeOf(FTileBank));
  State.Field(FShadow, SizeOf(FShadow));
end;

procedure TMapperSuborKaraoke.Reset;
begin
  inherited;
  FLatch := 0;
  FNametableBank := 0;
  Prg32(0);
  Chr8(0);
  Mirror(0);
end;

procedure TMapperSuborKaraoke.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FNametableBank, SizeOf(FNametableBank));
end;

procedure TMapperSuborKaraoke.UpdateLowerChr;
begin
  if (FLatch and $80) <> 0 then
    Chr4(0, FNametableBank)
  else
    Chr4(0, 0);
end;

function TMapperSuborKaraoke.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));
  FLatch := Value;
  Prg32(FLatch and $3F);
  Mirror((FLatch shr 6) and 1);
  UpdateLowerChr;
  Result := True;
end;

function TMapperSuborKaraoke.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if ((FLatch and $80) <> 0) and ((Address and $3000) = $2000) and
    ((Address and $3FF) < $3C0) then
  begin
    // In this mode CIRAM A10 drives the low pattern table's CHR A12.
    FNametableBank := (Address shr (10 + ((FLatch shr 6) and 1))) and 1;
    UpdateLowerChr;
  end;
  Result := inherited PpuRead(Address, Value);
end;

function TMapperSuborKaraoke.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := inherited PpuRead(Address, Value);
end;

function TMapperSuborKaraoke.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address < $1000) and ((FLatch and $80) <> 0) then
  begin
    FChrMemory[Address] := Value;
    Exit(True);
  end;
  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperKaraokeMicrophone.SetMicrophoneLevel(Level: Byte);
begin
  if Level > 63 then
    Level := 63;
  FMicrophoneLevel := Level;
end;

procedure TMapperKkachiKaraoke.PowerOn;
begin
  FPrgLatch := 0;
  inherited;
end;

procedure TMapperKkachiKaraoke.Reset;
begin
  inherited;
  FRamEnabled := False;
  Prg16(0, FPrgLatch);
  FAdcPhase := 0;
  FHighPulses := 0;
  FLowPulses := 0;
end;

procedure TMapperKkachiKaraoke.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgLatch, SizeOf(FPrgLatch));
  State.Field(FHighPulses, SizeOf(FHighPulses));
  State.Field(FLowPulses, SizeOf(FLowPulses));
  State.Field(FAdcPhase, SizeOf(FAdcPhase));
end;

function TMapperKkachiKaraoke.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address and $F000) <> $6000 then
    Exit(False);
  if Address = $6000 then
    Value := Ord((FAdcPhase = 1) or ((FAdcPhase = 2) and (FLowPulses <> 0)))
  else
    Value := Ord(FHighPulses = 0);
  Result := True;
end;

function TMapperKkachiKaraoke.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if not CpuPeek(Address, Value) then
    Exit(inherited CpuRead(Address, Value));
  if Address = $6000 then
    case FAdcPhase of
      0, 1:
        Inc(FAdcPhase);
      2:
        if FLowPulses <> 0 then
          Dec(FLowPulses)
        else
          FAdcPhase := 0;
    end
  else if FHighPulses <> 0 then
    Dec(FHighPulses);
  Result := True;
end;

function TMapperKkachiKaraoke.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(False);
  if Address < $9000 then
  begin
    // The ADC reports the coarse part on $6001 and a pulse train on $6000.
    FHighPulses := FMicrophoneLevel shr 2;
    FLowPulses := $40 - FHighPulses - ((FMicrophoneLevel and 3) shl 2);
    FAdcPhase := 0;
  end;
  FPrgLatch := Value;
  Prg16(0, FPrgLatch);
  Result := True;
end;

const
  NORAEBANG_OPLL_CLOCK = 3579545;

constructor TMapperFamilyNoraebang.Create(const Prg, Chr: NES.Types.TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  if (Length(Prg) < $100000) or ((Length(Prg) and $3FFF) <> 0) then
    raise ENesException.Create('Mapper 515 requires a 1 MiB internal ROM');
  FOpll := TYM2413.Create(NORAEBANG_OPLL_CLOCK);
  SetRegion(TNesRegion.NTSC);
  PowerOn;
end;

destructor TMapperFamilyNoraebang.Destroy;
begin
  FOpll.Free;
  inherited;
end;

procedure TMapperFamilyNoraebang.PowerOn;
begin
  FPrgLatch := 0;
  inherited;
end;

procedure TMapperFamilyNoraebang.Reset;
begin
  inherited;
  FRamEnabled := False;
  UpdateBank;
  FAdcShift := 0;
  FAdcPreamble := 0;
  FAdcOutput := 0;
  FAdcSelected := False;
  FAdcClockHigh := False;
  FNativePhase := 0;
  FOutput := 0;
  FOpll.Reset;
end;

procedure TMapperFamilyNoraebang.UpdateBank;
begin
  var ExternalBanks := (Length(FPrgRom) - $100000) shr 14;
  if (FPrgLatch and $80) <> 0 then
    Prg16(0, ExternalBanks + (FPrgLatch and $3F))
  else if ExternalBanks <> 0 then
    Prg16(0, (FPrgLatch and $7F) mod ExternalBanks);
end;

procedure TMapperFamilyNoraebang.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgLatch, SizeOf(FPrgLatch));
  State.Field(FAdcShift, SizeOf(FAdcShift));
  State.Field(FAdcPreamble, SizeOf(FAdcPreamble));
  State.Field(FAdcOutput, SizeOf(FAdcOutput));
  State.Field(FAdcSelected, SizeOf(FAdcSelected));
  State.Field(FAdcClockHigh, SizeOf(FAdcClockHigh));
  State.Field(FNativePhase, SizeOf(FNativePhase));
  State.Field(FOutput, SizeOf(FOutput));
  State.SharedFields(
    procedure(Archive: TStateArchive)
    begin
      FOpll.SerializeState(Archive);
    end);
end;

procedure TMapperFamilyNoraebang.SetRegion(Region: TNesRegion);
begin
  FNativePeriod := CpuFrequency(Region) * 72;
end;

procedure TMapperFamilyNoraebang.ClockCpu;
begin
  Inc(FNativePhase, NORAEBANG_OPLL_CLOCK);
  if FNativePhase >= FNativePeriod then
  begin
    Dec(FNativePhase, FNativePeriod);
    FOutput := FOpll.GenerateNative;
  end;
end;

function TMapperFamilyNoraebang.ExpansionAudio: Double;
begin
  Result := FOutput / 32768.0;
end;

function TMapperFamilyNoraebang.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := FAdcSelected and ((Address and $E003) = $6003);
  if Result then
    Value := (FCpuOpenBus and $7F) or FAdcOutput;
end;

function TMapperFamilyNoraebang.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if CpuPeek(Address, Value) then
    Exit(True);
  if (Address >= $8000) and (Address < $C000) and (Length(FPrgRom) = $100000) and
    ((FPrgLatch and $80) = 0) then
    Exit(False);
  Result := inherited CpuRead(Address, Value);
end;

procedure TMapperFamilyNoraebang.ClockAdc(HighLevel: Boolean);
begin
  if FAdcSelected and FAdcClockHigh and not HighLevel then
    if FAdcPreamble > 0 then
      Dec(FAdcPreamble)
    else
    begin
      FAdcOutput := FAdcShift and $80;
      FAdcShift := (FAdcShift shl 1) and $FF;
    end;
  FAdcClockHigh := HighLevel;
end;

function TMapperFamilyNoraebang.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address and $E003 of
    $6000, $6001:
      begin
        FOpll.WritePort(Address and 1, Value);
        Exit(True);
      end;
    $C002:
      begin
        var Selected := (Value and $80) = 0;
        if Selected and not FAdcSelected then
        begin
          FAdcShift := FMicrophoneLevel;
          // The original firmware sends three setup clocks before the result.
          FAdcPreamble := 3;
          FAdcOutput := 0;
        end;
        FAdcSelected := Selected;
        Exit(True);
      end;
    $C003:
      begin
        ClockAdc((Value and $80) <> 0);
        Exit(True);
      end;
  end;
  Result := (Address and $E00F) = $8000;
  if Result then
  begin
    FPrgLatch := Value;
    UpdateBank;
  end;
end;

end.

