unit RM.Gamepad.SG1000.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadSG1000Standart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadSG1000Standart.BuildLayout;
begin
  AddPad;
  AddMenus('', 'PAUSE');
  AddButton(TEmulatorButton.A, '1', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.B, '2', TVirtualSide.Right, 144, 172, 72, 72);
end;

end.

