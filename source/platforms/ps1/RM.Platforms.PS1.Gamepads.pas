unit RM.Platforms.PS1.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPS1Analog = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadPS1Digital = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  System.Types, Core.Emulation, RM.VirtualController, Core.Platforms.PS1.Adapter;

// As on a DualShock: shoulder buttons along the top, D-pad and face buttons
// above both sticks, which sit low towards the middle; SELECT and START
// between the halves, ANALOG below the D-pad.
procedure TGamepadPS1Analog.BuildLayout;
begin
  AddAuxiliaryButton(Ord(TPS1Extra.L2), 'L2', TVirtualSide.Left, RectF(16, 8, 112, 40));
  AddButton(TEmulatorButton.C, 'L1', TVirtualSide.Left, 16, 48, 96, 32, True);
  AddButton(TEmulatorButton.Select, 'SELECT', TVirtualSide.Left, 136, 48, 88, 32, True);
  AddPad;
  Find('dpad').Bounds := RectF(12, 88, 132, 208);
  AddStick(RectF(128, 208, 228, 308));
  AddAuxiliaryButton(Ord(TPS1Extra.L3), 'L3', TVirtualSide.Left, RectF(16, 216, 112, 252));
  AddAuxiliaryButton(Ord(TPS1Extra.Analog), 'ANALOG', TVirtualSide.Left, RectF(16, 268, 112, 300));

  AddButton(TEmulatorButton.Mode, 'R2', TVirtualSide.Right, 128, 8, 96, 32, True);
  AddButton(TEmulatorButton.Z, 'R1', TVirtualSide.Right, 128, 48, 96, 32, True);
  AddButton(TEmulatorButton.Start, 'START', TVirtualSide.Right, 16, 48, 88, 32, True);
  AddButton(TEmulatorButton.Y, 'Tri', TVirtualSide.Right, 139, 81, 54, 54, False, VirtualIconTriangle);
  AddButton(TEmulatorButton.X, 'Sq', TVirtualSide.Right, 95, 125, 54, 54, False, VirtualIconSquare);
  AddButton(TEmulatorButton.B, 'O', TVirtualSide.Right, 183, 125, 54, 54, False, VirtualIconCircle);
  AddButton(TEmulatorButton.A, 'X', TVirtualSide.Right, 139, 169, 54, 54, False, VirtualIconCross);
  AddRightStick(RectF(12, 208, 112, 308));
  AddAuxiliaryButton(Ord(TPS1Extra.R3), 'R3', TVirtualSide.Right, RectF(128, 216, 224, 252));
end;

procedure TGamepadPS1Digital.BuildLayout;
begin
  AddPad;
  AddMenus;
  // Face buttons in the PlayStation diamond; L1/L2 and R2/R1 along the top.
  AddButton(TEmulatorButton.Y, 'Tri', TVirtualSide.Right, 88, 120, 60, 60, False, VirtualIconTriangle);
  AddButton(TEmulatorButton.X, 'Sq', TVirtualSide.Right, 16, 184, 60, 60, False, VirtualIconSquare);
  AddButton(TEmulatorButton.B, 'O', TVirtualSide.Right, 160, 184, 60, 60, False, VirtualIconCircle);
  AddButton(TEmulatorButton.A, 'X', TVirtualSide.Right, 88, 248, 60, 60, False, VirtualIconCross);
  AddButton(TEmulatorButton.C, 'L1', TVirtualSide.Left, 16, 20, 104, 36, True);
  AddButton(TEmulatorButton.Z, 'R1', TVirtualSide.Right, 120, 20, 104, 36, True);
  AddAuxiliaryButton(Ord(TPS1Extra.L2), 'L2', TVirtualSide.Left, RectF(128, 20, 216, 56));
  AddButton(TEmulatorButton.Mode, 'R2', TVirtualSide.Right, 24, 20, 88, 36, True);
end;

end.

