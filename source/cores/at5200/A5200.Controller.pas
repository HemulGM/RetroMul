unit A5200.Controller;

interface

uses
  Core.Emulation.Types;

type
  TA5200Keypads = array[0..3] of Word;

  TA5200Controller = class
  private
    FInput: TEmulatorInput;
    FKeypad: array[0..3] of Word;
    function Buttons(Port: Integer): TEmulatorButtons;
  public
    procedure SetInput(const Input: TEmulatorInput);
    procedure SetKeypad(Port: Integer; Mask: Word);
    function Pot(Index: Integer): Byte;
    function Trigger(Port: Integer): Byte;
    function Keyboard(Port: Integer): Byte;
    function TopButton(Port: Integer): Boolean;
  end;

implementation

uses
  System.Math;

procedure TA5200Controller.SetInput(const Input: TEmulatorInput);
begin
  FInput := Input;
end;

procedure TA5200Controller.SetKeypad(Port: Integer; Mask: Word);
begin
  if (Port >= 0) and (Port < 4) then
    FKeypad[Port] := Mask;
end;

function TA5200Controller.Buttons(Port: Integer): TEmulatorButtons;
begin
  case Port of
    0:
      Result := FInput.Buttons;
    1:
      Result := FInput.Buttons2;
    2:
      Result := FInput.Buttons3;
    3:
      Result := FInput.Buttons4;
  else
    Result := [];
  end;
end;

function TA5200Controller.Pot(Index: Integer): Byte;
begin
  var Port := Index div 2;
  var B := Buttons(Port);
  var V := 114;
  if FInput.Analog[Port].Valid then
    if Index and 1 = 0 then
      V := 114 + Round(FInput.Analog[Port].X * 105.0 / 32768)
    else
      V := 114 + Round(FInput.Analog[Port].Y * 105.0 / 32768);
  if Index and 1 = 0 then
  begin
    // Host axis bindings also generate digital directions. Keep their measured
    // position; keyboard/D-pad input remains available when the axis is neutral.
    if not FInput.Analog[Port].Valid or (FInput.Analog[Port].X = 0) then
    begin
      if TEmulatorButton.Left in B then
        V := 6;
      if TEmulatorButton.Right in B then
        V := 220;
    end;
  end
  else
  begin
    if not FInput.Analog[Port].Valid or (FInput.Analog[Port].Y = 0) then
    begin
      if TEmulatorButton.Up in B then
        V := 6;
      if TEmulatorButton.Down in B then
        V := 220;
    end;
  end;
  Result := EnsureRange(V, 1, 228);
end;

function TA5200Controller.Trigger(Port: Integer): Byte;
begin
  Result := Ord(not (TEmulatorButton.A in Buttons(Port)));
end;

function TA5200Controller.TopButton(Port: Integer): Boolean;
begin
  Result := TEmulatorButton.B in Buttons(Port);
end;

function TA5200Controller.Keyboard(Port: Integer): Byte;
const
  Codes: array[0..14] of Byte = ($05, $1F, $1D, $1B, $17, $15, $13, $0F, $0D, $0B, $07, $03, $19, $11, $09);
begin
  Result := $FF;
  var Mask := FKeypad[Port];
  var B := Buttons(Port);
  if TEmulatorButton.Start in B then
    Mask := Mask or (1 shl 12);
  if TEmulatorButton.Select in B then
    Mask := Mask or (1 shl 13);
  if TEmulatorButton.Mode in B then
    Mask := Mask or (1 shl 14);
  for var I := 0 to High(Codes) do
    if Mask and (1 shl I) <> 0 then
    begin
      Result := Codes[I];
      Break;
    end;
  if Result <> $FF then
    Result := Result or $20;
  if not TopButton(Port) then
    Result := Result or $40;
end;

end.

