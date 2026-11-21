unit A8.Machine;

interface

uses
  System.SysUtils, A5200.Console, A5200.Types, A5200.CPU, A5200.ANTIC,
  A5200.GTIA, A8.Media, A8.POKEY, Core.Emulation.Types, Core.Snapshots,
  Core.InputConfig, Core.Storage;

type
  TA8Model = (Atari400, Atari800, Atari600XL, Atari800XL, Atari1200XL, Atari65XE, Atari130XE, Atari800XE, AtariXEGS);

  TA8Options = record
    Model: TA8Model;
    PAL, Basic, WriteProtected: Boolean;
    Mapper: Integer;
    OSROM, BasicROM, GameROM, FallbackOSROM: TBytes;
  end;

  TA8PIA = record
    Data, Direction, Control: Byte;
    C2Transition, C2Low: Boolean;
    function Pins(Inputs: Byte): Byte;
    function IRQ: Boolean;
    procedure WriteControl(Value: Byte; PortB: Boolean);
    function Read(Inputs: Byte): Byte;
    procedure Write(Value: Byte);
  end;

  TA8Machine = class(TAtariFrameMachine)
  private
    FOptions: TA8Options;
    FCPU: TCPU5200;
    FANTIC: TA5200ANTIC;
    FGTIA: TA5200GTIA;
    FPOKEY: TA8POKEY;
    FPots: TA8Pots;
    FPaddlePorts: array[0..3] of Boolean;
    FMedia: TA8Media;
    FRAM: array[0..$1FFFF] of Byte;
    FOS, FPrimaryOS, FBasic: TBytes;
    FUsingFallbackOS: Boolean;
    FBus, FConsole: Byte;
    FBootOption, FKeyboardConnected: Boolean;
    FPIA: array[0..1] of TA8PIA;
    FInput: TEmulatorInput;
    FLegacy, FResetKey, FResetPending, FXexActive: Boolean;
    FRAMSize, FLines, FXexSegment: Integer;
    FClock: Double;
    FBasicStartPending, FTapeStartPending, FTapeRunPending: Boolean;
    FHostKeyboard: Word;
    FClockHz: Integer;
    FBasicFileChannel, FBasicFileOffset: Integer;
    function PortB: Byte;
    function Stick(Port: Integer): Byte;
    function Trigger(Port: Integer): Byte;
    procedure AccessCartControl(Address: Word; Value: Byte; Writing: Boolean);
    function VideoRead(Address: Word): Byte;
    function RamAddress(Address: Word; Video: Boolean): Integer;
    function MemoryRead(Address: Word; Video: Boolean): Byte;
    procedure LoadExecutable;
    procedure ServiceBasicCIO;
  public
    constructor Create(const Data: TBytes; const Extension: string; const Options: TA8Options);
    destructor Destroy; override;
    procedure Reset; override;
    procedure SetInput(const Input: TEmulatorInput); override;
    procedure SetKeyboard(Keys: Word); override;
    procedure SetInputPorts(const Ports: TCoreInputPorts); override;
    procedure AttachDisk(const Storage: IStorage; const DiskCopy: string);
    procedure FlushMedia; override;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    procedure RunFrame; override;
    procedure SerializeState(State: TStateArchive); override;
    function GetRate: Double; override;
    property CPU: TCPU5200 read FCPU;
  end;

const
  A8ResetKey = $400;
  A8StartKey = $800;
  A8SelectKey = $1000;
  A8OptionKey = $2000;

implementation

uses
  System.Classes, System.UITypes, System.Math, A8.Firmware, NES.CPU;

function TA8PIA.Pins(Inputs: Byte): Byte;
begin
  Result := (Data and Direction) or (Inputs and not Direction);
end;

function TA8PIA.Read(Inputs: Byte): Byte;
begin
  if Control and 4 = 0 then
    Result := Direction
  else
  begin
    Control := Control and $3F;
    Result := Pins(Inputs);
  end;
end;

function TA8PIA.IRQ: Boolean;
begin
  Result := (Control and $81 = $81) or (Control and $68 = $48);
end;

