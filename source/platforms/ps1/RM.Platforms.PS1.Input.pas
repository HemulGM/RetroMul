unit RM.Platforms.PS1.Input;

{$I RM.Mobile.inc}

interface

uses
  RM.Platform.Host, System.IniFiles, FMXInput, RM.Input,
  Core.Platforms.PS1.Adapter, RM.Input.Runtime, Core.Emulation;

const
  PS1ExtraAction = 4112;

type
  TPS1InputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

function PS1Action(Port: Integer; Extra: TPS1Extra): Integer;

function PS1ExtraName(Extra: TPS1Extra): string;

function ReadPS1Pad(Input: IPlatformInput; Port: Integer): TPS1Pad;

procedure FilterPS1CompatibilityBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);

implementation

uses
  System.SysUtils, System.Math, RM.Gamepad, PS1.SIO;

function PS1Action(Port: Integer; Extra: TPS1Extra): Integer;
begin
  Result := PS1ExtraAction + Port * 16 + Ord(Extra);
end;

function PS1ExtraName(Extra: TPS1Extra): string;
const
  Names: array[TPS1Extra] of string = ('L2', 'L3', 'R3', 'Analog', 'LS ↑', 'LS ↓', 'LS ←', 'LS →', 'RS ↑', 'RS ↓',
    'RS ←', 'RS →');
begin
  Result := Names[Extra];
end;

function ReadPS1Pad(Input: IPlatformInput; Port: Integer): TPS1Pad;

  function Axis(Negative, Positive: TPS1Extra): SmallInt;
  begin
    var Amount := Input.ActionAmount(PS1Action(Port, Positive)) -
      Input.ActionAmount(PS1Action(Port, Negative));
    Result := EnsureRange(Round(Amount * 32767), -32768, 32767);
  end;

begin
  Result := Default(TPS1Pad);
  if Input = nil then
    Exit;

  if Input.IsActionPressed(PS1Action(Port, TPS1Extra.L2)) then
    Result.Buttons := Result.Buttons or PS1PadL2;
  if Input.IsActionPressed(PS1Action(Port, TPS1Extra.L3)) then
    Result.Buttons := Result.Buttons or PS1PadL3;
  if Input.IsActionPressed(PS1Action(Port, TPS1Extra.R3)) then
    Result.Buttons := Result.Buttons or PS1PadR3;
  Result.AnalogButton := Input.IsActionPressed(PS1Action(Port, TPS1Extra.Analog));
  Result.LeftX := Axis(TPS1Extra.LeftLeft, TPS1Extra.LeftRight);
  Result.LeftY := Axis(TPS1Extra.LeftUp, TPS1Extra.LeftDown);
  Result.RightX := Axis(TPS1Extra.RightLeft, TPS1Extra.RightRight);
  Result.RightY := Axis(TPS1Extra.RightUp, TPS1Extra.RightDown);
end;

procedure FilterPS1CompatibilityBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);
begin
  if (Binding.Action >= PS1ExtraAction) and (Binding.Action < PS1ExtraAction + 2 * 16) then
    Policy.SourceKey := 'Source' + IntToStr((Binding.Action - PS1ExtraAction) div 16 + 1);
end;

class procedure TPS1InputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  // PlayStation L2/L3/R3, ANALOG and the right stick sit outside the logical
  // pad; on-screen auxiliary button N is TPS1Extra(N).
  var PS1Input: IPS1ControllerInput;
  if Supports(Context.Host.Core, IPS1ControllerInput, PS1Input) then
    for var Port := 0 to 1 do
    begin
      var Pad := ReadPS1Pad(Context.Host.Input, Port);
      if (Port = 0) and (Context.Gamepad <> nil) then
      begin
        var Auxiliary := Context.Gamepad.AuxiliaryButtons;
        if (Auxiliary and (1 shl Ord(TPS1Extra.L2))) <> 0 then
          Pad.Buttons := Pad.Buttons or PS1PadL2;
        if (Auxiliary and (1 shl Ord(TPS1Extra.L3))) <> 0 then
          Pad.Buttons := Pad.Buttons or PS1PadL3;
        if (Auxiliary and (1 shl Ord(TPS1Extra.R3))) <> 0 then
          Pad.Buttons := Pad.Buttons or PS1PadR3;
        if (Auxiliary and (1 shl Ord(TPS1Extra.Analog))) <> 0 then
          Pad.AnalogButton := True;
        // The on-screen right stick (the left one arrives as Analog[0]).
        var Right := Context.Gamepad.RightAnalogInput;
        if Right.Valid then
        begin
          Pad.RightX := EnsureRange(Integer(Pad.RightX) + Right.X, -32768, 32767);
          Pad.RightY := EnsureRange(Integer(Pad.RightY) + Right.Y, -32768, 32767);
        end;
      end;
      PS1Input.SetPS1Controller(Port, Pad);
    end;
end;

end.

