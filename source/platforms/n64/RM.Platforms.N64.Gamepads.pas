unit RM.Platforms.N64.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadN64Standart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  System.Types, Core.Emulation, RM.VirtualController;

procedure TGamepadN64Standart.BuildLayout;
begin
  AddPad;
  Find('dpad').Bounds := RectF(28, 132, 172, 276);
  AddStick;
  // Put Z/L and START along the bottom edge, clear of the stick and D-pad.
  AddAuxiliaryButton(0, 'L', TVirtualSide.Left, RectF(88, 284, 176, 320));
  AddButton(TEmulatorButton.Select, 'Z', TVirtualSide.Left, 16, 284, 60, 36, True);
  AddButton(TEmulatorButton.Start, 'START', TVirtualSide.Right, 144, 284, 88, 36, True);
  AddButton(TEmulatorButton.Mode, 'R', TVirtualSide.Right, 120, 20, 104, 36, True);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 12, 180, 60, 60);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 72, 244, 64, 64);
  AddButton(TEmulatorButton.X, 'C-L', TVirtualSide.Right, 86, 134, 40, 40, False, VirtualIconLeft);
  AddButton(TEmulatorButton.Y, 'C-U', TVirtualSide.Right, 130, 90, 40, 40, False, VirtualIconUp);
  AddButton(TEmulatorButton.Z, 'C-R', TVirtualSide.Right, 174, 134, 40, 40, False, VirtualIconRight);
  AddButton(TEmulatorButton.C, 'C-D', TVirtualSide.Right, 130, 178, 40, 40, False, VirtualIconDown);
end;

end.

