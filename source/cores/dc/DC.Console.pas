unit DC.Console;

// The Dreamcast machine: owns the SH-4 and every device, decodes the
// physical address map for device accesses and runs one video field per
// RunFrame. Emulated time only advances through the scheduler.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, HW.SH4, HW.SH4.Periph,
  DC.Types, DC.Memory, DC.Scheduler, DC.Interrupts, DC.PVR, DC.PVR.TA,
  DC.PVR.Render, DC.GDROM, DC.GDROM.HLE, DC.AICA, DC.Maple, DC.Holly, DC.Boot,
  DC.Disc, DC.Flash, Core.CD.Disc;

type
  TDCConsoleConfig = record
    // Empty: high-level boot. Otherwise a 2 MiB boot ROM image.
    BootROM: TBytes;
    // High-level boot even with a boot ROM image, which then only provides
    // its contents (the ROM font) at their addresses.
    HLEBoot: Boolean;
    Flash: TBytes;
    Region: TDCRegion;
    Cable: TDCCable;
    PAL: Boolean;
    RTCSeconds: Cardinal; // seconds since 1950-01-01
    Language: TDCLanguage;
  end;

  TDCConsole = class
  private
    FConfig: TDCConsoleConfig;
    FFrameDone: Boolean;
    FHalted: Boolean;
    FSoftReset: Boolean;
    FFrameCount: Int64;
    FRenderFirst, FRenderLast: Cardinal;
    procedure DispatchEvent(Event: TDCEvent);
    procedure RequestSoftReset;
    procedure SoftReset;
    procedure SetRenderPages(Direct: Boolean);
    procedure JoinForMemory;
    procedure JoinForTA;
    procedure StartRender(Sender: Pointer);
    procedure Build;
  public
    Memory: TDCMemory;
    Scheduler: TDCScheduler;
    CPU: TSH4;
    Periph: TSH4Periph;
    Interrupts: TDCInterrupts;
    PVR: TDCPVR;
    TA: TDCTA;
    Renderer: TDCRenderer;
    GDROM: TDCGDROM;
    AICA: TDCAICA;
    Maple: TDCMaple;
    Holly: TDCHolly;
    Boot: TDCBoot;
    GDROMHLE: TDCGDROMHLE;
    Flash: TDCFlash;
    Disc: TDCDisc;
    // Optional diagnostics: device register accesses (not memory), limited
    // to IOTraceLimit lines.
    IOTrace: TStrings;
    IOTraceLimit: Integer;
    // Diagnostics: waits for renders from VRAM accesses and the TA.
    RenderJoins: array[0..1] of Int64;
    constructor Create(const Config: TDCConsoleConfig);
    destructor Destroy; override;
    procedure Reset;
    // Loads a homebrew program (ELF or raw binary) and enters it.
    procedure LoadProgram(const Data: TBytes);
    // Inserts a disc image (not owned) and, with the high-level boot ROM,
    // boots it through IP.BIN.
    procedure InsertDisc(Image: TCDDisc);
    procedure BootDisc;
    // Disc change while running: the lid opens (the drive reports status 6,
    // reads fail, the tray is empty), then closes on another image (not
    // owned; nil: no disc). ChangeDisc does both, keeping the lid open for
    // Seconds of machine time so that programs polling the drive see it.
    // Programs notice through the drive status and restart their disc access.
    procedure OpenLid;
    procedure CloseLid(Image: TCDDisc);
    procedure ChangeDisc(Image: TCDDisc; Seconds: Double);
    function LidOpen: Boolean;
    procedure RunFrame;
    // Waits for a render still running on worker threads.
    procedure JoinRender;
    function ReadBus(Address: Cardinal; Size: Integer): UInt64;
    procedure WriteBus(Address: Cardinal; Value: UInt64; Size: Integer);
    procedure SerializeState(Archive: TStateArchive);
    // True when the built-in boot code and system calls run (no boot ROM, or
    // HLEBoot).
    function HighLevelBoot: Boolean;
    property FrameCount: Int64 read FFrameCount;
    property Halted: Boolean read FHalted;
    property Config: TDCConsoleConfig read FConfig;
  end;

