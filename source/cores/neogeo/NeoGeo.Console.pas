unit NeoGeo.Console;

interface

uses
  System.SysUtils, System.Classes, MD.M68k, MD.Z80, Core.Emulation,
  Core.InputConfig, NeoGeo.Cartridge, NeoGeo.Video, NeoGeo.Sound, Core.Snapshots;

type
  TNeoGeoConsole = class
  private
    FCart: TNeoGeoCartridge;
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
    FBatteryDirty: Boolean;
    FWatchdog: Integer;
    FRTCControl, FRTCCommand, FRTCBits: Integer;
    FRTCShift: UInt64;
    FRTCReading: Boolean;
    FRTCMode, FRTCTPPeriod: Integer;
    FRTCEpoch, FRTCTestBase: Int64;
    FRTCCalendar: UInt64;
    FRTCTesting: Boolean;
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
    function ROMByte(const Data: TBytes; Address: Integer): Byte;
    function PadByte(const Buttons: TEmulatorButtons): Byte;
    procedure UpdateIRQ;
    procedure SyncSound(Target: Int64);
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
    function BatteryData: TBytes;
    function ReadWord(Address: Cardinal): Word;
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
end;

procedure CPUWrite(UserData: Pointer; Address: Cardinal; DoHighByte, DoLowByte: Byte; CurrentCycle: Cardinal; var TerminateEarly: Byte; Value: Cardinal);
begin
  var C := TNeoGeoConsole(UserData);
  C.FBusTime := C.FCPUBase + Int64(CurrentCycle) * 2;
  C.WriteBus((Address and $7FFFFF) shl 1, Word(Value and $FFFF), DoHighByte <> 0, DoLowByte <> 0);
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
  Sound.Free;
  Video.Free;
  inherited;
end;

procedure TNeoGeoConsole.Reset;
begin
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
  if FCart.Protection = 'kf2k3bl' then
    FBootOverlay := 0;
  if FCart.Protection = 'kof10th' then
  begin
    FCart.FixedROM := Copy(FInitialFixed);
    for var I := 0 to High(FCartRAM) do
      FCartRAM[I] := Word(Integer(ROMByte(FCart.ProgramROM, $E0000 + I * 2)) * 256 + ROMByte(FCart.ProgramROM, $E0001 + I * 2));
  end;
  FillChar(FPvcRAM, SizeOf(FPvcRAM), 0);
  FBanks[0] := $F000;
  FBanks[1] := $E000;
  FBanks[2] := $C000;
  FBanks[3] := $8000;
  FCartVectors := False;
  FCartAudio := False;
  FBackupUnlocked := False;
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
  FFrameTime := 0;
  FFrameNumber := 0;
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
  FRTCCalendar := UInt64($16) shl 32 or (UInt64(1) shl 24);
  FRTCTesting := False;
  Video.Reset;
  Sound.Reset;
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
  for var I := 0 to 7 do
    if Mapping[I] in Buttons then
      Result := Byte(Result and ($FF xor (1 shl I)));
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
  Clown68000Interrupt(FCPU, Level);
end;

procedure TNeoGeoConsole.SyncSound(Target: Int64);
begin
  while FSoundTime < Target do
  begin
    var Count := Integer(Min(Int64(4096), Target - FSoundTime));
    Sound.Advance(Count);
    Inc(FSoundTime, Count);
  end;
end;

procedure TNeoGeoConsole.SyncZ80(Target: Int64);
begin
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
  if Address >= $F800 then
    Exit(FZRAM[Address and $7FF]);
  if Address < $8000 then
  begin
    if FCartAudio then
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
    FBanks[Bank] := ((Address shr 8) * ($800 shl Bank)) and
      ((Length(FCart.AudioROM) - 1) and (not Mask));
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
    for var I := 0 to 5 do
    begin
      var Counter := (((FRTCCalendar shr (I * 8)) and $FF) + UInt64(Ticks)) and $FF;
      Result := Result or (Counter shl (I * 8));
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
    for var I := 0 to 5 do
      if ((Counter shr (I * 8)) and $FF) = 0 then
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
  Result := Word(((GBD and 3) shl 6) or ((GBD and 12) shl 2) or
    ((GAD and 3) shl 2) or ((GAD and 12) shr 2));
end;

