unit RM.Gamepad.Saturn.Analog;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadSaturnAnalog = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadSaturnAnalog.BuildLayout;
begin
  AddPad;
  AddStick;
  AddAnalogTriggers;
  // Below the right trigger, outside the six action buttons.
  AddButton(TEmulatorButton.Start, 'START', TVirtualSide.Right, 136, 116, 88, 28, True);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 12, 220, 60, 60);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 88, 220, 60, 60);
  AddButton(TEmulatorButton.C, 'C', TVirtualSide.Right, 164, 220, 60, 60);
  AddButton(TEmulatorButton.X, 'X', TVirtualSide.Right, 12, 148, 60, 60);
  AddButton(TEmulatorButton.Y, 'Y', TVirtualSide.Right, 88, 148, 60, 60);
  AddButton(TEmulatorButton.Z, 'Z', TVirtualSide.Right, 164, 148, 60, 60);
end;

end.