implementation

uses
  System.Math, DC.ELF, DC.Font;

procedure TraceIO(Console: TDCConsole; const Kind: string; Address: Cardinal; Value: UInt64; Size: Integer);
begin
  // Repeats of the last line (a polling loop) only count in its object.
  var Line := Format('%s%d %.8x=%x pc=%.8x', [Kind, Size, Address, Value, Console.CPU.S.PC]);
  var Trace := Console.IOTrace;
  if (Trace.Count > 0) and (Trace[Trace.Count - 1] = Line) then
    Trace.Objects[Trace.Count - 1] := TObject(NativeInt(Trace.Objects[Trace.Count - 1]) + 1)
  else if Trace.Count < Console.IOTraceLimit then
    Trace.Add(Line);
end;

function BusRead(User: Pointer; Address: Cardinal; Size: Integer): UInt64;
begin
  Result := TDCConsole(User).ReadBus(Address, Size);
  if TDCConsole(User).IOTrace <> nil then
    TraceIO(TDCConsole(User), 'R', Address, Result, Size);
end;

procedure BusWrite(User: Pointer; Address: Cardinal; Value: UInt64; Size: Integer);
begin
  if TDCConsole(User).IOTrace <> nil then
    TraceIO(TDCConsole(User), 'W', Address, Value, Size);
  TDCConsole(User).WriteBus(Address, Value, Size);
end;

procedure BusBurst(User: Pointer; Address: Cardinal; Data: PCardinal; Count: Integer);
begin
  var Console := TDCConsole(User);
  if (Address shr 26) = 4 then
    Console.Holly.WriteArea4(Address, Data, Count)
  else
    for var I := 0 to Count - 1 do
      Console.WriteBus(Address + Cardinal(I) * 4, Data[I], 4);
end;

function OnChipRead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TDCConsole(User).Periph.Read(Address, Size);
  if TDCConsole(User).IOTrace <> nil then
    TraceIO(TDCConsole(User), 'r', Address, Result, Size);
end;

procedure OnChipWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  if TDCConsole(User).IOTrace <> nil then
    TraceIO(TDCConsole(User), 'w', Address, Value, Size);
  TDCConsole(User).Periph.Write(Address, Value, Size);
end;

procedure PeriphSchedule(User: Pointer; At: Int64);
begin
  var Console := TDCConsole(User);
  if At = SH4Never then
    Console.Scheduler.Cancel(TDCEvent.Periph)
  else
    Console.Scheduler.Schedule(TDCEvent.Periph, At);
end;

procedure IRLChanged(User: Pointer; Level: Integer);
begin
  var Console := TDCConsole(User);
  if Console.Periph <> nil then
    Console.Periph.SetIRL(Level);
end;

procedure DMACopy(User: Pointer; Source, Dest: Cardinal; UnitSize: Integer; Count: Cardinal; SourceStep, DestStep: Integer);
begin
  var Console := TDCConsole(User);
  for var I := 0 to Int64(Count) - 1 do
  begin
    var Offset := 0;
    while Offset < UnitSize do
    begin
      var Size := UnitSize - Offset;
      if Size > 4 then
        Size := 4;
      var V := Console.ReadBus(Source + Cardinal(Offset), Size);
      Console.WriteBus(Dest + Cardinal(Offset), V, Size);
      Inc(Offset, Size);
    end;
    Source := Source + Cardinal(SourceStep);
    Dest := Dest + Cardinal(DestStep);
  end;
end;

{ TDCConsole }

constructor TDCConsole.Create(const Config: TDCConsoleConfig);
begin
  inherited Create;
  FConfig := Config;
  if (Length(Config.BootROM) <> 0) and (Length(Config.BootROM) <> DCBootSize) then
    raise EArgumentException.Create('Dreamcast boot ROM must contain 2 MiB');
  if (Length(Config.Flash) <> 0) and (Length(Config.Flash) <> DCFlashSize) then
    raise EArgumentException.Create('Dreamcast flash ROM must contain 128 KiB');
  Build;
  Reset;
