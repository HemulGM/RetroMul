unit RM.Gamepad.PCE.Pad2;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPCEPad2 = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadPCEPad2.BuildLayout;
begin
  AddPad;
  AddMenus('SELECT', 'RUN');
  AddButton(TEmulatorButton.B, 'II', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'I', TVirtualSide.Right, 144, 172, 72, 72);
end;

end.

