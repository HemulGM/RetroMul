unit RM.Gamepad.CPS.Arcade;

interface

uses RM.Gamepad.Base;

type
  TGamepadCPSArcade = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses Core.Emulation, RM.VirtualController;

procedure TGamepadCPSArcade.BuildLayout;
begin
  AddPad;
  AddMenus('COIN','START');
  AddButton(TEmulatorButton.Mode,'SERVICE',TVirtualSide.Left,16,20,104,36,True);
  // Capcom six-button panel: light / medium / heavy punches above kicks.
  AddButton(TEmulatorButton.A,'LP',TVirtualSide.Right,12,148,60,60);
  AddButton(TEmulatorButton.B,'MP',TVirtualSide.Right,88,148,60,60);
  AddButton(TEmulatorButton.C,'HP',TVirtualSide.Right,164,148,60,60);
  AddButton(TEmulatorButton.X,'LK',TVirtualSide.Right,12,220,60,60);
  AddButton(TEmulatorButton.Y,'MK',TVirtualSide.Right,88,220,60,60);
  AddButton(TEmulatorButton.Z,'HK',TVirtualSide.Right,164,220,60,60);
end;

end.
