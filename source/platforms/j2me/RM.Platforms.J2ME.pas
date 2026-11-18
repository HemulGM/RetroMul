unit RM.Platforms.J2ME;

{$I RM.Mobile.inc}

interface

uses
  RM.Platform.Host, Core.EmulatorRegistry, RM.Input, RM.Input.Runtime, FMXInput;

type
  TJ2MEPlatform = class
  private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

function J2MEKeypadAction(Key: Integer): Integer;

implementation

uses
  System.SysUtils, System.UITypes, System.IniFiles, System.Math, Core.Platforms,
  Core.Emulation, Core.Archive.Container, Core.Archive.Zip,
  Core.PlatformServices, RM.Input.Gamepads, Core.Platforms.J2ME.Adapter,
  J2ME.Device, J2ME.Suite, J2ME.Metadata, RM.Platforms.Presentation,
  RM.Platforms.CPS.Icons, RM.Settings.Catalog, RM.Settings.Platform,
  RM.Settings.Builder, RM.Settings.Devices, RM.Settings.Callouts,
  RM.Settings.Runtime, RM.ControlsHelp.Content, RM.Session.Runtime,
  RM.Window.Layout, RM.Gamepad.Factory, RM.Platforms.J2ME.Gamepads, RM.Gamepad,
  J2ME.Input, RM.Dialogs, FMX.Types, FMX.Controls, FMX.Objects;

type
  TJ2MEInputHandler = class(TPlatformInputHandler)
  public
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
    class function ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean; override;
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

  TJ2MESettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    procedure PrepareSave(Draft: TMemIniFile); override;
  end;

  TJ2MESettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
  end;

  TJ2MEDeviceCallouts = class(TPlatformDeviceCallouts)
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; override;
  end;

  IJ2MEKeypadOptions = interface
    ['{2603032D-5F9D-40B0-A992-0DDBB8D5B20B}']
    function IsShown: Boolean;
  end;

  TJ2MEKeypadOptions = class(TInterfacedObject, IJ2MEKeypadOptions)
  public
    Shown: Boolean;
    function IsShown: Boolean;
  end;

  TJ2MESessionHandler = class(TPlatformSessionHandler)
  public
    class procedure Connect(const Context: TSessionRuntimeContext); override;
    class procedure Disconnect(const Context: TSessionRuntimeContext); override;
    class procedure SyncActivity(const Context: TSessionRuntimeContext); override;
    class procedure FramePresented(const Context: TSessionRuntimeContext); override;
  end;

  TJ2MESettingsHandler = class(TPlatformSettingsHandler)
  public
    class procedure Apply(const Context: TSettingsRuntimeContext; Ini: TCustomIniFile); override;
  end;

  TJ2MEWindowLayout = class(TPlatformWindowLayout)
  public
    class procedure Arrange(const Context: TWindowLayoutContext); override;
  end;

  TJ2MEControlsHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
    class function StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean; override;
  end;

const
  J2MEKeypadActionBase = 2560;

function J2MEKeypadAction(Key: Integer): Integer;
begin
  // Keep the existing, assignable 0 action and its saved bindings.
  if Key = 0 then
    Result := PadAction(0, TEmulatorButton.B)
  else
    Result := J2MEKeypadActionBase + Key;
end;

function IsJ2MEKeypadAction(Action: Integer): Boolean;
begin
  Result := (Action > J2MEKeypadActionBase) and (Action <= J2MEKeypadActionBase + 11);
end;

procedure LoadJ2MEKeypadBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  for var Key := 1 to 9 do
  begin
    AddLegacyInputKey(Input, J2MEKeypadAction(Key), vk0 + Key);
    AddLegacyInputKey(Input, J2MEKeypadAction(Key), vkNumpad0 + Key);
  end;
  AddLegacyInputKey(Input, J2MEKeypadAction(10), vkF3);
  AddLegacyInputKey(Input, J2MEKeypadAction(10), vkMultiply);
  AddLegacyInputKey(Input, J2MEKeypadAction(11), vkF4);
  AddLegacyInputKey(Input, J2MEKeypadAction(11), vkDivide);
end;

procedure LoadJ2MELegacyBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  LoadJ2MEKeypadBindings(Input, Ini);
  AddLegacyInputKey(Input, J2MEKeypadAction(0), vkNumpad0);
  AddLegacyInputKey(Input, PadAction(0, TEmulatorButton.A), vkSpace);
end;

