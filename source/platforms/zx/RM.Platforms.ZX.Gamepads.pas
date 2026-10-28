unit RM.Platforms.ZX.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadZX = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadZX.BuildLayout;
begin
  AddPad;
  AddMenus('1', 'ENTER');
  AddButton(TEmulatorButton.B, 'TAPE', TVirtualSide.Right, 10, 105, 65, 45);
  AddButton(TEmulatorButton.Mode, 'REW', TVirtualSide.Right, 95, 105, 65, 45);
  AddButton(TEmulatorButton.A, 'FIRE', TVirtualSide.Right, 100, 185, 80, 80);
end;

end.

