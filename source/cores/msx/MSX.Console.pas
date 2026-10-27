unit MSX.Console;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes,
  Core.Emulation.Types, Core.Snapshots, Core.AudioFilter, MD.Z80, MSX.Machine,
  MSX.Cartridge, MSX.VDP, MSX.Sound.OPLL, ZX.Sound.YM2149, MSX.RTC, MSX.Cassette,
  MSX.Floppy, MSX.Peripherals;

type
  TMSXConsole = class
  private
    FModel: TMSXModel;
    FCPU: TZ80State;
    FBus: TZ80ReadAndWriteCallbacks;
    FVDP: TMSXVDP;
    FVDPWaitConnected: Boolean;
    FCartridge: TMSXCartridge;
    FCartridge2: TMSXCartridge;
    FFloppy: TMSXFloppy;
    FCassette: TMSXCassette;
    FRTC: TMSXRTC;
    FKanji: TMSXKanji;
    FMice: array[0..1] of TMSXMouse;
    FMousePorts: array[0..1] of Boolean;
    FSecondSlots: Byte;
    FSecondIdentity: string;
    FKanjiBasic: TBytes;
    FResetStatus, FResetInitial: Byte;
    FPSG: TYM2149F;
    FFM: TYM2413;
    FMain, FSub, FLogo, FMusic: TBytes;
    FRAM: array[0..$3FFFF] of Byte;
    FSlots, FSubSlots, FPPIControl, FPPIB, FPPIC: Byte;
    FMapper: array[0..3] of Byte;
    FKeys: TMSXHostKeys;
    FInput: TEmulatorInput;
    FLine, FLineClocks, FSamplePhase, FSampleCount, FWaits, FBusCycles: Integer;
    FFrameNumber: UInt64;
    FSamples: TArray<SmallInt>;
    FClickDC: TPCMDCBlocker;
    FState: TStateArchive;
    function KeyboardRow: Byte;
    function PSGPort(Port: Integer): Byte;
    function RAMSelected(Address: Word): Boolean;
    procedure Advance(Cycles: Integer);
    procedure CompleteVDPIO;
    procedure StateField(var Value; Size: Integer);
    function SecondSlotExpanded: Boolean;
    procedure UpdatePeripheralLines;
    function GetFPS: Double;
  public
    constructor Create(const Data: TBytes; Model: TMSXModel; MapperHint: Integer = -1; const BIOS: TBytes = nil; const SubROM: TBytes = nil);
    destructor Destroy; override;
    procedure Reset;
    procedure ConfigurePeripherals(const Options: TMSXPeripheralOptions);
    procedure SetMousePorts(Port1, Port2: Boolean);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    procedure SetInput(const Input: TEmulatorInput; const Keys: TMSXHostKeys);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Word; CPUCycle: Boolean = False): Byte;
    procedure WritePort(Address: Word; Value: Byte);
    function Step: Integer;
    procedure ClearSamples;
    procedure RunFrame;
    procedure SerializeState(State: TStateArchive);
    property Model: TMSXModel read FModel;
    property VDP: TMSXVDP read FVDP;
    property Cartridge: TMSXCartridge read FCartridge;
    property Cartridge2: TMSXCartridge read FCartridge2;
    property Floppy: TMSXFloppy read FFloppy;
    property Cassette: TMSXCassette read FCassette;
    property RTC: TMSXRTC read FRTC;
    property CPU: TZ80State read FCPU;
    property FrameNumber: UInt64 read FFrameNumber;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleCount;
    property FramesPerSecond: Double read GetFPS;
  end;

implementation

uses
  MSX.Firmware;

function BusRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TMSXConsole(Context).ReadMemory(Address and $FFFF);
end;

procedure BusWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TMSXConsole(Context).WriteMemory(Address and $FFFF, Value and $FF);
end;

function IORead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  var C := TMSXConsole(Context);
  Result := C.ReadPort(Address and $FFFF, True);
  C.CompleteVDPIO;