end;

procedure TDCConsole.Build;
begin
  Memory := TDCMemory.Create;
  Scheduler := TDCScheduler.Create;
  var Bus := Default(TSH4Bus);
  Bus.User := Self;
  Bus.Read := BusRead;
  Bus.Write := BusWrite;
  Bus.Burst := BusBurst;
  Bus.OnChipRead := OnChipRead;
  Bus.OnChipWrite := OnChipWrite;
  Bus.OnChipUser := Self;
  Bus.ReadPages := @Memory.ReadPages;
  Bus.WritePages := @Memory.WritePages;
  Bus.Gens := @Memory.Gens;
  CPU := TSH4.Create(Bus, @Scheduler.Now, @Scheduler.NextDue);
  // The 32-bit VRAM view, withdrawn over a render in flight (SetRenderPages).
  for var Area in [$0500, $0700] do
    for var P := 0 to 255 do
      CPU.SetVolatile(Area + P);
  Periph := TSH4Periph.Create(CPU, @Scheduler.Now, DMACopy, PeriphSchedule, Self);
  Interrupts := TDCInterrupts.Create(IRLChanged, Self);
  PVR := TDCPVR.Create(Memory, Scheduler, Interrupts);
  TA := TDCTA.Create(Memory, Interrupts, PVR);
  PVR.TA := TA;
  Renderer := TDCRenderer.Create(Memory, PVR, TA);
  PVR.OnStartRender := StartRender;
  GDROM := TDCGDROM.Create(Scheduler, Interrupts);
  AICA := TDCAICA.Create(Memory, Scheduler, Interrupts);
  Maple := TDCMaple.Create(Memory);
  Maple.OnLightGun := PVR.LatchLightGun;
  Holly := TDCHolly.Create(Memory, Scheduler, Interrupts, Periph, PVR, GDROM, AICA, Maple);
  Holly.OnSoftReset := RequestSoftReset;
  Boot := TDCBoot.Create(CPU, Memory, Periph, PVR);
  GDROMHLE := TDCGDROMHLE.Create(GDROM, Memory, Interrupts, ReadBus, WriteBus);
  Boot.GDROM := GDROMHLE;
  Flash := TDCFlash.Create(Memory.Flash);
  AICA.GDROM := GDROM;
end;

destructor TDCConsole.Destroy;
begin
  if (Renderer <> nil) and (Memory <> nil) then
    JoinRender;
  Disc.Free;
  Flash.Free;
  GDROMHLE.Free;
  Boot.Free;
  Holly.Free;
  Maple.Free;
  AICA.Free;
  GDROM.Free;
  Renderer.Free;
  TA.Free;
  PVR.Free;
  Interrupts.Free;
  Periph.Free;
  CPU.Free;
  Scheduler.Free;
  Memory.Free;
  inherited;
end;

