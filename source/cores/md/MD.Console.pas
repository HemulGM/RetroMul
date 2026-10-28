unit MD.Console;

interface

uses
  Core.InputConfig, Core.Snapshots, System.Classes, System.SysUtils,
  System.UITypes, MD.Cartridge, MD.M68k, MD.Z80, MD.VDP, MD.Sound,
  Core.AudioFilter, MD.EEPROM, MD.Mapper, MD.Mars, MD.MegaCD, Core.CD.Disc;

{$SCOPEDENUMS ON}

type
  TMDButton = (Up, Down, Left, Right, A, B, C, Start, X, Y, Z, Mode);

  TMDButtons = set of TMDButton;

  TMDConsole = class
  private
    FCartridge: TMDCartridge;
    FEEPROM: TMDEEPROM;
    FMapper: TMDMapper;
    F32X: TMD32X;
    FCD: TMDMegaCD;
    FCDAudioEnabled, F32XAudioEnabled: Boolean;
    FCDVolume, F32XVolume: Integer;
    FCPU: TM68kState;
    FCPUCallbacks: TM68kReadWriteCallbacks;
    FZ80: TZ80State;
    FZ80Callbacks: TZ80ReadAndWriteCallbacks;
    FVDP: TVDP;
    FFM: TFM;
    FPSG: TPSG;
    FRAM: array[0..65535] of Byte;
    FZRAM: array[0..8191] of Byte;
    FIO: array[0..15] of Byte;
    FPalette: array[0..191] of TAlphaColor;
    FFrame: TArray<TAlphaColor>;
    FAudio: TArray<SmallInt>;
    FAudioCount: Integer;
    FWidth, FHeight, FScanline, FMasterClock, FLines: Integer;
    FFrameNumber: UInt64;
    FFrameTime, FCPUTime, FCPUBase, FZ80Time, FBusTime: Int64;
    FAudioTime, FNextFM, FNextPSG, FNextPCM, FPCMNumber, FLastPCM: Int64;
    FAreaLeft, FAreaRight: Double;
    FFMFilter: array[0..1] of TPCMLowPass;
    FPSGFilter: TPCMLowPass;
    FOutputDC: array[0..1] of TPCMDCBlocker;
    FFilteredFM: array[0..1] of Double;
    FFilteredPSG: Double;
    FFMSamples: array[0..1] of SmallInt;
    FPSGSamples: array[0..0] of SmallInt;
    FBusyUntil: Int64;
    FPadTimeout: array[1..4] of Int64;
    FBusRequested, FZReset, FInZ80, FVInt, FHInt: Boolean;
    FZBank: Word;
    FButtons: array[1..4] of TMDButtons;
    FStrobes: array[1..4] of Integer;
    FTH: array[1..4] of Boolean;
    FPadDevices: array[1..4] of string;
    FSRAM: TBytes;
    FSRAMStart, FSRAMEnd, FSRAMStride: Cardinal;
    FSRAMEnabled, FSRAMReadOnly, FSRAMDirty: Boolean;
    FCPULastAccess: Int64;
    FRasterX: Integer;
    FRasterReady: Boolean;
    FRasterPixels: array[0..639] of Byte;
    procedure RenderRasterTo(Time: Int64);
    procedure SyncVDP(Time: Int64);
    procedure SyncAudio(Target: Int64);
    procedure SyncZ80(Target: Int64);
    procedure RunUntil(Target: Int64);
    procedure UpdateIRQ;
    function ReadPad(Port: Integer): Byte;
    procedure SetPadTH(Port: Integer; Value: Boolean);
    procedure WriteIO(Index: Integer; Value: Byte);
    function ReadZ80(Address: Word): Byte;
    procedure WriteZ80(Address: Word; Value: Byte);
    function ReadBus(Address: Cardinal; HighByte, LowByte: Boolean): Word;
    procedure WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
    function SRAMIndex(Address: Cardinal; out Index: Cardinal): Boolean;
    function GetBatteryDirty: Boolean;
  public
    constructor Create(const Data: TBytes; const Extension: string; Disc: TCDDisc = nil);
    destructor Destroy; override;
    property CDVolume: Integer read FCDVolume write FCDVolume;
    property Volume32X: Integer read F32XVolume write F32XVolume;
    property CDAudioEnabled: Boolean read FCDAudioEnabled write FCDAudioEnabled;
    property Audio32XEnabled: Boolean read F32XAudioEnabled write F32XAudioEnabled;
    procedure Reset;
    procedure RunFrame;
    procedure ConfigureInputPorts(const Ports: TCoreInputPorts);
    procedure SetInput(const Buttons: TMDButtons; const Buttons2: TMDButtons = []; const Buttons3: TMDButtons = []; const Buttons4: TMDButtons = []);
    function ReadByte(Address: Cardinal): Byte;
    function ReadWord(Address: Cardinal): Word;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    procedure WriteWord(Address: Cardinal; Value: Word);
    procedure LoadBattery(const Data: TBytes);
    procedure MarkBatteryDirty;
    function BatteryData: TBytes;
    property BatteryDirty: Boolean read GetBatteryDirty;
    property Pixels: TArray<TAlphaColor> read FFrame;
    property Samples: TArray<SmallInt> read FAudio;
    property SampleFrames: Integer read FAudioCount;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property FrameNumber: UInt64 read FFrameNumber;
    property Expansion32X: TMD32X read F32X;
    property ExpansionCD: TMDMegaCD read FCD;
    function FramesPerSecond: Double;

    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math, MD.Firmware;

function DMARead(User: Pointer; Address, Cycle: Cardinal): Cardinal; forward;

function CPURead(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte): Cardinal;
begin
  var C := TMDConsole(User);
  C.FBusTime := Max(C.FCPUBase + Int64(Cycle) * 7, C.FCPULastAccess + 28);
  var Start := C.FBusTime;
  Result := C.ReadBus(Address * 2, Hi <> 0, Lo <> 0);
  Inc(C.FCPUBase, C.FBusTime - Start);
  C.FCPULastAccess := C.FBusTime;
  if (C.FVDP.State.DMAActive <> 0) or (C.FBusTime <> Start) then
    Early := 1;
