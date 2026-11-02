unit RM.Platforms.PSP.Input;

// The PSP's analog stick from host bindings: four directions that keys,
// buttons or axes can be assigned to (an axis gives its deflection, a key or
// button the whole travel), added to the on-screen stick.

interface

uses
  Core.Emulation, Core.Emulation.Types, RM.Input.Runtime, RM.Settings.Devices,
  RM.ControlsHelp.Content;

const
  PSPStickAction = 4224;

type
  TPSPStickDirection = (StickUp, StickDown, StickLeft, StickRight);

  TPSPInputHandler = class(TPlatformInputHandler)
  public
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

  TPSPSettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
  end;

  TPSPControlsHelp = class(TPlatformControlsHelp)
  public
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
  end;

function PSPStickActionOf(Direction: TPSPStickDirection): Integer;

function PSPStickName(Direction: TPSPStickDirection): string;

implementation

uses
  System.SysUtils, System.Math, FMXInput, RM.Input;

function PSPStickActionOf(Direction: TPSPStickDirection): Integer;
begin
  Result := PSPStickAction + Ord(Direction);
end;

function PSPStickName(Direction: TPSPStickDirection): string;
const
  Names: array[TPSPStickDirection] of string = ('Stick ↑', 'Stick ↓', 'Stick ←', 'Stick →');
begin
  Result := Names[Direction];
end;

class procedure TPSPInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Manager := Context.State.Input.Manager;
  if (Manager = nil) or (Context.State.Input.Ports.Devices[0] = 'none') then
    Exit;
  var Bindings := Manager.Bindings;
  var Values := Manager.Values;
  var X := ActionAmount(Manager, Bindings, Values, PSPStickActionOf(TPSPStickDirection.StickRight)) -
    ActionAmount(Manager, Bindings, Values, PSPStickActionOf(TPSPStickDirection.StickLeft));
  var Y := ActionAmount(Manager, Bindings, Values, PSPStickActionOf(TPSPStickDirection.StickDown)) -
    ActionAmount(Manager, Bindings, Values, PSPStickActionOf(TPSPStickDirection.StickUp));
  if (X = 0) and (Y = 0) then
    Exit;
  var Stick := Input.Analog[0];
  if not Stick.Valid then
    Stick := Default(TEmulatorAnalogPad);
  Stick.X := EnsureRange(Integer(Stick.X) + Round(X * 32767), -32768, 32767);
  Stick.Y := EnsureRange(Integer(Stick.Y) + Round(Y * 32767), -32768, 32767);
  Stick.Valid := True;
  Input.Analog[0] := Stick;
end;

class function TPSPSettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited Assignments(Context);
  if (Context.Port <> 0) or (Length(Result) = 0) then
    Exit;
  for var Direction := Low(TPSPStickDirection) to High(TPSPStickDirection) do
    Result := Result + [TSettingsDeviceBinding.Create(PSPStickActionOf(Direction), PSPStickName(Direction))];
end;

class function TPSPControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited Assignments(Context);
  if (Context.Player <> 0) or (Length(Result) = 0) then
    Exit;
  for var Direction := Low(TPSPStickDirection) to High(TPSPStickDirection) do
    Result := Result + [TControlsHelpAssignment.Create(PSPStickName(Direction), PSPStickActionOf(Direction))];
end;

end.