procedure TNeoGeoConsole.FuryWrite(Address: Cardinal; Value: Word);
begin
  if (Address and 2) <> 0 then
    FFuryShift := (WireBits((Address shr 4) and $FFFF, [15, 11, 14, 10, 13, 9, 12, 8, 7, 3, 6, 2, 5, 1, 4, 0]) shl 16) or
      WireBits(Value, [15, 11, 14, 10, 13, 9, 12, 8, 7, 3, 6, 2, 5, 1, 4, 0])
  else if (Address and 8) <> 0 then
    FFuryShift := (FFuryShift and $3F3F3F3F) shl 2
  else
    FFuryShift := (FFuryShift shr 2) and $3F3F3F3F;
end;

function TNeoGeoConsole.HasBootRAM: Boolean;
begin
  Result := (FCart.Protection = 'kf2k3bl') or (FCart.Protection = 'kf2k3pl') or
    (FCart.Protection = 'kf2k3upl') or (FCart.Protection = 'kof10th');
end;

function TNeoGeoConsole.ExtraRead(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := True;
  var Kind := FCart.Protection;
  if HasBootRAM and (Address >= $2FE000) and (Address <= $2FFFFE) then
    Value := FPvcRAM[(Address - $2FE000) shr 1]
  else if ((Kind = 'kf2k3bl') or (Kind = 'kf2k3upl')) and (Address = $58196) then
    Value := FBootOverlay
  else if (Kind = 'ms5plus') and (Address >= $2FFFF0) and (Address <= $2FFFFE) then
    Value := $A0
  else if (Kind = 'kog') and (Address = $FFFFE) then
    Value := 1 // English jumper.
  else if (Kind = 'kof10th') and (Address >= $E0000) and (Address <= $FFFFE) then
    Value := FCartRAM[(Address - $E0000) shr 1]
  else if (Kind = 'kof10th') and (Address >= $10000) and (Address < $E0000) then
  begin
    var A := Integer(Address) + FSpecialBank;
    Value := Word(Integer(ROMByte(FCart.ProgramROM, A)) * 256 + ROMByte(FCart.ProgramROM, A + 1));
  end
  else if ((Kind = 'jockeygp') or (Kind = 'vliner')) and (Address >= $200000) and (Address <= $201FFE) then
    Value := FCartRAM[(Address - $200000) shr 1]
  else if (Kind = 'vliner') and (Address = $280000) then
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
  else if (Kind = 'vliner') and (Address = $2C0000) then
    Value := $0003
  else
    Result := False;
end;

function TNeoGeoConsole.ExtraWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
const
  CTHDBank: array[0..7] of Integer = (1, 0, 1, 0, 1, 0, 3, 2);
begin
  Result := True;
  var Kind := FCart.Protection;
  var Mask := 0;
  if HighByte then
    Mask := Mask or $FF00;
  if LowByte then
    Mask := Mask or $FF;
  if ((Kind = 'jockeygp') or (Kind = 'vliner')) and (Address >= $200000) and (Address <= $201FFE) then
  begin
    var I := (Address - $200000) shr 1;
    var W := Word((FCartRAM[I] and (Mask xor $FFFF)) or (Value and Mask));
    if W <> FCartRAM[I] then
    begin
      FCartRAM[I] := W;
      FBatteryDirty := True;
    end;
  end
  else if (Kind = 'kof10th') and (Address >= $200000) and (Address < $240000) then
  begin
    var I := Integer((Address - $200000) shr 1);
    if FPvcRAM[$FFE] = 0 then
      FCartRAM[I and $FFFF] := Word((FCartRAM[I and $FFFF] and (Mask xor $FFFF)) or (Value and Mask))
    else if I < Length(FCart.FixedROM) then
      FCart.FixedROM[I] := Byte(BootlegBits(Value and $FF, [7, 6, 0, 4, 3, 2, 1, 5]));
  end
  else if HasBootRAM and (Address >= $2FE000) and (Address <= $2FFFFE) then
  begin
    var I := Integer((Address - $2FE000) shr 1);
    var W := Word((FPvcRAM[I] and (Mask xor $FFFF)) or (Value and Mask));
    if Kind = 'kof10th' then
    begin
      if (Address = $2FFFF8) and (FPvcRAM[I] <> W) then
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
    FPvcRAM[I] := W;
    if (Kind <> 'kof10th') and ((Address = $2FFFF0) or (Address = $2FFFF2)) then
    begin
      var Low := FPvcRAM[$FF8] shr 8;
      if Kind = 'kf2k3pl' then
        Low := FPvcRAM[$FF8] and $FF;
      FProgramBank := $100000 + Low + ((Integer(FPvcRAM[$FF9]) and $FF) shl 8) +
        ((Integer(FPvcRAM[$FF9]) shr 8) shl 16);
      FBootOverlay := (FBootOverlay and $FF00) or (FPvcRAM[$FF9] and $FF);
      if Kind = 'kf2k3pl' then
        FPvcRAM[$FF8] := FPvcRAM[$FF8] and $FFFE
      else
        FPvcRAM[$FF8] := (FPvcRAM[$FF8] and $FE00) or $A0;
      FPvcRAM[$FF9] := FPvcRAM[$FF9] and $7FFF;
    end;
  end
  else if ((Kind = 'cthd2k3') or (Kind = 'ct2k3sp')) and (Address = $2FFFF0) then
    FProgramBank := (CTHDBank[Value and 7] + 1) * $100000
  else if (Kind = 'ms5plus') and (Address >= $2FFFF0) and (Address <= $2FFFFE) then
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
  for var I := 0 to 6 do
  begin
    if ((FInputSelect and 1) <> 0) and (TileButtons[I] in FInputs.Buttons) then
      Result := Result and Byte($FF xor (1 shl I));
    if ((FInputSelect and 2) <> 0) and (TileButtons[I] in FInputs.Buttons2) then
      Result := Result and Byte($FF xor (1 shl I));
  end;
  for var I := 0 to 4 do
    if ((FInputSelect and 4) <> 0) and (ActionButtons[I] in FInputs.Buttons2) then
      Result := Result and Byte($FF xor (1 shl I));
end;

function TNeoGeoConsole.HasPVC: Boolean;
begin
  Result := (FCart.Protection = 'mslug5') or (FCart.Protection = 'svc') or
    (FCart.Protection = 'kof2003') or (FCart.Protection = 'kof2003h') or (FCart.Protection = 'svcboot') or
    (FCart.Protection = 'svcsplus');
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
  var Kind := FCart.Protection;
  if not ((Kind = 'kof99') or (Kind = 'garou') or (Kind = 'garouh') or
    (Kind = 'mslug3') or (Kind = 'mslug3a') or (Kind = 'kof2000')) then
    Exit;
  if Address = $2FE446 then
  begin
    Value := $9A37;
    Exit(True);
  end;
  var RandomPort := ((Kind = 'kof99') and ((Address = $2FFFF8) or (Address = $2FFFFA))) or
    (((Kind = 'garou') or (Kind = 'garouh')) and ((Address = $2FFFCC) or (Address = $2FFFF0))) or
    ((Kind = 'kof2000') and ((Address = $2FFFD8) or (Address = $2FFFDA)));
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
  var Kind := FCart.Protection;
  Result := ((Kind = 'kof99') and (Address = $2FFFF0)) or
    (((Kind = 'garou') or (Kind = 'garouh')) and (Address = $2FFFC0)) or
    (((Kind = 'mslug3') or (Kind = 'mslug3a')) and (Address = $2FFFE4)) or
    ((Kind = 'kof2000') and (Address = $2FFFEC));
  if Result then
    FProgramBank := SMABank(Kind, Value);
end;

function TNeoGeoConsole.ReadBus(Address: Cardinal; HighByte, LowByte: Boolean): Word;
begin
  if ExtraRead(Address, Result) then
    Exit;
  Result := $FFFF;
  var Region := Address shr 20;
  var Offset := Integer(Address and $FFFF);
  case Region of
    0:
      begin
        if (FCart.Protection = 'kof98') and (FKof98Overlay <> 0) and
          ((Address = $100) or (Address = $102)) then
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
        var Data := FCart.ProgramROM;
        if (Address < $80) and not FCartVectors then
          Data := FCart.BIOS;
        var A := Integer(Address);
        Result := Word(ROMByte(Data, A) * 256 + ROMByte(Data, A + 1));
      end;
    1:
      Result := Word(Integer(FRAM[Offset]) * 256 + FRAM[Offset + 1]);
    2:
      begin
        if FCart.Protection = 'fatfury2' then
          Exit(FuryRead(Address));
        if (FCart.Protection = 'mslugx') and (Address >= $2FFFE0) and (Address <= $2FFFEE) then
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
          if (Address and $80) <> 0 then
            Result := $FFFF
          else
          begin
            var Pad := PadByte(FInputs.Buttons);
            if FCart.Protection = 'neogeo_mj' then
              Pad := MahjongByte;
            if FCart.Protection = 'irrmaze' then
              if (FInputSelect and 1) <> 0 then
                Pad := FTrackY
              else
                Pad := FTrackX;
            Result := Word(Integer(Pad) * 256 + $FF);
          end;
        $32:
          begin
            SyncZ80(FBusTime);
            var Coins := $1F;
            if (FCoin1 > 0) or (TEmulatorButton.Select in FInputs.Buttons) then
              Coins := Coins and $FE;
            if (FCoin2 > 0) or (TEmulatorButton.Select in FInputs.Buttons2) then
              Coins := Coins and $FD;
            if (FRTCTPPeriod > 0) and Odd((FBusTime - FRTCEpoch) div Max(1, FRTCTPPeriod)) then
              Coins := Coins or $40;
            if RTCData then
              Coins := Coins or $80;
            Result := Word(Integer(FReply) * 256 + Coins);
          end;
        $34:
          if FCart.Protection = 'irrmaze' then
            Result := Word(Integer((PadByte(FInputs.Buttons) and $30) or
                ((PadByte(FInputs.Buttons2) and $30) shl 2) or $F) * 256 + $FF)
          else
            Result := Word(Integer(PadByte(FInputs.Buttons2)) * 256 + $FF);
        $38:
          begin
            Result := $FFFF; // MVS hardware, memory card absent, two joystick ports.
            if (FCart.Protection <> 'jockeygp') and (TEmulatorButton.Start in FInputs.Buttons) then
              Result := Result and $FEFF;
            if TEmulatorButton.Select in FInputs.Buttons then
              Result := Result and $FDFF;
            if (FCart.Protection <> 'jockeygp') and (TEmulatorButton.Start in FInputs.Buttons2) then
              Result := Result and $FBFF;
            if TEmulatorButton.Select in FInputs.Buttons2 then
              Result := Result and $F7FF;
          end;
        $3C:
          if HighByte then
            Result := Video.ReadRegister((Address shr 1) and 3,
              Integer((FBusTime mod NG_FRAME_CLOCKS) div NG_LINE_CLOCKS));
      end;
    4, 5, 6, 7:
      Result := Video.Palette[Video.PaletteBank * $1000 + Integer((Address shr 1) and $FFF)];
    $C:
      begin
        var A := Integer(Address) mod Length(FCart.BIOS);
        Result := Word(ROMByte(FCart.BIOS, A) * 256 + ROMByte(FCart.BIOS, A + 1));
      end;
    $D:
      Result := Word(Integer(FBackup[Offset]) * 256 + FBackup[Offset + 1]);
  end;
end;

procedure TNeoGeoConsole.WriteBus(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
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
      if FCart.Protection = 'fatfury2' then
        FuryWrite(Address, Value)
      else if (FCart.Protection = 'kof98') and (Address = $20AAAA) then
      begin
        if Value = $90 then
          FKof98Overlay := 1
        else if Value = $F0 then
          FKof98Overlay := 2;
      end
      else if (FCart.Protection = 'mslugx') and (Address >= $2FFFE0) and (Address <= $2FFFEE) then
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
          if LowByte and ((Address and $70) = 0) then
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
              5:
                begin
                  FCartAudio := SetBit;
                  Video.CartFixed := SetBit;
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
    $D:
      if FBackupUnlocked then
      begin
        if HighByte then
          FBackup[Offset] := Value shr 8;
        if LowByte then
          FBackup[Offset + 1] := Value and $FF;
        FBatteryDirty := True;
      end;
  end;
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
  if FCart.Protection = 'irrmaze' then
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
  for var Line := 0 to NG_LINES - 1 do
  begin
    var Target := FFrameTime + Int64(Line + 1) * NG_LINE_CLOCKS;
    if Line = 240 then
    begin
      FIRQ1 := True;
      if (FIRQControl and $40) <> 0 then
        FIRQDeadline := FFrameTime + Int64(Line) * NG_LINE_CLOCKS + (Int64(FDisplayCounter) + 1) * 4;
    end;
    while FCPUTime < Target do
    begin
      if (FIRQDeadline >= 0) and (FCPUTime >= FIRQDeadline) then
      begin
        if (FIRQControl and $10) <> 0 then
          FIRQ2 := True;
        if (FIRQControl and $80) <> 0 then
          Inc(FIRQDeadline, (Int64(FDisplayCounter) + 1) * 4)
        else
          FIRQDeadline := -1;
      end;
      UpdateIRQ;
      FCPUBase := FCPUTime;
      var Cycles := Clown68000DoCycles(FCPU, FCPUCallbacks, 1);
      Inc(FCPUTime, Int64(Max(1, Integer(Cycles))) * 2);
      if FCPU.Halted <> 0 then
        raise EInvalidOpException.Create('Neo Geo 68000 halted');
    end;
    SyncZ80(Target);
    SyncSound(Target);
    Video.RenderLine(Line);
  end;
  // Only mask the host framebuffer; the CPU, VRAM and timing run normally.
  // Require readiness at both ends so a mid-frame clear cannot leak test pixels.
  if not DisplayReady or not Video.StartupVideoReady then
    Video.ClearFrame;
  Video.NextFrame;
  Inc(FFrameTime, NG_FRAME_CLOCKS);
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
  if (FWatchdog > 8) and (FCart.SetName <> 'neopong10') and (FCart.SetName <> 'syscheck') then
    Reset;
end;

function TNeoGeoConsole.BatteryData: TBytes;
begin
  SetLength(Result, SizeOf(FBackup));
  Move(FBackup[0], Result[0], SizeOf(FBackup));
  if (FCart.Protection = 'jockeygp') or (FCart.Protection = 'vliner') then
  begin
    SetLength(Result, SizeOf(FBackup) + $2000);
    for var I := 0 to $FFF do
    begin
      Result[SizeOf(FBackup) + I * 2] := FCartRAM[I] shr 8;
      Result[SizeOf(FBackup) + I * 2 + 1] := FCartRAM[I] and $FF;
    end;
  end;
end;

procedure TNeoGeoConsole.LoadBattery(const Data: TBytes);
begin
  var HasCart := (FCart.Protection = 'jockeygp') or (FCart.Protection = 'vliner');
  if (Length(Data) <> SizeOf(FBackup)) and not (HasCart and (Length(Data) = SizeOf(FBackup) + $2000)) then
    raise EReadError.Create('Invalid Neo Geo backup RAM size');
  Move(Data[0], FBackup[0], SizeOf(FBackup));
  if HasCart and (Length(Data) > SizeOf(FBackup)) then
    for var I := 0 to $FFF do
      FCartRAM[I] := Word(Integer(Data[SizeOf(FBackup) + I * 2]) * 256 + Data[SizeOf(FBackup) + I * 2 + 1]);
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
  Video.SerializeState(State);
  Sound.SerializeState(State);
  // These boards previously could not load; standard-cart snapshots retain their layout.
  if HasBootRAM then
  begin
    State.Field(FBootOverlay, SizeOf(FBootOverlay));
    if FCart.Protection = 'kof10th' then
    begin
      State.Field(FSpecialBank, SizeOf(FSpecialBank));
      State.Field(FCartRAM, SizeOf(FCartRAM));
      State.Field(FCart.FixedROM[0], Length(FCart.FixedROM));
    end;
  end;
  if (FCart.Protection = 'jockeygp') or (FCart.Protection = 'vliner') then
    State.Field(FCartRAM, $2000);
  if (FCart.Protection = 'neogeo_mj') or (FCart.Protection = 'irrmaze') then
  begin
    State.Field(FInputSelect, SizeOf(FInputSelect));
    State.Field(FTrackX, SizeOf(FTrackX));
    State.Field(FTrackY, SizeOf(FTrackY));
  end;
  if State.Loading then
  begin
    FInZ80 := False;
    if (FCart.Protection = 'kof10th') and (FSpecialBank <> 0) and (FSpecialBank <> $700000) and (FSpecialBank <> $800000) then
      raise EReadError.Create('Invalid Neo Geo bootleg bank state');
    if (Video.PaletteBank < 0) or (Video.PaletteBank > 1) or
      (FProgramBank < 0) or (FProgramBank > $10000000) or (FFrameTime < 0) then
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
  Result := NG_HEIGHT;
end;

function TNeoGeoConsole.GetFPS: Double;
begin
  Result := NG_FPS;
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
  MD.Z80.ConstantInitialise;

end.

