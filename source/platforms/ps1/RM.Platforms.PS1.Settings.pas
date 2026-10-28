unit RM.Platforms.PS1.Settings;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TPS1Settings = class(TSettingsPlatform)
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

procedure TPS1Settings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupPS1System', 'System');
  with Context.AddPath('RowPS1BIOS', 'BIOS file', 'Optional 512 KiB PlayStation BIOS. Without it, a BIOS beside the game or the built-in one is used.', 'Hardware', 'BIOS', '', False) do
  begin
    FileFilter := 'Boot ROM (*.bin;*.rom;*.gb)|*.bin;*.rom;*.gb|All files|*.*';
    PickerTitle := 'Choose boot ROM';
  end;
  Context.AddChoice('RowPS1Video', 'Video standard', 'Automatic follows the BIOS or the disc region.', 'System', 'Video',
    SettingChoices(['Automatic', 'NTSC (60 Hz)', 'PAL (50 Hz)'], ['auto', 'ntsc', 'pal']), 'auto');
end;

procedure TPS1Settings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupPS1Rumble', 'Rumble');
  Context.AddBoolean('RowPS1Rumble', 'DualShock rumble', 'Vibrate the gamepad when the game runs the motors of the first DualShock.', 'Peripherals', 'Rumble', True);
end;

function TPS1Settings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
end;

function TPS1Settings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.SingleLineDescription := False;
  Result.Caption := 'Controller';
  Result.Description := 'Digital pad, DualShock (press ANALOG for analog mode) or disconnected.';
  Result.RowName := 'RowPS1ControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['Digital pad', 'DualShock', 'None'];
  Result.Values := ['pad', 'pad-analog', 'none'];
  Result.Default := 'pad';
end;

procedure TPS1Settings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.

