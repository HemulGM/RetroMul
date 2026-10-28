unit SG1000.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Math,
  Core.Emulation.Types, Core.Snapshots, MD.Z80, SG1000.Cartridge, SG1000.VDP,
  SG1000.Sound, SG1000.SF7000, SG1000.Cassette, SMS.Cartridge, SMS.VDP,
  MSX.Sound.OPLL, Core.AudioFilter;

type
  TSGHostKeys = array[0..255] of Boolean;

  TSGModel = (SG1000, SG1000II, SC3000, SC3000H, Multivision, SF7000, MasterSystem, MarkIII, GameGear);

  // Host preferences are deliberately separate from the emulated snapshot.
  TSGOptions = record
    ShowBackground, ShowSprites, RemoveSpriteLimit: Boolean;
    FMEnabled, DiskWriteProtected: Boolean;
    ChannelVolume: array[0..3] of Integer;
    FMVolume: Integer;
    GGRegion: Integer; // 0 = cartridge header, 1 = export, 2 = Japan
    class function Defaults: TSGOptions; static;
  end;

  TSGConsole = class
  private
    FOptions: TSGOptions;
    FWarmBoot: Boolean;
    FCPU: TZ80State;
    FCallbacks: TZ80ReadAndWriteCallbacks;
    FCartridge: TSGCartridge;
    FModel: TSGModel;
    FSF7000: TSF7000;
    FCassette: TSGCassette;
    FSMSCartridge: TSMSCartridge;
    FFM: TYM2413;
    FFMUnsupportedROM: Boolean; // Derived from ROM identity, not a host preference.
    FPSGDC: array[0..1] of TPCMDCBlocker;
    FWorkRAM: array[0..$1FFF] of Byte;
    FBios: TBytes;
    FMemoryControl, FIOControl, FFMControl, FHCounter: Byte;
    FGGPorts: array[1..5] of Byte;
    FGGSerialCycles: Integer;
    FGGJapaneseHeader: Boolean;
    FVDP: TSGVDP;
    FSound: TSGSound;
    FRAM: array[0..$7FF] of Byte;
    FKeys: TSGHostKeys;
    FInput: TEmulatorInput;
    FSC3000, FPAL, FHold: Boolean;
    FPPI: array[0..2] of Byte;
    FPPIControl: Byte;
    FLine, FLineCycles, FSamplePhase, FSampleCount: Integer;
    FCPUClock, FSampleCountdown: Integer; // Derived timing, not snapshot fields.
    FFrameNumber: UInt64;
    FSamples: TArray<SmallInt>;
    function KeyboardPort(Port: Integer): Byte;
    function JoystickPort(Port: Integer): Byte;
    procedure Advance(Cycles: Integer);
    function GetCPUClock: Integer;
    function GetFPS: Double;
  public
    constructor Create(const Data: TBytes; SC3000: Boolean; PAL: Boolean = False);
    constructor CreateSF7000(const IPL, Disk: TBytes; PAL: Boolean = False; WarmBoot: Boolean = True);
    constructor CreateModel(const Data: TBytes; Model: TSGModel; PAL: Boolean = False; MapperHint: Integer = -1);
    destructor Destroy; override;
    procedure Reset;
    procedure SetInput(const Input: TEmulatorInput; const Keys: TSGHostKeys);
    procedure SetTablet(X, Y: Integer; Pressed: Boolean);
    procedure SetBIOS(const Data: TBytes);
    procedure ApplyOptions(const Options: TSGOptions);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Word): Byte;
    procedure WritePort(Address: Word; Value: Byte);
    function Step: Integer;
    procedure RunFrame;
    procedure SerializeState(State: TStateArchive);
    property VDP: TSGVDP read FVDP;
    property SF7000: TSF7000 read FSF7000;
    property Model: TSGModel read FModel;
    property Cassette: TSGCassette read FCassette;
    property Cartridge: TSGCartridge read FCartridge;
    property SMSCartridge: TSMSCartridge read FSMSCartridge;
    property CPU: TZ80State read FCPU;
    property FrameNumber: UInt64 read FFrameNumber;
    property FramesPerSecond: Double read GetFPS;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleCount;
  end;