end;

procedure IOWrite(Context: Pointer; Address, Value: Cardinal);
begin
  var C := TMSXConsole(Context);
  C.WritePort(Address and $FFFF, Value and $FF);
  C.CompleteVDPIO;
end;

procedure BusCycle(Context: Pointer; Kind: TZ80BusCycle; Address, Count: Cardinal);
begin
  var C := TMSXConsole(Context);
  var Ticks := Integer(Count);
  // MSX inserts one wait state into every M1 cycle, including prefixes/HALT.
  if Kind in [zbcOpcode, zbcAcknowledge] then
  begin
    Inc(C.FWaits);
    Inc(Ticks);
  end;
  Inc(C.FBusCycles, Ticks);
  C.Advance(Ticks);
end;

constructor TMSXConsole.Create(const Data: TBytes; Model: TMSXModel; MapperHint: Integer; const BIOS, SubROM: TBytes);
begin
  inherited Create;
  FModel := Model;
  LoadMSXFirmware(Model, FMain, FSub, FLogo, FMusic);
  if Length(BIOS) > 0 then
  begin
    if Length(BIOS) <> $8000 then
      raise EReadError.Create('MSX BIOS must be 32 KiB');
    FMain := Copy(BIOS);
    FLogo := nil;
    FMusic := nil;
    if (Model <> MSX1) and (Length(SubROM) <> $4000) then
      raise EReadError.Create('MSX2/2+ external BIOS requires a matching 16 KiB sub-ROM');
    FSub := Copy(SubROM);
  end;
  FResetInitial := 0;
  if (Model = MSX2Plus) and (FMain[$17A] = $C3) then
  begin
    var Entry := Integer(FMain[$17B]) or (Integer(FMain[$17C]) shl 8);
    if (Entry < $7FFD) and (FMain[Entry] = $DB) and (FMain[Entry + 1] = $F4) and
      (FMain[Entry + 2] = $2F) then
      FResetInitial := $FF;
  end;
  FVDP := TMSXVDP.Create(Model, (FMain[$2B] and $80) <> 0, True);
  var CartData := Data;
  if Length(CartData) = 0 then
  begin
    SetLength(CartData, $2000);
    FillChar(CartData[0], Length(CartData), $FF);
  end;
  FCartridge := TMSXCartridge.Create(CartData, MapperHint);
  FSecondIdentity := SnapshotIdentity(nil);
  FRTC := TMSXRTC.Create;
  FFloppy := TMSXFloppy.Create;
  FCassette := TMSXCassette.Create;
  FKanji := TMSXKanji.Create;
  for var I := 0 to 1 do
    FMice[I] := TMSXMouse.Create;
  FPSG := TYM2149F.Create(1789772);
  FPSG.AYModel := True;
  FPSG.OnPortRead := PSGPort;
  for var i := 0 to 2 do
    FPSG.SetPan(i, 1, 1);
  if Model = MSX2Plus then
    FFM := TYM2413.Create;
  FBus := Default(TZ80ReadAndWriteCallbacks);
  FBus.UserData := Self;
  FBus.ReadCallback := BusRead;
  FBus.WriteCallback := BusWrite;
  FBus.PortReadCallback := IORead;
  FBus.PortWriteCallback := IOWrite;
  FBus.CycleCallback := BusCycle;
  SetLength(FSamples, 2048 * 2);
  FClickDC.Configure(44100, 20);
  Reset;
end;

destructor TMSXConsole.Destroy;
begin
  FVDP.Free;
  FCartridge.Free;
  FCartridge2.Free;
  FPSG.Free;
  FFM.Free;
  FRTC.Free;
  FFloppy.Free;
  FCassette.Free;
  FKanji.Free;
  for var Mouse in FMice do
    Mouse.Free;
  inherited;
end;

