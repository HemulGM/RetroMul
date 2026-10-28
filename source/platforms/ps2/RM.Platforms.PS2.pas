unit RM.Platforms.PS2;

interface

uses Core.EmulatorRegistry, RM.Input, System.IniFiles, FMXInput;

const
  ROM_SYSTEM_PS2 = 'ps2';
  ROM_CORE_ID_PS2 = 'PS2';

type
  TPS2Platform = class
  private
    class var FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses System.SysUtils, Core.Emulation, Core.Platforms, Core.PlatformServices,
  Core.Snapshots, Core.DVD.Image, Core.Platforms.PS2.Adapter, Core.Platforms.PS1.Adapter,
  RM.Platforms.PS2.Settings, RM.Platforms.PS2.Input, RM.Platforms.PS2.Icons,
  RM.Platforms.PS1.Input, RM.Platforms.PS1.Devices, RM.Platforms.PS1.Help, RM.Platforms.PS1.Gamepads,
  RM.Settings.Platform, RM.Settings.Catalog, RM.Settings.Devices, RM.Settings.Callouts,
  RM.ControlsHelp.Content, RM.Settings.Runtime, RM.Session.Runtime, RM.Window.Layout,
  RM.Input.Runtime, RM.Gamepad.Factory, RM.Platforms.Presentation;

class function TPS2Platform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Core := TPS2CoreAdapter.TryCreate(Context.Stream, Context.Storage, Context.RomName, Context.SourceName);
  if Core <> nil then
    Exit(TCoreMatch.Create('PS2', function: IEmulationCore begin Result := Core; end));
  if Context.IsDiscSource and TPS2CoreAdapter.IsPS2CD(Context.Disc) then
    Result := TCoreMatch.Create('PS2',
      function: IEmulationCore
      begin
        Result := TPS2CoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName,
          TDVDCDImage.Create(Context.TakeDisc, True));
      end);
end;

class procedure TPS2Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var Config: IEmulatorConfig;
begin
  var C := TPS2Config.Create('', nil);
  Config := C;
  var Map := C.Keys;
  for var Port := 0 to 1 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do Keys[Port, B] := Map[Port, B];
end;

class procedure TPS2Platform.LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile);
var Config: IEmulatorConfig;
begin
  var C := TPS2Config.Create('', nil);
  Config := C;
  for var Port := 0 to 1 do
  begin
    var Section := 'Keys';
    if Port > 0 then Section := Section + IntToStr(Port + 1);
    for var Extra := Low(TPS2Extra) to High(TPS2Extra) do
      AddLegacyInputKey(Input, PS1Action(Port, TPS1Extra(Ord(Extra))), ReadEmulatorKey(Ini, Section,
        TPS2Config.ExtraKeyName(Extra), C.ExtraKey(Port, Extra)));
  end;
end;

class procedure TPS2Platform.RegisterPlatform;
begin
  if FRegistered then Exit;
  TPlatformRegistry.RegisterPlatform('ps2', 'PlayStation 2', 'PS2', 'Sony', 'PS2 PlayStation 2',
    'ps2', ['ps2', 'playstation2'], ['.iso', '.chd', '.cue', '.bin', '.mds', '.elf'], 'PS2', 'ps2', 2);
  var Registration := TEmulationCoreRegistration.Create('PS2', ['.elf']);
  // Before PSP's generic MIPS ELF route; the PS2 probe checks RAM entry bounds.
  Registration.Add(TCoreLoadStage.Source, 5, Source);
  RegisterEmulationCore(Registration);
  RegisterSnapshotPolicy('PS2', TSnapshotPolicy.Create(3));
  var Service := Default(TPlatformServices);
  Service.LibraryFeatures := [TLibraryFeature.CueTracks];
  Service.BackgroundExtensions := ['.iso', '.chd', '.cue', '.mds'];
  RegisterPlatformServices('ps2', Service);
  RegisterPlatformPresentation('ps2', 'ps2', PlatformIconPS2);
  RegisterSettingsProfile('PS2', TPS2Settings);
  RegisterPlatformSettingsDevices('ps2', TPS1SettingsDevices);
  RegisterPlatformDeviceCallouts('ps2', TPS1DeviceCallouts);
  RegisterPlatformControlsHelp('ps2', TPS1ControlsHelp);
  RegisterPlatformSettingsHandler('ps2', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('ps2', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('ps2', TPlatformSessionHandler);
  RegisterPlatformInputHandler('ps2', TPS2InputHandler);
  RegisterPlatformGamepads('ps2', TGamepadPS1Analog, [TGamepadDeviceVariant.Create('pad-analog', TGamepadPS1Analog)]);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C,
    TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode,
    TEmulatorButton.Start, TEmulatorButton.Select]);
  Definition.ButtonNames[TEmulatorButton.A] := 'Cross'; Definition.ButtonNames[TEmulatorButton.B] := 'Circle';
  Definition.ButtonNames[TEmulatorButton.C] := 'L1'; Definition.ButtonNames[TEmulatorButton.X] := 'Square';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Triangle'; Definition.ButtonNames[TEmulatorButton.Z] := 'R1';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'R2';
  Definition.LegacyPorts := 2; Definition.LegacySection := 'Keys';
  Definition.LegacyKeyNames[TEmulatorButton.A] := 'Cross'; Definition.LegacyKeyNames[TEmulatorButton.B] := 'Circle';
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'L1'; Definition.LegacyKeyNames[TEmulatorButton.X] := 'Square';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'Triangle'; Definition.LegacyKeyNames[TEmulatorButton.Z] := 'R1';
  Definition.LegacyKeyNames[TEmulatorButton.Mode] := 'R2';
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.BeforeLegacyBindings := LoadLegacyExtras;
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.SharedFilterBinding := FilterPS1CompatibilityBinding;
  Definition.SharedBindingOrder := 20;
  RegisterPlatformInput('ps2', Definition);
  FRegistered := True;
end;

end.
