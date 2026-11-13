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
  RM.Input.Gamepads,
  RM.Settings.Catalog, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.WS.Adapter, RM.Platforms.WS.Settings,
  RM.Platforms.Presentation, RM.Platforms.GB.Icons, RM.Gamepad.Factory,
  RM.Platforms.WS.Gamepads, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Settings.Callouts, RM.Settings.Devices, System.Classes, WS.Cartridge,
  RM.Platforms.WS.Help;

const
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
  RegisterSettingsProfile('WonderSwan', TWSSettings);
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
  RegisterPlatformPresentation('ws', 'ws', PlatformIconGB);
  RegisterPlatformPresentation('wsc', 'wsc', PlatformIconGB);
end;

class procedure TWSPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

