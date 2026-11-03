unit RM.Platforms.Atari2600.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.VirtualController;

type
  TGamepadAtari2600Standart = class(TPlatformGamepad)
  protected
    FSelectButton, FResetButton, FFireButton: TVirtualElement;
    procedure BuildLayout; override;
  public
    procedure ApplyLanguage; override;
  end;

  TGamepadAtari2600Paddles = class(TGamepadAtari2600Standart)
  protected
    FSecondFireButton: TVirtualElement;
    procedure BuildLayout; override;
  public
    procedure ApplyLanguage; override;
  end;

implementation

uses
  Core.Emulation, System.Types, FMX.Types;

procedure TGamepadAtari2600Standart.BuildLayout;
begin
  AddPad;
  FSelectButton := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 52, 88, 36, True);
  FResetButton := AddButton(TEmulatorButton.Start, '', TVirtualSide.Left, 16, 8, 88, 36, True);
  FFireButton := AddButton(TEmulatorButton.A, '', TVirtualSide.Right, 144, 220, 64, 64);
  ApplyLanguage;
end;

procedure TGamepadAtari2600Paddles.BuildLayout;
begin
  // X and Y are the two independent knobs on the same physical connector.
  AddStick(RectF(28, 140, 172, 284));
  FSelectButton := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 52, 88, 36, True);
  FResetButton := AddButton(TEmulatorButton.Start, '', TVirtualSide.Left, 16, 8, 88, 36, True);
  FFireButton := AddButton(TEmulatorButton.A, '', TVirtualSide.Right, 128, 210, 88, 64, True);
  FSecondFireButton := AddButton(TEmulatorButton.B, '', TVirtualSide.Right, 24, 210, 88, 64, True);
  ApplyLanguage;
end;

procedure TGamepadAtari2600Standart.ApplyLanguage;
begin
  inherited;
  FSelectButton.Caption := Translate('Select');
  FResetButton.Caption := Translate('Reset');
  FFireButton.Caption := Translate('Fire');
end;

procedure TGamepadAtari2600Paddles.ApplyLanguage;
begin
  inherited;
  FFireButton.Caption := Translate('Paddle 1');
  FSecondFireButton.Caption := Translate('Paddle 2');
end;

end.

