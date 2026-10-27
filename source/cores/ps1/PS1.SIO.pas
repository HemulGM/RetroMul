unit PS1.SIO;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.Scheduler;

{$SCOPEDENUMS ON}

const
  PS1MemoryCardSize = $20000;

  // Digital switch bits (active high here; the wire protocol inverts them).
  PS1PadSelect = $0001;
  PS1PadL3 = $0002;
  PS1PadR3 = $0004;
  PS1PadStart = $0008;
  PS1PadUp = $0010;
  PS1PadRight = $0020;
  PS1PadDown = $0040;
  PS1PadLeft = $0080;
  PS1PadL2 = $0100;
  PS1PadR2 = $0200;
  PS1PadL1 = $0400;
  PS1PadR1 = $0800;
  PS1PadTriangle = $1000;
  PS1PadCircle = $2000;
  PS1PadCross = $4000;
  PS1PadSquare = $8000;

type
  // A device behind one controller port. Bytes are exchanged after the
  // device accepted the address byte; Ack asks the host for another byte.
  TPS1SIODevice = class abstract
  public
    function Address(Value: Byte): Boolean; virtual; abstract;
    function Exchange(Value: Byte; out Ack: Boolean; var Delay: Integer): Byte; virtual; abstract;
    procedure Deselect; virtual; abstract;
    procedure SerializeState(State: TStateArchive); virtual; abstract;
  end;

  TPS1PadKind = (Digital, DualShock);

  TPS1PadInput = record
    Buttons: Word; // PS1Pad* bits, set while pressed
    // Right X, right Y, left X, left Y: 00h left/up, 80h centred, FFh right/down.
    Axes: array[0..3] of Byte;
    AnalogButton: Boolean; // DualShock ANALOG button, acts on press
    class function Centred(Buttons: Word = 0): TPS1PadInput; static;
  end;

  // Sony digital pad (SCPH-1080) or DualShock (SCPH-1200). The DualShock
  // starts in digital mode; the ANALOG button or config command 44h switches
  // it. Config mode (43h) adds 44h..4Dh; 4Dh maps the rumble motors to the
  // bytes the host sends with command 42h.
  TPS1Controller = class(TPS1SIODevice)
  private
    FKind: TPS1PadKind;
    FInput: TPS1PadInput;
    FStep, FLast: Integer;
    FCommand, FParam: Byte;
    FAnalog, FConfig, FLocked, FConfigured, FTransferConfig: Boolean;
    FRumble: array[0..5] of Byte;
    FSmall: Boolean;
    FLarge: Byte;
    procedure SetKind(Value: TPS1PadKind);
    procedure ResetState;
    function InputByte(Step: Integer; Analog: Boolean): Byte;
    procedure Motors(Step: Integer; Value: Byte);
  public
    constructor Create;
    procedure SetInput(const Value: TPS1PadInput);
    function Address(Value: Byte): Boolean; override;
    function Exchange(Value: Byte; out Ack: Boolean; var Delay: Integer): Byte; override;
    procedure Deselect; override;
    procedure SerializeState(State: TStateArchive); override;
    // Changing the kind resets the controller (as reconnecting it would).
    property Kind: TPS1PadKind read FKind write SetKind;
    property Input: TPS1PadInput read FInput;
    // Analog mode (LED on).
    property Analog: Boolean read FAnalog;
    // Rumble motors: right/small on or off, left/large speed 00h..FFh.
    property SmallMotor: Boolean read FSmall;
    property LargeMotor: Byte read FLarge;
  end;

  // Sony 128 KiB memory card protocol (read, write, get ID, FLAG byte).
  TPS1MemoryCard = class(TPS1SIODevice)
  private
    FStep: Integer;
    FCommand, FFlag, FPrevious, FChecksum: Byte;
    FSector: Cardinal;
    FBuffer: array[0..127] of Byte;
    FDirty: Boolean;
    FWrites: UInt64;
  public
    Data: array[0..PS1MemoryCardSize - 1] of Byte;
    constructor Create;
    procedure Format;
    procedure Load(const Image: TBytes);
    function Image: TBytes;
    function Address(Value: Byte): Boolean; override;
    function Exchange(Value: Byte; out Ack: Boolean; var Delay: Integer): Byte; override;
    procedure Deselect; override;
    procedure SerializeState(State: TStateArchive); override;
    property Dirty: Boolean read FDirty write FDirty;
    // Increments on every committed sector write.
    property Writes: UInt64 read FWrites;
  end;

  // SIO0 (controller and memory card serial port).
  TPS1SIO0 = class
  private
    FScheduler: TPS1Scheduler;
    FIRQ: TPS1IRQRequest;
    FMode, FControl, FBaud: Cardinal;
    FStatusIRQ, FAckLevel: Boolean;
    FRX: array[0..7] of Byte;
    FRXCount, FRXHead: Integer;
    FTXPending, FTXActive: Boolean;
    FTXValue, FTXShift: Byte;
    FTXLatchedEnable: Boolean;
    FTransferEnd, FAckStart, FAckEnd, FBaudStart: Int64;
    FSelected: array[0..1] of Integer; // -1 unaddressed, 0 none, 1 pad, 2 card
    FFinished: array[0..1] of Boolean;
    function BitCycles: Int64;
    function ActivePort: Integer; inline;
    procedure Deselect(Port: Integer);
    procedure StartTransfer(Time: Int64);
    procedure CompleteTransfer(Time: Int64);
    procedure ScheduleNext;
    procedure CheckIRQ;
    function PopRX: Byte;
  public
    Pads: array[0..1] of TPS1SIODevice;
    Cards: array[0..1] of TPS1MemoryCard;
    constructor Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure Event(Time: Int64);
    procedure SerializeState(State: TStateArchive);
  end;

  // SIO1 without a link cable partner.
  TPS1SIO1 = class
  private
    FMode, FControl, FBaud, FMisc: Cardinal;
  public
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