end;

procedure CPUWrite(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte; Value: Cardinal);
begin
  var C := TMDConsole(User);
  C.FBusTime := Max(C.FCPUBase + Int64(Cycle) * 7, C.FCPULastAccess + 28);
  var Start := C.FBusTime;
  C.WriteBus(Address * 2, Word(Value), Hi <> 0, Lo <> 0);
  Inc(C.FCPUBase, C.FBusTime - Start);
  C.FCPULastAccess := C.FBusTime;
  if (C.FVDP.State.DMAActive <> 0) or (C.FBusTime <> Start) then
    Early := 1;
end;

procedure CPUAck(User: Pointer);
begin
  var C := TMDConsole(User);
  if C.FCPU.PendingInterrupt = 6 then
    C.FVInt := False
  else
    C.FHInt := False;
  C.UpdateIRQ;
end;

function ZRead(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TMDConsole(User).ReadZ80(Word(Address and $FFFF));
end;

procedure ZWrite(User: Pointer; Address, Value: Cardinal);
begin
  TMDConsole(User).WriteZ80(Word(Address and $FFFF), Byte(Value and $FF));
end;

procedure ColourUpdated(User: Pointer; Index, Colour: Cardinal);
begin
  if Index >= 192 then
    Exit;
  TMDConsole(User).RenderRasterTo(TMDConsole(User).FVDP.State.MasterTime);
  TMDConsole(User).FPalette[Index] := $FF000000 or
    ((Colour and $F) * 17 shl 16) or
    (((Colour shr 4) and $F) * 17 shl 8) or
    (((Colour shr 8) and $F) * 17);

  // A CRAM write temporarily drives the output DAC even when the palette
  // entry is not selected by the current background/sprite pixel.
  var C := TMDConsole(User);
  if (Index < 64) and (C.FVDP.State.DisplayEnabled <> 0) and
    (C.FScanline >= 0) and (C.FScanline < 224 + 16 * Integer(C.FVDP.State.V30Enabled)) then
  begin
    var X := (C.FVDP.State.MasterTime - C.FFrameTime - Int64(C.FScanline) * 3420 - 860) div
      (10 - 2 * Integer(C.FVDP.State.H40Enabled));
    if (X >= 0) and (X < C.FWidth) then
    begin
      for var Pixel := Integer(X) to Min(Integer(X) + 1, C.FWidth - 1) do
        for var Field := 0 to Integer(C.FVDP.State.DoubleResolutionEnabled) do
          C.FFrame[(C.FScanline * (1 + Integer(C.FVDP.State.DoubleResolutionEnabled)) + Field) * 320 + Pixel] := C.FPalette[Index];
      C.FRasterX := Max(C.FRasterX, Min(Integer(X) + 2, C.FWidth));
    end;
  end;
end;

procedure ScanlineRendered(User: Pointer; Line: Cardinal; const Pixels: array of Byte; PixelOffset: Integer; Left, Right, Width, Height: Cardinal);
begin
  var C: TMDConsole := TMDConsole(User);
  if (Width > 320) or (Height > 480) or (Line >= Height) or (Left > Right) or (Right > Width) then
    raise Exception.CreateFmt('Invalid Mega Drive video dimensions: %dx%d line=%d span=%d..%d', [Width, Height, Line, Left, Right]);

  C.FWidth := Width;
  C.FHeight := Height;
  // Window and scrolling planes can publish separate spans of the same line.
  // Pixels outside this span still contain intermediate priority metadata.
  // Fixed stride inside the core; the frontend receives tightly packed pixels.
  for var X := Integer(Left) to Integer(Right) - 1 do
    C.FRasterPixels[(Integer(Line) and Integer(C.FVDP.State.DoubleResolutionEnabled)) * 320 + X] := Pixels[PixelOffset + X];
end;

procedure TMDConsole.RenderRasterTo(Time: Int64);
begin
  if (FScanline < 0) or (FScanline >= 224 + 16 * Integer(FVDP.State.V30Enabled)) then
    Exit;

  var Width := 256 + 64 * Integer(FVDP.State.H40Enabled);
  var ClockPerPixel := 10 - 2 * Integer(FVDP.State.H40Enabled);
  var XEnd := EnsureRange((Time - (FFrameTime + Int64(FScanline) * 3420) - 860) div ClockPerPixel, Int64(0), Int64(Width));
  if XEnd <= FRasterX then
    Exit;

  if not FRasterReady then
  begin
    if FVDP.State.DoubleResolutionEnabled <> 0 then
    begin
      VDPEndScanline(FVDP, FScanline * 2, ScanlineRendered, Self);
      VDPEndScanline(FVDP, FScanline * 2 + 1, ScanlineRendered, Self);
    end
    else
      VDPEndScanline(FVDP, FScanline, ScanlineRendered, Self);
    FRasterReady := True;
  end;
  for var Field := 0 to Integer(FVDP.State.DoubleResolutionEnabled) do
    for var X := FRasterX to Integer(XEnd) - 1 do
    begin
      var Index := FRasterPixels[Field * 320 + X];
      if FVDP.State.DisplayEnabled = 0 then
        Index := FVDP.State.BackgroundColour;
      FFrame[(FScanline * (1 + Integer(FVDP.State.DoubleResolutionEnabled)) + Field) * 320 + X] := FPalette[Index];
    end;
  FRasterX := XEnd;
end;

procedure TMDConsole.SyncVDP(Time: Int64);
begin
  VDPAdvance(FVDP, Time, ColourUpdated, DMARead, Self);
end;

function DMARead(User: Pointer; Address, Cycle: Cardinal): Cardinal;
begin
  // The VDP cannot recursively access its own 68k ports as a DMA source.
  if (Address and $E700E0) = $C00000 then
    Exit($FFFF);

  var C := TMDConsole(User);
  if C.FCD <> nil then
  begin
    C.FCD.Advance(C.FBusTime);
    var Data: Word;
    if C.FCD.ReadVDPDMA(Address, Data) then
      Exit(Data);
  end;
  Result := C.ReadWord(Address);
end;

procedure KDebug(User: Pointer; const Text: array of Byte);
begin
  // The frontend does not expose the cartridge debug output.
end;

constructor TMDConsole.Create(const Data: TBytes; const Extension: string; Disc: TCDDisc);
begin
  var StartAddress, EndAddress: Cardinal;
  inherited Create;
  FCDVolume := 100;
  F32XVolume := 100;
  FCDAudioEnabled := True;
  F32XAudioEnabled := True;
  FCartridge := TMDCartridge.Create(Data, Extension);
  FMapper := TMDMapper.Create(FCartridge);
  if FCartridge.EEPROMConfig.Mode <> TMDEEPROMMode.None then
    FEEPROM := TMDEEPROM.Create(FCartridge.EEPROMConfig);
  FCPUCallbacks.UserData := Self;
  FCPUCallbacks.ReadCallback := CPURead;
  FCPUCallbacks.WriteCallback := CPUWrite;
  FCPUCallbacks.InterruptAcknowledgeCallback := CPUAck;
  FZ80Callbacks.UserData := Self;
  FZ80Callbacks.ReadCallback := ZRead;
  FZ80Callbacks.WriteCallback := ZWrite;
  FMasterClock := 53693175;
  FLines := 262;
  if FCartridge.Region = TMDRegion.Europe then
  begin
    FMasterClock := 53203424;
    FLines := 313;
  end;
  if FCartridge.Is32X or TMDMegaCD.Requires32X(Disc) then
  begin
    var CartROM := FCartridge.Data;
    if Disc <> nil then
      CartROM := nil;
    F32X := TMD32X.Create(CartROM, LoadMDFirmware('32x_g'),
      LoadMDFirmware('32x_m'), LoadMDFirmware('32x_s'), FLines = 313);
  end;
  if Disc <> nil then
    FCD := TMDMegaCD.Create(Data, Disc, FMasterClock);
  SetLength(FFrame, 320 * 480);
  SetLength(FAudio, 2048 * 2);
  if (FEEPROM = nil) and not FMapper.HasBattery and (FCartridge.ReadWord($1B0) = $5241) then
  begin
    StartAddress := (Cardinal(FCartridge.ReadWord($1B4)) shl 16) or FCartridge.ReadWord($1B6);
    EndAddress := (Cardinal(FCartridge.ReadWord($1B8)) shl 16) or FCartridge.ReadWord($1BA);
    if (StartAddress <= EndAddress) and (EndAddress < $400000) and (EndAddress - StartAddress < $20000) then
    begin
      FSRAMStart := StartAddress;
      FSRAMEnd := EndAddress;
      if (StartAddress and 1) = (EndAddress and 1) then
        FSRAMStride := 2
      else
        FSRAMStride := 1;
      SetLength(FSRAM, (EndAddress - StartAddress) div FSRAMStride + 1);
    end;
  end;
  Reset;
end;

destructor TMDConsole.Destroy;
begin
  FCD.Free;
  F32X.Free;
  FEEPROM.Free;
  FMapper.Free;
  FCartridge.Free;
  inherited;
end;

procedure TMDConsole.Reset;
begin
  FMapper.Reset;
  if FCD <> nil then
    FCD.Reset;
  if F32X <> nil then
    F32X.Reset;
  if FEEPROM <> nil then
    FEEPROM.Reset;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FZRAM, SizeOf(FZRAM), 0);
  FillChar(FIO, SizeOf(FIO), 0);
  FCPU := Default(TM68kState);
  FZ80 := Default(TZ80State);
  FVDP := Default(TVDP);
  FFM := Default(TFM);
  FPSG := Default(TPSG);
  VDPInitialise(FVDP);
  FVDP.Configuration.TimedAccess := 1;
  FVDP.Configuration.PAL := Ord(FLines = 313);
  FMInitialise(FFM);
  PSGInitialise(FPSG);
  Z80StateInitialise(FZ80);
  for var i := 0 to High(FPalette) do
    FPalette[i] := $FF000000;
  for var i := 0 to High(FFrame) do
    FFrame[i] := $FF000000;
  FWidth := 256;
  FHeight := 224;
  FFrameTime := 0;
  FCPUTime := 0;
  FCPUBase := 0;
  FBusTime := 0;
  FZ80Time := 0;
  FAudioTime := 0;
  FNextFM := 1008;
  FNextPSG := 240;
  FPCMNumber := 1;
  FNextPCM := FMasterClock div 44100;
  FLastPCM := 0;
  FAreaLeft := 0;
  FAreaRight := 0;
  FFMSamples[0] := 0;
  FFMSamples[1] := 0;
  FPSGSamples[0] := 0;
  FAudioCount := 0;
  for var Channel := 0 to 1 do
  begin
    FFMFilter[Channel].Configure(FMasterClock / 1008.0, 12000);
    FFMFilter[Channel].Reset;
    FOutputDC[Channel].Configure(44100, 20);
    FOutputDC[Channel].Reset;
    FFilteredFM[Channel] := 0;
  end;
  FPSGFilter.Configure(FMasterClock / 240.0, 12000);
  FPSGFilter.Reset;
  FFilteredPSG := 0;
  FFrameNumber := 0;
  FScanline := 0;
  FCPULastAccess := -28;
  FRasterX := 0;
  FRasterReady := False;
  FillChar(FRasterPixels, SizeOf(FRasterPixels), 0);
  FBusyUntil := 0;
  FillChar(FPadTimeout, SizeOf(FPadTimeout), 0);
  FZReset := True;
  FBusRequested := False;
  FInZ80 := False;
  FVInt := False;
  FHInt := False;
  FZBank := 0;
  for var Port := 1 to 4 do
    FTH[Port] := True;
  FillChar(FStrobes, SizeOf(FStrobes), 0);
  FIO[1] := $7F;
  FIO[2] := $7F;
  FSRAMEnabled := (Length(FSRAM) <> 0) and (Length(FCartridge.Data) <= Integer(FSRAMStart));
  FSRAMReadOnly := False;
  Clown68000Reset(FCPU, FCPUCallbacks);
