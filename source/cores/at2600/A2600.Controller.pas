unit A2600.Controller;

interface

uses
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots;

type
  TA2600Controller = class
  private
    FInput: TEmulatorInput;
    FDevices: array[0..1] of string;
    FPosition: array[0..3] of Double;
    FPreviousAxis: array[0..3] of Integer;
    FPreviousValid, FInvert: array[0..3] of Boolean;
    FMinimum, FMaximum, FDeadZone: array[0..3] of Integer;
    FSpeed: array[0..1] of Integer;
    FMouse: array[0..1] of Boolean;
    FMouseSensitivity: array[0..1] of Integer;
    FMouseButtons: Byte;
  public
    constructor Create;
    procedure Configure(const Ports: TCoreInputPorts);
    procedure SetInput(const Input: TEmulatorInput);
    procedure Update(Seconds: Double);
    procedure ApplyMouse(DX, DY: Integer; Buttons: Byte);
    function Resistance(Index: Integer): Integer;
    function UsesPaddles(Port: Integer): Boolean;
    function ReadJoysticks: Byte;
    function ReadSwitches(Switches: Byte): Byte;
    function FirePressed(Port: Integer): Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

constructor TA2600Controller.Create;
begin
  inherited;
  for var Index := 0 to 3 do
    FPosition[Index] := 0.5;
  Configure(TCoreInputPorts.Defaults);
end;

procedure TA2600Controller.Configure(const Ports: TCoreInputPorts);
begin
  for var Port := 0 to 1 do
  begin
    if FDevices[Port] <> Ports.Devices[Port] then
      for var Knob := 0 to 1 do
        FPreviousValid[Port * 2 + Knob] := False;
    FDevices[Port] := Ports.Devices[Port];
    var Section := 'Paddles' + IntToStr(Port + 1) + '.';
    FSpeed[Port] := EnsureRange(StrToIntDef(Ports.Option(Section + 'Speed', '100'), 100), 1, 400);
    FMouse[Port] := SameText(Ports.Option(Section + 'Mouse', 'False'), 'True');
    FMouseSensitivity[Port] := EnsureRange(StrToIntDef(Ports.Option(Section + 'MouseSensitivity', '100'), 100), 1, 400);
    for var Knob := 0 to 1 do
    begin
      var Index := Port * 2 + Knob;
      var Suffix := IntToStr(Knob + 1);
      FMinimum[Index] := EnsureRange(StrToIntDef(Ports.Option(Section + 'Minimum' + Suffix, '0'), 0), 0, 99);
      FMaximum[Index] := EnsureRange(StrToIntDef(Ports.Option(Section + 'Maximum' + Suffix, '100'), 100), FMinimum[Index] + 1, 100);
      FDeadZone[Index] := EnsureRange(StrToIntDef(Ports.Option(Section + 'DeadZone' + Suffix, '2'), 2), 0, 30);
      FInvert[Index] := SameText(Ports.Option(Section + 'Invert' + Suffix, 'False'), 'True') or
        (Ports.Option(Section + 'Invert' + Suffix, '0') = '1');
    end;
  end;
end;

function TA2600Controller.UsesPaddles(Port: Integer): Boolean;
begin
  Result := (FDevices[Port] = 'pad-analog') or (FDevices[Port] = 'paddles');
end;

procedure TA2600Controller.Update(Seconds: Double);
const
  Decrease: array[0..1] of TEmulatorButton = (TEmulatorButton.Left, TEmulatorButton.Up);
  Increase: array[0..1] of TEmulatorButton = (TEmulatorButton.Right, TEmulatorButton.Down);
