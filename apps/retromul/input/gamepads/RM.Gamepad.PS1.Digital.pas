unit RM.Gamepad.PS1.Digital;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPS1Digital = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  System.Types, Core.Emulation, RM.VirtualController, Core.Adapter.PS1;

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
