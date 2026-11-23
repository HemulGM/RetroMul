unit RM.Platforms.Atari8;

interface

type
  TA8Platform = class
  strict private
    class var
      FRegistered: Boolean;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.Classes, System.SysUtils, System.UITypes, System.StrUtils,
  System.IniFiles, System.Types, FMX.Types, FMXInput, Core.Emulation,
  Core.EmulatorRegistry, Core.Platforms, Core.Snapshots, Core.Input.Keyboard,
  Core.PlatformServices, Core.Platforms.Atari8.Adapter, A8.Media, A8.Machine,
  RM.Input, RM.Input.Gamepads, RM.Input.Runtime, RM.Gamepad.Base,
  RM.Gamepad.Factory, RM.VirtualController, RM.Keyboard, RM.Keyboard.Input,
  RM.Keyboard.Settings, RM.Keyboard.Session, RM.Keyboard.Window,
  RM.Platforms.Presentation, RM.Settings.Builder, RM.Settings.Catalog,
  RM.Settings.Platform, RM.Settings.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Callouts, RM.Settings.Devices,
  RM.ControlsHelp.Content, RM.Platforms.SG1000.Icons;

const
  MediaExtensions: array[0..9] of string = ('.car', '.rom', '.bin', '.atr', '.xfd', '.xex', '.com', '.bas', '.atx', '.cas');
  ScanFolders: array[0..4] of string = ('atari800', 'atari8', 'atari-8bit', 'atari400', 'atarixe');

