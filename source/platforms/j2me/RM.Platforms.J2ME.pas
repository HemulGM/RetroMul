unit RM.Platforms.J2ME;

interface

uses
  Core.EmulatorRegistry, RM.Input, RM.Input.Runtime, FMXInput;

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

implementation

uses
  System.SysUtils, System.UITypes, Core.Platforms, Core.Emulation,
  Core.Archive.Container, Core.Archive.Zip, Core.PlatformServices,
  RM.Input.Gamepads, Core.Platforms.J2ME.Adapter, J2ME.Device,
  RM.Platforms.Presentation, RM.Platforms.CPS.Icons, RM.Settings.Catalog,
  RM.Settings.Platform, RM.Settings.Builder, RM.Settings.Devices,
  RM.Settings.Callouts, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Session.Runtime, RM.Window.Layout, RM.Gamepad.Factory,
  RM.Platforms.GB.Gamepads;

type
  TJ2MEInputHandler = class(TPlatformInputHandler)
  public
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
  end;

  TJ2MESettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
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
  var Sizes: TArray<TSettingsChoiceItem> := [SettingChoice('Custom width and height', 'custom')];
  for var Size in TJ2MEScreenSize.Presets do
    Sizes := Sizes + [SettingChoice(IntToStr(Size.Width) + ' × ' + IntToStr(Size.Height), Size.ToString)];
  var Preset := Context.AddChoice('RowJ2MEScreenSize', 'Screen size', 'Match the resolution of this game version. Reopen the game to apply.', 'Phone', 'ScreenSize', Sizes, 'custom');
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
  if (Archive = nil) or (Archive.FindName('META-INF/MANIFEST.MF') < 0) then
    Exit;
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
  RegisterPlatformSettingsDevices('j2me', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('j2me', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('j2me', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('j2me', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('j2me', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('j2me', TPlatformSessionHandler);
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
  Definition.UseSharedBindingRules := True;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('j2me', Definition);
  // Existing controls and Fluent Games icon are reused for the initial frontend.
  RegisterPlatformGamepads('j2me', TGamepadGBStandart, []);
  RegisterPlatformPresentation('j2me', 'j2me', PlatformIconCPS);
  FRegistered := True;
end;

end.

