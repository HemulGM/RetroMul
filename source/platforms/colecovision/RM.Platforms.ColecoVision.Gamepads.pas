unit RM.Platforms.ColecoVision.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadColecoVision = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

  TGamepadColecoSuperAction = class(TGamepadColecoVision)
  protected
    procedure BuildLayout; override;
  end;

  TGamepadColecoDriving = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

  TGamepadColecoRoller = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation.Types, RM.VirtualController, System.Types, System.SysUtils;

procedure TGamepadColecoVision.BuildLayout;
begin
  AddPad;
  AddButton(TEmulatorButton.A, 'L', TVirtualSide.Left, 28, 62, 64, 64);
  AddButton(TEmulatorButton.B, 'R', TVirtualSide.Left, 116, 62, 64, 64);
  for var I := 0 to 11 do
  begin
    var Digit := I + 1;
    var Caption := IntToStr(Digit);
    if I = 9 then
    begin
      Digit := 10;
      Caption := '*';
    end;
    if I = 10 then
    begin
      Digit := 0;
      Caption := '0';
    end;
    if I = 11 then
    begin
      Digit := 11;
      Caption := '#';
    end;
    var X := 24 + (I mod 3) * 64;
    var Y := 40 + (I div 3) * 60;
    if Digit = 1 then
      AddButton(TEmulatorButton.Start, Caption, TVirtualSide.Right, X, Y, 56, 52, True)
    else if Digit = 2 then
      AddButton(TEmulatorButton.Select, Caption, TVirtualSide.Right, X, Y, 56, 52, True)
    else
      AddAuxiliaryButton(Digit, Caption, TVirtualSide.Right, RectF(X, Y, X + 56, Y + 52));
  end;
end;

procedure TGamepadColecoSuperAction.BuildLayout;
begin
  inherited;
  AddButton(TEmulatorButton.X, 'BLUE', TVirtualSide.Left, 28, 8, 64, 44, True);
  AddButton(TEmulatorButton.Y, 'PURPLE', TVirtualSide.Left, 116, 8, 64, 44, True);
  AddAuxiliaryButton(12, 'S-', TVirtualSide.Left, RectF(184, 144, 232, 200));
  AddAuxiliaryButton(13, 'S+', TVirtualSide.Left, RectF(184, 220, 232, 276));
end;

procedure TGamepadColecoDriving.BuildLayout;
begin
  AddStick(RectF(28, 140, 172, 284));
  AddButton(TEmulatorButton.Left, 'LEFT', TVirtualSide.Left, 28, 62, 64, 64);
  AddButton(TEmulatorButton.Right, 'RIGHT', TVirtualSide.Left, 116, 62, 64, 64);
  AddButton(TEmulatorButton.A, 'GAS', TVirtualSide.Right, 80, 180, 88, 88);
end;

procedure TGamepadColecoRoller.BuildLayout;
begin
  AddStick(RectF(28, 140, 172, 284));
  AddButton(TEmulatorButton.A, 'L', TVirtualSide.Right, 28, 180, 72, 72);
  AddButton(TEmulatorButton.B, 'R', TVirtualSide.Right, 128, 180, 72, 72);
end;

end.

