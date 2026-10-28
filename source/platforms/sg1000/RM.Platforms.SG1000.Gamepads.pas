unit RM.Platforms.SG1000.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadMultivisionStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadSG1000Standart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadSC3000Standart = class(TGamepadSG1000Standart)
  end;

type
  TGamepadSF7000Standart = class(TGamepadSG1000Standart)
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadMultivisionStandart.BuildLayout;
begin
  AddPad;
  AddMenus('', 'PAUSE');
  AddButton(TEmulatorButton.A, '1', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.B, '2', TVirtualSide.Right, 144, 172, 72, 72);
end;

procedure TGamepadSG1000Standart.BuildLayout;
begin
  AddPad;
  AddMenus('', 'PAUSE');
  AddButton(TEmulatorButton.A, '1', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.B, '2', TVirtualSide.Right, 144, 172, 72, 72);
end;

end.