const
  // /ACK follows about 1500 cycles after the start of a byte at the standard
  // rate and stays low for a short pulse.
  AckDelay = 1500;
  AckPulse = 100;
  // Original Sony cards answer late after the seventh byte of a read.
  CardReadDelay = 31000;

{ TPS1PadInput }

class function TPS1PadInput.Centred(Buttons: Word): TPS1PadInput;
begin
  Result.Buttons := Buttons;
  FillChar(Result.Axes, SizeOf(Result.Axes), $80);
  Result.AnalogButton := False;
end;

{ TPS1Controller }

constructor TPS1Controller.Create;
begin
  inherited Create;
  FInput := TPS1PadInput.Centred;
  ResetState;
end;

// Power-on state: digital mode, unlocked, rumble unmapped and stopped.
procedure TPS1Controller.ResetState;
begin
  FStep := 0;
  FLast := 0;
  FCommand := 0;
  FParam := 0;
  FAnalog := False;
  FConfig := False;
  FLocked := False;
  FConfigured := False;
  FTransferConfig := False;
  FillChar(FRumble, SizeOf(FRumble), $FF);
  FSmall := False;
  FLarge := 0;
end;

procedure TPS1Controller.SetKind(Value: TPS1PadKind);
begin
  if FKind = Value then
    Exit;
  FKind := Value;
  ResetState;
end;

// The ANALOG button toggles the mode unless a game locked it (44h); like the
// watchdog reset it stops the motors and unmaps them.
procedure TPS1Controller.SetInput(const Value: TPS1PadInput);
begin
  if (FKind = TPS1PadKind.DualShock) and Value.AnalogButton and not FInput.AnalogButton and not FLocked then
  begin
    FAnalog := not FAnalog;
    FillChar(FRumble, SizeOf(FRumble), $FF);
    FSmall := False;
    FLarge := 0;
  end;
  FInput := Value;
end;

function TPS1Controller.Address(Value: Byte): Boolean;
begin
  Result := Value = $01;
  FStep := 0;
end;

// Step 2/3: switches (L3/R3 only with analog inputs), 4..7: the sticks.
function TPS1Controller.InputByte(Step: Integer; Analog: Boolean): Byte;
begin
  var Buttons := FInput.Buttons;
  if not Analog then
    Buttons := Buttons and not (PS1PadL3 or PS1PadR3);
  case Step of
    2:
      Result := Byte(not Buttons);
    3:
      Result := Byte(not Buttons shr 8);
  else
    Result := FInput.Axes[Step - 4];
  end;
end;