procedure TMSXConsole.Reset;
begin
  FCPU := Default(TZ80State);
  Z80StateInitialise(FCPU);
  FCPU.StackPointer := $FFFF;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FSlots := 0;
  FSubSlots := 0;
  FPPIControl := $9B;
  FPPIB := 0;
  FPPIC := 0;
  for var i := 0 to 3 do
    FMapper[i] := i;
  FRTC.ResetBus;
  FFloppy.Reset;
  FKanji.Reset;
  FSecondSlots := 0;
  FResetStatus := FResetInitial;
  for var Mouse in FMice do
    Mouse.Reset;
  if FCartridge2 <> nil then
    FCartridge2.Reset;
  FLine := 0;
  FLineClocks := 0;
  FSamplePhase := 0;
  FSampleCount := 0;
  FFrameNumber := 0;
  FWaits := 0;
  FClickDC.Reset;
  FVDP.Reset;
  FCartridge.Reset;
  FPSG.Reset;
  if FModel <> MSX1 then
    FVDP.EndLine(-1, FVDP.TotalLines);
  if FFM <> nil then
    FFM.Reset;
  UpdatePeripheralLines;
end;

procedure TMSXConsole.ConfigurePeripherals(const Options: TMSXPeripheralOptions);
begin
  FVDP.ConfigureChip(Options.VDPChip);
  if Options.VDPWaitConnected and (FVDP.Chip <> VDPV9958) then
    raise EArgumentException.Create('VDP WAIT connection requires a V9958 machine');
  FVDPWaitConnected := Options.VDPWaitConnected;
  FFloppy.SetROM(Options.DiskROM);
  if Length(Options.DiskA) > 0 then
    FFloppy.Controller.MountImage(Options.DiskA, 0, Options.DiskWriteProtected);
  if Length(Options.DiskB) > 0 then
    FFloppy.Controller.MountImage(Options.DiskB, 1, Options.DiskWriteProtected);
  FKanji.Load(Options.KanjiROM);
  if (Length(Options.KanjiBasicROM) <> 0) and
    ((Length(Options.KanjiBasicROM) <> $8000) or (FModel = MSX1)) then
    raise EReadError.Create('Kanji BASIC requires a matching 32 KiB ROM and MSX2/2+');
  FKanjiBasic := Copy(Options.KanjiBasicROM);
  if Length(Options.MusicROM) > 0 then
  begin
    if (Length(Options.MusicROM) <> $4000) or (FModel = MSX1) then
      raise EReadError.Create('MSX-MUSIC extension ROM requires 16 KiB and MSX2/2+');
    FMusic := Copy(Options.MusicROM);
    if FFM = nil then
    begin
      FFM := TYM2413.Create;
      FFM.Reset;
    end;
  end;
  var Cart2: TMSXCartridge := nil;
  if Length(Options.Cartridge2) > 0 then
    Cart2 := TMSXCartridge.Create(Options.Cartridge2, Options.Mapper2);
  FCartridge2.Free;
  FCartridge2 := Cart2;
  if Options.AudioSampleRAM <> 0 then
  begin
    FCartridge.ConfigureAudioRAM(Options.AudioSampleRAM);
    if FCartridge2 <> nil then
      FCartridge2.ConfigureAudioRAM(Options.AudioSampleRAM);
  end;
  FSecondIdentity := SnapshotIdentity(Options.Cartridge2);
  if Length(Options.Tape) > 0 then
    FCassette.Load(Options.Tape, Options.TapeCAS, Options.TapeBaud);
  case Options.TapeMode of
    1:
      FCassette.Play;
    2:
      FCassette.RecordTape;
  end;
  SetMousePorts(Options.MousePort = 1, Options.MousePort = 2);
  UpdatePeripheralLines;
end;

function TMSXConsole.SecondSlotExpanded: Boolean;
begin
  Result := (FModel = MSX1) and FFloppy.Enabled and (FCartridge2 <> nil);
end;

