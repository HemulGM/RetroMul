unit RM.Platforms.Atari5200.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.VirtualController;

type
  TGamepadAtari5200Standart = class(TPlatformGamepad)
  protected
    FStartButton, FPauseButton, FResetButton, FFireButton, FTopButton: TVirtualElement;
    procedure BuildLayout; override;
    procedure BuildDirectionControl; virtual;
  public
    procedure ApplyLanguage; override;
  end;

  TGamepadAtari5200Analog = class(TGamepadAtari5200Standart)
  protected
    procedure BuildDirectionControl; override;
  end;

implementation

uses
  System.Types, Core.Emulation, FMX.Types;

procedure TGamepadAtari5200Standart.BuildLayout;
const
  Captions: array[0..11] of string = ('1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#');
  Keys: array[0..11] of Integer = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 11);
begin
  BuildDirectionControl;
  FStartButton := AddButton(TEmulatorButton.Start, '', TVirtualSide.Left, 16, 8, 88, 32, True);
  FPauseButton := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 46, 88, 32, True);
  FResetButton := AddButton(TEmulatorButton.Mode, '', TVirtualSide.Left, 16, 84, 88, 32, True);
  FFireButton := AddButton(TEmulatorButton.A, '', TVirtualSide.Right, 130, 240, 64, 64);
  FTopButton := AddButton(TEmulatorButton.B, '', TVirtualSide.Right, 42, 240, 64, 64);
  for var I := 0 to 11 do
  begin
    var X := 38 + (I mod 3) * 56;
    var Y := 12 + (I div 3) * 48;
    AddAuxiliaryButton(Keys[I], Captions[I], TVirtualSide.Right, TRectF.Create(X, Y, X + 48, Y + 40));
  end;
  ApplyLanguage;
end;

procedure TGamepadAtari5200Standart.ApplyLanguage;
begin
  inherited;
  FStartButton.Caption := Translate('Start');
  FPauseButton.Caption := Translate('Pause');
  FResetButton.Caption := Translate('Reset');
  FFireButton.Caption := Translate('Fire');
  FTopButton.Caption := Translate('Top fire');
end;

procedure TGamepadAtari5200Standart.BuildDirectionControl;
begin
  AddPad;
end;

procedure TGamepadAtari5200Analog.BuildDirectionControl;
begin
  AddStick(RectF(28, 140, 172, 284));
end;

end.