// Command 42h: before config commands were used, the right motor follows the
// old one-motor protocol (xx 40h..7Fh with yy bit 0); afterwards 4Dh maps it.
procedure TPS1Controller.Motors(Step: Integer; Value: Byte);
begin
  if not FConfigured then
  begin
    if Step = 2 then
      FParam := Value
    else if Step = 3 then
      FSmall := ((FParam and $C0) = $40) and Odd(Value);
    Exit;
  end;
  case FRumble[Step - 2] of
    $00:
      FSmall := Odd(Value);
    $01:
      FLarge := Value;
  end;
end;

function TPS1Controller.Exchange(Value: Byte; out Ack: Boolean; var Delay: Integer): Byte;
begin
  var Step := FStep;
  Inc(FStep);
  Ack := True;
  Result := $FF;
  if FKind = TPS1PadKind.Digital then
  begin
    case Step of
      0:
        if Value = $42 then
          Result := $41
        else
          Ack := False;
      1:
        Result := $5A;
      2:
        Result := InputByte(2, False);
      3:
        begin
          Result := InputByte(3, False);
          Ack := False;
        end;
    else
      Ack := False;
    end;
    Exit;
  end;

  if Step = 0 then
  begin
    // The ID leaves while the command arrives, so it reflects the mode.
    FCommand := Value;
    FTransferConfig := FConfig;
    if FConfig then
    begin
      Result := $F3;
      Ack := Value in [$40..$4F];
      FLast := 7;
    end
    else
    begin
      Ack := Value in [$42, $43];
      if FAnalog then
      begin
        Result := $73;
        FLast := 7;
      end
      else
      begin
        Result := $41;
        FLast := 3;
      end;
    end;
    Exit;
  end;

  if Step > FLast then
  begin
    Ack := False;
    Exit;
  end;
  Ack := Step < FLast;
  if Step = 1 then
    Exit($5A);

  if not FTransferConfig then
  begin
    Result := InputByte(Step, FAnalog);
    if FCommand = $42 then
      Motors(Step, Value)
    else if (Step = 2) and Odd(Value) then
    begin
      FConfig := True;
      FConfigured := True;
    end;
    Exit;
  end;

  Result := $00;
  case FCommand of
    $42:
      begin
        Result := InputByte(Step, True);
        Motors(Step, Value);
      end;
    $43:
      if Step = 2 then
        FConfig := Odd(Value);
    $44:
      case Step of
        2:
          case Value of
            0:
              FAnalog := False;
            1:
              FAnalog := True;
          end;
        3:
          FLocked := (Value and 3) = 3;
      end;
    $45:
      case Step of
        2:
          Result := $01;
        3:
          Result := $02;
        4:
          Result := Ord(FAnalog);
        5:
          Result := $02;
        6:
          Result := $01;
      end;
    $46:
      if Step = 2 then
        FParam := Value
      else if (Step >= 4) and (FParam <= 1) then
        Result := Byte(IfThen(FParam = 0, $0A000201, $14010101) shr ((Step - 4) * 8));
    $47:
      case Step of
        4:
          Result := $02;
        6:
          Result := $01;
      end;
    $48:
      if Step = 2 then
        FParam := Value
      else if (Step = 6) and (FParam <= 1) then
        Result := $01;
    $4C:
      if Step = 2 then
        FParam := Value
      else if (Step = 5) and (FParam <= 1) then
        Result := IfThen(FParam = 0, $04, $07);
    $4D:
      begin
        Result := FRumble[Step - 2];
        FRumble[Step - 2] := Value;
      end;
  end;
end;

procedure TPS1Controller.Deselect;
begin
  FStep := 0;
end;

procedure TPS1Controller.SerializeState(State: TStateArchive);
begin
  State.Field(FKind, SizeOf(FKind));
  State.Field(FInput, SizeOf(FInput));
  State.Field(FStep, SizeOf(FStep));
  State.Field(FLast, SizeOf(FLast));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FParam, SizeOf(FParam));
  State.Field(FAnalog, SizeOf(FAnalog));
  State.Field(FConfig, SizeOf(FConfig));
  State.Field(FLocked, SizeOf(FLocked));
  State.Field(FConfigured, SizeOf(FConfigured));
  State.Field(FTransferConfig, SizeOf(FTransferConfig));
  State.Field(FRumble, SizeOf(FRumble));
  State.Field(FSmall, SizeOf(FSmall));
  State.Field(FLarge, SizeOf(FLarge));
