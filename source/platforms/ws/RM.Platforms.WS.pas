unit RM.Platforms.WS;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_WS = 'ws';
  ROM_SYSTEM_WSC = 'wsc';

type
  TWSPlatform = class
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
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RA.Console, Core.PlatformServices, RM.Input.Gamepads, RM.Settings.Catalog,
  Core.Snapshots, System.StrUtils, Core.Emulation, Core.Platforms,
  Core.Platforms.WS.Adapter, RM.Platforms.WS.Settings, RM.Platforms.Presentation,
  RM.Gamepad.Factory, RM.Platforms.WS.Gamepads, RM.Input.Runtime,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes, WS.Cartridge, RM.Platforms.WS.Help;

const
  PlatformIcon =
    '''
    M8,1 L58,1 C61,1 63,3 63,6 L63,29 C63,32 62,34 58,35 C51,37 44,37 37,36 C30,35 25,35 19,36 C15,37 11,37 8,37
    C4,37 2,34 1.5,30 C0.5,23 0.5,14 1.60000002384186,8 C2.29999995231628,4 4.19999980926514,1 8,1 Z M8,3.5
    C5.69999980926514,3.5 4.59999990463257,5.69999980926514 4.09999990463257,8.5 C3,14.1999998092651 3,
    22.7999992370605 4,29.6000003814697 C4.5,32.7999992370605 5.69999980926514,34.5 8,34.5 C11,34.5 14.8000001907349,
    34.5 18.6000003814697,33.5 C24.7000007629395,32.5 30.2999992370605,32.5 37.4000015258789,33.5 C44.2000007629395,
    34.5 50.7000007629395,34.5 57.2999992370605,32.5999984741211 C60,31.8999996185303 60.5,30.8999996185303 60.5,29
    L60.5,6 C60.5,4.40000009536743 59.5999984741211,3.5 58,3.5 Z M19,6 L48,6 C50.2000007629395,6 52,7.80000019073486 52,
    10 L52,26 C52,28.2000007629395 50.2000007629395,30 48,30 L19,30 C16.7999992370605,30 15,28.2000007629395 15,26 L15,
    10 C15,7.80000019073486 16.7999992370605,6 19,6 Z M19,8.5 C18.2000007629395,8.5 17.5,9.19999980926514 17.5,10 L17.5,
    26 C17.5,26.7999992370605 18.2000007629395,27.5 19,27.5 L48,27.5 C48.7999992370605,27.5 49.5,26.7999992370605 49.5,
    26 L49.5,10 C49.5,9.19999980926514 48.7999992370605,8.5 48,8.5 Z M8,7 L10.5,7 L10.5,9.80000019073486 L13.3000001907349,
    9.80000019073486 L13.3000001907349,12.3000001907349 L10.5,12.3000001907349 L10.5,15.1000003814697 L8,15.1000003814697
    L8,12.3000001907349 L5.19999980926514,12.3000001907349 L5.19999980926514,9.80000019073486 L8,9.80000019073486 Z M8,
    22 L10.5,22 L10.5,24.7999992370605 L13.3000001907349,24.7999992370605 L13.3000001907349,27.2999992370605 L10.5,
    27.2999992370605 L10.5,30.1000003814697 L8,30.1000003814697 L8,27.2999992370605 L5.19999980926514,27.2999992370605
    L5.19999980926514,24.7999992370605 L8,24.7999992370605 Z M59.4000015258789,9 C59.4000015258789,10.6999998092651
    58,12.1000003814697 56.2999992370605,12.1000003814697 C54.5999984741211,12.1000003814697 53.2000007629395,
    10.6999998092651 53.2000007629395,9 C53.2000007629395,7.30000019073486 54.5999984741211,5.90000009536743
    56.2999992370605,5.90000009536743 C58,5.90000009536743 59.4000015258789,7.30000019073486 59.4000015258789,
    9 Z M59.2000007629395,24.7999992370605 C59.2000007629395,25.7000007629395 58.5,26.3999996185303 57.5999984741211,
    26.3999996185303 C56.7000007629395,26.3999996185303 56,25.7000007629395 56,24.7999992370605 C56,23.8999996185303
    56.7000007629395,23.2000007629395 57.5999984741211,23.2000007629395 C58.5,23.2000007629395 59.2000007629395,
    23.8999996185303 59.2000007629395,24.7999992370605 Z M56,28.6000003814697 C56,29.5 55.2999992370605,30.2000007629395
    54.4000015258789,30.2000007629395 C53.5,30.2000007629395 52.7999992370605,29.5 52.7999992370605,28.6000003814697
    C52.7999992370605,27.7000007629395 53.5,27 54.4000015258789,27 C55.2999992370605,27 56,27.7000007629395 56,
    28.6000003814697 Z
    ''';
  WS_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class procedure TWSPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardAxis(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadAxis.RightX, -1);
  AddStandardAxis(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadAxis.RightY, -1);
  AddStandardAxis(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadAxis.RightX, 1);
  AddStandardAxis(Input, Port, PadAction(Port, TEmulatorButton.Z), TGamepadAxis.RightY, 1);