procedure TDCConsole.Reset;
begin
  if Renderer <> nil then
    JoinRender;
  Scheduler.Reset;
  FillChar(Memory.RAM^, DCRAMSize, 0);
  FillChar(Memory.VRAM^, DCVRAMSize, 0);
  FillChar(Memory.ARAM^, DCARAMSize, 0);
  FillChar(Memory.Boot^, DCBootSize, 0);
  // Without a boot ROM image the high-level boot provides a font of its own.
  if Length(FConfig.BootROM) = DCBootSize then
    Move(FConfig.BootROM[0], Memory.Boot^, DCBootSize)
  else
    DCWriteFont(Memory.Boot + (DCFontAddress and $1FFFFF));
  // A supplied flash image is kept; otherwise one is generated for the region.
  if Length(FConfig.Flash) = DCFlashSize then
    Move(FConfig.Flash[0], Memory.Flash^, DCFlashSize)
  else
  begin
    var Broadcast := TDCBroadcast.NTSC;
    if FConfig.PAL then
      Broadcast := TDCBroadcast.PAL;
    Flash.Generate(FConfig.Region, Broadcast, FConfig.Language, FConfig.RTCSeconds);
  end;
  Flash.Reset;
  // The clock is right: the boot ROM need not ask for the date.
  Flash.SetConfigTime(FConfig.RTCSeconds);
  for var I := 0 to High(Memory.RAMGens) do
    Inc(Memory.RAMGens[I]);
  for var I := 0 to High(Memory.VRAMGens) do
    Inc(Memory.VRAMGens[I]);
  CPU.Reset;
  Periph.Reset;
  Periph.CableType := Ord(FConfig.Cable);
  if FConfig.Cable = TDCCable.VGA then
    Periph.CableType := 0
  else if FConfig.Cable = TDCCable.RGB then
    Periph.CableType := 2
  else
    Periph.CableType := 3;
  Interrupts.Reset;
  PVR.Reset(FConfig.PAL);
  TA.Reset;
  TA.Rendering := nil;
  GDROM.Reset;
  GDROMHLE.Reset;
  AICA.Reset(FConfig.RTCSeconds);
  Holly.Reset;
  FHalted := False;
  FFrameCount := 0;
  Boot.VGA := FConfig.Cable = TDCCable.VGA;
  Boot.PAL := FConfig.PAL;
  if HighLevelBoot then
  begin
    // High-level boot: vectors installed, CPU waits for a program.
    CPU.SetIllegalHook(DCBootIllegalHook, Boot);
    Boot.Install;
  end
  else
    CPU.SetIllegalHook(nil, nil);
end;

function TDCConsole.HighLevelBoot: Boolean;
begin
  Result := (Length(FConfig.BootROM) = 0) or FConfig.HLEBoot;
end;

procedure TDCConsole.InsertDisc(Image: TCDDisc);
begin
  FreeAndNil(Disc);
  if Image <> nil then
    Disc := TDCDisc.Create(Image);
  GDROM.Disc := Disc;
  GDROM.Tray := Disc;
end;

procedure TDCConsole.OpenLid;
begin
  GDROM.OpenLid;
  GDROMHLE.LidOpened;
  FreeAndNil(Disc);
end;

procedure TDCConsole.CloseLid(Image: TCDDisc);
begin
  FreeAndNil(Disc);
  if Image <> nil then
    Disc := TDCDisc.Create(Image);
  GDROM.CloseLid(Disc);
end;

procedure TDCConsole.ChangeDisc(Image: TCDDisc; Seconds: Double);
begin
  OpenLid;
  if Image <> nil then
    Disc := TDCDisc.Create(Image);
  GDROM.CloseLidLater(Disc, Round(Seconds * DCCPUClock));
end;

function TDCConsole.LidOpen: Boolean;
begin
  Result := GDROM.S.LidOpen;
end;

procedure TDCConsole.BootDisc;
begin
  if Disc = nil then
    raise EReadError.Create('No disc inserted');
  CPU.InvalidateBlocks;
  Boot.BootDisc(Disc);
  if Boot.BootDMAEnd <> 0 then
    Holly.SetGDDMAEnd(Boot.BootDMAEnd, Boot.BootDMALength);
  CPU.InvalidateBlocks;
end;

procedure TDCConsole.LoadProgram(const Data: TBytes);
begin
  var Entry: Cardinal;
  if IsDCELF(Data) then
    Entry := LoadDCELF(Data, Memory)
  else
    Entry := LoadDCBinary(Data, Memory);
  CPU.InvalidateBlocks;
  Boot.EnterProgram(Entry);
end;