end;

procedure TMDConsole.UpdateIRQ;
begin
  if FVInt and (FVDP.State.VIntEnabled <> 0) then
    FCPU.PendingInterrupt := 6
  else if FHInt and (FVDP.State.HIntEnabled <> 0) then
    FCPU.PendingInterrupt := 4
  else
    FCPU.PendingInterrupt := 0;
end;

procedure TMDConsole.SetInput(const Buttons: TMDButtons; const Buttons2, Buttons3, Buttons4: TMDButtons);
begin
  FButtons[1] := Buttons;
  FButtons[2] := Buttons2;
  FButtons[3] := Buttons3;
  FButtons[4] := Buttons4;
end;

procedure TMDConsole.ConfigureInputPorts(const Ports: TCoreInputPorts);
begin
  for var Port := 1 to 4 do
    if FPadDevices[Port] <> Ports.Devices[Port - 1] then
    begin
      FStrobes[Port] := 0;
      FPadTimeout[Port] := 0;
    end;
  FPadDevices[1] := Ports.Devices[0];
  FPadDevices[2] := Ports.Devices[1];
  FPadDevices[3] := Ports.Devices[2];
  FPadDevices[4] := Ports.Devices[3];
end;

function TMDConsole.ReadPad(Port: Integer): Byte;

  function Released(Button: TMDButton; Bit: Integer): Byte;
  begin
    if Button in FButtons[Port] then
      Result := 0
    else
      Result := 1 shl Bit;
  end;