end;

class function TWSPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if TWSCartridge.Recognize(Bytes) then
  begin
    var SystemId := 'ws';
    if (Bytes[Length(Bytes) - 9] <> 0) or Context.HasExtension(['.wsc']) then
      SystemId := 'wsc';
    Result := ImageMatch(Context, 'WonderSwan',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TWSCoreAdapter.Create(Input, Context.Storage, Context.RomName, Context.SourceName);
      end, True, SystemId, '', WS_IMAGE_MAX_SIZE);
  end;
end;

class procedure TWSPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('ws', 'WonderSwan', 'WS',
    'Bandai', 'WS Pocket monochrome', 'ws', ['ws', 'wonderswan', 'wswan'],
    ['.ws', '.wsc'],
    'WonderSwan', 'ws', 1);
  TPlatformRegistry.RegisterPlatform('wsc', 'WonderSwan Color', 'WSC',
    'Bandai', 'WSC Pocket Color', 'wsc', ['wsc', 'wonderswancolor', 'wswanc'],
    ['.ws', '.wsc'],
    'WonderSwan', 'wsc', 1);
end;

class procedure TWSPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('WS', ['.ws', '.wsc']);
  Registration.Add(TCoreLoadStage.Header, 10, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TWSPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('WS', TSnapshotPolicy.Create(3));
  RegisterSnapshotPolicy('WSC', TSnapshotPolicy.Create(3));
end;

class procedure TWSPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TWSConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TWSPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]);
  Definition.ButtonNames[TEmulatorButton.Up] := 'X1 / Up';
  Definition.ButtonNames[TEmulatorButton.Right] := 'X2 / Right';
  Definition.ButtonNames[TEmulatorButton.Down] := 'X3 / Down';
  Definition.ButtonNames[TEmulatorButton.Left] := 'X4 / Left';
  Definition.ButtonNames[TEmulatorButton.X] := 'Y1 / Up';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Y2 / Right';
  Definition.ButtonNames[TEmulatorButton.Z] := 'Y3 / Down';
  Definition.ButtonNames[TEmulatorButton.C] := 'Y4 / Left';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('ws', Definition);
  RegisterPlatformInput('wsc', Definition);
end;

class procedure TWSPlatform.RegisterClient;
begin
  RegisterSettingsProfile('WonderSwan', TWSSettings,
    'Automatic model selection follows the image. Change the model only if the game requires ' +
    'specific hardware. For vertical games, check the screen orientation and bindings for both ' +
    'directional pads.');
  RegisterPlatformSettingsDevices('ws', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('wsc', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('ws', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('wsc', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('ws', TWSControlsHelp);
  RegisterPlatformControlsHelp('wsc', TWSControlsHelp);
  RegisterPlatformSettingsHandler('ws', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('wsc', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('ws', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('wsc', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('ws', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('wsc', TPlatformSessionHandler);
  RegisterPlatformInputHandler('ws', TPlatformInputHandler);
  RegisterPlatformInputHandler('wsc', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('ws', TGamepadWSStandart, []);
  RegisterPlatformGamepads('wsc', TGamepadWSCStandart, []);
  RegisterPlatformPresentation('ws', 'ws', PlatformIcon);
  RegisterPlatformPresentation('wsc', 'wsc', PlatformIcon);
end;

class procedure TWSPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
  RegisterPlatformAchievementMedia('ws', RAConsoleWonderSwan, TPlatformRegistry.Require('ws').Extensions);
  RegisterPlatformAchievementMedia('wsc', RAConsoleWonderSwan, TPlatformRegistry.Require('wsc').Extensions);
end;

end.

