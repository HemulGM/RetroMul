unit NES.Console;

interface

uses
  Core.Storage, System.SysUtils, System.Classes, NES.State, NES.Types, NES.CPU,
  NES.PPU, NES.APU, NES.Bus, NES.Cartridge, NES.Controller, Core.InputConfig,
  NES.FamicomKeyboardDevice, NES.FamicomDataRecorder, NES.MiraclePianoDevice;

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
    FRegion: TNesRegion;
    FConfiguredFourScore: Boolean;
    FPortsConfigured: Boolean;
    FDmcDmaCycles: Integer;
    procedure SerializeState(Stream: TStream; Loading: Boolean; Version: Integer = 17);
    function GetRomIdentity: string;
    function GetUsesMiraclePiano: Boolean;
    function GetUsesPowerPad: Boolean;
    function GetHasCoinAcceptor: Boolean;
  public
    constructor Create(FourScoreEnabled: Boolean = False; const Storage: IStorage = nil);
    destructor Destroy; override;
    procedure LoadRom(const FileName: string; RegionOverride: TRegionOverride = TRegionOverride.Auto); overload;
    procedure LoadRom(Stream: TStream; const RomName: string; RegionOverride: TRegionOverride = TRegionOverride.Auto); overload;
    procedure ConfigureInputPorts(const Ports: TCoreInputPorts);
    procedure LoadBattery(const DirectoryName: string);
    procedure SaveBattery;
    procedure SaveSnapshot(const FileName: string);
    procedure LoadSnapshot(const FileName: string);
    property RomIdentity: string read GetRomIdentity;
    property UsesPowerPad: Boolean read GetUsesPowerPad;
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Reset;
    procedure Clock;
    procedure RunFrame;
    procedure CheckCpuState;
    function HasCartridge: Boolean;
    function DebugCpuRead(Address: UInt16): UInt8;
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
  System.Hash, System.IOUtils, NES.Mapper, Core.Snapshots;

const
  SNAPSHOT_VERSION = 17;
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
  if FPortsConfigured then
    Result := FController2.PowerPadEnabled
  else
    Result := FCartridge.Metadata.DefaultExpansionDevice in [11, 12];
end;

procedure TNesConsole.SerializeState(Stream: TStream; Loading: Boolean; Version: Integer);
begin
  var State := TNesStateArchive.Create(Stream, Loading, Version);
  try
    State.Field(FCpuCycles, SizeOf(FCpuCycles));
    State.Field(FPalPpuPhase, SizeOf(FPalPpuPhase));
    State.Field(FDmcDmaCycles, SizeOf(FDmcDmaCycles));
    FCpu.SerializeState(State);
    FPpu.SerializeState(State);
    FApu.SerializeState(State);
    FBus.SerializeState(State);
    FController1.SerializeState(State);
    FController2.SerializeState(State);
    FController3.SerializeState(State);
    FController4.SerializeState(State);
    FCartridge.Mapper.SerializeState(State);
    if Version >= 4 then
      FZapper.SerializeState(State)
    else if Loading then
      FZapper.TriggerPressed := False;
    FBus.SerializeDataBus(State);
    if Version >= 5 then
    begin
      // Identical PRG/CHR hashes can have different NES 2.0 board wiring.
      var Submapper := FCartridge.Metadata.Submapper;
      State.Field(Submapper, SizeOf(Submapper));
      if Loading and (Submapper <> FCartridge.Metadata.Submapper) then
        raise ENesException.Create('Snapshot belongs to a different NES 2.0 submapper');
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
  finally
    State.Free;
  end;
end;