procedure TMSXConsole.UpdatePeripheralLines;
begin
  FCassette.SetLines(FPPIC and $10 = 0, FPPIC and $20 <> 0);
  var Pins := FPSG.ReadRegister(15);
  FMice[0].WriteStrobe(Pins and $10 <> 0);
  FMice[1].WriteStrobe(Pins and $20 <> 0);
end;

procedure TMSXConsole.SetMousePorts(Port1, Port2: Boolean);
begin
  if FMousePorts[0] <> Port1 then
    FMice[0].Reset;
  if FMousePorts[1] <> Port2 then
    FMice[1].Reset;
  FMousePorts[0] := Port1;
  FMousePorts[1] := Port2;
  UpdatePeripheralLines;
end;

procedure TMSXConsole.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  for var I := 0 to 1 do
    if FMousePorts[I] then
      FMice[I].Move(DX, DY, Buttons);
end;

function TMSXConsole.RAMSelected(Address: Word): Boolean;
begin
  Result := ((FSlots shr ((Address shr 14) * 2)) and 3) = 3;
  if (FModel <> MSX1) and Result then
    Result := ((FSubSlots shr ((Address shr 14) * 2)) and 3) = 2;
end;

function TMSXConsole.ReadMemory(Address: Word): Byte;
begin
  var Page := Address shr 14;
  var Slot := (FSlots shr (Page * 2)) and 3;
  if (Address = $FFFF) and (Slot = 3) and (FModel <> MSX1) then
    Exit(FSubSlots xor $FF);
  if (Address = $FFFF) and (Slot = 2) and SecondSlotExpanded then
    Exit(FSecondSlots xor $FF);
  if RAMSelected(Address) then
  begin
    if FModel = MSX1 then
      Exit(FRAM[Address]);
    Exit(FRAM[Integer(FMapper[Page] and 15) * $4000 + (Address and $3FFF)]);
  end;
  Result := $FF;
  case Slot of
    0:
      if Address < $8000 then
        Result := FMain[Address]
      else if (Address < $C000) and (Length(FLogo) > 0) then
        Result := FLogo[Address - $8000];
    1:
      Result := FCartridge.Read(Address);
    2:
      begin
        var Sub := 0;
        if SecondSlotExpanded then
          Sub := (FSecondSlots shr (Page * 2)) and 3;
        if (FCartridge2 <> nil) and (Sub = 0) then
          Result := FCartridge2.Read(Address)
        else if (FModel = MSX1) and ((FCartridge2 = nil) or (Sub = 1)) then
          Result := FFloppy.ReadMemory(Address);
      end;
    3:
      if FModel <> MSX1 then
        case (FSubSlots shr (Page * 2)) and 3 of
          0:
            begin
              if (Address >= $4000) and (Address < $C000) and (Length(FKanjiBasic) > 0) then
                Result := FKanjiBasic[Address - $4000]
              else if Length(FSub) > 0 then
                Result := FSub[Address and $3FFF];
            end;
          1:
            if (Address >= $4000) and (Address < $8000) and (Length(FMusic) > 0) then
              Result := FMusic[Address - $4000];
          3:
            Result := FFloppy.ReadMemory(Address);
        end;
  end;
end;

procedure TMSXConsole.WriteMemory(Address: Word; Value: Byte);
begin
  var Page := Address shr 14;
  var Slot := (FSlots shr (Page * 2)) and 3;
  if (Address = $FFFF) and (Slot = 3) and (FModel <> MSX1) then
  begin
    FSubSlots := Value;
    Exit;
  end;
  if (Address = $FFFF) and (Slot = 2) and SecondSlotExpanded then
  begin
    FSecondSlots := Value;
    Exit;
  end;
  if RAMSelected(Address) then
  begin
    if FModel = MSX1 then
      FRAM[Address] := Value
    else
      FRAM[Integer(FMapper[Page] and 15) * $4000 + (Address and $3FFF)] := Value;
  end
  else if Slot = 1 then
    FCartridge.Write(Address, Value)
  else if Slot = 2 then
  begin
    var Sub := 0;
    if SecondSlotExpanded then
      Sub := (FSecondSlots shr (Page * 2)) and 3;
    if (FCartridge2 <> nil) and (Sub = 0) then
      FCartridge2.Write(Address, Value)
    else if (FModel = MSX1) and ((FCartridge2 = nil) or (Sub = 1)) then
      FFloppy.WriteMemory(Address, Value);
  end
  else if (Slot = 3) and (FModel <> MSX1) and ((FSubSlots shr (Page * 2)) and 3 = 3) then
    FFloppy.WriteMemory(Address, Value);
