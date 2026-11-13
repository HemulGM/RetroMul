unit RM.Platforms.N64.Input;

{$I RM.Mobile.inc}

interface

uses
  RM.Input.Runtime, Core.Emulation, RM.Input, FMXInput, System.IniFiles;

const
  N64LAction = 4096;
  N64StickAction = 4240;

type
  TN64StickDirection = (Up, Down, Left, Right);

  TN64InputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

function N64StickActionOf(Port: Integer; Direction: TN64StickDirection): Integer;

function N64StickName(Direction: TN64StickDirection): string;

procedure FilterN64Binding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);

implementation

uses
  System.SysUtils, System.Math, RM.Gamepad, Core.Platforms.N64.Adapter,
  N64.Console;

function N64StickActionOf(Port: Integer; Direction: TN64StickDirection): Integer;
begin
  Result := N64StickAction + Port * 4 + Ord(Direction);
end;

function N64StickName(Direction: TN64StickDirection): string;
const
  Names: array[TN64StickDirection] of string = ('Stick ↑', 'Stick ↓', 'Stick ←', 'Stick →');
begin
  Result := Names[Direction];
end;

procedure FilterN64Binding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);
begin
  if (Binding.Action >= N64LAction) and (Binding.Action < N64LAction + 4) then
    Policy.SourceKey := 'Source' + IntToStr(Binding.Action - N64LAction + 1)
  else if (Binding.Action >= N64StickAction) and (Binding.Action < N64StickAction + 16) then
    Policy.SourceKey := 'Source' + IntToStr((Binding.Action - N64StickAction) div 4 + 1);
end;

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
      var Manager := Context.State.Input.Manager;
      var IndependentStick := False;
      if Manager <> nil then
      begin
        var Bindings := Manager.Bindings;
        var Values := Manager.Values;
        for var B in Bindings do
          if (B.Action >= N64StickActionOf(Port, TN64StickDirection.Up)) and
            (B.Action <= N64StickActionOf(Port, TN64StickDirection.Right)) then
            IndependentStick := True;
        var X := ActionAmount(Manager, Bindings, Values, N64StickActionOf(Port, TN64StickDirection.Right)) -
          ActionAmount(Manager, Bindings, Values, N64StickActionOf(Port, TN64StickDirection.Left));
        var Y := ActionAmount(Manager, Bindings, Values, N64StickActionOf(Port, TN64StickDirection.Down)) -
          ActionAmount(Manager, Bindings, Values, N64StickActionOf(Port, TN64StickDirection.Up));
        Pad.StickX := EnsureRange(Integer(Pad.StickX) + Round(X * 80), -80, 80);
        Pad.StickY := EnsureRange(Integer(Pad.StickY) - Round(Y * 80), -80, 80);
      end;
      N64Input.SetN64Controller(Port, Pad, IndependentStick);
    end;
end;

end.

