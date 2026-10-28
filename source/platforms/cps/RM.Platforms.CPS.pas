unit RM.Platforms.CPS;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TCPSPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, RM.Settings.Platform, Core.Snapshots, System.StrUtils,
  Core.Emulation, Core.Platforms, Core.Platforms.CPS.Adapter,
  CPS.RomSets, RM.Platforms.Presentation, RM.Platforms.CPS.Icons,
  RM.Gamepad.Factory, RM.Platforms.CPS.Gamepads, RM.Input.Runtime,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

class function TCPSPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.HasExtension(['.zip']) then
    Exit;
  var RomSet: TCPSRomSet;
  if TCPSRomSet.IdentifyStream(Context.Stream, Context.SourceName, RomSet) then
    Result := TCoreMatch.Create('CPS',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TCPSCoreAdapter.Create(Context.Stream, Context.Storage, Context.SourceName);
      end);
end;

class procedure TCPSPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('cps1', 'Capcom Play System I', 'CPS-1',
    'Capcom', 'CPS CPS1 arcade', 'cps1', ['cps1'],
    ['.zip', '.7z'],
    'CPS1', 'cps1', 4);
  TPlatformRegistry.RegisterPlatform('cps2', 'Capcom Play System II', 'CPS-2',
    'Capcom', 'CPS CPS2 arcade', 'cps2', ['cps2'],
    ['.zip', '.7z'],
    'CPS2', 'cps2', 4);
  TPlatformRegistry.RegisterPlatform('cps3', 'Capcom Play System III', 'CPS-3',
    'Capcom', 'CPS CPS3 arcade SIMM No-CD', 'cps3', ['cps3'],
    ['.zip', '.7z'],
    'CPS3', 'cps3', 2);
end;

class procedure TCPSPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('CPS', []);
  Registration.Add(TCoreLoadStage.Container, 20, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TCPSPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('CPS1', TSnapshotPolicy.Create(4));
  RegisterSnapshotPolicy('CPS2', TSnapshotPolicy.Create(2));
  RegisterSnapshotPolicy('CPS3', TSnapshotPolicy.Create(1, 128 * 1024 * 1024));
end;

class procedure TCPSPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TCPSConfig.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[0, B];
    Keys[1, B] := C.Keys[1, B];
  end;
end;

class procedure TCPSPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.A] := 'LP';
  Definition.ButtonNames[TEmulatorButton.B] := 'MP';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Coin';
  Definition.ButtonNames[TEmulatorButton.C] := 'HP';
  Definition.ButtonNames[TEmulatorButton.X] := 'LK';
  Definition.ButtonNames[TEmulatorButton.Y] := 'MK';
  Definition.ButtonNames[TEmulatorButton.Z] := 'HK';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Service';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.A] := 'LP';
  Definition.LegacyKeyNames[TEmulatorButton.B] := 'MP';
  Definition.LegacyKeyNames[TEmulatorButton.Select] := 'Coin';
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'HP';
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'LK';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'MK';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'HK';
  Definition.LegacyKeyNames[TEmulatorButton.Mode] := 'Service';
  RegisterPlatformInput('cps1', Definition);
  RegisterPlatformInput('cps2', Definition);
  RegisterPlatformInput('cps3', Definition);
end;

class procedure TCPSPlatform.RegisterClient;
begin
  RegisterSettingsPlatform('cps1', TSettingsPlatform);
  RegisterSettingsPlatform('cps2', TSettingsPlatform);
  RegisterSettingsPlatform('cps3', TSettingsPlatform);
  RegisterPlatformSettingsDevices('cps1', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('cps2', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('cps3', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('cps1', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('cps2', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('cps3', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('cps1', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('cps2', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('cps3', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('cps1', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('cps2', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('cps3', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('cps1', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('cps2', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('cps3', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('cps1', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('cps2', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('cps3', TPlatformSessionHandler);
  RegisterPlatformInputHandler('cps1', TPlatformInputHandler);
  RegisterPlatformInputHandler('cps2', TPlatformInputHandler);
  RegisterPlatformInputHandler('cps3', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('cps1', TGamepadCPSArcade, []);
  RegisterPlatformGamepads('cps2', TGamepadCPSArcade, []);
  RegisterPlatformGamepads('cps3', TGamepadCPSArcade, []);
  RegisterPlatformPresentation('cps1', 'cps1', PlatformIconCPS);
  RegisterPlatformPresentation('cps2', 'cps2', PlatformIconCPS);
  RegisterPlatformPresentation('cps3', 'cps3', PlatformIconCPS);
end;

class procedure TCPSPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

