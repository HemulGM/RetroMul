unit RM.Settings.GBA;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TGBASettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageBuilder); override;
    procedure Peripherals(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, System.Math, RM.Icons;

procedure TGBASettings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupBootROM', 'Boot ROM');
  Context.AddPath('RowBootFileGBA', 'Boot ROM file', 'Optional 16 KiB GBA BIOS. Leave empty to use the built-in emibios.', 'Boot', 'File', '', False, True);
  Context.Heading('GroupGBACartridge', 'GBA cartridge');
  Context.AddChoice('RowGBASaveType', 'Save memory', 'Auto detects the cartridge. Override only when a ROM uses an unrecognized save format.', 'Cartridge', 'SaveType', SettingChoices([Translate('Auto'), Translate('None'), Translate('SRAM'),
        Translate('Flash 64 KiB'), Translate('Flash 128 KiB'), Translate('EEPROM')], ['-1', '0', '1', '2', '3', '4']), '-1', True);
  Context.AddInteger('RowGBASolarLevel', 'Sunlight', 'Boktai sensor level: 0 is darkness, 255 is maximum light.', 'Cartridge', 'SolarLevel', 128, 255, True);
end;

procedure TGBASettings.Peripherals(Context: TSettingsPageBuilder);
begin
  Context.Heading('GroupRumble', 'Rumble');
  Context.AddBoolean('RowRumble', 'Cartridge rumble', 'Vibrate the device when the game activates its rumble motor.', 'Peripherals', 'Rumble', True, True);
end;

initialization
  RegisterSettingsProfile('GBA', TGBASettings);

end.

