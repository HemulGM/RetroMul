unit RM.Platforms.NES.GamepadCompatibility;

interface

uses
  System.Classes, RM.Gamepad, NES.Controller, Core.Emulation, System.Types;

type
  TNesGamepad = class(TScreenGamepad)
  private
    function GetNesButtons: TNesButtons;
  public
    constructor Create(AOwner: TComponent); override;
    function ButtonBounds(Button: TNesButton): TRectF; reintroduce;
    property Buttons: TNesButtons read GetNesButtons;
  end;

implementation

uses
  RM.Gamepad.Factory, RM.Gamepad.Base;

const
  NesButtonMap: array[TNesButton] of TEmulatorButton =
    (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select,
    TEmulatorButton.Start, TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right);

constructor TNesGamepad.Create(AOwner: TComponent);
begin
  inherited;
  var PadClass: TPlatformGamepadClass;
  if TryGamepadClass('nes', 'pad', PadClass) then
    Configure('nes', 'pad', [Low(TEmulatorButton)..High(TEmulatorButton)]);
end;

function TNesGamepad.GetNesButtons: TNesButtons;
begin
  Result := [];
  for var Button := Low(TNesButton) to High(TNesButton) do
    if NesButtonMap[Button] in inherited Buttons then
      Include(Result, Button);
end;

function TNesGamepad.ButtonBounds(Button: TNesButton): TRectF;
begin
  Result := inherited ButtonBounds(NesButtonMap[Button]);
end;

end.