procedure MigrateJ2MEKeypadBindings(Input: TInputManager; Ini: TCustomIniFile);
begin
  if Ini.ReadInteger('FMXInput', 'J2MEKeypadVersion', 0) >= 1 then
    Exit;
  var HasKeypad := False;
  for var Binding in Input.Bindings do
    HasKeypad := HasKeypad or IsJ2MEKeypadAction(Binding.Action);
  // Older profiles received digits outside the binding manager. Mark the
  // draft immediately so switching pages cannot restore cleared assignments.
  if not HasKeypad and (Ini.ReadString('FMXInput', 'Bindings', '') <> '') then
    LoadJ2MEKeypadBindings(Input, Ini);
  Ini.WriteInteger('FMXInput', 'J2MEKeypadVersion', 1);
end;

procedure FilterJ2MEKeypadBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);
begin
  if not IsJ2MEKeypadAction(Binding.Action) then
    Exit;
  Policy.SourceKey := 'Source1';
  Policy.Enabled := not SameText(Ini.ReadString('Ports', 'Port1', 'auto'), 'none');
end;

function TJ2MEKeypadOptions.IsShown: Boolean;
begin
  Result := Shown;
end;

class procedure TJ2MEWindowLayout.Arrange(const Context: TWindowLayoutContext);
begin
  var Pad := Context.Gamepad;
  if (Pad = nil) or not Pad.Visible or (Pad.PlatformPad = nil) or not (Pad.Parent is TControl) then
  begin
    inherited;
    Exit;
  end;
  var Host := TControl(Pad.Parent);
  // A complete phone panel uses a separate area. Split controls overlay only
  // the sides; they keep the central game picture available in landscape.
  if Pad.PlatformPad.DesignWidth = Pad.PlatformPad.DesignSideSize.Width then
  begin
    Context.Host.Video.FitFrame;
    if Host.Width > Host.Height then
    begin
      Pad.Align := TAlignLayout.Right;
      Pad.Width := Min(280.0, Host.Width * 0.4);
    end
    else
    begin
      Pad.Align := TAlignLayout.Bottom;
      Pad.Height := TScreenGamepad.PreferredHeight(Host.Width, Host.Height);
    end;
    Pad.BringToFront;
  end
  else
    inherited;
end;

procedure ConfigureJ2MEKeypad(const Context: TInputRuntimeContext; Ini: TCustomIniFile);
begin
  var Options := TJ2MEKeypadOptions.Create;
  Options.Shown := Ini.ReadBool('Phone', 'ShowKeypad', True);
  Context.SetData('j2me.keypad.options', Options);
  var Pad := Context.Gamepad;
  if Pad = nil then
    Exit;
  var Layout := NormalizeJ2MEKeypadLayout(Ini.ReadString('Phone', 'KeypadLayout', 'arrows-numbers'));
  Pad.Configure('j2me', Layout, CoreButtons('j2me', 'auto'));
  Pad.PlatformPad.InkOpacity := EnsureRange(Ini.ReadInteger('Phone', 'KeypadOpacity', 85), 10, 100) / 100;
end;

class procedure TJ2MESessionHandler.Connect(const Context: TSessionRuntimeContext);
begin
  inherited;
  var Ini := Context.Host.Storage.ReadConfig(Context.Host.Core.Config.FileName);
  try
    ConfigureJ2MEKeypad(Context, Ini);
  finally
    Ini.Free;
  end;
end;

class procedure TJ2MESessionHandler.FramePresented(const Context: TSessionRuntimeContext);
begin
  inherited;
  if not Context.Host.Activity.CanShowGameNotice then
    Exit;
  var Advice: IJ2MEResolutionAdvice;
  var Current, Recommended: TJ2MEScreenSize;
  if Supports(Context.Host.Core, IJ2MEResolutionAdvice, Advice) and
    Advice.TakeResolutionAdvice(Current, Recommended) then
    Context.Host.ShowMessage(
      Format(Translate('The game repeatedly requests a %d × %d screen. The current size is %d × %d, so part of the image may be clipped.'),
        [Recommended.Width, Recommended.Height, Current.Width, Current.Height]) + sLineBreak + sLineBreak +
      Translate('Set this size in the Java ME platform video settings, then restart the game from the beginning.'),
      False);
end;

class procedure TJ2MESessionHandler.SyncActivity(const Context: TSessionRuntimeContext);
begin
  inherited;
  var Pad := Context.Gamepad;
  if Pad = nil then
    Exit;
  var Options := Context.Data('j2me.keypad.options') as IJ2MEKeypadOptions;
  var Activity := Context.Host.Activity;
  Pad.Visible := Pad.Visible and ((Options = nil) or Options.IsShown);
  Pad.Enabled := Pad.Enabled and Pad.Visible and Activity.VirtualControlsEnabled and
    not Activity.PeripheralInputBlocked;
  LayoutControls(Context);