begin
  if FPadDevices[Port] = 'none' then
  begin
    if Port <= 2 then
      Exit(($7F and not FIO[Port + 3]) or (FIO[Port] and FIO[Port + 3]));
    Exit($3F or (Ord(FTH[Port]) shl 6));
  end;

  if (FPadDevices[Port] = 'pad3') or (FBusTime >= FPadTimeout[Port]) then
    FStrobes[Port] := 0;
  if FTH[Port] then
  begin
    Result := $40 or Released(TMDButton.B, 4) or Released(TMDButton.C, 5);
    if FStrobes[Port] = 3 then
      Result := Result or Released(TMDButton.Z, 0) or Released(TMDButton.Y, 1) or
        Released(TMDButton.X, 2) or Released(TMDButton.Mode, 3)
    else
      Result := Result or Released(TMDButton.Up, 0) or Released(TMDButton.Down, 1) or
        Released(TMDButton.Left, 2) or Released(TMDButton.Right, 3);
  end
  else
  begin
    Result := Released(TMDButton.A, 4) or Released(TMDButton.Start, 5);
    if FStrobes[Port] = 3 then
      Result := Result or $F
    else if FStrobes[Port] <> 2 then
      Result := Result or Released(TMDButton.Up, 0) or Released(TMDButton.Down, 1);
  end;
  if Port <= 2 then
    Result := (Result and not FIO[Port + 3]) or (FIO[Port] and FIO[Port + 3]);
end;

procedure TMDConsole.SetPadTH(Port: Integer; Value: Boolean);
begin
  if FBusTime >= FPadTimeout[Port] then
    FStrobes[Port] := 0;
  if Value and not FTH[Port] then
  begin
    FStrobes[Port] := (FStrobes[Port] + 1) and 3;
    FPadTimeout[Port] := FBusTime + FMasterClock * 3 div 2000;
  end;
  FTH[Port] := Value;
end;

procedure TMDConsole.WriteIO(Index: Integer; Value: Byte);
begin
  var NewTH: Boolean;
  FIO[Index] := Value;
  if Index in [1, 2, 4, 5] then
  begin
    var Port := Index;
    if Port > 3 then
      Dec(Port, 3);
    NewTH := (FIO[Port + 3] and $40 = 0) or (FIO[Port] and $40 <> 0);
    SetPadTH(Port, NewTH);
  end;
end;

function TMDConsole.SRAMIndex(Address: Cardinal; out Index: Cardinal): Boolean;
begin
  Result := FSRAMEnabled and (Length(FSRAM) <> 0) and (Address >= FSRAMStart) and (Address <= FSRAMEnd);
  if Result then
  begin
    Result := ((Address - FSRAMStart) mod FSRAMStride) = 0;
    Index := (Address - FSRAMStart) div FSRAMStride;
  end;
end;

