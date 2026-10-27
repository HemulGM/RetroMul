unit RM.Gamepad.SEGA.Pad3;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadSEGAPad3 = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadSEGAPad3.BuildLayout;
begin
  AddPad;
  AddMenus('', 'START');
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 12, 216, 64, 64);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 88, 196, 64, 64);
  AddButton(TEmulatorButton.C, 'C', TVirtualSide.Right, 164, 176, 64, 64);
end;

end.