end;

class procedure TJ2MESessionHandler.Disconnect(const Context: TSessionRuntimeContext);
begin
  if Context.Gamepad <> nil then
  begin
    Context.Gamepad.ReleaseAll;
    Context.Gamepad.Enabled := False;
    Context.Gamepad.Visible := False;
  end;
  var Phone: IJ2MEPhoneInput;
  if Supports(Context.Host.Core, IJ2MEPhoneInput, Phone) then
    Phone.SetVirtualKeypad(0);
  Context.SetData('j2me.keypad.options', nil);
  inherited;
end;

class procedure TJ2MESettingsHandler.Apply(const Context: TSettingsRuntimeContext; Ini: TCustomIniFile);
begin
  inherited;
  ConfigureJ2MEKeypad(Context, Ini);
end;

class procedure TJ2MEInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Phone: IJ2MEPhoneInput;
  if not Supports(Context.Host.Core, IJ2MEPhoneInput, Phone) then
    Exit;
  var Mask: Word := 0;
  var Pad := Context.Gamepad;
  if (Context.Host.Input.Ports.Devices[0] <> 'none') and
    not (Context.Host.Activity.Phase = TPlatformSessionPhase.Failed) and not Context.Host.Core.IsPaused then
  begin
    var Manager := Context.Host.Input;
    if Manager.HasInputSource then
      for var Key := 0 to 11 do
        if Manager.IsActionPressed(J2MEKeypadAction(Key)) then
          Mask := Mask or (Word(1) shl Key);
    if (Pad <> nil) and Pad.Visible and Pad.Enabled then
      Mask := Mask or (Pad.AuxiliaryButtons and J2MEKeypadMask);
  end;
  Phone.SetVirtualKeypad(Mask);
end;

class function TJ2MEInputHandler.ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean;
begin
  Result := False;
  var Manager := Context.Host.Input;
  if not Manager.HasInputSource then
    Exit;
  // Binding changes replace default keys rather than add a hard-coded route.
  // Other text/navigation keys still reach the MIDlet.
  if Code in [vk0..vk9, vkNumpad0..vkNumpad9, vkUp, vkDown, vkLeft, vkRight,
      vkReturn, vkSpace, vkF1..vkF4, vkMultiply, vkDivide] then
    Exit(True);
  var Hid := HostKeyToHid(Code);
  for var Binding in Manager.Bindings do
    if (Binding.Kind = TInputElementKind.Key) and (Binding.Code = Hid) and
      ((Binding.Action in [0..7]) or IsJ2MEKeypadAction(Binding.Action)) then
      Exit(True);
end;

class function TJ2MEControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited;
  Result.ControllerTitle := Translate('Phone keypad');
  Result.Note := Translate('L/R: soft keys. OK: Fire. Digits, * and # keep their phone key codes; arrows are separate keys.') + ' ' +
    Translate('Change bindings in the controls settings.');
end;

class function TJ2MEControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited;
  if (Context.Player <> 0) or (Length(Result) = 0) then
    Exit;
  for var Key := 1 to 11 do
    Result := Result + [TControlsHelpAssignment.Create(Char(J2MEKeypadCodes[Key]), J2MEKeypadAction(Key))];
end;

class function TJ2MESettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited;
  if (Context.Port <> 0) or (Length(Result) = 0) then
    Exit;
  for var Key := 1 to 11 do
    Result := Result + [TSettingsDeviceBinding.Create(J2MEKeypadAction(Key), Char(J2MEKeypadCodes[Key]))];
end;

class function TJ2MESettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := inherited;
  if (Context.Port <> 0) or not (Control is TScreenGamepad) then
    Exit;
  for var Key := 0 to 11 do
    if (TScreenGamepad(Control).AuxiliaryButtons and (Cardinal(1) shl Key)) <> 0 then
      Exit(TSettingsDeviceBinding.Create(J2MEKeypadAction(Key), Char(J2MEKeypadCodes[Key])));
end;

class function TJ2MEDeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := inherited;
  if (Context.Port <> 0) or not (Context.Device is TScreenGamepad) then
    Exit;
  for var Key := 0 to 11 do
    if not ButtonBounds(Context, -1 - Key).IsEmpty then
      Result := Result + [TDeviceCalloutDefinition.Create(-1 - Key, J2MEKeypadAction(Key),
        Char(J2MEKeypadCodes[Key]), Char(J2MEKeypadCodes[Key]), False)];
  for var I := 0 to High(Result) do
    Result[I].Left := ButtonBounds(Context, Result[I].Button).CenterPoint.X < Context.Device.Width / 2;
