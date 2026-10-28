unit RM.Platforms.SG1000;

interface

uses
  Core.Input.Keyboard, Core.EmulatorRegistry, RM.Input,
  System.SysUtils;

const
  ROM_SYSTEM_SG1000 = 'sg1000';
  ROM_SYSTEM_SC3000 = 'sc3000';
  ROM_SYSTEM_SF7000 = 'sf7000';
  ROM_SYSTEM_OMV = 'omv';
  ROM_EXTENSION_SC = '.sc';

type
  TSG1000Platform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Match(Context: TCoreLoadContext; const SystemId: string; const Encoding: string): TCoreMatch; static;
    class function ExtensionHint(Context: TCoreLoadContext): TCoreMatch; static;
    class function Disk(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure RegisterRuntimeServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, RM.Platforms.SG1000.Keyboard, Core.PlatformServices,
  Core.Platforms.SG1000.Adapter, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, SG1000.Console, RM.Platforms.SG1000.Settings,
  RM.Platforms.Presentation, RM.Platforms.SG1000.Icons, RM.Gamepad.Factory,
  RM.Platforms.SG1000.Gamepads, System.UITypes, RM.Input.Runtime,
  RM.Keyboard.Input, RM.Session.Runtime, RM.Keyboard.Session, RM.Window.Layout,
  RM.Keyboard.Window, RM.Settings.Runtime, RM.Keyboard.Settings,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

class function TSG1000Platform.Match(Context: TCoreLoadContext; const SystemId: string; const Encoding: string): TCoreMatch;
begin
  Result := ImageMatch(Context, SystemId,
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      if SystemId = 'sf7000' then
        Result := TSGCoreAdapter.Create(Input, Context.Storage, Context.RomName, True, Ord(TSGModel.SF7000))
      else if SystemId = 'omv' then
        Result := TSGCoreAdapter.Create(Input, Context.Storage, Context.RomName, False, Ord(TSGModel.Multivision))
      else
        Result := TSGCoreAdapter.Create(Input, Context.Storage, Context.RomName, SystemId = 'sc3000');
    end, True, SystemId, Encoding);
end;

class function TSG1000Platform.ExtensionHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var SystemId := '';
  var Encoding := Context.HeaderFormat.Encoding;
  if Context.HasExtension(['.sg']) or
    (not Context.HeaderRecognized and (Length(Context.Data) <= $C000) and
    Context.HasExtension(['.sms']) and (Context.SourceName.Contains('(SG-1000)') or
    SameText(ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(Context.SourceName))), 'sg1000'))) then
  begin
    SystemId := 'sg1000';
    Encoding := '';
  end
  else if Context.HasExtension(['.sc']) then
  begin
    SystemId := 'sc3000';
    Encoding := '';
  end
  else if Context.HasExtension(['.sf7', '.sf', '.dsk']) then
    SystemId := 'sf7000'
  else if Context.HasExtension(['.mv']) then
    SystemId := 'omv';
  if SystemId <> '' then
    Result := Match(Context, SystemId, Encoding);
end;