function TDCConsole.ReadBus(Address: Cardinal; Size: Integer): UInt64;
begin
  if Size = 8 then
  begin
    Result := ReadBus(Address, 4) or (ReadBus(Address + 4, 4) shl 32);
    Exit;
  end;
  Address := Address and $1FFFFFFF;
  Result := 0;
  case Address shr 26 of
    0:
      begin
        var A := Address and $01FFFFFF;
        if A < $00200000 then
          Result := PCardinal(Memory.Boot + (A and $1FFFFC))^ shr ((A and 3) * 8)
        else if A < $00220000 then
          Result := PCardinal(Memory.Flash + (A and $1FFFC))^ shr ((A and 3) * 8)
        else if (A >= $005F7000) and (A < $005F7100) then
          Result := GDROM.Read(A - $005F7000, Size)
        else if (A >= $005F6800) and (A < $005F8000) then
          Result := Holly.Read(A, Size)
        else if (A >= $005F8000) and (A < $005FA000) then
          Result := PVR.ReadRegister(A - $005F8000) shr ((A and 3) * 8)
        else if (A >= $00700000) and (A < $00708000) then
          Result := AICA.ReadRegister(A - $00700000, Size)
        else if (A >= $00710000) and (A < $00710010) then
          Result := AICA.ReadRTC(A - $00710000)
        else if (A >= $00800000) and (A < $01000000) then
          Result := AICA.ReadRAM(A - $00800000, Size);
      end;
    1:
      if (Address and $01000000) = 0 then
        Result := Memory.VRAMRead64Path(Address and $7FFFFF, Size)
      else
      begin
        var A := Address and $7FFFFF;
        Memory.Observe(A and not Cardinal(3), 4);
        case Size of
          1:
            Result := Memory.VRAM[A];
          2:
            Result := PWord(Memory.VRAM + (A and $7FFFFE))^;
        else
          Result := PCardinal(Memory.VRAM + (A and $7FFFFC))^;
        end;
      end;
    3:
      begin
        var A := Address and (DCRAMSize - 1);
        case Size of
          1:
            Result := Memory.RAM[A];
          2:
            Result := PWord(Memory.RAM + (A and not Cardinal(1)))^;
        else
          Result := PCardinal(Memory.RAM + (A and not Cardinal(3)))^;
        end;
      end;
    4:
      Result := Holly.ReadArea4(Address, Size);
  end;
  case Size of
    1:
      Result := Result and $FF;
    2:
      Result := Result and $FFFF;
    4:
      Result := Result and $FFFFFFFF;
  end;
end;

