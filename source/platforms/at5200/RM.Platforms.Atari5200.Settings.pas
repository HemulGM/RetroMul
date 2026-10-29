unit RM.Platforms.Atari5200.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, RM.Settings.Devices, FMX.Controls,
  System.IniFiles;

type
  TAtari5200Settings = class(TSettingsPlatform)
  public
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
    procedure PrepareSave(Draft: TMemIniFile); override;
  end;

  TAtari5200SettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
  end;

implementation

uses
  RM.Platforms.Atari5200.Input, RM.Gamepad;

procedure TAtari5200Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupAtari5200Cartridge', 'Cartridge');
  Context.AddChoice('RowAtari5200Mapper', 'Cartridge type',
    'Override automatic cartridge detection. Reopen the game after changing this setting.',
    'Cartridge', 'Mapper', SettingChoices(['Automatic', '4 KiB', '8 KiB', '16 KiB two chip', '16 KiB one chip', '32 KiB', '40 KiB Bounty Bob'],
      ['-1', '0', '1', '2', '3', '4', '5']), '-1', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

function TAtari5200Settings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result := inherited PortOptions(Port);
  Result.Description := 'Analog joystick for controller axes, or digital directions for a keyboard or D-pad.';
  Result.Labels := ['Digital directions', 'Analog joystick', 'None'];
  Result.Values := ['pad', 'pad-analog', 'none'];
end;

procedure TAtari5200Settings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.WriteInteger('FMXInput', 'Atari5200KeypadVersion', 1);
end;

class function TAtari5200SettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited Assignments(Context);
  for var Key := 0 to 11 do
    Result := Result + [TSettingsDeviceBinding.Create(Atari5200KeypadAction(Context.Port, Key),
      'Keypad ' + Atari5200KeypadCaption(Key))];
end;

class function TAtari5200SettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := inherited Selection(Context, Control);
  if Control is TScreenGamepad then
    for var Key := 0 to 11 do
      if TScreenGamepad(Control).AuxiliaryButtons and (Cardinal(1) shl Key) <> 0 then
        Exit(TSettingsDeviceBinding.Create(Atari5200KeypadAction(Context.Port, Key),
            'Keypad ' + Atari5200KeypadCaption(Key)));
end;

end.