function TMDConsole.ReadBus(Address: Cardinal; HighByte, LowByte: Boolean): Word;
begin
  var Index: Cardinal;
  var V: Byte;
  Address := Address and $FFFFFE;
  if FCD <> nil then
  begin
    FCD.Advance(FBusTime);
    if FCD.MainRead(Address, Result) then
      Exit;
  end;
  if F32X <> nil then
  begin
    F32X.Advance(FBusTime);
    if F32X.MainRead(Address, Result) then
      Exit;
  end;
  if FCartridge.JCart and (Address = $38FFFE) then
    // J-Cart D6 echoes TH; D14 is wired low, not the second pad's TH.
    Exit(ReadPad(3) or (Word(ReadPad(4) and $3F) shl 8));
  if Address < $400000 then
  begin
    FMapper.Read(Address, Result);
    if FEEPROM <> nil then
      Result := FEEPROM.ReadBus(Address, Result);
    // Most instruction fetches have no SRAM overlay. Avoid two mapping
    // calls in that case; retain the independent byte-lane checks when enabled.
    if FSRAMEnabled then
    begin
      if SRAMIndex(Address, Index) then
        Result := (Result and $FF) or (Word(FSRAM[Index]) shl 8);
      if SRAMIndex(Address + 1, Index) then
        Result := (Result and $FF00) or FSRAM[Index];
    end;
  end
  else if FMapper.Read(Address, Result) then
  begin
  end
  else if Address >= $E00000 then
    Result := (Word(FRAM[Address and $FFFF]) shl 8) or FRAM[(Address + 1) and $FFFF]
  else if (Address >= $A00000) and (Address <= $A0FFFF) then
  begin
    SyncZ80(FBusTime);
    Result := $FFFF;
    if FBusRequested and not FZReset then
    begin
      // The 68000's word access uses one Z80 bus cycle, repeating the byte.
      if HighByte then
        V := ReadZ80(Word(Address and $7FFF))
      else
        V := ReadZ80(Word((Address + 1) and $7FFF));
      Result := Word(V) * $101;
    end;
  end
  else if (Address >= $A10000) and (Address <= $A1001E) then
  begin
    Index := (Address and $1F) shr 1;
    case Index of
      0:
        begin
          V := $A0;
          if FCartridge.Region = TMDRegion.Japan then
            V := $20;
          if FCartridge.Region = TMDRegion.Europe then
            V := $E0;
          if FCD <> nil then
            V := V and $DF;
        end;
      1, 2:
        V := ReadPad(Index);
      3:
        V := $7F;
    else
      V := FIO[Index];
    end;
    Result := Word(V) * $101;
  end
  else if Address = $A11100 then
    Result := Word(Ord(not FBusRequested or FZReset)) shl 8
  else if (Address and $E700E0) = $C00000 then
  begin
    SyncVDP(FBusTime);
    while (FVDP.State.DMAActive <> 0) and (FVDP.State.Dma.Mode = VDP_DMA_MODE_MEMORY_TO_VRAM) do
    begin
      FBusTime := VDPNextAccessSlot(FVDP, FVDP.State.MasterTime);
      SyncVDP(FBusTime);
    end;
    case Address and $1E of
      0, 2:
        begin
          while FVDP.State.FIFOCount > 0 do
          begin
            FBusTime := VDPNextAccessSlot(FVDP, FVDP.State.MasterTime);
            SyncVDP(FBusTime);
          end;
          Result := VDPReadData(FVDP);
        end;
      4, 6:
        begin
          Result := VDPReadControl(FVDP);
          var PC := FCPU.ProgramCounter and $FFFFFF;
          if (PC < $400000) or (PC >= $E00000) then
            Result := Result or (ReadWord(PC) and $FC00);
          if FLines = 313 then
            Result := Result or 1;
          if ((FBusTime mod 3420) >= 280) and ((FBusTime mod 3420) < 860) then
            Result := Result or 4;
        end;
      8, 10, 12, 14:
        begin
          Result := VDPReadHV(FVDP);
        end;
    else
      Result := $FFFF;
    end;
  end
  else
    Result := $FFFF;
end;

procedure TMDConsole.WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  var Index: Cardinal;
  var V: Byte;
  Address := Address and $FFFFFE;
  if FCD <> nil then
  begin
    FCD.Advance(FBusTime);

    if FCD.MainWrite(Address, Value, HighByte, LowByte) then
      Exit;
  end;
  if F32X <> nil then
  begin
    F32X.Advance(FBusTime);
    if F32X.MainWrite(Address, Value, HighByte, LowByte) then
      Exit;
  end;
  if FCartridge.JCart and (Address = $38FFFE) then
  begin
    if LowByte then
    begin
      SetPadTH(3, Value and 1 <> 0);
      SetPadTH(4, Value and 1 <> 0);
    end;
    Exit;
  end;
  if FMapper.Write(Address, Value, HighByte, LowByte) then
    Exit;
  if Address < $400000 then
  begin
    if (FEEPROM <> nil) and FEEPROM.WriteBus(Address, Value, HighByte, LowByte) then
      Exit;
    if not FSRAMReadOnly then
    begin
      if HighByte and SRAMIndex(Address, Index) then
      begin
        FSRAM[Index] := Value shr 8;
        FSRAMDirty := True;
      end;
      if LowByte and SRAMIndex(Address + 1, Index) then
      begin
        FSRAM[Index] := Value and $FF;
        FSRAMDirty := True;
      end;
    end;
  end
  else if Address >= $E00000 then
  begin
    if HighByte then
      FRAM[Address and $FFFF] := Value shr 8;
    if LowByte then
      FRAM[(Address + 1) and $FFFF] := Value and $FF;
  end
  else if (Address >= $A00000) and (Address <= $A0FFFF) then
  begin
    SyncZ80(FBusTime);
    if FBusRequested and not FZReset then
    begin
      if HighByte then
        WriteZ80(Word(Address and $7FFF), Value shr 8)
      else if LowByte then
        WriteZ80(Word((Address + 1) and $7FFF), Value and $FF);
    end;
  end
  else if (Address >= $A10000) and (Address <= $A1001E) then
  begin
    if LowByte then
      WriteIO((Address and $1F) shr 1, Value and $FF);
  end
  else if Address = $A11100 then
  begin
    SyncZ80(FBusTime);
    if HighByte then
      FBusRequested := Value and $100 <> 0;
  end
  else if Address = $A11200 then
  begin
    SyncZ80(FBusTime);
    if HighByte then
    begin
      if FZReset and (Value and $100 <> 0) then
        Z80Reset(FZ80);
      FZReset := Value and $100 = 0;
      if FZReset then
      begin
        SyncAudio(FBusTime);
        FMInitialise(FFM);
      end;
    end;
  end
  else if Address = $A130F0 then
  begin
    if LowByte then
    begin
      FSRAMEnabled := Value and 1 <> 0;
      FSRAMReadOnly := Value and 2 <> 0;
    end;
  end
  else if (Address and $E700E0) = $C00000 then
  begin
    SyncVDP(FBusTime);
    while (FVDP.State.DMAActive <> 0) and (FVDP.State.Dma.Mode = VDP_DMA_MODE_MEMORY_TO_VRAM) do
    begin
      FBusTime := VDPNextAccessSlot(FVDP, FVDP.State.MasterTime);
      SyncVDP(FBusTime);
    end;
    if not (HighByte and LowByte) then
    begin
      if HighByte then
        V := Value shr 8
      else
        V := Value and $FF;
      Value := Word(V) * $101;
    end;
    case Address and $1E of
      0, 2:
        begin
          while FVDP.State.FIFOCount >= 4 do
          begin
            FBusTime := VDPNextAccessSlot(FVDP, FVDP.State.MasterTime);
            SyncVDP(FBusTime);
          end;
          VDPWriteData(FVDP, Value, ColourUpdated, Self);
        end;
      4, 6:
        begin
          RenderRasterTo(FBusTime);
          VDPWriteControl(FVDP, Value, ColourUpdated, Self, nil, DMARead, Self, KDebug, Self, 0);
          UpdateIRQ;
        end;
      16, 18, 20, 22:
        if LowByte then
        begin
          SyncAudio(FBusTime);
          PSGDoCommand(FPSG, Value and $FF);
        end;
      28:
        VDPWriteDebugData(FVDP, Value);
      30:
        VDPWriteDebugControl(FVDP, Value);
    end;
  end;
