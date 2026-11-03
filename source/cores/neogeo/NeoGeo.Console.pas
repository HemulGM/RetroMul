unit NeoGeo.Console;

interface

uses
  System.SysUtils, System.Classes, HW.M68k, HW.Z80, Core.Emulation.Types,
  Core.InputConfig, NeoGeo.Cartridge, NeoGeo.Video, NeoGeo.Sound, Core.Snapshots,
  NeoGeoCD.Controller;

type
  TNeoGeoProtection = (ngpOther,
    ngpCt2k3sp, ngpCthd2k3, ngpFatfury2, ngpGarou, ngpGarouh,
    ngpIrrmaze, ngpJockeygp, ngpKf2k3bl, ngpKf2k3pl, ngpKf2k3upl,
    ngpKof10th, ngpKof2000, ngpKof2003, ngpKof2003h, ngpKof98,
    ngpKof99, ngpKog, ngpMs5plus, ngpMslug3, ngpMslug3a, ngpMslug5,
    ngpMslugx, ngpNeogeoMj, ngpSvc, ngpSvcboot, ngpSvcsplus, ngpVliner);

  TNeoGeoConsole = class
  private
    FCart: TNeoGeoCartridge;
    FCD: TNeoGeoCDController;
    FProtection: TNeoGeoProtection;
    FCPU: TM68kState;
    FCPUCallbacks: TM68kReadWriteCallbacks;
    FZ80: TZ80State;
    FZCallbacks: TZ80ReadAndWriteCallbacks;
    FRAM, FBackup: array[0..$FFFF] of Byte;
    FZRAM: array[0..$7FF] of Byte;
    FBanks: array[0..3] of Integer;
    FProgramBank: Integer;
    FSmaRandom: Word;
    FKof98Overlay: Byte;
    FSlugCommand, FSlugCounter: Word;
    FFuryShift: Cardinal;
    FPvcRAM: array[0..$FFF] of Word;
    FCartRAM: array[0..$FFFF] of Word;
    FSpecialBank: Integer;
    FBootOverlay: Word;
    FInputSelect: Byte;
    FTrackX, FTrackY: Byte;
    FInitialFixed: TBytes;
    FCartVectors, FCartAudio, FBackupUnlocked: Boolean;
    FNMIEnabled, FCommandPending, FInZ80: Boolean;
    FCommand, FReply: Byte;
    FInputs: TEmulatorInput;
    FInputPorts: TCoreInputPorts;
    FCoin1, FCoin2: Integer;
    FIRQ1, FIRQ2, FIRQ3: Boolean;
    FIRQControl: Word;
    FDisplayCounter: Cardinal;
    FIRQDeadline: Int64;
    FCPUTime, FZTime, FSoundTime, FCPUBase, FBusTime, FFrameTime: Int64;
    FFrameNumber: UInt64;
    FProgramStarted: Boolean;
    FRenderingLine: Integer;
    FBatteryDirty: Boolean;
    FCard: TBytes;
    FCardInserted, FCardReadOnly, FCardLock1, FCardUnlock2, FCardAttribute, FCardDirty: Boolean;
    FCardBank: Byte;
    FDMASource, FDMATarget, FDMARemaining, FDMAIndex: Cardinal;
    FDMAMode: Word;
    FDMAPeriod: Integer;
    FWatchdog: Integer;
    FRTCControl, FRTCCommand, FRTCBits: Integer;
    FRTCShift: UInt64;
    FRTCReading: Boolean;
    FRTCMode, FRTCTPPeriod: Integer;
    FRTCEpoch, FRTCTestBase: Int64;
    FRTCCalendar: UInt64;
    FRTCTesting, FRTCInitialized: Boolean;
    function CDRead(Address: Cardinal; HighByte, LowByte: Boolean; out Value: Word): Boolean;
    function CDWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
    procedure CDDMA;
    procedure AdvanceDMA(Time: Int64);
    procedure DMAStep;
    function ExtraRead(Address: Cardinal; out Value: Word): Boolean;
    function ExtraWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
    function HasBootRAM: Boolean;
    function MahjongByte: Byte;
    function SMARead(Address: Cardinal; out Value: Word): Boolean;
    function SMAWrite(Address: Cardinal; Value: Word): Boolean;
    function HasPVC: Boolean;
    procedure PVCWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
    function FuryRead(Address: Cardinal): Word;
    procedure FuryWrite(Address: Cardinal; Value: Word);
    function ROMByte(const Data: TBytes; Address: Integer): Byte; inline;
    function PadByte(const Buttons: TEmulatorButtons): Byte;
    procedure UpdateIRQ;
    procedure SyncSound(Target: Int64);
    procedure SyncRaster;
    procedure SyncZ80(Target: Int64);
    procedure RTCWrite(Value: Byte);
    function RTCData: Boolean;
    function RTCCounter: UInt64;
    function ReadZMemory(Address: Word): Byte;
    procedure WriteZMemory(Address: Word; Value: Byte);
    function ReadZPort(Address: Word): Byte;
    procedure WriteZPort(Address: Word; Value: Byte);
    function ReadBus(Address: Cardinal; HighByte, LowByte: Boolean): Word;
    procedure WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
  public
    Video: TNeoGeoVideo;
    Sound: TNeoGeoSound;
    constructor Create(Cartridge: TNeoGeoCartridge);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame;
    procedure SetInput(const Input: TEmulatorInput);
    procedure ConfigureInputPorts(const Ports: TCoreInputPorts);
    procedure InsertCoin(Player: Integer);
    procedure LoadBattery(const Data: TBytes);
    procedure SetMemoryCard(Inserted, ReadOnly: Boolean);
    procedure LoadMemoryCard(const Data: TBytes);
    function MemoryCardData: TBytes;
    function BatteryData: TBytes;
    function RTCBatteryData: TBytes;
    procedure LoadRTCBattery(const Data: TBytes);
    function ReadWord(Address: Cardinal): Word;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    procedure WriteWord(Address: Cardinal; Value: Word);
    procedure SerializeState(State: TStateArchive);
    procedure MarkBatteryDirty;
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetFPS: Double;
    function GetSamples: TArray<SmallInt>;
    function GetSampleFrames: Integer;
    property Width: Integer read GetWidth;
    property Height: Integer read GetHeight;
    property FramesPerSecond: Double read GetFPS;
    property Samples: TArray<SmallInt> read GetSamples;
    property SampleFrames: Integer read GetSampleFrames;
    property FrameNumber: UInt64 read FFrameNumber;
    property BatteryDirty: Boolean read FBatteryDirty;
    property MemoryCardDirty: Boolean read FCardDirty;
    property CDController: TNeoGeoCDController read FCD;
    property CPUState: TM68kState read FCPU;
  end;

implementation

uses
  NeoGeo.Protection, NeoGeo.Bootleg, System.Math, System.DateUtils;

function CPURead(UserData: Pointer; Address: Cardinal; DoHighByte, DoLowByte: Byte; CurrentCycle: Cardinal; var TerminateEarly: Byte): Cardinal;
begin
  var C := TNeoGeoConsole(UserData);
  C.FBusTime := C.FCPUBase + Int64(CurrentCycle) * 2;
  Result := C.ReadBus((Address and $7FFFFF) shl 1, DoHighByte <> 0, DoLowByte <> 0);
  if (C.FCD = nil) and (Address >= $400000) and (Address < $600000) then
    Inc(C.FCPUBase, 4);
end;

procedure CPUWrite(UserData: Pointer; Address: Cardinal; DoHighByte, DoLowByte: Byte; CurrentCycle: Cardinal; var TerminateEarly: Byte; Value: Cardinal);
begin
  var C := TNeoGeoConsole(UserData);
  C.FBusTime := C.FCPUBase + Int64(CurrentCycle) * 2;
  C.WriteBus((Address and $7FFFFF) shl 1, Word(Value and $FFFF), DoHighByte <> 0, DoLowByte <> 0);
  if (C.FCD = nil) and (Address >= $400000) and (Address < $600000) then
    Inc(C.FCPUBase, 4);
end;

procedure CPUAcknowledge(UserData: Pointer);
begin
  // The LSPC pending latch is cleared only by writes to $3c000c.
end;

