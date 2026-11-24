unit RM.Platforms.ZX;

interface

uses
  FMXInput, Core.Input.Keyboard, Core.EmulatorRegistry, RM.Input,
  System.SysUtils;

type
  TZXPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Image(Context: TCoreLoadContext): TCoreMatch; static;
    class function Preference(const OldName, NewName: string): Integer; static;
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
  RM.Input.Gamepads, RM.Settings.Catalog, RM.Platforms.ZX.Keyboard,
  Core.PlatformServices, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.ZX.Adapter, RM.Platforms.ZX.Settings,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Platforms.ZX.Gamepads,
  RM.Input.Runtime, RM.Keyboard.Input, RM.Platforms.ZX.Runtime,
  RM.Session.Runtime, RM.Keyboard.Session, RM.Window.Layout, RM.Keyboard.Window,
  RM.Settings.Runtime, RM.Keyboard.Settings, RM.ControlsHelp.Content,
  RM.Platforms.ZX.Help, RM.Settings.Callouts, RM.Settings.Devices,
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

class procedure TZXPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Mode), TGamepadButton.RightShoulder);
end;

class function TZXPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.mmc', '.ide']) then
    Result := TCoreMatch.Create('ZX',
      function: IEmulationCore
      begin
        Result := TZXCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class function TZXPlatform.Image(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if IsZXImageName(Context.SourceName) then
    Result := ImageMatch(Context, 'ZX',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        var Owned := Data;
        Result := TZXCoreAdapter.CreateOwned(Owned, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class function TZXPlatform.Preference(const OldName, NewName: string): Integer;
begin
  Result := -1;
  if not IsZXImageName(OldName) or not IsZXImageName(NewName) then
    Exit;
  var OldDisk := MatchText(ExtractFileExt(OldName), ['.trd', '.scl', '.dsk']);
  var NewDisk := MatchText(ExtractFileExt(NewName), ['.trd', '.scl', '.dsk']);
  if OldDisk and not NewDisk then
    Exit(0);
  if NewDisk and not OldDisk then
    Exit(1);
  if SameText(ExtractFileExt(OldName), '.trd') and SameText(ExtractFileExt(NewName), '.scl') then
    Exit(0);
  if SameText(ExtractFileExt(NewName), '.trd') and SameText(ExtractFileExt(OldName), '.scl') then
    Exit(1);
end;

class procedure TZXPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('zx', 'ZX Spectrum', 'ZX',
    'Sinclair', 'ZX Spectrum 48K 128K +2 Pentagon 128K TR-DOS', 'zxspectrum', ['zxspectrum', 'zx', 'spectrum'],
    ['.sna', '.z80', '.tap', '.tzx', '.trd', '.scl', '.dsk', '.mmc', '.ide', '.dck', '.pro', '.kdi'],
    'ZXSpectrum', 'zx', 2);
end;

class procedure TZXPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('ZX', ['.sna', '.z80', '.tap', '.tzx', '.trd', '.scl', '.dsk', '.dck', '.mmc', '.ide', '.pro', '.kdi']);
  Registration.Add(TCoreLoadStage.Source, 110, Source);
  Registration.Add(TCoreLoadStage.Image, 30, Image);
  Registration.ArchivePreference := Preference;
  RegisterEmulationCore(Registration);
end;

class procedure TZXPlatform.RegisterServices;
begin
  var Policy := TSnapshotPolicy.Create(29);
  Policy.AcceptedVersions := [28];
  RegisterSnapshotPolicy('ZX', Policy);
end;

class procedure TZXPlatform.RegisterTerminalInput;
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
  RegisterPlatformServices('zx', Service);
end;

class procedure TZXPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TZXConfig.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TZXPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.Mode]);
  Definition.PadDevicesOnly := False;
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('none', []));
  Definition.ButtonNames[TEmulatorButton.A] := 'Fire';
  Definition.ButtonNames[TEmulatorButton.B] := 'Tape play/pause';
  Definition.ButtonNames[TEmulatorButton.Select] := '1';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Enter';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Tape rewind';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('zx', Definition);
end;

class procedure TZXPlatform.RegisterClient;
begin
  RegisterSettingsProfile('ZXSpectrum', TZXSettings,
    'Select a machine model or a configuration preset before opening media. Tapes use the ' +
    'selected machine. TRD and SCL use a compatible TR-DOS model, and .dsk opens on +3. Enable ' +
    'the emulated keyboard for typed commands or choose a joystick mode for games that support ' +
    'it.');
  RegisterPlatformKeyboard('zx', TZXKeyboard);
  RegisterPlatformSettingsDevices('zx', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('zx', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('zx', TZXControlsHelp);
  RegisterPlatformSettingsHandler('zx', TKeyboardSettingsHandler);
  RegisterPlatformWindowLayout('zx', TKeyboardWindowLayout);
  RegisterPlatformSessionHandler('zx', TZXSessionHandler);
  RegisterPlatformInputHandler('zx', TZXInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('zx', TGamepadZX, []);
  RegisterPlatformPresentation('zx', 'zx', PlatformIcon);
end;

class procedure TZXPlatform.RegisterPlatform;
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