end;

function TMDConsole.ReadByte(Address: Cardinal): Byte;
begin
  var V: Word := ReadBus(Address and $FFFFFE, not Odd(Address), Odd(Address));
  if Odd(Address) then
    Result := V and $FF
  else
    Result := V shr 8;
end;

function TMDConsole.ReadWord(Address: Cardinal): Word;
begin
  Result := ReadBus(Address, True, True);
end;

procedure TMDConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  if Odd(Address) then
    WriteBus(Address and $FFFFFE, Value, False, True)
  else
    WriteBus(Address, Word(Value) shl 8, True, False);
end;

procedure TMDConsole.WriteWord(Address: Cardinal; Value: Word);
begin
  WriteBus(Address, Value, True, True);
end;

function TMDConsole.ReadZ80(Address: Word): Byte;
begin
  if Address < $4000 then
    Result := FZRAM[Address and $1FFF]
  else if Address < $6000 then
  begin
    SyncAudio(FBusTime);
    Result := FFM.State.Status and $7F;
    if FBusTime < FBusyUntil then
      Result := Result or $80;
  end
  else if Address >= $8000 then
  begin
    if (FZBank and $1FE) = $140 then
      Result := $FF // Exclude the entire A00000-A0FFFF window.
    else
      Result := ReadByte(Cardinal(FZBank) * $8000 + (Address and $7FFF));
  end
  else if Address >= $7F00 then
    Result := ReadByte($C00000 + (Address and $1F))
  else
    Result := $FF;
end;

procedure TMDConsole.WriteZ80(Address: Word; Value: Byte);
begin
  if Address < $4000 then
    FZRAM[Address and $1FFF] := Value
  else if Address < $6000 then
  begin
    SyncAudio(FBusTime);
    if not Odd(Address) then
      FMDoAddress(FFM, (Address shr 1) and 1, Value)
    else
    begin
      FMDoData(FFM, Value);
      FBusyUntil := FBusTime + 32 * 7;
    end;
  end
  else if Address < $6100 then
    FZBank := (FZBank shr 1) or (Word(Value and 1) shl 8)
  else if Address >= $8000 then
  begin
    if (FZBank and $1FE) <> $140 then
      WriteByte(Cardinal(FZBank) * $8000 + (Address and $7FFF), Value);
  end
  else if Address >= $7F00 then
    WriteByte($C00000 + (Address and $1F), Value);
end;

procedure TMDConsole.SyncZ80(Target: Int64);
begin
  var Cycles: Cardinal;
  if FInZ80 or (Target <= FZ80Time) then
    Exit;

  if FBusRequested or FZReset then
  begin
    FZ80Time := Target;
    Exit;
  end;

  FInZ80 := True;
  var SavedBus: Int64 := FBusTime;
  try
    while FZ80Time < Target do
    begin
      FBusTime := FZ80Time;
      Cycles := Z80DoInstruction(FZ80, FZ80Callbacks);
      Inc(FZ80Time, Max(1, Integer(Cycles)) * 15);
      if FBusRequested or FZReset then
      begin
        FZ80Time := Target;
        Break;
      end;
    end;
  finally
    FBusTime := SavedBus;
    FInZ80 := False;
  end;
end;

