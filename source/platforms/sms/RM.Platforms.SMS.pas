unit RM.Platforms.SMS;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_SMS = 'sms';
  ROM_SYSTEM_GG = 'gg';

type
  TSMSPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Match(Context: TCoreLoadContext; const SystemId: string; const Encoding: string): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function ExtensionHint(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterCore; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, RM.Platforms.SMS.Keyboard, Core.Emulation, Core.Platforms,
  Core.PlatformServices, Core.Snapshots, Core.Platforms.SMS.Adapter,
  SG1000.Console, RM.Platforms.SMS.Settings, RM.Platforms.Presentation,
  RM.Platforms.SMS.Icons, RM.Gamepad.Factory, RM.Platforms.SMS.Gamepads,
  System.UITypes, RM.Input.Runtime, RM.Keyboard.Input, RM.Session.Runtime,
  RM.Keyboard.Session, RM.Window.Layout, RM.Keyboard.Window, RM.Settings.Runtime,
  RM.Keyboard.Settings, RM.ControlsHelp.Content, RM.Settings.Callouts,
  RM.Settings.Devices, System.Classes;

const
  SMS_ROM_COPIER_HEADER_SIZE = 512;

class function TSMSPlatform.Match(Context: TCoreLoadContext; const SystemId: string; const Encoding: string): TCoreMatch;
begin
  Result := ImageMatch(Context, SystemId,
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      var Model := TSGModel.MasterSystem;
      if SystemId = 'gg' then
        Model := TSGModel.GameGear;
      Result := TSMSCoreAdapter.Create(Input, Context.Storage, Context.RomName, False, Ord(Model));
    end, True, SystemId, Encoding);
end;

class function TSMSPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  for var Offset in [$1FF0, $3FF0, $7FF0] do
    for var Copier in [0, SMS_ROM_COPIER_HEADER_SIZE] do
      if Context.Signature(Offset + Copier, 'TMR SEGA') and
        (Length(Bytes) > Offset + Copier + 15) and ((Bytes[Offset + Copier + 15] shr 4) in [3..7]) then
      begin
        var SystemId := 'sms';
        if Bytes[Offset + Copier + 15] shr 4 >= 5 then
          SystemId := 'gg';
        Exit(Match(Context, SystemId, ''));
      end;
end;

class function TSMSPlatform.ExtensionHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.sms']) then
    Result := Match(Context, 'sms', Context.HeaderFormat.Encoding)
  else if Context.HasExtension(['.gg']) then
    Result := Match(Context, 'gg', Context.HeaderFormat.Encoding);
end;

class procedure TSMSPlatform.RegisterCore;
begin
  TPlatformRegistry.RegisterPlatform('sms', 'Master System', 'Master System',
    'Sega', 'SMS Mark III', 'mastersystem', ['mastersystem', 'sms'],
    ['.sms', '.zip', '.7z'],
    'MasterSystem', 'sms', 2);
  TPlatformRegistry.RegisterPlatform('gg', 'Game Gear', 'Game Gear',
    'Sega', 'GG GameGear', 'gamegear', ['gamegear', 'gg'],
    ['.gg', '.zip', '.7z'],
    'GameGear', 'gg', 1);
  RegisterSnapshotPolicy('SMS', TSnapshotPolicy.Create(4));
  RegisterSnapshotPolicy('GG', TSnapshotPolicy.Create(4));
  var Registration := TEmulationCoreRegistration.Create('SMS', ['.sms', '.gg']);
  Registration.Add(TCoreLoadStage.Header, 50, Header);
  Registration.Add(TCoreLoadStage.OverrideHint, 10, ExtensionHint);
  RegisterEmulationCore(Registration);
end;

class procedure TSMSPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
begin
  Keys[0, TEmulatorButton.Up] := vkUp;
  Keys[0, TEmulatorButton.Down] := vkDown;
  Keys[0, TEmulatorButton.Left] := vkLeft;
  Keys[0, TEmulatorButton.Right] := vkRight;
  Keys[0, TEmulatorButton.A] := vkZ;
  Keys[0, TEmulatorButton.B] := vkX;
  Keys[0, TEmulatorButton.Start] := vkReturn;
  Keys[1, TEmulatorButton.Up] := vkNumpad8;
  Keys[1, TEmulatorButton.Down] := vkNumpad5;
  Keys[1, TEmulatorButton.Left] := vkNumpad4;
  Keys[1, TEmulatorButton.Right] := vkNumpad6;
  Keys[1, TEmulatorButton.A] := vkNumpad1;
  Keys[1, TEmulatorButton.B] := vkNumpad2;
  Keys[1, TEmulatorButton.Start] := vkNumpad0;
end;

class procedure TSMSPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start]);
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('sms', Definition);
  RegisterPlatformInput('gg', Definition);
end;

class procedure TSMSPlatform.RegisterClient;
begin
  RegisterSettingsProfile('MasterSystem', TMasterSystemSettings);
  RegisterSettingsProfile('GameGear', TGameGearSettings);
  RegisterPlatformKeyboard('sms', TSMSKeyboard);
  RegisterPlatformKeyboard('gg', TSMSKeyboard);
  RegisterPlatformSettingsDevices('sms', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('gg', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('sms', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('gg', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('sms', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('gg', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('sms', TKeyboardSettingsHandler);
  RegisterPlatformSettingsHandler('gg', TKeyboardSettingsHandler);
  RegisterPlatformWindowLayout('sms', TKeyboardWindowLayout);
  RegisterPlatformWindowLayout('gg', TKeyboardWindowLayout);
  RegisterPlatformSessionHandler('sms', TKeyboardSessionHandler);
  RegisterPlatformSessionHandler('gg', TKeyboardSessionHandler);
  RegisterPlatformInputHandler('sms', TKeyboardInputHandler);
  RegisterPlatformInputHandler('gg', TKeyboardInputHandler);
  RegisterPlatformGamepads('sms', TGamepadSMSStandart, []);
  RegisterPlatformGamepads('gg', TGamepadGameGearStandart, []);
  RegisterPlatformPresentation('sms', 'sms', PlatformIconSMS);
  RegisterPlatformPresentation('gg', 'gg', PlatformIconGG);
  RegisterInput;
end;

class procedure TSMSPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

