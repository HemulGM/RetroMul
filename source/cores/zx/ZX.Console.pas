unit ZX.Console;

interface

uses
  System.SysUtils, System.UITypes, MD.Z80, ZX.Sound.YM2149, SAM.Sound.SAA1099,
  ZX.SID, ZX.MoonSound, ZX.DMAUSC, ZX.NeoGS, ZX.GeneralSound, ZX.NextDAC,
  ZX.TurboSoundFM, ZX.Timex, ZX.DivStorage, SG1000.FDC, SG1000.Disk, ZX.Tape,
  ZX.BetaDisk, ZX.CMOS, Core.Emulation.Types, Core.AudioFilter, Core.Snapshots,
  ZX.Machine;

type
  TZXBusEvent = record
    Kind: Byte;
    Address, Value, Count: Cardinal;
  end;

  TZXTransferEvent = record
    Kind, Stage, Device: Byte; // kinds match the continuation journal; stages: CPU/RAM/device
    Address, Value: Cardinal;
    MasterClock: UInt64;
    ClockHigh, BusAck: Boolean;
  end;

  TZXTransferObserver = procedure(Context: Pointer; const Event: TZXTransferEvent);

  TZXHostKeys = array[0..255] of Boolean;

  TZXByteCounter = record
    Reload, Count, Phase: Integer;
    Mode, Access: Byte;
    Low: Byte;
    High, Pending, Enabled, Output, BCD: Boolean;
  end;

  TZXConsole = class
  private
    FMachine: TZXMachineConfig;
    FOptions: TZXRuntimeOptions;
    FAYGain, FBeeperGain, FExpansionGain: Double;
    FPalette: array[0..63] of Byte;
    FPaletteColors: array[0..63] of TAlphaColor;
    FPaletteSelect, FPaletteMode, FTimex: Byte;
    FMouseX, FMouseY, FMouseButtons: Byte;
    FCPU: TZ80State;
    FCallbacks: TZ80ReadAndWriteCallbacks;
    FRAM: array[0..63, 0..16383] of Byte;
    FROM: array[0..39] of TBytes;
    F128, FPentagon, FTRDOSActive, FHasAY: Boolean;
    FBeta: TZXBetaDisk;
    FPlus3FDC: TSGFDC;
    FPlus3Disk: TSGDisk;
    FPlus3Paging: Byte;
    FDiv: TZXDivStorage;
    FTimexMemory: TZXTimexMemory;
    FTimexAYAddress: Byte;
    FGamaControl, FGamaPending, FGamaEnable: Byte;
    FGamaLatch: array[0..2] of Byte;
    FScorpionPaging: Byte;
    FProfiPaging: Byte;
    FByteGate: Boolean;
    FByteMemory, FByteVideo, FByteDisk: Byte;
    FBytePIT: array[0..2] of TZXByteCounter;
    FByteWait: array[0..69887] of Byte;
    FProfiPalette: array[0..15] of TAlphaColor;
    FProfiBitmap, FProfiAttr: array[0..63] of Byte;
    FScorpionNMI, FScorpionROMOverride: Boolean;
    FCMOS: TZXCMOS;
    // Half-periods of the 14 MHz master; zero is the base-clock rising edge.
    FTurboPhase: Integer;
    FBusSlow, FBusClock, FBusPortReady, FBusRAMWait: Boolean;
    FBusGrant, FBusVideoUsed, FBusRAM, FBusIO, FBusRefresh: Boolean;
    FCPUTStates: UInt64;
    FMemoryWaitStates, FIOWaitStates: UInt64;
    FBusAck, FBusSample, FBusCyclePending: Boolean;
    FBusAckStates, FBusAckEntries, FLastBusAck, FLastBusResume: UInt64;
    // A frame can end in BUSACK inside an instruction. Replay completed bus
    // events to reconstruct the decoder stack, without repeating their effects.
    FInstructionActive: Boolean;
    FInstructionStart: TZ80State;
    FBusEvents: array[0..127] of TZXBusEvent;
    FBusEventCount, FBusEventPosition: Integer;
    FTransferActive, FTransferIO, FTransferWrite, FTransferCommitted: Boolean;
    FTransferAddress, FTransferValue, FTransferLatch: Cardinal;
    FOpcodeAddress, FOpcodeLatch: Cardinal;
    FTransferCounts: array[0..2, 0..5] of UInt64;
    FTransferLast: array[0..2, 0..5] of UInt64;
    FTransferObserver: TZXTransferObserver;
    FTransferContext: Pointer;
    FWidth, FHeight: Integer;
    FVideoModesSeen: Byte;
    FTurboSeen, FCMOSSeen: Boolean;
    FHasDisk: Boolean;
    FPaging, FULA, FExpansion: Byte;
    FRAMSizeKB: Integer;
    FClock, FFrameCycles, FLineCycles, FDisplayStart, FTime: Integer;
    FAYPhase, FSamplePhase, FSampleCount: Integer;
    FContentionStart, FFetchStart: Integer;
    FAbsoluteTStates: UInt64;
    FBitmapLatch, FAttributeLatch: array[0..31] of Byte;
    FFloatingBus, FBorder: Byte;
    FRefreshAddress: Integer;
    FFrameNumber: UInt64;
    FChip, FChip2: TYM2149F;
    FSAA: TSAA1099;
    FTFM: TZXTurboSoundFM;
    FNextDAC: TZXNextDAC;
    FGS: TZXGeneralSound;
    FNeoGS: TZXNeoGS;
    FMoon: TZXMoonSound;
    FSID: TZXSID;
    FUSC: TZXDMAUSC;
    FUSCBusAck: Boolean;
    FUSCVector: Byte;
    FAYSelect: Byte;
    FDAC: array[0..3] of Byte;
    FLevel2L, FLevel2R: Double;
    FTape: TZXTape;
    FHasTape: Boolean;
    FTapePhase: Integer;
    FKeys: TZXHostKeys;
    FInput: TEmulatorInput;
    FLevelL, FLevelR, FSumL, FSumR: Double;
    FDCLeft, FDCRight: TPCMDCBlocker;
    FPixels: TArray<TAlphaColor>;
    FSamples: TArray<SmallInt>;
    FSampleFrames: Integer;
    function GamaPortC(Status: Boolean): Byte;
    function ReadGamaPort(RegisterIndex: Byte): Byte;
    procedure WriteGamaPort(RegisterIndex, Value: Byte);
    function ReadOtherPort(Address: Word): Byte;
    function ASICMachine: Boolean; inline;
    procedure InitByteTiming;
    procedure ResetByte;
    function ByteRAM(Address: Word): Integer;
    function ReadByteROM(Address: Word): Byte;
    function ReadByteKeyboard(Address: Word): Byte;
    procedure WriteBytePIT(Address: Word; Value: Byte);
    procedure TickBytePIT;
    procedure SetByteDisk(Value: Byte);
    procedure FetchByteVideo;
    procedure DrawByteVideo;
    function ProfiGraphics: Boolean;
    procedure FetchProfiVideo;
    procedure DrawProfiVideo;
    procedure WriteProfiPalette(Address: Word);
    function InterruptLength: Integer;
    function TapeStartDelay: Integer;
    function BetaMachine: Boolean; inline;
    function BetaPort(Address: Word): Integer;
    function RAMBank(Address: Word): Integer;
    function ContendedRAM(Address: Word): Boolean;
    function ActivePSG: TYM2149F;
    procedure WriteSoundExpansion(Address: Word; Value: Byte);
    procedure DACLevels(out Left, Right: Double);
    function PaletteColor(Index: Byte): TAlphaColor; inline;
    function BorderColor: TAlphaColor;
    function DisplayColor(Attr: Byte; Ink: Boolean): TAlphaColor;
    function FlashActive: Boolean; inline;
    function VideoDisplayStart: Integer; inline;
    procedure DrawCompatibleVideo;
    procedure UpdatePalette(Index: Integer);
    function TimexHiRes: Boolean; inline;
    function GetTurbo: Boolean;
    function ExtendedHardware: Boolean; inline;
    procedure UpdateVideoSize;
    procedure DrawExtendedVideo;
    function PentagonDisplayActive: Boolean;
    procedure PentagonMasterEdge;
    procedure PentagonClockEdge(High: Boolean);
    function PentagonWait: Boolean;
    function PentagonBusRequest: Boolean;
    procedure PentagonEndCycle;
    function PentagonServiceBusAck: Boolean;
    function ReplayBusEvent(Kind: Byte; Address, Count: Cardinal; var Value: Cardinal): Boolean;
    procedure RememberBusEvent(Kind: Byte; Address, Count, Value: Cardinal);
    function ReadBusData(Kind: Byte; Address: Cardinal): Cardinal;
    procedure WriteBusData(Kind: Byte; Address, Value: Cardinal);
    procedure TransferEvent(Kind, Stage, Device: Byte; Address, Value: Cardinal);
    procedure PentagonRAMWrite;
    function FinishTransfer(IsWrite: Boolean; Address, Value: Cardinal): Cardinal;
    procedure RunBusStates(Kind: TZ80BusCycle; Address, First, Count: Cardinal; FirstHalfDone: Boolean = False);
    procedure WritePortPart(Address: Word; Value, Parts: Byte; Timed: Boolean = False);
    procedure TurboBus(Kind: TZ80BusCycle; Address, Count: Cardinal);
    procedure SetMachine(const Machine: TZXMachineConfig);
    procedure SetModel(Is128: Boolean; Pentagon: Boolean = False; RAMSizeKB: Integer = 128);
    function PagedBank: Integer;
    function ServiceUSC: Boolean;
    function MoonSoundSelected(Address: Word): Boolean;
    function InterruptActive(Length: Integer): Boolean;
    procedure ClockBus(Kind: TZ80BusCycle; Address, Count: Cardinal);
    procedure Contend(Address: Word; Force: Boolean = False);
    procedure FetchULA;
    procedure Tick;
    procedure LoadSNA(const Data: TBytes);
    procedure LoadZ80(const Data: TBytes);
    procedure RestoreZ80Timing(const Data: TBytes);
    function Color(Index: Byte): TAlphaColor;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset; overload;
    procedure Reset(const Machine: TZXMachineConfig); overload;
    procedure Load(const Data: TBytes; const Name: string; Tape128: Boolean = False; Pentagon: Boolean = False; PentagonRAMKB: Integer = 128); overload;
    procedure Load(const Data: TBytes; const Name: string; const Machine: TZXMachineConfig); overload;
    procedure ApplyOptions(const Options: TZXRuntimeOptions);
    procedure SetServiceROM(const Data: TBytes);
    procedure MountPlus3Disk(const Data: TBytes);
    procedure RequestNMI;
    procedure MountTimexCartridge(const Data: TBytes);
    property GeneralSound: TZXGeneralSound read FGS;
    property NeoGS: TZXNeoGS read FNeoGS;
    property MoonSound: TZXMoonSound read FMoon;
    property SID: TZXSID read FSID;
    property DMAUSC: TZXDMAUSC read FUSC;
    property DMAUSCBusHeld: Boolean read FUSCBusAck;
    property DivStorage: TZXDivStorage read FDiv;
    property Plus3Disk: TSGDisk read FPlus3Disk;
    function BytePITOutput(Channel: Integer): Boolean;
    procedure RunFrame;
    function StepInstruction: Cardinal;
    procedure AdvanceTStates(Count: Integer);
    procedure MoveMouse(DX, DY: Integer; Buttons: Byte);
    procedure SetInput(const Input: TEmulatorInput; const Keys: TZXHostKeys);
    function FetchOpcode(Address: Word): Byte;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Word): Byte;
    procedure WritePort(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    function FramesPerSecond: Double;
    procedure SetTransferObserver(Observer: TZXTransferObserver; Context: Pointer);
    function TransferCount(Kind, Stage: Integer): UInt64;
    function LastTransferMaster(Kind, Stage: Integer): UInt64;
    property HasTape: Boolean read FHasTape;
    property Machine: TZXMachineConfig read FMachine;
    property CMOS: TZXCMOS read FCMOS;
    property ExpansionRegister: Byte read FExpansion;
    property Turbo: Boolean read GetTurbo;
    property CPUTStates: UInt64 read FCPUTStates;
    property MemoryWaitStates: UInt64 read FMemoryWaitStates;
    property IOWaitStates: UInt64 read FIOWaitStates;
    property BusRequest: Boolean read PentagonBusRequest;
    property BusAcknowledge: Boolean read FBusAck;
    property BusAckTStates: UInt64 read FBusAckStates;
    property BusAckEntries: UInt64 read FBusAckEntries;
    property LastBusAckMaster: UInt64 read FLastBusAck;
    property LastBusResumeMaster: UInt64 read FLastBusResume;
    property InstructionSuspended: Boolean read FInstructionActive;
    property MasterClockPhase: Integer read FTurboPhase;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property VideoModesSeen: Byte read FVideoModesSeen;
    property TurboSeen: Boolean read FTurboSeen;
    property CMOSSeen: Boolean read FCMOSSeen;
    property Pentagon: Boolean read FPentagon;
    property RAMSizeKB: Integer read FRAMSizeKB;
    property TRDOSActive: Boolean read FTRDOSActive;
    property ByteConfiguration: Byte read FByteMemory;
    property Beta: TZXBetaDisk read FBeta;
    property CPU: TZ80State read FCPU;
    property TStates: Integer read FTime;
    property TotalTStates: UInt64 read FAbsoluteTStates;
    property Tape: TZXTape read FTape;
    property Is128: Boolean read F128;
    property Pixels: TArray<TAlphaColor> read FPixels;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleFrames;
    property FrameNumber: UInt64 read FFrameNumber;
  end;

implementation

uses
  System.Classes, System.Math;

{$R 'ZX.Firmware.res' 'ZX.Firmware.rc'}

type
  EZXBusHeld = class(Exception);

function MemoryRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TZXConsole(Context).ReadBusData(1, Address and $FFFF);
end;

function OpcodeRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TZXConsole(Context).ReadBusData(2, Address and $FFFF);
end;

procedure MemoryWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TZXConsole(Context).WriteBusData(3, Address and $FFFF, Value and $FF);
end;

function PortRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TZXConsole(Context).ReadBusData(4, Address and $FFFF);
end;

procedure PortWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TZXConsole(Context).WriteBusData(5, Address and $FFFF, Value and $FF);
end;

procedure ClockBusCallback(Context: Pointer; Kind: TZ80BusCycle; Address, Count: Cardinal);
begin
  TZXConsole(Context).ClockBus(Kind, Address, Count);
end;

function USCRead(Context: Pointer; Address: Cardinal): Byte;
begin
  var C := TZXConsole(Context);
  Address := Address and Cardinal(C.FRAMSizeKB * 1024 - 1);
  Result := C.FRAM[Address shr 14, Address and $3FFF];
end;

procedure USCWrite(Context: Pointer; Address: Cardinal; Value: Byte);
begin
  var C := TZXConsole(Context);
  Address := Address and Cardinal(C.FRAMSizeKB * 1024 - 1);
  C.FRAM[Address shr 14, Address and $3FFF] := Value;
end;

constructor TZXConsole.Create;
const
  Names: array[0..38] of string = ('ZX_ROM48', 'ZX_ROM128_0', 'ZX_ROM128_1', 'ZX_PENTAGON0', 'ZX_TRDOS', 'ZX_PLUS2_0', 'ZX_PLUS2_1',
    'ZX_PLUS3_0', 'ZX_PLUS3_1', 'ZX_PLUS3_2', 'ZX_PLUS3_3',
    'ZX_PLUS2B_0', 'ZX_PLUS2B_1', 'ZX_PLUS2B_2', 'ZX_PLUS2B_3', 'ZX_TC2048', 'ZX_TC2068_HOME', 'ZX_TC2068_EXROM', 'ZX_SCORPION0', 'ZX_SCORPION1', 'ZX_SCORPION2', 'ZX_SCORPION3', 'ZX_PROFI0', 'ZX_PROFI1', 'ZX_PROFI2', 'ZX_PROFI3', 'ZX_BYTE', 'ZX_BYTE01', 'ZX_BYTE66', 'ZX_BYTE71', 'ZX_BYTE10', 'ZX_BYTE11', 'ZX_GAMA87', 'ZX_GAMA88', 'ZX_GAMA89', 'ZX_TK90PT', 'ZX_TK90ES', 'ZX_TK95PT', 'ZX_TK95ES');
begin
  inherited;
  for var i := 0 to High(Names) do
  begin
    var Index := i;
    if i >= 5 then
      Inc(Index); // Slot 5 is the optional service ROM.
    var Stream := TResourceStream.Create(HInstance, Names[i], PChar(10));
    try
      var Size := 16384;
      if Index = 18 then
        Size := 8192;
      if Index in [29, 31, 32] then
        Size := 512;
      if Index = 30 then
        Size := 2048;
      if Stream.Size <> Size then
        raise EReadError.Create('Invalid Spectrum ROM size');
      SetLength(FROM[Index], Size);
      Stream.ReadBuffer(FROM[Index][0], Size);
    finally
      Stream.Free;
    end;
  end;
  FCallbacks.UserData := Self;
  FCallbacks.CycleCallback := ClockBusCallback;
  FCallbacks.ReadCallback := MemoryRead;
  FCallbacks.WriteCallback := MemoryWrite;
  FCallbacks.PortReadCallback := PortRead;
  FCallbacks.PortWriteCallback := PortWrite;
  FOptions := TZXRuntimeOptions.Defaults;
  FAYGain := 1;
  FBeeperGain := 1;
  FExpansionGain := 1;
  FChip := TYM2149F.Create;
  FChip.AYModel := True;
  FChip2 := TYM2149F.Create;
  FChip2.AYModel := True;
  FSAA := TSAA1099.Create;
  FTFM := TZXTurboSoundFM.Create;
  FNextDAC := TZXNextDAC.Create;
  FTimexMemory := TZXTimexMemory.Create;
  FDiv := TZXDivStorage.Create;
  FPlus3FDC := TSGFDC.Create(3546900);
  FPlus3FDC.TimedTransfers := True;
  FTape := TZXTape.Create;
  FBeta := TZXBetaDisk.Create;
  FCMOS := TZXCMOS.Create;
  SetLength(FPixels, 320 * 240);
  SetLength(FSamples, 2048);
  FDCLeft.Configure(44100, 20);
  FDCRight.Configure(44100, 20);
  Reset;
end;

destructor TZXConsole.Destroy;
begin
  FTimexMemory.Free;
  FDiv.Free;
  FPlus3FDC.Free;
  FPlus3Disk.Free;
  FCMOS.Free;
  FBeta.Free;
  FTape.Free;
  FSID.Free;
  FMoon.Free;
  FUSC.Free;
  FGS.Free;
  FNextDAC.Free;
  FTFM.Free;
  FSAA.Free;
  FChip2.Free;
  FChip.Free;
  inherited;
end;

procedure TZXConsole.SetModel(Is128: Boolean; Pentagon: Boolean; RAMSizeKB: Integer);
begin
  var Model := TZXMachineConfig.FromLegacy(Is128, Pentagon, RAMSizeKB);
  SetMachine(FMachine.WithModel(Model.Model));
end;

procedure TZXConsole.SetMachine(const Machine: TZXMachineConfig);
begin
  Machine.Validate;
  if Machine.SID then
  begin
    if FSID = nil then
      FSID := TZXSID.Create;
  end
  else
    FreeAndNil(FSID);
  if Machine.MoonSound then
  begin
    if FMoon = nil then
      FMoon := TZXMoonSound.Create;
  end
  else
    FreeAndNil(FMoon);
  if Machine.DMAUSC then
  begin
    if FUSC = nil then
      FUSC := TZXDMAUSC.Create(Self, USCRead, USCWrite);
  end
  else
    FreeAndNil(FUSC);
  var Profile := Machine.Profile;
  FMachine := Machine;
  FNeoGS := nil;
  if Machine.GeneralSound or Machine.NeoGS then
  begin
    var RAMKB := Machine.GeneralSoundRAMKB;
    if RAMKB = 0 then
      RAMKB := 128;
    if Machine.NeoGS then
    begin
      RAMKB := Machine.NeoGSRAMKB;
      if RAMKB = 0 then
        RAMKB := 2048;
    end;
    if (FGS <> nil) and ((FGS.RAMKB <> RAMKB) or ((FGS is TZXNeoGS) <> Machine.NeoGS)) then
    begin
      if (FGS is TZXNeoGS) and Machine.NeoGS then
      begin
        var Replacement := TZXNeoGS.Create(RAMKB);
        TZXNeoGS(FGS).MoveMediaTo(Replacement);
        FGS.Free;
        FGS := Replacement;
      end
      else
        FreeAndNil(FGS);
    end;
    if FGS = nil then
      if Machine.NeoGS then
        FGS := TZXNeoGS.Create(RAMKB)
      else
        FGS := TZXGeneralSound.Create(RAMKB);
    if Machine.NeoGS then
      FNeoGS := TZXNeoGS(FGS);
  end
  else
    FreeAndNil(FGS);
  FPentagon := Profile.IsPentagon;
  F128 := Profile.Has128Paging;
  FHasAY := Profile.HasAY;
  FTape.Model128 := F128;
  FCallbacks.InternalMachineCallback := nil;
  if Machine.Model = zmPentagon1024 then
    FCallbacks.InternalMachineCallback := ClockBusCallback;
  FRAMSizeKB := Profile.RAMSizeKB;
  FClock := Profile.ClockHz;
  if FSID <> nil then
    FSID.SetMotherboardClock(FClock);
  if FTFM.Clock <> FClock then
    FTFM.Reset(FClock);
  FFrameCycles := Profile.FrameCycles;
  FLineCycles := Profile.LineCycles;
  FDisplayStart := Profile.DisplayStart;
  FContentionStart := Profile.ContentionStart;
  FFetchStart := FContentionStart + 3;
  if FPentagon then
    FFetchStart := FDisplayStart - 2;
  if ASICMachine or Machine.Scorpion or Machine.Profi or Machine.ByteFamily then
    FFetchStart := FDisplayStart - 2;
  FTime := FTime mod FFrameCycles;
  FChip.SetClock(FClock div 2);
  FChip2.SetClock(FClock div 2);
  if Machine.ByteFamily then
    InitByteTiming;
end;

procedure TZXConsole.Reset(const Machine: TZXMachineConfig);
begin
  Machine.Validate; // Reject invalid profiles before resetting the machine.
  FMachine := Machine;
  Reset;
end;

procedure TZXConsole.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FCPU := Default(TZ80State);
  Z80Reset(FCPU);
  FPentagon := False;
  FTRDOSActive := False;
  FHasDisk := False;
  FBeta.EjectAll;
  FPlus3FDC.Mount(nil);
  FreeAndNil(FPlus3Disk);
  FPlus3FDC.SetLines(True, False, False, False);
  FPlus3FDC.Reset;
  FPlus3Paging := 0;
  FScorpionPaging := 0;
  FScorpionNMI := False;
  FScorpionROMOverride := False;
  SetLength(FROM[5], 0);
  FCMOS.ResetInterface;
  FTurboPhase := 0;
  FCPUTStates := 0;
  FBusAck := False;
  FBusSample := False;
  FBusCyclePending := False;
  FBusAckStates := 0;
  FBusAckEntries := 0;
  FLastBusAck := 0;
  FLastBusResume := 0;
  FInstructionActive := False;
  FBusEventCount := 0;
  FBusEventPosition := 0;
  FInstructionStart := Default(TZ80State);
  FTransferActive := False;
  FTransferIO := False;
  FTransferWrite := False;
  FTransferCommitted := False;
  FTransferAddress := 0;
  FTransferValue := 0;
  FTransferLatch := 0;
  FOpcodeAddress := 0;
  FOpcodeLatch := 0;
  FillChar(FTransferCounts, SizeOf(FTransferCounts), 0);
  FillChar(FTransferLast, SizeOf(FTransferLast), 0);
  FMemoryWaitStates := 0;
  FIOWaitStates := 0;
  FBusSlow := True;
  FBusClock := True;
  FBusPortReady := True;
  FBusRAMWait := False;
  FBusGrant := False;
  FBusVideoUsed := False;
  FBusRAM := False;
  FBusIO := False;
  FBusRefresh := False;
  FVideoModesSeen := 0;
  FTurboSeen := False;
  FCMOSSeen := False;
  FWidth := 320;
  FHeight := 240;
  SetLength(FPixels, FWidth * FHeight);
  ResetByte;
  FGamaControl := $9B;
  FillChar(FGamaLatch, SizeOf(FGamaLatch), 0);
  FGamaPending := 0;
  FGamaEnable := 0;
  FProfiPaging := 0;
  for var i := 0 to 15 do
    FProfiPalette[i] := Color(i);
  FillChar(FProfiBitmap, SizeOf(FProfiBitmap), 0);
  FillChar(FProfiAttr, SizeOf(FProfiAttr), 0);
  FPaletteSelect := 0;
  FPaletteMode := 0;
  FTimex := 0;
  FTimexAYAddress := 0;
  if FMachine.Model = zmTimex2068 then
    FTimexMemory.Reset(FROM[18])
  else
    FTimexMemory.Reset(nil);
  FillChar(FPalette, SizeOf(FPalette), 0);
  for var i := 0 to 63 do
    UpdatePalette(i);
  FMouseX := 0;
  FMouseY := 0;
  FMouseButtons := 0;
  FAYSelect := 0;
  FillChar(FDAC, SizeOf(FDAC), 128);
  FNextDAC.Reset;
  if FMachine.DAC = 6 then
    FNextDAC.ConfigureStartup(FMachine.NextDACStartup, FMachine.NextDACDecodeMask);
  FLevel2L := 0;
  FLevel2R := 0;
  FPaging := 0;
  FExpansion := 0;
  FULA := 7;
  FTime := 0;
  FAbsoluteTStates := 0;
  FFrameNumber := 0;
  FAYPhase := 0;
  FSamplePhase := 0;
  FillChar(FBitmapLatch, SizeOf(FBitmapLatch), 0);
  FillChar(FAttributeLatch, SizeOf(FAttributeLatch), 0);
  FFloatingBus := $FF;
  FBorder := 7;
  FRefreshAddress := -1;
  FTapePhase := 0;
  FSampleCount := 0;
  FSampleFrames := 0;
  FLevelL := 0;
  FLevelR := 0;
  FSumL := 0;
  FSumR := 0;
  FDCLeft.Reset;
  FDCRight.Reset;
  FChip.Reset;
  FChip2.Reset;
  FSAA.Reset;
  FTFM.Reset(FMachine.Profile.ClockHz);
  FTape.Rewind;
  FDiv.Configure(FMachine.DivType, FMachine.DivRAMKB);
  SetMachine(FMachine);
  if FGS <> nil then
    FGS.Reset;
  if FSID <> nil then
    FSID.Reset(FClock, FMachine.SIDModel, FMachine.SIDNTSC, FMachine.SIDInterface, FMachine.SIDClock1MHz);
  if FMoon <> nil then
    FMoon.Reset(FClock);
  FUSCBusAck := False;
  FUSCVector := $FF;
  if FUSC <> nil then
  begin
    FUSC.Reset;
    FUSC.ConfigureULABypass(FMachine.DMAUSCULABypass);
  end;
  ApplyOptions(FOptions);
  UpdateVideoSize;
end;

procedure TZXConsole.RequestNMI;
begin
  if FDiv.Mapped then
    Exit;
  if (FMachine.Model = zmByte01) and ((FByteMemory and $20) <> 0) then
    Exit;
  if FMachine.Scorpion and (FDiv.Kind = zdNone) then
    FScorpionNMI := True
  else
    Z80NonMaskableInterrupt(FCPU);
end;

function TZXConsole.FetchOpcode(Address: Word): Byte;
begin
  FDiv.BeforeFetch(Address);
  if (FMachine.Model = zmByte01) and ((FByteMemory and $80) <> 0) then
    if Address >= $4000 then
      FTRDOSActive := False
    else if (Address and $FF00) = $3D00 then
      FTRDOSActive := True;
  if BetaMachine and (FDiv.Kind = zdNone) and not (FMachine.Profi and ((FProfiPaging and $20) <> 0)) then
    if Address >= $4000 then
      FTRDOSActive := False
    else if ((Address and $FF00) = $3D00) and ((FPaging and $10) <> 0) then
      FTRDOSActive := True;
  Result := ReadMemory(Address);
  FDiv.AfterFetch(Address);
end;

procedure TZXConsole.ApplyOptions(const Options: TZXRuntimeOptions);
const
  Orders: array[0..6] of string = ('ABC', 'ABC', 'ACB', 'BAC', 'BCA', 'CAB', 'CBA');
begin
  FOptions := Options.Normalized;
  FAYGain := FOptions.AYVolume / 100;
  FBeeperGain := FOptions.BeeperVolume / 100;
  FExpansionGain := FOptions.ExpansionVolume / 100;
  FChip.AYModel := not FOptions.YMChip;
  FChip2.AYModel := not FOptions.YMChip;
  for var Channel := 0 to 2 do
    if FOptions.Stereo = 1 then
      FTFM.SetPan(Channel, 0.7071067811865475, 0.7071067811865475)
    else
      case Pos(Char(Ord('A') + Channel), Orders[FOptions.Stereo]) of
        1:
          FTFM.SetPan(Channel, 1, 0);
        2:
          FTFM.SetPan(Channel, 0.7071067811865475, 0.7071067811865475);
        3:
          FTFM.SetPan(Channel, 0, 1);
      end;
  for var Channel := 0 to 2 do
    if FOptions.Stereo = 1 then
      FChip.SetPan(Channel, 0.7071067811865475, 0.7071067811865475)
    else
      case Pos(Char(Ord('A') + Channel), Orders[FOptions.Stereo]) of
        1:
          FChip.SetPan(Channel, 1, 0);
        2:
          FChip.SetPan(Channel, 0.7071067811865475, 0.7071067811865475);
        3:
          FChip.SetPan(Channel, 0, 1);
      end;
  for var Channel := 0 to 2 do
    if FOptions.Stereo = 1 then
      FChip2.SetPan(Channel, 0.7071067811865475, 0.7071067811865475)
    else
      case Pos(Char(Ord('A') + Channel), Orders[FOptions.Stereo]) of
        1:
          FChip2.SetPan(Channel, 1, 0);
        2:
          FChip2.SetPan(Channel, 0.7071067811865475, 0.7071067811865475);
        3:
          FChip2.SetPan(Channel, 0, 1);
      end;
  if FDiv.Disk <> nil then
    FDiv.Disk.WriteProtected := FOptions.DiskWriteProtected;
  if (FNeoGS <> nil) and (FNeoGS.Disk <> nil) then
    FNeoGS.Disk.WriteProtected := FOptions.DiskWriteProtected;
  if FPlus3Disk <> nil then
    FPlus3Disk.WriteProtected := FOptions.DiskWriteProtected;
  for var Drive := 0 to 3 do
    if FBeta.Disk(Drive) <> nil then
      FBeta.Disk(Drive).WriteProtected := FOptions.DiskWriteProtected;
end;

procedure TZXConsole.SetServiceROM(const Data: TBytes);
begin
  if not ExtendedHardware then
    raise EReadError.Create('Service ROM requires Pentagon 1024K');
  if (Length(Data) <> 16384) and (Length(Data) <> 65536) then
    raise EReadError.Create('Pentagon service ROM must be 16 or 64 KiB');
  FROM[5] := Copy(Data);
end;

procedure TZXConsole.MountTimexCartridge(const Data: TBytes);
begin
  if FMachine.Model <> zmTimex2068 then
    raise EReadError.Create('DCK cartridges require Timex TC2068');
  FTimexMemory.LoadDCK(Data);
end;

function TZXConsole.PagedBank: Integer;
begin
  if not F128 then
    Exit(0);
  Result := FPaging and 7;
  if FMachine.Profi then
    Exit((Result or ((FProfiPaging and 7) shl 3)) and (FRAMSizeKB div 16 - 1));
  if FMachine.Scorpion then
    Exit(Result or ((FScorpionPaging and $10) shr 1));
  if FPentagon and (FRAMSizeKB > 128) then
  begin
    // 512K uses 7FFD D6/D7; 1024K additionally uses D5 when EFF7 D2 is clear.
    if (FRAMSizeKB = 1024) and ((FExpansion and 4) <> 0) then
      Exit;
    Result := Result or ((FPaging shr 3) and $18);
    if FRAMSizeKB = 1024 then
      Result := Result or (FPaging and $20);
  end;
end;

function TZXConsole.BetaPort(Address: Word): Integer;
begin
  Result := -1;
  if FMachine.ByteFamily then
    Exit; // KVU has its own always-decoded 08/28/48/68 ports.
  if FMachine.Profi then
  begin
    var P := Address and 255;
    if ((FProfiPaging and $20) <> 0) and ((FPaging and $10) <> 0) then
    begin
      if (P and $E3) = $23 then
        Exit($FF);
      if (P and $9F) = $83 then
        Exit((P and $60) or $1F);
    end
    else
    begin
      if (P and $83) = $03 then
        Exit((P and $60) or $1F);
      var SystemPort := $E3;
      if (FProfiPaging and $20) <> 0 then
        SystemPort := $A3;
      if (P and $E3) = SystemPort then
        Exit($FF);
    end;
    Exit;
  end;
  if FMachine.Scorpion then
    case Address and $E3 of
      $03:
        Result := $1F;
      $23:
        Result := $3F;
      $43:
        Result := $5F;
      $63:
        Result := $7F;
      $E3:
        Result := $FF;
    end
  else if (Address and 255) in [$1F, $3F, $5F, $7F, $FF] then
    Result := Address and 255;
end;

function TZXConsole.BetaMachine: Boolean;
begin
  Result := FPentagon or FMachine.Scorpion or FMachine.Profi;
end;

function TZXConsole.ASICMachine: Boolean;
begin
  Result := FMachine.Model in [zmSpectrumPlus2b, zmSpectrumPlus3];
end;

procedure TZXConsole.MountPlus3Disk(const Data: TBytes);
begin
  // Reuse RetroMul's native DSK and 765 implementation. Only drive A is wired.
  if (Length(Data) < 256) or not ((Data[0] = Ord('M')) or (Data[0] = Ord('E'))) then
    raise EReadError.Create('Expected a standard or extended DSK image');
  var Disk := TSGDisk.Create(Data, FOptions.DiskWriteProtected);
  FPlus3FDC.Mount(Disk);
  FPlus3Disk.Free;
  FPlus3Disk := Disk;
end;

function TZXConsole.RAMBank(Address: Word): Integer;
const
  AllRAM: array[0..3, 0..3] of Byte = ((0, 1, 2, 3), (4, 5, 6, 7), (4, 5, 6, 3), (4, 7, 6, 3));
begin
  if FMachine.Model = zmByte01 then
    Exit(ByteRAM(Address));
  if FMachine.Gama and (Address >= $8000) and ((GamaPortC(False) and 1) <> 0) then
    Exit(1 + 2 * Ord(Address >= $C000)); // Second 32 KiB: banks 1 and 3.
  if FMachine.Profi then
    case Address shr 14 of
      0:
        begin
          if (FProfiPaging and $10) <> 0 then
            Exit(0);
          Exit(-1);
        end;
      1:
        begin
          if (FProfiPaging and 8) <> 0 then
            Exit(PagedBank);
          Exit(5);
        end;
      2:
        begin
          if ((FProfiPaging and $40) <> 0) and ((FPaging and 8) <> 0) then
            Exit(6);
          Exit(2);
        end;
      3:
        begin
          if (FProfiPaging and 8) <> 0 then
            Exit(7);
          Exit(PagedBank);
        end;
    end;
  if FMachine.Scorpion and (Address < $4000) and not FScorpionROMOverride and ((FScorpionPaging and 1) <> 0) then
    Exit(0);
  if ASICMachine and ((FPlus3Paging and 1) <> 0) then
    Exit(AllRAM[(FPlus3Paging shr 1) and 3, Address shr 14]);
  case Address shr 14 of
    0:
      Result := -1;
    1:
      Result := 5;
    2:
      Result := 2;
  else
    Result := PagedBank;
  end;
end;

function TZXConsole.ContendedRAM(Address: Word): Boolean;
begin
  if ASICMachine then
    Result := RAMBank(Address) >= 4
  else
    Result := ((Address >= $4000) and (Address < $8000)) or
      (F128 and (Address >= $C000) and ((FPaging and 1) <> 0));
end;

function TZXConsole.ReadMemory(Address: Word): Byte;
var
  Bank: Integer;
begin
  if (Address < $4000) and FDiv.Mapped then
    Exit(FDiv.ReadMemory(Address));
  if FMachine.Scorpion and (Address < $4000) and not FScorpionROMOverride and ((FScorpionPaging and 1) <> 0) then
    Exit(FRAM[0, Address]);
  if (FMachine.Profi or FMachine.Gama or (FMachine.Model = zmByte01)) and (RAMBank(Address) >= 0) then
    Exit(FRAM[RAMBank(Address), Address and $3FFF]);
  var TimexValue: Byte;
  if FMachine.Timex and FTimexMemory.ReadMemory(Address, TimexValue) then
    Exit(TimexValue);
  if ASICMachine and ((FPlus3Paging and 1) <> 0) then
    Exit(FRAM[RAMBank(Address), Address and $3FFF]);
  if Address < $4000 then
  begin
    var DMAValue: Byte;
    if (FNeoGS <> nil) and not (ExtendedHardware and ((FExpansion and 8) <> 0)) and
      FNeoGS.DMARead(Address, True, DMAValue) then
      Exit(DMAValue);
    if FMachine.ByteFamily then
      Exit(ReadByteROM(Address));
    Bank := 0;
    if FMachine.Gama then
      Bank := 33 + Ord(FMachine.Model) - Ord(zmGama87);
    if FMachine.TK then
      Bank := 36 + 2 * Ord(FMachine.Model = zmTK95) + Ord(FMachine.TKSpanish);
    if FMachine.Model = zmTimex2048 then
      Bank := 16;
    if FMachine.Model = zmTimex2068 then
      Bank := 17;
    if F128 then
      Bank := 1 + ((FPaging shr 4) and 1);
    if FMachine.Model = zmSpectrumPlus2 then
      Bank := 6 + ((FPaging shr 4) and 1);
    if ASICMachine then
    begin
      Bank := 8 + ((FPaging shr 4) and 1) + ((FPlus3Paging and 4) shr 1);
      if FMachine.Model = zmSpectrumPlus2b then
        Inc(Bank, 4);
    end;
    if FPentagon and (Bank = 1) then
      Bank := 3;
    if FTRDOSActive then
      Bank := 4;
    if FMachine.Scorpion then
    begin
      Bank := 19 + ((FPaging shr 4) and 1) + 2 * Ord(FTRDOSActive);
      if (FScorpionPaging and 2) <> 0 then
        Bank := 21;
    end;
    if FMachine.Profi then
      Bank := 23 + 2 * Ord(not FTRDOSActive) + ((FPaging shr 4) and 1);
    if ExtendedHardware then
    begin
      if (FExpansion and 8) <> 0 then
        Exit(FRAM[0, Address]);
      if Length(FROM[5]) = 65536 then
      begin
        var Offset := 32768;
        if FTRDOSActive then
          Offset := 0;
        if (FPaging and $10) <> 0 then
          Inc(Offset, 16384);
        Exit(FROM[5][Offset + Address]);
      end;
      if FTRDOSActive and ((FPaging and $10) = 0) and (Length(FROM[5]) = 16384) then
        Exit(FROM[5][Address]);
    end;
    Exit(FROM[Bank][Address]);
  end;
  if (FMachine.Model = zmSpectrum16) and (Address >= $8000) then
    Exit($FF);
  case Address shr 14 of
    1:
      Bank := 5;
    2:
      Bank := 2;
  else
    Bank := PagedBank;
  end;
  Result := FRAM[Bank, Address and $3FFF];
end;

procedure TZXConsole.WriteMemory(Address: Word; Value: Byte);
var
  Bank: Integer;
begin
  if FNeoGS <> nil then
    FNeoGS.DMAWrite(Address, Value);
  if (Address < $4000) and FDiv.Mapped then
  begin
    FDiv.WriteMemory(Address, Value);
    Exit;
  end;
  if FMachine.Scorpion and (Address < $4000) and not FScorpionROMOverride and ((FScorpionPaging and 1) <> 0) then
  begin
    FRAM[0, Address] := Value;
    Exit;
  end;
  if (FMachine.Profi or FMachine.Gama or (FMachine.Model = zmByte01)) and (RAMBank(Address) >= 0) then
  begin
    if (FMachine.Model = zmByte01) and (Address < $4000) and ((FByteMemory and 4) <> 0) then
      Exit;
    FRAM[RAMBank(Address), Address and $3FFF] := Value;
    Exit;
  end;
  if FMachine.Timex and FTimexMemory.WriteMemory(Address, Value) then
    Exit;
  if ASICMachine and ((FPlus3Paging and 1) <> 0) then
  begin
    FRAM[RAMBank(Address), Address and $3FFF] := Value;
    Exit;
  end;
  if Address < $4000 then
  begin
    if ExtendedHardware and ((FExpansion and 8) <> 0) then
      FRAM[0, Address] := Value;
    Exit;
  end;
  if (FMachine.Model = zmSpectrum16) and (Address >= $8000) then
    Exit;
  case Address shr 14 of
    1:
      Bank := 5;
    2:
      Bank := 2;
  else
    Bank := PagedBank;
  end;
  FRAM[Bank, Address and $3FFF] := Value;
end;

function TZXConsole.MoonSoundSelected(Address: Word): Boolean;
begin
  Result := (FMoon <> nil) and TZXMoonSound.Decodes(Address);
  if not Result then
    Exit;
  if FTRDOSActive and not FMachine.MoonSoundInDOS then
    Exit(False);
  if (FTRDOSActive or (FMachine.Profi and ((FProfiPaging and $20) <> 0))) and (BetaPort(Address) >= 0) then
    Exit(False);
end;

function TZXConsole.InterruptActive(Length: Integer): Boolean;
begin
  Result := (FTime < Length) and not (FMachine.VideoTimex and ((FTimex and $40) <> 0));
  if FUSC <> nil then
    Result := FUSC.Interrupt(Result);
  if (FMoon <> nil) and FMachine.MoonSoundIRQ then
    Result := Result or FMoon.Interrupt;
end;

function TZXConsole.ServiceUSC: Boolean;
begin
  Result := True;
  var Frame := FFrameNumber;
  while FUSC.BusRequest do
  begin
    if not FUSC.BeginBus then
      Break;
    FUSCBusAck := True;
    if ExtendedHardware then
      for var I := 1 to 8 do
        PentagonMasterEdge
    else
      Tick;
    if FUSC.Released then
      FUSCBusAck := False;
    if FFrameNumber <> Frame then
      Exit(False);
    if FUSC.Released then
      Exit(True); // single mode grants a CPU cycle between services
  end;
  FUSCBusAck := False;
end;

procedure TZXConsole.AdvanceTStates(Count: Integer);
begin
  for var i := 1 to Count do
    Tick;
end;

procedure TZXConsole.Contend(Address: Word; Force: Boolean);
const
  Delay: array[0..7] of Byte = (6, 5, 4, 3, 2, 1, 0, 0);
  ASICDelay: array[0..7] of Byte = (1, 0, 7, 6, 5, 4, 3, 2);
begin
  if FMachine.ByteFamily then
  begin
    var VideoRAM := (Address >= $4000) and (Address < $8000);
    if FMachine.Model = zmByte01 then
      VideoRAM := ByteRAM(Address) in [0..3];
    if VideoRAM then
      AdvanceTStates(FByteWait[FTime]);
    Exit;
  end;
  if BetaMachine then
    Exit;
  if not (Force or ContendedRAM(Address)) then
    Exit;
  var T := FTime - FContentionStart;
  if (T >= 0) and (T div FLineCycles < 192) and (T mod FLineCycles < 128) then
    if ASICMachine then
      AdvanceTStates(ASICDelay[T mod FLineCycles mod 8])
    else
      AdvanceTStates(Delay[T mod FLineCycles mod 8]);
end;

procedure TZXConsole.ClockBus(Kind: TZ80BusCycle; Address, Count: Cardinal);
begin
  if Kind = zbcRefresh then
    FDiv.Refresh;
  if ExtendedHardware then
  begin
    var Value := Cardinal(Ord(Kind));
    if ReplayBusEvent(0, Address, Count, Value) then
      Exit;
    if (FUSC <> nil) and not (Kind in [zbcRefresh, zbcInternal, zbcIdle, zbcInternalMachine]) then
    begin
      PentagonEndCycle;
      if FBusAck or not ServiceUSC then
        raise EZXBusHeld.Create('DMA USC BUSACK');
    end;
    if (Kind = zbcAcknowledge) and (FUSC <> nil) then
      FUSC.Acknowledge;
    TurboBus(Kind, Address, Count);
    RememberBusEvent(0, Address, Count, Value);
    Exit;
  end;
  if FUSC <> nil then
  begin
    var Value := Cardinal(Ord(Kind));
    if ReplayBusEvent(0, Address, Count, Value) then
      Exit;
    if not (Kind in [zbcRefresh, zbcInternal, zbcIdle, zbcInternalMachine]) and not ServiceUSC then
      raise EZXBusHeld.Create('DMA USC BUSACK');
    if Kind = zbcAcknowledge then
      FUSC.Acknowledge;
  end;
  Inc(FCPUTStates, Count);
  try
    case Kind of
      zbcMemory, zbcOpcode:
        begin
          if FMachine.Scorpion and (Kind = zbcOpcode) and ((FTime and 1) <> 0) then
            AdvanceTStates(1);
          Contend(Address);
          AdvanceTStates(Count);
        end;
      zbcInternal:
        if ASICMachine then
        begin
          Contend(Address);
          AdvanceTStates(Count);
        end
        else
          for var i := 1 to Count do
          begin
            Contend(Address);
            Tick;
          end;
      zbcIO:
        begin
          if ASICMachine or FMachine.Scorpion or FMachine.Profi or FMachine.ByteFamily then
          begin
            AdvanceTStates(Count);
            Exit;
          end;
          if FMachine.TK then
          begin
          // MC16845 gates the address phase and the delayed /IORQ phase.
            var RAMAddress := (Address and $C000) = $4000;
            if RAMAddress then
              Contend(0, True);
            Tick;
            var T := FTime - (FContentionStart - 2);
            var Delay := 0;
            if (T >= 0) and (T div FLineCycles < 192) then
            begin
              var X := T mod FLineCycles;
              if RAMAddress and (X <= 128) then
              begin
                if X < 2 then
                  Delay := 6
                else if X < 122 then
                  Delay := 12 - Max(0, ((X - 2) and 7) - 1)
                else
                  Delay := Min(6, 129 - X);
              end
              else if ((Address and 1) = 0) and (X < 128) then
                Delay := Min(6, 7 - (X and 7));
            end;
            Inc(FIOWaitStates, Delay);
            AdvanceTStates(3 + Delay);
            Exit;
          end;
        // The 128K/+2 upper window also contends when an odd RAM bank is mapped.
          var HighContended := ContendedRAM(Address);
          if ((not FMachine.ByteFamily and not FMachine.Timex and not FMachine.Scorpion and ((Address and 1) = 0)) or
            (FMachine.ByteFamily and ((Address and $35) = $34)) or
            (FMachine.Timex and ((Address and 255) in [$F4, $FE, $FF]))) then
          begin
            if HighContended then
              Contend(0, True);
            Tick;
            Contend(0, True);
            AdvanceTStates(3);
          end
          else if HighContended then
            for var i := 1 to 4 do
            begin
              Contend(0, True);
              Tick;
            end
          else
            AdvanceTStates(4);
        end;
      zbcRefresh:
        begin
          FRefreshAddress := Address;
          AdvanceTStates(Count);
          FRefreshAddress := -1;
        end;
    else
      AdvanceTStates(Count);
    end;
  finally
    if FUSC <> nil then
      RememberBusEvent(0, Address, Count, Ord(Kind));
  end;
end;

procedure TZXConsole.FetchULA;
begin
  FFloatingBus := $FF;
  if FMachine.Model = zmByte01 then
  begin
    FetchByteVideo;
    Exit;
  end;
  if ProfiGraphics then
  begin
    FetchProfiVideo;
    Exit;
  end;
  var T := FTime - FFetchStart;
  if (T < 0) or (T div FLineCycles >= 192) then
    Exit;
  var X := T mod FLineCycles;
  if (X >= 128) or ((X and 7) >= 4) then
    Exit;
  var Y := T div FLineCycles;
  var Col := (X div 8) * 2 + ((X and 3) div 2);
  var Bank := 5;
  if F128 and ((FPaging and 8) <> 0) then
    Bank := 7;
  var Offset: Integer;
  var Bitmap := ((Y and $C0) shl 5) or ((Y and 7) shl 8) or ((Y and $38) shl 2) or Col;
  if (X and 1) = 0 then
    Offset := Bitmap
  else
    Offset := $1800 + (Y div 8) * 32 + Col;
  if FMachine.VideoTimex then
    case FTimex and 7 of
      1:
        Offset := Offset or $2000;
      2, 6:
        if (X and 1) <> 0 then
          Offset := Bitmap or $2000;
    end;
  // NMOS refresh in contended RAM interferes with the ULA's row address.
  if not BetaMachine and not ASICMachine and not FMachine.Timex and not FMachine.ByteFamily and not FMachine.TK and (FRefreshAddress >= $4000) and (FRefreshAddress < $8000) then
    Offset := (Offset and $3F80) or (FRefreshAddress and $7F);
  FFloatingBus := FRAM[Bank, Offset];
  if (X and 1) = 0 then
    FBitmapLatch[Col] := FFloatingBus
  else
    FAttributeLatch[Col] := FFloatingBus;
end;

function TZXConsole.GamaPortC(Status: Boolean): Byte;
begin
  // Unconnected TTL inputs are high. PC0 drives BANK SEL even in input mode.
  Result := FGamaLatch[2];
  if (FGamaControl and 1) <> 0 then
    Result := Result or $0F;
  if (FGamaControl and 8) <> 0 then
    Result := Result or $F0;
  if (FGamaControl and $64) = 4 then
  begin
    // Group B mode 1 reserves PC0..2; the spare PC3 belongs to group A.
    Result := Result and $F7;
    if ((FGamaControl and 8) <> 0) or ((FGamaLatch[2] and 8) <> 0) then
      Result := Result or 8;
  end;
  // No external strobed peripheral is attached: /STB and /ACK stay high,
  // input buffers remain empty, and output buffers await acknowledgement.
  if (FGamaControl and $60) <> 0 then
  begin
    var InputA := (FGamaControl and $10) <> 0;
    var Mode2 := (FGamaControl and $40) <> 0;
    Result := Result and $F7; // INTR A
    if not InputA or Mode2 then
    begin
      Result := Result and $37;
      if (FGamaPending and 1) = 0 then
      begin
        Result := Result or $80; // /OBF A
        if (FGamaEnable and $40) <> 0 then
          Result := Result or 8;
      end;
      if not Status or ((FGamaEnable and $40) <> 0) then
        Result := Result or $40; // /ACK pin, INTE output in status
    end;
    if InputA or Mode2 then
    begin
      Result := Result and $CF; // IBF A = 0
      if not Status or ((FGamaEnable and $10) <> 0) then
        Result := Result or $10; // /STB pin, INTE input in status
    end;
  end;
  if (FGamaControl and 4) <> 0 then
  begin
    Result := Result and $F8;
    if (FGamaControl and 2) = 0 then
      if (FGamaPending and 2) = 0 then
      begin
        Result := Result or 2; // /OBF B
        if (FGamaEnable and 4) <> 0 then
          Result := Result or 1; // INTR B replaces BANK SEL's general I/O bit
      end;
    if not Status or ((FGamaEnable and 4) <> 0) then
      Result := Result or 4;
  end;
end;

function TZXConsole.ReadGamaPort(RegisterIndex: Byte): Byte;
begin
  if RegisterIndex = 3 then
    Exit($FF); // Original NMOS 8255 control register is write-only.
  if RegisterIndex = 2 then
    Exit(GamaPortC(True));
  if RegisterIndex = 0 then
  begin
    if (FGamaControl and $40) <> 0 then
      Exit(0); // Mode 2 input buffer has received no /STB.
    if (FGamaControl and $10) = 0 then
      Exit(FGamaLatch[0]);
    if (FGamaControl and $20) <> 0 then
      Exit(0);
  end
  else
  begin
    if (FGamaControl and 2) = 0 then
      Exit(FGamaLatch[1]);
    if (FGamaControl and 4) <> 0 then
      Exit(0);
  end;
  Result := $FF;
  if ((RegisterIndex = 0) and (FOptions.Joystick in [0, 1])) or
    ((RegisterIndex = 1) and FOptions.SecondJoystick) then
  begin
    var Buttons := FInput.Buttons;
    if RegisterIndex = 1 then
      Buttons := FInput.Buttons2;
    Result := 0; // The factory Kempston adapter has eight pull-downs.
    if TEmulatorButton.Right in Buttons then
      Result := Result or 1;
    if TEmulatorButton.Left in Buttons then
      Result := Result or 2;
    if TEmulatorButton.Down in Buttons then
      Result := Result or 4;
    if TEmulatorButton.Up in Buttons then
      Result := Result or 8;
    if TEmulatorButton.A in Buttons then
      Result := Result or 16;
  end;
end;

procedure TZXConsole.WriteGamaPort(RegisterIndex, Value: Byte);
begin
  if RegisterIndex < 3 then
  begin
    if (RegisterIndex = 2) and ((FGamaControl and $64) <> 0) then
      // In strobed modes the spare upper C outputs are accessible via BSR only.
      FGamaLatch[2] := (FGamaLatch[2] and $F0) or (Value and $0F)
    else
      FGamaLatch[RegisterIndex] := Value;
    if (RegisterIndex = 0) and ((FGamaControl and $60) <> 0) and
      (((FGamaControl and $10) = 0) or ((FGamaControl and $40) <> 0)) then
      FGamaPending := FGamaPending or 1;
    if (RegisterIndex = 1) and ((FGamaControl and 6) = 4) then
      FGamaPending := FGamaPending or 2;
  end
  else if (Value and $80) <> 0 then
  begin
    FGamaControl := Value;
    FillChar(FGamaLatch, SizeOf(FGamaLatch), 0);
    FGamaPending := 0;
    FGamaEnable := 0;
  end
  else
  begin
    var Mask := Byte(1 shl ((Value shr 1) and 7));
    FGamaLatch[2] := FGamaLatch[2] and not Mask;
    FGamaEnable := FGamaEnable and not Mask;
    if (Value and 1) <> 0 then
    begin
      FGamaLatch[2] := FGamaLatch[2] or Mask;
      FGamaEnable := FGamaEnable or (Mask and $54);
    end;
  end;
end;

function TZXConsole.ReadPort(Address: Word): Byte;
begin
  if (FSID <> nil) and FSID.HandlesPort(Address) then
    Exit(FSID.ReadPort(Address));
  if MoonSoundSelected(Address) then
    Exit(FMoon.ReadPort(Address));
  Result := ReadOtherPort(Address);
  // Only A7 and /IORQ select the on-board PPI; A5/A6 select its register.
  // A0..A4 and the high byte are not decoded. Even aliases also select ULA.
  if FMachine.Gama and ((Address and $80) = 0) then
    Result := Result and ReadGamaPort((Address shr 5) and 3);
end;

function TZXConsole.ReadOtherPort(Address: Word): Byte;
const
  Matrix: array[0..7, 0..4] of Byte =
    ((vkShift, vkZ, vkX, vkC, vkV), (vkA, vkS, vkD, vkF, vkG),
    (vkQ, vkW, vkE, vkR, vkT), (vk1, vk2, vk3, vk4, vk5),
    (vk0, vk9, vk8, vk7, vk6), (vkP, vkO, vkI, vkU, vkY),
    (vkReturn, vkL, vkK, vkJ, vkH), (vkSpace, vkControl, vkM, vkN, vkB));
begin
  if (FMachine.Model = zmByte) and ((Address and $75) = $15) then
    FByteGate := True;
  if FMachine.Model = zmByte01 then
  begin
    if (Address and $9F) = 8 then
      Exit(FBeta.ReadPort(((Address shr 5) and 3) * 32 + $1F));
  end;
  var NextValue: Byte;
  if (FMachine.DAC = 6) and FNextDAC.ReadPort(Address, NextValue) then
    Exit(NextValue);
  var USCValue: Byte;
  if (FUSC <> nil) and FUSC.ReadPort(Address, USCValue) then
    Exit(USCValue);
  var GSValue: Byte;
  if (FGS <> nil) and FGS.HostRead(Address, GSValue) then
    Exit(GSValue);
  var DivValue: Byte;
  if FDiv.ReadPort(Address, DivValue) then
    Exit(DivValue);
  if FMachine.ByteFamily and ((Address and 1) = 0) then
    Exit(ReadByteKeyboard(Address));
  if FMachine.ULAPlus and (Address = $FF3B) then
    case FPaletteSelect shr 6 of
      0:
        Exit(FPalette[FPaletteSelect]);
      1:
        Exit(FPaletteMode);
    else
      Exit($FF);
    end;
  if FMachine.KempstonMouse then
    case Address of
      $FBDF:
        Exit(FMouseX);
      $FFDF:
        Exit(FMouseY);
      $FADF:
        Exit($FF xor ((FMouseButtons and 1) shl 1) xor ((FMouseButtons and 2) shr 1) xor (FMouseButtons and 4));
    end;
  if ExtendedHardware and ((FExpansion and $80) <> 0) and ((Address and $F008) = $B000) then
  begin
    FCMOSSeen := True;
    Exit(FCMOS.ReadData);
  end;
  var DiskPort := BetaPort(Address);
  if (FTRDOSActive or (FMachine.Profi and ((FProfiPaging and $20) <> 0))) and (DiskPort >= 0) then
    Exit(FBeta.ReadPort(DiskPort));
  if FMachine.Model = zmSpectrumPlus3 then
    case Address and $F002 of
      $2000:
        Exit(FPlus3FDC.ReadStatus);
      $3000:
        Exit(FPlus3FDC.ReadData);
    end;
  if FMachine.VideoTimex and ((Address and $FF) = $FF) then
    Exit(FTimex);
  if FMachine.Timex and ((Address and 255) = $F4) then
    Exit(FTimexMemory.HSR);
  if FMachine.Model = zmTimex2068 then
    case Address and 255 of
      $F5:
        begin
          if FTimexAYAddress = 14 then
            Exit($FF);
          Exit(FChip.ReadData);
        end;
      $F6:
        begin
          if FTimexAYAddress <> 14 then
            Exit(FChip.ReadData);
          Result := FChip.ReadData;
          for var J := 0 to 1 do
            if (Address and (256 shl J)) <> 0 then
            begin
              var Buttons := FInput.Buttons;
              if J = 1 then
                Buttons := FInput.Buttons2;
              if TEmulatorButton.Up in Buttons then
                Result := Result and $FE;
              if TEmulatorButton.Down in Buttons then
                Result := Result and $FD;
              if TEmulatorButton.Left in Buttons then
                Result := Result and $FB;
              if TEmulatorButton.Right in Buttons then
                Result := Result and $F7;
              if TEmulatorButton.A in Buttons then
                Result := Result and $7F;
            end;
          Exit;
        end;
    end;
  if (not FMachine.Timex and not FMachine.Scorpion and ((Address and 1) = 0)) or
    (FMachine.Scorpion and ((Address and $23) = $22)) or (FMachine.Timex and ((Address and 255) = $FE)) then
  begin
    if FMachine.TK then
    begin
      // LS365 drives keyboard bits 0..4; Q7 inverts EAR independently of BEEP.
      // D1 grounds D7 on Brazilian boards; otherwise D5/D7 see the video bus.
      Result := $1F or (FFloatingBus and $20);
      if FMachine.TKSpanish then
        Result := Result or (FFloatingBus and $80);
      if not FTape.Level then
        Result := Result or $40;
    end
    else
      Result := $BF;
    if not FMachine.TK and (FTape.Level or (not ASICMachine and not FHasTape and ((FULA and $10) <> 0))) then
      Result := Result or $40;
    for var Row := 0 to 7 do
      if (Address and (1 shl (8 + Row))) = 0 then
        for var Col := 0 to 4 do
          if FKeys[Matrix[Row, Col]] then
            Result := Result and not (1 shl Col);
    Exit;
  end;
  if not FMachine.Gama and ((FMachine.Scorpion and ((Address and $A3) = 3)) or
    ((FMachine.Model = zmTimex2048) and ((Address and $20) = 0)) or
    (not FMachine.Scorpion and (FMachine.Model <> zmTimex2048) and ((Address and $E0) = 0))) and (FOptions.Joystick in [0, 1]) then
  begin
    Result := 0;
    if FMachine.Scorpion then
      Result := FBeta.ReadPort($FF) and $C0;
    if TEmulatorButton.Right in FInput.Buttons then
      Result := Result or 1;
    if TEmulatorButton.Left in FInput.Buttons then
      Result := Result or 2;
    if TEmulatorButton.Down in FInput.Buttons then
      Result := Result or 4;
    if TEmulatorButton.Up in FInput.Buttons then
      Result := Result or 8;
    if TEmulatorButton.A in FInput.Buttons then
      Result := Result or 16;
    Exit;
  end;
  if (F128 or FMachine.TurboSound or FMachine.TurboSoundFM) and ((FMachine.Profi and ((Address and $E002) = $E000)) or (FMachine.Scorpion and ((Address and $E023) = $E021)) or (not FMachine.Scorpion and not FMachine.Profi and ((not ExtendedHardware and ((Address and $C002) = $C000)) or
    (ExtendedHardware and ((Address and $E002) = $E000))))) then
  begin
    if FMachine.TurboSoundFM then
      Exit(FTFM.ReadData);
    Exit(ActivePSG.ReadData);
  end;
  if BetaMachine or ASICMachine or FMachine.Timex or FMachine.ByteFamily or
    (FMachine.Gama and ((Address and $80) = 0)) then
    Result := $FF
  else
    Result := FFloatingBus;
end;

procedure TZXConsole.WritePort(Address: Word; Value: Byte);
begin
  WritePortPart(Address, Value, $1F);
end;

procedure TZXConsole.WritePortPart(Address: Word; Value, Parts: Byte; Timed: Boolean);

  procedure Notify(Device: Byte);
  begin
    if Timed then
      TransferEvent(5, 2, Device, Address, Value);
  end;

begin
  if (FSID <> nil) and FSID.HandlesPort(Address) then
  begin
    if (Parts and 16) <> 0 then
    begin
      FSID.WritePort(Address, Value);
      Notify(19);
    end;
    Exit;
  end;
  // CPLD IORQG suppresses motherboard I/O, including even-port ULA and paging.
  if MoonSoundSelected(Address) then
  begin
    if (Parts and 16) <> 0 then
    begin
      FMoon.WritePort(Address, Value);
      Notify(18);
    end;
    Exit;
  end;
  if FMachine.Gama and ((Address and $80) = 0) and ((Parts and 16) <> 0) then
    WriteGamaPort((Address shr 5) and 3, Value);
  if FMachine.ByteFamily then
  begin
    if ((Address and $15) = 4) and ((Parts and 16) <> 0) then
      WriteBytePIT(Address, Value);
    if FMachine.Model = zmByte01 then
    begin
      if (Address and $FF) = $F0 then
      begin
        if (Parts and 4) <> 0 then
        begin
          if (Value and $80) = 0 then
            FTRDOSActive := False
          else if (FByteMemory and $80) = 0 then
            FTRDOSActive := True;
          FByteMemory := Value;
        end;
        Exit;
      end;
      if (Address and $35) = 5 then
      begin
        if (Parts and 16) <> 0 then
          FByteVideo := Value;
        Exit;
      end;
      if (Address and $9F) = 8 then
      begin
        if (Parts and 16) <> 0 then
          FBeta.WritePort(((Address shr 5) and 3) * 32 + $1F, Value);
        Exit;
      end;
      if (Address and $9F) = 9 then
      begin
        if (Parts and 16) <> 0 then
          SetByteDisk(Value);
        Exit;
      end;
    end;
  end;
  if (Parts and 16) <> 0 then
    FDiv.WritePort(Address, Value);
  if ExtendedHardware and ((FExpansion and $80) <> 0) then
  begin
    case Address and $F008 of
      $D000:
        begin
          if (Parts and 16) <> 0 then
          begin
            FCMOS.Select(Value);
            FCMOSSeen := True;
            Notify(6);
          end;
          Exit;
        end;
      $B000:
        begin
          if (Parts and 16) <> 0 then
          begin
            FCMOS.WriteData(Value);
            FCMOSSeen := True;
            Notify(7);
          end;
          Exit;
        end;
    end;
  end;
  var DiskPort := BetaPort(Address);
  if (FTRDOSActive or (FMachine.Profi and ((FProfiPaging and $20) <> 0))) and (DiskPort >= 0) then
  begin
    if FMachine.Profi and (DiskPort = $FF) then
      Value := Value or $20;
    if (Parts and 16) <> 0 then
    begin
      FBeta.WritePort(DiskPort, Value);
      Notify(8);
    end;
    Exit;
  end;
  if FMachine.Profi and ((Address and $2002) = 0) and ((Address and 1) <> 0) then
  begin
    if (Parts and 4) <> 0 then
      FProfiPaging := Value;
    Exit;
  end;
  if FMachine.Scorpion and ((Parts and 4) <> 0) and ((Address and $C023) = $0021) then
  begin
    FScorpionPaging := Value;
    FScorpionROMOverride := False;
  end;
  if ASICMachine then
  begin
    if ((Parts and 4) <> 0) and ((Address and $F002) = $1000) then
    begin
      // Lock disables memory switching, but motor/printer outputs remain live.
      if (FPaging and $20) = 0 then
        FPlus3Paging := Value
      else
        FPlus3Paging := (FPlus3Paging and 7) or (Value and $F8);
      FPlus3FDC.SetLines(True, (FPlus3Paging and 8) <> 0, False, False);
    end;
    if (FMachine.Model = zmSpectrumPlus3) and ((Parts and 16) <> 0) and
      ((Address and $F002) = $3000) then
      FPlus3FDC.WriteData(Value);
  end;
  if (Parts and 16) <> 0 then
    WriteSoundExpansion(Address, Value);
  if FMachine.ULAPlus and ((Parts and 16) <> 0) then
    case Address of
      $BF3B:
        begin
          FPaletteSelect := Value;
          Notify(9);
        end;
      $FF3B:
        case FPaletteSelect shr 6 of
          0:
            begin
              FPalette[FPaletteSelect] := Value;
              UpdatePalette(FPaletteSelect);
              Notify(10);
            end;
          1:
            begin
              FPaletteMode := Value;
              Notify(10);
            end;
        end;
    end;
  if FMachine.VideoTimex and ((Address and $FF) = $FF) and ((Parts and 16) <> 0) then
  begin
    FTimex := Value;
    FTimexMemory.DEC := Value;
    Notify(11);
  end;
  if FMachine.Timex and ((Parts and 16) <> 0) and ((Address and 255) = $F4) then
    FTimexMemory.HSR := Value;
  if (FMachine.Model = zmTimex2068) and ((Parts and 8) <> 0) then
    case Address and 255 of
      $F5:
        begin
          FTimexAYAddress := Value and 15;
          FChip.WriteAddress(FTimexAYAddress);
        end;
      $F6:
        FChip.WriteData(Value);
    end;
  if ((not FMachine.ByteFamily and not FMachine.Timex and not FMachine.Scorpion and ((Address and 1) = 0)) or
    (FMachine.ByteFamily and ((Address and $35) = $34)) or
    (FMachine.Scorpion and ((Address and $23) = $22)) or (FMachine.Timex and ((Address and 255) = $FE))) and ((Parts and 1) <> 0) then
  begin
    if FMachine.Profi and ProfiGraphics and ((FProfiPaging and $20) <> 0) and ((FPaging and $20) <> 0) and ((Address and $80) = 0) then
      WriteProfiPalette(Address);
    FULA := Value;
    Notify(1);
  end;
  // In the 1024SL port1/port2 network, an even FE write takes priority over
  // paging and EFF7. AY has its own independent select and can overlap FE.
  var PageAllowed := not ExtendedHardware or ((Address and 1) <> 0);
  if ExtendedHardware and PageAllowed and ((Parts and 2) <> 0) and ((Address and $F008) = $E000) then
  begin
    FExpansion := Value;
    UpdateVideoSize;
    FVideoModesSeen := FVideoModesSeen or (Value and $63);
    Notify(2);
  end;
  if F128 or FMachine.TurboSound or FMachine.TurboSoundFM then
  begin
    if F128 and PageAllowed and ((Parts and 4) <> 0) and ((FMachine.Scorpion and ((Address and $C023) = $4021)) or (not FMachine.Scorpion and not ASICMachine and ((Address and $8002) = 0)) or
      (ASICMachine and ((Address and $C002) = $4000))) and
      (((FPaging and $20) = 0) or (FMachine.Profi and ((FProfiPaging and $10) <> 0)) or (ExtendedHardware and ((FExpansion and 4) = 0))) then
    begin
      FPaging := Value;
      Notify(3);
    end;
    if (Parts and 8) <> 0 then
    begin
      var Mask := Word($C002);
      if ExtendedHardware then
        Mask := $E002;
      var SelectAddress := Word($C000);
      var SelectData := Word($8000);
      if ExtendedHardware then
      begin
        SelectAddress := $E000;
        SelectData := $A000;
      end;
      if FMachine.Profi then
      begin
        Mask := $E002;
        SelectAddress := $E000;
        SelectData := $A000;
      end;
      if FMachine.Scorpion then
      begin
        Mask := $E023;
        SelectAddress := $E021;
        SelectData := $A021;
      end;
      if (Address and Mask) = SelectAddress then
      begin
        if FMachine.TurboSoundFM then
          FTFM.WriteAddress(Value)
        else if FMachine.TurboSound and ((Value = $FF) or (Value = $FE)) then
          FAYSelect := Value xor $FF
        else
          ActivePSG.WriteAddress(Value);
        Notify(4);
      end;
      if (Address and Mask) = SelectData then
      begin
        if FMachine.TurboSoundFM then
          FTFM.WriteData(Value)
        else
          ActivePSG.WriteData(Value);
        Notify(5);
      end;
    end;
  end;
end;

function TZXConsole.Color(Index: Byte): TAlphaColor;
const
  Colors: array[0..15] of TAlphaColor = (
    $FF000000, $FF0000CD, $FFCD0000, $FFCD00CD,
    $FF00CD00, $FF00CDCD, $FFCDCD00, $FFCDCDCD,
    $FF000000, $FF0000FF, $FFFF0000, $FFFF00FF,
    $FF00FF00, $FF00FFFF, $FFFFFF00, $FFFFFFFF);
begin
  Result := Colors[Index and 15];
end;

procedure TZXConsole.Tick;
begin
  if BetaMachine or (FMachine.Model = zmByte01) then
    FBeta.Tick;
  if FMachine.ByteFamily then
    TickBytePIT;
  if FMachine.Model = zmSpectrumPlus3 then
    FPlus3FDC.Advance(1);
  FetchULA;
  if FPentagon or ((FTime and 3) = 0) then
    FBorder := FULA and 7;
  if ExtendedHardware then
    FCMOS.Tick;
  if ExtendedHardware and ((FExpansion and $63) <> 0) then
    DrawExtendedVideo
  else
  begin
    if FMachine.Model = zmByte01 then
      DrawByteVideo
    else if FMachine.Profi then
      DrawProfiVideo
    else
      DrawCompatibleVideo;
  end;
  if FHasTape and (FFrameNumber >= UInt64(150 + TapeStartDelay)) then
  begin
    Inc(FTapePhase, 3500000);
    if FTapePhase >= FClock then
    begin
      Dec(FTapePhase, FClock);
      FTape.Tick;
    end;
  end;
  if FSID <> nil then
    FSID.Tick;
  if FMoon <> nil then
    FMoon.Tick;
  if FUSC <> nil then
    FUSC.Tick(FUSCBusAck);
  if FGS <> nil then
    FGS.Tick(FClock);
  if FMachine.TurboSoundFM then
    FTFM.Tick;
  Inc(FAYPhase);
  if FAYPhase = 16 then
  begin
    FAYPhase := 0;
    if (FHasAY or FMachine.TurboSound) and not FMachine.TurboSoundFM then
      FChip.GenerateNative(FLevelL, FLevelR);
    if FMachine.TurboSound then
      FChip2.GenerateNative(FLevel2L, FLevel2R);
  end;
  var Beeper := (Ord((FULA and $10) <> 0) * 0.22 + Ord((FULA and 8) <> 0) * 0.04) * FBeeperGain;
  if FMachine.ByteFamily then
    for var Channel := 0 to 2 do
      if FBytePIT[Channel].Enabled then
        Beeper := Beeper + (Ord(FBytePIT[Channel].Output) * 2 - 1) * 0.055 * FOptions.PITVolume / 100;
  var AYLeft := FLevelL;
  var AYRight := FLevelR;
  if FMachine.TurboSound then
  begin
    AYLeft := (AYLeft + FLevel2L) * 0.5;
    AYRight := (AYRight + FLevel2R) * 0.5;
  end;
  if FMachine.TurboSoundFM then
  begin
    AYLeft := 0;
    AYRight := 0;
  end;
  var DACLeft, DACRight: Double;
  DACLevels(DACLeft, DACRight);
  if FGS <> nil then
  begin
    var GSL, GSR: Double;
    FGS.Levels(GSL, GSR);
    DACLeft := DACLeft + GSL;
    DACRight := DACRight + GSR;
  end;
  if FUSC <> nil then
  begin
    var USCL, USCR: Double;
    FUSC.Levels(FMachine.DMAUSCStereo, USCL, USCR);
    DACLeft := DACLeft + USCL;
    DACRight := DACRight + USCR;
  end;
  if FMoon <> nil then
  begin
    var L, R: Double;
    FMoon.Levels(L, R);
    DACLeft := DACLeft + L;
    DACRight := DACRight + R;
  end;
  if FSID <> nil then
  begin
    var SIDLevel := FSID.Level;
    DACLeft := DACLeft + SIDLevel;
    DACRight := DACRight + SIDLevel;
  end;
  FSumL := FSumL + AYLeft * FAYGain + Beeper + DACLeft * FExpansionGain;
  FSumR := FSumR + AYRight * FAYGain + Beeper + DACRight * FExpansionGain;
  Inc(FSampleCount);
  Inc(FSamplePhase, 44100);
  if FSamplePhase >= FClock then
  begin
    Dec(FSamplePhase, FClock);
    if FMachine.TurboSoundFM then
    begin
      var SSGLeft, SSGRight, FMLeft, FMRight: Double;
      FTFM.Sample(SSGLeft, SSGRight, FMLeft, FMRight);
      FSumL := FSumL + (SSGLeft * FAYGain + FMLeft * FExpansionGain) * FSampleCount;
      FSumR := FSumR + (SSGRight * FAYGain + FMRight * FExpansionGain) * FSampleCount;
    end;
    var SAAL, SAAR: SmallInt;
    SAAL := 0;
    SAAR := 0;
    if FMachine.SAA1099 then
      FSAA.Sample(SAAL, SAAR);
    FSamples[FSampleFrames * 2] := EnsureRange(Round(FDCLeft.Process(FSumL / FSampleCount + SAAL / 32768.0 * 0.25 * FExpansionGain) * 24000), -32768, 32767);
    FSamples[FSampleFrames * 2 + 1] := EnsureRange(Round(FDCRight.Process(FSumR / FSampleCount + SAAR / 32768.0 * 0.25 * FExpansionGain) * 24000), -32768, 32767);
    Inc(FSampleFrames);
    FSampleCount := 0;
    FSumL := 0;
    FSumR := 0;
  end;
  Inc(FTime);
  Inc(FAbsoluteTStates);
  if FTime >= FFrameCycles then
  begin
    FTime := 0;
    Inc(FFrameNumber);
  end;
  Z80Interrupt(FCPU, Ord(InterruptActive(InterruptLength)));
end;

function TZXConsole.StepInstruction: Cardinal;
begin
  var Before := FAbsoluteTStates;
  if FScorpionNMI and (FCPU.ProgramCounter >= $4000) then
  begin
    FScorpionNMI := False;
    FScorpionROMOverride := True;
    FTRDOSActive := True;
    Z80NonMaskableInterrupt(FCPU);
  end;
  if ExtendedHardware or FMachine.DMAUSC then
  begin
    if ExtendedHardware and FBusAck and not PentagonServiceBusAck then
      Exit(FAbsoluteTStates - Before);
    if FInstructionActive then
    begin
      FCPU := FInstructionStart;
      FBusEventPosition := 0;
    end
    else
    begin
      Z80Interrupt(FCPU, Ord(InterruptActive(InterruptLength)));
      FUSCVector := $FF;
      if FUSC <> nil then
        FUSCVector := FUSC.InterruptVector((FTime < InterruptLength) and not (FMachine.VideoTimex and ((FTimex and $40) <> 0)));
      FInstructionStart := FCPU;
      FInstructionActive := True;
      FBusEventCount := 0;
      FBusEventPosition := 0;
    end;
    try
      Z80DoInstruction(FCPU, FCallbacks, OpcodeRead, False, FUSCVector);
    except
      on E: EZXBusHeld do
        Exit(FAbsoluteTStates - Before);
    end;
    if ExtendedHardware then
      PentagonEndCycle;
    FInstructionActive := False;
    FBusEventCount := 0;
    FBusEventPosition := 0;
  end
  else
  begin
    Z80Interrupt(FCPU, Ord(InterruptActive(InterruptLength)));
    Z80DoInstruction(FCPU, FCallbacks, OpcodeRead);
  end;
  var Snapshot: TBytes;
  var Kind: Byte;
  if FTape.TakeSnapshot(Snapshot, Kind) then
    if Kind = 0 then
      LoadZ80(Snapshot)
    else
      LoadSNA(Snapshot);
  Result := FAbsoluteTStates - Before;
end;

procedure TZXConsole.RunFrame;
begin
  FSampleFrames := 0;
  var Target := FFrameNumber + 1;
  while FFrameNumber < Target do
    StepInstruction;
end;

procedure TZXConsole.SetInput(const Input: TEmulatorInput; const Keys: TZXHostKeys);
begin
  FInput := Input;
  FKeys := Keys;
  // Optional keyboard joystick emulation is independent of physical keyboard input.
  if FOptions.Joystick in [0, 2] then
  begin
    FKeys[vkQ] := FKeys[vkQ] or (TEmulatorButton.Up in Input.Buttons);
    FKeys[vkA] := FKeys[vkA] or (TEmulatorButton.Down in Input.Buttons);
    FKeys[vkO] := FKeys[vkO] or (TEmulatorButton.Left in Input.Buttons);
    FKeys[vkP] := FKeys[vkP] or (TEmulatorButton.Right in Input.Buttons);
    FKeys[vkSpace] := FKeys[vkSpace] or (TEmulatorButton.A in Input.Buttons);
  end;
  if FOptions.Joystick in [4, 5] then
  begin
    var LeftKey := vk6;
    var RightKey := vk7;
    var DownKey := vk8;
    var UpKey := vk9;
    var FireKey := vk0;
    if FOptions.Joystick = 5 then
    begin
      LeftKey := vk1;
      RightKey := vk2;
      DownKey := vk3;
      UpKey := vk4;
      FireKey := vk5;
    end;
    FKeys[LeftKey] := FKeys[LeftKey] or (TEmulatorButton.Left in Input.Buttons);
    FKeys[RightKey] := FKeys[RightKey] or (TEmulatorButton.Right in Input.Buttons);
    FKeys[DownKey] := FKeys[DownKey] or (TEmulatorButton.Down in Input.Buttons);
    FKeys[UpKey] := FKeys[UpKey] or (TEmulatorButton.Up in Input.Buttons);
    FKeys[FireKey] := FKeys[FireKey] or (TEmulatorButton.A in Input.Buttons);
  end;
  if FOptions.SecondJoystick and not FMachine.Gama then
  begin
    FKeys[vk1] := FKeys[vk1] or (TEmulatorButton.Left in Input.Buttons2);
    FKeys[vk2] := FKeys[vk2] or (TEmulatorButton.Right in Input.Buttons2);
    FKeys[vk3] := FKeys[vk3] or (TEmulatorButton.Down in Input.Buttons2);
    FKeys[vk4] := FKeys[vk4] or (TEmulatorButton.Up in Input.Buttons2);
    FKeys[vk5] := FKeys[vk5] or (TEmulatorButton.A in Input.Buttons2);
  end;
  if FOptions.Joystick <> 3 then
  begin
    FKeys[vkReturn] := FKeys[vkReturn] or (TEmulatorButton.Start in Input.Buttons);
    FKeys[vk1] := FKeys[vk1] or (TEmulatorButton.Select in Input.Buttons);
  end;
  if FOptions.AutoLoad and FHasDisk and (FMachine.Model = zmByte01) and (FFrameNumber >= 600) and (FFrameNumber <= 619) then
    FKeys[vk1] := True;
  if FOptions.AutoLoad and FHasDisk and BetaMachine and (Length(FROM[5]) = 0) and
    not (FMachine.Profi and (FBeta.Disk <> nil) and (FBeta.Disk.SectorSize = 1024)) then
    case FFrameNumber of
      400..404:
        begin
          FKeys[vkShift] := True;
          FKeys[vk7] := True;
        end;
      410..414, 610..614:
        FKeys[vkReturn] := True;
      600..604:
        FKeys[vkR] := True;
    end;
  if FOptions.AutoLoad and (FPlus3Disk <> nil) and (FFrameNumber >= 150) and (FFrameNumber <= 154) then
    FKeys[vkReturn] := True; // The original +3 menu starts on Loader.
  if FOptions.AutoLoad and FHasTape and (FMachine.Model = zmByte01) and (FFrameNumber < 5) then
  begin
    FKeys[vkS] := True;
    FKeys[vkD] := True;
    FKeys[vkF] := True;
  end;
  var TapeFrame := FFrameNumber;
  if TapeFrame >= UInt64(TapeStartDelay) then
    Dec(TapeFrame, TapeStartDelay)
  else
    TapeFrame := 0;
  if FOptions.AutoLoad and FHasTape then
    case TapeFrame of
      100..104:
        FKeys[vkJ] := True;
      110..114, 120..124:
        begin
          FKeys[vkControl] := True;
          FKeys[vkP] := True;
        end;
      130..134:
        FKeys[vkReturn] := True;
    end;
end;

function TZXConsole.FramesPerSecond: Double;
begin
  Result := FClock / FFrameCycles;
end;

procedure TZXConsole.SerializeState(State: TStateArchive);
begin
  var ModelCode := Ord(FMachine.Model);
  State.Field(ModelCode, SizeOf(ModelCode));
  if (ModelCode < Ord(Low(TZXMachineModel))) or (ModelCode > Ord(High(TZXMachineModel))) then
    raise EReadError.Create('Unsupported Spectrum machine in snapshot');
  var DivKind: Integer := Ord(FMachine.DivType);
  State.Field(DivKind, 4);
  if (DivKind < 0) or (DivKind > Ord(High(TZXDivType))) then
    raise EReadError.Create('Invalid DivIDE/DivMMC kind');
  if State.Loading then
    FMachine.DivType := TZXDivType(DivKind);
  State.Field(FMachine.DivRAMKB, SizeOf(FMachine.DivRAMKB));
  FDiv.SerializeState(State);
  if (Ord(FDiv.Kind) <> DivKind) or ((FDiv.Kind = zdMMC) and ((FDiv.Banks = 64) <> (FMachine.DivRAMKB = 512))) then
    raise EReadError.Create('Mismatched DivIDE/DivMMC state');
  State.Field(FMachine.ULAPlus, SizeOf(FMachine.ULAPlus));
  State.Field(FMachine.TimexVideo, SizeOf(FMachine.TimexVideo));
  State.Field(FMachine.KempstonMouse, SizeOf(FMachine.KempstonMouse));
  State.Field(FMachine.TurboSound, SizeOf(FMachine.TurboSound));
  State.Field(FMachine.TurboSoundFM, SizeOf(FMachine.TurboSoundFM));
  State.Field(FMachine.SAA1099, SizeOf(FMachine.SAA1099));
  State.Field(FMachine.DAC, SizeOf(FMachine.DAC));
  State.Field(FMachine.NextDACMode, SizeOf(FMachine.NextDACMode));
  State.Field(FMachine.NextDACStartup, SizeOf(FMachine.NextDACStartup));
  State.Field(FMachine.GeneralSound, SizeOf(FMachine.GeneralSound));
  State.Field(FMachine.GeneralSoundRAMKB, SizeOf(FMachine.GeneralSoundRAMKB));
  State.Field(FMachine.SID, SizeOf(FMachine.SID));
  State.Field(FMachine.SIDModel, SizeOf(FMachine.SIDModel));
  State.Field(FMachine.SIDNTSC, SizeOf(FMachine.SIDNTSC));
  State.Field(FMachine.SIDInterface, SizeOf(FMachine.SIDInterface));
  State.Field(FMachine.SIDClock1MHz, SizeOf(FMachine.SIDClock1MHz));
  State.Field(FMachine.MoonSound, SizeOf(FMachine.MoonSound));
  State.Field(FMachine.MoonSoundIRQ, SizeOf(FMachine.MoonSoundIRQ));
  State.Field(FMachine.MoonSoundInDOS, SizeOf(FMachine.MoonSoundInDOS));
  State.Field(FMachine.DMAUSC, SizeOf(FMachine.DMAUSC));
  State.Field(FMachine.DMAUSCULABypass, SizeOf(FMachine.DMAUSCULABypass));
  State.Field(FMachine.DMAUSCStereo, SizeOf(FMachine.DMAUSCStereo));
  State.Field(FMachine.NeoGS, SizeOf(FMachine.NeoGS));
  State.Field(FMachine.NeoGSRAMKB, SizeOf(FMachine.NeoGSRAMKB));
  State.Field(FPalette, SizeOf(FPalette));
  State.Field(FPaletteSelect, SizeOf(FPaletteSelect));
  State.Field(FPaletteMode, SizeOf(FPaletteMode));
  State.Field(FMachine.ByteCompatibility, SizeOf(FMachine.ByteCompatibility));
  var TKMode := Ord(FMachine.TKTiming);
  State.Field(TKMode, 4);
  if (TKMode < 0) or (TKMode > Ord(High(TZXTKTiming))) then
    raise EReadError.Create('Invalid TK video timing state');
  if State.Loading then
    FMachine.TKTiming := TZXTKTiming(TKMode);
  State.Field(FMachine.TKSpanish, SizeOf(FMachine.TKSpanish));
  State.Field(FGamaControl, 1);
  State.Field(FGamaLatch, SizeOf(FGamaLatch));
  State.Field(FGamaPending, 1);
  State.Field(FGamaEnable, 1);
  if ((FGamaControl and $80) = 0) or (FGamaPending > 3) or ((FGamaEnable and $AB) <> 0) then
    raise EReadError.Create('Invalid Didaktik Gama PPI state');
  State.Field(FByteGate, SizeOf(FByteGate));
  State.Field(FByteMemory, 1);
  State.Field(FByteVideo, 1);
  State.Field(FByteDisk, 1);
  for var Channel := 0 to 2 do
  begin
    State.Field(FBytePIT[Channel], SizeOf(TZXByteCounter));
    var P := FBytePIT[Channel];
    if (P.Mode > 5) or (P.Access > 3) or (P.Reload < 0) or (P.Reload > 65536) or (P.Count < 0) or (P.Count > 65536) or (P.Phase < 0) or (P.Phase > 65536) then
      raise EReadError.Create('Invalid Byte PIT state');
  end;
  State.Field(FProfiPaging, 1);
  State.Field(FProfiPalette, SizeOf(FProfiPalette));
  State.Field(FProfiBitmap, SizeOf(FProfiBitmap));
  State.Field(FProfiAttr, SizeOf(FProfiAttr));
  State.Field(FScorpionPaging, 1);
  State.Field(FScorpionNMI, SizeOf(FScorpionNMI));
  State.Field(FScorpionROMOverride, SizeOf(FScorpionROMOverride));
  State.Field(FTimex, SizeOf(FTimex));
  FTimexMemory.SerializeState(State);
  State.Field(FTimexAYAddress, 1);
  if (FTimexMemory.DEC <> FTimex) or (FTimexAYAddress > 15) then
    raise EReadError.Create('Invalid Timex register state');
  State.Field(FMouseX, SizeOf(FMouseX));
  State.Field(FMouseY, SizeOf(FMouseY));
  State.Field(FMouseButtons, SizeOf(FMouseButtons));
  if State.Loading then
    for var i := 0 to 63 do
      UpdatePalette(i);
  State.Field(FExpansion, SizeOf(FExpansion));
  if State.Loading then
  begin
    SetMachine(FMachine.WithModel(TZXMachineModel(ModelCode)));
    UpdateVideoSize;
  end;
  State.Field(FUSCBusAck, SizeOf(FUSCBusAck));
  State.Field(FUSCVector, 1);
  if FUSCBusAck and (FUSC = nil) then
    raise EReadError.Create('DMA USC bus held without card');
  State.Field(FTurboPhase, SizeOf(FTurboPhase));
  State.Field(FCPUTStates, SizeOf(FCPUTStates));
  State.Field(FMemoryWaitStates, SizeOf(FMemoryWaitStates));
  State.Field(FIOWaitStates, SizeOf(FIOWaitStates));
  State.Field(FBusSlow, SizeOf(FBusSlow));
  State.Field(FBusClock, SizeOf(FBusClock));
  State.Field(FBusPortReady, SizeOf(FBusPortReady));
  State.Field(FBusRAMWait, SizeOf(FBusRAMWait));
  State.Field(FBusGrant, SizeOf(FBusGrant));
  State.Field(FBusVideoUsed, SizeOf(FBusVideoUsed));
  State.Field(FBusRAM, SizeOf(FBusRAM));
  State.Field(FBusIO, SizeOf(FBusIO));
  State.Field(FBusRefresh, SizeOf(FBusRefresh));
  State.Field(FBusAck, SizeOf(FBusAck));
  State.Field(FBusSample, SizeOf(FBusSample));
  State.Field(FBusCyclePending, SizeOf(FBusCyclePending));
  State.Field(FBusAckStates, SizeOf(FBusAckStates));
  State.Field(FBusAckEntries, SizeOf(FBusAckEntries));
  State.Field(FLastBusAck, SizeOf(FLastBusAck));
  State.Field(FLastBusResume, SizeOf(FLastBusResume));
  State.Field(FInstructionActive, SizeOf(FInstructionActive));
  State.Field(FInstructionStart, SizeOf(FInstructionStart));
  State.Field(FBusEventCount, SizeOf(FBusEventCount));
  if (FBusEventCount < 0) or (FBusEventCount > Length(FBusEvents)) then
    raise EReadError.Create('Invalid Z80 continuation');
  if FBusEventCount > 0 then
    State.Field(FBusEvents[0], FBusEventCount * SizeOf(TZXBusEvent));
  if State.Loading then
  begin
    FBusEventPosition := FBusEventCount;
    for var i := 0 to FBusEventCount - 1 do
      if (FBusEvents[i].Kind > 5) or (FBusEvents[i].Address > $FFFF) then
        raise EReadError.Create('Invalid Z80 bus event');
  end;
  State.Field(FTransferCounts, SizeOf(FTransferCounts));
  State.Field(FTransferLast, SizeOf(FTransferLast));
  if State.Loading then
    FTransferActive := False;
  State.Field(FVideoModesSeen, SizeOf(FVideoModesSeen));
  State.Field(FTurboSeen, SizeOf(FTurboSeen));
  State.Field(FCMOSSeen, SizeOf(FCMOSSeen));
  if State.Loading and ((FTurboPhase < 0) or (FTurboPhase > 7)) then
    raise EReadError.Create('Invalid Pentagon turbo phase');
  FCMOS.SerializeState(State);
  State.Field(FTRDOSActive, SizeOf(FTRDOSActive));
  State.Field(FHasDisk, SizeOf(FHasDisk));
  State.Field(FHasTape, SizeOf(FHasTape));
  var ServiceSize := Length(FROM[5]);
  State.Field(ServiceSize, SizeOf(ServiceSize));
  if (ServiceSize <> 0) and (ServiceSize <> 16384) and (ServiceSize <> 65536) then
    raise EReadError.Create('Invalid Pentagon service ROM state');
  if State.Loading then
    SetLength(FROM[5], ServiceSize);
  if ServiceSize > 0 then
    State.Field(FROM[5][0], ServiceSize);
  FBeta.SerializeState(State);
  State.Field(FPlus3Paging, SizeOf(FPlus3Paging));
  var HasPlus3Disk := FPlus3Disk <> nil;
  State.Field(HasPlus3Disk, SizeOf(HasPlus3Disk));
  if State.Loading then
  begin
    FPlus3FDC.Mount(nil);
    FreeAndNil(FPlus3Disk);
    if HasPlus3Disk then
      FPlus3Disk := TSGDisk.Create;
  end;
  if HasPlus3Disk then
    FPlus3Disk.SerializeState(State);
  FPlus3FDC.Mount(FPlus3Disk);
  FPlus3FDC.SerializeState(State);
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FPaging, SizeOf(FPaging));
  State.Field(FULA, SizeOf(FULA));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FAbsoluteTStates, SizeOf(FAbsoluteTStates));
  State.Field(FBitmapLatch, SizeOf(FBitmapLatch));
  State.Field(FAttributeLatch, SizeOf(FAttributeLatch));
  State.Field(FFloatingBus, SizeOf(FFloatingBus));
  State.Field(FBorder, SizeOf(FBorder));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FAYPhase, SizeOf(FAYPhase));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FSampleCount, SizeOf(FSampleCount));
  State.Field(FTapePhase, SizeOf(FTapePhase));
  State.Field(FLevelL, SizeOf(FLevelL));
  State.Field(FLevelR, SizeOf(FLevelR));
  State.Field(FSumL, SizeOf(FSumL));
  State.Field(FSumR, SizeOf(FSumR));
  State.Field(FDCLeft, SizeOf(FDCLeft));
  State.Field(FDCRight, SizeOf(FDCRight));
  FChip.SerializeState(State.Field);
  FChip2.SerializeState(State.Field);
  FSAA.SerializeState(State.Field);
  FTFM.SerializeState(State);
  if FTFM.Clock <> FClock then
    raise EReadError.Create('Mismatched Turbo Sound FM clock');
  State.Field(FAYSelect, SizeOf(FAYSelect));
  if FAYSelect > 1 then
    raise EReadError.Create('Invalid Turbo Sound chip select');
  State.Field(FDAC, SizeOf(FDAC));
  FNextDAC.SerializeState(State);
  if FSID <> nil then
  begin
    FSID.SerializeState(State);
    if (FSID.MotherboardClock <> FClock) or (FSID.InterfaceType <> FMachine.SIDInterface) or
      (FSID.FixedClock <> Ord(FMachine.SIDClock1MHz) * 1000000) then
      raise EReadError.Create('Mismatched SID interface state');
  end;
  if FMoon <> nil then
    FMoon.SerializeState(State);
  if FUSC <> nil then
    FUSC.SerializeState(State);
  if FGS <> nil then
    FGS.SerializeState(State);
  State.Field(FLevel2L, SizeOf(FLevel2L));
  State.Field(FLevel2R, SizeOf(FLevel2R));
  FTape.SerializeState(State);
  State.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));
