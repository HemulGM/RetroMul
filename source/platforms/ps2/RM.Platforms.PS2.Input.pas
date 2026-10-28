unit RM.Platforms.PS2.Input;

interface

uses RM.Input.Runtime, Core.Emulation;

type
  TPS2InputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

implementation

uses System.SysUtils, System.Math, RM.Platforms.PS1.Input, Core.Platforms.PS1.Adapter,
  Core.Platforms.PS2.Adapter, PS1.SIO, RM.Gamepad;

class procedure TPS2InputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Controller: IPS2ControllerInput;
  if not Supports(Context.State.Session.Emulation, IPS2ControllerInput, Controller) then Exit;
  for var Port := 0 to 1 do
  begin
    // PS2 retains the existing PlayStation action IDs and DualShock layout.
    var Pad := ReadPS1Pad(Context.State.Input.Manager, Port);
    if Port = 0 then
    begin
      var Aux := Context.State.Input.Gamepad.AuxiliaryButtons;
      if (Aux and (1 shl Ord(TPS1Extra.L2))) <> 0 then Pad.Buttons := Pad.Buttons or PS1PadL2;
      if (Aux and (1 shl Ord(TPS1Extra.L3))) <> 0 then Pad.Buttons := Pad.Buttons or PS1PadL3;
      if (Aux and (1 shl Ord(TPS1Extra.R3))) <> 0 then Pad.Buttons := Pad.Buttons or PS1PadR3;
      if (Aux and (1 shl Ord(TPS1Extra.Analog))) <> 0 then Pad.AnalogButton := True;
      var Right := Context.State.Input.Gamepad.RightAnalogInput;
      if Right.Valid then
      begin
        Pad.RightX := EnsureRange(Integer(Pad.RightX) + Right.X, -32768, 32767);
        Pad.RightY := EnsureRange(Integer(Pad.RightY) + Right.Y, -32768, 32767);
      end;
    end;
    var Pad2: TPS2Pad;
    Pad2.Buttons := Pad.Buttons;
    Pad2.AnalogButton := Pad.AnalogButton;
    Pad2.LeftX := Pad.LeftX; Pad2.LeftY := Pad.LeftY;
    Pad2.RightX := Pad.RightX; Pad2.RightY := Pad.RightY;
    Controller.SetPS2Controller(Port, Pad2);
  end;
end;

end.
