unit RM.Platforms.PS2;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.IniFiles, FMXInput;

const
  ROM_SYSTEM_PS2 = 'ps2';
  ROM_CORE_ID_PS2 = 'PS2';

type
  TPS2Platform = class
  private
    class var
      FRegistered: Boolean;
    class function DVDSource(Context: TCoreLoadContext): TCoreMatch; static;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RA.Console, System.SysUtils, Core.Emulation, Core.Platforms,
  Core.PlatformServices, Core.Snapshots, Core.DVD.Image, PS2.Console,
  Core.Platforms.PS2.Adapter, Core.Platforms.PS1.Adapter,
  RM.Platforms.PS2.Settings, RM.Platforms.PS2.Input, RM.Platforms.PS1.Input,
  RM.Platforms.PS1.Devices, RM.Platforms.PS1.Help, RM.Platforms.PS1.Gamepads,
  RM.Settings.Platform, RM.Settings.Catalog, RM.Settings.Devices,
  RM.Settings.Callouts, RM.ControlsHelp.Content, RM.Settings.Runtime,
  RM.Session.Runtime, RM.Window.Layout, RM.Input.Runtime, RM.Gamepad.Factory,
  RM.Platforms.Presentation;

const
  PlatformIconPS2 =
    'M6,5 C5,3 6,1 8,1 L14,1 C16,1 17,2 17,4 L31,4 C31,2 32,1 34,1 L40,1 C42,1 43,3 42,5 ' +
    'C44,6 45,9 45.5,12 L48,26 C49,32 44,35 40.5,31 L34,23.5 C31.5,26.5 26.5,26 24.7,22.5 ' +
    'L23.3,22.5 C21.5,26 16.5,26.5 14,23.5 L7.5,31 C4,35 -1,32 0,26 L2.5,12 C3,9 4,6 6,5 Z ' +
    'M8.5,7.5 L8.5,10.5 L5.5,10.5 L5.5,13.5 L8.5,13.5 L8.5,16.5 L11.5,16.5 L11.5,13.5 ' +
    'L14.5,13.5 L14.5,10.5 L11.5,10.5 L11.5,7.5 Z ' +
    'M18.5,16.5 C16.8,16.5 15.5,17.8 15.5,19.5 C15.5,21.2 16.8,22.5 18.5,22.5 ' +
    'C20.2,22.5 21.5,21.2 21.5,19.5 C21.5,17.8 20.2,16.5 18.5,16.5 Z ' +
    'M29.5,16.5 C27.8,16.5 26.5,17.8 26.5,19.5 C26.5,21.2 27.8,22.5 29.5,22.5 ' +
    'C31.2,22.5 32.5,21.2 32.5,19.5 C32.5,17.8 31.2,16.5 29.5,16.5 Z ' +
    'M18,10.5 L18,12.5 L22,12.5 L22,10.5 Z M25,10 L25,13 L29,11.5 Z ' +
    'M38,7 C35.8,7 35.8,10.2 38,10.2 C40.2,10.2 40.2,7 38,7 Z ' +
    'M34.5,10.5 C32.3,10.5 32.3,13.7 34.5,13.7 C36.7,13.7 36.7,10.5 34.5,10.5 Z ' +
    'M41.5,10.5 C39.3,10.5 39.3,13.7 41.5,13.7 C43.7,13.7 43.7,10.5 41.5,10.5 Z ' +
    'M38,14 C35.8,14 35.8,17.2 38,17.2 C40.2,17.2 40.2,14 38,14 Z';

type
  TPS2ScreenSession = class(TPlatformSessionHandler)
    class procedure Connect(const Context: TSessionRuntimeContext); override;
    class procedure Disconnect(const Context: TSessionRuntimeContext); override;
  end;

class procedure TPS2ScreenSession.Connect(const Context: TSessionRuntimeContext);
begin
  inherited;
  var Core := Context.Host.Core;
  if Core is TPS2CoreAdapter then
    (Core as TPS2CoreAdapter).SetDisplayAttached(True);
end;

class procedure TPS2ScreenSession.Disconnect(const Context: TSessionRuntimeContext);
begin
  var Core := Context.Host.Core;
  if Core is TPS2CoreAdapter then
    (Core as TPS2CoreAdapter).SetDisplayAttached(False);
  inherited;
end;

class function TPS2Platform.DVDSource(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if (Context.SelectedPlatform <> '') and not SameText(Context.SelectedPlatform, ROM_SYSTEM_PS2) then
    Exit;
  if (Context.Archive = nil) and not Context.HasExtension(['.iso', '.mds', '.chd']) then
    Exit;
  var Core := TPS2CoreAdapter.TryCreateDVD(Context.Stream, Context.Storage, Context.RomName, Context.SourceName);
  if Core <> nil then
    Result := TCoreMatch.Create(ROM_CORE_ID_PS2,
      function: IEmulationCore
      begin
        Result := Core;
      end);
end;

class function TPS2Platform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.elf']) then
  begin
    var Core := TPS2CoreAdapter.TryCreateELF(Context.Stream, Context.Storage, Context.RomName);
    if Core <> nil then
      Exit(TCoreMatch.Create(ROM_CORE_ID_PS2,
        function: IEmulationCore
        begin
          Result := Core;
        end));
  end;
  if Context.IsDiscSource and TPS2CoreAdapter.IsPS2CD(Context.Disc) then
    Result := TCoreMatch.Create('PS2',
      function: IEmulationCore
      begin
        Result := TPS2CoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName,
          TDVDCDImage.Create(Context.TakeDisc, True));
      end);
