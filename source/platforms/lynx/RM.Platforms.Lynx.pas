unit RM.Platforms.Lynx;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_LYNX = 'lynx';

type
  TLynxPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class function RecognizeRaw(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Input.Gamepads,
  System.Classes, Core.Emulation, Core.Platforms, Core.Snapshots,
  Core.Platforms.Lynx.Adapter, RM.Platforms.Lynx.Settings,
  RM.Platforms.Lynx.Gamepads, RM.Settings.Catalog, RM.Platforms.Presentation,
  RM.Gamepad.Factory, RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout,
  RM.Settings.Runtime, RM.ControlsHelp.Content, RM.Settings.Callouts,
  RM.Settings.Devices;

const
  // Device silhouette: the Lynx is a horizontal handheld.
  PlatformIconLynx = 'M4,0 H60 Q64,0 64,4 V28 Q64,32 60,32 H4 Q0,32 0,28 V4 Q0,0 4,0 Z ' +
    'M20,5 V27 H44 V5 Z M8,10 V14 H4 V18 H8 V22 H12 V18 H16 V14 H12 V10 Z ' +
    'M50,20 A3,3 0 1 0 56,20 A3,3 0 1 0 50,20 Z M56,12 A3,3 0 1 0 62,12 A3,3 0 1 0 56,12 Z';

class procedure TLynxPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.LeftShoulder);
end;

class function TLynxPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not (Context.Signature(0, 'LYNX') or Context.Signature(6, 'BS93')) then
    Exit;
  Result := ImageMatch(Context, 'LYNX',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TLynxCoreAdapter.Create(Input, Context.Storage, Context.RomName);
    end, False, ROM_SYSTEM_LYNX, '', 2 * 1024 * 1024);
end;

class function TLynxPlatform.RecognizeRaw(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.HasExtension(['.lnx', '.lyx']) then
    Exit;
  Result := ImageMatch(Context, 'LYNX',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TLynxCoreAdapter.Create(Input, Context.Storage, Context.RomName);
    end, False, ROM_SYSTEM_LYNX, '', 2 * 1024 * 1024);
end;

class procedure TLynxPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TLynxConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TLynxPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('lynx', 'Lynx', 'Lynx', 'Atari',
    'Atari Lynx Handy portable', 'lynx', ['lynx', 'atarilynx'],
    ['.lnx', '.lyx', '.o', '.com', '.bll'], 'Lynx', 'lynx', 1);
  RegisterSnapshotPolicy('LYNX', TSnapshotPolicy.Create(1));
  var Registration := TEmulationCoreRegistration.Create('LYNX', ['.lnx', '.lyx', '.o', '.com', '.bll']);
  Registration.MaxArchiveImageSize := 2 * 1024 * 1024;
  Registration.Add(TCoreLoadStage.Header, 5, Recognize);
  Registration.Add(TCoreLoadStage.Image, 90, RecognizeRaw);
  RegisterEmulationCore(Registration);
  RegisterSettingsProfile('Lynx', TLynxSettings);
  RegisterPlatformSettingsDevices('lynx', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('lynx', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('lynx', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('lynx', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('lynx', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('lynx', TPlatformSessionHandler);
  RegisterPlatformInputHandler('lynx', TPlatformInputHandler);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.C]);
  Definition.ButtonNames[TEmulatorButton.Select] := 'Option 1';
  Definition.ButtonNames[TEmulatorButton.C] := 'Option 2';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Pause';
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('lynx', Definition);
  RegisterPlatformGamepads('lynx', TGamepadLynxStandard, []);
  RegisterPlatformPresentation('lynx', 'lynx', PlatformIconLynx);
  FRegistered := True;
end;

end.