procedure TA8PIA.WriteControl(Value: Byte; PortB: Boolean);
begin
  var Flags := Control and $C0;
  case (Value shr 3) and 7 of
    0..3:
      begin
        if C2Transition and (PortB or (Value and $10 <> 0)) then
          Flags := Flags or $40;
        C2Transition := False;
        C2Low := False;
      end;
    5:
      begin
        C2Transition := False;
        C2Low := False;
      end;
    6:
      begin
        C2Transition := not PortB;
        C2Low := True;
      end;
    7:
      begin
        if PortB then
          C2Transition := C2Transition or C2Low;
        C2Low := False;
      end;
  end;
  if Value and $20 <> 0 then
    Flags := Flags and $80;
  Control := (Value and $3F) or Flags;
end;

procedure TA8PIA.Write(Value: Byte);
begin
  if Control and 4 = 0 then
    Direction := Value
  else
    Data := Value;
end;

constructor TA8Machine.Create(const Data: TBytes; const Extension: string; const Options: TA8Options);
begin
  inherited Create;
  FOptions := Options;
  FKeyboardConnected := True;
  FLegacy := Options.Model in [TA8Model.Atari400, TA8Model.Atari800];
  case Options.Model of
    TA8Model.Atari400, TA8Model.Atari600XL:
      FRAMSize := $4000;
    TA8Model.Atari800:
      FRAMSize := $C000;
  else
    FRAMSize := $10000;
  end;
  if Options.PAL then
  begin
    FLines := 312;
    FClock := 1773447.0;
  end
  else
  begin
    FLines := 262;
    FClock := A5200CPUClock;
  end;

  FClockHz := Round(FClock);
  FMedia := TA8Media.Create(Data, Extension, Options.Mapper);
  FOS := Options.OSROM;
  if Length(FOS) = 0 then
    FOS := AtariOS(FLegacy);
  FPrimaryOS := FOS;
  if not FLegacy and (Options.Model <> TA8Model.Atari1200XL) then
  begin
    FBasic := Options.BasicROM;
    if Length(FBasic) = 0 then
      FBasic := AtariBasic;
  end
  else if FLegacy and (FMedia.Kind = TA8MediaKind.Cassette) then
    // The 400/800 has no internal BASIC, but can boot tape with a BASIC cart in its left slot.
    FBasic := Options.BasicROM;
  if (FMedia.Kind = TA8MediaKind.BasicProgram) and (Length(FBasic) = 0) then
    raise EReadError.Create('Atari BASIC programs require a model with a built-in BASIC ROM');
  if not (Options.Model = TA8Model.AtariXEGS) then
    FOptions.GameROM := nil;
  FillChar(FPots, SizeOf(FPots), 228);
  FGTIA := TA5200GTIA.Create(Options.PAL);
  FPOKEY := TA8POKEY.Create(not Options.PAL);
  FANTIC := TA5200ANTIC.Create(VideoRead, FLines);
  FCPU := TCPU5200.Create;
  FCPU.Connect(ReadMemory, WriteMemory);
  FFrame.Width := A5200Width;
  FFrame.Height := A5200Height;
  Reset;
end;

destructor TA8Machine.Destroy;
begin
  FCPU.Free;
  FANTIC.Free;
  FPOKEY.Free;
  FGTIA.Free;
  FMedia.Free;
  inherited;
end;

procedure TA8Machine.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FPIA, SizeOf(FPIA), 0);
  FBus := $FF;
  FConsole := 7;
  FBootOption := not FLegacy and (Length(FBasic) <> 0) and not FOptions.Basic and
    not (FMedia.Kind in [TA8MediaKind.Cartridge, TA8MediaKind.BasicProgram]) and not (FMedia.TapeBasic or FMedia.TapeBootBasic);
  FBasicStartPending := (FMedia.Kind = TA8MediaKind.BasicProgram) or
    ((FMedia.Kind = TA8MediaKind.Cassette) and FMedia.TapeBasic and (Length(FBasic) <> 0));
  FTapeStartPending := FMedia.Kind = TA8MediaKind.Cassette;
  FTapeRunPending := False;
  FHostKeyboard := A8NoKey;
  FBasicFileChannel := -1;
  FBasicFileOffset := 0;
  FResetKey := False;
  FResetPending := False;
  FXexActive := False;
  FXexSegment := 0;
  FMedia.Reset;
  FANTIC.Reset;
  FGTIA.Reset;
  FPOKEY.Reset;
  FCPU.Reset;
  FFrame.FrameNumber := 0;
  FFrame.FramesPerSecond := Rate;
  FFrame.Pixels := nil;
  SetLength(FFrame.Pixels, A5200Width * A5200Height);
  for var I := 0 to High(FFrame.Pixels) do
    FFrame.Pixels[I] := $FF000000;