end;

procedure TZXConsole.Load(const Data: TBytes; const Name: string; Tape128, Pentagon: Boolean; PentagonRAMKB: Integer);
begin
  Load(Data, Name, TZXMachineConfig.FromLegacy(Tape128, Pentagon, PentagonRAMKB));
end;

procedure TZXConsole.Load(const Data: TBytes; const Name: string; const Machine: TZXMachineConfig);
begin
  Reset(Machine);
  FHasTape := False;
  Machine.Validate;
  var Profile := Machine.Profile;
  var Ext := ExtractFileExt(Name).ToLower;
  if (Ext = '.mmc') or (Ext = '.ide') then
  begin
    if Machine.DivType = zdNone then
    begin
      var Config := Machine;
      Config.DivType := zdMMC;
      if Ext = '.ide' then
        Config.DivType := zdIDE;
      FMachine := Config;
      FDiv.Configure(Config.DivType, Config.DivRAMKB);
    end;
  end
  else if Ext = '.dck' then
  begin
    SetMachine(Machine.WithModel(zmTimex2068));
    FTimexMemory.Reset(FROM[18]);
    MountTimexCartridge(Data);
  end
  else if Ext = '.sna' then
    LoadSNA(Data)
  else if Ext = '.z80' then
    LoadZ80(Data)
  else if (Ext = '.trd') or (Ext = '.scl') then
  begin
    if Machine.DivType <> zdNone then
      raise EReadError.Create('Disable divIDE/divMMC to boot native TR-DOS disks; esxDOS virtual disks must be on the card');
    var DiskRAM := 128;
    if Profile.IsPentagon then
      DiskRAM := Profile.RAMSizeKB;
    if Machine.Scorpion or Machine.Profi then
      SetMachine(Machine)
    else
      SetModel(True, True, DiskRAM);
    if Machine.Scorpion or Machine.Profi then
      FPaging := $10;
    FBeta.Mount(Data, Ext = '.scl');
    FHasDisk := True;
    FTRDOSActive := True;
  end
  else if Ext = '.kdi' then
  begin
    if Machine.DivType <> zdNone then
      raise EReadError.Create('Disable CF/SD interfaces for native Byte-01 KDI disks');
    if Length(Data) <> 819200 then
      raise EReadError.Create('Byte-01 KDI requires 80 cylinders, two heads, five 1024-byte sectors');
    SetMachine(Machine.WithModel(zmByte01));
    FBeta.Mount(Data, False, 0, False, True);
    SetByteDisk(0);
    FHasDisk := True;
  end
  else if Ext = '.pro' then
  begin
    if not ((Length(Data) = 409600) or (Length(Data) = 819200)) then
      raise EReadError.Create('PRO must contain 80 cylinders, one or two heads and five 1024-byte sectors');
    if Machine.DivType <> zdNone then
      raise EReadError.Create('Disable divIDE/divMMC to boot native Profi CP/M disks');
    if not Machine.Profi then
      SetMachine(Machine.WithModel(zmProfi1024));
    FBeta.Mount(Data, False, 0, True);
    FHasDisk := True;
    FTRDOSActive := True;
  end
  else if Ext = '.dsk' then
  begin
    SetMachine(Machine.WithModel(zmSpectrumPlus3));
    MountPlus3Disk(Data);
  end
  else if (Ext = '.tap') or (Ext = '.tzx') then
  begin
    SetMachine(Machine);
    if ASICMachine then
      FPlus3Paging := 4;
    if F128 then
      FPaging := $10; // 128K RAM/AY, boot directly into 48 BASIC.
    FTape.Load(Data, Ext = '.tzx', F128);
    FHasTape := True;
    if not FOptions.TapeAutoPlay then
      FTape.Stop;
  end
  else
    raise EReadError.Create('Expected Spectrum .sna, .z80, .tap, .tzx, .trd, .scl or .dsk/.dck/.pro/.kdi/.mmc/.ide');
  if Machine.TK and ((Ext = '.sna') or (Ext = '.z80')) then
  begin
    if F128 then
      raise EReadError.Create('TK90X/TK95 imports require a 48K Spectrum snapshot');
    SetMachine(Machine);
  end;
  if Machine.Gama and ((Ext = '.sna') or (Ext = '.z80')) then
  begin
    if F128 then
      raise EReadError.Create('Didaktik Gama imports require a 48K Spectrum snapshot');
    SetMachine(Machine);
    WriteGamaPort(3, $92); // ROM's normal mode 0: A/B inputs, C outputs, bank 0.
  end;
  if Machine.ByteFamily and ((Ext = '.sna') or (Ext = '.z80')) then
  begin
    if F128 then
      raise EReadError.Create('Byte imports require a 48K Spectrum snapshot');
    if Machine.Model = zmByte01 then
    begin
      FRAM[1] := FRAM[5];
      FRAM[4] := FRAM[2];
      FRAM[5] := FRAM[0];
    end;
    SetMachine(Machine);
  end;
  if (Machine.Scorpion or Machine.Profi) and not F128 and ((Ext = '.sna') or (Ext = '.z80')) then
    FPaging := $10;
  if (Profile.IsPentagon or Machine.Scorpion or Machine.Profi) and (Ext <> '.dsk') and (Ext <> '.dck') and (Ext <> '.pro') and (Ext <> '.kdi') then
    SetMachine(Machine);
  if ExtendedHardware then
    FExpansion := $10; // Start in tape/legacy-compatible 3.5 MHz mode.
  UpdateVideoSize;
  if Ext = '.z80' then
    RestoreZ80Timing(Data);
  FAbsoluteTStates := FTime;
  FBorder := FULA and 7;
  ApplyOptions(FOptions);