procedure TMDConsole.SyncAudio(Target: Int64);
begin
  var Next, Delta, Span: Int64;
  var PWMLeft, PWMRight: Integer;
  var CDLeft, CDRight: Integer;
  while FAudioTime < Target do
  begin
    Next := Min(Target, Min(FNextPCM, Min(FNextFM, FNextPSG)));
    PWMLeft := 0;
    PWMRight := 0;
    if F32X <> nil then
    begin
      F32X.Advance(Next);
      F32X.Sample(PWMLeft, PWMRight);
    end;
    CDLeft := 0;
    CDRight := 0;
    if FCD <> nil then
    begin
      FCD.Advance(Next);
      FCD.Sample(CDLeft, CDRight);
    end;
    // Keep advancing expansion hardware even when its audio is muted.
    if not FCDAudioEnabled then
    begin
      CDLeft := 0;
      CDRight := 0;
    end;
    if not F32XAudioEnabled then
    begin
      PWMLeft := 0;
      PWMRight := 0;
    end;
    CDLeft := CDLeft * FCDVolume div 100;
    CDRight := CDRight * FCDVolume div 100;
    PWMLeft := PWMLeft * F32XVolume div 100;
    PWMRight := PWMRight * F32XVolume div 100;
    Delta := Next - FAudioTime;
    FAreaLeft := FAreaLeft + (FFilteredFM[0] + FFilteredPSG + PWMLeft + CDLeft) * Delta;
    FAreaRight := FAreaRight + (FFilteredFM[1] + FFilteredPSG + PWMRight + CDRight) * Delta;
    FAudioTime := Next;
    if Next = FNextFM then
    begin
      FFMSamples[0] := 0;
      FFMSamples[1] := 0;
      FMOutputSamples(FFM, FFMSamples);
      for var Channel := 0 to 1 do
        FFilteredFM[Channel] := FFMFilter[Channel].Process(FFMSamples[Channel]);
      Inc(FNextFM, 1008);
    end;
    if Next = FNextPSG then
    begin
      FPSGSamples[0] := 0;
      PSGUpdate(FPSG, FPSGSamples);

      // The ported FM core already divides its channels by 8; PSG does not.
      // Match ClownMDEmu's CLOWNMDEMU_PSG_VOLUME_DIVISOR at the mixing boundary.
      FFilteredPSG := FPSGFilter.Process(FPSGSamples[0] / 8.0);
      Inc(FNextPSG, 240);
    end;
    if Next = FNextPCM then
    begin
      Span := Next - FLastPCM;
      if FAudioCount < Length(FAudio) div 2 then
      begin
        // Chip normalization already reserves mixing headroom.
        FAudio[FAudioCount * 2] := EnsureRange(Round(FOutputDC[0].Process(FAreaLeft / Span)), Int64(-32768), Int64(32767));
        FAudio[FAudioCount * 2 + 1] := EnsureRange(Round(FOutputDC[1].Process(FAreaRight / Span)), Int64(-32768), Int64(32767));
        Inc(FAudioCount);
      end;
      FAreaLeft := 0;
      FAreaRight := 0;
      FLastPCM := Next;
      Inc(FPCMNumber);
      FNextPCM := FPCMNumber * FMasterClock div 44100;
    end;
  end;
end;

procedure TMDConsole.RunUntil(Target: Int64);
begin
  while FCPUTime < Target do
  begin
    if (FVDP.State.DMAActive <> 0) and (FVDP.State.Dma.Mode = VDP_DMA_MODE_MEMORY_TO_VRAM) then
    begin
      var Next := Min(Target, VDPNextAccessSlot(FVDP, FVDP.State.MasterTime));
      SyncVDP(Next);
      FCPUTime := Max(FCPUTime, Next);
      Continue;
    end;

    FCPUBase := FCPUTime;
    var Cycles := Clown68000DoCycles(FCPU, FCPUCallbacks, (Target - FCPUTime + 6) div 7);
    FCPUTime := Max(FCPUBase + Cycles * 7, FCPULastAccess + 28);
  end;
  SyncVDP(Target);
  SyncZ80(Target);
  SyncAudio(Target);
  if F32X <> nil then
    F32X.Advance(Target);
  if FCD <> nil then
    FCD.Advance(Target);
end;

procedure TMDConsole.RunFrame;
begin
  var Visible, HCounter: Integer;
  var Target: Int64;
  FAudioCount := 0;
  Visible := 224;
  if FVDP.State.V30Enabled <> 0 then
    Visible := 240;
  HCounter := FVDP.State.HIntInterval;
  for var Line := 0 to FLines - 1 do
  begin
    FScanline := Line;
    FRasterX := 0;
    FRasterReady := False;
    if Line = 0 then
      FVDP.State.CurrentlyInVblank := 0;
    if Line = Visible then
    begin
      FVDP.State.CurrentlyInVblank := 1;
      FVInt := True;
      UpdateIRQ;

      Z80Interrupt(FZ80, 1);
    end;
    if Line = Visible + 1 then
      Z80Interrupt(FZ80, 0);
    if Line < Visible then
    begin
      VDPBeginScanline(FVDP);
      Target := FFrameTime + Int64(Line) * 3420 + 1710;
      RunUntil(Target);
      if HCounter = 0 then
      begin
        FHInt := True;
        UpdateIRQ;
        HCounter := FVDP.State.HIntInterval;
      end
      else
        Dec(HCounter);
    end;
    RunUntil(FFrameTime + Int64(Line + 1) * 3420);
    RenderRasterTo(FFrameTime + Int64(Line + 1) * 3420);
    if (F32X <> nil) and (Line < Visible) then
      F32X.RenderLine(Line, FFrame, Line * 320, FWidth, FRasterPixels, FVDP.State.BackgroundColour);
  end;
  Inc(FFrameTime, Int64(FLines) * 3420);
  Inc(FFrameNumber);
end;

function TMDConsole.FramesPerSecond: Double;
begin
  Result := FMasterClock / (FLines * 3420);
end;

procedure TMDConsole.LoadBattery(const Data: TBytes);
begin
  if FCD <> nil then
  begin
    FCD.LoadBattery(Data);
    Exit;
  end;
  if FMapper.HasBattery then
  begin
    FMapper.LoadBattery(Data);
    Exit;
  end;
  if FEEPROM <> nil then
  begin
    FEEPROM.LoadBattery(Data);
    Exit;
  end;
  if Length(Data) <> Length(FSRAM) then
    raise EMDCartridge.Create('Mega Drive SRAM file has an invalid size');

  FSRAM := Copy(Data);
  FSRAMDirty := False;
end;

function TMDConsole.BatteryData: TBytes;
begin
  if FCD <> nil then
    Exit(FCD.BatteryData);
  if FMapper.HasBattery then
    Exit(FMapper.BatteryData);
  if FEEPROM <> nil then
    Result := FEEPROM.BatteryData
  else
    Result := Copy(FSRAM);
end;

function TMDConsole.GetBatteryDirty: Boolean;
begin
  if FCD <> nil then
    Exit(FCD.Dirty);
  if FMapper.HasBattery then
    Exit(FMapper.Dirty);
  Result := FSRAMDirty;
  if FEEPROM <> nil then
    Result := FEEPROM.Dirty;