end;

procedure TJ2MESettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.WriteInteger('FMXInput', 'J2MEKeypadVersion', 1);
end;

class function TJ2MEControlsHelp.StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean;
begin
  Result := inherited;
  if Id = 'pause' then
    Result := False;
end;

procedure TJ2MESettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupJ2MEKeypad', 'Phone keypad');
  Context.AddBoolean('RowJ2MEShowKeypad', 'On-screen phone keypad',
    'Show phone buttons during emulation. Supports mouse and simultaneous touches.', 'Phone', 'ShowKeypad', True);
  Context.AddChoice('RowJ2MEKeypadLayout', 'Keypad layout',
    'Choose phone keys, arrows or both. The split layouts keep the centre clear.',
    'Phone', 'KeypadLayout', [
      SettingChoice('Arrows and numbers', 'arrows-numbers'),
      SettingChoice('Numbers and arrows', 'numbers-arrows'),
      SettingChoice('Phone', 'phone'),
      SettingChoice('Phone with arrows', 'phone-arrows'),
      SettingChoice('Numbers', 'numbers'),
      SettingChoice('Arrows', 'arrows')], 'arrows-numbers');
  var Opacity := Context.AddInteger('RowJ2MEKeypadOpacity', 'Keypad opacity (%)',
    'Button size and bottom offset use the general on-screen button settings.',
    'Phone', 'KeypadOpacity', 85, 100);
  Opacity.Min := 10;
end;

class function TJ2MEInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited;
  Result.KeyboardActive := True;
  Result.ForwardWithManager := True;
  Result.ReserveCaptureShortcuts := True;
  Result.ControlKeys := [vkF7, vkF8, vkF9, vkF10];
end;

procedure TJ2MESettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupJ2MEPhone', 'Java ME phone');
  var Sizes: TArray<TSettingsChoiceItem> := [SettingChoice('Automatic', 'auto'), SettingChoice('Custom width and height', 'custom')];
  for var Size in TJ2MEScreenSize.Presets do
    Sizes := Sizes + [SettingChoice(IntToStr(Size.Width) + ' × ' + IntToStr(Size.Height), Size.ToString)];
  var DefaultSize := 'auto';
  if (Context.Draft <> nil) and not Context.Draft.ValueExists('Phone', 'ScreenSize') and
    (Context.Draft.ValueExists('Phone', 'Width') or
    Context.Draft.ValueExists('Phone', 'Height')) then
    DefaultSize := 'custom';
  var Preset := Context.AddChoice('RowJ2MEScreenSize', 'Virtual Canvas size', 'Automatic selects a compatible Canvas and applies JAR/JAD scaling. Manual sizes take priority. Reopen the game to apply.', 'Phone', 'ScreenSize', Sizes, DefaultSize);
  Preset.ApplyMode := TSettingsApplyMode.OnNextLoad;
  var W := Context.AddInteger('RowJ2MEWidth', 'Screen width', 'Reopen the game to apply.', 'Phone', 'Width', 240, 1024);
  W.Min := 1;
  W.ApplyMode := TSettingsApplyMode.OnNextLoad;
  W.EnabledWhen :=
    function: Boolean
    begin
      Result := Preset.Value = 'custom';
    end;
  var H := Context.AddInteger('RowJ2MEHeight', 'Screen height', 'Reopen the game to apply.', 'Phone', 'Height', 320, 1024);
  H.Min := 1;
  H.ApplyMode := TSettingsApplyMode.OnNextLoad;
  H.EnabledWhen :=
    function: Boolean
    begin
      Result := Preset.Value = 'custom';
    end;
  Context.AddBoolean('RowJ2MEResolutionRecommendations', 'Show resolution recommendations',
    'Suggest a screen size detected during emulation. Shown only when starting a game from the beginning.',
    'Phone', 'ShowResolutionRecommendations', True);
  var M := Context.AddInteger('RowJ2MEMIDlet', 'MIDlet index', 'Zero selects the first application in the suite.', 'Phone', 'MIDletIndex', 0, 1023);
  M.Min := 0;
  M.ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

class function TJ2MEPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
var
  Archive: Core.Archive.Container.IArchiveContainer;
