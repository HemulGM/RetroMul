unit RM.Platforms.WS.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadWSStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

  TGamepadWSCStandart = class(TGamepadWSStandart)
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadWSStandart.BuildLayout;
begin
  AddPad;
  AddMenus('', 'START');
  AddButton(TEmulatorButton.X, 'Y1', TVirtualSide.Left, 76, 2, 48, 40);
  AddButton(TEmulatorButton.Y, 'Y2', TVirtualSide.Left, 126, 44, 48, 40);
  AddButton(TEmulatorButton.Z, 'Y3', TVirtualSide.Left, 76, 86, 48, 40);
  AddButton(TEmulatorButton.C, 'Y4', TVirtualSide.Left, 26, 44, 48, 40);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 44, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 140, 164, 72, 72);
end;

end.

