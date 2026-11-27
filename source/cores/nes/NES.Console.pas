unit NES.Console;

interface

uses
  Core.Microphone, Core.Storage, System.SysUtils, System.Classes, NES.State,
  NES.Types, NES.CPU, NES.PPU, NES.APU, NES.Bus, NES.Cartridge, NES.Controller,
  Core.InputConfig, NES.FamicomKeyboardDevice, NES.FamicomDataRecorder,
  NES.MiraclePianoDevice, NES.DiskSystem, NES.Options, NES.Mapper.Yuxing,
  NES.Mapper.Xmas, NES.Mapper.ExtendedMemory, NES.Mapper.OneBus,
  NES.Mapper.Um6578;

type
  TNesConsole = class
  private
    FCpu: TCpu6502;
    FPpu: TPpu;
    FApu: TApu;
    FBus: TNesBus;
    FCartridge: TCartridge;
    FStorage: IStorage;
    FController1: TController;
    FController2: TController;
    FController3: TController;
    FController4: TController;
    FSuborKeyboard: TSuborKeyboard;
    FFamicomKeyboard: TFamicomKeyboard;
    FDataRecorder: TFamicomDataRecorder;
    FZapper: TZapper;
    FMiraclePiano: TMiraclePianoDevice;
    FCpuCycles: UInt64;
    FPalPpuPhase: Integer;
    FVt369: TMapperOneBus;
    FSuborSb2000: TMapperSuborSb2000;
    FVt369PpuPhase, FVt369ApuPhase: Integer;
    FRegion: TNesRegion;
    FConfiguredFourScore: Boolean;
    FPortsConfigured: Boolean;
    FInputPorts: TCoreInputPorts;
    FDmcDmaCycles: Integer;
    FMapperHasCpuClock, FMapperHasCpuBus, FMapperUsesCpuAddress, FMapperHasIrq, FMapperHasAudio, FHasUmDma: Boolean;
    FMapperIrqAfterCpuAccess: Boolean;
    FFdsProtectionConfigured, FFdsWriteProtected: Boolean;
    FMicrophone: IMicrophoneSource;
    procedure SerializeState(Stream: TStream; Loading: Boolean; Version: Integer = NES_SNAPSHOT_VERSION; LegacyMapper: Integer = -1);
    procedure UpdateKaraokeMicrophone;
    procedure ResetMachine(ColdStart: Boolean);
    function GetRomIdentity: string;
    function GetUsesMiraclePiano: Boolean;
    function GetUsesPowerPad: Boolean;
    function GetHasCoinAcceptor: Boolean;
  public
    constructor Create(FourScoreEnabled: Boolean = False; const Storage: IStorage = nil);
    destructor Destroy; override;
    procedure LoadRom(const FileName: string; RegionOverride: TRegionOverride = TRegionOverride.Auto; Mmc3IrqRevision: TMmc3IrqRevision = TMmc3IrqRevision.Auto); overload;
    procedure LoadRom(Stream: TStream; const RomName: string; RegionOverride: TRegionOverride = TRegionOverride.Auto; Mmc3IrqRevision: TMmc3IrqRevision = TMmc3IrqRevision.Auto); overload;
    procedure ConfigureInputPorts(const Ports: TCoreInputPorts);
    function SetFcnsHostKey(Code: UInt32; Pressed: Boolean): Boolean;
    procedure ClearFcnsInput;
    function UsesFcnsController: Boolean;
    function UsesGameinisInfrared: Boolean;
    procedure SetGameinisInfrared(Active, FallingEdge: Boolean);
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
    procedure LoadBattery(const DirectoryName: string);
    procedure SaveBattery;
    function DiskSystem: TMapperFds;
    function PcFloppy: TYuxingFloppy;
    function XmasPanel: TMapperXmas;
    procedure ConfigureDiskSystem(const BiosFile: string; WriteProtected: Boolean);
    procedure SetDiskWriteProtection(Value: Boolean);
    procedure ConfigureOptions(const Options: TNesOptions);
    procedure OpenDisk(const FileName, SaveDirectory: string);
    procedure SaveSnapshot(const FileName: string; const AchievementProgress: TBytes = nil);
    procedure LoadSnapshot(const FileName: string); overload;
    procedure LoadSnapshot(const FileName: string; out AchievementProgress: TBytes); overload;
    function AchievementROM: TBytes;
    function ReadAchievementMemory(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
    property RomIdentity: string read GetRomIdentity;
    property UsesPowerPad: Boolean read GetUsesPowerPad;
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Reset;
    procedure Clock;
    function UsesKaraokeMicrophone: Boolean;
    procedure SetMicrophoneSource(const Source: IMicrophoneSource);
    procedure RunFrame;
    procedure CheckCpuState;
    function HasCartridge: Boolean;
    function DebugCpuRead(Address: UInt16): UInt8;
    function SenarioLcdLine(Line: Integer): string;
    procedure DebugWriteRam(Address: UInt16; Value: UInt8);
    property Cpu: TCpu6502 read FCpu;
    property Ppu: TPpu read FPpu;
    property Apu: TApu read FApu;
    property Region: TNesRegion read FRegion;
    property Controller1: TController read FController1;
    property Controller2: TController read FController2;
    property Controller3: TController read FController3;
    property Controller4: TController read FController4;
    property SuborKeyboard: TSuborKeyboard read FSuborKeyboard;
    property FamicomKeyboard: TFamicomKeyboard read FFamicomKeyboard;
    property DataRecorder: TFamicomDataRecorder read FDataRecorder;
    property UsesMiraclePiano: Boolean read GetUsesMiraclePiano;
    property MiraclePiano: TMiraclePianoDevice read FMiraclePiano;
    property Zapper: TZapper read FZapper;
  end;

implementation

uses
  System.Hash, System.IOUtils, System.Math, System.UITypes, NES.Mapper,
  NES.Mapper.GameDoctor, NES.Mapper.SuperGameMega, NES.Mapper.Discrete,
  NES.Mapper.ExtendedDiscrete, NES.Mapper.Mmc3Variants, NES.Mapper.Mmc5,
  NES.Mapper.Fcns, NES.Mapper.Rambo, NES.Consts, NES.Mapper.Vrc, NES.Mapper.Nrom,
  NES.Mapper.MagicCard, Core.Snapshots;

const
  SNAPSHOT_MAGIC: array[0..7] of AnsiChar = ('R', 'E', 'T', 'R', 'O', 'M', 'U', 'L');

type
  TSnapshotHeader = packed record
    Magic: array[0..7] of AnsiChar;
    Version, PayloadSize: UInt32;
    MapperId: Integer;
    RomHash: array[0..63] of AnsiChar;
    Digest: array[0..31] of Byte;
    Region: Byte;
  end;

function TNesConsole.GetRomIdentity: string;
begin
  Result := FCartridge.RomIdentity;
end;

function TNesConsole.GetHasCoinAcceptor: Boolean;
begin
  Result := FBus.HasCoinAcceptor;
end;

procedure TNesConsole.InsertCoin1;
begin
  FBus.InsertCoin1;
end;

procedure TNesConsole.InsertCoin2;
begin
  FBus.InsertCoin2;
end;

function TNesConsole.GetUsesMiraclePiano: Boolean;
begin
  Result := FMiraclePiano.Connected;
end;

function TNesConsole.GetUsesPowerPad: Boolean;
begin
  Result := FController2.PowerPadEnabled or (FBus.FamilyTrainer <> TFamilyTrainerMode.ftDisconnected);
end;

procedure TNesConsole.SerializeState(Stream: TStream; Loading: Boolean; Version: Integer; LegacyMapper: Integer);
begin
  var State := TNesStateArchive.Create(Stream, Loading, Version);
  try
    State.Field(FCpuCycles, SizeOf(FCpuCycles));
    State.Field(FPalPpuPhase, SizeOf(FPalPpuPhase));
    if FVt369 <> nil then
    begin
      State.Field(FVt369PpuPhase, SizeOf(FVt369PpuPhase));
      State.Field(FVt369ApuPhase, SizeOf(FVt369ApuPhase));
    end;
    State.Field(FDmcDmaCycles, SizeOf(FDmcDmaCycles));
    FCpu.SerializeState(State);
    FPpu.SerializeState(State);
    FApu.SerializeState(State);
    FBus.SerializeState(State);
    FController1.SerializeState(State);
    FController2.SerializeState(State);
    FController3.SerializeState(State);
    FController4.SerializeState(State);
    if (LegacyMapper >= 0) and (FCartridge.Mapper is TMapperMagicCard) then
      TMapperMagicCard(FCartridge.Mapper).LoadLegacyState(State, LegacyMapper)
    else if (LegacyMapper >= 0) and (FCartridge.MapperId = MAPPER_NROM) then
      TMapperNrom(FCartridge.Mapper).LoadLegacyState(State, LegacyMapper)
    else if (LegacyMapper = MAPPER_MMC3) and (FCartridge.MapperId = MAPPER_MMC3_245) then
      TMapperMmc3Variant(FCartridge.Mapper).LoadLegacyMmc3State(State)
    else
      case LegacyMapper of
        MAPPER_CNROM:
          TMapperDiscrete(FCartridge.Mapper).LoadLegacyCnromState(State);
        MAPPER_UXROM:
          TMapperDiscrete(FCartridge.Mapper).LoadLegacyUxromState(State);
      else
        FCartridge.Mapper.SerializeState(State);
      end;
    if Loading and (Version < MMC5_SCANLINE_STATE_VERSION) and (FCartridge.Mapper is TMapperMmc5) then
      TMapperMmc5(FCartridge.Mapper).RestoreLegacyScanline(FPpu.Scanline, FPpu.DebugMask);
    if Version >= 4 then
      FZapper.SerializeState(State)
    else if Loading then
      FZapper.Reset;
    FBus.SerializeDataBus(State);
    if Version >= 5 then
    begin
      // Identical PRG/CHR hashes can have different NES 2.0 board wiring.
      var Submapper := FCartridge.Metadata.Submapper;
      State.Field(Submapper, SizeOf(Submapper));
      if Loading then
      begin
        if not FCartridge.MatchesSnapshotSubmapper(Submapper, Version) then
          raise ENesException.Create('Snapshot belongs to a different NES 2.0 submapper');
        if (Submapper = 0) and (FCartridge.MapperId = MAPPER_VRC2B_VRC4E) and
          (FCartridge.Metadata.Submapper = 3) then
          TMapperVrc(FCartridge.Mapper).RestoreLegacyVrc2BitLatch;
      end;
    end;
    FApu.SerializeDmaState(State);
    FBus.SerializeCoins(State);
    if Version >= 12 then
      FFamicomKeyboard.SerializeState(State)
    else if Loading then
    begin
      FFamicomKeyboard.Clear;
      FFamicomKeyboard.Reset;
    end;
    if Version >= 13 then
      FDataRecorder.SerializeState(State)
    else if Loading then
      FDataRecorder.Reset(True);
    if Version >= 16 then
      FMiraclePiano.SerializeState(State)
    else if Loading then
      FMiraclePiano.Reset;
    FBus.SerializeFamilyTrainer(State);
  finally
    State.Free;
  end;
end;

procedure TransferAchievementProgress(Stream: TStream; Loading: Boolean; var Progress: TBytes);
begin
  var State := TStateArchive.Create(Stream, Loading);
  try
    State.OptionalBytes(Progress, 16 * 1024 * 1024);
  finally
    State.Free;
  end;
end;

procedure TNesConsole.SaveSnapshot(const FileName: string; const AchievementProgress: TBytes);
begin
  if not HasCartridge then
    raise ENesException.Create('No game loaded');

  var Payload := TMemoryStream.Create;
  var Output := TMemoryStream.Create;
  try
    var Header := Default(TSnapshotHeader);
    Move(SNAPSHOT_MAGIC, Header.Magic, SizeOf(Header.Magic));
    Header.Version := NES_SNAPSHOT_VERSION;
    // Keep snapshots without RA progress readable by older RetroMul versions.
    if (Header.Version = NES_ACHIEVEMENT_STATE_VERSION) and (Length(AchievementProgress) = 0) then
      Header.Version := MMC3_FCEUX_STATE_VERSION;
    SerializeState(Payload, False, Header.Version);
    if Length(AchievementProgress) <> 0 then
    begin
      var Progress := AchievementProgress;
      TransferAchievementProgress(Payload, False, Progress);
    end;
    Header.MapperId := FCartridge.MapperId;
    Header.PayloadSize := Payload.Size;
    Header.Region := Ord(FRegion);
    var Identity := AnsiString(RomIdentity);
    Move(Identity[1], Header.RomHash[0], Length(Identity));
    Payload.Position := 0;
    var Digest := THashSHA2.GetHashBytes(Payload);
    Move(Digest[0], Header.Digest[0], SizeOf(Header.Digest));
    Output.WriteBuffer(Header, SizeOf(Header));
    Output.WriteBuffer(Payload.Memory^, Payload.Size);
    FStorage.EnsureFolder(ExtractFilePath(ExpandFileName(FileName)));
    var Id: TGUID;
    CreateGUID(Id);
    var Temporary := FileName + '.' + GUIDToString(Id) + '.tmp';
    var PreviewName := ChangeFileExt(FileName, '.png');
    var PreviewTemporary := ChangeFileExt(Temporary, '.png');
    try
      FStorage.WriteAtomic(Temporary, Output);
      if FPpu.WideFrameReady then
      begin
        var WideFrame := FPpu.WideFrame;
        SaveSnapshotPreview(Temporary, VT389_WIDTH, VT389_HEIGHT, VT389_WIDTH, @WideFrame[0], FStorage);
      end
      else
      begin
        var Pixels: TArray<TAlphaColor>;
        CopyNesFrameRows(FPpu.Frame, Pixels, 0, 0, NES_WIDTH, NES_HEIGHT);
        SaveSnapshotPreview(Temporary, NES_WIDTH, NES_HEIGHT, NES_WIDTH, @Pixels[0], FStorage);
      end;
      FStorage.Replace(PreviewTemporary, PreviewName);
      FStorage.Replace(Temporary, FileName);
    finally
      FStorage.Delete(Temporary);
      FStorage.Delete(PreviewTemporary);
    end;
  finally
    Output.Free;
    Payload.Free;
  end;
end;

procedure TNesConsole.LoadSnapshot(const FileName: string);
begin
  var AchievementProgress: TBytes;
  LoadSnapshot(FileName, AchievementProgress);
end;

procedure TNesConsole.LoadSnapshot(const FileName: string; out AchievementProgress: TBytes);
begin
  AchievementProgress := nil;
  if not HasCartridge then
    raise ENesException.Create('No game loaded');

  var Input := FStorage.OpenRead(FileName);
  var Payload := TMemoryStream.Create;
  var Backup := TMemoryStream.Create;
  try
    var Header: TSnapshotHeader;
    Input.ReadBuffer(Header, SizeOf(Header));
    var LegacyMapper := -1;
    if (Header.MapperId <> FCartridge.MapperId) and FCartridge.CanMigrateSnapshotMapper(Header.MapperId) then
      LegacyMapper := Header.MapperId;
    var Identity: AnsiString;
    SetString(Identity, PAnsiChar(@Header.RomHash[0]), Length(RomIdentity));
    if not CompareMem(@Header.Magic, @SNAPSHOT_MAGIC, SizeOf(SNAPSHOT_MAGIC)) or
      ((Header.Version < 2) or (Header.Version > NES_SNAPSHOT_VERSION)) or
      ((Header.MapperId <> FCartridge.MapperId) and (LegacyMapper = -1)) or
      (Integer(Header.Region) <> Ord(FRegion)) or
      not FCartridge.MatchesSnapshotIdentity(string(Identity), Header.Version) or
      (Header.PayloadSize > UInt32(64 * 1024 * 1024)) or
      (Int64(Header.PayloadSize) <> Input.Size - Input.Position) then
      raise ENesException.Create('Snapshot is incompatible with this game or region');

    if Header.PayloadSize = 0 then
      raise ENesException.Create('Empty snapshot');

    Payload.CopyFrom(Input, Header.PayloadSize);
    Payload.Position := 0;
    var Digest := THashSHA2.GetHashBytes(Payload);
    if not CompareMem(@Digest[0], @Header.Digest[0], SizeOf(Header.Digest)) then
      raise ENesException.Create('Snapshot checksum mismatch');

    SerializeState(Backup, False);
    try
      Payload.Position := 0;
      SerializeState(Payload, True, Header.Version, LegacyMapper);
      if Header.Version >= NES_ACHIEVEMENT_STATE_VERSION then
        TransferAchievementProgress(Payload, True, AchievementProgress);
      if Payload.Position <> Payload.Size then
        raise ENesException.Create('Unexpected snapshot data');
      // Explicit host connections take priority over devices in older saves.
      // Automatic ports still follow the restored state.
      if FPortsConfigured then
        ConfigureInputPorts(FInputPorts);
      if FFdsProtectionConfigured then
        SetDiskWriteProtection(FFdsWriteProtected);
    except
      // A failed load must leave the running game completely unchanged.
      Backup.Position := 0;
      SerializeState(Backup, True);
      raise;
    end;
  finally
    Backup.Free;
    Payload.Free;
    Input.Free;
  end;
end;

constructor TNesConsole.Create(FourScoreEnabled: Boolean; const Storage: IStorage);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FCpu := TCpu6502.Create;
  FPpu := TPpu.Create;
  FApu := TApu.Create;
  FBus := TNesBus.Create;
  FBus.TimedIo := True;
  FCartridge := TCartridge.Create;
  FCartridge.Storage := FStorage;
  FController1 := TController.Create;
  FController2 := TController.Create;
  FController3 := TController.Create;
  FController4 := TController.Create;
  FSuborKeyboard := TSuborKeyboard.Create;
  FFamicomKeyboard := TFamicomKeyboard.Create;
  FDataRecorder := TFamicomDataRecorder.Create;
  FDataRecorder.Storage := FStorage;
  FBus.DataRecorder := FDataRecorder;
  FMiraclePiano := TMiraclePianoDevice.Create;
  FBus.MiraclePiano := FMiraclePiano;
  FZapper := TZapper.Create;
  FBus.Zapper := FZapper;
  FConfiguredFourScore := FourScoreEnabled;
  FController2.PowerPadEnabled := False;
  FBus.FourScoreEnabled := FourScoreEnabled;
  FBus.Connect(FCartridge, FPpu, FApu, FController1, FController2,
    FController3, FController4, FSuborKeyboard, FFamicomKeyboard);
  FCpu.Connect(FBus.CpuRead, FBus.CpuWrite);
end;

destructor TNesConsole.Destroy;
begin
  FMiraclePiano.Free;
  FZapper.Free;
  FSuborKeyboard.Free;
  FFamicomKeyboard.Free;
  FDataRecorder.Free;
  FController4.Free;
  FController3.Free;
  FController2.Free;
  FController1.Free;
  FCartridge.Free;
  FBus.Free;
  FApu.Free;
  FPpu.Free;
  FCpu.Free;
  inherited Destroy;
end;

function FamilyTrainerMode(ExpansionDevice: Byte): TFamilyTrainerMode;
begin
  case ExpansionDevice of
    $0D, $1A:
      Result := TFamilyTrainerMode.ftSideA;
    $0E:
      Result := TFamilyTrainerMode.ftSideB;
  else
    Result := TFamilyTrainerMode.ftDisconnected;
  end;
end;

procedure TNesConsole.ConfigureInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPorts := Ports;
  FBus.DisconnectedPads := 0;
  for var I := 0 to 3 do
    if Ports.Devices[I] = 'none' then
      FBus.DisconnectedPads := FBus.DisconnectedPads or (1 shl I);
  if Ports.Devices[0] <> 'auto' then
    FMiraclePiano.Connected := Ports.Devices[0] = 'piano';
  if Ports.Devices[1] <> 'auto' then
  begin
    FController2.PowerPadEnabled := Ports.Devices[1] = 'powerpad';
    FZapper.Enabled := Ports.Devices[1] = 'zapper';
  end;
  if Ports.Expansion <> 'auto' then
  begin
    FSuborKeyboard.Connected := FSuborKeyboard.MemoryMapped or (Ports.Expansion = 'subor');
    FFamicomKeyboard.Connected := Ports.Expansion = 'famicom';
    if Ports.Expansion = 'family-trainer-a' then
      FBus.FamilyTrainer := TFamilyTrainerMode.ftSideA
    else if Ports.Expansion = 'family-trainer-b' then
      FBus.FamilyTrainer := TFamilyTrainerMode.ftSideB
    else
      FBus.FamilyTrainer := TFamilyTrainerMode.ftDisconnected;
    FDataRecorder.Connected := (Ports.Expansion = 'recorder') or FFamicomKeyboard.Connected or
      (FBus.TapeOnMapper and (Ports.Expansion = 'subor'));
  end;
  // The gun occupies port 2; Four Score and parallel port devices cannot share it.
  if FZapper.Enabled then
  begin
    FController2.PowerPadEnabled := False;
    FBus.FamilyTrainer := TFamilyTrainerMode.ftDisconnected;
    FMiraclePiano.Connected := False;
  end;
  FBus.FourScoreEnabled := FConfiguredFourScore and not UsesPowerPad
    and not FMiraclePiano.Connected and not FZapper.Enabled;
  FPortsConfigured := True;
end;

procedure TNesConsole.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  // Finish a recording before changing any connections. A failed write leaves
  // the old devices attached so the caller can retry without losing the tape.
  var KeepRecorder := (Ports.Expansion = 'recorder') or (Ports.Expansion = 'famicom') or
    (FBus.TapeOnMapper and (Ports.Expansion = 'subor')) or
    ((Ports.Expansion = 'auto') and (FBus.TapeOnMapper or
    (FCartridge.Metadata.DefaultExpansionDevice in [$20, $23])));
  if FDataRecorder.Connected and not KeepRecorder then
    FDataRecorder.Stop;
  // Resolve Automatic from this cartridge each time, not from the device
  // that occupied the socket before the user selected Automatic.
  FConfiguredFourScore := Ports.FourScore;
  FMiraclePiano.Connected := FCartridge.Metadata.DefaultExpansionDevice = $19;
  FController2.PowerPadEnabled := FCartridge.Metadata.DefaultExpansionDevice in [11, 12];
  FZapper.Enabled := (Ports.Devices[1] = 'auto') and
    (Ports.LegacyZapper or (FCartridge.Metadata.DefaultExpansionDevice in [7, 8, $2F]));
  FFamicomKeyboard.Connected := FCartridge.Metadata.DefaultExpansionDevice = $23;
  FSuborKeyboard.Connected := FSuborKeyboard.MemoryMapped or
    (FCartridge.Metadata.DefaultExpansionDevice = $26) or (FSuborKeyboard.Model <> TNesKeyboardModel.Subor) or
    ((FCartridge.MapperId = MAPPER_SUBOR) and not FFamicomKeyboard.Connected);
  FDataRecorder.Connected := FBus.TapeOnMapper or (FCartridge.Metadata.DefaultExpansionDevice in [$20, $23]);
  var Resolved := Ports;
  if Resolved.Devices[0] = 'auto' then
    if FMiraclePiano.Connected then
      Resolved.Devices[0] := 'piano'
    else
      Resolved.Devices[0] := 'pad';
  if Resolved.Devices[1] = 'auto' then
    if FZapper.Enabled then
      Resolved.Devices[1] := 'zapper'
    else if FController2.PowerPadEnabled then
      Resolved.Devices[1] := 'powerpad'
    else
      Resolved.Devices[1] := 'pad';
  if Resolved.Expansion = 'auto' then
    if FFamicomKeyboard.Connected then
      Resolved.Expansion := 'famicom'
    else if FSuborKeyboard.Connected then
      Resolved.Expansion := 'subor'
    else if FDataRecorder.Connected then
      Resolved.Expansion := 'recorder'
    else
      case FamilyTrainerMode(FCartridge.Metadata.DefaultExpansionDevice) of
        TFamilyTrainerMode.ftSideA:
          Resolved.Expansion := 'family-trainer-a';
        TFamilyTrainerMode.ftSideB:
          Resolved.Expansion := 'family-trainer-b';
      else
        Resolved.Expansion := 'none';
      end;
  ConfigureInputPorts(Resolved);
  FZapper.Reset;
  FSuborKeyboard.Clear;
  FSuborKeyboard.Reset;
  FFamicomKeyboard.Clear;
  FFamicomKeyboard.Reset;
  FMiraclePiano.ClearInput;
  FMiraclePiano.Reset;
end;

procedure TNesConsole.LoadRom(const FileName: string; RegionOverride: TRegionOverride; Mmc3IrqRevision: TMmc3IrqRevision);
begin
  var Stream := FStorage.OpenRead(FileName);
  try
    LoadRom(Stream, FileName, RegionOverride, Mmc3IrqRevision);
  finally
    Stream.Free;
  end;
end;

procedure TNesConsole.LoadRom(Stream: TStream; const RomName: string; RegionOverride: TRegionOverride; Mmc3IrqRevision: TMmc3IrqRevision);
begin
  FPortsConfigured := False;
  FBus.DisconnectedPads := 0;
  FCartridge.LoadFromStream(Stream, RomName, Mmc3IrqRevision);
  FCpu.DecimalArithmeticEnabled := (FCartridge.Metadata.Format = TRomFormat.Nes20) and
    (FCartridge.Metadata.ConsoleType = 3) and (FCartridge.Metadata.ExtendedConsoleType = 3);
  if FFdsProtectionConfigured then
    SetDiskWriteProtection(FFdsWriteProtected);
  FZapper.VsMode := (FCartridge.MapperId = MAPPER_VS_SYSTEM) or
    (FCartridge.Metadata.ConsoleType = 1);
  FZapper.Enabled := FCartridge.Metadata.DefaultExpansionDevice in [7, 8, $2F];
  FZapper.SerialMouse := FCartridge.Mapper is TMapperSuborSb2000;
  FZapper.DrawingTablet := FCartridge.MapperId = MAPPER_WIN_LOSE_OR_DRAW;
  FMiraclePiano.ClearInput;
  FMiraclePiano.Connected := FCartridge.Metadata.DefaultExpansionDevice = $19;
  FDataRecorder.Reset;
  FBus.TapeOnMapper := FCartridge.Mapper is TMapperPec;
  if FBus.TapeOnMapper then
    TMapperPec(FCartridge.Mapper).ConnectDataRecorder(FDataRecorder);
  FDataRecorder.Connected := FBus.TapeOnMapper or (FCartridge.Metadata.DefaultExpansionDevice in [$20, $23]);
  FController1.SwapStartSelect := FCartridge.MapperId = MAPPER_VS_SYSTEM;
  FController2.SwapStartSelect := FController1.SwapStartSelect;
  FController2.PowerPadEnabled := FCartridge.Metadata.DefaultExpansionDevice in [11, 12];
  FBus.FamilyTrainer := FamilyTrainerMode(FCartridge.Metadata.DefaultExpansionDevice);
  FBus.FourScoreEnabled := FConfiguredFourScore and not UsesPowerPad and not UsesMiraclePiano;
  FFamicomKeyboard.Clear;
  FSuborKeyboard.Clear;
  FSuborKeyboard.Model := TNesKeyboardModel.Subor;
  if FBus.TapeOnMapper then
    if FCartridge.MapperId = MAPPER_SONIC_REC9388 then
      FSuborKeyboard.Model := TNesKeyboardModel.Sonic
    else
      case FCartridge.Metadata.DefaultExpansionDevice of
        $35:
          FSuborKeyboard.Model := TNesKeyboardModel.Keda;
        $3E:
          FSuborKeyboard.Model := TNesKeyboardModel.Kingwon;
      else
        if FCartridge.MapperId = MAPPER_GOLDEN_KEY then
          FSuborKeyboard.Model := TNesKeyboardModel.Keda
        else
          FSuborKeyboard.Model := TNesKeyboardModel.Dongda;
      end;
  FSuborKeyboard.MemoryMapped := (FCartridge.Mapper is TMapperYuxing) or
    (FCartridge.Mapper is TMapperAsderPc95) or (FCartridge.Mapper is TMapperLittleKimPc95) or
    (FCartridge.Mapper is TMapperSuborSb2000);
  if FCartridge.Mapper is TMapperYuxing then
    TMapperYuxing(FCartridge.Mapper).ConnectKeyboard(FSuborKeyboard)
  else if FCartridge.Mapper is TMapperAsderPc95 then
    TMapperAsderPc95(FCartridge.Mapper).ConnectKeyboard(FSuborKeyboard)
  else if FCartridge.Mapper is TMapperLittleKimPc95 then
    TMapperLittleKimPc95(FCartridge.Mapper).ConnectKeyboard(FSuborKeyboard)
  else if FCartridge.Mapper is TMapperSuborSb2000 then
    TMapperSuborSb2000(FCartridge.Mapper).ConnectInput(FSuborKeyboard, FZapper);
  FFamicomKeyboard.Connected := FCartridge.Metadata.DefaultExpansionDevice = $23;
  FSuborKeyboard.Connected := FSuborKeyboard.MemoryMapped or
    (FCartridge.Metadata.DefaultExpansionDevice = $26) or (FSuborKeyboard.Model <> TNesKeyboardModel.Subor) or
    ((FCartridge.MapperId = MAPPER_SUBOR) and not FFamicomKeyboard.Connected);
  FRegion := TNesRegion.NTSC;
  case RegionOverride of
    TRegionOverride.PAL:
      FRegion := TNesRegion.PAL;
    TRegionOverride.Dendy:
      FRegion := TNesRegion.Dendy;
    TRegionOverride.Auto:
      begin
        if FCartridge.Metadata.Timing = TRomTiming.PAL then
          FRegion := TNesRegion.PAL
        else if (FCartridge.Metadata.Timing = TRomTiming.Dendy) or
          ((FCartridge.Metadata.Timing = TRomTiming.MultiRegion) and
          (FCartridge.MapperId = MAPPER_CROAKY_KARAOKE)) then
          FRegion := TNesRegion.Dendy;
      end;
  end;
  if FCartridge.DiskSystem <> nil then
    FRegion := TNesRegion.NTSC;
  FPpu.SetRegion(FRegion);
  FPpu.UseVs2C04DPalette := (FCartridge.MapperId = MAPPER_VS_SYSTEM) and (FCartridge.Metadata.VsPpuType = 5);
  FApu.SetRegion(FRegion);
  FPpu.ConnectMapper(FCartridge.Mapper);
  ResetMachine(True);
end;

function TNesConsole.SetFcnsHostKey(Code: UInt32; Pressed: Boolean): Boolean;
begin
  Result := (FCartridge.Mapper is TMapperFcns) and TMapperFcns(FCartridge.Mapper).SetHostKey(Code, Pressed);
end;

function TNesConsole.UsesFcnsController: Boolean;
begin
  Result := FCartridge.Mapper is TMapperFcns;
end;

procedure TNesConsole.ClearFcnsInput;
begin
  if FCartridge.Mapper is TMapperFcns then
    TMapperFcns(FCartridge.Mapper).ClearInput;
end;

procedure TNesConsole.LoadBattery(const DirectoryName: string);
begin
  FCartridge.LoadBattery(DirectoryName);
end;

procedure TNesConsole.SaveBattery;
begin
  FCartridge.SaveBattery;
end;

function TNesConsole.DiskSystem: TMapperFds;
begin
  Result := FCartridge.DiskSystem;
end;

procedure TNesConsole.ConfigureDiskSystem(const BiosFile: string; WriteProtected: Boolean);
begin
  FCartridge.ConfigureFdsBIOS(BiosFile);
  SetDiskWriteProtection(WriteProtected);
end;

procedure TNesConsole.ConfigureOptions(const Options: TNesOptions);
begin
  FPpu.RemoveSpriteLimit := Options.RemoveSpriteLimit;
  var Volumes: TNesChannelVolumes := Options.ChannelVolume;
  if DiskSystem <> nil then
  begin
    DiskSystem.ChangeDelayMs := Options.FdsChangeDelayMs;
    DiskSystem.RamReader := FBus.PeekInternalRam;
    DiskSystem.AutoSwitchEnabled := Options.FdsAutoSwitch;
    Volumes[5] := Options.FdsVolume;
  end;
  FApu.ConfigureMixer(Volumes, Options.SwapDutyCycles,
    Options.SilenceUltrasonicTriangle, Options.DisableNoiseMode);
end;

procedure TNesConsole.SetDiskWriteProtection(Value: Boolean);
begin
  FFdsWriteProtected := Value;
  FFdsProtectionConfigured := True;
  if DiskSystem <> nil then
    DiskSystem.WriteProtected := Value;
end;

function TNesConsole.XmasPanel: TMapperXmas;
begin
  Result := nil;
  if FCartridge.Mapper is TMapperXmas then
    Result := TMapperXmas(FCartridge.Mapper);
end;

function TNesConsole.PcFloppy: TYuxingFloppy;
begin
  Result := nil;
  if FCartridge.Mapper is TMapperYuxing then
    Result := TMapperYuxing(FCartridge.Mapper).Floppy
  else if FCartridge.Mapper is TMapperSuborSb2000 then
    Result := TMapperSuborSb2000(FCartridge.Mapper).Floppy;
end;

procedure TNesConsole.OpenDisk(const FileName, SaveDirectory: string);
begin
  FCartridge.OpenDisk(FileName, SaveDirectory);
end;

procedure TNesConsole.Reset;
begin
  ResetMachine(False);
end;

procedure TNesConsole.ResetMachine(ColdStart: Boolean);
type
  TClockCallback = procedure of object;

  TBusCallback = procedure(Address: UInt16) of object;

  TIrqCallback = function: Boolean of object;

  TAudioCallback = function: Double of object;
var
  ClockCallback: TClockCallback;
  BusCallback: TBusCallback;
  IrqCallback: TIrqCallback;
  AudioCallback: TAudioCallback;
begin
  FDataRecorder.Reset;
  FZapper.Reset;
  FBus.CroakyPanel := FCartridge.Valid and ((FCartridge.MapperId = MAPPER_CROAKY_KARAOKE) or
    (FCartridge.Metadata.DefaultExpansionDevice = $3D));
  if FCartridge.Valid then
  begin
    FCartridge.Reset(ColdStart);
    FCartridge.Mapper.SetRegion(FRegion);
  end;
  FPpu.Reset;
  FPpu.ConnectMapper(FCartridge.Mapper);
  // Virtual method identity is fixed for the loaded board. Avoid calling the
  // base mapper's empty clock and constant IRQ/audio queries every CPU cycle.
  FMapperHasCpuClock := False;
  FMapperHasCpuBus := False;
  FMapperUsesCpuAddress := False;
  FMapperHasIrq := False;
  FMapperHasAudio := False;
  FMapperIrqAfterCpuAccess := FCartridge.Mapper is TMapperMmc5;
  if FCartridge.Mapper <> nil then
  begin
    ClockCallback := FCartridge.Mapper.ClockCpu;
    BusCallback := FCartridge.Mapper.ClockCpuBus;
    IrqCallback := FCartridge.Mapper.IrqPending;
    AudioCallback := FCartridge.Mapper.ExpansionAudio;
    FMapperHasCpuClock := TMethod(ClockCallback).Code <> @TMapper.ClockCpu;
    FMapperHasCpuBus := TMethod(BusCallback).Code <> @TMapper.ClockCpuBus;
    // RAMBO-1 uses this phase to sample M2 and PPU A12 without decoding the CPU address.
    FMapperUsesCpuAddress := FMapperHasCpuBus and (TMethod(BusCallback).Code <> @TMapperRambo.ClockCpuBus);
    FMapperHasIrq := TMethod(IrqCallback).Code <> @TMapper.IrqPending;
    FMapperHasAudio := TMethod(AudioCallback).Code <> @TMapper.ExpansionAudio;
  end;
  FHasUmDma := FCartridge.Mapper is TMapperUm6578;
  FSuborSb2000 := nil;
  if FCartridge.Mapper is TMapperSuborSb2000 then
    FSuborSb2000 := TMapperSuborSb2000(FCartridge.Mapper);
  FApu.Um6578Mode := FHasUmDma and ((FSuborSb2000 = nil) or not FSuborSb2000.RamBoot);
  FApu.Reset;
  FApu.InternalAudioMuted := FCartridge.Mapper is TMapperFamilyNoraebang;
  if FCartridge.Mapper is TMapperSuperGameMega then
    TMapperSuperGameMega(FCartridge.Mapper).ConnectAudio(FApu);
  FCpu.OpcodeDecoder := nil;
  FCpu.OnJump := nil;
  FVt369 := nil;
  FVt369PpuPhase := 0;
  FVt369ApuPhase := 0;
  if FCartridge.Mapper is TMapperOneBus then
  begin
    var OneBus := TMapperOneBus(FCartridge.Mapper);
    if OneBus.HasVt369 then
      FVt369 := OneBus;
    OneBus.ConnectAudio(FApu);
    OneBus.ConnectPanel(FController1, FZapper);
    FCpu.OpcodeDecoder := OneBus.DecodeOpcode;
    if OneBus.HasVt32 then
      FCpu.OnJump := OneBus.CommitOpcodeMode;
  end;
  if FMicrophone <> nil then
    FMicrophone.Clear;
  FBus.Reset;
  FMiraclePiano.Reset;
  FDmcDmaCycles := 0;
  var Startup: UInt16 := 0;
  if ColdStart and (FCartridge.Mapper is TMapperGameDoctor) then
    Startup := TMapperGameDoctor(FCartridge.Mapper).InstallStartup(FBus.CpuWrite)
  else if ColdStart and (FCartridge.Mapper is TMapperMagicCard) then
    Startup := TMapperMagicCard(FCartridge.Mapper).InstallStartup(FBus.CpuWrite)
  else if FCartridge.Mapper is TMapperNesticle then
    Startup := TMapperNesticle(FCartridge.Mapper).StartupAddress;
  FCpu.Reset;
  if Startup <> 0 then
    FCpu.Pc := Startup;
  FCpuCycles := 0;
  FPalPpuPhase := 0;
end;

procedure TNesConsole.Clock;
begin
  if FSuborSb2000 <> nil then
    FApu.Um6578Mode := not FSuborSb2000.RamBoot;
  var WasFrameReady := FPpu.FrameReady;
  FBus.CpuCycle := FCpuCycles;
  if FMapperUsesCpuAddress then
    FBus.CpuAddress := FCpu.NextReadAddress;
  case FRegion of
    TNesRegion.PAL:
      FDataRecorder.Clock(FCpuCycles * 16);
    TNesRegion.Dendy:
      FDataRecorder.Clock(FCpuCycles * 15);
  else
    FDataRecorder.Clock(FCpuCycles * 12);
  end;
  var CpuOdd: Boolean := (FBus.CpuCycle and 1) <> 0;
  var FinalPpuDot := True;
  var ClockApu := True;
  if FVt369 = nil then
  begin
    FPpu.Clock;
    FPpu.Clock;
    // PAL divides the master clock by 16 for CPU and by 5 for PPU.
    if FRegion = TNesRegion.PAL then
    begin
      Inc(FPalPpuPhase);
      if FPalPpuPhase = 5 then
      begin
        FPpu.Clock;
        FPalPpuPhase := 0;
      end;
    end;
  end
  else
  begin
    var Speed := 1 + 2 * Ord(FVt369.FastCpu);
    var VideoDivisor := Speed * (1 + Ord(FVt369.HalfVideoClock));
    Inc(FVt369PpuPhase, (90 + 6 * Ord(FRegion = TNesRegion.PAL)) div VideoDivisor);
    var Dots := FVt369PpuPhase div 30;
    FVt369PpuPhase := FVt369PpuPhase mod 30;
    for var Dot := 2 to Dots do
      FPpu.Clock;
    FinalPpuDot := Dots > 0;
    Inc(FVt369ApuPhase, 3 div Speed);
    ClockApu := FVt369ApuPhase >= 3;
    FVt369ApuPhase := FVt369ApuPhase mod 3;
  end;

  FBus.ClockIo;
  if FMapperHasAudio then
    FApu.SetExpansionAudio(FCartridge.Mapper.ExpansionAudio)
  else
    FApu.SetExpansionAudio(0);
  if ClockApu then
    FApu.Clock;
  // The read phase is already committed when its clock begins; a disable
  // arriving on this phase prevents playback, but cannot recover that cycle.
  if FApu.ConsumeDmcAbort and (FDmcDmaCycles <> 1) then
    FDmcDmaCycles := 0;
  if FMapperHasCpuClock then
    FCartridge.Mapper.ClockCpu;
  FCpu.SetIrqLine(FApu.IrqPending or (FMapperHasIrq and FCartridge.Mapper.IrqPending));

  var DmcHaltStarted := False;
  if (FDmcDmaCycles = 0) and FApu.DmcDmaRequested then
  begin
    var CanHalt: Boolean;
    if FBus.IsDmaActive then
      CanHalt := not FBus.DmaWritePending
    else
      CanHalt := not FCpu.NextCycleIsWrite;
    if CanHalt then
    begin
      DmcHaltStarted := True;
      FCpu.NotifyDmaHalt;
      // Halt + dummy + optional alignment + get. Get shares OAM's read phase.
      if CpuOdd then
        FDmcDmaCycles := 3
      else
        FDmcDmaCycles := 4;
    end;
  end;
  // This derived address is consumed only by DMA's internal I/O decoder.
  // The CPU has not advanced since the start of this clock, so compute it
  // only when a DMA transfer can actually read the bus.
  if (FDmcDmaCycles > 0) or FBus.IsDmaActive then
    FBus.HaltedCpuAddress := FCpu.NextReadAddress;
  var UmOwnsBus := FHasUmDma and (FDmcDmaCycles = 0) and not FBus.IsDmaActive and FBus.ClockUmDma;
  if FDmcDmaCycles > 0 then
  begin
    Dec(FDmcDmaCycles);
    if FDmcDmaCycles = 0 then
      FApu.CompleteDmcDma(FBus.DmaTransferRead(FApu.DmcDmaAddress))
    else if FBus.IsDmaActive then
      FBus.ClockDma(CpuOdd)
    else
    begin
      var Address := FCpu.NextReadAddress;
      // RDY holds the CPU read address. Joypad clocks remain low across
      // consecutive held reads; the DMC fetch releases them before resume.
      if DmcHaltStarted or ((Address <> $4016) and (Address <> $4017)) then
        FBus.DmaRead(Address);
    end;
  end
  else if FBus.IsDmaActive and not FCpu.NextCycleIsWrite then
    FBus.ClockDma(CpuOdd)
  else if not UmOwnsBus then
    FCpu.Clock(True);

  // The floppy loader pulses the NOAC reset pin after mapping program DRAM.
  if (FSuborSb2000 <> nil) and FSuborSb2000.ConsumeBootReset then
  begin
    FBus.Reset;
    FPpu.Reset;
    FApu.Um6578Mode := False;
    FApu.Reset;
    FDmcDmaCycles := 0;
    FCpu.Reset;
  end;

  if FMapperHasCpuBus then
    FCartridge.Mapper.ClockCpuBus(FBus.CpuAddress);
  if FMapperHasCpuBus then
    FCpu.SetIrqLine(FApu.IrqPending or (FMapperHasIrq and FCartridge.Mapper.IrqPending));

  // Register access precedes interrupt sampling within phi2. Keep one PPU
  // dot between them, including when the access reads/clears PPUSTATUS.
  if FinalPpuDot then
    FPpu.Clock;
  if FMapperIrqAfterCpuAccess then
    FCpu.SetIrqLine(FApu.IrqPending or (FMapperHasIrq and FCartridge.Mapper.IrqPending));
  if FPpu.ConsumeNmi then
    FCpu.TriggerNmi;
  FCpu.PollInterrupts;

  if FPpu.FrameReady and not WasFrameReady then
  begin
    FBus.ClockCoinFrame;
    if DiskSystem <> nil then
      DiskSystem.EndFrame;
  end;
  Inc(FCpuCycles);
end;

function TNesConsole.UsesGameinisInfrared: Boolean;
begin
  Result := FCartridge.Mapper is TMapperGameinis;
end;

procedure TNesConsole.SetGameinisInfrared(Active, FallingEdge: Boolean);
begin
  if UsesGameinisInfrared then
    TMapperGameinis(FCartridge.Mapper).SetInfraredInput(Active, FallingEdge);
end;

function TNesConsole.UsesKaraokeMicrophone: Boolean;
begin
  Result := FCartridge.Mapper is TMapperKaraokeMicrophone;
end;

procedure TNesConsole.SetMicrophoneSource(const Source: IMicrophoneSource);
begin
  FMicrophone := Source;
  if (Source = nil) and UsesKaraokeMicrophone then
    TMapperKaraokeMicrophone(FCartridge.Mapper).SetMicrophoneLevel(0);
end;

procedure TNesConsole.UpdateKaraokeMicrophone;
var
  Samples: array[0..MICROPHONE_SAMPLE_RATE div 48 - 1] of SmallInt;
begin
  if (FMicrophone = nil) or not UsesKaraokeMicrophone then
    Exit;

  var Wanted := Min(Length(Samples), Round(MICROPHONE_SAMPLE_RATE / FrameRate(FRegion)));
  var Count := FMicrophone.ReadSamples(Slice(Samples, Wanted));
  var Peak := 0;
  for var Index := 0 to Count - 1 do
    Peak := Max(Peak, Abs(Integer(Samples[Index])));
  TMapperKaraokeMicrophone(FCartridge.Mapper).SetMicrophoneLevel((Min(Peak, High(SmallInt)) * 63) div High(SmallInt));
end;

procedure TNesConsole.RunFrame;
begin
  UpdateKaraokeMicrophone;
  FPpu.FrameReady := False;
  while not FPpu.FrameReady do
    Clock;
  FPpu.RebuildFrame;
  CheckCpuState;
end;

procedure TNesConsole.CheckCpuState;
begin
  if FCpu.Jammed then
    raise ENesException.CreateFmt('CPU halted: KIL/JAM %s at PC=%s; check ROM data and mapper', [IntToHex(FCpu.JamOpcode, 2), IntToHex(FCpu.JamPc, 4)]);

  if FCpu.UnknownOpcodeCount <> 0 then
    raise ENesException.CreateFmt('Unknown opcode %s at PC=%s', [IntToHex(FCpu.LastUnknownOpcode, 2), IntToHex(FCpu.LastUnknownPc, 4)]);
end;

function TNesConsole.HasCartridge: Boolean;
begin
  Result := FCartridge.Valid;
end;

function TNesConsole.AchievementROM: TBytes;
begin
  Result := Copy(FCartridge.AchievementROM);
end;

function TNesConsole.ReadAchievementMemory(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
begin
  Result := 0;
  if (Buffer = nil) or (Address > $FFFF) then
    Exit;
  Count := Min(Count, $10000 - Address);
  while Result < Count do
  begin
    var Value: Byte;
    if not FBus.PeekAchievementByte(Word(Address + Result), Value) then
      Break;
    Buffer^ := Value;
    Inc(Buffer);
    Inc(Result);
  end;
end;

function TNesConsole.DebugCpuRead(Address: UInt16): UInt8;
begin
  Result := FBus.DebugCpuRead(Address);
end;

function TNesConsole.SenarioLcdLine(Line: Integer): string;
begin
  Result := '';
  if FCartridge.Mapper is TMapperOneBus then
  begin
    var Io := TMapperOneBus(FCartridge.Mapper).Senario;
    if Io <> nil then
      Result := Io.LcdLine(Line);
  end;
end;

procedure TNesConsole.DebugWriteRam(Address: UInt16; Value: UInt8);
begin
  if Address > FBus.InternalRamMask then
    raise EArgumentOutOfRangeException.Create('Diagnostic writes are limited to CPU RAM');

  FBus.CpuWrite(Address, Value);
end;

end.

