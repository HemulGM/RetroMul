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
  RM.Input.Runtime, RM.Platforms.Presentation, RM.Platforms.System32.Gamepads,
  RM.Settings.Catalog, RM.Settings.Platform, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Settings.Callouts, RM.Settings.Devices, RM.Settings.Builder;

const
  PlatformIcon =
 'M85,20 L85,0 L15,0 L15,20 L20,20 L20,50 L15,70 L15,100 L85,100 L85,70 L80,50 L80,20 L85,20 Z M25,20 L75,20 L75,50 L37.5,50 L37.5,47.0699996948242 C40.4099998474121,46.0379981994629 42.5,43.2589988708496 ' +
    '42.5,40 C42.5,35.8639984130859 39.1360015869141,32.5 35,32.5 C30.8639984130859,32.5 27.5,35.8639984130859 27.5,40 C27.5,43.2589988708496 29.5900001525879,46.0380020141602 32.5,47.0699996948242 L32.5,50 ' +
    'L25,50 L25,20 Z M45,90 L40,90 L40,80 L45,80 L45,90 Z M60,90 L55,90 L55,80 L60,80 L60,90 Z M20.1560001373291,70 L23.9060001373291,55 L32.5,55 L32.5,65 L37.5,65 L37.5,55 L76.0940017700195,55 L79.8440017700195,' +
    '70 L20.1560001373291,70 Z M62.5,60 C62.5,61.3819999694824 61.3819999694824,62.5 60,62.5 C58.6180000305176,62.5 57.5,61.3819999694824 57.5,60 C57.5,58.6180000305176 58.6180000305176,57.5 60,57.5 C61.3819999694824,' +
    '57.5 62.5,58.6180000305176 62.5,60 Z M52.5,60 C52.5,61.3819999694824 51.3819999694824,62.5 50,62.5 C48.6180000305176,62.5 47.5,61.3819999694824 47.5,60 C47.5,58.6180000305176 48.6180000305176,57.5 50,57.5 ' +
    'C51.3819999694824,57.5 52.5,58.6180000305176 52.5,60 Z M67.5,65 C67.5,66.3820037841797 66.3820037841797,67.5 65,67.5 C63.6179962158203,67.5 62.5,66.3820037841797 62.5,65 C62.5,63.6179962158203 63.6180000305176,' +
    '62.5 65,62.5 C66.3820037841797,62.5 67.5,63.6180000305176 67.5,65 Z M57.5,65 C57.5,66.3820037841797 56.3819999694824,67.5 55,67.5 C53.6180000305176,67.5 52.5,66.3820037841797 52.5,65 C52.5,63.6179962158203 ' +
    '53.6180000305176,62.5 55,62.5 C56.3819999694824,62.5 57.5,63.6180000305176 57.5,65 Z M72.5,60 C72.5,61.3819999694824 71.3820037841797,62.5 70,62.5 C68.6179962158203,62.5 67.5,61.3819999694824 67.5,60 C67.5,' +
    '58.6180000305176 68.6179962158203,57.5 70,57.5 C71.3820037841797,57.5 72.5,58.6180000305176 72.5,60 Z ';

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
  RegisterPlatformPresentation('system32', 'system32', PlatformIcon);
  FRegistered := True;
end;

end.