end;

class procedure TPS2Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TPS2Config.Create('', nil);
  Config := C;
  var Map := C.Keys;
  for var Port := 0 to 1 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[Port, B] := Map[Port, B];
end;

class procedure TPS2Platform.LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile);
var
  Config: IEmulatorConfig;
begin
  var C := TPS2Config.Create('', nil);
  Config := C;
  for var Port := 0 to 1 do
  begin
    var Section := 'Keys';
    if Port > 0 then
      Section := Section + IntToStr(Port + 1);
    for var Extra := Low(TPS2Extra) to High(TPS2Extra) do
      AddLegacyInputKey(Input, PS1Action(Port, TPS1Extra(Ord(Extra))), ReadEmulatorKey(Ini, Section,
          TPS2Config.ExtraKeyName(Extra), C.ExtraKey(Port, Extra)));
  end;
end;

class procedure TPS2Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform(
    'ps2',
    'PlayStation 2',
    'PS2',
    'Sony',
    'PS2 PlayStation 2',
    'ps2',
    ['ps2', 'playstation2'],
    ['.iso', '.chd', '.cue', '.bin', '.mds', '.elf'],
    'PS2',
    'ps2',
    2
  );
  var Registration := TEmulationCoreRegistration.Create(ROM_CORE_ID_PS2, ['.elf']);
  // PS2 DVDs share the PLAYSTATION volume marker with PS1. Verify BOOT2
  // before disc-platform probes interpret the image as a CD.
  Registration.Add(TCoreLoadStage.Stream, 5, DVDSource);
  // Before PSP's generic MIPS ELF route; the PS2 probe checks RAM entry bounds.
  Registration.Add(TCoreLoadStage.Source, 5, Source);
  // Disc images launched as PlayStation 2 (library, recent games, the platform
  // choice) are resolved among the disc platforms only.
  Registration.AddDiscPlatform('ps2', Source);
  RegisterEmulationCore(Registration);
  RegisterSnapshotPolicy(ROM_CORE_ID_PS2, TPS2Console.SnapshotPolicy);
  var Service := Default(TPlatformServices);
  Service.LibraryFeatures := [TLibraryFeature.CueTracks];
  RegisterPlatformServices('ps2', Service);
  RegisterPlatformPresentation('ps2', 'ps2', PlatformIconPS2);
  RegisterSettingsProfile('PS2', TPS2Settings);
  RegisterPlatformSettingsDevices('ps2', TPS1SettingsDevices);
  RegisterPlatformDeviceCallouts('ps2', TPS1DeviceCallouts);
  RegisterPlatformControlsHelp('ps2', TPS1ControlsHelp);
  RegisterPlatformSettingsHandler('ps2', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('ps2', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('ps2', TPS2ScreenSession);
  RegisterPlatformInputHandler('ps2', TPS2InputHandler);
  RegisterPlatformGamepads('ps2', TGamepadPS1Analog, [TGamepadDeviceVariant.Create('pad-analog', TGamepadPS1Analog)]);
  var Definition :=
    TPlatformInputDefinition.Create(
    [
      TEmulatorButton.Up,
      TEmulatorButton.Down,
      TEmulatorButton.Left,
      TEmulatorButton.Right,
      TEmulatorButton.A,
      TEmulatorButton.B,
      TEmulatorButton.C,
      TEmulatorButton.X,
      TEmulatorButton.Y,
      TEmulatorButton.Z,
      TEmulatorButton.Mode,
      TEmulatorButton.Start,
      TEmulatorButton.Select
    ]
  );
  Definition.ButtonNames[TEmulatorButton.A] := 'Cross';
  Definition.ButtonNames[TEmulatorButton.B] := 'Circle';
  Definition.ButtonNames[TEmulatorButton.C] := 'L1';
  Definition.ButtonNames[TEmulatorButton.X] := 'Square';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Triangle';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R1';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'R2';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.LegacyKeyNames[TEmulatorButton.A] := 'Cross';
  Definition.LegacyKeyNames[TEmulatorButton.B] := 'Circle';
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'L1';
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'Square';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'Triangle';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'R1';
  Definition.LegacyKeyNames[TEmulatorButton.Mode] := 'R2';
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.BeforeLegacyBindings := LoadLegacyExtras;
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.SharedFilterBinding := FilterPS1CompatibilityBinding;
  Definition.SharedBindingOrder := 20;
  RegisterPlatformInput('ps2', Definition);
  FRegistered := True;
  RegisterPlatformAchievementMedia('ps2', RAConsolePlayStation2, TPlatformRegistry.Require('ps2').Extensions, True);
end;

end.

