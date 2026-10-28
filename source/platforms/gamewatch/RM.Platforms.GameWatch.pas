unit RM.Platforms.GameWatch;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_GW = 'gw';

type
  TGWPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  GW.Artwork, RM.Platforms.GameWatch.Artwork, RM.Settings.Catalog,
  RM.Settings.Platform, System.StrUtils, Core.Emulation, Core.Platforms,
  Core.Platforms.GameWatch.Adapter, GW.Cartridge, RM.Platforms.Presentation,
  RM.Platforms.GameWatch.Icons, RM.Gamepad.Factory,
  RM.Platforms.GameWatch.Gamepads, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Platforms.GameWatch.Help, RM.Settings.Callouts, RM.Settings.Devices,
  RM.Platforms.GameWatch.Devices, System.Classes;

class function TGWPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if TGWCartridge.Recognizes(Context.Data, Context.SourceName) then
    Result := ImageMatch(Context, 'GW',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TGWCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end);
end;

class procedure TGWPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('gw', 'Game && Watch', 'G&&W',
    'Nintendo', 'GW MGW LCD Micro Vs', 'gw', ['gw'],
    ['.gw', '.mgw', '.zip', '.7z'], '', 'gw', 2);
end;

class procedure TGWPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('GW', ['.gw', '.mgw']);
  Registration.Add(TCoreLoadStage.Container, 10, Recognize);
  Registration.Add(TCoreLoadStage.Image, 1, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TGWPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TGWConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TGWPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.PadDevicesOnly := False;
  Definition.ButtonNames[TEmulatorButton.Select] := 'Time';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Game A';
  Definition.ButtonNames[TEmulatorButton.C] := 'X';
  Definition.ButtonNames[TEmulatorButton.X] := 'Game B';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Alarm / ACL';
  Definition.ButtonNames[TEmulatorButton.Z] := 'Y';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Start';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('gw', Definition);
end;

class procedure TGWPlatform.RegisterClient;
begin
  RegisterSettingsPlatform('gw', TSettingsPlatform);
  RegisterPlatformSettingsDevices('gw', TGWSettingsDevices);
  RegisterPlatformDeviceCallouts('gw', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('gw', TGWControlsHelp);
  RegisterPlatformSettingsHandler('gw', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('gw', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('gw', TPlatformSessionHandler);
  RegisterPlatformInputHandler('gw', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('gw', TGamepadGameWatchStandart, []);
  RegisterPlatformPresentation('gw', 'gw', PlatformIconGW);
end;

class procedure TGWPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  SetDefaultGWArtworkRenderer(CreateGWArtworkRenderer);
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

