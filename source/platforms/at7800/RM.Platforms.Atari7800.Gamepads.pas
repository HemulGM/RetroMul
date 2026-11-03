unit RM.Platforms.Atari7800.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.VirtualController;

type
  TGamepadAtari7800 = class(TPlatformGamepad)
  protected
    FResetButton, FSelectButton, FPauseButton: TVirtualElement;
    procedure BuildLayout; override;
  public
    procedure ApplyLanguage; override;
  end;

implementation

uses
  Core.Emulation.Types, FMX.Types;

procedure TGamepadAtari7800.BuildLayout;
begin
  AddPad;
  AddButton(TEmulatorButton.A, '1', TVirtualSide.Right, 120, 210, 64, 64);
  AddButton(TEmulatorButton.B, '2', TVirtualSide.Right, 36, 210, 64, 64);
  FResetButton := AddButton(TEmulatorButton.Start, '', TVirtualSide.Left, 16, 8, 88, 32, True);
  FSelectButton := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 46, 88, 32, True);
  FPauseButton := AddButton(TEmulatorButton.Mode, '', TVirtualSide.Left, 16, 84, 88, 32, True);
  ApplyLanguage;
end;

procedure TGamepadAtari7800.ApplyLanguage;
begin
  inherited;
  FResetButton.Caption := Translate('Reset');
  FSelectButton.Caption := Translate('Select');
  FPauseButton.Caption := Translate('Pause');
end;

end.

