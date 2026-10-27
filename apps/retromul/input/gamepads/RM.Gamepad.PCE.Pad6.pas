unit RM.Gamepad.PCE.Pad6;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPCEPad6 = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadPCEPad6.BuildLayout;
begin
  AddPad;
  AddMenus('SELECT', 'RUN');
  AddButton(TEmulatorButton.X, 'III', TVirtualSide.Right, 12, 220, 60, 60);
  AddButton(TEmulatorButton.B, 'II', TVirtualSide.Right, 88, 220, 60, 60);
  AddButton(TEmulatorButton.A, 'I', TVirtualSide.Right, 164, 220, 60, 60);
  AddButton(TEmulatorButton.Z, 'VI', TVirtualSide.Right, 12, 148, 60, 60);
  AddButton(TEmulatorButton.C, 'V', TVirtualSide.Right, 88, 148, 60, 60);
  AddButton(TEmulatorButton.Y, 'IV', TVirtualSide.Right, 164, 148, 60, 60);
end;

end.

