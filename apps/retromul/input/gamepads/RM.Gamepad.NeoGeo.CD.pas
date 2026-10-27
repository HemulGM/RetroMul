unit RM.Gamepad.NeoGeo.CD;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadNeoGeoCD = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadNeoGeoCD.BuildLayout;
begin
  AddPad;
  AddMenus;
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 20, 204, 60, 60);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 92, 248, 60, 60);
  AddButton(TEmulatorButton.C, 'C', TVirtualSide.Right, 92, 136, 60, 60);
  AddButton(TEmulatorButton.X, 'D', TVirtualSide.Right, 164, 204, 60, 60);
end;

end.

