unit RM.Settings.Runtime;

interface

uses
  System.IniFiles, RM.Input.Runtime, RM.Session.Runtime;

type
  TSettingsRuntimeContext = TInputRuntimeContext;

  TSettingsHelpInfo = record
    Players: Integer;
    KeyboardPeripheral: Boolean;
  end;

  // Borrowed controls; the platform supplies its existing attach/release methods.
  TSettingsPeripheral = record
    Input: TSessionInputControl;
    ReleaseOrder, DetachOrder: Integer;
    class function Create(const Input: TSessionInputControl; ReleaseOrder, DetachOrder: Integer): TSettingsPeripheral; static;
  end;

  TPlatformSettingsHandler = class
  public
    class procedure Apply(const Context: TSettingsRuntimeContext; Ini: TCustomIniFile); virtual;
    class function HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo; virtual;
    class function Peripherals(const Context: TSettingsRuntimeContext): TArray<TSettingsPeripheral>; virtual;
  end;

  TPlatformSettingsHandlerClass = class of TPlatformSettingsHandler;

procedure RegisterPlatformSettingsHandler(const PlatformId: string; Handler: TPlatformSettingsHandlerClass);

function TryPlatformSettingsHandler(const PlatformId: string; out Handler: TPlatformSettingsHandlerClass): Boolean;

function PlatformSettingsHandler(const PlatformId: string): TPlatformSettingsHandlerClass;

procedure ReleaseSettingsPeripherals(const Context: TSettingsRuntimeContext);

procedure DetachSettingsPeripherals(const Context: TSettingsRuntimeContext);

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, FMX.Controls, Core.Emulation, Core.InputConfig,
  Core.Platforms, RM.Input, RM.Gamepad;

var
  Handlers: TDictionary<string, TPlatformSettingsHandlerClass>;

class function TSettingsPeripheral.Create(const Input: TSessionInputControl; ReleaseOrder, DetachOrder: Integer): TSettingsPeripheral;
begin
  Result.Input := Input;
  Result.ReleaseOrder := ReleaseOrder;
  Result.DetachOrder := DetachOrder;
end;

procedure RegisterPlatformSettingsHandler(const PlatformId: string; Handler: TPlatformSettingsHandlerClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Handler = nil) then
    raise EArgumentException.Create('Invalid platform settings handler: ' + PlatformId);
  if Handlers.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate platform settings handler: ' + Id);
  Handlers.Add(Id, Handler);
end;

function TryPlatformSettingsHandler(const PlatformId: string; out Handler: TPlatformSettingsHandlerClass): Boolean;
begin
  Handler := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Handlers.TryGetValue(Id, Handler);
  if not Result then
    Result := Handlers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Handler);
end;

function PlatformSettingsHandler(const PlatformId: string): TPlatformSettingsHandlerClass;
begin
  if not TryPlatformSettingsHandler(PlatformId, Result) then
    Result := TPlatformSettingsHandler;
end;

function SettingsPeripherals(const Context: TSettingsRuntimeContext; Detaching: Boolean): TArray<TSettingsPeripheral>;
begin
  var Classes := TList<TPlatformSettingsHandlerClass>.Create;
  var Items := TList<TSettingsPeripheral>.Create;
  var Seen := TList<TControl>.Create;
  try
    for var Handler in Handlers.Values do
      if not Classes.Contains(Handler) then
        Classes.Add(Handler);
    Classes.Sort(TComparer<TPlatformSettingsHandlerClass>.Construct(
      function(const A, B: TPlatformSettingsHandlerClass): Integer
      begin
        Result := CompareStr(A.ClassName, B.ClassName);
      end));
    for var Handler in Classes do
      for var Item in Handler.Peripherals(Context) do
        if (Item.Input.Control <> nil) and not Seen.Contains(Item.Input.Control) then
        begin
          Seen.Add(Item.Input.Control);
          Items.Add(Item);
        end;
    Items.Sort(TComparer<TSettingsPeripheral>.Construct(
      function(const A, B: TSettingsPeripheral): Integer
      begin
        if Detaching then
          Result := CompareValue(A.DetachOrder, B.DetachOrder)
        else
          Result := CompareValue(A.ReleaseOrder, B.ReleaseOrder);
      end));
    Result := Items.ToArray;
  finally
    Seen.Free;
    Items.Free;
    Classes.Free;
  end;
end;

procedure ReleaseSettingsPeripherals(const Context: TSettingsRuntimeContext);
begin
  if Context.State.Input.Gamepad <> nil then
    Context.State.Input.Gamepad.ReleaseAll;
  for var Item in SettingsPeripherals(Context, False) do
    if Assigned(Item.Input.Release) then
      Item.Input.Release;
end;

procedure DetachSettingsPeripherals(const Context: TSettingsRuntimeContext);
begin
  DetachSessionTouch(Context);
  if Context.State.Input.Gamepad <> nil then
    Context.State.Input.Gamepad.AttachToForm(nil);
  for var Item in SettingsPeripherals(Context, True) do
    if Assigned(Item.Input.Attach) then
      Item.Input.Attach(nil);
end;

class procedure TPlatformSettingsHandler.Apply(const Context: TSettingsRuntimeContext; Ini: TCustomIniFile);
begin
  Context.State.Session.Emulation.Config.Load;
  var InputPorts: IEmulationInputPorts;
  if Supports(Context.State.Session.Emulation, IEmulationInputPorts, InputPorts) then
  begin
    var Ports := ReadCoreInputPorts(Ini, Context.State.Input.SystemId);
    if not SameInputPorts(Context.State.Input.Ports, Ports) then
    begin
      ReleaseSettingsPeripherals(Context);
      Context.State.Input.GamepadInput := Default(TEmulatorInput);
      InputPorts.ApplyInputPorts(Ports);
      Context.State.Input.Ports := Ports;
      var platform := TPlatformRegistry.Require(Context.State.Input.SystemId);
      Context.State.Input.Gamepad.Configure(platform.Id, Ports.Devices[0],
        CoreButtons(Context.State.Input.SystemId, Ports.Devices[0]));
    end;
  end;
  var LiveSettings: IEmulationLiveSettings;
  if Supports(Context.State.Session.Emulation, IEmulationLiveSettings, LiveSettings) then
    LiveSettings.ApplyLiveSettings;
end;

class function TPlatformSettingsHandler.HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo;
begin
  Result := Default(TSettingsHelpInfo);
  Result.Players := TPlatformRegistry.Require(Context.State.Input.SystemId).Ports;
end;

class function TPlatformSettingsHandler.Peripherals(const Context: TSettingsRuntimeContext): TArray<TSettingsPeripheral>;
begin
  Result := nil;
end;

initialization
  Handlers := TDictionary<string, TPlatformSettingsHandlerClass>.Create(TIStringComparer.Ordinal);

finalization
  Handlers.Free;

end.