end;

procedure TZXConsole.ResetByte;
begin
  FByteGate := False;
  FByteMemory := 0;
  FByteVideo := 0;
  FByteDisk := 0;
  FillChar(FBytePIT, SizeOf(FBytePIT), 0);
  for var i := 0 to 2 do
    FBytePIT[i].Access := 3;
end;

procedure TZXConsole.InitByteTiming;
var
  H, V, T, Start, Last, Count: Integer;
  Gate, HS, OldHS, Retrace, IRQ: Boolean;
  Blocked: array[0..69887] of Boolean;
begin
  // Original DD3/DD4 and DD5/DD6 counters. PROM D1 controls presets;
  // DD10 D5 and DD11 D4 arbitrate screen RAM. DD29 captures horizontal sync.
  H := $140;
  V := $F0;
  Gate := True;
  OldHS := (FROM[31][H] and 1) <> 0;
  Start := -1;
  Last := -1;
  Count := 0;
  FillChar(Blocked, SizeOf(Blocked), 0);
  for T := 0 to 209999 do
  begin
    var A := FROM[31][H and 511];
    var B := FROM[32][V and 511];
    HS := (A and 1) <> 0;
    Retrace := (A and $80) <> 0;
    if Retrace then
      Gate := True
    else if HS and not OldHS then
      Gate := False;
    IRQ := not (Gate or ((B and $80) <> 0));
    OldHS := HS;
    if IRQ and (Last <> T - 1) then
    begin
      if Start >= 0 then
      begin
        Count := T - Start;
        Break;
      end;
      Start := T;
    end;
    if IRQ then
      Last := T;
    if (Start >= 0) and (T - Start < 69888) then
      Blocked[T - Start] := ((A and $20) <> 0) and ((B and $10) = 0);
    for var Half := 0 to 1 do
    begin
      var LoadH := (FROM[31][H and 511] and 2) = 0;
      var OldBlank := (FROM[31][H and 511] and $80) = 0;
      Inc(H);
      var Carry := (H and 7) = 0;
      var Carry2 := Carry and ((H and $78) = 0);
      if Carry and LoadH then
        H := (H and $187) or $40;
      if Carry2 and LoadH then
        H := (H and $7F) or $100;
      H := H and 511;
      if (FROM[32][V and 511] and 2) = 0 then
        V := (V and $100) or $F0
      else if ((FROM[31][H] and $80) = 0) and not OldBlank then
        V := (V + 1) and 511;
    end;
  end;
  if Count <> 69888 then
    raise EReadError.Create('Invalid Byte timing PROM frame');
  var Delay := 0;
  for T := 69887 downto 0 do
  begin
    if Blocked[T] then
      Inc(Delay)
    else
      Delay := 0;
    FByteWait[T] := Delay;
  end;
