unit RM.Platforms.SMS.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.Platforms.SG1000.Gamepads;

type
  TGamepadGameGearStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadSMSStandart = class(TGamepadSG1000Standart)
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