end;

procedure TA8Machine.AttachDisk(const Storage: IStorage; const DiskCopy: string);
begin
  FMedia.AttachDisk(Storage, DiskCopy, FOptions.WriteProtected);
end;

procedure TA8Machine.FlushMedia;
begin
  FMedia.Flush;
end;

procedure TA8Machine.SetInputPorts(const Ports: TCoreInputPorts);
begin
  if FOptions.Model = TA8Model.AtariXEGS then
  begin
    FKeyboardConnected := Ports.KeyboardEnabled;
    if not FKeyboardConnected then
      FPOKEY.SetKeyboard(A8NoKey);
  end;
  for var Port := 0 to High(FPaddlePorts) do
  begin
    var Connected := (FLegacy or (Port < 2)) and (Ports.Devices[Port] = 'pad-analog');
    if Connected <> FPaddlePorts[Port] then
    begin
      FPots[Port * 2] := 228 - 114 * Ord(Connected);
      FPots[Port * 2 + 1] := FPots[Port * 2];
      FPaddlePorts[Port] := Connected;
    end;
  end;
end;

procedure TA8Machine.SetInput(const Input: TEmulatorInput);
const
  Decrease: array[0..1] of TEmulatorButton = (TEmulatorButton.Left, TEmulatorButton.Up);
  Increase: array[0..1] of TEmulatorButton = (TEmulatorButton.Right, TEmulatorButton.Down);
begin
  FInput := Input;
  for var Port := 0 to High(FPaddlePorts) do
    if FPaddlePorts[Port] then
      for var Knob := 0 to 1 do
      begin
        var Axis := Input.Analog[Port].X;
        if Knob = 1 then
          Axis := Input.Analog[Port].Y;
        var Index := Port * 2 + Knob;
        if Input.Analog[Port].Valid then
          FPots[Index] := EnsureRange(114 - Round(Axis * 113.0 / 32768), 1, 228)
        else
          FPots[Index] := EnsureRange(FPots[Index] + Round(220 / Rate *
                (Input.ButtonAmount(Port, Decrease[Knob]) - Input.ButtonAmount(Port, Increase[Knob]))), 1, 228);
      end;
end;

procedure TA8Machine.SetKeyboard(Keys: Word);
begin
  FHostKeyboard := Keys;
  if FKeyboardConnected then
    FPOKEY.SetKeyboard(Keys);
  FConsole := 7;
  if (Keys and A8StartKey <> 0) or (TEmulatorButton.Start in FInput.Buttons) then
    FConsole := FConsole and 6;
  if (Keys and A8SelectKey <> 0) or (TEmulatorButton.Select in FInput.Buttons) then
    FConsole := FConsole and 5;
  if (Keys and A8OptionKey <> 0) or (TEmulatorButton.Mode in FInput.Buttons) then
    FConsole := FConsole and 3;
  var ResetPressed := Keys and A8ResetKey <> 0;
  if ResetPressed and not FResetKey then
    FResetPending := True;
  FResetKey := ResetPressed;
end;

function TA8Machine.PortB: Byte;
begin
  Result := FPIA[1].Pins($FF);
end;

function TA8Machine.Stick(Port: Integer): Byte;
begin
  Result := 15;
  if FPaddlePorts[Port] then
    Exit(15 - 4 * Ord(FInput.ButtonAmount(Port, TEmulatorButton.A) >= 0.5)
      - 8 * Ord(FInput.ButtonAmount(Port, TEmulatorButton.B) >= 0.5));
  for var Button := TEmulatorButton.Up to TEmulatorButton.Right do
    if FInput.ButtonAmount(Port, Button) >= 0.5 then
      Result := Result and not (1 shl Ord(Button));
end;

