unit RM.Platforms.Lynx.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.VirtualController;

type
  TGamepadLynxStandard = class(TPlatformGamepad)
  private
    FOption1Button, FOption2Button, FPauseButton: TVirtualElement;
  protected
    procedure BuildLayout; override;
  public
    procedure ApplyLanguage; override;
  end;

implementation

uses
  Core.Emulation, FMX.Types;

procedure TGamepadLynxStandard.BuildLayout;
begin
  AddPad;
  FOption1Button := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 74, 104, 36, True);
  FOption2Button := AddButton(TEmulatorButton.C, '', TVirtualSide.Right, 16, 74, 112, 36, True);
  FPauseButton := AddButton(TEmulatorButton.Start, '', TVirtualSide.Right, 144, 74, 80, 36, True, VirtualIconPause);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 144, 172, 72, 72);
  ApplyLanguage;
end;

procedure TGamepadLynxStandard.ApplyLanguage;
begin
  inherited;
  FOption1Button.Caption := Translate('OPTION 1');
  FOption2Button.Caption := Translate('OPTION 2');
  FPauseButton.Caption := Translate('PAUSE');
end;

end.