end;

procedure TMSXConsole.SetInput(const Input: TEmulatorInput; const Keys: TMSXHostKeys);
begin
  FInput := Input;
  FKeys := Keys;
  FKeys[vkShift] := FKeys[vkShift] or FKeys[vkLShift] or FKeys[vkRShift];
  FKeys[vkControl] := FKeys[vkControl] or FKeys[vkLControl] or FKeys[vkRControl];
  FKeys[vkMenu] := FKeys[vkMenu] or FKeys[vkLMenu];
  FKeys[vkSpace] := FKeys[vkSpace] or (TEmulatorButton.A in Input.Buttons);
  FKeys[vkReturn] := FKeys[vkReturn] or (TEmulatorButton.Start in Input.Buttons);
  FKeys[vkF1] := FKeys[vkF1] or (TEmulatorButton.Select in Input.Buttons);
end;

function TMSXConsole.KeyboardRow: Byte;
const
  // International/Japanese common matrix. Host OEM keys use physical positions.
  Matrix: array[0..10, 0..7] of Integer = (
    ($30, $31, $32, $33, $34, $35, $36, $37),
    ($38, $39, $BD, $BB, $DC, $DB, $DD, $BA),
    ($DE, $C0, $BC, $BE, $BF, 0, $41, $42),
    ($43, $44, $45, $46, $47, $48, $49, $4A),
    ($4B, $4C, $4D, $4E, $4F, $50, $51, $52),
    ($53, $54, $55, $56, $57, $58, $59, $5A),
    (vkShift, vkControl, vkMenu, vkCapital, vkRMenu, vkF1, vkF2, vkF3),
    (vkF4, vkF5, vkEscape, vkTab, vkPause, vkBack, vkEnd, vkReturn),
    (vkSpace, vkHome, vkInsert, vkDelete, vkLeft, vkUp, vkDown, vkRight),
    (vkMultiply, vkAdd, vkDivide, vkNumpad0, vkNumpad1, vkNumpad2, vkNumpad3, vkNumpad4),
    (vkNumpad5, vkNumpad6, vkNumpad7, vkNumpad8, vkNumpad9, vkSubtract, vkSeparator, vkDecimal));
begin
  Result := $FF;
  var Row := FPPIC and 15;
  if Row > 10 then
    Exit;
  for var Bit := 0 to 7 do
    if (Matrix[Row, Bit] <> 0) and FKeys[Matrix[Row, Bit]] then
      Result := Result and ($FF xor (1 shl Bit));
end;

function TMSXConsole.PSGPort(Port: Integer): Byte;
const
  Mapping: array[0..5] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B);
begin
  Result := $FF;
  if Port <> 0 then
    Exit;
  var Control := FPSG.ReadRegister(15);
  var PortIndex := Ord(Control and $40 <> 0);
  if FMousePorts[PortIndex] then
  begin
    Result := $80 or FMice[PortIndex].Read;
    if not FCassette.Input then
      Result := Result and $7F;
    Exit;
  end;
  var Buttons := FInput.Buttons;
  var Strobe := $10;
  if Control and $40 <> 0 then
  begin
    Buttons := FInput.Buttons2;
    Strobe := $20;
  end;
  // A standard MSX joystick returns its switches through pin 8. Raising
  // that port's strobe releases all six inputs, independently of port select.
  if Control and Strobe <> 0 then
    Buttons := [];
  for var Bit := 0 to 5 do
    if Mapping[Bit] in Buttons then
      Result := Result and ($FF xor (1 shl Bit));
  // Released cassette input high, Japanese keyboard layout pin low.
  Result := Result and $BF;
  if not FCassette.Input then
    Result := Result and $7F;