end;

function TZXConsole.ByteRAM(Address: Word): Integer;
begin
  // The adapter DD13 latch selects RAM7 (DOS) versus RAM6 (BASIC)
  // in the low main-RAM window; A14/A15 opcode fetches release that latch.
  var Main := 4;
  if (FByteMemory and $18) <> 0 then
    Main := 6;
  case Address shr 14 of
    0:
      begin
        if (FByteMemory and $40) <> 0 then
          Exit(6 + Ord(FTRDOSActive));
        if (FByteMemory and 8) <> 0 then
          Exit(4);
        if (FByteMemory and 1) <> 0 then
          Exit(FByteMemory and 2);
        Exit(-1);
      end;
    1:
      begin
        if (FByteMemory and 8) <> 0 then
          Exit(5);
        if (FByteMemory and 2) <> 0 then
          Exit(3);
        Exit(1);
      end;
    2:
      Result := Main;
  else
    Result := Main + 1;
  end;
end;

function TZXConsole.ReadByteROM(Address: Word): Byte;
begin
  if FMachine.Model = zmByte01 then
    Exit(FROM[28][Address]);
  Result := FROM[27][Address];
  if not FByteGate then
    Exit;
  var Index := Address shr 7;
  if not FMachine.ByteCompatibility then
    Index := Index or $100;
  var Select := FROM[29][Index];
  if (Select and $10) = 0 then
    Result := FROM[30][((Select and 15) shl 7) or (Address and 127)];
