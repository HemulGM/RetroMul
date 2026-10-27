unit RM.Gamepad.SEGA.Pad6;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadSEGAPad6 = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadSEGAPad6.BuildLayout;
begin
  AddPad;
  AddMenus('', 'START');
  AddButton(TEmulatorButton.Mode, 'MODE', TVirtualSide.Left, 16, 74, 88, 36, True);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 12, 220, 60, 60);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 88, 220, 60, 60);
  AddButton(TEmulatorButton.C, 'C', TVirtualSide.Right, 164, 220, 60, 60);
  AddButton(TEmulatorButton.X, 'X', TVirtualSide.Right, 12, 148, 60, 60);
  AddButton(TEmulatorButton.Y, 'Y', TVirtualSide.Right, 88, 148, 60, 60);
  AddButton(TEmulatorButton.Z, 'Z', TVirtualSide.Right, 164, 148, 60, 60);
end;

end.

