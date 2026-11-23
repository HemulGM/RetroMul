unit RM.Platforms.System32;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input;

type
  TSystem32Platform = class
  private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.Classes, Core.Emulation, Core.Platforms, Core.Snapshots, S32.RomSets,
  Core.Platforms.System32.Adapter, RM.Gamepad.Factory, RM.Input.Gamepads,
  RM.Input.Runtime, RM.Platforms.Presentation, RM.Platforms.CPS.Icons,
  RM.Platforms.System32.Gamepads, RM.Settings.Catalog, RM.Settings.Platform,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  RM.Settings.Builder;

type
  TSystem32Settings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

procedure TSystem32Settings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSystem32DIP', 'System 32 board');
  var A := Context.AddInteger('RowSystem32DIPA', 'Board DIP switches',
    'Use -1 for board defaults, or 0-15 for the four DIP switches. Reopen the game to apply.',
    'System32', 'DIPA', -1, 15);
  A.Min := -1;
  A.ApplyMode := TSettingsApplyMode.OnNextLoad;
  var B := Context.AddInteger('RowSystem32DIPB', 'Second board DIP switches',
    'Use -1 for defaults, or 0-15 for the second PCB in Air Rescue and F1 Exhaust Note.',
    'System32', 'DIPB', -1, 15);
  B.Min := -1;
  B.ApplyMode := TSettingsApplyMode.OnNextLoad;
  var Printer := Context.AddBoolean('RowSystem32PrinterReady', 'Virtual printer ready signal',
    'Permit Kokology CD playback without a physical printer. Paper output is not emulated.',
    'System32', 'CDPrinterReady', True);
  Printer.ApplyMode := TSettingsApplyMode.OnNextLoad;
  var CD := Context.AddPath('RowSystem32CD', 'CD image',
    'Optional Kokology CD image. Leave empty to find a CHD or CUE beside the ROM archive or in its game folder.',
    'System32', 'DiscImage', '', False);
  CD.ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

class function TSystem32Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var RomSet: TS32RomSet;
  if TS32RomSet.Identify(Context.Archive, Context.SourceName, RomSet) then
  begin
    Result := TCoreMatch.Create('System32',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TS32CoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end);
    Result.Format.SystemId := 'system32';
  end;
end;

class procedure TSystem32Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TS32Config.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    for var P := 0 to 3 do
      Keys[P, B] := C.Keys[P, B];
end;

class procedure TSystem32Platform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var B := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, B), Ord(B), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.North);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.LeftShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Z), TGamepadButton.RightShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Mode), TGamepadButton.RightStick);
end;

class procedure TSystem32Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('system32', 'Sega System 32', 'System 32',
    'Sega', 'Sega System32 System 32 V60 arcade', 'system32', ['system32', 'segas32'],
    [], 'System32', 'system32', 4);
  var Registration := TEmulationCoreRegistration.Create('System32', []);
  Registration.Add(TCoreLoadStage.Container, 20, Recognize);
  RegisterEmulationCore(Registration);
  var Policy := TSnapshotPolicy.Create(10);
  Policy.AcceptedVersions := [8, 9];
  RegisterSnapshotPolicy('system32', Policy);
  RegisterSettingsPlatform('system32', TSystem32Settings,
    'Use a complete, recognized arcade ROM set for the matching board. Keep the ROM archive ' +
    'name and the expected names inside it. Some variants require parent set data or ' +
    'board-specific ROMs. The emulation menu offers coin insertion for games with a coin ' +
    'acceptor.');
  RegisterPlatformSettingsDevices('system32', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('system32', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('system32', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('system32', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('system32', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('system32', TPlatformSessionHandler);
  RegisterPlatformInputHandler('system32', TPlatformInputHandler);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.A] := '1';
  Definition.ButtonNames[TEmulatorButton.B] := '2';
  Definition.ButtonNames[TEmulatorButton.C] := '3';
  Definition.ButtonNames[TEmulatorButton.X] := '4';
  Definition.ButtonNames[TEmulatorButton.Y] := '5';
  Definition.ButtonNames[TEmulatorButton.Z] := '6';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Coin';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Service';
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('system32', Definition);
  RegisterPlatformGamepads('system32', TGamepadSystem32, []);
  // Reuse the existing Fluent Games TPath icon.
  RegisterPlatformPresentation('system32', 'system32', PlatformIconCPS);
  FRegistered := True;
end;

end.