procedure TNesConsole.SaveSnapshot(const FileName: string);
begin
  if not HasCartridge then
    raise ENesException.Create('No game loaded');
  var Payload := TMemoryStream.Create;
  var Output := TMemoryStream.Create;
  try
    SerializeState(Payload, False);
    var Header := Default(TSnapshotHeader);
    Move(SNAPSHOT_MAGIC, Header.Magic, SizeOf(Header.Magic));
    Header.Version := SNAPSHOT_VERSION;
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
      var Frame := FPpu.Frame;
      var Preview: TArray<Cardinal>;
      SetLength(Preview, 256 * 240);
      for var Y := 0 to 239 do
        for var X := 0 to 255 do
          Preview[Y * 256 + X] := Frame[X, Y];
      SaveSnapshotPreview(Temporary, 256, 240, 256, @Preview[0], FStorage);
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
  if not HasCartridge then
    raise ENesException.Create('No game loaded');
  var Input := FStorage.OpenRead(FileName);
  var Payload := TMemoryStream.Create;
  var Backup := TMemoryStream.Create;
  try
    var Header: TSnapshotHeader;
    Input.ReadBuffer(Header, SizeOf(Header));
    var Identity: AnsiString;
    SetString(Identity, PAnsiChar(@Header.RomHash[0]), Length(RomIdentity));
    if not CompareMem(@Header.Magic, @SNAPSHOT_MAGIC, SizeOf(SNAPSHOT_MAGIC)) or
      ((Header.Version < 2) or (Header.Version > SNAPSHOT_VERSION)) or
      (Header.MapperId <> FCartridge.MapperId) or
      (Integer(Header.Region) <> Ord(FRegion)) or (string(Identity) <> RomIdentity) or
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
      SerializeState(Payload, True, Header.Version);
      if Payload.Position <> Payload.Size then
        raise ENesException.Create('Unexpected snapshot data');
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

procedure TNesConsole.ConfigureInputPorts(const Ports: TCoreInputPorts);
begin
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
    FSuborKeyboard.Connected := Ports.Expansion = 'subor';
    FFamicomKeyboard.Connected := Ports.Expansion = 'famicom';
    FDataRecorder.Connected := (Ports.Expansion = 'recorder') or FFamicomKeyboard.Connected;
  end;
  // The gun occupies port 2; Four Score and parallel port devices cannot share it.
  if FZapper.Enabled then
  begin
    FController2.PowerPadEnabled := False;
    FMiraclePiano.Connected := False;
  end;
  FBus.FourScoreEnabled := FConfiguredFourScore and not FController2.PowerPadEnabled
    and not FMiraclePiano.Connected and not FZapper.Enabled;
  FPortsConfigured := True;
end;

procedure TNesConsole.LoadRom(const FileName: string; RegionOverride: TRegionOverride);
begin
  var Stream := FStorage.OpenRead(FileName);
  try
    LoadRom(Stream, FileName, RegionOverride);
  finally
    Stream.Free;
  end;
end;

procedure TNesConsole.LoadRom(Stream: TStream; const RomName: string; RegionOverride: TRegionOverride);
begin
  FPortsConfigured := False;
  FBus.DisconnectedPads := 0;
  FCartridge.LoadFromStream(Stream, RomName);
  FMiraclePiano.ClearInput;
  FMiraclePiano.Connected := FCartridge.Metadata.DefaultExpansionDevice = $19;
  FDataRecorder.Reset;
  FDataRecorder.Connected := FCartridge.Metadata.DefaultExpansionDevice in [$20, $23];
  FController1.SwapStartSelect := FCartridge.MapperId = MAPPER_VS_SYSTEM;
  FController2.SwapStartSelect := FController1.SwapStartSelect;
  FBus.FourScoreEnabled := FConfiguredFourScore and not UsesPowerPad and not UsesMiraclePiano;
  FController2.PowerPadEnabled := UsesPowerPad;
  FFamicomKeyboard.Clear;
  FFamicomKeyboard.Connected := FCartridge.Metadata.DefaultExpansionDevice = $23;
  FSuborKeyboard.Connected := (FCartridge.MapperId = MAPPER_SUBOR) and not FFamicomKeyboard.Connected;
  FRegion := TNesRegion.NTSC;
  case RegionOverride of
    TRegionOverride.PAL:
      FRegion := TNesRegion.PAL;
    TRegionOverride.Auto:
      begin
        if FCartridge.Metadata.Timing = TRomTiming.PAL then
          FRegion := TNesRegion.PAL
        else if FCartridge.Metadata.Timing = TRomTiming.Dendy then
          FRegion := TNesRegion.Dendy;
      end;
  end;
  FPpu.SetRegion(FRegion);
  FPpu.UseVs2C04DPalette := (FCartridge.MapperId = MAPPER_VS_SYSTEM) and (FCartridge.Metadata.VsPpuType = 5);
  FApu.SetRegion(FRegion);
  FPpu.ConnectMapper(FCartridge.Mapper);
  Reset;
