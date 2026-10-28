unit RM.Settings.Devices;

interface

uses System.Classes, FMX.Controls, RM.Settings.Builder;

type
  TSettingsDeviceDiagramFactory = reference to function(Control: TControl): TControl;
  TSettingsDeviceContext = record
    SystemId, Device: string;
    Port: Integer;
    Owner: TComponent;
    OnChange: TNotifyEvent;
    CreateDiagram: TSettingsDeviceDiagramFactory;
  end;
  TSettingsDeviceBinding = record
    Action: Integer;
    Caption: string;
    class function Create(Action: Integer; const Caption: string): TSettingsDeviceBinding; static;
    class function None: TSettingsDeviceBinding; static;
  end;
  TSettingsDeviceVisual = record
    Control, Diagram: TControl;
    InitialHeight: Single;
    ShowAssignments: Boolean;
  end;

  TPlatformSettingsDevices = class
  public
    class function FixedDevice(const Context: TSettingsDeviceContext): string; virtual;
    class function HasPortSettings: Boolean; virtual;
    class function SourceKey(const Context: TSettingsDeviceContext): string; virtual;
    class procedure BindingFields(const Context: TSettingsDeviceContext; Page: TSettingsPageBuilder); virtual;
    class function DirectBindings(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; virtual;
    class function CreateVisual(const Context: TSettingsDeviceContext): TSettingsDeviceVisual; virtual;
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; virtual;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; virtual;
    class procedure Disconnect(const Context: TSettingsDeviceContext; Control: TControl); virtual;
  end;
  TPlatformSettingsDevicesClass = class of TPlatformSettingsDevices;

procedure RegisterPlatformSettingsDevices(const PlatformId: string; Provider: TPlatformSettingsDevicesClass);
function TryPlatformSettingsDevices(const PlatformId: string; out Provider: TPlatformSettingsDevicesClass): Boolean;
function PlatformSettingsDevices(const PlatformId: string): TPlatformSettingsDevicesClass;

implementation

uses System.SysUtils, System.Generics.Collections, System.Generics.Defaults,
  FMX.Types, Core.Platforms, RM.Gamepad, RM.Input;

var Providers: TDictionary<string, TPlatformSettingsDevicesClass>;

class function TSettingsDeviceBinding.Create(Action: Integer; const Caption: string): TSettingsDeviceBinding;
begin Result.Action := Action; Result.Caption := Caption; end;
class function TSettingsDeviceBinding.None: TSettingsDeviceBinding;
begin Result := Create(-1, ''); end;

procedure RegisterPlatformSettingsDevices(const PlatformId: string; Provider: TPlatformSettingsDevicesClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Provider = nil) then raise EArgumentException.Create('Invalid settings devices provider: ' + PlatformId);
  if Providers.ContainsKey(Id) then raise EArgumentException.Create('Duplicate settings devices provider: ' + Id);
  Providers.Add(Id, Provider);
end;
function TryPlatformSettingsDevices(const PlatformId: string; out Provider: TPlatformSettingsDevicesClass): Boolean;
begin
  Provider := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Providers.TryGetValue(Id, Provider);
  if not Result then Result := Providers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Provider);
end;
function PlatformSettingsDevices(const PlatformId: string): TPlatformSettingsDevicesClass;
begin
  if not TryPlatformSettingsDevices(PlatformId, Result) then Result := TPlatformSettingsDevices;
end;
class function TPlatformSettingsDevices.FixedDevice(const Context: TSettingsDeviceContext): string;
begin Result := ''; end;
class function TPlatformSettingsDevices.HasPortSettings: Boolean;
begin Result := True; end;
class function TPlatformSettingsDevices.SourceKey(const Context: TSettingsDeviceContext): string;
begin Result := 'Source' + IntToStr(Context.Port + 1); end;
class procedure TPlatformSettingsDevices.BindingFields(const Context: TSettingsDeviceContext; Page: TSettingsPageBuilder);
begin end;
class function TPlatformSettingsDevices.DirectBindings(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin Result := nil; end;

class function TPlatformSettingsDevices.CreateVisual(const Context: TSettingsDeviceContext): TSettingsDeviceVisual;
begin
  Result := Default(TSettingsDeviceVisual);
  var Pad := TScreenGamepad.Create(Context.Owner);
  Pad.Configure(TPlatformRegistry.Require(Context.SystemId).Id, Context.Device,
    CoreButtons(Context.SystemId, Context.Device));
  Pad.OnChange := Context.OnChange;
  Result.Control := Pad;
  Result.Diagram := Context.CreateDiagram(Pad);
  Result.InitialHeight := 460;
  Result.ShowAssignments := True;
end;
class function TPlatformSettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := nil;
  for var Button in CoreButtons(Context.SystemId, Context.Device) do
    Result := Result + [TSettingsDeviceBinding.Create(PadAction(Context.Port, Button), CoreButtonName(Context.SystemId, Button))];
end;
class function TPlatformSettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := TSettingsDeviceBinding.None;
  if Control is TScreenGamepad then
    for var Button in TScreenGamepad(Control).Buttons do
      if Button in CoreButtons(Context.SystemId, Context.Device) then
        Exit(TSettingsDeviceBinding.Create(PadAction(Context.Port, Button),
          Translate('Button ') + Translate(CoreButtonName(Context.SystemId, Button))));
end;
class procedure TPlatformSettingsDevices.Disconnect(const Context: TSettingsDeviceContext; Control: TControl);
begin
  if Control is TScreenGamepad then TScreenGamepad(Control).OnChange := nil;
end;

initialization
  Providers := TDictionary<string, TPlatformSettingsDevicesClass>.Create(TIStringComparer.Ordinal);
finalization
  Providers.Free;
end.