function TA8Machine.Trigger(Port: Integer): Byte;
begin
  if not FLegacy then
    case Port of
      // XEGS uses the otherwise unused third trigger input for keyboard sense.
      2:
        Exit(Ord(FKeyboardConnected));
      3:
        Exit(Ord(FMedia.CartHigh));
    end;
  Result := Ord(FPaddlePorts[Port] or (FInput.ButtonAmount(Port, TEmulatorButton.A) < 0.5));
end;

procedure TA8Machine.AccessCartControl(Address: Word; Value: Byte; Writing: Boolean);
begin
  FMedia.CartControl(Address, Value, Writing);
  // RD5 feeds the GTIA latch even if software never reads TRIG3 while RD5 is low.
  if not FLegacy then
    FGTIA.ReadTrigger(3, Trigger(3));
end;

function TA8Machine.RamAddress(Address: Word; Video: Boolean): Integer;
begin
  Result := Address;
  if (FOptions.Model = TA8Model.Atari130XE) and (Address >= $4000) and (Address < $8000) then
  begin
    var Bank := PortB;
    var EnableBit := $10;
    if Video then
      EnableBit := $20;
    if Bank and EnableBit = 0 then
      Exit($10000 + (((Bank shr 2) and 3) shl 14) + (Address and $3FFF));
  end;
  if Result >= FRAMSize then
    Result := -1;
end;

function TA8Machine.MemoryRead(Address: Word; Video: Boolean): Byte;
begin
  if Address and $F800 = $D000 then
  begin
    case Address shr 8 of
      $D0:
        begin
          var Index := Address and 31;
          case Index of
            $10..$13:
              Exit(FGTIA.ReadTrigger(Index - $10, Trigger(Index - $10)));
            $14:
              if FOptions.PAL then
                Exit(1)
              else
                Exit(15);
            $1F:
              begin
                Result := FConsole and not FGTIA.ConsoleControl;
                if FTapeStartPending and not FMedia.TapeBasic then
                  Result := Result and 6;
                // Let the XEGS OS see SELECT without a simulated OPTION at boot.
                if FBootOption and FKeyboardConnected and
                  ((FOptions.Model <> TA8Model.AtariXEGS) or (FConsole and 2 <> 0)) then
                  Result := Result and 3;
                Exit;
              end;
          end;
          Exit(FGTIA.Read(Index, nil));
        end;
      $D2:
        Exit(FPOKEY.ReadComputer(Address and 15));
      $D3:
        case Address and 3 of
          0:
            begin
              var Inputs := Stick(0) or (Stick(1) shl 4);
              var DataSelected := FPIA[0].Control and 4 <> 0;
              var PortValue := FPIA[0].Read($FF);
              if DataSelected then
                PortValue := PortValue and Inputs;
              Exit(PortValue);
            end;
          1:
            if FLegacy then
              Exit(FPIA[1].Read(Stick(2) or (Stick(3) shl 4)))
            else
              Exit(FPIA[1].Read($FF));
          2:
            Exit(FPIA[0].Control);
          3:
            Exit(FPIA[1].Control);
        end;
      $D4:
        Exit(FANTIC.Read(Address and 15));
      $D5:
        AccessCartControl(Address, FBus, False);
    end;
    Exit(FBus);
  end;
  if FMedia.ReadCart(Address, Result) then
    Exit;
  if FLegacy then
  begin
    if (Length(FBasic) <> 0) and (Address >= $A000) and (Address < $C000) then
      Exit(FBasic[Address - $A000]);
    if Address >= $D800 then
      Exit(FOS[Address - $D800]);
  end
  else
  begin
    var Bank := PortB;
    if Bank and 1 <> 0 then
    begin
      if Address >= $C000 then
        Exit(FOS[Address - $C000]);
      if (Bank and $80 = 0) and (Address >= $5000) and (Address < $5800) then
        Exit(FOS[Address - $4000]);
    end;
    if (Length(FBasic) <> 0) and (Bank and 2 = 0) and (Address >= $A000) and (Address < $C000) then
      Exit(FBasic[Address - $A000]);
    if (Length(FOptions.GameROM) <> 0) and (Bank and $40 = 0) and (Address >= $A000) and (Address < $C000) then
      Exit(FOptions.GameROM[Address - $A000]);
  end;
  var Offset := RamAddress(Address, Video);
  if Offset >= 0 then
    Exit(FRAM[Offset]);
  Result := FBus;
