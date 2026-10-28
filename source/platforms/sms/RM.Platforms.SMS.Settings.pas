unit RM.Platforms.SMS.Settings;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Platforms.SG1000.Settings.Base;

type
  TMasterSystemSettings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageBuilder); override;
    procedure Audio(Context: TSettingsPageBuilder); override;
  end;

type
  TGameGearSettings = class(TSega8BitSettings)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Hardware(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  FMX.Types, System.SysUtils, RM.Icons;

procedure TMasterSystemSettings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddChoice('RowSegaModel', 'Console model', 'Select the hardware used when opening a ROM.', 'Hardware', 'Model',
    SettingChoices([Translate('Automatic'), 'Master System', 'Mark III'], ['auto', 'sms', 'markiii']), 'auto', True);
  Context.AddBoolean('RowSegaBIOSEnabled', 'Use BIOS', 'Run the selected BIOS before the cartridge.', 'Hardware', 'BIOSEnabled', True, True);
  Context.AddPath('RowSegaBIOS', 'BIOS file', 'Optional 8, 16 or 32 KiB Master System BIOS.', 'Hardware', 'BIOS', '', False, True);
  Context.AddChoice('RowSegaMapper', 'Cartridge mapper', 'Auto detects known cartridges. Override for unrecognized ROMs.', 'Cartridge', 'Mapper',
    SettingChoices([Translate('Automatic'), 'Sega', 'Codemasters', 'Korean', 'Zemina', 'Nemesis',
        'Janggun', 'HiCom', '4 Pak', 'Korean 188', 'Fixed 48 KiB', 'Seojin', '93C46 EEPROM'],
      ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11']), '-1', True);
end;

procedure TMasterSystemSettings.Audio(Context: TSettingsPageBuilder);
begin
  inherited;
  Context.AddInteger('RowSegaFMVolume', 'FM volume (%)', 'Adjust FM sound independently of the PSG channels.', 'Audio', 'FMVolume', 100, 100, True);
end;

procedure TGameGearSettings.Video(Context: TSettingsPageBuilder);
begin
  Hardware(Context);
  Context.Heading('GroupSegaVideo', 'Video layers');
  Context.AddBoolean('RowSegaShowBackground', 'Show background', 'Display the background layer.', 'Video', 'ShowBackground', True, True);
  Context.AddBoolean('RowSegaShowSprites', 'Show sprites', 'Display the sprite layer.', 'Video', 'ShowSprites', True, True);
  Context.AddBoolean('RowSegaRemoveSpriteLimit', 'Remove sprite limit', 'Reduce sprite flicker. Extra sprites may reveal unexpected graphics.', 'Video', 'RemoveSpriteLimit', False, True);
end;

procedure TGameGearSettings.Hardware(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupSegaHardware', 'Sega hardware');
  Context.AddChoice('RowSegaGGRegion', 'Console region', 'Automatic follows the cartridge header. Some games require Japanese hardware.', 'Hardware', 'Territory', SettingChoices([Translate('Automatic'), 'Export', 'Japan'], ['0', '1', '2']), '0', True);
  Context.AddChoice('RowSegaMapper', 'Cartridge mapper', 'Auto detects known cartridges. Override for unrecognized ROMs.', 'Cartridge', 'Mapper', SettingChoices([Translate('Automatic'), 'Sega', 'Codemasters', '93C46 EEPROM'], ['-1', '0', '1', '11']), '-1', True);
end;

end.