procedure TDCConsole.WriteBus(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  if Size = 8 then
  begin
    if (Address shr 26) and 7 = 4 then
    begin
      var Words: array[0..1] of Cardinal;
      Words[0] := Cardinal(Value);
      Words[1] := Cardinal(Value shr 32);
      Holly.WriteArea4(Address, @Words[0], 2);
      Exit;
    end;
    WriteBus(Address, Cardinal(Value), 4);
    WriteBus(Address + 4, Cardinal(Value shr 32), 4);
    Exit;
  end;
  Address := Address and $1FFFFFFF;
  case Address shr 26 of
    0:
      begin
        var A := Address and $01FFFFFF;
        if (A >= $00200000) and (A < $00220000) then
          Flash.Write(A - $00200000, Cardinal(Value))
        else if (A >= $005F7000) and (A < $005F7100) then
          GDROM.Write(A - $005F7000, Cardinal(Value), Size)
        else if (A >= $005F6800) and (A < $005F8000) then
          Holly.Write(A, Cardinal(Value), Size)
        else if (A >= $005F8000) and (A < $005FA000) then
          PVR.WriteRegister(A - $005F8000, Cardinal(Value))
        else if (A >= $00700000) and (A < $00708000) then
          AICA.WriteRegister(A - $00700000, Cardinal(Value), Size)
        else if (A >= $00710000) and (A < $00710010) then
          AICA.WriteRTC(A - $00710000, Cardinal(Value))
        else if (A >= $00800000) and (A < $01000000) then
          AICA.WriteRAM(A - $00800000, Cardinal(Value), Size);
      end;
    1:
      if (Address and $01000000) = 0 then
        Memory.VRAMWrite64Path(Address and $7FFFFF, Value, Size)
      else
      begin
        var A := Address and $7FFFFF;
        Memory.Observe(A and not Cardinal(3), 4);
        case Size of
          1:
            Memory.VRAM[A] := Byte(Value);
          2:
            PWord(Memory.VRAM + (A and $7FFFFE))^ := Word(Value);
        else
          PCardinal(Memory.VRAM + (A and $7FFFFC))^ := Cardinal(Value);
        end;
        Memory.TouchVRAM(A, Size);
      end;
    3:
      begin
        var A := Address and (DCRAMSize - 1);
        case Size of
          1:
            Memory.RAM[A] := Byte(Value);
          2:
            PWord(Memory.RAM + (A and not Cardinal(1)))^ := Word(Value);
        else
          PCardinal(Memory.RAM + (A and not Cardinal(3)))^ := Cardinal(Value);
        end;
        Inc(Memory.RAMGens[A shr 12]);
      end;
    4:
      begin
        var Word_ := Cardinal(Value);
        Holly.WriteArea4(Address, @Word_, 1);
      end;
  end;
end;

procedure TDCConsole.DispatchEvent(Event: TDCEvent);
begin
  case Event of
    TDCEvent.Periph:
      Periph.Update;
    TDCEvent.SPGLine:
      begin
        var Before := PVR.VBlankCount;
        PVR.LineEvent;
        if PVR.VBlankCount <> Before then
        begin
          Inc(FFrameCount);
          FFrameDone := True;
          Holly.VBlank;
        end;
      end;
    TDCEvent.Render:
      begin
        Interrupts.RaiseNormal(HollyRenderDoneISP);
        Interrupts.RaiseNormal(HollyRenderDoneTSP);
        Interrupts.RaiseNormal(HollyRenderDoneVideo);
      end;
    TDCEvent.Ch2DMA, TDCEvent.SortDMA, TDCEvent.PVRDMA, TDCEvent.MapleDMA, TDCEvent.GDDMA, TDCEvent.G2DMA:
      Holly.Event(Event);
    TDCEvent.GDROM:
      GDROM.Event;
    TDCEvent.AICA:
      AICA.Event;
  end;
end;

procedure TDCConsole.SetRenderPages(Direct: Boolean);
begin
  Memory.MapVRAMPages(FRenderFirst, FRenderLast, Direct);
  for var P := Integer(FRenderFirst shr 16) to Integer((FRenderLast - 1) shr 16) and $7F do
    for var Area in [$0500, $0700] do
      for var Mirror in [0, 128] do
        CPU.RemapPhysical(Area + Mirror + P);
end;

procedure TDCConsole.JoinForMemory;
begin
  Inc(RenderJoins[0]);
  JoinRender;
end;

procedure TDCConsole.JoinForTA;
begin
  Inc(RenderJoins[1]);
  JoinRender;
end;

procedure TDCConsole.JoinRender;
begin
  if not Assigned(Memory.Barrier) then
    Exit;
  Renderer.Wait;
  Memory.Barrier := nil;
  TA.OnBusy := nil;
  SetRenderPages(True);
end;

procedure TDCConsole.StartRender(Sender: Pointer);
begin
  // The scene renders at once; completion is signalled after a nominal time.
  // The rasterizer uses nearest rounding without traps on every thread,
  // whatever FPSCR mode the CPU loop has applied here.
  var SavedMask := GetExceptionMask;
  var SavedRound := GetRoundMode;
  SetExceptionMask(exAllArithmeticExceptions);
  SetRoundMode(rmNearest);
  JoinRender;
  try
    Renderer.Render;
    TA.Rendering := Renderer.Context;
    // The workers may finish later: every access that could observe their
    // output (the framebuffer range, the scene's TA context) waits for them
    // first, so results match a render completed here.
    if Renderer.RenderAsync then
    begin
      FRenderFirst := Renderer.FramebufferFirst;
      FRenderLast := Renderer.FramebufferLast;
      Memory.PendingFirst := FRenderFirst;
      Memory.PendingLast := FRenderLast;
      Memory.Barrier := JoinForMemory;
      TA.OnBusy := JoinForTA;
      SetRenderPages(False);
    end;
  finally
    SetExceptionMask(SavedMask);
    SetRoundMode(SavedRound);
  end;
  // Cached textures over the written range are stale.
  var Base := Renderer.FramebufferFirst;
  var Size := Renderer.FramebufferLast - Base;
  if (PVR.R[PVRFBWSOF1 shr 2] and $1000000) <> 0 then
  begin
    // Render to texture: the 64-bit range spreads over both banks.
    for var P := 0 to Integer(Size shr 13) do
    begin
      Inc(Memory.VRAMGens[((Base shr 1) shr 12 + Cardinal(P)) and 1023]);
      Inc(Memory.VRAMGens[(((Base shr 1) shr 12 + Cardinal(P)) and 1023) + 1024]);
    end;
  end
  else
    for var P := Integer(Base shr 12) to Integer((Base + Size - 1) shr 12) do
      Inc(Memory.VRAMGens[P and High(Memory.VRAMGens)]);
  Scheduler.Schedule(TDCEvent.Render, Scheduler.Now + 40000 + Int64(Renderer.PolygonsRendered) * 200);
end;

procedure TDCConsole.RequestSoftReset;
begin
  FSoftReset := True;
  CPU.RequestExit;
end;

// SB_SFRES: the SH-4 and its on-chip modules restart at the boot ROM; memory,
// Holly, PVR, AICA and the drive keep their state. Without a boot ROM image
// there is nothing to restart into, so the program has left to the menu.
procedure TDCConsole.SoftReset;
begin
  FSoftReset := False;
  if HighLevelBoot then
  begin
    FHalted := True;
    Exit;
  end;
  JoinRender;
  CPU.Reset;
  Periph.Reset;
  // Holly keeps driving its interrupt lines.
  if Interrupts.Level > 0 then
    Periph.SetIRL(Interrupts.Level);
end;

procedure TDCConsole.RunFrame;
begin
  FFrameDone := False;
  var Guard := 0;
  repeat
    if Scheduler.NextDue > Scheduler.Now then
      CPU.Run;
    var Event: TDCEvent;
    var At: Int64;
    if FSoftReset then
      SoftReset;
    while Scheduler.TakeDue(Event, At) do
      DispatchEvent(Event);
    if Boot.TakeRequest = TDCBootRequest.ExitToMenu then
      FHalted := True;
    Inc(Guard);
  until FFrameDone or FHalted or (Guard > 10000000);
end;

procedure TDCConsole.SerializeState(Archive: TStateArchive);
begin
  JoinRender;
  Scheduler.SerializeState(Archive);
  Memory.SerializeState(Archive);
  CPU.SerializeState(Archive);
  Periph.SerializeState(Archive);
  Interrupts.SerializeState(Archive);
  PVR.SerializeState(Archive);
  GDROM.SerializeState(Archive);
  // The drive holds the inserted disc unless the snapshot has the lid open;
  // an open lid that is due to close has it in the tray.
  if Archive.Loading then
    if not GDROM.S.LidOpen then
    begin
      GDROM.Disc := Disc;
      GDROM.Tray := Disc;
    end
    else
    begin
      GDROM.Disc := nil;
      if GDROM.S.LidCloseAt <> 0 then
        GDROM.Tray := Disc
      else
        GDROM.Tray := nil;
    end;
  AICA.SerializeState(Archive);
  Maple.SerializeState(Archive);
  Holly.SerializeState(Archive);
  GDROMHLE.SerializeState(Archive);
  Flash.SerializeState(Archive);
  Archive.Field(FFrameCount, SizeOf(FFrameCount));
  Archive.Field(FHalted, SizeOf(FHalted));
end;

end.