function ZRead(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TNeoGeoConsole(UserData).ReadZMemory(Word(Address and $FFFF));
end;

procedure ZWrite(UserData: Pointer; Address, Value: Cardinal);
begin
  TNeoGeoConsole(UserData).WriteZMemory(Word(Address and $FFFF), Byte(Value and $FF));
end;

function ZPortRead(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TNeoGeoConsole(UserData).ReadZPort(Word(Address and $FFFF));
end;

procedure ZPortWrite(UserData: Pointer; Address, Value: Cardinal);
begin
  TNeoGeoConsole(UserData).WriteZPort(Word(Address and $FFFF), Byte(Value and $FF));
end;

constructor TNeoGeoConsole.Create(Cartridge: TNeoGeoCartridge);
begin
  inherited Create;
  if Cartridge = nil then
    raise EArgumentNilException.Create('Cartridge');

  FCart := Cartridge;

  // Protection is immutable cartridge metadata. Classify it once so bus
  // accesses do not manage temporary strings or repeat string comparisons.
  FProtection := ngpOther;
  if FCart.Protection = 'ct2k3sp' then
    FProtection := ngpCt2k3sp
  else if FCart.Protection = 'cthd2k3' then
    FProtection := ngpCthd2k3
  else if FCart.Protection = 'fatfury2' then
    FProtection := ngpFatfury2
  else if FCart.Protection = 'garou' then
    FProtection := ngpGarou
  else if FCart.Protection = 'garouh' then
    FProtection := ngpGarouh
  else if FCart.Protection = 'irrmaze' then
    FProtection := ngpIrrmaze
  else if FCart.Protection = 'jockeygp' then
    FProtection := ngpJockeygp
  else if FCart.Protection = 'kf2k3bl' then
    FProtection := ngpKf2k3bl
  else if FCart.Protection = 'kf2k3pl' then
    FProtection := ngpKf2k3pl
  else if FCart.Protection = 'kf2k3upl' then
    FProtection := ngpKf2k3upl
  else if FCart.Protection = 'kof10th' then
    FProtection := ngpKof10th
  else if FCart.Protection = 'kof2000' then
    FProtection := ngpKof2000
  else if FCart.Protection = 'kof2003' then
    FProtection := ngpKof2003
  else if FCart.Protection = 'kof2003h' then
    FProtection := ngpKof2003h
  else if FCart.Protection = 'kof98' then
    FProtection := ngpKof98
  else if FCart.Protection = 'kof99' then
    FProtection := ngpKof99
  else if FCart.Protection = 'kog' then
    FProtection := ngpKog
  else if FCart.Protection = 'ms5plus' then
    FProtection := ngpMs5plus
  else if FCart.Protection = 'mslug3' then
    FProtection := ngpMslug3
  else if FCart.Protection = 'mslug3a' then
    FProtection := ngpMslug3a
  else if FCart.Protection = 'mslug5' then
    FProtection := ngpMslug5
  else if FCart.Protection = 'mslugx' then
    FProtection := ngpMslugx
  else if FCart.Protection = 'neogeo_mj' then
    FProtection := ngpNeogeoMj
  else if FCart.Protection = 'svc' then
    FProtection := ngpSvc
  else if FCart.Protection = 'svcboot' then
    FProtection := ngpSvcboot
  else if FCart.Protection = 'svcsplus' then
    FProtection := ngpSvcsplus
  else if FCart.Protection = 'vliner' then
    FProtection := ngpVliner;
  if FCart.Disc <> nil then
    FCD := TNeoGeoCDController.Create(FCart.Disc, FCart.CDZ, FCart.Region);
  if FCart.Disc = nil then
  begin
    SetLength(FCard, Max(2048, FCart.CardSize));
    FillChar(FCard[0], Length(FCard), $FF);
    SetMemoryCard(FCart.CardInserted, FCart.CardReadOnly);
  end;
  FInitialFixed := Copy(FCart.FixedROM);
  Video := TNeoGeoVideo.Create(FCart);
  Sound := TNeoGeoSound.Create(FCart);
  FCPUCallbacks.UserData := Self;
  FCPUCallbacks.ReadCallback := CPURead;
  FCPUCallbacks.WriteCallback := CPUWrite;
  FCPUCallbacks.InterruptAcknowledgeCallback := CPUAcknowledge;
  FZCallbacks.UserData := Self;
  FZCallbacks.ReadCallback := ZRead;
  FZCallbacks.WriteCallback := ZWrite;
  FZCallbacks.PortReadCallback := ZPortRead;
  FZCallbacks.PortWriteCallback := ZPortWrite;
  Reset;
end;

destructor TNeoGeoConsole.Destroy;
begin
  FCD.Free;
  Sound.Free;
  Video.Free;
  inherited;
end;

function NGDateCalendar(Date: TDateTime): UInt64; forward;

procedure TNeoGeoConsole.Reset;
begin
  // The battery-powered RTC is independent of the 68000 reset line.
  var Calendar := NGDateCalendar(Now);
  if FRTCInitialized then
    Calendar := RTCCounter;
  FRTCInitialized := True;
  FCPU := Default(TM68kState);
  FZ80 := Default(TZ80State);
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FZRAM, SizeOf(FZRAM), 0);
  FProgramBank := $100000;
  FSmaRandom := $2345;
  FKof98Overlay := 0;
  FSlugCommand := 0;
  FSlugCounter := 0;
  FFuryShift := 0;
  FInputSelect := 0;
  FTrackX := 0;
  FTrackY := 0;
  FSpecialBank := 0;
  FBootOverlay := Word(Integer(ROMByte(FCart.ProgramROM, $58196)) * 256 + ROMByte(FCart.ProgramROM, $58197));
  if FProtection = ngpKf2k3bl then
    FBootOverlay := 0;
  if FProtection = ngpKof10th then
  begin
    FCart.FixedROM := Copy(FInitialFixed);
    for var i := 0 to High(FCartRAM) do
      FCartRAM[i] := Word(Integer(ROMByte(FCart.ProgramROM, $E0000 + i * 2)) * 256 + ROMByte(FCart.ProgramROM, $E0001 + i * 2));
  end;
  FillChar(FPvcRAM, SizeOf(FPvcRAM), 0);
  FBanks[0] := $F000;
  FBanks[1] := $E000;
  FBanks[2] := $C000;
  FBanks[3] := $8000;
  FCartVectors := False;
  FCartAudio := FCart.AES;
  FBackupUnlocked := False;
  FCardLock1 := True;
  FCardUnlock2 := False;
  FCardAttribute := False;
  FCardBank := 0;
  FDMARemaining := 0;
  FDMASource := 0;
  FDMATarget := 0;
  FDMAIndex := 0;
  FDMAMode := 0;
  FDMAPeriod := 0;
  FNMIEnabled := False;
  FCommandPending := False;
  FInZ80 := False;
  FCommand := 0;
  FReply := 0;
  FCoin1 := 0;
  FCoin2 := 0;
  FIRQ1 := False;
  FIRQ2 := False;
  FIRQ3 := True;
  FIRQControl := 0;
  FDisplayCounter := 0;
  FIRQDeadline := -1;
  FCPUTime := 0;
  FZTime := 0;
  FSoundTime := 0;
  FCPUBase := 0;
  FBusTime := 0;
  FRenderingLine := -1;
  FFrameTime := 0;
  FFrameNumber := 0;
  FProgramStarted := False;
  FWatchdog := 0;
  FRTCControl := 0;
  FRTCCommand := 0;
  FRTCBits := 0;
  FRTCShift := 0;
  FRTCReading := False;
  FRTCMode := 0;
  FRTCTPPeriod := 187500;
  FRTCEpoch := 0;
  FRTCTestBase := 0;
  FRTCCalendar := Calendar;
  FRTCTesting := False;
  Video.Reset;
  Sound.Reset;
  if FCD <> nil then
  begin
    FCD.Reset;
    FillChar(FCart.ProgramROM[0], Length(FCart.ProgramROM), 0);
    FillChar(FCart.SpriteROM[0], Length(FCart.SpriteROM), 0);
    FillChar(FCart.FixedROM[0], Length(FCart.FixedROM), 0);
    FillChar(FCart.AudioROM[0], Length(FCart.AudioROM), 0);
    FillChar(FCart.SamplesA[0], Length(FCart.SamplesA), 0);
    Video.CartFixed := True;
    FIRQ3 := False;
  end;
  Z80StateInitialise(FZ80);
  Clown68000Reset(FCPU, FCPUCallbacks);
end;

function TNeoGeoConsole.ROMByte(const Data: TBytes; Address: Integer): Byte;
begin
  Result := $FF;
  if (Address >= 0) and (Address < Length(Data)) then
    Result := Data[Address];
end;

function TNeoGeoConsole.PadByte(const Buttons: TEmulatorButtons): Byte;
const
  Mapping: array[0..7] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X);
begin
  Result := $FF;
  for var i := 0 to 7 do
    if Mapping[i] in Buttons then
      Result := Byte(Result and ($FF xor (1 shl i)));
end;

procedure TNeoGeoConsole.SetInput(const Input: TEmulatorInput);
begin
  FInputs := Input;
  if FInputPorts.Devices[0] = 'none' then
    FInputs.Buttons := [];
  if FInputPorts.Devices[1] = 'none' then
    FInputs.Buttons2 := [];
end;

procedure TNeoGeoConsole.ConfigureInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPorts := Ports;
end;

procedure TNeoGeoConsole.InsertCoin(Player: Integer);
begin
  if Player = 1 then
    FCoin1 := 3;
  if Player = 2 then
    FCoin2 := 3;
end;

procedure TNeoGeoConsole.UpdateIRQ;
begin
  var Level := 0;
  if FIRQ1 then
    Level := 1;
  if FIRQ2 then
    Level := 2;
  if FIRQ3 then
    Level := 3;
  if FCD <> nil then
  begin
    Level := 0;
    if FIRQ1 then
      Level := 1;
    if FCD.InterruptVector >= 0 then
      Level := 2;
    if FIRQ2 then
      Level := 3;
  end;
  Clown68000Interrupt(FCPU, Level);
end;

procedure TNeoGeoConsole.SyncRaster;
begin
  if FRenderingLine < 0 then
    Exit;

  if FCD <> nil then
  begin
    Video.DisplayEnabled := FCD.State.VideoEnabled;
    Video.SpritesEnabled := not FCD.State.SprDisabled and ((FCD.State.BusRequest and 1) = 0);
    Video.FixedEnabled := not FCD.State.FixDisabled;
  end;

  // 4 master clocks per pixel; sync and back porch occupy 224 clocks.
  var Elapsed := FBusTime - FFrameTime - Int64(FRenderingLine) * NG_LINE_CLOCKS - 224;
  Video.RenderUntil(FRenderingLine, Integer(EnsureRange(Elapsed div 4, Int64(0), Int64(NG_WIDTH))));
end;

procedure TNeoGeoConsole.SyncSound(Target: Int64);
begin
  while FSoundTime < Target do
  begin
    var Count := Integer(Min(Int64(4096), Target - FSoundTime));
    var StartSample := Length(Sound.Samples);
    Sound.Advance(Count);
    if FCD <> nil then
      for var i := StartSample div 2 to Length(Sound.Samples) div 2 - 1 do
        FCD.Mix(Sound.Samples[i * 2], Sound.Samples[i * 2 + 1]);
    Inc(FSoundTime, Count);
  end;
end;

procedure TNeoGeoConsole.SyncZ80(Target: Int64);
begin
  if (FCD <> nil) and (not FCD.State.Z80Enabled or ((FCD.State.BusRequest and 4) <> 0)) then
  begin
    FZTime := Target;
    Exit;
  end;

  if FInZ80 then
    Exit;

  FInZ80 := True;
  try
    while FZTime < Target do
    begin
      SyncSound(FZTime);
      Z80Interrupt(FZ80, Ord(Sound.IRQ));
      var Cycles := Z80DoInstruction(FZ80, FZCallbacks);
      Inc(FZTime, Int64(Max(1, Integer(Cycles))) * 6);
    end;
  finally
    FInZ80 := False;
  end;
end;