begin
  for var Port := 0 to 1 do
  begin
    if not UsesPaddles(Port) then
      Continue;
    var Buttons := FInput.Buttons;
    if Port = 1 then
      Buttons := FInput.Buttons2;
    for var Knob := 0 to 1 do
    begin
      var Index := Port * 2 + Knob;
      var Axis := Integer(FInput.Analog[Port].X);
      if Knob = 1 then
        Axis := FInput.Analog[Port].Y;
      var DeadZone := Round(32768 * FDeadZone[Index] / 100);
      if Abs(Axis) <= DeadZone then
        Axis := 0;
      var Valid := FInput.Analog[Port].Valid and not FMouse[Port];
      // Host axis bindings also assert digital directions. Preserve the axis.
      // Detect centering once so keyboard motion can then retain its position.
      if Valid and ((Axis <> 0) or not FPreviousValid[Index] or (FPreviousAxis[Index] <> 0)) then
        FPosition[Index] := (Axis + 32768.0) / 65535.0
      else
      begin
        var Direction := Ord(Increase[Knob] in Buttons) - Ord(Decrease[Knob] in Buttons);
        FPosition[Index] := EnsureRange(FPosition[Index] + Direction * Seconds * FSpeed[Port] / 100, 0.0, 1.0);
      end;
      FPreviousAxis[Index] := Axis;
      FPreviousValid[Index] := Valid;
    end;
  end;
end;

procedure TA2600Controller.ApplyMouse(DX, DY: Integer; Buttons: Byte);
begin
  FMouseButtons := Buttons;
  for var Port := 0 to 1 do
    if UsesPaddles(Port) and FMouse[Port] then
    begin
      FPosition[Port * 2] := EnsureRange(FPosition[Port * 2] + DX * FMouseSensitivity[Port] / 40000.0, 0.0, 1.0);
      FPosition[Port * 2 + 1] := EnsureRange(FPosition[Port * 2 + 1] + DY * FMouseSensitivity[Port] / 40000.0, 0.0, 1.0);
    end;
end;

function TA2600Controller.Resistance(Index: Integer): Integer;
begin
  if not UsesPaddles(Index div 2) then
    Exit(-1);
  var Position := FPosition[Index];
  if FInvert[Index] then
    Position := 1 - Position;
  Result := Round((FMinimum[Index] + Position * (FMaximum[Index] - FMinimum[Index])) * 10000);
end;

procedure TA2600Controller.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

function TA2600Controller.ReadJoysticks: Byte;
begin
  Result := $FF;
  for var Port := 0 to 1 do
  begin
    var Buttons := FInput.Buttons;
    if Port = 1 then
      Buttons := FInput.Buttons2;
    if FDevices[Port] = 'none' then
      Continue;
    if UsesPaddles(Port) then
    begin
      if (TEmulatorButton.A in Buttons) or (FMouse[Port] and (FMouseButtons and 1 <> 0)) then
        Result := Result and not (1 shl (7 - Port * 4));
      if (TEmulatorButton.B in Buttons) or (FMouse[Port] and (FMouseButtons and 2 <> 0)) then
        Result := Result and not (1 shl (6 - Port * 4));
      Continue;
    end;
    for var B := 0 to 3 do
      if TEmulatorButton(B) in Buttons then
        Result := Result and not (1 shl (B + (1 - Port) * 4));
  end;
end;

function TA2600Controller.ReadSwitches(Switches: Byte): Byte;
begin
  Result := Switches;
  var Buttons := FInput.Buttons + FInput.Buttons2;
  if TEmulatorButton.Start in Buttons then
    Result := Result and $FE;
  if TEmulatorButton.Select in Buttons then
    Result := Result and $FD;
end;

function TA2600Controller.FirePressed(Port: Integer): Boolean;
begin
  if UsesPaddles(Port) or (FDevices[Port] = 'none') then
    Exit(False);
  if Port = 0 then
    Result := TEmulatorButton.A in FInput.Buttons
  else
    Result := TEmulatorButton.A in FInput.Buttons2;
end;

procedure TA2600Controller.SerializeState(State: TStateArchive);
begin
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FPreviousAxis, SizeOf(FPreviousAxis));
  State.Field(FPreviousValid, SizeOf(FPreviousValid));
  if State.Loading then
    for var Index := 0 to 3 do
      if IsNan(FPosition[Index]) or IsInfinite(FPosition[Index]) or
        (FPosition[Index] < 0) or (FPosition[Index] > 1) or
        (FPreviousAxis[Index] < -32768) or (FPreviousAxis[Index] > 32767) then
        raise EReadError.Create('Invalid Atari 2600 paddle position');
end;

end.

