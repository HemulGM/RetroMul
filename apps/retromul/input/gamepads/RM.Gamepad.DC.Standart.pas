unit RM.Gamepad.DC.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadDCStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

// As on the Dreamcast controller: the stick above the D-pad, START between
// the halves, the face buttons in a diamond and the analog L/R triggers.
procedure TGamepadDCStandart.BuildLayout;
begin
  AddPad;
  AddStick;
  AddAnalogTriggers;
  AddButton(TEmulatorButton.Start, 'START', TVirtualSide.Right, 16, 40, 88, 32, True);
  AddButton(TEmulatorButton.Y, 'Y', TVirtualSide.Right, 88, 120, 60, 60);
  AddButton(TEmulatorButton.X, 'X', TVirtualSide.Right, 16, 184, 60, 60);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 160, 184, 60, 60);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 88, 248, 60, 60);
end;

end.