function TNeoGeoConsole.ReadZMemory(Address: Word): Byte;
begin
  if FCD <> nil then
    Exit(FCart.AudioROM[Address]);

  if Address >= $F800 then
    Exit(FZRAM[Address and $7FF]);

  if Address < $8000 then
  begin
    if FCartAudio or FCart.AES then
      Exit(ROMByte(FCart.AudioROM, Address));

    Exit(ROMByte(FCart.AudioBIOS, Address));
  end;

  var Bank := 0;
  var Offset := Integer(Address and $7FF);
  if Address < $C000 then
  begin
    Bank := 3;
    Offset := Address and $3FFF;
  end
  else if Address < $E000 then
  begin
    Bank := 2;
    Offset := Address and $1FFF;
  end
  else if Address < $F000 then
  begin
    Bank := 1;
    Offset := Address and $FFF;
  end;
  Result := ROMByte(FCart.AudioROM, (FBanks[Bank] + Offset) mod Length(FCart.AudioROM));
end;

procedure TNeoGeoConsole.WriteZMemory(Address: Word; Value: Byte);
begin
  if FCD <> nil then
  begin
    FCart.AudioROM[Address] := Value;
    Exit;
  end;

  if Address >= $F800 then
    FZRAM[Address and $7FF] := Value;
end;

function TNeoGeoConsole.ReadZPort(Address: Word): Byte;
begin
  var Port := Address and $FF;
  Result := 0;
  if Port = 0 then
  begin
    Result := FCommand;
    FCommandPending := False;
  end
  else if Port in [4, 5, 6, 7] then
  begin
    SyncSound(FZTime + Int64(FZ80.Cycles) * 6);
    Result := Sound.ReadPort(Port - 4);
  end
  else if (Port and $F) in [8, 9, 10, 11] then
  begin
    var Bank := Port and 3;
    var Mask := ($800 shl Bank) - 1;
    FBanks[Bank] := ((Address shr 8) * ($800 shl Bank)) and ((Length(FCart.AudioROM) - 1) and (not Mask));
  end;
end;

procedure TNeoGeoConsole.WriteZPort(Address: Word; Value: Byte);
begin
  case Address and $FF of
    0:
      FCommandPending := False;
    4, 5, 6, 7:
      begin
        SyncSound(FZTime + Int64(FZ80.Cycles) * 6);
        Sound.WritePort((Address and $FF) - 4, Value);
      end;
    8:
      begin
        // NMI is edge-triggered: rewriting an already enabled gate must not
        // interrupt the handler again before it can acknowledge the command.
        if not FNMIEnabled then
        begin
          FNMIEnabled := True;
          if FCommandPending then
            Z80NonMaskableInterrupt(FZ80);
        end;
      end;
    $18:
      FNMIEnabled := False;
    $C:
      FReply := Value;
  end;
end;

procedure TNeoGeoConsole.RTCWrite(Value: Byte);
begin
  // uPD4990 serial interface: DATA, CLK, STROBE on bits 0..2.
  if ((FRTCControl and 2) = 0) and ((Value and 2) <> 0) then
  begin
    var Incoming := FRTCCommand and 1;
    FRTCCommand := ((FRTCCommand shr 1) or ((Value and 1) shl 3)) and 15;
    if FRTCMode = 1 then
      FRTCShift := (FRTCShift shr 1) or (UInt64(Incoming) shl 47);
    FRTCBits := Min(64, FRTCBits + 1);
  end;

  if ((FRTCControl and 4) = 0) and ((Value and 4) <> 0) then
  begin
    FRTCMode := FRTCCommand;
    if (FRTCMode = 0) or ((FRTCMode >= 4) and (FRTCMode < 15)) then
      FRTCTesting := False;
    case FRTCMode of
      0:
        FRTCTPPeriod := 187500;
      2:
        begin
          FRTCCalendar := FRTCShift;
          FRTCTestBase := FBusTime;
        end;
      3:
        FRTCShift := RTCCounter;
      4:
        FRTCTPPeriod := 187500;
      5:
        FRTCTPPeriod := 46875;
      6:
        FRTCTPPeriod := 5859;
      7:
        FRTCTPPeriod := 2929;
      8:
        FRTCTPPeriod := 12000000;
      9:
        FRTCTPPeriod := 120000000;
      10:
        FRTCTPPeriod := 360000000;
      11:
        FRTCTPPeriod := 720000000;
      15:
        begin
          FRTCCalendar := RTCCounter;
          FRTCTesting := True;
          FRTCTestBase := FBusTime;
        end;
    end;
    if FRTCTesting and (FRTCMode in [1, 3]) then
      FRTCTPPeriod := 375000;
    if FRTCTesting and (FRTCMode = 2) then
      FRTCTPPeriod := 0;
    FRTCEpoch := FBusTime;
    FRTCReading := FRTCMode = 1;
    FRTCBits := 0;
  end;
  FRTCControl := Value and 7;
end;

function NGCalendarDate(Calendar: UInt64; out Date: TDateTime): Boolean;

  function DecimalAt(Shift: Integer): Word;
  begin
    var Value := (Calendar shr Shift) and $FF;
    Result := Word(((Value shr 4) and 15) * 10 + (Value and 15));
  end;

begin
  Result := TryEncodeDateTime(2000 + DecimalAt(40), Word((Calendar shr 36) and 15),
    DecimalAt(24), DecimalAt(16), DecimalAt(8), DecimalAt(0), 0, Date);
end;

function NGDateCalendar(Date: TDateTime): UInt64;

  function BCD(Value: Word): UInt64;
  begin
    Result := UInt64(Value div 10 * 16 + Value mod 10);
  end;

begin
  var Year, Month, Day, Hour, Minute, Second, MS: Word;
  DecodeDateTime(Date, Year, Month, Day, Hour, Minute, Second, MS);
  Result := BCD(Second) or (BCD(Minute) shl 8) or (BCD(Hour) shl 16) or
    (BCD(Day) shl 24) or (UInt64(Month * 16 + DayOfWeek(Date) - 1) shl 32) or
    (BCD(Year mod 100) shl 40);
end;

function TNeoGeoConsole.RTCBatteryData: TBytes;
begin
  Result := nil;
  if FCart.AES or (FCD <> nil) or FRTCTesting then
    Exit;

  var Calendar := RTCCounter;
  var Date: TDateTime;
  if not NGCalendarDate(Calendar, Date) then
    Exit;

  SetLength(Result, 18);
  Result[0] := Ord('N');
  Result[1] := Ord('G');
  Result[2] := Ord('R');
  Result[3] := 1;
  for var i := 0 to 5 do
    Result[4 + i] := (Calendar shr (i * 8)) and $FF;
  var Timestamp := DateTimeToUnix(Now, False);
  for var i := 0 to 7 do
    Result[10 + i] := (Timestamp shr (i * 8)) and $FF;
end;

procedure TNeoGeoConsole.LoadRTCBattery(const Data: TBytes);
begin
  if FCart.AES or (FCD <> nil) then
    Exit;

  if (Length(Data) <> 18) or (Data[0] <> Ord('N')) or (Data[1] <> Ord('G')) or (Data[2] <> Ord('R')) or (Data[3] <> 1) then
    raise EReadError.Create('Invalid MVS RTC battery file');

  var Calendar: UInt64 := 0;
  var Timestamp: UInt64 := 0;
  for var i := 0 to 5 do
    Calendar := Calendar or (UInt64(Data[4 + i]) shl (i * 8));
  for var i := 0 to 7 do
    Timestamp := Timestamp or (UInt64(Data[10 + i]) shl (i * 8));
  var Date: TDateTime;
  if not NGCalendarDate(Calendar, Date) or (Timestamp > UInt64(High(Int64))) then
    raise EReadError.Create('Invalid MVS RTC battery date');

  var Elapsed := EnsureRange(DateTimeToUnix(Now, False) - Int64(Timestamp), Int64(0), Int64(3155760000));
  FRTCCalendar := NGDateCalendar(IncSecond(Date, Elapsed));
  FRTCTestBase := FBusTime;
end;

function TNeoGeoConsole.RTCCounter: UInt64;

  function BCD(Value: Word): UInt64;
  begin
    Result := UInt64(Value div 10 * 16 + Value mod 10);
  end;

  function DecimalAt(Shift: Integer): Word;
  begin
    var Value := (FRTCCalendar shr Shift) and $FF;
    Result := Word(((Value shr 4) and 15) * 10 + (Value and 15));
  end;

begin
  if FRTCTesting then
  begin
    var Ticks := Max(Int64(0), FBusTime - FRTCTestBase) * 8192 div 24000000;
    Result := 0;
    for var i := 0 to 5 do
    begin
      var Counter := (((FRTCCalendar shr (i * 8)) and $FF) + UInt64(Ticks)) and $FF;
      Result := Result or (Counter shl (i * 8));
    end;
  end
  else
  begin
    var Date: TDateTime;
    if not TryEncodeDateTime(2000 + DecimalAt(40), Word((FRTCCalendar shr 36) and 15),
      DecimalAt(24), DecimalAt(16), DecimalAt(8), DecimalAt(0), 0, Date) then
      Date := EncodeDate(2000, 1, 1);
    Date := IncSecond(Date, Max(Int64(0), FBusTime - FRTCTestBase) div 24000000);
    var Year, Month, Day, Hour, Minute, Second, MS: Word;
    DecodeDateTime(Date, Year, Month, Day, Hour, Minute, Second, MS);
    Result := BCD(Second) or (BCD(Minute) shl 8) or (BCD(Hour) shl 16) or
      (BCD(Day) shl 24) or (UInt64(Month * 16 + DayOfWeek(Date) - 1) shl 32) or
      (BCD(Year mod 100) shl 40);
  end;
end;

function TNeoGeoConsole.RTCData: Boolean;
begin
  if FRTCMode in [1, 2] then
    Exit((FRTCShift and 1) <> 0);

  if FRTCTesting then
  begin
    var Counter := RTCCounter;
    Result := False;
    for var i := 0 to 5 do
      if ((Counter shr (i * 8)) and $FF) = 0 then
        Exit(True);
  end
  else
    Result := Odd((FBusTime - FRTCEpoch) div 12000000);
end;

function WireBits(Value: Cardinal; const Order: array of Integer): Cardinal;
begin
  Result := 0;
  for var Bit in Order do
    Result := (Result shl 1) or ((Value shr Bit) and 1);
end;

