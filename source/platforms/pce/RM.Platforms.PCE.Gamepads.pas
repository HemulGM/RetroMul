unit RM.Platforms.PCE.Gamepads;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPCEPad2 = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadPCEPad6 = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

type
  TGamepadPCECDPad2 = class(TGamepadPCEPad2)
  end;

type
  TGamepadPCECDPad6 = class(TGamepadPCEPad6)
  end;

type
  TGamepadSuperGrafxPad2 = class(TGamepadPCEPad2)
  end;

type
  TGamepadSuperGrafxPad6 = class(TGamepadPCEPad6)
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadPCEPad2.BuildLayout;
begin
  AddPad;
  AddMenus('SELECT', 'RUN');
  AddButton(TEmulatorButton.B, 'II', TVirtualSide.Right, 52, 208, 72, 72);
  AddButton(TEmulatorButton.A, 'I', TVirtualSide.Right, 144, 172, 72, 72);
end;

procedure TGamepadPCEPad6.BuildLayout;
begin
  AddPad;
  AddMenus('SELECT', 'RUN');
  AddButton(TEmulatorButton.X, 'III', TVirtualSide.Right, 12, 220, 60, 60);
  AddButton(TEmulatorButton.B, 'II', TVirtualSide.Right, 88, 220, 60, 60);
  AddButton(TEmulatorButton.A, 'I', TVirtualSide.Right, 164, 220, 60, 60);
  AddButton(TEmulatorButton.Z, 'VI', TVirtualSide.Right, 12, 148, 60, 60);
  AddButton(TEmulatorButton.C, 'V', TVirtualSide.Right, 88, 148, 60, 60);
  AddButton(TEmulatorButton.Y, 'IV', TVirtualSide.Right, 164, 148, 60, 60);
end;

end.

