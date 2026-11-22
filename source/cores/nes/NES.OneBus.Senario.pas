unit NES.OneBus.Senario;

interface

uses
  System.Types, NES.Controller, NES.State;

type
  TSenarioIo = class
  private
    FPointer: TZapper;
    FDirection, FPanelPort, FLcdPort, FLcdControl: Byte;
    FAdcClock, FAdcCommand, FAdcSample: Byte;
    FLcdAddress: Byte;
    FLcdBusy, FWriteCycles, FClearCycles: Integer;
    FDisplayEnabled, FIncrement, FCharacterRam: Boolean;
    FDdram: array[0..$67] of Byte;
    FCgram: array[0..$3F] of Byte;
    function ReadPen(out Point: TPoint): Boolean;
    function SampleAdc: Byte;
    procedure WritePanelPort(Value: Byte);
    procedure WriteLcdControl(Value: Byte);
    function ReadLcdPort: Byte;
    procedure WriteLcd;
    procedure MoveLcdAddress(ForwardDirection: Boolean);
  public
    procedure ConnectPointer(Pointer: TZapper);
    procedure SetCpuFrequency(Frequency: Cardinal);
    procedure Reset;
    procedure Clock;
    function Read(Address: Word; out Value: Byte): Boolean;
    function Write(Address: Word; Value: Byte): Boolean;
    function ReadController(Value: Byte): Byte;
    function PenButton: Byte;
    function LcdLine(Line: Integer): string;
    procedure SerializeState(State: TNesStateArchive);
  end;

implementation

uses
  NES.Types;

procedure TSenarioIo.ConnectPointer(Pointer: TZapper);
begin
  FPointer := Pointer;
end;

procedure TSenarioIo.SetCpuFrequency(Frequency: Cardinal);
begin
  // HD44780-compatible command execution at the nominal LCD oscillator rate.
  FWriteCycles := (Int64(Frequency) * 37 + 999999) div 1000000;
  FClearCycles := (Int64(Frequency) * 1520 + 999999) div 1000000;
end;

procedure TSenarioIo.Reset;
begin
  FDirection := 0;
  FPanelPort := $20;
  FLcdPort := 0;
  FLcdControl := 0;
  FAdcClock := 0;
  FAdcCommand := 0;
  FAdcSample := $FF;
  FLcdAddress := 0;
  FLcdBusy := 0;
  FDisplayEnabled := False;
  FIncrement := True;
  FCharacterRam := False;
  FillChar(FDdram, SizeOf(FDdram), Ord(' '));
  FillChar(FCgram, SizeOf(FCgram), 0);
end;

procedure TSenarioIo.Clock;
begin
  if FLcdBusy > 0 then
    Dec(FLcdBusy);
end;

function TSenarioIo.ReadPen(out Point: TPoint): Boolean;
begin
  if (FPointer = nil) or not FPointer.TriggerPressed or not Assigned(FPointer.OnReadPosition) then
    Exit(False);
  Point := FPointer.OnReadPosition();
  // The ROM scales these ADC ranges to the TV drawing area at $E88F.
  Result := (Point.X >= 20) and (Point.X <= 235) and (Point.Y >= 56) and (Point.Y <= 196);
end;

function TSenarioIo.PenButton: Byte;
var
  Point: TPoint;
begin
  // While the ADC is deselected, pad bit 5 reports the pen's tip switch.
  Result := Ord(((FPanelPort and $20) <> 0) and ReadPen(Point)) shl Ord(TNesButton.Down);
end;

function TSenarioIo.SampleAdc: Byte;
var
  Point: TPoint;
begin
  Result := $FF;
  if not ReadPen(Point) then
    Exit;
  case FPanelPort and $F of
    6:
      if FAdcCommand = 3 then
        Result := 16 + ((Point.X - 20) * 232 + 214) div 215;
    7:
      if FAdcCommand = 3 then
        Result := 0;
    9:
      if FAdcCommand = 7 then
        Result := 20 + ((Point.Y - 56) * 228 + 139) div 140;
  end;
end;

procedure TSenarioIo.WritePanelPort(Value: Byte);
begin
  var Previous := FPanelPort;
  FPanelPort := Value;
  if ((Previous xor Value) and $20) <> 0 then
  begin
    FAdcClock := 0;
    FAdcCommand := 0;
  end;
  // $410F.5 selects the ADC, .4 clocks it and .6 carries command bits.
  if ((Value and $30) <> $10) or ((Previous and $10) <> 0) or (FAdcClock = 20) then
    Exit;
  if FAdcClock < 3 then
  begin
    var Bit := (Value shr 6) and 1;
    if (FAdcClock = 0) and (Bit = 0) then
      Exit;
    FAdcCommand := FAdcCommand or (Bit shl FAdcClock);
  end;
  Inc(FAdcClock);
  if FAdcClock = 3 then
    FAdcSample := SampleAdc;
end;

function TSenarioIo.ReadController(Value: Byte): Byte;
begin
  if (FPanelPort and $20) <> 0 then
    Exit(Value);
  // The result is sampled after the falling edge. The board inverts DO on D0.
  var Bit := 0;
  case FAdcClock of
    4..11:
      Bit := (FAdcSample shr (11 - FAdcClock)) and 1;
    12..18:
      Bit := (FAdcSample shr (FAdcClock - 11)) and 1;
  end;
  Result := (Value and $FE) or (Bit xor 1);