end;

{ TPS1MemoryCard }

constructor TPS1MemoryCard.Create;
begin
  inherited Create;
  FFlag := $08;
  Format;
end;

// Formatted card: header and write-test frames, free directory entries,
// no broken sectors.
procedure TPS1MemoryCard.Format;

  procedure Checksum(Frame: Integer);
  begin
    var Sum: Byte := 0;
    for var I := 0 to 126 do
      Sum := Sum xor Data[Frame * 128 + I];
    Data[Frame * 128 + 127] := Sum;
  end;

begin
  FillChar(Data, SizeOf(Data), 0);
  Data[0] := Ord('M');
  Data[1] := Ord('C');
  Checksum(0);
  for var Frame := 1 to 15 do
  begin
    Data[Frame * 128] := $A0;
    Data[Frame * 128 + 8] := $FF;
    Data[Frame * 128 + 9] := $FF;
    Checksum(Frame);
  end;
  for var Frame := 16 to 35 do
  begin
    FillChar(Data[Frame * 128], 4, $FF);
    Data[Frame * 128 + 8] := $FF;
    Data[Frame * 128 + 9] := $FF;
    Checksum(Frame);
  end;
  for var Frame := 36 to 62 do
    FillChar(Data[Frame * 128], 128, $FF);
  Move(Data[0], Data[63 * 128], 128);
  FDirty := True;
end;

procedure TPS1MemoryCard.Load(const Image: TBytes);
begin
  if Length(Image) <> PS1MemoryCardSize then
    raise EPS1Error.Create('PS1 memory card image must contain 128 KiB');

  Move(Image[0], Data[0], PS1MemoryCardSize);
  FDirty := False;
end;

function TPS1MemoryCard.Image: TBytes;
begin
  SetLength(Result, PS1MemoryCardSize);
  Move(Data[0], Result[0], PS1MemoryCardSize);
end;

function TPS1MemoryCard.Address(Value: Byte): Boolean;
begin
  Result := Value = $81;
  FStep := 0;
end;

function TPS1MemoryCard.Exchange(Value: Byte; out Ack: Boolean; var Delay: Integer): Byte;
begin
  Ack := True;
  Result := $FF;
  var Step := FStep;
  Inc(FStep);
  if Step = 0 then
  begin
    FCommand := Value;
    Result := FFlag;
    Ack := Value in [$52, $53, $57];
    FPrevious := Value;
    Exit;
  end;

  case FCommand of
    $52:
      case Step of
        1:
          Result := $5A;
        2:
          Result := $5D;
        3:
          begin
            FSector := Cardinal(Value) shl 8;
            Result := $00;
          end;
        4:
          begin
            FSector := FSector or Value;
            Result := FPrevious;
          end;
        5:
          begin
            Result := $5C;
            Inc(Delay, CardReadDelay);
          end;
        6:
          Result := $5D;
        7:
          if FSector > $3FF then
            Result := $FF
          else
          begin
            Result := Byte(FSector shr 8);
            FChecksum := Result;
          end;
        8:
          if FSector > $3FF then
          begin
            Result := $FF;
            Ack := False;
          end
          else
          begin
            Result := Byte(FSector);
            FChecksum := FChecksum xor Result;
          end;
        9..136:
          begin
            Result := Data[FSector * 128 + Cardinal(Step - 9)];
            FChecksum := FChecksum xor Result;
          end;
        137:
          Result := FChecksum;
        138:
          begin
            Result := $47;
            Ack := False;
          end;
      else
        Ack := False;
      end;
    $57:
      case Step of
        1:
          Result := $5A;
        2:
          Result := $5D;
        3:
          begin
            FSector := Cardinal(Value) shl 8;
            FChecksum := Value;
            Result := $00;
          end;
        4:
          begin
            FSector := FSector or Value;
            FChecksum := FChecksum xor Value;
            Result := FPrevious;
          end;
        5..132:
          begin
            FBuffer[Step - 5] := Value;
            FChecksum := FChecksum xor Value;
            Result := FPrevious;
          end;
        133:
          begin
            FChecksum := FChecksum xor Value;
            Result := FPrevious;
          end;
        134:
          Result := $5C;
        135:
          Result := $5D;
        136:
          begin
            Ack := False;
            if FSector > $3FF then
              Result := $FF
            else if FChecksum <> 0 then
              Result := $4E
            else
            begin
              Move(FBuffer[0], Data[FSector * 128], 128);
              FFlag := FFlag and not $08;
              FDirty := True;
              Inc(FWrites);
              Result := $47;
            end;
          end;
      else
        Ack := False;
      end;
    $53:
      case Step of
        1:
          Result := $5A;
        2:
          Result := $5D;
        3:
          Result := $5C;
        4:
          Result := $5D;
        5:
          Result := $04;
        6:
          Result := $00;
        7:
          Result := $00;
        8:
          begin
            Result := $80;
            Ack := False;
          end;
      else
        Ack := False;
      end;
  else
    Ack := False;
  end;
  FPrevious := Value;
