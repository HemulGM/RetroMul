unit RM.Platforms.NGP.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadNGPStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadNGPCStandart = class(TGamepadNGPStandart)
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadNGPStandart.BuildLayout;
begin
  AddPad;
  AddMenus('', 'OPTION');
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 144, 172, 72, 72);
end;

end.