end;

function TA8Machine.ReadMemory(Address: Word): Byte;
begin
  Result := MemoryRead(Address, False);
  FBus := Result;
end;

function TA8Machine.VideoRead(Address: Word): Byte;
begin
  Result := MemoryRead(Address, True);
  FBus := Result;
end;

procedure TA8Machine.WriteMemory(Address: Word; Value: Byte);
begin
  FBus := Value;
  if Address and $F800 = $D000 then
  begin
    case Address shr 8 of
      $D0:
        FGTIA.Write(Address and 31, Value);
      $D2:
        begin
          if Address and 15 = 11 then
            FPOKEY.StartPotScan(FPots);
          FPOKEY.WriteComputer(Address and 15, Value);
        end;
      $D3:
        case Address and 3 of
          0, 1:
            FPIA[Address and 1].Write(Value);
          2:
            begin
              FPIA[0].WriteControl(Value, False);
              if FPIA[0].C2Low then
                FTapeStartPending := False;
            end;
          3:
            begin
              FPIA[1].WriteControl(Value, True);
              FMedia.SetCommandLine(Value and $38 = $30);
            end;
        end;
      $D4:
        FANTIC.Write(Address and 15, Value);
      $D5:
        AccessCartControl(Address, Value, True);
    end;
    Exit;
  end;
  var Ignored: Byte;
  if FMedia.ReadCart(Address, Ignored) or
    (FLegacy and (Length(FBasic) <> 0) and (Address >= $A000) and (Address < $C000)) then
    Exit;
  if not FLegacy then
  begin
    var Bank := PortB;
    if (Bank and 1 <> 0) and ((Address >= $C000) or
      ((Bank and $80 = 0) and (Address >= $5000) and (Address < $5800))) then
      Exit;
    if (Address >= $A000) and (Address < $C000) and
      (((Length(FBasic) <> 0) and (Bank and 2 = 0)) or
      ((Length(FOptions.GameROM) <> 0) and (Bank and $40 = 0))) then
      Exit;
  end;
  var Offset := RamAddress(Address, False);
  if Offset >= 0 then
    FRAM[Offset] := Value;
end;

procedure TA8Machine.LoadExecutable;
begin
  if (FXexSegment = 0) and (FCPU.Pc = A8XexEntry) then
  begin
    FXexActive := True;
    var First := FMedia.Segments[0].Address;
    FRAM[$02E0] := Byte(First);
    FRAM[$02E1] := First shr 8;
  end
  else if not FXexActive or (FCPU.Pc <> A8XexContinue) then
    Exit;

  while FXexSegment < Length(FMedia.Segments) do
  begin
    FRAM[$02E2] := 0;
    FRAM[$02E3] := 0;
    var Segment := FMedia.Segments[FXexSegment];
    Inc(FXexSegment);
    var Data := FMedia.Data;
    for var I := 0 to Segment.Size - 1 do
      WriteMemory(Segment.Address + I, Data[Segment.Offset + I]);
    var Init := FRAM[$02E2] or (Word(FRAM[$02E3]) shl 8);
    if Init <> 0 then
    begin
      // RTS resumes at the second entry after each INITAD callback.
      FRAM[$100 + FCPU.Sp] := A8XexEntry shr 8;
      FCPU.Sp := Byte((Integer(FCPU.Sp) - 1) and $FF);
      FRAM[$100 + FCPU.Sp] := Byte(A8XexEntry and $FF);
      FCPU.Sp := Byte((Integer(FCPU.Sp) - 1) and $FF);
      FCPU.Pc := Init;
      Exit;
    end;
  end;
  FXexActive := False;
  FBootOption := False;
  FCPU.Pc := FRAM[$02E0] or (Word(FRAM[$02E1]) shl 8);
end;

procedure TA8Machine.ServiceBasicCIO;
const
  ProgramName: AnsiString = 'D:START.BAS';
  DiskRun: AnsiString = 'RUN "D:START.BAS"' + #$9B;
  TapeRun: AnsiString = 'RUN "C:"' + #$9B;
  TapeLoadShort: AnsiString = 'CLOAD' + #$9B;
  BasicRun: AnsiString = 'RUN' + #$9B;
  StatementTable = $88;
  StringTable = $8C;
  EndOfFile = 136;
  Success = 1;
