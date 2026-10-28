unit RM.Platforms.PCE.Settings;

interface

uses
  System.IniFiles, RM.Settings.Platform, RM.Settings.Builder;

type
  TPCESettings = class(TSettingsPlatform)
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
  FMX.Types, System.SysUtils;

procedure TPCESettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupPCEHardware', 'PC Engine hardware');
  if CoreId = 'pcecd' then
  begin
    Context.AddChoice('RowPCEModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model', SettingChoices([Translate('Automatic'), 'CD-ROM²',
          'TurboGrafx-CD', 'Super CD-ROM²', 'Duo', 'Duo-R', 'Duo-RX', 'TurboDuo',
          'Arcade Card Duo', 'Arcade Card Pro', 'SuperGrafx + Super CD-ROM²', 'SuperGrafx + Arcade Card'], ['auto', 'cdrom2', 'tgcd', 'supercd', 'duo', 'duor', 'duorx', 'turboduo',
          'arcadeduo', 'arcadepro', 'sgxcd', 'sgxarcade']), 'auto', True);
    with Context.AddPath('RowPCEBIOS', 'System Card BIOS', 'Leave empty to use the built-in BIOS.', 'Hardware', 'BIOS', '', False) do
    begin
      FileFilter := 'Boot ROM (*.bin;*.rom;*.gb)|*.bin;*.rom;*.gb|All files|*.*';
      PickerTitle := 'Choose boot ROM';
    end;
  end
  else if CoreId = 'sgx' then
    Context.AddChoice('RowPCEModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model',
      SettingChoices([Translate('Automatic'), 'SuperGrafx'], ['auto', 'sgx']), 'auto', True)
  else
    Context.AddChoice('RowPCEModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model',
      SettingChoices([Translate('Automatic'), 'PC Engine', 'TurboGrafx-16', 'CoreGrafx', 'CoreGrafx II', 'Shuttle',
          'GT / TurboExpress', 'LT', 'SuperGrafx'],
        ['auto', 'pce', 'tg16', 'coregrafx', 'coregrafxii', 'shuttle', 'gt', 'lt', 'sgx']), 'auto', True);
  Context.Heading('GroupPCEVideo', 'Video layers');
  Context.AddBoolean('RowPCEBackground', 'Show background', 'Display the background layer.', 'Video', 'ShowBackground', True, True);
  Context.AddBoolean('RowPCESprites', 'Show sprites', 'Display the sprite layer.', 'Video', 'ShowSprites', True, True);
  Context.AddBoolean('RowPCESpriteLimit', 'Remove sprite limit', 'Reduce sprite flicker. Extra sprites may reveal unexpected graph' + 'ics.', 'Video', 'RemoveSpriteLimit', False, True);
end;

procedure TPCESettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupPCEInput', 'Controllers');
  Context.AddBoolean('RowPCETurboTap', 'TurboTap (5 players)', 'Connect up to five controllers.', 'Input', 'Multitap1', False, True).OnChange := Context.OnRebuild;
end;

function TPCESettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 1;
  if Draft.ReadBool('Input', 'Multitap1', False) then
    Result := 5;
end;

function TPCESettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.SingleLineDescription := False;
  Result.Caption := 'Connected device';
  Result.Description := 'Controller connected to this port.';
  Result.RowName := 'RowConnecteddevice26Port' + IntToStr(Port + 1);
  Result.Labels := ['Pad I / II', 'Avenue Pad 6', Translate('None')];
  Result.Values := ['pad', 'pad6', 'none'];
  Result.Default := 'pad';
end;

procedure TPCESettings.PrepareSave(Draft: TMemIniFile);
begin
  inherited;
  Draft.DeleteKey('Audio', 'FMEnabled');
end;

end.