end;

procedure TZXConsole.WriteBytePIT(Address: Word; Value: Byte);
begin
  var Channel := (Address shr 5) and 3;
  if Channel = 3 then
  begin
    Channel := Value shr 6;
    if Channel = 3 then
      Exit;
    if (Value and $30) = 0 then
      Exit; // No PIT read bus on Byte.
    var P: ^TZXByteCounter;
    P := @FBytePIT[Channel];
    P.Access := (Value shr 4) and 3;
    P.Mode := (Value shr 1) and 7;
    if P.Mode > 5 then
      Dec(P.Mode, 4);
    P.BCD := (Value and 1) <> 0;
    P.High := False;
    P.Enabled := False;
    P.Pending := False;
    P.Output := P.Mode <> 0;
    Exit;
  end;
  var P: ^TZXByteCounter;
  P := @FBytePIT[Channel];
  var N: Integer;
  case P.Access of
    1:
      N := Value;
    2:
      N := Value shl 8;
    3:
      begin
        if not P.High then
        begin
          P.Low := Value;
          P.High := True;
          Exit;
        end;
        N := (Value shl 8) or P.Low;
        P.High := False;
      end;
  else
    Exit;
  end;
  if P.BCD then
  begin
    N := (N and 15) + ((N shr 4) and 15) * 10 + ((N shr 8) and 15) * 100 + ((N shr 12) and 15) * 1000;
    N := N mod 10000;
    if N = 0 then
      N := 10000;
  end
  else if N = 0 then
    N := 65536;
  P.Reload := N;
  P.Pending := True;
