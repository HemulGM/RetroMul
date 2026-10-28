unit RM.Platforms.MSX;

interface

uses
  Core.Input.Keyboard, Core.EmulatorRegistry, MSX.Machine, RM.Input,
  System.SysUtils;

type
  TMSXPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function ModelHint(Context: TCoreLoadContext): Integer; static;
    class function Match(Context: TCoreLoadContext; Model: TMSXModel; Media: TMSXMediaKind): TCoreMatch; static;
    class function Image(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure RegisterTerminalInput; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, RM.Platforms.MSX.Keyboard, Core.PlatformServices,
  Core.Snapshots, System.StrUtils, Core.Emulation, Core.Platforms,
  Core.Platforms.MSX.Adapter, MSX.Cartridge,
  RM.Platforms.MSX.Settings, RM.Platforms.Presentation,
  RM.Platforms.SG1000.Icons, RM.Gamepad.Factory, RM.Platforms.SG1000.Gamepads,
  System.UITypes, RM.Input.Runtime, RM.Keyboard.Input, RM.Session.Runtime,
  RM.Keyboard.Session, RM.Window.Layout, RM.Keyboard.Window, RM.Settings.Runtime,
  RM.Keyboard.Settings, RM.ControlsHelp.Content, RM.Settings.Callouts,
  RM.Settings.Devices, System.Classes;

class function TMSXPlatform.ModelHint(Context: TCoreLoadContext): Integer;
begin
  Result := -1;
  var Folder := Context.RomName.ToLower.Replace('\', '/');
  if Folder.Contains('/msx1/') or Folder.Contains('/msx/') then
    Result := Ord(MSX1);
  if Folder.Contains('/msx2/') then
    Result := Ord(MSX2);
  if Folder.Contains('/msx2plus/') or Folder.Contains('/msx2+/') then
    Result := Ord(MSX2Plus);
end;

class function TMSXPlatform.Match(Context: TCoreLoadContext; Model: TMSXModel; Media: TMSXMediaKind): TCoreMatch;
begin
  Result := ImageMatch(Context, 'MSX',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TMSXCoreAdapter.Create(Data, Model, Context.Storage, Context.RomName, Media);
    end);
end;

class function TMSXPlatform.Image(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := ModelHint(Context);
  var Bytes := Context.Data;
  if Context.HasExtension(['.mx1']) and (Hint < 0) then
    Hint := Ord(MSX1);
  if Context.HasExtension(['.mx2']) and (Hint < 0) then
    Hint := Ord(MSX2);
  if Context.HasExtension(['.mxp']) then
    Hint := Ord(MSX2Plus);
  if Context.HasExtension(['.cas']) then
  begin
    if Hint < 0 then
      Hint := Ord(MSX1);
    Exit(Match(Context, TMSXModel(Hint), CASMedia));
  end;
  if (Hint >= 0) and Context.HasExtension(['.wav']) then
    Exit(Match(Context, TMSXModel(Hint), WAVMedia));
  var Disk := Context.HasExtension(['.dsk']) and (Hint >= 0);
  if Context.HasExtension(['.dsk']) and (Hint < 0) and
    (Length(Bytes) >= 320 * 1024) and (Length(Bytes) <= 86 * 2 * 9 * 512) and
    (Bytes[0] in [$EB, $E9]) and (Bytes[11] = 0) and (Bytes[12] = 2) and
    (Bytes[24] in [8, 9]) and (Bytes[25] = 0) and (Bytes[26] in [1, 2]) and (Bytes[27] = 0) and
    (Length(Bytes) mod (512 * Bytes[24] * Bytes[26]) = 0) then
  begin
    Disk := True;
    Hint := Ord(MSX2);
  end;
  if Disk then
    Exit(Match(Context, TMSXModel(Hint), DiskMedia));
  if (Hint >= 0) and (TMSXCartridge.Recognizes(Bytes) or Context.HasExtension(['.rom', '.mx1', '.mx2', '.mxp'])) then
    Result := Match(Context, TMSXModel(Hint), CartridgeMedia);
end;

class function TMSXPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if (Length(Bytes) >= $2000) and (Length(Bytes) <= $800000) and
    (Context.Signature(0, 'AB') or ((Length(Bytes) >= $4010) and Context.Signature($4000, 'AB'))) then
  begin
    Result := Match(Context, MSX1, CartridgeMedia);
    Result.Format.SystemId := 'msx1';
  end;
end;

class procedure TMSXPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('msx1', 'MSX1', 'MSX1',
    'ASCII / Microsoft', 'MSX TMS9918 AY Z80', 'msx1', ['msx1', 'msx'],
    ['.rom', '.mx1', '.dsk', '.cas', '.wav', '.zip', '.7z', '.7z'],
    'MSX', 'msx1', 2);
  TPlatformRegistry.RegisterPlatform('msx2', 'MSX2', 'MSX2',
    'ASCII / Microsoft', 'MSX V9938', 'msx2', ['msx2'],
    ['.rom', '.mx2', '.dsk', '.cas', '.wav', '.zip', '.7z', '.7z'],
    'MSX', 'msx2', 2);
  TPlatformRegistry.RegisterPlatform('msx2plus', 'MSX2+', 'MSX2+',
    'ASCII', 'MSX2+ V9958 YJK MSX MUSIC', 'msx2plus', ['msx2plus', 'msx2+'],
    ['.rom', '.mx2', '.mxp', '.dsk', '.cas', '.wav', '.zip', '.7z', '.7z'],
    'MSX', 'msx2plus', 2);
end;

class procedure TMSXPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('MSX', ['.mx1', '.mx2', '.mxp', '.cas', '.dsk']);
  Registration.Add(TCoreLoadStage.Image, 10, Image);
  Registration.Add(TCoreLoadStage.Header, 130, Header);
  Registration.ExtraArchiveCandidate :=
    function(Context: TCoreLoadContext; const Name: string; Size: UInt64): Boolean
    begin
      Result := (ModelHint(Context) >= 0) and MatchText(ExtractFileExt(Name), ['.rom', '.wav']);
    end;
  Registration.AllowArchiveVariants :=
    function(Context: TCoreLoadContext): Boolean
    begin
      Result := ModelHint(Context) >= 0;
    end;
  RegisterEmulationCore(Registration);
end;

class procedure TMSXPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('MSX1', TSnapshotPolicy.Create(16));
  RegisterSnapshotPolicy('MSX2', TSnapshotPolicy.Create(16));
  RegisterSnapshotPolicy('MSX2PLUS', TSnapshotPolicy.Create(16));
end;

class procedure TMSXPlatform.RegisterTerminalInput;
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
  RegisterPlatformServices('msx1', Service);
  RegisterPlatformServices('msx2', Service);
  RegisterPlatformServices('msx2plus', Service);
end;

class procedure TMSXPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
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

class procedure TMSXPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.PadDevicesOnly := False;
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Controls';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('msx1', Definition);
  RegisterPlatformInput('msx2', Definition);
  RegisterPlatformInput('msx2plus', Definition);
end;

class procedure TMSXPlatform.RegisterClient;
begin
  RegisterSettingsProfile('MSX', TMSXSettings);
  RegisterPlatformKeyboard('msx1', TMSXKeyboard);
  RegisterPlatformKeyboard('msx2', TMSXKeyboard);
  RegisterPlatformKeyboard('msx2plus', TMSXKeyboard);
  RegisterPlatformSettingsDevices('msx1', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('msx2', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('msx2plus', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('msx1', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('msx2', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('msx2plus', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('msx1', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('msx2', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('msx2plus', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('msx1', TKeyboardSettingsHandler);
  RegisterPlatformSettingsHandler('msx2', TKeyboardSettingsHandler);
  RegisterPlatformSettingsHandler('msx2plus', TKeyboardSettingsHandler);
  RegisterPlatformWindowLayout('msx1', TKeyboardWindowLayout);
  RegisterPlatformWindowLayout('msx2', TKeyboardWindowLayout);
  RegisterPlatformWindowLayout('msx2plus', TKeyboardWindowLayout);
  RegisterPlatformSessionHandler('msx1', TKeyboardSessionHandler);
  RegisterPlatformSessionHandler('msx2', TKeyboardSessionHandler);
  RegisterPlatformSessionHandler('msx2plus', TKeyboardSessionHandler);
  RegisterPlatformInputHandler('msx1', TKeyboardInputHandler);
  RegisterPlatformInputHandler('msx2', TKeyboardInputHandler);
  RegisterPlatformInputHandler('msx2plus', TKeyboardInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('msx1', TGamepadSC3000Standart, []);
  RegisterPlatformGamepads('msx2', TGamepadSC3000Standart, []);
  RegisterPlatformGamepads('msx2plus', TGamepadSC3000Standart, []);
  RegisterPlatformPresentation('msx1', 'msx1', PlatformIconSC3000);
  RegisterPlatformPresentation('msx2', 'msx2', PlatformIconSC3000);
  RegisterPlatformPresentation('msx2plus', 'msx2plus', PlatformIconSC3000);
end;

class procedure TMSXPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterTerminalInput;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