end;

function TMSXConsole.ReadPort(Address: Word; CPUCycle: Boolean): Byte;
begin
  Result := $FF;
  case Address and $FF of
    $98:
      Result := FVDP.ReadData;
    $99:
      if CPUCycle then
        Result := FVDP.ReadStatusCPU
      else
        Result := FVDP.ReadStatus;
    $A2:
      Result := FPSG.ReadData;
    $A8:
      Result := FSlots;
    $A9:
      if FPPIControl and 2 <> 0 then
        Result := KeyboardRow
      else
        Result := FPPIB;
    $AA:
      Result := FPPIC;
    $B5:
      if FModel <> MSX1 then
        Result := FRTC.ReadData;
    $D8..$DB:
      Result := FKanji.ReadPort(Address and $FF);
    $F4:
      if FModel = MSX2Plus then
        Result := FResetStatus;
    $FC..$FF:
      if FModel <> MSX1 then
        Result := $F0 or FMapper[Address and 3];
  end;
  Result := Result and FCartridge.ReadPort(Address and $FF);
  if FCartridge2 <> nil then
    Result := Result and FCartridge2.ReadPort(Address and $FF);
end;

procedure TMSXConsole.WritePort(Address: Word; Value: Byte);
begin
  if Address and $FF in [$00..$1F, $C0..$C3] then
  begin
    FCartridge.WritePort(Address and $FF, Value);
    if FCartridge2 <> nil then
      FCartridge2.WritePort(Address and $FF, Value);
  end;
  case Address and $FF of
    $7C, $7D:
      begin
        if FFM <> nil then
          FFM.WritePort(Address and 1, Value);
        FCartridge.WritePort(Address and $FF, Value);
        if FCartridge2 <> nil then
          FCartridge2.WritePort(Address and $FF, Value);
      end;
    $98:
      FVDP.WriteData(Value);
    $99:
      FVDP.WriteControl(Value);
    $9A:
      FVDP.WritePalette(Value);
    $9B:
      FVDP.WriteIndirect(Value);
    $A0:
      FPSG.WriteAddress(Value);
    $A1:
      FPSG.WriteData(Value);
    $A8:
      if FPPIControl and $10 = 0 then
        FSlots := Value;
    $A9:
      if FPPIControl and 2 = 0 then
        FPPIB := Value;
    $AA:
      begin
        var Mask := 0;
        if FPPIControl and 1 = 0 then
          Mask := Mask or $0F;
        if FPPIControl and 8 = 0 then
          Mask := Mask or $F0;
        FPPIC := (FPPIC and ($FF xor Mask)) or (Value and Mask);
      end;
    $AB:
      if Value and $80 <> 0 then
      begin
        FPPIControl := Value;
        FSlots := 0;
        FPPIB := 0;
        FPPIC := 0;
      end
      else
      begin
        var Bit := (Value shr 1) and 7;
        FPPIC := FPPIC and ($FF xor (1 shl Bit));
        if Value and 1 <> 0 then
          FPPIC := FPPIC or (1 shl Bit);
      end;
    $B4:
      if FModel <> MSX1 then
        FRTC.Select(Value);
    $B5:
      if FModel <> MSX1 then
        FRTC.WriteData(Value);
    $D8..$DB:
      FKanji.WritePort(Address and $FF, Value);
    $F4:
      if FModel = MSX2Plus then
        FResetStatus := Value;
    $FC..$FF:
      if FModel <> MSX1 then
        FMapper[Address and 3] := Value and 15;
  end;
  if (Address and $FF in [$A0, $A1, $AA, $AB]) then
    UpdatePeripheralLines;
end;