begin
  // CIOV, with X indexing one of the eight sixteen-byte IOCBs.
  var Channel := Integer(FCPU.X);
  if (Channel > $70) or (Channel and 15 <> 0) or (not FLegacy and (PortB and 1 = 0)) then
    Exit;
  var IOCB := $0340 + Channel;
  var Operation := FRAM[IOCB + 2];
  var Address := Word(FRAM[IOCB + 4]) or (Word(FRAM[IOCB + 5]) shl 8);
  var Requested := Integer(FRAM[IOCB + 8]) or (Integer(FRAM[IOCB + 9]) shl 8);
  var ReturnPC := Word(FRAM[$100 + ((Integer(FCPU.Sp) + 1) and $FF)]) or
    (Word(FRAM[$100 + ((Integer(FCPU.Sp) + 2) and $FF)]) shl 8);
  var Status: Byte := Success;
  var RunCommand := DiskRun;
  if FMedia.Kind = TA8MediaKind.Cassette then
    if FTapeRunPending then
      RunCommand := BasicRun
    else if FMedia.TapeShortGaps then
      RunCommand := TapeLoadShort
    else
      RunCommand := TapeRun;

  // Supply the first direct-mode line when the built-in BASIC asks the
  // editor for it. BASIC itself parses, relocates and runs the SAVE file.
  if (FBasicStartPending or FTapeRunPending) and (Channel = 0) and (Operation = 5) and
    (ReturnPC >= $A000) and (ReturnPC < $C000) and (FLegacy or (PortB and 2 = 0)) and
    (Requested >= Length(RunCommand)) and (Integer(Address) + Length(RunCommand) <= FRAMSize) then
  begin
    if FTapeRunPending then
    begin
      FTapeRunPending := False;
      // CLOAD has returned to the editor. Run only when its program table
      // agrees with the saved BASIC header.
      var Statements := Word(FRAM[StatementTable]) or (Word(FRAM[StatementTable + 1]) shl 8);
      var Strings := Word(FRAM[StringTable]) or (Word(FRAM[StringTable + 1]) shl 8);
      if (Statements < $100) or (Statements >= $A000) or
        (Integer(Strings) - Statements <> FMedia.TapeBasicStatements) or (FRAM[Statements + 1] >= $80) then
        Exit;
    end
    else
      FTapeRunPending := (FMedia.Kind = TA8MediaKind.Cassette) and FMedia.TapeShortGaps;
    for var I := 1 to Length(RunCommand) do
      WriteMemory(Address + I - 1, Byte(RunCommand[I]));
    FRAM[IOCB + 8] := Length(RunCommand);
    FRAM[IOCB + 9] := 0;
    FBasicStartPending := False;
  end
  else if (FMedia.Kind = TA8MediaKind.BasicProgram) and (Operation = 3) and
    (FBasicFileChannel = -1) and (FRAM[IOCB] = $FF) and
    (FRAM[IOCB + 10] = 4) then
  begin
    if Integer(Address) + Length(ProgramName) >= FRAMSize then
      Exit;
    for var I := 1 to Length(ProgramName) do
      if ReadMemory(Address + I - 1) <> Byte(ProgramName[I]) then
        Exit;
    if not (ReadMemory(Address + Length(ProgramName)) in [0, $9B]) then
      Exit;
    FBasicFileChannel := Channel;
    FBasicFileOffset := 0;
    FRAM[IOCB] := $FE;
    FRAM[IOCB + 1] := 1;
  end
  else if FBasicFileChannel = Channel then
  begin
    case Operation of
      7:
        begin
          var Data := FMedia.BasicData;
          var Count := Min(Max(Requested, 1), Length(Data) - FBasicFileOffset);
          if Count < Max(Requested, 1) then
            Status := EndOfFile;
          if Requested = 0 then
          begin
            if Count = 1 then
              FCPU.A := Data[FBasicFileOffset];
          end
          else
          begin
            for var I := 0 to Count - 1 do
              WriteMemory(Word((Integer(Address) + I) and $FFFF), Data[FBasicFileOffset + I]);
            FRAM[IOCB + 8] := Byte(Count);
            FRAM[IOCB + 9] := Byte(Count shr 8);
          end;
          Inc(FBasicFileOffset, Count);
        end;
      12:
        begin
          FBasicFileChannel := -1;
          FRAM[IOCB] := $FF;
        end;
    else
      Status := 132; // Invalid command for this read-only device.
    end;
  end
  else
    Exit;

  FRAM[IOCB + 3] := Status;
  FCPU.Y := Status;
  FCPU.P := (FCPU.P and not (FLAG_NEGATIVE or FLAG_ZERO)) or (Status and FLAG_NEGATIVE);
  FCPU.Sp := Byte((Integer(FCPU.Sp) + 2) and $FF);
  FCPU.Pc := Word((Integer(ReturnPC) + 1) and $FFFF);
