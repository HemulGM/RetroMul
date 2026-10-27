unit RM.Gamepad.SNES.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadSNESStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadSNESStandart.BuildLayout;
begin
  AddPad;
  AddMenus;
  AddButton(TEmulatorButton.Y, 'Y', TVirtualSide.Right, 16, 200, 60, 60);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 88, 248, 60, 60);
  AddButton(TEmulatorButton.X, 'X', TVirtualSide.Right, 88, 136, 60, 60);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 160, 200, 60, 60);
  AddButton(TEmulatorButton.C, 'L', TVirtualSide.Left, 16, 20, 104, 36, True);
  AddButton(TEmulatorButton.Z, 'R', TVirtualSide.Right, 120, 20, 104, 36, True);
end;

end.

