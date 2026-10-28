unit RM.Platforms.GBA;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_GBA = 'gba';

type
  TGBAPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function ExtensionHint(Context: TCoreLoadContext): TCoreMatch; static;
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
  Core.Platforms, Core.Platforms.GBA.Adapter, GBA.Cartridge,
  RM.Platforms.GBA.Settings, RM.Platforms.Presentation, RM.Platforms.GBA.Icons,
  RM.Gamepad.Factory, RM.Platforms.GBA.Gamepads, RM.Input.Runtime,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  GBA_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TGBAPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if IsGBAROM(Context.Data) then
    Result := ImageMatch(Context, 'GBA',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TGBACoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'gba', '', GBA_IMAGE_MAX_SIZE);
end;

class function TGBAPlatform.ExtensionHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.HeaderRecognized and Context.HasExtension(['.gba']) then
    Result := ImageMatch(Context, 'GBA',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TGBACoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'gba', '', GBA_IMAGE_MAX_SIZE);
end;

class procedure TGBAPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('gba', 'Game Boy Advance', 'GBA',
    'Nintendo', 'GBA AGB', 'gba', ['gba'],
    ['.gba', '.zip', '.7z'],
    'GBA', 'gba', 1);
end;

class procedure TGBAPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('GBA', ['.gba']);
  Registration.Add(TCoreLoadStage.Header, 90, Header);
  Registration.Add(TCoreLoadStage.OverrideHint, 20, ExtensionHint);
  RegisterEmulationCore(Registration);
end;

class procedure TGBAPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('GBA', TSnapshotPolicy.Create(6));
end;

class procedure TGBAPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TGBAConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TGBAPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.Z]);
  Definition.ButtonNames[TEmulatorButton.C] := 'L';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'L';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'R';
  RegisterPlatformInput('gba', Definition);
end;

class procedure TGBAPlatform.RegisterClient;
begin
  RegisterSettingsProfile('GBA', TGBASettings);
  RegisterPlatformSettingsDevices('gba', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('gba', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('gba', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('gba', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('gba', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('gba', TPlatformSessionHandler);
  RegisterPlatformInputHandler('gba', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('gba', TGamepadGBAStandart, []);
  RegisterPlatformPresentation('gba', 'gba', PlatformIconGBA);
end;

class procedure TGBAPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;

  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

