unit RM.Platforms.Saturn;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_SATURN = 'saturn';

type
  TSaturnPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
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
  RM.Settings.Catalog, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.Saturn.Adapter,
  RM.Platforms.Saturn.Settings, RM.Platforms.Presentation,
  RM.Platforms.Saturn.Icons, RM.Gamepad.Factory, RM.Platforms.Saturn.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  SATURN_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TSaturnPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;

  if Context.Signature(0, AnsiString(#$20#$00#$02#$00#$06#$00#$20#$00#$20#$00#$02#$00#$06#$00#$20#$00)) then
    Result := ImageMatch(Context, 'Saturn',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TSaturnCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'saturn', '', SATURN_IMAGE_MAX_SIZE);
end;

class function TSaturnPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource and Context.DiscSignature('SEGA SEGASATURN ') then
    Result := TCoreMatch.Create('Saturn',
      function: IEmulationCore
      begin
        Result := TSaturnCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
      end);
end;

class procedure TSaturnPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('saturn', 'SEGA Saturn', 'Saturn',
    'Sega', 'Saturn SH2 CD', 'saturn', ['saturn'],
    ['.bin', '.rom', '.bios', '.cue', '.iso', '.chd', '.mds', '.nrg'],
    'Saturn', 'saturn', 2);
end;

class procedure TSaturnPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('Saturn', []);
  Registration.Add(TCoreLoadStage.Header, 40, Recognize);
  Registration.Add(TCoreLoadStage.Source, 50, Disc);
  RegisterEmulationCore(Registration);
end;

class procedure TSaturnPlatform.RegisterServices;
begin
  var Policy := TSnapshotPolicy.Create(5);
  Policy.AcceptedVersions := [2, 3, 4];
  RegisterSnapshotPolicy('SATURN', Policy);
end;

class procedure TSaturnPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TSaturnConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TSaturnPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.Select] := 'L';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'R';
  Definition.LegacyPorts := 12;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('saturn', Definition);
end;

class procedure TSaturnPlatform.RegisterClient;
begin
  RegisterSettingsProfile('Saturn', TSaturnSettings);
  RegisterPlatformSettingsDevices('saturn', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('saturn', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('saturn', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('saturn', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('saturn', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('saturn', TPlatformSessionHandler);
  RegisterPlatformInputHandler('saturn', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('saturn', TGamepadSaturnDigital, [TGamepadDeviceVariant.Create('pad-analog', TGamepadSaturnAnalog)]);
  RegisterPlatformPresentation('saturn', 'saturn', PlatformIconSaturn);
end;

class procedure TSaturnPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

