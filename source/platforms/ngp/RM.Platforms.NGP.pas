unit RM.Platforms.NGP;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_NGP = 'ngp';
  ROM_SYSTEM_NGPC = 'ngpc';

type
  TNGPPlatform = class
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
  Core.Platforms.NGP.Adapter, RM.Platforms.NGP.Settings,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Platforms.NGP.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  PlatformIcon =
    'M50,4 L14,4 C12.8999996185303,4 12,4.90000009536743 12,6 L12,56 C12,58.2099990844727 13.789999961853,60 16,60 ' +
    'L48,60 C50.2099990844727,60 52,58.2099990844727 52,56 L52,6 C52,4.90000009536743 51.0999984741211,4 50,4 Z M27' +
    ',44 L24,44 L24,47 L20,47 L20,44 L17,44 L17,40 L20,40 L20,37 L24,37 L24,40 L27,40 L27,44 Z M30,56 L29,56 C28.45' +
    '00007629395,56 28,55.5499992370605 28,55 C28,54.4500007629395 28.4500007629395,54 29,54 L30,54 C30.54999923706' +
    '05,54 31,54.4500007629395 31,55 C31,55.5499992370605 30.5499992370605,56 30,56 Z M35,56 L34,56 C33.45000076293' +
    '95,56 33,55.5499992370605 33,55 C33,54.4500007629395 33.4500007629395,54 34,54 L35,54 C35.5499992370605,54 36,' +
    '54.4500007629395 36,55 C36,55.5499992370605 35.5499992370605,56 35,56 Z M38,48 C36.3400001525879,48 35,46.6599' +
    '998474121 35,45 C35,43.3400001525879 36.3400001525879,42 38,42 C39.6599998474121,42 41,43.3400001525879 41,45 ' +
    'C41,46.6599998474121 39.6599998474121,48 38,48 Z M45,41 C43.3400001525879,41 42,39.6599998474121 42,38 C42,36.' +
    '3400001525879 43.3400001525879,35 45,35 C46.6599998474121,35 48,36.3400001525879 48,38 C48,39.6599998474121 46' +
    '.6599998474121,41 45,41 Z M48,30 L16,30 L16,8 L48,8 L48,30 Z ';
  NGP_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class procedure TNGPPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
end;

class function TNGPPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if (Length(Bytes) >= $40) and (Length(Bytes) <= $400000) and
    (Context.Signature(0, 'COPYRIGHT BY SNK CORPORATION') or Context.Signature(0, ' LICENSED BY SNK CORPORATION')) and
    (Bytes[$23] in [$00, $10]) then
  begin
    var SystemId := 'ngp';
    if Bytes[$23] = $10 then
      SystemId := 'ngpc';
    Result := ImageMatch(Context, 'NeoGeoPocket',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNGPCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, SystemId, '', NGP_IMAGE_MAX_SIZE);
  end;
end;

class procedure TNGPPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('ngp', 'Neo Geo Pocket', 'NGP',
    'SNK', 'NGP Pocket monochrome', 'ngp', ['ngp', 'neogeopocket'],
    ['.ngp', '.ngc'],
    'NeoGeoPocket', 'ngp', 1);
  TPlatformRegistry.RegisterPlatform('ngpc', 'Neo Geo Pocket Color', 'NGPC',
    'SNK', 'NGPC Pocket Color', 'ngpc', ['ngpc', 'neogeopocketcolor'],
    ['.ngp', '.ngc'],
    'NeoGeoPocket', 'ngpc', 1);
end;

class procedure TNGPPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('NGP', ['.ngp', '.ngc']);
  Registration.Add(TCoreLoadStage.Header, 10, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TNGPPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('NGP', TSnapshotPolicy.Create(2));
  RegisterSnapshotPolicy('NGPC', TSnapshotPolicy.Create(2));
end;

class procedure TNGPPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TNGPConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TNGPPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start]);
  Definition.ButtonNames[TEmulatorButton.Start] := 'Option';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('ngp', Definition);
  RegisterPlatformInput('ngpc', Definition);
end;

class procedure TNGPPlatform.RegisterClient;
begin
  RegisterSettingsProfile('NeoGeoPocket', TNGPSettings,
    'Use the Pocket or Pocket Color folder for the appropriate system. Keep original dumps ' +
    'when firmware or cartridge detection behaves unexpectedly. Save progress in the game when ' +
    'it supports cartridge save memory.');
  RegisterPlatformSettingsDevices('ngp', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('ngpc', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('ngp', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('ngpc', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('ngp', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('ngpc', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('ngp', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('ngpc', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('ngp', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('ngpc', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('ngp', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('ngpc', TPlatformSessionHandler);
  RegisterPlatformInputHandler('ngp', TPlatformInputHandler);
  RegisterPlatformInputHandler('ngpc', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('ngp', TGamepadNGPStandart, []);
  RegisterPlatformGamepads('ngpc', TGamepadNGPCStandart, []);
  RegisterPlatformPresentation('ngp', 'ngp', PlatformIcon);
  RegisterPlatformPresentation('ngpc', 'ngpc', PlatformIcon);
end;

class procedure TNGPPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
  RegisterPlatformAchievementMedia('ngp', RAConsoleNeoGeoPocket, TPlatformRegistry.Require('ngp').Extensions);
  RegisterPlatformAchievementMedia('ngpc', RAConsoleNeoGeoPocket, TPlatformRegistry.Require('ngpc').Extensions);
end;

end.

