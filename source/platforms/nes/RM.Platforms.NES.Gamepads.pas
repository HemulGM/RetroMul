unit RM.Platforms.NES.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadNESStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadNESDendy = class(TGamepadNESStandart)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController, System.Types, System.SysUtils;

procedure TGamepadNESStandart.BuildLayout;
begin
  AddPad;
  AddMenus;
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 144, 172, 72, 72);
end;

procedure TGamepadNESDendy.BuildLayout;
begin
  inherited;
  // Keep START above the turbo buttons after moving it to the outer edge.
  Find('button' + IntToStr(Ord(TEmulatorButton.Start))).Bounds := RectF(136, 20, 224, 56);
  AddButton(TEmulatorButton.X, 'TB', TVirtualSide.Right, 52, 124, 64, 64);
  AddButton(TEmulatorButton.Y, 'TA', TVirtualSide.Right, 144, 88, 64, 64);
end;

end.