end;

procedure TZXConsole.TickBytePIT;
begin
  // All three CLK inputs use the board's 3.5 MHz clock; GATE stays high.
  for var i := 0 to 2 do
  begin
    var P: ^TZXByteCounter;
    P := @FBytePIT[i];
    if P.Pending and not (P.Enabled and (P.Mode in [2, 3])) then
    begin
      P.Pending := False;
      P.Count := P.Reload;
      P.Phase := (P.Reload + 1) div 2;
      P.Output := P.Mode <> 0;
      P.Enabled := not (P.Mode in [1, 5]);
      Continue;
    end;
    if not P.Enabled then
      Continue;
    case P.Mode of
      0:
        begin
          if P.Count > 0 then
            Dec(P.Count);
          if P.Count = 0 then
          begin
            P.Output := True;
            P.Enabled := False;
          end;
        end;
      2:
        begin
          if P.Count <= 1 then
          begin
            P.Count := P.Reload;
            P.Output := True;
            P.Pending := False;
          end
          else
          begin
            Dec(P.Count);
            P.Output := P.Count <> 1;
          end;
        end;
      3:
        begin
          Dec(P.Phase);
          if P.Phase <= 0 then
          begin
            P.Output := not P.Output;
            P.Pending := False;
            P.Phase := P.Reload div 2;
            if P.Output then
              P.Phase := (P.Reload + 1) div 2;
            P.Phase := Max(1, P.Phase);
          end;
        end;
      4:
        begin
          if P.Count > 0 then
          begin
            Dec(P.Count);
            P.Output := P.Count <> 0;
          end
          else
          begin
            P.Output := True;
            P.Enabled := False;
          end;
        end;
    end;
  end;
end;

function TZXConsole.BytePITOutput(Channel: Integer): Boolean;
begin
  if not (Channel in [0..2]) then
    raise EArgumentOutOfRangeException.Create('VI53 channel');
  Result := FBytePIT[Channel].Output;
end;

procedure TZXConsole.SetByteDisk(Value: Byte);
begin
  FByteDisk := Value;
  var Control: Byte := $04 or ((Value shr 3) and 1) or (((Value xor 4) and 4) shl 2);
  if (Value and 2) <> 0 then
    Control := Control or $28;
  FBeta.WritePort($FF, Control);
end;

procedure TZXConsole.FetchByteVideo;
begin
  var T := FTime - FFetchStart;
  if (T < 0) or (T div FLineCycles >= 192) then
    Exit;
  var X := T mod FLineCycles;
  if (X >= 128) or ((X and 7) >= 4) then
    Exit;
  var Y := T div FLineCycles;
  var Col := (X div 8) * 2 + ((X and 3) div 2);
  var Bitmap := ((Y and $C0) shl 5) or ((Y and 7) shl 8) or ((Y and $38) shl 2) or Col;
  var Offset := Bitmap;
  if (FByteVideo and $80) <> 0 then
  begin
    if Odd(X) then
      Offset := Bitmap or $2000;
  end
  else
  begin
    var Mode := 0;
    if FMachine.VideoTimex then
      Mode := FTimex and 7;
    if Mode = 1 then
      Offset := Offset or $2000;
    if Odd(X) then
      if Mode in [2, 6] then
        Offset := Bitmap or $2000
      else
      begin
        Offset := $1800 + (Y div 8) * 32 + Col;
        if Mode = 1 then
          Offset := Offset or $2000;
      end;
  end;
  if (X and 1) = 0 then
    FBitmapLatch[Col] := FRAM[1, Offset]
  else
    FAttributeLatch[Col] := FRAM[1, Offset];
end;

procedure TZXConsole.DrawByteVideo;
begin
  var T := FTime - (FDisplayStart - 24 * FLineCycles - 16);
  if T < 0 then
    Exit;
  var Y := T div FLineCycles;
  var X := (T mod FLineCycles) * 4;
  if (Y >= 240) or (X >= 640) then
    Exit;
  for var i := 0 to 3 do
  begin
    var C := BorderColor;
    var SX := X + i - 64;
    var SY := Y - 24;
    if (SX >= 0) and (SX < 512) and (SY >= 0) and (SY < 192) then
      if (FByteVideo and $80) <> 0 then
      begin
        var Data := FBitmapLatch[SX div 16];
        if Odd(SX div 8) then
          Data := FAttributeLatch[SX div 16];
        C := DisplayColor(FByteVideo and $7F, (Data and ($80 shr (SX and 7))) <> 0);
      end
      else if TimexHiRes then
      begin
        var Data := FBitmapLatch[SX div 16];
        if Odd(SX div 8) then
          Data := FAttributeLatch[SX div 16];
        var Ink := ((FTimex shr 3) and 7) xor 7;
        var SetBit := (Data and ($80 shr (SX and 7))) <> 0;
        if FMachine.ULAPlus and (FPaletteMode = 1) then
        begin
          if SetBit then
            C := PaletteColor(24 + Ink)
          else
            C := PaletteColor(31 - Ink);
        end
        else
        begin
          var Index := Ink xor 7;
          if SetBit then
            Index := Ink;
          C := Color(Index or 8);
        end;
      end
      else
        C := DisplayColor(FAttributeLatch[SX div 16], (FBitmapLatch[SX div 16] and ($80 shr ((SX div 2) and 7))) <> 0);
    FPixels[Y * 2 * 640 + X + i] := C;
    FPixels[(Y * 2 + 1) * 640 + X + i] := C;
  end;
end;

function TZXConsole.ReadByteKeyboard(Address: Word): Byte;
const
  Keys: array[0..7, 0..4] of Byte =
    ((vkShift, vkZ, vkX, vkC, vkV), (vkA, vkS, vkD, vkF, vkG), (vkQ, vkW, vkE, vkR, vkT),
    (vk1, vk2, vk3, vk4, vk5), (vk0, vk9, vk8, vk7, vk6), (vkP, vkO, vkI, vkU, vkY),
    (vkReturn, vkL, vkK, vkJ, vkH), (vkSpace, vkControl, vkM, vkN, vkB));
  Extra: array[0..7] of Byte = ($BE, $DE, 0, 0, $DD, $DB, $BA, $BC);
var
  Rows: array[0..7] of Byte;

  procedure Press(Row, Col: Integer);
  begin
    Rows[Row] := Rows[Row] and not (1 shl Col);
  end;

  procedure Caps(Key: Byte; Row, Col: Integer);
  begin
    if FKeys[Key] then
    begin
      Press(0, 0);
      Press(Row, Col);
    end;
  end;

begin
  FillChar(Rows, SizeOf(Rows), $FF);
  for var Row := 0 to 7 do
  begin
    for var Col := 0 to 4 do
      if FKeys[Keys[Row, Col]] then
        Press(Row, Col);
    if (Extra[Row] <> 0) and FKeys[Extra[Row]] then
      Press(Row, 7);
  end;
  if FKeys[$BD] then
    Press(1, 5); // ЛАТ
  if FKeys[$DC] then
    Press(4, 5); // РУС
  if FKeys[$BB] then
    Press(5, 5); // ЛАТ/РУС
  Caps(vkLeft, 3, 4);
  Caps(vkRight, 4, 2);
  Caps(vkUp, 4, 3);
  Caps(vkDown, 4, 4);
  Caps(vkInsert, 3, 0);
  Caps(vkDelete, 3, 1);
  Caps(vkHome, 3, 2);
  Caps(vkEnd, 3, 3);
  Caps(vkBack, 7, 0);
  Caps(vkTab, 4, 0);
  Caps(vkCapital, 7, 1);
  if FKeys[vkLMenu] then
  begin
    Press(7, 1);
    Press(0, 1);
  end;
  if FKeys[vkRMenu] then
  begin
    Press(7, 1);
    Press(5, 0);
  end;
  Result := $FF;
  for var Row := 0 to 7 do
    if (Address and (256 shl Row)) = 0 then
      Result := Result and Rows[Row];
  if FTape.Level then
    Result := Result and $BF; // The native Byte EAR input is inverted.
end;

function TZXConsole.TapeStartDelay: Integer;
begin
  // Allow the original ROM's memory test/startup screen to enter the editor.
  if FMachine.TK then
    Exit(100);
  if FMachine.Model = zmGama89 then
    Exit(50);
  Result := 0;
end;

function TZXConsole.InterruptLength: Integer;
begin
  if FMachine.ByteFamily then
    Exit(33);
  if FMachine.Profi then
    Exit(28);
  Result := 32 + Ord(BetaMachine) * 4;
end;

function TZXConsole.ProfiGraphics: Boolean;
begin
  Result := FMachine.Profi and ((FProfiPaging and $80) <> 0);
end;

procedure TZXConsole.FetchProfiVideo;
begin
  var T := FTime - (FDisplayStart - 24 * FLineCycles - 4);
  if (T < 0) or (T div FLineCycles >= 240) then
    Exit;
  var X := T mod FLineCycles;
  if X >= 128 then
    Exit;
  var Y := T div FLineCycles;
  var Col := (X div 4) * 2 + ((X and 3) div 2);
  var Offset := ((Y and $C0) shl 5) or ((Y and 7) shl 8) or ((Y and $38) shl 2) or (Col div 2);
  if (Col and 1) = 0 then
    Offset := Offset or $2000;
  var Bank := 4;
  if (FPaging and 8) <> 0 then
    Bank := 6;
  if (X and 1) = 0 then
    FProfiBitmap[Col] := FRAM[Bank, Offset]
  else
    FProfiAttr[Col] := FRAM[(Bank + $34) and (FRAMSizeKB div 16 - 1), Offset];
end;

procedure TZXConsole.DrawProfiVideo;
begin
  // Stable 640x576 surface: 512x240 DS80 or doubled 256x192 Spectrum.
  var T := FTime - (FDisplayStart - 48 * FLineCycles - 16);
  if T < 0 then
    Exit;
  var Y := T div FLineCycles;
  var X := (T mod FLineCycles) * 4;
  if (Y >= 288) or (X >= 640) then
    Exit;
  for var i := 0 to 3 do
  begin
    var C := BorderColor;
    var SX := X + i - 64;
    if ProfiGraphics then
    begin
      var SY := Y - 24;
      if (SX >= 0) and (SX < 512) and (SY >= 0) and (SY < 240) then
      begin
        var Attr := FProfiAttr[SX div 8];
        var Index := ((Attr shr 3) and 7) or ((Attr shr 4) and 8);
        if (FProfiBitmap[SX div 8] and ($80 shr (SX and 7))) <> 0 then
          Index := (Attr and 7) or ((Attr shr 3) and 8);
        C := FProfiPalette[Index];
      end;
    end
    else
    begin
      var SY := Y - 48;
      if (SX >= 0) and (SX < 512) and (SY >= 0) and (SY < 192) then
        if TimexHiRes then
        begin
          var Data := FBitmapLatch[SX div 16];
          if Odd(SX div 8) then
            Data := FAttributeLatch[SX div 16];
          var Ink := ((FTimex shr 3) and 7) xor 7;
          var SetBit := (Data and ($80 shr (SX and 7))) <> 0;
          if FMachine.ULAPlus and (FPaletteMode = 1) then
          begin
            if SetBit then
              C := PaletteColor(24 + Ink)
            else
              C := PaletteColor(31 - Ink);
          end
          else
          begin
            var Index := Ink xor 7;
            if SetBit then
              Index := Ink;
            C := Color(Index or 8);
          end;
        end
        else
          C := DisplayColor(FAttributeLatch[SX div 16], (FBitmapLatch[SX div 16] and ($80 shr ((SX div 2) and 7))) <> 0);
    end;
    FPixels[(Y * 2) * 640 + X + i] := C;
    FPixels[(Y * 2 + 1) * 640 + X + i] := C;
  end;
end;

procedure TZXConsole.WriteProfiPalette(Address: Word);

  function Expand(Value: Cardinal): Cardinal;
  begin
    Result := (Value shl 5) or (Value shl 2) or (Value shr 1);
  end;

begin
  // The previous FE latch selects the DAC register; inverted A8..A15 carry RGB.
  var Value := Byte(not (Address shr 8));
  var B := Cardinal(Value and 3);
  B := B * 85; // Digital RGB332 approximation; physical DAC levels are board-dependent.
  FProfiPalette[(FULA xor 15) and 15] := $FF000000 or (Expand((Value shr 2) and 7) shl 16) or
    (Expand(Value shr 5) shl 8) or B;
end;

function TZXConsole.TimexHiRes: Boolean;
begin
  Result := FMachine.VideoTimex and ((FTimex and 7) = 6);
end;

procedure TZXConsole.UpdatePalette(Index: Integer);

  function Expand3(Value: Cardinal): Cardinal;
  begin
    Result := (Value shl 5) or (Value shl 2) or (Value shr 1);
  end;

begin
  var Value := FPalette[Index];
  var Blue := Cardinal(Value and 3);
  Blue := (Blue shl 1) or Cardinal(Ord(Blue <> 0));
  FPaletteColors[Index] := $FF000000 or (Expand3((Value shr 2) and 7) shl 16) or
    (Expand3(Value shr 5) shl 8) or Expand3(Blue);
end;

function TZXConsole.PaletteColor(Index: Byte): TAlphaColor;
begin
  Result := FPaletteColors[Index and 63];
end;

