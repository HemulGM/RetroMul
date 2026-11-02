unit RM.Platforms.Jaguar.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.VirtualController;

type
  TGamepadJaguar = class(TPlatformGamepad)
  protected
    FStartButton, FOptionButton, FFireButton, FBButton, FCButton: TVirtualElement;
    procedure BuildLayout; override;
    procedure BuildDirectionControl; virtual;
  public
    procedure ApplyLanguage; override;
  end;

implementation

uses
  System.Types, Core.Emulation, FMX.Types;

procedure TGamepadJaguar.BuildLayout;
const
  Captions: array[0..11] of string = ('1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#');
  Keys: array[0..11] of Integer = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 11);
begin
  BuildDirectionControl;
  FStartButton := AddButton(TEmulatorButton.Start, '', TVirtualSide.Left, 16, 8, 88, 32, True);
  FOptionButton := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 46, 88, 32, True);
  FFireButton := AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 150, 204, 52, 52);
  FBButton := AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 90, 214, 52, 52);
  FCButton := AddButton(TEmulatorButton.C, 'C', TVirtualSide.Right, 30, 204, 52, 52);
  AddButton(TEmulatorButton.X, 'X', TVirtualSide.Right, 150, 264, 52, 44);
  AddButton(TEmulatorButton.Y, 'Y', TVirtualSide.Right, 90, 274, 52, 44);
  AddButton(TEmulatorButton.Z, 'Z', TVirtualSide.Right, 30, 264, 52, 44);
  for var I := 0 to 11 do
  begin
    var X := 38 + (I mod 3) * 56;
    var Y := 12 + (I div 3) * 48;
    AddAuxiliaryButton(Keys[I], Captions[I], TVirtualSide.Right, TRectF.Create(X, Y, X + 48, Y + 40));
  end;
  ApplyLanguage;
end;

procedure TGamepadJaguar.ApplyLanguage;
begin
  inherited;
  FStartButton.Caption := Translate('Pause');
  FOptionButton.Caption := Translate('Option');
  FFireButton.Caption := 'A';
  FBButton.Caption := 'B';
  FCButton.Caption := 'C';
end;

procedure TGamepadJaguar.BuildDirectionControl;
begin
  AddPad;
end;

end.