end;

function TA8Machine.GetRate: Double;
begin
  Result := FClock / (A5200CyclesPerLine * FLines);
end;

procedure TA8Machine.RunFrame;
begin
  if FResetPending then
  begin
    FResetPending := False;
    FTapeRunPending := False;
    FXexSegment := 0;
    FXexActive := False;
    FBasicFileChannel := -1;
    FBasicFileOffset := 0;
    if FLegacy then
      FANTIC.SystemReset
    else
    begin
      FillChar(FPIA, SizeOf(FPIA), 0);
      FMedia.SetCommandLine(False);
      FANTIC.Reset;
      FCPU.Reset;
    end;
  end;
  if FKeyboardConnected and (FMedia.Kind = TA8MediaKind.Cassette) then
  begin
    // With the selected tape in PLAY, acknowledge the OS's initial key prompt.
    // Once the motor starts, subsequent keyboard prompts are left to the game.
    var Key := FHostKeyboard;
    if FTapeStartPending and not FBasicStartPending and (Byte(Key) = A8NoKey) and
      (FFrame.FrameNumber >= 24) and (FFrame.FrameNumber < 480) and (FFrame.FrameNumber mod 8 < 2) then
      Key := $21;
    FPOKEY.SetKeyboard(Key);
  end;
  FFrame.Pixels := Copy(FFrame.Pixels);
  FPOKEY.BeginFrame;
  for var Line := 0 to FLines - 1 do
  begin
    for var Port := 0 to 3 do
      FGTIA.ReadTrigger(Port, Trigger(Port));
    FANTIC.BeginLine(Line, FGTIA);
    for var Cycle := 0 to A5200CyclesPerLine - 1 do
    begin
      var Halted := FANTIC.Halted(Cycle);
      if FANTIC.TakeNMI then
        FCPU.TriggerAnticNmi(Halted and FANTIC.WaitingForSync);
      FCPU.SetIrqLine(FPOKEY.IRQ or FPIA[0].IRQ or FPIA[1].IRQ);
      if not Halted or (FCPU.NextCycleIsWrite and not FANTIC.DMAActive) then
      begin
        if (FMedia.Kind = TA8MediaKind.Executable) and (FCPU.CyclesRemaining = 0) and
          ((FCPU.Pc = A8XexEntry) or (FCPU.Pc = A8XexContinue)) then
          LoadExecutable
        else if ((FMedia.Kind = TA8MediaKind.BasicProgram) or FBasicStartPending or FTapeRunPending) and
          (FCPU.CyclesRemaining = 0) and (FCPU.Pc = $E456) then
          ServiceBasicCIO;
        FCPU.Clock;
      end;
      if FCPU.Jammed then
      begin
        if not FUsingFallbackOS and (Length(FOptions.FallbackOSROM) <> 0) and (FFrame.FrameNumber < 120) then
        begin
          // Retry cold boot early with the verified XL ROM. Avoid resetting
          // a running game or overriding an explicitly selected ROM.
          FOS := FOptions.FallbackOSROM;
          FUsingFallbackOS := True;
          var Number := FFrame.FrameNumber;
          Reset;
          FFrame.FrameNumber := Number;
          FSamples := nil;
          Exit;
        end;
        var Detail := Format('Atari 8-bit CPU jam at %.4x', [FCPU.JamPc]);
        if (Length(FOptions.OSROM) = 0) and not FLegacy and FMedia.RequiresOriginalXLOS then
          Detail := Detail + '. This loader uses internal XL/XE OS addresses. Select an original Atari 800XL/XE OS ROM in firmware settings.';
        raise EInvalidOpException.Create(Detail);
      end;
      FANTIC.ClockObjects(Cycle, FGTIA, FBus);
      FPOKEY.ClockComputer(FMedia, FPIA[0].C2Low, FClockHz);
      RenderVideoCycle(FANTIC, FGTIA, Line, Cycle);
    end;
    FANTIC.EndLine;
  end;
  FPOKEY.EndFrame(FSamples);
  Inc(FFrame.FrameNumber);
  if ((FRAM[$244] = 0) and (FFrame.FrameNumber >= 30)) or (FFrame.FrameNumber = 240) then
    FBootOption := False;
