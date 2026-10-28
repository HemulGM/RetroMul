unit RM.Platforms.Saturn.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TSaturnSettings = class(TSettingsPlatform)
  public
    procedure PrepareSave(Draft: TMemIniFile); override;
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils;

procedure TSaturnSettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSaturnSystem', 'System');
  Context.AddChoice('RowSaturnRegion', 'Region', 'Select the console region used by the BIOS.', 'System', 'Region',
    SettingChoices(['Japan', 'North America', 'Europe'], ['1', '4', '12']), '4');
  with Context.AddPath('RowSaturnBIOS', 'BIOS file', 'Optional 512 KiB BIOS override. A regional BIOS is built in.', 'Hardware', 'BIOS', '', False) do
  begin
    FileFilter := 'Boot ROM (*.bin;*.rom;*.gb)|*.bin;*.rom;*.gb|All files|*.*';
    PickerTitle := 'Choose boot ROM';
  end;
  Context.AddChoice('RowSaturnRAMCart', 'Cartridge', 'Expansion RAM, game ROM, or persistent backup memory.',
    'Hardware', 'RAMCart',
    SettingChoices(['None', '1 MiB RAM', '4 MiB RAM', 'ROM cartridge', '512 KiB backup', '1 MiB backup',
        '2 MiB backup', '4 MiB backup'], ['0', '1', '4', '16', '33', '34', '35', '36']), '0');
  with Context.AddPath('RowSaturnCartROM', 'ROM cartridge file', 'Game-specific ROM cartridge image, used when ROM cartridge is selected.', 'Hardware', 'CartROM', '', False) do
  begin
    FileFilter := 'Boot ROM (*.bin;*.rom;*.gb)|*.bin;*.rom;*.gb|All files|*.*';
    PickerTitle := 'Choose boot ROM';
  end;
  Context.AddChoice('RowSaturnCDBackend', 'CD Block', 'Command model or original SH-1 firmware. Firmware mode is experimental.',
    'Hardware', 'CDBackend',
    SettingChoices(['Command model', 'SH-1 firmware (experimental)'], ['model', 'sh1']), 'model');
  Context.AddBoolean('RowSaturnProtection', 'Optical protection',
    'Require the physical security ring. Sector images cannot provide it.', 'Hardware', 'OpticalProtection', False);
  Context.AddBoolean('RowSaturnPAL', 'PAL video', 'Use PAL video timing.', 'System', 'PAL', False);
end;

procedure TSaturnSettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupAdditionalplayers', 'Additional players');
  Context.AddBoolean('RowMultitapport1', 'Multitap '#183' port 1', 'Players 1, 6, 7 and 8.', 'Input', 'Multitap1', False).OnChange := Context.OnRebuild;
  Context.AddBoolean('RowMultitapport2', 'Multitap '#183' port 2', 'Controllers for players 2'#8211'5.', 'Input', 'Multitap2', False).OnChange := Context.OnRebuild;
end;

function TSaturnSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  for var Port := 1 to 2 do
    if Draft.ReadBool('Input', 'Multitap' + IntToStr(Port), False) then
      Inc(Result, 5);
end;

function TSaturnSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.SingleLineDescription := False;
  Result.Caption := 'Controller';
  Result.Description := 'Digital pad, analog 3D pad, or disconnected.';
  Result.RowName := 'RowSaturnControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['Digital pad', 'Analog 3D pad', 'None'];
  Result.Values := ['pad', 'pad-analog', 'none'];
  Result.Default := 'pad';
end;

procedure TSaturnSettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.

