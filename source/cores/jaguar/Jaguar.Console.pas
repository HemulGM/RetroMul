unit Jaguar.Console;

interface

uses
  System.SysUtils, HW.M68k, Jaguar.RISC, Jaguar.Video, Jaguar.Blitter,
  Jaguar.Jerry, Jaguar.CD, Core.CD.Disc, Core.InputConfig, Core.Emulation.Types,
  Core.Snapshots;

type
  TJaguarCPUTrace = procedure(const State: TM68kState) of object;

  TJaguarBusWriteTrace = procedure(Address, Value: Cardinal; Size: Integer) of object;

  TJaguarConsole = class
  private
    FCPU: TM68kState;
    FCallbacks: TM68kReadWriteCallbacks;
    FGPU, FDSP: TJaguarRISC;
    FVideo: TJaguarVideo;
    FBlitter: TJaguarBlitter;
    FJerry: TJaguarJerry;
    FCD: TJaguarCD;
    FRAM, FROM, FBIOS, FNVM: TBytes;
    FGPURAM: array[0..4095] of Byte;
    FBootMap, FPAL, FUseBIOS: Boolean;
    FCPUDebt: Integer;
    FCPUTrace: TJaguarCPUTrace;
    FBusWriteTrace: TJaguarBusWriteTrace;
    function GetFrame: TEmulatorFrame;
    function GetSamples: TArray<SmallInt>;
    function GetRate: Double;
    procedure GPUIRQ(Line: Integer);
    procedure DSPIRQ(Line: Integer);
    procedure CPUIRQ(Line: Integer);
    procedure JerryIRQ(Line: Integer);
    procedure CDIRQ(Line: Integer);
    procedure FastBootCD;
  public
    constructor Create(const Image, BIOS: TBytes; PAL: Boolean = False; UseBIOS: Boolean = True; Disc: TCDDisc = nil; CDHardware: Boolean = False);
    destructor Destroy; override;
    procedure Reset;
    function ReadBus(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteBus(Address, Value: Cardinal; Size: Integer);
    procedure RunFrame;
    procedure SetInput(const Input: TEmulatorInput);
    procedure ConfigurePorts(const Ports: TCoreInputPorts);
    procedure InsertDisc(Disc: TCDDisc);
    procedure SetKeypad(Port: Integer; Mask: Word);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
    property Frame: TEmulatorFrame read GetFrame;
    property Samples: TArray<SmallInt> read GetSamples;
    property Rate: Double read GetRate;
    property CPU: TM68kState read FCPU;
    property GPU: TJaguarRISC read FGPU;
    property DSP: TJaguarRISC read FDSP;
    property CD: TJaguarCD read FCD;
    property OnCPUExecute: TJaguarCPUTrace read FCPUTrace write FCPUTrace;
    property OnBusWrite: TJaguarBusWriteTrace read FBusWriteTrace write FBusWriteTrace;
  end;

implementation

uses
  System.Classes, System.Math, Jaguar.Firmware;

{$Q-}{$R-}

function CPURead(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte): Cardinal;
begin
  var C := TJaguarConsole(User);
  if (Hi <> 0) and (Lo <> 0) then
    Exit(C.ReadBus(Address * 2, 2));
  Result := 0;
  if Hi <> 0 then
    Result := C.ReadBus(Address * 2, 1) shl 8;
  if Lo <> 0 then
    Result := Result or C.ReadBus(Address * 2 + 1, 1);
end;

procedure CPUWrite(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte; Value: Cardinal);
begin
  var C := TJaguarConsole(User);
  if (Hi <> 0) and (Lo <> 0) then
    C.WriteBus(Address * 2, Value, 2)
  else
  begin
    if Hi <> 0 then
      C.WriteBus(Address * 2, Value shr 8, 1);
    if Lo <> 0 then
      C.WriteBus(Address * 2 + 1, Value, 1);
  end;
end;

procedure CPUAcknowledge(User: Pointer);
begin
  Clown68000Interrupt(TJaguarConsole(User).FCPU, 0);
end;

constructor TJaguarConsole.Create(const Image, BIOS: TBytes; PAL, UseBIOS: Boolean; Disc: TCDDisc; CDHardware: Boolean);
begin
  inherited Create;
  if (Length(Image) < $2000) or (Length(Image) > $600000) then
    raise EReadError.Create('Jaguar cartridge must contain 8 KiB to 6 MiB');
  if Length(BIOS) <> $20000 then
    raise EReadError.Create('Jaguar BIOS must contain 128 KiB');
  FROM := Copy(Image);
  FBIOS := Copy(BIOS);
  FPAL := PAL;
  FUseBIOS := UseBIOS;
  SetLength(FRAM, $200000);
  FGPU := TJaguarRISC.Create(ReadBus, WriteBus, False);
  FDSP := TJaguarRISC.Create(ReadBus, WriteBus, True);
  FVideo := TJaguarVideo.Create(ReadBus, WriteBus, GPUIRQ, CPUIRQ, PAL);
  FBlitter := TJaguarBlitter.Create(ReadBus, WriteBus);
  FJerry := TJaguarJerry.Create(DSPIRQ, JerryIRQ, PAL);
  if CDHardware or (Disc <> nil) then
  begin
    SetLength(FNVM, $20000);
    FCD := TJaguarCD.Create(CDIRQ, FJerry.CDSerialInput);
    FCD.InsertDisc(Disc);
  end;
  FCallbacks.ReadCallback := CPURead;
  FCallbacks.WriteCallback := CPUWrite;
  FCallbacks.UserData := Self;
  FCallbacks.InterruptAcknowledgeCallback := CPUAcknowledge;
  Reset;
end;

destructor TJaguarConsole.Destroy;
begin
  FCD.Free;
  FJerry.Free;
  FBlitter.Free;
  FVideo.Free;
  FDSP.Free;
  FGPU.Free;
  inherited;
end;

procedure TJaguarConsole.Reset;
begin
  FillChar(FRAM[0], Length(FRAM), 0);
  FillChar(FGPURAM, SizeOf(FGPURAM), 0);
  FCPU := Default(TM68kState);
  FCPUDebt := 0;
  FBootMap := True;
  if FCD <> nil then
    FCD.Reset;
  FGPU.Reset;
  FDSP.Reset;
  FVideo.Reset;
  FBlitter.Reset;
  FJerry.Reset;
  Clown68000Reset(FCPU, FCallbacks);
  if not FUseBIOS then
  begin
    FBootMap := False;
    var Entry := ReadBus($800404, 4);
    if (Entry < $800000) or (Entry >= $E00000) or (Entry and 1 <> 0) then
      raise EReadError.Create('Invalid Jaguar cartridge entry point');
    WriteBus(0, $4000, 4);
    WriteBus(4, Entry, 4);
    WriteBus($400, $508F4E73, 4);
    WriteBus($404, $4E73, 2);
    WriteBus(8, $400, 4);
    WriteBus(12, $400, 4);
    for var Vector := 4 to 255 do
      WriteBus(Vector * 4, $404, 4);
    WriteBus($1000, 0, 4);
    WriteBus($1004, 4, 4);
    WriteBus($F00020, $10000000, 4);
    WriteBus($F00000, $1861 or (FROM[$400] and $1E), 2);
    WriteBus($F00002, $35CC, 2);
    WriteBus($F0004E, 519, 2);
    WriteBus($F000E0, $1F00, 2);
    WriteBus($F03000, $03D0DEAD, 4);
    WriteBus($F1A152, 19, 2);
    WriteBus($F1A156, $15, 2);
    FCPU.AddressRegisters[7] := $4000;
    FCPU.SupervisorStackPointer := $4000;
    FCPU.ProgramCounter := Entry;
    FCPU.StatusRegister := $2700;
    if FCD <> nil then
      FastBootCD;
  end;
end;

procedure TJaguarConsole.FastBootCD;
begin
  var Entry: Cardinal;
  var Code: TBytes;
  if not FCD.ReadBootCode(Entry, Code) then
  begin
    if FCD.Disc <> nil then
      raise EReadError.Create('Jaguar CD boot header or executable is missing or damaged. Use a complete CUE/BIN, CDI or CHD image.');
    Exit;
  end;
  // The supplied retail CD ROM copies its resident 68k/GPU driver from
  // $8084A6 to $3000 (verified against that ROM's startup copy loop).
  // Execute that original driver for every subsequent CD BIOS call.
  if (Length(FROM) <> $40000) or (FROM[$84A6] <> $60) or (FROM[$84A8] <> $4E) then
    raise EReadError.Create('Unsupported Jaguar CD BIOS resident driver layout');
  Move(FROM[$84A6], FRAM[$3000], $8E90 - $84A6);
  // Original Atari NVM filesystem driver, executing as 68000 guest code.
  // Its ROMulator backend uses the documented $900000 byte-addressed window.
  // This preserves the shipped filesystem, error codes and register ABI.
  var NVM := LoadJaguarNVMBIOS;
  Move(NVM[0], FRAM[$2400], Length(NVM));
  var Disc := FCD.Disc;
  FillChar(FRAM[$2C00], $400, 0);
  var Sessions := 1;
  FRAM[$2C02] := Disc.Track(1).Number;
  FRAM[$2C03] := Disc.Track(Disc.TrackCount).Number;
  for var i := 1 to Disc.TrackCount do
  begin
    var Track := Disc.Track(i);
    var P := $2C00 + Track.Number * 8;
    if P + 8 > $3000 then
      raise EReadError.Create('Jaguar CD TOC contains an invalid track number');
    var Session := FCD.TrackSession(i) + 1;
    Sessions := Max(Sessions, Session);
    var Time := Track.StartLBA + 150;
    FRAM[P] := Track.Number;
    FRAM[P + 1] := Time div 4500;
    FRAM[P + 2] := Time div 75 mod 60;
    FRAM[P + 3] := Time mod 75;
    FRAM[P + 4] := Session - 1;
    Time := Track.EndLBA - Track.StartLBA;
    FRAM[P + 5] := Time div 4500;
    FRAM[P + 6] := Time div 75 mod 60;
    FRAM[P + 7] := Time mod 75;
  end;
  FRAM[$2C04] := Sessions;
  var Time := Disc.LeadOut + 150;
  FRAM[$2C05] := Time div 4500;
  FRAM[$2C06] := Time div 75 mod 60;
  FRAM[$2C07] := Time mod 75;
  Move(Code[0], FRAM[Entry], Length(Code));
  FCPU.ProgramCounter := Entry;
end;

procedure TJaguarConsole.GPUIRQ(Line: Integer);
begin
  FGPU.Interrupt(Line);
end;

procedure TJaguarConsole.DSPIRQ(Line: Integer);
begin
  FDSP.Interrupt(Line);
end;

procedure TJaguarConsole.CPUIRQ(Line: Integer);
begin
  Clown68000Interrupt(FCPU, Line);
end;

procedure TJaguarConsole.JerryIRQ(Line: Integer);
begin
  FVideo.SetJerryIRQ(Line <> 0);
  if Line <> 0 then
    FGPU.Interrupt(1);
end;

procedure TJaguarConsole.CDIRQ(Line: Integer);
begin
  FJerry.ExternalInterrupt;
end;

function TJaguarConsole.ReadBus(Address: Cardinal; Size: Integer): Cardinal;
begin
  Address := Address and $FFFFFF;
  // TOM's normal internal window is 16 KiB. The +$8000 window is
  // write-only; reserved +$4000/+$C000 addresses are not register mirrors.
  if (Address >= $F04000) and (Address < $F10000) then
    Exit(Cardinal($FFFFFFFF) shr ((4 - Size) * 8));
  Result := 0;
  if (Address >= $F02100) and (Address < $F02120) then
  begin
    var V := FGPU.ReadControl(Address - $F02100);
    if Size < 4 then
      V := V shr ((4 - Size - Integer(Address and 3)) * 8);
    if Size = 1 then
      V := V and $FF
    else if Size = 2 then
      V := V and $FFFF;
    Exit(V);
  end;
  if (Address >= $F1A100) and (Address < $F1A124) then
  begin
    var V := FDSP.ReadControl(Address - $F1A100);
    if Size < 4 then
      V := V shr ((4 - Size - Integer(Address and 3)) * 8);
    if Size = 1 then
      V := V and $FF
    else if Size = 2 then
      V := V and $FFFF;
    Exit(V);
  end;
  if (Address >= $F02000) and (Address < $F02100) then
  begin
    var V := FGPU.ReadRegister((Address - $F02000) div 4);
    if Size < 4 then
      V := V shr ((4 - Size - Integer(Address and 3)) * 8);
    if Size = 1 then
      V := V and $FF
    else if Size = 2 then
      V := V and $FFFF;
    Exit(V);
  end;
  if (Address >= $F02200) and (Address < $F02300) then
  begin
    var V := FBlitter.Read(Address - $F02200);
    if Size < 4 then
      V := V shr ((4 - Size - Integer(Address and 3)) * 8);
    if Size = 1 then
      V := V and $FF
    else if Size = 2 then
      V := V and $FFFF;
    Exit(V);
  end;
  if (Address >= $F00000) and (Address < $F02000) then
    Exit(FVideo.Read(Address - $F00000, Size));
  if (Address >= $F10000) and (Address < $F20000) then
    Exit(FJerry.Read(Address - $F10000, Size));
  if (FCD <> nil) and (Address >= $DFFF00) and (Address < $DFFF30) then
    Exit(FCD.Read(Address - $DFFF00, Size));
  for var i := 0 to Size - 1 do
  begin
    var A := (Address + Cardinal(i)) and $FFFFFF;
    var V: Byte := $FF;
    if (A >= $F03000) and (A < $F04000) then
      V := FGPURAM[A and $FFF]
    else if (FBootMap and (A < $E00000)) or ((A >= $E00000) and (A < $E40000)) then
      V := FBIOS[A and $1FFFF]
    else if (FCD <> nil) and (A >= $900000) and (A < $920000) then
      V := FNVM[A - $900000]
    else if A < $800000 then
      V := FRAM[A and $1FFFFF]
    else if (A >= $800000) and (A < $E00000) then
    begin
      if A - $800000 < Cardinal(Length(FROM)) then
        V := FROM[A - $800000];
    end;
    Result := (Result shl 8) or V;
  end;
end;

procedure TJaguarConsole.WriteBus(Address, Value: Cardinal; Size: Integer);
begin
  Address := Address and $FFFFFF;
  if Assigned(FBusWriteTrace) then
    FBusWriteTrace(Address, Value, Size);
  if (Address >= $F08000) and (Address < $F0C000) then
    Dec(Address, $8000);
  if (Address >= $F04000) and (Address < $F10000) then
    Exit;
  if (Address >= $F02100) and (Address < $F02120) then
  begin
    var Offset := Address - $F02100;
    var V := Value;
    if Size < 4 then
    begin
      var Shift := (4 - Size - Integer(Address and 3)) * 8;
      var Mask := $FFFF;
      if Size = 1 then
        Mask := $FF;
      V := (FGPU.ReadControl(Offset) and not (Cardinal(Mask) shl Shift)) or ((Value and Cardinal(Mask)) shl Shift);
    end;
    FGPU.WriteControl(Offset, V);
    if (Offset and $FC = $14) and (V and 2 <> 0) then
      FVideo.RaiseIRQ(1);
    Exit;
  end;
  if (Address >= $F1A100) and (Address < $F1A124) then
  begin
    var Offset := Address - $F1A100;
    var V := Value;
    if Size < 4 then
    begin
      var Shift := (4 - Size - Integer(Address and 3)) * 8;
      var Mask := $FFFF;
      if Size = 1 then
        Mask := $FF;
      V := (FDSP.ReadControl(Offset) and not (Cardinal(Mask) shl Shift)) or ((Value and Cardinal(Mask)) shl Shift);
    end;
    FDSP.WriteControl(Offset, V);
    if (Offset and $FC = $14) and (V and 2 <> 0) then
      FJerry.DSPInterruptCPU;
    Exit;
  end;
  if (Address >= $F02000) and (Address < $F02100) then
  begin
    var Index := (Address - $F02000) div 4;
    var V := Value;
    if Size < 4 then
    begin
      var Shift := (4 - Size - Integer(Address and 3)) * 8;
      var Mask := $FFFF;
      if Size = 1 then
        Mask := $FF;
      V := (FGPU.ReadRegister(Index) and not (Cardinal(Mask) shl Shift)) or ((Value and Cardinal(Mask)) shl Shift);
    end;
    FGPU.WriteRegister(Index, V);
    Exit;
  end;
  if (Address >= $F02200) and (Address < $F02300) then
  begin
    var Offset := Address - $F02200;
    var V := Value;
    if Size < 4 then
    begin
      var Shift := (4 - Size - Integer(Address and 3)) * 8;
      var Mask := $FFFF;
      if Size = 1 then
        Mask := $FF;
      V := (FBlitter.RegisterValue(Offset) and not (Cardinal(Mask) shl Shift)) or ((Value and Cardinal(Mask)) shl Shift);
    end;
    // 68000 writes the high word before the triggering command low word.
    if (Offset and $FC <> $38) or (Size = 4) or (Offset and 3 <> 0) then
    begin
      FBlitter.Write(Offset, V);
      if Offset and $FC = $38 then
        FGPU.Interrupt(4);
    end
    else
      FBlitter.Write(Offset, V, False);
    Exit;
  end;
  if (Address >= $F00000) and (Address < $F02000) then
  begin
    if Address < $F00002 then
      FBootMap := False;
    FVideo.Write(Address - $F00000, Value, Size);
    Exit;
  end;
  if (Address >= $F10000) and (Address < $F20000) then
  begin
    FJerry.Write(Address - $F10000, Value, Size);
    Exit;
  end;
  if (FCD <> nil) and (Address >= $DFFF00) and (Address < $DFFF30) then
  begin
    FCD.Write(Address - $DFFF00, Value, Size);
    Exit;
  end;
  for var i := 0 to Size - 1 do
  begin
    var A := (Address + Cardinal(i)) and $FFFFFF;
    var V := Byte(Value shr ((Size - 1 - i) * 8));
    if A < $800000 then
      FRAM[A and $1FFFFF] := V
    else if (FCD <> nil) and (A >= $900000) and (A < $920000) then
      FNVM[A - $900000] := V
    else if (A >= $F03000) and (A < $F04000) then
      FGPURAM[A and $FFF] := V;
  end;
end;

function TJaguarConsole.GetFrame: TEmulatorFrame;
begin
  Result := FVideo.Frame;
end;

function TJaguarConsole.GetSamples: TArray<SmallInt>;
begin
  Result := FJerry.Samples;
end;

function TJaguarConsole.GetRate: Double;
begin
  Result := FVideo.Frame.FramesPerSecond;
end;

procedure TJaguarConsole.SetInput(const Input: TEmulatorInput);
begin
  FJerry.SetInput(Input);
end;

procedure TJaguarConsole.ConfigurePorts(const Ports: TCoreInputPorts);
begin
  FJerry.ConfigurePorts(Ports);
end;

procedure TJaguarConsole.InsertDisc(Disc: TCDDisc);
begin
  if FCD = nil then
    raise EInvalidOpException.Create('Jaguar CD hardware is not installed');
  FCD.InsertDisc(Disc);
end;

procedure TJaguarConsole.SetKeypad(Port: Integer; Mask: Word);
begin
  FJerry.SetKeypad(Port, Mask);
end;

function TJaguarConsole.Battery: TBytes;
begin
  if FCD = nil then
    Exit(FJerry.EEPROM.Battery);
  Result := Copy(FNVM);
  Result := Result + FCD.EEPROM.Battery;
end;

procedure TJaguarConsole.LoadBattery(const Data: TBytes);
begin
  if FCD = nil then
    FJerry.EEPROM.LoadBattery(Data)
  else if Length(Data) = $20080 then
  begin
    Move(Data[0], FNVM[0], $20000);
    FCD.EEPROM.LoadBattery(Copy(Data, $20000, 128));
  end
  else if Length(Data) = $20000 then
    Move(Data[0], FNVM[0], $20000)
  else
    raise EReadError.Create('Invalid Jaguar CD Memory Track save size');
end;

procedure TJaguarConsole.RunFrame;
begin
  FJerry.BeginFrame;
  FVideo.BeginFrame;
  var Lines := 262;
  if FPAL then
    Lines := 312;
  for var Line := 0 to Lines - 1 do
  begin
    FVideo.BeginLine(Line * 2);
    for var Chunk := 0 to 52 do
    begin
      var Cycles := 32;
      if Chunk = 52 then
        Cycles := 26;
      Dec(FCPUDebt, Cycles div 2);
      if FCPUDebt < 0 then
      begin
        if Assigned(FCPUTrace) then
          FCPUTrace(FCPU);
        Inc(FCPUDebt, Integer(Clown68000DoCycles(FCPU, FCallbacks, -FCPUDebt, 64)));
      end;
      FGPU.Run(Cycles);
      FDSP.Run(Cycles);
      if FCD <> nil then
        FCD.Clock(Cycles);
      FJerry.Clock(Cycles);
      FVideo.Clock(Cycles);
    end;
    FVideo.DisplayLine;
  end;
  FJerry.EndFrame;
  FVideo.EndFrame;
end;

procedure TJaguarConsole.SerializeState(State: TStateArchive);
begin
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM[0], Length(FRAM));
  State.Field(FGPURAM, SizeOf(FGPURAM));
  State.Field(FBootMap, SizeOf(FBootMap));
  State.Field(FCPUDebt, SizeOf(FCPUDebt));
  FGPU.SerializeState(State);
  FDSP.SerializeState(State);
  FVideo.SerializeState(State);
  FBlitter.SerializeState(State);
  FJerry.SerializeState(State);
  if FCD <> nil then
  begin
    FCD.SerializeState(State);
    State.Field(FNVM[0], Length(FNVM));
  end;
end;

end.

