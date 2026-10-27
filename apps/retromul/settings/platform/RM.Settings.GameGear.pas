unit RM.Settings.GameGear;

interface

uses
  RM.Settings.Builder, RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TGameGearSettings = class(TSega8BitSettings)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Hardware(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types;

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

initialization
  RegisterSettingsProfile('GameGear', TGameGearSettings);

end.