implementation

function ReadBus(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TSGConsole(UserData).ReadMemory(Word(Address and $FFFF));
end;

procedure WriteBus(UserData: Pointer; Address, Value: Cardinal);
begin
  TSGConsole(UserData).WriteMemory(Word(Address and $FFFF), Byte(Value and $FF));
end;

function ReadIO(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TSGConsole(UserData).ReadPort(Word(Address and $FFFF));
end;

procedure WriteIO(UserData: Pointer; Address, Value: Cardinal);
begin
  TSGConsole(UserData).WritePort(Word(Address and $FFFF), Byte(Value and $FF));
end;

class function TSGOptions.Defaults: TSGOptions;
begin
  Result := Default(TSGOptions);
  Result.ShowBackground := True;
  Result.ShowSprites := True;
  Result.FMEnabled := True;
  Result.FMVolume := 100;
  for var i := 0 to 3 do
    Result.ChannelVolume[i] := 100;
end;

procedure TSGConsole.ApplyOptions(const Options: TSGOptions);
begin
  FOptions := Options;
  FOptions.FMVolume := EnsureRange(FOptions.FMVolume, 0, 100);
  FVDP.ConfigureDisplay(Options.ShowBackground, Options.ShowSprites, Options.RemoveSpriteLimit);
  FSound.SetVolumes(Options.ChannelVolume);
  if (FSF7000 <> nil) and (FSF7000.Disk <> nil) then
    FSF7000.Disk.WriteProtected := Options.DiskWriteProtected;
end;

constructor TSGConsole.Create(const Data: TBytes; SC3000, PAL: Boolean);
begin
  inherited Create;
  FSC3000 := SC3000;
  if SC3000 then
    FModel := TSGModel.SC3000
  else
    FModel := TSGModel.SG1000;
  FPAL := PAL;
  FCartridge := TSGCartridge.Create(Data);
  FVDP := TSGVDP.Create;
  FSound := TSGSound.Create;
  FCassette := TSGCassette.Create;
  ApplyOptions(TSGOptions.Defaults);
  SetLength(FSamples, 2048 * 2);
  FCallbacks.ReadCallback := ReadBus;
  FCallbacks.WriteCallback := WriteBus;
  FCallbacks.PortReadCallback := ReadIO;
  FCallbacks.PortWriteCallback := WriteIO;
  FCallbacks.UserData := Self;
  Reset;
end;

constructor TSGConsole.CreateSF7000(const IPL, Disk: TBytes; PAL, WarmBoot: Boolean);
begin
  Create(IPL, True, PAL);
  FModel := TSGModel.SF7000;
  FSF7000 := TSF7000.Create(IPL, Disk);
  FWarmBoot := WarmBoot and (SGCRC32(IPL) = $D76810B8);
  Reset;
end;

constructor TSGConsole.CreateModel(const Data: TBytes; Model: TSGModel; PAL: Boolean; MapperHint: Integer);
begin
  var Bytes := Data;
  if (Model in [TSGModel.MasterSystem, TSGModel.MarkIII, TSGModel.GameGear]) and (Length(Data) mod $4000 = 512) then
    Bytes := Copy(Data, 512, Length(Data) - 512);
  Create(Bytes, Model in [TSGModel.SG1000II, TSGModel.SC3000, TSGModel.SC3000H], PAL);
  FModel := Model;
  if Model = TSGModel.GameGear then
    FPAL := False;
  if Model in [TSGModel.MasterSystem, TSGModel.MarkIII, TSGModel.GameGear] then
  begin
    FSMSCartridge := TSMSCartridge.Create(Bytes, MapperHint);
    // These releases probe FM despite missing/incomplete YM2413 drivers.
    // Besides lost sound, Wanted and Walter Payton jump into invalid driver
    // code or loop during initialization. Use their working PSG path.
    // Match the unheadered image, never a filename or an idle FM chip.
    if (Length(Bytes) = $20000) or (Length(Bytes) = $40000) then
      case SGCRC32(Bytes) of
        $32F4B791, // Dinosaur Dooley, The (K)
        $A0CF8B15, // World Cup Italia '90 (sample)
        $5359762D, // Wanted (USA/Europe/Brazil)
        $3D55759B: // Walter Payton Football (USA)
          FFMUnsupportedROM := True;
      end;
    FVDP.Free;
    FVDP := TSMSVDP.Create(Model = TSGModel.MarkIII, Model = TSGModel.GameGear);
    FSound.Free;
    FSound := TSGSound.Create(True);
    for var Offset in [$1FF0, $3FF0, $7FF0] do
      if (Length(Bytes) > Offset + 15) and CompareMem(@Bytes[Offset], PAnsiChar(AnsiString('TMR SEGA')), 8) then
        FGGJapaneseHeader := Bytes[Offset + 15] shr 4 = 5;
    if Model <> TSGModel.GameGear then
      FFM := TYM2413.Create(GetCPUClock);
    Reset;
  end;
end;

destructor TSGConsole.Destroy;
begin
  FSF7000.Free;
  FCassette.Free;
  FSMSCartridge.Free;
  FFM.Free;
  FSound.Free;
  FVDP.Free;
  FCartridge.Free;
  inherited;
end;

function TSGConsole.GetCPUClock: Integer;
begin
  Result := FCPUClock;
end;

function TSGConsole.GetFPS: Double;
begin
  if FPAL then
    Result := GetCPUClock / (228.0 * 313)
  else
    Result := GetCPUClock / (228.0 * 262);
end;

procedure TSGConsole.Reset;
begin
  FCPUClock := 3579545;
  if FPAL then
    FCPUClock := 3546893;
  FCPU := Default(TZ80State);
  Z80StateInitialise(FCPU);
  FCPU.StackPointer := $FFFF;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FCartridge.Reset;
  FVDP.Reset;
  FSound.Reset;
  FillChar(FPPI, SizeOf(FPPI), 0);
  FPPIControl := $9B;
  FLine := 0;
  FLineCycles := 0;
  FSamplePhase := 0;
  FSampleCountdown := (FCPUClock + 44099) div 44100;
  FSampleCount := 0;
  FFrameNumber := 0;
  for var Channel := 0 to 1 do
  begin
    FPSGDC[Channel].Configure(44100, 20);
    FPSGDC[Channel].Reset;
  end;
  FHold := False;
  if FSF7000 <> nil then
    FSF7000.Reset;
  FillChar(FWorkRAM, SizeOf(FWorkRAM), 0);
  if FSMSCartridge <> nil then
    FSMSCartridge.Reset;
  if FFM <> nil then
    FFM.Reset;
  FMemoryControl := $A8;
  FIOControl := $FF;
  FFMControl := 0;
  FHCounter := 0;
  FGGPorts[1] := $7F;
  FGGPorts[2] := $FF;
  FGGPorts[3] := 0;
  FGGPorts[4] := $FF;
  FGGPorts[5] := 0;
  FGGSerialCycles := 0;
  if Length(FBios) > 0 then
    FMemoryControl := $A0;
  ApplyOptions(FOptions);
  if (FSF7000 <> nil) and FWarmBoot then
  begin
    // Use the IPL's warm-boot entry after its normal PPI initialization.
    WritePort($DF, $92);
    WritePort($E7, $90);
    WritePort($E6, 3);
    FCPU.StackPointer := $FF00;
    FCPU.ProgramCounter := $30;
  end;
end;

procedure TSGConsole.SetInput(const Input: TEmulatorInput; const Keys: TSGHostKeys);
begin
  FInput := Input;
  FKeys := Keys;
  var Hold := (TEmulatorButton.Start in Input.Buttons) or (FSC3000 and Keys[vkF10]);
  if (FModel <> TSGModel.GameGear) and Hold and not FHold then
    Z80NonMaskableInterrupt(FCPU);
  FHold := Hold;
end;

procedure TSGConsole.SetTablet(X, Y: Integer; Pressed: Boolean);
begin
  FCartridge.SetTablet(X, Y, Pressed);
end;

procedure TSGConsole.SetBIOS(const Data: TBytes);
begin
  if (Length(Data) <> 0) and (Length(Data) <> $2000) and (Length(Data) <> $4000) and (Length(Data) <> $8000) then
    raise EReadError.Create('SMS BIOS must contain 8, 16 or 32 KiB');

  FBios := Copy(Data);
  Reset;
end;

function TSGConsole.ReadMemory(Address: Word): Byte;
begin
  if FSF7000 <> nil then
    Exit(FSF7000.ReadMemory(Address));

  if FSMSCartridge <> nil then
  begin
    if Address >= $C000 then
    begin
      if FSMSCartridge.ExpandedRAM then
        Exit(FSMSCartridge.Read(Address));

      if FMemoryControl and $10 <> 0 then
        Exit($FF);

      Exit(FWorkRAM[Address and $1FFF]);
    end;
    if (FMemoryControl and 8 = 0) and (Length(FBios) > 0) and (Address < Length(FBios)) then
      Exit(FBios[Address]);

    if FMemoryControl and $40 <> 0 then
      Exit($FF);

    Exit(FSMSCartridge.Read(Address));
  end;

  if (Address < $C000) or FCartridge.OverridesSystemRAM then
    Exit(FCartridge.Read(Address));

  if (FModel in [TSGModel.SC3000, TSGModel.SC3000H, TSGModel.Multivision]) then
    Result := FRAM[Address and $7FF]
  else
    Result := FRAM[Address and $3FF];
end;

procedure TSGConsole.WriteMemory(Address: Word; Value: Byte);
begin
  if FSF7000 <> nil then
  begin
    FSF7000.WriteMemory(Address, Value);
    Exit;
  end;

  if FSMSCartridge <> nil then
  begin
    FSMSCartridge.Write(Address, Value);
    if (Address >= $C000) and (FMemoryControl and $10 = 0) then
      FWorkRAM[Address and $1FFF] := Value;
    Exit;
  end;

  FCartridge.Write(Address, Value);
  if (Address >= $C000) and not FCartridge.OverridesSystemRAM then
  begin
    if FModel in [TSGModel.SC3000, TSGModel.SC3000H, TSGModel.Multivision] then
      FRAM[Address and $7FF] := Value
    else
      FRAM[Address and $3FF] := Value;
  end;
end;

function TSGConsole.JoystickPort(Port: Integer): Byte;
const
  Buttons: array[0..5] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B);
begin
  var First := $3F;
  var Second := $3F;
  for var i := 0 to 5 do
  begin
    if Buttons[i] in FInput.Buttons then
      First := First and ($3F xor (1 shl i));
    if Buttons[i] in FInput.Buttons2 then
      Second := Second and ($3F xor (1 shl i));
  end;
  if Port = 0 then
    Result := First or ((Second and 3) shl 6)
  else
    Result := $F0 or (Second shr 2);
end;

function TSGConsole.KeyboardPort(Port: Integer): Byte;
const
  // SC-3000/SK-1100 contacts, host virtual-key codes. $FF is an unused contact.
  PA: array[0..6, 0..7] of Byte = (
    ($31, $51, $41, $5A, $A5, $BC, $4B, $49),
    ($32, $57, $53, $58, $20, $BE, $4C, $4F),
    ($33, $45, $44, $43, $2D, $BF, $BA, $50),
    ($34, $52, $46, $56, $2E, $E2, $DE, $C0),
    ($35, $54, $47, $42, $FF, $28, $DD, $DB),
    ($36, $59, $48, $4E, $FF, $25, $0D, $FF),
    ($37, $55, $4A, $4D, $FF, $27, $26, $FF));
  PB: array[0..6, 0..3] of Byte = (
    ($38, $FF, $FF, $FF), ($39, $FF, $FF, $FF), ($30, $FF, $FF, $FF),
    ($BD, $FF, $FF, $FF), ($BB, $FF, $FF, $FF), ($DC, $FF, $FF, $09),
    ($1B, $12, $11, $10));
begin
  var Row := FPPI[2] and 7;
  if Row = 7 then
    Exit(JoystickPort(Port));

  if Port = 0 then
  begin
    Result := $FF;
    for var i := 0 to 7 do
      if (PA[Row, i] <> $FF) and FKeys[PA[Row, i]] then
        Result := Result and ($FF xor (1 shl i));
  end
  else
  begin
    // No cassette signal; printer is idle, /CONT and /FAULT are high.
    Result := $3F;
    if FCassette.Input then
      Result := Result or $80;
    for var i := 0 to 3 do
      if (PB[Row, i] <> $FF) and FKeys[PB[Row, i]] then
        Result := Result and ($FF xor (1 shl i));
  end;
end;

function TSGConsole.ReadPort(Address: Word): Byte;
begin
  var Port := Address and $FF;
  if FSMSCartridge <> nil then
  begin
    if FModel = TSGModel.GameGear then
    begin
      case Port of
        0:
          begin
            var Japanese := (FOptions.GGRegion = 2) or ((FOptions.GGRegion = 0) and FGGJapaneseHeader);
            Exit((Ord(not (TEmulatorButton.Start in FInput.Buttons)) shl 7) or (Ord(not Japanese) shl 6));
          end;
        1:
          Exit((FGGPorts[1] and ($FF xor FGGPorts[2])) or (FGGPorts[2] and $7F));
        2, 3, 4:
          Exit(FGGPorts[Port]);
        5:
          Exit(FGGPorts[5] or 4); // No peer connected; receive buffer stays empty.
          6:
          Exit($FF); // Stereo register is write-only.
      end;

      if Port >= $C0 then
      begin
        if not (Port in [$C0, $C1, $DC, $DD]) then
          Exit($FF);
        if FMemoryControl and 4 <> 0 then
          Exit($FF);
        if Port and 1 <> 0 then
          Exit($FF);
        Exit(JoystickPort(0) or $C0);
      end;
    end;

    if Port = $F2 then
      if FOptions.FMEnabled and not FFMUnsupportedROM then
        Exit(FFMControl and 3)
      else
        Exit($FF);

    case Port of
      $40..$7F:
        if Port and 1 = 0 then
          Exit(TSMSVDP(FVDP).VCounter(FLine, FPAL))
        else
          Exit(FHCounter);
      $C0..$FF:
        begin
          if FMemoryControl and 4 <> 0 then
            Exit($FF);
          var Value := JoystickPort(Port and 1);
          if Port and 1 = 0 then
          begin
            if FIOControl and 1 = 0 then
              Value := (Value and $DF) or ((FIOControl and $10) shl 1);
          end
          else
          begin
            if FIOControl and 4 = 0 then
              Value := (Value and $F7) or ((FIOControl and $40) shr 3);
            if FIOControl and 2 = 0 then
              Value := (Value and $BF) or ((FIOControl and $20) shl 1);
            if FIOControl and 8 = 0 then
              Value := (Value and $7F) or (FIOControl and $80);
            if FKeys[vkF10] then
              Value := Value and $EF;
          end;
          Exit(Value);
        end;
    end;
  end;

  if (FSF7000 <> nil) and (Port >= $E0) then
    Exit(FSF7000.ReadPort(Port));

  if (FModel = TSGModel.Multivision) and (Port >= $C0) then
  begin
    Result := $FF;
    case Port and 7 of
      0, 1, 2, 3:
        begin
          var Base := Ord('1');
          var Count := 6;
          if Port and 7 = 1 then
          begin
            Base := Ord('7');
            Count := 4;
          end;
          if Port and 7 = 2 then
            Base := Ord('A');
          if Port and 7 = 3 then
          begin
            Base := Ord('G');
            Count := 2;
          end;
          for var i := 0 to Count - 1 do
          begin
            var Key := Base + i;
            if Key = Ord(':') then
              Key := Ord('0');
            if FKeys[Key] then
              Result := Result and ($FF xor (1 shl i));
          end;
        end;
      4:
        Result := JoystickPort(0);
      5:
        Result := JoystickPort(1);
    end;
    Exit;
  end;

  Result := $FF;
  if (Port >= $80) and (Port <= $BF) then
  begin
    if Port and 1 = 0 then
      Result := FVDP.ReadData
    else
      Result := FVDP.ReadStatus;
    Exit;
  end;

  if (Port < $DC) or (Port > $DF) then
    Exit;

  if not FSC3000 then
  begin
    Result := JoystickPort(Port and 1);
    Exit;
  end;

  case Port and 3 of
    0:
      if FPPIControl and $10 <> 0 then
        Result := KeyboardPort(0)
      else
        Result := FPPI[0];
    1:
      if FPPIControl and 2 <> 0 then
        Result := KeyboardPort(1)
      else
        Result := FPPI[1];
    2:
      begin
        Result := FPPI[2];
        if FPPIControl and 8 <> 0 then
          Result := Result or $F0;
        if FPPIControl and 1 <> 0 then
          Result := Result or $0F;
      end;
    3:
      Result := $FF; // 8255 control register is write-only.
  end;
end;

procedure TSGConsole.WritePort(Address: Word; Value: Byte);
begin
  var Port := Address and $FF;
  if FSMSCartridge <> nil then
  begin
    if FModel = TSGModel.GameGear then
    begin
      case Port of
        0:
          Exit;
        1, 2:
          begin
            FGGPorts[Port] := Value;
            Exit;
          end;
        3:
          begin
            FGGPorts[3] := Value;
            if FGGPorts[5] and $30 = $30 then
            begin
              FGGPorts[5] := FGGPorts[5] or 1;
              case FGGPorts[5] shr 6 of
                0:
                  FGGSerialCycles := GetCPUClock div 480;
                1:
                  FGGSerialCycles := GetCPUClock div 240;
                2:
                  FGGSerialCycles := GetCPUClock div 120;
                3:
                  FGGSerialCycles := GetCPUClock div 30;
              end;
            end;
            Exit;
          end;
        4:
          Exit;
        5:
          begin
            FGGPorts[5] := (Value and $F8) or (FGGPorts[5] and 1);
            Exit;
          end;
        6:
          begin
            FSound.SetStereo(Value);
            Exit;
          end;
        $F0..$F2:
          Exit;
      end;
    end;
    case Port of
      $00..$3F:
        begin
          if Port and 1 = 0 then
            FMemoryControl := Value
          else
          begin
            var OldA := (FIOControl and 2 <> 0) or (FIOControl and $20 <> 0);
            var OldB := (FIOControl and 8 <> 0) or (FIOControl and $80 <> 0);
            var NewA := (Value and 2 <> 0) or (Value and $20 <> 0);
            var NewB := (Value and 8 <> 0) or (Value and $80 <> 0);
            if (not OldA and NewA) or (not OldB and NewB) then
              FHCounter := TSMSVDP(FVDP).HCounter(FLineCycles);
            FIOControl := Value;
          end;
          Exit;
        end;
      $F0, $F1:
        begin
          if FOptions.FMEnabled and not FFMUnsupportedROM then
            FFM.WritePort(Port and 1, Value);
          Exit;
        end;
      $F2:
        begin
          if FOptions.FMEnabled and not FFMUnsupportedROM then
          begin
            FFMControl := Value and 3;
            if FModel = TSGModel.MarkIII then
              FFMControl := FFMControl and 1;
          end;
          Exit;
        end;
    end;
  end;

  if (FSF7000 <> nil) and (Port >= $E0) then
  begin
    FSF7000.WritePort(Port, Value);
    Exit;
  end;

  FCartridge.WritePort(Port, Value);
  if (Port >= $40) and (Port <= $7F) then
    FSound.Write(Value)
  else if (Port >= $80) and (Port <= $BF) then
  begin
    if Port and 1 = 0 then
    begin
      if FSMSCartridge <> nil then
        TSMSVDP(FVDP).FlushPalette(FLine, FLineCycles);
      FVDP.WriteData(Value);
    end
    else
      FVDP.WriteControl(Value);
  end
  else if FSC3000 and (Port >= $DC) and (Port <= $DF) then
    case Port and 3 of
      0, 1:
        FPPI[Port and 3] := Value;
      2:
        FPPI[2] := Value;
      3:
        if Value and $80 <> 0 then
        begin
          FPPIControl := Value;
          FillChar(FPPI, SizeOf(FPPI), 0);
        end
        else
        begin
          var Bit := (Value shr 1) and 7;
          if Value and 1 <> 0 then
            FPPI[2] := FPPI[2] or (1 shl Bit)
          else
            FPPI[2] := FPPI[2] and ($FF xor (1 shl Bit));
        end;
    end;
  if FSC3000 then
    FCassette.SetOutput(FPPI[2] and $10 <> 0);
end;

procedure TSGConsole.Advance(Cycles: Integer);
begin
  // Advance only to the next raster/audio event; retain exact T-state phases
  // and instruction overshoot without looping through every individual clock.
  while Cycles > 0 do
  begin
    var Chunk := Cycles;
    if Chunk > 228 - FLineCycles then
      Chunk := 228 - FLineCycles;
    if Chunk > FSampleCountdown then
      Chunk := FSampleCountdown;
    Dec(Cycles, Chunk);
    FSound.Advance(Chunk);
    if FGGSerialCycles > 0 then
    begin
      FGGSerialCycles := Max(0, FGGSerialCycles - Chunk);
      if FGGSerialCycles = 0 then
        FGGPorts[5] := FGGPorts[5] and $FE;
    end;
    if FSF7000 <> nil then
      FSF7000.Advance(Chunk);
    FCassette.Advance(Chunk, GetCPUClock);
    Dec(FSampleCountdown, Chunk);
    Inc(FSamplePhase, Chunk * 44100);
    if FSampleCountdown = 0 then
    begin
      Dec(FSamplePhase, FCPUClock);
      FSampleCountdown := (FCPUClock - FSamplePhase + 44099) div 44100;
      if FSampleCount >= Length(FSamples) div 2 then
        raise EInvalidOpException.Create('SG-1000 audio frame buffer exhausted');

      var Sample: SmallInt := 0;
      if FModel <> TSGModel.GameGear then
      begin
        Sample := FSound.Sample;
        // Keep the PSG DAC level internally, including PCM volume modulation.
        // Model AC coupling at its output, before mixing with FM.
        if FSMSCartridge <> nil then
          Sample := EnsureRange(Round(FPSGDC[0].Process(Sample)), -32768, 32767);
      end;
      if FFM <> nil then
      begin
        var Left, Right: SmallInt;
        FFM.Sample(Left, Right);
        var Mixed := Integer(Sample);
        if FOptions.FMEnabled and not FFMUnsupportedROM then
        begin
          // SMS: $00 = PSG, $01 = FM, $02 = mute, $03 = PSG + FM.
          // Mark III's external FM unit selects PSG or FM exclusively.
          if ((FModel = TSGModel.MarkIII) and (FFMControl and 1 <> 0)) or
            ((FModel <> TSGModel.MarkIII) and (FFMControl in [1, 2])) then
            Mixed := 0;
          if FFMControl and 1 <> 0 then
            Inc(Mixed, Integer(Left) * FOptions.FMVolume div 100);
        end;
        Sample := System.Math.EnsureRange(Mixed, -32768, 32767);
      end;
      FSamples[FSampleCount * 2] := Sample;
      FSamples[FSampleCount * 2 + 1] := Sample;
      if FModel = TSGModel.GameGear then
      begin
        FSound.SampleStereo(FSamples[FSampleCount * 2], FSamples[FSampleCount * 2 + 1]);
        for var Channel := 0 to 1 do
          FSamples[FSampleCount * 2 + Channel] := EnsureRange(
              Round(FPSGDC[Channel].Process(FSamples[FSampleCount * 2 + Channel])), -32768, 32767);
      end;
      Inc(FSampleCount);
    end;
    Inc(FLineCycles, Chunk);
    if FLineCycles = 228 then
    begin
      FLineCycles := 0;
      if FLine < FVDP.ScreenHeight then
        FVDP.RenderLine(FLine);
      if FLine = FVDP.ScreenHeight + 1 then
        FVDP.VBlank;
      FVDP.EndLine(FLine, 262 + Ord(FPAL) * 51);
      Inc(FLine);
      if ((not FPAL) and (FLine = 262)) or (FPAL and (FLine = 313)) then
      begin
        FLine := 0;

        // Explicit modulo arithmetic also works with overflow checking enabled.
        if FFrameNumber = High(UInt64) then
          FFrameNumber := 0
        else
          Inc(FFrameNumber);
      end;
    end;
  end;
end;

function TSGConsole.Step: Integer;
begin
  var IRQ := FVDP.Interrupt;
  // Delay only a newly asserted request. An unacknowledged IRQ from an
  // earlier line must not be deasserted at the next VBlank boundary.
  if (FSMSCartridge <> nil) and (FCPU.InterruptPending = 0) then
    IRQ := TSMSVDP(FVDP).InterruptAt(FLine, FLineCycles);
  Z80Interrupt(FCPU, Ord(IRQ));
  Result := Z80DoInstruction(FCPU, FCallbacks);
  Advance(Result);
end;

procedure TSGConsole.RunFrame;
begin
  FSampleCount := 0;
  var Frame := FFrameNumber;
  repeat
    Step
  until FFrameNumber <> Frame;
end;

procedure TSGConsole.SerializeState(State: TStateArchive);
begin
  var Region := FPAL;
  State.Field(Region, SizeOf(Region));
  if State.Loading and (Region <> FPAL) then
    raise EReadError.Create('Snapshot TV region differs from the current configuration');

  var Model := FModel;
  State.Field(Model, SizeOf(Model));
  if State.Loading and (Model <> FModel) then
    raise EReadError.Create('Snapshot machine model differs');

  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FPPI, SizeOf(FPPI));
  State.Field(FPPIControl, SizeOf(FPPIControl));
  State.Field(FHold, SizeOf(FHold));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineCycles, SizeOf(FLineCycles));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  FCartridge.SerializeState(State);
  FVDP.SerializeState(State);
  FSound.SerializeState(State, FModel = TSGModel.GameGear);
  if FSF7000 <> nil then
    FSF7000.SerializeState(State);
  FCassette.SerializeState(State);

  if FSMSCartridge <> nil then
  begin
    FSMSCartridge.SerializeState(State);
    if FFM <> nil then
      FFM.SerializeState(State);

    if FModel = TSGModel.GameGear then
    begin
      State.Field(FGGPorts, SizeOf(FGGPorts));
      State.Field(FGGSerialCycles, SizeOf(FGGSerialCycles));
      if State.Loading and ((FGGSerialCycles < 0) or (FGGSerialCycles > GetCPUClock div 30)) then
        raise EReadError.Create('Invalid Game Gear serial state');
    end;

    State.Field(FWorkRAM, SizeOf(FWorkRAM));
    State.Field(FMemoryControl, SizeOf(FMemoryControl));
    State.Field(FIOControl, SizeOf(FIOControl));
    State.Field(FFMControl, SizeOf(FFMControl));
    State.Field(FHCounter, SizeOf(FHCounter));
    State.Field(FPSGDC, SizeOf(FPSGDC));
  end;

  if State.Loading then
  begin
    FSampleCount := 0;
    if (FLine < 0) or (FLine >= 262 + Ord(FPAL) * 51) or
      (FLineCycles < 0) or (FLineCycles >= 228) or
      (FSamplePhase < 0) or (FSamplePhase >= GetCPUClock) or
      (FCPU.RegisterMode > 2) or (FCPU.InterruptMode > 2) then
      raise EReadError.Create('Invalid SG-1000/SC-3000 snapshot state');

    FSampleCountdown := (FCPUClock - FSamplePhase + 44099) div 44100;
  end;
end;

initialization
  MD.Z80.ConstantInitialise;

end.

