unit RM.Platforms.PSP.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPSP = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  System.Types, Core.Emulation, RM.VirtualController;

procedure TGamepadPSP.BuildLayout;
begin
  // These are vector elements on the existing virtual-controller canvas,
  // not separately positioned FMX controls.
  AddPad;
  Find('dpad').Bounds := RectF(12, 116, 132, 236);
  AddMenus;
  AddStick(RectF(136, 216, 232, 312));
  AddButton(TEmulatorButton.Y, 'Tri', TVirtualSide.Right, 88, 120, 60, 60, False, VirtualIconTriangle);
  AddButton(TEmulatorButton.X, 'Sq', TVirtualSide.Right, 16, 184, 60, 60, False, VirtualIconSquare);
  AddButton(TEmulatorButton.B, 'O', TVirtualSide.Right, 160, 184, 60, 60, False, VirtualIconCircle);
  AddButton(TEmulatorButton.A, 'X', TVirtualSide.Right, 88, 248, 60, 60, False, VirtualIconCross);
  AddButton(TEmulatorButton.C, 'L', TVirtualSide.Left, 16, 20, 104, 36, True);
  AddButton(TEmulatorButton.Z, 'R', TVirtualSide.Right, 120, 20, 104, 36, True);
end;

end.