procedure TMSXConsole.CompleteVDPIO;
begin
  if not FVDPWaitConnected then
    Exit;
  // MD.Z80 delivers the port operation at the end of its I/O bus cycle.
  // Retain every added CPU T-state in peripherals, raster and Step's result.
  // Pin assertion/Tw sample phase is not calibrated by this callback model.
  while FVDP.CPUWaitAsserted do
  begin
    Inc(FWaits);
    Inc(FBusCycles);
    Advance(1);
  end;
end;

procedure TMSXConsole.Advance(Cycles: Integer);
begin
  while Cycles > 0 do
  begin
    var Chunk := Min(Cycles, (FVDP.ScanlineClocks - FLineClocks + 5) div 6);
    Chunk := Min(Chunk, (3579545 - FSamplePhase + 44099) div 44100);
    Dec(Cycles, Chunk);
    var VideoClocks := Chunk * 6;
    while VideoClocks > 0 do
    begin
      var Part := Min(VideoClocks, FVDP.ScanlineClocks - FLineClocks);
      FVDP.AdvanceMasterClocks(Part);
      Inc(FLineClocks, Part);
      Dec(VideoClocks, Part);
      if FLineClocks = FVDP.ScanlineClocks then
      begin
        FLineClocks := 0;
        if FLine < FVDP.ScreenHeight then
          FVDP.RenderLine(FLine);
        FVDP.EndLine(FLine, FVDP.TotalLines);
        Inc(FLine);
        if FLine >= FVDP.TotalLines then
        begin
          FLine := 0;
          if FFrameNumber = High(UInt64) then
            FFrameNumber := 0
          else
            Inc(FFrameNumber);
        end;
      end;
    end;
    FCartridge.AdvanceClocks(Chunk);
    if FCartridge2 <> nil then
      FCartridge2.AdvanceClocks(Chunk);
    if FModel <> MSX1 then
      FRTC.Advance(Chunk);
    FFloppy.Advance(Chunk);
    FCassette.Advance(Chunk);
    for var I := 0 to 1 do
      if FMousePorts[I] then
        FMice[I].Advance(Chunk);
    Inc(FSamplePhase, Chunk * 44100);
    if FSamplePhase >= 3579545 then
    begin
      Dec(FSamplePhase, 3579545);
      if FSampleCount >= Length(FSamples) div 2 then
        raise EInvalidOpException.Create('MSX audio buffer exhausted');
      var L, R: SmallInt;
      FPSG.Sample(L, R);
      var Mixed := (Integer(L) + Integer(R)) div 2 + FCartridge.Sample +
        Round(FClickDC.Process(Ord(FPPIC and $80 <> 0) * 1400));
      if FCartridge2 <> nil then
        Inc(Mixed, FCartridge2.Sample);
      if FFM <> nil then
      begin
        FFM.Sample(L, R);
        Inc(Mixed, (Integer(L) + Integer(R)) div 2);
      end;
      FSamples[FSampleCount * 2] := EnsureRange(Mixed, -32768, 32767);
      FSamples[FSampleCount * 2 + 1] := FSamples[FSampleCount * 2];
      Inc(FSampleCount);
    end;
  end;
end;

function TMSXConsole.Step: Integer;
begin
  var IRQ := FVDP.Interrupt or FCartridge.Interrupt;
  if FCartridge2 <> nil then
    IRQ := IRQ or FCartridge2.Interrupt;
  Z80Interrupt(FCPU, Ord(IRQ));
  FWaits := 0;
  FBusCycles := 0;
  Result := Integer(Z80DoInstruction(FCPU, FBus)) + FWaits;
  if FBusCycles > Result then
    raise EInvalidOpException.Create('MSX Z80 bus timing exceeds instruction');
  if FBusCycles < Result then
    Advance(Result - FBusCycles);
end;

procedure TMSXConsole.RunFrame;
begin
  ClearSamples;
  var Frame := FFrameNumber;
  repeat
    Step
  until FFrameNumber <> Frame;