function TNeoGeoConsole.FuryRead(Address: Cardinal): Word;
begin
  // SNK PRO-CT0 / ALPHA-8921 serializer, per MAME's cam900 implementation.
  var GAD, GBD: Cardinal;
  if (Address and 8) <> 0 then
  begin
    GBD := WireBits(FFuryShift, [30, 22, 14, 6]);
    GAD := WireBits(FFuryShift, [31, 23, 15, 7]);
  end
  else
  begin
    GBD := WireBits(FFuryShift, [25, 17, 9, 1]);
    GAD := WireBits(FFuryShift, [24, 16, 8, 0]);
  end;
  if (Address and 4) <> 0 then
  begin
    var Temp := GAD;
    GAD := GBD;
    GBD := Temp;
  end;
  Result := Word(((GBD and 3) shl 6) or ((GBD and 12) shl 2) or ((GAD and 3) shl 2) or ((GAD and 12) shr 2));
end;

procedure TNeoGeoConsole.FuryWrite(Address: Cardinal; Value: Word);
begin
  if (Address and 2) <> 0 then
    FFuryShift := (
      WireBits((Address shr 4) and $FFFF, [15, 11, 14, 10, 13, 9, 12, 8, 7, 3, 6, 2, 5, 1, 4, 0]) shl 16) or
      WireBits(Value, [15, 11, 14, 10, 13, 9, 12, 8, 7, 3, 6, 2, 5, 1, 4, 0])
  else if (Address and 8) <> 0 then
    FFuryShift := (FFuryShift and $3F3F3F3F) shl 2
  else
    FFuryShift := (FFuryShift shr 2) and $3F3F3F3F;
end;

function TNeoGeoConsole.HasBootRAM: Boolean;
begin
  Result :=
    (FProtection = ngpKf2k3bl) or (FProtection = ngpKf2k3pl) or
    (FProtection = ngpKf2k3upl) or (FProtection = ngpKof10th);
end;

function TNeoGeoConsole.ExtraRead(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := True;
  var Kind := FProtection;
  if HasBootRAM and (Address >= $2FE000) and (Address <= $2FFFFE) then
    Value := FPvcRAM[(Address - $2FE000) shr 1]
  else if ((Kind = ngpKf2k3bl) or (Kind = ngpKf2k3upl)) and (Address = $58196) then
    Value := FBootOverlay
  else if (Kind = ngpMs5plus) and (Address >= $2FFFF0) and (Address <= $2FFFFE) then
    Value := $A0
  else if (Kind = ngpKog) and (Address = $FFFFE) then
    Value := 1 // English jumper.
  else if (Kind = ngpKof10th) and (Address >= $E0000) and (Address <= $FFFFE) then
    Value := FCartRAM[(Address - $E0000) shr 1]
  else if (Kind = ngpKof10th) and (Address >= $10000) and (Address < $E0000) then
  begin
    var A := Integer(Address) + FSpecialBank;
    Value := Word(Integer(ROMByte(FCart.ProgramROM, A)) * 256 + ROMByte(FCart.ProgramROM, A + 1));
  end
  else if ((Kind = ngpJockeygp) or (Kind = ngpVliner)) and (Address >= $200000) and (Address <= $201FFE) then
    Value := FCartRAM[(Address - $200000) shr 1]
  else if (Kind = ngpVliner) and (Address = $280000) then
  begin
    Value := $FFFF;
    if FCoin1 > 0 then
      Value := Value and $FFFE;
    if FCoin2 > 0 then
      Value := Value and $FFFD;
    if TEmulatorButton.Mode in FInputs.Buttons then
      Value := Value and $FFEF;
    if TEmulatorButton.Y in FInputs.Buttons then
      Value := Value and $FFDF;
  end
  else if (Kind = ngpVliner) and (Address = $2C0000) then
    Value := $0003
  else
    Result := False;
end;

function TNeoGeoConsole.ExtraWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
const
  CTHDBank: array[0..7] of Integer = (1, 0, 1, 0, 1, 0, 3, 2);
begin
  Result := True;
  var Kind := FProtection;
  var Mask := 0;
  if HighByte then
    Mask := Mask or $FF00;
  if LowByte then
    Mask := Mask or $FF;
  if ((Kind = ngpJockeygp) or (Kind = ngpVliner)) and (Address >= $200000) and (Address <= $201FFE) then
  begin
    var i := (Address - $200000) shr 1;
    var W := Word((FCartRAM[i] and (Mask xor $FFFF)) or (Value and Mask));
    if W <> FCartRAM[i] then
    begin
      FCartRAM[i] := W;
      FBatteryDirty := True;
    end;
  end
  else if (Kind = ngpKof10th) and (Address >= $200000) and (Address < $240000) then
  begin
    var i := Integer((Address - $200000) shr 1);
    if FPvcRAM[$FFE] = 0 then
      FCartRAM[i and $FFFF] := Word((FCartRAM[i and $FFFF] and (Mask xor $FFFF)) or (Value and Mask))
    else if i < Length(FCart.FixedROM) then
      FCart.FixedROM[i] := Byte(BootlegBits(Value and $FF, [7, 6, 0, 4, 3, 2, 1, 5]));
  end
  else if HasBootRAM and (Address >= $2FE000) and (Address <= $2FFFFE) then
  begin
    var i := Integer((Address - $2FE000) shr 1);
    var W := Word((FPvcRAM[i] and (Mask xor $FFFF)) or (Value and Mask));
    if Kind = ngpKof10th then
    begin
      if (Address = $2FFFF8) and (FPvcRAM[i] <> W) then
        if (W and 1) <> 0 then
          FSpecialBank := $800000
        else
          FSpecialBank := $700000;
      if Address = $2FFFF0 then
      begin
        FProgramBank := $100000 + (W and 7) * $100000;
        if FProgramBank >= $700000 then
          FProgramBank := $100000;
      end;
    end;
    FPvcRAM[i] := W;
    if (Kind <> ngpKof10th) and ((Address = $2FFFF0) or (Address = $2FFFF2)) then
    begin
      var Low := FPvcRAM[$FF8] shr 8;
      if Kind = ngpKf2k3pl then
        Low := FPvcRAM[$FF8] and $FF;
      FProgramBank := $100000 + Low + ((Integer(FPvcRAM[$FF9]) and $FF) shl 8) +
        ((Integer(FPvcRAM[$FF9]) shr 8) shl 16);
      FBootOverlay := (FBootOverlay and $FF00) or (FPvcRAM[$FF9] and $FF);
      if Kind = ngpKf2k3pl then
        FPvcRAM[$FF8] := FPvcRAM[$FF8] and $FFFE
      else
        FPvcRAM[$FF8] := (FPvcRAM[$FF8] and $FE00) or $A0;
      FPvcRAM[$FF9] := FPvcRAM[$FF9] and $7FFF;
    end;
  end
  else if ((Kind = ngpCthd2k3) or (Kind = ngpCt2k3sp)) and (Address = $2FFFF0) then
    FProgramBank := (CTHDBank[Value and 7] + 1) * $100000
  else if (Kind = ngpMs5plus) and (Address >= $2FFFF0) and (Address <= $2FFFFE) then
  begin
    if (Address = $2FFFF0) and (Value = $A0) then
      FProgramBank := $A0
    else if Address = $2FFFF4 then
      if (Value shr 4) > $FF then
        FProgramBank := $10000000
      else
        FProgramBank := (Integer(Value) shr 4) * $100000;
  end
  else
    Result := False;
end;

function TNeoGeoConsole.MahjongByte: Byte;
const
  // A..G use the first logical pad, H..N use the second; action row uses X/Y/Z/Mode/Select.
  TileButtons: array[0..6] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C);
  ActionButtons: array[0..4] of TEmulatorButton = (TEmulatorButton.X, TEmulatorButton.Y,
    TEmulatorButton.Z, TEmulatorButton.Mode, TEmulatorButton.Select);
begin
  Result := $FF;
  for var i := 0 to 6 do
  begin
    if ((FInputSelect and 1) <> 0) and (TileButtons[i] in FInputs.Buttons) then
      Result := Result and Byte($FF xor (1 shl i));
    if ((FInputSelect and 2) <> 0) and (TileButtons[i] in FInputs.Buttons2) then
      Result := Result and Byte($FF xor (1 shl i));
  end;
  for var i := 0 to 4 do
    if ((FInputSelect and 4) <> 0) and (ActionButtons[i] in FInputs.Buttons2) then
      Result := Result and Byte($FF xor (1 shl i));
end;

function TNeoGeoConsole.HasPVC: Boolean;
begin
  Result :=
    (FProtection = ngpMslug5) or (FProtection = ngpSvc) or
    (FProtection = ngpKof2003) or (FProtection = ngpKof2003h) or
    (FProtection = ngpSvcboot) or (FProtection = ngpSvcsplus);
end;

procedure TNeoGeoConsole.PVCWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  var Index := Integer((Address - $2FE000) shr 1);
  var Mask := 0;
  if HighByte then
    Mask := Mask or $FF00;
  if LowByte then
    Mask := Mask or $FF;

  FPvcRAM[Index] := Word((FPvcRAM[Index] and (Mask xor $FFFF)) or (Value and Mask));
  if Index = $FF0 then
  begin
    var Pen := FPvcRAM[$FF0];
    var B := ((Pen and $F) shl 1) or ((Pen shr 12) and 1);
    var G := ((Pen and $F0) shr 3) or ((Pen shr 13) and 1);
    var R := ((Pen and $F00) shr 7) or ((Pen shr 14) and 1);
    FPvcRAM[$FF1] := Word((G shl 8) or B);
    FPvcRAM[$FF2] := Word(((Pen shr 15) shl 8) or R);
  end
  else if (Index = $FF4) or (Index = $FF5) then
  begin
    var GB := FPvcRAM[$FF4];
    var SR := FPvcRAM[$FF5];
    FPvcRAM[$FF6] := Word(((GB and $1E) shr 1) or ((GB and $1E00) shr 5) or
        ((SR and $1E) shl 7) or ((GB and 1) shl 12) or ((GB and $100) shl 5) or
        ((SR and 1) shl 14) or ((SR and $100) shl 7));
  end;
  if Index >= $FF8 then
  begin
    FProgramBank := $100000 + ((FPvcRAM[$FF8] shr 8) or (Integer(FPvcRAM[$FF9]) shl 8));
    FPvcRAM[$FF8] := (FPvcRAM[$FF8] and $FE00) or $A0;
    FPvcRAM[$FF9] := FPvcRAM[$FF9] and $7FFF;
  end;
end;