function TZXConsole.BorderColor: TAlphaColor;
begin
  if TimexHiRes then
  begin
    var Ink := ((FTimex shr 3) and 7) xor 7;
    if FMachine.ULAPlus and (FPaletteMode = 1) then
      Exit(PaletteColor(31 - Ink));
    Exit(Color((Ink xor 7) or 8));
  end;
  if FMachine.ULAPlus and (FPaletteMode = 1) then
    Exit(PaletteColor(8 + FBorder));
  Result := Color(FBorder);
end;

function TZXConsole.FlashActive: Boolean;
begin
  if FMachine.ByteFamily then
    Exit(((FFrameNumber div 25) and 1) <> 0);
  if FMachine.TK then
    Exit((FFrameNumber and 32) <> 0);
  Result := (FFrameNumber and 16) <> 0;
end;

function TZXConsole.DisplayColor(Attr: Byte; Ink: Boolean): TAlphaColor;
begin
  if FMachine.ULAPlus and (FPaletteMode = 1) then
  begin
    var Base := (Attr shr 6) * 16;
    if Ink then
      Exit(PaletteColor(Base + (Attr and 7)));
    Exit(PaletteColor(Base + 8 + ((Attr shr 3) and 7)));
  end;
  if ((Attr and $80) <> 0) and FlashActive then
    Ink := not Ink;
  var C := (Attr shr 3) and 7;
  if Ink then
    C := Attr and 7;
  Result := Color(C or ((Attr shr 3) and 8));
end;

function TZXConsole.VideoDisplayStart: Integer;
begin
  // Pentagon visible paper starts at 17989 T. Keep the 17984 T physical
  // counter origin for memory fetches and the 1024SL bus arbitration.
  Result := FDisplayStart;
  if FPentagon then
    Inc(Result, 5);
end;

procedure TZXConsole.DrawCompatibleVideo;
begin
  var T := FTime - (VideoDisplayStart - 24 * FLineCycles - 16);
  if T < 0 then
    Exit;
  var Y := T div FLineCycles;
  var X := (T mod FLineCycles) * 2;
  if (Y >= 240) or (X >= 320) then
    Exit;
  var Scale := 1;
  // Keep a stable 640x480 surface for mixed Timex screen modes within a frame.
  if FMachine.VideoTimex then
    Scale := 2;
  for var i := 0 to 2 * Scale - 1 do
  begin
    var SX := X * Scale + i - 32 * Scale;
    var SY := Y - 24;
    var C := BorderColor;
    if (SX >= 0) and (SX < 256 * Scale) and (SY >= 0) and (SY < 192) then
      if TimexHiRes then
      begin
        var Column := SX div 16;
        var Data := FBitmapLatch[Column];
        if ((SX div 8) and 1) <> 0 then
          Data := FAttributeLatch[Column];
        var SetBit := (Data and ($80 shr (SX and 7))) <> 0;
        var Ink := ((FTimex shr 3) and 7) xor 7;
        if FMachine.ULAPlus and (FPaletteMode = 1) then
        begin
          if SetBit then
            C := PaletteColor(24 + Ink)
          else
            C := PaletteColor(31 - Ink);
        end
        else
        begin
          var Index := Ink xor 7;
          if SetBit then
            Index := Ink;
          C := Color(Index or 8);
        end;
      end
      else
      begin
        var Pixel := SX div Scale;
        C := DisplayColor(FAttributeLatch[Pixel div 8],
          (FBitmapLatch[Pixel div 8] and ($80 shr (Pixel and 7))) <> 0);
      end;
    FPixels[(Y * Scale) * FWidth + X * Scale + i] := C;
    if Scale = 2 then
      FPixels[(Y * 2 + 1) * FWidth + X * 2 + i] := C;
  end;
end;

procedure TZXConsole.MoveMouse(DX, DY: Integer; Buttons: Byte);
begin
  if not FMachine.KempstonMouse then
    Exit;
  FMouseX := (Integer(FMouseX) + (DX mod 256) + 256) and 255;
  // Host Y grows downwards; the Kempston counter grows upwards.
  FMouseY := (Integer(FMouseY) - (DY mod 256) + 256) and 255;
  FMouseButtons := Buttons and 7;
end;

function TZXConsole.ActivePSG: TYM2149F;
begin
  Result := FChip;
  if FMachine.TurboSound and (FAYSelect = 1) then
    Result := FChip2;
end;

procedure TZXConsole.WriteSoundExpansion(Address: Word; Value: Byte);
begin
  if FUSC <> nil then
    FUSC.WritePort(Address, Value);
  if FGS <> nil then
    FGS.HostWrite(Address, Value);
  if FMachine.DAC = 6 then
    FNextDAC.WritePort(Address, Value);
  if FMachine.SAA1099 then
    case Address of
      $00FF:
        FSAA.WriteData(Value);
      $01FF:
        FSAA.WriteAddress(Value);
    end;
  var Port := Address and $FF;
  case FMachine.DAC of
    1:
      if Port = $FB then
        FDAC[0] := Value;
    2:
      if Port = $DD then
        FDAC[0] := Value;
    3:
      if Port = $B3 then
        FDAC[0] := Value;
    4:
      case Port of
        $0F:
          FDAC[0] := Value;
        $1F:
          FDAC[1] := Value;
        $4F:
          FDAC[2] := Value;
        $5F:
          FDAC[3] := Value;
      end;
    5:
      if Port = $DF then
        FDAC[0] := Value;
  end;
end;

procedure TZXConsole.DACLevels(out Left, Right: Double);
begin
  Left := 0;
  Right := 0;
  if FMachine.DAC = 0 then
    Exit;
  if FMachine.DAC = 6 then
  begin
    FNextDAC.Levels(Left, Right);
    Exit;
  end;
  if FMachine.DAC = 4 then
  begin
    Left := (Integer(FDAC[0]) + FDAC[1] - 256) / 256.0 * 0.25;
    Right := (Integer(FDAC[2]) + FDAC[3] - 256) / 256.0 * 0.25;
  end
  else
  begin
    Left := (Integer(FDAC[0]) - 128) / 128.0 * 0.25;
    Right := Left;
  end;
end;

function ZXWord(const Data: TBytes; Offset: Integer): Word;
begin
  if (Offset < 0) or (Offset > Length(Data) - 2) then
    raise EReadError.Create('Truncated Spectrum snapshot');
  Result := Word(Data[Offset]) or (Word(Data[Offset + 1]) shl 8);
end;

procedure TZXConsole.LoadSNA(const Data: TBytes);
begin
  if (Length(Data) <> 49179) and (Length(Data) <> 131103) and (Length(Data) <> 147487) then
    raise EReadError.Create('Invalid SNA snapshot size');
  // SNA has no 16K/+2 identifier: retain a compatible selected profile.
  if Length(Data) = 49179 then
  begin
    if not (FMachine.Model in [zmSpectrum16, zmTimex2048, zmTimex2068]) then
      SetModel(False);
  end
  // A 128K SNA does not identify the motherboard. Retain the selected
  // compatible paging profile (including expanded RAM and its bus timing).
  else if not FMachine.Profile.Has128Paging then
    SetModel(True);
  FCPU.i := Data[0];
  FCPU.LAlt := Data[1];
  FCPU.HAlt := Data[2];
  FCPU.EAlt := Data[3];
  FCPU.DAlt := Data[4];
  FCPU.CAlt := Data[5];
  FCPU.BAlt := Data[6];
  FCPU.FAlt := Data[7];
  FCPU.AAlt := Data[8];
  FCPU.L := Data[9];
  FCPU.H := Data[10];
  FCPU.E := Data[11];
  FCPU.D := Data[12];
  FCPU.C := Data[13];
  FCPU.B := Data[14];
  FCPU.IYL := Data[15];
  FCPU.IYH := Data[16];
  FCPU.IXL := Data[17];
  FCPU.IXH := Data[18];
  FCPU.InterruptsEnabled := Ord((Data[19] and 4) <> 0);
  FCPU.IFF2 := FCPU.InterruptsEnabled;
  FCPU.R := Data[20];
  FCPU.F := Data[21];
  FCPU.A := Data[22];
  FCPU.StackPointer := ZXWord(Data, 23);
  FCPU.InterruptMode := Data[25];
  if FCPU.InterruptMode > 2 then
    raise EReadError.Create('Invalid SNA interrupt mode');
  FULA := Data[26] and 7;
  Move(Data[27], FRAM[5, 0], 16384);
  Move(Data[16411], FRAM[2, 0], 16384);
  if F128 then
  begin
    FCPU.ProgramCounter := ZXWord(Data, 49179);
    FPaging := Data[49181];
    if Data[49182] <> 0 then
    begin
      if not (FMachine.Scorpion or BetaMachine) then
        SetModel(True, True);
      FTRDOSActive := True;
    end;
    var Bank := FPaging and 7;
    var Expected := 131103;
    if (Bank = 2) or (Bank = 5) then
      Expected := 147487;
    if Length(Data) <> Expected then
      raise EReadError.Create('Invalid bank count in SNA');
    Move(Data[32795], FRAM[Bank, 0], 16384);
    var P := 49183;
    for var i := 0 to 7 do
      if (i <> 5) and (i <> 2) and (i <> Bank) then
      begin
        Move(Data[P], FRAM[i, 0], 16384);
        Inc(P, 16384);
      end;
  end
  else
  begin
    Move(Data[32795], FRAM[0, 0], 16384);
    if FCPU.StackPointer < $4000 then
      raise EReadError.Create('SNA stack points into ROM');
    var SP := FCPU.StackPointer;
    if SP = $FFFF then
      raise EReadError.Create('SNA return address crosses ROM');
    if (FMachine.Model = zmSpectrum16) and (SP > $7FFE) then
      raise EReadError.Create('SNA return address is outside 16K RAM');
    FCPU.ProgramCounter := ReadMemory(SP) or (Word(ReadMemory(SP + 1)) shl 8);
    FCPU.StackPointer := (Cardinal(SP) + 2) and $FFFF;
  end;
end;

procedure TZXConsole.LoadZ80(const Data: TBytes);
var
  P, HeaderLength, Mode, N, Page, Bank: Integer;
  Seen: set of Byte;

  function Expand(Start, Size, Expected: Integer; Compressed: Boolean): TBytes;
  begin
    if (Start < 0) or (Size < 0) or (Start > Length(Data) - Size) then
      raise EReadError.Create('Truncated Z80 memory block');
    SetLength(Result, Expected);
    var Pos := Start;
    var OutPos := 0;
    var Finish := Start + Size;
    while (Pos < Finish) and (OutPos < Expected) do
    begin
      var Count := 1;
      var Value := Data[Pos];
      Inc(Pos);
      if Compressed and (Value = $ED) and (Pos < Finish) and (Data[Pos] = $ED) then
      begin
        if Pos > Finish - 3 then
          raise EReadError.Create('Truncated Z80 RLE run');
        Count := Data[Pos + 1];
        Value := Data[Pos + 2];
        Inc(Pos, 3);
        if Count = 0 then
          raise EReadError.Create('Zero Z80 RLE run');
      end;
      if Count > Expected - OutPos then
        raise EReadError.Create('Z80 RLE exceeds memory block');
      FillChar(Result[OutPos], Count, Value);
      Inc(OutPos, Count);
    end;
    if OutPos <> Expected then
      raise EReadError.Create('Incomplete Z80 memory block');
    if Pos <> Finish then
      if not ((Expected = 49152) and (Finish - Pos = 4) and
        (Data[Pos] = 0) and (Data[Pos + 1] = $ED) and
        (Data[Pos + 2] = $ED) and (Data[Pos + 3] = 0)) then
        raise EReadError.Create('Trailing data in Z80 memory block');
  end;

begin
  if Length(Data) < 30 then
    raise EReadError.Create('Truncated Z80 snapshot header');
  FCPU.A := Data[0];
  FCPU.F := Data[1];
  FCPU.C := Data[2];
  FCPU.B := Data[3];
  FCPU.L := Data[4];
  FCPU.H := Data[5];
  FCPU.ProgramCounter := ZXWord(Data, 6);
  FCPU.StackPointer := ZXWord(Data, 8);
  FCPU.i := Data[10];
  var Flags := Data[12];
  if Flags = 255 then
    Flags := 1;
  FCPU.R := (Data[11] and $7F) or ((Flags and 1) shl 7);
  FULA := (Flags shr 1) and 7;
  FCPU.E := Data[13];
  FCPU.D := Data[14];
  FCPU.CAlt := Data[15];
  FCPU.BAlt := Data[16];
  FCPU.EAlt := Data[17];
  FCPU.DAlt := Data[18];
  FCPU.LAlt := Data[19];
  FCPU.HAlt := Data[20];
  FCPU.AAlt := Data[21];
  FCPU.FAlt := Data[22];
  FCPU.IYL := Data[23];
  FCPU.IYH := Data[24];
  FCPU.IXL := Data[25];
  FCPU.IXH := Data[26];
  FCPU.InterruptsEnabled := Ord(Data[27] <> 0);
  FCPU.IFF2 := Ord(Data[28] <> 0);
  FCPU.InterruptMode := Data[29] and 3;
  if FCPU.InterruptMode > 2 then
    raise EReadError.Create('Invalid Z80 interrupt mode');
  if FCPU.ProgramCounter <> 0 then
  begin
    if not (FMachine.Model in [zmSpectrum16, zmTimex2048, zmTimex2068]) then
      SetModel(False);
    var Memory := Expand(30, Length(Data) - 30, 49152, (Flags and $20) <> 0);
    Move(Memory[0], FRAM[5, 0], 16384);
    Move(Memory[16384], FRAM[2, 0], 16384);
    Move(Memory[32768], FRAM[0, 0], 16384);
    Exit;
  end;
  HeaderLength := ZXWord(Data, 30);
  if not (HeaderLength in [23, 54, 55]) or (Length(Data) < 32 + HeaderLength) then
    raise EReadError.Create('Invalid Z80 extended header');
  FCPU.ProgramCounter := ZXWord(Data, 32);
  Mode := Data[34];
  if HeaderLength = 23 then
  begin
    if not (Mode in [0, 1, 3, 4, 9, 12, 10, 14, 15]) then
      raise EReadError.Create('Unsupported Z80 hardware model');
    SetModel(Mode in [3, 4, 9, 12], Mode = 9);
  end
  else
  begin
    if not (Mode in [0, 1, 3, 4, 5, 6, 7, 8, 9, 12, 13, 10, 14, 15]) then
      raise EReadError.Create('Unsupported Z80 hardware model');
    SetModel(Mode in [4, 5, 6, 7, 8, 9, 12, 13], Mode = 9);
  end;
  if (HeaderLength >= 54) and (Mode in [7, 8, 13]) then
  begin
    if Mode = 13 then
      SetMachine(FMachine.WithModel(zmSpectrumPlus2b))
    else
      SetMachine(FMachine.WithModel(zmSpectrumPlus3));
    if HeaderLength = 55 then
      FPlus3Paging := Data[86];
  end;
  if Mode = 10 then
  begin
    SetMachine(FMachine.WithModel(zmScorpion256));
    if HeaderLength = 55 then
      FScorpionPaging := Data[86];
  end;
  if Mode = 14 then
  begin
    FTimexMemory.Reset(nil);
    SetMachine(FMachine.WithModel(zmTimex2048));
  end;
  if Mode = 15 then
  begin
    FTimexMemory.Reset(FROM[18]);
    SetMachine(FMachine.WithModel(zmTimex2068));
  end;
  if FMachine.Timex then
  begin
    FTimexMemory.HSR := Data[35];
    FTimex := Data[36];
    FTimexMemory.DEC := FTimex;
  end;
  if Mode = 12 then
    SetMachine(FMachine.WithModel(zmSpectrumPlus2));
  // Z80 hardware-modifier flag: 48K -> 16K; Sinclair 128K -> grey +2.
  if (Data[37] and $80) <> 0 then
    if FMachine.Model = zmSpectrum48 then
      SetMachine(FMachine.WithModel(zmSpectrum16))
    else if FMachine.Model = zmSpectrum128 then
      SetMachine(FMachine.WithModel(zmSpectrumPlus2))
    else if FMachine.Model = zmSpectrumPlus3 then
      SetMachine(FMachine.WithModel(zmSpectrumPlus2b))
    else if not (FMachine.Model in [zmSpectrumPlus2, zmSpectrumPlus2b]) then
      raise EReadError.Create('Unsupported Z80 hardware modifier');
  if not FMachine.Timex and (Data[36] <> 0) then
    raise EReadError.Create('Z80 snapshot requires unsupported expansion hardware');
  if (HeaderLength >= 54) and ((Data[59] <> 0) or (Data[60] <> 0)) then
    raise EReadError.Create('Z80 snapshot requires paged expansion ROM');
  if F128 then
    FPaging := Data[35];
  for var i := 0 to 15 do
  begin
    FChip.WriteRegister(i, Data[39 + i]);
    if FMachine.TurboSoundFM then
    begin
      FTFM.WriteAddress(i);
      FTFM.WriteData(Data[39 + i]);
    end;
  end;
  FChip.WriteAddress(Data[38]);
  FTimexAYAddress := Data[38] and 15;
  if FMachine.TurboSoundFM then
    FTFM.WriteAddress(Data[38] and 15);
  Seen := [];
  P := 32 + HeaderLength;
  while P < Length(Data) do
  begin
    N := ZXWord(Data, P);
    if P > Length(Data) - 3 then
      raise EReadError.Create('Truncated Z80 page header');
    Page := Data[P + 2];
    Inc(P, 3);
    Bank := -1;
    if F128 then
    begin
      if (Page >= 3) and (Page <= 10 + 8 * Ord(FMachine.Scorpion)) then
        Bank := Page - 3;
    end
    else
      case Page of
        8:
          Bank := 5;
        4:
          Bank := 2;
        5:
          Bank := 0;
      end;
    var Compressed := N <> $FFFF;
    if not Compressed then
      N := 16384;
    var Memory := Expand(P, N, 16384, Compressed);
    Inc(P, N);
    if Bank >= 0 then
    begin
      if Bank in Seen then
        raise EReadError.Create('Duplicate Z80 RAM page');
      Include(Seen, Bank);
      Move(Memory[0], FRAM[Bank, 0], 16384);
    end;
  end;
  if (FMachine.Scorpion and (Seen <> [0..15])) or
    (F128 and not FMachine.Scorpion and (Seen <> [0..7])) or
    ((FMachine.Model = zmSpectrum16) and not (5 in Seen)) or
    ((not F128 and (FMachine.Model <> zmSpectrum16)) and (Seen <> [0, 2, 5])) then
    raise EReadError.Create('Missing Z80 RAM pages');
  RestoreZ80Timing(Data);
end;

procedure TZXConsole.RestoreZ80Timing(const Data: TBytes);
begin
  if (ZXWord(Data, 6) = 0) and (ZXWord(Data, 30) >= 54) then
  begin
    // V3 stores a descending counter within one quarter and a rotating quadrant.
    var Quarter := FFrameCycles div 4;
    var LowCounter := ZXWord(Data, 55);
    if (LowCounter >= Quarter) or (Data[57] > 3) then
      raise EReadError.Create('Invalid Z80 frame timing');
    FTime := (((Integer(Data[57]) + 1) and 3) * Quarter + Quarter - 1 - LowCounter) mod FFrameCycles;
  end;
end;

function TZXConsole.ExtendedHardware: Boolean;
begin
  Result := FPentagon and (FRAMSizeKB = 1024);
end;

function TZXConsole.GetTurbo: Boolean;
begin
  // Report the latched clock, including the DOS/refresh clock transition.
  Result := ExtendedHardware and not FBusSlow;
end;

function TZXConsole.PentagonDisplayActive: Boolean;
begin
  if (FExpansion and $40) <> 0 then
    Exit(True); // CPLD: bordo=0 in 384 mode.
  // CPLD raster counters advance on Z rising (phase 2), two master
  // half-periods after the base Tick. BUSRQ follows unregistered BORDO.
  var Pos := FTime - FDisplayStart - Ord(FTurboPhase < 2);
  Result := (Pos >= 0) and (Pos div FLineCycles < 192) and (Pos mod FLineCycles < 128);
end;