end;

procedure TA8Machine.SerializeState(State: TStateArchive);
begin
  var Fallback := FUsingFallbackOS;
  if (State.Version = 0) or (State.Version >= 3) then
    State.Field(Fallback, SizeOf(Fallback))
  else if State.Loading then
    Fallback := False;
  if State.Loading then
  begin
    if Fallback and (Length(FOptions.FallbackOSROM) = 0) then
      raise EReadError.Create('This Atari snapshot requires the original 800XL/XE OS rev 2 ROM');
    FUsingFallbackOS := Fallback;
    if Fallback then
      FOS := FOptions.FallbackOSROM
    else
      FOS := FPrimaryOS;
  end;
  State.Field(FRAM, SizeOf(FRAM));
  if State.Version = 1 then
  begin
    var Ports: array[0..1, 0..2] of Byte;
    for var Port := 0 to 1 do
    begin
      Ports[Port, 0] := FPIA[Port].Data;
      Ports[Port, 1] := FPIA[Port].Direction;
      Ports[Port, 2] := FPIA[Port].Control;
    end;
    State.Field(Ports, SizeOf(Ports));
    if State.Loading then
      for var Port := 0 to 1 do
      begin
        FPIA[Port].Data := Ports[Port, 0];
        FPIA[Port].Direction := Ports[Port, 1];
        FPIA[Port].Control := Ports[Port, 2];
        FPIA[Port].C2Transition := False;
        FPIA[Port].C2Low := FPIA[Port].Control and $38 = $30;
      end;
  end
  else
    State.Field(FPIA, SizeOf(FPIA));
  State.Field(FBus, SizeOf(FBus));
  State.Field(FBootOption, SizeOf(FBootOption));
  State.Field(FPots, SizeOf(FPots));
  State.Field(FXexSegment, SizeOf(FXexSegment));
  State.Field(FXexActive, SizeOf(FXexActive));
  State.Field(FFrame.FrameNumber, SizeOf(UInt64));
  FCPU.SerializeState(State);
  FANTIC.SerializeState(State);
  FGTIA.SerializeState(State);
  FPOKEY.SerializeComputer(State);
  FMedia.SerializeState(State);
  if FMedia.Kind = TA8MediaKind.Cassette then
  begin
    State.Field(FTapeStartPending, SizeOf(FTapeStartPending));
    State.Field(FBasicStartPending, SizeOf(FBasicStartPending));
    if (State.Version = 0) or (State.Version >= 4) then
      State.Field(FTapeRunPending, SizeOf(FTapeRunPending))
    else if State.Loading then
      FTapeRunPending := False;
  end
  else if FMedia.Kind = TA8MediaKind.BasicProgram then
  begin
    State.Field(FBasicStartPending, SizeOf(FBasicStartPending));
    State.Field(FBasicFileChannel, SizeOf(FBasicFileChannel));
    State.Field(FBasicFileOffset, SizeOf(FBasicFileOffset));
    if State.Loading and ((FBasicFileChannel < -1) or (FBasicFileChannel > $70) or
      ((FBasicFileChannel <> -1) and (FBasicFileChannel and 15 <> 0)) or
      (FBasicFileOffset < 0) or (FBasicFileOffset > Length(FMedia.BasicData))) then
      raise EReadError.Create('Invalid Atari BASIC device state');
  end;
  FFrame.Pixels := Copy(FFrame.Pixels);
  State.Field(FFrame.Pixels[0], Length(FFrame.Pixels) * SizeOf(TAlphaColor));
end;

end.

