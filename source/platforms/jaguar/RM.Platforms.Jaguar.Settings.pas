unit RM.Platforms.Jaguar.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, RM.Settings.Devices, FMX.Controls,
  System.IniFiles;

type
  TJaguarSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
    procedure PrepareSave(Draft: TMemIniFile); override;
  end;

  TJaguarSettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
  end;

implementation

uses
  RM.Platforms.Jaguar.Input, RM.Gamepad;

procedure TJaguarSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupJaguarSystem', 'Atari Jaguar');
  Context.AddChoice('RowJaguarBoot', 'Boot mode',
    'Fast startup for cartridges and CDs, or original boot ROM. Reopen the game to apply.',
    'Hardware', 'BootBIOS', SettingChoices(['Fast startup', 'Original BIOS'], ['0', '1']), '0', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
  Context.AddChoice('RowJaguarRegion', 'Video standard',
    'Video timing and console region. Reopen the game to apply.',
    'Video', 'PAL', SettingChoices(['NTSC', 'PAL'], ['0', '1']), '0', True).ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

procedure TJaguarSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupJaguarTeamTap', 'Team Tap');
  var Tap := Context.AddBoolean('RowJaguarTap1', 'Team Tap · port 1', 'Players 1, 3, 4 and 5.', 'Input', 'Multitap1', False);
  Tap.OnChange := Context.OnRebuild;
  Tap := Context.AddBoolean('RowJaguarTap2', 'Team Tap · port 2', 'Players 2, 6, 7 and 8.', 'Input', 'Multitap2', False);
  Tap.OnChange := Context.OnRebuild;
end;

function TJaguarSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  if Draft.ReadBool('Input', 'Multitap1', False) then
    Result := 5;
  if Draft.ReadBool('Input', 'Multitap2', False) then
    Result := 8;
end;

function TJaguarSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result := inherited PortOptions(Port);
  Result.Description := 'Jaguar controller with A, B, C, Pause, Option and a twelve-key keypad.';
  Result.Labels := ['Jaguar joypad / ProController', 'Rotary (Tempest)', 'None'];
  Result.Values := ['pad', 'rotary', 'none'];
end;

procedure TJaguarSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.WriteInteger('FMXInput', 'JaguarKeypadVersion', 1);
end;

class function TJaguarSettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited Assignments(Context);
  for var Key := 0 to 11 do
    Result := Result + [TSettingsDeviceBinding.Create(JaguarKeypadAction(Context.Port, Key),
      'Keypad ' + JaguarKeypadCaption(Key))];
end;

class function TJaguarSettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := inherited Selection(Context, Control);
  if Control is TScreenGamepad then
    for var Key := 0 to 11 do
      if TScreenGamepad(Control).AuxiliaryButtons and (Cardinal(1) shl Key) <> 0 then
        Exit(TSettingsDeviceBinding.Create(JaguarKeypadAction(Context.Port, Key),
            'Keypad ' + JaguarKeypadCaption(Key)));
end;

end.

