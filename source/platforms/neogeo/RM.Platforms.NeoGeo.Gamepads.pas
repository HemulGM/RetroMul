unit RM.Platforms.NeoGeo.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadNeoGeoArcade = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadNeoGeoAES = class(TGamepadNeoGeoArcade)
  end;

type
  TGamepadNeoGeoCD = class(TPlatformGamepad)
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

