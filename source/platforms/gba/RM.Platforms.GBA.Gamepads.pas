unit RM.Platforms.GBA.Gamepads;

interface

uses
  RM.Platforms.GB.Gamepads;

type
  TGamepadGBAStandart = class(TGamepadGBStandart)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadGBAStandart.BuildLayout;
begin
  inherited;
  AddButton(TEmulatorButton.C, 'L', TVirtualSide.Left, 16, 20, 104, 36, True);
  AddButton(TEmulatorButton.Z, 'R', TVirtualSide.Right, 120, 20, 104, 36, True);
end;

end.