class function TSG1000Platform.Disk(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.HasExtension(['.dsk']) then
    Exit;
  var Bytes := Context.Data;
  var CPC := (Length(Bytes) >= 256) and
    (Context.Signature(0, 'EXTENDED CPC DSK File') or Context.Signature(0, 'MV - CPCEMU Disk-File'));
  var Folder := Context.RomName.ToLower.Replace('\', '/');
  if ((Length(Bytes) = 163840) and not CPC) or
    ((Length(Bytes) >= 512) and CPC and (Bytes[$30] = 40) and (Bytes[$31] = 1) and
    (Bytes[256 + $14] = 1) and (Bytes[256 + $15] = 16)) or
    Folder.Contains('/sf7000/') or Folder.Contains('/sg1000/') or
    Folder.Contains('(sf-7000)') or Folder.Contains('initial program loader') then
  begin
    // Only claim Sega DSKs here; generic +3 DSKs reach the ZX provider.
    var Format := RecognizeEmulationCore(Context, TCoreLoadStage.Header);
    try
      var Encoding := '';
      if Format <> nil then
        Encoding := Format.Format.Encoding;
      Result := Match(Context, 'sf7000', Encoding);
    finally
      Format.Free;
    end;
  end;
end;

class procedure TSG1000Platform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('sg1000', 'SG-1000', 'SG-1000',
    'Sega', 'SG1000 SG-1000 II SK-1100', 'sg1000', ['sg1000'],
    ['.sg', '.sms', '.zip', '.7z'],
    'SG1000', 'sg1000', 2);
  TPlatformRegistry.RegisterPlatform('sc3000', 'SC-3000', 'SC-3000',
    'Sega', 'SC3000 SC-3000H', 'sc3000', ['sc3000', 'sg1000'],
    ['.sc', '.zip', '.7z'],
    'SC3000', 'sc3000', 2);
  TPlatformRegistry.RegisterPlatform('sf7000', 'SF-7000', 'SF-7000',
    'Sega', 'SF7000 floppy', 'sf7000', ['sf7000', 'sg1000'],
    ['.sf7', '.sf', '.dsk', '.zip', '.7z'],
    'SF7000', 'sf7000', 2);
  TPlatformRegistry.RegisterPlatform('omv', 'Multivision', 'Multivision',
    'Tsukuda Original', 'OMV Othello Multivision', 'omv', ['omv', 'sg1000'],
    ['.mv', '.zip', '.7z'],
    'Multivision', 'omv', 2);
end;

class procedure TSG1000Platform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('SG1000', ['.sg', '.sc', '.sf7', '.sf', '.dsk', '.mv', '.sms']);
  Registration.Add(TCoreLoadStage.Image, 25, Disk);
  Registration.Add(TCoreLoadStage.OverrideHint, 10, ExtensionHint);
  Registration.ExtraArchiveCandidate :=
    function(Context: TCoreLoadContext; const Name: string; Size: UInt64): Boolean
    begin
      Result := SameText(ExtractFileExt(Name), '.bin') and (Size = $2000) and Name.ToLower.Contains('initial program loader');
    end;
  Registration.ArchiveImageName :=
    function(const Name: string): string
    begin
      Result := Name;
      if Name.ToLower.Contains('initial program loader') then
        Result := ChangeFileExt(Name, '.sf7');
    end;
  RegisterEmulationCore(Registration);
end;

class procedure TSG1000Platform.RegisterServices;
begin
  RegisterSnapshotPolicy('SG1000', TSnapshotPolicy.Create(3));
  RegisterSnapshotPolicy('SC3000', TSnapshotPolicy.Create(3));
  RegisterSnapshotPolicy('SF7000', TSnapshotPolicy.Create(2));
  RegisterSnapshotPolicy('OMV', TSnapshotPolicy.Create(2));
end;

class procedure TSG1000Platform.RegisterRuntimeServices;
begin
  var Service := Default(TPlatformServices);
  Service.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    var
      Keyboard: IEmulationKeyboard;
    begin
      Result := Default(TTerminalInputPolicy);
      Result.ExitKey := $1B;
      Result.AllKeys := Supports(Core, IEmulationKeyboard, Keyboard) and Keyboard.HasKeyboard;
      if Result.AllKeys then
        Result.ExitKey := $7B;
    end;
  RegisterPlatformServices('sg1000', Service);
  RegisterPlatformServices('sc3000', Service);
  RegisterPlatformServices('sf7000', Service);
  RegisterPlatformServices('omv', Service);
end;

class procedure TSG1000Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
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

class procedure TSG1000Platform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start]);
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('sg1000', Definition);
  Definition.LegacyButtons := [];
  RegisterPlatformInput('sc3000', Definition);
  Definition.LegacyButtons := Definition.Buttons;
  RegisterPlatformInput('sf7000', Definition);
  RegisterPlatformInput('omv', Definition);
end;

class procedure TSG1000Platform.RegisterClient;
begin
  RegisterSettingsProfile('SG1000', TSG1000Settings);
  RegisterSettingsProfile('SC3000', TSC3000Settings);
  RegisterSettingsProfile('SF7000', TSF7000Settings);
  RegisterSettingsProfile('Multivision', TMultivisionSettings);
  RegisterPlatformKeyboard('sg1000', TSGKeyboard);
  RegisterPlatformKeyboard('sc3000', TSGKeyboard);
  RegisterPlatformKeyboard('sf7000', TSGKeyboard);
  RegisterPlatformKeyboard('omv', TSGKeyboard);
  RegisterPlatformSettingsDevices('sg1000', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('sc3000', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('sf7000', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('omv', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('sg1000', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('sc3000', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('sf7000', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('omv', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('sg1000', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('sc3000', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('sf7000', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('omv', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('sg1000', TKeyboardSettingsHandler);
  RegisterPlatformSettingsHandler('sc3000', TKeyboardSettingsHandler);
  RegisterPlatformSettingsHandler('sf7000', TKeyboardSettingsHandler);
  RegisterPlatformSettingsHandler('omv', TKeyboardSettingsHandler);
  RegisterPlatformWindowLayout('sg1000', TKeyboardWindowLayout);
  RegisterPlatformWindowLayout('sc3000', TKeyboardWindowLayout);
  RegisterPlatformWindowLayout('sf7000', TKeyboardWindowLayout);
  RegisterPlatformWindowLayout('omv', TKeyboardWindowLayout);
  RegisterPlatformSessionHandler('sg1000', TKeyboardSessionHandler);
  RegisterPlatformSessionHandler('sc3000', TKeyboardSessionHandler);
  RegisterPlatformSessionHandler('sf7000', TKeyboardSessionHandler);
  RegisterPlatformSessionHandler('omv', TKeyboardSessionHandler);
  RegisterPlatformInputHandler('sg1000', TKeyboardInputHandler);
  RegisterPlatformInputHandler('sc3000', TKeyboardInputHandler);
  RegisterPlatformInputHandler('sf7000', TKeyboardInputHandler);
  RegisterPlatformInputHandler('omv', TKeyboardInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('sg1000', TGamepadSG1000Standart, []);
  RegisterPlatformGamepads('sc3000', TGamepadSC3000Standart, []);
  RegisterPlatformGamepads('sf7000', TGamepadSF7000Standart, []);
  RegisterPlatformGamepads('omv', TGamepadMultivisionStandart, []);
  RegisterPlatformPresentation('sg1000', 'sg1000', PlatformIconSG1000);
  RegisterPlatformPresentation('sc3000', 'sc3000', PlatformIconSC3000);
  RegisterPlatformPresentation('sf7000', 'sf7000', PlatformIconSF7000);
  RegisterPlatformPresentation('omv', 'omv', PlatformIconOMV);
end;

class procedure TSG1000Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterRuntimeServices;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