end;

procedure TPS1MemoryCard.Deselect;
begin
  FStep := 0;
end;

procedure TPS1MemoryCard.SerializeState(State: TStateArchive);
begin
  State.Field(FStep, SizeOf(FStep));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FFlag, SizeOf(FFlag));
  State.Field(FPrevious, SizeOf(FPrevious));
  State.Field(FChecksum, SizeOf(FChecksum));
  State.Field(FSector, SizeOf(FSector));
  State.Field(FBuffer, SizeOf(FBuffer));
  State.Field(Data, SizeOf(Data));
  if State.Loading then
    FDirty := True;
end;

{ TPS1SIO0 }

constructor TPS1SIO0.Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  Reset;
end;

procedure TPS1SIO0.Reset;
begin
  FMode := 0;
  FControl := 0;
  FBaud := $88;
  FStatusIRQ := False;
  FAckLevel := False;
  FRXCount := 0;
  FRXHead := 0;
  FTXPending := False;
  FTXActive := False;
  FTXValue := 0;
  FTXShift := 0;
  FTXLatchedEnable := False;
  FTransferEnd := PS1Never;
  FAckStart := PS1Never;
  FAckEnd := PS1Never;
  FBaudStart := 0;
  for var Port := 0 to 1 do
    Deselect(Port);
  FScheduler.Cancel(TPS1Event.SIO0);
end;

function TPS1SIO0.BitCycles: Int64;
begin
  var Factor: Cardinal := 1;
  case FMode and 3 of
    2:
      Factor := 16;
    3:
      Factor := 64;
  end;
  Result := (Int64(FBaud) * Factor) and not Int64(1);
  if Result < 1 then
    Result := 1;
end;

function TPS1SIO0.ActivePort: Integer;
begin
  Result := Integer((FControl shr 13) and 1);
end;

procedure TPS1SIO0.Deselect(Port: Integer);
begin
  FSelected[Port] := -1;
  FFinished[Port] := False;
  if Pads[Port] <> nil then
    Pads[Port].Deselect;
  if Cards[Port] <> nil then
    Cards[Port].Deselect;
end;

procedure TPS1SIO0.ScheduleNext;
begin
  var Next := FTransferEnd;
  if FAckStart < Next then
    Next := FAckStart;
  if FAckEnd < Next then
    Next := FAckEnd;
  if Next = PS1Never then
    FScheduler.Cancel(TPS1Event.SIO0)
  else
    FScheduler.Schedule(TPS1Event.SIO0, Next);
end;

procedure TPS1SIO0.CheckIRQ;
begin
  var Before := FStatusIRQ;
  if FAckLevel and ((FControl and $1000) <> 0) then
    FStatusIRQ := True;
  if ((FControl and $800) <> 0) and (FRXCount >= (1 shl ((FControl shr 8) and 3))) then
    FStatusIRQ := True;
  if FStatusIRQ and not Before then
    FIRQ(TPS1IRQ.SIO0);
end;

procedure TPS1SIO0.StartTransfer(Time: Int64);
begin
  FTXPending := False;
  FTXActive := True;
  FTXShift := FTXValue;
  FTransferEnd := Time + BitCycles * 8;
  ScheduleNext;
end;