type
  TA8Settings = class(TSettingsPlatform)
  public
    procedure Configuration(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    function HasConfiguration: Boolean; override;
    function ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean; override;
    function PeripheralPortCount(Draft: TMemIniFile): Integer; override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

  TA8Keyboard = class(TScreenKeyboard)
  protected
    function RowCount: Integer; override;
    procedure BuildLayout; override;
    function KeyCaption(const Caption: string): string; override;
  end;

  TA8InputHandler = class(TKeyboardInputHandler)
  public
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
  end;

  TA8Gamepad = class(TPlatformGamepad)
  protected
    FStart, FSelect, FOption, FFire, FSecondFire: TVirtualElement;
    procedure BuildLayout; override;
    procedure BuildDirectionControl; virtual;
  public
    procedure ApplyLanguage; override;
  end;

  TA8Paddles = class(TA8Gamepad)
  protected
    procedure BuildDirectionControl; override;
  public
    procedure ApplyLanguage; override;
  end;

  TA8ControlsHelp = class(TPlatformControlsHelp)
  public
    class function StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean; override;
    class function Shortcuts(const Context: TControlsHelpContext): TArray<TControlsHelpShortcut>; override;
  end;

procedure TA8Settings.Configuration(Context: TSettingsPageBuilder);
begin
  var Names, Values: TArray<string>;
  for var Model := Low(TA8Model) to High(TA8Model) do
  begin
    Names := Names + [Atari8ModelNames[Model]];
    Values := Values + [IntToStr(Ord(Model))];
  end;
  Context.Heading('GroupAtari8Machine', 'Atari computer');
  Context.AddChoice('ChoiceAtari8Model', 'Model', 'Reopen the game to switch models.',
    'Machine', 'Model', SettingChoices(Names, Values), '3', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('ChoiceAtari8TV', 'Video standard', 'Set Atari video timing. Reopen the game to apply.',
    'Machine', 'PAL', SettingChoices(['NTSC (60 Hz)', 'PAL (50 Hz)'], ['0', '1']), '0', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddBoolean('ToggleAtari8Basic', 'Built-in BASIC', 'Enable BASIC at startup on models with a built-in ROM.',
    'Machine', 'Basic', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.Heading('GroupAtari8Firmware', 'Firmware');
  Context.AddPath('PathAtari8LegacyOS', 'Atari 400/800 OS ROM',
    'Optional 10 KiB firmware image. Leave empty to use Altirra OS.',
    'Firmware', 'LegacyOS', '', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddPath('PathAtari8XLOS', 'Atari XL/XE OS ROM',
    'Optional 16 KiB firmware image. Recognized 800XL loaders can find a local Atari OS rev 2 automatically. Other software uses Altirra OS when left empty.',
    'Firmware', 'XLOS', '', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddPath('PathAtari8Basic', 'Atari BASIC ROM',
    'Optional 8 KiB interpreter image. Leave empty to use Altirra BASIC.',
    'Firmware', 'Basic', '', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddPath('PathAtari8XEGSGame', 'XEGS game ROM',
    'Optional 8 KiB game firmware for the XEGS model.',
    'Firmware', 'Game', '', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.Heading('GroupAtari8Cartridge', 'Cartridge');
  Context.AddChoice('ChoiceAtari8Mapper', 'Cartridge type',
    'Select the mapper for a raw ROM. CART headers take precedence.',
    'Cartridge', 'Mapper', SettingChoices(['Automatic', 'Standard 8 KiB', 'Standard 16 KiB',
        'OSS 034M', 'OSS 043M', 'OSS one chip', 'Bounty Bob 40 KiB', 'XEGS 32 KiB',
        'XEGS 64 KiB (0–7)', 'XEGS 64 KiB (8–15)', 'XEGS 128 KiB', 'Atarimax 128 KiB'],
      ['0', '1', '2', '3', '45', '15', '18', '12', '13', '67', '14', '41']), '0', True)
    .ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.Heading('GroupAtari8Disk', 'Disk drive');
  Context.AddBoolean('ToggleAtari8DiskReadSound', 'Disk read sound',
    'Play the Atari disk loading sound.',
    'Media', 'DiskReadSound', True, True);
  Context.AddBoolean('ToggleAtari8DiskProtection', 'Write protect disk',
    'Prevent new disk writes. Reopen the game to apply.',
    'Media', 'DiskWriteProtected', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

procedure TA8Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupAtari8Input', 'Atari input');
  Context.AddBoolean('ToggleAtari8Keyboard', 'Keyboard',
    'Send keyboard input to the Atari computer. On XEGS, turning this off disconnects the emulated keyboard.',
    'Ports', 'KeyboardEnabled', True, True);
end;

function TA8Settings.HasConfiguration: Boolean;
begin
  Result := True;
end;

function TA8Settings.ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean;
begin
  Result := SameText(Section, 'Machine') and SameText(Key, 'Model');
end;

function TA8Settings.PeripheralPortCount(Draft: TMemIniFile): Integer;
begin
  Result := PlayerCount(Draft);
end;

function TA8Settings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  var Model := Draft.ReadInteger('Machine', 'Model', Ord(TA8Model.Atari800XL));
  if Model in [Ord(TA8Model.Atari400), Ord(TA8Model.Atari800)] then
    Result := 4
  else
    Result := 2;
end;

function TA8Settings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result := inherited PortOptions(Port);
  Result.Description := 'A joystick, a pair of paddles (two knobs and two fire buttons), or no controller.';
  Result.Labels := ['Joystick', 'Paddles (pair)', 'None'];
  Result.Values := ['pad', 'pad-analog', 'none'];
end;

function TA8Keyboard.KeyCaption(const Caption: string): string;
begin
  Result := Translate(Caption);
end;

function TA8Keyboard.RowCount: Integer;
begin
  Result := 6;
end;

procedure TA8Keyboard.BuildLayout;
const
  Rows: array[0..3] of string = ('1234567890', 'QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM');
begin
  AddKey(vkEscape, 'Esc', 0, 0, 2);
  AddKey(vkF2, 'Start', 0, 2, 2.3);
  AddKey(vkF3, 'Select', 0, 4.3, 2.3);
  AddKey(vkF4, 'Option', 0, 6.6, 2.3);
  AddKey(vkF5, 'Reset', 0, 8.9, 2.3);
  AddKey(vkF6, 'Help', 0, 11.2, 2.3);
  AddKey(vkF7, 'Break', 0, 13.5, 2.5);
  for var Row := Low(Rows) to High(Rows) do
    for var Col := 1 to Length(Rows[Row]) do
      AddKey(Ord(Rows[Row][Col]), Rows[Row][Col], Row + 1, (Col - 1) * 1.2, 1.2);
  AddKey(vkMinus, '-', 1, 12, 1.2);
  AddKey(vkEqual, '=', 1, 13.2, 1.2);
  AddKey(vkBack, 'Del', 1, 14.4, 1.6);
  AddKey(vkLeftBracket, '[', 2, 12, 1.2);
  AddKey(vkRightBracket, ']', 2, 13.2, 1.2);
  AddKey(vkTab, 'Tab', 2, 14.4, 1.6);
  AddKey(vkSemicolon, ';', 3, 10.8, 1.2);
  AddKey(vkReturn, 'Return', 3, 12, 4);
  AddKey(vkComma, ',', 4, 8.4, 1.1);
  AddKey(vkPeriod, '.', 4, 9.5, 1.1);
  AddKey(vkSlash, '/', 4, 10.6, 1.1);
  AddKey(vkShift, 'Shift', 4, 11.7, 1.5, True);
  AddKey(vkControl, 'Ctrl', 4, 13.2, 1.3, True);
  AddKey(vkSpace, 'Space', 4, 14.5, 1.5);
  AddKey(vkLeft, '←', 5, 4.8, 1.6);
  AddKey(vkUp, '↑', 5, 6.4, 1.6);
  AddKey(vkDown, '↓', 5, 8, 1.6);
  AddKey(vkRight, '→', 5, 9.6, 1.6);
end;

class function TA8InputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited KeyPolicy(Context);
  if Result.KeyboardActive then
    Result.ControlKeys := [vkF2, vkF3, vkF4, vkF5, vkF6, vkF7];
end;

procedure TA8Gamepad.BuildLayout;
begin
  BuildDirectionControl;
  FStart := AddButton(TEmulatorButton.Start, '', TVirtualSide.Left, 16, 8, 88, 32, True);
  FSelect := AddButton(TEmulatorButton.Select, '', TVirtualSide.Left, 16, 46, 88, 32, True);
  FOption := AddButton(TEmulatorButton.Mode, '', TVirtualSide.Left, 16, 84, 88, 32, True);
  FFire := AddButton(TEmulatorButton.A, '', TVirtualSide.Right, 126, 219, 81, 64, True);
  ApplyLanguage;
end;

procedure TA8Gamepad.BuildDirectionControl;
begin
  AddPad;
end;

procedure TA8Gamepad.ApplyLanguage;
begin
  inherited;
  FStart.Caption := Translate('Start');
  FSelect.Caption := Translate('Select');
  FOption.Caption := Translate('Option');
  FFire.Caption := Translate('Fire');
end;

procedure TA8Paddles.BuildDirectionControl;
begin
  AddStick(RectF(28, 140, 172, 284));
  FSecondFire := AddButton(TEmulatorButton.B, '', TVirtualSide.Right, 30, 219, 81, 64, True);
end;

procedure TA8Paddles.ApplyLanguage;
begin
  inherited;
  FFire.Caption := Translate('Paddle 1');
  FSecondFire.Caption := Translate('Paddle 2');
end;

class function TA8ControlsHelp.StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean;
begin
  if Context.KeyboardPeripheral and MatchText(Id, ['save', 'load', 'screenshot', 'coin']) then
    Exit(False);
  Result := inherited StandardShortcutAvailable(Context, Id);
end;

class function TA8ControlsHelp.Shortcuts(const Context: TControlsHelpContext): TArray<TControlsHelpShortcut>;
begin
  Result := nil;
  if not Context.KeyboardPeripheral then
    Exit;
  Result := [
      TControlsHelpShortcut.Create('atari-start', 'Atari Start', 'F2'),
      TControlsHelpShortcut.Create('atari-select', 'Atari Select', 'F3'),
      TControlsHelpShortcut.Create('atari-option', 'Atari Option', 'F4'),
      TControlsHelpShortcut.Create('atari-reset', 'Atari System Reset', 'F5'),
      TControlsHelpShortcut.Create('atari-help', 'Atari Help', 'F6'),
      TControlsHelpShortcut.Create('atari-break', 'Atari Break', 'F7')];
end;

procedure LoadJoystickKeys(var Keys: TPlatformInputKeyMap);
begin
  Keys[0, TEmulatorButton.Up] := vkNumpad8;
  Keys[0, TEmulatorButton.Down] := vkNumpad2;
  Keys[0, TEmulatorButton.Left] := vkNumpad4;
  Keys[0, TEmulatorButton.Right] := vkNumpad6;
  Keys[0, TEmulatorButton.A] := vkNumpad0;
  Keys[0, TEmulatorButton.B] := vkNumpad1;
end;

procedure LoadGamepad(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  if Port = 0 then
  begin
    AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
    AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
    AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Mode), TGamepadButton.RightShoulder);
  end;
end;

function MatchesFolder(const Value: string): Boolean;
begin
  var Path := '/' + Value.ToLower.Replace('\', '/');
  for var Folder in ScanFolders do
    if Path.Contains('/' + Folder + '/') then
      Exit(True);
  Result := False;
end;

function RecognizeAtari8(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Confidence := TCoreMatchConfidence.Signature;
  var Extension := ExtractFileExt(Context.SourceName).ToLower;
  var Header := Context.Prefix(16);
  if (Length(Header) = 16) and (Header[0] = $96) and (Header[1] = $02) and
    (Header[4] in [0, $80]) and (Header[5] in [0, 1]) then
    Extension := '.atr'
  else if (Length(Header) = 16) and (Header[0] = Ord('A')) and (Header[1] = Ord('T')) and
    (Header[2] = Ord('8')) and (Header[3] = Ord('X')) then
    Extension := '.atx'
  else if (Length(Header) >= 8) and (Header[0] = Ord('F')) and (Header[1] = Ord('U')) and
    (Header[2] = Ord('J')) and (Header[3] = Ord('I')) then
    Extension := '.cas'
  else if (Length(Header) = 16) and (Header[0] = Ord('C')) and (Header[1] = Ord('A')) and
    (Header[2] = Ord('R')) and (Header[3] = Ord('T')) then
  begin
    if (Header[4] <> 0) or (Header[5] <> 0) or (Header[6] <> 0) or
      not A8ComputerCartType(Header[7]) then
      Exit;
    Extension := '.car';
  end
  else if MatchText(Extension, ['.xex', '.com']) and (Length(Header) >= 6) and (Header[0] = $FF) and (Header[1] = $FF) then
    Confidence := TCoreMatchConfidence.Signature
  else
  begin
    var Hint := SameText(Context.SelectedPlatform, Atari8SystemId) or
      MatchesFolder(Context.RomName) or MatchesFolder(Context.SourceName);
    if (Extension <> '.xfd') and not (Hint and MatchText(Extension, MediaExtensions)) then
      Exit;
    Confidence := TCoreMatchConfidence.Hint;
  end;
  Result := ImageMatch(Context, Atari8CoreId,
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      try
        Result := TA8CoreAdapter.Create(Data, Context.Storage, Context.RomName, Extension);
      except
        on E: EReadError do
        begin
          if (Confidence = TCoreMatchConfidence.Signature) and MatchText(Extension, ['.cas', '.atx']) then
            raise ECoreInvalidMedia.Create(E.Message);
          raise;
        end;
      end;
    end, False, Atari8SystemId, '', A8MediaLimit);
  Result.Confidence := Confidence;
end;

class procedure TA8Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform(Atari8SystemId, 'Atari 400/800/XL/XE', 'Atari 8-bit',
    'Atari', 'Atari 400 800 600XL 800XL 1200XL 65XE 130XE 800XE XEGS', 'atari800',
    ScanFolders, MediaExtensions, '', Atari8SystemId, 4);
  TPlatformRegistry.RegisterAlias('atari8', Atari8SystemId);
  TPlatformRegistry.RegisterAlias('atari-8bit', Atari8SystemId);
  TPlatformRegistry.RegisterAlias('atari400', Atari8SystemId);
  TPlatformRegistry.RegisterAlias('atarixe', Atari8SystemId);
  var Policy := TSnapshotPolicy.Create(4);
  Policy.AcceptedVersions := [1, 2, 3];
  RegisterSnapshotPolicy(Atari8CoreId, Policy);
  var Services := Default(TPlatformServices);
  Services.TerminalInput :=
    function(const Emulation: IEmulationCore): TTerminalInputPolicy
    var
      Keyboard: IEmulationKeyboard;
    begin
      Result := Default(TTerminalInputPolicy);
      Result.AllKeys := Supports(Emulation, IEmulationKeyboard, Keyboard) and Keyboard.HasKeyboard;
      if Result.AllKeys then
        Result.ExitKey := vkF12
      else
        Result.ExitKey := vkEscape;
    end;
  RegisterPlatformServices(Atari8SystemId, Services);
  var Core := TEmulationCoreRegistration.Create(Atari8CoreId, MediaExtensions);
  Core.Add(TCoreLoadStage.Image, 10, RecognizeAtari8);
  RegisterEmulationCore(Core);

  var Input := TPlatformInputDefinition.Create(Atari8Buttons);
  Input.Devices := [TInputDeviceVariant.Create('pad', Atari8Buttons - [TEmulatorButton.B]),
      TInputDeviceVariant.Create('pad-analog', Atari8Buttons)];
  Input.ButtonNames[TEmulatorButton.B] := 'Paddle 2 fire';
  Input.ButtonNames[TEmulatorButton.A] := 'Fire';
  Input.ButtonNames[TEmulatorButton.Mode] := 'Option';
  Input.LegacyPorts := 4;
  Input.LegacySection := 'Keys';
  Input.UseSharedBindingRules := True;
  Input.LoadLegacyKeys := LoadJoystickKeys;
  Input.LoadGamepadPreset := LoadGamepad;
  RegisterPlatformInput(Atari8SystemId, Input);

  RegisterPlatformPresentation(Atari8SystemId, Atari8SystemId, PlatformIconSC3000);
  RegisterSettingsPlatform(Atari8SystemId, TA8Settings,
    'Atari 8-bit software can come as a cartridge, disk image or executable. Choose the ' +
    'machine configuration and BASIC setting expected by the software. An optional interpreter ' +
    'ROM can replace the included Altirra BASIC.');
  RegisterPlatformSettingsDevices(Atari8SystemId, TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts(Atari8SystemId, TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp(Atari8SystemId, TA8ControlsHelp);
  RegisterPlatformKeyboard(Atari8SystemId, TA8Keyboard);
  RegisterPlatformSettingsHandler(Atari8SystemId, TKeyboardSettingsHandler);
  RegisterPlatformWindowLayout(Atari8SystemId, TKeyboardWindowLayout);
  RegisterPlatformSessionHandler(Atari8SystemId, TKeyboardSessionHandler);
  RegisterPlatformInputHandler(Atari8SystemId, TA8InputHandler);
  RegisterPlatformGamepads(Atari8SystemId, TA8Gamepad,
    [TGamepadDeviceVariant.Create('pad-analog', TA8Paddles)]);
  FRegistered := True;
end;

end.

