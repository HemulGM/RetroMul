unit RM.Gamepad.NES.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadNESStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadNESStandart.BuildLayout;
begin
  AddPad;
  AddMenus;
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 144, 172, 72, 72);
end;

end.