procedure TPS1SIO0.CompleteTransfer(Time: Int64);
begin
  FTXActive := False;
  FTransferEnd := PS1Never;
  var Port := ActivePort;
  var Response: Byte := $FF;
  var Ack := False;
  var Delay := 0;
  // Devices see the byte only while /CS (DTR) selects their port.
  if (FControl and 2) <> 0 then
  begin
    if FSelected[Port] < 0 then
    begin
      FSelected[Port] := 0;
      if (Pads[Port] <> nil) and Pads[Port].Address(FTXShift) then
        FSelected[Port] := 1
      else if (Cards[Port] <> nil) and Cards[Port].Address(FTXShift) then
        FSelected[Port] := 2;
      Ack := FSelected[Port] <> 0;
    end
    else if not FFinished[Port] then
    begin
      case FSelected[Port] of
        1:
          Response := Pads[Port].Exchange(FTXShift, Ack, Delay);
        2:
          Response := Cards[Port].Exchange(FTXShift, Ack, Delay);
      end;
    end;
    FFinished[Port] := FFinished[Port] or ((FSelected[Port] <> -1) and not Ack);
  end;
  if ((FControl and 2) <> 0) or ((FControl and 4) <> 0) then
  begin
    if FRXCount < 8 then
    begin
      FRX[(FRXHead + FRXCount) and 7] := Response;
      Inc(FRXCount);
    end
    else
      FRX[(FRXHead + 7) and 7] := Response;
    FControl := FControl and not Cardinal(4);
  end;
  if Ack then
  begin
    var Start := Time - BitCycles * 8 + AckDelay + Delay;
    if Start <= Time then
      Start := Time + 1;
    FAckStart := Start;
  end;
  if FTXPending then
    StartTransfer(Time);
  CheckIRQ;
  ScheduleNext;
end;

procedure TPS1SIO0.Event(Time: Int64);
begin
  if FTransferEnd <= Time then
    CompleteTransfer(FTransferEnd);
  if FAckStart <= Time then
  begin
    FAckStart := PS1Never;
    FAckLevel := True;
    FAckEnd := Time + AckPulse;
    CheckIRQ;
  end;
  if FAckEnd <= Time then
  begin
    FAckEnd := PS1Never;
    FAckLevel := False;
  end;
  ScheduleNext;
end;

function TPS1SIO0.PopRX: Byte;
begin
  if FRXCount = 0 then
    Exit(FRX[(FRXHead + 7) and 7]);

  Result := FRX[FRXHead];
  FRXHead := (FRXHead + 1) and 7;
  Dec(FRXCount);
end;

function TPS1SIO0.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  case Address and $F of
    $0:
      begin
        // Wider reads preview later FIFO entries but pop only one (16-bit)
        // or four (32-bit) of them.
        Result := 0;
        var Preview := 1;
        if Size = 2 then
          Preview := 2
        else if Size = 4 then
          Preview := 4;
        for var I := 0 to Preview - 1 do
          Result := Result or (Cardinal(FRX[(FRXHead + I) and 7]) shl (I * 8));
        PopRX;
        if Size = 4 then
          for var I := 1 to 3 do
            PopRX;
      end;
    $4:
      begin
        Result := 0;
        if not FTXPending then
          Result := Result or 1;
        if FRXCount > 0 then
          Result := Result or 2;
        if not FTXPending and not FTXActive then
          Result := Result or 4;
        if FAckLevel then
          Result := Result or $80;
        if FStatusIRQ then
          Result := Result or $200;
        var Reload := (Int64(FBaud) * 1) div 2;
        if Reload > 0 then
          Result := Result or (Cardinal(Reload - (FScheduler.Now - FBaudStart) mod Reload) and $1FFFFF) shl 11;
      end;
    $8:
      Result := FMode;
    $A:
      Result := FControl;
    $E:
      Result := FBaud;
  else
    Result := 0;
  end;
  if (Size < 4) and ((Address and $F) <> 0) then
    Result := Result and ($FFFFFFFF shr ((4 - Size) * 8));
end;

