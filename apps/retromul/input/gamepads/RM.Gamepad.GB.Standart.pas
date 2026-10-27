unit RM.Gamepad.GB.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadGBStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadGBStandart.BuildLayout;
begin
  AddPad;
  AddMenus;
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 144, 172, 72, 72);
end;

end.

