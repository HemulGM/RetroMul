unit RM.Platforms.MSX;

interface

uses
  FMXInput, Core.Input.Keyboard, Core.EmulatorRegistry, MSX.Machine, RM.Input,
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
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Input.Gamepads, RM.Settings.Catalog, RM.Platforms.MSX.Keyboard,
  Core.PlatformServices, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.MSX.Adapter, MSX.Cartridge,
  RM.Platforms.MSX.Settings, RM.Platforms.Presentation, RM.Gamepad.Factory,
  RM.Platforms.SG1000.Gamepads, System.UITypes, RM.Input.Runtime,
  RM.Keyboard.Input, RM.Session.Runtime, RM.Keyboard.Session, RM.Window.Layout,
  RM.Keyboard.Window, RM.Settings.Runtime, RM.Keyboard.Settings,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  PlatformIcon =
 'M80,17 C81.1054992675781,17 82,17.8945293426514 82,19 C82,22.3125 79.3125,25 76,25 L56,25 C53.7891006469727,25' +
    ' 52,26.7891006469727 52,29 C55.7266006469727,29 58.8593978881836,31.5508003234863 59.7461013793945,35 L78.0000' +
    '991821289,35 C84.6289978027344,35 90.0000991821289,40.3711013793945 90.0000991821289,47 L90.0000991821289,71 C' +
    '90.0000991821289,77.6288986206055 84.6289978027344,83 78.0000991821289,83 L22.0000991821289,83 C15.37119865417' +
    '48,83 10.0000991821289,77.6288986206055 10.0000991821289,71 L10.0000991821289,47 C10.0000991821289,40.37110137' +
    '93945 15.3711986541748,35 22.0000991821289,35 L40.2540969848633,35 C41.1408157348633,31.5508003234863 44.27359' +
    '77172852,29 48.0001983642578,29 C48.0001983642578,24.5820007324219 51.5821990966797,21 56.0001983642578,21 L76' +
    '.0001983642578,21 C77.1056976318359,21 78.0001983642578,20.1054706573486 78.0001983642578,19 C78.0001983642578' +
    ',17.8945293426514 78.8947296142578,17 80.0001983642578,17 Z M17.5,50 C17.5,47.2383003234863 19.7383003234863,4' +
    '5 22.5,45 C25.2616996765137,45 27.5,47.2383003234863 27.5,50 C27.5,52.7616996765137 25.2616996765137,55 22.5,5' +
    '5 C19.7383003234863,55 17.5,52.7616996765137 17.5,50 Z M31.5,50 C31.5,47.2383003234863 33.7383003234863,45 36.' +
    '5,45 C39.2616996765137,45 41.5,47.2383003234863 41.5,50 C41.5,52.7616996765137 39.2616996765137,55 36.5,55 C33' +
    '.7383003234863,55 31.5,52.7616996765137 31.5,50 Z M45.5,50 C45.5,47.2383003234863 47.7383003234863,45 50.5,45 ' +
    'C53.2616996765137,45 55.5,47.2383003234863 55.5,50 C55.5,52.7616996765137 53.2616996765137,55 50.5,55 C47.7383' +
    '003234863,55 45.5,52.7616996765137 45.5,50 Z M59.5,50 C59.5,47.2383003234863 61.7383003234863,45 64.5,45 L77.5' +
    ',45 C80.2617034912109,45 82.5,47.2383003234863 82.5,50 C82.5,52.7616996765137 80.2617034912109,55 77.5,55 L64.' +
    '5,55 C61.7383003234863,55 59.5,52.7616996765137 59.5,50 Z M17,67 C17,64.2382965087891 19.2383003234863,62 22,6' +
    '2 C24.7616996765137,62 27,64.2382965087891 27,67 C27,69.7617034912109 24.7616996765137,72 22,72 C19.2383003234' +
    '863,72 17,69.7617034912109 17,67 Z M30.5,67 C30.5,64.2382965087891 32.7383003234863,62 35.5,62 L64.5,62 C67.26' +
    '17034912109,62 69.5,64.2382965087891 69.5,67 C69.5,69.7617034912109 67.2617034912109,72 64.5,72 L35.5,72 C32.7' +
    '383003234863,72 30.5,69.7617034912109 30.5,67 Z M73,67 C73,64.2382965087891 75.2382965087891,62 78,62 C80.7617' +
    '034912109,62 83,64.2382965087891 83,67 C83,69.7617034912109 80.7617034912109,72 78,72 C75.2382965087891,72 73,' +
    '69.7617034912109 73,67 Z ';

class procedure TMSXPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
end;

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
  if Context.SelectedPlatform = 'msx1' then
    Model := MSX1;
  if Context.SelectedPlatform = 'msx2' then
    Model := MSX2;
  if Context.SelectedPlatform = 'msx2plus' then
    Model := MSX2Plus;
  Result := ImageMatch(Context, 'MSX',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TMSXCoreAdapter.Create(Data, Model, Context.Storage, Context.RomName, Media);
    end);
  case Model of
    MSX1:
      Result.Format.SystemId := 'msx1';
    MSX2:
      Result.Format.SystemId := 'msx2';
    MSX2Plus:
      Result.Format.SystemId := 'msx2plus';
  end;
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
  end;
end;

class procedure TMSXPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('msx1', 'MSX1', 'MSX1',
    'ASCII / Microsoft', 'MSX TMS9918 AY Z80', 'msx1', ['msx1', 'msx'],
    ['.rom', '.mx1', '.dsk', '.cas', '.wav'],
    'MSX', 'msx1', 2);
  TPlatformRegistry.RegisterPlatform('msx2', 'MSX2', 'MSX2',
    'ASCII / Microsoft', 'MSX V9938', 'msx2', ['msx2'],
    ['.rom', '.mx2', '.dsk', '.cas', '.wav'],
    'MSX', 'msx2', 2);
  TPlatformRegistry.RegisterPlatform('msx2plus', 'MSX2+', 'MSX2+',
    'ASCII', 'MSX2+ V9958 YJK MSX MUSIC', 'msx2plus', ['msx2plus', 'msx2+'],
    ['.rom', '.mx2', '.mxp', '.dsk', '.cas', '.wav'],
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
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('msx1', Definition);
  RegisterPlatformInput('msx2', Definition);
  RegisterPlatformInput('msx2plus', Definition);
end;

class procedure TMSXPlatform.RegisterClient;
begin
  RegisterSettingsProfile('MSX', TMSXSettings,
    'Choose the MSX generation required by the software. Disk and tape images use the original ' +
    'machine BIOS with BASIC automatically. For cartridges start with automatic mapper ' +
    'selection. Peripherals include keyboard input and optional devices in the second slot.');
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
  RegisterPlatformPresentation('msx1', 'msx1', PlatformIcon);
  RegisterPlatformPresentation('msx2', 'msx2', PlatformIcon);
  RegisterPlatformPresentation('msx2plus', 'msx2plus', PlatformIcon);
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

