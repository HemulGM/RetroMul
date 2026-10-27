unit RM.Gamepad.NeoGeo.Arcade;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadNeoGeoArcade = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadNeoGeoArcade.BuildLayout;
begin
  AddPad;
  AddMenus('COIN', 'START');
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 12, 236, 52, 52);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 66, 202, 52, 52);
  AddButton(TEmulatorButton.C, 'C', TVirtualSide.Right, 120, 168, 52, 52);
  AddButton(TEmulatorButton.X, 'D', TVirtualSide.Right, 174, 134, 52, 52);
end;

end.