end;

procedure TSenarioIo.MoveLcdAddress(ForwardDirection: Boolean);
begin
  if FCharacterRam then
    FLcdAddress := (Integer(FLcdAddress) + 2 * Ord(ForwardDirection) - 1) and $3F
  else if ForwardDirection then
    case FLcdAddress of
      $27:
        FLcdAddress := $40;
      $67:
        FLcdAddress := 0;
    else
      Inc(FLcdAddress);
    end
  else
    case FLcdAddress of
      0:
        FLcdAddress := $67;
      $40:
        FLcdAddress := $27;
    else
      Dec(FLcdAddress);
    end;
end;

procedure TSenarioIo.WriteLcd;
begin
  FLcdBusy := FWriteCycles;
  if (FLcdControl and 1) <> 0 then
  begin
    if FCharacterRam then
      FCgram[FLcdAddress] := FLcdPort and $1F
    else
      FDdram[FLcdAddress] := FLcdPort;
    MoveLcdAddress(FIncrement);
    Exit;
  end;
  case FLcdPort of
    1..3:
      begin
        if FLcdPort = 1 then
        begin
          FillChar(FDdram, SizeOf(FDdram), Ord(' '));
          FIncrement := True;
        end;
        FLcdAddress := 0;
        FCharacterRam := False;
        FLcdBusy := FClearCycles;
      end;
    4..7:
      FIncrement := (FLcdPort and 2) <> 0;
    8..15:
      FDisplayEnabled := (FLcdPort and 4) <> 0;
    $10..$17:
      MoveLcdAddress((FLcdPort and 4) <> 0);
    $40..$7F:
      begin
        FCharacterRam := True;
        FLcdAddress := FLcdPort and $3F;
      end;
    $80..$A7, $C0..$E7:
      begin
        FCharacterRam := False;
        FLcdAddress := FLcdPort and $7F;
      end;
    // The firmware sends $FF between characters after releasing the bus to read BF.
  end;
end;

procedure TSenarioIo.WriteLcdControl(Value: Byte);
begin
  var Falling := ((FLcdControl and 4) <> 0) and ((Value and 4) = 0);
  FLcdControl := Value and 7;
  if Falling and ((Value and 2) = 0) and ((FDirection and $F) = $F) and (FLcdBusy = 0) then
    WriteLcd;
end;

function TSenarioIo.ReadLcdPort: Byte;
begin
  if ((FLcdControl and 6) <> 6) or ((FDirection and $F) <> $A) then
    Exit(FLcdPort);
  if (FLcdControl and 1) = 0 then
    Exit(FLcdAddress or (Ord(FLcdBusy > 0) shl 7));
  if FCharacterRam then
    Result := FCgram[FLcdAddress]
  else
    Result := FDdram[FLcdAddress];
end;

function TSenarioIo.Read(Address: Word; out Value: Byte): Boolean;
begin
  case Address of
    $410E:
      Value := ReadLcdPort;
    $410F:
      Value := FPanelPort;
  else
    Exit(False);
  end;
  Result := True;
end;

function TSenarioIo.Write(Address: Word; Value: Byte): Boolean;
begin
  case Address of
    $4016:
      WriteLcdControl(Value);
    $410D:
      FDirection := Value;
    $410E:
      if (FDirection and $F) = $F then
        FLcdPort := Value;
    $410F:
      if (FDirection and $F0) = $F0 then
        WritePanelPort(Value);
  else
    Exit(False);
  end;
  Result := True;
end;

function TSenarioIo.LcdLine(Line: Integer): string;
begin
  if not FDisplayEnabled or (Line < 0) or (Line > 1) then
    Exit('');
  SetLength(Result, 8);
  for var I := 0 to 7 do
    Result[I + 1] := Char(FDdram[Line * $40 + I]);
end;

procedure TSenarioIo.SerializeState(State: TNesStateArchive);
begin
  State.Field(FDirection, SizeOf(FDirection));
  State.Field(FPanelPort, SizeOf(FPanelPort));
  State.Field(FLcdPort, SizeOf(FLcdPort));
  State.Field(FLcdControl, SizeOf(FLcdControl));
  State.Field(FAdcClock, SizeOf(FAdcClock));
  State.Field(FAdcCommand, SizeOf(FAdcCommand));
  State.Field(FAdcSample, SizeOf(FAdcSample));
  State.Field(FLcdAddress, SizeOf(FLcdAddress));
  State.Field(FLcdBusy, SizeOf(FLcdBusy));
  State.Field(FDisplayEnabled, SizeOf(FDisplayEnabled));
  State.Field(FIncrement, SizeOf(FIncrement));
  State.Field(FCharacterRam, SizeOf(FCharacterRam));
  State.Field(FDdram, SizeOf(FDdram));
  State.Field(FCgram, SizeOf(FCgram));
  if State.Loading and ((FLcdControl > 7) or (FAdcClock > 20) or (FAdcCommand > 7) or
    (FLcdBusy < 0) or (FLcdBusy > FClearCycles) or
    (FCharacterRam and (FLcdAddress > $3F)) or
    (not FCharacterRam and ((FLcdAddress > $67) or (FLcdAddress in [$28..$3F])))) then
    raise ENesException.Create('Invalid Senario tablet snapshot');
end;

end.