procedure TPS1SIO0.Write(Address, Value: Cardinal; Size: Integer);
begin
  case Address and $F of
    $0:
      begin
        // A transfer starts now, or as soon as TXEN is set.
        FTXValue := Byte(Value);
        FTXLatchedEnable := (FControl and 1) <> 0;
        FTXPending := True;
        if not FTXActive and FTXLatchedEnable then
          StartTransfer(FScheduler.Now);
      end;
    $8:
      FMode := Value and $13F;
    $A:
      begin
        var Old := FControl;
        FControl := Value and $3F2F;
        if (Value and $40) <> 0 then
        begin
          // INTRST: reset the port, keep the configuration registers.
          FControl := 0;
          FStatusIRQ := False;
          FRXCount := 0;
          FTXPending := False;
          FTXActive := False;
          FTransferEnd := PS1Never;
          FAckStart := PS1Never;
          FAckEnd := PS1Never;
          FAckLevel := False;
          ScheduleNext;
        end;
        if (Value and $10) <> 0 then
          // Acknowledge; the request stays while /ACK is still low.
          FStatusIRQ := False;
        if ((FControl and 2) = 0) or (((Old xor FControl) and $2000) <> 0) then
        begin
          if (Old and 2) <> 0 then
            Deselect(Integer((Old shr 13) and 1));
        end;
        if ((FControl and 2) <> 0) and (((Old and 2) = 0) or (((Old xor FControl) and $2000) <> 0)) then
          Deselect(ActivePort);
        if FTXPending and not FTXActive and ((FControl and 1) <> 0) then
          StartTransfer(FScheduler.Now);
        CheckIRQ;
      end;
    $E:
      begin
        FBaud := Value and $FFFF;
        FBaudStart := FScheduler.Now;
      end;
  end;
end;

procedure TPS1SIO0.SerializeState(State: TStateArchive);
begin
  State.Field(FMode, SizeOf(FMode));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FBaud, SizeOf(FBaud));
  State.Field(FStatusIRQ, SizeOf(FStatusIRQ));
  State.Field(FAckLevel, SizeOf(FAckLevel));
  State.Field(FRX, SizeOf(FRX));
  State.Field(FRXCount, SizeOf(FRXCount));
  State.Field(FRXHead, SizeOf(FRXHead));
  State.Field(FTXPending, SizeOf(FTXPending));
  State.Field(FTXActive, SizeOf(FTXActive));
  State.Field(FTXValue, SizeOf(FTXValue));
  State.Field(FTXShift, SizeOf(FTXShift));
  State.Field(FTXLatchedEnable, SizeOf(FTXLatchedEnable));
  State.Field(FTransferEnd, SizeOf(FTransferEnd));
  State.Field(FAckStart, SizeOf(FAckStart));
  State.Field(FAckEnd, SizeOf(FAckEnd));
  State.Field(FBaudStart, SizeOf(FBaudStart));
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FFinished, SizeOf(FFinished));
  if State.Loading and ((FRXCount < 0) or (FRXCount > 8) or (FRXHead < 0) or (FRXHead > 7) or
    (FSelected[0] < -1) or (FSelected[0] > 2) or (FSelected[1] < -1) or (FSelected[1] > 2)) then
    raise EReadError.Create('PS1 snapshot SIO0');
end;

{ TPS1SIO1 }

procedure TPS1SIO1.Reset;
begin
  FMode := 0;
  FControl := 0;
  FBaud := 0;
  FMisc := 0;
end;

function TPS1SIO1.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  case Address and $F of
    $0:
      Result := $FF;
    // TX ready and idle; no partner drives CTS/DSR.
      $4:
      Result := $00000005;
    $8:
      Result := FMode;
    $A:
      Result := FControl;
    $C:
      Result := FMisc;
    $E:
      Result := FBaud;
  else
    Result := 0;
  end;
  if Size < 4 then
    Result := Result and ($FFFFFFFF shr ((4 - Size) * 8));
end;

procedure TPS1SIO1.Write(Address, Value: Cardinal; Size: Integer);
begin
  case Address and $F of
    $8:
      FMode := Value and $FF;
    $A:
      FControl := Value and $FFFF;
    $C:
      FMisc := Value and $FFFF;
    $E:
      FBaud := Value and $FFFF;
  end;
end;

procedure TPS1SIO1.SerializeState(State: TStateArchive);
begin
  State.Field(FMode, SizeOf(FMode));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FBaud, SizeOf(FBaud));
  State.Field(FMisc, SizeOf(FMisc));
end;

end.

