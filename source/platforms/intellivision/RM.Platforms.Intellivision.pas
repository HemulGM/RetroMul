unit RM.Platforms.Intellivision;

interface

uses
  Core.EmulatorRegistry, FMXInput, RM.Input;

type
  TIntvPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function CreateMatch(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function ExtensionHint(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RA.Console, System.Classes, System.IniFiles, System.SysUtils, System.StrUtils,
  System.Types, System.UITypes, FMX.Types, Core.Emulation, Core.Emulation.Types,
  Core.Platforms, Core.PlatformServices, Core.Snapshots, Core.Storage,
  Core.Archive.Container, Core.CD.Disc, INTV.Cartridge, INTV.LuigiImage,
  INTV.PlayCable, Core.Platforms.Intellivision.Adapter, RM.Platforms.Atari2600,
  RM.Input.Gamepads, RM.Input.Runtime, RM.Gamepad, RM.Gamepad.Base,
  RM.Gamepad.Factory, RM.VirtualController, RM.Platforms.Presentation,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Platform,
  RM.Settings.Builder, RM.Settings.Catalog, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices;

const
  ConsolePath =
 'M6,11 H90 L98,26 V46 H6 Z M14,17 V36 H39 V17 Z M51,17 V36 H80 V17 Z ' +
    'M6,50 H98 V56 H6 Z M12,59 H40 V73 H12 Z M64,59 H92 V73 H64 Z ' +
    'M23,62 V70 H29 V62 Z M75,62 V70 H81 V62 Z';
  MaxMappingBytes = 64 * 1024;
  FirmwareNames: array[0..18] of string =
    ('exec.bin', 'grom.bin', 'miniexec.bin', 'minigrom.bin', 'ecs.bin',
    'ivoice.bin', 'sp0256-012.bin', '012.bin', 'kbd-master.bin', 'kbd-6502.bin', 'kbd-font.bin',
    'kbd-exec.bin', 'kbd-grom.bin', 'kbd-basic.bin', 'wbexec.bin', 'wbgrom.bin',
    'exec2.bin', 'ro-3-9506-010.ic6', 'searsexc.bin');
  KeypadOrder: array[0..11] of Byte = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 11);

type
  TIntvGamepad = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

  TIntvInputHandler = class(TPlatformInputHandler)
  public
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

  TIntvHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
  end;

  TIntvSettings = class(TSettingsPlatform)
  public
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PeripheralPortCount(Draft: TMemIniFile): Integer; override;
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

procedure TIntvGamepad.BuildLayout;
begin
  AddStick(RectF(40, 140, 184, 284));
  AddButton(TEmulatorButton.A, 'Top', TVirtualSide.Left, 28, 68, 52, 52);
  AddButton(TEmulatorButton.B, 'L', TVirtualSide.Left, 88, 68, 52, 52);
  AddButton(TEmulatorButton.C, 'R', TVirtualSide.Left, 148, 68, 52, 52);
  for var Index := 0 to High(KeypadOrder) do
  begin
    var Digit := KeypadOrder[Index];
    var Caption := IntToStr(Digit);
    if Digit = 10 then
      Caption := 'Clear'
    else if Digit = 11 then
      Caption := 'Enter';
    var X := 24 + (Index mod 3) * 64;
    var Y := 40 + (Index div 3) * 60;
    AddAuxiliaryButton(Digit, Caption, TVirtualSide.Right, RectF(X, Y, X + 56, Y + 52));
  end;
end;

class function TIntvInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited;
  Result.KeyboardActive := (Context.Host = nil) or Context.Host.Input.Ports.KeyboardEnabled;
  Result.ForwardWithManager := True;
  Result.AllowSnapshotsWithKeyboard := True;
end;

class procedure TIntvInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Keypad: IIntvKeypadInput;
  if (Context.Host = nil) or not Supports(Context.Host.Core, IIntvKeypadInput, Keypad) then
    Exit;
  var Mask: Word := 0;
  if Context.Gamepad <> nil then
    Mask := Context.Gamepad.AuxiliaryButtons and $FFF;
  Keypad.SetVirtualKeypad(Mask);
end;

class function TIntvHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited;
  Result.ControllerTitle := 'Intellivision';
  Result.Note := Translate('Player 1 keypad uses 0–9, Q (Clear), and Enter. Player 2 uses numpad 0–9, E (Clear), and R (Enter).');
end;

function TIntvSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  if SameText(Draft.ReadString('Hardware', 'ECSInput', 'Keyboard'), 'Controllers') and
    not SameText(Draft.ReadString('Hardware', 'ECS', 'Auto'), 'Off') then
    Result := 4;
end;

function TIntvSettings.PeripheralPortCount(Draft: TMemIniFile): Integer;
begin
  Result := PlayerCount(Draft);
end;

procedure TIntvSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.AddChoice('RowIntvRegion', 'NTSC / PAL',
    'Select the video standard and frame timing. Changing the region requires reopening the game.',
    'Video', 'Region', SettingChoices(['NTSC', 'PAL'], ['NTSC', 'PAL']),
    'NTSC').ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

procedure TIntvSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.AddChoice('RowIntvModel', 'Console model',
    'Intellivision II uses the extended EXEC, and Sears uses searsexc.bin. INTV88 adds STIC 1A and expanded memory. ' +
    'TutorVision also uses wbexec.bin and wbgrom.bin.',
    'Hardware', 'Model', SettingChoices(['Standard', 'Intellivision II', 'Sears Super Video Arcade', 'INTV88', 'TutorVision'],
      ['Standard', 'Intellivision II', 'Sears Super Video Arcade', 'INTV88', 'TutorVision']), 'Standard').ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowIntvECS', 'Entertainment Computer System',
    'The ECS adds memory, sound and input ports. Its firmware is built in.',
    'Hardware', 'ECS', SettingChoices(['Automatic', 'Enabled', 'Disabled'], ['Auto', 'On', 'Off']),
    'Auto').ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowIntvECSInput', 'ECS input device', 'Choose the device connected to the ECS input ports.',
    'Hardware', 'ECSInput', SettingChoices(['Keyboard', 'Two controllers', 'Piano'],
      ['Keyboard', 'Controllers', 'Piano']), 'Keyboard').ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowIntvVoice', 'Intellivoice',
    'The SP0256-012 speech firmware is built in.',
    'Hardware', 'Intellivoice', SettingChoices(['Automatic', 'Enabled', 'Disabled'], ['Auto', 'On', 'Off']),
    'Auto').ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowIntvKeyboardComponent', 'Keyboard Component',
    'Use the original Keyboard Component firmware with its own processor, keyboard and text display.',
    'Hardware', 'KeyboardComponent', SettingChoices(['Disabled', 'Enabled'], ['Off', 'On']),
    'Off').ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddPath('RowIntvKeyboardTape', 'Keyboard Component tape',
    'Optional digital tape image. Reopen the cartridge to insert it.',
    'Hardware', 'KeyboardTape', '', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddPath('RowIntvKeyboardTapeAudio', 'Keyboard Component tape audio',
    'Optional WAV recording synchronized with the digital tape image.',
    'Hardware', 'KeyboardTapeAudio', '', False, True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowIntvKeyboardMicrophone', 'Keyboard Component microphone',
    'Record onto cassette audio track B when the emulated drive selects audio recording.',
    'Hardware', 'KeyboardMicrophone', SettingChoices(['Disabled', 'Enabled'], ['0', '1']),
    '0', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddBoolean('RowIntvKeyboard', 'Physical keyboard',
    'Player 1 keypad uses 0–9, Q (Clear), and Enter. Player 2 uses numpad 0–9, E (Clear), and R (Enter).',
    'Ports', 'KeyboardEnabled', True, True);
end;

function ReadMapping(Context: TCoreLoadContext): string;
begin
  Result := '';
  var Input: TStream := nil;
  if Context.Stream is TArchiveImageStream then
  begin
    var Image := TArchiveImageStream(Context.Stream);
    var Entry := Image.Container.FindName(ChangeFileExt(Image.MemberName, '.cfg'));
    if Entry >= 0 then
    begin
      if Image.Container.Entries[Entry].Size > MaxMappingBytes then
        raise ECoreInvalidMedia.Create('Intellivision cartridge configuration is too large');
      Input := Image.Container.OpenRead(Entry);
    end;
  end
  else if Context.RomName <> '' then
  begin
    var Storage := Context.EffectiveStorage;
    var Name := ChangeFileExt(ExtractFileName(Context.SourceName), '.cfg');
    var Location := '';
    try
      Location := CDSibling(Storage, Context.RomName, Name);
    except
      on E: EReadError do
        Exit;
    end;
    Input := Storage.OpenRead(Location);
  end;
  if Input = nil then
    Exit;
  try
    if Input.Size > MaxMappingBytes then
      raise ECoreInvalidMedia.Create('Intellivision cartridge configuration is too large');
    var Bytes := ReadRomData(Input);
    var Encoding := TEncoding.UTF8;
    var Offset := TEncoding.GetBufferEncoding(Bytes, Encoding);
    Result := Encoding.GetString(Bytes, Offset, Length(Bytes) - Offset);
  finally
    Input.Free;
  end;
end;

class function TIntvPlatform.CreateMatch(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := ImageMatch(Context, IntvCoreId,
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      var Mapping := '';
      if Context.HasExtension(['.kiosk']) and not TIntvKiosk.IsImage(Data) then
        raise ECoreInvalidMedia.Create('Invalid Intellivision kiosk signature');
      if Context.HasExtension(['.luigi']) and not TLuigiImage.IsContainer(Data) then
        raise ECoreInvalidMedia.Create('Invalid LUIGI signature');
      if Context.HasExtension(['.playcable']) and not TIntvPlayCable.IsImage(Data) then
        raise ECoreInvalidMedia.Create('Invalid PlayCable signature');
      if not TIntvPlayCable.IsImage(Data) and not TIntvCartridge.HasContainerHeader(Data) then
        Mapping := ReadMapping(Context);
      Result := TIntvCoreAdapter.Create(Data, Context.EffectiveStorage, Context.RomName, Mapping);
    end, False, IntvPlatformId, '', IntvCartSizeLimit);
end;

class function TIntvPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.HasExtension(['.int', '.itv', '.rom', '.bin', '.cc3', '.luigi', '.playcable', '.kiosk']) then
    Exit;
  if (Context.Stream.Size <= IntvCartSizeLimit) and
    (TIntvPlayCable.IsImage(Context.Prefix(4)) or TIntvCartridge.HasContainerHeader(Context.Prefix(53))) then
    Result := CreateMatch(Context);
end;

class function TIntvPlatform.ExtensionHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if (Context.Stream.Size > IntvCartSizeLimit) or
    MatchText(ExtractFileName(Context.SourceName), FirmwareNames) then
    Exit;
  if Context.HasExtension(['.int', '.itv', '.cc3', '.luigi', '.playcable', '.kiosk']) then
    Exit(CreateMatch(Context));
  var Name := ('/' + Context.RomName + ' ' + Context.SourceName).ToLower.Replace('\', '/');
  if Context.HasExtension(['.rom', '.bin']) and ((Context.SelectedPlatform = IntvPlatformId) or
    Name.Contains('/intellivision/') or Name.Contains('/intv/')) and
    not TIntvCartridge.HasContainerHeader(Context.Prefix(53)) then
  begin
    Result := CreateMatch(Context);
    Result.Confidence := TCoreMatchConfidence.Hint;
  end;
end;

class procedure TIntvPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
begin
  var Defaults: TIntvKeyMap;
  TIntvConfig.DefaultKeys(Defaults);
  for var Port := 0 to 1 do
    for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[Port, Button] := Defaults[Port, Button];
end;

class procedure TIntvPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.LeftShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.North);
end;

class procedure TIntvPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform(IntvPlatformId, 'Intellivision', 'Intellivision', 'Mattel',
    'Mattel Intellivision INTV', IntvPlatformId, ['intellivision', 'intv'],
    ['.int', '.itv', '.rom', '.bin', '.cc3', '.luigi', '.playcable', '.kiosk'], 'Intellivision', IntvPlatformId, 4);
  TPlatformRegistry.RegisterAlias('intv', IntvPlatformId);
  TA2600Platform.RegisterSystemChanger;
  var SnapshotPolicy := TSnapshotPolicy.Create(8);
  SnapshotPolicy.AcceptedVersions := [1, 2, 3, 4, 5, 6, 7, 8];
  RegisterSnapshotPolicy(IntvCoreId, SnapshotPolicy);

  var Registration := TEmulationCoreRegistration.Create(IntvCoreId, ['.int', '.itv', '.rom', '.bin', '.cc3', '.luigi', '.playcable', '.kiosk']);
  Registration.MaxArchiveImageSize := IntvCartSizeLimit;
  Registration.Add(TCoreLoadStage.Header, 95, Header);
  Registration.Add(TCoreLoadStage.OverrideHint, 10, ExtensionHint);
  RegisterEmulationCore(Registration);

  var Service := Default(TPlatformServices);
  SetLength(Service.FirmwareFiles, Length(FirmwareNames));
  for var Index := 0 to High(FirmwareNames) do
    Service.FirmwareFiles[Index] := FirmwareNames[Index];
  Service.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result := Default(TTerminalInputPolicy);
      Result.AllKeys := True;
      Result.ExitKey := $1B;
    end;
  RegisterPlatformServices(IntvPlatformId, Service);

  RegisterSettingsProfile('Intellivision', TIntvSettings,
    'Standard, Intellivision II, Sears, TutorVision, ECS, Intellivoice and Keyboard Component firmware is built in. Optional firmware files override built-in images.');
  RegisterPlatformSettingsDevices(IntvPlatformId, TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts(IntvPlatformId, TPlatformDeviceCallouts);
  RegisterPlatformSettingsHandler(IntvPlatformId, TPlatformSettingsHandler);
  RegisterPlatformWindowLayout(IntvPlatformId, TPlatformWindowLayout);
  RegisterPlatformSessionHandler(IntvPlatformId, TPlatformSessionHandler);
  RegisterPlatformControlsHelp(IntvPlatformId, TIntvHelp);
  RegisterPlatformInputHandler(IntvPlatformId, TIntvInputHandler);
  RegisterPlatformGamepads(IntvPlatformId, TIntvGamepad, []);
  RegisterPlatformPresentation(IntvPlatformId, IntvPlatformId, ConsolePath);

  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.C, TEmulatorButton.Start, TEmulatorButton.Select, TEmulatorButton.X, TEmulatorButton.Y]);
  Definition.PadDevicesOnly := False;
  Definition.ButtonNames[TEmulatorButton.A] := 'Top';
  Definition.ButtonNames[TEmulatorButton.B] := 'Lower left';
  Definition.ButtonNames[TEmulatorButton.C] := 'Lower right';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Enter';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Clear';
  Definition.ButtonNames[TEmulatorButton.X] := '1';
  Definition.ButtonNames[TEmulatorButton.Y] := '2';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput(IntvPlatformId, Definition);
  FRegistered := True;
  RegisterPlatformAchievementMedia('intellivision', RAConsoleIntellivision, TPlatformRegistry.Require('intellivision').Extensions);
end;

end.

