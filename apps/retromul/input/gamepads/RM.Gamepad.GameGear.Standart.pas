unit RM.Gamepad.GameGear.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadGameGearStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadGameGearStandart.BuildLayout;
begin
  AddPad;
  AddMenus('', 'START');
  AddButton(TEmulatorButton.A, '1', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.B, '2', TVirtualSide.Right, 144, 172, 72, 72);
end;

end.

