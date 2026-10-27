unit RM.Gamepad.NES.Dendy;

interface

uses
  RM.Gamepad.NES.Standart;

type
  TGamepadNESDendy = class(TGamepadNESStandart)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  System.Types, System.SysUtils, Core.Emulation, RM.VirtualController;

procedure TGamepadNESDendy.BuildLayout;
begin
  inherited;
  // Keep START above the turbo buttons after moving it to the outer edge.
  Find('button' + IntToStr(Ord(TEmulatorButton.Start))).Bounds := RectF(136, 20, 224, 56);
  AddButton(TEmulatorButton.X, 'TB', TVirtualSide.Right, 52, 124, 64, 64);
  AddButton(TEmulatorButton.Y, 'TA', TVirtualSide.Right, 144, 88, 64, 64);
end;

end.