end;

procedure TMDConsole.SerializeState(State: TStateArchive);
begin
  var Expansions: Byte := Ord(FCD <> nil) or (Ord(F32X <> nil) shl 1);
  var Expected := Expansions;
  State.Field(Expansions, SizeOf(Expansions));
  if Expansions <> Expected then
    raise EReadError.Create('Snapshot expansion hardware mismatch');
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FZ80, SizeOf(FZ80));
  State.Field(FVDP, SizeOf(FVDP));
  State.Field(FFM, SizeOf(FFM));
  State.Field(FPSG, SizeOf(FPSG));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FZRAM, SizeOf(FZRAM));
  State.Field(FIO, SizeOf(FIO));
  State.Field(FPalette, SizeOf(FPalette));
  if Length(FFrame) > 0 then
    State.Field(FFrame[0], Length(FFrame) * SizeOf(FFrame[0]));
  if Length(FAudio) > 0 then
    State.Field(FAudio[0], Length(FAudio) * SizeOf(FAudio[0]));
  State.Field(FAudioCount, SizeOf(FAudioCount));
  State.Field(FWidth, SizeOf(FWidth));
  State.Field(FHeight, SizeOf(FHeight));
  State.Field(FScanline, SizeOf(FScanline));
  State.Field(FMasterClock, SizeOf(FMasterClock));
  State.Field(FLines, SizeOf(FLines));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FFrameTime, SizeOf(FFrameTime));
  State.Field(FCPUTime, SizeOf(FCPUTime));
  State.Field(FCPUBase, SizeOf(FCPUBase));
  State.Field(FZ80Time, SizeOf(FZ80Time));
  State.Field(FBusTime, SizeOf(FBusTime));
  State.Field(FAudioTime, SizeOf(FAudioTime));
  State.Field(FNextFM, SizeOf(FNextFM));
  State.Field(FNextPSG, SizeOf(FNextPSG));
  State.Field(FNextPCM, SizeOf(FNextPCM));
  State.Field(FPCMNumber, SizeOf(FPCMNumber));
  State.Field(FLastPCM, SizeOf(FLastPCM));
  State.Field(FAreaLeft, SizeOf(FAreaLeft));
  State.Field(FAreaRight, SizeOf(FAreaRight));
  State.Field(FFMFilter, SizeOf(FFMFilter));
  State.Field(FPSGFilter, SizeOf(FPSGFilter));
  State.Field(FOutputDC, SizeOf(FOutputDC));
  State.Field(FFilteredFM, SizeOf(FFilteredFM));
  State.Field(FFilteredPSG, SizeOf(FFilteredPSG));
  State.Field(FFMSamples, SizeOf(FFMSamples));
  State.Field(FPSGSamples, SizeOf(FPSGSamples));
  State.Field(FBusyUntil, SizeOf(FBusyUntil));
  State.Field(FPadTimeout, SizeOf(FPadTimeout));
  State.Field(FBusRequested, SizeOf(FBusRequested));
  State.Field(FZReset, SizeOf(FZReset));
  State.Field(FInZ80, SizeOf(FInZ80));
  State.Field(FVInt, SizeOf(FVInt));
  State.Field(FHInt, SizeOf(FHInt));
  State.Field(FZBank, SizeOf(FZBank));
  State.Field(FButtons, SizeOf(FButtons));
  State.Field(FStrobes, SizeOf(FStrobes));
  State.Field(FTH, SizeOf(FTH));
  if Length(FSRAM) > 0 then
    State.Field(FSRAM[0], Length(FSRAM) * SizeOf(FSRAM[0]));
  State.Field(FSRAMStart, SizeOf(FSRAMStart));
  State.Field(FSRAMEnd, SizeOf(FSRAMEnd));
  State.Field(FSRAMStride, SizeOf(FSRAMStride));
  State.Field(FSRAMEnabled, SizeOf(FSRAMEnabled));
  State.Field(FSRAMReadOnly, SizeOf(FSRAMReadOnly));
  FMapper.SerializeState(State);
  State.Field(FCPULastAccess, SizeOf(FCPULastAccess));
  State.Field(FRasterX, SizeOf(FRasterX));
  State.Field(FRasterReady, SizeOf(FRasterReady));
  State.Field(FRasterPixels, SizeOf(FRasterPixels));
  if FEEPROM <> nil then
    FEEPROM.SerializeState(State);
  if F32X <> nil then
    F32X.SerializeState(State);
  if FCD <> nil then
    FCD.SerializeState(State);

  if (FWidth < 1) or (FWidth > 320) or (FHeight < 1) or (FHeight > 480) or
    (FAudioCount < 0) or (FAudioCount > Length(FAudio) div 2) then
    raise EReadError.Create('Invalid snapshot display or audio dimensions');

  if (FVDP.State.FIFOCount < 0) or (FVDP.State.FIFOCount > 4) or
    (FVDP.State.FIFOSlotsLeft < 0) or (FVDP.State.FIFOSlotsLeft > 2) or
    (FVDP.State.DMASlotsLeft < 0) or (FVDP.State.DMASlotsLeft > 2) or
    (FVDP.State.DMARemaining > $10000) or (FVDP.State.MasterTime < 0) or
    (FVDP.State.DMAActive > 1) or (FVDP.State.DMAWaitingFill > 1) or
    (FVDP.State.DMABusy > 1) or (FRasterX < 0) or (FRasterX > 320) then
    raise EReadError.Create('Invalid snapshot VDP timing state');
end;

procedure TMDConsole.MarkBatteryDirty;
begin
  if FCD <> nil then
    FCD.Dirty := True;
  if FMapper.HasBattery then
    FMapper.Dirty := True;
  FSRAMDirty := Length(FSRAM) > 0;
  if FEEPROM <> nil then
    FEEPROM.Dirty := True;
end;

initialization
  MD.VDP.ConstantInitialise;
  MD.Z80.ConstantInitialise;

end.

