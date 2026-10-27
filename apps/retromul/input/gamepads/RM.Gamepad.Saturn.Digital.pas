unit RM.Gamepad.Saturn.Digital;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadSaturnDigital = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadSaturnDigital.BuildLayout;
begin
  AddPad;
  AddMenus('', 'START');
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 12, 220, 60, 60);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 88, 220, 60, 60);
  AddButton(TEmulatorButton.C, 'C', TVirtualSide.Right, 164, 220, 60, 60);
  AddButton(TEmulatorButton.X, 'X', TVirtualSide.Right, 12, 148, 60, 60);
  AddButton(TEmulatorButton.Y, 'Y', TVirtualSide.Right, 88, 148, 60, 60);
  AddButton(TEmulatorButton.Z, 'Z', TVirtualSide.Right, 164, 148, 60, 60);
  AddButton(TEmulatorButton.Select, 'L', TVirtualSide.Left, 16, 20, 104, 36, True);
  AddButton(TEmulatorButton.Mode, 'R', TVirtualSide.Right, 120, 20, 104, 36, True);
end;

end.

