unit RM.Platforms.Atari2600.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, RM.Settings.Devices,
  System.IniFiles;

type
  TAtari2600Settings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
    procedure Validate(Draft: TMemIniFile); override;
  end;

  TAtari2600SettingsDevices = class(TPlatformSettingsDevices)
  public
    class procedure BindingFields(const Context: TSettingsDeviceContext; Page: TSettingsPageBuilder); override;
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
  end;

implementation

uses
  System.SysUtils, Core.Emulation.Types, RM.Input, FMX.Types;

function TAtari2600Settings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result := inherited PortOptions(Port);
  Result.Description := 'A joystick, a pair of paddles (two knobs and two fire buttons), or no controller.';
  Result.Labels := ['Joystick', 'Paddles (pair)', 'None'];
  Result.Values := ['pad', 'pad-analog', 'none'];
end;

procedure TAtari2600Settings.Validate(Draft: TMemIniFile);
begin
  inherited;
  for var Port := 1 to 2 do
    for var Knob := 1 to 2 do
    begin
      var Section := 'Paddles' + IntToStr(Port);
      var Suffix := IntToStr(Knob);
      var Minimum := Draft.ReadInteger(Section, 'Minimum' + Suffix, 0);
      var Maximum := Draft.ReadInteger(Section, 'Maximum' + Suffix, 100);
      if (Minimum < 0) or (Maximum > 100) or (Minimum >= Maximum) then
        raise EArgumentException.Create(Translate('Paddle range must be within 0..100% and its minimum must be less than its maximum.'));
    end;
end;

class procedure TAtari2600SettingsDevices.BindingFields(const Context: TSettingsDeviceContext; Page: TSettingsPageBuilder);
begin
  if Context.Device <> 'pad-analog' then
    Exit;
  var Section := 'Paddles' + IntToStr(Context.Port + 1);
  Page.AddInformation('Info' + Section, 'Paddle controls',
    'Assign Left/Right to knob 1 (X axis), Up/Down to knob 2 (Y axis), and a fire button for each knob. Keyboard directions turn the knobs and retain their position.', '');
  var Mouse := Page.AddBoolean('Row' + Section + 'Mouse', 'Use mouse',
    'Use mouse movement instead of absolute controller axes. X controls paddle 1, Y controls paddle 2; left/right mouse buttons fire.',
    Section, 'Mouse', False);
  var Sensitivity := Page.AddInteger('Row' + Section + 'MouseSensitivity', 'Mouse sensitivity (%)',
    'At 100%, 400 mouse counts cover the full paddle travel.', Section, 'MouseSensitivity', 100, 400);
  Sensitivity.Min := 1;
  Sensitivity.EnabledWhen := Mouse.IsTrue();
  var Speed := Page.AddInteger('Row' + Section + 'Speed', 'Keyboard turn speed (%)',
    'Percent of the full travel per second when holding a direction.', Section, 'Speed', 100, 400);
  Speed.Min := 1;
  for var Knob := 1 to 2 do
  begin
    var Suffix := IntToStr(Knob);
    var Caption := 'Paddle ' + Suffix + ' ';
    Page.AddBoolean('Row' + Section + 'Invert' + Suffix, Caption + 'invert',
      'Reverse the rotation direction.', Section, 'Invert' + Suffix, False);
    Page.AddInteger('Row' + Section + 'Minimum' + Suffix, Caption + 'minimum (%)',
      'Lower end of the physical potentiometer range.', Section, 'Minimum' + Suffix, 0, 99);
    var Maximum := Page.AddInteger('Row' + Section + 'Maximum' + Suffix, Caption + 'maximum (%)',
      'Upper end of the physical potentiometer range. Reduce it if the game uses only part of the travel.',
      Section, 'Maximum' + Suffix, 100, 100);
    Maximum.Min := 1;
    Page.AddInteger('Row' + Section + 'DeadZone' + Suffix, Caption + 'dead zone (%)',
      'Ignore small analog axis movement around its center.', Section, 'DeadZone' + Suffix, 2, 30);
  end;
end;

class function TAtari2600SettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  if Context.Device <> 'pad-analog' then
    Exit(inherited Assignments(Context));
  Result := [
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.Left), 'Paddle 1 decrease / X-'),
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.Right), 'Paddle 1 increase / X+'),
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.A), 'Paddle 1 fire'),
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.Up), 'Paddle 2 decrease / Y-'),
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.Down), 'Paddle 2 increase / Y+'),
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.B), 'Paddle 2 fire'),
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.Start), 'Reset'),
      TSettingsDeviceBinding.Create(PadAction(Context.Port, TEmulatorButton.Select), 'Select')];
end;

procedure TAtari2600Settings.Video(Context: TSettingsPageBuilder);
begin
  Context.AddChoice('RowAtariVideoRegion', 'TV standard', 'Automatic uses the PAL tag in the cartridge name. Reopen the game after changing this setting.',
    'Video', 'Region', SettingChoices(['Automatic', 'NTSC', 'PAL'], ['auto', 'ntsc', 'pal']), 'auto', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

procedure TAtari2600Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupAtariConsole', 'Console switches');
  Context.AddBoolean('RowAtariColor', 'Color TV', 'Turn off for black and white TV mode.', 'Console', 'Color', True, True);
  Context.AddBoolean('RowAtariDifficultyLeft', 'Left difficulty A', 'Off selects difficulty B.', 'Console', 'DifficultyLeft', False, True);
  Context.AddBoolean('RowAtariDifficultyRight', 'Right difficulty A', 'Off selects difficulty B.', 'Console', 'DifficultyRight', False, True);
  Context.AddChoice('RowAtariMapper', 'Cartridge type', 'Automatic detects common cartridges. Reopen the game after changing this setting.',
    'Cartridge', 'Mapper', SettingChoices(['Automatic', '2K', '4K', 'F8', 'F8SC', 'F6', 'F6SC', 'F4', 'F4SC', 'E0', '3F', 'FA', 'E7', 'FE', 'UA', 'CV', '0840', 'MB', 'MC32', 'DPC', 'AR', 'CM', 'MC16'],
      ['', '2K', '4K', 'F8', 'F8SC', 'F6', 'F6SC', 'F4', 'F4SC', 'E0', '3F', 'FA', 'E7', 'FE', 'UA', 'CV', '0840', 'MB', 'MC32', 'DPC', 'AR', 'CM', 'MC16']), '', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

end.