end;

procedure TNesConsole.LoadBattery(const DirectoryName: string);
begin
  FCartridge.LoadBattery(DirectoryName);
end;

procedure TNesConsole.SaveBattery;
begin
  FCartridge.SaveBattery;
end;

procedure TNesConsole.Reset;
begin
  FDataRecorder.Reset;
  FZapper.TriggerPressed := False;
  if FCartridge.Valid then
    FCartridge.Reset;
  FPpu.Reset;
  FPpu.ConnectMapper(FCartridge.Mapper);
  FApu.Reset;
  FBus.Reset;
  FMiraclePiano.Reset;
  FDmcDmaCycles := 0;
  FCpu.Reset;
  FCpuCycles := 0;
  FPalPpuPhase := 0;
end;

procedure TNesConsole.Clock;
begin
  var WasFrameReady := FPpu.FrameReady;
  FBus.CpuCycle := FCpuCycles;
  case FRegion of
    TNesRegion.PAL:
      FDataRecorder.Clock(FCpuCycles * 16);
    TNesRegion.Dendy:
      FDataRecorder.Clock(FCpuCycles * 15);
  else
    FDataRecorder.Clock(FCpuCycles * 12);
  end;
  var CpuOdd: Boolean := (FBus.CpuCycle and 1) <> 0;
  FPpu.Clock;
  FPpu.Clock;
  // PAL divides the master clock by 16 for CPU and by 5 for PPU.
  // Carry the fractional dot across CPU cycles and frame boundaries.
  if FRegion = TNesRegion.PAL then
  begin
    Inc(FPalPpuPhase);
    if FPalPpuPhase = 5 then
    begin
      FPpu.Clock;
      FPalPpuPhase := 0;
    end;
  end;

  FBus.ClockIo;
  if FCartridge.Mapper <> nil then
    FApu.SetExpansionAudio(FCartridge.Mapper.ExpansionAudio)
  else
    FApu.SetExpansionAudio(0);
  FApu.Clock;
  // The read phase is already committed when its clock begins; a disable
  // arriving on this phase prevents playback, but cannot recover that cycle.
  if FApu.ConsumeDmcAbort and (FDmcDmaCycles <> 1) then
    FDmcDmaCycles := 0;
  if FCartridge.Mapper <> nil then
    FCartridge.Mapper.ClockCpu;
  FCpu.SetIrqLine(FApu.IrqPending or ((FCartridge.Mapper <> nil) and FCartridge.Mapper.IrqPending));

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
  else
    FCpu.Clock(True);

  // Register access precedes interrupt sampling within phi2. Keep one PPU
  // dot between them, including when the access reads/clears PPUSTATUS.
  FPpu.Clock;
  if FPpu.ConsumeNmi then
    FCpu.TriggerNmi;
  FCpu.PollInterrupts;

  if FPpu.FrameReady and not WasFrameReady then
    FBus.ClockCoinFrame;
  Inc(FCpuCycles);
end;

procedure TNesConsole.RunFrame;
begin
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

function TNesConsole.DebugCpuRead(Address: UInt16): UInt8;
begin
  Result := FBus.DebugCpuRead(Address);
end;

procedure TNesConsole.DebugWriteRam(Address: UInt16; Value: UInt8);
begin
  if Address >= $0800 then
    raise EArgumentOutOfRangeException.Create('Diagnostic writes are limited to CPU RAM');

  FBus.CpuWrite(Address, Value);
end;

end.