procedure TZXConsole.PentagonMasterEdge;
begin
  // P1024SL 2.2 trig[0..6], delay, penttrg1 and memtrg, with ideal
  // propagation. One step is 1/28 MHz; CAS rises at phase 5, OCAS is
  // high at phases 1..4. Simultaneously clocked DFFs sample OLD Q.
  FTurboPhase := (FTurboPhase + 1) and 7;
  if FTurboPhase = 0 then
    Tick;
  if (FTurboPhase and 1) = 0 then
  begin
    var OldClock := FBusClock;
    if FBusSlow then
      FBusClock := (FTurboPhase = 0) or (FTurboPhase = 2)
    else
      FBusClock := (FTurboPhase = 2) or (FTurboPhase = 6);
    if (FTurboPhase and 3) = 0 then
      FBusSlow := ((FExpansion and $10) <> 0) or (FTRDOSActive and FBusRefresh);
    // delay.d=IORQ or not(delay.q), clocked on CPU rising edges.
    if FBusClock and not OldClock then
      FBusPortReady := not FBusIO or not FBusPortReady;
    // count1 advances at Z rising. Its low bits reset the video lock.
    if (FTurboPhase = 2) and (((FTime - FDisplayStart + 1) and 3) = 3) then
      FBusVideoUsed := False;
  end;
  if FTurboPhase = 5 then
  begin
    var Grant := not FBusGrant and FBusRAM and not FBusVideoUsed;
    if Grant and not FBusGrant then
      FBusVideoUsed := PentagonDisplayActive and (((FTime - FDisplayStart + 1) and 3) <> 3);
    FBusGrant := Grant;
  end;
  // FPM DRAM latches data on CAS falling with /WE low. A late /WE
  // transition while CAS is already low is handled when MREQ is asserted.
  if FTurboPhase = 1 then
    PentagonRAMWrite;
  if FBusRefresh then
    FBusGrant := False; // asynchronous /RFSH clear
  if FBusGrant and (FTurboPhase in [1..4]) then
    FBusRAMWait := False;
end;

procedure TZXConsole.PentagonClockEdge(High: Boolean);
begin
  // Waiting for a real output transition also preserves shortened/lengthened
  // clock pulses when the turbo latch changes. It is not Count/2 rounding.
  repeat
    var OldClock := FBusClock;
    PentagonMasterEdge;
    if (OldClock <> FBusClock) and (FBusClock = High) then
      Exit;
  until False;
end;

function TZXConsole.PentagonWait: Boolean;
begin
  Result := not FBusSlow and (FBusRAMWait or not FBusPortReady);
end;

function TZXConsole.PentagonBusRequest: Boolean;
begin
  Result := ExtendedHardware and ((FExpansion and 1) <> 0) and PentagonDisplayActive;
end;

procedure TZXConsole.PentagonEndCycle;
begin
  if not FBusCyclePending then
    Exit;
  FBusCyclePending := False;
  // Sample was taken at the rising edge of the last T. This boundary is
  // the NEXT rising edge: the CPU now releases address/data/control buses.
  if not FBusSample then
    Exit;
  FBusAck := True;
  Inc(FBusAckEntries);
  FLastBusAck := FAbsoluteTStates * 8 + UInt64(FTurboPhase);
  FBusRAM := False;
  FBusIO := False;
  FBusRefresh := False;
  FRefreshAddress := -1;
end;

function TZXConsole.PentagonServiceBusAck: Boolean;
begin
  var Frame := FFrameNumber;
  while FBusAck do
  begin
    // Tx samples BUSRQ at its rising edge. BUSACK/bus ownership change
    // on the following rising edge, never at an asynchronous raster edge.
    var ReleaseBus := not PentagonBusRequest;
    PentagonClockEdge(False);
    PentagonClockEdge(True);
    Inc(FBusAckStates);
    if ReleaseBus then
    begin
      FBusAck := False;
      FLastBusResume := FAbsoluteTStates * 8 + UInt64(FTurboPhase);
    end;
    if (FFrameNumber <> Frame) and FBusAck then
      Exit(False);
  end;
  Result := True;
end;

function TZXConsole.ReplayBusEvent(Kind: Byte; Address, Count: Cardinal; var Value: Cardinal): Boolean;
begin
  Result := FInstructionActive and (FBusEventPosition < FBusEventCount);
  if not Result then
    Exit;
  var Event := FBusEvents[FBusEventPosition];
  if (Event.Kind <> Kind) or (Event.Address <> Address) or (Event.Count <> Count) or
    ((Kind in [0, 3, 5]) and (Event.Value <> Value)) then
    raise EReadError.Create('Z80 bus continuation mismatch');
  Value := Event.Value;
  Inc(FBusEventPosition);
  if FBusEventPosition = FBusEventCount then
    Z80Interrupt(FCPU, Ord(InterruptActive(InterruptLength)));
end;

procedure TZXConsole.RememberBusEvent(Kind: Byte; Address, Count, Value: Cardinal);
begin
  if not FInstructionActive then
    Exit;
  if FBusEventCount = Length(FBusEvents) then
    raise EReadError.Create('Z80 bus continuation overflow');
  var Event := Default(TZXBusEvent);
  Event.Kind := Kind;
  Event.Address := Address;
  Event.Count := Count;
  Event.Value := Value;
  FBusEvents[FBusEventCount] := Event;
  Inc(FBusEventCount);
  FBusEventPosition := FBusEventCount;
end;

procedure TZXConsole.SetTransferObserver(Observer: TZXTransferObserver; Context: Pointer);
begin
  FTransferObserver := Observer;
  FTransferContext := Context;
end;

function TZXConsole.TransferCount(Kind, Stage: Integer): UInt64;
begin
  if (Kind < 0) or (Kind > 5) or (Stage < 0) or (Stage > 2) then
    Exit(0);
  Result := FTransferCounts[Stage, Kind];
end;

function TZXConsole.LastTransferMaster(Kind, Stage: Integer): UInt64;
begin
  if (Kind < 0) or (Kind > 5) or (Stage < 0) or (Stage > 2) then
    Exit(0);
  Result := FTransferLast[Stage, Kind];
end;

procedure TZXConsole.TransferEvent(Kind, Stage, Device: Byte; Address, Value: Cardinal);
begin
  var Master := FAbsoluteTStates * 8 + UInt64(FTurboPhase);
  Inc(FTransferCounts[Stage, Kind]);
  FTransferLast[Stage, Kind] := Master;
  if Assigned(FTransferObserver) then
  begin
    var Event := Default(TZXTransferEvent);
    Event.Kind := Kind;
    Event.Stage := Stage;
    Event.Device := Device;
    Event.Address := Address;
    Event.Value := Value;
    Event.MasterClock := Master;
    Event.ClockHigh := FBusClock;
    Event.BusAck := FBusAck;
    FTransferObserver(FTransferContext, Event);
  end;
end;

procedure TZXConsole.PentagonRAMWrite;
begin
  if FTransferActive and not FTransferIO and FTransferWrite and
    FBusRAM and FBusGrant and not FBusRefresh and (FTurboPhase in [1..4]) then
  begin
    WriteMemory(FTransferAddress, FTransferValue);
    FTransferCommitted := True;
    TransferEvent(3, 1, 0, FTransferAddress, FTransferValue);
  end;
end;

function TZXConsole.ReadBusData(Kind: Byte; Address: Cardinal): Cardinal;
begin
  Result := 0;
  if ReplayBusEvent(Kind, Address, 0, Result) then
    Exit;
  if ExtendedHardware then
  begin
    if Kind = 2 then
    begin
      if Address <> FOpcodeAddress then
        raise EReadError.Create('Pentagon opcode latch mismatch');
      Result := FOpcodeLatch;
    end
    else
      Result := FinishTransfer(False, Address, 0);
  end
  else
    case Kind of
      1:
        Result := ReadMemory(Address);
      2:
        Result := FetchOpcode(Address);
      4:
        Result := ReadPort(Address);
    end;
  RememberBusEvent(Kind, Address, 0, Result);
end;

procedure TZXConsole.WriteBusData(Kind: Byte; Address, Value: Cardinal);
begin
  if ReplayBusEvent(Kind, Address, 0, Value) then
    Exit;
  if ExtendedHardware then
    FinishTransfer(True, Address, Value)
  else if Kind = 3 then
    WriteMemory(Address, Value)
  else
    WritePort(Address, Value);
  RememberBusEvent(Kind, Address, 0, Value);
end;

function TZXConsole.FinishTransfer(IsWrite: Boolean; Address, Value: Cardinal): Cardinal;
begin
  if not FTransferActive or (FTransferAddress <> Address) then
    raise EReadError.Create('Pentagon transfer mismatch');
  FTransferWrite := IsWrite;
  FTransferValue := Value;
  if FTransferIO then
  begin
    // FE decode becomes active with IORQ/WR just after T2 rising.
    if IsWrite then
      WritePortPart(Address, Value, 1, True);
    RunBusStates(zbcIO, Address, 1, 4);
  end
  else
  begin
    PentagonRAMWrite; // late write: /WE falls while CAS is already low
    RunBusStates(zbcMemory, Address, 0, 3, True);
  end;
  Result := FTransferLatch;
  FTransferActive := False;
  FTransferWrite := False;
end;

procedure TZXConsole.TurboBus(Kind: TZ80BusCycle; Address, Count: Cardinal);
begin
  if not (Kind in [zbcRefresh, zbcInternal, zbcIdle]) then
  begin
    PentagonEndCycle;
    if FBusAck then
      raise EZXBusHeld.Create('BUSACK');
  end;
  if FTransferActive then
    raise EReadError.Create('Unfinished Pentagon transfer');
  FBusCyclePending := False;
  FBusRAM := False;
  FBusIO := False;
  FBusRefresh := Kind = zbcRefresh;
  if FBusRefresh then
  begin
    FBusGrant := False;
    FRefreshAddress := Address;
  end;
  if Kind in [zbcMemory, zbcIO] then
  begin
    // The callback after this prefix supplies direction and write data. It
    // finishes the same transaction; no memory/port data callback runs late.
    FTransferActive := True;
    FTransferIO := Kind = zbcIO;
    FTransferWrite := False;
    FTransferCommitted := False;
    FTransferAddress := Address;
    FTransferValue := 0;
    FTransferLatch := 0;
    if Kind = zbcMemory then
    begin
      PentagonClockEdge(False); // T1 falling: address and write data become stable
      FBusRAM := (Address >= $4000) or ((FExpansion and 8) <> 0);
      if FBusRAM and not (FBusGrant and (FTurboPhase in [1..4])) then
        FBusRAMWait := True;
    end
    else
    begin
      PentagonClockEdge(False);
      PentagonClockEdge(True);
      Inc(FCPUTStates);
      if not FBusSlow then
        FTurboSeen := True;
      FBusIO := True; // IORQ asserted just after T2 rising
    end;
    Exit;
  end;
  RunBusStates(Kind, Address, 0, Count);
end;

procedure TZXConsole.RunBusStates(Kind: TZ80BusCycle; Address, First, Count: Cardinal; FirstHalfDone: Boolean);
begin
  var Memory := Kind in [zbcMemory, zbcOpcode];
  var RAM := Memory and ((Address >= $4000) or ((FExpansion and 8) <> 0));
  for var T := Integer(First) to Integer(Count) - 1 do
  begin
    if ((Kind = zbcIO) and (T = 1)) or ((Kind = zbcAcknowledge) and (T = 2)) then
      FBusIO := True;
    if (Kind = zbcAcknowledge) and (T = 5) then
    begin
      FBusIO := False;
      FBusRefresh := True;
      FBusGrant := False;
    end;
    if T = Integer(Count) - 1 then
      FBusSample := PentagonBusRequest;
    if not (FirstHalfDone and (T = Integer(First))) then
      PentagonClockEdge(False);
    if (Kind = zbcOpcode) and (T = 0) then
    begin
      if Address >= $4000 then
        FTRDOSActive := False
      else if ((Address and $FF00) = $3D00) and ((FPaging and $10) <> 0) then
        FTRDOSActive := True;
      FBusRAM := RAM;
      if RAM and not (FBusGrant and (FTurboPhase in [1..4])) then
        FBusRAMWait := True;
    end;
    // EFF7/7FFD are clocked on every falling CLK while IORQ/WR are active,
    // including automatic/inserted waits. Their writes precede WAIT sampling.
    if (Kind = zbcIO) and FTransferWrite then
      WritePortPart(Address, FTransferValue, 6, True);
    var SampleWait := (Memory and (T = 1)) or ((Kind = zbcIO) and (T = 2)) or ((Kind = zbcAcknowledge) and (T = 4));
    while SampleWait and PentagonWait do
    begin
      Inc(FCPUTStates);
      if Memory then
        Inc(FMemoryWaitStates)
      else
        Inc(FIOWaitStates);
      PentagonClockEdge(True);
      PentagonClockEdge(False);
      if (Kind = zbcIO) and FTransferWrite then
        WritePortPart(Address, FTransferValue, 6, True);
    end;
    if (Kind = zbcMemory) and (T = 2) then
    begin
      if FTransferWrite then
      begin
        if RAM and not FTransferCommitted then
          raise EReadError.Create('Pentagon DRAM write missed grant');
        TransferEvent(3, 0, 0, Address, FTransferValue); // /WR rises: CPU completes its write
      end
      else
      begin
        FTransferLatch := ReadMemory(Address);
        TransferEvent(1, 0, 0, Address, FTransferLatch);
      end;
      FBusRAM := False;
    end;
    if (Kind = zbcIO) and (T = 3) then
    begin
      if FTransferWrite then
      begin
        WritePortPart(Address, FTransferValue, 24, True); // trailing /WR: AY/CMOS/WD1793
        TransferEvent(5, 0, 0, Address, FTransferValue);
      end
      else
      begin
        FTransferLatch := ReadPort(Address);
        TransferEvent(4, 0, 0, Address, FTransferLatch);
      end;
      FBusIO := False;
    end;
    PentagonClockEdge(True);
    Inc(FCPUTStates);
    if not FBusSlow then
      FTurboSeen := True;
    if (Kind = zbcOpcode) and (T = 1) then
    begin
      // M1 samples data at T3 RISING, unlike ordinary memory and I/O reads.
      FOpcodeAddress := Address;
      FOpcodeLatch := ReadMemory(Address);
      TransferEvent(2, 0, 0, Address, FOpcodeLatch);
      FBusRAM := False;
      FBusRefresh := True;
      FBusGrant := False;
    end;
  end;
  FBusCyclePending := Kind <> zbcOpcode;
  FBusRAM := False;
  FBusIO := False;
  if Kind in [zbcRefresh, zbcAcknowledge] then
  begin
    FBusRefresh := False;
    FRefreshAddress := -1;
  end;
end;

procedure TZXConsole.UpdateVideoSize;
begin
  var W := 320;
  var H := 240;
  if FMachine.VideoTimex and (not ExtendedHardware or ((FExpansion and $63) = 0)) then
  begin
    W := 640;
    H := 480;
  end;
  if ExtendedHardware then
    if (FExpansion and $40) <> 0 then
    begin
      W := 384;
      H := 304;
    end
    else if ((FExpansion and 2) <> 0) and ((FExpansion and 1) = 0) then
    begin
      W := 640;
      H := 480;
    end;
  if FMachine.Profi then
  begin
    W := 640;
    H := 576;
  end;
  if FMachine.Model = zmByte01 then
  begin
    W := 640;
    H := 480;
  end;
  if (W = FWidth) and (H = FHeight) then
    Exit;
  FWidth := W;
  FHeight := H;
  SetLength(FPixels, W * H);
  for var i := 0 to High(FPixels) do
    FPixels[i] := Color(FULA and 7);
end;

procedure TZXConsole.DrawExtendedVideo;
const
  Base384: array[0..4] of Integer = ($C000, $4000, $4800, $5000, $D800);
  Attr384: array[0..4] of Integer = ($D000, $5800, $5900, $5A00, $D300);
  Disp384: array[0..5] of Integer = ($18, $2000, $2008, $2010, $2018, $08);
var
  Bank, Offset, AttrOffset, ByteValue, Attr, Ink, ScreenBank: Integer;

  function LogicalByte(Address: Integer): Byte;
  begin
    var B := ScreenBank;
    if Address >= $C000 then
      Dec(B);
    Result := FRAM[B, Address and $3FFF];
  end;

begin
  var Wide := (FExpansion and $40) <> 0;
  var Hires := not Wide and ((FExpansion and 2) <> 0) and ((FExpansion and 1) = 0);
  var Nibbles := (FExpansion and 1) <> 0;
  var Start := VideoDisplayStart - 24 * FLineCycles - 16;
  if Wide then
    Start := VideoDisplayStart - 64 * FLineCycles - 32;
  var T := FTime - Start;
  if T < 0 then
    Exit;
  var Y := T div FLineCycles;
  var X := (T mod FLineCycles) * 2;
  var ViewW := 320;
  var ViewH := 240;
  if Wide then
  begin
    ViewW := 384;
    ViewH := 304;
  end;
  if (Y >= ViewH) or (X >= ViewW) then
    Exit;
  ScreenBank := 5;
  if (FPaging and 8) <> 0 then
    ScreenBank := 7;
  var Count := 2;
  if Hires then
  begin
    Count := 4;
    X := X * 2;
  end;
  for var i := 0 to Count - 1 do
  begin
    var SX := X + i - 32;
    var SY := Y - 24;
    if Hires then
      SX := X + i - 64;
    var C := Integer(FBorder);
    if Wide then
    begin
      SX := X + i;
      SY := Y;
    end;
    var ActiveW := 256;
    if Hires then
      ActiveW := 512
    else if Wide then
      ActiveW := 384;
    var ActiveH := 192;
    if Wide then
      ActiveH := 304;
    if (SX >= 0) and (SX < ActiveW) and (SY >= 0) and (SY < ActiveH) then
    begin
      Offset := ((SY and $C0) shl 5) or ((SY and 7) shl 8) or ((SY and $38) shl 2) or (SX div 8);
      Bank := ScreenBank;
      if Wide then
      begin
        var Col := SX div 8;
        var Disp := Disp384[Col div 8] + (Col and 7) + (SY and 56) * 4;
        Offset := Base384[SY div 64] + Disp + (SY and 7) * 256;
        AttrOffset := Attr384[SY div 64] + Disp;
        ByteValue := LogicalByte(Offset);
        Attr := LogicalByte(AttrOffset);
      end
      else if Nibbles then
      begin
        // Four interleaved two-pixel bytes: C000,4000,E000,6000.
        var Pair := (SX div 2) and 3;
        if (Pair and 1) = 0 then
          Dec(Bank);
        if (Pair and 2) <> 0 then
          Offset := Offset or $2000;
        ByteValue := FRAM[Bank, Offset];
        Attr := 0;
      end
      else if Hires then
      begin
        var Col := SX div 8;
        Offset := ((SY and $C0) shl 5) or ((SY and 7) shl 8) or ((SY and $38) shl 2) or (Col div 2);
        if (Col and 1) <> 0 then
          Offset := Offset or $2000;
        ByteValue := FRAM[Bank, Offset];
        Attr := $38;
      end
      else
      begin
        ByteValue := FRAM[Bank, Offset];
        // Hardware multicolor: attribute follows bitmap line addressing in +2000.
        Attr := FRAM[Bank, Offset or $2000];
      end;
      if Nibbles then
      begin
        if (SX and 1) = 0 then
          C := (ByteValue and 7) or ((ByteValue shr 3) and 8)
        else
          C := ((ByteValue shr 3) and 7) or ((ByteValue shr 4) and 8);
      end
      else
      begin
        Ink := Ord((ByteValue and ($80 shr (SX and 7))) <> 0);
        if ((Attr and $80) <> 0) and ((FFrameNumber and (16 shl Ord(FMachine.TK))) <> 0) then
          Ink := 1 - Ink;
        if Ink <> 0 then
          C := Attr and 7
        else
          C := (Attr shr 3) and 7;
        C := C or ((Attr shr 3) and 8);
      end;
    end;
    if Hires then
    begin
      FPixels[(Y * 2) * FWidth + X + i] := Color(C);
      FPixels[(Y * 2 + 1) * FWidth + X + i] := Color(C);
    end
    else
      FPixels[Y * FWidth + X + i] := Color(C);
  end;
end;

initialization
  ConstantInitialise;

end.

