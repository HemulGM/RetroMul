unit RM.Platforms.SegaArcade.Gamepads;

interface

uses
  RM.Gamepad.Base, RM.VirtualController;

type
  TGamepadSegaArcade = class(TPlatformGamepad)
  private
    FCoinButton, FStartButton, FServiceButton: TVirtualElement;
  protected
    procedure BuildLayout; override;
  public
    procedure ApplyLanguage; override;
  end;

implementation

uses
  Core.Emulation, FMX.Types;

procedure TGamepadSegaArcade.BuildLayout;
begin
  AddPad;
  FCoinButton := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 74, 88, 36, True);
  FStartButton := AddButton(TEmulatorButton.Start, '', TVirtualSide.Right, 136, 74, 88, 36, True);
  FServiceButton := AddButton(TEmulatorButton.Mode, '', TVirtualSide.Left, 16, 20, 104, 36, True);
  AddButton(TEmulatorButton.A, '1', TVirtualSide.Right, 12, 200, 60, 60);
  AddButton(TEmulatorButton.B, '2', TVirtualSide.Right, 88, 180, 60, 60);
  AddButton(TEmulatorButton.C, '3', TVirtualSide.Right, 164, 160, 60, 60);
  ApplyLanguage;
end;

procedure TGamepadSegaArcade.ApplyLanguage;
begin
  inherited;
  FCoinButton.Caption := Translate('Coin');
  FStartButton.Caption := Translate('Start');
  FServiceButton.Caption := Translate('Service');
end;

end.

