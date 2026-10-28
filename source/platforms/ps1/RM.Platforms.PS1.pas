unit RM.Platforms.PS1;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.IniFiles, FMXInput, System.SysUtils;

const
  ROM_SYSTEM_PS1 = 'ps1';
  ROM_CORE_ID_PS1 = 'PS1';

type
  TPS1Platform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure RegisterRuntimeServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, Core.PlatformServices, Core.Snapshots, System.StrUtils,
  Core.Emulation, Core.Platforms, Core.Platforms.PS1.Adapter,
  RM.Platforms.PS1.Settings, RM.Platforms.Presentation, RM.Platforms.PS1.Icons,
  RM.Gamepad.Factory, RM.Platforms.PS1.Gamepads, RM.Input.Runtime,
  RM.Platforms.PS1.Input, RM.Session.Runtime, RM.Window.Layout,
  RM.Settings.Runtime, RM.ControlsHelp.Content, RM.Platforms.PS1.Help,
  RM.Settings.Callouts, RM.Platforms.PS1.Devices, RM.Settings.Devices,
  System.Classes;

const
  PS1_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TPS1Platform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.m3u']) then
    Exit(TCoreMatch.Create('PS1',
      function: IEmulationCore
      begin
        Result := TPS1CoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end));
  if Context.IsDiscSource and TPS1CoreAdapter.IsPS1Disc(Context.Disc) then
    Result := TCoreMatch.Create('PS1',
      function: IEmulationCore
      begin
        Result := TPS1CoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
      end);
end;

class function TPS1Platform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if (Length(Context.Data) >= $800) and Context.Signature(0, 'PS-X EXE') then
    Result := ImageMatch(Context, 'PS1',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TPS1CoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'ps1', '', PS1_IMAGE_MAX_SIZE);
end;

class procedure TPS1Platform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('ps1', 'PlayStation', 'PS1',
    'Sony', 'PS1 PSX PSone PlayStation', 'ps1', ['ps1', 'psx', 'playstation'],
    ['.m3u', '.cue', '.chd', '.iso', '.mds', '.nrg', '.bin', '.exe', '.zip'],
    'PS1', 'ps1', 2);
end;

class procedure TPS1Platform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('PS1', ['.exe']);
  Registration.Add(TCoreLoadStage.Source, 80, Source);
  Registration.Add(TCoreLoadStage.Header, 20, Header);
  RegisterEmulationCore(Registration);
end;

class procedure TPS1Platform.RegisterServices;
begin
  var Policy := TSnapshotPolicy.Create(1);
  Policy.IdentityError := 'This PS1 snapshot belongs to a different disc. Insert the disc used to save it.';
  RegisterSnapshotPolicy('PS1', Policy);
end;

class procedure TPS1Platform.RegisterRuntimeServices;
begin
  var Service := Default(TPlatformServices);
  Service.LibraryFeatures := [TLibraryFeature.Playlists, TLibraryFeature.CueTracks];
  Service.BackgroundExtensions := ['.m3u', '.cue', '.iso', '.chd', '.mds', '.nrg'];
  RegisterPlatformServices('ps1', Service);
end;

class procedure TPS1Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TPS1Config.Create('', nil);
  Config := C;
  var Map := C.Keys;
  for var Port := 0 to 1 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[Port, B] := Map[Port, B];
end;

class procedure TPS1Platform.LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile);
var
  Config: IEmulatorConfig;
begin
  var C := TPS1Config.Create('', nil);
  Config := C;
  for var Port := 0 to 1 do
  begin
    var Section := 'Keys';
    if Port > 0 then
      Section := Section + IntToStr(Port + 1);
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      AddLegacyInputKey(Input, PS1Action(Port, Extra), ReadEmulatorKey(Ini, Section, TPS1Config.ExtraKeyName(Extra),
          C.ExtraKey(Port, Extra)));
  end;
end;

class procedure TPS1Platform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.A] := 'Cross';
  Definition.ButtonNames[TEmulatorButton.B] := 'Circle';
  Definition.ButtonNames[TEmulatorButton.C] := 'L1';
  Definition.ButtonNames[TEmulatorButton.X] := 'Square';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Triangle';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R1';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'R2';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.A] := 'Cross';
  Definition.LegacyKeyNames[TEmulatorButton.B] := 'Circle';
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'L1';
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'Square';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'Triangle';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'R1';
  Definition.LegacyKeyNames[TEmulatorButton.Mode] := 'R2';
  Definition.BeforeLegacyBindings := LoadLegacyExtras;
  Definition.SharedFilterBinding := FilterPS1CompatibilityBinding;
  Definition.SharedBindingOrder := 20;
  RegisterPlatformInput('ps1', Definition);
end;

class procedure TPS1Platform.RegisterClient;
begin
  RegisterSettingsProfile('PS1', TPS1Settings);
  RegisterPlatformSettingsDevices('ps1', TPS1SettingsDevices);
  RegisterPlatformDeviceCallouts('ps1', TPS1DeviceCallouts);
  RegisterPlatformControlsHelp('ps1', TPS1ControlsHelp);
  RegisterPlatformSettingsHandler('ps1', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('ps1', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('ps1', TPlatformSessionHandler);
  RegisterPlatformInputHandler('ps1', TPS1InputHandler);
  RegisterInput;
  RegisterPlatformGamepads('ps1', TGamepadPS1Digital, [TGamepadDeviceVariant.Create('pad-analog', TGamepadPS1Analog)]);
  RegisterPlatformPresentation('ps1', 'ps1', PlatformIconPS1);
end;

class procedure TPS1Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterRuntimeServices;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

