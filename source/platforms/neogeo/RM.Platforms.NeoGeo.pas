unit RM.Platforms.NeoGeo;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  NEOGEO_ZIP_ROM_SIGNATURE: AnsiString = 'PK' + #3 + #4;

type
  TNeoGeoPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function Disc(Context: TCoreLoadContext): TCoreMatch; static;
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
  NeoGeo.Cartridge, RM.Settings.Catalog, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.NeoGeo.Adapter,
  RM.Platforms.NeoGeo.Settings, RM.Platforms.Presentation,
  RM.Platforms.NeoGeo.Icons, RM.Gamepad.Factory, RM.Platforms.NeoGeo.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

class function TNeoGeoPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.Signature(0, NEOGEO_ROM_SIGNATURE) or Context.Signature(0, NEOGEO_ZIP_ROM_SIGNATURE) then
  begin
    Result := ImageMatch(Context, 'NeoGeo',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNeoGeoCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'neogeo', '', 0);
    Result.ArchiveCandidate := not Context.Signature(0, NEOGEO_ZIP_ROM_SIGNATURE);
  end;
end;

class function TNeoGeoPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource then
    Result := TCoreMatch.Create('NeoGeoCD',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TNeoGeoCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName, True);
      end);
end;

class procedure TNeoGeoPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('neogeo', 'Neo Geo', 'NG',
    'SNK', 'NG NeoGeo MVS AES Advanced Entertainment System', 'neogeo', ['neogeo', 'neogeoaes', 'aes'],
    ['.zip', '.neo', '.7z'],
    'NeoGeo', 'neogeo', 2);
  TPlatformRegistry.RegisterPlatform('neogeocd', 'Neo Geo CD', 'NG CD',
    'SNK', 'NG NeoGeo CD', 'neogeocd', ['neogeocd'],
    ['.cue', '.iso', '.chd', '.mds', '.nrg'],
    'NeoGeo', 'neogeocd', 2);
  TPlatformRegistry.RegisterAlias('neogeoaes', 'neogeo');
  TPlatformRegistry.RegisterAlias('aes', 'neogeo');
end;

class procedure TNeoGeoPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('NeoGeo', ['.neo']);
  Registration.Add(TCoreLoadStage.Header, 80, Header);
  Registration.Add(TCoreLoadStage.Source, 100, Disc);
  RegisterEmulationCore(Registration);
end;

class procedure TNeoGeoPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('NEOGEO', TSnapshotPolicy.Create(4));
  RegisterSnapshotPolicy('NEOGEOCD', TSnapshotPolicy.Create(3));
end;

class procedure TNeoGeoPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TNeoGeoConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TNeoGeoPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X]);
  Definition.ButtonNames[TEmulatorButton.X] := 'D';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'D';
  RegisterPlatformInput('neogeo', Definition);
  RegisterPlatformInput('neogeoaes', Definition);
  RegisterPlatformInput('neogeocd', Definition);
end;

class procedure TNeoGeoPlatform.RegisterClient;
begin
  RegisterSettingsProfile('NeoGeo', TNeoGeoSettings);
  RegisterPlatformSettingsDevices('neogeo', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('neogeoaes', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('neogeocd', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('neogeo', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('neogeoaes', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('neogeocd', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('neogeo', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('neogeoaes', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('neogeocd', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('neogeo', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('neogeoaes', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('neogeocd', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('neogeo', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('neogeoaes', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('neogeocd', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('neogeo', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('neogeoaes', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('neogeocd', TPlatformSessionHandler);
  RegisterPlatformInputHandler('neogeo', TPlatformInputHandler);
  RegisterPlatformInputHandler('neogeoaes', TPlatformInputHandler);
  RegisterPlatformInputHandler('neogeocd', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('neogeo', TGamepadNeoGeoArcade, []);
  RegisterPlatformGamepads('neogeoaes', TGamepadNeoGeoAES, []);
  RegisterPlatformGamepads('neogeocd', TGamepadNeoGeoCD, []);
  RegisterPlatformPresentation('neogeo', 'neogeo', PlatformIconNEOGEO);
  RegisterPlatformPresentation('neogeocd', 'neogeocd', PlatformIconNEOGEOCD);
end;

class procedure TNeoGeoPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