begin
  Result := nil;
  // JAR is a complete MIDlet suite, not a generic ROM archive to unpack.
  // PrepareArchive intentionally opens only ZIP/7z/RAR source extensions.
  if not Context.HasExtension(['.jar']) then
    Exit;
  Archive := Context.Archive;
  if Archive = nil then
  begin
    var Saved := Context.Stream.Position;
    try
      Context.Stream.Position := 0;
      if not IsZipArchive(Context.Stream) then
        Exit;
      Archive := OpenZip(Context.Stream, Context.EffectiveStorage);
    finally
      Context.Stream.Position := Saved;
    end;
  end;
  if Archive = nil then
    Exit;
  if Archive.FindName(J2MEManifestName) < 0 then
  begin
    var Location, Error: string;
    var JAD := ReadJ2MEJAD(Context.Stream, Context.EffectiveStorage, Context.RomName, Location, Error);
    if Length(JAD) = 0 then
      Exit;
    // The archive has no manifest. Verify the companion before claiming J2ME.
    TJ2MESuite.Create(Archive, JAD, Context.EffectiveStorage, Context.Stream.Size).Free;
  end;
  Result := TCoreMatch.Create('J2ME',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TJ2MECoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName);
    end);
  Result.Format.SystemId := 'j2me';
end;

class procedure TJ2MEPlatform.LoadKeys(var Keys: TPlatformInputKeyMap);
begin
  Keys[0, TEmulatorButton.Up] := vkUp;
  Keys[0, TEmulatorButton.Down] := vkDown;
  Keys[0, TEmulatorButton.Left] := vkLeft;
  Keys[0, TEmulatorButton.Right] := vkRight;
  Keys[0, TEmulatorButton.A] := vkReturn;
  Keys[0, TEmulatorButton.B] := Ord('0');
  Keys[0, TEmulatorButton.Select] := vkF1;
  Keys[0, TEmulatorButton.Start] := vkF2;
end;

class procedure TJ2MEPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
end;

class procedure TJ2MEPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('j2me', 'Java ME', 'J2ME', 'Java',
    'CLDC MIDP mobile phone Java games', 'j2me', ['j2me', 'javame', 'midp'], ['.jar'], 'J2ME', 'j2me', 1);
  var Registration := TEmulationCoreRegistration.Create('J2ME', ['.jar']);
  Registration.Add(TCoreLoadStage.Source, 50, Recognize);
  RegisterEmulationCore(Registration);
  var Services := Default(TPlatformServices);
  Services.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result := Default(TTerminalInputPolicy);
      Result.AllKeys := True;
      Result.ExitKey := vkEscape;
    end;
  RegisterPlatformServices('j2me', Services);
  RegisterSettingsPlatform('j2me', TJ2MESettings);
  RegisterPlatformSettingsDevices('j2me', TJ2MESettingsDevices);
  RegisterPlatformDeviceCallouts('j2me', TJ2MEDeviceCallouts);
  RegisterPlatformControlsHelp('j2me', TJ2MEControlsHelp);
  RegisterPlatformSettingsHandler('j2me', TJ2MESettingsHandler);
  RegisterPlatformWindowLayout('j2me', TJ2MEWindowLayout);
  RegisterPlatformSessionHandler('j2me', TJ2MESessionHandler);
  RegisterPlatformInputHandler('j2me', TJ2MEInputHandler);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.ButtonNames[TEmulatorButton.A] := 'Fire';
  Definition.ButtonNames[TEmulatorButton.B] := '0';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Left soft key';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Right soft key';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.LoadLegacyKeys := LoadKeys;
  Definition.AfterLegacyBindings := LoadJ2MELegacyBindings;
  Definition.AfterLoadBindings := MigrateJ2MEKeypadBindings;
  Definition.FilterBinding := FilterJ2MEKeypadBinding;
  Definition.UseSharedBindingRules := True;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('j2me', Definition);
  RegisterPlatformGamepads('j2me', TGamepadJ2MEArrowsNumbers, [
      TGamepadDeviceVariant.Create('numbers-arrows', TGamepadJ2ME),
      TGamepadDeviceVariant.Create('arrows-numbers', TGamepadJ2MEArrowsNumbers),
      TGamepadDeviceVariant.Create('phone', TGamepadJ2MEPhone),
      TGamepadDeviceVariant.Create('phone-arrows', TGamepadJ2MEPhoneArrows),
      TGamepadDeviceVariant.Create('numbers', TGamepadJ2MENumbers),
      TGamepadDeviceVariant.Create('arrows', TGamepadJ2MEArrows)]);
  RegisterPlatformPresentation('j2me', 'j2me', PlatformIconCPS);
  FRegistered := True;
end;

end.