end;

procedure TMSXConsole.ClearSamples;
begin
  FSampleCount := 0;
end;

function TMSXConsole.GetFPS: Double;
begin
  Result := (3579545.0 * 6) / (FVDP.ScanlineClocks * FVDP.TotalLines);
end;

procedure TMSXConsole.StateField(var Value; Size: Integer);
begin
  FState.Field(Value, Size);
end;

procedure TMSXConsole.SerializeState(State: TStateArchive);
begin
  var Model := FModel;
  State.Field(Model, SizeOf(Model));
  if State.Loading and (Model <> FModel) then
    raise EReadError.Create('MSX snapshot model differs');
  var SavedWaitConnected := FVDPWaitConnected;
  State.Field(SavedWaitConnected, SizeOf(SavedWaitConnected));
  if State.Loading and (SavedWaitConnected <> FVDPWaitConnected) then
    raise EReadError.Create('MSX VDP WAIT wiring differs');
  // The firmware identity belongs to the machine, not just the cartridge.
  var Identity := SnapshotIdentity(FMain) + SnapshotIdentity(FSub) +
    SnapshotIdentity(FMusic) + SnapshotIdentity(FKanjiBasic) + FSecondIdentity + FFloppy.Identity + FKanji.Identity;
  var SavedIdentity := TEncoding.ASCII.GetBytes(Identity);
  State.Field(SavedIdentity[0], Length(SavedIdentity));
  if State.Loading and (TEncoding.ASCII.GetString(SavedIdentity) <> Identity) then
    raise EReadError.Create('MSX snapshot firmware differs');
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FSlots, SizeOf(FSlots));
  State.Field(FSubSlots, SizeOf(FSubSlots));
  State.Field(FPPIControl, SizeOf(FPPIControl));
  State.Field(FPPIB, SizeOf(FPPIB));
  State.Field(FPPIC, SizeOf(FPPIC));
  State.Field(FMapper, SizeOf(FMapper));
  FRTC.SerializeState(State);
  State.Field(FResetStatus, SizeOf(FResetStatus));
  State.Field(FSecondSlots, SizeOf(FSecondSlots));
  var HasCart2 := FCartridge2 <> nil;
  var SavedCart2 := HasCart2;
  State.Field(SavedCart2, SizeOf(SavedCart2));
  if State.Loading and (HasCart2 <> SavedCart2) then
    raise EReadError.Create('MSX second cartridge differs');
  if HasCart2 then
  begin
    var Identity2 := TEncoding.ASCII.GetBytes(FSecondIdentity);
    var Saved2 := Copy(Identity2);
    State.Field(Saved2[0], Length(Saved2));
    if State.Loading and not CompareMem(@Saved2[0], @Identity2[0], Length(Saved2)) then
      raise EReadError.Create('MSX second cartridge ROM differs');
    FCartridge2.SerializeState(State);
  end;
  FFloppy.SerializeState(State);
  FCassette.SerializeState(State);
  FKanji.SerializeState(State);
  State.Field(FMousePorts, SizeOf(FMousePorts));
  for var Mouse in FMice do
    Mouse.SerializeState(State);
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineClocks, SizeOf(FLineClocks));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FClickDC, SizeOf(FClickDC));
  FCartridge.SerializeState(State);
  FVDP.SerializeState(State);
  FState := State;
  try
    FPSG.SerializeState(StateField);
  finally
    FState := nil;
  end;
  if FFM <> nil then
    FFM.SerializeState(State);
  if State.Loading then
  begin
    FSampleCount := 0;
    if (FLine < 0) or (FLine >= 313) or (FLineClocks < 0) or (FLineClocks >= FVDP.ScanlineClocks) or
      (FSamplePhase < 0) or (FSamplePhase >= 3579545) then
      raise EReadError.Create('Invalid MSX machine state');
  end;
end;

initialization
  MD.Z80.ConstantInitialise;

end.

