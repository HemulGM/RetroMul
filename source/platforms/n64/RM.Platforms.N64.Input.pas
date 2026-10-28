unit RM.Platforms.N64.Input;

{$I RM.Mobile.inc}

interface

uses
  RM.Input.Runtime, Core.Emulation;

const
  N64LAction = 4096;

type
  TN64InputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

implementation

uses
  System.SysUtils, System.Math, RM.Input, RM.Gamepad, Core.Platforms.N64.Adapter,
  N64.Console;

class procedure TN64InputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var N64Input: IN64ControllerInput;
  if Supports(Context.State.Session.Emulation, IN64ControllerInput, N64Input) then
    for var Port := 0 to 3 do
    begin
      var Pad := Default(TN64Pad);
      if ((Port = 0) and ((Context.State.Input.Gamepad.AuxiliaryButtons and 1) <> 0)) or
        ((Context.State.Input.Manager <> nil) and Context.State.Input.Manager.IsPressed(N64LAction + Port)) then
        Pad.Buttons := $20;
      if Input.Analog[Port].Valid then
      begin
        Pad.StickX := Round(Input.Analog[Port].X / 32767 * 80);
        Pad.StickY := -Round(Input.Analog[Port].Y / 32767 * 80);
      end;
      N64Input.SetN64Controller(Port, Pad);
    end;
end;

end.