function TNeoGeoConsole.SMARead(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := False;
  var Kind := FProtection;
  if not ((Kind = ngpKof99) or (Kind = ngpGarou) or (Kind = ngpGarouh) or
    (Kind = ngpMslug3) or (Kind = ngpMslug3a) or (Kind = ngpKof2000)) then
    Exit;

  if Address = $2FE446 then
  begin
    Value := $9A37;
    Exit(True);
  end;

  var RandomPort :=
    ((Kind = ngpKof99) and ((Address = $2FFFF8) or (Address = $2FFFFA))) or
    (((Kind = ngpGarou) or (Kind = ngpGarouh)) and ((Address = $2FFFCC) or (Address = $2FFFF0))) or
    ((Kind = ngpKof2000) and ((Address = $2FFFD8) or (Address = $2FFFDA)));

  if RandomPort then
  begin
    Value := FSmaRandom;
    var Bit := ((FSmaRandom shr 2) xor (FSmaRandom shr 3) xor (FSmaRandom shr 5) xor
      (FSmaRandom shr 6) xor (FSmaRandom shr 7) xor (FSmaRandom shr 11) xor
      (FSmaRandom shr 12) xor (FSmaRandom shr 15)) and 1;
    FSmaRandom := Word(((Integer(FSmaRandom) shl 1) or Bit) and $FFFF);
    Result := True;
  end;
end;

function TNeoGeoConsole.SMAWrite(Address: Cardinal; Value: Word): Boolean;
begin
  var Kind := FProtection;
  Result := ((Kind = ngpKof99) and (Address = $2FFFF0)) or
    (((Kind = ngpGarou) or (Kind = ngpGarouh)) and (Address = $2FFFC0)) or
    (((Kind = ngpMslug3) or (Kind = ngpMslug3a)) and (Address = $2FFFE4)) or
    ((Kind = ngpKof2000) and (Address = $2FFFEC));
  if Result then
    FProgramBank := SMABank(FCart.Protection, Value);
end;

function TNeoGeoConsole.CDRead(Address: Cardinal; HighByte, LowByte: Boolean; out Value: Word): Boolean;
begin
  Result := True;
  Value := $FFFF;
  if Address < $200000 then
  begin
    if (Address < $80) and not FCartVectors then
      Value := Word(Integer(FCart.BIOS[Address]) * 256 + FCart.BIOS[Address + 1])
    else
      Value := Word(Integer(FCart.ProgramROM[Address]) * 256 + FCart.ProgramROM[Address + 1]);
  end
  else if (Address >= $800000) and (Address < $900000) then
    Value := $FF00 or FBackup[(Address shr 1) and $1FFF]
  else if (Address >= $FF0000) and (Address <= $FF01FE) then
  begin
    SyncZ80(FBusTime);
    SyncSound(FBusTime);
    FCD.Advance(FBusTime);
    UpdateIRQ;
    Value := FCD.ReadWord(Address, HighByte, LowByte);
  end
  else if (Address >= $E00000) and (Address < $F00000) then
  begin
    var Offset := Integer(Address and $FFFFF);
    case FCD.State.Area of
      0:
        if (FCD.State.BusRequest and 1) <> 0 then
        begin
          Offset := Offset + Integer(FCD.State.SprBank) * $100000;
          Value := Word(Integer(FCart.SpriteROM[Offset]) * 256 + FCart.SpriteROM[Offset + 1]);
        end;
      1:
        if (FCD.State.BusRequest and 2) <> 0 then
          Value := $FF00 or FCart.SamplesA[(Offset shr 1) + Integer(FCD.State.PCMBank) * $80000];
      4:
        if (FCD.State.BusRequest and 4) <> 0 then
          Value := $FF00 or FCart.AudioROM[(Offset shr 1) and $FFFF];
      5:
        if (FCD.State.BusRequest and 8) <> 0 then
          Value := $FF00 or FCart.FixedROM[(Offset shr 1) and $1FFFF];
    end;
  end
  else if (Address >= $320000) and (Address < $340000) then
  begin
    SyncZ80(FBusTime);
    Value := Word(Integer(FReply) * 256 + $FF);
  end
  else if (Address >= $380000) and (Address < $3A0000) then
  begin
    Value := $0FFF;
    if TEmulatorButton.Start in FInputs.Buttons then
      Value := Value and $FEFF;
    if TEmulatorButton.Select in FInputs.Buttons then
      Value := Value and $FDFF;
    if TEmulatorButton.Start in FInputs.Buttons2 then
      Value := Value and $FBFF;
    if TEmulatorButton.Select in FInputs.Buttons2 then
      Value := Value and $F7FF;
  end
  else if ((Address >= $300000) and (Address < $400000)) or
    ((Address >= $400000) and (Address < $500000)) or
    ((Address >= $C00000) and (Address < $D00000)) then
    Result := False;
end;

function TNeoGeoConsole.CDWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
begin
  Result := True;
  if Address < $200000 then
  begin
    if (Address < $80) and not FCartVectors then
      Exit;

    if HighByte then
      FCart.ProgramROM[Address] := Value shr 8;
    if LowByte then
      FCart.ProgramROM[Address + 1] := Value and $FF;
  end
  else if (Address >= $800000) and (Address < $900000) then
  begin
    if LowByte then
    begin
      FBackup[(Address shr 1) and $1FFF] := Value and $FF;
      FBatteryDirty := True;
    end;
  end
  else if (Address >= $FF0000) and (Address <= $FF01FE) then
  begin
    SyncZ80(FBusTime);
    SyncSound(FBusTime);
    FCD.Advance(FBusTime);
    if FCD.WriteWord(Address, Value, HighByte, LowByte) then
      CDDMA;
    if (Address = $FF0182) and LowByte and (Value and $FF <> 0) then
    begin
      Z80StateInitialise(FZ80);
      Sound.Reset;
    end;
    UpdateIRQ;
  end
  else if (Address >= $E00000) and (Address < $F00000) then
  begin
    var Offset := Integer(Address and $FFFFF);
    case FCD.State.Area of
      0:
        if (FCD.State.BusRequest and 1) <> 0 then
        begin
          Offset := Offset + Integer(FCD.State.SprBank) * $100000;
          if HighByte then
            FCart.SpriteROM[Offset] := Value shr 8;
          if LowByte then
            FCart.SpriteROM[Offset + 1] := Value and $FF;
        end;
      1:
        if LowByte and ((FCD.State.BusRequest and 2) <> 0) then
          FCart.SamplesA[(Offset shr 1) + Integer(FCD.State.PCMBank) * $80000] := Value and $FF;
      4:
        if LowByte and ((FCD.State.BusRequest and 4) <> 0) then
          FCart.AudioROM[(Offset shr 1) and $FFFF] := Value and $FF;
      5:
        if LowByte and ((FCD.State.BusRequest and 8) <> 0) then
          FCart.FixedROM[(Offset shr 1) and $1FFFF] := Value and $FF;
    end;
  end
  else if ((Address >= $300000) and (Address < $400000)) or ((Address >= $400000) and (Address < $500000)) then
    Result := False;
end;

procedure TNeoGeoConsole.CDDMA;
begin
  var Mode := FCD.State.DMAConfig[0];
  var Count := FCD.State.DMALength;
  if FCD.State.DMABusy then
    Exit;

  if Count > $200000 then
    raise EReadError.Create('Invalid Neo Geo CD DMA length');

  if Count = 0 then
    Exit;

  FDMASource := FCD.State.DMADestination and $FFFFFE;
  FDMATarget := FCD.State.DMASource and $FFFFFE;
  FDMAPeriod := 16; // 68000 bus: one read and one word write.
  if (Mode = $FFC5) or (Mode = $FF89) or (Mode = $FC2D) then
  begin
    Count := Min(Count, Cardinal(1024));
    FDMATarget := FDMASource;
    FDMAPeriod := 8;
    if Mode = $FC2D then
      FDMAPeriod := 16;
  end
  else if (Mode = $FFCD) or (Mode = $FFDD) or (Mode = $FEF5) or (Mode = $CFFD) then
  begin
    FDMATarget := FDMASource;
    FDMAPeriod := 8;
    if Mode = $FEF5 then
      FDMAPeriod := 16;
    if Mode = $CFFD then
      FDMAPeriod := 32;
  end
  else if (Mode = $E2DD) or (Mode = $F2DD) then
    FDMAPeriod := 24
  else if (Mode <> $FE3D) and (Mode <> $FE6D) then
    raise EReadError.CreateFmt('Unsupported Neo Geo CD DMA mode %.4x', [Mode]);

  if FDMATarget >= $FF0000 then
    raise EReadError.Create('Invalid Neo Geo CD DMA destination');

  FDMAMode := Mode;
  FDMARemaining := Count;
  FDMAIndex := 0;
  FCD.State.DMABusy := True;
  FCD.State.NextDMA := Max(FBusTime, FCPUTime) + FDMAPeriod;
  FCD.State.IFStat := FCD.State.IFStat and $F7;
end;

procedure TNeoGeoConsole.AdvanceDMA(Time: Int64);
begin
  while FCD.State.DMABusy and (FCD.State.NextDMA <= Time) do
  begin
    FBusTime := FCD.State.NextDMA;
    DMAStep;
    Inc(FCD.State.NextDMA, FDMAPeriod);
  end;
end;

procedure TNeoGeoConsole.DMAStep;

  procedure DMAWrite(Address: Cardinal; Value: Word);
  begin
    // A DMA descriptor cannot start another DMA by targeting CD registers.
    if Address >= $FF0000 then
      raise EReadError.Create('Invalid Neo Geo CD DMA destination');

    WriteBus(Address, Value, True, True);
  end;

begin
  var Mode := FDMAMode;
  var Count := FDMARemaining;

  // Hardware transfer counts are bounded by available memory. Reject corrupt
  // descriptors instead of allowing a guest to freeze the worker for billions of writes.
  if Count > $200000 then
    raise EReadError.Create('Invalid Neo Geo CD DMA length');

  if Count = 0 then
    Exit;

  var Source := FDMASource;
  var Target := FDMATarget;
  var FromCD := (Mode = $FFC5) or (Mode = $FF89) or (Mode = $FC2D);
  var OddBytes := (Mode = $E2DD) or (Mode = $F2DD) or (Mode = $FC2D);
  if FromCD then
  begin
    if FDMAIndex >= 1024 then
      raise EReadError.Create('Invalid CD DMA sector offset');
  end
  else if (Mode = $FFCD) or (Mode = $FFDD) or (Mode = $FEF5) or (Mode = $CFFD) then
    Target := FDMATarget
  else if (Mode <> $FE3D) and (Mode <> $FE6D) and not OddBytes then
    raise EReadError.CreateFmt('Unsupported Neo Geo CD DMA mode %.4x', [Mode]);

  for var i := Integer(FDMAIndex) to Integer(FDMAIndex) do
  begin
    var Data: Word;
    if FromCD then
      Data := Word(Integer(FCD.State.Sector[i * 2]) * 256 + FCD.State.Sector[i * 2 + 1])
    else if (Mode = $FFCD) or (Mode = $FFDD) then
      Data := FCD.State.DMAPattern
    else if (Mode = $FEF5) or (Mode = $CFFD) then
      Data := 0
    else
    begin
      Data := ReadBus(Source, True, True);
      Source := (Source + 2) and $FFFFFE;
    end;
    if Mode = $FEF5 then
    begin
      DMAWrite(Target, Word(Target shr 16));
      DMAWrite((Target + 2) and $FFFFFE, Word(Target and $FFFF));
      Target := (Target + 4) and $FFFFFE;
    end
    else if Mode = $CFFD then
    begin
      var Pattern := Target;
      for var N := 0 to 3 do
      begin
        DMAWrite(Target, Word((Pattern shr (24 - N * 8)) and $FF));
        Target := (Target + 2) and $FFFFFE;
      end;
    end
    else
    begin
      if OddBytes then
      begin
        var First := Word((Data shr 8) or ((Data and $FF) shl 8));
        if FromCD then
          First := Data shr 8;
        DMAWrite(Target, First);
        Target := (Target + 2) and $FFFFFE;
      end;
      DMAWrite(Target, Data);
      Target := (Target + 2) and $FFFFFE;
    end;
  end;
  FDMASource := Source;
  FDMATarget := Target;
  Inc(FDMAIndex);
  Dec(FDMARemaining);
  FCD.State.DMALength := FDMARemaining;
  if FDMARemaining = 0 then
  begin
    if FromCD or (Mode = $FFCD) or (Mode = $FFDD) or (Mode = $FEF5) or (Mode = $CFFD) then
      FCD.State.DMADestination := FDMATarget
    else
    begin
      FCD.State.DMADestination := FDMASource;
      FCD.State.DMASource := FDMATarget;
    end;
    FCD.State.DMABusy := False;
    if FromCD then
      FCD.EndTransfer
    else
      FCD.State.IFStat := FCD.State.IFStat or 8;
  end;
end;

function TNeoGeoConsole.ReadBus(Address: Cardinal; HighByte, LowByte: Boolean): Word;
begin
  if (FCD <> nil) and CDRead(Address, HighByte, LowByte, Result) then
    Exit;

  if ExtraRead(Address, Result) then
    Exit;

  Result := $FFFF;
  var Region := Address shr 20;
  var Offset := Integer(Address and $FFFF);
  case Region of
    0:
      begin
        if (FProtection = ngpKof98) and (FKof98Overlay <> 0) and ((Address = $100) or (Address = $102)) then
        begin
          if FKof98Overlay = 1 then
          begin
            if Address = $100 then
              Exit($C2)
            else
              Exit($FD);
          end
          else
          begin
            if Address = $100 then
              Exit($4E45)
            else
              Exit($4F2D);
          end;
        end;

        var A := Integer(Address);
        if (Address < $80) and not FCartVectors then
          Result := Word(ROMByte(FCart.BIOS, A) * 256 + ROMByte(FCart.BIOS, A + 1))
        else
          Result := Word(ROMByte(FCart.ProgramROM, A) * 256 + ROMByte(FCart.ProgramROM, A + 1));
      end;
    1:
      Result := Word(Integer(FRAM[Offset]) * 256 + FRAM[Offset + 1]);
    2:
      begin
        if FProtection = ngpFatfury2 then
          Exit(FuryRead(Address));

        if (FProtection = ngpMslugx) and (Address >= $2FFFE0) and (Address <= $2FFFEE) then
        begin
          var Selection := -1;
          if FSlugCommand = 1 then
          begin
            Selection := FSlugCounter;
            FSlugCounter := Word((Integer(FSlugCounter) + 1) and $FFFF);
          end
          else if FSlugCommand = $FFF then
            Selection := Integer(ReadBus($10F00A, True, True)) - 1;
          Result := 0;
          if (FSlugCommand = 1) or (FSlugCommand = $FFF) then
            Result := (ROMByte(FCart.ProgramROM, $DEDD2 + ((Selection shr 3) and $FFF)) shr
              ((not Selection) and 7)) and 1;
          Exit;
        end;

        if HasPVC and (Address >= $2FE000) then
          Exit(FPvcRAM[(Address - $2FE000) shr 1]);

        if SMARead(Address, Result) then
          Exit;

        var A := FProgramBank + Integer(Address and $FFFFF);
        if Length(FCart.ProgramROM) <= $100000 then
          A := Integer(Address and $FFFFF);
        Result := Word(ROMByte(FCart.ProgramROM, A) * 256 + ROMByte(FCart.ProgramROM, A + 1));
      end;
    3:
      case (Address shr 16) and $FE of
        $30:
          begin
            var Switches := $FF;
            if not FCart.AES then
              if (Address and $80) = 0 then
                Switches := FCart.CabinetDIPs
              else if TEmulatorButton.Mode in FInputs.Buttons then
                Switches := $7F;
            var Pad := PadByte(FInputs.Buttons);
            if FProtection = ngpNeogeoMj then
              Pad := MahjongByte;
            if FProtection = ngpIrrmaze then
              if (FInputSelect and 1) <> 0 then
                Pad := FTrackY
              else
                Pad := FTrackX;
            Result := Word(Integer(Pad) * 256 + Switches);
          end;
        $32:
          begin
            SyncZ80(FBusTime);
            var Coins := $1F;
            if FCart.AES then
              Coins := $FF
            else if TEmulatorButton.Y in FInputs.Buttons then
              Coins := Coins and $FB;
            if not FCart.AES and ((FCoin1 > 0) or (TEmulatorButton.Select in FInputs.Buttons)) then
              Coins := Coins and $FE;
            if not FCart.AES and ((FCoin2 > 0) or (TEmulatorButton.Select in FInputs.Buttons2)) then
              Coins := Coins and $FD;
            if (FRTCTPPeriod > 0) and Odd((FBusTime - FRTCEpoch) div Max(1, FRTCTPPeriod)) then
              Coins := Coins or $40;
            if RTCData then
              Coins := Coins or $80;
            Result := Word(Integer(FReply) * 256 + Coins);
          end;
        $34:
          if FProtection = ngpIrrmaze then
            Result := Word(Integer((PadByte(FInputs.Buttons) and $30) or ((PadByte(FInputs.Buttons2) and $30) shl 2) or $F) * 256 + $FF)
          else
            Result := Word(Integer(PadByte(FInputs.Buttons2)) * 256 + $FF);
        $38:
          begin
            Result := $FFFF;
            if FCart.AES then
              Result := Result and $7FFF;
            if FCardInserted then
              Result := Result and $CFFF;
            if FCardInserted and not FCardReadOnly then
              Result := Result and $BFFF;
            if (FProtection <> ngpJockeygp) and (TEmulatorButton.Start in FInputs.Buttons) then
              Result := Result and $FEFF;
            if TEmulatorButton.Select in FInputs.Buttons then
              Result := Result and $FDFF;
            if (FProtection <> ngpJockeygp) and (TEmulatorButton.Start in FInputs.Buttons2) then
              Result := Result and $FBFF;
            if TEmulatorButton.Select in FInputs.Buttons2 then
              Result := Result and $F7FF;
          end;
        $3C:
          if HighByte then
            Result := Video.ReadRegister((Address shr 1) and 3, Integer((FBusTime mod (FCart.FrameLines * NG_LINE_CLOCKS)) div NG_LINE_CLOCKS));
      end;
    4, 5, 6, 7:
      Result := Video.Palette[Video.PaletteBank * $1000 + Integer((Address shr 1) and $FFF)];
    8, 9, $A, $B:
      if HighByte and FCardInserted and not FCardAttribute then
        Result := $FF00 or FCard[((Address and $3FFFFF) shr 1) mod Cardinal(Length(FCard))];
    $C:
      begin
        var A := Integer(Address) mod Length(FCart.BIOS);
        Result := Word(ROMByte(FCart.BIOS, A) * 256 + ROMByte(FCart.BIOS, A + 1));
      end;
    $D:
      if not FCart.AES then
        Result := Word(Integer(FBackup[Offset]) * 256 + FBackup[Offset + 1]);
  end;
end;

procedure TNeoGeoConsole.WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  if ((Address >= $3A0000) and (Address < $800000)) or
    ((FCD <> nil) and (((Address >= $E00000) and (Address < $F00000)) or
    ((Address >= $FF0110) and (Address <= $FF0128)))) then
    SyncRaster;
  if (FCD <> nil) and CDWrite(Address, Value, HighByte, LowByte) then
    Exit;

  if ExtraWrite(Address, Value, HighByte, LowByte) then
    Exit;

  var Region := Address shr 20;
  var Offset := Integer(Address and $FFFF);
  case Region of
    1:
      begin
        if HighByte then
          FRAM[Offset] := Value shr 8;
        if LowByte then
          FRAM[Offset + 1] := Value and $FF;
      end;
    2:
      if FProtection = ngpFatfury2 then
        FuryWrite(Address, Value)
      else if (FProtection = ngpKof98) and (Address = $20AAAA) then
      begin
        if Value = $90 then
          FKof98Overlay := 1
        else if Value = $F0 then
          FKof98Overlay := 2;
      end
      else if (FProtection = ngpMslugx) and (Address >= $2FFFE0) and (Address <= $2FFFEE) then
      begin
        case Address and $F of
          0:
            FSlugCommand := 0;
          2, 4:
            FSlugCommand := FSlugCommand or Value;
          $A:
            begin
              FSlugCounter := 0;
              FSlugCommand := 0;
            end;
        end;
      end
      else if HasPVC and (Address >= $2FE000) then
        PVCWrite(Address, Value, HighByte, LowByte)
      else if SMAWrite(Address, Value) then
        Exit
      else if (Address >= $2FFFF0) and LowByte then
      begin
        FProgramBank := ((Value and 7) + 1) * $100000;
        if FProgramBank >= Length(FCart.ProgramROM) then
          FProgramBank := $100000;
      end;
    3:
      case (Address shr 16) and $FE of
        $30:
          if LowByte then
            FWatchdog := 0;
        $32:
          if HighByte then
          begin
            SyncZ80(FBusTime);
            var WasPending := FCommandPending;
            FCommand := Value shr 8;
            FCommandPending := True;
            if FNMIEnabled and not WasPending then
              Z80NonMaskableInterrupt(FZ80);
          end;
        $38:
          if LowByte and ((Address and $70) = $10) then
            FCardBank := Value and $FF
          else if LowByte and ((Address and $70) = 0) then
            FInputSelect := Byte(Value and $FF)
          else if LowByte and ((Address and $FE) = $50) then
            RTCWrite(Byte(Value and $FF));
        $3A:
          if LowByte then
          begin
            var SetBit := (Address and $10) <> 0;
            case (Address shr 1) and 7 of
              0:
                Video.Shadow := SetBit;
              1:
                FCartVectors := SetBit;
              2:
                FCardLock1 := SetBit;
              3:
                FCardUnlock2 := SetBit;
              4:
                FCardAttribute := not SetBit;
              5:
                if FCD = nil then
                begin
                  FCartAudio := SetBit or FCart.AES;
                  Video.CartFixed := SetBit or FCart.AES;
                end;
              6:
                FBackupUnlocked := SetBit;
              7:
                Video.PaletteBank := Ord(SetBit);
            end;
          end;
        $3C:
          if HighByte then
          begin
            if not LowByte then
              Value := Word((Value and $FF00) or (Value shr 8));
            case (Address shr 1) and 7 of
              0:
                Video.SetAddress(Value);
              1:
                Video.WriteData(Value);
              2:
                Video.Modulo := Value;
              3:
                begin
                  Video.Control(Value);
                  FIRQControl := Value and $F0;
                end;
              4:
                FDisplayCounter := (FDisplayCounter and $FFFF) or (Cardinal(Value) shl 16);
              5:
                begin
                  FDisplayCounter := (FDisplayCounter and $FFFF0000) or Value;
                  if (FIRQControl and $20) <> 0 then
                    FIRQDeadline := FBusTime + (Int64(FDisplayCounter) + 1) * 4;
                end;
              6:
                begin
                  if (Value and 1) <> 0 then
                    FIRQ3 := False;
                  if (Value and 2) <> 0 then
                    FIRQ2 := False;
                  if (Value and 4) <> 0 then
                    FIRQ1 := False;
                  UpdateIRQ;
                end;
            end;
          end;
      end;
    4, 5, 6, 7:
      begin
        var A := Video.PaletteBank * $1000 + Integer((Address shr 1) and $FFF);
        var Previous := Video.Palette[A];
        if HighByte then
          Previous := (Previous and $FF) or (Value and $FF00);
        if LowByte then
          Previous := (Previous and $FF00) or (Value and $FF);
        Video.Palette[A] := Previous;
      end;
    8, 9, $A, $B:
      if HighByte and FCardInserted and not FCardReadOnly and not FCardLock1 and
        FCardUnlock2 and not FCardAttribute then
      begin
        FCard[((Address and $3FFFFF) shr 1) mod Cardinal(Length(FCard))] := Value and $FF;
        FCardDirty := True;
      end;
    $D:
      if FBackupUnlocked and not FCart.AES then
      begin
        if HighByte then
          FBackup[Offset] := Value shr 8;
        if LowByte then
          FBackup[Offset + 1] := Value and $FF;
        FBatteryDirty := True;
      end;
  end;
end;

function TNeoGeoConsole.ReadByte(Address: Cardinal): Byte;
begin
  var Value := ReadBus(Address and $FFFFFE, not Odd(Address), Odd(Address));
  if Odd(Address) then
    Result := Value and $FF
  else
    Result := Value shr 8;
end;

procedure TNeoGeoConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  var Data := Word(Value);
  if not Odd(Address) then
    Data := Data shl 8;
  WriteBus(Address and $FFFFFE, Data, not Odd(Address), Odd(Address));
end;

function TNeoGeoConsole.ReadWord(Address: Cardinal): Word;
begin
  if Odd(Address) then
    raise EArgumentException.Create('Unaligned Neo Geo word');

  Result := ReadBus(Address and $FFFFFF, True, True);
end;

procedure TNeoGeoConsole.WriteWord(Address: Cardinal; Value: Word);
begin
  if Odd(Address) then
    raise EArgumentException.Create('Unaligned Neo Geo word');

  WriteBus(Address and $FFFFFF, Value, True, True);
end;

procedure TNeoGeoConsole.RunFrame;
begin
  if FProtection = ngpIrrmaze then
  begin
    if TEmulatorButton.Left in FInputs.Buttons then
      FTrackX := Byte((Integer(FTrackX) + 252) and $FF);
    if TEmulatorButton.Right in FInputs.Buttons then
      FTrackX := Byte((Integer(FTrackX) + 4) and $FF);
    if TEmulatorButton.Up in FInputs.Buttons then
      FTrackY := Byte((Integer(FTrackY) + 252) and $FF);
    if TEmulatorButton.Down in FInputs.Buttons then
      FTrackY := Byte((Integer(FTrackY) + 4) and $FF);
  end;

  var DisplayReady := Video.StartupVideoReady;
  Sound.BeginFrame;

  // MAME neogeo.h/neogeo.cpp: IRQ1 is latched 58 master clocks into
  // VBlank; the display counter reload follows at master clock 1146.
  var VBlankStart := FFrameTime + Int64(240) * NG_LINE_CLOCKS;
  var VBlankIRQDone := False;
  var VBlankReloadDone := False;
  for var Line := 0 to FCart.FrameLines - 1 do
  begin
    FRenderingLine := Line;
    var Target := FFrameTime + Int64(Line + 1) * NG_LINE_CLOCKS;
    while FCPUTime < Target do
    begin
      if (FCD <> nil) and FCD.State.DMABusy then
      begin
        FCPUTime := Max(FCPUTime, Min(Target, FCD.State.NextDMA));
        FCD.Advance(FCPUTime);
        AdvanceDMA(FCPUTime);
        Continue;
      end;

      // Process timer events in timestamp order before the next instruction.
      // A late CPU instruction can cross both an IRQ2 deadline and reload.
      while True do
      begin
        var EventTime := FIRQDeadline;
        var Event := 0;
        if Line >= 240 then
        begin
          if not VBlankIRQDone and ((EventTime < 0) or (VBlankStart + 58 < EventTime)) then
          begin
            EventTime := VBlankStart + 58;
            Event := 1;
          end;
          if not VBlankReloadDone and ((EventTime < 0) or (VBlankStart + 1146 < EventTime)) then
          begin
            EventTime := VBlankStart + 1146;
            Event := 2;
          end;
        end;
        if (EventTime < 0) or (EventTime > FCPUTime) then
          Break;

        case Event of
          0:
            begin
              if ((FIRQControl and $10) <> 0) and ((FCD = nil) or ((FCD.State.IRQMask2 and $300) = $300)) then
                FIRQ2 := True;
              if (FIRQControl and $80) <> 0 then
                Inc(FIRQDeadline, (Int64(FDisplayCounter) + 1) * 4)
              else
                FIRQDeadline := -1;
            end;
          1:
            begin
              if (FCD = nil) or ((FCD.State.IRQMask2 and $30) = $30) then
                FIRQ1 := True;
              VBlankIRQDone := True;
            end;
          2:
            begin
              if (FIRQControl and $40) <> 0 then
                FIRQDeadline := EventTime + (Int64(FDisplayCounter) + 1) * 4;
              VBlankReloadDone := True;
            end;
        end;
      end;
      if FCD <> nil then
        FCD.Advance(FCPUTime);
      UpdateIRQ;
      FCPUBase := FCPUTime;
      var Vector := -1;
      if FCD <> nil then
      begin
        if FCPU.PendingInterrupt = 1 then
          Vector := $68 div 4
        else if FCPU.PendingInterrupt = 3 then
          Vector := $64 div 4
        else
          Vector := FCD.InterruptVector;
      end;
      if (FCD = nil) and (FCPU.ProgramCounter < $300000) then
        FProgramStarted := True;
      var Cycles := Clown68000DoCycles(FCPU, FCPUCallbacks, 1, Vector);
      FCPUTime := FCPUBase + Int64(Max(1, Integer(Cycles))) * 2;
      if FCPU.Halted <> 0 then
        raise EInvalidOpException.Create('Neo Geo 68000 halted');
    end;
    SyncZ80(Target);
    SyncSound(Target);
    if FCD <> nil then
    begin
      Video.DisplayEnabled := FCD.State.VideoEnabled;
      Video.SpritesEnabled := not FCD.State.SprDisabled and ((FCD.State.BusRequest and 1) = 0);
      Video.FixedEnabled := not FCD.State.FixDisabled;
    end;
    Video.RenderLine(Line);
  end;

  FRenderingLine := -1;

  // Only mask the host framebuffer; the CPU, VRAM and timing run normally.
  // Require readiness at both ends so a mid-frame clear cannot leak test pixels.
  if (FCD = nil) and not FProgramStarted and (not DisplayReady or not Video.StartupVideoReady) then
    Video.ClearFrame;
  Video.NextFrame;
  Inc(FFrameTime, FCart.FrameLines * NG_LINE_CLOCKS);
  if FFrameNumber = High(UInt64) then
    FFrameNumber := 0
  else
    Inc(FFrameNumber);
  if FCoin1 > 0 then
    Dec(FCoin1);
  if FCoin2 > 0 then
    Dec(FCoin2);
  if FWatchdog < 9 then
    Inc(FWatchdog);
  if (FWatchdog > 8) and ((FCD = nil) or not FCD.State.WatchdogDisabled) and (FCart.SetName <> 'neopong10') and (FCart.SetName <> 'syscheck') then
    Reset;
end;

function TNeoGeoConsole.BatteryData: TBytes;
begin
  if FCD <> nil then
  begin
    SetLength(Result, $2000);
    Move(FBackup[0], Result[0], $2000);
    Exit;
  end;

  SetLength(Result, SizeOf(FBackup));
  Move(FBackup[0], Result[0], SizeOf(FBackup));
  if (FProtection = ngpJockeygp) or (FProtection = ngpVliner) then
  begin
    SetLength(Result, SizeOf(FBackup) + $2000);
    for var i := 0 to $FFF do
    begin
      Result[SizeOf(FBackup) + i * 2] := FCartRAM[i] shr 8;
      Result[SizeOf(FBackup) + i * 2 + 1] := FCartRAM[i] and $FF;
    end;
  end;
end;

procedure TNeoGeoConsole.SetMemoryCard(Inserted, ReadOnly: Boolean);
begin
  FCardInserted := Inserted and (FCD = nil);
  FCardReadOnly := ReadOnly;
end;

procedure TNeoGeoConsole.LoadMemoryCard(const Data: TBytes);
begin
  if (Length(Data) < 2048) or (Length(Data) > 16384) or (Length(Data) mod 2048 <> 0) then
    raise EReadError.Create('Invalid Neo Geo memory card size');

  FCard := Copy(Data);
  FCardDirty := False;
end;

function TNeoGeoConsole.MemoryCardData: TBytes;
begin
  Result := Copy(FCard);
end;

procedure TNeoGeoConsole.LoadBattery(const Data: TBytes);
begin
  if FCD <> nil then
  begin
    if Length(Data) <> $2000 then
      raise EReadError.Create('Invalid Neo Geo CD backup RAM size');

    Move(Data[0], FBackup[0], $2000);
    FBatteryDirty := False;
    Exit;
  end;

  var HasCart := (FProtection = ngpJockeygp) or (FProtection = ngpVliner);
  if (Length(Data) <> SizeOf(FBackup)) and not (HasCart and (Length(Data) = SizeOf(FBackup) + $2000)) then
    raise EReadError.Create('Invalid Neo Geo backup RAM size');

  Move(Data[0], FBackup[0], SizeOf(FBackup));
  if HasCart and (Length(Data) > SizeOf(FBackup)) then
    for var i := 0 to $FFF do
      FCartRAM[i] := Word(Integer(Data[SizeOf(FBackup) + i * 2]) * 256 + Data[SizeOf(FBackup) + i * 2 + 1]);

  FBatteryDirty := False;
end;

procedure TNeoGeoConsole.SerializeState(State: TStateArchive);
begin
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FZ80, SizeOf(FZ80));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FBackup, SizeOf(FBackup));
  State.Field(FZRAM, SizeOf(FZRAM));
  State.Field(FBanks, SizeOf(FBanks));
  State.Field(FProgramBank, SizeOf(FProgramBank));
  State.Field(FSmaRandom, SizeOf(FSmaRandom));
  State.Field(FKof98Overlay, SizeOf(FKof98Overlay));
  State.Field(FSlugCommand, SizeOf(FSlugCommand));
  State.Field(FSlugCounter, SizeOf(FSlugCounter));
  State.Field(FFuryShift, SizeOf(FFuryShift));
  State.Field(FPvcRAM, SizeOf(FPvcRAM));
  State.Field(FCartVectors, SizeOf(FCartVectors));
  State.Field(FCartAudio, SizeOf(FCartAudio));
  State.Field(FBackupUnlocked, SizeOf(FBackupUnlocked));
  State.Field(FNMIEnabled, SizeOf(FNMIEnabled));
  State.Field(FCommandPending, SizeOf(FCommandPending));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FReply, SizeOf(FReply));
  State.Field(FCoin1, SizeOf(FCoin1));
  State.Field(FCoin2, SizeOf(FCoin2));
  State.Field(FIRQ1, SizeOf(FIRQ1));
  State.Field(FIRQ2, SizeOf(FIRQ2));
  State.Field(FIRQ3, SizeOf(FIRQ3));
  State.Field(FIRQControl, SizeOf(FIRQControl));
  State.Field(FDisplayCounter, SizeOf(FDisplayCounter));
  State.Field(FIRQDeadline, SizeOf(FIRQDeadline));
  State.Field(FCPUTime, SizeOf(FCPUTime));
  State.Field(FZTime, SizeOf(FZTime));
  State.Field(FSoundTime, SizeOf(FSoundTime));
  State.Field(FCPUBase, SizeOf(FCPUBase));
  State.Field(FBusTime, SizeOf(FBusTime));
  State.Field(FFrameTime, SizeOf(FFrameTime));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FProgramStarted, SizeOf(FProgramStarted));
  State.Field(FBatteryDirty, SizeOf(FBatteryDirty));
  State.Field(FWatchdog, SizeOf(FWatchdog));
  State.Field(FRTCControl, SizeOf(FRTCControl));
  State.Field(FRTCCommand, SizeOf(FRTCCommand));
  State.Field(FRTCBits, SizeOf(FRTCBits));
  State.Field(FRTCShift, SizeOf(FRTCShift));
  State.Field(FRTCReading, SizeOf(FRTCReading));
  State.Field(FRTCMode, SizeOf(FRTCMode));
  State.Field(FRTCTPPeriod, SizeOf(FRTCTPPeriod));
  State.Field(FRTCEpoch, SizeOf(FRTCEpoch));
  State.Field(FRTCTestBase, SizeOf(FRTCTestBase));
  State.Field(FRTCCalendar, SizeOf(FRTCCalendar));
  State.Field(FRTCTesting, SizeOf(FRTCTesting));
  var CardSize := Length(FCard);
  State.Field(CardSize, SizeOf(CardSize));
  if (CardSize <> 0) and ((CardSize < 2048) or (CardSize > 16384) or (CardSize mod 2048 <> 0)) then
    raise EReadError.Create('Invalid memory card snapshot');

  if ((FCart.Disc = nil) and (CardSize = 0)) or ((FCart.Disc <> nil) and (CardSize <> 0)) then
    raise EReadError.Create('Memory card snapshot does not match the machine');

  if State.Loading then
    SetLength(FCard, CardSize);
  if CardSize > 0 then
    State.Field(FCard[0], CardSize);
  State.Field(FCardInserted, SizeOf(FCardInserted));
  State.Field(FCardReadOnly, SizeOf(FCardReadOnly));
  State.Field(FCardLock1, SizeOf(FCardLock1));
  State.Field(FCardUnlock2, SizeOf(FCardUnlock2));
  State.Field(FCardAttribute, SizeOf(FCardAttribute));
  State.Field(FCardBank, SizeOf(FCardBank));
  if State.Loading then
    FCardDirty := True;
  if FCD <> nil then
  begin
    State.Field(FDMASource, SizeOf(FDMASource));
    State.Field(FDMATarget, SizeOf(FDMATarget));
    State.Field(FDMARemaining, SizeOf(FDMARemaining));
    State.Field(FDMAIndex, SizeOf(FDMAIndex));
    State.Field(FDMAMode, SizeOf(FDMAMode));
    State.Field(FDMAPeriod, SizeOf(FDMAPeriod));
    FCD.SerializeState(State);
    if State.Loading and FCD.State.DMABusy then
      if (FDMARemaining = 0) or (FDMARemaining > $200000) or
        not (FDMAPeriod in [8, 16, 24, 32]) or (FCD.State.NextDMA <= FCD.State.Clock) or
        (FDMATarget >= $FF0000) or (FDMAIndex > $200000) then
        raise EReadError.Create('Invalid Neo Geo CD DMA snapshot');

    State.Field(FCart.ProgramROM[0], Length(FCart.ProgramROM));
    State.Field(FCart.SpriteROM[0], Length(FCart.SpriteROM));
    State.Field(FCart.FixedROM[0], Length(FCart.FixedROM));
    State.Field(FCart.AudioROM[0], Length(FCart.AudioROM));
    State.Field(FCart.SamplesA[0], Length(FCart.SamplesA));
  end;
  Video.SerializeState(State);
  Sound.SerializeState(State);

  // These boards previously could not load; standard-cart snapshots retain their layout.
  if HasBootRAM then
  begin
    State.Field(FBootOverlay, SizeOf(FBootOverlay));
    if FProtection = ngpKof10th then
    begin
      State.Field(FSpecialBank, SizeOf(FSpecialBank));
      State.Field(FCartRAM, SizeOf(FCartRAM));
      State.Field(FCart.FixedROM[0], Length(FCart.FixedROM));
    end;
  end;
  if (FProtection = ngpJockeygp) or (FProtection = ngpVliner) then
    State.Field(FCartRAM, $2000);
  if (FProtection = ngpNeogeoMj) or (FProtection = ngpIrrmaze) then
  begin
    State.Field(FInputSelect, SizeOf(FInputSelect));
    State.Field(FTrackX, SizeOf(FTrackX));
    State.Field(FTrackY, SizeOf(FTrackY));
  end;
  if State.Loading then
  begin
    FInZ80 := False;
    if (FProtection = ngpKof10th) and (FSpecialBank <> 0) and (FSpecialBank <> $700000) and (FSpecialBank <> $800000) then
      raise EReadError.Create('Invalid Neo Geo bootleg bank state');

    if (Video.PaletteBank < 0) or (Video.PaletteBank > 1) or (FProgramBank < 0) or (FProgramBank > $10000000) or (FFrameTime < 0) then
      raise EReadError.Create('Invalid Neo Geo snapshot state');

    // Older snapshots may contain an unfiltered BIOS test framebuffer.
    if not Video.StartupVideoReady then
      Video.ClearFrame;
  end;
end;

function TNeoGeoConsole.GetWidth: Integer;
begin
  Result := NG_WIDTH;
end;

function TNeoGeoConsole.GetHeight: Integer;
begin
  Result := FCart.VideoHeight;
end;

function TNeoGeoConsole.GetFPS: Double;
begin
  Result := FCart.MasterClock / (FCart.FrameLines * NG_LINE_CLOCKS);
end;

function TNeoGeoConsole.GetSampleFrames: Integer;
begin
  Result := Sound.SampleFrames;
end;

function TNeoGeoConsole.GetSamples: TArray<SmallInt>;
begin
  Result := Sound.Samples;
end;

procedure TNeoGeoConsole.MarkBatteryDirty;
begin
  FBatteryDirty := True;
end;

initialization
  HW.Z80.ConstantInitialise;

end.

