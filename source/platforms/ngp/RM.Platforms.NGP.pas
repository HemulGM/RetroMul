unit RM.Platforms.NGP;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_NGP = 'ngp';
  ROM_SYSTEM_NGPC = 'ngpc';

type
  TNGPPlatform = class
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
  RM.Settings.Catalog, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.NGP.Adapter,
  RM.Platforms.NGP.Settings, RM.Platforms.Presentation, RM.Platforms.GB.Icons,
  RM.Gamepad.Factory, RM.Platforms.NGP.Gamepads, RM.Input.Runtime,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  NGP_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TNGPPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if (Length(Bytes) >= $40) and (Length(Bytes) <= $400000) and
    (Context.Signature(0, 'COPYRIGHT BY SNK CORPORATION') or Context.Signature(0, ' LICENSED BY SNK CORPORATION')) and
    (Bytes[$23] in [$00, $10]) then
  begin
    var SystemId := 'ngp';
    if Bytes[$23] = $10 then
      SystemId := 'ngpc';
    Result := ImageMatch(Context, 'NeoGeoPocket',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNGPCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, SystemId, '', NGP_IMAGE_MAX_SIZE);
  end;
end;

class procedure TNGPPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('ngp', 'Neo Geo Pocket', 'NGP',
    'SNK', 'NGP Pocket monochrome', 'ngp', ['ngp', 'neogeopocket'],
    ['.ngp', '.ngc', '.zip', '.7z'],
    'NeoGeoPocket', 'ngp', 1);
  TPlatformRegistry.RegisterPlatform('ngpc', 'Neo Geo Pocket Color', 'NGPC',
    'SNK', 'NGPC Pocket Color', 'ngpc', ['ngpc', 'neogeopocketcolor'],
    ['.ngp', '.ngc', '.zip', '.7z'],
    'NeoGeoPocket', 'ngpc', 1);
end;

class procedure TNGPPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('NGP', ['.ngp', '.ngc']);
  Registration.Add(TCoreLoadStage.Header, 10, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TNGPPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('NGP', TSnapshotPolicy.Create(2));
  RegisterSnapshotPolicy('NGPC', TSnapshotPolicy.Create(2));
end;

class procedure TNGPPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TNGPConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TNGPPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start]);
  Definition.ButtonNames[TEmulatorButton.Start] := 'Option';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('ngp', Definition);
  RegisterPlatformInput('ngpc', Definition);
end;

class procedure TNGPPlatform.RegisterClient;
begin
  RegisterSettingsProfile('NeoGeoPocket', TNGPSettings);
  RegisterPlatformSettingsDevices('ngp', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('ngpc', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('ngp', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('ngpc', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('ngp', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('ngpc', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('ngp', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('ngpc', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('ngp', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('ngpc', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('ngp', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('ngpc', TPlatformSessionHandler);
  RegisterPlatformInputHandler('ngp', TPlatformInputHandler);
  RegisterPlatformInputHandler('ngpc', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('ngp', TGamepadNGPStandart, []);
  RegisterPlatformGamepads('ngpc', TGamepadNGPCStandart, []);
  RegisterPlatformPresentation('ngp', 'ngp', PlatformIconGB);
  RegisterPlatformPresentation('ngpc', 'ngpc', PlatformIconGB);
end;

class procedure TNGPPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

